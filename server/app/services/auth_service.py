"""认证与账户服务。

事务边界：本模块的方法**自己提交事务**。理由是一个方法就是一个完整的业务动作
（注册 / 登录 / 刷新…），把 commit 交给调用方容易漏掉，产生"看起来成功其实没写"的 bug。
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass
from datetime import datetime

from sqlalchemy import delete, select, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from ..core.config import Settings
from ..core.errors import ApiError, ErrorCode
from ..core.logging import redact  # noqa: F401  （保持与日志脱敏同一模块依赖）
from ..core.timeutil import utcnow
from ..models import Device, RefreshToken, User, UserStatus
from ..security.passwords import hash_password, needs_rehash, verify_password
from ..security.tokens import create_access_token, create_refresh_token, hash_token


@dataclass(frozen=True)
class TokenBundle:
    """一次签发的令牌对。``refresh_token`` 是明文，只在响应里出现这一次。"""

    access_token: str
    access_expires_at: datetime
    refresh_token: str
    refresh_expires_at: datetime
    refresh_model: RefreshToken


def _issue_bundle(
    db: Session,
    *,
    user: User,
    settings: Settings,
    device: Device | None,
    access_ttl_minutes: int | None = None,
) -> TokenBundle:
    """签发一对令牌。

    ``access_ttl_minutes`` 用于「同一套令牌体系、不同的有效期」：
    Windows / Android 客户端沿用 15 分钟；网页会话（HttpOnly Cookie）默认 30 分钟，
    避免长驻标签页频繁静默刷新。``None`` = 用配置里的默认值。
    """
    access = create_access_token(
        user_id=user.id,
        secret=settings.jwt_secret,
        algorithm=settings.jwt_algorithm,
        ttl_minutes=access_ttl_minutes or settings.access_token_ttl_minutes,
        issuer=settings.jwt_issuer,
        device_id=device.id if device else None,
    )
    refresh = create_refresh_token(ttl_days=settings.refresh_token_ttl_days)
    model = RefreshToken(
        user_id=user.id,
        device_id=device.id if device else None,
        token_hash=refresh.token_hash,
        issued_at=utcnow(),
        expires_at=refresh.expires_at,
    )
    db.add(model)
    db.flush()
    return TokenBundle(
        access_token=access.token,
        access_expires_at=access.expires_at,
        refresh_token=refresh.token,
        refresh_expires_at=refresh.expires_at,
        refresh_model=model,
    )


def register(
    db: Session,
    *,
    email: str,
    password: str,
    display_name: str,
) -> User:
    """注册新账户。重复邮箱返回 ``email_taken``。"""
    normalized = email.strip().lower()

    existing = db.scalar(select(User).where(User.email == normalized))
    if existing is not None:
        # 注意：这里确实暴露了"邮箱已注册"。注册接口不可避免，
        # 但**登录**接口一律返回统一的 invalid_credentials（见 authenticate）。
        raise ApiError(ErrorCode.email_taken, "该邮箱已被注册")

    user = User(
        email=normalized,
        display_name=display_name.strip(),
        password_hash=hash_password(password),
        status=UserStatus.active.value,
    )
    db.add(user)
    try:
        db.commit()
    except IntegrityError as exc:
        # 并发注册同一邮箱：唯一索引兜底
        db.rollback()
        raise ApiError(ErrorCode.email_taken, "该邮箱已被注册") from exc
    db.refresh(user)
    return user


def authenticate(db: Session, *, email: str, password: str) -> User:
    """校验邮箱 + 密码。

    需求要求"登录错误不要暴露邮箱是否存在"，因此：
    * 用户不存在 → ``invalid_credentials``；
    * 密码错误 → ``invalid_credentials``；
    * 账户被停用 → ``account_disabled``（这是用户需要知道的状态，且只有
      密码正确时才会返回，不会泄露邮箱是否存在）。
    """
    normalized = email.strip().lower()
    user = db.scalar(select(User).where(User.email == normalized))
    if user is None:
        raise ApiError(ErrorCode.invalid_credentials, "邮箱或密码错误")

    if not verify_password(password, user.password_hash):
        raise ApiError(ErrorCode.invalid_credentials, "邮箱或密码错误")

    if user.status == UserStatus.deleted.value:
        raise ApiError(ErrorCode.invalid_credentials, "邮箱或密码错误")
    if user.status == UserStatus.disabled.value:
        raise ApiError(ErrorCode.account_disabled, "账户已被停用")

    # 哈希参数升级后顺手升级存储的哈希（不影响用户体验）
    if needs_rehash(user.password_hash):
        user.password_hash = hash_password(password)
        db.commit()
    return user


def create_session(
    db: Session,
    *,
    user: User,
    settings: Settings,
    device: Device | None = None,
    access_ttl_minutes: int | None = None,
) -> TokenBundle:
    bundle = _issue_bundle(
        db,
        user=user,
        settings=settings,
        device=device,
        access_ttl_minutes=access_ttl_minutes,
    )
    db.commit()
    return bundle


def refresh_session(
    db: Session,
    *,
    raw_refresh_token: str,
    settings: Settings,
    device_local_id: str | None = None,
    access_ttl_minutes: int | None = None,
) -> tuple[User, TokenBundle, Device | None]:
    """刷新令牌（带轮换与复用检测）。

    复用检测规则：
    * 该 token 已被**轮换**过（``replaced_by_id`` 非空）却再次出现 → 判定为泄露，
      吊销该用户全部 refresh token 并返回 ``refresh_token_reused``；
    * 因为注销 / 改密 / 撤销设备被吊销的 token → 返回 ``token_invalid``
      （不触发全量吊销，否则一个在途的重试请求会把用户所有设备踢下线）。

    ``device_local_id`` 用于「先登录、后注册设备」的客户端流程：
    原令牌没绑设备时，在这里把它绑到已存在的同 local_id 设备上，
    使后续的撤销设备能够立刻让这台机器掉线。
    """
    now = utcnow()
    token_hash = hash_token(raw_refresh_token)
    record = db.scalar(select(RefreshToken).where(RefreshToken.token_hash == token_hash))
    if record is None:
        raise ApiError(ErrorCode.token_invalid, "Refresh Token 无效，请重新登录")

    if record.reused_detected_at is not None:
        raise ApiError(ErrorCode.refresh_token_reused, "Refresh Token 已被判定为泄露，请重新登录")

    if record.revoked_at is not None:
        if record.replaced_by_id is not None:
            # 已轮换过的 token 再次使用：泄露信号
            record.reused_detected_at = now
            revoked = revoke_all_sessions(db, user_id=record.user_id, commit=False)
            db.commit()
            raise ApiError(
                ErrorCode.refresh_token_reused,
                "检测到 Refresh Token 被重复使用，已注销全部会话，请重新登录",
                detail={"revoked_sessions": revoked},
            )
        raise ApiError(ErrorCode.token_invalid, "Refresh Token 已失效，请重新登录")

    if record.expires_at <= now:
        record.revoked_at = now
        db.commit()
        raise ApiError(ErrorCode.token_expired, "Refresh Token 已过期，请重新登录")

    user = db.get(User, record.user_id)
    if user is None or user.status != UserStatus.active.value:
        raise ApiError(ErrorCode.unauthorized, "账户不可用，请重新登录")

    device: Device | None = None
    if record.device_id is not None:
        device = db.get(Device, record.device_id)
        if device is None or device.revoked_at is not None:
            record.revoked_at = now
            db.commit()
            raise ApiError(ErrorCode.device_revoked, "该设备已被撤销，请重新登录")
    elif device_local_id:
        # 只做「查已存在的设备并补绑定」，不在这里创建设备：
        # 避免刷新接口被用来批量创建垃圾设备记录。
        device = db.scalar(
            select(Device).where(
                Device.user_id == user.id,
                Device.device_local_id == device_local_id.strip(),
                Device.revoked_at.is_(None),
            )
        )

    # 轮换：旧 token 立即失效，并链到新 token
    bundle = _issue_bundle(
        db,
        user=user,
        settings=settings,
        device=device,
        access_ttl_minutes=access_ttl_minutes,
    )
    record.revoked_at = now
    record.replaced_by_id = bundle.refresh_model.id
    db.commit()
    return user, bundle, device


def revoke_by_token(db: Session, *, raw_refresh_token: str) -> int:
    """注销当前会话（按 token 精确注销）。返回被吊销的条数。"""
    now = utcnow()
    token_hash = hash_token(raw_refresh_token)
    result = db.execute(
        update(RefreshToken)
        .where(RefreshToken.token_hash == token_hash, RefreshToken.revoked_at.is_(None))
        .values(revoked_at=now)
    )
    db.commit()
    return int(result.rowcount or 0)


def revoke_all_sessions(
    db: Session,
    *,
    user_id: uuid.UUID,
    commit: bool = True,
    keep_token_hash: str | None = None,
) -> int:
    """注销该用户的全部会话。

    ``keep_token_hash`` 用于"改密后保留当前设备"的场景；本阶段改密一律全量注销，
    因此默认不保留。
    """
    now = utcnow()
    stmt = update(RefreshToken).where(
        RefreshToken.user_id == user_id, RefreshToken.revoked_at.is_(None)
    )
    if keep_token_hash is not None:
        stmt = stmt.where(RefreshToken.token_hash != keep_token_hash)
    result = db.execute(stmt.values(revoked_at=now))
    if commit:
        db.commit()
    return int(result.rowcount or 0)


def revoke_device_tokens(db: Session, *, device_id: uuid.UUID, commit: bool = True) -> int:
    """吊销某设备的全部 refresh token（撤销设备时调用）。"""
    now = utcnow()
    result = db.execute(
        update(RefreshToken)
        .where(RefreshToken.device_id == device_id, RefreshToken.revoked_at.is_(None))
        .values(revoked_at=now)
    )
    if commit:
        db.commit()
    return int(result.rowcount or 0)


def change_password(
    db: Session,
    *,
    user: User,
    current_password: str,
    new_password: str,
) -> int:
    """修改密码；成功后吊销该用户全部会话（含当前），返回被吊销数量。

    需求：「修改密码…后，旧 Refresh Token 全部失效」。
    """
    if not verify_password(current_password, user.password_hash):
        raise ApiError(ErrorCode.invalid_credentials, "当前密码不正确")
    if verify_password(new_password, user.password_hash):
        raise ApiError(ErrorCode.conflict, "新密码不能与当前密码相同")

    user.password_hash = hash_password(new_password)
    user.updated_at = utcnow()
    db.flush()
    revoked = revoke_all_sessions(db, user_id=user.id, commit=False)
    db.commit()
    return revoked


def update_display_name(db: Session, *, user: User, display_name: str) -> User:
    user.display_name = display_name.strip()
    user.updated_at = utcnow()
    db.commit()
    db.refresh(user)
    return user


def delete_account(db: Session, *, user: User, current_password: str) -> None:
    """删除账户。

    采用**软删除 + 数据清理**：
    * ``status = deleted``、``deleted_at`` 置位，邮箱改为带后缀的占位值以便邮箱被重新注册；
    * 吊销全部 refresh token；
    * 物理删除设备与同步数据（需求：「删除账户后无法访问数据」+ 隐私最小化）。
    """
    if not verify_password(current_password, user.password_hash):
        raise ApiError(ErrorCode.invalid_credentials, "密码不正确")

    now = utcnow()
    revoke_all_sessions(db, user_id=user.id, commit=False)

    # 直接删除设备与同步数据；表上都有 ON DELETE CASCADE，但这里显式删除更直观
    db.execute(delete(Device).where(Device.user_id == user.id))

    # 邮箱加后缀，释放原邮箱（同时避免"已删除账户"被登录枚举出来）
    suffix = f"+deleted.{uuid.uuid4().hex[:8]}"
    local, _, domain = user.email.partition("@")
    user.email = f"{local}{suffix}@{domain}" if domain else f"{user.email}{suffix}"
    user.status = UserStatus.deleted.value
    user.deleted_at = now
    user.updated_at = now
    # 把密码哈希也换成一个不可用的随机值，确保旧密码无法再登录
    user.password_hash = hash_password(uuid.uuid4().hex + uuid.uuid4().hex)
    db.commit()

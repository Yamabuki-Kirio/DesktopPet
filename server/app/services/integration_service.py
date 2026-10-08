"""Phase 3：Telegram 绑定服务。

只做两件事：**发放一次性绑定码**、**把 Telegram 身份绑到 PetLife 用户**。
统计算法一律复用 ``stats_service``，这里不重复实现。

安全要点
--------
* 绑定码明文只在生成响应里出现一次；库里、日志里都只有 SHA-256 哈希；
* 消费绑定码用**带条件的 UPDATE**（``consumed_at IS NULL AND expires_at > now``）
  一次性占位，因此并发提交同一个码时**只有一个**能成功——不依赖"先查再改"；
* 冲突（同一 Telegram 账号已绑到别的账户）由**数据库的部分唯一索引**兜底，
  应用层只是把 ``IntegrityError`` 翻译成可读错误码。
"""

from __future__ import annotations

import hashlib
import secrets
import uuid
from datetime import datetime, timedelta

from sqlalchemy import func, select, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from ..core.errors import ApiError, ErrorCode
from ..core.logger import get_logger
from ..core.timeutil import utcnow
from ..models import (
    Device,
    IntegrationLinkCode,
    TelegramBinding,
    User,
    UserStatus,
)

logger = get_logger(__name__)

#: 去掉容易看错的 0/O/1/I/L，方便用户从屏幕上抄进 Telegram
_CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
_CODE_GROUP_SIZE = 4
_CODE_GROUPS = 2


def normalize_link_code(raw: str) -> str:
    """归一化用户输入：去空格/连字符并转大写。

    用户在 Telegram 里可能发 ``abcd-1234`` / ``ABCD1234`` / ``abcd 1234``，
    这些都应当能绑定成功。
    """
    return "".join(ch for ch in raw.upper() if ch.isalnum())


def hash_link_code(normalized: str) -> str:
    """对归一化后的码做 SHA-256。

    绑定码只有 40 bit 熵、且 10 分钟就过期，因此不需要额外加盐；
    关键是**库里不出现明文**。
    """
    return hashlib.sha256(normalized.encode("utf-8")).hexdigest()


def generate_link_code() -> str:
    """生成形如 ``ABCD-1234`` 的绑定码。"""
    chars = [secrets.choice(_CODE_ALPHABET) for _ in range(_CODE_GROUP_SIZE * _CODE_GROUPS)]
    groups = [
        "".join(chars[i : i + _CODE_GROUP_SIZE])
        for i in range(0, len(chars), _CODE_GROUP_SIZE)
    ]
    return "-".join(groups)


# ---------------------------------------------------------------------------
# 绑定码
# ---------------------------------------------------------------------------


def create_link_code(
    db: Session,
    *,
    user: User,
    ttl_minutes: int,
    now: datetime | None = None,
) -> tuple[str, IntegrationLinkCode]:
    """为 ``user`` 生成一个新的绑定码，并作废其之前未使用的码。

    返回 ``(明文码, 记录)``。明文码只在这里产生一次，调用方负责放进响应体。
    """
    issued_at = now or utcnow()
    expires_at = issued_at + timedelta(minutes=ttl_minutes)

    # 每个账户同时只允许一个"未消费"的码（部分唯一索引保证）。
    # 这里把旧的标记为已消费，而不是删除：保留审计痕迹，也不会撞唯一索引。
    db.execute(
        update(IntegrationLinkCode)
        .where(
            IntegrationLinkCode.user_id == user.id,
            IntegrationLinkCode.consumed_at.is_(None),
        )
        .values(consumed_at=issued_at)
        .execution_options(synchronize_session=False)
    )

    code = generate_link_code()
    record = IntegrationLinkCode(
        user_id=user.id,
        code_hash=hash_link_code(normalize_link_code(code)),
        expires_at=expires_at,
        created_at=issued_at,
    )
    db.add(record)
    db.commit()
    db.refresh(record)

    # 只记录"给谁发了码"，绝不记录码本身
    logger.info("link code issued user=%s ttl_minutes=%s", user.id, ttl_minutes)
    return code, record


def _claim_code(
    db: Session,
    *,
    digest: str,
    now: datetime,
) -> IntegrationLinkCode:
    """原子地占用一个绑定码。

    用一条带条件的 UPDATE 占位：并发提交同一个码时只有一条语句的
    ``rowcount`` 会是 1，其余拿到 0，从而**不可能**被用两次。
    """
    claimed = db.execute(
        update(IntegrationLinkCode)
        .where(
            IntegrationLinkCode.code_hash == digest,
            IntegrationLinkCode.consumed_at.is_(None),
            IntegrationLinkCode.expires_at > now,
        )
        .values(consumed_at=now)
        .execution_options(synchronize_session=False)
    )
    if claimed.rowcount == 1:
        record = db.scalar(
            select(IntegrationLinkCode).where(IntegrationLinkCode.code_hash == digest)
        )
        if record is not None:
            db.commit()
            return record
        raise ApiError(ErrorCode.internal_error, "绑定码状态异常，请重新生成")

    db.rollback()
    # 没能占用：把原因说清楚（无效 / 已用过 / 已过期），便于用户自查
    existing = db.scalar(
        select(IntegrationLinkCode).where(IntegrationLinkCode.code_hash == digest)
    )
    if existing is None:
        raise ApiError(ErrorCode.link_code_invalid, "绑定码无效，请在客户端重新生成")
    if existing.consumed_at is not None:
        raise ApiError(ErrorCode.link_code_consumed, "该绑定码已被使用过，请重新生成")
    raise ApiError(ErrorCode.link_code_expired, "绑定码已过期（有效期 10 分钟），请重新生成")


# ---------------------------------------------------------------------------
# 绑定
# ---------------------------------------------------------------------------


def active_binding_for_telegram(
    db: Session, *, telegram_user_id: int
) -> TelegramBinding | None:
    return db.scalar(
        select(TelegramBinding).where(
            TelegramBinding.telegram_user_id == telegram_user_id,
            TelegramBinding.revoked_at.is_(None),
        )
    )


def consume_link_code(
    db: Session,
    *,
    code: str,
    telegram_user_id: int,
    telegram_chat_id: int,
    now: datetime | None = None,
) -> tuple[TelegramBinding, bool]:
    """用绑定码建立 Telegram ↔ PetLife 关联。

    返回 ``(binding, already_bound)``；``already_bound=True`` 表示该 Telegram
    账号本来就绑在这个账户上（重复提交绑定码的幂等结果，不算错误）。
    """
    moment = now or utcnow()
    digest = hash_link_code(normalize_link_code(code))

    record = _claim_code(db, digest=digest, now=moment)

    user = db.get(User, record.user_id)
    if user is None or user.status != UserStatus.active.value:
        raise ApiError(
            ErrorCode.account_disabled,
            "绑定码对应的 PetLife 账户当前不可用（已停用或已注销）",
        )

    existing = active_binding_for_telegram(db, telegram_user_id=telegram_user_id)
    if existing is not None:
        if existing.user_id == user.id:
            logger.info("telegram already bound telegram_user=%s", telegram_user_id)
            return existing, True
        # 绑定码已经被占用，这里如实报冲突（不回滚码的占用）：
        # 否则会变成一个"这个码是否存在"的探测口子。
        raise ApiError(
            ErrorCode.telegram_already_bound,
            "该 Telegram 账号已绑定到另一个 PetLife 账户，请先在原账户解绑",
        )

    binding = TelegramBinding(
        user_id=user.id,
        telegram_user_id=telegram_user_id,
        telegram_chat_id=telegram_chat_id,
        created_at=moment,
    )
    db.add(binding)
    try:
        db.commit()
    except IntegrityError as exc:
        # 并发下两个请求同时绑定同一个 Telegram 账号，另一个先提交了
        db.rollback()
        raise ApiError(
            ErrorCode.telegram_already_bound,
            "该 Telegram 账号已绑定到另一个 PetLife 账户，请先在原账户解绑",
        ) from exc

    db.refresh(binding)
    logger.info(
        "telegram bound user=%s telegram_user=%s", user.id, telegram_user_id
    )
    return binding, False


def list_bindings(db: Session, *, user: User) -> list[TelegramBinding]:
    """列出某账户的全部绑定（含已解绑的，便于展示历史）。"""
    return list(
        db.scalars(
            select(TelegramBinding)
            .where(TelegramBinding.user_id == user.id)
            .order_by(TelegramBinding.created_at.desc())
        )
    )


def revoke_binding(
    db: Session, *, user: User, binding_id: uuid.UUID, now: datetime | None = None
) -> TelegramBinding:
    """解绑（幂等）。只能解绑**自己**的绑定。"""
    binding = db.scalar(
        select(TelegramBinding).where(
            TelegramBinding.id == binding_id,
            TelegramBinding.user_id == user.id,
        )
    )
    if binding is None:
        # 不区分"不存在"与"不属于你"，避免泄露其他用户的绑定是否存在
        raise ApiError(ErrorCode.binding_not_found, "绑定不存在或不属于当前账户")

    if binding.revoked_at is None:
        binding.revoked_at = now or utcnow()
        db.commit()
        db.refresh(binding)
        logger.info("telegram binding revoked user=%s binding=%s", user.id, binding.id)
    return binding


def revoke_binding_by_telegram(
    db: Session, *, telegram_user_id: int, now: datetime | None = None
) -> TelegramBinding | None:
    """Telegram 侧 ``/unbind``：按 Telegram 身份解绑。找不到返回 None。"""
    binding = active_binding_for_telegram(db, telegram_user_id=telegram_user_id)
    if binding is None:
        return None
    binding.revoked_at = now or utcnow()
    db.commit()
    db.refresh(binding)
    logger.info("telegram binding revoked by telegram_user=%s", telegram_user_id)
    return binding


def resolve_active_user(db: Session, *, telegram_user_id: int) -> User | None:
    """由 Telegram 身份反查**当前有效**的 PetLife 用户。

    这是整个 AI 链路唯一的身份入口：``user_id`` 永远从绑定关系推导，
    绝不接受调用方传入。账户被停用/注销时同样返回 None（立即失权）。
    """
    binding = active_binding_for_telegram(db, telegram_user_id=telegram_user_id)
    if binding is None:
        return None
    user = db.get(User, binding.user_id)
    if user is None or user.status != UserStatus.active.value:
        return None
    return user


def count_active_devices(db: Session, *, user: User) -> int:
    """当前用户的**未撤销**设备数（用于 ``/context`` 与同步状态）。"""
    value = db.scalar(
        select(func.count())
        .select_from(Device)
        .where(Device.user_id == user.id, Device.revoked_at.is_(None))
    )
    return int(value or 0)


__all__ = [
    "active_binding_for_telegram",
    "consume_link_code",
    "count_active_devices",
    "create_link_code",
    "generate_link_code",
    "hash_link_code",
    "list_bindings",
    "normalize_link_code",
    "resolve_active_user",
    "revoke_binding",
    "revoke_binding_by_telegram",
]

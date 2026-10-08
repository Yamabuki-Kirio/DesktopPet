"""Phase 3（改版）：个人访问密钥服务。

职责边界
--------
* **生成**：``plk_`` + 43 位 URL-safe 随机串；明文只经由返回值出现一次；
* **存储**：只落 SHA-256 哈希与前 12 字符前缀（复用 ``security.tokens.hash_token``）；
* **鉴权**：按哈希查一行 → 检查撤销 → 检查 scope → 刷新 ``last_used_at``；
* **撤销**：写 ``revoked_at``，幂等，且只能撤销自己的密钥。

这里**不做**任何统计，也不碰 Telegram 绑定：密钥本身就是身份。
"""

from __future__ import annotations

import secrets
import uuid
from datetime import datetime

from sqlalchemy import select
from sqlalchemy.orm import Session

from ..core.errors import ApiError, ErrorCode
from ..core.logger import get_logger
from ..core.timeutil import utcnow
from ..models import (
    ALLOWED_SCOPES,
    API_KEY_PREFIX,
    API_KEY_PREFIX_LENGTH,
    DEFAULT_SCOPES,
    SCOPE_STATS_READ,
    ApiKey,
    User,
    UserStatus,
)
from ..security.tokens import hash_token

logger = get_logger(__name__)

#: 随机部分的字节数（token_urlsafe(32) → 43 个 URL-safe 字符）
_KEY_RANDOM_BYTES = 32

NAME_MIN_LENGTH = 1
NAME_MAX_LENGTH = 64


def generate_key() -> str:
    """生成一把新密钥的明文（``plk_...``）。"""
    return f"{API_KEY_PREFIX}{secrets.token_urlsafe(_KEY_RANDOM_BYTES)}"


def key_prefix_of(plaintext: str) -> str:
    """取展示用前缀。截断到 ``API_KEY_PREFIX_LENGTH``，不泄露其余部分。"""
    return plaintext[:API_KEY_PREFIX_LENGTH]


def normalize_scopes(scopes: object) -> tuple[str, ...]:
    """校验并归一化权限集合。

    "权限固定为只读统计" 这件事在这里兜住：集合外的任何取值一律拒绝，
    而不是"存下来但不生效"——后者会让人以为授权成功了。
    """
    if scopes is None:
        return DEFAULT_SCOPES
    if isinstance(scopes, str):
        raw = [part for part in scopes.replace(",", " ").split() if part]
    elif isinstance(scopes, (list, tuple, set, frozenset)):
        raw = [str(part).strip() for part in scopes if str(part).strip()]
    else:
        raise ApiError(ErrorCode.validation_error, "scopes 格式不正确")

    if not raw:
        return DEFAULT_SCOPES

    unique = tuple(dict.fromkeys(raw))
    unknown = [scope for scope in unique if scope not in ALLOWED_SCOPES]
    if unknown:
        raise ApiError(
            ErrorCode.validation_error,
            f"不支持的权限 {unknown}；当前只允许 {sorted(ALLOWED_SCOPES)}（只读统计）",
        )
    return unique


def _validate_name(name: str) -> str:
    cleaned = (name or "").strip()
    if len(cleaned) < NAME_MIN_LENGTH:
        raise ApiError(ErrorCode.validation_error, "请给密钥起一个名字，便于日后识别")
    if len(cleaned) > NAME_MAX_LENGTH:
        raise ApiError(
            ErrorCode.validation_error, f"名称最长 {NAME_MAX_LENGTH} 个字符"
        )
    return cleaned


def create_key(
    db: Session,
    *,
    user: User,
    name: str,
    scopes: object = None,
    now: datetime | None = None,
) -> tuple[str, ApiKey]:
    """为 ``user`` 生成一把密钥，返回 ``(明文, 记录)``。"""
    plaintext = generate_key()
    record = ApiKey(
        user_id=user.id,
        key_hash=hash_token(plaintext),
        key_prefix=key_prefix_of(plaintext),
        name=_validate_name(name),
        scopes=" ".join(normalize_scopes(scopes)),
        created_at=now or utcnow(),
    )
    db.add(record)
    db.commit()
    db.refresh(record)

    # 只记录"给谁建了哪把（前缀）"，绝不记录明文或哈希
    logger.info(
        "api key created user=%s prefix=%s scopes=%s",
        user.id,
        record.key_prefix,
        record.scopes,
    )
    return plaintext, record


def list_keys(db: Session, *, user: User) -> list[ApiKey]:
    """列出某用户的全部密钥（含已撤销的，便于展示历史）。"""
    return list(
        db.scalars(
            select(ApiKey)
            .where(ApiKey.user_id == user.id)
            .order_by(ApiKey.created_at.desc())
        )
    )


def revoke_key(
    db: Session, *, user: User, key_id: uuid.UUID, now: datetime | None = None
) -> ApiKey:
    """撤销（幂等）。只能撤销**自己**的密钥。"""
    record = db.scalar(
        select(ApiKey).where(ApiKey.id == key_id, ApiKey.user_id == user.id)
    )
    if record is None:
        # 不区分"不存在"与"不属于你"，避免探测别人有哪些密钥
        raise ApiError(ErrorCode.api_key_not_found, "密钥不存在或不属于当前账户")

    if record.revoked_at is None:
        record.revoked_at = now or utcnow()
        db.commit()
        db.refresh(record)
        logger.info("api key revoked user=%s prefix=%s", user.id, record.key_prefix)
    return record


def find_by_plaintext(db: Session, *, plaintext: str) -> ApiKey | None:
    """按明文反查（内部只做哈希比对，不会明文入库）。"""
    candidate = (plaintext or "").strip()
    if not candidate:
        return None
    return db.scalar(select(ApiKey).where(ApiKey.key_hash == hash_token(candidate)))


def authenticate(db: Session, *, plaintext: str) -> tuple[ApiKey, User]:
    """鉴权：返回 ``(密钥, 用户)``，失败抛统一错误。

    失败原因刻意分成"无效"与"已撤销"两种：前者说明配置抄错了，
    后者说明这把钥匙被主动停用，排查方向完全不同。
    """
    record = find_by_plaintext(db, plaintext=plaintext)
    if record is None:
        raise ApiError(ErrorCode.api_key_invalid, "API 密钥无效")
    if record.revoked_at is not None:
        raise ApiError(ErrorCode.api_key_revoked, "该 API 密钥已被撤销")

    user = db.get(User, record.user_id)
    if user is None or user.status == UserStatus.deleted.value:
        raise ApiError(ErrorCode.api_key_invalid, "API 密钥对应的账户不存在")
    if user.status == UserStatus.disabled.value:
        raise ApiError(ErrorCode.account_disabled, "API 密钥对应的账户已被停用")

    if SCOPE_STATS_READ not in record.scope_set:
        raise ApiError(
            ErrorCode.api_key_scope_denied,
            f"该 API 密钥缺少 {SCOPE_STATS_READ} 权限",
        )

    record.last_used_at = utcnow()
    db.commit()
    db.refresh(record)
    return record, user


__all__ = [
    "NAME_MAX_LENGTH",
    "NAME_MIN_LENGTH",
    "authenticate",
    "create_key",
    "find_by_plaintext",
    "generate_key",
    "key_prefix_of",
    "list_keys",
    "normalize_scopes",
    "revoke_key",
]

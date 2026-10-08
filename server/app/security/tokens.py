"""令牌签发与校验。

两类令牌，职责完全不同：

===============  ==========================  ==========================================
                Access Token                Refresh Token
===============  ==========================  ==========================================
形态            JWT（HS256，自包含）        不透明随机串（``secrets.token_urlsafe``）
有效期          15 分钟（可配）              30 天（可配）
服务端存储      不存                        只存 SHA-256 哈希
轮换            不需要                      每次刷新都换新，旧的立刻失效
===============  ==========================  ==========================================

为什么 Refresh Token 用不透明随机串而不是 JWT：
JWT 自包含、无法"真正吊销"，而需求要求注销 / 改密 / 撤销设备后旧 Refresh Token **立即失效**，
因此必须让服务端持有权威状态。用随机串 + 哈希存库是最直接可靠的实现。
"""

from __future__ import annotations

import hashlib
import secrets
import uuid
from dataclasses import dataclass
from datetime import timedelta
from typing import Any

import jwt

from ..core.errors import ApiError, ErrorCode
from ..core.timeutil import utcnow

TOKEN_TYPE_ACCESS = "access"
TOKEN_TYPE_REFRESH = "refresh"

#: Refresh Token 的随机字节数（token_urlsafe(48) ≈ 64 字符）
REFRESH_TOKEN_BYTES = 48

#: 用于密码重置等场景的最小长度（当前阶段未使用，保留常量便于统一） 
MIN_SECRET_LENGTH = 16


@dataclass(frozen=True)
class IssuedAccessToken:
    token: str
    expires_at: Any  # datetime


@dataclass(frozen=True)
class IssuedRefreshToken:
    #: 明文，只在响应的这一次出现，服务端不留存
    token: str
    token_hash: str
    expires_at: Any  # datetime


def hash_token(raw_token: str) -> str:
    """Refresh Token 的存储形态：SHA-256 十六进制。

    这里用 SHA-256 而不是 Argon2：Refresh Token 本身是 48 字节的高熵随机值，
    不存在被暴力猜解的风险，而刷新是高频操作，需要 O(1) 校验。
    """
    return hashlib.sha256(raw_token.encode("utf-8")).hexdigest()


def create_access_token(
    *,
    user_id: uuid.UUID,
    secret: str,
    algorithm: str = "HS256",
    ttl_minutes: int = 15,
    issuer: str = "petlife",
    device_id: uuid.UUID | None = None,
) -> IssuedAccessToken:
    """签发 Access Token（JWT）。"""
    now = utcnow()
    expires_at = now + timedelta(minutes=ttl_minutes)
    payload: dict[str, Any] = {
        "sub": str(user_id),
        "typ": TOKEN_TYPE_ACCESS,
        "iat": int(now.timestamp()),
        "exp": int(expires_at.timestamp()),
        "iss": issuer,
        "jti": uuid.uuid4().hex,
    }
    if device_id is not None:
        payload["dev"] = str(device_id)
    token = jwt.encode(payload, secret, algorithm=algorithm)
    return IssuedAccessToken(token=token, expires_at=expires_at)


def create_refresh_token(*, ttl_days: int = 30) -> IssuedRefreshToken:
    """生成不透明 Refresh Token 及其哈希。"""
    raw = secrets.token_urlsafe(REFRESH_TOKEN_BYTES)
    return IssuedRefreshToken(
        token=raw,
        token_hash=hash_token(raw),
        expires_at=utcnow() + timedelta(days=ttl_days),
    )


def decode_access_token(
    token: str,
    *,
    secret: str,
    algorithm: str = "HS256",
    issuer: str = "petlife",
) -> dict[str, Any]:
    """解析并校验 Access Token；失败时抛统一的 :class:`ApiError`。

    ``expired`` 与"签名/结构错误"返回不同错误码：客户端据此决定
    「静默刷新」还是「重新登录」。
    """
    try:
        payload = jwt.decode(
            token,
            secret,
            algorithms=[algorithm],
            issuer=issuer,
            options={"require": ["exp", "sub", "iss"]},
        )
    except jwt.ExpiredSignatureError as exc:
        raise ApiError(ErrorCode.token_expired, "Access Token 已过期") from exc
    except jwt.InvalidTokenError as exc:
        raise ApiError(ErrorCode.token_invalid, "Access Token 无效") from exc

    if payload.get("typ") != TOKEN_TYPE_ACCESS:
        # 防止把 Refresh Token 当 Access Token 使用
        raise ApiError(ErrorCode.token_invalid, "令牌类型不正确")
    return payload

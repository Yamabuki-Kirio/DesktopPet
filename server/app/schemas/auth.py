"""认证与账户 schema。"""

from __future__ import annotations

import uuid
from datetime import datetime

from pydantic import EmailStr, Field, field_validator

from .common import FlexibleDatetime, StrictModel, to_iso
from .device import DeviceRegisterRequest

#: 密码长度下限。上限用于挡住超长输入造成的哈希开销放大（DoS）。
PASSWORD_MIN = 8
PASSWORD_MAX = 128


class RegisterRequest(StrictModel):
    email: EmailStr
    password: str = Field(min_length=PASSWORD_MIN, max_length=PASSWORD_MAX)
    display_name: str = Field(min_length=1, max_length=64)

    #: 可选：客户端知道自己的设备标识时一并上报，令牌会直接绑定到该设备。
    #:
    #: 绑定设备的价值：撤销设备时能**立刻让这台机器的 Refresh Token 失效**；
    #: 若客户端选择"先登录、再单独注册设备"，则登录时签发的令牌不带设备绑定，
    #: 撤销设备后仍要靠 ``X-Device-Id`` 校验来拦住同步（两条防线都在）。
    device: DeviceRegisterRequest | None = None

    @field_validator("password")
    @classmethod
    def _password_not_blank(cls, value: str) -> str:
        if not value.strip():
            raise ValueError("密码不能为空")
        return value


class LoginRequest(StrictModel):
    email: EmailStr
    password: str = Field(min_length=1, max_length=PASSWORD_MAX)
    #: 见 RegisterRequest.device 的说明
    device: DeviceRegisterRequest | None = None


class RefreshRequest(StrictModel):
    refresh_token: str = Field(min_length=16, max_length=512)
    #: 可选：刷新时顺带刷新设备信息
    device_local_id: str | None = Field(default=None, max_length=64)


class LogoutRequest(StrictModel):
    """注销当前会话。

    ``refresh_token`` 可省略：省略时按设备维度注销（需要 ``X-Device-Id`` 头），
    提供时只注销这一条令牌链。
    """

    refresh_token: str | None = Field(default=None, max_length=512)


class TokenPair(StrictModel):
    access_token: str
    token_type: str = "bearer"
    #: Access Token 剩余有效秒数，客户端据此提前刷新
    expires_in: int
    refresh_token: str
    refresh_expires_at: datetime

    def model_dump_api(self) -> dict[str, object]:
        return {
            "access_token": self.access_token,
            "token_type": self.token_type,
            "expires_in": self.expires_in,
            "refresh_token": self.refresh_token,
            "refresh_expires_at": to_iso(self.refresh_expires_at),
        }


class UserOut(StrictModel):
    id: uuid.UUID
    email: str
    display_name: str
    status: str
    created_at: datetime
    updated_at: datetime

    @classmethod
    def from_model(cls, user) -> "UserOut":
        return cls(
            id=user.id,
            email=user.email,
            display_name=user.display_name,
            status=user.status,
            created_at=user.created_at,
            updated_at=user.updated_at,
        )


class UpdateMeRequest(StrictModel):
    display_name: str = Field(min_length=1, max_length=64)


class UpdatePasswordRequest(StrictModel):
    current_password: str = Field(min_length=1, max_length=PASSWORD_MAX)
    new_password: str = Field(min_length=PASSWORD_MIN, max_length=PASSWORD_MAX)


class LoginResponse(TokenPair):
    """登录 / 注册成功后的响应：令牌 + 账户信息。"""

    user: UserOut
    device_id: uuid.UUID | None = None


class MessageOut(StrictModel):
    message: str
    revoked_sessions: int = 0


__all__ = [
    "LoginRequest",
    "LoginResponse",
    "LogoutRequest",
    "MessageOut",
    "PASSWORD_MAX",
    "PASSWORD_MIN",
    "RefreshRequest",
    "RegisterRequest",
    "TokenPair",
    "UpdateMeRequest",
    "UpdatePasswordRequest",
    "UserOut",
    "FlexibleDatetime",
]

"""认证与账户接口。

路径严格按需求「六、同步协议」的接口清单：

```
POST   /api/v1/auth/register
POST   /api/v1/auth/login
POST   /api/v1/auth/refresh
POST   /api/v1/auth/logout
POST   /api/v1/auth/logout-all
GET    /api/v1/me
PATCH  /api/v1/me
DELETE /api/v1/me
```

补充一个 ``POST /api/v1/me/password``（修改密码，需求正文要求但没有列出路径）。
"""

from __future__ import annotations

import uuid
from typing import Annotated

from fastapi import APIRouter, Depends, Header, status
from sqlalchemy.orm import Session

from ...core.config import Settings, get_settings
from ...core.logger import get_logger
from ...database.session import get_db
from ...schemas.auth import (
    LoginRequest,
    LogoutRequest,
    MessageOut,
    RefreshRequest,
    RegisterRequest,
    UpdatePasswordRequest,
    UpdateMeRequest,
    UserOut,
)
from ...security.deps import DEVICE_ID_HEADER, CurrentUser
from ...services import auth_service, device_service

router = APIRouter(tags=["auth"])
logger = get_logger(__name__)


def _token_payload(bundle: auth_service.TokenBundle, user, device_id: uuid.UUID | None):
    """统一构造令牌响应（时间一律 ISO 8601 UTC）。"""
    return {
        "access_token": bundle.access_token,
        "token_type": "bearer",
        "expires_in": int(
            (bundle.access_expires_at - auth_service.utcnow()).total_seconds()
        ),
        "refresh_token": bundle.refresh_token,
        "refresh_expires_at": bundle.refresh_expires_at.isoformat().replace("+00:00", "Z"),
        "user": UserOut.from_model(user).model_dump(),
        "device_id": device_id,
    }


def _bind_device_if_requested(db: Session, *, user, payload):
    """客户端在登录/注册时上报了设备信息 → 顺带绑定，并让令牌与之关联。

    这样"撤销设备"能立刻让这台机器的 Refresh Token 失效，
    而不是只靠 ``X-Device-Id`` 拦截同步。
    """
    if payload.device is None:
        return None
    return device_service.register_or_update(
        db,
        user=user,
        device_local_id=payload.device.device_local_id,
        device_name=payload.device.device_name,
        platform=payload.device.platform,
        architecture=payload.device.architecture,
        os_version=payload.device.os_version,
        app_version=payload.device.app_version,
        model_name=payload.device.model_name,
    )


@router.post("/auth/register", status_code=status.HTTP_201_CREATED)
async def register(
    payload: RegisterRequest,
    db: Annotated[Session, Depends(get_db)],
    settings: Annotated[Settings, Depends(get_settings)],
):
    """注册账户。

    注册成功即返回一对令牌（等价于自动登录），客户端也可以忽略它们再显式登录。
    """
    user = auth_service.register(
        db,
        email=payload.email,
        password=payload.password,
        display_name=payload.display_name,
    )
    device = _bind_device_if_requested(db, user=user, payload=payload)
    bundle = auth_service.create_session(db, user=user, settings=settings, device=device)
    logger.info("新账户注册 user_id=%s", user.id)
    return _token_payload(bundle, user, device.id if device else None)


@router.post("/auth/login")
async def login(
    payload: LoginRequest,
    db: Annotated[Session, Depends(get_db)],
    settings: Annotated[Settings, Depends(get_settings)],
):
    """登录。邮箱不存在与密码错误返回同一个错误码，不泄露邮箱是否已注册。"""
    user = auth_service.authenticate(db, email=payload.email, password=payload.password)
    device = _bind_device_if_requested(db, user=user, payload=payload)
    bundle = auth_service.create_session(db, user=user, settings=settings, device=device)
    logger.info("登录成功 user_id=%s", user.id)
    return _token_payload(bundle, user, device.id if device else None)


@router.post("/auth/refresh")
async def refresh(
    payload: RefreshRequest,
    db: Annotated[Session, Depends(get_db)],
    settings: Annotated[Settings, Depends(get_settings)],
):
    """刷新 Access Token（Refresh Token 轮换）。

    旧 Refresh Token 立即失效并记录轮换链；若已被轮换过的旧 token 再次出现，
    判定为泄露并注销该用户全部会话。

    若原令牌未绑定设备，可携带 ``device_local_id`` 在这里补绑定
    （客户端"先登录后注册设备"的流程会走到这条分支）。
    """
    user, bundle, device = auth_service.refresh_session(
        db,
        raw_refresh_token=payload.refresh_token,
        settings=settings,
        device_local_id=payload.device_local_id,
    )
    return _token_payload(bundle, user, device.id if device else None)


@router.post("/auth/logout")
async def logout(
    payload: LogoutRequest,
    db: Annotated[Session, Depends(get_db)],
    device_id: Annotated[str | None, Header(alias=DEVICE_ID_HEADER)] = None,
):
    """注销当前会话。

    * 提供 ``refresh_token`` → 精确注销这条令牌链；
    * 只提供 ``X-Device-Id`` → 注销该设备的全部令牌。
    """
    if payload.refresh_token:
        revoked = auth_service.revoke_by_token(db, raw_refresh_token=payload.refresh_token)
        return MessageOut(message="当前会话已注销", revoked_sessions=revoked)

    if device_id:
        try:
            parsed = uuid.UUID(device_id)
        except (ValueError, TypeError):
            parsed = None
        if parsed is not None:
            revoked = auth_service.revoke_device_tokens(db, device_id=parsed)
            return MessageOut(message="该设备的会话已注销", revoked_sessions=revoked)

    return MessageOut(message="未提供 refresh_token 或设备标识，未注销任何会话", revoked_sessions=0)


@router.post("/auth/logout-all")
async def logout_all(
    user: CurrentUser,
    db: Annotated[Session, Depends(get_db)],
):
    """注销该账户的全部会话（含当前）。"""
    revoked = auth_service.revoke_all_sessions(db, user_id=user.id)
    logger.info("注销全部会话 user_id=%s revoked=%s", user.id, revoked)
    return MessageOut(message="已注销全部会话", revoked_sessions=revoked)


@router.get("/me")
async def read_me(user: CurrentUser):
    """当前账户信息。"""
    return UserOut.from_model(user).model_dump()


@router.patch("/me")
async def update_me(
    payload: UpdateMeRequest,
    user: CurrentUser,
    db: Annotated[Session, Depends(get_db)],
):
    """修改显示名称。"""
    updated = auth_service.update_display_name(
        db, user=user, display_name=payload.display_name
    )
    return UserOut.from_model(updated).model_dump()


@router.post("/me/password")
async def change_password(
    payload: UpdatePasswordRequest,
    user: CurrentUser,
    db: Annotated[Session, Depends(get_db)],
):
    """修改密码；成功后该账户的全部 Refresh Token 立即失效。"""
    revoked = auth_service.change_password(
        db,
        user=user,
        current_password=payload.current_password,
        new_password=payload.new_password,
    )
    logger.info("密码已修改 user_id=%s revoked_sessions=%s", user.id, revoked)
    return MessageOut(
        message="密码已修改，请在所有设备上重新登录", revoked_sessions=revoked
    )


@router.delete("/me")
async def delete_me(
    payload: UpdatePasswordRequest,
    user: CurrentUser,
    db: Annotated[Session, Depends(get_db)],
):
    """删除账户（需要当前密码确认）。

    删除后：账户不可登录、全部 token 失效、设备与同步数据被清除。
    """
    auth_service.delete_account(
        db, user=user, current_password=payload.current_password
    )
    logger.info("账户已删除 user_id=%s", user.id)
    return MessageOut(message="账户已删除，本地使用记录不受影响")

"""设备接口。

```
POST   /api/v1/devices/register
GET    /api/v1/devices
PATCH  /api/v1/devices/{device_id}
DELETE /api/v1/devices/{device_id}
```

隐私：只接受客户端自报的设备元数据，服务端**不采集任何硬件指纹**。
"""

from __future__ import annotations

import uuid
from typing import Annotated

from fastapi import APIRouter, Depends, Header, status
from sqlalchemy.orm import Session

from ...core.logger import get_logger
from ...database.session import get_db
from ...schemas.auth import MessageOut
from ...schemas.device import DeviceOut, DeviceRegisterRequest, DeviceUpdateRequest, device_to_out
from ...security.deps import DEVICE_ID_HEADER, CurrentUser, CurrentUserOrWeb
from ...services import device_service

router = APIRouter(tags=["devices"])
logger = get_logger(__name__)


def _current_device_id(raw: str | None) -> uuid.UUID | None:
    if not raw:
        return None
    try:
        return uuid.UUID(raw)
    except (ValueError, TypeError):
        return None


@router.post("/devices/register", status_code=status.HTTP_201_CREATED)
async def register_device(
    payload: DeviceRegisterRequest,
    user: CurrentUser,
    db: Annotated[Session, Depends(get_db)],
):
    """登录后注册或更新设备（幂等：同一 device_local_id 只会有一条记录）。"""
    device = device_service.register_or_update(
        db,
        user=user,
        device_local_id=payload.device_local_id,
        device_name=payload.device_name,
        platform=payload.platform,
        architecture=payload.architecture,
        os_version=payload.os_version,
        app_version=payload.app_version,
        model_name=payload.model_name,
    )
    return device_to_out(device, current_device_id=device.id)


@router.get("/devices")
async def list_devices(
    user: CurrentUserOrWeb,
    db: Annotated[Session, Depends(get_db)],
    device_id: Annotated[str | None, Header(alias=DEVICE_ID_HEADER)] = None,
):
    """列出当前账户的全部设备（含已撤销）。

    身份可来自 Bearer 或网页会话 Cookie —— GameLog「生活足迹」的设备筛选
    需要它，而网页没有 Authorization 头（docs/43 第四节）。
    """
    current = _current_device_id(device_id)
    devices = device_service.list_devices(db, user=user)
    return [device_to_out(d, current_device_id=current) for d in devices]


@router.patch("/devices/{device_uuid}")
async def update_device(
    device_uuid: uuid.UUID,
    payload: DeviceUpdateRequest,
    user: CurrentUser,
    db: Annotated[Session, Depends(get_db)],
):
    """修改设备名称 / 型号备注。"""
    device = device_service.update_device(
        db,
        user=user,
        device_id=device_uuid,
        device_name=payload.device_name,
        model_name=payload.model_name,
    )
    return device_to_out(device)


@router.delete("/devices/{device_uuid}")
async def revoke_device(
    device_uuid: uuid.UUID,
    user: CurrentUser,
    db: Annotated[Session, Depends(get_db)],
):
    """撤销设备。

    撤销后：该设备的 Refresh Token 全部失效、Access Token 立即被拒、后续同步返回
    ``device_revoked``；同时释放 ``device_local_id``，便于将来重新绑定同一台机器。
    """
    device, revoked = device_service.revoke_device(db, user=user, device_id=device_uuid)
    return {
        **device_to_out(device).model_dump(mode="json"),
        "revoked_sessions": revoked,
        "message": "设备已撤销，其上的登录已失效",
    }


@router.get("/devices/{device_uuid}", response_model=DeviceOut)
async def get_device(
    device_uuid: uuid.UUID,
    user: CurrentUser,
    db: Annotated[Session, Depends(get_db)],
):
    device = device_service.get_owned_device(db, user=user, device_id=device_uuid)
    return device_to_out(device)


__all__ = ["MessageOut", "router"]

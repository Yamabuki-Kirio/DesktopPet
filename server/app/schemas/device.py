"""设备 schema。"""

from __future__ import annotations

import uuid
from datetime import datetime

from pydantic import Field, field_validator

from .common import StrictModel, to_iso

#: 允许上报的平台标识。
#:
#: Phase 4A 起 Windows 与 Android 是**两台不同的设备**（同一个账户可以有多个），
#: 因此这里必须同时接受两者；macos / linux 保留给后续可能的桌面端。
PLATFORM_CHOICES = ("windows", "android", "macos", "linux")

#: 允许上报的架构标识。
#:
#: 桌面用 `x64` / `arm64` / `x86`；Android 客户端上报的是 **ABI 名**
#: （与 Gradle 产物一致）：`arm64-v8a` / `armeabi-v7a` / `x86_64`。
#: 两种命名都保留：不接受 Android ABI 会让 Android 注册设备直接 422。
ARCHITECTURE_CHOICES = (
    "x64",
    "arm64",
    "x86",
    # Android ABI
    "arm64-v8a",
    "armeabi-v7a",
    "x86_64",
)


class DeviceRegisterRequest(StrictModel):
    """登录后注册或更新设备。

    ``device_local_id`` 是客户端本地生成的稳定 UUID，**服务端不做任何硬件指纹采集**。
    """

    device_local_id: str = Field(min_length=8, max_length=64)
    device_name: str = Field(min_length=1, max_length=128)
    platform: str = Field(default="windows", max_length=32)
    architecture: str = Field(default="x64", max_length=32)
    os_version: str | None = Field(default=None, max_length=128)
    app_version: str | None = Field(default=None, max_length=32)
    model_name: str | None = Field(default=None, max_length=128)

    @field_validator("platform")
    @classmethod
    def _check_platform(cls, value: str) -> str:
        normalized = value.strip().lower()
        if normalized not in PLATFORM_CHOICES:
            raise ValueError(f"platform 必须是 {PLATFORM_CHOICES} 之一")
        return normalized

    @field_validator("architecture")
    @classmethod
    def _check_architecture(cls, value: str) -> str:
        normalized = value.strip().lower()
        if normalized not in ARCHITECTURE_CHOICES:
            raise ValueError(f"architecture 必须是 {ARCHITECTURE_CHOICES} 之一")
        return normalized


class DeviceUpdateRequest(StrictModel):
    """用户可修改的只有名称与型号备注。"""

    device_name: str | None = Field(default=None, min_length=1, max_length=128)
    model_name: str | None = Field(default=None, max_length=128)


class DeviceOut(StrictModel):
    id: uuid.UUID
    device_local_id: str
    device_name: str
    platform: str
    architecture: str
    os_version: str | None
    app_version: str | None
    model_name: str | None
    last_seen_at: str
    created_at: str
    revoked_at: str | None
    is_current: bool = False


def device_to_out(device, *, current_device_id: uuid.UUID | None = None) -> DeviceOut:
    return DeviceOut(
        id=device.id,
        device_local_id=device.device_local_id,
        device_name=device.device_name,
        platform=device.platform,
        architecture=device.architecture,
        os_version=device.os_version,
        app_version=device.app_version,
        model_name=device.model_name,
        last_seen_at=to_iso(device.last_seen_at) or "",
        created_at=to_iso(device.created_at) or "",
        revoked_at=to_iso(device.revoked_at),
        is_current=current_device_id is not None and device.id == current_device_id,
    )


__all__ = [
    "ARCHITECTURE_CHOICES",
    "DeviceOut",
    "DeviceRegisterRequest",
    "DeviceUpdateRequest",
    "PLATFORM_CHOICES",
    "device_to_out",
    "datetime",
]

"""设备模型。

隐私约定：**不采集硬件序列号、MAC 地址或其他难以撤销的硬件指纹**。
``device_local_id`` 由客户端本地生成的 UUID，用户随时可以撤销设备并让它失效。
"""

from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import ForeignKey, Index, String, UniqueConstraint, Uuid
from sqlalchemy.orm import Mapped, mapped_column

from ..core.types import UTCDateTime
from ..core.timeutil import utcnow
from ..database.base import Base

PLATFORM_WINDOWS = "windows"

#: Phase 4A：Android 客户端与 Windows 客户端是**两台不同的设备**
#: （同一账户可同时拥有两者），但它们共用同一套同步协议与统计口径。
PLATFORM_ANDROID = "android"


class Device(Base):
    __tablename__ = "devices"
    __table_args__ = (
        # 同一用户下 device_local_id 唯一（需求「三、设备系统」）
        UniqueConstraint(
            "user_id", "device_local_id", name="uq_devices_user_id_device_local_id"
        ),
        Index("ix_devices_user_id_revoked_at", "user_id", "revoked_at"),
    )

    id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True, default=uuid.uuid4)

    user_id: Mapped[uuid.UUID] = mapped_column(
        Uuid, ForeignKey("users.id", ondelete="CASCADE"), nullable=False
    )

    #: 客户端安装实例的稳定标识（本地 UUID，重启不变）
    device_local_id: Mapped[str] = mapped_column(String(64), nullable=False)

    device_name: Mapped[str] = mapped_column(String(128), nullable=False)

    platform: Mapped[str] = mapped_column(
        String(32), nullable=False, default=PLATFORM_WINDOWS
    )
    architecture: Mapped[str] = mapped_column(String(32), nullable=False, default="x64")
    os_version: Mapped[str | None] = mapped_column(String(128), nullable=True)
    app_version: Mapped[str | None] = mapped_column(String(32), nullable=True)

    #: 用户可填写的设备型号或备注
    model_name: Mapped[str | None] = mapped_column(String(128), nullable=True)

    last_seen_at: Mapped[datetime] = mapped_column(
        UTCDateTime, nullable=False, default=utcnow
    )
    created_at: Mapped[datetime] = mapped_column(
        UTCDateTime, nullable=False, default=utcnow
    )
    revoked_at: Mapped[datetime | None] = mapped_column(UTCDateTime, nullable=True)

    @property
    def is_revoked(self) -> bool:
        return self.revoked_at is not None

    def __repr__(self) -> str:  # pragma: no cover
        return f"<Device {self.device_name} local={self.device_local_id}>"

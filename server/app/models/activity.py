"""同步数据模型（活动段 / 每日用量 / 应用库 / 变更日志）。

三条硬约束：

1. **隐私**：这里不存在窗口标题、URL、文档名、本地完整路径等字段——
   不是"不填"，而是**表结构里根本没有这些列**，从物理上杜绝误存。
2. **隔离**：所有表都以 ``user_id`` 作为主键的一部分（或第一列索引），
   因此不同用户的数据在结构层面就不可能互相覆盖。
3. **幂等**：客户端上传的记录 ID 是稳定 UUID，`(user_id, <record id>)` 是主键，
   重复上传同一 UUID 只会覆盖同一行，不会产生重复数据。

游标机制：每张可同步表都有 ``change_seq``，其值取自 :class:`SyncLog` 的自增序号。
`/sync/pull?cursor=N` 即 ``change_seq > N``，因此游标是**单调递增**的。
"""

from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import (
    BigInteger,
    Boolean,
    ForeignKey,
    Index,
    Integer,
    String,
    Uuid,
)
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column
from sqlalchemy.types import JSON

from ..core.types import UTCDateTime
from ..core.timeutil import utcnow
from ..database.base import Base

#: SQLite 没有 BIGSERIAL；用 INTEGER 变体让自增在主键上生效
#: （SQLite 只把 ``INTEGER PRIMARY KEY`` 当作 rowid 别名）。
AutoIncrementBigInt = BigInteger().with_variant(Integer, "sqlite")

#: PostgreSQL 用 JSONB（可索引、更省空间），其他后端退化为 JSON。
PortableJSON = JSON().with_variant(JSONB, "postgresql")

#: 可同步实体类型
ENTITY_ACTIVITY_SEGMENT = "activity_segment"
ENTITY_DAILY_USAGE = "daily_usage"
ENTITY_APPLICATION = "application"
ENTITY_TYPES = (
    ENTITY_ACTIVITY_SEGMENT,
    ENTITY_DAILY_USAGE,
    ENTITY_APPLICATION,
)


class ActivitySegment(Base):
    """一段应用使用记录。

    ``(user_id, id)`` 为复合主键：``id`` 是客户端生成的稳定 UUID。
    复合主键让"用户 A 无法通过重放 id 覆盖用户 B 的记录"成为**结构保证**。
    """

    __tablename__ = "activity_segments"
    __table_args__ = (
        Index("ix_activity_segments_user_started", "user_id", "started_at"),
        Index("ix_activity_segments_user_device", "user_id", "device_id"),
        Index("ix_activity_segments_user_change_seq", "user_id", "change_seq"),
        Index("ix_activity_segments_user_app_key", "user_id", "app_key"),
        # Phase 4B：云端统计按「设备 + 日期」与「设备 + 应用 + 日期」查询逐条会话，
        # 这两条组合索引让统计接口不必回表扫描（见 docs/34）。
        Index(
            "ix_activity_segments_user_device_started",
            "user_id",
            "device_id",
            "started_at",
        ),
        Index(
            "ix_activity_segments_user_device_app_started",
            "user_id",
            "device_id",
            "app_key",
            "started_at",
        ),
    )

    user_id: Mapped[uuid.UUID] = mapped_column(
        Uuid, ForeignKey("users.id", ondelete="CASCADE"), primary_key=True
    )
    id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True)

    device_id: Mapped[uuid.UUID] = mapped_column(
        Uuid, ForeignKey("devices.id", ondelete="CASCADE"), nullable=False
    )

    #: 规范化后的可执行文件名（如 code），**不含完整路径**
    app_key: Mapped[str] = mapped_column(String(128), nullable=False)
    category: Mapped[str] = mapped_column(String(32), nullable=False, default="other")

    started_at: Mapped[datetime] = mapped_column(UTCDateTime, nullable=False)
    ended_at: Mapped[datetime | None] = mapped_column(UTCDateTime, nullable=True)
    active_seconds: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    end_reason: Mapped[str | None] = mapped_column(String(32), nullable=True)

    #: 客户端侧时间戳；``updated_at`` 是冲突裁决依据（较新者胜）
    created_at: Mapped[datetime] = mapped_column(UTCDateTime, nullable=False)
    updated_at: Mapped[datetime] = mapped_column(UTCDateTime, nullable=False)

    #: 服务端接收时刻（诊断用，不参与冲突裁决）
    server_received_at: Mapped[datetime] = mapped_column(
        UTCDateTime, nullable=False, default=utcnow
    )

    #: 变更序号，供增量拉取
    change_seq: Mapped[int | None] = mapped_column(AutoIncrementBigInt, nullable=True)


class DailyUsage(Base):
    """设备级每日用量。

    ``(user_id, device_id, local_day)`` 为复合主键。
    同步语义是**整行快照覆盖**而不是秒数累加：客户端重传同一份快照不会把时间叠加，
    因此"重试导致重复累计"从模型上就不可能发生。
    """

    __tablename__ = "daily_usage"
    __table_args__ = (
        Index("ix_daily_usage_user_local_day", "user_id", "local_day"),
        Index("ix_daily_usage_user_change_seq", "user_id", "change_seq"),
    )

    user_id: Mapped[uuid.UUID] = mapped_column(
        Uuid, ForeignKey("users.id", ondelete="CASCADE"), primary_key=True
    )
    device_id: Mapped[uuid.UUID] = mapped_column(
        Uuid, ForeignKey("devices.id", ondelete="CASCADE"), primary_key=True
    )
    #: 客户端本地日期 YYYY-MM-DD
    local_day: Mapped[str] = mapped_column(String(10), primary_key=True)

    #: 客户端当时相对 UTC 的偏移（分钟），用于"今天"的时区归属
    timezone_offset_minutes: Mapped[int] = mapped_column(Integer, nullable=False, default=0)

    session_seconds: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    active_seconds: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    idle_seconds: Mapped[int] = mapped_column(Integer, nullable=False, default=0)

    first_active_at: Mapped[datetime | None] = mapped_column(UTCDateTime, nullable=True)
    last_active_at: Mapped[datetime | None] = mapped_column(UTCDateTime, nullable=True)

    updated_at: Mapped[datetime] = mapped_column(UTCDateTime, nullable=False)
    server_received_at: Mapped[datetime] = mapped_column(
        UTCDateTime, nullable=False, default=utcnow
    )
    change_seq: Mapped[int | None] = mapped_column(AutoIncrementBigInt, nullable=True)


class UserApplication(Base):
    """用户维度的应用库（只存可公开的安全字段）。

    **只有这四个数据字段**：app_key、display_name、category、user_overridden。
    没有可执行文件路径、没有窗口标题、没有进程名以外的东西。
    """

    __tablename__ = "user_applications"
    __table_args__ = (
        Index("ix_user_applications_user_change_seq", "user_id", "change_seq"),
    )

    user_id: Mapped[uuid.UUID] = mapped_column(
        Uuid, ForeignKey("users.id", ondelete="CASCADE"), primary_key=True
    )
    app_key: Mapped[str] = mapped_column(String(128), primary_key=True)

    display_name: Mapped[str] = mapped_column(String(128), nullable=False)
    category: Mapped[str] = mapped_column(String(32), nullable=False, default="other")

    #: 用户手工分类（优先于内置分类，见 sync_service 的冲突策略）
    user_overridden: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)

    updated_at: Mapped[datetime] = mapped_column(UTCDateTime, nullable=False)
    server_received_at: Mapped[datetime] = mapped_column(
        UTCDateTime, nullable=False, default=utcnow
    )
    change_seq: Mapped[int | None] = mapped_column(AutoIncrementBigInt, nullable=True)


class SyncLog(Base):
    """变更日志：为增量拉取提供**单调递增**的游标。

    单表自增主键在 SQLite 与 PostgreSQL 上都是严格递增的
    （PG 的序列在回滚时可能留下空洞，但单调性不受影响），
    因此可以直接当游标使用。
    """

    __tablename__ = "sync_log"
    __table_args__ = (
        Index("ix_sync_log_user_seq", "user_id", "seq"),
        Index("ix_sync_log_user_entity", "user_id", "entity_type"),
    )

    seq: Mapped[int] = mapped_column(
        AutoIncrementBigInt, primary_key=True, autoincrement=True
    )
    user_id: Mapped[uuid.UUID] = mapped_column(
        Uuid, ForeignKey("users.id", ondelete="CASCADE"), nullable=False
    )
    entity_type: Mapped[str] = mapped_column(String(32), nullable=False)

    #: 记录的业务键：活动段为记录 UUID，每日用量为 "device_id:local_day"，应用为 app_key
    record_key: Mapped[str] = mapped_column(String(256), nullable=False)

    #: 目前只有 upsert；保留 delete 以便后续支持客户端删除
    op: Mapped[str] = mapped_column(String(8), nullable=False, default="upsert")

    changed_at: Mapped[datetime] = mapped_column(
        UTCDateTime, nullable=False, default=utcnow
    )

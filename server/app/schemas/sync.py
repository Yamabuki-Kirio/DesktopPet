"""同步 schema（push / pull）。

隐私说明：这些模型里**不存在**窗口标题、URL、文档名、本地完整路径、截图等字段。
不是"客户端别传"，而是"服务端连字段都没有"，传了会被 :class:`StrictModel`
的 ``extra="forbid"`` 直接判为 422。
"""

from __future__ import annotations

import re
import uuid
from datetime import datetime

from pydantic import Field, field_validator

from .common import FlexibleDatetime, StrictModel

APP_CATEGORIES = (
    "development",
    "productivity",
    "gaming",
    "social",
    "entertainment",
    "browser",
    "system",
    "other",
)

APP_KEY_MAX = 128
_LOCAL_DAY_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
#: UTC 偏移的范围（分钟）：UTC-12:00 ~ UTC+14:00
_TZ_OFFSET_MIN = -12 * 60
_TZ_OFFSET_MAX = 14 * 60


def _validate_category(value: str) -> str:
    normalized = value.strip().lower()
    if normalized not in APP_CATEGORIES:
        raise ValueError(f"category 必须是 {APP_CATEGORIES} 之一")
    return normalized


def _validate_local_day(value: str) -> str:
    if not _LOCAL_DAY_RE.match(value):
        raise ValueError("local_day 必须是 YYYY-MM-DD")
    # 顺手校验真实性（2 月 30 日这类会被拒）
    try:
        datetime.strptime(value, "%Y-%m-%d")
    except ValueError as exc:
        raise ValueError("local_day 不是合法日期") from exc
    return value


class ActivitySegmentIn(StrictModel):
    """活动段上传体。

    字段与需求「六、同步协议」一致：``id / device_id / app_key / category /
    started_at / ended_at / active_seconds / created_at / updated_at``。
    ``end_reason`` 是可选的诊断字段（枚举值有限，不含隐私内容）。
    """

    id: uuid.UUID
    device_id: uuid.UUID
    app_key: str = Field(min_length=1, max_length=APP_KEY_MAX)
    category: str = Field(default="other", max_length=32)
    started_at: FlexibleDatetime
    ended_at: FlexibleDatetime | None = None
    active_seconds: int = Field(default=0, ge=0, le=86400 * 2)
    end_reason: str | None = Field(default=None, max_length=32)
    created_at: FlexibleDatetime
    updated_at: FlexibleDatetime

    @field_validator("category")
    @classmethod
    def _check_category(cls, value: str) -> str:
        return _validate_category(value)

    @field_validator("app_key")
    @classmethod
    def _check_app_key(cls, value: str) -> str:
        """``app_key`` 不得包含路径分隔符。

        需求要求「如果现有 app_key 含完整路径，应先在客户端规范化或哈希，
        不能直接上传完整路径」。服务端再做一道**拒绝式**校验，
        防止本地路径因为客户端 bug 而泄露上来。
        """
        cleaned = value.strip()
        if "\\" in cleaned or "/" in cleaned:
            raise ValueError("app_key 不得包含路径分隔符（请先在客户端规范化）")
        return cleaned


class DailyUsageIn(StrictModel):
    """每日用量快照。

    **整行快照**语义：服务端以 ``(device_id, local_day)`` 为唯一键覆盖写入，
    不做秒数累加，因此重传不会重复累计。
    """

    device_id: uuid.UUID
    local_day: str = Field(min_length=10, max_length=10)
    timezone_offset_minutes: int = Field(default=0)
    session_seconds: int = Field(default=0, ge=0, le=86400 * 2)
    active_seconds: int = Field(default=0, ge=0, le=86400 * 2)
    idle_seconds: int = Field(default=0, ge=0, le=86400 * 2)
    first_active_at: FlexibleDatetime | None = None
    last_active_at: FlexibleDatetime | None = None
    updated_at: FlexibleDatetime

    @field_validator("local_day")
    @classmethod
    def _check_day(cls, value: str) -> str:
        return _validate_local_day(value)

    @field_validator("timezone_offset_minutes")
    @classmethod
    def _check_offset(cls, value: int) -> int:
        if not (_TZ_OFFSET_MIN <= value <= _TZ_OFFSET_MAX):
            raise ValueError(
                f"timezone_offset_minutes 必须在 {_TZ_OFFSET_MIN} ~ {_TZ_OFFSET_MAX} 之间"
            )
        return value


class AppRecordIn(StrictModel):
    """应用库记录（只允许可公开的安全字段）。"""

    app_key: str = Field(min_length=1, max_length=APP_KEY_MAX)
    display_name: str = Field(min_length=1, max_length=128)
    category: str = Field(default="other", max_length=32)
    user_overridden: bool = False
    updated_at: FlexibleDatetime

    @field_validator("category")
    @classmethod
    def _check_category(cls, value: str) -> str:
        return _validate_category(value)

    @field_validator("app_key")
    @classmethod
    def _check_app_key(cls, value: str) -> str:
        cleaned = value.strip()
        if "\\" in cleaned or "/" in cleaned:
            raise ValueError("app_key 不得包含路径分隔符（请先在客户端规范化）")
        return cleaned


class PushRequest(StrictModel):
    """批量上传。

    单批总量由服务端 ``PETLIFE_SYNC_MAX_BATCH_SIZE`` 限制（默认 200）。
    ``batch_id`` 仅用于幂等审计与日志关联：**真正的幂等来自每条记录的主键**，
    因此重复提交同一个批次不会产生任何重复数据。
    """

    batch_id: uuid.UUID | None = None
    activity_segments: list[ActivitySegmentIn] = Field(default_factory=list)
    daily_usage: list[DailyUsageIn] = Field(default_factory=list)
    applications: list[AppRecordIn] = Field(default_factory=list)

    def total_records(self) -> int:
        return len(self.activity_segments) + len(self.daily_usage) + len(self.applications)


class RejectedRecord(StrictModel):
    """被拒绝的单条记录（不影响同批次里其他记录）。"""

    kind: str
    key: str
    code: str
    message: str


class PushResponse(StrictModel):
    batch_id: uuid.UUID | None = None
    accepted_activity_segments: int = 0
    accepted_daily_usage: int = 0
    accepted_applications: int = 0
    accepted_total: int = 0
    rejected: list[RejectedRecord] = Field(default_factory=list)
    server_time: str
    #: 本批写入后服务端的最大游标，客户端可直接用它作为下次 pull 的起点
    cursor: int = 0


class ActivitySegmentOut(StrictModel):
    id: uuid.UUID
    device_id: uuid.UUID
    app_key: str
    category: str
    started_at: str
    ended_at: str | None
    active_seconds: int
    end_reason: str | None
    created_at: str
    updated_at: str


class DailyUsageOut(StrictModel):
    device_id: uuid.UUID
    local_day: str
    timezone_offset_minutes: int
    session_seconds: int
    active_seconds: int
    idle_seconds: int
    first_active_at: str | None
    last_active_at: str | None
    updated_at: str


class AppRecordOut(StrictModel):
    app_key: str
    display_name: str
    category: str
    user_overridden: bool
    updated_at: str


class PullResponse(StrictModel):
    cursor: int
    has_more: bool
    activity_segments: list[ActivitySegmentOut] = Field(default_factory=list)
    daily_usage: list[DailyUsageOut] = Field(default_factory=list)
    applications: list[AppRecordOut] = Field(default_factory=list)
    server_time: str


__all__ = [
    "APP_CATEGORIES",
    "ActivitySegmentIn",
    "ActivitySegmentOut",
    "AppRecordIn",
    "AppRecordOut",
    "DailyUsageIn",
    "DailyUsageOut",
    "PullResponse",
    "PushRequest",
    "PushResponse",
    "RejectedRecord",
]

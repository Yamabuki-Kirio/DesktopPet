"""服务端统计 schema。

口径严格沿用 ``docs/12-使用统计口径.md``：

* **屏幕会话时间** = 解锁且未休眠（``daily_usage.session_seconds``）
* **活跃使用时间** = 屏幕会话中空闲未超阈（``daily_usage.active_seconds``）
* **空闲时间**     = 解锁但空闲超阈（``daily_usage.idle_seconds``）
* **应用使用时间** = 活跃时间中归属到有效前台应用的部分（``activity_segments``）

其中 ``应用使用时间 ≤ 活跃使用时间``。

多设备说明：不同设备的时间**可能重叠**（人在两台机器前），
因此"所有设备合计"是一个**求和**而不是去重结果，响应里用
``overlap_warning`` 明确提示，绝不偷偷去重。
"""

from __future__ import annotations

import uuid

from pydantic import Field

from .common import StrictModel

#: 支持的统计区间
PERIOD_TODAY = "today"
PERIOD_YESTERDAY = "yesterday"
PERIOD_7D = "7d"
PERIOD_30D = "30d"
PERIODS = (PERIOD_TODAY, PERIOD_YESTERDAY, PERIOD_7D, PERIOD_30D)

PERIOD_DAYS = {PERIOD_TODAY: 1, PERIOD_YESTERDAY: 1, PERIOD_7D: 7, PERIOD_30D: 30}

#: 相对「今天」的起始日偏移
PERIOD_DAY_OFFSET = {
    PERIOD_TODAY: 0,
    PERIOD_YESTERDAY: -1,
    PERIOD_7D: 0,
    PERIOD_30D: 0,
}

OVERLAP_WARNING = (
    "这是各设备使用时长的合计；同一账号在多台设备上并行使用时时间会重叠，"
    "该合计未做去重。"
)


class OverviewOut(StrictModel):
    period: str
    from_utc: str
    to_utc: str
    timezone_offset_minutes: int
    session_seconds: int = 0
    active_seconds: int = 0
    idle_seconds: int = 0
    app_active_seconds: int = 0
    first_active_at: str | None = None
    last_active_at: str | None = None
    device_count: int = 0
    total_active_seconds_across_devices: int = 0
    overlap_warning: str = OVERLAP_WARNING


class DeviceUsageOut(StrictModel):
    device_id: uuid.UUID
    device_name: str
    platform: str
    active_seconds: int = 0
    session_seconds: int = 0
    idle_seconds: int = 0
    last_seen_at: str | None = None
    revoked: bool = False


class AppUsageOut(StrictModel):
    #: **归一后的统一键**（Phase 2 起）。旧字段名保持不变以兼容既有调用方，
    #: 但值不再一定是原始 app_key —— 多个子进程会合并到同一个键上。
    app_key: str
    display_name: str
    category: str
    active_seconds: int = 0
    segment_count: int = 0
    #: 占「应用使用时间」的比例（0~1）
    ratio_of_app_time: float = 0.0
    #: 合并进来的原始进程名（可追溯，如
    #: ``["com.tencent.mm", "com.tencent.mm:tools"]``）
    raw_app_keys: list[str] = Field(default_factory=list)
    #: 是否被识别。false → 属于"未识别进程"，可在网页整理
    recognized: bool = True
    #: 是否发生了归一（子进程后缀被剥离或别名命中）
    normalized: bool = False
    #: 图标标识
    icon_key: str | None = None
    #: 命中用户手工映射时的统一应用 id
    catalog_id: uuid.UUID | None = None


class CategoryUsageOut(StrictModel):
    category: str
    active_seconds: int = 0
    ratio_of_app_time: float = 0.0


class AppUsageListOut(StrictModel):
    period: str
    from_utc: str
    to_utc: str
    timezone_offset_minutes: int
    total_app_active_seconds: int = 0
    items: list[AppUsageOut] = Field(default_factory=list)


class CategoryUsageListOut(StrictModel):
    period: str
    from_utc: str
    to_utc: str
    timezone_offset_minutes: int
    total_app_active_seconds: int = 0
    items: list[CategoryUsageOut] = Field(default_factory=list)


class DeviceUsageListOut(StrictModel):
    period: str
    from_utc: str
    to_utc: str
    timezone_offset_minutes: int
    items: list[DeviceUsageOut] = Field(default_factory=list)
    total_active_seconds: int = 0
    overlap_warning: str = OVERLAP_WARNING


__all__ = [
    "AppUsageListOut",
    "AppUsageOut",
    "CategoryUsageListOut",
    "CategoryUsageOut",
    "DeviceUsageListOut",
    "DeviceUsageOut",
    "OVERLAP_WARNING",
    "OverviewOut",
    "PERIOD_30D",
    "PERIOD_7D",
    "PERIOD_DAY_OFFSET",
    "PERIOD_DAYS",
    "PERIOD_TODAY",
    "PERIOD_YESTERDAY",
    "PERIODS",
]

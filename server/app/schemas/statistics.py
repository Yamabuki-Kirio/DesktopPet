"""Phase 4B：跨设备云端统计 schema。

设计说明（为什么是这些字段，而不是另起一套模型）：

现有 ``activity_segments`` **已经是逐条会话表**，且上传链路已经在传原始会话
（不是只传每日汇总）。因此本模块只在它之上做查询与聚合，字段映射如下：

======================  ==========================================================
需求字段                 实际来源
======================  ==========================================================
``local_record_id``     ``activity_segments.id`` —— 客户端生成的稳定 UUID，
                        同时是 ``(user_id, id)`` 复合主键与同步幂等键
``app_id``              ``activity_segments.app_key``（规范化可执行名，不含路径）
``app_name``            ``user_applications.display_name``，回退 ``app_key``
``device_id``           ``activity_segments.device_id``（属于当前用户）
``started_at`` /        ``activity_segments.started_at`` / ``ended_at``（UTC）
``ended_at``
``duration_seconds``    ``activity_segments.active_seconds`` 按窗口裁剪后的秒数
                        （客户端认定的"真实使用时长"，口径与 /stats/* 一致）
``category``            ``user_applications.category``，回退 ``activity_segments.category``
======================  ==========================================================

隐私：这里的响应**只**包含应用名 / 分类 / 起止时间 / 时长，
没有任何窗口标题、网址、文档名或本地路径字段。
"""

from __future__ import annotations

import uuid

from pydantic import Field

from .common import StrictModel

#: 「全部设备」的两种写法
DEVICE_ALL = "all"

#: 逐条会话分页的默认/最大页大小
DEFAULT_SESSION_LIMIT = 100
MAX_SESSION_LIMIT = 500

#: 相邻会话在**展示层**允许合并的最大间隔（秒）。
#: 仅影响展示（时间线/时间段），不影响累计时长的区间并集计算。
DISPLAY_MERGE_GAP_SECONDS = 60

#: 单次查询允许的最大天数（防止一次拉取整年数据）
MAX_QUERY_DAYS = 92

#: 「往日记录」按天分页：默认与最大页大小都是 7 天。
#:
#: 为什么固定成 7：这是界面上一屏能看清、且不会让用户等太久的最小合理单位
#: （定稿第四节要求"每次只加载 7 天历史摘要"）。上限也设成 7，
#: 避免有人用 ``limit=92`` 绕过"默认折叠"的意图，一次把整季数据拉走。
DAYS_PAGE_SIZE = 7

#: 历史摘要里最多回几个应用名（界面一行只显示 "Chrome / 微信" 这种概览）
TOP_APPS_IN_DAY = 3

OVERLAP_WARNING_ALL_DEVICES = (
    "这是各设备使用时长的合计；同一账号在多台设备上并行使用时时间会重叠，"
    "该合计未做去重。"
)


class StatisticsDeviceOut(StrictModel):
    """云端统计的设备选择项。"""

    id: uuid.UUID
    name: str
    platform: str
    model_name: str | None = None
    last_seen_at: str | None = None
    revoked: bool = False
    #: 是否是发起本次查询的设备（便于界面标注"本机"）
    is_current: bool = False


class DeviceListOut(StrictModel):
    items: list[StatisticsDeviceOut] = Field(default_factory=list)


class StatisticsAppOut(StrictModel):
    app_id: str
    app_name: str
    category: str = "other"
    duration_seconds: int = 0
    session_count: int = 0
    #: 归一化进来之前用过的原始名（可追溯；单项时就是它自己）
    raw_app_keys: list[str] = Field(default_factory=list)
    #: 是否被内置表 / 用户应用库识别。false → 界面进"未识别进程，去整理"
    recognized: bool = True
    #: 是否发生了归一（子进程后缀被剥离、或别名命中）
    normalized: bool = False
    #: 图标标识（由服务端给出稳定标识，前端映射到自己的图标集，不传图片）
    icon_key: str | None = None
    #: 命中的统一应用 id（Phase 2 整理界面用它做"合并到已有应用"的目标）。
    #: 仅当这一组来自用户手工映射时非空；内置推导的应用没有目录行。
    catalog_id: uuid.UUID | None = None


class StatisticsSummaryOut(StrictModel):
    """某个（或全部）设备在某一天（或某段日期）的使用汇总。"""

    date: str
    date_from: str | None = None
    date_to: str | None = None
    timezone: str
    device_id: uuid.UUID | None = None
    total_duration_seconds: int = 0
    session_count: int = 0
    app_count: int = 0
    #: 该账号在该窗口内最后一次收到上传的时间（用于界面显示"最近同步时间"）
    last_synced_at: str | None = None
    apps: list[StatisticsAppOut] = Field(default_factory=list)
    #: 仅在「全部设备」时非空
    overlap_warning: str | None = None


class UsageSessionOut(StrictModel):
    """一条原始使用会话（未做任何展示合并）。"""

    id: uuid.UUID
    local_record_id: str
    device_id: uuid.UUID
    device_name: str
    platform: str
    app_id: str
    app_name: str
    category: str = "other"
    started_at: str
    ended_at: str | None = None
    duration_seconds: int = 0
    #: 这条记录上传时的**原始**进程名 / 包名。归一化会把它合并到统一应用，
    #: 但原始值必须可追溯（定稿第八节：点击详情能看到
    #: ``com.tencent.mm:tools`` 这类子进程名）。
    raw_app_key: str = ""


class UsageSessionPageOut(StrictModel):
    """逐条会话分页。``next_cursor`` 为 null 表示没有更多。"""

    date: str
    date_from: str | None = None
    date_to: str | None = None
    timezone: str
    device_id: uuid.UUID | None = None
    items: list[UsageSessionOut] = Field(default_factory=list)
    next_cursor: str | None = None


class TimelineEntryOut(StrictModel):
    """时间线的一条（相邻同应用会话已在**展示层**合并）。"""

    app_id: str
    app_name: str
    category: str = "other"
    device_id: uuid.UUID
    device_name: str
    started_at: str
    ended_at: str | None = None
    duration_seconds: int = 0
    #: 这条展示项由几条原始会话合并而来
    merged_session_count: int = 1
    #: 合并进来的原始进程名（归一时用于追溯，例如
    #: ``["com.tencent.mm", "com.tencent.mm:tools"]``）
    raw_app_keys: list[str] = Field(default_factory=list)
    #: 是否发生了应用归一（同一展示项内含多个原始名，或别名/子进程后缀命中）
    normalized: bool = False


class TimelineOut(StrictModel):
    date: str
    date_from: str | None = None
    date_to: str | None = None
    timezone: str
    device_id: uuid.UUID | None = None
    items: list[TimelineEntryOut] = Field(default_factory=list)
    total_duration_seconds: int = 0
    overlap_warning: str | None = None


class DaySummaryOut(StrictModel):
    """「往日记录」里的一行（某一天的概览）。

    **刻意只给概览，不给明细**：这是"默认折叠、按需加载"的实现基础——
    用户不点开某一天，就不该为那一天付出任何查询代价。

    ``device_count`` 是**该日有活动记录的设备数**，不是账户的设备总数：
    界面要表达的是"这一天我在几台设备上用过"，用总数会误导。
    """

    date: str
    active_seconds: int = 0
    device_count: int = 0
    #: 该日时长前几名的应用（已按归一化后的显示名给出）
    top_apps: list[StatisticsAppOut] = Field(default_factory=list)
    #: 该日是否有任何数据。false 时界面显示"这天没有记录"而不是"0 分钟"
    has_data: bool = False


class DaySummaryPageOut(StrictModel):
    """按日期倒序的一页历史摘要。``next_before`` 为 null 表示没有更早的日期。"""

    items: list[DaySummaryOut] = Field(default_factory=list)
    #: 下一页的 ``before`` 参数（不包含的上界）
    next_before: str | None = None
    has_more: bool = False
    timezone: str
    device_id: uuid.UUID | None = None


# ---------------------------------------------------------------------------
# Phase 2B：五维洞察
# ---------------------------------------------------------------------------

#: 五维的键与标签（顺序固定，前端按序渲染）
INSIGHT_DIMENSIONS = (
    ("focus", "专注度"),
    ("rhythm", "使用节律"),
    ("intensity", "使用强度"),
    ("structure", "内容结构"),
    ("cross_device", "跨设备状态"),
)

#: 基线窗口天数（与用户自己的近 7 日比较）
INSIGHT_BASELINE_DAYS = 7

#: 少于这个天数就判定"样本不足"，**不强行评分**
INSIGHT_MIN_SAMPLE_DAYS = 3

#: 深夜时段（本地时间，含起点不含终点）：23:00–05:00
LATE_NIGHT_START_HOUR = 23
LATE_NIGHT_END_HOUR = 5


class InsightDimensionOut(StrictModel):
    """一个维度的评分与依据。

    ``score`` 为 null 表示**样本不足**——此时界面必须显示「样本不足」，
    而不是把 null 当 0 分。定稿要求"数据不足时不生成虚假评价"。
    """

    key: str
    label: str
    score: int | None = None
    baseline_score: int | None = None
    #: ``score - baseline_score``；null 表示无从比较
    delta: int | None = None
    #: up / down / flat / null
    direction: str | None = None
    #: 必须能解释：每条都含具体数字
    reasons: list[str] = Field(default_factory=list)


class InsightOverviewOut(StrictModel):
    """洞察响应里用到的原始指标（界面"为什么"展开时可展示）。"""

    total_seconds: int = 0
    session_count: int = 0
    app_count: int = 0
    longest_continuous_seconds: int = 0
    short_session_ratio: float = 0.0
    switch_count: int = 0
    first_active_at: str | None = None
    last_active_at: str | None = None
    late_night_ratio: float = 0.0
    top_app_name: str | None = None
    top_app_share: float = 0.0
    device_count: int = 0


class InsightsOut(StrictModel):
    date: str
    timezone: str
    device_id: uuid.UUID | None = None
    #: 基线实际用到的有效天数（有数据的天数）
    sample_days: int = 0
    is_sample_sufficient: bool = False
    insufficient_reason: str | None = None
    dimensions: list[InsightDimensionOut] = Field(default_factory=list)
    overview: InsightOverviewOut = Field(default_factory=InsightOverviewOut)
    highlights: list[str] = Field(default_factory=list)
    observations: list[str] = Field(default_factory=list)
    suggestions: list[str] = Field(default_factory=list)
    #: 规则生成的文字总结（**不调用大模型**）
    summary_text: str = ""
    #: 「全部设备」时的既有口径提示（时长可能重叠）
    overlap_warning: str | None = None


# ---------------------------------------------------------------------------
# Phase 2C：趋势
# ---------------------------------------------------------------------------

#: 只支持这两档（定稿只要求 7 / 30）。放开任意值等于允许一次拉整年。
TREND_DAYS_CHOICES = (7, 30)


class TrendDailyOut(StrictModel):
    date: str
    total_seconds: int = 0
    #: 该日是否有数据。false 时界面画"空柱"而不是 0 高度实柱
    has_data: bool = False


class TrendCategoryOut(StrictModel):
    category: str
    total_seconds: int = 0
    ratio: float = 0.0


class TrendFocusOut(StrictModel):
    date: str
    #: null = 该日样本不足，不评分
    score: int | None = None


class TrendPlatformOut(StrictModel):
    platform: str
    total_seconds: int = 0
    ratio: float = 0.0


class TrendAppOut(StrictModel):
    app_id: str
    app_name: str
    total_seconds: int = 0


class TrendsOut(StrictModel):
    days: int
    timezone: str
    device_id: uuid.UUID | None = None
    date_from: str
    date_to: str
    daily: list[TrendDailyOut] = Field(default_factory=list)
    categories: list[TrendCategoryOut] = Field(default_factory=list)
    focus_scores: list[TrendFocusOut] = Field(default_factory=list)
    #: 深夜（23:00–05:00）使用占比
    late_night_ratio: float = 0.0
    platform_split: list[TrendPlatformOut] = Field(default_factory=list)
    top_apps: list[TrendAppOut] = Field(default_factory=list)
    #: 窗口内没有任何记录的天数，供界面标注"这段时间有 N 天没数据"
    insufficient_days: int = 0
    total_seconds: int = 0
    overlap_warning: str | None = None


__all__ = [
    "DAYS_PAGE_SIZE",
    "DEFAULT_SESSION_LIMIT",
    "DEVICE_ALL",
    "DISPLAY_MERGE_GAP_SECONDS",
    "DaySummaryOut",
    "DaySummaryPageOut",
    "DeviceListOut",
    "INSIGHT_BASELINE_DAYS",
    "INSIGHT_DIMENSIONS",
    "INSIGHT_MIN_SAMPLE_DAYS",
    "LATE_NIGHT_END_HOUR",
    "LATE_NIGHT_START_HOUR",
    "MAX_QUERY_DAYS",
    "MAX_SESSION_LIMIT",
    "OVERLAP_WARNING_ALL_DEVICES",
    "InsightDimensionOut",
    "InsightOverviewOut",
    "InsightsOut",
    "StatisticsAppOut",
    "StatisticsDeviceOut",
    "StatisticsSummaryOut",
    "TOP_APPS_IN_DAY",
    "TREND_DAYS_CHOICES",
    "TimelineEntryOut",
    "TimelineOut",
    "TrendAppOut",
    "TrendCategoryOut",
    "TrendDailyOut",
    "TrendFocusOut",
    "TrendPlatformOut",
    "TrendsOut",
    "UsageSessionOut",
    "UsageSessionPageOut",
]

"""Phase 4B：跨设备云端统计接口。

```
GET /api/v1/statistics/summary
GET /api/v1/statistics/apps
GET /api/v1/statistics/sessions
GET /api/v1/statistics/timeline
```

（设备列表复用既有的 ``GET /api/v1/devices`` —— 它已经返回 id / 名称 / 平台 /
型号 / 最近在线 / 是否撤销 / 是否本机，没有必要再开一个同义端点。）

通用查询参数
------------
* ``device_id``：不传或 ``all`` → 当前账户**全部设备**；指定时必须属于当前用户（否则 404）
* ``date``：单日（``YYYY-MM-DD``）。与 ``date_from``/``date_to`` 互斥
* ``date_from`` / ``date_to``：日期区间（含两端，最多 92 天）
* ``timezone``：IANA 时区名（如 ``Asia/Shanghai``），用于把 UTC 数据划分到**用户当地日期**
* ``tz_offset_minutes``：``timezone`` 不可用时的等价替代（客户端每次查询都会带上）
* ``app_id``：只看某个应用
* ``cursor`` / ``limit``：逐条会话分页

身份一律来自访问令牌，**不接受客户端传入 user_id**。
"""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends, Query
from sqlalchemy.orm import Session

from ...core.config import Settings, get_settings
from ...core.logger import get_logger
from ...database.session import get_db
from ...schemas.statistics import (
    DAYS_PAGE_SIZE,
    DEFAULT_SESSION_LIMIT,
    MAX_SESSION_LIMIT,
    DaySummaryPageOut,
    DeviceListOut,
    InsightsOut,
    StatisticsSummaryOut,
    TimelineOut,
    TrendsOut,
    UsageSessionPageOut,
)
from ...security.deps import ApiKeyAuth, CurrentUserOrWeb
from ...services import insights_service, statistics_service, trends_service
from ...services.statistics_service import (
    resolve_device_scope,
    resolve_timezone,
    resolve_window,
)

router = APIRouter(tags=["statistics"])
#: MCP / 集成用的同一批统计端点（身份由个人访问密钥推导）。
#: 与上面的 Bearer 端点**共用同一个服务函数**，因此两处结果不可能不一致。
integration_router = APIRouter(tags=["integrations"])
logger = get_logger(__name__)

DeviceIdQuery = Annotated[
    str | None,
    Query(description="设备 UUID；不传或 all 表示当前账户全部设备"),
]
DateQuery = Annotated[str | None, Query(description="单日 YYYY-MM-DD")]
DateFromQuery = Annotated[str | None, Query(description="区间起始日 YYYY-MM-DD（含）")]
DateToQuery = Annotated[str | None, Query(description="区间结束日 YYYY-MM-DD（含）")]
TimezoneQuery = Annotated[
    str | None,
    Query(description="IANA 时区名，例如 Asia/Shanghai；用于决定「当地日期」的边界"),
]
OffsetQuery = Annotated[
    int | None,
    Query(
        description="相对 UTC 的分钟偏移（timezone 的等价替代），-720 ~ 840",
        ge=-720,
        le=840,
    ),
]
AppIdQuery = Annotated[str | None, Query(description="只看某个应用（app_id）", max_length=128)]
CursorQuery = Annotated[str | None, Query(description="分页游标，取自上一页的 next_cursor")]
LimitQuery = Annotated[
    int,
    Query(description="页大小", ge=1, le=MAX_SESSION_LIMIT),
]
BeforeQuery = Annotated[
    str | None,
    Query(description="日期游标：只返回**早于**该日期(YYYY-MM-DD)的记录（不包含）"),
]
DaysLimitQuery = Annotated[
    int,
    Query(
        description=f"天数页大小，默认与上限都是 {DAYS_PAGE_SIZE}",
        ge=1,
        le=DAYS_PAGE_SIZE,
    ),
]
TrendsDaysQuery = Annotated[
    int,
    Query(description="趋势窗口：只支持 7 或 30"),
]


@router.get("/statistics/summary", response_model=StatisticsSummaryOut)
async def summary(
    user: CurrentUserOrWeb,
    db: Annotated[Session, Depends(get_db)],
    device_id: DeviceIdQuery = None,
    date: DateQuery = None,
    date_from: DateFromQuery = None,
    date_to: DateToQuery = None,
    timezone: TimezoneQuery = None,
    tz_offset_minutes: OffsetQuery = None,
):
    """某设备（或全部设备）在指定日期的使用汇总 + 应用排行。

    身份可来自 ``Authorization: Bearer``（Windows / Android 客户端）
    或网页会话 Cookie（GameLog「生活足迹」，见 docs/43），两者走同一条校验路径。
    """
    tz = resolve_timezone(timezone, tz_offset_minutes)
    window = resolve_window(
        date_str=date, date_from=date_from, date_to=date_to, tz=tz
    )
    scope = resolve_device_scope(db, user=user, device_id=device_id)
    return statistics_service.get_summary(db, user=user, window=window, scope=scope)


@router.get("/statistics/apps", response_model=StatisticsSummaryOut)
async def apps(
    user: CurrentUserOrWeb,
    db: Annotated[Session, Depends(get_db)],
    device_id: DeviceIdQuery = None,
    date: DateQuery = None,
    date_from: DateFromQuery = None,
    date_to: DateToQuery = None,
    timezone: TimezoneQuery = None,
    tz_offset_minutes: OffsetQuery = None,
):
    """应用排行。

    响应体与 ``/statistics/summary`` **完全一致**（重点看 ``apps``，已按时长降序），
    由同一个服务函数产出，因此客户端（含 MCP）只需要一套解析逻辑，
    两处口径不可能漂移。
    """
    tz = resolve_timezone(timezone, tz_offset_minutes)
    window = resolve_window(
        date_str=date, date_from=date_from, date_to=date_to, tz=tz
    )
    scope = resolve_device_scope(db, user=user, device_id=device_id)
    return statistics_service.get_summary(db, user=user, window=window, scope=scope)


@router.get("/statistics/sessions", response_model=UsageSessionPageOut)
async def sessions(
    user: CurrentUserOrWeb,
    db: Annotated[Session, Depends(get_db)],
    device_id: DeviceIdQuery = None,
    date: DateQuery = None,
    date_from: DateFromQuery = None,
    date_to: DateToQuery = None,
    timezone: TimezoneQuery = None,
    tz_offset_minutes: OffsetQuery = None,
    app_id: AppIdQuery = None,
    cursor: CursorQuery = None,
    limit: LimitQuery = DEFAULT_SESSION_LIMIT,
):
    """逐条原始会话（按开始时间升序分页）。

    客户端展开某个应用的时间段时，只需带上 ``app_id``。
    """
    tz = resolve_timezone(timezone, tz_offset_minutes)
    window = resolve_window(
        date_str=date, date_from=date_from, date_to=date_to, tz=tz
    )
    scope = resolve_device_scope(db, user=user, device_id=device_id)
    return statistics_service.get_sessions(
        db,
        user=user,
        window=window,
        scope=scope,
        app_id=app_id,
        cursor=cursor,
        limit=limit,
    )


@router.get("/statistics/timeline", response_model=TimelineOut)
async def timeline(
    user: CurrentUserOrWeb,
    db: Annotated[Session, Depends(get_db)],
    device_id: DeviceIdQuery = None,
    date: DateQuery = None,
    date_from: DateFromQuery = None,
    date_to: DateToQuery = None,
    timezone: TimezoneQuery = None,
    tz_offset_minutes: OffsetQuery = None,
    app_id: AppIdQuery = None,
):
    """全天时间线（相邻同应用会话已在展示层合并）。

    合并只影响展示，累计时长仍按区间并集计算。
    """
    tz = resolve_timezone(timezone, tz_offset_minutes)
    window = resolve_window(
        date_str=date, date_from=date_from, date_to=date_to, tz=tz
    )
    scope = resolve_device_scope(db, user=user, device_id=device_id)
    result = statistics_service.get_timeline(db, user=user, window=window, scope=scope)
    return _filter_timeline(result, app_id)


def _filter_timeline(result: TimelineOut, app_id: str | None) -> TimelineOut:
    """按应用过滤时间线。

    同时匹配**统一键**与**任一原始名**：前者是前端回传的值，
    后者保证旧调用方（直接传 ``com.tencent.mm:tools`` 这类原始名）仍然有效。
    """
    if not app_id:
        return result
    result.items = [
        item
        for item in result.items
        if item.app_id == app_id or app_id in (item.raw_app_keys or [])
    ]
    return result


# ---------------------------------------------------------------------------
# 集成（MCP / 个人访问密钥）用的同一批统计端点
# ---------------------------------------------------------------------------


def _resolve(
    db: Session,
    *,
    user,
    device_id: str | None,
    date: str | None,
    date_from: str | None,
    date_to: str | None,
    timezone: str | None,
    tz_offset_minutes: int | None,
):
    tz = resolve_timezone(timezone, tz_offset_minutes)
    window = resolve_window(date_str=date, date_from=date_from, date_to=date_to, tz=tz)
    scope = resolve_device_scope(db, user=user, device_id=device_id)
    return window, scope


def _effective_limit(limit: int | None, settings: Settings) -> int:
    """集成侧页大小上限：不超过 ``integration_max_items``，避免把大结果丢给模型。"""
    cap = max(1, int(settings.integration_max_items))
    if limit is None:
        return min(DEFAULT_SESSION_LIMIT, cap)
    return max(1, min(limit, cap))


@integration_router.get("/integrations/statistics/devices", response_model=DeviceListOut)
async def integration_devices(
    principal: ApiKeyAuth,
    db: Annotated[Session, Depends(get_db)],
):
    """密钥对应用户的设备列表（用于回答"我有哪几台电脑"）。"""
    return statistics_service.list_devices(db, user=principal.user)


@integration_router.get(
    "/integrations/statistics/summary", response_model=StatisticsSummaryOut
)
async def integration_usage_summary(
    principal: ApiKeyAuth,
    db: Annotated[Session, Depends(get_db)],
    device_id: DeviceIdQuery = None,
    date: DateQuery = None,
    date_from: DateFromQuery = None,
    date_to: DateToQuery = None,
    timezone: TimezoneQuery = None,
    tz_offset_minutes: OffsetQuery = None,
):
    """按设备 / 日期查询使用汇总与应用排行。"""
    window, scope = _resolve(
        db,
        user=principal.user,
        device_id=device_id,
        date=date,
        date_from=date_from,
        date_to=date_to,
        timezone=timezone,
        tz_offset_minutes=tz_offset_minutes,
    )
    return statistics_service.get_summary(db, user=principal.user, window=window, scope=scope)


@integration_router.get(
    "/integrations/statistics/apps", response_model=StatisticsSummaryOut
)
async def integration_app_usage(
    principal: ApiKeyAuth,
    db: Annotated[Session, Depends(get_db)],
    device_id: DeviceIdQuery = None,
    date: DateQuery = None,
    date_from: DateFromQuery = None,
    date_to: DateToQuery = None,
    timezone: TimezoneQuery = None,
    tz_offset_minutes: OffsetQuery = None,
):
    """应用排行（与 summary 同一份聚合结果）。"""
    window, scope = _resolve(
        db,
        user=principal.user,
        device_id=device_id,
        date=date,
        date_from=date_from,
        date_to=date_to,
        timezone=timezone,
        tz_offset_minutes=tz_offset_minutes,
    )
    return statistics_service.get_summary(db, user=principal.user, window=window, scope=scope)


@integration_router.get(
    "/integrations/statistics/sessions", response_model=UsageSessionPageOut
)
async def integration_usage_sessions(
    principal: ApiKeyAuth,
    db: Annotated[Session, Depends(get_db)],
    settings: Annotated[Settings, Depends(get_settings)],
    device_id: DeviceIdQuery = None,
    date: DateQuery = None,
    date_from: DateFromQuery = None,
    date_to: DateToQuery = None,
    timezone: TimezoneQuery = None,
    tz_offset_minutes: OffsetQuery = None,
    app_id: AppIdQuery = None,
    cursor: CursorQuery = None,
    limit: int | None = None,
):
    """逐条使用会话（分页）。页大小受 ``integration_max_items`` 限制。"""
    window, scope = _resolve(
        db,
        user=principal.user,
        device_id=device_id,
        date=date,
        date_from=date_from,
        date_to=date_to,
        timezone=timezone,
        tz_offset_minutes=tz_offset_minutes,
    )
    return statistics_service.get_sessions(
        db,
        user=principal.user,
        window=window,
        scope=scope,
        app_id=app_id,
        cursor=cursor,
        limit=_effective_limit(limit, settings),
    )


@integration_router.get("/integrations/statistics/timeline", response_model=TimelineOut)
async def integration_daily_timeline(
    principal: ApiKeyAuth,
    db: Annotated[Session, Depends(get_db)],
    device_id: DeviceIdQuery = None,
    date: DateQuery = None,
    date_from: DateFromQuery = None,
    date_to: DateToQuery = None,
    timezone: TimezoneQuery = None,
    tz_offset_minutes: OffsetQuery = None,
    app_id: AppIdQuery = None,
):
    """全天时间线（相邻同应用会话已合并）。"""
    window, scope = _resolve(
        db,
        user=principal.user,
        device_id=device_id,
        date=date,
        date_from=date_from,
        date_to=date_to,
        timezone=timezone,
        tz_offset_minutes=tz_offset_minutes,
    )
    result = statistics_service.get_timeline(
        db, user=principal.user, window=window, scope=scope
    )
    return _filter_timeline(result, app_id)


@router.get("/statistics/insights", response_model=InsightsOut)
async def insights(
    user: CurrentUserOrWeb,
    db: Annotated[Session, Depends(get_db)],
    date: DateQuery = None,
    device_id: DeviceIdQuery = None,
    timezone: TimezoneQuery = None,
    tz_offset_minutes: OffsetQuery = None,
):
    """五维洞察（专注度 / 使用节律 / 使用强度 / 内容结构 / 跨设备状态）。

    规则**全部是确定性的纯函数**，与用户自己的近 7 日基线比较，
    不使用任何社会标准判断好坏；每个分数都带可解释的 ``reasons``。

    数据不足时（当天无记录，或基线有数据的天数 < 3）
    ``score`` / ``baseline_score`` / ``delta`` 一律为 ``null`` 且
    ``is_sample_sufficient=false`` —— **不强行评分**（定稿要求）。
    """
    tz = resolve_timezone(timezone, tz_offset_minutes)
    scope = resolve_device_scope(db, user=user, device_id=device_id)
    return insights_service.get_insights(
        db, user=user, date_str=date, tz=tz, scope=scope
    )


@router.get("/statistics/trends", response_model=TrendsOut)
async def trends(
    user: CurrentUserOrWeb,
    db: Annotated[Session, Depends(get_db)],
    days: TrendsDaysQuery = 7,
    device_id: DeviceIdQuery = None,
    timezone: TimezoneQuery = None,
    tz_offset_minutes: OffsetQuery = None,
):
    """逐日趋势（只支持 7 天与 30 天两档）。

    加载纪律由前端保证：**进入页面不请求本接口**；
    打开「总结」页才请求 ``days=7``；点「近30日」才请求 ``days=30``；
    结果在当前页面缓存。服务端只负责"按请求的档位返回"，且**不查每一天的完整时间线**。
    """
    tz = resolve_timezone(timezone, tz_offset_minutes)
    scope = resolve_device_scope(db, user=user, device_id=device_id)
    return trends_service.get_trends(
        db, user=user, days=days, tz=tz, scope=scope
    )


# ---------------------------------------------------------------------------
# 「往日记录」：按日期倒序的摘要分页（GameLog 生活足迹，见 docs/43）
# ---------------------------------------------------------------------------


@router.get("/statistics/days", response_model=DaySummaryPageOut)
async def days(
    user: CurrentUserOrWeb,
    db: Annotated[Session, Depends(get_db)],
    before: BeforeQuery = None,
    limit: DaysLimitQuery = DAYS_PAGE_SIZE,
    device_id: DeviceIdQuery = None,
    timezone: TimezoneQuery = None,
    tz_offset_minutes: OffsetQuery = None,
):
    """历史日期摘要（**日期游标**分页，倒序）。

    * ``before`` 是**不包含**的日期上界；不传表示从今天往前取；
    * ``limit`` 默认与上限都是 **7**（定稿第七节：每次只加载 7 天）；
    * 页面初始化**不得**调用本接口 —— 只有用户展开「往日记录」时才请求。

    与 ``/statistics/summary`` 共用同一套时区、设备范围与归一化逻辑，
    因此"往日里某天的时长"与"点进那天看到的时长"必然一致。
    """
    tz = resolve_timezone(timezone, tz_offset_minutes)
    scope = resolve_device_scope(db, user=user, device_id=device_id)
    parsed_before = None
    if before is not None:
        parsed_before = statistics_service._parse_date(before, field="before")
    return statistics_service.get_day_summaries(
        db,
        user=user,
        scope=scope,
        tz=tz,
        before=parsed_before,
        limit=limit,
    )


__all__ = ["integration_router", "router"]

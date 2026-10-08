"""Phase 3：集成统计服务（只读）。

这个模块**不实现任何统计口径**，只做三件编排工作：

1. 把 ``stats_service`` 的结果按 ``integration_max_items`` 截断，
   并如实告诉调用方"截断过"（``returned`` / ``truncated``）；
2. 为"两个时段对比"构造两个 ``StatsWindow``，然后调两次
   ``stats_service.get_summary_for_window``（同一套聚合代码）；
3. 计算数据新鲜度（最近一次收到数据的时间、最近一次活动时间）。

因此 AI 看到的数字与 Windows 客户端、与 ``/api/v1/stats/*`` 完全一致。
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from ..core.errors import ApiError, ErrorCode
from ..core.logger import get_logger
from ..core.timeutil import ensure_utc, utcnow
from ..models import ActivitySegment, DailyUsage, User, UserApplication
from ..schemas.integration import (
    IntegrationAppListOut,
    IntegrationCategoryListOut,
    IntegrationDeviceListOut,
    PeriodComparisonOut,
    PeriodMetricsOut,
    SyncStatusOut,
)
from ..schemas.stats import OverviewOut
from . import integration_service, stats_service

logger = get_logger(__name__)

#: 超过这个时长没有新数据，就认为"可能过期"。
#: 客户端每 5 分钟同步一次，因此 60 分钟足够宽松，不会误报。
STALE_AFTER_MINUTES = 60

COMPARE_TODAY_VS_YESTERDAY = "today_vs_yesterday"
COMPARE_WEEK_VS_LAST_WEEK = "week_vs_last_week"
COMPARE_LAST7_VS_PREVIOUS7 = "last7_vs_previous7"

COMPARE_KINDS: tuple[str, ...] = (
    COMPARE_TODAY_VS_YESTERDAY,
    COMPARE_WEEK_VS_LAST_WEEK,
    COMPARE_LAST7_VS_PREVIOUS7,
)

_COMPARE_LABELS: dict[str, tuple[str, str]] = {
    COMPARE_TODAY_VS_YESTERDAY: ("今天", "昨天"),
    COMPARE_WEEK_VS_LAST_WEEK: ("本周（截至现在）", "上周（同时长）"),
    COMPARE_LAST7_VS_PREVIOUS7: ("最近 7 天", "此前 7 天"),
}

_NOTE_TODAY_VS_YESTERDAY = "今天与昨天都是完整的自然日，口径一致。"
_NOTE_WEEK = (
    "本周与上周都只统计**相同已过时长**（从周一 00:00 到现在），"
    "避免用没过完的一周去比完整一周。"
)
_NOTE_LAST7 = "两个窗口都是 7 个自然日（含今天）；后者是紧邻的前 7 天。"


def validate_compare_kind(kind: str) -> str:
    if kind not in COMPARE_KINDS:
        raise ApiError(
            ErrorCode.validation_error,
            f"kind 必须是 {list(COMPARE_KINDS)} 之一",
        )
    return kind


def _cap(items: list, limit: int) -> tuple[list, bool]:
    """按上限截断，返回 ``(截断后的列表, 是否被截断)``。"""
    if limit >= len(items):
        return items, False
    return items[:limit], True


# ---------------------------------------------------------------------------
# 四个只读统计（全部委托 stats_service）
# ---------------------------------------------------------------------------


def get_summary(
    db: Session, *, user: User, period: str, offset_minutes: int
) -> OverviewOut:
    return stats_service.get_summary(
        db, user=user, period=period, offset_minutes=offset_minutes
    )


def list_apps(
    db: Session, *, user: User, period: str, offset_minutes: int, limit: int
) -> IntegrationAppListOut:
    result = stats_service.get_apps(
        db, user=user, period=period, offset_minutes=offset_minutes
    )
    items, truncated = _cap(list(result.items), limit)
    return IntegrationAppListOut(
        period=result.period,
        from_utc=result.from_utc,
        to_utc=result.to_utc,
        timezone_offset_minutes=result.timezone_offset_minutes,
        total_app_active_seconds=result.total_app_active_seconds,
        returned=len(items),
        truncated=truncated,
        items=items,
    )


def list_categories(
    db: Session, *, user: User, period: str, offset_minutes: int, limit: int
) -> IntegrationCategoryListOut:
    result = stats_service.get_categories(
        db, user=user, period=period, offset_minutes=offset_minutes
    )
    items, truncated = _cap(list(result.items), limit)
    return IntegrationCategoryListOut(
        period=result.period,
        from_utc=result.from_utc,
        to_utc=result.to_utc,
        timezone_offset_minutes=result.timezone_offset_minutes,
        total_app_active_seconds=result.total_app_active_seconds,
        returned=len(items),
        truncated=truncated,
        items=items,
    )


def list_devices(
    db: Session, *, user: User, period: str, offset_minutes: int, limit: int
) -> IntegrationDeviceListOut:
    result = stats_service.get_devices(
        db, user=user, period=period, offset_minutes=offset_minutes
    )
    items, truncated = _cap(list(result.items), limit)
    return IntegrationDeviceListOut(
        period=result.period,
        from_utc=result.from_utc,
        to_utc=result.to_utc,
        timezone_offset_minutes=result.timezone_offset_minutes,
        total_active_seconds=result.total_active_seconds,
        overlap_warning=result.overlap_warning,
        returned=len(items),
        truncated=truncated,
        items=items,
    )


# ---------------------------------------------------------------------------
# 时段对比
# ---------------------------------------------------------------------------


def _week_windows(
    offset_minutes: int, moment: datetime
) -> tuple[stats_service.StatsWindow, stats_service.StatsWindow]:
    """本周 / 上周的窗口，两侧**等长**（都从周一 00:00 起算到"现在"这么长）。"""
    tz = timezone(timedelta(minutes=offset_minutes))
    local_now = ensure_utc(moment).astimezone(tz)
    local_midnight = datetime(local_now.year, local_now.month, local_now.day, tzinfo=tz)
    monday = local_midnight - timedelta(days=local_now.weekday())
    elapsed = local_now - monday
    if elapsed <= timedelta(0):  # pragma: no cover - 周一 00:00 整点的极端边界
        elapsed = timedelta(minutes=1)

    def build(start_local: datetime) -> stats_service.StatsWindow:
        end_local = start_local + elapsed
        keys: list[str] = []
        cursor = start_local
        while cursor < end_local:
            keys.append(cursor.date().isoformat())
            cursor += timedelta(days=1)
        if not keys:
            keys.append(start_local.date().isoformat())
        return stats_service.StatsWindow(
            from_utc=start_local.astimezone(timezone.utc),
            to_utc=end_local.astimezone(timezone.utc),
            day_keys=keys,
            offset_minutes=offset_minutes,
        )

    return build(monday), build(monday - timedelta(days=7))


def resolve_compare_windows(
    kind: str, *, offset_minutes: int, now: datetime | None = None
) -> tuple[stats_service.StatsWindow, stats_service.StatsWindow, str]:
    """返回 ``(当前窗口, 上一窗口, 口径说明)``。"""
    validate_compare_kind(kind)
    stats_service.validate_offset(offset_minutes)
    moment = now or utcnow()

    if kind == COMPARE_TODAY_VS_YESTERDAY:
        current = stats_service.resolve_window(
            "today", offset_minutes=offset_minutes, now=moment
        )
        previous = stats_service.resolve_window(
            "yesterday", offset_minutes=offset_minutes, now=moment
        )
        return current, previous, _NOTE_TODAY_VS_YESTERDAY

    if kind == COMPARE_LAST7_VS_PREVIOUS7:
        current = stats_service.resolve_window(
            "7d", offset_minutes=offset_minutes, now=moment
        )
        previous = stats_service.resolve_window(
            "7d", offset_minutes=offset_minutes, now=moment - timedelta(days=7)
        )
        return current, previous, _NOTE_LAST7

    current, previous = _week_windows(offset_minutes, moment)
    return current, previous, _NOTE_WEEK


def _ratio(current: int, previous: int) -> float | None:
    """变化比例；基线为 0 时返回 None（**不伪造百分比**）。"""
    if previous <= 0:
        return None
    return round((current - previous) / previous, 4)


def _metrics(label: str, window: stats_service.StatsWindow, overview: OverviewOut) -> PeriodMetricsOut:
    return PeriodMetricsOut(
        label=label,
        from_utc=window.iso_from(),
        to_utc=window.iso_to(),
        session_seconds=overview.session_seconds,
        active_seconds=overview.active_seconds,
        idle_seconds=overview.idle_seconds,
        app_active_seconds=overview.app_active_seconds,
        device_count=overview.device_count,
    )


def compare_periods(
    db: Session,
    *,
    user: User,
    kind: str,
    offset_minutes: int,
    now: datetime | None = None,
) -> PeriodComparisonOut:
    current_window, previous_window, note = resolve_compare_windows(
        kind, offset_minutes=offset_minutes, now=now
    )
    current_label, previous_label = _COMPARE_LABELS[kind]

    current_overview = stats_service.get_summary_for_window(
        db, user=user, window=current_window, period_label=current_label
    )
    previous_overview = stats_service.get_summary_for_window(
        db, user=user, window=previous_window, period_label=previous_label
    )

    active_delta = current_overview.active_seconds - previous_overview.active_seconds
    app_delta = current_overview.app_active_seconds - previous_overview.app_active_seconds
    has_data = bool(
        current_overview.active_seconds
        or previous_overview.active_seconds
        or current_overview.session_seconds
        or previous_overview.session_seconds
    )

    return PeriodComparisonOut(
        kind=kind,
        timezone_offset_minutes=offset_minutes,
        current=_metrics(current_label, current_window, current_overview),
        previous=_metrics(previous_label, previous_window, previous_overview),
        active_seconds_delta=active_delta,
        active_seconds_change_ratio=_ratio(
            current_overview.active_seconds, previous_overview.active_seconds
        ),
        app_active_seconds_delta=app_delta,
        app_active_seconds_change_ratio=_ratio(
            current_overview.app_active_seconds, previous_overview.app_active_seconds
        ),
        has_data=has_data,
        note=note,
    )


# ---------------------------------------------------------------------------
# 同步状态
# ---------------------------------------------------------------------------


def _max_dt(*values: datetime | None) -> datetime | None:
    candidates = [ensure_utc(v) for v in values if v is not None]
    return max(candidates) if candidates else None


def sync_status(db: Session, *, user: User) -> SyncStatusOut:
    """最近同步时间 / 最近活动时间 / 有效设备数 / 数据是否可能过期。

    只做 ``MAX()`` 聚合，不读任何内容字段——因此不可能带出窗口标题、URL 或路径。
    """
    device_count = integration_service.count_active_devices(db, user=user)

    received: list[datetime | None] = [
        db.scalar(
            select(func.max(model.server_received_at)).where(model.user_id == user.id)
        )
        for model in (ActivitySegment, DailyUsage, UserApplication)
    ]
    last_received = _max_dt(*received)

    last_activity = db.scalar(
        select(func.max(ActivitySegment.started_at)).where(
            ActivitySegment.user_id == user.id
        )
    )
    last_activity_at = ensure_utc(last_activity) if last_activity else None

    now = utcnow()
    if last_received is None:
        stale = True
        note = "该账户还没有收到任何同步数据。"
    else:
        age = now - last_received
        stale = age > timedelta(minutes=STALE_AFTER_MINUTES)
        note = (
            f"最近一次收到数据在 {int(age.total_seconds() // 60)} 分钟前。"
            if not stale
            else f"已经超过 {STALE_AFTER_MINUTES} 分钟没有收到新数据，"
            "可能是客户端未运行、网络不通或同步失败。"
        )

    return SyncStatusOut(
        registered_device_count=device_count,
        last_data_received_at=last_received.isoformat().replace("+00:00", "Z")
        if last_received
        else None,
        last_activity_at=last_activity_at.isoformat().replace("+00:00", "Z")
        if last_activity_at
        else None,
        data_may_be_stale=stale,
        stale_after_minutes=STALE_AFTER_MINUTES,
        note=note,
    )


__all__ = [
    "COMPARE_KINDS",
    "COMPARE_LAST7_VS_PREVIOUS7",
    "COMPARE_TODAY_VS_YESTERDAY",
    "COMPARE_WEEK_VS_LAST_WEEK",
    "STALE_AFTER_MINUTES",
    "compare_periods",
    "get_summary",
    "list_apps",
    "list_categories",
    "list_devices",
    "resolve_compare_windows",
    "sync_status",
    "validate_compare_kind",
]

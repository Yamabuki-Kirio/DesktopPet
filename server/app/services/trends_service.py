"""趋势服务（Phase 2C）：7 日 / 30 日的逐日趋势。

复用而非重写
------------
逐日指标、评分函数、跨设备重叠计算**全部复用** :mod:`insights_service`，
本模块只做"批量 + 汇总"：

* 逐日总时长、分类占比、专注度、深夜占比、平台比例、使用最多的应用；
* 不为趋势去查每一天的完整时间线（定稿的加载纪律要求），
  只做区间聚合，一次查询。

加载纪律（接口侧只保证"按请求的 days 返回"，缓存与懒加载由前端负责）
--------------------------------------------------------------------
* 进入页面**不**请求趋势；
* 打开「总结」页才请求 7 日；
* 点「近30日」才请求 30 日。

`days` 只接受 7 或 30：放开成任意值等于允许一次把整年数据拉走。
"""

from __future__ import annotations

from collections import defaultdict
from datetime import date as date_cls
from datetime import timedelta

from sqlalchemy.orm import Session

from ..core.errors import ApiError, ErrorCode
from ..core.logger import get_logger
from ..models import User
from ..schemas.statistics import (
    TREND_DAYS_CHOICES,
    OVERLAP_WARNING_ALL_DEVICES,
    TrendAppOut,
    TrendCategoryOut,
    TrendDailyOut,
    TrendFocusOut,
    TrendPlatformOut,
    TrendsOut,
)
from .app_identity import AppIdentityIndex
from .insights_service import (
    DayMetrics,
    _build_daily_metrics,
    _device_platforms,
    score_focus,
)
from .statistics_service import (
    DeviceScope,
    ResolvedTimezone,
    _load_sessions,
    _to_sessions,
    resolve_window,
)

logger = get_logger(__name__)


def validate_trend_days(days: int) -> int:
    if days not in TREND_DAYS_CHOICES:
        raise ApiError(
            ErrorCode.validation_error,
            f"days 只能是 {' 或 '.join(str(d) for d in TREND_DAYS_CHOICES)}",
        )
    return days


def get_trends(
    db: Session,
    *,
    user: User,
    days: int,
    tz: ResolvedTimezone,
    scope: DeviceScope,
) -> TrendsOut:
    """返回最近 ``days`` 天（含今天）的逐日趋势。"""
    validate_trend_days(days)

    today = resolve_window(date_str=None, date_from=None, date_to=None, tz=tz).date_from
    end = date_cls.fromisoformat(today)
    start = end - timedelta(days=days - 1)
    day_keys = [(start + timedelta(days=offset)).isoformat() for offset in range(days)]

    span = resolve_window(
        date_str=None, date_from=day_keys[0], date_to=day_keys[-1], tz=tz
    )
    rows = _load_sessions(db, user_id=user.id, window=span, device_ids=scope.device_ids)
    sessions = _to_sessions(rows, span)

    device_platforms = _device_platforms(db, user_id=user.id)
    for session in sessions:
        session.platform = device_platforms.get(session.device_id, "unknown")

    sessions_by_day: dict[str, list] = defaultdict(list)
    for session in sessions:
        key = session.start.astimezone(tz.tz).date().isoformat()
        sessions_by_day[key].append(session)

    identities = AppIdentityIndex.load(db, user_id=user.id)
    metrics_by_day = _build_daily_metrics(
        day_keys=day_keys,
        sessions_by_day=sessions_by_day,
        identities=identities,
        tz=tz,
    )

    # --- 逐日总时长 ---
    daily = [
        TrendDailyOut(
            date=key,
            total_seconds=metrics_by_day[key].total_seconds,
            has_data=metrics_by_day[key].has_data,
        )
        for key in day_keys
    ]

    # --- 分类占比（窗口内合计）---
    category_totals: dict[str, int] = defaultdict(int)
    for key in day_keys:
        for category, seconds in metrics_by_day[key].category_seconds.items():
            category_totals[category] += seconds
    grand_total = sum(category_totals.values())
    categories = [
        TrendCategoryOut(
            category=category,
            total_seconds=seconds,
            ratio=(seconds / grand_total) if grand_total else 0.0,
        )
        for category, seconds in sorted(
            category_totals.items(), key=lambda kv: (-kv[1], kv[0])
        )
    ]

    # --- 专注度趋势 ---
    # 逐日单独评分：用当天与"它之前若干天"的对比会更准，但那会让
    # 前几天的基线为空、几乎全是"样本不足"。折中做法：用**同一窗口内的均值**
    # 作为基线口径（与"个人近 7 日基线"是同一个思路，且窗口内自洽）。
    average = _window_average(metrics_by_day, day_keys)
    focus_scores = []
    for key in day_keys:
        metrics = metrics_by_day[key]
        if not metrics.has_data:
            focus_scores.append(TrendFocusOut(date=key, score=None))
            continue
        score, _reasons = score_focus(metrics)
        focus_scores.append(TrendFocusOut(date=key, score=score))

    # --- 深夜占比 ---
    late_seconds = sum(metrics_by_day[k].late_night_seconds for k in day_keys)
    late_ratio = (late_seconds / grand_total) if grand_total else 0.0

    # --- 平台比例 ---
    platform_totals: dict[str, int] = defaultdict(int)
    for key in day_keys:
        for platform, seconds in metrics_by_day[key].platform_seconds.items():
            platform_totals[platform] += seconds
    platform_total = sum(platform_totals.values())
    platform_split = [
        TrendPlatformOut(
            platform=platform,
            total_seconds=seconds,
            ratio=(seconds / platform_total) if platform_total else 0.0,
        )
        for platform, seconds in sorted(
            platform_totals.items(), key=lambda kv: (-kv[1], kv[0])
        )
    ]

    # --- 使用最多的应用 ---
    app_totals: dict[str, int] = defaultdict(int)
    app_names: dict[str, str] = {}
    for key in day_keys:
        metrics = metrics_by_day[key]
        for app_key, seconds in metrics.app_seconds.items():
            app_totals[app_key] += seconds
            app_names.setdefault(app_key, metrics.app_names.get(app_key, app_key))
    top_apps = [
        TrendAppOut(app_id=key, app_name=app_names.get(key, key), total_seconds=seconds)
        for key, seconds in sorted(app_totals.items(), key=lambda kv: (-kv[1], kv[0]))[:5]
    ]

    insufficient_days = sum(1 for key in day_keys if not metrics_by_day[key].has_data)

    logger.debug(
        "trends user_id=%s days=%s total=%s insufficient=%s",
        user.id,
        days,
        grand_total,
        insufficient_days,
    )

    return TrendsOut(
        days=days,
        timezone=tz.label,
        device_id=scope.selected.id if scope.selected else None,
        date_from=day_keys[0],
        date_to=day_keys[-1],
        daily=daily,
        categories=categories,
        focus_scores=focus_scores,
        late_night_ratio=round(late_ratio, 4),
        platform_split=platform_split,
        top_apps=top_apps,
        insufficient_days=insufficient_days,
        total_seconds=grand_total,
        overlap_warning=(
            OVERLAP_WARNING_ALL_DEVICES
            if scope.is_all and len(scope.device_ids or []) > 1
            else None
        ),
    )


def _window_average(
    metrics_by_day: dict[str, DayMetrics], day_keys: list[str]
) -> DayMetrics | None:
    """窗口内有数据的天取平均（趋势里用来自查口径，不对外暴露）。"""
    sample = [metrics_by_day[k] for k in day_keys if metrics_by_day[k].has_data]
    if not sample:
        return None
    out = DayMetrics(day="average", has_data=True)
    count = len(sample)
    out.total_seconds = int(round(sum(m.total_seconds for m in sample) / count))
    out.longest_seconds = int(round(sum(m.longest_seconds for m in sample) / count))
    out.switch_count = int(round(sum(m.switch_count for m in sample) / count))
    out.session_count = int(round(sum(m.session_count for m in sample) / count))
    out.short_session_count = int(round(sum(m.short_session_count for m in sample) / count))
    return out


__all__ = ["get_trends", "validate_trend_days"]

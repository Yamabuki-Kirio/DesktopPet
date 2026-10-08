"""服务端统计服务。

口径严格照搬 ``docs/12-使用统计口径.md`` 与客户端 ``UsageAnalyticsService``：
两边的裁剪与折算公式必须**完全一致**，否则客户端看到的今日数据和网页看到的会不一致。

关键点：
1. **时区由客户端指定**（``tz_offset_minutes``）——服务端绝不按服务器本地时区算"今天"；
2. 与窗口有交集的活动段按**墙钟比例折算**活跃秒数，跨零点的那一段会被正确拆到两天；
3. ``应用使用时间 ≤ 活跃使用时间``，两者分别来自 ``activity_segments`` 与 ``daily_usage``；
4. 多设备求和**不做去重**，并在响应里显式提示可能重叠。
"""

from __future__ import annotations

import uuid
from collections import defaultdict
from datetime import datetime, timedelta, timezone

from sqlalchemy import select
from sqlalchemy.orm import Session

from ..core.logger import get_logger
from ..core.timeutil import ensure_utc, utcnow
from ..models import ActivitySegment, DailyUsage, Device, User
from ..schemas.stats import (
    OVERLAP_WARNING,
    PERIOD_DAY_OFFSET,
    PERIOD_DAYS,
    PERIOD_TODAY,
    PERIODS,
    AppUsageListOut,
    AppUsageOut,
    CategoryUsageListOut,
    CategoryUsageOut,
    DeviceUsageListOut,
    DeviceUsageOut,
    OverviewOut,
)
from ..core.errors import ApiError, ErrorCode
from .app_identity import AppIdentityIndex, ResolvedApp

logger = get_logger(__name__)


class StatsWindow:
    """一个统计窗口：UTC 区间 + 该区间覆盖的本地日期键。"""

    def __init__(
        self,
        *,
        from_utc: datetime,
        to_utc: datetime,
        day_keys: list[str],
        offset_minutes: int,
    ) -> None:
        self.from_utc = from_utc
        self.to_utc = to_utc
        self.day_keys = day_keys
        self.offset_minutes = offset_minutes

    def iso_from(self) -> str:
        return self.from_utc.isoformat().replace("+00:00", "Z")

    def iso_to(self) -> str:
        return self.to_utc.isoformat().replace("+00:00", "Z")


def validate_period(period: str) -> str:
    if period not in PERIODS:
        raise ApiError(
            ErrorCode.validation_error,
            f"period 必须是 {PERIODS} 之一",
        )
    return period


def validate_offset(offset_minutes: int) -> int:
    if not (-12 * 60 <= offset_minutes <= 14 * 60):
        raise ApiError(
            ErrorCode.validation_error,
            "tz_offset_minutes 必须在 -720 ~ 840 之间（UTC-12:00 ~ UTC+14:00）",
        )
    return offset_minutes


def resolve_window(
    period: str, *, offset_minutes: int = 0, now: datetime | None = None
) -> StatsWindow:
    """把「今天 / 最近 7 天 / 最近 30 天」+ 客户端时区换算成 UTC 区间。"""
    validate_period(period)
    validate_offset(offset_minutes)

    now_utc = ensure_utc(now or utcnow())
    tz = timezone(timedelta(minutes=offset_minutes))
    local_now = now_utc.astimezone(tz)
    local_midnight = datetime(
        local_now.year, local_now.month, local_now.day, tzinfo=tz
    )
    days = PERIOD_DAYS[period]
    offset_days = PERIOD_DAY_OFFSET[period]
    # 今天/昨天只覆盖 1 天；7d/30d 覆盖含今天在内的 N 天
    from_local = local_midnight - timedelta(days=days - 1 + abs(offset_days))
    to_local = local_midnight + timedelta(days=1 + offset_days)

    from_utc = from_local.astimezone(timezone.utc)
    to_utc = to_local.astimezone(timezone.utc)

    day_keys: list[str] = []
    cursor = from_local
    while cursor < to_local:
        day_keys.append(cursor.date().isoformat())
        cursor += timedelta(days=1)

    return StatsWindow(
        from_utc=from_utc,
        to_utc=to_utc,
        day_keys=day_keys,
        offset_minutes=offset_minutes,
    )


def _fetch_segments(
    db: Session, *, user_id: uuid.UUID, window: StatsWindow
) -> list[ActivitySegment]:
    """取与窗口有交集的活动段（走 (user_id, started_at) 索引）。"""
    return list(
        db.scalars(
            select(ActivitySegment).where(
                ActivitySegment.user_id == user_id,
                ActivitySegment.started_at < window.to_utc,
                (ActivitySegment.ended_at.is_(None))
                | (ActivitySegment.ended_at > window.from_utc),
            )
        )
    )


class _Clipped:
    __slots__ = ("start", "end", "active_seconds", "app_key", "category", "device_id")

    def __init__(
        self,
        start: datetime,
        end: datetime,
        active_seconds: int,
        app_key: str,
        category: str,
        device_id: uuid.UUID,
    ) -> None:
        self.start = start
        self.end = end
        self.active_seconds = active_seconds
        self.app_key = app_key
        self.category = category
        self.device_id = device_id


def _clip(rows: list[ActivitySegment], window: StatsWindow) -> list[_Clipped]:
    """把跨界段裁剪到窗口内，并按墙钟比例折算活跃秒数。"""
    now = utcnow()
    result: list[_Clipped] = []
    for row in rows:
        seg_start = ensure_utc(row.started_at)
        seg_end = ensure_utc(row.ended_at) if row.ended_at else now
        start = max(seg_start, window.from_utc)
        end = min(seg_end, window.to_utc)
        if end <= start:
            continue
        total_wall = (seg_end - seg_start).total_seconds()
        overlap = (end - start).total_seconds()
        active = int(row.active_seconds or 0)
        credited = 0 if total_wall <= 0 else int(round(active * overlap / total_wall))
        result.append(
            _Clipped(start, end, credited, row.app_key, row.category, row.device_id)
        )
    return result


def _fetch_daily(
    db: Session, *, user_id: uuid.UUID, window: StatsWindow
) -> list[DailyUsage]:
    if not window.day_keys:
        return []
    return list(
        db.scalars(
            select(DailyUsage).where(
                DailyUsage.user_id == user_id,
                DailyUsage.local_day.in_(window.day_keys),
            )
        )
    )


def _summary(
    db: Session, *, user: User, window: StatsWindow
) -> tuple[OverviewOut, list[DeviceUsageOut], list[_Clipped], list[DailyUsage]]:
    clipped = _clip(_fetch_segments(db, user_id=user.id, window=window), window)
    daily = _fetch_daily(db, user_id=user.id, window=window)

    devices = {d.id: d for d in db.scalars(select(Device).where(Device.user_id == user.id))}

    per_device: dict[uuid.UUID, DeviceUsageOut] = {}
    for row in daily:
        entry = per_device.get(row.device_id)
        if entry is None:
            device = devices.get(row.device_id)
            entry = DeviceUsageOut(
                device_id=row.device_id,
                device_name=device.device_name if device else str(row.device_id),
                platform=device.platform if device else "unknown",
                last_seen_at=device.last_seen_at.isoformat().replace("+00:00", "Z")
                if device
                else None,
                revoked=bool(device.revoked_at) if device else False,
            )
            per_device[row.device_id] = entry
        entry.session_seconds += row.session_seconds
        entry.active_seconds += row.active_seconds
        entry.idle_seconds += row.idle_seconds

    # 只有活动段、没有 daily_usage 的设备也要出现在列表里
    for device_id in {c.device_id for c in clipped}:
        if device_id in per_device:
            continue
        device = devices.get(device_id)
        per_device[device_id] = DeviceUsageOut(
            device_id=device_id,
            device_name=device.device_name if device else str(device_id),
            platform=device.platform if device else "unknown",
            last_seen_at=device.last_seen_at.isoformat().replace("+00:00", "Z")
            if device
            else None,
            revoked=bool(device.revoked_at) if device else False,
        )

    session_total = sum(d.session_seconds for d in per_device.values())
    active_total = sum(d.active_seconds for d in per_device.values())
    idle_total = sum(d.idle_seconds for d in per_device.values())
    app_active_total = sum(c.active_seconds for c in clipped)

    firsts = [row.first_active_at for row in daily if row.first_active_at]
    lasts = [row.last_active_at for row in daily if row.last_active_at]

    overview = OverviewOut(
        period="",
        from_utc=window.iso_from(),
        to_utc=window.iso_to(),
        timezone_offset_minutes=window.offset_minutes,
        session_seconds=session_total,
        active_seconds=active_total,
        idle_seconds=idle_total,
        app_active_seconds=app_active_total,
        first_active_at=min(firsts).isoformat().replace("+00:00", "Z") if firsts else None,
        last_active_at=max(lasts).isoformat().replace("+00:00", "Z") if lasts else None,
        device_count=len(per_device),
        total_active_seconds_across_devices=active_total,
        overlap_warning=OVERLAP_WARNING,
    )
    device_list = sorted(
        per_device.values(), key=lambda d: d.active_seconds, reverse=True
    )
    return overview, device_list, clipped, daily


def get_summary(
    db: Session, *, user: User, period: str, offset_minutes: int
) -> OverviewOut:
    window = resolve_window(period, offset_minutes=offset_minutes)
    overview, _devices, _clipped, _daily = _summary(db, user=user, window=window)
    overview.period = period
    return overview


def get_summary_for_window(
    db: Session, *, user: User, window: StatsWindow, period_label: str = ""
) -> OverviewOut:
    """按**显式窗口**取总览。

    存在的唯一理由：集成层要做"两个时段对比"（例如最近 7 天 vs 此前 7 天），
    需要按给定窗口取两次汇总。它复用同一个 ``_summary``，
    因此**口径与 ``/stats/summary`` 完全一致**，不存在第二套算法。
    """
    overview, _devices, _clipped, _daily = _summary(db, user=user, window=window)
    overview.period = period_label
    return overview


def get_devices(
    db: Session, *, user: User, period: str, offset_minutes: int
) -> DeviceUsageListOut:
    window = resolve_window(period, offset_minutes=offset_minutes)
    _overview, devices, _clipped, _daily = _summary(db, user=user, window=window)
    return DeviceUsageListOut(
        period=period,
        from_utc=window.iso_from(),
        to_utc=window.iso_to(),
        timezone_offset_minutes=window.offset_minutes,
        items=devices,
        total_active_seconds=sum(d.active_seconds for d in devices),
        overlap_warning=OVERLAP_WARNING,
    )


def get_apps(
    db: Session, *, user: User, period: str, offset_minutes: int
) -> AppUsageListOut:
    window = resolve_window(period, offset_minutes=offset_minutes)
    _overview, _devices, clipped, _daily = _summary(db, user=user, window=window)

    # 与 ``statistics_service`` **共用同一个身份索引**。
    #
    # 审计（docs/45 第 1.3 节）发现统计聚合有两层：这一层服务 /stats/* 与
    # MCP 的 /integrations/stats/*，另一层服务网页的 /statistics/*。
    # 如果只给其中一层归一化，就会出现"网页 1 条微信、MCP 4 条"。
    # 因此这里也必须走 AppIdentityIndex，而不是按原始 app_key 直接分组。
    index = AppIdentityIndex.load(db, user_id=user.id)

    agg: dict[str, int] = defaultdict(int)
    counts: dict[str, int] = defaultdict(int)
    #: 首次见到的身份即该组的展示信息；同键必然同显示名/分类
    identities: dict[str, ResolvedApp] = {}
    raws_by_key: dict[str, set[str]] = defaultdict(set)
    #: 应用库里没有记录时，回退到活动段自带的分类，而不是一律 other
    fallback_category: dict[str, str] = {}

    for c in clipped:
        identity = index.resolve(c.app_key)
        key = identity.key
        agg[key] += c.active_seconds
        counts[key] += 1
        identities.setdefault(key, identity)
        raws_by_key[key].add(c.app_key)
        fallback_category.setdefault(c.app_key, c.category)

    total = sum(agg.values())
    items: list[AppUsageOut] = []
    for key, seconds in agg.items():
        identity = identities[key]
        items.append(
            AppUsageOut(
                # ``app_key`` 沿用既有字段名（旧客户端/MCP 依赖它），
                # 但值改为归一后的统一键 —— 这样一次微信只出现一条。
                app_key=key,
                display_name=identity.display_name,
                category=(
                    identity.category
                    if identity.recognized
                    else fallback_category.get(key, identity.category)
                ),
                active_seconds=seconds,
                segment_count=counts[key],
                ratio_of_app_time=(seconds / total) if total else 0.0,
                raw_app_keys=sorted(raws_by_key[key]),
                recognized=identity.recognized,
                normalized=len(raws_by_key[key]) > 1 or identity.normalized,
                icon_key=identity.icon_key,
                catalog_id=identity.catalog_id,
            )
        )
    items.sort(key=lambda i: i.active_seconds, reverse=True)
    return AppUsageListOut(
        period=period,
        from_utc=window.iso_from(),
        to_utc=window.iso_to(),
        timezone_offset_minutes=window.offset_minutes,
        total_app_active_seconds=total,
        items=items,
    )


def get_categories(
    db: Session, *, user: User, period: str, offset_minutes: int
) -> CategoryUsageListOut:
    window = resolve_window(period, offset_minutes=offset_minutes)
    _overview, _devices, clipped, _daily = _summary(db, user=user, window=window)

    # 分类也走同一个身份索引：否则用户在整理界面把某个进程归到「社交」后，
    # 应用排行会立刻变成一条微信，而分类占比却还是按原始 app_key 的用户库分类算，
    # 两边对不上（应用之和 ≠ 分类之和）。
    index = AppIdentityIndex.load(db, user_id=user.id)

    agg: dict[str, int] = defaultdict(int)
    for c in clipped:
        identity = index.resolve(c.app_key)
        # 识别过的用归一后的分类；未识别的回退到活动段自带的分类
        category = identity.category if identity.recognized else c.category
        agg[category] += c.active_seconds

    total = sum(agg.values())
    items = [
        CategoryUsageOut(
            category=category,
            active_seconds=seconds,
            ratio_of_app_time=(seconds / total) if total else 0.0,
        )
        for category, seconds in agg.items()
    ]
    items.sort(key=lambda i: i.active_seconds, reverse=True)
    return CategoryUsageListOut(
        period=period,
        from_utc=window.iso_from(),
        to_utc=window.iso_to(),
        timezone_offset_minutes=window.offset_minutes,
        total_app_active_seconds=total,
        items=items,
    )


__all__ = [
    "PERIOD_TODAY",
    "StatsWindow",
    "get_apps",
    "get_categories",
    "get_devices",
    "get_summary",
    "get_summary_for_window",
    "resolve_window",
    "validate_offset",
    "validate_period",
]

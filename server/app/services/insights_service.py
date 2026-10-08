"""五维洞察服务（Phase 2B）：纯规则评分，与用户自己的历史比较。

设计原则（定稿"评分原则"逐条落实）
----------------------------------
1. 分数范围 **0~100**；
2. **每个分数都能解释** —— 每个维度至少带 1 条 ``reasons``，且每条都含具体数字；
3. **与用户自己的近 7 日基线比较**，不使用任何社会标准判断"好坏"
   （所以没有"你应该休息"这类结论，只有"比你自己平时高/低多少"）；
4. **数据不足时显示"样本不足"，不强行评分** —— ``score`` 返回 ``null``；
5. 「全部设备」时沿用既有 **求和不去重** 口径，并透出 ``overlap_warning``；
6. 总结**由规则生成，不调用外部大模型**。

为什么不用大模型
----------------
分数要"可解释"就要求计算路径完全确定。大模型会给出一段读起来很顺、
但无法逐项追溯到具体秒数与次数的文字——那正是定稿要避免的。

计算成本
--------
一次查询取回"当天 + 之前 7 天"共 8 天的会话，之后全部在内存里按本地日期切分计算，
不做 N+1 查询。
"""

from __future__ import annotations

import uuid
from collections import defaultdict
from dataclasses import dataclass, field
from datetime import date as date_cls
from datetime import datetime, timedelta

from sqlalchemy.orm import Session

from ..core.logger import get_logger
from ..core.timeutil import ensure_utc, utcnow
from ..models import User
from ..schemas.common import to_iso
from ..schemas.statistics import (
    INSIGHT_BASELINE_DAYS,
    INSIGHT_DIMENSIONS,
    INSIGHT_MIN_SAMPLE_DAYS,
    LATE_NIGHT_END_HOUR,
    LATE_NIGHT_START_HOUR,
    OVERLAP_WARNING_ALL_DEVICES,
    InsightDimensionOut,
    InsightOverviewOut,
    InsightsOut,
)
from .app_identity import AppIdentityIndex
from .statistics_service import (
    DeviceScope,
    ResolvedTimezone,
    _effective_seconds,
    _load_sessions,
    _to_sessions,
    resolve_window,
)

logger = get_logger(__name__)

#: 短会话阈值（秒）：低于它算"碎片"
SHORT_SESSION_SECONDS = 5 * 60

#: 最长连续时段的封顶（秒）：达到它专注项就得满分
FOCUS_CAP_SECONDS = 60 * 60

#: 休息判定阈值（秒）：间隔达到它算一次"真正休息"
REST_GAP_SECONDS = 15 * 60

#: 时段划分（本地小时）
SLOT_BOUNDS = ((0, 6), (6, 12), (12, 18), (18, 24))
SLOT_LABELS = ("凌晨", "上午", "下午", "晚上")

#: 分类的中文名（用于文案）
CATEGORY_LABELS = {
    "development": "开发",
    "productivity": "效率",
    "gaming": "游戏",
    "social": "社交",
    "entertainment": "娱乐",
    "browser": "浏览器",
    "system": "系统",
    "other": "其他",
}


def _clamp(value: float, low: int = 0, high: int = 100) -> int:
    return int(max(low, min(high, round(value))))


def _fmt_duration(seconds: int) -> str:
    """人类可读时长（用于 reasons 文案）。"""
    total = max(0, int(seconds))
    hours, remainder = divmod(total, 3600)
    minutes = remainder // 60
    if hours and minutes:
        return f"{hours} 小时 {minutes} 分钟"
    if hours:
        return f"{hours} 小时"
    if minutes:
        return f"{minutes} 分钟"
    return "不到 1 分钟"


@dataclass
class DayMetrics:
    """一天的全部指标（当天与每个基线日都算这一套，保证可比）。"""

    day: str
    has_data: bool = False

    total_seconds: int = 0
    app_seconds: dict[str, int] = field(default_factory=dict)
    app_names: dict[str, str] = field(default_factory=dict)
    category_seconds: dict[str, int] = field(default_factory=dict)
    device_seconds: dict[uuid.UUID, int] = field(default_factory=dict)
    platform_seconds: dict[str, int] = field(default_factory=dict)

    session_count: int = 0
    short_session_count: int = 0
    longest_seconds: int = 0
    switch_count: int = 0

    first_active: datetime | None = None
    last_active: datetime | None = None
    slot_seconds: list[int] = field(default_factory=lambda: [0, 0, 0, 0])
    late_night_seconds: int = 0

    #: 多设备重叠秒数（同一分钟内 ≥2 台设备都有记录）
    overlap_seconds: int = 0
    #: 电脑使用期间开始手机会话的次数
    cross_device_switch_count: int = 0

    # --- 派生指标 ---

    @property
    def short_session_ratio(self) -> float:
        return (self.short_session_count / self.session_count) if self.session_count else 0.0

    @property
    def late_night_ratio(self) -> float:
        return (self.late_night_seconds / self.total_seconds) if self.total_seconds else 0.0

    @property
    def top_app_share(self) -> float:
        if not self.total_seconds or not self.app_seconds:
            return 0.0
        return max(self.app_seconds.values()) / self.total_seconds

    def top_app(self) -> tuple[str, int] | None:
        if not self.app_seconds:
            return None
        key = max(self.app_seconds, key=lambda k: (self.app_seconds[k], k))
        return key, self.app_seconds[key]

    @property
    def first_hour(self) -> float | None:
        if self.first_active is None:
            return None
        local = self.first_active
        return local.hour + local.minute / 60.0

    @property
    def last_hour(self) -> float | None:
        if self.last_active is None:
            return None
        local = self.last_active
        return local.hour + local.minute / 60.0

    @property
    def slot_ratios(self) -> list[float]:
        if not self.total_seconds:
            return [0.0, 0.0, 0.0, 0.0]
        return [value / self.total_seconds for value in self.slot_seconds]


def _slot_index(hour: int) -> int:
    for index, (start, end) in enumerate(SLOT_BOUNDS):
        if start <= hour < end:
            return index
    return len(SLOT_BOUNDS) - 1


def _is_late_night(hour: int) -> bool:
    return hour >= LATE_NIGHT_START_HOUR or hour < LATE_NIGHT_END_HOUR


def _build_daily_metrics(
    *,
    day_keys: list[str],
    sessions_by_day: dict[str, list],
    identities,
    tz: ResolvedTimezone,
) -> dict[str, DayMetrics]:
    """把会话按本地日期摊成"每天一套指标"。

    ``sessions_by_day`` 的值是 ``statistics_service.UsageSession`` 列表
    （已裁剪到查询窗口、已按窗口重叠比例折算计入秒数）。
    """
    out: dict[str, DayMetrics] = {}

    for day in day_keys:
        metrics = DayMetrics(day=day)
        day_sessions = sessions_by_day.get(day, [])
        if day_sessions:
            metrics.has_data = True

        # --- 应用/分类/设备维度：按 (设备, 归一键) 分组后去重计时 ----
        grouped: dict[tuple, list] = defaultdict(list)
        for session in day_sessions:
            identity = identities.resolve(session.app_key)
            grouped[(session.device_id, identity.key)].append(session)

        per_app: dict[str, int] = defaultdict(int)
        device_seconds: dict[uuid.UUID, int] = defaultdict(int)
        for (device_id, key), group in grouped.items():
            seconds = _effective_seconds(group)
            per_app[key] += seconds
            device_seconds[device_id] += seconds
            identity = identities.resolve(group[0].app_key)
            metrics.app_names.setdefault(key, identity.display_name)
            metrics.category_seconds[identity.category] = (
                metrics.category_seconds.get(identity.category, 0) + seconds
            )

        metrics.app_seconds = dict(per_app)
        metrics.device_seconds = dict(device_seconds)
        metrics.total_seconds = sum(per_app.values())
        metrics.session_count = len(day_sessions)

        # --- 时间维度 ---
        ordered = sorted(day_sessions, key=lambda s: (s.start, s.device_id, s.app_key))
        if ordered:
            metrics.first_active = ordered[0].start.astimezone(tz.tz)
            metrics.last_active = max(s.end for s in ordered).astimezone(tz.tz)

        previous_key: str | None = None
        for session in ordered:
            identity = identities.resolve(session.app_key)
            duration = max(0, int(session.credited))
            if duration < SHORT_SESSION_SECONDS:
                metrics.short_session_count += 1
            metrics.longest_seconds = max(metrics.longest_seconds, duration)

            local = session.start.astimezone(tz.tz)
            index = _slot_index(local.hour)
            metrics.slot_seconds[index] += duration
            if _is_late_night(local.hour):
                metrics.late_night_seconds += duration

            # 平台时长：调用方会先给会话补好 platform（它存在 devices 表上），
            # 这里统一累加，供洞察与趋势共用，避免两处各算一份而漂移
            platform = (session.platform or "unknown").lower()
            metrics.platform_seconds[platform] = (
                metrics.platform_seconds.get(platform, 0) + duration
            )

            # 应用切换次数：相邻两条会话的应用不同就算一次切换
            if previous_key is not None and identity.key != previous_key:
                metrics.switch_count += 1
            previous_key = identity.key

        # --- 跨设备：重叠秒数 + 手机在电脑使用期间的切换次数 ---
        metrics.overlap_seconds = _overlap_seconds(day_sessions)
        metrics.cross_device_switch_count = _cross_device_switches(day_sessions)

        out[day] = metrics

    return out


def _overlap_seconds(sessions: list) -> int:
    """至少两台设备同时有记录的秒数（按秒级区间并集求交）。

    实现：把所有会话按设备分组取并集，再求"被 ≥2 台设备覆盖"的总时长。
    数据量小（一天的会话），用事件扫描即可。
    """
    by_device: dict[uuid.UUID, list[tuple[datetime, datetime]]] = defaultdict(list)
    for session in sessions:
        by_device[session.device_id].append((session.start, session.end))
    if len(by_device) < 2:
        return 0

    events: list[tuple[datetime, int]] = []
    for intervals in by_device.values():
        merged = _merge_intervals(intervals)
        for start, end in merged:
            events.append((start, 1))
            events.append((end, -1))
    if not events:
        return 0

    events.sort(key=lambda item: (item[0], -item[1]))
    active = 0
    total = 0.0
    previous: datetime | None = None
    for moment, delta in events:
        if previous is not None and active >= 2:
            total += (moment - previous).total_seconds()
        active += delta
        previous = moment
    return int(round(total))


def _merge_intervals(intervals: list[tuple[datetime, datetime]]) -> list[tuple[datetime, datetime]]:
    if not intervals:
        return []
    ordered = sorted(intervals)
    out = [ordered[0]]
    for start, end in ordered[1:]:
        last_start, last_end = out[-1]
        if start <= last_end:
            out[-1] = (last_start, max(last_end, end))
        else:
            out.append((start, end))
    return out


def _cross_device_switches(sessions: list) -> int:
    """电脑使用期间开始使用手机的次数。

    "开始"指的是：某条 Android 会话的起始时刻落在**同一天**某个 Windows
    会话的时间范围内。用来回答"工作时是否频繁看手机"。
    """
    windows = [(s.start, s.end) for s in sessions if (s.platform or "") == "windows"]
    if not windows:
        return 0
    merged = _merge_intervals(windows)
    count = 0
    for session in sessions:
        if (session.platform or "") != "android":
            continue
        if any(start <= session.start <= end for start, end in merged):
            count += 1
    return count


# ---------------------------------------------------------------------------
# 五个维度的评分函数（纯函数，便于单测）
# ---------------------------------------------------------------------------


def score_focus(metrics: DayMetrics) -> tuple[int, list[str]]:
    """专注度：连续使用越长越好，碎片与频繁切换扣分。"""
    longest = metrics.longest_seconds
    longest_score = min(100.0, longest / FOCUS_CAP_SECONDS * 100)

    hours = metrics.total_seconds / 3600.0
    switches_per_hour = (metrics.switch_count / hours) if hours > 0.05 else float(metrics.switch_count)
    switch_score = max(0.0, 100 - switches_per_hour * 8)

    short_score = max(0.0, 100 - metrics.short_session_ratio * 200)

    score = _clamp(0.5 * longest_score + 0.25 * switch_score + 0.25 * short_score)
    reasons = [
        f"最长连续使用 {_fmt_duration(longest)}",
        f"短会话（不足 5 分钟）占比 {round(metrics.short_session_ratio * 100)}%",
        f"应用切换 {metrics.switch_count} 次"
        + (f"（约 {round(switches_per_hour)} 次/小时）" if hours > 0.05 else ""),
    ]
    return score, reasons


def score_rhythm(metrics: DayMetrics, baseline: DayMetrics | None) -> tuple[int, list[str]]:
    """使用节律：与个人平时作息相比的偏离程度。

    **刻意不做"早睡早起才好"这种判断**：晚型作息只要稳定，节律分同样高。
    只有"今天偏离你自己的常态"才扣分。
    """
    reasons: list[str] = []
    penalties = 0.0

    if metrics.first_active:
        reasons.append(f"首次活动 {metrics.first_active.strftime('%H:%M')}")
    if metrics.last_active:
        reasons.append(f"最后活动 {metrics.last_active.strftime('%H:%M')}")

    late_ratio = metrics.late_night_ratio
    # 深夜占比本身不算"坏"，但显著高于个人基线时说明作息被打乱
    reasons.append(f"深夜（23:00–05:00）使用占 {round(late_ratio * 100)}%")

    if baseline is not None and baseline.first_hour is not None and metrics.first_hour is not None:
        drift = abs(metrics.first_hour - baseline.first_hour)
        penalties += min(40.0, drift * 8)
        reasons.append(
            f"首次活动比平时{'晚' if metrics.first_hour > baseline.first_hour else '早'} "
            f"{_fmt_hours(drift)}"
        )
    if baseline is not None and baseline.last_hour is not None and metrics.last_hour is not None:
        drift = abs(metrics.last_hour - baseline.last_hour)
        penalties += min(40.0, drift * 8)
        reasons.append(
            f"结束时间比平时{'晚' if metrics.last_hour > baseline.last_hour else '早'} "
            f"{_fmt_hours(drift)}"
        )
    if baseline is not None:
        # 时段分布的 L1 距离（0~2 → 0~100 分）
        distance = sum(
            abs(a - b) for a, b in zip(metrics.slot_ratios, baseline.slot_ratios)
        )
        penalties += min(40.0, distance * 40)
        reasons.append(f"各时段分布与平时差异 {round(distance * 50)}%")

    if baseline is None:
        # 没有基线时只按"是否有深夜使用"给一个温和的判断，并说明依据
        penalties += min(30.0, late_ratio * 100)

    return _clamp(100 - penalties), reasons


def _fmt_hours(value: float) -> str:
    minutes = int(round(value * 60))
    if minutes < 60:
        return f"{minutes} 分钟"
    return f"{minutes // 60} 小时 {minutes % 60} 分钟"


def score_intensity(metrics: DayMetrics, baseline: DayMetrics | None) -> tuple[int, list[str]]:
    """使用强度：设备累计时长与个人平时相比的偏离。"""
    reasons = [f"设备累计 {_fmt_duration(metrics.total_seconds)}"]
    if baseline is not None and baseline.total_seconds > 0:
        ratio = metrics.total_seconds / baseline.total_seconds
        # 强度是"描述"而不是"好坏"：与平时持平就是 50 分基准线附近
        score = _clamp(50 + (ratio - 1) * 50)
        diff = metrics.total_seconds - baseline.total_seconds
        verb = "多" if diff >= 0 else "少"
        reasons.append(
            f"平时约 {_fmt_duration(baseline.total_seconds)}，今天{verb} {_fmt_duration(abs(diff))}"
        )
    else:
        # 没有基线：以"时长本身"给出一个中性估计，并说明依据
        score = _clamp(metrics.total_seconds / (6 * 3600) * 60)
        reasons.append("暂无同期基线，按当日累计时长估算")

    reasons.append(f"最长连续使用 {_fmt_duration(metrics.longest_seconds)}")
    reasons.append(f"被记录的使用段数 {metrics.session_count} 段")
    return score, reasons


def score_structure(metrics: DayMetrics, baseline: DayMetrics | None) -> tuple[int, list[str]]:
    """内容结构：分类是否均衡、是否过度集中于单一应用、用途是否与平时不同。"""
    reasons: list[str] = []
    if metrics.total_seconds:
        top_category = max(
            metrics.category_seconds,
            key=lambda k: (metrics.category_seconds[k], k),
        )
        share = metrics.category_seconds[top_category] / metrics.total_seconds
        label = CATEGORY_LABELS.get(top_category, top_category)
        reasons.append(f"{label}类应用占 {round(share * 100)}%")
        # 单一分类占比过高 → 结构单一；过于均衡反而说明没有明确用途，故取"中间偏高"最优
        balance_score = 100 - abs(share - 0.5) * 120
    else:
        balance_score = 0.0

    top = metrics.top_app()
    if top is not None:
        top_share = top[1] / metrics.total_seconds if metrics.total_seconds else 0.0
        reasons.append(
            f"{metrics.app_names.get(top[0], top[0])} 占 {round(top_share * 100)}%"
        )
        reasons.append(f"共 {len(metrics.app_seconds)} 个应用")
        concentration_penalty = max(0.0, (top_share - 0.5) * 100)
    else:
        concentration_penalty = 0.0

    score = balance_score - concentration_penalty

    if baseline is not None and baseline.total_seconds and baseline.category_seconds:
        keys = set(metrics.category_seconds) | set(baseline.category_seconds)
        distance = sum(
            abs(
                metrics.category_seconds.get(k, 0) / metrics.total_seconds
                - baseline.category_seconds.get(k, 0) / baseline.total_seconds
            )
            for k in keys
        )
        reasons.append(f"分类结构与平时差异 {round(distance * 50)}%")
        # 用途与平时差得越多，"内容结构"这一项越难用平常心解释 → 轻微扣分
        score -= min(20.0, distance * 20)

    return _clamp(score), reasons


def score_cross_device(
    metrics: DayMetrics, baseline: DayMetrics | None
) -> tuple[int, list[str]]:
    """跨设备状态：设备比例是否稳定、重叠与切换是否明显增多。"""
    reasons: list[str] = []
    total = sum(metrics.platform_seconds.values())
    if total:
        for platform, seconds in sorted(
            metrics.platform_seconds.items(), key=lambda kv: -kv[1]
        ):
            name = {"windows": "Windows", "android": "Android"}.get(platform, platform)
            reasons.append(f"{name} 占 {round(seconds / total * 100)}%")
    reasons.append(f"活跃设备 {len(metrics.device_seconds)} 台")

    if metrics.device_seconds and len(metrics.device_seconds) == 1:
        # 单设备无重叠问题，给中性偏高的分（不是"好"）。
        # 依据里带上数字，保持"每条依据都含具体数据"的一致性。
        reasons.append(f"仅 {len(metrics.device_seconds)} 台设备有记录，不存在重叠")
        return _clamp(80), reasons

    overlap_ratio = (
        metrics.overlap_seconds / metrics.total_seconds if metrics.total_seconds else 0.0
    )
    reasons.append(f"多设备重叠 {_fmt_duration(metrics.overlap_seconds)}")
    if metrics.cross_device_switch_count:
        reasons.append(f"电脑使用期间开始手机使用 {metrics.cross_device_switch_count} 次")

    score = 100 - overlap_ratio * 200 - metrics.cross_device_switch_count * 5

    if baseline is not None and baseline.total_seconds:
        base_overlap = (
            baseline.overlap_seconds / baseline.total_seconds
            if baseline.total_seconds
            else 0.0
        )
        if base_overlap > 0:
            reasons.append(f"平时重叠比例约 {round(base_overlap * 100)}%")
        score += min(20.0, (base_overlap - overlap_ratio) * 100)

    return _clamp(score), reasons


# ---------------------------------------------------------------------------
# 主入口
# ---------------------------------------------------------------------------


def get_insights(
    db: Session,
    *,
    user: User,
    date_str: str | None,
    tz: ResolvedTimezone,
    scope: DeviceScope,
) -> InsightsOut:
    """计算某一天的五维洞察（与用户自己的近 7 日基线比较）。"""
    # 先把"当天 + 基线窗口"整体取回来（一个查询窗口，避免 N+1）
    day_window = resolve_window(
        date_str=date_str, date_from=None, date_to=None, tz=tz
    )
    target_day = date_cls.fromisoformat(day_window.date_from)
    baseline_days = [
        (target_day - timedelta(days=offset)).isoformat()
        for offset in range(1, INSIGHT_BASELINE_DAYS + 1)
    ]
    all_days = baseline_days + [target_day.isoformat()]

    span = resolve_window(
        date_str=None,
        date_from=min(all_days),
        date_to=max(all_days),
        tz=tz,
    )
    rows = _load_sessions(
        db, user_id=user.id, window=span, device_ids=scope.device_ids
    )
    raw_sessions = _to_sessions(rows, span)

    # 会话本身不带平台信息（它在 devices 表上），这里补一次，供跨设备维度使用
    device_platforms = _device_platforms(db, user_id=user.id)
    for session in raw_sessions:
        session.platform = device_platforms.get(session.device_id, "unknown")

    sessions_by_day: dict[str, list] = defaultdict(list)
    for session in raw_sessions:
        day_key = session.start.astimezone(tz.tz).date().isoformat()
        if day_key in all_days:
            sessions_by_day[day_key].append(session)

    identities = AppIdentityIndex.load(db, user_id=user.id)
    metrics_by_day = _build_daily_metrics(
        day_keys=all_days,
        sessions_by_day=sessions_by_day,
        identities=identities,
        tz=tz,
    )

    today = metrics_by_day[target_day.isoformat()]
    sample = [metrics_by_day[d] for d in baseline_days if metrics_by_day[d].has_data]
    sample_days = len(sample)

    sufficient = today.has_data and sample_days >= INSIGHT_MIN_SAMPLE_DAYS
    insufficient_reason = None
    if not today.has_data:
        insufficient_reason = "这一天没有任何使用记录"
    elif sample_days < INSIGHT_MIN_SAMPLE_DAYS:
        insufficient_reason = (
            f"近 {INSIGHT_BASELINE_DAYS} 日只有 {sample_days} 天有记录，"
            f"至少需要 {INSIGHT_MIN_SAMPLE_DAYS} 天才能与你自己比较"
        )

    average = _average_metrics(sample)
    dimensions: list[InsightDimensionOut] = []
    for key, label in INSIGHT_DIMENSIONS:
        dimensions.append(_dimension(key, label, today, average, sufficient))

    overview = InsightOverviewOut(
        total_seconds=today.total_seconds,
        session_count=today.session_count,
        app_count=len(today.app_seconds),
        longest_continuous_seconds=today.longest_seconds,
        short_session_ratio=round(today.short_session_ratio, 4),
        switch_count=today.switch_count,
        first_active_at=to_iso(today.first_active.astimezone(tz.tz)) if today.first_active else None,
        last_active_at=to_iso(today.last_active.astimezone(tz.tz)) if today.last_active else None,
        late_night_ratio=round(today.late_night_ratio, 4),
        top_app_name=(today.app_names.get(today.top_app()[0]) if today.top_app() else None),
        top_app_share=round(today.top_app_share, 4),
        device_count=len(today.device_seconds),
    )

    return InsightsOut(
        date=target_day.isoformat(),
        timezone=tz.label,
        device_id=scope.selected.id if scope.selected else None,
        sample_days=sample_days,
        is_sample_sufficient=sufficient,
        insufficient_reason=insufficient_reason,
        dimensions=dimensions,
        overview=overview,
        highlights=_highlights(today, dimensions, sufficient),
        observations=_observations(today, average, sufficient),
        suggestions=_suggestions(today, average, sufficient),
        summary_text=_summary_text(target_day, today, sample_days, dimensions, sufficient),
        overlap_warning=(
            OVERLAP_WARNING_ALL_DEVICES
            if scope.is_all and len(scope.device_ids or []) > 1
            else None
        ),
    )


def _device_platforms(db: Session, *, user_id: uuid.UUID) -> dict[uuid.UUID, str]:
    """设备 id → 平台（小写）。跨设备维度需要它。"""
    from sqlalchemy import select

    from ..models import Device

    return {
        d.id: (d.platform or "unknown").lower()
        for d in db.scalars(select(Device).where(Device.user_id == user_id))
    }


def _average_metrics(sample: list[DayMetrics]) -> DayMetrics | None:
    """基线日的平均指标（只对有数据的天取平均）。"""
    if not sample:
        return None
    count = len(sample)
    out = DayMetrics(day="baseline", has_data=True)

    out.total_seconds = int(round(sum(m.total_seconds for m in sample) / count))
    out.session_count = int(round(sum(m.session_count for m in sample) / count))
    out.short_session_count = int(round(sum(m.short_session_count for m in sample) / count))
    out.longest_seconds = int(round(sum(m.longest_seconds for m in sample) / count))
    out.switch_count = int(round(sum(m.switch_count for m in sample) / count))
    out.overlap_seconds = int(round(sum(m.overlap_seconds for m in sample) / count))
    out.cross_device_switch_count = int(
        round(sum(m.cross_device_switch_count for m in sample) / count)
    )
    out.late_night_seconds = int(round(sum(m.late_night_seconds for m in sample) / count))
    out.slot_seconds = [
        int(round(sum(m.slot_seconds[i] for m in sample) / count)) for i in range(4)
    ]

    # 时间取"圆均值"的近似：普通平均即可（不跨午夜，误差可接受且可解释）
    firsts = [m.first_hour for m in sample if m.first_hour is not None]
    lasts = [m.last_hour for m in sample if m.last_hour is not None]
    base_day = ensure_utc(utcnow()).astimezone()
    if firsts:
        hour = sum(firsts) / len(firsts)
        out.first_active = base_day.replace(
            hour=int(hour), minute=int(round((hour % 1) * 60)), second=0, microsecond=0
        )
    if lasts:
        hour = sum(lasts) / len(lasts)
        out.last_active = base_day.replace(
            hour=min(23, int(hour)),
            minute=int(round((hour % 1) * 60)),
            second=0,
            microsecond=0,
        )

    for metric in sample:
        for key, seconds in metric.app_seconds.items():
            out.app_seconds[key] = out.app_seconds.get(key, 0) + int(round(seconds / count))
            out.app_names.setdefault(key, metric.app_names.get(key, key))
        for key, seconds in metric.category_seconds.items():
            out.category_seconds[key] = (
                out.category_seconds.get(key, 0) + int(round(seconds / count))
            )
        for key, seconds in metric.platform_seconds.items():
            out.platform_seconds[key] = (
                out.platform_seconds.get(key, 0) + int(round(seconds / count))
            )
        for device in metric.device_seconds:
            out.device_seconds.setdefault(device, 0)

    return out


def _dimension(
    key: str,
    label: str,
    today: DayMetrics,
    baseline: DayMetrics | None,
    sufficient: bool,
) -> InsightDimensionOut:
    """统一构造一个维度；样本不足时分数一律 null。"""
    if not today.has_data:
        # 当天没有记录：给出明确说明而不是一串 0 分依据。
        # 依据里带数字，保持"每条依据都含具体数据"的一致性。
        return InsightDimensionOut(
            key=key,
            label=label,
            # 依据仍写明"0 分钟"，让用户明确知道缺的是数据而不是计算失败
            reasons=[f"当天记录 0 分钟，{label}无法计算"],
        )

    scorer = {
        "focus": lambda: score_focus(today),
        "rhythm": lambda: score_rhythm(today, baseline),
        "intensity": lambda: score_intensity(today, baseline),
        "structure": lambda: score_structure(today, baseline),
        "cross_device": lambda: score_cross_device(today, baseline),
    }[key]

    score, reasons = scorer()

    if not sufficient:
        # 定稿：数据不足时显示"样本不足"，**不强行评分**。
        # 依据仍然给出，便于用户理解"缺的是什么"。
        return InsightDimensionOut(
            key=key, label=label, score=None, baseline_score=None, delta=None,
            direction=None, reasons=reasons,
        )

    baseline_score: int | None = None
    if baseline is not None:
        baseline_score = {
            "focus": lambda: score_focus(baseline)[0],
            "rhythm": lambda: score_rhythm(baseline, None)[0],
            "intensity": lambda: score_intensity(baseline, None)[0],
            "structure": lambda: score_structure(baseline, None)[0],
            "cross_device": lambda: score_cross_device(baseline, None)[0],
        }[key]()

    delta = None
    direction = None
    if baseline_score is not None:
        delta = score - baseline_score
        if delta >= 3:
            direction = "up"
        elif delta <= -3:
            direction = "down"
        else:
            direction = "flat"

    return InsightDimensionOut(
        key=key,
        label=label,
        score=score,
        baseline_score=baseline_score,
        delta=delta,
        direction=direction,
        reasons=reasons,
    )


def _highlights(
    today: DayMetrics, dimensions: list[InsightDimensionOut], sufficient: bool
) -> list[str]:
    if not today.has_data:
        return []
    out: list[str] = []
    if today.longest_seconds >= 25 * 60:
        out.append(f"最长连续使用 {_fmt_duration(today.longest_seconds)}")
    top = today.top_app()
    if top is not None and today.total_seconds:
        share = top[1] / today.total_seconds
        if share >= 0.3:
            out.append(
                f"{today.app_names.get(top[0], top[0])} 占全天 {round(share * 100)}%"
            )
    if len(today.device_seconds) > 1:
        out.append(f"在 {len(today.device_seconds)} 台设备上有记录")
    return out


def _observations(
    today: DayMetrics, baseline: DayMetrics | None, sufficient: bool
) -> list[str]:
    out: list[str] = []
    if today.has_data and today.first_active and today.last_active:
        out.append(
            f"活动时间从 {today.first_active.strftime('%H:%M')} 到 {today.last_active.strftime('%H:%M')}"
        )
    if today.has_data and today.short_session_count:
        out.append(
            f"有 {today.short_session_count} 段不足 5 分钟的碎片使用"
            f"（占 {round(today.short_session_ratio * 100)}%）"
        )
    if baseline is not None and today.has_data:
        if today.total_seconds > baseline.total_seconds:
            out.append(
                f"比平时多 {_fmt_duration(today.total_seconds - baseline.total_seconds)}"
            )
        elif today.total_seconds < baseline.total_seconds:
            out.append(
                f"比平时少 {_fmt_duration(baseline.total_seconds - today.total_seconds)}"
            )
    return out


def _suggestions(
    today: DayMetrics, baseline: DayMetrics | None, sufficient: bool
) -> list[str]:
    """建议只基于"与你自己的对比"，不做价值判断。"""
    if not sufficient or not today.has_data:
        return []
    out: list[str] = []
    if today.short_session_ratio >= 0.4:
        out.append("碎片化使用较多，可以考虑把同类任务合并成更长的连续时段")
    if baseline is not None and today.late_night_ratio > baseline.late_night_ratio * 1.5:
        out.append("深夜使用明显多于你平时，留意作息变化")
    if today.overlap_seconds >= 10 * 60:
        out.append("多设备重叠时间较长，注意总时长里包含重复计算的部分")
    return out


def _summary_text(
    day: date_cls,
    today: DayMetrics,
    sample_days: int,
    dimensions: list[InsightDimensionOut],
    sufficient: bool,
) -> str:
    """规则生成的文字总结（不调用大模型）。"""
    if not today.has_data:
        return f"{day.isoformat()} 没有使用记录，因此无法生成总结。"

    parts: list[str] = []
    parts.append(f"这一天共记录 {_fmt_duration(today.total_seconds)}")

    top = today.top_app()
    if top is not None:
        names = [
            today.app_names.get(key, key)
            for key, _ in sorted(
                today.app_seconds.items(), key=lambda kv: -kv[1]
            )[:3]
        ]
        parts.append(f"主要使用 {('、'.join(names))}")

    parts.append(f"共 {today.session_count} 段使用记录、{len(today.app_seconds)} 个应用")

    if today.longest_seconds:
        parts.append(f"最长的一段连续使用 {_fmt_duration(today.longest_seconds)}")

    text = "，".join(parts) + "。"

    if sufficient:
        scored = [d for d in dimensions if d.score is not None]
        higher = [d for d in scored if d.direction == "up"]
        lower = [d for d in scored if d.direction == "down"]
        if higher:
            text += (
                "与近 "
                f"{INSIGHT_BASELINE_DAYS} 日相比，"
                + "、".join(d.label for d in higher)
                + "有所提高"
            )
            if lower:
                text += "；" + "、".join(d.label for d in lower) + "有所下降"
            text += "。"
        elif lower:
            text += (
                f"与近 {INSIGHT_BASELINE_DAYS} 日相比，"
                + "、".join(d.label for d in lower)
                + "有所下降。"
            )
        else:
            text += f"与近 {INSIGHT_BASELINE_DAYS} 日相比，各项指标基本持平。"
    else:
        text += (
            f"（基线样本仅 {sample_days} 天，不足以与你自己比较，"
            "因此本次不给出评分。）"
        )
    return text


__all__ = [
    "DayMetrics",
    "SHORT_SESSION_SECONDS",
    "get_insights",
    "score_cross_device",
    "score_focus",
    "score_intensity",
    "score_rhythm",
    "score_structure",
]

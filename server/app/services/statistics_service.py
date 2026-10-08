"""Phase 4B：跨设备云端统计服务。

职责边界
--------
* **只读**：本模块不写入任何表，也不参与同步；云端数据永远不会写回本地采集表，
  更不会进入 outbox（否则会形成循环同步与重复累计）。
* **复用同一条上传链路**：数据源就是现有 ``activity_segments``（客户端已经在上传
  原始逐条会话），不新建第二套同步体系。
* **口径与 ``stats_service`` 保持一致**：单条会话的"计入秒数"仍是
  ``active_seconds`` 按窗口重叠比例折算，因此手机看到的今日数据和电脑上
  「本机统计」看到的一致（差别只在于这里额外做了**重叠去重**）。

时长计算规则（用户需求第七节）
------------------------------
1. **同设备同应用重叠去重**：先把该组会话裁剪到查询窗口，取其时钟区间的**并集**，
   再按该组的活跃占比折算 —— 无重叠时结果与逐条相加完全一致（不改变既有口径）；
2. **展示合并**：同设备同应用、间隔 ≤ 60s 的相邻会话在**时间线**里合并成一条，
   合并项的时长仍按区间并集计算（不是简单用首尾时间差）；
3. **跨午夜**：窗口按用户时区的本地午夜切分，原始 UTC 记录不动，
   一条 23:50→00:20 的会话在两天里各出现被裁剪后的那一段；
4. **全部设备**：各设备时长**求和**（可能包含同时使用），显式返回 ``overlap_warning``。

时区
----
优先使用 IANA 时区名（``timezone=Asia/Shanghai``）。Windows 上 Python 的
``zoneinfo`` 需要 ``tzdata`` 数据包，容器/生产镜像里由系统时区库提供；
若运行环境缺少该数据包，本模块内置一份**常用时区的标准偏移回退表**，
并始终支持客户端已有的 ``tz_offset_minutes``（最精确，客户端每次查询都会带上）。
无效时区一律返回明确的 422，而不是悄悄按 UTC 计算。
"""

from __future__ import annotations

import base64
import binascii
import uuid
from collections import defaultdict
from datetime import date as date_cls
from datetime import datetime, timedelta, timezone, tzinfo
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from ..core.errors import ApiError, ErrorCode
from ..core.logger import get_logger
from ..core.timeutil import ensure_utc, utcnow
from ..models import ActivitySegment, Device, User, UserApplication
from ..schemas.common import to_iso
from ..schemas.statistics import (
    DAYS_PAGE_SIZE,
    DEFAULT_SESSION_LIMIT,
    DEVICE_ALL,
    DISPLAY_MERGE_GAP_SECONDS,
    MAX_QUERY_DAYS,
    MAX_SESSION_LIMIT,
    OVERLAP_WARNING_ALL_DEVICES,
    TOP_APPS_IN_DAY,
    DaySummaryOut,
    DaySummaryPageOut,
    DeviceListOut,
    StatisticsAppOut,
    StatisticsDeviceOut,
    StatisticsSummaryOut,
    TimelineEntryOut,
    TimelineOut,
    UsageSessionOut,
    UsageSessionPageOut,
)
from .app_identity import AppIdentityIndex, ResolvedApp, distinct_raw_app_keys
from .stats_service import validate_offset

logger = get_logger(__name__)

#: 单次时间线最多回收的原始会话数（超出则标记 truncated，绝不静默截断）
MAX_TIMELINE_RAW_SESSIONS = 4000

#: ``zoneinfo`` 缺少 tzdata 时的回退表（**标准偏移**，不含夏令时）。
#: 只覆盖常见时区；带夏令时的地区请优先使用 ``tz_offset_minutes``。
_FALLBACK_OFFSETS: dict[str, int] = {
    "UTC": 0,
    "Asia/Shanghai": 480,
    "Asia/Chongqing": 480,
    "Asia/Harbin": 480,
    "Asia/Urumqi": 360,
    "Asia/Hong_Kong": 480,
    "Asia/Macau": 480,
    "Asia/Taipei": 480,
    "Asia/Tokyo": 540,
    "Asia/Seoul": 540,
    "Asia/Singapore": 480,
    "Asia/Kuala_Lumpur": 480,
    "Asia/Bangkok": 420,
    "Asia/Jakarta": 420,
    "Asia/Kolkata": 330,
    "Asia/Dubai": 240,
    "Europe/London": 0,
    "Europe/Paris": 60,
    "Europe/Berlin": 60,
    "Europe/Moscow": 180,
    "America/New_York": -300,
    "America/Chicago": -360,
    "America/Denver": -420,
    "America/Los_Angeles": -480,
    "America/Sao_Paulo": -180,
    "Australia/Sydney": 600,
    "Pacific/Auckland": 720,
}


class ResolvedTimezone:
    """解析后的时区：tzinfo + 展示名 + 当前偏移分钟。"""

    __slots__ = ("tz", "label", "offset_minutes")

    def __init__(self, tz: tzinfo, label: str, offset_minutes: int) -> None:
        self.tz = tz
        self.label = label
        self.offset_minutes = offset_minutes


def _offset_label(offset_minutes: int) -> str:
    sign = "+" if offset_minutes >= 0 else "-"
    total = abs(offset_minutes)
    return f"UTC{sign}{total // 60:02d}:{total % 60:02d}"


def resolve_timezone(timezone_name: str | None, offset_minutes: int | None) -> ResolvedTimezone:
    """把 ``timezone`` / ``tz_offset_minutes`` 解析成一个明确的时区。

    优先 IANA 名称；环境缺少 tzdata 时回退到内置常见时区表；
    两者都不行则**报错**（而不是悄悄按 UTC 计算，那会让"今天"整体错位）。
    """
    if timezone_name is not None and timezone_name.strip():
        key = timezone_name.strip()
        try:
            tz = ZoneInfo(key)
            offset = int((utcnow().astimezone(tz).utcoffset() or timedelta()).total_seconds() // 60)
            return ResolvedTimezone(tz, key, offset)
        except (ZoneInfoNotFoundError, ValueError, KeyError, OSError):
            pass

        fallback = _FALLBACK_OFFSETS.get(key)
        if fallback is None:
            lowered = key.lower()
            for candidate, value in _FALLBACK_OFFSETS.items():
                if candidate.lower() == lowered:
                    key, fallback = candidate, value
                    break
        if fallback is None:
            raise ApiError(
                ErrorCode.validation_error,
                f"不支持的时区：{timezone_name}",
                detail={
                    "hint": "请使用 IANA 时区名（例如 Asia/Shanghai），"
                    "或改用 tz_offset_minutes 直接指定相对 UTC 的分钟偏移。",
                },
            )
        return ResolvedTimezone(timezone(timedelta(minutes=fallback)), key, fallback)

    offset = validate_offset(0 if offset_minutes is None else offset_minutes)
    return ResolvedTimezone(timezone(timedelta(minutes=offset)), _offset_label(offset), offset)


class StatisticsWindow:
    """查询窗口：UTC 区间 + 覆盖的本地日期键。"""

    __slots__ = ("from_utc", "to_utc", "day_keys", "date_from", "date_to", "tz")

    def __init__(
        self,
        *,
        from_utc: datetime,
        to_utc: datetime,
        day_keys: list[str],
        date_from: str,
        date_to: str,
        tz: ResolvedTimezone,
    ) -> None:
        self.from_utc = from_utc
        self.to_utc = to_utc
        self.day_keys = day_keys
        self.date_from = date_from
        self.date_to = date_to
        self.tz = tz

    @property
    def single_day(self) -> bool:
        return self.date_from == self.date_to


def _parse_date(value: str, *, field: str) -> date_cls:
    try:
        return date_cls.fromisoformat(value.strip())
    except (ValueError, AttributeError):
        raise ApiError(
            ErrorCode.validation_error, f"{field} 必须是 YYYY-MM-DD 格式的日期"
        ) from None


def _local_midnight(day: date_cls, tz: tzinfo) -> datetime:
    return datetime(day.year, day.month, day.day, tzinfo=tz)


def resolve_window(
    *,
    date_str: str | None,
    date_from: str | None,
    date_to: str | None,
    tz: ResolvedTimezone,
    now: datetime | None = None,
) -> StatisticsWindow:
    """解析日期参数。默认"该时区的今天"。"""
    if date_str and (date_from or date_to):
        raise ApiError(
            ErrorCode.validation_error, "date 与 date_from/date_to 不能同时使用"
        )

    if date_str:
        first = _parse_date(date_str, field="date")
        last = first
    elif date_from or date_to:
        if not date_from:
            date_from = date_to
        first = _parse_date(date_from, field="date_from")  # type: ignore[arg-type]
        last = _parse_date(date_to, field="date_to") if date_to else first
    else:
        local_today = ensure_utc(now or utcnow()).astimezone(tz.tz).date()
        first = last = local_today

    if last < first:
        raise ApiError(ErrorCode.validation_error, "date_to 不能早于 date_from")
    span = (last - first).days + 1
    if span > MAX_QUERY_DAYS:
        raise ApiError(
            ErrorCode.validation_error, f"单次查询最多 {MAX_QUERY_DAYS} 天（当前 {span} 天）"
        )

    from_utc = _local_midnight(first, tz.tz).astimezone(timezone.utc)
    to_utc = _local_midnight(last + timedelta(days=1), tz.tz).astimezone(timezone.utc)

    day_keys: list[str] = []
    cursor = first
    while cursor <= last:
        day_keys.append(cursor.isoformat())
        cursor += timedelta(days=1)

    return StatisticsWindow(
        from_utc=from_utc,
        to_utc=to_utc,
        day_keys=day_keys,
        date_from=first.isoformat(),
        date_to=last.isoformat(),
        tz=tz,
    )


class DeviceScope:
    """设备过滤范围：``device_ids`` 为 None 表示"全部设备"。"""

    __slots__ = ("device_ids", "selected", "is_all")

    def __init__(
        self, *, device_ids: list[uuid.UUID] | None, selected: Device | None, is_all: bool
    ) -> None:
        self.device_ids = device_ids
        self.selected = selected
        self.is_all = is_all


def resolve_device_scope(db: Session, *, user: User, device_id: str | None) -> DeviceScope:
    """解析 ``device_id``：不传或 ``all`` 表示全部设备。

    指定设备时必须**属于当前用户**，否则 404（不泄露他人设备是否存在）。
    """
    owned = list(db.scalars(select(Device).where(Device.user_id == user.id)))
    if device_id is None or device_id.strip() == "" or device_id.strip().lower() == DEVICE_ALL:
        return DeviceScope(
            device_ids=[d.id for d in owned], selected=None, is_all=True
        )

    try:
        parsed = uuid.UUID(device_id.strip())
    except (ValueError, AttributeError):
        raise ApiError(ErrorCode.invalid_uuid, "device_id 不是合法 UUID") from None

    found = next((d for d in owned if d.id == parsed), None)
    if found is None:
        # 别人的设备与不存在的设备返回同样的错误，避免探测
        raise ApiError(ErrorCode.device_not_found, "设备不存在或不属于当前账户")
    return DeviceScope(device_ids=[found.id], selected=found, is_all=False)


def _union_seconds(intervals: list[tuple[datetime, datetime]]) -> int:
    """时钟区间的并集秒数（重叠只算一次）。"""
    if not intervals:
        return 0
    ordered = sorted(intervals)
    total = 0.0
    cur_start, cur_end = ordered[0]
    for start, end in ordered[1:]:
        if start <= cur_end:
            if end > cur_end:
                cur_end = end
        else:
            total += (cur_end - cur_start).total_seconds()
            cur_start, cur_end = start, end
    total += (cur_end - cur_start).total_seconds()
    return int(round(total))


class UsageSession:
    """一条已裁剪到窗口内的会话。"""

    __slots__ = (
        "record_id",
        "device_id",
        "app_key",
        "category",
        "start",
        "end",
        "credited",
        #: 设备平台（windows / android / unknown）。
        #: 会话本身不带这个信息，由调用方在需要时填充（Phase 2B 的跨设备维度要用）。
        "platform",
    )

    def __init__(
        self,
        *,
        record_id: uuid.UUID,
        device_id: uuid.UUID,
        app_key: str,
        category: str,
        start: datetime,
        end: datetime,
        credited: int,
        platform: str = "unknown",
    ) -> None:
        self.record_id = record_id
        self.device_id = device_id
        self.app_key = app_key
        self.category = category
        self.start = start
        self.end = end
        self.credited = credited
        self.platform = platform

    @property
    def wall_seconds(self) -> float:
        return max(0.0, (self.end - self.start).total_seconds())


def _load_sessions(
    db: Session,
    *,
    user_id: uuid.UUID,
    window: StatisticsWindow,
    device_ids: list[uuid.UUID] | None,
    app_keys: list[str] | None = None,
    limit: int | None = None,
    after: tuple[datetime, uuid.UUID] | None = None,
) -> list[ActivitySegment]:
    stmt = select(ActivitySegment).where(
        ActivitySegment.user_id == user_id,
        ActivitySegment.started_at < window.to_utc,
        (ActivitySegment.ended_at.is_(None)) | (ActivitySegment.ended_at > window.from_utc),
    )
    if device_ids is not None:
        if not device_ids:
            return []
        stmt = stmt.where(ActivitySegment.device_id.in_(device_ids))
    if app_keys:
        # 用 IN 而不是等值：一个统一应用可能由多个原始名合并而来
        # （``com.tencent.mm`` + ``com.tencent.mm:tools`` …），
        # 只匹配其中一个会漏掉其余记录。
        stmt = stmt.where(ActivitySegment.app_key.in_(app_keys))
    if after is not None:
        cursor_start, cursor_id = after
        stmt = stmt.where(
            (ActivitySegment.started_at > cursor_start)
            | (
                (ActivitySegment.started_at == cursor_start)
                & (ActivitySegment.id > cursor_id)
            )
        )
    stmt = stmt.order_by(ActivitySegment.started_at.asc(), ActivitySegment.id.asc())
    if limit is not None:
        stmt = stmt.limit(limit)
    return list(db.scalars(stmt))


def resolve_app_filter(
    db: Session, *, user_id: uuid.UUID, app_id: str | None
) -> list[str] | None:
    """把请求里的 ``app_id`` 展开成需要匹配的原始名列表。

    返回 ``None`` 表示"不按应用过滤"。

    前端传回的是**统一键**，而库里存的是原始名，所以这里必须展开：
    点「微信」时要把 ``com.tencent.mm`` 与 ``com.tencent.mm:tools`` 都算上。
    展开依赖该账户的原始名全集（有索引，代价很低）。
    """
    if not app_id:
        return None
    index = AppIdentityIndex.load(db, user_id=user_id)
    return index.matching_raw_keys(app_id, distinct_raw_app_keys(db, user_id=user_id))


def _to_sessions(rows: list[ActivitySegment], window: StatisticsWindow) -> list[UsageSession]:
    """裁剪到窗口，并按窗口重叠比例折算计入秒数（与 stats_service 口径一致）。"""
    now = utcnow()
    out: list[UsageSession] = []
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
        credited = active if total_wall <= 0 else int(round(active * overlap / total_wall))
        out.append(
            UsageSession(
                record_id=row.id,
                device_id=row.device_id,
                app_key=row.app_key,
                category=row.category or "other",
                start=start,
                end=end,
                credited=max(0, credited),
            )
        )
    return out


def _effective_seconds(group: list[UsageSession]) -> int:
    """一组同 (设备, 应用) 会话的**去重后**时长。

    先算区间并集去掉重叠，再按这一组的"活跃占比"折算；
    无重叠时并集 == 各段之和，结果与逐条相加完全一致（不改变既有口径）。
    """
    credited = sum(s.credited for s in group)
    if credited <= 0:
        return 0
    wall_total = sum(s.wall_seconds for s in group)
    if wall_total <= 0:
        return credited
    union = float(_union_seconds([(s.start, s.end) for s in group]))
    if union >= wall_total:
        return credited
    return int(round(credited * union / wall_total))


def _group_by_device_app(
    sessions: list[UsageSession],
) -> dict[tuple[uuid.UUID, str], list[UsageSession]]:
    grouped: dict[tuple[uuid.UUID, str], list[UsageSession]] = defaultdict(list)
    for s in sessions:
        grouped[(s.device_id, s.app_key)].append(s)
    return grouped


def _identity_index(db: Session, *, user_id: uuid.UUID) -> AppIdentityIndex:
    """构造该用户的应用身份索引。

    归一化实现集中在 ``app_identity``，**与 ``stats_service``（MCP 侧）共用**，
    这样"网页显示 1 条微信、MCP 显示 4 条"这种漂移从结构上不可能发生
    （见 docs/45 第 1.3 节的审计结论）。

    每次请求重建索引（不跨请求缓存），代价是 3 条小查询，
    换来定稿要求的"映射保存后立即生效"。
    """
    return AppIdentityIndex.load(db, user_id=user_id)


def _device_map(db: Session, *, user_id: uuid.UUID) -> dict[uuid.UUID, Device]:
    return {
        d.id: d for d in db.scalars(select(Device).where(Device.user_id == user_id))
    }


def _device_name(device: Device | None, device_id: uuid.UUID) -> str:
    if device is None or not device.device_name:
        return str(device_id)
    return device.device_name


def _last_synced_at(
    db: Session, *, user_id: uuid.UUID, device_ids: list[uuid.UUID] | None
) -> datetime | None:
    stmt = select(func.max(ActivitySegment.server_received_at)).where(
        ActivitySegment.user_id == user_id
    )
    if device_ids is not None:
        if not device_ids:
            return None
        stmt = stmt.where(ActivitySegment.device_id.in_(device_ids))
    value = db.scalar(stmt)
    return ensure_utc(value) if value else None


def list_devices(
    db: Session, *, user: User, current_device_id: uuid.UUID | None = None
) -> DeviceListOut:
    rows = list(
        db.scalars(
            select(Device).where(Device.user_id == user.id).order_by(Device.created_at.asc())
        )
    )
    return DeviceListOut(
        items=[
            StatisticsDeviceOut(
                id=d.id,
                name=_device_name(d, d.id),
                platform=d.platform or "unknown",
                model_name=d.model_name,
                last_seen_at=to_iso(ensure_utc(d.last_seen_at)) if d.last_seen_at else None,
                revoked=bool(d.revoked_at),
                is_current=current_device_id is not None and d.id == current_device_id,
            )
            for d in rows
        ]
    )


def _summary_rows(
    db: Session, *, user: User, window: StatisticsWindow, scope: DeviceScope
) -> tuple[list[StatisticsAppOut], int, int, int]:
    """汇总的核心聚合：返回 ``(apps, total, session_count, raw_session_count)``。

    先按 ``(设备, 归一后应用)`` 分组再算时长，因此：

    * 同一设备上 ``com.tencent.mm`` 与 ``com.tencent.mm:tools`` 的重叠区间只算一次；
    * 不同设备之间仍然**求和不去重**（保持既有口径，见 docs/43 第三节）。

    ``/statistics/summary``、``/statistics/apps`` 与 ``/statistics/days`` 全部走这里，
    所以三处永远不会出现"同一个应用三个时长"的情况。
    """
    rows = _load_sessions(db, user_id=user.id, window=window, device_ids=scope.device_ids)
    sessions = _to_sessions(rows, window)
    index = _identity_index(db, user_id=user.id)

    grouped: dict[tuple[uuid.UUID, str], list[UsageSession]] = defaultdict(list)
    identities: dict[str, ResolvedApp] = {}
    raws_by_key: dict[str, set[str]] = defaultdict(set)
    for session in sessions:
        identity = index.resolve(session.app_key)
        grouped[(session.device_id, identity.key)].append(session)
        # 首次见到的身份即为该组的展示信息；同键必然同显示名/分类，
        # 这里只累积"这一组一共由哪些原始名合并而来"（可追溯性）
        identities.setdefault(identity.key, identity)
        raws_by_key[identity.key].add(session.app_key)

    per_app: dict[str, int] = defaultdict(int)
    per_app_sessions: dict[str, int] = defaultdict(int)
    for (_device_id, key), group in grouped.items():
        per_app[key] += _effective_seconds(group)
        per_app_sessions[key] += len(group)

    apps = [
        StatisticsAppOut(
            app_id=key,
            app_name=identities[key].display_name,
            category=identities[key].category,
            duration_seconds=seconds,
            session_count=per_app_sessions[key],
            raw_app_keys=sorted(raws_by_key[key]),
            recognized=identities[key].recognized,
            # 组内出现多个原始名，或该身份本身被归一过 → 视为"已归一"
            normalized=len(raws_by_key[key]) > 1 or identities[key].normalized,
            icon_key=identities[key].icon_key,
            catalog_id=identities[key].catalog_id,
        )
        for key, seconds in per_app.items()
    ]
    apps.sort(key=lambda a: (-a.duration_seconds, a.app_id))
    return apps, sum(per_app.values()), len(sessions), len(rows)


def get_summary(
    db: Session,
    *,
    user: User,
    window: StatisticsWindow,
    scope: DeviceScope,
) -> StatisticsSummaryOut:
    apps, total, session_count, _raw = _summary_rows(
        db, user=user, window=window, scope=scope
    )

    synced = _last_synced_at(db, user_id=user.id, device_ids=scope.device_ids)
    return StatisticsSummaryOut(
        date=window.date_from,
        date_from=window.date_from,
        date_to=window.date_to,
        timezone=window.tz.label,
        device_id=scope.selected.id if scope.selected else None,
        total_duration_seconds=total,
        session_count=session_count,
        app_count=len(apps),
        last_synced_at=to_iso(synced) if synced else None,
        apps=apps,
        overlap_warning=OVERLAP_WARNING_ALL_DEVICES if scope.is_all and len(scope.device_ids or []) > 1 else None,
    )


def get_apps(
    db: Session,
    *,
    user: User,
    window: StatisticsWindow,
    scope: DeviceScope,
) -> list[StatisticsAppOut]:
    """应用排行（时长降序）。与 summary 使用同一份聚合逻辑。"""
    return get_summary(db, user=user, window=window, scope=scope).apps


def _encode_cursor(start: datetime, record_id: uuid.UUID) -> str:
    raw = f"{ensure_utc(start).isoformat()}|{record_id}"
    return base64.urlsafe_b64encode(raw.encode("utf-8")).decode("ascii").rstrip("=")


def _decode_cursor(cursor: str) -> tuple[datetime, uuid.UUID]:
    padded = cursor + "=" * (-len(cursor) % 4)
    try:
        raw = base64.urlsafe_b64decode(padded.encode("ascii")).decode("utf-8")
        start_part, _, id_part = raw.partition("|")
        start = datetime.fromisoformat(start_part)
        record_id = uuid.UUID(id_part)
    except (binascii.Error, UnicodeDecodeError, ValueError, AttributeError):
        raise ApiError(ErrorCode.invalid_cursor, "cursor 无效，请从第一页重新开始") from None
    return ensure_utc(start), record_id


def get_sessions(
    db: Session,
    *,
    user: User,
    window: StatisticsWindow,
    scope: DeviceScope,
    app_id: str | None,
    cursor: str | None,
    limit: int,
) -> UsageSessionPageOut:
    """逐条会话分页（按开始时间升序；同一时间按记录 ID 升序，保证不重不漏）。"""
    safe_limit = max(1, min(limit, MAX_SESSION_LIMIT))
    after = _decode_cursor(cursor) if cursor else None

    rows = _load_sessions(
        db,
        user_id=user.id,
        window=window,
        device_ids=scope.device_ids,
        # 统一键 → 原始名集合（点「微信」要连它的子进程一起查出来）
        app_keys=resolve_app_filter(db, user_id=user.id, app_id=app_id),
        limit=safe_limit + 1,  # 多取一条判断是否还有下一页
        after=after,
    )
    has_more = len(rows) > safe_limit
    page_rows = rows[:safe_limit]
    sessions = _to_sessions(page_rows, window)

    devices = _device_map(db, user_id=user.id)
    index = _identity_index(db, user_id=user.id)

    items = []
    for s in sessions:
        identity = index.resolve(s.app_key)
        items.append(
            UsageSessionOut(
                id=s.record_id,
                local_record_id=str(s.record_id),
                device_id=s.device_id,
                device_name=_device_name(devices.get(s.device_id), s.device_id),
                platform=(devices[s.device_id].platform if s.device_id in devices else "unknown"),
                # app_id 给归一后的统一键，app_name 给统一显示名；
                # raw_app_key 保留原始进程名，界面详情里可以追溯
                app_id=identity.key,
                app_name=identity.display_name,
                category=identity.category if identity.recognized else s.category,
                raw_app_key=s.app_key,
                started_at=to_iso(s.start) or "",
                ended_at=to_iso(s.end),
                duration_seconds=s.credited,
            )
        )

    next_cursor = None
    if has_more and page_rows:
        last = page_rows[-1]
        next_cursor = _encode_cursor(
            ensure_utc(last.started_at),
            last.id,
        )

    return UsageSessionPageOut(
        date=window.date_from,
        date_from=window.date_from,
        date_to=window.date_to,
        timezone=window.tz.label,
        device_id=scope.selected.id if scope.selected else None,
        items=items,
        next_cursor=next_cursor,
    )


def get_timeline(
    db: Session,
    *,
    user: User,
    window: StatisticsWindow,
    scope: DeviceScope,
) -> TimelineOut:
    """全天时间线：同设备同应用、间隔 ≤ 60s 的相邻会话在**展示层**合并。

    合并只影响展示；1 条展示项的时长仍按该组区间的**并集**计算，
    因此中间那 20 秒的间隙不会被算进时长。

    「同应用」按**归一后**的键判断：手机的 ``com.tencent.mm`` 与
    ``com.tencent.mm:tools`` 是同一个应用，理应合成一条连续时间线，
    而不是在界面上出现两段"微信"。
    """
    rows = _load_sessions(
        db,
        user_id=user.id,
        window=window,
        device_ids=scope.device_ids,
        limit=MAX_TIMELINE_RAW_SESSIONS + 1,
    )
    truncated = len(rows) > MAX_TIMELINE_RAW_SESSIONS
    sessions = _to_sessions(rows[:MAX_TIMELINE_RAW_SESSIONS], window)
    normalizer = _identity_index(db, user_id=user.id)
    # 归一键随会话一起带出，供下面的分组与合并判断使用（不修改 UsageSession 本身）
    keys = {id(s): normalizer.resolve(s.app_key).key for s in sessions}
    sessions.sort(key=lambda s: (s.start, s.device_id, keys[id(s)]))

    devices = _device_map(db, user_id=user.id)
    gap = timedelta(seconds=DISPLAY_MERGE_GAP_SECONDS)

    items: list[TimelineEntryOut] = []
    group: list[UsageSession] = []

    def flush() -> None:
        if not group:
            return
        head = group[0]
        identity = normalizer.resolve(head.app_key)
        merged_start = min(s.start for s in group)
        merged_end = max(s.end for s in group)
        raws = sorted({s.app_key for s in group})
        devices_seen = {s.device_id for s in group}
        # 防御：不同设备的记录绝不合并（分组时已保证，这里再兜一层）
        if len(devices_seen) != 1:
            return
        items.append(
            TimelineEntryOut(
                app_id=identity.key,
                app_name=identity.display_name,
                category=identity.category if identity.recognized else head.category,
                device_id=head.device_id,
                device_name=_device_name(devices.get(head.device_id), head.device_id),
                started_at=to_iso(merged_start) or "",
                ended_at=to_iso(merged_end),
                duration_seconds=_union_seconds([(s.start, s.end) for s in group]),
                merged_session_count=len(group),
                raw_app_keys=raws,
                normalized=len(raws) > 1 or identity.normalized,
            )
        )

    for session in sessions:
        if group:
            prev = group[-1]
            same_target = (
                prev.device_id == session.device_id
                and keys[id(prev)] == keys[id(session)]
            )
            close_enough = (session.start - max(s.end for s in group)) <= gap
            if not (same_target and close_enough):
                flush()
                group = []
        group.append(session)
    flush()

    items.sort(key=lambda i: (i.started_at, i.device_id, i.app_id))
    # 合计仍按「设备 + 归一后应用」去重后求和（与 summary 一致）
    total_groups: dict[tuple[uuid.UUID, str], list[UsageSession]] = defaultdict(list)
    for session in sessions:
        total_groups[(session.device_id, keys[id(session)])].append(session)
    total = sum(_effective_seconds(group) for group in total_groups.values())
    if truncated:
        logger.warning(
            "timeline 超过 %s 条原始会话，已截断", MAX_TIMELINE_RAW_SESSIONS
        )

    return TimelineOut(
        date=window.date_from,
        date_from=window.date_from,
        date_to=window.date_to,
        timezone=window.tz.label,
        device_id=scope.selected.id if scope.selected else None,
        items=items,
        total_duration_seconds=total,
        overlap_warning=(
            OVERLAP_WARNING_ALL_DEVICES if scope.is_all and len(scope.device_ids or []) > 1 else None
        ),
    )


def get_day_summaries(
    db: Session,
    *,
    user: User,
    scope: DeviceScope,
    tz: ResolvedTimezone,
    before: date_cls | None,
    limit: int,
    today: date_cls | None = None,
) -> DaySummaryPageOut:
    """按日期**倒序**返回一页历史摘要（日期游标分页，供「往日记录」）。

    为什么用日期游标而不是偏移量
    ----------------------------
    偏移量会让"翻页期间又同步了新的一天"这种事情把整个序列错位（重复或漏项）。
    日期游标 ``before`` 是**不包含的上界**，天然稳定：新增的今天永远在游标之前，
    不影响已翻过的页。

    查询代价
    --------
    一次只查 ``limit`` 天（最大 7），且只取汇总需要的列，不碰时间线、不碰会话明细。
    界面初次进入**不调用**本接口（定稿第七节：历史默认折叠）。

    ``has_more`` 的判定：多取一天（``limit + 1``）来判断，
    且**不早于**该账户最早的一条记录 —— 否则"早就没有更早数据了"却一直显示
    「加载更早的 7 天」，用户会一直点下去。
    """
    safe_limit = max(1, min(limit, DAYS_PAGE_SIZE))
    local_today = today or ensure_utc(utcnow()).astimezone(tz.tz).date()
    # 默认从"今天"往前（不包含 before 指定日；未指定则不排除任何一天）
    upper = before if before is not None else local_today + timedelta(days=1)

    # 该账户最早有数据的那一天：翻到它就该停
    earliest = db.scalar(
        select(func.min(ActivitySegment.started_at)).where(
            ActivitySegment.user_id == user.id
        )
    )
    earliest_day: date_cls | None = None
    if earliest is not None:
        earliest_day = ensure_utc(earliest).astimezone(tz.tz).date()

    if earliest_day is None:
        # 该账户一条记录都没有：返回**空页**而不是 7 个空行。
        # 界面据 has_more=false 显示"还没有使用记录"，不会出现"7 天都是 0 分钟"的假象。
        return DaySummaryPageOut(
            items=[],
            next_before=None,
            has_more=False,
            timezone=tz.label,
            device_id=scope.selected.id if scope.selected else None,
        )

    # 收集候选日期：从 upper-1 起往前取，直到拿到 safe_limit+1 天或触及最早一天
    window_days: list[date_cls] = []
    cursor = upper - timedelta(days=1)
    while len(window_days) < safe_limit + 1:
        if cursor < earliest_day:
            break
        window_days.append(cursor)
        cursor -= timedelta(days=1)
    if not window_days:
        return DaySummaryPageOut(
            items=[],
            next_before=None,
            has_more=False,
            timezone=tz.label,
            device_id=scope.selected.id if scope.selected else None,
        )

    has_more = len(window_days) > safe_limit
    page_days = window_days[:safe_limit]

    # 一次性把这一页的区间拉出来（连续区间 = 一个查询窗口），避免 N+1 次查询
    span = resolve_window(
        date_str=None,
        date_from=page_days[-1].isoformat(),
        date_to=page_days[0].isoformat(),
        tz=tz,
    )
    rows = _load_sessions(
        db, user_id=user.id, window=span, device_ids=scope.device_ids
    )
    sessions = _to_sessions(rows, span)
    index = _identity_index(db, user_id=user.id)

    # 把每条会话按"它所在的本地日期"归位
    per_day: dict[str, list[UsageSession]] = defaultdict(list)
    for session in sessions:
        # 跨午夜的会话会被切成两条（见到的是裁剪后的 start/end），
        # 这里按 start 归属它主要所在的那一天：与 resolve_window 的切分口径一致。
        day_key = session.start.astimezone(tz.tz).date().isoformat()
        per_day[day_key].append(session)

    items: list[DaySummaryOut] = []
    for day in page_days:
        key = day.isoformat()
        day_sessions = per_day.get(key, [])
        if not day_sessions:
            # 没有数据的日子也要返回（界面显示"这天没有记录"），
            # 但 has_data=false，前端不会把它当作"0 分钟"来画。
            items.append(DaySummaryOut(date=key, has_data=False))
            continue

        grouped: dict[tuple[uuid.UUID, str], list[UsageSession]] = defaultdict(list)
        identities: dict[str, ResolvedApp] = {}
        raws_by_key: dict[str, set[str]] = defaultdict(set)
        for session in day_sessions:
            identity = index.resolve(session.app_key)
            grouped[(session.device_id, identity.key)].append(session)
            identities.setdefault(identity.key, identity)
            raws_by_key[identity.key].add(session.app_key)

        per_app: dict[str, int] = defaultdict(int)
        for (_device_id, app_key), group in grouped.items():
            per_app[app_key] += _effective_seconds(group)

        top = sorted(per_app.items(), key=lambda kv: (-kv[1], kv[0]))[:TOP_APPS_IN_DAY]
        items.append(
            DaySummaryOut(
                date=key,
                active_seconds=sum(per_app.values()),
                device_count=len({s.device_id for s in day_sessions}),
                top_apps=[
                    StatisticsAppOut(
                        app_id=app_key,
                        app_name=identities[app_key].display_name,
                        category=identities[app_key].category,
                        duration_seconds=seconds,
                        raw_app_keys=sorted(raws_by_key[app_key]),
                        recognized=identities[app_key].recognized,
                        normalized=len(raws_by_key[app_key]) > 1 or identities[app_key].normalized,
                        icon_key=identities[app_key].icon_key,
                        catalog_id=identities[app_key].catalog_id,
                    )
                    for app_key, seconds in top
                ],
                has_data=True,
            )
        )

    # next_before 必须取**本页最后返回的那一天**，而不是多取来判断 has_more 的那一天：
    # 下一页的语义是"早于 next_before"，用它才能接着本页往下、不重不漏。
    next_before = page_days[-1].isoformat() if has_more else None
    return DaySummaryPageOut(
        items=items,
        next_before=next_before,
        has_more=has_more,
        timezone=tz.label,
        device_id=scope.selected.id if scope.selected else None,
    )


__all__ = [
    "DEFAULT_SESSION_LIMIT",
    "DeviceScope",
    "MAX_SESSION_LIMIT",
    "ResolvedTimezone",
    "StatisticsWindow",
    "UsageSession",
    "get_apps",
    "get_day_summaries",
    "get_sessions",
    "get_summary",
    "get_timeline",
    "list_devices",
    "resolve_device_scope",
    "resolve_timezone",
    "resolve_window",
]

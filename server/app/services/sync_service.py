"""同步服务：批量上传（push）与增量拉取（pull）。

幂等性
------
* 活动段：``(user_id, id)`` 是复合主键，``id`` 是客户端生成的稳定 UUID。
  重复上传同一 UUID 只会命中同一行 → 不可能产生重复数据。
* 每日用量：``(user_id, device_id, local_day)`` 是复合主键，同步语义是
  **整行快照覆盖**而不是秒数累加 → 重传不会重复累计。
* 应用库：``(user_id, app_key)`` 是复合主键。

冲突策略（严格按需求）
----------------------
* 活动段：同一 UUID 视为同一记录，``updated_at`` 较新者胜（Last-Write-Wins）。
* 每日用量：按 ``device_id + local_day`` 唯一，用**最新完整快照覆盖**，绝不累加。
* 应用库：用户手工分类（``user_overridden``）优先于内置分类，
  即使内置分类的记录时间更新也不能覆盖人工选择。

事务边界
--------
整个批次在**一个事务**里完成：要么全部写入并记入变更日志，要么全部回滚。
这样"客户端收到 200 但服务端只写了一半"的情况不会出现。
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass, field

from sqlalchemy import func, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from ..core.config import Settings
from ..core.errors import ApiError, ErrorCode
from ..core.logger import get_logger
from ..core.timeutil import ensure_utc, utcnow
from ..models import (
    ENTITY_ACTIVITY_SEGMENT,
    ENTITY_APPLICATION,
    ENTITY_DAILY_USAGE,
    ENTITY_TYPES,
    ActivitySegment,
    DailyUsage,
    Device,
    SyncLog,
    User,
    UserApplication,
)
from ..schemas.sync import (
    ActivitySegmentIn,
    ActivitySegmentOut,
    AppRecordIn,
    AppRecordOut,
    DailyUsageIn,
    DailyUsageOut,
    PullResponse,
    PushRequest,
    PushResponse,
    RejectedRecord,
)

logger = get_logger(__name__)


@dataclass
class _BatchStats:
    accepted_activity: int = 0
    accepted_daily: int = 0
    accepted_apps: int = 0
    rejected: list[RejectedRecord] = field(default_factory=list)
    max_seq: int = 0


def _record_change(
    db: Session,
    *,
    user_id: uuid.UUID,
    entity_type: str,
    record_key: str,
) -> int:
    """写一条变更日志并返回其自增序号（用作 ``change_seq`` 游标）。"""
    log = SyncLog(
        user_id=user_id,
        entity_type=entity_type,
        record_key=record_key,
        op="upsert",
        changed_at=utcnow(),
    )
    db.add(log)
    db.flush()  # 拿到自增主键
    return int(log.seq)


# ---------------------------------------------------------------------------
# push
# ---------------------------------------------------------------------------


def push(
    db: Session,
    *,
    user: User,
    device: Device,
    payload: PushRequest,
    settings: Settings,
) -> PushResponse:
    """批量上传。返回逐类计数与被拒绝记录明细。

    每条记录包在一个 SAVEPOINT 里：单条失败（例如并发唯一冲突）只拒绝这一条，
    不会把整批数据一起回滚掉。整批最终仍是一个事务提交。
    """
    total = payload.total_records()
    if total > settings.sync_max_batch_size:
        raise ApiError(
            ErrorCode.batch_too_large,
            f"单批最多 {settings.sync_max_batch_size} 条，本次 {total} 条",
            detail={"max_batch_size": settings.sync_max_batch_size, "received": total},
        )

    stats = _BatchStats()

    for item in payload.activity_segments:
        _guarded(
            db,
            stats=stats,
            kind=ENTITY_ACTIVITY_SEGMENT,
            key=str(item.id),
            action=lambda: _push_activity_segment(
                db, user=user, device=device, item=item, stats=stats
            ),
        )
    for item in payload.daily_usage:
        _guarded(
            db,
            stats=stats,
            kind=ENTITY_DAILY_USAGE,
            key=f"{item.device_id}:{item.local_day}",
            action=lambda: _push_daily_usage(
                db, user=user, device=device, item=item, stats=stats
            ),
        )
    for item in payload.applications:
        _guarded(
            db,
            stats=stats,
            kind=ENTITY_APPLICATION,
            key=item.app_key,
            action=lambda: _push_application(db, user=user, item=item, stats=stats),
        )

    db.commit()

    cursor = current_cursor(db, user_id=user.id)
    if stats.max_seq > cursor:
        cursor = stats.max_seq

    accepted_total = (
        stats.accepted_activity + stats.accepted_daily + stats.accepted_apps
    )
    logger.info(
        "sync push user_id=%s device=%s accepted=%s rejected=%s",
        user.id,
        device.id,
        accepted_total,
        len(stats.rejected),
    )
    return PushResponse(
        batch_id=payload.batch_id,
        accepted_activity_segments=stats.accepted_activity,
        accepted_daily_usage=stats.accepted_daily,
        accepted_applications=stats.accepted_apps,
        accepted_total=accepted_total,
        rejected=stats.rejected,
        server_time=utcnow().isoformat().replace("+00:00", "Z"),
        cursor=cursor,
    )


def _guarded(
    db: Session,
    *,
    stats: _BatchStats,
    kind: str,
    key: str,
    action,
) -> None:
    """在 SAVEPOINT 中执行单条写入，失败只拒绝这一条。"""
    try:
        with db.begin_nested():
            action()
    except ApiError as exc:
        _reject(stats, kind=kind, key=key, code=exc.code, message=exc.message)
    except IntegrityError:
        logger.warning("单条写入冲突已跳过 kind=%s key=%s", kind, key)
        _reject(
            stats,
            kind=kind,
            key=key,
            code=ErrorCode.conflict,
            message="并发写入冲突，请重试该条记录",
        )
    except Exception:
        logger.exception("单条写入失败已跳过 kind=%s key=%s", kind, key)
        _reject(
            stats,
            kind=kind,
            key=key,
            code=ErrorCode.internal_error,
            message="服务端处理该条记录时出错",
        )



def _reject(stats: _BatchStats, *, kind: str, key: str, code: str, message: str) -> None:
    stats.rejected.append(
        RejectedRecord(kind=kind, key=key, code=code, message=message)
    )


def _push_activity_segment(
    db: Session,
    *,
    user: User,
    device: Device,
    item: ActivitySegmentIn,
    stats: _BatchStats,
) -> None:
    key = str(item.id)

    # 归属校验：本设备只能上传自己的记录，防止把数据错误地挂到别的设备上
    if item.device_id != device.id:
        _reject(
            stats,
            kind=ENTITY_ACTIVITY_SEGMENT,
            key=key,
            code=ErrorCode.invalid_batch,
            message="记录中的 device_id 与当前设备不一致",
        )
        return

    started = ensure_utc(item.started_at)
    ended = ensure_utc(item.ended_at) if item.ended_at is not None else None
    if ended is not None and ended < started:
        _reject(
            stats,
            kind=ENTITY_ACTIVITY_SEGMENT,
            key=key,
            code=ErrorCode.invalid_time_range,
            message="ended_at 早于 started_at",
        )
        return

    updated_at = ensure_utc(item.updated_at)
    existing = db.get(ActivitySegment, (user.id, item.id))

    if existing is None:
        row = ActivitySegment(
            user_id=user.id,
            id=item.id,
            device_id=device.id,
            app_key=item.app_key,
            category=item.category,
            started_at=started,
            ended_at=ended,
            active_seconds=item.active_seconds,
            end_reason=item.end_reason,
            created_at=ensure_utc(item.created_at),
            updated_at=updated_at,
            server_received_at=utcnow(),
        )
        db.add(row)
        db.flush()
    else:
        # Last-Write-Wins：只有更新的记录才允许覆盖
        if updated_at > ensure_utc(existing.updated_at):
            existing.device_id = device.id
            existing.app_key = item.app_key
            existing.category = item.category
            existing.started_at = started
            existing.ended_at = ended
            existing.active_seconds = item.active_seconds
            existing.end_reason = item.end_reason
            existing.updated_at = updated_at
            existing.server_received_at = utcnow()

    seq = _record_change(
        db, user_id=user.id, entity_type=ENTITY_ACTIVITY_SEGMENT, record_key=key
    )
    segment = db.get(ActivitySegment, (user.id, item.id))
    if segment is not None:
        segment.change_seq = seq
    stats.max_seq = max(stats.max_seq, seq)
    stats.accepted_activity += 1


def _push_daily_usage(
    db: Session,
    *,
    user: User,
    device: Device,
    item: DailyUsageIn,
    stats: _BatchStats,
) -> None:
    key = f"{item.device_id}:{item.local_day}"

    if item.device_id != device.id:
        _reject(
            stats,
            kind=ENTITY_DAILY_USAGE,
            key=key,
            code=ErrorCode.invalid_batch,
            message="记录中的 device_id 与当前设备不一致",
        )
        return

    updated_at = ensure_utc(item.updated_at)
    existing = db.get(DailyUsage, (user.id, device.id, item.local_day))

    if existing is None:
        db.add(
            DailyUsage(
                user_id=user.id,
                device_id=device.id,
                local_day=item.local_day,
                timezone_offset_minutes=item.timezone_offset_minutes,
                session_seconds=item.session_seconds,
                active_seconds=item.active_seconds,
                idle_seconds=item.idle_seconds,
                first_active_at=ensure_utc(item.first_active_at)
                if item.first_active_at
                else None,
                last_active_at=ensure_utc(item.last_active_at)
                if item.last_active_at
                else None,
                updated_at=updated_at,
                server_received_at=utcnow(),
            )
        )
        db.flush()
    else:
        # 整行快照覆盖（>= 让"重传同一份快照"成为幂等空操作，而不是被忽略）
        if updated_at >= ensure_utc(existing.updated_at):
            existing.timezone_offset_minutes = item.timezone_offset_minutes
            # 关键：直接赋值为快照值，**不是** existing.xxx += item.xxx
            existing.session_seconds = item.session_seconds
            existing.active_seconds = item.active_seconds
            existing.idle_seconds = item.idle_seconds
            existing.first_active_at = (
                ensure_utc(item.first_active_at) if item.first_active_at else None
            )
            existing.last_active_at = (
                ensure_utc(item.last_active_at) if item.last_active_at else None
            )
            existing.updated_at = updated_at
            existing.server_received_at = utcnow()

    seq = _record_change(
        db, user_id=user.id, entity_type=ENTITY_DAILY_USAGE, record_key=key
    )
    row = db.get(DailyUsage, (user.id, device.id, item.local_day))
    if row is not None:
        row.change_seq = seq
    stats.max_seq = max(stats.max_seq, seq)
    stats.accepted_daily += 1


def _push_application(
    db: Session,
    *,
    user: User,
    item: AppRecordIn,
    stats: _BatchStats,
) -> None:
    key = item.app_key
    updated_at = ensure_utc(item.updated_at)
    existing = db.get(UserApplication, (user.id, item.app_key))

    if existing is None:
        db.add(
            UserApplication(
                user_id=user.id,
                app_key=item.app_key,
                display_name=item.display_name,
                category=item.category,
                user_overridden=item.user_overridden,
                updated_at=updated_at,
                server_received_at=utcnow(),
            )
        )
        db.flush()
    else:
        incoming_overridden = bool(item.user_overridden)
        existing_overridden = bool(existing.user_overridden)
        if existing_overridden and not incoming_overridden:
            # 人工分类优先：内置分类即使更新也不覆盖
            pass
        elif incoming_overridden and not existing_overridden:
            existing.display_name = item.display_name
            existing.category = item.category
            existing.user_overridden = True
            existing.updated_at = updated_at
            existing.server_received_at = utcnow()
        elif updated_at >= ensure_utc(existing.updated_at):
            existing.display_name = item.display_name
            existing.category = item.category
            existing.user_overridden = incoming_overridden
            existing.updated_at = updated_at
            existing.server_received_at = utcnow()

    seq = _record_change(
        db, user_id=user.id, entity_type=ENTITY_APPLICATION, record_key=key
    )
    row = db.get(UserApplication, (user.id, item.app_key))
    if row is not None:
        row.change_seq = seq
    stats.max_seq = max(stats.max_seq, seq)
    stats.accepted_apps += 1


# ---------------------------------------------------------------------------
# pull
# ---------------------------------------------------------------------------


def current_cursor(db: Session, *, user_id: uuid.UUID) -> int:
    """该用户当前的最大游标（没有数据时为 0）。"""
    value = db.scalar(
        select(func.max(SyncLog.seq)).where(SyncLog.user_id == user_id)
    )
    return int(value or 0)


def pull(
    db: Session,
    *,
    user: User,
    cursor: int,
    limit: int,
    device_ids: list[uuid.UUID] | None = None,
) -> PullResponse:
    """增量拉取该用户 ``change_seq > cursor`` 的记录。

    只返回**当前用户**的数据——隔离由 ``WHERE user_id = ?`` 保证。
    默认返回该用户全部设备的数据（新设备可据此完成首次全量对齐）；
    传 ``device_ids`` 可只拉指定设备。
    """
    if cursor < 0:
        raise ApiError(ErrorCode.invalid_cursor, "cursor 不能为负数")

    per_type = max(1, limit)
    segments = list(
        db.scalars(
            select(ActivitySegment)
            .where(
                ActivitySegment.user_id == user.id,
                ActivitySegment.change_seq.is_not(None),
                ActivitySegment.change_seq > cursor,
                *([ActivitySegment.device_id.in_(device_ids)] if device_ids else []),
            )
            .order_by(ActivitySegment.change_seq.asc())
            .limit(per_type)
        )
    )
    daily = list(
        db.scalars(
            select(DailyUsage)
            .where(
                DailyUsage.user_id == user.id,
                DailyUsage.change_seq.is_not(None),
                DailyUsage.change_seq > cursor,
                *([DailyUsage.device_id.in_(device_ids)] if device_ids else []),
            )
            .order_by(DailyUsage.change_seq.asc())
            .limit(per_type)
        )
    )
    apps = list(
        db.scalars(
            select(UserApplication)
            .where(
                UserApplication.user_id == user.id,
                UserApplication.change_seq.is_not(None),
                UserApplication.change_seq > cursor,
            )
            .order_by(UserApplication.change_seq.asc())
            .limit(per_type)
        )
    )

    has_more = any(len(rows) >= per_type for rows in (segments, daily, apps))
    seqs = [int(r.change_seq) for r in (*segments, *daily, *apps) if r.change_seq]
    next_cursor = max(seqs) if seqs else cursor

    return PullResponse(
        cursor=next_cursor,
        has_more=has_more,
        activity_segments=[_segment_out(r) for r in segments],
        daily_usage=[_daily_out(r) for r in daily],
        applications=[_app_out(r) for r in apps],
        server_time=utcnow().isoformat().replace("+00:00", "Z"),
    )


def _iso(value) -> str | None:
    if value is None:
        return None
    return ensure_utc(value).isoformat().replace("+00:00", "Z")


def _segment_out(row: ActivitySegment) -> ActivitySegmentOut:
    return ActivitySegmentOut(
        id=row.id,
        device_id=row.device_id,
        app_key=row.app_key,
        category=row.category,
        started_at=_iso(row.started_at) or "",
        ended_at=_iso(row.ended_at),
        active_seconds=row.active_seconds,
        end_reason=row.end_reason,
        created_at=_iso(row.created_at) or "",
        updated_at=_iso(row.updated_at) or "",
    )


def _daily_out(row: DailyUsage) -> DailyUsageOut:
    return DailyUsageOut(
        device_id=row.device_id,
        local_day=row.local_day,
        timezone_offset_minutes=row.timezone_offset_minutes,
        session_seconds=row.session_seconds,
        active_seconds=row.active_seconds,
        idle_seconds=row.idle_seconds,
        first_active_at=_iso(row.first_active_at),
        last_active_at=_iso(row.last_active_at),
        updated_at=_iso(row.updated_at) or "",
    )


def _app_out(row: UserApplication) -> AppRecordOut:
    return AppRecordOut(
        app_key=row.app_key,
        display_name=row.display_name,
        category=row.category,
        user_overridden=row.user_overridden,
        updated_at=_iso(row.updated_at) or "",
    )


__all__ = ["ENTITY_TYPES", "current_cursor", "pull", "push"]

"""应用目录服务（Phase 2A）：统一应用与别名的增删改查。

职责边界
--------
* **只动两张新表**（``application_catalog`` / ``application_aliases``），
  绝不修改 ``activity_segments`` 与 ``user_applications``
  ⇒ 历史数据无需重传，旧客户端零影响（docs/45 第 1.4 节）。
* 所有查询都带 ``user_id``，隔离是**结构保证**而不是靠调用方自觉。
* 目录里的时长只统计**近 N 天**（默认 30），避免为了显示一个数字去扫全表。

"保存即生效"靠什么
------------------
归一化不缓存：每次统计请求都用 :class:`AppIdentityIndex` 重新读一遍
别名与目录（3 条小查询）。所以用户点完保存，下一次刷新就是新名字，
不需要重启服务、也不需要客户端重传。
"""

from __future__ import annotations

import uuid
from collections import defaultdict
from datetime import timedelta

from sqlalchemy import func, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from ..core.errors import ApiError, ErrorCode
from ..core.logger import get_logger
from ..core.timeutil import ensure_utc, utcnow
from ..models import (
    CATALOG_SOURCE_BUILTIN,
    CATALOG_SOURCE_USER,
    MATCH_TYPE_MANUAL,
    ActivitySegment,
    ApplicationAlias,
    ApplicationCatalog,
    Device,
    User,
)
from ..schemas.applications import (
    AliasOut,
    AliasUpsertRequest,
    CatalogCreateRequest,
    CatalogEntryOut,
    CatalogListOut,
    CatalogUpdateRequest,
    UnrecognizedItemOut,
    UnrecognizedListOut,
)
from . import app_normalization
from .app_identity import AppIdentityIndex

logger = get_logger(__name__)

#: 目录时长统计窗口（天）
DEFAULT_WINDOW_DAYS = 30


# ---------------------------------------------------------------------------
# 读取
# ---------------------------------------------------------------------------


def _recent_usage(
    db: Session, *, user_id: uuid.UUID, window_days: int
) -> dict[str, tuple[int, int, set[str]]]:
    """近 N 天每个**原始名**的 (秒数, 段数, 平台集合)。

    一次查询取回，之后在内存里按归一化键聚合。数据量是"应用个数"级别，
    不做 N+1 查询。
    """
    since = utcnow() - timedelta(days=max(1, window_days))
    rows = db.execute(
        select(
            ActivitySegment.app_key,
            func.sum(ActivitySegment.active_seconds),
            func.count(),
            ActivitySegment.device_id,
        )
        .where(
            ActivitySegment.user_id == user_id,
            ActivitySegment.started_at >= since,
        )
        .group_by(ActivitySegment.app_key, ActivitySegment.device_id)
    ).all()

    platforms = {
        d.id: (d.platform or "unknown")
        for d in db.scalars(select(Device).where(Device.user_id == user_id))
    }

    agg: dict[str, list] = {}
    for app_key, seconds, count, device_id in rows:
        bucket = agg.setdefault(app_key, [0, 0, set()])
        bucket[0] += int(seconds or 0)
        bucket[1] += int(count or 0)
        bucket[2].add(platforms.get(device_id, "unknown"))
    return {k: (v[0], v[1], v[2]) for k, v in agg.items()}


def list_catalog(
    db: Session, *, user: User, window_days: int = DEFAULT_WINDOW_DAYS
) -> CatalogListOut:
    """列出本账户的统一应用（含别名与窗口内时长）。

    ``items`` 里既有**用户建过目录行**的应用，也有**仅靠内置规则归并**出来的应用
    （``auto_grouped=True``）——否则用户第一次打开整理界面会看不到「微信」，
    而它明明就在数据里。
    """
    index = AppIdentityIndex.load(db, user_id=user.id)
    usage = _recent_usage(db, user_id=user.id, window_days=window_days)

    # 归一化键 -> 累积
    groups: dict[str, CatalogEntryOut] = {}
    raws_by_key: dict[str, set[str]] = defaultdict(set)
    platforms_by_key: dict[str, set[str]] = defaultdict(set)

    for raw, (seconds, count, platforms) in usage.items():
        identity = index.resolve(raw)
        entry = groups.get(identity.key)
        if entry is None:
            entry = CatalogEntryOut(
                # 统一键可能不是 UUID（内置推导的应用），此处的 id 用占位，
                # 真实可编辑的目录 id 在下面用 aliases/catalog_id 覆盖
                id=identity.catalog_id or uuid.uuid5(uuid.NAMESPACE_URL, identity.key),
                # app_key 就是"统一键"，前端拿它做合并目标（见 schema 注释）
                app_key=identity.key,
                display_name=identity.display_name,
                category=identity.category,
                icon_key=identity.icon_key,
                source=(
                    CATALOG_SOURCE_USER if identity.catalog_id is not None else CATALOG_SOURCE_BUILTIN
                ),
                auto_grouped=identity.catalog_id is None,
            )
            groups[identity.key] = entry
        entry.total_seconds += seconds
        entry.segment_count += count
        raws_by_key[identity.key].add(raw)
        platforms_by_key[identity.key] |= platforms

    # 补上"还没有任何数据"的目录行（用户在整理界面刚建的）
    for row in index.catalog_rows():
        key = str(row.id)
        if key in groups:
            continue
        groups[key] = CatalogEntryOut(
            id=row.id,
            app_key=key,
            display_name=row.display_name,
            category=row.category,
            icon_key=row.icon_key,
            source=row.source,
            auto_grouped=False,
        )

    # 别名明细：把数据库里显式建过的别名挂上去
    alias_by_catalog: dict[str, list[AliasOut]] = defaultdict(list)
    for alias in index.alias_rows():
        alias_by_catalog[str(alias.catalog_id)].append(
            AliasOut(
                id=alias.id,
                raw_app_key=alias.raw_app_key,
                platform=alias.platform,
                match_type=alias.match_type,
                priority=alias.priority,
            )
        )
    for key, entry in groups.items():
        entry.aliases = sorted(
            alias_by_catalog.get(key, []), key=lambda a: (a.priority, a.raw_app_key)
        )
        # 显式别名 + 由内置规则归并进来的原始名，去重后给出完整列表，
        # 界面「查看该统一应用包含的所有原始名称」直接用它
        explicit = {alias.raw_app_key for alias in entry.aliases}
        entry.raw_app_keys = sorted(explicit | raws_by_key.get(key, set()))
        entry.raw_app_key_count = len(entry.raw_app_keys)
        entry.platforms = sorted(platforms_by_key.get(key, set()))

    items = sorted(groups.values(), key=lambda e: (-e.total_seconds, e.display_name))
    unrecognized = sum(
        1 for raw in usage if not index.resolve(raw).recognized
    )
    return CatalogListOut(
        items=items,
        unrecognized_count=unrecognized,
        window_days=window_days,
        timezone="UTC",
    )


def list_unrecognized(
    db: Session, *, user: User, window_days: int = DEFAULT_WINDOW_DAYS
) -> UnrecognizedListOut:
    """未识别的原始名（内置表没收录、用户也没整理过）。

    对每一项额外给出**建议目标**：若"去除子进程后缀"后能命中内置表，
    界面就能直接提示"归入 微信"，用户点一下即可，不用手打名字。
    """
    index = AppIdentityIndex.load(db, user_id=user.id)
    usage = _recent_usage(db, user_id=user.id, window_days=window_days)

    items: list[UnrecognizedItemOut] = []
    for raw, (seconds, count, platforms) in usage.items():
        identity = index.resolve(raw)
        if identity.recognized:
            continue

        suggestion = None
        stripped = app_normalization.strip_subprocess_suffix(raw)
        if stripped and stripped != raw:
            # 去掉子进程后缀后能命中内置表 → 给出建议
            builtin = app_normalization.lookup_builtin(stripped)
            if builtin is not None:
                suggestion = builtin

        items.append(
            UnrecognizedItemOut(
                raw_app_key=raw,
                platform=sorted(platforms)[0] if len(platforms) == 1 else None,
                total_seconds=seconds,
                segment_count=count,
                suggested_app_key=suggestion.key if suggestion else None,
                suggested_display_name=suggestion.display_name if suggestion else None,
                suggested_category=suggestion.category if suggestion else None,
            )
        )

    items.sort(key=lambda i: (-i.total_seconds, i.raw_app_key))
    return UnrecognizedListOut(
        items=items, total=len(items), window_days=window_days
    )


# ---------------------------------------------------------------------------
# 写入
# ---------------------------------------------------------------------------


def _get_owned_catalog(
    db: Session, *, user: User, catalog_id: uuid.UUID
) -> ApplicationCatalog:
    """取目录行，且必须属于当前账户。

    别人的 id 与不存在的 id 返回**同一个** 404，避免被用来探测
    "某个 id 是否存在"（与设备接口的既有做法一致）。
    """
    row = db.scalar(
        select(ApplicationCatalog).where(
            ApplicationCatalog.id == catalog_id,
            ApplicationCatalog.user_id == user.id,
        )
    )
    if row is None:
        raise ApiError(ErrorCode.catalog_not_found, "统一应用不存在或不属于当前账户")
    return row


def _get_owned_alias(db: Session, *, user: User, alias_id: uuid.UUID) -> ApplicationAlias:
    row = db.scalar(
        select(ApplicationAlias).where(
            ApplicationAlias.id == alias_id,
            ApplicationAlias.user_id == user.id,
        )
    )
    if row is None:
        raise ApiError(ErrorCode.alias_not_found, "别名不存在或不属于当前账户")
    return row


def _find_catalog_by_display_name(
    db: Session, *, user_id: uuid.UUID, display_name: str
) -> ApplicationCatalog | None:
    return db.scalar(
        select(ApplicationCatalog).where(
            ApplicationCatalog.user_id == user_id,
            ApplicationCatalog.display_name == display_name,
        )
    )


def _ensure_catalog_for_key(
    db: Session, *, user: User, target_app_key: str
) -> ApplicationCatalog:
    """把"某个统一键"物化成一条目录行（不存在则建）。

    场景：用户要把 ``com.tencent.mm:tools`` 合并到界面上已有的「微信」，
    而「微信」只是内置规则推导出来的分组、并没有目录行。
    这里按内置表建一条 ``source=builtin`` 的目录行，之后别名就有地方可指。
    """
    index = AppIdentityIndex.load(db, user_id=user.id)
    existing_catalog = index.get_catalog_for_key(target_app_key)
    if existing_catalog is not None:
        return existing_catalog

    identity = index.resolve(target_app_key)
    display_name = identity.display_name or target_app_key

    # 同名目录行已存在（用户之前建过）→ 直接复用，避免撞唯一约束
    same_name = _find_catalog_by_display_name(
        db, user_id=user.id, display_name=display_name
    )
    if same_name is not None:
        return same_name

    row = ApplicationCatalog(
        user_id=user.id,
        display_name=display_name,
        category=identity.category or "other",
        icon_key=identity.icon_key,
        source=CATALOG_SOURCE_USER if not identity.recognized else CATALOG_SOURCE_BUILTIN,
        created_at=utcnow(),
        updated_at=utcnow(),
    )
    db.add(row)
    db.flush()

    # 同时给"目标键本身"建一条别名 —— 这一步是必需的：
    # 只有主包名有了别名，同一族的子进程（``:tools`` / ``:push`` …）
    # 才会在解析时通过"内置主包名 → 别名"这条路径一起跟随过来。
    # 少了它，「微信」会被拆成"主包名组"和"子进程组"两条（实测踩到过）。
    _write_alias(
        db,
        user=user,
        raw_app_key=target_app_key,
        catalog=row,
        platform=None,
        match_type=MATCH_TYPE_MANUAL,
    )
    return row


def create_catalog(
    db: Session, *, user: User, payload: CatalogCreateRequest
) -> ApplicationCatalog:
    """新建统一应用，可同时把若干原始名归入它。"""
    existing = _find_catalog_by_display_name(
        db, user_id=user.id, display_name=payload.display_name
    )
    if existing is not None:
        raise ApiError(
            ErrorCode.catalog_duplicate,
            f"已存在名为「{payload.display_name}」的统一应用",
            detail={"catalog_id": str(existing.id)},
        )

    now = utcnow()
    row = ApplicationCatalog(
        user_id=user.id,
        display_name=payload.display_name,
        category=payload.category,
        icon_key=payload.icon_key,
        source=CATALOG_SOURCE_USER,
        created_at=now,
        updated_at=now,
    )
    db.add(row)
    try:
        db.flush()
    except IntegrityError as exc:
        db.rollback()
        raise ApiError(
            ErrorCode.catalog_duplicate, f"已存在名为「{payload.display_name}」的统一应用"
        ) from exc

    for raw in payload.raw_app_keys:
        _write_alias(
            db,
            user=user,
            raw_app_key=raw,
            catalog=row,
            platform=None,
            match_type=MATCH_TYPE_MANUAL,
        )

    db.commit()
    db.refresh(row)
    logger.info(
        "新建统一应用 user_id=%s catalog=%s aliases=%s",
        user.id,
        row.id,
        len(payload.raw_app_keys),
    )
    return row


def update_catalog(
    db: Session, *, user: User, catalog_id: uuid.UUID, payload: CatalogUpdateRequest
) -> ApplicationCatalog:
    row = _get_owned_catalog(db, user=user, catalog_id=catalog_id)

    if payload.display_name is not None and payload.display_name != row.display_name:
        clash = _find_catalog_by_display_name(
            db, user_id=user.id, display_name=payload.display_name
        )
        if clash is not None and clash.id != row.id:
            raise ApiError(
                ErrorCode.catalog_duplicate,
                f"已存在名为「{payload.display_name}」的统一应用",
                detail={"catalog_id": str(clash.id)},
            )
        row.display_name = payload.display_name
    if payload.category is not None:
        row.category = payload.category
    if payload.icon_key is not None:
        row.icon_key = payload.icon_key

    row.updated_at = utcnow()
    db.commit()
    db.refresh(row)
    return row


def delete_catalog(db: Session, *, user: User, catalog_id: uuid.UUID) -> int:
    """删除统一应用；其别名随外键级联删除。

    删除后原来被归并的原始名会**回到内置名或原始名显示**
    （定稿验收项："删除映射后可以恢复原始显示"）——
    因为归一化每次请求重算，不存在残留缓存。
    """
    row = _get_owned_catalog(db, user=user, catalog_id=catalog_id)
    removed_aliases = db.scalar(
        select(func.count())
        .select_from(ApplicationAlias)
        .where(ApplicationAlias.catalog_id == row.id)
    )
    db.delete(row)
    db.commit()
    logger.info(
        "删除统一应用 user_id=%s catalog=%s aliases=%s",
        user.id,
        catalog_id,
        removed_aliases,
    )
    return int(removed_aliases or 0)


def _write_alias(
    db: Session,
    *,
    user: User,
    raw_app_key: str,
    catalog: ApplicationCatalog,
    platform: str | None,
    match_type: str = MATCH_TYPE_MANUAL,
) -> ApplicationAlias:
    """写入或覆盖一条别名。

    同一原始名已经指向**别的**统一应用时，视为"用户改主意了"——
    直接改指而不是报错（报错会让用户必须先删除旧映射，多一步无意义操作）。
    真正需要拒绝的是跨账户操作，那由 user_id 条件保证。
    """
    existing = db.scalar(
        select(ApplicationAlias).where(
            ApplicationAlias.user_id == user.id,
            ApplicationAlias.raw_app_key == raw_app_key,
        )
    )
    now = utcnow()
    if existing is not None:
        existing.catalog_id = catalog.id
        existing.platform = platform
        existing.match_type = match_type
        existing.updated_at = now
        db.flush()
        return existing

    row = ApplicationAlias(
        user_id=user.id,
        catalog_id=catalog.id,
        raw_app_key=raw_app_key,
        platform=platform,
        match_type=match_type,
        created_at=now,
        updated_at=now,
    )
    db.add(row)
    db.flush()
    return row


def upsert_alias(
    db: Session, *, user: User, payload: AliasUpsertRequest
) -> ApplicationAlias:
    """合并到已有应用 / 新建应用并归入。"""
    if payload.catalog_id is not None:
        catalog = _get_owned_catalog(db, user=user, catalog_id=payload.catalog_id)
    elif payload.target_app_key is not None:
        catalog = _ensure_catalog_for_key(
            db, user=user, target_app_key=payload.target_app_key
        )
    elif payload.display_name:
        catalog = _find_catalog_by_display_name(
            db, user_id=user.id, display_name=payload.display_name
        )
        if catalog is None:
            now = utcnow()
            catalog = ApplicationCatalog(
                user_id=user.id,
                display_name=payload.display_name,
                category=payload.category or "other",
                icon_key=payload.icon_key,
                source=CATALOG_SOURCE_USER,
                created_at=now,
                updated_at=now,
            )
            db.add(catalog)
            db.flush()
    else:
        raise ApiError(
            ErrorCode.validation_error,
            "必须指定 catalog_id / target_app_key / display_name 之一",
        )

    row = _write_alias(
        db,
        user=user,
        raw_app_key=payload.raw_app_key,
        catalog=catalog,
        platform=payload.platform,
    )
    db.commit()
    db.refresh(row)
    logger.info(
        "别名映射 user_id=%s raw=%s -> catalog=%s",
        user.id,
        payload.raw_app_key,
        catalog.id,
    )
    return row


def delete_alias(db: Session, *, user: User, alias_id: uuid.UUID) -> str:
    """撤销一条映射，返回被撤销的原始名（便于界面提示）。"""
    row = _get_owned_alias(db, user=user, alias_id=alias_id)
    raw = row.raw_app_key
    db.delete(row)
    db.commit()
    logger.info("撤销别名 user_id=%s raw=%s", user.id, raw)
    return raw


def segment_started_within(db: Session, *, user_id: uuid.UUID, days: int) -> int:
    """辅助：窗口内是否有任何记录（界面用来区分"没数据"与"没识别"）。"""
    since = ensure_utc(utcnow()) - timedelta(days=max(1, days))
    value = db.scalar(
        select(func.count())
        .select_from(ActivitySegment)
        .where(ActivitySegment.user_id == user_id, ActivitySegment.started_at >= since)
    )
    return int(value or 0)


__all__ = [
    "DEFAULT_WINDOW_DAYS",
    "create_catalog",
    "delete_alias",
    "delete_catalog",
    "list_catalog",
    "list_unrecognized",
    "segment_started_within",
    "update_catalog",
    "upsert_alias",
]

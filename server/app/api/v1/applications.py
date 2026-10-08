"""应用目录接口（Phase 2A，契约见 docs/45 第 4.1 节）。

```
GET    /api/v1/applications/catalog
GET    /api/v1/applications/unrecognized
POST   /api/v1/applications/catalog
PATCH  /api/v1/applications/catalog/{id}
DELETE /api/v1/applications/catalog/{id}
POST   /api/v1/applications/aliases
DELETE /api/v1/applications/aliases/{id}
```

身份：网页（HttpOnly 会话 Cookie）与客户端（Bearer）都可用
—— ``CurrentUserOrWeb``。**写**操作额外要求 CSRF 对照值，
因为网页侧是 Cookie 认证，必须防跨站提交；
客户端带 ``Authorization`` 头时天然不受 CSRF 影响，
但为保持单一入口，这条要求对两者一致（客户端只需多发一个头）。

隔离：每个查询与写入都带 ``user_id``，别人的 id 一律 404
（不泄露"该 id 是否存在"）。
"""

from __future__ import annotations

import uuid
from typing import Annotated

from fastapi import APIRouter, Depends, Query, status
from sqlalchemy.orm import Session

from ...core.logger import get_logger
from ...database.session import get_db
from ...schemas.applications import (
    AliasOut,
    AliasUpsertRequest,
    CatalogCreateRequest,
    CatalogEntryOut,
    CatalogListOut,
    CatalogUpdateRequest,
    UnrecognizedListOut,
)
from ...schemas.auth import MessageOut
from ...security.deps import CurrentUserOrWeb, WebCsrf
from ...services import application_catalog_service as catalog_service

router = APIRouter(tags=["applications"])
logger = get_logger(__name__)

WindowDaysQuery = Annotated[
    int,
    Query(description="统计窗口天数（目录里的时长只覆盖这个窗口）", ge=1, le=365),
]


def _entry_out(db: Session, *, user, catalog) -> CatalogEntryOut:
    """单个目录行的响应（用于写操作的回执，便于界面立即更新）。"""
    listing = catalog_service.list_catalog(db, user=user)
    for item in listing.items:
        if item.id == catalog.id:
            return item
    # 刚建好、窗口内还没有数据时上面的列表可能不含它（已补目录行，兜底构造）
    return CatalogEntryOut(
        id=catalog.id,
        display_name=catalog.display_name,
        category=catalog.category,
        icon_key=catalog.icon_key,
        source=catalog.source,
    )


@router.get("/applications/catalog", response_model=CatalogListOut)
async def read_catalog(
    user: CurrentUserOrWeb,
    db: Annotated[Session, Depends(get_db)],
    window_days: WindowDaysQuery = catalog_service.DEFAULT_WINDOW_DAYS,
):
    """统一应用目录：显示名 / 分类 / 图标 / 别名 / 窗口内时长。"""
    return catalog_service.list_catalog(db, user=user, window_days=window_days)


@router.get("/applications/unrecognized", response_model=UnrecognizedListOut)
async def read_unrecognized(
    user: CurrentUserOrWeb,
    db: Annotated[Session, Depends(get_db)],
    window_days: WindowDaysQuery = catalog_service.DEFAULT_WINDOW_DAYS,
):
    """未识别的原始进程名，并给出"建议归入"的目标。"""
    return catalog_service.list_unrecognized(db, user=user, window_days=window_days)


@router.post(
    "/applications/catalog",
    response_model=CatalogEntryOut,
    status_code=status.HTTP_201_CREATED,
)
async def create_catalog(
    payload: CatalogCreateRequest,
    _csrf: WebCsrf,
    user: CurrentUserOrWeb,
    db: Annotated[Session, Depends(get_db)],
):
    """新建统一应用，可同时把若干原始名归入它。"""
    row = catalog_service.create_catalog(db, user=user, payload=payload)
    return _entry_out(db, user=user, catalog=row)


@router.patch("/applications/catalog/{catalog_id}", response_model=CatalogEntryOut)
async def update_catalog(
    catalog_id: uuid.UUID,
    payload: CatalogUpdateRequest,
    _csrf: WebCsrf,
    user: CurrentUserOrWeb,
    db: Annotated[Session, Depends(get_db)],
):
    """修改显示名 / 分类 / 图标。"""
    row = catalog_service.update_catalog(
        db, user=user, catalog_id=catalog_id, payload=payload
    )
    return _entry_out(db, user=user, catalog=row)


@router.delete("/applications/catalog/{catalog_id}", response_model=MessageOut)
async def delete_catalog(
    catalog_id: uuid.UUID,
    _csrf: WebCsrf,
    user: CurrentUserOrWeb,
    db: Annotated[Session, Depends(get_db)],
):
    """删除统一应用；其原始名回到内置名或原始名显示。"""
    removed = catalog_service.delete_catalog(db, user=user, catalog_id=catalog_id)
    return MessageOut(
        message=f"已删除该统一应用，并撤销 {removed} 条映射", revoked_sessions=0
    )


@router.post(
    "/applications/aliases", response_model=AliasOut, status_code=status.HTTP_201_CREATED
)
async def upsert_alias(
    payload: AliasUpsertRequest,
    _csrf: WebCsrf,
    user: CurrentUserOrWeb,
    db: Annotated[Session, Depends(get_db)],
):
    """新增 / 覆盖别名映射 —— 「合并到已有应用」与「新建并归入」都走这里。

    同一原始名再次提交会**改指**到新目标（等价于用户改主意），
    不会因为已存在就报错。
    """
    row = catalog_service.upsert_alias(db, user=user, payload=payload)
    return AliasOut(
        id=row.id,
        raw_app_key=row.raw_app_key,
        platform=row.platform,
        match_type=row.match_type,
        priority=row.priority,
    )


@router.delete("/applications/aliases/{alias_id}", response_model=MessageOut)
async def delete_alias(
    alias_id: uuid.UUID,
    _csrf: WebCsrf,
    user: CurrentUserOrWeb,
    db: Annotated[Session, Depends(get_db)],
):
    """撤销一条映射（恢复该原始名的原始显示）。"""
    raw = catalog_service.delete_alias(db, user=user, alias_id=alias_id)
    return MessageOut(message=f"已撤销映射：{raw}", revoked_sessions=0)


__all__ = ["router"]

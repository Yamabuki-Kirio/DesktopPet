"""同步接口。

```
POST /api/v1/sync/push
GET  /api/v1/sync/pull?cursor=...
```

两个接口都需要 ``X-Device-Id``：被撤销的设备在这里会被 ``device_revoked`` 挡住。
"""

from __future__ import annotations

import uuid
from typing import Annotated

from fastapi import APIRouter, Depends, Query
from sqlalchemy.orm import Session

from ...core.config import Settings, get_settings
from ...core.errors import ApiError, ErrorCode
from ...core.logger import get_logger
from ...database.session import get_db
from ...schemas.sync import PushRequest, PushResponse
from ...security.deps import CurrentDevice, CurrentUser
from ...services import sync_service

router = APIRouter(tags=["sync"])
logger = get_logger(__name__)


@router.post("/sync/push", response_model=PushResponse)
async def push(
    payload: PushRequest,
    user: CurrentUser,
    device: CurrentDevice,
    db: Annotated[Session, Depends(get_db)],
    settings: Annotated[Settings, Depends(get_settings)],
):
    """批量上传（幂等）。

    * 单批上限由 ``PETLIFE_SYNC_MAX_BATCH_SIZE`` 控制（默认 200）；
    * 重复上传相同 UUID 不会产生重复数据；
    * 每日用量是**整行快照覆盖**，重传不会重复累计；
    * 单条记录出错只拒绝那一条，并在 ``rejected`` 里给出原因。
    """
    return sync_service.push(db, user=user, device=device, payload=payload, settings=settings)


@router.get("/sync/pull")
async def pull(
    user: CurrentUser,
    device: CurrentDevice,
    db: Annotated[Session, Depends(get_db)],
    settings: Annotated[Settings, Depends(get_settings)],
    cursor: Annotated[int, Query(ge=0)] = 0,
    limit: Annotated[int | None, Query(ge=1, le=2000)] = None,
    device_ids: Annotated[list[uuid.UUID] | None, Query()] = None,
):
    """增量拉取 ``change_seq > cursor`` 的记录。

    默认返回当前账户**全部设备**的数据（新设备可据此完成首次对齐）；
    传 ``device_ids`` 可只拉指定设备。游标单调递增、只增不减。
    """
    if cursor < 0:
        raise ApiError(ErrorCode.invalid_cursor, "cursor 不能为负数")
    return sync_service.pull(
        db,
        user=user,
        cursor=cursor,
        limit=limit or settings.sync_pull_max_items,
        device_ids=device_ids,
    )


__all__ = ["router"]

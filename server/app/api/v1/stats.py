"""服务端统计接口。

```
GET /api/v1/stats/summary
GET /api/v1/stats/apps
GET /api/v1/stats/categories
GET /api/v1/stats/devices
```

**时区由客户端通过 ``tz_offset_minutes`` 指定**，服务端绝不按服务器本地时区算"今天"。
"""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends, Query
from sqlalchemy.orm import Session

from ...core.logger import get_logger
from ...database.session import get_db
from ...schemas.stats import (
    PERIOD_TODAY,
    AppUsageListOut,
    CategoryUsageListOut,
    DeviceUsageListOut,
    OverviewOut,
)
from ...security.deps import CurrentUser
from ...services import stats_service

router = APIRouter(tags=["stats"])
logger = get_logger(__name__)

PeriodQuery = Annotated[
    str,
    Query(
        description="统计区间：today / yesterday / 7d / 30d",
        pattern="^(today|yesterday|7d|30d)$",
    ),
]
OffsetQuery = Annotated[
    int,
    Query(
        description="客户端相对 UTC 的时区偏移（分钟），用于确定「今天」的边界",
        ge=-720,
        le=840,
    ),
]


@router.get("/stats/summary", response_model=OverviewOut)
async def summary(
    user: CurrentUser,
    db: Annotated[Session, Depends(get_db)],
    period: PeriodQuery = PERIOD_TODAY,
    tz_offset_minutes: OffsetQuery = 0,
):
    """总览：屏幕会话 / 活跃 / 空闲 / 应用使用时间 + 设备数 + 首次与最后活跃。"""
    return stats_service.get_summary(
        db, user=user, period=period, offset_minutes=tz_offset_minutes
    )


@router.get("/stats/devices", response_model=DeviceUsageListOut)
async def devices(
    user: CurrentUser,
    db: Annotated[Session, Depends(get_db)],
    period: PeriodQuery = PERIOD_TODAY,
    tz_offset_minutes: OffsetQuery = 0,
):
    """每台设备的使用时长 + 合计（**未做重叠去重**，响应里带提示）。"""
    return stats_service.get_devices(
        db, user=user, period=period, offset_minutes=tz_offset_minutes
    )


@router.get("/stats/apps", response_model=AppUsageListOut)
async def apps(
    user: CurrentUser,
    db: Annotated[Session, Depends(get_db)],
    period: PeriodQuery = PERIOD_TODAY,
    tz_offset_minutes: OffsetQuery = 0,
):
    """各应用使用时长（按应用使用时间倒序）。"""
    return stats_service.get_apps(
        db, user=user, period=period, offset_minutes=tz_offset_minutes
    )


@router.get("/stats/categories", response_model=CategoryUsageListOut)
async def categories(
    user: CurrentUser,
    db: Annotated[Session, Depends(get_db)],
    period: PeriodQuery = PERIOD_TODAY,
    tz_offset_minutes: OffsetQuery = 0,
):
    """各分类使用时长。"""
    return stats_service.get_categories(
        db, user=user, period=period, offset_minutes=tz_offset_minutes
    )


__all__ = ["router"]

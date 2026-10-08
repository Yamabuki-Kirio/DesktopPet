"""v1 路由汇总。"""

from __future__ import annotations

from fastapi import APIRouter

from . import (
    api_keys,
    applications,
    auth,
    devices,
    integrations,
    statistics,
    stats,
    sync,
    web_session,
)

api_router = APIRouter(prefix="/api/v1")
api_router.include_router(auth.router)
# GameLog「生活足迹」网页会话（HttpOnly Cookie + CSRF），见 docs/43 第六节
api_router.include_router(web_session.router)
api_router.include_router(devices.router)
# Phase 2：应用身份管理（统一应用目录 + 别名），见 docs/45
api_router.include_router(applications.router)
api_router.include_router(sync.router)
api_router.include_router(stats.router)
# Phase 4B：跨设备云端统计（按设备/日期查询逐条会话）
api_router.include_router(statistics.router)
api_router.include_router(statistics.integration_router)
api_router.include_router(api_keys.router)
api_router.include_router(integrations.router)

__all__ = ["api_router"]

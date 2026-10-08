"""FastAPI 应用装配。

启动顺序（与客户端一样强调"强依赖顺序"）：

1. 读配置（缺 JWT 密钥直接失败，绝不退化到弱默认值）
2. 初始化日志脱敏
3. 配置 Argon2id
4. 初始化数据库引擎
5. 挂中间件（request_id + 访问日志）
6. 挂统一错误处理器
7. 挂 v1 路由与 /health

数据库结构由 **Alembic 迁移** 负责，应用启动时**不**建表：
避免"开发环境 create_all 建的表和迁移脚本不一致"这类经典事故。
"""

from __future__ import annotations

import logging

from fastapi import FastAPI
from fastapi.responses import JSONResponse
from sqlalchemy import text

from .api.v1.router import api_router
from .core.config import Settings, get_settings
from .core.errors import install_error_handlers
from .core.logging import RequestContextMiddleware, setup_logging
from .core.timeutil import utcnow
from .database.session import get_engine, init_engine
from .security import passwords

VERSION = "0.2.0"


def create_app(settings: Settings | None = None) -> FastAPI:
    """构造应用（测试可直接传入自定义 Settings）。"""
    cfg = settings or get_settings()

    setup_logging(logging.DEBUG if cfg.environment == "development" else logging.INFO)

    passwords.configure(
        time_cost=cfg.argon2_time_cost,
        memory_cost=cfg.argon2_memory_cost,
        parallelism=cfg.argon2_parallelism,
    )

    init_engine(cfg.database_url, echo=cfg.database_echo)

    app = FastAPI(
        title=cfg.app_name,
        version=VERSION,
        description=(
            "PetLife 账户 / 设备 / 使用数据同步服务。\n\n"
            "隐私边界：**只接收应用使用时长与分类**；"
            "不接受窗口标题、URL、文档名、本地完整路径、截图或素材文件。"
        ),
        docs_url="/docs" if not cfg.is_production else None,
        redoc_url=None,
        openapi_url="/openapi.json" if not cfg.is_production else None,
    )

    app.add_middleware(RequestContextMiddleware)
    install_error_handlers(app)
    app.include_router(api_router)

    @app.get("/health", tags=["ops"])
    async def health() -> JSONResponse:
        """健康检查：同时探测数据库连通性。

        Docker Compose 与反向代理都用它做存活/就绪探测；
        数据库不可用时返回 503，让编排层能把实例摘掉。
        """
        db_ok = True
        detail = "ok"
        try:
            with get_engine().connect() as conn:
                conn.execute(text("SELECT 1"))
        except Exception as exc:  # pragma: no cover - 依赖真实故障
            db_ok = False
            detail = type(exc).__name__
        return JSONResponse(
            status_code=200 if db_ok else 503,
            content={
                "status": "ok" if db_ok else "degraded",
                "database": db_ok,
                "database_detail": detail,
                "environment": cfg.environment,
                "version": VERSION,
                "time": utcnow().isoformat().replace("+00:00", "Z"),
            },
        )

    @app.get("/", tags=["ops"])
    async def root() -> dict[str, str]:
        return {
            "service": cfg.app_name,
            "version": VERSION,
            "docs": "/docs" if not cfg.is_production else "disabled in production",
            "health": "/health",
        }

    return app


#: uvicorn 入口：``uvicorn app.main:app``
app = create_app()

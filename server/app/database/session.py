"""数据库引擎与会话。

* 生产：PostgreSQL（``postgresql+psycopg2://...``）
* 开发/测试：SQLite（``sqlite+pysqlite:///...``）

两种后端共用同一套模型与迁移，差异集中在连接参数上。
"""

from __future__ import annotations

from collections.abc import Iterator
from contextlib import contextmanager

from sqlalchemy import create_engine, event
from sqlalchemy.engine import Engine
from sqlalchemy.orm import Session, sessionmaker

_engine: Engine | None = None
_session_factory: sessionmaker[Session] | None = None


def build_engine(database_url: str, *, echo: bool = False) -> Engine:
    """按 URL 建引擎；SQLite 需要额外的兼容处理。"""
    kwargs: dict[str, object] = {"echo": echo, "future": True, "pool_pre_ping": True}

    if database_url.startswith("sqlite"):
        # TestClient 会在不同线程里使用同一连接。
        kwargs["connect_args"] = {"check_same_thread": False}

    engine = create_engine(database_url, **kwargs)  # type: ignore[arg-type]

    if database_url.startswith("sqlite"):

        @event.listens_for(engine, "connect")
        def _enable_sqlite_fk(dbapi_connection, _record):  # pragma: no cover - 驱动回调
            """SQLite 默认不启用外键，必须逐连接打开。"""
            cursor = dbapi_connection.cursor()
            cursor.execute("PRAGMA foreign_keys=ON")
            cursor.close()

    return engine


def init_engine(database_url: str, *, echo: bool = False) -> Engine:
    """初始化进程级引擎与会话工厂（幂等；重复调用会重建）。"""
    global _engine, _session_factory
    if _engine is not None:
        _engine.dispose()
    _engine = build_engine(database_url, echo=echo)
    _session_factory = sessionmaker(bind=_engine, autoflush=False, expire_on_commit=False)
    return _engine


def get_engine() -> Engine:
    if _engine is None:
        raise RuntimeError("数据库引擎尚未初始化，请先调用 init_engine()")
    return _engine


def get_session_factory() -> sessionmaker[Session]:
    if _session_factory is None:
        raise RuntimeError("数据库会话工厂尚未初始化，请先调用 init_engine()")
    return _session_factory


def dispose_engine() -> None:
    global _engine, _session_factory
    if _engine is not None:
        _engine.dispose()
    _engine = None
    _session_factory = None


def get_db() -> Iterator[Session]:
    """FastAPI 依赖：每个请求一个会话。"""
    factory = get_session_factory()
    session = factory()
    try:
        yield session
    finally:
        session.close()


@contextmanager
def session_scope() -> Iterator[Session]:
    """脚本/测试用的上下文管理器。

    注意：这里**不自动 commit**，由调用方决定事务边界，避免"以为提交了其实没有"。
    """
    factory = get_session_factory()
    session = factory()
    try:
        yield session
    finally:
        session.close()

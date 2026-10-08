"""Alembic 运行环境。

要点：
* URL 从应用配置读取（单一来源），不写在 alembic.ini 里；
* ``render_as_batch=True`` 让 SQLite 也能执行 ALTER（本地开发用 SQLite）；
* ``compare_type=True`` 让 autogenerate 能发现类型变更；
* 导入 ``app.models`` 保证 ``Base.metadata`` 里有全部表。
"""

from __future__ import annotations

from logging.config import fileConfig

from alembic import context
from sqlalchemy import create_engine, pool

import app.models  # noqa: F401  （导入以注册全部表）
from app.core.config import get_settings
from app.database.base import Base

config = context.config

if config.config_file_name is not None:
    # disable_existing_loggers=False：否则 alembic 的 logging 配置会把应用与 pytest
    # 已经装好的 logger 全部禁掉，导致进程内调用迁移后日志静默消失。
    fileConfig(config.config_file_name, disable_existing_loggers=False)

target_metadata = Base.metadata


def _database_url() -> str:
    """允许通过 -x db_url=... 覆盖（测试与 CI 用），否则取应用配置。"""
    override = context.get_x_argument(as_dictionary=True).get("db_url")
    if override:
        return override
    return get_settings().database_url


def run_migrations_offline() -> None:
    """离线模式：只生成 SQL，不连库。"""
    context.configure(
        url=_database_url(),
        target_metadata=target_metadata,
        literal_binds=True,
        dialect_opts={"paramstyle": "named"},
        render_as_batch=True,
        compare_type=True,
    )
    with context.begin_transaction():
        context.run_migrations()


def run_migrations_online() -> None:
    """在线模式：连库执行迁移。"""
    url = _database_url()
    connectable = create_engine(url, poolclass=pool.NullPool, future=True)
    with connectable.connect() as connection:
        context.configure(
            connection=connection,
            target_metadata=target_metadata,
            render_as_batch=True,
            compare_type=True,
        )
        with context.begin_transaction():
            context.run_migrations()
    connectable.dispose()


if context.is_offline_mode():
    run_migrations_offline()
else:
    run_migrations_online()

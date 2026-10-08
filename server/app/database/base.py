"""SQLAlchemy 声明式基类与命名约定。

显式命名约定有两个好处：
1. Alembic autogenerate 能稳定识别既有约束（否则 SQLite 上的匿名约束无法 drop/alter）；
2. 唯一约束与索引有可读名字，出问题时能直接从数据库报错定位到代码。
"""

from __future__ import annotations

from sqlalchemy import MetaData
from sqlalchemy.orm import DeclarativeBase

NAMING_CONVENTION = {
    "ix": "ix_%(table_name)s_%(column_0_N_name)s",
    "uq": "uq_%(table_name)s_%(column_0_N_name)s",
    "ck": "ck_%(table_name)s_%(constraint_name)s",
    "fk": "fk_%(table_name)s_%(column_0_N_name)s_%(referred_table_name)s",
    "pk": "pk_%(table_name)s",
}


class Base(DeclarativeBase):
    """所有 ORM 模型的基类。"""

    metadata = MetaData(naming_convention=NAMING_CONVENTION)

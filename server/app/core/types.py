"""自定义列类型。

``UTCDateTime`` 解决一个很实际的坑：PostgreSQL 用 ``timestamptz``、
SQLite 不保存时区，如果不做归一化，同一段代码在两个后端上会得到
naive / aware 混杂的 datetime，比较时直接抛 ``TypeError``。

约定：
* 写入：naive 视为 UTC；一律转换为 UTC。
* 读取：naive 补上 UTC；一律返回 aware UTC。
* 对 SQLite：落库前抹掉 tzinfo（SQLite 存不了），读取时再补回 UTC。
"""

from __future__ import annotations

from datetime import datetime
from typing import Any

from sqlalchemy import DateTime, TypeDecorator

from .timeutil import UTC, ensure_utc


class UTCDateTime(TypeDecorator[datetime]):
    """始终以 UTC 语义读写的 TIMESTAMP。"""

    impl = DateTime(timezone=True)
    cache_ok = True

    def process_bind_param(self, value: Any, dialect: Any) -> datetime | None:
        if value is None:
            return None
        if not isinstance(value, datetime):
            raise TypeError(f"UTCDateTime 只接受 datetime，收到 {type(value)!r}")
        normalized = ensure_utc(value)
        if dialect is None or dialect.name == "sqlite":
            # SQLite 不支持带时区的 TIMESTAMP，落库前去掉 tzinfo。
            return normalized.replace(tzinfo=None)
        return normalized

    def process_result_value(self, value: Any, dialect: Any) -> datetime | None:
        if value is None:
            return None
        if value.tzinfo is None:
            return value.replace(tzinfo=UTC)
        return value.astimezone(UTC)

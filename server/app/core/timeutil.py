"""时间工具：全服务端统一使用 UTC。

对外 API 一律返回 **ISO 8601 带 ``Z`` 的 UTC 时间**；
数据库统一存储 UTC（由 ``app/core/types.py`` 的 ``UTCDateTime`` 保证）。
"""

from __future__ import annotations

from datetime import datetime, timezone

UTC = timezone.utc


def utcnow() -> datetime:
    """当前 UTC 时间（带时区信息）。"""
    return datetime.now(UTC)


def ensure_utc(value: datetime) -> datetime:
    """把可能是 naive 的时间按 UTC 解释，并统一转成 aware UTC。

    SQLite 不保存时区信息；读取时若不补齐，跨后端比较会出现
    ``can't compare offset-naive and offset-aware datetimes``。
    """
    if value.tzinfo is None:
        return value.replace(tzinfo=UTC)
    return value.astimezone(UTC)


def to_iso8601(value: datetime | None) -> str | None:
    """序列化为 ``2026-09-27T12:00:00Z`` 形式。"""
    if value is None:
        return None
    return ensure_utc(value).isoformat().replace("+00:00", "Z")


def from_epoch_millis(millis: int) -> datetime:
    """客户端以毫秒时间戳上传，这里转成 aware UTC。"""
    return datetime.fromtimestamp(millis / 1000.0, tz=UTC)


def to_epoch_millis(value: datetime) -> int:
    return int(ensure_utc(value).timestamp() * 1000)

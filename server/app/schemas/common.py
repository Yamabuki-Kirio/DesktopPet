"""通用 schema：时间归一化、错误体、分页元信息。"""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Annotated, Any

from pydantic import BaseModel, BeforeValidator, ConfigDict, Field

from ..core.timeutil import ensure_utc


def _coerce_datetime(value: Any) -> Any:
    """把毫秒时间戳也接受为时间输入。

    客户端（Dart）内部用 epoch 毫秒，直接发数字最省事；
    同时保留 ISO 8601 字符串作为标准形式，两种都收。
    """
    if value is None:
        return None
    if isinstance(value, (int, float)):
        # 客户端可能传秒或毫秒；>= 1e11 视为毫秒（1973 年之后都是这个量级）
        seconds = value / 1000.0 if abs(value) >= 1e11 else float(value)
        return datetime.fromtimestamp(seconds, tz=timezone.utc)
    return value


#: 接受 ISO 8601 字符串或 epoch（秒/毫秒）
FlexibleDatetime = Annotated[datetime, BeforeValidator(_coerce_datetime)]


class StrictModel(BaseModel):
    """统一的 pydantic 配置：拒绝未知字段，避免客户端静默传了不该传的字段。"""

    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)


class ErrorBody(StrictModel):
    code: str
    message: str
    request_id: str
    detail: Any | None = None


class ErrorResponse(StrictModel):
    """统一错误体（仅用于 OpenAPI 文档展示）。"""

    error: ErrorBody


class PageMeta(StrictModel):
    has_more: bool = False
    returned: int = Field(default=0, ge=0)


def to_iso(value: datetime | None) -> str | None:
    """统一输出 ``...Z`` 形式的 UTC 时间。"""
    if value is None:
        return None
    return ensure_utc(value).isoformat().replace("+00:00", "Z")


def ok(**kwargs: Any) -> dict[str, Any]:
    """构造简单成功响应。"""
    return {"ok": True, **kwargs}

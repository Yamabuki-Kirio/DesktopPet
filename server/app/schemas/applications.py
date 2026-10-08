"""应用目录 schema（Phase 2A，契约见 docs/45 第四节）。

命名上刻意区分两个概念，避免调用方混淆：

* ``raw_app_key``：**原始**进程名 / 包名（``com.tencent.mm:tools``）
* ``app_key`` / ``app_id``：**统一键**（归一化之后的键，可直接用于过滤）
"""

from __future__ import annotations

import uuid

from pydantic import Field, field_validator

from .common import StrictModel

#: 统一键 / 原始名的长度上限（与 activity_segments.app_key 一致）
APP_KEY_MAX = 128
DISPLAY_NAME_MAX = 128
ICON_KEY_MAX = 64

#: 允许的平台（与 device.py 的 PLATFORM_CHOICES 保持一致，另允许"不限"）
PLATFORM_ANY = None
PLATFORM_CHOICES = ("windows", "android", "macos", "linux")


class AliasOut(StrictModel):
    id: uuid.UUID
    raw_app_key: str
    platform: str | None = None
    match_type: str = "manual"
    priority: int = 100


class CatalogEntryOut(StrictModel):
    id: uuid.UUID
    #: **统一键**：可直接作为 ``target_app_key`` 回传给
    #: ``POST /applications/aliases`` 完成"合并到已有应用"。
    #:
    #: 有它之后前端不必区分"这个人建的目录行"与"内置规则推导的分组"——
    #: 两种情况都能用同一个字段提交，服务端会自行物化目录行。
    app_key: str = ""
    display_name: str
    category: str = "other"
    icon_key: str | None = None
    source: str = "user"
    aliases: list[AliasOut] = Field(default_factory=list)
    #: 该统一应用在窗口内的时长合计（秒）
    total_seconds: int = 0
    segment_count: int = 0
    #: 合并进来的原始名个数（含未显式建别名的、由内置规则归并的）
    raw_app_key_count: int = 0
    #: 实际出现的原始名（用于界面展开"包含哪些原始名"）
    raw_app_keys: list[str] = Field(default_factory=list)
    #: 涉及平台（windows / android）
    platforms: list[str] = Field(default_factory=list)
    #: 窗口内有数据但尚未被用户整理过（由内置规则自动归并）
    auto_grouped: bool = False


class CatalogListOut(StrictModel):
    items: list[CatalogEntryOut] = Field(default_factory=list)
    #: 未识别原始名个数，界面据此显示「⚠ 发现 N 个未识别进程」
    unrecognized_count: int = 0
    #: 统计窗口（天）。目录里的时长只覆盖这个窗口，避免全表扫描。
    window_days: int = 30
    timezone: str = "UTC"


class UnrecognizedItemOut(StrictModel):
    raw_app_key: str
    platform: str | None = None
    total_seconds: int = 0
    segment_count: int = 0
    #: 若"去除子进程后缀"后能命中内置表，给出建议归入的目标
    suggested_app_key: str | None = None
    suggested_display_name: str | None = None
    suggested_category: str | None = None


class UnrecognizedListOut(StrictModel):
    items: list[UnrecognizedItemOut] = Field(default_factory=list)
    total: int = 0
    window_days: int = 30


class CatalogCreateRequest(StrictModel):
    """新建一个统一应用（可选同时把若干原始名归入它）。"""

    display_name: str = Field(min_length=1, max_length=DISPLAY_NAME_MAX)
    category: str = "other"
    icon_key: str | None = Field(default=None, max_length=ICON_KEY_MAX)
    #: 一并归入的原始名（整理界面"新建应用"时把当前进程带进来）
    raw_app_keys: list[str] = Field(default_factory=list, max_length=200)

    @field_validator("category")
    @classmethod
    def _check_category(cls, value: str) -> str:
        from .sync import _validate_category

        return _validate_category(value)

    @field_validator("raw_app_keys")
    @classmethod
    def _check_raw_keys(cls, values: list[str]) -> list[str]:
        out: list[str] = []
        for item in values:
            cleaned = _clean_app_key(item)
            if cleaned not in out:
                out.append(cleaned)
        return out


class CatalogUpdateRequest(StrictModel):
    """修改统一应用。只传需要改的字段。"""

    display_name: str | None = Field(default=None, min_length=1, max_length=DISPLAY_NAME_MAX)
    category: str | None = None
    icon_key: str | None = Field(default=None, max_length=ICON_KEY_MAX)

    @field_validator("category")
    @classmethod
    def _check_category(cls, value: str | None) -> str | None:
        if value is None:
            return None
        from .sync import _validate_category

        return _validate_category(value)


class AliasUpsertRequest(StrictModel):
    """新增 / 覆盖一条别名映射 —— 「合并到已有应用」走这里。

    三种目标方式**三选一**：

    1. ``catalog_id``：合并到已有的统一应用；
    2. ``target_app_key``：合并到某个已存在的统一键
       （例如界面上的「微信」，它由内置规则推导、还没有目录行 —— 服务端会自动物化目录行）；
    3. ``display_name``（+ ``category``）：新建一个统一应用并归入。
    """

    raw_app_key: str = Field(min_length=1, max_length=APP_KEY_MAX)
    catalog_id: uuid.UUID | None = None
    target_app_key: str | None = Field(default=None, max_length=APP_KEY_MAX)
    display_name: str | None = Field(default=None, max_length=DISPLAY_NAME_MAX)
    category: str | None = None
    icon_key: str | None = Field(default=None, max_length=ICON_KEY_MAX)
    platform: str | None = Field(default=None, max_length=32)

    @field_validator("raw_app_key")
    @classmethod
    def _check_raw(cls, value: str) -> str:
        return _clean_app_key(value)

    @field_validator("target_app_key")
    @classmethod
    def _check_target(cls, value: str | None) -> str | None:
        if value is None:
            return None
        return _clean_app_key(value)

    @field_validator("category")
    @classmethod
    def _check_category(cls, value: str | None) -> str | None:
        if value is None:
            return None
        from .sync import _validate_category

        return _validate_category(value)

    @field_validator("platform")
    @classmethod
    def _check_platform(cls, value: str | None) -> str | None:
        if value is None:
            return None
        normalized = value.strip().lower()
        if normalized not in PLATFORM_CHOICES:
            raise ValueError(f"platform 必须是 {PLATFORM_CHOICES} 之一或留空")
        return normalized


def _clean_app_key(value: str) -> str:
    cleaned = (value or "").strip()
    if not cleaned:
        raise ValueError("app_key 不能为空")
    if "\\" in cleaned or "/" in cleaned:
        raise ValueError("app_key 不得包含路径分隔符")
    return cleaned


__all__ = [
    "APP_KEY_MAX",
    "AliasOut",
    "AliasUpsertRequest",
    "CatalogCreateRequest",
    "CatalogEntryOut",
    "CatalogListOut",
    "CatalogUpdateRequest",
    "DISPLAY_NAME_MAX",
    "ICON_KEY_MAX",
    "PLATFORM_ANY",
    "PLATFORM_CHOICES",
    "UnrecognizedItemOut",
    "UnrecognizedListOut",
]

"""个人访问密钥（Personal Access Key）的请求/响应模型。

三条约定：

* 响应里**永远不会**出现 ``key_hash``；
* 明文密钥只在 ``POST /api/v1/api-keys`` 的响应里出现**一次**
  （``ApiKeyCreatedOut.key``），之后任何接口都只能看到 ``key_prefix``；
* ``key_prefix`` 是明文前 12 个字符（``plk_`` + 8 位），仅用于在列表里
  区分"这是哪把钥匙"，不足以还原密钥。
"""

from __future__ import annotations

from typing import TYPE_CHECKING

from pydantic import Field

from .common import StrictModel, to_iso

if TYPE_CHECKING:  # pragma: no cover - 仅类型标注，避免与 models 形成导入环
    from ..models import ApiKey


class ApiKeyCreateRequest(StrictModel):
    name: str = Field(
        min_length=1,
        max_length=64,
        description="便于日后识别的名字，例如「AstrBot」「家里那台」",
    )
    scopes: list[str] | None = Field(
        default=None,
        description="权限集合；当前只支持 stats:read（只读统计），不传即默认值",
    )


class ApiKeyOut(StrictModel):
    id: str
    name: str
    key_prefix: str
    scopes: list[str]
    created_at: str
    last_used_at: str | None = None
    revoked_at: str | None = None
    is_active: bool


class ApiKeyCreatedOut(ApiKeyOut):
    """创建响应：**唯一**出现明文密钥的地方。"""

    key: str = Field(description="完整密钥（plk_...），只返回这一次，请立即保存")


class ApiKeyListOut(StrictModel):
    items: list[ApiKeyOut]
    total: int


def api_key_to_out(record: ApiKey) -> ApiKeyOut:
    return ApiKeyOut(
        id=str(record.id),
        name=record.name,
        key_prefix=record.key_prefix,
        scopes=sorted(record.scope_set),
        created_at=to_iso(record.created_at) or "",
        last_used_at=to_iso(record.last_used_at),
        revoked_at=to_iso(record.revoked_at),
        is_active=record.is_active,
    )


def api_key_to_created(record: ApiKey, *, plaintext: str) -> ApiKeyCreatedOut:
    """把明文与记录组装成创建响应（**唯一**出现明文的地方）。"""
    base = api_key_to_out(record)
    return ApiKeyCreatedOut(**base.model_dump(), key=plaintext)


__all__ = [
    "ApiKeyCreateRequest",
    "ApiKeyCreatedOut",
    "ApiKeyListOut",
    "ApiKeyOut",
    "api_key_to_created",
    "api_key_to_out",
]

"""个人访问密钥（Personal Access Key）管理接口。

三个端点，**全部用用户 Access Token 鉴权**——密钥的生成/查看/撤销
属于"账户自助操作"，只能由本人在已登录的 Windows 客户端里做：

| 端点 | 用途 |
|---|---|
| ``POST /api/v1/api-keys`` | 生成密钥，**明文只在这个响应里出现一次** |
| ``GET /api/v1/api-keys`` | 列出本账户的密钥（只回显前缀，不含密钥与哈希） |
| ``DELETE /api/v1/api-keys/{key_id}`` | 撤销（幂等，只能撤自己的） |

MCP / AstrBot 侧**没有**任何生成或撤销密钥的能力：它只用
``X-API-Key`` 读统计，这样"AI 手里那把钥匙从哪来、怎么失效"始终由用户掌握。
"""

from __future__ import annotations

import uuid
from typing import Annotated

from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session

from ...database.session import get_db
from ...schemas.api_key import (
    ApiKeyCreateRequest,
    ApiKeyCreatedOut,
    ApiKeyListOut,
    ApiKeyOut,
    api_key_to_created,
    api_key_to_out,
)
from ...security.deps import CurrentUser
from ...services import api_key_service

router = APIRouter(tags=["api-keys"])


@router.post("/api-keys", response_model=ApiKeyCreatedOut, status_code=201)
async def create_api_key(
    payload: ApiKeyCreateRequest,
    user: CurrentUser,
    db: Annotated[Session, Depends(get_db)],
):
    """生成一把只读统计用的个人访问密钥。

    * 权限固定为只读统计（``stats:read``），传入其它 scope 会被拒绝；
    * 服务端只保存 SHA-256 哈希与前 12 字符前缀，**明文不再可查**；
    * 忘了保存就只能撤销后重新生成。
    """
    plaintext, record = api_key_service.create_key(
        db, user=user, name=payload.name, scopes=payload.scopes
    )
    return api_key_to_created(record, plaintext=plaintext)


@router.get("/api-keys", response_model=ApiKeyListOut)
async def list_api_keys(user: CurrentUser, db: Annotated[Session, Depends(get_db)]):
    """列出当前账户的全部密钥（含已撤销的，便于确认"确实撤销了"）。"""
    items = api_key_service.list_keys(db, user=user)
    return ApiKeyListOut(items=[api_key_to_out(k) for k in items], total=len(items))


@router.delete("/api-keys/{key_id}", response_model=ApiKeyOut)
async def revoke_api_key(
    key_id: uuid.UUID,
    user: CurrentUser,
    db: Annotated[Session, Depends(get_db)],
):
    """撤销密钥（幂等）。撤销后立即失效，使用中的 MCP 会收到 401。

    只能撤销自己的密钥；别人的密钥统一返回 ``api_key_not_found``，
    不泄露"该密钥是否存在"。
    """
    record = api_key_service.revoke_key(db, user=user, key_id=key_id)
    return api_key_to_out(record)


__all__ = ["router"]

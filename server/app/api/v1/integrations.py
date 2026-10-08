"""Phase 3 集成接口。

两类调用方，两套完全独立的鉴权，**不要混用**：

| 端点 | 鉴权 | 调用方 | 状态 |
|---|---|---|---|
| ``POST /integrations/telegram/link-code`` | 用户 Access Token | Windows 客户端 | 绑定流程 |
| ``GET /integrations/telegram/bindings`` | 用户 Access Token | Windows 客户端 | 绑定流程 |
| ``DELETE /integrations/telegram/bindings/{binding_id}`` | 用户 Access Token | Windows 客户端 | 绑定流程 |
| ``POST /integrations/telegram/consume-link-code`` | 集成服务令牌 | AstrBot | 绑定流程 |
| ``GET /integrations/telegram/context`` | 集成服务令牌 | AstrBot | 绑定流程 |
| ``GET /integrations/stats/{summary,apps,categories,devices}`` | **个人访问密钥** | MCP | 数据读取 |
| ``GET /integrations/compare`` | **个人访问密钥** | MCP | 数据读取 |
| ``GET /integrations/sync-status`` | **个人访问密钥** | MCP | 数据读取 |

为什么数据读取改成个人访问密钥（本版改动）
----------------------------------------------

原设计让 MCP 依赖 ``telegram_user_id`` + AstrBot 注入的动态请求头来确定用户，
这要求接入方必须能按会话注入请求头——现实中不保证做得到，会话复用还会串号。

现在：**密钥本身标识用户**。调用方只需带 ``X-API-Key: plk_...``，
用户由服务端从密钥记录推导。因此：

* 统计接口的入参里**没有、也不接受** ``user_id`` / Telegram ID / 任意身份字段；
* 密钥只能读只读统计（``stats:read``），撤销后立即失效；
* Telegram 绑定相关端点仍然保留（已部署的绑定流程可以继续用），
  但它**不再是 MCP 的必要流程**。

统计数字全部委托给 ``stats_service`` / ``integration_stats_service``，
因此与 Windows 客户端、与 ``/api/v1/stats/*`` 的数字**必然一致**。
"""

from __future__ import annotations

import uuid
from typing import Annotated

from fastapi import APIRouter, Depends, Query
from sqlalchemy.orm import Session

from ...core.config import Settings, get_settings
from ...database.session import get_db
from ...schemas.integration import (
    ConsumeLinkCodeRequest,
    ConsumeLinkCodeResponse,
    IntegrationAppListOut,
    IntegrationCategoryListOut,
    IntegrationDeviceListOut,
    LinkCodeOut,
    PeriodComparisonOut,
    SyncStatusOut,
    TelegramBindingListOut,
    TelegramBindingOut,
    TelegramContextOut,
    binding_to_out,
    link_code_to_out,
)
from ...schemas.stats import OverviewOut
from ...security.deps import ApiKeyAuth, CurrentUser, IntegrationService
from ...services import integration_service, integration_stats_service

router = APIRouter(tags=["integrations"])

TelegramUserIdQuery = Annotated[
    int,
    Query(description="Telegram 侧 user_id（仅绑定流程使用，数据读取不需要）", gt=0),
]
PeriodQuery = Annotated[
    str,
    Query(description="统计区间：today / yesterday / 7d / 30d", pattern="^(today|yesterday|7d|30d)$"),
]
OffsetQuery = Annotated[
    int,
    Query(description="客户端相对 UTC 的时区偏移（分钟）", ge=-720, le=840),
]
LimitQuery = Annotated[
    int | None,
    Query(description="单次返回条数上限（不超过服务端配置）", ge=1, le=200),
]
CompareKindQuery = Annotated[
    str,
    Query(
        description="对比类型：today_vs_yesterday / week_vs_last_week / last7_vs_previous7",
        pattern="^(today_vs_yesterday|week_vs_last_week|last7_vs_previous7)$",
    ),
]


def _effective_limit(limit: int | None, settings: Settings) -> int:
    """调用方只能**收紧**上限，不能放宽。"""
    cap = max(1, settings.integration_max_items)
    if limit is None:
        return cap
    return min(limit, cap)


# ---------------------------------------------------------------------------
# Telegram 绑定流程（保留；不再是 MCP 的必要流程）
# ---------------------------------------------------------------------------


@router.post("/integrations/telegram/link-code", response_model=LinkCodeOut, status_code=201)
async def create_link_code(
    user: CurrentUser,
    db: Annotated[Session, Depends(get_db)],
    settings: Annotated[Settings, Depends(get_settings)],
):
    """生成一次性 Telegram 绑定码（10 分钟有效、只能用一次）。

    明文码**只在这个响应里出现一次**；服务端只保存 SHA-256 哈希。
    重复调用会作废上一个未使用的码（每个账户同时最多一个有效码）。
    """
    ttl_minutes = settings.link_code_ttl_minutes
    code, record = integration_service.create_link_code(
        db, user=user, ttl_minutes=ttl_minutes
    )
    return link_code_to_out(code, expires_at=record.expires_at, ttl_seconds=ttl_minutes * 60)


@router.get("/integrations/telegram/bindings", response_model=TelegramBindingListOut)
async def list_bindings(user: CurrentUser, db: Annotated[Session, Depends(get_db)]):
    """列出当前账户的 Telegram 绑定（含已解绑的历史记录）。"""
    items = integration_service.list_bindings(db, user=user)
    return TelegramBindingListOut(
        items=[binding_to_out(b) for b in items],
        total=len(items),
    )


@router.delete(
    "/integrations/telegram/bindings/{binding_id}", response_model=TelegramBindingOut
)
async def revoke_binding(
    binding_id: uuid.UUID,
    user: CurrentUser,
    db: Annotated[Session, Depends(get_db)],
):
    """解绑（幂等）。解绑后该 Telegram 身份的上下文接口立即变为未绑定。

    只能解绑自己的绑定；别人的绑定统一返回 ``binding_not_found``，
    不泄露"该绑定是否存在"。
    """
    binding = integration_service.revoke_binding(db, user=user, binding_id=binding_id)
    return binding_to_out(binding)


@router.post(
    "/integrations/telegram/consume-link-code",
    response_model=ConsumeLinkCodeResponse,
)
async def consume_link_code(
    payload: ConsumeLinkCodeRequest,
    _service: IntegrationService,
    db: Annotated[Session, Depends(get_db)],
):
    """AstrBot 侧：用绑定码把 Telegram 账号绑到 PetLife 账户。

    ``petlife_user_id`` 来自绑定码本身，请求体里没有这个字段。
    重复提交同一个绑定码会得到 ``link_code_consumed``；
    若该 Telegram 账号已绑在同一个账户上，则返回 ``already_bound=true``（幂等）。
    """
    binding, already_bound = integration_service.consume_link_code(
        db,
        code=payload.code,
        telegram_user_id=payload.telegram_user_id,
        telegram_chat_id=payload.telegram_chat_id,
    )
    # 绑定刚建立，这里必然能查到（顺带回显显示名给 Bot 做确认话术）
    user = integration_service.resolve_active_user(
        db, telegram_user_id=payload.telegram_user_id
    )
    return ConsumeLinkCodeResponse(
        bound=True,
        display_name=user.display_name if user else "",
        bound_at=binding_to_out(binding).created_at,
        already_bound=already_bound,
    )


@router.get("/integrations/telegram/context", response_model=TelegramContextOut)
async def telegram_context(
    _service: IntegrationService,
    db: Annotated[Session, Depends(get_db)],
    telegram_user_id: TelegramUserIdQuery,
):
    """AstrBot 侧：查询当前 Telegram 身份的绑定上下文。

    未绑定（或账户已停用/注销）时返回 ``bound=false``。
    """
    user = integration_service.resolve_active_user(db, telegram_user_id=telegram_user_id)
    if user is None:
        return TelegramContextOut(bound=False)

    binding = integration_service.active_binding_for_telegram(
        db, telegram_user_id=telegram_user_id
    )
    return TelegramContextOut(
        bound=True,
        binding_id=str(binding.id) if binding else None,
        display_name=user.display_name,
        bound_at=binding_to_out(binding).created_at if binding else None,
        device_count=integration_service.count_active_devices(db, user=user),
    )


# ---------------------------------------------------------------------------
# 只读统计（供 MCP 调用）
#
# 鉴权：``X-API-Key: plk_...``。用户由密钥推导，入参里没有任何身份字段。
# ---------------------------------------------------------------------------


@router.get("/integrations/stats/summary", response_model=OverviewOut)
async def integration_summary(
    principal: ApiKeyAuth,
    db: Annotated[Session, Depends(get_db)],
    period: PeriodQuery = "today",
    tz_offset_minutes: OffsetQuery = 0,
):
    """总览：屏幕会话 / 活跃 / 空闲 / 应用使用时间 + 设备数 + 首次与最后活跃。"""
    return integration_stats_service.get_summary(
        db, user=principal.user, period=period, offset_minutes=tz_offset_minutes
    )


@router.get("/integrations/stats/apps", response_model=IntegrationAppListOut)
async def integration_apps(
    principal: ApiKeyAuth,
    db: Annotated[Session, Depends(get_db)],
    settings: Annotated[Settings, Depends(get_settings)],
    period: PeriodQuery = "today",
    tz_offset_minutes: OffsetQuery = 0,
    limit: LimitQuery = None,
):
    """应用使用排行（按应用使用时间倒序，最多 ``integration_max_items`` 条）。"""
    return integration_stats_service.list_apps(
        db,
        user=principal.user,
        period=period,
        offset_minutes=tz_offset_minutes,
        limit=_effective_limit(limit, settings),
    )


@router.get("/integrations/stats/categories", response_model=IntegrationCategoryListOut)
async def integration_categories(
    principal: ApiKeyAuth,
    db: Annotated[Session, Depends(get_db)],
    settings: Annotated[Settings, Depends(get_settings)],
    period: PeriodQuery = "today",
    tz_offset_minutes: OffsetQuery = 0,
    limit: LimitQuery = None,
):
    """分类使用时长与占比。"""
    return integration_stats_service.list_categories(
        db,
        user=principal.user,
        period=period,
        offset_minutes=tz_offset_minutes,
        limit=_effective_limit(limit, settings),
    )


@router.get("/integrations/stats/devices", response_model=IntegrationDeviceListOut)
async def integration_devices(
    principal: ApiKeyAuth,
    db: Annotated[Session, Depends(get_db)],
    settings: Annotated[Settings, Depends(get_settings)],
    period: PeriodQuery = "today",
    tz_offset_minutes: OffsetQuery = 0,
    limit: LimitQuery = None,
):
    """各设备时长 + 合计；响应里带"多设备时间可能重叠"的提示。"""
    return integration_stats_service.list_devices(
        db,
        user=principal.user,
        period=period,
        offset_minutes=tz_offset_minutes,
        limit=_effective_limit(limit, settings),
    )


@router.get("/integrations/compare", response_model=PeriodComparisonOut)
async def integration_compare(
    principal: ApiKeyAuth,
    db: Annotated[Session, Depends(get_db)],
    kind: CompareKindQuery = "today_vs_yesterday",
    tz_offset_minutes: OffsetQuery = 0,
):
    """两个时段对比。基线为 0 时 ``*_change_ratio`` 返回 null，不伪造百分比。"""
    return integration_stats_service.compare_periods(
        db, user=principal.user, kind=kind, offset_minutes=tz_offset_minutes
    )


@router.get("/integrations/sync-status", response_model=SyncStatusOut)
async def integration_sync_status(
    principal: ApiKeyAuth,
    db: Annotated[Session, Depends(get_db)],
):
    """数据新鲜度：最近同步时间 / 最近活动时间 / 有效设备数 / 是否可能过期。"""
    return integration_stats_service.sync_status(db, user=principal.user)


__all__ = ["router"]

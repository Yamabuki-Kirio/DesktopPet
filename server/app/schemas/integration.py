"""Phase 3 集成接口的请求/响应模型。

约定（与其它 schema 一致）：
* 全部继承 ``StrictModel``（``extra="forbid"``），多余字段直接 422；
* 时间一律输出 ISO 8601 字符串（``...Z``）；
* **请求体里没有 ``user_id``**：所有 ``user_id`` 都由服务端从认证上下文/绑定关系推导，
  这样 AI 侧结构上就无法指定"查哪个用户"。
"""

from __future__ import annotations

from datetime import datetime
from typing import TYPE_CHECKING

from pydantic import Field

from .common import StrictModel, to_iso
from .stats import AppUsageOut, CategoryUsageOut, DeviceUsageOut

if TYPE_CHECKING:  # pragma: no cover - 仅用于类型标注，避免与 models 形成导入环
    from ..models import TelegramBinding


def _iso(value: datetime) -> str:
    """``to_iso`` 的"调用方已保证非 None"版本。"""
    text = to_iso(value)
    return text if text is not None else ""


class LinkCodeOut(StrictModel):
    """一次性绑定码。**明文只在这一处返回一次**，库里只存哈希。"""

    code: str = Field(description="形如 ABCD-1234，10 分钟内有效且只能用一次")
    expires_at: str
    ttl_seconds: int
    telegram_command: str = Field(description="可直接在 Telegram 里发送的绑定命令")


class TelegramBindingOut(StrictModel):
    id: str
    telegram_user_id: int
    telegram_chat_id: int
    created_at: str
    revoked_at: str | None = None
    is_active: bool


class TelegramBindingListOut(StrictModel):
    items: list[TelegramBindingOut]
    total: int


class ConsumeLinkCodeRequest(StrictModel):
    """AstrBot 侧提交的绑定请求。

    注意这里**只有 Telegram 侧身份**：``petlife_user_id`` 不在请求里，
    它来自绑定码本身（绑定码是某个已登录 PetLife 账户生成的）。
    """

    code: str = Field(min_length=4, max_length=32)
    telegram_user_id: int = Field(gt=0)
    telegram_chat_id: int = Field(gt=0)


class ConsumeLinkCodeResponse(StrictModel):
    bound: bool
    display_name: str
    bound_at: str
    #: true 表示该 Telegram 账号原本就已绑定到这个账户（重复提交绑定码的幂等结果）
    already_bound: bool = False


class TelegramContextOut(StrictModel):
    """给 AstrBot 用的"当前绑定上下文"。

    刻意**不返回** ``user_id`` 与邮箱：Bot 只需要知道"绑没绑、绑给谁（显示名）"，
    多给一个不可用的内部 ID 只会增加泄露面。
    """

    bound: bool
    binding_id: str | None = None
    display_name: str | None = None
    bound_at: str | None = None
    device_count: int = 0


def link_code_to_out(code: str, *, expires_at: datetime, ttl_seconds: int) -> LinkCodeOut:
    """把明文码与过期时间组装成响应（**唯一**出现明文码的地方）。"""
    return LinkCodeOut(
        code=code,
        expires_at=_iso(expires_at),
        ttl_seconds=ttl_seconds,
        telegram_command=f"/bind {code}",
    )


def binding_to_out(binding: TelegramBinding) -> TelegramBindingOut:
    return TelegramBindingOut(
        id=str(binding.id),
        telegram_user_id=binding.telegram_user_id,
        telegram_chat_id=binding.telegram_chat_id,
        created_at=_iso(binding.created_at),
        revoked_at=to_iso(binding.revoked_at),
        is_active=binding.revoked_at is None,
    )


# ---------------------------------------------------------------------------
# 集成统计（只读）
# ---------------------------------------------------------------------------
#
# 为什么不直接复用 ``/api/v1/stats/*`` 的响应模型：集成侧必须能告诉调用方
# "结果被截断过"（``returned`` / ``truncated``）。给用户侧的 schema 加字段会
# 影响已有客户端契约，因此这里用独立外壳，**item 模型完全复用**，
# 统计口径也只有 ``stats_service`` 一份。
#


class IntegrationAppListOut(StrictModel):
    period: str
    from_utc: str
    to_utc: str
    timezone_offset_minutes: int
    total_app_active_seconds: int
    returned: int
    truncated: bool
    items: list[AppUsageOut]


class IntegrationCategoryListOut(StrictModel):
    period: str
    from_utc: str
    to_utc: str
    timezone_offset_minutes: int
    total_app_active_seconds: int
    returned: int
    truncated: bool
    items: list[CategoryUsageOut]


class IntegrationDeviceListOut(StrictModel):
    period: str
    from_utc: str
    to_utc: str
    timezone_offset_minutes: int
    total_active_seconds: int
    overlap_warning: str
    returned: int
    truncated: bool
    items: list[DeviceUsageOut]


class PeriodMetricsOut(StrictModel):
    """对比里的单侧指标（只有汇总，不含明细）。"""

    label: str
    from_utc: str
    to_utc: str
    session_seconds: int
    active_seconds: int
    idle_seconds: int
    app_active_seconds: int
    device_count: int


class PeriodComparisonOut(StrictModel):
    """两个时段对比。

    ``*_change_ratio`` 在**基线为 0**（上一时段没有数据）时是 ``None``：
    此时任何百分比都是编出来的，宁可明确给 null。
    """

    kind: str
    timezone_offset_minutes: int
    current: PeriodMetricsOut
    previous: PeriodMetricsOut
    active_seconds_delta: int
    active_seconds_change_ratio: float | None = None
    app_active_seconds_delta: int
    app_active_seconds_change_ratio: float | None = None
    has_data: bool
    note: str


class SyncStatusOut(StrictModel):
    """数据新鲜度。

    刻意**只给时间与计数**：没有设备密钥、没有令牌、没有内部异常信息。
    "未绑定"不用这个结构表达 —— 那种情况直接在接口层报 ``telegram_not_bound``。

    ⚠️ ``registered_device_count`` 是**注册且未撤销**的设备数，
    与 ``/stats/*`` 的 ``device_count``（**窗口内有数据的设备数**）不是一回事，
    因此这里用不同的字段名，避免 AI 把两者混为一谈。
    """

    registered_device_count: int
    last_data_received_at: str | None = None
    last_activity_at: str | None = None
    data_may_be_stale: bool
    stale_after_minutes: int
    note: str

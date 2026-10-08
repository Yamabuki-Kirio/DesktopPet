"""MCP Server 配置。

与 API 服务端**共用 ``PETLIFE_`` 前缀**，但只读它需要的那几项：
``MCP_URL`` / ``API_KEY`` / ``REQUEST_TIMEOUT`` 等。
这里刻意**不引入** ``app.core.config.Settings``——那样会把数据库配置一起拖进来，
而我们希望"这个进程拿不到数据库口令"是结构性的，而不是靠自觉。

身份模型（本版改动）
--------------------
旧版让 MCP 依赖 ``PETLIFE_TELEGRAM_USER_ID`` 或 AstrBot 注入的动态请求头来
确定"这是谁"。现在改为：**``PETLIFE_API_KEY`` 本身就是身份**。

* 密钥由用户在 Windows 客户端「AI 数据访问」里生成（``plk_...``）；
* 权限固定为只读统计，撤销后立即失效；
* 一把密钥对一个账户，因此**一个 MCP 进程即一个用户**，
  不需要（也无法）在请求里传 ``user_id`` / Telegram ID。
"""

from __future__ import annotations

from functools import lru_cache

from pydantic import Field, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

DEFAULT_MCP_URL = "http://127.0.0.1:8000"


class McpSettings(BaseSettings):
    """从环境变量（前缀 ``PETLIFE_``）加载。

    三项必备配置：

    * ``PETLIFE_MCP_URL``          —— PetLife API 基地址
    * ``PETLIFE_API_KEY``          —— 个人访问密钥（``plk_...``，不下发给模型）
    * ``PETLIFE_REQUEST_TIMEOUT``  —— 单次 HTTP 调用超时（秒）
    """

    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        env_prefix="PETLIFE_",
        extra="ignore",
    )

    mcp_url: str = DEFAULT_MCP_URL

    #: 个人访问密钥。为空时**所有工具都会失败**（而不是无鉴权放行）。
    api_key: str = ""

    #: 单次 API 调用超时（秒）
    request_timeout: float = Field(default=15.0, gt=0, le=120)

    #: 单次列表返回上限（与 API 侧 ``PETLIFE_INTEGRATION_MAX_ITEMS`` 保持一致）
    integration_max_items: int = Field(default=50, ge=1, le=200)

    #: 是否让 httpx 读取代理相关环境变量（HTTP_PROXY / ALL_PROXY / NO_PROXY ...）。
    #:
    #: 默认 **False**：服务进程访问自家 API 应当是确定行为。
    #: 实测踩过坑——开发机上开着系统代理时，httpx 默认会把
    #: ``MCP → API`` 的请求也送进代理，结果收到 502，看起来像是"服务端挂了"。
    mcp_trust_env: bool = False

    #: Streamable HTTP 监听地址
    mcp_host: str = "127.0.0.1"
    mcp_port: int = Field(default=8765, ge=1, le=65535)

    #: 是否为**每个 HTTP 请求**创建独立传输（MCP SDK 的 ``stateless_http``）。
    #:
    #: 默认 **true**：MCP 进程里只有一把密钥（一个用户），无状态传输
    #: 不会带来身份串号风险，但能避免长连接会话在断线后卡死。
    mcp_stateless_http: bool = True

    #: Streamable HTTP 的 ``Host`` / ``Origin`` 白名单（逗号分隔）。
    #:
    #: MCP SDK 在监听本机地址时会**自动**开启 DNS-rebinding 保护，只允许
    #: ``127.0.0.1:*`` / ``localhost:*`` / ``[::1]:*``。如果 MCP 端口是通过
    #: 反向代理或别的域名暴露出去的，就必须在这里把它加上，否则请求会被拒。
    #: 留空表示沿用 SDK 默认（仅本机）。
    mcp_allowed_hosts: str = ""
    mcp_allowed_origins: str = ""

    @staticmethod
    def _split(value: str) -> list[str]:
        return [item.strip() for item in value.split(",") if item.strip()]

    @property
    def allowed_hosts(self) -> list[str]:
        return self._split(self.mcp_allowed_hosts)

    @property
    def allowed_origins(self) -> list[str]:
        return self._split(self.mcp_allowed_origins)

    @property
    def api_base_url(self) -> str:
        return self.mcp_url.strip().rstrip("/")

    # --- 空值的容错 ---------------------------------------------------------
    #
    # `.env` 里写了 `PETLIFE_API_KEY=`（等号右边留空）是很常见的情况，
    # 而 pydantic 拿到空字符串本身不会报错，但 `MCP_URL="   "` 会让地址变成空白，
    # 因此这里统一把"空白"归一成"未设置"的语义。

    @field_validator("mcp_url", mode="before")
    @classmethod
    def _blank_url_falls_back(cls, value: object) -> str:
        text = "" if value is None else str(value).strip()
        return text or DEFAULT_MCP_URL

    @field_validator("api_key", mode="before")
    @classmethod
    def _blank_key_means_empty(cls, value: object) -> str:
        return "" if value is None else str(value).strip()

    @property
    def api_key_configured(self) -> bool:
        return bool(self.api_key)


@lru_cache
def get_mcp_settings() -> McpSettings:
    return McpSettings()  # type: ignore[call-arg]


def reset_mcp_settings_cache() -> None:
    """仅供测试使用。"""
    get_mcp_settings.cache_clear()

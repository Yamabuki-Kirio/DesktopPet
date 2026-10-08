"""MCP Server 入口。

运行方式
--------
```bash
# stdio（本地自动化测试 / AstrBot 以子进程方式启动）
python -m mcp_server.main stdio

# Streamable HTTP（AstrBot 以 HTTP 方式接入）
python -m mcp_server.main http
```

身份模型（本版改动）
--------------------
身份 = **``PETLIFE_API_KEY``**（个人访问密钥，``plk_...``），由用户在 Windows 客户端
「AI 数据访问」里生成。服务端按密钥确定账户，因此：

* 进程里**只有一把密钥**，一个 MCP 进程即一个用户；
* 请求头 / 环境变量里**不再有任何 Telegram 身份**，工具参数里也没有身份字段；
* 撤销密钥后，本进程的所有调用会立刻收到 401 并给出可读提示。

为什么 HTTP 模式**不**在进程启动时校验密钥能否用：MCP 握手不应该依赖 API 在线；
真正不可用时由工具调用给出明确、可读的错误（``guard`` 统一翻译）。
"""

from __future__ import annotations

import asyncio
import logging
import os
import sys

from mcp.server.fastmcp import FastMCP

from .client import PetLifeApiClient
from .config import McpSettings, get_mcp_settings
from .tools import ToolDeps, register_all

SERVER_NAME = "petlife-usage"

INSTRUCTIONS = """\
PetLife 记录用户自己电脑上的使用情况。这里提供的工具都是**只读**的，
只能查询「本服务端配置的 API 密钥所属的那个 PetLife 账户」的数据。

统计口径（回答前请遵守）：
- 屏幕会话时间 ≠ 活跃时间；空闲时间**包含在**屏幕会话时间里；
- 活跃时间 ≠ 应用使用时间；应用使用时间不会超过活跃时间；
- 多设备的时间**可能重叠**，各设备相加不等于"人的真实使用时间"，回答时要说明；
- 所有时长字段单位都是**秒**，请换算成"X 小时 Y 分"再回答，不要原样抛秒数；
- 没有数据就明确说"暂无数据"，不要推测、不要补全、不要编造百分比。

隐私边界：只能读到汇总统计、应用名/分类、设备名与时间；
读不到窗口标题、网页地址、文档名、本地文件路径或任何输入内容。

身份由服务端配置的 API 密钥决定，工具参数里没有 user_id —— 不要尝试查询其他用户，
也不存在任何可以执行 SQL 或任意查询的工具。如果调用返回"API 密钥无效或已被撤销"，
请提示用户到客户端的「AI 数据访问」里重新生成密钥，不要自行猜测数据。
"""

logger = logging.getLogger("petlife.mcp")


def build_deps(settings: McpSettings | None = None) -> ToolDeps:
    cfg = settings or get_mcp_settings()
    client = PetLifeApiClient(
        base_url=cfg.api_base_url,
        api_key=cfg.api_key,
        timeout=cfg.request_timeout,
        trust_env=cfg.mcp_trust_env,
    )
    return ToolDeps(client=client, max_items=cfg.integration_max_items)


def build_server(
    *,
    deps: ToolDeps | None = None,
    settings: McpSettings | None = None,
) -> FastMCP:
    """组装 MCP 服务（工具注册在这里完成，测试可直接用 ``mcp.call_tool``）。"""
    cfg = settings or get_mcp_settings()
    transport_security = None
    if cfg.allowed_hosts or cfg.allowed_origins:
        from mcp.server.transport_security import TransportSecuritySettings

        transport_security = TransportSecuritySettings(
            enable_dns_rebinding_protection=True,
            allowed_hosts=cfg.allowed_hosts or ["127.0.0.1:*", "localhost:*", "[::1]:*"],
            allowed_origins=cfg.allowed_origins
            or ["http://127.0.0.1:*", "http://localhost:*", "http://[::1]:*"],
        )

    mcp = FastMCP(
        SERVER_NAME,
        instructions=INSTRUCTIONS,
        host=cfg.mcp_host,
        port=cfg.mcp_port,
        stateless_http=cfg.mcp_stateless_http,
        transport_security=transport_security,
    )
    register_all(mcp, deps or build_deps(cfg))
    return mcp


def _warn_if_key_missing(cfg: McpSettings) -> None:
    if not cfg.api_key_configured:
        logger.warning(
            "未配置 PETLIFE_API_KEY：所有工具调用都会被 PetLife API 以 401 拒绝。"
            "请先在 Windows 客户端「账户与同步 → AI 数据访问」生成密钥。"
        )


def run_stdio(mcp: FastMCP, *, settings: McpSettings | None = None) -> None:
    _warn_if_key_missing(settings or get_mcp_settings())
    asyncio.run(mcp.run_stdio_async())


def run_http(mcp: FastMCP, *, settings: McpSettings | None = None) -> None:
    """Streamable HTTP 模式。"""
    import uvicorn

    cfg = settings or get_mcp_settings()
    _warn_if_key_missing(cfg)

    logger.info(
        "MCP Streamable HTTP 监听 http://%s:%s/mcp（身份来自 PETLIFE_API_KEY）",
        cfg.mcp_host,
        cfg.mcp_port,
    )
    uvicorn.run(
        mcp.streamable_http_app(), host=cfg.mcp_host, port=cfg.mcp_port, log_level="info"
    )


def _resolve_transport(argv: list[str]) -> str:
    for arg in argv:
        if arg in {"stdio", "http", "streamable-http"}:
            return "http" if arg == "streamable-http" else arg
    env = (os.environ.get("PETLIFE_MCP_TRANSPORT") or "").strip().lower()
    if env in {"http", "streamable-http", "streamable_http"}:
        return "http"
    return "stdio"


def main(argv: list[str] | None = None) -> None:
    args = list(sys.argv[1:] if argv is None else argv)
    # 日志一律走 stderr：stdio 模式下 stdout 是 JSON-RPC 通道，不能被日志污染
    logging.basicConfig(stream=sys.stderr, level=logging.INFO)

    settings = get_mcp_settings()
    mcp = build_server(settings=settings)

    transport = _resolve_transport(args)
    if transport == "http":
        run_http(mcp, settings=settings)
    else:
        run_stdio(mcp, settings=settings)


if __name__ == "__main__":  # pragma: no cover - 进程入口
    main()

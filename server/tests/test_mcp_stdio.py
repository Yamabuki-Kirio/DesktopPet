"""Phase 3（改版）：MCP **协议层**测试（stdio 传输，真实子进程）。

与 ``test_mcp_tools.py`` 的区别：

* 那个文件在进程内直接调工具（快，用来验证逻辑与数据）；
* 这个文件用**官方 MCP 客户端**启动一个真实子进程，走完整的
  ``initialize`` → ``tools/list`` → ``tools/call`` 握手，
  用来证明"这个 MCP Server 真的能被标准客户端用起来"。

这里刻意**不要求** PetLife API 在线：API 地址指向一个没人监听的端口，
我们要验证的是"协议跑通 + 密钥从环境变量读取 + 错误被结构化返回"。
真实数据链路由 ``test_mcp_tools.py``（进程内真实 API）与后续 E2E 覆盖。
"""

from __future__ import annotations

import asyncio
import os
import sys
from typing import Any

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

from .conftest import SERVER_ROOT

EXPECTED_TOOLS = {
    "petlife_get_summary",
    "petlife_get_top_apps",
    "petlife_get_categories",
    "petlife_get_devices",
    "petlife_compare_periods",
    "petlife_get_sync_status",
    # Phase 4B：按设备 + 日期的跨设备云端统计
    "petlife_list_devices",
    "petlife_get_usage_summary",
    "petlife_get_app_usage",
    "petlife_get_usage_sessions",
    "petlife_get_daily_timeline",
}

#: 没有任何服务监听的地址：用来稳定复现"服务端不可达"
DEAD_URL = "http://127.0.0.1:9"

#: 测试用密钥（绝不能出现在任何返回内容里）
STDIO_KEY = "plk_stdio-test-key-0123456789"


def _server_params(**overrides: str) -> StdioServerParameters:
    env = {
        **os.environ,
        "PYTHONPATH": str(SERVER_ROOT),
        "PYTHONUTF8": "1",
        "PETLIFE_MCP_URL": DEAD_URL,
        "PETLIFE_API_KEY": STDIO_KEY,
        "PETLIFE_REQUEST_TIMEOUT": "2",
    }
    env.update(overrides)
    return StdioServerParameters(
        command=sys.executable,
        args=["-m", "mcp_server.main", "stdio"],
        env=env,
    )


async def _handshake_and_call(
    tool: str, arguments: dict[str, Any] | None = None, **env_overrides: str
) -> tuple[Any, list[Any], Any]:
    params = _server_params(**env_overrides)
    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as session:
            init = await session.initialize()
            tools = await session.list_tools()
            result = await session.call_tool(tool, arguments or {})
            return init, list(tools.tools), result


def _text_of(result: Any) -> str:
    parts: list[str] = []
    for block in getattr(result, "content", []) or []:
        text = getattr(block, "text", None)
        if isinstance(text, str):
            parts.append(text)
    return "\n".join(parts)


def test_stdio_initialize_and_tool_listing():
    """官方客户端能完成握手，并看到 6 个只读工具。"""
    init, tools, _ = asyncio.run(_handshake_and_call("petlife_get_sync_status"))

    assert init.serverInfo.name == "petlife-usage"
    assert {tool.name for tool in tools} == EXPECTED_TOOLS
    for tool in tools:
        properties = (tool.inputSchema or {}).get("properties") or {}
        assert "user_id" not in properties
        assert "telegram_user_id" not in properties
        assert "api_key" not in properties


def test_stdio_tool_call_reports_unreachable_api():
    """密钥来自环境变量：调用真的发出去了，并把"连不上 API"结构化返回。

    具体是"连接被拒"还是"超时"取决于本机对目标端口的处理方式，
    两者都是合法的"不可达"结论，因此这里接受任一。
    """
    _, _, result = asyncio.run(_handshake_and_call("petlife_get_sync_status"))

    assert result.isError is True
    text = _text_of(result)
    assert ("无法连接" in text) or ("超时" in text), text
    # 密钥绝不能出现在返回内容里
    assert STDIO_KEY not in text


def test_stdio_starts_without_api_key():
    """未配置密钥时进程仍要正常起来（不能崩），错误在调用时才暴露。

    旧版实现里 ``.env`` 留空会让 MCP 进程直接 ``ValidationError`` 退出，
    这条用例守住"空值 = 未设置，而不是致命错误"。
    """
    init, tools, result = asyncio.run(
        _handshake_and_call("petlife_get_sync_status", PETLIFE_API_KEY="")
    )

    assert init.serverInfo.name == "petlife-usage"
    assert {tool.name for tool in tools} == EXPECTED_TOOLS
    # 目标地址不可达，因此这里得到的仍是"不可达"；关键是**没有崩溃**
    assert result.isError is True


def test_stdio_rejects_unknown_tool():
    """不存在的工具名会被协议层拒绝（不存在"万能查询"入口）。"""
    _, _, result = asyncio.run(
        _handshake_and_call("petlife_execute_sql", {"query": "select 1"})
    )
    assert result.isError is True

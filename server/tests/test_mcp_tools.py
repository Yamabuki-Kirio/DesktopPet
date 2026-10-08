"""Phase 3（改版）：MCP 工具测试。

测试策略
--------
MCP 工具 → ``PetLifeApiClient`` → **真实 FastAPI 应用**（用 ``httpx.ASGITransport``
在进程内直连 ASGI app）→ 真实的密钥鉴权 → 真实的 ``stats_service``。

也就是说：这里**没有 mock 掉 API**，只是省掉了 TCP。因此"工具返回的数字与服务端
统计一致"这句话是真的被验证过，而不是靠打桩。

身份模型：密钥（``PETLIFE_API_KEY``）就是身份，工具参数里没有任何身份字段，
也没有任何可以塞身份的地方（旧版的会话上下文注入已删除）。
"""

from __future__ import annotations

import asyncio
import json
from typing import Any

import httpx
import pytest
from mcp.server.fastmcp.exceptions import ToolError

from app.security.deps import API_KEY_HEADER as API_SIDE_KEY_HEADER
from mcp_server.client import (
    API_KEY_HEADER,
    PetLifeApiClient,
    PetLifeApiError,
    PetLifeApiTimeout,
)
from mcp_server.main import build_server
from mcp_server.tools import ToolDeps

from .conftest import API
from .test_api_keys import issue_key
from .test_integration_stats import seed_usage

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

#: 允许出现在工具参数里的名字（**没有**任何身份字段）
ALLOWED_PARAM_NAMES = {
    "period",
    "limit",
    "timezone_offset_minutes",
    "kind",
    # Phase 4B
    "device_id",
    "date",
    "date_from",
    "date_to",
    "timezone",
    "app_id",
    "cursor",
}

FAKE_KEY = "plk_" + "0" * 43


# --- 装置 -------------------------------------------------------------------


def _build_deps(
    app, *, api_key: str = FAKE_KEY, max_items: int = 50
) -> ToolDeps:
    """把 MCP 的 HTTP 客户端接到进程内的真实 ASGI 应用上。"""
    http = httpx.AsyncClient(
        transport=httpx.ASGITransport(app=app),
        base_url="http://petlife.test",
    )
    client = PetLifeApiClient(
        base_url="http://petlife.test",
        api_key=api_key,
        timeout=10.0,
        http=http,
    )
    return ToolDeps(client=client, max_items=max_items)


def _payload(result: Any) -> dict[str, Any]:
    """把 FastMCP 的返回统一成 dict。"""
    if isinstance(result, dict):
        return result
    if isinstance(result, tuple):
        for item in result:
            if isinstance(item, dict):
                return item
    if isinstance(result, list):
        for block in result:
            text = getattr(block, "text", None)
            if isinstance(text, str):
                try:
                    return json.loads(text)
                except ValueError:
                    return {"text": text}
    raise AssertionError(f"无法解析工具返回：{result!r}")


def _call(
    app,
    name: str,
    arguments: dict[str, Any] | None = None,
    *,
    api_key: str = FAKE_KEY,
    max_items: int = 50,
) -> dict[str, Any]:
    async def _run() -> Any:
        deps = _build_deps(app, api_key=api_key, max_items=max_items)
        try:
            mcp = build_server(deps=deps)
            return await mcp.call_tool(name, arguments or {})
        finally:
            await deps.client.aclose()

    return _payload(asyncio.run(_run()))


def _call_error(app, name: str, arguments: dict[str, Any] | None = None, **kwargs) -> str:
    """调用工具并断言失败，返回错误文案。"""
    try:
        result = _call(app, name, arguments, **kwargs)
    except ToolError as exc:
        return str(exc)
    raise AssertionError(f"预期失败，但工具返回了结果：{result!r}")


def _list_tools(app, *, api_key: str = FAKE_KEY, max_items: int = 50) -> list[Any]:
    async def _run() -> list[Any]:
        deps = _build_deps(app, api_key=api_key, max_items=max_items)
        try:
            mcp = build_server(deps=deps)
            return await mcp.list_tools()
        finally:
            await deps.client.aclose()

    return asyncio.run(_run())


def setup_account(api, *, name: str = "AstrBot") -> str:
    """注册账户、灌入使用数据、发一把密钥，返回密钥明文。"""
    api.register()
    seed_usage(api)
    return issue_key(api, name=name)["key"]


# --- 工具清单与安全边界 -----------------------------------------------------


def test_api_key_header_matches_api():
    """MCP 侧硬编码的请求头名必须与 API 侧一致（防止两处漂移）。"""
    assert API_KEY_HEADER == API_SIDE_KEY_HEADER


def test_tools_list_contains_exactly_six_tools(app_module):
    tools = _list_tools(app_module)
    assert {t.name for t in tools} == EXPECTED_TOOLS


def test_tools_have_no_identity_or_sql_surface(app_module):
    """工具参数里没有身份字段，也不存在任意 SQL 的能力。"""
    for tool in _list_tools(app_module):
        properties = (tool.inputSchema or {}).get("properties") or {}
        assert set(properties) <= ALLOWED_PARAM_NAMES, (
            f"{tool.name} 出现了计划外的参数：{sorted(set(properties) - ALLOWED_PARAM_NAMES)}"
        )

        haystack = f"{tool.name} {(tool.description or '').lower()}"
        for banned in ("sql", "execute", "database", "postgres", "user_id", "api_key"):
            assert banned not in haystack, f"{tool.name} 的描述里出现了 {banned}"


def test_injected_identity_argument_is_ignored(app_module, api):
    """模型硬塞身份参数也**不会**改变查询对象。

    实测行为：FastMCP 会**忽略**不在 schema 里的多余参数（而不是报错），
    因此这里断言"被忽略"而不是"被拒绝"——这恰恰是更安全的语义：
    身份只能来自服务端配置的密钥，模型既看不到也改不了。
    """
    key = setup_account(api)
    victim_user_id = api.user["id"]

    other = type(api)(api.http)
    other.register()  # 另一个账户：没有任何使用数据
    victim_key = issue_key(other)["key"]

    body = _call(
        app_module,
        "petlife_get_summary",
        {
            "period": "today",
            "timezone_offset_minutes": 0,
            "user_id": victim_user_id,  # PetLife 侧的 user_id
            "telegram_user_id": 900012,  # 旧版的身份入口
        },
        api_key=key,
    )
    assert body["active_seconds"] == 1800, "注入的身份参数必须被忽略，只按密钥查询"

    # 反向确认：换用另一个账户的密钥，看到的是另一个账户（空白）的数据
    blank = _call(
        app_module,
        "petlife_get_summary",
        {"period": "today", "timezone_offset_minutes": 0},
        api_key=victim_key,
    )
    assert blank["active_seconds"] == 0


def test_tool_with_invalid_key_gives_actionable_hint(app_module, api):
    setup_account(api)
    error = _call_error(
        app_module, "petlife_get_summary", {}, api_key="plk_definitely-not-valid"
    )
    assert "密钥" in error
    assert "AI 数据访问" in error, "必须告诉用户去哪里重新生成密钥"


def test_tool_reports_401_without_leaking_key(app_module, api):
    setup_account(api)
    secret = "plk_" + "s3cr3t" * 6
    error = _call_error(app_module, "petlife_get_summary", {}, api_key=secret)
    assert "api_key_invalid" in error
    assert secret not in error, "错误信息里绝不能出现密钥"


def test_tool_stops_working_after_key_revoked(app_module, api):
    api.register()
    seed_usage(api)
    created = issue_key(api)
    assert _call(
        app_module, "petlife_get_summary", {}, api_key=created["key"]
    )["active_seconds"] == 1800

    api.delete(f"{API}/api-keys/{created['id']}")

    error = _call_error(app_module, "petlife_get_summary", {}, api_key=created["key"])
    assert "api_key_revoked" in error


# --- 六个工具的正常路径 -----------------------------------------------------


def test_summary_tool_matches_user_facing_api(app_module, api):
    key = setup_account(api)
    body = _call(
        app_module,
        "petlife_get_summary",
        {"period": "today", "timezone_offset_minutes": 0},
        api_key=key,
    )
    assert body["active_seconds"] == 1800
    assert body["app_active_seconds"] == 1800
    assert body["session_seconds"] == 2400
    assert body["idle_seconds"] == 600

    direct = api.get(
        f"{API}/stats/summary", params={"period": "today", "tz_offset_minutes": 0}
    ).json()
    for field in ("session_seconds", "active_seconds", "idle_seconds", "app_active_seconds"):
        assert body[field] == direct[field], f"{field} 与 /stats/summary 不一致"


def test_top_apps_tool_and_limit(app_module, api):
    key = setup_account(api)
    body = _call(
        app_module,
        "petlife_get_top_apps",
        {"period": "7d", "limit": 10, "timezone_offset_minutes": 0},
        api_key=key,
    )
    assert [item["app_key"] for item in body["items"]] == ["code", "chrome"]
    assert body["truncated"] is False
    assert body["items"][0]["display_name"] == "VS Code"

    narrowed = _call(
        app_module,
        "petlife_get_top_apps",
        {"period": "7d", "limit": 1, "timezone_offset_minutes": 0},
        api_key=key,
    )
    assert narrowed["returned"] == 1
    assert narrowed["truncated"] is True


def test_top_apps_limit_cannot_exceed_tool_cap(app_module, api):
    """工具侧也要夹紧上限：请求 500 条也只能拿到 max_items 以内。"""
    key = setup_account(api)
    body = _call(
        app_module,
        "petlife_get_top_apps",
        {"period": "7d", "limit": 500, "timezone_offset_minutes": 0},
        api_key=key,
        max_items=1,
    )
    assert body["returned"] <= 1


def test_categories_tool(app_module, api):
    key = setup_account(api)
    body = _call(
        app_module,
        "petlife_get_categories",
        {"period": "today", "timezone_offset_minutes": 0},
        api_key=key,
    )
    assert body["items"][0]["category"] == "development"
    assert body["items"][0]["active_seconds"] == 1800


def test_devices_tool_carries_overlap_warning(app_module, api):
    key = setup_account(api)
    body = _call(
        app_module,
        "petlife_get_devices",
        {"period": "today", "timezone_offset_minutes": 0},
        api_key=key,
    )
    assert body["returned"] == 1
    assert "重叠" in body["overlap_warning"]


def test_compare_tool_all_three_kinds(app_module, api):
    key = setup_account(api)
    today = _call(
        app_module,
        "petlife_compare_periods",
        {"kind": "today_vs_yesterday", "timezone_offset_minutes": 0},
        api_key=key,
    )
    assert today["active_seconds_delta"] == 1200
    assert today["active_seconds_change_ratio"] == 2.0
    assert today["has_data"] is True

    for kind in ("week_vs_last_week", "last7_vs_previous7"):
        body = _call(
            app_module,
            "petlife_compare_periods",
            {"kind": kind, "timezone_offset_minutes": 0},
            api_key=key,
        )
        assert body["kind"] == kind
        assert body["note"]


def test_sync_status_tool(app_module, api):
    key = setup_account(api)
    body = _call(app_module, "petlife_get_sync_status", {}, api_key=key)
    assert body["registered_device_count"] == 1
    assert body["data_may_be_stale"] is False
    assert body["last_data_received_at"] is not None
    assert "token" not in json.dumps(body, ensure_ascii=False).lower()
    assert key not in json.dumps(body, ensure_ascii=False)


def test_sync_status_tool_is_param_free(app_module):
    """``petlife_get_sync_status`` 不接任何参数。"""
    tools = _list_tools(app_module)
    sync_tool = next(t for t in tools if t.name == "petlife_get_sync_status")
    assert (sync_tool.inputSchema or {}).get("properties", {}) == {}


def test_summary_tool_on_empty_account(app_module, api):
    api.register()
    key = issue_key(api)["key"]

    body = _call(
        app_module,
        "petlife_get_summary",
        {"period": "today", "timezone_offset_minutes": 0},
        api_key=key,
    )
    assert body["active_seconds"] == 0
    assert body["app_active_seconds"] == 0
    assert body["device_count"] == 0


# --- 超时 / 网络错误 --------------------------------------------------------


def test_tool_reports_timeout(app_module):
    """超时要被翻译成可读提示，而不是抛裸异常。"""

    class _TimeoutClient(PetLifeApiClient):
        def __init__(self) -> None:
            super().__init__(base_url="http://petlife.test", api_key=FAKE_KEY)

        async def summary(self, **kwargs):  # type: ignore[override]
            raise PetLifeApiTimeout("调用 PetLife 服务端超时（0.01s）")

    async def _run() -> Any:
        mcp = build_server(deps=ToolDeps(client=_TimeoutClient(), max_items=50))
        return await mcp.call_tool("petlife_get_summary", {})

    with pytest.raises(ToolError) as excinfo:
        asyncio.run(_run())
    assert "超时" in str(excinfo.value)


def test_tool_reports_network_error_without_internals(app_module):
    def _handler(request: httpx.Request) -> httpx.Response:  # pragma: no cover
        raise httpx.ConnectError("boom-should-not-leak", request=request)

    async def _run() -> Any:
        http = httpx.AsyncClient(transport=httpx.MockTransport(_handler))
        client = PetLifeApiClient(
            base_url="http://unreachable.test",
            api_key=FAKE_KEY,
            http=http,
        )
        try:
            mcp = build_server(deps=ToolDeps(client=client, max_items=50))
            return await mcp.call_tool("petlife_get_summary", {})
        finally:
            await http.aclose()

    with pytest.raises(ToolError) as excinfo:
        asyncio.run(_run())
    message = str(excinfo.value)
    assert "无法连接" in message
    assert "boom-should-not-leak" not in message, "不应把底层异常细节抛给模型"


# --- 客户端本身 -------------------------------------------------------------


def test_client_sends_api_key_header_and_never_leaks_it():
    secret = "plk_client-secret-0123456789"
    seen: dict[str, Any] = {}

    def _handler(request: httpx.Request) -> httpx.Response:
        seen["header"] = request.headers.get(API_KEY_HEADER)
        seen["url"] = str(request.url)
        return httpx.Response(
            401,
            json={
                "error": {
                    "code": "api_key_invalid",
                    "message": "API 密钥无效",
                    "request_id": "req-1",
                }
            },
        )

    async def _run() -> None:
        http = httpx.AsyncClient(transport=httpx.MockTransport(_handler))
        client = PetLifeApiClient(
            base_url="http://petlife.test",
            api_key=secret,
            http=http,
        )
        try:
            with pytest.raises(PetLifeApiError) as excinfo:
                await client.summary(period="today", timezone_offset_minutes=0)
            error = excinfo.value
            assert error.code == "api_key_invalid"
            assert error.request_id == "req-1"
            assert error.is_key_rejected is True
            assert secret not in str(error)
            assert secret not in repr(error.__dict__)
        finally:
            await http.aclose()

    asyncio.run(_run())
    assert seen["header"] == secret
    # 请求里不含任何身份参数
    assert "telegram_user_id" not in seen["url"]
    assert "user_id" not in seen["url"]
    assert "period=today" in seen["url"]


def test_client_is_read_only():
    """MCP 客户端只读：公开方法集合是固定的，没有任何写操作。"""
    public = {
        name
        for name in dir(PetLifeApiClient)
        if not name.startswith("_") and callable(getattr(PetLifeApiClient, name))
    }
    assert public == {
        "aclose",
        "app_usage",
        "apps",
        "categories",
        "cloud_devices",
        "compare",
        "daily_timeline",
        "devices",
        "summary",
        "sync_status",
        "usage_sessions",
        "usage_summary",
    }


def test_settings_tolerate_blank_env_values(monkeypatch):
    """空字符串必须被当成"没设置"，而不是让进程起不来或地址变成空白。"""
    from mcp_server.config import McpSettings

    monkeypatch.setenv("PETLIFE_API_KEY", "")
    monkeypatch.setenv("PETLIFE_MCP_URL", "   ")

    settings = McpSettings()
    assert settings.api_key == ""
    assert settings.api_key_configured is False
    assert settings.api_base_url == "http://127.0.0.1:8000"


def test_settings_reads_api_key(monkeypatch):
    from mcp_server.config import McpSettings

    monkeypatch.setenv("PETLIFE_API_KEY", "  plk_abc  ")

    settings = McpSettings()
    assert settings.api_key == "plk_abc"
    assert settings.api_key_configured is True

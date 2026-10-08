"""PetLife API 客户端（只读）。

三条硬约束
----------
1. **只读**：本客户端只提供 ``GET``。所有数据都由 PetLife API 在自己的统计服务里
   算好，MCP 只是搬运；于是"MCP 工具全是只读"是结构性的，而不是靠约定。
2. **不持有数据库信息**：只有 ``PETLIFE_MCP_URL`` + 个人访问密钥。
3. **密钥不外泄**：密钥只出现在 ``X-API-Key`` 请求头里；异常信息只带
   状态码 / 错误码 / 服务端返回的 message / request_id，**绝不包含密钥**。

身份模型：``X-API-Key`` 一把密钥对应一个 PetLife 账户，用户由服务端推导。
因此这里的每个方法都**没有** ``user_id`` / ``telegram_user_id`` 参数。
"""

from __future__ import annotations

from typing import Any

import httpx

#: 与 ``app.security.deps.API_KEY_HEADER`` 必须一致。
#: 这里刻意**硬编码**而不是 import：那样会把 FastAPI / 数据库配置一起拖进 MCP 进程。
#: 测试 ``test_mcp_tools.py::test_api_key_header_matches_api`` 会断言两者相等。
API_KEY_HEADER = "X-API-Key"

#: 只读统计接口前缀（用户由密钥推导，路径里不需要任何身份信息）
STATS_PREFIX = "/api/v1/integrations/stats"

#: Phase 4B：跨设备云端统计（按设备 + 日期查询逐条会话）。
#: 与客户端 App 走**同一个服务函数**，因此 MCP 与 App 看到的结果必然一致。
CLOUD_PREFIX = "/api/v1/integrations/statistics"


class PetLifeApiError(RuntimeError):
    """服务端返回的结构化错误（或网络层失败）。

    属性里**没有**密钥；``message`` 直接来自服务端错误体，可以安全展示。
    """

    def __init__(
        self,
        *,
        status_code: int,
        code: str,
        message: str,
        request_id: str | None = None,
    ) -> None:
        super().__init__(message)
        self.status_code = status_code
        self.code = code
        self.message = message
        self.request_id = request_id

    @property
    def is_key_rejected(self) -> bool:
        """密钥无效 / 已撤销 / 未配置（都应该提示用户重新生成密钥）。"""
        return self.code in {
            "api_key_invalid",
            "api_key_revoked",
            "integration_token_invalid",
            "unauthorized",
        }

    @property
    def is_scope_denied(self) -> bool:
        return self.code == "api_key_scope_denied"

    @property
    def is_account_unavailable(self) -> bool:
        return self.code == "account_disabled"

    def __str__(self) -> str:
        parts = [f"[{self.code}]", self.message, f"(HTTP {self.status_code})"]
        if self.request_id:
            parts.append(f"request_id={self.request_id}")
        return " ".join(parts)


class PetLifeApiTimeout(RuntimeError):
    """调用超时。"""


def _parse_error(status_code: int, payload: Any) -> tuple[str, str, str | None]:
    """解析统一错误体 ``{"error": {"code","message","request_id"}}``。"""
    if isinstance(payload, dict):
        error = payload.get("error")
        if isinstance(error, dict):
            return (
                str(error.get("code") or "unknown_error"),
                str(error.get("message") or "服务端返回错误"),
                error.get("request_id") if isinstance(error.get("request_id"), str) else None,
            )
    return "http_error", f"PetLife 服务端返回 HTTP {status_code}", None


class PetLifeApiClient:
    """集成接口的只读封装。"""

    def __init__(
        self,
        *,
        base_url: str,
        api_key: str,
        timeout: float = 15.0,
        http: httpx.AsyncClient | None = None,
        trust_env: bool = False,
    ) -> None:
        self.base_url = base_url.strip().rstrip("/")
        self._api_key = api_key.strip()
        self.timeout = timeout
        self._owned = http is None
        # trust_env 默认 **False**：httpx 默认会读取 HTTP_PROXY / ALL_PROXY 等环境变量，
        # 于是"服务进程 → 自家 API"的请求会被塞进开发机上的代理，
        # 表现为莫名其妙的 502（实测踩到过）。服务端组件应当行为确定，
        # 需要走代理时用 PETLIFE_MCP_TRUST_ENV=true 显式打开。
        self._http = http or httpx.AsyncClient(trust_env=trust_env)

    # --- 生命周期 ---

    async def aclose(self) -> None:
        if self._owned:
            await self._http.aclose()

    async def __aenter__(self) -> "PetLifeApiClient":
        return self

    async def __aexit__(self, *exc: object) -> None:
        await self.aclose()

    # --- 内部 ---

    @property
    def _headers(self) -> dict[str, str]:
        # 密钥只在这里出现，且只放进请求头
        return {API_KEY_HEADER: self._api_key, "Accept": "application/json"}

    async def _get(self, path: str, params: dict[str, Any]) -> dict[str, Any]:
        url = f"{self.base_url}{path}"
        try:
            response = await self._http.get(
                url,
                params={k: v for k, v in params.items() if v is not None},
                headers=self._headers,
                timeout=self.timeout,
            )
        except httpx.TimeoutException as exc:
            raise PetLifeApiTimeout(
                f"调用 PetLife 服务端超时（{self.timeout:g}s）"
            ) from exc
        except httpx.HTTPError as exc:
            # 不回显底层异常细节（里面可能带 URL；密钥在头里虽不会被带出，
            # 但保持"只给可读结论"的一致性）
            raise PetLifeApiError(
                status_code=0,
                code="network_error",
                message="无法连接 PetLife 服务端（网络不可达或地址配置错误）",
            ) from exc

        if response.status_code >= 400:
            try:
                payload: Any = response.json()
            except ValueError:
                payload = None
            code, message, request_id = _parse_error(response.status_code, payload)
            raise PetLifeApiError(
                status_code=response.status_code,
                code=code,
                message=message,
                request_id=request_id,
            )

        try:
            body = response.json()
        except ValueError as exc:
            raise PetLifeApiError(
                status_code=response.status_code,
                code="malformed_response",
                message="PetLife 服务端返回了无法解析的响应",
            ) from exc

        if not isinstance(body, dict):
            raise PetLifeApiError(
                status_code=response.status_code,
                code="malformed_response",
                message="PetLife 服务端返回了非预期的响应结构",
            )
        return body

    # --- 只读统计 ---

    async def summary(self, *, period: str, timezone_offset_minutes: int) -> dict[str, Any]:
        return await self._get(
            f"{STATS_PREFIX}/summary",
            {"period": period, "tz_offset_minutes": timezone_offset_minutes},
        )

    async def apps(
        self,
        *,
        period: str,
        timezone_offset_minutes: int,
        limit: int | None = None,
    ) -> dict[str, Any]:
        return await self._get(
            f"{STATS_PREFIX}/apps",
            {
                "period": period,
                "tz_offset_minutes": timezone_offset_minutes,
                "limit": limit,
            },
        )

    async def categories(
        self,
        *,
        period: str,
        timezone_offset_minutes: int,
        limit: int | None = None,
    ) -> dict[str, Any]:
        return await self._get(
            f"{STATS_PREFIX}/categories",
            {
                "period": period,
                "tz_offset_minutes": timezone_offset_minutes,
                "limit": limit,
            },
        )

    async def devices(
        self,
        *,
        period: str,
        timezone_offset_minutes: int,
        limit: int | None = None,
    ) -> dict[str, Any]:
        return await self._get(
            f"{STATS_PREFIX}/devices",
            {
                "period": period,
                "tz_offset_minutes": timezone_offset_minutes,
                "limit": limit,
            },
        )

    async def compare(self, *, kind: str, timezone_offset_minutes: int) -> dict[str, Any]:
        return await self._get(
            "/api/v1/integrations/compare",
            {"kind": kind, "tz_offset_minutes": timezone_offset_minutes},
        )

    async def sync_status(self) -> dict[str, Any]:
        return await self._get("/api/v1/integrations/sync-status", {})

    # --- Phase 4B：跨设备云端统计（全部只读） ---

    async def cloud_devices(self) -> dict[str, Any]:
        """密钥对应用户的设备列表。"""
        return await self._get(f"{CLOUD_PREFIX}/devices", {})

    async def usage_summary(
        self,
        *,
        device_id: str | None = None,
        date: str | None = None,
        date_from: str | None = None,
        date_to: str | None = None,
        timezone_name: str | None = None,
        timezone_offset_minutes: int | None = None,
    ) -> dict[str, Any]:
        return await self._get(
            f"{CLOUD_PREFIX}/summary",
            {
                "device_id": device_id,
                "date": date,
                "date_from": date_from,
                "date_to": date_to,
                "timezone": timezone_name,
                "tz_offset_minutes": timezone_offset_minutes,
            },
        )

    async def app_usage(
        self,
        *,
        device_id: str | None = None,
        date: str | None = None,
        date_from: str | None = None,
        date_to: str | None = None,
        timezone_name: str | None = None,
        timezone_offset_minutes: int | None = None,
    ) -> dict[str, Any]:
        return await self._get(
            f"{CLOUD_PREFIX}/apps",
            {
                "device_id": device_id,
                "date": date,
                "date_from": date_from,
                "date_to": date_to,
                "timezone": timezone_name,
                "tz_offset_minutes": timezone_offset_minutes,
            },
        )

    async def usage_sessions(
        self,
        *,
        device_id: str | None = None,
        date: str | None = None,
        date_from: str | None = None,
        date_to: str | None = None,
        timezone_name: str | None = None,
        timezone_offset_minutes: int | None = None,
        app_id: str | None = None,
        cursor: str | None = None,
        limit: int | None = None,
    ) -> dict[str, Any]:
        return await self._get(
            f"{CLOUD_PREFIX}/sessions",
            {
                "device_id": device_id,
                "date": date,
                "date_from": date_from,
                "date_to": date_to,
                "timezone": timezone_name,
                "tz_offset_minutes": timezone_offset_minutes,
                "app_id": app_id,
                "cursor": cursor,
                "limit": limit,
            },
        )

    async def daily_timeline(
        self,
        *,
        device_id: str | None = None,
        date: str | None = None,
        date_from: str | None = None,
        date_to: str | None = None,
        timezone_name: str | None = None,
        timezone_offset_minutes: int | None = None,
        app_id: str | None = None,
    ) -> dict[str, Any]:
        return await self._get(
            f"{CLOUD_PREFIX}/timeline",
            {
                "device_id": device_id,
                "date": date,
                "date_from": date_from,
                "date_to": date_to,
                "timezone": timezone_name,
                "tz_offset_minutes": timezone_offset_minutes,
                "app_id": app_id,
            },
        )


__all__ = [
    "API_KEY_HEADER",
    "CLOUD_PREFIX",
    "STATS_PREFIX",
    "PetLifeApiClient",
    "PetLifeApiError",
    "PetLifeApiTimeout",
]

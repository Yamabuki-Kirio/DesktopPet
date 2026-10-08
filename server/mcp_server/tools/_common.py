"""工具注册的公共依赖与错误映射。

工具函数本身**不接触**密钥、URL、身份来源——它们只调用这里暴露的
``deps.guard(...)`` 并把结果原样返回。这样"错误里不可能出现密钥"是结构性的。

身份模型（本版改动）
--------------------
身份 = ``PETLIFE_API_KEY``（一把密钥一个账户），由 ``PetLifeApiClient`` 在请求头里
带给服务端。因此 ``ToolDeps`` 里没有任何 ``require_identity()``：
**工具参数里既没有 identity，也没有地方能塞 identity**。
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Awaitable, TypeVar

from mcp.server.fastmcp.exceptions import ToolError

from ..client import PetLifeApiClient, PetLifeApiError, PetLifeApiTimeout

T = TypeVar("T")

#: 默认时区偏移（分钟）。AstrBot 应按用户所在时区覆盖它；
#: 默认给 +08:00 是因为本部署的目标用户在中国，避免"忘了传导致今天算错"。
DEFAULT_TZ_OFFSET_MINUTES = 480

_KEY_REJECTED_HINT = (
    "PetLife API 密钥无效或已被撤销。\n"
    "请让用户在 Windows 客户端「账户与同步 → AI 数据访问」里生成一把新密钥"
    "（形如 plk_...），并把新密钥配置到运行本 MCP 的 PETLIFE_API_KEY，然后重启。"
)

_SCOPE_DENIED_HINT = (
    "这把 API 密钥没有只读统计权限（stats:read）。\n"
    "请让用户在客户端重新生成一把密钥（当前只发放只读统计权限）。"
)


@dataclass
class ToolDeps:
    """工具运行期依赖（不含任何身份信息——身份由客户端持有的密钥决定）。"""

    client: PetLifeApiClient
    max_items: int = 50

    def clamp_limit(self, limit: int | None) -> int:
        """调用方只能**收紧**上限，不能超过服务端配置。"""
        cap = max(1, self.max_items)
        if limit is None:
            return cap
        return max(1, min(int(limit), cap))

    async def guard(self, awaitable: Awaitable[T]) -> T:
        """统一把底层异常翻译成**可安全展示**的 ``ToolError``。

        注意：这里只带错误码、可读文案与 request_id，
        **不带** API 密钥、不带服务端堆栈、不带数据库细节。
        """
        try:
            return await awaitable
        except PetLifeApiTimeout as exc:
            raise ToolError(f"{exc}，请稍后重试。") from exc
        except PetLifeApiError as exc:
            # 带上服务端错误码与 request_id（便于对照日志），
            # 但不带密钥——``PetLifeApiError`` 里本来就没有它。
            if exc.is_key_rejected:
                raise ToolError(f"{_KEY_REJECTED_HINT}\n（服务端返回：{exc}）") from exc
            if exc.is_scope_denied:
                raise ToolError(f"{_SCOPE_DENIED_HINT}\n（服务端返回：{exc}）") from exc
            if exc.is_account_unavailable:
                raise ToolError(
                    "这把密钥对应的 PetLife 账户当前不可用（已停用或已注销），无法查询。"
                    f"\n（服务端返回：{exc}）"
                ) from exc
            raise ToolError(f"PetLife 服务端返回错误：{exc}") from exc


def as_dict(payload: Any) -> dict[str, Any]:
    """工具统一返回 ``dict``（FastMCP 会生成结构化输出）。"""
    if isinstance(payload, dict):
        return payload
    return {"result": payload}


__all__ = ["DEFAULT_TZ_OFFSET_MINUTES", "ToolDeps", "as_dict"]

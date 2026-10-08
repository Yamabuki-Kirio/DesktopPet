"""设备统计工具：``petlife_get_devices``。"""

from __future__ import annotations

from typing import Any, Literal

from mcp.server.fastmcp import FastMCP

from ._common import DEFAULT_TZ_OFFSET_MINUTES, ToolDeps, as_dict

Period = Literal["today", "yesterday", "7d", "30d"]


def register(mcp: FastMCP, deps: ToolDeps) -> None:
    @mcp.tool()
    async def petlife_get_devices(
        period: Period = "today",
        timezone_offset_minutes: int = DEFAULT_TZ_OFFSET_MINUTES,
    ) -> dict[str, Any]:
        """按设备拆分某个时间段的使用时长。

        用于回答"我有几台设备在用""每台机器分别用了多久"这类**设备**问题。

        参数：
        - period: today / yesterday / 7d / 30d
        - timezone_offset_minutes: 用户时区偏移（分钟），中国用户是 480

        返回：
        - `items[]`：`device_name`、`platform`、`last_seen_at`、`revoked`（是否已撤销）、
          `session_seconds` / `active_seconds` / `idle_seconds`（均为秒）
        - `total_active_seconds`：各设备活跃时间**求和**
        - `overlap_warning`：服务端给出的重叠提示

        ⚠️ **多设备时间可能重叠**：多台设备同时使用时，把它们相加会大于"人的真实
        使用时间"。回答时必须把这一点说清楚，不要把合计当成"用户实际用了这么久"。
        """
        payload = await deps.guard(
            deps.client.devices(
                period=period,
                timezone_offset_minutes=timezone_offset_minutes,
                limit=deps.clamp_limit(None),
            )
        )
        return as_dict(payload)


__all__ = ["Period", "register"]

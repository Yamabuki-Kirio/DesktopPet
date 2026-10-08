"""分类统计工具：``petlife_get_categories``。"""

from __future__ import annotations

from typing import Any, Literal

from mcp.server.fastmcp import FastMCP

from ._common import DEFAULT_TZ_OFFSET_MINUTES, ToolDeps, as_dict

Period = Literal["today", "yesterday", "7d", "30d"]


def register(mcp: FastMCP, deps: ToolDeps) -> None:
    @mcp.tool()
    async def petlife_get_categories(
        period: Period = "today",
        timezone_offset_minutes: int = DEFAULT_TZ_OFFSET_MINUTES,
    ) -> dict[str, Any]:
        """按应用分类（development / productivity / gaming / social /
        entertainment / browser / system / other）汇总使用时长。

        用于回答"时间主要花在哪类事情上""是不是玩游戏比较多"这类**分类**问题。

        参数：
        - period: today / yesterday / 7d / 30d
        - timezone_offset_minutes: 用户时区偏移（分钟），中国用户是 480

        返回：
        - `items[]`：`category`、`active_seconds`（秒）、
          `ratio_of_app_time`（占应用使用总时间的比例，0~1）
        - `total_app_active_seconds`：应用使用时间合计（秒）

        分类是用户在客户端里可以改的（人工分类优先），因此它就是用户自己的口径。
        没有任何数据时如实说"暂无数据"。
        """
        payload = await deps.guard(
            deps.client.categories(
                period=period,
                timezone_offset_minutes=timezone_offset_minutes,
                limit=deps.clamp_limit(None),
            )
        )
        return as_dict(payload)


__all__ = ["Period", "register"]

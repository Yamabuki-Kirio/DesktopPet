"""应用排行工具：``petlife_get_top_apps``。"""

from __future__ import annotations

from typing import Any, Literal

from mcp.server.fastmcp import FastMCP

from ._common import DEFAULT_TZ_OFFSET_MINUTES, ToolDeps, as_dict

Period = Literal["today", "yesterday", "7d", "30d"]


def register(mcp: FastMCP, deps: ToolDeps) -> None:
    @mcp.tool()
    async def petlife_get_top_apps(
        period: Period = "today",
        limit: int = 10,
        timezone_offset_minutes: int = DEFAULT_TZ_OFFSET_MINUTES,
    ) -> dict[str, Any]:
        """查询某个时间段内使用最多的应用排行。

        用于回答"今天哪个软件用得最多""用得最多的前 5 个应用"这类**排行**问题。

        参数：
        - period: today / yesterday / 7d / 30d
        - limit: 返回条数，默认 10；服务端有上限（默认 50），超出会被截断
        - timezone_offset_minutes: 用户时区偏移（分钟），中国用户是 480

        返回：
        - `items[]`：每个应用含 `app_key`、`display_name`、`category`、
          `active_seconds`（秒）、`segment_count`（活动段数）、
          `ratio_of_app_time`（占**应用使用总时间**的比例，0~1）
        - `total_app_active_seconds`：所有应用使用时间之和（秒）
        - `returned` / `truncated`：实际返回条数与是否被截断；被截断时要如实告诉用户
          "只列出了前 N 个"

        注意：`ratio_of_app_time` 的分母是**应用使用时间**，不是活跃时间或会话时间。
        给用户回答时请把秒换算成易读时长，并说明是"占应用使用时间的比例"。
        """
        payload = await deps.guard(
            deps.client.apps(
                period=period,
                timezone_offset_minutes=timezone_offset_minutes,
                limit=deps.clamp_limit(limit),
            )
        )
        return as_dict(payload)


__all__ = ["Period", "register"]

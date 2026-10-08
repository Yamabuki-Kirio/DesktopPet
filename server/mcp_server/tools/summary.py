"""总览统计工具：``petlife_get_summary``。"""

from __future__ import annotations

from typing import Any, Literal

from mcp.server.fastmcp import FastMCP

from ._common import DEFAULT_TZ_OFFSET_MINUTES, ToolDeps, as_dict

Period = Literal["today", "yesterday", "7d", "30d"]


def register(mcp: FastMCP, deps: ToolDeps) -> None:
    @mcp.tool()
    async def petlife_get_summary(
        period: Period = "today",
        timezone_offset_minutes: int = DEFAULT_TZ_OFFSET_MINUTES,
    ) -> dict[str, Any]:
        """查询某个时间段的电脑使用总览（屏幕会话 / 活跃 / 空闲 / 应用使用时间）。

        用于回答"我今天用了多久电脑""昨天呢""最近 7 天一共多久"这类**总时长**问题。

        口径（务必按此解释，不要混为一谈）：
        - `session_seconds` 屏幕会话时间（解锁且未休眠）；`idle_seconds` 空闲时间**包含在**
          会话时间之内；
        - `active_seconds` 活跃时间（空闲未超阈值的那部分）；活跃时间 ≠ 应用使用时间；
        - `app_active_seconds` 应用使用时间，来自各应用活动段，**不会超过**活跃时间；
        - `device_count` 是**该时间段内有数据的设备数**（不是注册设备数）。

        参数：
        - period: today / yesterday / 7d / 30d
        - timezone_offset_minutes: 用户所在时区相对 UTC 的偏移（分钟），
          决定"今天"的边界；中国用户是 480。

        返回里所有时长单位都是**秒**；给用户回答时请换算成"X 小时 Y 分"，
        不要把秒数原样抛给用户。没有任何数据时如实说"暂无数据"，不要推测。
        """
        payload = await deps.guard(
            deps.client.summary(
                period=period,
                timezone_offset_minutes=timezone_offset_minutes,
            )
        )
        return as_dict(payload)


__all__ = ["Period", "register"]

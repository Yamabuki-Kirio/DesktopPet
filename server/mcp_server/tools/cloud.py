"""Phase 4B：跨设备云端统计工具。

五个工具（全部只读，参数里**没有任何身份字段** —— 用户由个人访问密钥推导）：

* ``petlife_list_devices``        —— 我有哪些设备
* ``petlife_get_usage_summary``   —— 某设备某天的使用总时长
* ``petlife_get_app_usage``       —— 某设备某天各应用用了多久
* ``petlife_get_usage_sessions``  —— 某设备某天某个应用的具体时间段（分页）
* ``petlife_get_daily_timeline``  —— 某设备某天从早到晚的时间线

它们调用的是与手机 App **完全相同的服务端统计函数**（同一个区间并集/重叠去重/
跨午夜拆分实现），因此"MCP 说的时长"和"App 里看到的时长"不会出现两套口径。
"""

from __future__ import annotations

from typing import Any, Literal

from mcp.server.fastmcp import FastMCP

from ._common import DEFAULT_TZ_OFFSET_MINUTES, ToolDeps, as_dict

#: 客户端已有偏移量时用它；有 IANA 时区名时优先用它（更准确）。
Timezone = Literal[
    "Asia/Shanghai",
    "Asia/Tokyo",
    "Asia/Seoul",
    "Asia/Singapore",
    "Asia/Hong_Kong",
    "Asia/Taipei",
    "UTC",
    "Europe/London",
    "Europe/Berlin",
    "America/New_York",
    "America/Los_Angeles",
    "Australia/Sydney",
]


def register(mcp: FastMCP, deps: ToolDeps) -> None:
    @mcp.tool()
    async def petlife_list_devices() -> dict[str, Any]:
        """列出当前账户下的所有设备（电脑 / 手机），用于回答"我有哪几台设备"。

        返回每台设备的：id（后续查询要用它）、名称、平台（windows / android）、
        型号、最近在线时间、是否已撤销。

        用法：先用本工具拿到 device_id，再把它传给
        get_usage_summary / get_app_usage / get_usage_sessions / get_daily_timeline。
        不传 device_id 时那些工具默认汇总**全部设备**。
        没有任何设备时如实说"暂无设备"，不要推测。
        """
        payload = await deps.guard(deps.client.cloud_devices())
        return as_dict(payload)

    @mcp.tool()
    async def petlife_get_usage_summary(
        device_id: str | None = None,
        date: str | None = None,
        date_from: str | None = None,
        date_to: str | None = None,
        timezone: Timezone | None = None,
        timezone_offset_minutes: int = DEFAULT_TZ_OFFSET_MINUTES,
    ) -> dict[str, Any]:
        """查询某台设备在某一天（或某段日期）的电脑使用总时长与各应用占比。

        用于回答"我的电脑今天用了多久""昨天呢""这周各设备分别多久"这类问题。

        参数：
        - device_id: 设备 id（来自 petlife_list_devices）。留空表示**全部设备合计**；
          合计值是各设备时长相加，多台设备并行使用时会有重叠，返回值里的
          overlap_warning 会明确提示，回答时应把这一点告诉用户。
        - date: 单日，格式 YYYY-MM-DD；不传则默认为用户当地的"今天"。
        - date_from / date_to: 日期区间（含两端）。与 date 互斥。
        - timezone: IANA 时区名（如 Asia/Shanghai），决定"哪一天"的边界。
        - timezone_offset_minutes: 没有时区名时的等价替代（中国是 480）。

        返回 total_duration_seconds（总时长，秒）与 apps（按时长降序，
        含 app_id / app_name / duration_seconds / session_count）。
        时长单位都是**秒**，给用户回答时请换算成"X 小时 Y 分"。
        同一设备同一应用的重叠时间段已经去重，不要自己再相加。
        """
        payload = await deps.guard(
            deps.client.usage_summary(
                device_id=device_id,
                date=date,
                date_from=date_from,
                date_to=date_to,
                timezone_name=timezone,
                timezone_offset_minutes=timezone_offset_minutes,
            )
        )
        return as_dict(payload)

    @mcp.tool()
    async def petlife_get_app_usage(
        device_id: str | None = None,
        date: str | None = None,
        date_from: str | None = None,
        date_to: str | None = None,
        timezone: Timezone | None = None,
        timezone_offset_minutes: int = DEFAULT_TZ_OFFSET_MINUTES,
    ) -> dict[str, Any]:
        """查询某台设备在某天各应用分别使用了多久（应用排行）。

        参数含义与 petlife_get_usage_summary 完全一致；返回结构也一致，
        重点是 apps 列表（按时长降序）。

        用于回答"今天电脑上什么用得最多""昨天我用了多久 VS Code"。
        需要看"具体是哪几个时间段"时，请改用 petlife_get_usage_sessions
        并带上对应的 app_id。
        """
        payload = await deps.guard(
            deps.client.app_usage(
                device_id=device_id,
                date=date,
                date_from=date_from,
                date_to=date_to,
                timezone_name=timezone,
                timezone_offset_minutes=timezone_offset_minutes,
            )
        )
        return as_dict(payload)

    @mcp.tool()
    async def petlife_get_usage_sessions(
        device_id: str | None = None,
        date: str | None = None,
        date_from: str | None = None,
        date_to: str | None = None,
        timezone: Timezone | None = None,
        timezone_offset_minutes: int = DEFAULT_TZ_OFFSET_MINUTES,
        app_id: str | None = None,
        cursor: str | None = None,
        limit: int = 50,
    ) -> dict[str, Any]:
        """查询某台设备某天**逐条**使用记录（每条的起止时间与时长）。

        用于回答"昨天 VS Code 是哪几个时间段用的""上午 9 点我在用什么"。
        每条包含：app_id / app_name / started_at / ended_at / duration_seconds /
        device_name。时间是 UTC（带 Z），给用户回答时请换算成其当地时间的
        "HH:MM–HH:MM"。

        参数：
        - app_id: 只看某个应用（例如 code / msedge / wechat）
        - limit: 页大小（服务端有上限）
        - cursor: 分页游标，取上一页返回的 next_cursor；为 null 表示没有更多

        这里是**未合并的原始记录**：同一应用相邻的几段会各占一条，
        回答"一共几段"时不要把它们当成一次连续使用；要看合并后的时间线，
        请用 petlife_get_daily_timeline。
        """
        payload = await deps.guard(
            deps.client.usage_sessions(
                device_id=device_id,
                date=date,
                date_from=date_from,
                date_to=date_to,
                timezone_name=timezone,
                timezone_offset_minutes=timezone_offset_minutes,
                app_id=app_id,
                cursor=cursor,
                limit=limit,
            )
        )
        return as_dict(payload)

    @mcp.tool()
    async def petlife_get_daily_timeline(
        device_id: str | None = None,
        date: str | None = None,
        date_from: str | None = None,
        date_to: str | None = None,
        timezone: Timezone | None = None,
        timezone_offset_minutes: int = DEFAULT_TZ_OFFSET_MINUTES,
        app_id: str | None = None,
    ) -> dict[str, Any]:
        """查询某台设备某天从早到晚的时间线（相邻同应用的记录已合并展示）。

        用于回答"我今天一天的顺序是怎样的""下午我在忙什么"。
        每条包含 app_name / started_at / ended_at / duration_seconds /
        merged_session_count（这条是由几条原始记录合并而来）。

        说明：
        - 合并只用于**展示**：相邻间隔 ≤ 60 秒的同应用记录会合并成一条；
        - 每条 duration_seconds 仍是这些记录时间段的**并集**，
          不是首尾相减，因此不要把显示的间隔当成真实使用时长；
        - 不同设备、不同应用绝不合并。
        """
        payload = await deps.guard(
            deps.client.daily_timeline(
                device_id=device_id,
                date=date,
                date_from=date_from,
                date_to=date_to,
                timezone_name=timezone,
                timezone_offset_minutes=timezone_offset_minutes,
                app_id=app_id,
            )
        )
        return as_dict(payload)


__all__ = ["Timezone", "register"]

"""趋势与同步状态工具：``petlife_compare_periods`` / ``petlife_get_sync_status``。"""

from __future__ import annotations

from typing import Any, Literal

from mcp.server.fastmcp import FastMCP

from ._common import DEFAULT_TZ_OFFSET_MINUTES, ToolDeps, as_dict

CompareKind = Literal["today_vs_yesterday", "week_vs_last_week", "last7_vs_previous7"]


def register(mcp: FastMCP, deps: ToolDeps) -> None:
    @mcp.tool()
    async def petlife_compare_periods(
        kind: CompareKind = "today_vs_yesterday",
        timezone_offset_minutes: int = DEFAULT_TZ_OFFSET_MINUTES,
    ) -> dict[str, Any]:
        """对比两个时间段的使用情况，回答"这周和上周比怎么样""今天比昨天多吗"。

        参数：
        - kind:
          - `today_vs_yesterday`：今天 vs 昨天（两个完整自然日）
          - `week_vs_last_week`：本周 vs 上周，**两侧都只取相同已过时长**
            （从周一 00:00 到现在），避免拿没过完的一周去比完整一周
          - `last7_vs_previous7`：最近 7 个自然日 vs 紧邻的前 7 个自然日
        - timezone_offset_minutes: 用户时区偏移（分钟），中国用户是 480

        返回：
        - `current` / `previous`：两侧的 `label` 与汇总秒数（含 `from_utc`/`to_utc`）
        - `active_seconds_delta` / `app_active_seconds_delta`：差值（秒）
        - `*_change_ratio`：变化比例（0.5 表示增长 50%）。
          **为 null 时表示上一时段没有任何数据**，此时**不要**编造百分比，
          只需说"上一次没有记录，无法比较"
        - `has_data`：两个窗口是否都没有数据
        - `note`：服务端给出的口径说明，可直接引用

        回答时请给出"变化了多少"（易读时长）与方向，而不是只报一个百分比。
        """
        payload = await deps.guard(
            deps.client.compare(
                kind=kind,
                timezone_offset_minutes=timezone_offset_minutes,
            )
        )
        return as_dict(payload)

    @mcp.tool()
    async def petlife_get_sync_status() -> dict[str, Any]:
        """查询电脑数据是否正常同步（数据新鲜度）。

        用于回答"数据同步了吗""为什么数据看起来是旧的""我有几台设备"。

        无需参数：能查到哪个账户由服务端配置的 API 密钥决定，不在参数里指定。

        返回：
        - `registered_device_count`：注册且未撤销的设备数
          （注意这与总览里的 `device_count` 口径不同，后者是"窗口内有数据的设备数"）
        - `last_data_received_at`：服务端最近一次收到同步数据的时间（UTC）
        - `last_activity_at`：最近一次活动段开始时间（UTC）
        - `data_may_be_stale`：true 表示超过阈值没有新数据
        - `stale_after_minutes`：判定阈值（分钟）
        - `note`：可读说明，可直接引用

        ⚠️ 这里**不含**任何令牌、设备密钥或内部错误信息；如果用户问"同步失败的原因"，
        只能根据 `data_may_be_stale` 与 `note` 给出排查建议（客户端是否在运行、
        网络是否可达、是否已登录），不要臆测具体错误。
        """
        payload = await deps.guard(
            deps.client.sync_status()
        )
        return as_dict(payload)


__all__ = ["CompareKind", "register"]

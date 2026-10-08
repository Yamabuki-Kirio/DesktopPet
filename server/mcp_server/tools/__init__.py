"""MCP 只读工具集合。

工具清单（全部**只读**，且都不接受身份参数 —— 用户由个人访问密钥推导）：

按「区间」查询（Phase 3 既有）：

| 工具 | 用途 |
|---|---|
| ``petlife_get_summary`` | 总览：会话 / 活跃 / 空闲 / 应用使用时间 |
| ``petlife_get_top_apps`` | 应用使用排行 |
| ``petlife_get_categories`` | 分类使用时长与占比 |
| ``petlife_get_devices`` | 按设备拆分（含重叠提示） |
| ``petlife_compare_periods`` | 两个时段对比 |
| ``petlife_get_sync_status`` | 数据新鲜度 |

按「设备 + 日期」查询（Phase 4B 新增，与手机 App 同一套统计数据）：

| 工具 | 用途 |
|---|---|
| ``petlife_list_devices`` | 我有哪些设备（拿 device_id） |
| ``petlife_get_usage_summary`` | 某设备某天的总时长 + 各应用占比 |
| ``petlife_get_app_usage`` | 某设备某天的应用排行 |
| ``petlife_get_usage_sessions`` | 某设备某天逐条使用记录（可看具体时间段） |
| ``petlife_get_daily_timeline`` | 某设备某天的全天时间线 |

这里**没有、也不会有**"执行 SQL"或"任意查询"的工具：所有数据都由 PetLife API
在自己的统计服务里算好，MCP 只是搬运。
"""

from __future__ import annotations

from mcp.server.fastmcp import FastMCP

from ._common import ToolDeps
from . import applications, categories, cloud, devices, insights, summary


def register_all(mcp: FastMCP, deps: ToolDeps) -> None:
    summary.register(mcp, deps)
    applications.register(mcp, deps)
    categories.register(mcp, deps)
    devices.register(mcp, deps)
    insights.register(mcp, deps)
    # Phase 4B：跨设备云端统计（按设备 + 日期）
    cloud.register(mcp, deps)


__all__ = ["ToolDeps", "register_all"]

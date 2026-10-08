# 27 - Android 使用统计口径

> ⚠️ **本阶段（Phase 4A）Android 不采集任何使用数据。**
> 本文记录的是"已经确定的口径决策"与"为什么不能照搬 Windows 口径"，
> 具体实现属于 Phase 4B，**尚未落地**。文中每一条都标注了状态。

## 1. 当前状态（Phase 4A）

| 项 | 状态 |
|---|---|
| 前台应用采集（`UsageStatsManager`） | ❌ 未实现 |
| 使用情况访问权限申请与引导 | ❌ 未实现 |
| Android 活动段写入 `activity_segments` | ❌ 未实现 |
| Android 每日汇总写入 `daily_usage` | ❌ 未实现 |
| 查看服务端已有统计（Windows 上传的） | ✅ 可用 |
| 手动同步 | ✅ 可用 |

因此 Android 端「使用统计」页在导航上标注为「使用统计（本机）」，
桌宠页会显示一段平台说明（`MobilePlatformNotice`）明确告知：
**这一版还没有启用采集；桌宠、登录、同步与已上传的统计都可正常使用，但本机不会新增使用记录。**

## 2. 数据来源与字段（Phase 4B 设计，未实现）

计划采集（与 Windows 的 `activity_segments` 对齐）：

| 字段 | 来源 |
|---|---|
| `app_key` | package name（如 `com.tencent.mm`） |
| `app_name` | 应用显示名（`PackageManager`） |
| `category` | 复用现有 `ApplicationClassifier` + 用户在客户端的覆盖 |
| `started_at` / `ended_at` | `UsageEvents` 中 `ACTIVITY_RESUMED` / `ACTIVITY_PAUSED` 的时间戳 |
| `active_seconds` | 段长（见 §4 的口径约束） |
| `device_local_id` | 复用 `DeviceIdentity`（稳定 UUID） |

设备级每日汇总复用现有 `daily_usage`（`session_seconds` / `active_seconds` / `idle_seconds`）。

## 3. 明确禁止采集的内容（不会因为进入 4B 而改变）

页面内容、输入内容、通知正文、网页 URL、文件名、聊天内容、无障碍界面树、
已安装应用全量列表、位置。只记录 **应用包名 / 显示名 / 分类 / 起止时间 / 时长**。

## 4. 与 Windows 的关键口径差异（必须先说清楚）

Android **没有**与 Windows `GetLastInputInfo` 等价的"全局最后一次输入时间"来源，因此：

| 指标 | Windows | Android（计划口径） |
|---|---|---|
| 屏幕会话时间 | 解锁且未休眠的时长 | 屏幕亮且未锁定的时长（`PowerManager` + `KeyguardManager`） |
| 应用使用时间 | 前台窗口进程 + 活动段 | `UsageEvents` 前台段 |
| **空闲时间** | `GetLastInputInfo` **精确**判定 | **不提供精确值**；无法可靠确定的"屏幕亮但用户没操作"时间**不得**假装成精确空闲 |
| 活跃时间 | 会话 − 空闲 | **不计算**（或按平台口径单独标记） |

由此确定的硬约束：

1. **屏幕关闭与锁定时间不计入任何应用使用时长**（切段时必须关闭当前段）；
2. Android 的 `idle_seconds` 应显式标记为**平台口径**，UI 与服务端展示必须避免
   与 Windows 的精确空闲时间混为一谈（例如标注"（Android 口径）"）；
3. 不允许为了"看起来和 Windows 一致"而编造空闲数字或活跃时间；
4. 跨平台汇总时，"活跃时间"不跨平台相加；应用使用时间可以相加，但多设备重叠提示必须保留。

## 5. 采集状态机（Phase 4B 设计，未实现）

```
无权限   → 引导用户授予「使用情况访问权限」，不采集
已暂停   → 用户主动暂停，不采集（桌宠/登录/同步/已有统计不受影响）
屏幕关闭 → 关闭当前段
设备锁定 → 关闭当前段
空闲/无有效前台应用 → 不产生新段
正在使用某应用 → 产生/延续活动段
采集异常 → 记录状态与原因，降级为不采集（绝不写入疑似脏数据）
```

## 6. 与服务端的关系（已确定的复用点）

* 上传协议不变：仍走 `sync/push`（`activity_segments` / `daily_usage` / `applications`），
  记录 ID 使用稳定 UUID，**幂等**（同一批重复上传不会翻倍）；
* 统计口径不变：服务端 `stats_service` / `integration_stats_service` 一行未改，
  因此 MCP / AstrBot 查询到的数字与客户端一致；
* 多设备汇总不变：`/stats/devices` 与 MCP 的设备工具继续带"多设备时间可能重叠"的提示；
* 服务端必须能把两台设备区分开：`devices.platform` 取 `windows` / `android`
  （Phase 4A 已放宽平台与架构白名单，见 docs/29 §2）。

## 7. 验收时必须人工确认的点（Phase 4B）

1. 授权前不采集（数据库里没有新增活动段）；
2. 授权后切换多个应用，统计能更新且包名/显示名正确；
3. 锁屏与关屏期间不累计应用时长；
4. 暂停后停止增长；
5. 重启应用后不重复累计（检查点恢复）；
6. 同一批数据重复上传不翻倍；
7. 服务端能区分 Windows 与 Android 设备；
8. Telegram AI 通过 MCP 能查到 Android 数据，且多设备汇总仍显示重叠提示。

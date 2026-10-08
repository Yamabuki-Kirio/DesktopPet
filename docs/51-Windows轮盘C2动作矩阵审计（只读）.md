# 51 · Windows 正式轮盘 **C2 全业务接入** —— 只读审计（动作矩阵 + 服务清点）

> 本文件是增量 **C2** 实施前的 **只读审计结论**（需求 §2）。
> 审计**未修改任何代码**；实施见 `docs/52-Windows轮盘C2全部业务接入交付说明.md`。
> 代码事实基准：`lib/menu/menu_contract.dart`（`MenuCatalog`）、
> `lib/ui/overlay_menu_actions.dart`（`MenuActionIds.canonical` / `OverlayMenuActionExecutor`）、
> `lib/platform/windows/windows_menu_action_executor.dart`、
> `lib/ui/desktop/desktop_menu_action_bridge.dart`、
> `lib/ui/desktop/fixed_canvas_probe.dart`（`_runAction`）。

---

## 0. 一句话结论

**业务实现基本都在，缺的是"最后一跳"的接线。**
Android 侧 `OverlayMenuActionExecutor` 已经实现了全部 17 个 canonical 动作；
`DesktopMenuActionBridge` 已经把 Windows 的 `AppServices` 装配进同一个执行器。
**真正的缺口只有 3 类**：

1. `WindowsMenuActionExecutor._dispatchBusiness` 对 **6 个记录 / 同步动作**返回
   统一占位文案 `记录与同步功能将在增量 C2 接入`（`c2Notice`）；
2. **2 个只读信息项**（`pet_current` / `records_app`）落进兜底分支，返回
   `Windows 尚未接入该业务动作`；
3. `settings_open` 只"打开面板"、**不导航到设置页**（与 `tools_open_app` 无差别）。

外加一条**重复实现**：`pet_auto` / `appearance_*` 在 Windows 由 host 回调
**另写一遍**（`toggleAutomaticState` 是"开关"，而 canonical 的 `pet_auto` 是"只开启"），
违反需求 §3.1「唯一业务入口 / 不得复制业务逻辑」。

---

## 1. 动作矩阵（§2.1）

约定：**以代码里的真实 id 为准**，不按中文名猜 id。
"—"= 该项无独立处理器（由菜单栈即时处理）。

### 1.1 根菜单 `root`

| 层级 | 显示名 | actionId | canonicalId | 当前处理器 | 当前状态 | 目标行为 |
| --- | --- | --- | --- | --- | --- | --- |
| root | 桌宠 | `open_pet` | —（导航） | `MenuStack.push('pet')` | ✅ 正常 | 进入桌宠子菜单 |
| root | 形象 | `open_appearance` | —（导航） | `MenuStack.push('appearance')` | ✅ 正常 | 进入形象子菜单 |
| root | 记录 | `open_records` | —（导航） | `MenuStack.push('records')` | ✅ 正常 | 进入记录子菜单 |
| root | 工具 | `open_tools` | —（导航） | `MenuStack.push('tools')` | ✅ 正常 | 进入工具子菜单 |
| root | 设置 | `open_settings` | —（导航） | `MenuStack.push('settings')` | ✅ 正常 | 进入设置子菜单 |
| root | 隐藏 | `root_hide` | `root_hide`※ | `_dispatchNative` → `host.setPetVisible(false)` | ✅ 正常 | 隐藏桌宠（服务继续） |

※ `root_hide` 是 Windows 原生窗口 id，**不在** 17 个 canonical 里（与 Android 原生 id 逐字一致）。

### 1.2 桌宠子菜单 `pet`

| 层级 | 显示名 | actionId | canonicalId | 当前处理器 | 当前状态 | 目标行为 |
| --- | --- | --- | --- | --- | --- | --- |
| pet | 缩小 | `pet_size_down` | `pet_size_down`※ | `host.decreasePetScale` | ✅ 正常 | 桌宠缩放 −1 |
| pet | 放大 | `pet_size_up` | `pet_size_up`※ | `host.increasePetScale` | ✅ 正常 | 桌宠缩放 +1 |
| pet | 恢复默认 | `pet_size_reset` | `pet_size_reset`※ | `host.resetPetScale`（scale=2.0） | ✅ 正常 | 恢复默认大小 |
| pet | 自动状态 | `pet_auto` | `pet_auto` | **host 自写 toggle**（重复实现） | ⚠️ 与 canonical 语义不一致 | 收敛到 canonical |
| pet | 当前状态 | `pet_current` | —（info） | 兜底分支 | ❌ 提示"尚未接入" | 只读展示当前状态 |
| pet | 重置位置 | `pet_home` | `pet_home`※ | `host.resetPetPosition` | ✅ 正常 | 安全重建画布回默认角落 |
| pet | 返回 | `back` | —（导航） | `wheel.back()` | ✅ 正常 | 回根层 |

### 1.3 形象子菜单 `appearance`

| 层级 | 显示名 | actionId | canonicalId | 当前处理器 | 当前状态 | 目标行为 |
| --- | --- | --- | --- | --- | --- | --- |
| appearance | 上一张 | `appearance_prev` | `appearance_prev` | host → bridge → canonical | ✅ 正常 | 上一素材 |
| appearance | 下一张 | `appearance_next` | `appearance_next` | host → bridge → canonical | ✅ 正常 | 下一素材 |
| appearance | 自动形象 | `appearance_auto` | `appearance_auto` | host → bridge → canonical | ✅ 正常 | 解除 manual 锁定 |
| appearance | 收藏 | `appearance_fav` | `appearance_fav` | host → bridge → canonical | ✅ 正常 | 收藏当前素材 |
| appearance | 编辑状态素材 | `appearance_mapping` | `appearance_mapping` | host → bridge → canonical | ✅ 正常 | 打开状态映射页 |
| appearance | 打开素材库 | `appearance_library` | `appearance_library` | host → bridge → canonical | ✅ 正常 | 打开素材库页 |
| appearance | 返回 | `back` | —（导航） | `wheel.back()` | ✅ 正常 | 回根层 |

### 1.4 记录子菜单 `records`

| 层级 | 显示名 | actionId | canonicalId | 当前处理器 | 当前状态 | 目标行为 |
| --- | --- | --- | --- | --- | --- | --- |
| records | 今日时长 | `records_today` | `records_today` | **`c2Notice`** | ❌ 占位 | 轮盘内直接显示今日时长 |
| records | 当前应用 | `records_app` | —（info） | 兜底分支 | ❌ 提示"尚未接入" | 只读展示当前前台应用 |
| records | 本机统计 | `records_stats` | `records_stats` | **`c2Notice`** | ❌ 占位 | 导航到「使用统计·本机」 |
| records | 云端记录 | `records_cloud` | `records_cloud` | **`c2Notice`** | ❌ 占位 | 导航到「使用统计·云端」 |
| records | 返回 | `back` | —（导航） | `wheel.back()` | ✅ 正常 | 回根层 |

### 1.5 工具子菜单 `tools`

| 层级 | 显示名 | actionId | canonicalId | 当前处理器 | 当前状态 | 目标行为 |
| --- | --- | --- | --- | --- | --- | --- |
| tools | 暂停采集 | `records_track` | `records_track` | **`c2Notice`** | ❌ 占位 | 切换采集暂停（复用 `saveTrackingSettings`） |
| tools | 立即同步 | `records_sync` | `records_sync` | **`c2Notice`**（未登录先 `requires_login`） | ❌ 占位 | 走 `SyncEngine.syncNow(manual:true)` |
| tools | 同步状态 | `records_sync_state` | `records_sync_state` | **`c2Notice`** | ❌ 占位 | 只读回报同步状态 |
| tools | 打开 PetLife | `tools_open_app` | `tools_open_app`※ | `host.openControlPanel` | ✅ 正常 | 打开控制面板 |
| tools | 返回 | `back` | —（导航） | `wheel.back()` | ✅ 正常 | 回根层 |

### 1.6 设置子菜单 `settings`

| 层级 | 显示名 | actionId | canonicalId | 当前处理器 | 当前状态 | 目标行为 |
| --- | --- | --- | --- | --- | --- | --- |
| settings | 轮盘主题 | `settings_theme` | `settings_theme` | 菜单栈调整层（`wheelAdjust`） | ✅ 正常 | 进调整层，就地切主题 |
| settings | 轮盘大小 | `settings_wheel_size` | `settings_wheel_size` | 菜单栈调整层 | ✅ 正常 | 进调整层，±步进 |
| settings | 按钮大小 | `settings_button_size` | `settings_button_size` | 菜单栈调整层 | ✅ 正常 | 进调整层，±步进 |
| settings | 菜单距离 | `settings_menu_distance` | `settings_menu_distance`★ | 菜单栈调整层 | ✅ 正常 | 进调整层，±步进 |
| settings | 完整设置 | `settings_open` | `settings_open` | `host.openControlPanel`（**不选页签**） | ⚠️ 与"打开 PetLife"无差别 | 导航到「设置」页 |
| settings | 返回 | `back` | —（导航） | `wheel.back()` | ✅ 正常 | 回根层 |

★ `settings_menu_distance` 是 **Windows 新增** id（`WindowsOnlyActionIds`），刻意不进 canonical 集合。
※ `pet_size_*` / `pet_home` / `tools_open_app` 是 Windows 原生窗口 id（与 Android 原生 id 逐字一致）。

---

## 2. 现有服务清点（§2.2）

**全部复用，不新建**。装配点：`lib/app/app_scope.dart`（`AppServices`）。

| 能力 | 服务 / 入口 | 备注 |
| --- | --- | --- |
| 桌宠显示 / 隐藏 | `AppServices.windowController.setVisible` | `root_hide` 已接 |
| 当前角色 / 素材 | `stateEngine.snapshots`（`StateSnapshot.currentCharacter / currentAsset`） | bridge 已用 |
| 状态素材映射 | `StateEngine.lockManual` / `releaseManual` | bridge 已用 |
| 桌宠大小 | `SettingsController.setScale` + `windowController.applySettings` | `pet_size_*` 已接 |
| 轮盘主题 / 大小 / 按钮 / 距离 | `SettingsController.setWheelThemeId / setWheelScale / setWheelButtonScale / setWheelMenuDistance` | 调整层已接 |
| 本机使用统计 | `UsageAnalyticsService.summarize(UsageAnalyticsService.windowFor(UsageRange.today))` | canonical 已用 |
| 云端统计 | `CloudStatisticsRepository` / `CloudStatisticsCache` / `CloudStatisticsController` | 页面已用 |
| 时间线 | `ActivitySegmentService` + `UsageAnalyticsService`（「使用统计」页） | 页面已用 |
| 设备列表 | `authenticatedApi.lastAccount` + 云端统计设备选择器 | 页面已用 |
| 登录 / 账户 | `AuthenticatedApi`（`isSignedIn` / `lastAccount` / `needsReauthentication` / `deviceServerId`） | bridge 已用 |
| 同步协调器 | `SyncEngine`（`syncNow(manual:true)`、单任务互斥 `_running`） | canonical 已用 |
| 待上传队列 | `SyncOutboxDao` / `SyncEngine.pendingCount` | canonical 已用 |
| 网络状态 | `SyncStatus.waitingForNetwork` + `AuthenticatedApi.proxyResolution` | canonical 已用 |
| 日志目录 | `AppPaths.instance.root` / `logFile` | 诊断页已用 |
| 开机自启 | `StartupRegistrationService` | 设置页已用 |
| 控制面板导航 | `AppNavigationController` + `DesktopShell._applyDestination` | bridge 已用 |
| 应用退出流程 | `DesktopShell._exitApp` → `AppServices.shutdown()` | 托盘已用 |
| 当前前台应用 | `CurrentActivityProvider` / `ActivityTracker.currentAppDisplayName` | 统计页已用 |
| 采集暂停 | `AppServices.saveTrackingSettings` | canonical 已用 |

**结论**：轮盘只需要做**入口**，**不得**复制统计 / 同步 / 数据库 / HTTP 逻辑。
现有 `DesktopMenuActionBridge` 正是这条"复用通道"。

---

## 3. 八条链路现状（需求指定的接入点）

| 链路 | 现状 | 缺口 |
| --- | --- | --- |
| 唯一业务入口 | `WindowsMenuActionExecutor.execute` + `DesktopMenuActionBridge.run` | 未收敛：`pet_auto`/`appearance_*` 另有 host 自写实现 |
| 菜单栈（进入 / 返回） | `WheelMenuController.enterLayerByAction` / `back` + `MenuStack` | 无 |
| 动作ID注册表 | `MenuActionDefinitions.all`（导航 / 窗口 / 调整 / canonical / info） | 无**完整性校验**；兜底分支会静默给"尚未接入" |
| 面板导航 | `AppNavigationController` + `DesktopShell._applyDestination` | `AppDestination` 只有 6 项，**无** `Diagnostics`；无强类型 `PanelDestination` |
| 轮盘反馈 | `_presentActionResult` → `_onWheelFeedback` | 无 `WheelFeedbackKind`；无 busy 视觉 |
| 忙碌 / 幂等 | `_actionLedger`（requestId 去重）+ `_inFlightActions` + 晚到结果丢弃 | 已满足 §8.2 / §13.2 |
| 同步并发 | `SyncEngine._running` 互斥（既有 `sync_engine_test.dart` 已钉） | 无上/下行**摘要**（§8.1） |
| 日志 | `wheelGeometryJournal` + `Loggers.*` | 缺 §14 的 `wheel.action.* / wheel.navigation.* / wheel.sync.*` 事件族 |

---

## 4. 归因结论（§2.3 六类）

| 类别 | 动作 |
| --- | --- |
| ① 已有正式业务，**只缺轮盘接线** | `records_today`、`records_stats`、`records_cloud`、`records_track`、`records_sync`、`records_sync_state` |
| ② 已接入且正常 | 根菜单 5 个导航 + `root_hide`；`pet_size_down/up/reset`、`pet_home`；`appearance_prev/next/auto/fav/mapping/library`；`tools_open_app`；`settings_theme/wheel_size/button_size/menu_distance`（调整层）；全部 `back` |
| ③ **Windows 可实现但缺处理器** | `pet_current`（只读：当前状态）、`records_app`（只读：当前应用）、`settings_open`（应导航到设置页而非仅开面板） |
| ④ 仅 Android 支持 | **无**。17 个 canonical 全部跨端；差异只在实现通道（Android 原生悬浮窗 / Windows 本地服务），已由 `DesktopMenuActionBridge` 抹平 |
| ⑤ 废弃或重复 | `pet_auto` / `appearance_*` 的 **Windows host 自写实现**（与 canonical 重复，且 `pet_auto` 语义不一致） |
| ⑥ 后续阶段 | **无**（本增量应清零） |

### 扫描到的"占位 / 泛化"字串（§15）

| 位置 | 字串 | 处理 |
| --- | --- | --- |
| `windows_menu_action_executor.dart` | `c2Notice = '记录与同步功能将在增量 C2 接入'`（6 处） | **删除**，改为真实接线 |
| 同上 | `'Windows 尚未接入该业务动作：$actionId'`（default 分支） | **删除**，改为**注册表完整性校验**：装配期/测试期即失败 |
| 同上 | `'Windows 未实现的窗口动作：$actionId'`（native default） | **保留但收窄**：注册表校验保证不可达；保留为防御性断言 |
| `fixed_canvas_probe.dart` | `'动作执行器未装配，暂时无法执行「…」'` | 保留（真实装配缺失，非占位） |

**未发现**：`unsupported` / `not implemented` / `未支持` / `暂未实现` / 旧 Probe action / 测试菜单 action / 重复 canonical ID。

---

## 5. 实施计划（审计后立即执行，§17）

- **C2-A**：`lib/menu/wheel_action_dispatch.dart` —— `WheelMenuActionDispatcher` 接口、
  `MenuActionContext`、`sealed class PanelDestination`、`WheelFeedbackKind`、
  `WheelActionRegistry`（叶子动作 ↔ 处理器唯一映射 + `validate()`）。
- **C2-B**：`WindowsMenuActionExecutor` 收敛为**唯一业务入口**：
  全部 `dartAction` → `host.dispatchBusiness`（→ `DesktopMenuActionBridge` → canonical 执行器）；
  删除 `c2Notice` 与泛化 default；`pet_current` / `records_app` 只读处理器；
  `settings_open` 改为 `PanelDestination.settings` 导航；同步摘要。
- **C2-C**：反馈 + 忙碌态 + §14 日志；§16 测试；冻结回归；**只构建一次** `build_incrC2`。

**边界自查**：不改菜单尺寸/几何/动画时间；不重写固定画布 / Region / `WheelPointerState` /
`WheelHitTester` / 扇形角度 / `anchorIndex` / `WheelPlacementSolver` / 六种布局 / 右键菜单 /
控制面板定位；不扩大透明输入区域；不用延时修时序；业务处理器不碰 Region；**不改 Android 代码**。

# 52 · Windows 正式轮盘 **全部业务接入（增量 C2）** 交付说明

> 范围：**只做"最后一跳"的业务接线** —— 统一动作分发契约、业务动作全量路由、
> 只读信息项、控制面板强类型导航、同步摘要、反馈 / 忙碌 / 日志、注册表完整性校验、测试。
> **冻结**（需求 §1，逐字不动）：`RegionCoordinator` / `WheelInteractionState` /
> `WheelPointerState` / `WheelHitTester` / 扇形角度与 7° 滞回 / `anchorIndex` /
> `WheelPlacementSolver` / 六种布局 / `WheelSpaceSnapshot` / alpha 上下界 /
> CanvasPlan 与 Painter / Region / HitTest 共享 / P3P 视觉 / 拖拽 / 点击穿透 /
> 右键菜单 / 控制面板定位；**不改菜单几何 / 动画 / Region / Android 代码**。
>
> 前置：`docs/51-Windows轮盘C2动作矩阵审计（只读）.md`（本文 §2 的审计结论）。
> 本文即需求 **§0–§20** 的落地交付。

---

## 1. 目标（需求 §0）

正式轮盘里的**每个**叶子动作都要有**真实业务**，且：

1. 只有一个业务入口，菜单 Widget / Painter / HitTest / 动画 / Region 层不直接碰业务；
2. 每个叶子动作**有且仅有**一个处理器；
3. 正式目录里**零**泛化的"未支持的菜单动作 / 尚未接入 / 增量 C2 接入"字样；
4. 未登录 / 离线 / 失败 / 进行中都有**明确中文反馈**，长任务有**忙碌态**且**幂等**；
5. 控制面板导航用**强类型**目的地键（禁止中文文案做路由）。

---

## 2. 只读审计结论（§2，详见 doc 51）

**一句话：业务实现基本都在，缺的是"最后一跳"的接线。**

Android 侧 `OverlayMenuActionExecutor` 已实现全部 **17 个 canonical** 动作；
`DesktopMenuActionBridge` 已把 Windows 的 `AppServices` 装配进**同一个**执行器。
真正的缺口只有 3 类 + 1 条重复实现：

| # | 缺口 | 位置 | 处置 |
| --- | --- | --- | --- |
| ① | 6 个记录 / 同步动作返回占位 `c2Notice = '记录与同步功能将在增量 C2 接入'` | `windows_menu_action_executor.dart` | 删占位 → 真实接线 |
| ② | 2 个只读信息项（`pet_current` / `records_app`）落兜底，返回 `Windows 尚未接入该业务动作` | 同上 | 新增只读处理器，回报**真实状态** |
| ③ | `settings_open` 只"打开面板"、**不导航到设置页**（与 `tools_open_app` 无差别） | 同上 | 改为 `PanelDestination.settings` 导航 |
| ④ | `pet_auto` / `appearance_*` 在 Windows host 回调里**另写一遍**（`toggleAutomaticState` 是"开关"，canonical 的 `pet_auto` 是"只开启"，语义不一致） | `desktop_shell.dart` | **删除** host 自写实现，收敛到 canonical |

归因（§2.3 六类）：① 缺接线（6 项）；② 已正常（其余）；③ Windows 可实现但缺处理器（3 项）；
④ **无** Android 独有；⑤ 重复实现（`pet_auto` / `appearance_*`）；⑥ **无**后续阶段（本增量清零）。

> 落点：`docs/51-Windows轮盘C2动作矩阵审计（只读）.md` §1（全量动作矩阵）、
> §2（服务清点）、§3（八条链路现状）、§4（归因 + 占位字串扫描）。

---

## 3. 决策（对应需求 §3–§15）

### 3.1 唯一业务入口（§3.1 / §3.2 / §3.3）

- 新增 `lib/menu/wheel_action_dispatch.dart`（**纯 Dart、平台中立**）：
  - `abstract interface class WheelMenuActionDispatcher`：`dispatch(canonicalActionId, MenuActionContext)`；
  - `MenuActionContext`：`transactionId / invokedAt / surfaceMode / menuLevel /
    isAuthenticated / accountSessionId / currentDeviceId` + `toLogFields()`（**当次快照**，不落长生存期字段）；
  - `MenuExecutionResult` 扩展：新增 `PanelDestination? navigation` 与 `bool closeMenu`；
    `success(...)` 在带目的地时**自动** `closeMenu = true`；
    `requiresLogin(..., navigation:)` 也可携带目的地（→ 去登录）。
- `WindowsMenuActionExecutor` **实现**该接口，且 `dispatch` 内 `assert` 拦截菜单栈动作。
- **菜单 Widget / Painter / HitTest / 动画 / Region 层只依赖接口**，不 import 任何具体服务。

### 3.2 动作注册表 + 完整性校验（§3.4 / §15）

- `abstract final class WheelActionRegistry`（同文件）：**从 `MenuCatalog` 派生**，不手写第二份 id 清单
  （手写清单一定会漂移，而那正是"点下去提示未支持"的根源）。
  - `WheelActionRoute`：`menuStack / nativeWindow / business / info / wheelAdjust`（来自 `MenuActionDefinitions.of`）；
  - `leafActionIds`（去菜单栈动作）、`routes`、`businessActionIds`；
  - `validate()` 返回问题清单（空 = 通过），`assertValid()` 抛 `StateError`。
- **装配期**（`DesktopShell._bootstrapAsync` 开头）与**测试期**都调用 `assertValid()` ——
  往菜单目录加了新条目却忘接业务，会**立即变成启动 / 测试失败**，而不是运行期一句"尚未接入"。

### 3.3 菜单栈动作不进业务分发（§4）

`back` / `open_pet` / `open_appearance` / `open_records` / `open_tools` / `open_settings`
由 `WheelMenuController.enterLayerByAction` / `back` + `MenuStack` 即时处理；
执行器若收到导航项（防御）→ `unavailable` + 明确原因；调整层入口同理（由菜单栈就地进层）。

### 3.4 只读信息项（§5 / §7）

`pet_current` / `records_app` 由 `WindowsMenuActionExecutor._dispatchInfo` 回报**真实状态**：

- `pet_current` → `状态引擎快照`：`当前状态：<state> · <emotion>/<variant>`（复用 `StateSnapshot`，**不新建口径**）；
- `records_app` → `当前前台应用：<displayName>`（复用 `ActivityTracker.currentAppDisplayName`）。

### 3.5 控制面板强类型导航（§12）

- 新增 `sealed class PanelDestination`（`menu_contract.dart`），9 个目的地：
  `petHome / localUsage / cloudUsage / timeline / accountSync / assetLibrary / stateMapping / settings / diagnostics`；
  每个有稳定 `wireName`（snake_case）、`fromWire`、`all`。
- **为什么另立而**不**扩展 `AppDestination`**：后者被 Android `mobile_shell.dart` **穷举 switch** 消费，
  加一个值就会让 Android 编译失败 —— 而需求 §1 明令不得改 Android。
- `DesktopMenuActionBridge.mapAppDestination(AppDestination) → PanelDestination?` 是**唯一映射点**；
  外壳 `_applyDestination(PanelDestination)` 在 `openPanel()` 事务**完成之后**再 `panel.selectTab(tab)`
  （**不使用任何固定延时**），并按 `wheel.navigation.begin/ready/failed` 留痕。
- `PanelPetHome` = 关闭面板返回桌宠（§12.3），**不是**某个页签。

### 3.6 同步：单任务幂等 + 摘要（§8）

- **不做第二份同步实现**：同步本身仍由 `SyncEngine.syncNow(manual:true)` 跑（引擎内部单任务互斥）。
- `DesktopMenuActionBridge._runSync()`：`isSyncing` 时**如实回报**"同步正在进行"（不并发）；
  否则调 canonical，再用**引擎自己的状态 + 摘要**翻译文案。
- `SyncEngine` 新增 `lastUploadedCount / lastDownloadedCount / lastRunSummary`
  （每轮 `_run` 开始归零；推送 `+= acked`，拉取 `+= outcome.totalRecords`）。
- `syncFeedbackMessage(status, summary)` 是**纯函数**（可单测，无需启网络）：
  `success`+有数据 → `同步完成：上传 N 条，下载 M 条`；`success`+空 → `没有需要同步的数据`；
  `waitingForNetwork` → `当前离线，记录已保留`；`needsReauthentication` → `登录已失效，请重新登录`；
  `signedOut` → `请先登录`；`syncing` → `同步正在进行`；`failed/idle` → `同步失败，可稍后重试`。
- **账户隔离**（§8.2）：`MenuActionContext` 携带 `accountSessionId`，晚到结果按层级 / 会话丢弃。

### 3.7 反馈 / 忙碌 / 日志（§13 / §14）

- `enum WheelFeedbackKind { success, info, warning, error, progress }` +
  `static fromResult(MenuExecutionResult)` —— **唯一推导点**，视图不再各自 switch。
- 忙碌态：`fixed_canvas_probe` 的 `_actionLedger`（requestId 去重）+ `_inFlightActions` 已满足 §13.2；
  同一动作执行中重复点击 → `wheel.action.busy` + 返回 `running`。
- §14 日志（`wheelGeometryJournal`）：
  `wheel.action.request / wheel.action.result / wheel.action.failure / wheel.action.busy /
  wheel.action.deduped / wheel.action.late_result_dropped`（带 `elapsedMs / resultKind / feedbackKind / navigation`）；
  `wheel.navigation.begin / ready / failed`；`wheel.sync.begin / wheel.sync.summary`。

### 3.8 清零泛化占位（§15）

- 删除 `c2Notice`（6 处）与 `'Windows 尚未接入该业务动作：$actionId'` default 分支；
- `nativeWindow` 的 default 收窄为**防御性断言**（注册表校验保证不可达），文案明确附 id，不写泛化"不支持"；
- `'动作执行器未装配，暂时无法执行「…」'` **保留**（这是真实装配缺失，不是占位）。

---

## 4. 实现（新增 / 改动）

### 新增

| 文件 | 职责 |
| --- | --- |
| `lib/menu/wheel_action_dispatch.dart` | `WheelFeedbackKind` + `MenuActionContext` + `WheelMenuActionDispatcher` + `WheelActionRoute` + `WheelActionRegistry`（`validate()` / `assertValid()`）。纯 Dart，可 `flutter_tester` 直接单测。 |
| `test/wheel_c2_registry_test.dart` | **27 项**：§16.1 注册表完整性 + §15 零占位 + §3.1 唯一入口 + §12.1 `PanelDestination` + §8.1 同步文案 + §13 `WheelFeedbackKind` + §3.3 导航 / 收起。 |

### 改动

| 文件 | 改动 |
| --- | --- |
| `lib/menu/menu_contract.dart` | 新增 `sealed class PanelDestination`（9 目的地 + `fromWire` + `all` + `wireName`）；`MenuExecutionResult` 新增 `navigation` / `closeMenu`，`success(...)` 自动带 `closeMenu`，`requiresLogin(..., navigation:)`；更新 `toMap()` / `toString()`。 |
| `lib/platform/windows/windows_menu_action_executor.dart` | **重写**：host 契约改为 `dispatchBusiness` + `currentPetStateLabel` + `currentForegroundAppLabel`；实现 `WheelMenuActionDispatcher`；`_dispatch` 按 kind 分派（`navigation→unavailable`、`info→_dispatchInfo`、`nativeWindow→_dispatchNative`、`dartAction→host.dispatchBusiness`、`wheelAdjust→unavailable`）；**删除全部占位**。 |
| `lib/ui/desktop/desktop_menu_action_bridge.dart` | 保留**同一个** `OverlayMenuActionExecutor` 装配；新增 `loginRequiredActions={'records_sync'}`、`destinations`（actionId→`PanelDestination`）、`mapAppDestination`、`_runSync()`、纯函数 `syncFeedbackMessage`；`_drain` 走强类型映射。 |
| `lib/ui/desktop/desktop_shell.dart` | `_menuActionHost()` 改传 `dispatchBusiness` + 两个 label 回调；**删除** host 的 `pet_auto` / `appearance_*` 第二份实现；`_applyDestination(AppDestination) → _applyDestination(PanelDestination)` + `_tabIndexFor()` 静态映射 + `wheel.navigation.*` 日志；`_bootstrapAsync` 起始处 `WheelActionRegistry.assertValid()`。 |
| `lib/ui/desktop/wheel_geometry_probe.dart` | host 构造改新形状；`onDestination` / `onNavigateDestination` 形参类型 `AppDestination → PanelDestination`。 |
| `lib/ui/desktop/control_panel.dart` | 新增 `static const int diagnosticsTabIndex = 6;`。 |
| `lib/sync/sync_engine.dart` | 新增 `_lastUploadedCount / _lastDownloadedCount` + getter + `lastRunSummary`；`_run` 起始归零；`_applyPushOutcome` / `_pull` 累加。 |
| `lib/ui/desktop/fixed_canvas_probe.dart` | §14 日志：`_dispatchAction` 记 `wheel.action.request` / `wheel.action.busy`，存 `_actionStartedAt`；`_presentActionResult` 记 `wheel.action.result` / `wheel.action.failure`（含 `elapsedMs / resultKind / feedbackKind / navigation / errorType`）。 |

---

## 5. 测试（§16，当前 HEAD 实跑）

**新增 `test/wheel_c2_registry_test.dart`（27 项）**

| 分组 | 断言要点 |
| --- | --- |
| §16.1 注册表完整性 | `validate()` 空；叶子动作 **26** 项（= 菜单目录里的非导航条目：`root_hide`1 + `pet`6 + `appearance`6 + `records`4 + `tools`4 + `settings`5）；无叶子是菜单栈动作；canonical 无重复；业务集合覆盖记录/同步/形象/桌宠/设置页；窗口级归 `nativeWindow`、四个设置入口归 `wheelAdjust`、只读项归 `info` |
| §15 零占位 | 遍历**全部**叶子动作：不得出现"不支持 / 尚未接入 / 增量 C2"字样；全部业务动作都真的到达唯一业务通道 |
| §3.1 唯一入口 | `dispatch()` 转交业务通道；菜单栈动作**断言拦截** |
| §12.1 `PanelDestination` | `wireName` 唯一；`fromWire` 往返一致；含需求列出的 8 个目的地；`AppDestination → PanelDestination` 覆盖全 6 值；导航动作 → 目的地声明与 canonical 一一对应；登录门槛集合只含 `records_sync` |
| §8.1 同步文案 | 成功有数据 / 成功无数据 / 离线 / 需重登 / 未登录 / 失败各自中文；文案不含英文异常或技术细节 |
| §13 `WheelFeedbackKind` | 按结果状态映射（唯一推导点） |
| §3.3 结果导航 | 带目的地自动收起；非导航不收起；`requiresLogin` 可携带目的地 |

**改动测试**

| 文件 | 改动 |
| --- | --- |
| `test/windows_menu_action_executor_test.dart` | **重写**：新 host 形状；业务委托；信息项返回真实状态；无占位文案；`dispatch` 拒绝导航动作。 |
| `test/wheel_action_dispatch_test.dart` | host 构造改新形状；`appearance_*` / `pet_auto` 断言改为 `dispatch:*`；§11.22 `c2Notice` 组 → `§16` 组（records_* 全成功 + 信息项返回真实状态）。 |
| `test/sync_engine_test.dart` | 新增 `增量 C2：同步摘要` 组（**3 项**：默认无数据；上传 2 段 → `上传 2 条`；每轮归零）。 |

**验证结论（当前 HEAD 实跑，顺序同 §18）**

| 步骤 | 命令 | 结果 |
| --- | --- | --- |
| ① 静态分析 | `flutter analyze` | **No issues found!**（exit 0） |
| ② C2 定向 | 注册表 + 执行器 + 分发 + contract + overlay + sync（6 文件） | **+132 All tests passed!**（exit 0） |
| ③ 冻结回归（C1.1~C1.1.3） | 13 个 wheel / geometry / 面板 / 链路测试文件 | **+273 All tests passed!**（exit 0） |
| ④ 全量 | `flutter test --no-pub` | **+1452 passed / ~1 skipped / 0 failed**（exit 0） |
| ⑤ 只构建一次 Release | 见 §7 | exit 0（242.6s） |

> 单跑 `test/wheel_c2_registry_test.dart` = **+27 passed**（专项确认）。

---

## 6. 真机验收步骤（§19）

> 前置：直接运行 §7 的 Release（`build_incrC2`）。

### 6.1 桌宠子菜单（§5）

1. **缩小 / 放大 / 恢复默认** → 桌宠尺寸即时变化。
2. **自动状态** → 仅**开启**自动（不再"开关"），与 Android 语义一致。
3. **当前状态** → 反馈条显示 `当前状态：<状态> · <情绪>/<变体>`（真实状态，**不再**"尚未接入"）。
4. **重置位置** → 回到默认角落。

### 6.2 形象子菜单（§6）

5. **上一张 / 下一张** → 素材切换；**自动形象** → 解除手动锁定；**收藏** → 当前素材入收藏；
   **编辑状态素材** → 打开「状态素材映射」页；**打开素材库** → 打开「素材库」页（页签正确）。

### 6.3 记录子菜单（§7）

6. **今日时长** → 轮盘内直接显示今日时长。
7. **当前应用** → 显示当前前台应用（真实值，**不再**"尚未接入"）。
8. **本机统计** → 打开「使用统计」页（本机）。
9. **云端记录** → 打开「使用统计」页（云端子标签）；**未登录**时进页面后由页面引导登录。

### 6.4 工具子菜单（§9）

10. **暂停采集 / 继续采集** → 切换采集状态（复用 `saveTrackingSettings`）。
11. **立即同步**（已登录）→ 反馈 `同步完成：上传 N 条，下载 M 条` / `没有需要同步的数据`；
    **连点** → 第二次如实显示"同步正在进行"，**不产生第二个任务**。
12. **同步状态** → 只读回报当前同步状态。
13. **打开 PetLife** → 打开控制面板。

### 6.5 设置子菜单（§10）

14. **轮盘主题 / 大小 / 按钮大小 / 菜单距离** → 就地进调整层，加减即时生效。
15. **完整设置** → 打开控制面板并**切到「设置」页**（不再停在首屏）。

### 6.6 隐藏 / 退出（§11）与导航事务（§12）

16. **隐藏** → 隐藏桌宠（服务继续）；**托盘退出** → 正常退出。
17. 从轮盘触发**任意**导航动作 → 控制面板**先完成打开事务**再切页签（无固定延时；日志
    `wheel.navigation.begin → ready`，失败记 `failed` 且不抛到 UI）。

### 6.7 泛化文案清零（§15，硬指标）

18. 遍历**所有**菜单项并逐个点击 → **不得**出现"未支持的菜单动作 / 尚未接入 / 增量 C2 接入"。
    仅真实装配缺失（执行器未装配）才可能出提示。

日志对账：每个动作都应有 `wheel.action.request` 与其后的 `wheel.action.result`（或 `failure`），
字段含 `canonicalActionId / menuLevel / surfaceMode / resultKind / feedbackKind / elapsedMs`。

---

## 7. Release 构建（**只构建一次**，§18）

```
C:\Users\Administrator\WorkBuddy\DesktopPet\petlife\build_incrC2\windows\x64\runner\Release\petlife.exe
```

| 产物 | 值 |
| --- | --- |
| `petlife.exe` | `D75DA6F303B04903E521015A67913DEBC41D107BB465259DFBCADCA0C77D15B8`（137,216 B） |
| `data\app.so` | `98A8105D5525DC680D13FFB3171C3A961A994C10AC1C3E6AEB5A2DC650BB01CF`（9,356,168 B） |

- 构建命令：`flutter config --build-dir=build_incrC2` → `flutter build windows --release` → **exit 0**（242.6s），
  随后已把 `build-dir` **还原为 `build`**。
- 产物清单见 `docs/52-evidence/c2-release-artifacts.txt`。
- 本轮**未**改动 `pubspec` / 原生插件，仅 Dart 源码 + 测试。

---

## 8. 交付证据（§20）

- `docs/52-evidence/c2-analyze.txt` — `flutter analyze`（No issues found!）
- `docs/52-evidence/c2-tests-directed.txt` — C2 定向（+132）
- `docs/52-evidence/c2-tests-frozen.txt` — 冻结回归 C1.1~C1.1.3（+273）
- `docs/52-evidence/c2-tests-full.txt` — 全量（+1452 / ~1 skipped / 0 failed）
- `docs/52-evidence/c2-build.txt` — Release 构建输出
- `docs/52-evidence/c2-release-artifacts.txt` — EXE / app.so 路径 / 尺寸 / SHA-256

---

## 9. 边界自查（§1，逐条）

- ✅ 未重写 `RegionCoordinator` / `WheelInteractionState` / `WheelPointerState` / `WheelHitTester`；
- ✅ 未改扇形角度 / 7° 滞回 / `anchorIndex` / `WheelPlacementSolver` / 六种布局 / `WheelSpaceSnapshot`；
- ✅ 未改 alpha 上下界 / CanvasPlan 与 Painter / Region / HitTest 共享 / P3P 视觉 / 拖拽 / 点击穿透；
- ✅ 未改右键菜单 / 控制面板定位 / 菜单几何 / 动画时长；
- ✅ **未改 Android 代码**（`AppDestination` 不扩展，另立 Windows 专属 `PanelDestination`）；
- ✅ 无定时器修时序（导航事务完成后才选页签，无固定延时）；
- ✅ 业务处理器不碰 Region；反馈条引起的 Region 重算沿用既有单点 `_refreshWheelRegion('feedback')`。

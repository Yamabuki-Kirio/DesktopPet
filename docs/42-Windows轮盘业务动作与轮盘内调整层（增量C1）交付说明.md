# 42 · Windows 轮盘业务动作接入 + 轮盘内调整层（增量 C1）交付说明

> 范围：**只做增量 C1**（轮盘条目真的能执行、设置能在轮盘内就地调整、幂等与晚到结果可判定）。
> 未改 Android、未接 `records_*`（记录类动作按计划留给 C2，返回**明确原因**而不是假装成功）、
> 未进入 C2。
> 交付物：`build_incrC1\windows\x64\runner\Release\petlife.exe`（**只构建一次**）。

## 1. 这次解决了什么问题

增量 B 结束时，轮盘已经能画、能悬停、能进层，但**确认条目以后什么也不会发生** ——
所有业务动作统一返回"将在增量 C 接入"。C1 把这条链路补齐，并且刻意做了三件"反退化"的事：

| 需求 | 做法 |
| --- | --- |
| 动作执行不能出现"第二套状态引擎" | 业务动作**全部委托**给既有的 `OverlayMenuActionExecutor`（移动端同一实现），只补一层桌面桥 |
| 设置类条目不能跳控制面板 | 新增**轮盘内调整层**（就地加减 / 恢复默认 / 返回），层级与步进是纯数据 |
| 连点 / 动画未落位时的重复派发不能执行两次 | `MenuActionRequest` + `MenuActionLedger` 幂等账本，**不靠延时** |

## 2. 新增文件（3 个源文件 + 2 个测试）

| 文件 | 职责 |
| --- | --- |
| `lib/menu/menu_action_request.dart` | 幂等账本：`MenuActionRequest{requestId, actionId, levelId}` + `MenuActionLedger`（容量 64，FIFO 淘汰）。`begin` 同一 key 只成功一次，`finish` **不**移除记录（否则重复投递又能进来） |
| `lib/menu/wheel_adjustment_layer.dart` | 调整层**纯数据 + 纯函数**：`WheelAdjustmentKind`（主题 / 轮盘大小 / 按钮大小 / 菜单距离，含 min/max/step/默认值/格式化）、`WheelAdjustmentLayer.build`（固定 5 条目：减小 / 当前值 / 增大 / 恢复默认 / 返回）、`WheelAdjustmentLayer.quantize/stepped`、`WheelSettingRevision` |
| `lib/ui/desktop/desktop_menu_action_bridge.dart` | 桌面桥：把 `OverlayMenuActionExecutor` 适配成桌面可用的动作执行器，并负责页面跳转（素材库 / 状态映射 / 统计 / 账户） |
| `test/wheel_adjustment_layer_test.dart` | 21 项：范围 / 步进 / 量化 / 边界 / 默认值可达性 / 层级条目 |
| `test/wheel_action_dispatch_test.dart` | 22 项：派发 / 幂等 / 一次重建 / 修订号 / 晚到结果 / Region 与反馈 / 不依赖桌面实现 |

## 3. 关键实现点

### 3.1 契约：新增 `MenuActionKind.wheelAdjust`

调整层动作**不**进业务执行器（它只改设置 + 进退层级），所以给它一个独立分类，避免被
`WindowsMenuActionExecutor` 误当业务动作。目录新增 `settings_menu_distance` 条目
（菜单距离以前只能在控制面板改），目录条目从 31 → **32**。

`MenuStack` 相应补齐两个**可判定**操作（而不是"反复 push/pop 靠中间态合法"）：

* `pushDynamic(levelId)` —— 压入一个不在 `MenuCatalog.levels` 里的动态层；
* `restoreTo(levelId)` —— 把栈直接重置成 `[root, levelId]`。

### 3.2 设置写入与"当前值"只读展示

调整层里"`当前值`"那一行是一个**信息行**（`adjust_<kind>_value`，登记为 `info` 分类），
永远不会被执行为业务动作 —— 这样既不用新增枚举值，也不会出现"点了当前值却改了设置"。

设置读取走 `readWheelSetting` 回调，视图**不持有**设置；写入走唯一入口 `applyWheelSetting`。
因此不会出现"界面显示 130% 而库里存 120%"。

### 3.3 几何变化 → 一次重建 → 自动重开并**回到原调整层**

改轮盘大小 / 按钮大小 / 菜单距离会影响画布尺寸，必须走关闭态重建事务：

1. 写设置（唯一入口）；
2. `_settingRevision.bump()` 拿到本次修订号；
3. `rebuildFixedCanvasAt(..., expectedRevision: 修订号)`：重建期间**先关菜单**，
   保持人物屏幕位置不变，提交一次 bounds，回读校验；
4. 成功后 `open(restoreLevelId: 原层级, restoreIndex: 原选中项)` —— 用户回到刚才那一层，
   不是掉回根菜单。

### 3.4 修订号语义（真缺陷修复 ①）

`rebuildFixedCanvasAt` 的返回从 `bool` 改成**三态** `CanvasRebuildOutcome`：

* `applied` —— 重建成功；
* `superseded` —— 被更新的修订号 / 在飞的重建取代（**什么都不做**，设置保持有效，**绝不回滚**）；
* `failed` —— 真失败（Region / 回读 / 异常）→ 才回滚设置。

**为什么必须分三态**：连点"增大"三次会产生三个重建请求，其中两个按定义会被取代。
旧实现把它们当失败 → 走"回滚到旧设置"→ 用户的三次增大只剩两次、甚至回滚到一个过期值。
这正是测试 §11.8 抓出来的：期望 `1.30`，实际 `1.20`（被回滚）。

### 3.5 打开序列中恢复层级的相位（真缺陷修复 ②）

`state.restoreToLevel` 以前只接受 `open` / `switching`。但恢复层级是**打开序列内部**的装配
步骤，此时相位本来就是 `opening` → 恢复被拒 → 轮盘打开后**掉回根菜单**（测试 §11.9）。

修法：额外允许 `opening`，并且**不改相位**（让 `opening → open` 由展开动画自己收尾）。
若在这里把相位改成 `enteringLayer`，动画结束回调会把层级重新压回根层。

用户输入路径（`enterDynamicLevel`）**保持**只接受 `open` / `switching` —— 展开动画期间必须拦下输入。

### 3.6 默认值必须落在步进网格上（真缺陷修复 ③）

菜单距离默认 `0.16`、范围 `0.05~0.30`，原步进 `0.02`：`0.05 + k×0.02` 既到不了 `0.16`
也到不了 `0.30` → "恢复默认"和"加到最大"都到不了。步进改为 **`0.01`**，
并新增一条**关键回归测试**：对三个数值量逐一断言"默认值 / 下限 / 上限的量化都等于自身"
（防止以后有人再调步进把网格弄歪）。

### 3.7 幂等与晚到结果

* 每个动作带自增 `requestId` → `MenuActionLedger.begin(key)`，同一次确认被派发两次只执行一次；
* 结果回来时若菜单已关 / 层级已变 → 记 `wheel.action.late_result_dropped`，**不**恢复旧 UI；
* 调整动作执行期间会出现在飞集合里（按钮置灰）；
* 测试用**闸门**（挂起执行器 → 先关菜单 → 再放行）真实制造"晚到"，不是靠时序碰运气。

## 4. 记录类动作的处置（不假装成功）

`records_today` / `records_stats` / `records_cloud` / `records_track` / `records_sync_state`
以及 `records_sync`（未登录时先返回 `requires_login`）统一返回 **`unavailable` + 明确原因**
（"将在增量 C2 接入"），绝不用一个含糊的"不支持的菜单动作"糊过去。
`fixed_canvas_probe_test` 里有一条测试专门断言"原因必须存在且不能是那句笼统文案"。

## 5. 验证与存证

| 项目 | 结果 | 证据 |
| --- | --- | --- |
| `flutter analyze` | **No issues found!**（exit 0） | `docs/42-evidence/incrC1-analyze.txt` |
| 定向测试（12 个文件） | **302 passed / 0 failed** | `docs/42-evidence/incrC1-tests-directed.txt` |
| 全量测试 | **1299 passed / 1 skipped / 0 failed** | `docs/42-evidence/incrC1-tests-full.txt` |
| Windows Release | **只构建一次**，295.0s → `build_incrC1\windows\x64\runner\Release\petlife.exe`（137,216 B） | `docs/42-evidence/incrC1-build.txt` |
| `build-dir` 还原 | 已回读 `%APPDATA%\.flutter_settings` → `"build-dir": "build"` | 同上 |

增量 B4 结束时全量为 1277 passed；C1 自身新增 **43 项**测试（调整层 21 + 派发 22），
两者都计入上表的全量数字。

## 6. 没做的事（明确边界）

* **未接 `records_*`**：按计划留 C2（见 §4）。
* **未改 Android**：C1 只碰 `lib/menu/`、`lib/ui/desktop/`、`lib/platform/windows/`，
  并新增一条"新增模块不依赖桌面实现"的测试兜住跨端隔离。
* **未改右键菜单 / 控制面板行为**：新增一条测试断言右键菜单仍按 workArea 约束（未受 C1 影响）。
* **未做真机验收**：C1 到构建为止，接下来暂停等真机验收。

## 7. 真机验收建议顺序

1. 左键打开轮盘 → 设置 → **轮盘大小 / 按钮大小 / 菜单距离**：连点"增大"三次，
   确认最终值与点击次数一致（不是只生效一次），且轮盘**自动重开并停在原调整层**；
2. 每个调整层点"恢复默认" → 数值必须**精确**回到 100% / 100% / 0.16；
   拖到边界后再点"增大" → 必须提示"已到最大"而不是假装成功；
3. 快速双击同一按钮 → 只执行一次（收藏不会被切两下）；
4. 形象 → 上一张 / 下一张 / 收藏；工具 → 隐藏桌宠（托盘可恢复）/ 打开控制面板；
5. 记录 → 今日 / 统计 / 云端 / 暂停记录：应给出**明确原因**（C2 接入），不是无反应；
6. 全程窗口矩形不变（菜单开合只改 Region）。

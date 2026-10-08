# 49 · Windows 轮盘「悬停重置」与「静止单击」稳定性修复（增量 **C1.1.2**）交付说明

> 范围：**只修交互状态与事件分发**。不改轮盘几何、不改六种位置决策、不改 Region 可见性契约、
> 不改画布尺寸、不改业务菜单内容，**不进入 C2**。
> 前置：`docs/48-C1.1.2方案-轮盘悬停与静止单击稳定性（待确认）.md`（含 D 系列根因诊断）。
> 本文即为该方案在 **A1 + B1 + C1** 决策下的落地交付。

---

## 1. 真机症状（回归项）

1. 左键打开轮盘 → 鼠标移到第二个及以后的按钮 → **保持不动约 0.5 秒** → 高亮**自动回到第一个按钮**。
2. 鼠标仍不移动 → 单击左键 → **菜单关闭，但对应功能没有执行**。

两条都必须先"用日志确认根因、不得先猜动画参数"——诊断过程见 §2。

---

## 2. 根因（日志实测，非推测）

前提事实：`WheelAnimationTimeline.openMs = 300`；生产顺序是
`prepareContent → setInteractive(true) → [异步 Region apply] → beginOpenAnimation()`，
而 `beginOpenAnimation` 之后 Widget 才挂载、`Ticker` 才启动 ⇒
**"点桌宠 → 真正可交互" ≈ 400–500ms**，与用户描述的"约 0.5 秒"吻合。

| 诊断 | 实测 | 结论 |
| --- | --- | --- |
| D1 动画期间悬停 | `preview=null`（被丢） | 旧 `hover()` 开头 `if (phase.transitioning) return;` 把**整个打开动画期的悬停全部丢弃** |
| D2 动画结束（鼠标没动） | `phase=open preview=null active=0` | 动画结束**没有任何**"按最近鼠标位置重算 hover" |
| D3 动画结束后再悬停 + 推时钟 | `preview=3` 稳定 | **排除**"动画完成回调重置选择"这类写法（代码里没有 `selectedIndex = 0`） |
| D4 静止单击（down+up 同点） | `confirmed=[root_records]` | 装配层的静止单击**本身是好的** |
| D7 `opening` 期 down、动画后才 up | `confirmed=[] closeRequests=0`，全程 `owner=none` | down 被丢 → up 无从属 → 这次点击被吞 |
| **D9 Region 内分区分布** | `rimOuterPx=293`、`ringRadius=252`；Region 内 3px 采样 **ring=15521 / center=7278 / outside=21094**；死区最远半径 **544.5px** | **← 症状 2 的真凶**：Region（按 C1.1 契约必须覆盖**全部绘制像素**，含标签、文字带、刀刃、外缘装饰）**远大于可点击环带**；落在这 21094 个点上的单击全部走 `outsideTap → onRequestClose()` → **菜单关闭但什么都没执行** |

### 三个确认的缺陷

1. **过渡期丢悬停 + 四个时机都不主动重算 hover** → 症状 1。
2. **Region ≫ 可点击区，形成 21k 点级"点它就关菜单"的死区** → 症状 2 主因。
   与需求 §六 相矛盾：§六 说"按下**菜单背景**：不执行按钮""按下**轮盘外透明区域**：关闭菜单"，
   而旧代码把"Region 内、环带外"的一切都当成"透明区域"去关闭，**真正的 Region 之外却收不到事件**。
3. **down 落在过渡窗口内会整条丢失**，up 到达时无从属 → 该次点击被吞。

> 用户猜测的 `onTap { if (hoveredIndex == null) closeWheel(); }` **在代码里不存在**（D4 证明静止单击能命中）。

---

## 3. 决策（已确认）

- **A1**：Region 内、不属于按钮/标签/文字 chip/缺口 的**菜单背景**，单击**不执行任何动作、也不关闭**。
- **B1**：按钮的**图标圆形 + 对应角度槽位 + 该按钮自己的标签/文字 chip** 同属一个按钮的命中区。
- **C1**：鼠标不在任何按钮命中区时**不高亮任何按钮**；键盘模式仍可默认聚焦第一项。

### 两条强制约束（本实现逐条满足）

**约束 1 —— B1 不得扩张成"整片环带都属于一个按钮"**：
按**按钮索引**建立 `ButtonHitRegion`，每按钮只拥有
`按钮圆形 ∪ 对应角度槽位内的环带 ∪ 该按钮自己的标签/chip`；
重叠时按 **① 按钮圆形 → ② 标签/chip → ③ 角度槽位 → ④ 距离相同取视觉中心最近者** 判定。

**约束 2 —— 保留明确的关闭方式**：
采用 A1 后背景不再关闭，因此关闭方式明确收敛为：
① **再次单击桌宠（中央缺口）**；② `Esc`；③ 动作结果协议决定；④ 子菜单"返回"只返回上一级；
⑤ 右键/控制面板切换按既有事务关闭。
**没有**为实现"点外部关闭"扩大透明窗口 Region —— Region 之外的点击仍**穿透给下层应用**
（不再出现"关闭后遮挡下层窗口"）。

---

## 4. 实现

### 新增（纯 Dart，可 `flutter_tester` 直接单测）

| 文件 | 职责 |
| --- | --- |
| `lib/menu/wheel_pointer_state.dart` | **交互态拆分**：`hoveredIndex / keyboardFocusedIndex / gestureSelectedIndex / pressedIndex / activeInputKind / keyboardMode / lastPointerLocal / lastHitIndex`；`visualActiveIndex` **纯派生**、`visualActiveIndexOrNone(itemCount)` 给出 `-1`（无高亮）。 |
| `lib/menu/wheel_button_hit.dart` | `ButtonHitRegion`（按按钮索引）+ `WheelHitTester`（**共享 HitTest**，四级优先）+ `WheelHit/WheelHitKind`。标签矩形与 Painter / 视觉包围盒**同源**；chip 矩形与 `_drawTexts` 同源。 |

### 改动

| 文件 | 改动 |
| --- | --- |
| `lib/ui/desktop/wheel_menu_view.dart` | `WheelMenuController` 新增 `pointer` / `_hitTester` / `_geometryRevision` / `_downHitIndex` / `_inputSeq`；`pointerDown/Move/Up` 全部改为**实时 HitTest**（down 存 `pressedIndex`，up 用**抬起坐标**重新 HitTest 再判定）；`hover` 期间也保存位置；新增 `recomputeHoverFromLastPointer()`、`hitTestAt()`、`_setHovered()`、`_log()`、`_setInputKind()`；`_bindLayout` 重建 HitTest 并清指针态（保留最近位置）；`_finishRun` 在 open/enterLayer/exitLayer 后重算 hover；`setInteractive(false)` / `prepareContent` 清指针态；`highlightIndexNow` 供渲染。 |
| `lib/ui/desktop/wheel_menu_painter.dart` | `WheelRenderParams` 新增 `highlightIndex`（默认 `-1`）；`_drawButtons` 改用 `highlightIndex`。**`activeIndex` 语义不变**（弧形文字/实时信息的锚点），因此"无高亮"**不会**让标题/chip 消失。 |
| `lib/ui/desktop/fixed_canvas_probe.dart` | `_refreshWheelRegion` 成功后调用 `recomputeHoverFromLastPointer()`（§七-1「Region 已开放」时机）。 |

### §七 四个确定性时机（不用定时器、不延长动画，`openMs` 仍为 300）

1. **Region 已开放** → 探针 `_refreshWheelRegion` 收尾；
2. **第一帧可见** → `WheelMenuView.initState` 的 post-frame 回调；
3. **打开动画结束** → `_finishRun(open)`；
4. **菜单层级切换完成** → `_finishRun(enterLayer / exitLayer)`。

重算一律用 `lastPointerLocal`（**CanvasLocalSpace / 菜单窗口局部坐标**，唯一口径）
+ 真实 HitTest；**没有最近位置 / 不在按钮上 ⇒ 无高亮，绝不默认第一项**。

### §九 时间线日志（沿用 `wheelGeometryJournal`）

事件：`wheel.pointer.down / .up / .move(仅落点变化时) 、wheel.hit.down / .up 、
wheel.hover.changed 、wheel.animation.completed 、wheel.items.changed 、
wheel.input_mode.changed 、wheel.action.confirmed 、wheel.close.requested`。
字段：`transactionId / phase / menuLevel / geometryRevision / hoveredIndex / keyboardFocusedIndex /
gestureSelectedIndex / pressedIndex / inputKind / keyboardMode / pointerLocal / lastHitIndex`。

---

## 5. 测试（16 项定向回归 + 全量）

新增 `test/wheel_c112_interaction_test.dart`（**19 项**）：

| # | 需求 §十 | 结果 |
| --- | --- | --- |
| 1 | 悬停第三项 1 秒高亮不变 | ✅ |
| 2 | 打开动画完成不把 hover 重置第一项 | ✅ |
| 3 | 静止单击能执行（不是只关闭） | ✅ |
| 4 | 单击用实时 HitTest（旧 hover 在第 3 项、单击第 5 项 → 执行第 5 项） | ✅ |
| 5 | 展开后按钮上完成时主动重算 hover（背景位置 → `-1`） | ✅ |
| 6 | 同按钮只执行一次（多余 up 不重复） | ✅ |
| 7 | 按下后拖出环带抬起 → 不执行、不关闭 | ✅ |
| 8 | 缺口单击关闭 / 背景单击不关闭（A1） | ✅ |
| 9 | 六个根按钮：每次都执行、且从不触发外层关闭 | ✅ |
| 10 | 换层后旧 hover 不残留、按新几何重算 | ✅ |
| 11 | 键盘默认焦点不覆盖鼠标 hover | ✅ |
| 12 | 动画跑完不得修改任何交互态 | ✅ |
| 13 | rebuild 不重建交互控制器（+ MouseRegion 悬停生效） | ✅ |
| 14 | 关闭后清空 hover / pressed / 最近位置 | ✅ |
| 15 | 快速连续点击恰好执行两次（不多不少） | ✅ |
| **16** | **D9 死区回归**：窗口内**只有缺口**会关闭菜单（17px 网格穷举，非缺口点一个都不许关） | ✅ |
| B1-a | 点击按钮**标签**带 → 命中该按钮（而非关菜单） | ✅ |
| B1-b | 优先规则：圆形 > 标签 > 角度槽位；重叠取最近；环带内不得错选 | ✅ |
| §九 | 时间线日志事件留痕 | ✅ |

配套变更：`test/wheel_menu_view_test.dart` 中原「落在环带之外的空白处松手 → 请求关闭菜单」
按 A1 语义改为「**不**关闭、也不执行」（旧断言是缺陷行为）。

验证结论（当前 HEAD 实跑）：

- `flutter analyze` → **No issues found!**
- 定向（C1.1.2 + view + C1.1 几何 + C1.1.1 顶部边缘）→ **+83 All tests passed!**
- 全量 → **+1372 passed / ~1 skipped / 0 failed**（C1.1.1 基线 1353 + 本轮 19）。

---

## 6. 真机验收步骤（§十一）

> 前置：直接运行 §7 的 Release。

1. 打开菜单，把鼠标停在**第三个**按钮上 **2 秒** → 高亮**必须保持**在第三个。
2. **不移动**鼠标，单击 → **必须执行第三个按钮**，不得只是关闭。
3. **六个根菜单按钮**逐个重复"停留 2 秒后单击"。
4. 进入**每个子菜单**，重复"停留 2 秒后单击"。
5. 测试**返回**按钮（只返回上一级，不关闭）。
6. 鼠标放到**菜单背景**（按钮之间、环带外、窗口内）单击 → **不关、不执行**（A1）。
7. 鼠标放到按钮**外侧标签带**与**标题文字**上各单击一次 → 应当命中/或至少**不关闭**
   （修复前这两处会直接关菜单；D9 的 21094 个采样点）。
8. 点**中央桌宠（缺口）**单击 → 正常关闭；`Esc` → 关闭/返回。
9. **连续打开关闭十次**（`wheel.pointer.*` / `wheel.hit.*` 日志应成对且无残留）。
10. **四角位置各测试一次**（左上/右上/左下/右下），几何不得回归（C1.1.1 的六种布局诊断应保持 §C1.1.1 表值）。

日志对账（验收硬指标）：动画完成后 **`hoveredIndex` 不得被写成 `0`**，除非鼠标真的在第 1 个按钮上。

---

## 7. Release 构建（**只构建一次**）

```
C:\Users\Administrator\WorkBuddy\DesktopPet\petlife\build_incrC112\windows\x64\runner\Release\petlife.exe
```

| 产物 | 值 |
| --- | --- |
| `petlife.exe` | `7ED4B78E01A66F852BF9D91B32677089C47C378AEF0E36DD255358F2E5C5611E`（137,216 B） |
| `data\app.so` | `76E43BE060F18E915C98E1CA3F2A88E9CDB188071C79AD7F42F350C909809505` |

- 构建命令：`flutter config --build-dir=build_incrC112` → `flutter build windows --release` → **exit 0**（157s），
  随后已把 `build-dir` **还原为 `build`**。
- 产物清单见 `docs/49-evidence/c112-release-artifacts.txt`。
- 本轮**未**改动 `pubspec` / 原生插件，仅 Dart 源码 + 测试。

---

## 8. 交付证据

- `docs/49-evidence/c112-analyze.txt` — analyze 输出
- `docs/49-evidence/c112-tests-directed.txt` — 定向回归
- `docs/49-evidence/c112-tests-full.txt` — 全量回归
- `docs/49-evidence/c112-build.txt` — Release 构建输出
- `docs/49-evidence/c112-release-artifacts.txt` — EXE 路径 / 尺寸 / SHA-256

---

## 9. 边界（§十二，逐条）

- ✅ 不改轮盘几何、不改六种位置决策、不改 Region 边界/可见性契约、不改画布尺寸、不改业务菜单内容。
- ✅ 不进入 C2。
- ✅ **不用延时或定时器维持 hover**（重算只在四个确定性时机触发）。
- ✅ **不通过延长动画规避**（`openMs` 保持 300）。
- ✅ `activeIndex = -1` 时 Painter / 动画 / 键盘导航安全，无数组越界
  （`_drawTexts` 走独立 `activeIndex` 锚点，`_drawButtons` 用 `slot.index == -1` 恒 false）。
- ✅ Region 外点击仍穿透给下层应用，未扩大透明窗口 Region。

# 47 · Windows 轮盘顶部边缘适配修复（增量 C1.1.1）交付说明

> 范围：**只做 C1.1.1** —— 修"轮盘在屏幕顶部（左上 / 右上 / 顶部居中）展开时上半截
> 越过工作区、被裁切"这一个现象。不碰 C1.1 已验收的左/右展开、左下/右下效果、
> alpha 锚点、轮盘大小、固定画布架构、RegionCoordinator、拖动/关闭状态。
> **未改 Android、未接 `records_*`（仍留 C2）、未进入 C2。**
> 交付物：`build_incrC111\windows\x64\runner\Release\petlife.exe`（**只构建一次**）。

---

## 1. 根因（为什么"只有顶部"会被裁）

C1.1 把"人物可见边界 → 屏幕坐标 → 画布局部 → 缩放 → 绘制包围盒"打通了，
但 **纵向模式（靠上 / 居中 / 靠下）仍沿用旧链路**：

1. `FixedCanvasProbeState.open()` 调 `WheelMenuGeometry.resolveExpansion(... previousVerticalMode: _lastVerticalMode ...)`。
2. `resolveExpansion` 内部对纵向模式传的是 `lockMode: true` —— **用"上一次"的纵向模式锁住这一次**。
3. 于是"把桌宠从屏幕底部拖到顶部再打开"时，纵向模式仍是 `bottomEdge`，
   信封的扇心偏角被钉在 **-26°**（`kEdgeFanBiasDeg`），整块菜单被**朝上**推，
   而顶部位置本来就没有上方余量 → 上半截越过工作区上边、被 HWND 矩形硬切。

4. 旧判据本身也是"点估计"：`decideVerticalMode` 只看
   `above = centerY - bounds.top` 与 `below = bounds.bottom - centerY`
   （`above < below * 0.55 → topEdge`），**与扇形真实外缘无关** —— 即使没有锁死，
   也会在"人物中心尚在中线附近、但扇形上缘已经出界"的位置给出错误结论。

**修法**：把纵向决议从"点估计 + 上一次锁定"改为
**逐候选算完整视觉包围盒 → 与 workArea 求四侧溢出 → 按需求 §三 规则选择**，
并且**第一件事就是解除锁定**（对 `resolveExpansion` 传 `previousVerticalMode: null`）。
**绝不通过缩小轮盘、移动人物或裁切菜单来"看起来正常"。**

---

## 2. 改了哪些东西

### 2.1 新增：组合求解器 `lib/menu/wheel_placement_solver.dart`

唯一入口 `WheelPlacementSolver.solve(...)`：

1. **水平侧**：完全沿用 C1.1 已验收的 `resolveExpansion`（策略 → 信封 → 不变量 → 反向重试），
   但**纵向传 `null`**（§三 / §七 要求：纵向模式必须是"当前位置"的纯函数）。
2. **三个纵向候选**（`top / middle / bottom`）各自 `evaluate()`：
   用**正式共享几何** `WheelMenuGeometry.computeEnvelope(..., lockMode: true)` +
   `layoutFor` + `WheelVisualBoundsCalculator.compute` 算出该组合的
   **完整视觉包围盒**，再按需求 §三 的公式**逐字**算四侧溢出：

   ```
   overflow = max(0, workArea.left  - bounds.left)
            + max(0, bounds.right  - workArea.right)
            + max(0, workArea.top    - bounds.top)
            + max(0, bounds.bottom - workArea.bottom)
   ```

   ⚠️ 方向必须"**外扩为正**"：内容**越过**工作区边界才算溢出。
3. **选择规则**（`_select`）：
   * 位置指示的模式（Android `decideVerticalMode(petVisible, workArea, null, false)`
     的纯启发式：顶部→`top`、底部→`bottom`、居中→`middle`）**零溢出 → 直接采用**；
   * 放不下 → 退回 `middle`（保持普通位置的既有观感）；
   * 还放不下 → 取**溢出最小者**，再交给既有链路（窗口夹取 + `deviceEmergencyScale`）兜底。
     **不在这里发明新的缩放。**
4. 输出一个不可变 `WheelPlacementSolution`（含最终信封 / 几何 / 视觉包围盒 / 画布矩形 / 全部诊断）。

> **为什么"位置说的模式"优先于"居中"**：三个候选的竖直外扩是**包含关系** ——
> 居中对称外扩 `e`；靠上把向上外扩换小、向下换大（靠下镜像）。
> 因此"居中放得下"时靠上 / 靠下**通常也放得下**；若一律优先居中，
> `top` / `bottom` 就**永远不会**被选中 —— 顶部适配形同虚设，且与 §八
> "顶部场景 `verticalPlacement` 必须 = `top`"直接冲突。所以口径是
> **位置优先 → 居中兜底 → 最小溢出兜底**。

### 2.2 修改：`lib/ui/desktop/fixed_canvas_probe.dart`

* `open()` 不再直接调 `resolveExpansion`，改调 `WheelPlacementSolver.solve(...)`；
  信封 / 几何 / 画布矩形**全部来自该解**（`placement.resolution` / `placement.envelope`）。
* `_lastVerticalMode` / `_lastDirection` **只写日志**（新增 `prevVertical` / `prevDirection`
  字段），**不再回流**到下一次决议。
* 快照用 `withPlacement(placement / visualBoundsScreen / canvasBoundsScreen)` 落地，
  与 C1.1 的 `WheelSpaceSnapshot` 单一事实来源兼容。
* 新增只读诊断 getter：`placementSolutionForTest` / `verticalPlacementForTest` /
  `placementForTest` / `candidateOverflowsForTest` / `topOverflowPxForTest` /
  `bottomOverflowPxForTest` / `anchorErrorPxForTest` / `selectedVisualBoundsForTest` /
  `canvasBoundsForTest` / `placementDiagnosticsForTest`。
* `close()` / `_finishClose()` / `_recoverToPet()` 里清空 `_placementSolution`（诊断回到"未打开"）。

### 2.3 修改：`lib/menu/wheel_space_pipeline.dart`

`WheelSpaceSnapshot` 增加 `placement` / `visualBoundsScreen` / `canvasBoundsScreen`
三个字段与 `horizontalSide` / `verticalPlacement` 取值器（未打开时为 `null`），
新增 `withPlacement(...)` 派生方法、`describe()` 增补对应键。
**快照仍是唯一事实来源**（Painter / HitTest / Region / CanvasPlan 只消费它）。

### 2.4 修改：`lib/menu/wheel_region.dart`（顺带补掉一个 C1.1 遗留缺口）

`rectsFor()` 在 `vb.texts` 之后补上 `vb.labels`。C1.1 只补了 `texts`、漏了
按钮**中文标签**；在"居中（bias 0）"等朝向下标签外缘会落在 Region 之外，
真机上表现为**标签被硬直线切掉一截**。这是新增回归测试在"屏幕中心"场景抓到的，
与"Region 必须覆盖全部会被绘制的元素"的既定契约一致。

### 2.5 `lib/menu/wheel_canvas_plan.dart`

**还原**为 C1.1 的干净版本（决策已下沉到求解器；画布仍用其已验证的"超集"尺寸口径），
本轮不引入新的画布行为。

---

## 3. 六种布局的几何快照（需求 §三 / §八 / §十）

固定条件（与 C1.1 真机一致）：**工作区 1920×1040**（任务栏 40px）、**100% DPI**、
真机设置 `wheel.scale = 0.6` / `buttonScale = 1.3` / `menuDistance = 0.16`、
素材 256×192 Maya、alpha 可见边界 `0.3047, 0.1875, 0.6641, 1.0` → 人物可见 **92×156**。
几何由 `test/wheel_c111_top_edge_test.dart` 打印（证据：`docs/47-evidence/incrC111-tests-directed.txt`）。

| 场景 | 桌宠窗口左上 | 展开侧 | 纵向模式 | 选择原因 | top / middle / bottom 候选溢出(px) | `topOverflowPx` | `bottomOverflowPx` | 视觉包围盒(屏幕) | 画布矩形(屏幕) | `anchorErrorPx` |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| **左上** | 64,120 | **right** | **top** | `fit_natural_top` | 0 / 46.6 / 61.3 | **0** | **0** | 81.8,7.5 → 445.0,529.3 | 4,3 → 450,534 | 0.0064 |
| **右上** | 1600,120 | **left** | **top** | `fit_natural_top` | 0 / 46.6 / 61.3 | **0** | **0** | 1467.0,7.5 → 1830.2,529.3 | 1462,3 → 1908,534 | 0.0064 |
| **顶部居中** | 832,120 | right | **top** | `fit_natural_top` | 0 / 46.6 / 61.3 | **0** | **0** | 849.8,7.5 → 1213.0,529.3 | 772,3 → 1218,534 | 0.0064 |
| **左下** | 64,680 | right | **bottom** | `fit_natural_bottom` | 49.3 / 34.6 / **0** | **0** | **0** | 81.8,498.7 → 445.0,1020.5 | 4,494 → 450,1025 | 0.0064 |
| **右下** | 1600,680 | left | **bottom** | `fit_natural_bottom` | 49.3 / 34.6 / **0** | **0** | **0** | 1467.0,498.7 → 1830.2,1020.5 | 1462,494 → 1908,1025 | 0.0064 |
| **屏幕中心** | 832,420 | right | **middle** | `fit_natural_middle` | 0 / 0 / 0 | **0** | **0** | 940.8,253.4 → 1208.8,814.6 | 841,249 → 1213,819 | 0.0064 |

**左上 / 右上（= 顶部场景）三条硬指标全部满足（§八）**：
`verticalPlacement = top` ✓、`topOverflowPx = 0` ✓、`bottomOverflowPx = 0` ✓、`anchorErrorPx ≤ 1`（实测 0.0064）✓。

对照：左上 / 右上的 `middle` 候选溢出 **46.6px**、`bottom` 候选溢出 **61.3px** ——
即"若继续锁在居中 / 靠下，顶部就是会溢出这么多"，正是被裁的量级。
修复后两个顶部场景均选出 `top`（向外偏角 +26°、不再朝上顶出），
**视觉包围盒上边 7.5px 落在工作区内**（> 0），整块菜单完整可见。

---

## 4. 新增测试（`test/wheel_c111_top_edge_test.dart`，23 项）

| 组 | 覆盖 |
| --- | --- |
| §二 方向模型 | 六种组合齐全、扇心偏角逐字复用 Android（`+26 / 0 / -26`） |
| §三 / §八 六种布局 | 每个场景纵向模式正确 + **四侧溢出均 ≤ 1px** + 诊断字段齐全 |
| §四 / §六 不缩不放 | 顶部适配**不移动人物 / 不缩小菜单**（与 `middle` 逐项比对按钮直径 / 实际缩放 / 环半径） |
| §九 每场景回归 | 不裁切 / 全在画布内 / 全在工作区内 / **Region 覆盖全部会被绘制的元素** / 方向不回归 / 缺口 ≤1px / 关闭无残片 |
| §七 开合稳定 | 左上、右上各开关 10 次：仅 **1 次**窗口提交、组合稳定、无残片 |
| §三 纯函数性质 | 上一次是 `bottom` **不锁住**这一次；三个候选都被评估；`canvasBounds = visualBounds ∪ windowRect` 外扩取整；Android 隔离（不得 import `dart:io` / material / window_manager / platform/windows / region_coordinator） |

边界用例 11/12/13 钉住语义：极端位置 `y=40` **仍选 `top`** 并如实报告残余溢出（不偷偷缩小）；
`y=206` 处"位置说 top、居中放得下" → **位置赢**；屏幕中心 → **保持 middle**。

---

## 5. 测试与构建证据

| 项 | 结果 | 证据 |
| --- | --- | --- |
| `flutter analyze` | **No issues found!** | `docs/47-evidence/incrC111-analyze.txt` |
| 定向测试（C1.1.1） | **+23 All tests passed!**（EXIT=0） | `docs/47-evidence/incrC111-tests-directed.txt` |
| 全量测试 | **1353 passed / 1 skipped / 0 failed**（EXIT=0；C1.1 基线 1330 + 本轮 23） | `docs/47-evidence/incrC111-tests-full.txt` |
| Windows Release | **只构建一次**，219s → `build_incrC111\windows\x64\runner\Release\petlife.exe` | `docs/47-evidence/incrC111-build.txt` |
| `build-dir` 还原 | 已回读 `flutter config --list` → `build-dir: build` | 见第 5 节说明 |
| 产物 SHA-256 | `petlife.exe` = `ED479D5D95402393A7CC44A21C62F844CA27DD9EE4B013B0FB67C51913423942`<br>`data\app.so` = `10D1537EAF67E28EAF54FDCD4F88211747475E85377E746BEE0032003D67D4BC` | `docs/47-evidence/incrC111-release-artifacts.txt` |

**交付 EXE 完整路径**

```
C:\Users\Administrator\WorkBuddy\DesktopPet\petlife\build_incrC111\windows\x64\runner\Release\petlife.exe
```

（`petlife.exe` 137,216 B；`data\app.so` 9,323,400 B；同目录另有 7 个 plugin DLL + `flutter_windows.dll` + `data\`）

---

## 6. 明确未做的事

* **未改 Android**（`android/` 一行未动）；新增纯 Dart 模块由测试钉住平台隔离。
* **未接 `records_*`**（仍是 C2）。
* **未做 golden 位图**：六种布局的**几何 JSON 快照**已固化在定向测试输出里（可对账）。
  golden 位图受本机字体渲染影响，沿用 C1.1 的既定口径（先在 CI 固定字体再单独补），
  避免引入不稳定基线。
* **未做真机验收**：到构建为止，接下来**暂停等真机验收**。
* **本轮不碰**：左/右展开、左下/右下效果、alpha 锚点、轮盘大小、固定画布架构、
  RegionCoordinator、拖动 / 关闭状态（均为 C1.1 已验收项，回归测试保证不回退）。

---

## 7. 真机验收步骤（顶部专项）

1. **顶部左 / 右**：把桌宠拖到屏幕**左上**（如 64,120）打开轮盘 → 菜单应完整在**右下**、
   **上半截不再被裁**；再拖到**右上**（如 1600,120）→ 菜单应完整在**左下**、同样不被裁。
2. **顶部居中**：桌宠放到顶部中间（如 832,120）→ 菜单应完整居中偏下展开、无直线切口。
3. **不缩不放**：与"屏幕中心（如 832,420）打开"对比，**菜单大小应完全一致**（不因靠顶而变小）、
   **人物不移动**。
4. **拖动刷新**：在屏幕底部打开 → 直接拖到顶部 → 菜单应**立即收起**；松手后再打开 →
   **新位置用"靠上"布局**（不再沿用底部的靠下布局、不再被裁）。
5. **缺口对齐**：目视确认扇形"咬口"正对**人物可见区中心**（不是素材方框中心）。
6. **关闭残片**：顶部各场景开一次再关，关闭后**不得**看到粉色扇形残片。
7. **不动窗**：全程窗口矩形不变（菜单开合只改 Region）。

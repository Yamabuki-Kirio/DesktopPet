# 43 · Windows 轮盘坐标、缩放与裁切修复（增量 C1.1）交付说明

> 范围：**只做 C1.1**（统一坐标管线、alpha 边界、方向、拖动刷新、缩放、裁切、关闭残片）。
> 未改 Android、未接 `records_*`（仍留 C2）、未进入 C2。
> 交付物：`build_incrC11\windows\x64\runner\Release\petlife.exe`（**只构建一次**）。

## 1. 步骤 A：真机实际持久化值与缩放诊断（先看数字，再动手）

从 `%APPDATA%\com.petlife\petlife\PetLife\petlife.db` 的 `local_settings` 直接读出：

| 键 | 真机值 | 说明 |
| --- | --- | --- |
| `wheel.scale` | **0.6** | ⚠️ 用户把轮盘调到了 60%（默认 1.00） |
| `wheel.buttonScale` | **1.3** | **就是 Android 默认值**（`DEFAULT_BUTTON_SCALE = 1.30`），不是"用户调大了按钮" |
| `wheel.menuDistance` | 0.16 | 默认值 |
| `wheel.themeId` | `p3p-pink` | 默认主题 |
| `window.scale` | 1.0 | 桌宠尺寸倍率 |
| `window.x/y` | 1376 / 534 | v2 语义（= petScreenPosition） |
| `window.positionSchema` | 2 | 已是 v2 |

当前素材（`state.lastAssetId`）：`Maya_Cheerful_1.webp`，**256×192**，9 帧动画。
用 Pillow 逐帧量 alpha 包围盒（阈值 12，与 Android `PetAlphaBounds` 同口径）：

```
文件尺寸 256×192
每帧 bbox = (78, 36, 170, 192)     ← 9 帧完全一致
UNION 归一化 = 0.3047, 0.1875, 0.6641, 1.0000
可见像素 92×156（占宽 35.9% / 占高 81.3%），且**偏下**：上边 18.75%、下边贴到 100%
可见区中心 x = 124（素材中心 128）、中心 y = 114（素材中心 96）
```

### 修复前的"轮盘过大 / 错位"是怎么来的

`petSize` 用的是**素材文件尺寸**（`renderer.contentSize × scale`），而几何里的
"人物可见矩形"又套了一层 `0.86` 下限（`max(实测, 0.86×Widget)`），于是：

| 量 | 修复前（0.86×256×192） | 修复后（alpha 92×156） | 比值 |
| --- | --- | --- | --- |
| 缺口核半径 `holeRx` | **144.4** | **58.3** | 2.48× |
| 缺口核半径 `holeRy` | **110.8** | **91.9** | 1.21× |
| 环半径 `ringRadiusPx` | **220.6** | **124.9** | 1.77× |
| 缺口中心相对人物视觉中心 | 偏 **18px**（y） | 0（对齐 alpha 中心） | — |
| 画布（真机设置，1920×1040，桌宠 @1376,534） | 760×680 | **530×607** | — |

**关键结论**：用户把轮盘调到 60% 却仍然"巨大"，是因为环半径被
`max(spacing, 缺口下界, clearance, 62dp)` 里的**缺口下界**顶住了 ——
`visible × 1.05 / 2 + 10dp` 在 `visible = 220` 时算出 125.5，
而 `minRadiusForNotch = 125.5/0.88 + buttonR` 直接决定了环半径，
**与 `wheelScale` 无关**。可见区从 220 修回 92 后，环半径立刻从 220.6 掉到 124.9。

## 2. 改了哪些东西

### 2.1 新增：统一坐标管线（`lib/menu/wheel_space_pipeline.dart`）

冻结五个坐标空间（`WheelCoordinateSpace`）与**唯一**转换顺序，并把"一次打开用的
全部几何"收进一个不可变快照 `WheelSpaceSnapshot`：

```
sprite alpha bounds → petVisualLocalRect → petVisualScreenRect
  → 方向判定（只在屏幕坐标比 workArea）→ WheelGeometry（画布局部）
  → Region（画布局部）→ 最后一步才转 NativePhysical（乘 DPR）
```

下游（Painter / Region / CanvasPlan / HitTest）**只消费快照**，
`canvasLocalToScreen` / `screenToCanvasLocal` 是仅有的两个换算入口。
快照还带 `positionRevision / geometryRevision / surfaceGeneration` 与
`matches(...)`，用于丢弃晚到的异步结果。

### 2.2 新增：alpha 包围盒（`lib/character/pet_visual_bounds.dart`）

* `PetAlphaBoundsScanner.measureRgba/measureImage`：阈值 12，超大图按步长采样
  并**保守外扩一个步长**；纯函数，可单测。
* `PetVisualBoundsCache`：按 `(assetId, frameIndex)` 缓存，**逐帧累加稳定并集**
  （某帧更小不会缩回），LRU 上限 32 素材 / 240 帧。
* `PetFrameController` 在换素材与每帧推进时测量一次（同帧不重复扫像素），
  并新增 `visualBounds` / `ensureVisualBounds()`；**首帧测量不额外发通知**
  （避免"静态图持续重绘"，该回归由测试钉住）。
* `AppSettings` 里持久化的值仍是归一化值域；渲染器只在测量成功后通知。

### 2.3 修正：人物保护区必须用 alpha 边界（`WheelMenuGeometry.petVisibleRect`）

旧实现把兜底比例 `0.86` 当**下限**，把实测可见区又抬回 220×165 —— 与"直接用整张素材"
几乎没有区别。现在：

* `content == null`（从未测量）→ 按整张素材（Android `FULL` 口径），调用方必须先 `await ensureVisualBounds()`；
* `content` 退化（span < 5%，即"几乎全透明"）→ 才用 0.86 兜底（这才是 `docs/37` 的本意）；
* `content` 合理 → **原样采信**。

缺口中心因此恒等于**人物视觉中心**（不是 Widget 中心、更不是素材中心），
半径用 Android 原公式 `visibleWidth × 1.05 / 2 + 10dp`。

### 2.4 新增：完整视觉包围盒（`lib/menu/wheel_visual_bounds.dart`）

逐项复算 Painter 真正会画的每个元素并取并集：

* 扇带（内 `ringRadius×0.30` → 外 `max(bladeLength, rimOuter)`）+ 描边；
* 按钮轨道带（内 `ringRadius - button×0.6` → `bandOuter` + 描边）；
* **外缘齿轮凸起**（圆心 `rimOuter - rimLobe×0.35`，半径 `rimLobe×0.72 + 描边`）；
* **高亮强调弧**（半径 `bladeLength×0.86`，线宽 `outline×2.2`）；
* **刀刃**（最极端槽位 ± 半张角，外半径 `bladeLength` + 描边 ×1.35，含内缘 1.18× 鼓包）；
* **按钮**（位置按弹出进度峰值 **1.36×** 外移 + 缩放 `1.14 × 1.36` + 描边）；
* **按钮中文标签**（径向朝外，含 overshoot 外移）；
* **标题 / chip / 说明**三层文字（半径取 `WheelTextLayout` 同源值，宽度取**安全带宽度**）；
* 反馈条（只在有反馈时）；
* 动画主体缩放峰值 **1.03**（`canvas.scale` 的 overshoot，围绕中心整体外扩）；
* `shadowPadding = 0`（当前 Painter **不画**阴影；文件里显式说明"若加阴影必须在此补偿"）。

`buttonVisualRects` 是按钮矩形的**唯一**来源：Region 与包围盒共用它。

### 2.5 修正：规划器不再用近似 envelope（`WheelCanvasPlanner`）

`measureReach` 改为调 `_visualInPetFrame(...)`：构造与正式实现**同公式**的测量布局
（`WheelMenuGeometry.layoutFor` + 合成信封），算出四侧外扩量与**视觉包围盒**。
画布 = 桌宠 + 四侧外扩 + 安全边，且：

* 锚点**取整**（避免 `Rect.fromLTWH(...).size` 出现 `255.99999999999994` 的浮点漂移
  —— 这个漂移真机上表现为 Region / 位置 1px 抖动）；
* 画布尺寸**向上取整**，`fits` 允许 **1px 取整容差**（否则"1088.4 → 1089 > 1088"
  会触发一次毫无意义的压缩）；
* `WheelCanvasPlan` 新增 `visualBoundsInCanvas` / `interactiveBoundsInCanvas` /
  `visualFitsCanvas` / `interactiveFitsCanvas`，即"会不会被裁"的**可断言事实**。

### 2.6 修正：Region 与 Painter 同源（`WheelRegionBuilder`）

* **不再**把每块 Region 夹进"菜单窗口矩形"——窗口只是信封，刀刃 / 外缘齿轮 /
  动画 overshoot / 文字安全带都可能超出它，提前夹就是真机上看到的**硬直线裁切**；
* 新增**刀刃分段**覆盖（旧实现完全漏掉，高亮扇区外半截被裁）；
* 扇环外缘覆盖到 `max(bladeLength, rimOuter) × 1.03 + 强调弧线宽`，内缘 `(ringRadius - button×0.6)/1.03`；
* 按钮命中块直接消费 `buttonVisualRects`（含 overshoot 外移与 1.36× 半径）；
* 标题 / chip / 说明的文字安全带整块纳入；
* 反馈条显式加回（漏掉会导致"反馈条画出来却点不到 + Region 不重算"）；
* `coversVisualBounds(...)`：按**真实会画的采样点**判覆盖（扇环按张角采样半径、
  刀刃按极端槽位外弧采样、按钮/标签/文字按四角+中心），
  **不用包围盒四角**（扇形包围盒的角落根本没有像素 —— 那是假失败）。

### 2.7 修正：打开前拒绝"裁掉交互内容"（§六）

`open()` 前置检查 `plan.interactiveFitsCanvas`；为 false 时**拒绝打开**并提示
"当前屏幕可用空间放不下轮盘按钮：请把桌宠拖离屏幕边缘，或调小轮盘大小 / 按钮大小"，
同时记 `wheel.open.refused`。装饰允许在 `truncated` 下被裁，**按钮 / 标签 / 返回 / 人物绝不裁**。

### 2.8 修正：拖动生命周期（§四）

新增 `FixedCanvasProbeState.onPetPositionChanged(x, y)` 并在外壳把
`windowController.onPositionCommitted` 接上（此前**根本没有装配**，所以拖完只写了持久化，
画布 / 快照 / 展开侧全停在旧值 —— 正是"移动后菜单出现在旧位置"的成因）：

1. 位置真的变了才处理（同像素重复回调忽略）；
2. 轮盘开着 → 先 `close(animate: false)`（Region 收敛回 pet，取消进行中的事务）；
3. `positionRevision + 1`（旧的在飞计算从此作废）；
4. 回读 `actualWindowRect` → 重建空间快照 → 重算人物视觉屏幕矩形 / 目标显示器 / `expansionSide` / Region；
5. 记 `pet.position.changed` 日志；**全程不 `commitBounds`、不重建画布**。

### 2.9 修正：关闭残片可断言（§八）

`_finishClose` 现在：`setState` + `scheduleFrame()` **强制再绘一帧**
（分层窗口必须被真正重绘，否则上一帧像素留在窗口表面），随后评估
`closedStateViolations()` 五条不变量并记
`wheel.close.invariants` / `wheel.close.invariants.violated`：

* `openProgress == 0`；菜单几何 inactive（widget 矩形已清 + 控制器已释放）；
* `shouldPaintMenu == false`（与 `WheelMenuRenderer.draw` 首行判据同源）；
* `RegionOwner == pet`；`interactionState == closed`。

⚠️ 这里**不能** `await endOfFrame`：本方法可能被外壳直接 await（托盘隐藏 / 拖动收起），
而 `endOfFrame` 依赖后续帧 —— 在 `flutter_tester` 里会永久挂起（本轮又踩了一次，已改成
`scheduleFrame + microtask`）。

### 2.10 新增：缩放诊断（`lib/menu/wheel_scale_audit.dart`）

`WheelScaleAudit` 一口气输出需求 §五 列的全部字段，并给出四条**可断言不变量**：
`normalizedOk`（持久化值已在归一化域）、`screenFactorOk`（只压缩不放大）、
`effectiveScaleOk`（= 归一化 × screenFactor，恰好一次）、
`buttonDiameterOk`（按钮直径只按一个公式算一次）。
`WheelDefaultRestore` 冻结"恢复 Android 默认"：**1.00 / 1.30 / 0.16 / p3p-pink**
（按钮倍率的 Android 默认值是 1.30）。

## 3. 验证与存证

| 项目 | 结果 | 证据 |
| --- | --- | --- |
| `flutter analyze` | **No issues found!**（exit 0） | `docs/43-evidence/incrC11-analyze.txt` |
| 定向测试（7 文件） | **193 passed / 0 failed** | `docs/43-evidence/incrC11-tests-directed.txt` |
| 全量测试 | **1330 passed / 1 skipped / 0 failed** | `docs/43-evidence/incrC11-tests-full.txt` |
| 全量测试（**交付前复验**，含清未用导入后的 HEAD） | **1330 passed / 1 skipped / 0 failed** | `docs/43-evidence/incrC11-tests-full-final.txt` |
| Windows Release | **只构建一次**，188.4s → `build_incrC11\windows\x64\runner\Release\petlife.exe` | `docs/43-evidence/incrC11-build.txt` |
| `build-dir` 还原 | 已回读 `%APPDATA%\.flutter_settings` → `"build-dir": "build"` | 同上 |
| 产物 SHA-256 | `petlife.exe` = `a92e13aa8bf309756fc0c0d9ec7a84ded0b432713855c708647b1e95aa3e05ed`<br>`data\app.so` = `fba86a4be760898721828734baf9fce5890f3d5d344549e98c129571cdb9f53e` | — |

### 四张截图回归（§十）几何快照（1920×1040、100% DPI、真机设置 0.6/1.3/0.16、256×192 Maya）

| 场景 | 桌宠位置 | 展开侧 | 画布 | 菜单窗口（画布局部） | 视觉包围盒 |
| --- | --- | --- | --- | --- | --- |
| A 右下 | 1376,534 | **left** | 530×607 | 29,84 → 376,522 | 8.3,7.7 → 521.7,598.3 |
| B 左下 | 64,780 | **right** | 530×607 | 85,-4 → 503,449 | 8.3,7.7 → 521.7,598.3 |
| C 左上 | 64,120 | **right** | 530×607 | 85,77 → 503,530 | 8.3,7.7 → 521.7,598.3 |
| D 中右 | 1500,500 | **left** | 530×607 | 29,84 → 376,522 | 8.3,7.7 → 521.7,598.3 |

四场景全部满足：`wheelWindowFitsCanvas` ✓、`visualFitsCanvas` ✓、`interactiveFitsCanvas` ✓、
展开侧正确 ✓、**缺口中心 = 人物视觉中心（< 2px）** ✓、关闭后 `closedStateViolations()` 空 ✓。

> 口径说明：`menuLocalRect.top = -4`（场景 B）表示**信封窗口**比画布高 4px；
> 但真正会被绘制的像素（视觉包围盒 7.7…598.3）完整落在画布 0…607 内，
> 因此不会裁切。判据用"会被绘制的界限"而不是"信封窗口"，
> 这一点由 `plan.visualFitsCanvas` 与四场景断言共同钉住。

### 与 Android 默认比例对照（§九）

| 比例 | 真机修复前 | 修复后 | Android 基准 |
| --- | --- | --- | --- |
| `ringRadius / 人物可见高度` | 220.6 / 156 = **1.41** | 124.9 / 156 = **0.80** | 0.7 ~ 1.0 |
| `holeRx` vs 可见宽 | 144.4 vs 92（1.57×） | 58.3（= 92×1.05/2+10） | 同公式 |
| `holeRy` vs 可见高 | 110.8 vs 156（0.71×） | 91.9（= 156×1.05/2+10） | 同公式 |
| 按钮直径 / 人物高度 | 44×0.6×1.3 = 34.3 → 0.22 | 同左（公式未改，**只应用一次**） | `44dp × scale × buttonScale` |

测试 `10 默认设置下 ringRadius 与人物可见尺寸同量级` 把 `0.55 ~ 1.6` 钉成区间。

## 4. 新增测试（`test/wheel_c11_geometry_regression_test.dart`，27 项）

覆盖需求 §十一 的清单项：alpha 计算 / 全透明回退 / 多帧稳定并集 **1/1b/2**、
视觉锚点而非素材矩形 **3**、缺口中心不变量 **4**、左/右/两侧判定 **5/6/7**、
不二次镜像 **8**、比例基准 **10**、视觉包围盒入画布 **11**、
拖动用新位置 **12**、拖动先收起 **13**、旧 revision 丢弃 **14**、
默认不重复缩放 **15**、250% 压缩 **16**、恢复默认口径 **17**、越界值归一化 **18**、
Region 覆盖全部绘制元素 **19/20**、overshoot 预留 **21**、
关闭后不再绘制 **22**、四张截图回归 **23**、
三分辨率 × 三 DPI **24**、负坐标副屏 **25**、HWND 不变 **26**、Android 隔离 **27**。

`test/wheel_visual_geometry_diag_test.dart`（步骤 A 的产物）留在仓库里，
作为"真机设置 → 全链路几何"的可复现诊断（打印画布 / 锚点 / 四侧预留 /
信封 / 布局 / Region / 是否装得下）。

## 5. 明确未做的事

* **未改 Android**（`android/` 一行未动）；新增的纯 Dart 模块由测试钉住
  "不得 import `dart:io` / material / window_manager / platform/windows / region_coordinator"。
* **未接 `records_*`**（C2）。
* **未做 golden 图**：四场景的**几何 JSON 快照**已固化在测试输出里（可对账）；
  golden 位图受本机字体渲染影响，本轮先用几何快照 + 断言，避免引入不稳定的基线。
  如需位图基线，建议在 CI 固定字体后单独补一轮。
* **未做真机验收**：到构建为止，接下来暂停等真机验收。

## 6. 真机验收步骤

1. **第一步先看设置**：确认 `wheel.scale`（当前 0.6）、`buttonScale`（1.3 = 默认）、
   `menuDistance`（0.16）；再打开控制面板「设置 → 轮盘」核对显示值一致。
2. **比例**：桌宠靠右下（如 1376,534）打开轮盘 → 菜单应完整在**左上**，
   占屏高度明显小于半屏，按钮与文字完整、扇形无直线切口。
3. **副作用方向**：把桌宠拖到屏幕左侧（如 64,780）→ 菜单应完整在**右上**（与上一步相反）。
4. **拖动刷新**：轮盘打开时拖动桌宠 → 菜单**立即收起**；松手后再打开 →
   菜单围绕**新位置**展开，不再出现在旧位置。
5. **缺口对齐**：目视确认扇形的"咬口"正对人物（不是素材方框的中心）。
6. **关闭残片**：在屏幕右下 / 中间各开一次再关，关闭后**不得**在任何位置看到粉色扇形残片。
7. **设置边界**：把「轮盘大小」拉到 250%（256×192 素材在 1920×1040 上）→
   应被压缩；若压到最小仍放不下，打开菜单时应看到
   "当前屏幕可用空间放不下轮盘按钮…"而不是被裁掉按钮。
8. **恢复默认**：点「恢复默认」→ 轮盘 100%、按钮 130%、菜单距离 0.16、主题 P3P 粉。
9. **不动窗**：全程窗口矩形不变（菜单开合只改 Region）。

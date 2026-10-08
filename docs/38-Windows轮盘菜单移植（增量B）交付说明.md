# 38 · Windows 轮盘菜单移植（增量 B）交付说明

> ⚠️ **部分已被取代（2026-10-06）**
> 本文件 §1 的产物、§10 的「按设置上限预留固定画布」结论**已被否决**：
> 构建产物标记为 **superseded**，固定画布改为「按当前设置 + 当前屏幕可用空间」规划。
> 请看 `docs/39-固定画布按当前设置与屏幕可用空间规划（增量B修正）.md`。
> 本文件其余部分（菜单树 / 动作 ID 映射 / 几何与 Region 规则 / 动画参数 /
> 主题色值 / 测试清单）**仍然有效**。

> 基准：`docs/37-Android轮盘菜单视觉与交互基准审计.md`（Android 是唯一视觉与交互基准）。
> 范围：**只做 UI / 层级 / 动画 / 交互**；正式业务动作留到增量 C。
> 未改动：Android 任何文件、服务端、`RegionCoordinator` 语义、动态 `setBounds`（不恢复）、诊断探针与回退入口（不删除）。

---

## 1. 交付产物

| 项 | 值 |
| --- | --- |
| 可执行文件 | `build_incrB\windows\x64\runner\Release\petlife.exe` |
| exe SHA256 | `84699a5b010357c575490f6c0456eadc1be4e06cb1645bd015067b0247af37db` |
| AOT 产物 | `build_incrB\windows\x64\runner\Release\data\app.so` |
| app.so SHA256 | `b6bb077abfbb9f18b4ade89169f3972e785ecab0576a520304e1baf07d5945ff` |
| 构建命令 | `flutter config --build-dir=build_incrB` → `flutter build windows --release --no-pub` → `flutter config --build-dir=build` |
| 构建耗时 | 232.3s（AOT + MSVC x64 Release） |

**为什么用 `build_incrB` 而不是默认 `build`**：默认输出目录里残留 9 个上一轮会话遗留的
`petlife.exe` 进程（Console 会话），占用 `build\windows\x64\runner\Release\*.exe / *.dll`，
直接构建会因文件占用失败。为避免杀掉用户可能正在使用的进程，改用独立目录构建
（沿用 `build_incrA` 的命名约定），**构建结束后已把 `build-dir` 恢复为 `build`**
（`%APPDATA%\.flutter_settings` 现为 `{"jdk-dir": "...", "build-dir": "build"}`）。

> 交付包 = `build_incrB\windows\x64\runner\Release\` 整个目录（exe + 3 个插件 dll +
> `flutter_windows.dll` + `dartjni.dll` + `sqlite3.dll` + `data\`）。

---

## 2. 菜单树与动作 ID 映射

目录来源：`lib/menu/menu_contract.dart` · `MenuCatalog`（与 Android `WheelMenuCatalog` 逐字对齐）。
固定返回键 `back`（`MenuNavigationIds.back`）挂在每个子菜单末尾。

### 根菜单 `root`（标题「桌宠 / PETLIFE」，6 项）

| # | node id | actionId | 标签 |
| --- | --- | --- | --- |
| 0 | `root_pet` | `open_pet` | 桌宠 |
| 1 | `root_appearance` | `open_appearance` | 形象 |
| 2 | `root_records` | `open_records` | 记录 |
| 3 | `root_tools` | `open_tools` | 工具 |
| 4 | `root_settings` | `open_settings` | 设置 |
| 5 | `root_hide` | `win_root_hide` | 隐藏 |

### 子菜单

| 层级 id | 标题 | 条目（node id → actionId） |
| --- | --- | --- |
| `pet` | 桌宠 / PET | `pet_size_down`→`win_pet_size_down`、`pet_size_up`→`win_pet_size_up`、`pet_size_reset`→`win_pet_size_reset`、`pet_auto`→`pet_auto`、`pet_current`→`pet_current`(info)、`pet_home`→`win_pet_home`、`back` |
| `appearance` | 形象 / APPEARANCE | `appearance_prev`、`appearance_next`、`appearance_auto`、`appearance_fav`、`appearance_mapping`、`appearance_library`、`back` |
| `records` | 记录 / RECORD | `records_today`、`records_app`(info)、`records_stats`、`records_cloud`、`back` |
| `tools` | 工具 / TOOLS | `records_track`、`records_sync`、`records_sync_state`、`tools_open_app`→`win_tools_open_app`、`back` |
| `settings` | 设置 / SYSTEM | `settings_theme`、`settings_wheel_size`、`settings_button_size`、`settings_open`、`back` |

`MenuNavigationIds.open*` 为**进层动作**（`enterLayerByAction`）；`MenuInfoIds.*`（`pet_current` /
`records_app`）是**只读信息条目**，只刷新文字 chip，不执行动作也不进层。
增量 B 只登记 / 提示「该功能将在下一阶段接入」，**不执行真实业务**。

---

## 3. 几何规则（1:1 对齐，逐字）

来源：`lib/menu/wheel_menu_geometry.dart`，常量与公式逐字取自审计文档 §4/§5。

**尺寸参数（dp，`density=1.0`）**：`BUTTON_DIAMETER_DP 44`、`BUTTON_DIAMETER_COMPACT_DP 40`、
`BUTTON_GAP_DP 6`（固定不暴露）、`BAND_PADDING_DP 8`、`RIM_LOBE_DP 7`、`OUTLINE_DP 2.2`、
`MIN_OUTLINE_DP 1.2`、`MAX_OUTLINE_DP 4.5`、`MIN_OUTLINE_SCALE 0.72`。

**用户设置 `WheelMenuLayoutSettings`**：

| 参数 | MIN / MAX / STEP / DEFAULT |
| --- | --- |
| 轮盘大小 `preferredScale` | 0.50 / 2.50 / 0.10 / 1.00 |
| 菜单距离 `menuDistance` | 0.05 / 0.30 / — / 0.16 |
| 按钮大小 `buttonVisualScale` | 0.50 / 2.50 / 0.10 / 1.30 |
| 按钮触摸直径下界 | 48 dp |

**固有几何 `intrinsicLayout`**（输入只有 itemCount / spec / settings / 桌宠可见宽高）：

```
compact   = settings.compactMode
halfSpan  = halfSpanFor(count, compact)                 // 68° / 50°，紧凑下界 38°
step      = stepDegFor(count, halfSpan)                 // 16°..30°
effScale  = preferredScale * (compact ? 0.92 : 1)
buttonDia = buttonDiameterFor(count, effScale * buttonVisualScale)
          = (count >= 7 ? 40 : 44) * (effScale * buttonVisualScale).clamp(0.20, 4.0)
notchRxRaw= petVisibleW * 1.05 / 2 + 10dp               // 缺口必须始终盖住桌宠
notchRyRaw= petVisibleH * 1.05 / 2 + 10dp
minRadiusForNotch = max(notchRxRaw, notchRyRaw) / 0.88 + buttonR
spacing   = spacingRadiusPx(count, step, buttonDia)      // 轨道间距
clearance = hypot(petW/2, petH/2) + petW * menuDistance + buttonR + 4dp
ringRadius= max( max(spacing, minRadiusForNotch), max(clearance, 62dp) )   // 三式求解
bandOuter = ringRadius + buttonR + 8dp
rimOuter  = bandOuter + 7dp
bladeExtent = (0.42 * ringRadius).clamp(40dp, 88dp)
bladeLength = rimOuter + bladeExtent * preferredScale.clamp(0.50, 2.50)
```

**三条结构性分水岭（Audit §3，Windows 端必须一致）**：

1. **扇形不是圆盘** —— 按钮沿一段圆弧分布，半张角 `halfSpan`，靠边时叠加 `fanBiasDeg ±26°`；
2. **缺口绑桌宠，不是"挖洞"** —— 缺口椭圆中心**恒等于桌宠视觉锚点**，半径由桌宠**可见**尺寸决定
   （`×1.05` 相对比例 + `10dp` 边距），**不乘应急缩放**；
3. **人物在菜单之上** —— 桌宠矩形始终在 Region 的第一位，人物层永远可点。

**方向 / 垂直模式**：`decideDirection` 比较桌宠中心左右剩余空间取较大侧，带 8% 宽度死区滞回；
`decideVerticalMode`：`above < below*0.55 → topEdge(+26°)`、`below < above*0.55 → bottomEdge(-26°)`、
否则 `center`，带 6% 高度死区滞回。**靠边只改扇形朝向 + 降实际缩放，绝不平移轮盘中心**
（平移会让缺口与桌宠错位）。镜像只把 `absoluteAngle` 取反（左展开 = `180° − offset`），**图标内容不镜像**。

**两段式 API**：`computeEnvelope`（打开时一次，`maxItemCount = 7`）与 `layoutFor`
（换层 / 切选中时在同一信封内重算）。打开期间**窗口矩形不变**。

---

## 4. Region 规则

来源：`lib/menu/wheel_region.dart` · `WheelRegionBuilder`。

* Region 成员 = `桌宠缺口外接矩形 ∪ 弧带扇形(10 段外接矩形) ∪ 按钮命中圆 ∪ 文字 chip ∪ 反馈条`；
* **绝不是"整块画布"** —— 否则轮盘会吃掉整屏鼠标事件（有专门断言守护）；
* 矩形数量上限 `maxRects = 48`，超出时**丢弃面积最小**的若干块；
* 夹进窗口；宽或高 ≤ `mergeTolerance(1.5)` 的碎块被丢弃；
* 按钮命中圆用**触摸直径**：`max(buttonTouchDiameterPx, buttonDiameterPx * 1.14)`；
  弹出进度 ≤ 0.01 的按钮**不产生**命中块（「不画就不该能点」）；
* **只在**开 / 关、镜像方向、层级变化、尺寸变化时重写；**悬停与滑动过程中不重写**；
* 关闭走 180ms 收起动画，**动画结束才收敛 Region**；面板切换则立即收敛。

实测（默认设置、256 桌宠、1920×1080）：**13 块**（1 桌宠 + 10 扇形段 + 1 按钮圆 + 1 chip）。

---

## 5. 动画参数

来源：`lib/menu/wheel_animator.dart`。

**时间线（ms）**：`OPEN 300`、`CLOSE 180`、`SELECT 220`、`ENTER_LAYER 300`、`EXIT_LAYER 230`、
`PRESS 70`、`BUTTON_STAGGER 25`；展开分段 `BODY 0→120`、`BUTTON 50→230`、`TITLE 100→300`；
关闭整体同收，`CLOSE_BUTTON_TAIL 40`。

**缓动（CubicBezier 控制点，牛顿 8 次 + 二分 18 次求解）**：

| 曲线 | 控制点 | 用途 |
| --- | --- | --- |
| `OPEN` | (0.16, 1.0, 0.30, 1.0) | 展开 |
| `SWITCH` | (0.22, 0.85, 0.30, 1.0) | 切换 / 换层 |
| `CLOSE` | (0.55, 0.0, 0.85, 0.35) | 关闭 |
| `POP` | (0.18, 1.36, 0.36, 1.0) | 按钮弹出轻微回弹 |

**帧推导（`WheelAnimationClock.frame`，纯函数）**：

```
raw   = clamp((now - startedAt) / duration, 0, 1)
eased = open ? OPEN(raw) : close ? CLOSE(raw) : SWITCH(raw)
openProgress  = open ? OPEN(raw) : close ? 1-CLOSE(raw) : 1
layerProgress = enterLayer ? eased : exitLayer ? 1-eased : 1
titleProgress = selectionSwitch/enterLayer ? eased : exitLayer ? 1-eased : 1
buttonProgress[i]:
    open       → POP(clamp((elapsed-(50+min(25, 180*0.5/(count-1))*i))/180, 0, 1))   // 错峰
    enterLayer → staggeredPop(delay=80, total=300)
    exitLayer  → staggeredPop(delay=60, total=230)
    其它       → 1
rotationDeg: open → raw<0.5 ? -6+7*(raw/0.5) : 1-1*((raw-0.5)/0.5)；close → 6*raw；其它 0
scale      : open → raw<0.55 ? 0.75+0.28*(raw/0.55) : 1.03-0.03*((raw-0.55)/0.45)
             close→ 1-0.25*raw；其它 1
```

**驱动纪律**：单一 ticker；`run` + `pressRun` 互相**接管**（新动画先按旧动画当前帧收敛再起）；
`run == null && pressRun == null` → 立刻停 ticker（不留 Timer/Animator）。

---

## 6. 主题色值（逐字）

来源：`lib/menu/wheel_theme.dart`。`themeId` 的 wire 取值是 `p3p-pink`（不是 `p3p_pink`）。

| 角色 | 值 |
| --- | --- |
| primary | `#F24D96` |
| secondary | `#FF8ABA` |
| background | `#FFD8E9` |
| highlight（强调，各预设共用） | `#FFD42A` |
| outline（描边，各预设共用） | `#111111` |
| text | `#FFFFFF` |
| disabled | `#8E7180` |

派生：`baseFanColor = mix(secondary, background, 0.40)` 再压 alpha `108`；
`autoTextColor` 大号粗体对比度阈值 `3.0`（浅色主色→近黑）。
其它预设只钉主色：`blue #2F7CF6`、`red #E23B3B`、`purple #8B4DE0`、`green #1FA463`；
`custom(primary)` 走同一派生算法，非法色回退 P3P 主色派生且不抛异常。

**图标**：`lib/ui/desktop/wheel_icons.dart` —— 39 个原创 `Path` 图标（不用 Material、不用图片资源、
不用 P3P 原始版权资产），归一化 `[-1,1]²`、`STROKE = 0.16`、`lineCap/Join = ROUND`，
Path 以**按钮内容框**缩放，**始终直立**（镜像只镜像槽位布局）。

---

## 7. 设置持久化 / 诊断开关

* 新增持久化字段：`wheelThemeId` / `wheelCustomPrimary` / `wheelScale` / `wheelButtonScale` /
  `wheelMenuDistance`，键名前缀 `wheel.*`（已无 `menuGap`；`fixed_canvas_contract.dart` 里的
  `menuGap` 是**画布几何常量**，保留不删）；
* 取消用户设置里的 `menuGap`，统一为 Android 已有语义的 `menuDistance`
  （范围 0.05~0.30、默认 0.16，含义「菜单中心相对桌宠可见宽度的偏移比例」）；
  只改变轮盘中心相对人物锚点的距离，**不改**固定画布 HWND / `petAnchor` / 人物缩放 / 按钮间距
  （Android 内部 `BUTTON_GAP_DP = 6` 保持固定、不暴露）；
* `normalized()`：区间内按 10% 步进吸附，越界一律夹到 MIN/MAX；
* 设置页新增「桌宠轮盘」`WheelSettingsCard`（主题 chip + 自定义主色、轮盘大小、按钮大小、菜单距离、恢复默认）；
* 诊断开关 `FixedCanvasDiagnosticsFlags`（单例 `ValueNotifier`，默认全 `false`）：
  面板显示 / 六色块测试菜单 / Region 可视化。测试菜单与正式轮盘**互斥**。

---

## 8. 测试结果（原始）

| 项 | 结果 |
| --- | --- |
| `flutter analyze` | **No issues found!**（ran in 4.3s） |
| 增量 B 定向测试 | **+92 All tests passed!**（parity / icons / view 三个文件） |
| 全量测试 `flutter test` | **+1103 ~1 All tests passed!**（1103 通过 / 1 跳过 / 0 失败） |

增量 B 新增测试：

* `test/wheel_menu_android_parity_test.dart` —— 与 Android 逐项对照（主题色值与派生、
  几何常量、信封缺口与 ringRadius 三式、方向与镜像、七态状态机、手势、
  动画时间线与帧推导、Region 生成、固定画布桥接、设置夹取与持久化）。
* `test/wheel_menu_icons_test.dart` —— 39 图标覆盖与映射、描边画法、
  归一化范围、直立性。
* `test/wheel_menu_view_test.dart` —— 装配层输入映射（打开期间拦输入、点击确认、
  滑过不执行、悬停只预览、缺口/空白关闭、Esc 三级收敛、滑选中 Esc 取消）。

本轮修正的**测试期望错误**（实现与 Android 一致，是断言写错了）：

1. 按钮直径 = `base(count) × (effScale × buttonVisualScale)`（`effScale` 含 `preferredScale`）
   —— 原断言误以为轮盘大小不影响按钮直径；
2. 展开错峰 `start = 50 + min(25, 90/(count-1)) × i`，6 项时 = 18ms（原断言假设间隔 ≥ 74ms）；
3. `normalized()` 越界**夹取**（`MIN_SCALE 0.50`），不是吸附到更小值；
4. `Paint.strokeWidth` 走 Skia float32，`0.16` 存回是 `0.1599999964237213`（改容差比较）；
5. 视图测试：生产路径 `prepareContent → setInteractive(true) → beginOpenAnimation`，
   harness 漏了 `setInteractive(true)`，导致所有指针事件被丢弃；
6. 视图测试：默认测试视口 800×600 放不下 587×816 的轮盘窗口，落在下缘的坐标成为
   「屏幕外」→ 指针事件不派发（假阴性）；改为把视口设为 1920×1080；
7. 视图测试：「滑选中 Esc」的位移 +2dp 未超过 12dp 的 swipe 阈值，根本没有进入滑选。

同时把 4 个**增量 A 旧契约测试**更新到增量 B 契约（断言不弱化）：

* `#2/#5`：`Region` 不再是「桌宠 + 一块菜单矩形」两块 → 改为断言
  「块数 ∈ [2, 48]、第一块是桌宠矩形、没有任何一块覆盖整块画布」；
* `#4`：方向不再靠「菜单矩形边缘」推断（扇形包围块会与桌宠块水平重叠）→
  改为断言 `wheelEnvelope.direction`（靠左→`right`、靠右→`left`），并断言镜像只改菜单 Region；
* `#6b`：右键 Overlay 放大到「整块固定画布」——画布尺寸不再硬编码 `1352×560`，
  改为按同一公式（桥接预算与增量 A 旧公式**逐维取大**）计算；
* 右键测试：`Region 仍是 pet+menu` 由「恰好 2 块」改为「多块几何、且不出现整块画布」。

---

## 9. 真机验收步骤（Android / Windows 并排截图）

> 本轮**未执行**（需要真机 / 模拟器对照，不在自动化范围内）。

用 `FixedCanvasDiagnosticsFlags.panelVisible = true` 打开诊断面板，逐项截图 Android 与 Windows 并排：

1. 收起态（桌宠单独，无菜单）；
2. 打开动画中途帧（约 120ms，按钮错峰中）；
3. 完全展开（根菜单 6 项）；
4. 高亮 / 选中态（滑选到 3 号槽，刀刃 + chip）；
5. 子菜单（进入「桌宠」后的换层过渡帧 + 稳定帧）；
6. `menuDistance` 0.05 / 0.16 / 0.30 三档（只改中心距离，窗口矩形不变）；
7. 轮盘大小 0.5 / 1.0 / 2.5；
8. 按钮大小 0.5 / 1.3 / 2.5；
9. 靠左 / 靠右（方向 + 镜像）、靠上 / 靠下（±26° 偏转）；
10. 关闭动画中途帧；
11. 主题切换（P3P 粉 / blue / red / purple / green / custom）+ 诊断 Region 边界可视化。

每张图核验：按钮直径基准、扇形半张角、缺口是否盖住桌宠、人物是否在菜单之上。

---

## 10. 已知限制与需要复核的偏差

1. **固定画布尺寸变大（需复核）**：`_canvasPlan` 取
   `max(桥接预算画布, 增量 A 旧公式画布)` 逐维较大值，而桥接预算按
   `preferredScale / buttonVisualScale / menuDistance` 的**上限**预留。
   256 桌宠实测画布 `2054.7 × 2054.7`（增量 A 旧公式为 `1352 × 560`）。
   这是「拖动任何轮盘设置都不改窗口矩形」这一决策的直接后果，但**窗口比增量 A 大**，
   如不希望预留到 max 档，请明确新的预算口径（例如按默认档预留、极端档允许裁切）。
2. **正式业务动作未接**：增量 B 只登记 / 提示，真实动作留到增量 C。
3. **右键 Overlay 与轮盘互斥**：轮盘打开时右键被拒绝（优先级 `wheel > contextMenu`）。
4. **鼠标穿透开启时**拒绝打开菜单并给明确提示。
5. **并排截图验收未做**（见 §9）。

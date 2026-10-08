# 50 · Windows 轮盘「扇形角度选择」与「鼠标移动回落」修复（增量 **C1.1.3**）交付说明

> 范围：**只改鼠标输入模式 / 统一 HitTest / 扇形角度映射 / 高亮派生 / 日志 / 测试**。
> 不改视觉尺寸、不改四角位置、不改 alpha 上下界、不改画布 / Region、
> 不改动画时长、不改业务菜单、不碰 Android、**不进入 C2**。
> 前置：`docs/49-Windows轮盘悬停与静止单击稳定性修复（增量C1.1.2）交付说明.md`。
> 本文即需求 **§1–§13** 的落地交付。

---

## 1. 真机症状（回归项）

1. 鼠标移入**正式扇形**（扇叶本体），**必须精确压在按钮小圆或窄环带上**才有反应 ——
   落在扇形里但不在圆/环上时**没有高亮**。
2. 沿着扇形**圆弧方向**移动 → 高亮**不切换**（或乱跳）。
3. 鼠标**沿半径向内 / 向外**移动（同一角度）→ 高亮**丢失**。
4. 鼠标**移出有效扇形**（但仍落在窗口 Region 内）→ 扇叶 / 标题 chip / 实时信息
   **回落到第 1 项**（而不是取消高亮）。
5. 在扇形区域内**静止单击** → **没执行**（被判成背景）。

---

## 2. 根因（日志实测，非推测）

诊断脚本（`.tmp_c113_diag.txt`，诊断用临时测试已删除）在真机几何下抓到了**完整回落链**：

```
GEOM center=(199,408) ring=252 rimOuter=293 bladeLen=381 bladeHalf=30
     fanHalf=68 bias=0 step=27.2 btnD=52 notchRx=144.4 window=587x816 dir=right items=6
```

**关键事实：`rimOuterPx=293`，但扇叶真正画到 `bladeLengthPx=381`**
（正式几何里 `max(bladeLengthPx, rimOuterPx)`）。

| 步骤 | 鼠标位置 | 实测 | 结论 |
| --- | --- | --- | --- |
| A 悬停 slot3 圆心 | `r=252` | `hover=3 stateSel=0 selPos=3.00 bladeA=13.6` | 基准：命中圆内正常 |
| B 微动 +4,+4 | `r=256.8` | `hover=3 selPos=3.00` | 有微动容差，稳定 |
| C 同角度向外 `rimOuter+30` | `r=323` | `hitZone=label hover=3` | 标签带仍能命中 |
| **D 同角度向外 `rimOuter+90`** | **`r=383`** | **`hover=null visualActive=-1 hitZone=background selPos=0.00 bladeA=-68.0`** | **← 症状 1/3/4 的真凶**：`383>293`，旧代码只在 `distance<=rimOuterPx` 才做角度槽位判定，**293–381 的扇叶本体被判成背景** |
| E 同角度向内 `notchRx*1.5` | `r=216.6` | `hitZone=slot hover=3` | 缺口外正常 |
| **J slot4 角度 `rimOuter+40`** | `r=333` | **`hover=null hitZone=background`** | **← 症状 5 的真凶**：扇形内的静止点被判成背景 → 单击走 `outsideTap → onRequestClose()` → 关菜单但什么都不执行 |

### 两个确认的缺陷

1. **有效扇形半径错配**：旧 HitTest 半径上限取 `rimOuterPx=293`，
   而正式扇叶画到 `max(bladeLengthPx, rimOuterPx)=381`。
   ⇒ 半径 293–381 的**整段扇叶本体**既不高亮、也不能点击。
2. **背景命中把视觉锚点写回第 1 项**：旧代码在判为背景时
   `state.selectedIndex`（=0）被拿去驱动扇叶 / 标题 chip / 实时信息，
   于是移出扇形时 `selPos 3.00 → 0.00`、`bladeA 13.6 → -68.0`，
   **视觉整体回落到第一项**（§1-4）。

> 用户猜测的"扇叶被重置为第一项是因为某处写了 `selectedIndex=0`"被证实为
> **派生链问题**：没有任何动画 / 定时器把 hover 归零，是"背景命中 → 锚点取 `state.selectedIndex`
> → 恰好等于 0"造成的。**未改任何动画参数**即修复。

---

## 3. 决策（对应需求 §3–§11）

- **鼠标模式粘性**（§3）：`activeInputKind = mouse` 后**只有真实键盘导航事件**才切回键盘模式；
  鼠标模式下 `visualActiveIndex = hoveredIndex ?? -1`，
  **绝不**回落到 `keyboardFocusedIndex / gestureSelectedIndex / activeIndex / firstEnabledIndex / 0`。
- **一个统一 HitTest**（§4）：`WheelHitTester.resolve(local, {previousIndex, selectedIndex})`
  → `WheelPointerHit{ kind, buttonIndex, slotIndex, radius, angle, distance }`，
  `enum WheelPointerHitKind { buttonCircle, buttonLabel, angularSector, petProtection, decoration, outside }`。
  **悬停 / down / up / 圆弧拖拽**四条链路全部走它。
- **六级优先**（§5）：① 按钮圆形 → ② 该按钮自己的标签 / chip → ③ 有效扇形的角度槽位
  → ④ 人物保护区 → ⑤ 纯装饰 → ⑥ Region 之外。
- **有效扇形取自正式几何**（§6）：角度 = 正式扇形 `start → end`（含 `fanBiasDeg`、镜像一致）；
  半径 = 缺口外缘 → `max(bladeLengthPx, rimOuterPx)`；**排除**远端标题 / 阴影 / 装饰文字。
- **角度映射**（§7）：`atan2` → 归一化到正式扇形域 → 最近槽位中心；
  **7° 滞回**（复用 `WheelMenuGeometry.rawIndexAt`，不另造槽位角度）；图标保持正立。
- **半径方向保持同按钮**（§8）：同一角度下半径向内 / 向外移动都在有效扇形内 → 同一按钮；
  落进人物保护区才交给桌宠规则。
- **实时 HitTest 判定点击**（§9）：`down.buttonIndex != null && up.buttonIndex == down.buttonIndex`
  才执行；**允许** down 在扇形、up 在圆内。
- **高亮派生原则**（§11）：`hoveredIndex` **只**由鼠标 HitTest 写入；
  切换层级 / 几何变化后**用新几何重算**，**绝不默认 0**。

### 关键设计：粘性锚点 `anchorIndex`

需求 §1-4 要求"移出有效扇形 → 取消鼠标高亮，**不回落到第一项**"。
为区分"**高亮**取消"与"**扇叶/标题锚点**取消"，引入独立字段：

- `hoveredIndex`：**只**表达"鼠标当前在哪个按钮上"（移出 → `null`）。
- `anchorIndex`：驱动扇叶 / 标题 chip / 实时信息的**视觉锚点**；
  悬停 / down / up / 圆弧拖拽时更新，**移出有效扇形时保持不变**（粘住最后一项）；
  只有 **cancel 手势结果**（以及换层 / 关闭 / 清指针态）才重置。

⇒ `visualActiveIndex = -1`（无高亮）时，扇叶与标题**停在最后悬停项**，
不再"跳回第一项"。

---

## 4. 实现

### 新增 / 重写（纯 Dart，可 `flutter_tester` 直接单测）

| 文件 | 职责 |
| --- | --- |
| `lib/menu/wheel_button_hit.dart` | **完全重写**：`WheelPointerHitKind`（六级）+ `WheelPointerHit` + `ButtonHitRegion`（按按钮索引，逻辑不变）+ `WheelPointerSector`（有效扇形：`startAngleDeg / sweepDeg / outerRadiusPx / containsAngle / contains / insideNotch`）+ `WheelHitTester`（**统一 `resolve`** + 角度槽位映射 + 7° 滞回）。`radiusTolerancePx=2`、`angleToleranceDeg=2`、`hysteresisDeg=7`。 |
| `lib/menu/wheel_pointer_state.dart` | 新增 **`anchorIndex`**（粘性锚点）+ `lastHitZone / lastHitRadius / lastHitAngle`；`visualActiveIndex` 简化为三态优先级（`pressedIndex ?? gestureSelectedIndex ?? hoveredIndex`）；新增 `highlightSource`；`clearPointer / reset` 一并清 `anchorIndex`；`describe()` 增补 `anchorIndex / hitZone / radius / angle / visualActiveIndex / highlightSource`。 |

### 改动

| 文件 | 改动 |
| --- | --- |
| `lib/ui/desktop/wheel_menu_view.dart` | `activeIndexNow` 改为**从粘性锚点派生**（`pointer.anchorIndex`，回退 `state.selectedIndex`）；新增 `resolvePointerHit(local, {previousIndex})`（`hitTestAt` 保留为别名）；新增 `_logHitResolve` / `_logHighlightDerived`；`pointerDown / pointerUp / pointerMove / hover / recomputeHover` 全改用 `resolvePointerHit`（down/up 取 `buttonIndex`，并传 `previousIndex: pointer.hoveredIndex` 供滞回）；`_setHovered` 移出时**保留** `anchorIndex`、移入时更新；新增 `_applySwipeHighlight(local)` 供圆弧拖拽（§4）；`cancel` 分支是全代码**唯一**显式重置锚点处；`_setInputKind` 追加 `wheel.pointer.mode` 日志；`_refreshInfo` 用 `activeIndexNow` 取信息。 |

### 需求 §2 的时间线日志（沿用 `wheelGeometryJournal`）

事件：`wheel.pointer.move / wheel.pointer.mode / wheel.hit.resolve /
wheel.hover.changed / wheel.highlight.derived`（另保留 C1.1.2 的
`wheel.pointer.down/.up / wheel.hit.down/.up / wheel.animation.completed / wheel.action.confirmed / wheel.close.requested`）。
字段：`pointerLocal / inputKind / previousHoveredIndex / resolvedHoveredIndex /
keyboardFocusedIndex / gestureSelectedIndex / visualActiveIndex / hitZone / angle / radius / phase / geometryRevision`。

---

## 5. 测试（51 项定向 + 全量回归）

新增 `test/wheel_c113_sector_test.dart`（**51 项** = 7 项 × 6 场景 + 9 项定场景）：

**六场景矩阵**（左 / 右镜像 × top / middle / bottom，坐标与 C1.1 / C1.1.1 同源）：
`左上(右展开/靠上)`、`顶部居中`、`右上(左展开/靠上)`、`中部居中`、`左下(右展开/靠下)`、`右下(左展开/靠下)`。
每场景 7 项：

| # | 需求 | 断言 |
| --- | --- | --- |
| §12-1/2/3 | §1a/§8 | 悬停第 3 项后微动 / 沿半径向内 / 向外 → **仍是第 3 项** |
| §12-4 | §1c | 沿圆弧移到第 4 项 → 高亮切到第 4 项 |
| §12-5 | §7 | 相邻槽位边界附近受 **7° 滞回**保护 |
| §12-6/7 | §1e | 移出有效扇形 → `hover=-1`，**且锚点不回第一项**（`activeIndexNow != 1`） |
| §12-9/10 | §6 | 在扇形中但**不在窄环带上** → 能选中，且静止单击**执行该按钮** |
| §12-13/14 | §5/§10 | 人物保护区与装饰区**都不映射**按钮 |
| §12-15/16 | §5 | 每个槽位：圆心 / 扇形角度槽位都命中**它自己** |

**定场景 9 项**（右展开 / 居中）：§2-日志事件齐全、§3 键盘焦点不接管鼠标高亮、
§12-11 down 在扇形 + up 在同按钮圆内 → 只执行一次、§12-12 down/up 异槽 → 不执行也不关闭、
§8 保护区点击按桌宠规则、§12-17 换层后按当前鼠标位置重算、§12-18 打开动画期移动 → 打开后高亮正确、
§12-20 连续移动 500 次无异常无越界、§12-19 widget 层 rebuild 不把鼠标状态打回第一项。

配套变更：`test/wheel_c112_interaction_test.dart` 随 API 更名同步
（`WheelHit→WheelPointerHit`、`hitTest→resolve`、`.index→.buttonIndex`、`WheelHitKind→WheelPointerHitKind`）。

验证结论（当前 HEAD 实跑）：

- `flutter analyze` → **No issues found!**
- 定向（C1.1.3 + C1.1.2 + view + C1.1 几何 + C1.1.1 顶部边缘 + probe）→ **+162 All tests passed!**
- 全量 → **+1423 passed / ~1 skipped / 0 failed**（C1.1.2 基线 1372 + 本轮 51）。

---

## 6. 真机验收步骤（§1 / §12）

> 前置：直接运行 §7 的 Release。

1. 打开轮盘，把鼠标移入**扇叶本体**（**故意不压**在小圆和环带上）→ 立即高亮对应按钮。
2. 沿**圆弧方向**缓慢移动 → 高亮**平滑切换**到相邻按钮。
3. 在同一角度沿**半径向内 / 向外**移动（不进入人物保护区）→ 高亮**保持**同一个按钮。
4. 把鼠标**移出扇形**（仍在窗口内，如远端标题 / 角落装饰）→ 高亮消失，
   **扇叶与标题不回落到第一项**（日志：`hoveredIndex=null`、`visualActiveIndex=-1`，`anchorIndex` 不变）。
5. 在**扇形内但不在环带上**的位置**静止单击** → 执行该角度对应按钮（不再"关菜单但没执行"）。
6. **四个角 + 上中 / 中中**各测一次（几何不得回归，C1.1.1 六种布局诊断应保持原表值）。
7. 进子菜单重复 1–5（层级切换后按新几何重算）。
8. `Esc` / 再次单击桌宠 → 正常关闭。

日志对账（验收硬指标）：**移出扇形后不得再出现 `hoveredIndex=0`**，
除非鼠标真的落在第 1 个按钮上。

---

## 7. Release 构建（**只构建一次**）

```
C:\Users\Administrator\WorkBuddy\DesktopPet\petlife\build_incrC113\windows\x64\runner\Release\petlife.exe
```

| 产物 | 值 |
| --- | --- |
| `petlife.exe` | `442BC34E7F791BCDFD91EE600AF68631919A13759C450BC4C935E4EE9827CA2A`（137,216 B） |
| `data\app.so` | `22F2799EB438BA517B5351B8906F8A2BC5A2C54F87E0ABB04C6F740190C8C1AA`（9,356,168 B） |

- 构建命令：`flutter config --build-dir=build_incrC113` → `flutter build windows --release` → **exit 0**（66.9s），
  随后已把 `build-dir` **还原为 `build`**。
- 产物清单见 `docs/50-evidence/c113-release-artifacts.txt`。
- 本轮**未**改动 `pubspec` / 原生插件，仅 Dart 源码 + 测试。

---

## 8. 交付证据

- `docs/50-evidence/c113-diagnostic.txt` — 根因诊断日志（含回落链）
- `docs/50-evidence/c113-analyze.txt` — analyze 输出
- `docs/50-evidence/c113-tests-directed.txt` — 定向回归（+162）
- `docs/50-evidence/c113-tests-full.txt` — 全量回归（+1423 / 0 failed）
- `docs/50-evidence/c113-build.txt` — Release 构建输出
- `docs/50-evidence/c113-release-artifacts.txt` — EXE 路径 / 尺寸 / SHA-256

---

## 9. 边界（§13，逐条）

- ✅ 只改鼠标输入模式 / 统一 HitTest / 扇形角度映射 / 高亮派生 / 日志 / 测试。
- ✅ 不改视觉尺寸、不改四角位置、不改 alpha 上下界、不改画布 / Region、不改动画时长。
- ✅ 不改业务菜单内容。
- ✅ 不碰 Android、**不进入 C2**。
- ✅ 扇叶半径上限用正式几何 `max(bladeLengthPx, rimOuterPx)`，**未**改动几何本身。
- ✅ 无定时器、不延长动画（`openMs` 保持 300）。

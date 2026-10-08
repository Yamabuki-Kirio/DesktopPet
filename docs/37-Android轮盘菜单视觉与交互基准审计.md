# 37 - Android 轮盘菜单视觉与交互基准审计

> 审计性质：**只读**。本次未修改 `android/` 下任何文件。
> 审计目的：把当前 Android 上**已验收**的正式 P3P 轮盘菜单，逐项提取为 Windows 版本的
> **唯一视觉/交互基准**。增量 B 的 Windows 实现必须以本文档为准，而不是重新设计。
>
> 审计时间：2026-10-05。审计对象：`android/app/src/main/kotlin/asia/akechi/petlife/overlay/`。

---

## 0. 结论摘要（先看这段）

Android 正式轮盘不是一个"圆形菜单控件"，而是**一套参数化几何 + 一个七态状态机 + 一个纯逻辑手势控制器 + 一个 Canvas 渲染器**的组合。它有三个必须原样迁移的特征：

1. **扇形，不是圆盘**。菜单背景只在"展开方向"的一整片扇形内绘制（内缘贴近轮盘中心、外缘到刀刃），角度范围 = 按钮轨道带范围。**从不画完整圆环、也从不画整圆**。
2. **缺口绑桌宠，不是挖洞**。中央缺口是一个**椭圆**，中心**恒等于桌宠视觉锚点**（不是轮盘中心）。轮盘中心可以比桌宠锚点偏一点，缺口永远压在桌宠上。缺口由桌宠**可见尺寸**决定，**不乘应急缩放**。
3. **人物层盖住菜单层**。菜单与桌宠在**同一个窗口**里分层（菜单层在下、人物层在上），人物透明处自然透出菜单底色。因此渲染器里**没有"挖洞"代码**，也不需要避开人物。

Windows 侧的既有成果（固定画布、Window Region、RegionCoordinator、WheelInteractionState、右键旧菜单、面板事务）**全部保留**，本次只把"六色块测试菜单"替换为按本文档复刻的正式轮盘。

---

## 1. 源文件清单与职责

| 文件 | 职责 | 迁移去向（Windows） |
| --- | --- | --- |
| `WheelMenuGeometry.kt` | 纯函数几何：信封 / 固有布局 / 放置 / 层级内几何 / 槽位角度映射 / 文字安全带 | `lib/menu/wheel_geometry.dart`（重写 `wheel_layout_engine.dart`） |
| `WheelMenuTheme.kt` | 纯函数主题：预设、派生、对比度 | `lib/menu/wheel_theme.dart`（对齐色值） |
| `WheelMenuModel.kt` | 目录 + 条目 + 菜单栈 + canonical 动作 id | `lib/menu/menu_contract.dart`（已一致，仅核对） |
| `WheelMenuState.kt` | 七态状态机（层级 / 选中 / 方向） | `lib/menu/wheel_ui_state.dart`（核对） |
| `WheelMenuGesture.kt` | 纯逻辑手势：分区 / 角度判定 / 滞回 / 松手确认 | `lib/menu/wheel_selection_controller.dart`（重写） |
| `WheelMenuAnimator.kt` | 缓动 + 时间线 + 帧推导（纯函数） | `lib/menu/wheel_animator.dart`（新增） |
| `WheelMenuRenderer.kt` | Canvas 逐帧绘制（绘制顺序 + 各层参数） | `lib/ui/desktop/wheel_menu_view.dart`（重写绘制） |
| `WheelMenuIcons.kt` | 39 个图标的归一化几何 | `lib/ui/desktop/wheel_icons.dart`（新增） |
| `WheelMenuView.kt` | View 装配：触摸 → 手势 → 状态 → 绘制；ticker | `lib/ui/desktop/wheel_menu_view.dart`（Widget 装配） |
| `MenuFeedback.kt` | 反馈条纯逻辑（位置 + 陈旧结果判定） | 诊断/反馈 chip（增量 B 可降级为只读诊断） |
| `WheelMenuActionDispatcher.kt` / `MenuActions.kt` | 动作分派（navigation / native / dartRequest / info） | **增量 C** 才接，B 阶段只发"未接入"反馈 |

---

## 2. 关键类与关键契约

```
WheelExpandDirection   right(sign=+1) / left(sign=-1)
WheelVerticalMode      center(0°) / topEdge(+26°) / bottomEdge(-26°)
WheelMenuLayoutSettings  用户设置（scale / distance / buttonScale / compact）
WheelMenuSpec            密度换算后的尺寸参数（dp → px）
WheelMenuEnvelope        打开时一次性确定的信封（窗口 + 中心 + 锚点 + 缺口）
WheelMenuLayout          某一层级的实际几何（窗口内相对坐标 + 槽位表）
WheelIntrinsicLayout     固有几何（与位置无关）
WheelMenuTheme           主题（7 色 + gradientEnabled + animationStyle）
WheelMenuEntry           条目（id / action / icon / labelZh / titleEn / description / isBack）
WheelMenuLevel           层级（id / titleEn / titleZh / entries）
WheelMenuCatalog         目录（根 6 项 + 5 子菜单 + 固定返回）
WheelMenuStack           菜单栈（push / pop / popToRoot / clear）
WheelMenuStateMachine    七态状态机
WheelMenuGestureController  手势控制器（Owner 六态）
WheelMenuAnimationRun / WheelAnimationFrame / WheelAnimationClock / WheelAnimationTimeline
WheelMenuRenderer / WheelRenderParams / WheelTextLayout / WheelTextSlots
MenuFeedbackPolicy / MenuFeedbackState / FeedbackKind
```

### 2.1 canonical 动作 id（跨端唯一契约，共 17 个）

`pet_auto` / `appearance_prev` / `appearance_next` / `appearance_auto` / `appearance_fav` /
`appearance_mapping` / `appearance_library` / `records_today` / `records_stats` /
`records_cloud` / `records_track` / `records_sync` / `records_sync_state` /
`settings_theme` / `settings_wheel_size` / `settings_button_size` / `settings_open`

与 Windows 侧 `lib/menu/menu_contract.dart` 的 `MenuActionIds.canonical` **已一致**（增量 A 已核对）。**界面文案与 enum 名永远不是协议 id。**

### 2.2 动作路由（B 阶段只登记，不执行）

- `navigation`：`openPetMenu` / `openAppearanceMenu` / `openRecordsMenu` / `openToolsMenu` / `openSettingsMenu` / `back` / `closeMenu`
- `native`：`hideOverlay` / `resetPetPosition` / `changePetSizeDown` / `changePetSizeUp` / `resetPetSize` / `openPetLife`
- `dartRequest`：上表 17 个 canonical id
- `info`：`showInfo`（只读信息项，点击无副作用）

---

## 3. 菜单目录（冻结，顺序即视觉顺序）

层级 id：`root` / `pet` / `appearance` / `records` / `tools` / `settings`。
`maxItems = 7`（形象层 6 项 + 返回）。所有 `BACK` 条目的 id 固定为 `back`、`isBack = true`，**永远排在最后一个槽位**（视觉最下方）。

| 层级 | titleEn / titleZh | 条目（id · icon · labelZh · titleEn · description） |
| --- | --- | --- |
| root | `PETLIFE` / 桌宠 | `root_pet`·pet·桌宠·`PET`·`AUTO MODE`；`root_appearance`·appearance·形象·`APPEARANCE`·角色与素材；`root_records`·record·记录·`RECORD`·今日使用时长；`root_tools`·tools·工具·`TOOLS`·专注与快捷入口；`root_settings`·gear·设置·`SYSTEM`·主题与服务；`root_hide`·hide·隐藏·`HIDE`·隐藏桌宠（服务继续运行） |
| pet | `PET` / 桌宠 | 缩小·resize；放大·resize；恢复默认·refresh；自动状态·cycle；当前状态·state（info）；重置位置·home；返回 |
| appearance | `APPEARANCE` / 形象 | 上一张·prev；下一张·next；自动形象·shuffle；收藏·heart；编辑状态素材·mapping；打开素材库·library；返回 |
| records | `RECORD` / 记录 | 今日时长·clock；当前应用·app（info）；本机统计·chart；云端记录·cloud；返回 |
| tools | `TOOLS` / 工具 | 暂停采集·pause；立即同步·sync；同步状态·cloud；打开 PetLife·star；返回 |
| settings | `SYSTEM` / 设置 | 轮盘主题·palette；轮盘大小·ruler；按钮大小·resize；完整设置·gear；返回 |

根菜单六项顺序**必须是**：桌宠 → 形象 → 记录 → 工具 → 设置 → 隐藏。

> ⚠️ `maxLabelChars` 是**代码推导值**，不是常量：取全部 `labelZh.length` 的最大值。
> 当前由 `"打开 PetLife"` 决定 → **10**。它参与菜单窗口包围盒计算（见 §6.4），
> 因此 **Windows 侧的 labelZh 必须与上表逐字一致**，否则窗口尺寸会与 Android 不同。

---

## 4. 几何常量（逐字，不得改动）

### 4.1 用户设置 `WheelMenuLayoutSettings`

| 参数 | 值 |
| --- | --- |
| 轮盘大小 | MIN `0.50` / MAX `2.50` / STEP `0.10` / DEFAULT `1.00` |
| 菜单偏移 `menuDistance` | MIN `0.05` / MAX `0.30` / DEFAULT `0.16` |
| 按钮大小 `buttonVisualScale` | MIN `0.50` / MAX `2.50` / STEP `0.10` / DEFAULT `1.30` |
| 按钮触摸直径下界 | `48` dp |

`normalized()`：scale / distance / buttonScale 各自夹取；`quantizeScale` / `quantizeButtonScale` 吸附到 10% 步进。

### 4.2 尺寸参数 `WheelMenuSpec`（dp → px，乘 density）

`BUTTON_DIAMETER_DP = 44`、`BUTTON_DIAMETER_COMPACT_DP = 40`、`BUTTON_GAP_DP = 6`、
`BAND_PADDING_DP = 8`、`RIM_LOBE_DP = 7`、`OUTLINE_DP = 2.2`、
`MIN_OUTLINE_DP = 1.2`、`MAX_OUTLINE_DP = 4.5`、`MIN_OUTLINE_SCALE = 0.72`。

- 按钮可见直径：`buttonDiameterFor(count, scale) = (count >= 7 ? 40 : 44) * scale.clamp(0.20, 4.0)`，`scale` 来自 **本层的有效缩放 × buttonVisualScale**。**按钮大小的唯一落点就是这里**。
- 描边宽度：`outlineWidthFor(base, scaled) = (base * max(scaled, 0.72)).clamp(1.2 * d, 4.5 * d)`。

### 4.3 几何 `WheelMenuGeometry`

| 常量 | 值 | 用途 |
| --- | --- | --- |
| `MIN_STEP_DEG` / `MAX_STEP_DEG` | `16` / `30` | 相邻按钮角间隔上下界 |
| `MAX_HALF_SPAN_DEG` / `COMPACT_HALF_SPAN_DEG` | `68` / `50` | 扇形半张角 |
| `MIN_HALF_SPAN_DEG` | `38` | 紧凑模式半张角下界 |
| `BLADE_HALF_SWEEP_DEG` | `30` | 高亮刀刃（扇区）半张角 |
| `BLADE_EXTENT_RATIO` | `0.42` | 刀刃伸出量相对环带半径 |
| `BLADE_EXTENT_MIN_DP` / `MAX_DP` | `40` / `88` | 刀刃伸出量上下界（dp） |
| `MIN_RADIUS_DP` | `62` | 环带半径绝对下界 |
| `HOLE_WIDTH_RATIO` / `HOLE_HEIGHT_RATIO` | `1.05` / `1.05` | 缺口相对桌宠可见尺寸 |
| `NOTCH_PADDING_DP` | `10` | 缺口额外边距 |
| `NOTCH_MAX_INNER_DIAMETER_RATIO` | `0.88` | 缺口 ≤ 环带内径的 88%（防"粗甜甜圈"回归） |
| `HOLE_MARGIN_DP`（private） | `4` | 缺口与按钮净空 |
| `SAFETY_PADDING_DP` | `10` | 窗口额外安全边距 |
| `MIN_ACTUAL_SCALE` | `0.60` | 实际缩放下限 |
| `EDGE_FAN_BIAS_DEG`（private） | `26` | 靠边时扇形偏转 |
| `COMPACT_BUTTON_SHRINK`（private） | `0.92` | 紧凑模式按钮收缩 |
| 垂直滞回 `VERTICAL_HYSTERESIS` | `0.06` | 相对安全区高度 |
| 方向滞回 `DIRECTION_HYSTERESIS` | `0.08` | 相对安全区宽度 |
| 窗口建议占比（普通 / 紧凑） | 宽 `0.65`/`0.55`，高 `0.70`/`0.60` | 超出即紧凑模式 |
| 桌宠可见边界兜底比例 | `0.86` | 素材几乎全透明时 |

### 4.4 文字 `WheelTextLayout`

| 常量 | 值 |
| --- | --- |
| `TITLE_RADIUS_RATIO` / `CHIP_RADIUS_RATIO` / `INFO_RADIUS_RATIO` | `0.30` / `0.72` / `0.93` |
| `TITLE_SIZE_RATIO` | `0.30` |
| `CHORD_SAFETY` | `0.78` |
| `TEXT_BAND_GAP_DP` | `4` |
| `MIN_CHIP_SP` | `16` |

---

## 5. 几何求解流程（原样复刻）

### 5.1 两段式 API

- `computeEnvelope(bounds, petWindowRect, content, maxItemCount, spec, settings, prevDirection, prevVertical, lockMode)` —— **打开时调用一次**，用 `maxItemCount = 7` 算：方向、垂直模式、桌宠锚点、缺口、窗口矩形、环带半径、按钮直径、实际缩放。打开期间窗口不变。
- `layoutFor(envelope, level, spec)` —— **每次换层级 / 切换选中**时在同一信封内重算内部几何，**绝不改窗口**。

### 5.2 方向 `decideDirection`

锁定时直接返回上次；否则比较桌宠中心左右剩余空间，取较大侧；有历史值时套 8% 宽度死区滞回。

### 5.3 垂直模式 `decideVerticalMode`

`above < below * 0.55 → topEdge(+26°)`；`below < above * 0.55 → bottomEdge(-26°)`；否则 `center`。六分之一（6%）高度死区滞回。**注意：靠边时只改扇形朝向（fanBiasDeg）+ 降实际缩放，绝不平移轮盘中心** —— 平移会让缺口与桌宠错位。

### 5.4 桌宠可见矩形 `petVisibleRect`

按素材内容边界裁掉透明留白；若裁出的矩形相对窗口异常小（< 86%），回退到窗口的 86% 居中矩形。缺口绑在**这个矩形**的中心上。

### 5.5 固有几何 `intrinsicLayout`

输入只有：itemCount、spec、settings、桌宠**可见宽高**。**不含桌宠坐标 / 剩余空间 / 离边距离。**

```
compact      = settings.compactMode
halfSpan     = halfSpanFor(count, compact)           // 见 5.6
step         = stepDegFor(count, halfSpan)           // 见 5.6
effScale     = preferredScale * (compact ? 0.92 : 1)
buttonDia    = buttonDiameterFor(count, effScale * buttonVisualScale)
buttonR      = buttonDia / 2
padding      = 10dp
notchRxRaw   = petVisibleW * 1.05 / 2 + padding      // 未夹取，缺口必须始终盖住桌宠
notchRyRaw   = petVisibleH * 1.05 / 2 + padding
minRadiusForNotch = max(notchRxRaw, notchRyRaw) / 0.88 + buttonR
spacing      = spacingRadiusPx(count, step, buttonDia, spec)   // 见 5.6
margin       = 4dp
clearance    = hypot(petW/2, petH/2) + petW * menuDistance + buttonR + margin
ringRadius   = max(max(spacing, minRadiusForNotch), max(clearance, 62dp))
bandOuter    = ringRadius + buttonR + 8dp
rimOuter     = bandOuter + 7dp
bladeExtent  = (0.42 * ringRadius).clamp(40dp, 88dp)
bladeLength  = rimOuter + bladeExtent * preferredScale.clamp(0.50, 2.50)
```

包围盒半宽/半高（**"放不放得下"只由它决定**，必须是扇形真实包络而不是正方形）：

```
reachDeg = halfSpan + 30 + |26|
outward  = max(bladeLength, rimOuter)
inwardFactor = reachDeg > 90 ? -cos(min(180, reachDeg)°) : 0
halfW = (outward + outward*inwardFactor)/2 + 10dp
halfH = outward * sin(min(90, reachDeg)°) + 10dp
```

### 5.6 角度公式

```
halfSpanFor(count, compact):
  base = compact ? 50 : 68
  count <= 1 → 0
  needed = 16 * (count-1) / 2
  max(base, min(needed, 68))

stepDegFor(count, halfSpan):
  count <= 1 → 0
  (halfSpan * 2 / (count-1)).clamp(16, 30)

spacingRadiusPx(count, step, buttonDia, spec):
  count<=1 || step<=0 → 0
  chordUnit = 2 * sin(step/2)
  (buttonDia + 6dp) / chordUnit

absoluteAngle(direction, offsetDeg):            // 镜像取反，不是加
  normalize(baseAngle + sign * offsetDeg)       // baseAngle: right=0, left=180

rawIndexAt(layout, absoluteAngleDeg):           // 连续槽位下标
  count<=1 || step<=0 → 0
  offset = normalizeAngle(abs - baseAngle) * sign
  (offset - fanBiasDeg) / step + (count-1)/2

normalizeAngle(deg): → (-180, 180]
```

> 镜像必须用 `180° − offset`（即 `sign * offset`），否则左展开时"下标越大越靠下"会翻转，固定返回键会跑到视觉最上方。

### 5.7 设备级应急缩放 `deviceEmergencyScale`

`min(1, min(bounds.w / needW, bounds.h / needH)).clamp(0.60, 1)`。
**用户把轮盘调大（> 1.00）时一律不缩回**（`deviceScale = 1`），放不下就裁外围装饰并标记 `degraded`。

### 5.8 层级内几何 `layoutFor`

```
radius   = envelope.maxRingRadiusPx
button   = envelope.buttonDiameterPx
bandOuter= radius + button/2 + 8dp
rimOuter = bandOuter + 7dp
bladeExtent = (0.42 * radius).clamp(40dp, 88dp)
bladeLength = rimOuter + bladeExtent * actualScale.clamp(0.6, 1.2)

cx = envelope.centerX - window.left
cy = envelope.centerY - window.top
notchCx = envelope.petAnchorX - window.left      // 缺口中心 = 桌宠锚点（窗口坐标）
notchCy = envelope.petAnchorY - window.top
half = (count-1)/2
slot[i]: offsetAngle = (i-half)*step
         absolute    = absoluteAngle(direction, offsetAngle + fanBiasDeg)
         center      = (cx + radius*cos, cy + radius*sin)
outlineWidth = outlineWidthFor(spec.outlinePx, actualScale)
buttonTouchDiameter = max(button, 48dp)
rimOuter = bandOuter + rimLobePx
```

---

## 6. 缺口（notch）规则 —— Windows 最容易做错的一环

1. 缺口是**椭圆**，半径 `holeRx/holeRy`，由**桌宠可见尺寸**决定：`可见尺寸 * 1.05 / 2 + 10dp`。
2. 缺口中心**恒等于桌宠视觉锚点**（窗口内坐标），**不是轮盘中心**。
3. 缺口**不乘设备级应急缩放** —— 桌宠不会因为屏幕小就变小。
4. 环带反过来必须容得下缺口：`ringRadius >= max(notchRx, notchRy)/0.88 + buttonR`，不够时**扩大轮盘**，而不是把缺口撑到按钮边缘。
5. 缺口**永远不是"从圆形背景里挖掉的洞"**：渲染器不挖洞，人物由同窗口上层 View 盖住。

---

## 7. 主题与颜色（P3P 逐字一致）

### 7.1 P3P 粉（默认，`themeId = "p3p-pink"`）

| 语义 | 值 |
| --- | --- |
| `primary` | `0xFFF24D96` |
| `secondary` | `0xFFFF8ABA` |
| `background` | `0xFFFFD8E9` |
| `highlight` | `0xFFFFD42A` |
| `outline` | `0xFF111111` |
| `text` | `0xFFFFFFFF` |
| `disabled` | `0xFF8E7180` |

### 7.2 其它预设（只钉主色，其余派生）

`blue 0xFF2F7CF6`、`red 0xFFE23B3B`、`purple 0xFF8B4DE0`、`green 0xFF1FA463`、`custom`（用户主色）。

派生规则（`custom(primary)`，`derivedPreset` 只是换掉 themeId/displayName）：

```
secondary  = lighten(primary, 0.42)        // mix(primary, WHITE, 0.42)
background = mix(primary, WHITE, 0.84)
highlight  = 0xFFFFD42A                     // 固定 P3P 黄，所有主题共用
outline    = 0xFF111111                     // 固定近黑
text       = autoTextColor(primary)         // 白字对比度 ≥ 3.0 就用白，否则纯黑
disabled   = mix(primary, 0xFF808080, 0.55)
```

`presets` 展示顺序：p3p-pink → blue → red → purple → green。`default()` = p3p-pink。
`revision` 用于防止旧配置覆盖新配置。`fromWire(themeId, customPrimary, revision)` 解析持久化值。

### 7.3 底色扇面 `baseFanColor`（视觉收尾的关键）

```
baseFanColor(theme) = withAlpha(mix(theme.secondary, theme.background, 0.40), 108)
```

即 `secondary` 向 `background` 混 40%，再压 **alpha=108**。粉色主题得到"深玫瑰"，绿/蓝主题各自得到同色系底色。**它是"打开方向那一整片扇形"的填充色**，压在刀刃与按钮轨道带下面。

### 7.4 颜色工具

`mix` / `lighten` / `darken` / `opaque` / `withAlpha` / `relativeLuminance` / `contrastRatio` /
`isLegible`（文字对主色对比度 ≥ 3.0）/ `parseHex` / `toHex` / `channelDistance`。
`ANIMATION_STANDARD = "standard"` / `ANIMATION_CALM = "calm"`。

---

## 8. 绘制顺序与各层实际参数（`WheelMenuRenderer`）

### 8.1 变换与顺序

```
if (openProgress <= 0.004) return
canvas.scale(frame.scale, frame.scale, centerX, centerY)
canvas.rotate(frame.rotationDeg, centerX, centerY)
```

绘制顺序（**严格**）：

```
1. verifyFan        （仅架构验证期，默认关闭；粉色 160° 扇区，alpha 200）
2. baseFan          （菜单真正底色：secondary→background 0.40，alpha 108）
3. blade            （高亮扇区"刀刃"，线性渐变 primary→secondary + 黑描边 ×1.35）
4. band             （按钮轨道带：background 填充 + outline 描边）
5. rimDecoration    （外缘齿轮凸起 + 黄色强调弧）
6. texts            （英文大标题 + 中文 chip + 说明）
7. buttons          （圆按钮 + 图标）
8. buttonLabels     （仅根菜单，径向朝外）
9. debug            （诊断边界，默认关闭）
```

### 8.2 刀刃 `drawBlade`

```
angle      = absoluteAngle(direction, (selection - (count-1)/2) * step + fanBiasDeg)
halfSweep  = 30
innerRadius= notchRx * 0.72
outerRadius= bladeLength
路径内缘：从起点沿内弧走到终点，中间用一段"鼓包"（bump = innerRadius * 1.18）表达缺口咬合
路径外缘：圆角 corner = (outer - inner) * 0.28，arcTo 扫 -(halfSweep*2)*0.94
填充：若 gradientEnabled → LinearGradient(内缘点 → 外缘点, primary → secondary, CLAMP)
描边：outline，宽度 = outlineWidthPx * 1.35
```

### 8.3 轨道带 `drawBand`

```
inner = max(1, ringRadius - buttonDiameter * 0.60)
outer = bandOuter
start = absoluteAngle(direction, -fanHalfSpan + fanBiasDeg)
sweep = direction.sign * fanHalfSpan * 2
填充 background（无渐变）；描边 outline，宽度 = outlineWidthPx
```

扇形带几何 `buildFanBand(inner, outer)` 被 baseFan / band 复用；**baseFan 的 inner = ringRadius * 0.30、outer = max(bladeLength, rimOuter)**。

### 8.4 外缘装饰 `drawRimDecoration`

```
count = compact ? max(2, itemCount) : max(2, itemCount*2 - 1)
每个凸起：半径 = rimOuter - rimLobe*0.35，圆半径 = rimLobe*0.72
         填充 background + 描边 outline（宽度 outlineWidthPx * 0.85）
强调弧：半径 = bladeLength * 0.86，颜色 highlight，宽度 outlineWidthPx * 2.2，CAP.ROUND
        sweep 方向 = right ? +1 : -1
        起始 = selectionAngle - bladeHalfSweep*0.62*dir，扫 bladeHalfSweep*1.24*dir
```

### 8.5 按钮 `drawButtons`

```
每个 slot：
  progress = frame.buttonProgress[i]；<= 0.01 跳过
  isSelected = (i == activeIndex)；pressed = (frame.pressIndex == i)
  scale = (isSelected ? 1.14 : 1) * (1 + (progress-1)) * (1 - pressAmount*0.12)
  diameter = buttonDiameterPx * scale
  圆心从槽位向轮盘中心插值：(1 - progress)
  选中项：先画白色底座圆，半径 diameter * 0.62，颜色 text，alpha * 0.95
  按钮圆：填充 (enabled ? primary : disabled)，半径 diameter/2
          描边 outline，宽度 outlineWidthPx
  图标：size = diameter * 0.58，颜色 enabled ? text : outline
```

### 8.6 文字

**根菜单按钮标签**（`showButtonLabels = (levelId == "root")`）：

```
若 entry.isBack 则跳过
size = max(buttonDiameter * 0.30, 10sp*d)；BOLD；letterSpacing 0
位置：沿槽位径向朝外 radius = buttonDiameter/2 + rimLobe*0.5 + size*0.95
baseline = ly + size*0.34
先描边（宽度 outlineWidthPx*1.1，色 outline）再填充（色 text，alpha * progress）
镜像时位置翻转，但文字不水平翻转
```

**主扇区三层文字**（安全带 `[ringRadius + buttonDiameter/2 + 4dp, bladeLength]`）：

```
slot 由 WheelTextLayout.compute 给出：
  bandStart = ringRadius + buttonDiameter*0.5 + 4dp
  bandEnd   = max(bladeLength, bandStart+1)
  titleRadius = bandStart + (bandEnd-bandStart)*0.30
  chipRadius  = bandStart + (bandEnd-bandStart)*0.72
  infoRadius  = bandStart + (bandEnd-bandStart)*0.93
  titleSize   = max(band*0.30, 13sp*d)
  chipSize    = max(buttonDiameter*0.42, 16sp*d)
  infoSize    = max(buttonDiameter*0.27, 11sp*d)
  maxWidth    = 2 * radius * sin(bladeHalfSweep * 0.78)
倾斜角 tilt = clamp(sign * (-10 + offsetAngle*0.30), -8, 8)；chip 倾斜 clamp 至 ±3
```

- **有 titleEn**：① 英文大标题（先黑描边 outlineWidthPx*1.35 → 再填充 text，旋转 tilt，letterSpacing 0.06）；② 中文名称 chip（近白底圆角矩形 + 黑描边 + 深色字），两处半径不同，绝不重叠。
- **无 titleEn**：只画一次中文 chip（不再额外画一遍，避免重叠）。
- **说明 / 实时信息**：NORMAL 字体，色 outline alpha*0.88，半径 infoRadius。
- `fitText`：先按 0.92 倍递减字号到最小值，仍放不下则逐字省略加 `…`（至少保留 1 字）。

`drawChip`：宽 `measureText(text)/2 + size*0.55`，高 `size*0.86`，圆角 `halfH*0.5`，白底 alpha*0.94，黑描边 outlineWidthPx*0.8，深色字。文本宽度有缓存。

`TEXT_SKEW = -0.10`（文字轻微斜体，仅主标题）。

### 8.7 其余渲染常量

`SELECTED_SCALE = 1.14`、`ICON_RATIO = 0.58`、`VERIFY_FAN_SPAN_DEG = 160`、
`VERIFY_FAN_INNER_RATIO = 0.22`、`VERIFY_FAN_ALPHA = 200`、`BASE_FAN_INNER_RATIO = 0.30`、
`LABEL_SIZE_RATIO = 0.30`、`SUBTITLE_SIZE_RATIO = 0.42`、`INFO_SIZE_RATIO = 0.27`、
`TEXT_BASE_TILT_DEG = -10`、`TEXT_ARC_FOLLOW = 0.30`、`MAX_TEXT_TILT_DEG = 8`、
`MAX_CHIP_TILT_DEG = 3`、`MIN_TITLE_SP = 13`、`MIN_SUBTITLE_SP = 16`、`MIN_INFO_SP = 11`、`MIN_LABEL_SP = 10`。

> 绘制纪律：所有 Paint / Path / RectF / Shader **复用**，`onDraw` 内不分配对象、不查数据、不解码图片；文字宽度只在标题变化时测一次。

---

## 9. 图标系统（`WheelMenuIcons`，原创几何，39 个）

全部用 `Path` 现场绘制，在归一化坐标 `[-1, 1]²` 内，`STROKE = 0.16`，`CAP.ROUND` / `JOIN.ROUND`。
图标**保持直立**（不跟随圆周倒转），旋转由调用方决定。

可用 icon 枚举（39）：`pet, appearance, record, tools, gear, hide, cycle, state, hand, refresh, pin, resize, home, back, prev, next, shuffle, heart, character, mapping, library, clock, timer, app, pause, sync, cloud, chart, bolt, star, edit, palette, opacity, ruler, vibrate, sound, info, restart, power`。

> Windows 侧若用 Material 图标映射，**形状必然与 Android 不同**。要"一眼看出是同一个轮盘"，建议按 Android 的归一化几何用 Path 重画（至少：pet / sparkle / bars / wrench / gear / eyeOff / resize / refresh / home / back / prev / next / shuffle / heart / mapping / library / clock / app / pause / sync / cloud / chart / star / palette / ruler）。若为控制成本先用 Material 图标，必须在验收单里显式标注"图标形状与 Android 有差异"。

---

## 10. 手势（`WheelMenuGestureController`，纯逻辑）

### 10.1 常量

`HYSTERESIS_DEG = 7`、`LEAVE_TOLERANCE_MS = 130`、`TAP_SLOP_DP = 8`、`SWIPE_SLOP_DP = 12`（后两者乘 density）。

### 10.2 分区 `zoneAt`

```
insideNotch(layout, x, y) → center          // 椭圆判定：((x-ncx)/rx)² + ((y-ncy)/ry)² <= 1
dist(center, point) <= rimOuter → ring
否则 → outside
```

### 10.3 槽位命中 `indexAt`

```
count <= 0 → null；count == 1 → 0；step <= 0 → null
angle = atan2(y - centerY, x - centerX)  (度)
raw   = rawIndexAt(layout, angle)
若 previous 合法：hysteresisUnits = min(7/step, 0.45)
                 若 |raw - previous| < 0.5 + hysteresisUnits → 保持 previous
返回 round(raw).clamp(0, count-1)
```

**关键**：判定用**角度**（`atan2`），不是水平位移 —— 只用 x 位移在轮盘下半圈会判反。
**第一版不做惯性旋转**：甩动最多按最后落点确认一项。

### 10.4 Owner 六态与转移

`none / pressing / swiping / pendingOutside / petDrag / cancelled`

| 事件 | 行为 |
| --- | --- |
| `onDown` 多指 | owner = cancelled，返回 `cancel` |
| `onDown` ring | owner = pressing，highlight = indexAt(..., selectedIndex)，返回 `press`(index) |
| `onDown` center | owner = petDrag，返回 `none`（后续拖动转发给桌宠） |
| `onDown` outside | owner = pendingOutside，返回 `none` |
| `onMove` pressing | 位移 > swipeSlop → owner = swiping，返回 `swipeStart`(index) |
| `onMove` pendingOutside | 位移 > swipeSlop **且**当前在 ring → swiping + `swipeStart` |
| `onMove` swiping | 不在 ring：首次离开记时，≤130ms 保持高亮；超过 → `cancel`。在 ring：next = indexAt(prev=highlight)；变了 → `highlight`(next, haptic=true) |
| `onMove` petDrag | 位移 > swipeSlop → 首次 `petDragStart`，之后 `petDragMove` |
| `onUp` swiping | 有 highlight 且仍在 ring → `confirm`(index)；否则 `cancel` |
| `onUp` pressing | 有 highlight 且位移 ≤ tapSlop → `confirm`(index)（**点击按钮**）；否则 `cancel` |
| `onUp` pendingOutside | 位移 ≤ tapSlop → `outsideTap`（关闭菜单） |
| `onUp` petDrag | 拖过 → `petDragEnd`；没拖过 → `outsideTap`（点桌宠关闭菜单） |
| `onUp` 多指 | `cancel` |
| `onCancel` | owner 非 none → `cancel` |

**三条硬规则**：① 角度判定；② 槽位滞回 7°；③ **松手才确认**（划过即执行会让"隐藏/停止服务"被误触发）。

### 10.5 触摸期间的输入屏蔽（`WheelMenuView.onTouchEvent`）

- 正在转发桌宠拖动 → 先无条件收敛终止事件（防"菜单看不见却继续吞触摸"）。
- `interactive == false` → 只吞事件，不产生任何菜单动作。
- `phase == opening || closing` → 不接受输入（防"还没张开就被点掉"）。

---

## 11. 状态机（`WheelMenuPhase` 七态）

`closed / opening / open / switching / enteringLayer / exitingLayer / closing`

| 方法 | 前置 | 效果 |
| --- | --- | --- |
| `open(direction)` | 仅 closed / closing | 方向锁定；栈 clear + open(root)；selected=0；phase=opening |
| `close()` | 非 closed | 栈 clear；selected=0；phase=closed |
| `markOpened()` | opening | → open |
| `markClosed()` | 任意 | → closed |
| `beginSwitch(i)` | open，i 合法且 ≠ selected | → switching |
| `finishSwitch(i)` | — | selected=i；switching → open |
| `enterLayer(id)` | open / switching，push 成功 | selected=0；→ enteringLayer |
| `exitLayer()` | open / switching，pop 成功 | selected=0；→ exitingLayer |
| `finishLayerTransition()` | entering/exiting | → open |
| `beginClosing()` | 非 closed | → closing |
| `setPreview(i?)` | — | 临时高亮（夹取，null = 取消区） |
| `confirmSelection()` | — | preview → selected，返回被选条目 |
| `settleAfterInterruption()` | — | opening/switching/entering/exiting → open；closing → closed；清 preview |

派生量：`activeIndex = previewIndex ?: selectedIndex`；`canGoBack = depth > 1`；`phase.animating`；`phase.occupiesWindow`。

---

## 12. 动画（`WheelMenuAnimator`，纯函数）

### 12.1 缓动（CubicBezier，牛顿迭代 8 次 + 二分 18 次，epsilon 1e-4）

| 名称 | 控制点 | 用途 |
| --- | --- | --- |
| `OPEN` | (0.16, 1.0, 0.30, 1.0) | 展开 |
| `SWITCH` | (0.22, 0.85, 0.30, 1.0) | 切换 / 换层 |
| `CLOSE` | (0.55, 0.0, 0.85, 0.35) | 关闭 |
| `POP` | (0.18, 1.36, 0.36, 1.0) | 按钮弹出轻微回弹 |

### 12.2 时间线（ms）

`OPEN 300`、`CLOSE 180`、`SELECT 220`、`ENTER_LAYER 300`、`EXIT_LAYER 230`、`PRESS 70`、`BUTTON_STAGGER 25`。
展开分段：`BODY 0→120`、`BUTTON 50→230`、`TITLE 100→300`；关闭整体同收，`CLOSE_BUTTON_TAIL 40`。

### 12.3 帧推导（`WheelAnimationClock.frame`）

```
raw = clamp((now - startedAt) / duration, 0, 1)
eased = kind==open ? OPEN(raw) : kind==close ? CLOSE(raw) : SWITCH(raw)

openProgress = open ? OPEN(raw) : close ? 1-CLOSE(raw) : 1
selectionPosition = (open/close/enterLayer/exitLayer) ? toSelection
                    : fromSelection + (toSelection-fromSelection) * eased
layerProgress = enterLayer ? eased : exitLayer ? 1-eased : 1
titleProgress = selectionSwitch/enterLayer ? eased : exitLayer ? 1-eased : 1
buttonProgress[i] :
   open        → buttonProgress(elapsed, i, count)      // 错峰 POP
   close       → 1 - CLOSE(clamp((elapsed + 0)/total))
   enterLayer  → staggeredPop(elapsed, i, count, delay=80, total=300)
   exitLayer   → staggeredPop(elapsed, i, count, delay=60, total=230)
   其它        → 1
pressProgress : press 动画前半段 SWITCH(raw/0.5)，后半段 1-OPEN((raw-0.5)/0.5)，其它 0
rotationDeg : open → raw<0.5 ? -6 + 7*(raw/0.5) : 1 - 1*((raw-0.5)/0.5)；close → 6*raw；其它 0
scale       : open → raw<0.55 ? 0.75 + 0.28*(raw/0.55) : 1.03 - 0.03*((raw-0.55)/0.45)
              close → 1 - 0.25*raw；其它 1
```

`buttonProgress(elapsed, i, count)`：`start = 50 + min(25, (180*0.5)/(count-1)) * i`，`local = clamp((elapsed-start)/180, 0, 1)`，返回 `POP(local)`。
`staggeredPop`：`stagger = min(25, 120/(count-1))`，`start = delay + stagger*i`，`span = total - start`，返回 `POP(local)`。

### 12.4 动画驱动纪律（View 层）

- 单一 ticker；`run` + `pressRun` 两个 run，动画互相**接管**（新动画先按旧动画当前帧收敛再起）。
- `run == null && pressRun == null` → 立刻停 ticker（不留 Timer/Animator）。
- 换层动画只做过渡，**窗口不动**：新层级在既有信封内重算几何。
- `animateSelectionTo(i)`：`beginSwitch` → 起 `selectionSwitch` 动画 → `finishSwitch`。

---

## 13. 反馈条（`MenuFeedback`）

`FeedbackKind`：`running / success / warning / error`（wire 同名）。
`DURATION_MS = 2800`、`MAX_SUPERSEDED = 16`、`BAR_HEIGHT_DP = 26`、`MARGIN_DP = 8`。
`rectInWindow(w, h, barH, margin)`：固定在**窗口底部**，左右留 margin，**不改变窗口几何**。
`isStale(incoming, active, superseded)`：旧异步结果不得覆盖新反馈。

---

## 14. 分层与"桌宠覆盖菜单"（结构保证）

- 菜单与桌宠在**同一个窗口**内：菜单层 index 0（下），人物层 index 1（上）。
- 人物**永远画在菜单之上**；菜单底色从人物背后穿过；人物透明处自然透出菜单。
- 打开/关闭只改根窗口矩形与两层偏移（**一次** `updateViewLayout`），人物 View 实例与父容器在窗口生命周期内不变 → **人物不抽动是结构性保证**。
- 因为分层由窗口结构保证，**渲染器里没有"挖洞"逻辑**，也不需要避开人物。

> Windows 侧对应：增量 A 的固定画布 + Window Region 已实现"桌宠与菜单同画布、桌宠在上"。**迁移时不要引入挖洞、也不要把菜单画成整圆。**

---

## 15. Windows 迁移落点（增量 B 实施口径）

### 15.1 复用（不重写）

Android 的**纯逻辑**按语义 1:1 移植到 Dart（同一套公式与常量，不"顺手优化"）：
几何公式（§4/5/6）、颜色与派生（§7）、目录与栈（§3，已一致）、状态机（§11）、
手势（§10，输入源改鼠标）、动画（§12）、图标几何（§9）。

Kotlin **不在 Windows 运行**；Android 的双窗口方案**不照搬**，Windows 继续用
固定画布 + RegionCoordinator。

### 15.2 输入映射（触摸 → 鼠标）

| Android 触摸 | Windows 鼠标 |
| --- | --- |
| `ACTION_DOWN` | 左键按下 |
| `ACTION_MOVE`（按住拖动） | 按住左键拖动 |
| `ACTION_UP` | 松开左键 |
| `ACTION_CANCEL` / 多指 | Esc / 焦点丢失 / 窗口失活 |
| （无） | **额外支持悬停**：`onHover` 按 ring 分区更新高亮，但不确认、不改已确认项 |
| （无） | **额外支持 Esc**：等价 cancel，回弹到已确认项；根菜单再按 Esc 关闭 |

鼠标下 `touchSlop`/`swipeSlop` 用同一 dp 值换 px（8dp / 12dp）；`hy` 与 `leaveTolerance` 原样保留。
悬停不需要 130ms 离开容差（无手指抖动问题），但**漂移出 ring 时应清掉 hover 高亮**，与 Android 的 cancel 语义区分清楚（hover 是"预览"，cancel 是"回弹"）。

### 15.3 禁止项（对应用户反馈，逐条自查）

1. 禁止 Windows 重新设计"完整圆盘" —— 必须是扇形带。
2. 禁止六色块测试菜单出现在正式路径（保留为**默认关闭**的诊断开关）。
3. 禁止用普通 Material 菜单替代。
4. 禁止改变菜单顺序。
5. 禁止按钮明显更小（按钮直径基准 44dp × buttonVisualScale，默认 1.30）。
6. 禁止文字被裁切（必须走 `fitText` + 安全带弦宽）。
7. 禁止桌宠被菜单覆盖（人物在上层）。
8. 禁止菜单离桌宠过远（缺口恒绑桌宠锚点，偏移 ≤ `menuDistance`）。
9. 禁止大面积空白 / 完整圆底板。

### 15.4 Region（增量 A 成果，继续用）

Region 由**实际几何**生成：`pet ∪ 弧带扇形 ∪ 按钮命中圆 ∪ 文字 chip ∪ 反馈条`，
**不含整画布**，矩形数有上限；仅在开/关、镜像方向、层级变化、尺寸变化时更新，
**悬停与滑动过程中不重写** Region。

> ⚠️ **术语风险**：Android 轮盘**没有**用户可见的"menuGap"设置。
> 最接近的是 `menuDistance`（0.05~0.30，默认 0.16，"菜单偏离桌宠可见宽度的比例"）。
> 另有 `BUTTON_GAP_DP = 6`（相邻按钮净空，内部常量，不可调）。
> 若增量 B 要暴露"menuGap"设置，必须先明确它映射到 `menuDistance`，
> 否则会与 Android 语义漂移、导致缺口偏心量与 Android 不一致。

---

## 16. 基准截图清单（实施前从 Android 取，实施后逐项对照）

建议固定同一台设备、同一主题、同一桌宠位置，取以下 10 类基准：

1. 根菜单打开完成后（含 6 个按钮、6 个中文标签、选中项白底座、黄色强调弧）
2. 根菜单"形象"选中态（刀刃指向 + 三层文字：`APPEARANCE` / 形象 / 角色与素材）
3. 形象子菜单（6 项 + 返回在视觉最下方）
4. 记录子菜单（含 info 项"当前应用"）
5. 桌宠子菜单（7 项，最密）
6. 设置子菜单
7. 靠屏幕上边缘（topEdge：扇形偏 +26°）
8. 靠屏幕下边缘（bottomEdge：扇形偏 -26°）
9. 靠屏幕左边缘（左展开镜像：返回键仍在视觉最下方）
10. 打开动画中途帧（约 120ms，按钮错峰中）

---

## 17. 待修正项：已创建的 Windows 文件与基准的偏差

上一轮在"用户更正"之前，已按文字描述创建了 5 个 Windows 文件。它们与本文档基准存在**系统性偏差**，需按 Android 对齐（或直接重写）：

| Windows 文件 | 偏差 | 处理 |
| --- | --- | --- |
| `lib/menu/wheel_theme.dart` | 色值偏差：浅色 `0xFFFFD2E4`（应 `0xFFFFD8E9`）、强调 `0xFFFFD447`（应 `0xFFFFD42A`）、描边 `0xFF1B1320`（应 `0xFF111111`）；多出 Android 没有的"深色/次文字"字段；缺 `disabled 0xFF8E7180`、缺 `mix` 派生与 `baseFanColor`；wireName 用 `p3p_pink`（Android themeId 是 `p3p-pink`） | 重写 |
| `lib/menu/wheel_layout_engine.dart` | 参数凭文字设定：`baseButtonDiameter=64`（应 44dp）、`minHitDiameter=44`（应 48dp）、`minArcSpanRad=80°/maxArcSpanRad=200°`（应半张角 68°/50°/38°）、`arcSegmentRad=6°`、`defaultMaxRegionRects=48`；**完全没有**缺口椭圆、环带半径求解三式（spacing / notchHost / clearance）、`stepDeg 16..30`、`bladeHalfSweep 30°`、文字安全带、设备级应急缩放、`EDGE_FAN_BIAS 26°`、垂直模式 | 重写为 `wheel_geometry.dart` |
| `lib/menu/wheel_selection_controller.dart` | 缺 `rawIndexAt` 角度映射、7° 槽位滞回、中央缺口**椭圆**取消区、130ms 离开容差、`tapSlop 8dp / swipeSlop 12dp`、Owner 六态语义 | 重写 |
| `lib/menu/wheel_ui_state.dart` | 与七态状态机基本一致，需补 `settleAfterInterruption` / `beginSwitch`+`finishSwitch` / `canGoBack` / `phase.animating` 语义核对 | 核对后微调 |
| `lib/ui/desktop/wheel_menu_view.dart` | 绘制风格偏差：完整圆盘感 + 线性渐变（应**扇形带** + `secondary→background 0.40 @ alpha 108` 底色）、缺"鼓包"咬合内缘、缺齿轮凸起与黄色强调弧、缺选中项白底座（`0.62×` 白圆）、缺根菜单径向中文标签、缺三层文字安全带与 `fitText`；`iconForNode` 用 Material 图标而非 Android 原创几何 | 重写绘制 |

另需新增：`lib/menu/wheel_animator.dart`（缓动 + 时间线 + 帧推导）、`lib/ui/desktop/wheel_icons.dart`（39 个图标几何）。

---

## 18. 一句话验收标准

> 用户看到 Windows 版的第一反应应该是"**这是 Android PetLife 轮盘菜单的 Windows 版本**"，
> 而不是"Windows 又重新做了一套轮盘"。

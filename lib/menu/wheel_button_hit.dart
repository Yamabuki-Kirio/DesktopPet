/// C1.1.3 **统一 HitTest**（唯一权威）与**有效扇形**。
///
/// 这一层解决两个真机缺陷（C1.1.3 诊断脚本 `.tmp_c113_diag.txt` 的实测结论）
/// ----------------------------------------------------------------
/// 1. **选不中扇形本体**：旧实现只在 `distance <= rimOuterPx` 的**窄环带**上做
///    角度槽位判定，而正式菜单画出来的扇形半径是
///    `max(bladeLengthPx, rimOuterPx)`（实测 293 vs **381**）。落在 293~381
///    这段**扇形主体**上的鼠标被判成"背景"：
///    * 悬停 → 不高亮（`hoveredIndex = null`）；
///    * 单击 → 既不执行也不关闭（决策 A1）。
///    实测（悬停第 3 项后沿半径向外）：`r=323 → label#3`、
///    **`r=383 → background / hover=null`**、`r=333（第 4 项角度）→ background`。
/// 2. **高亮/指针回落到第一项**：命中背景时旧实现把视觉锚点写回
///    `state.selectedIndex`（= 0），于是**扇叶、标题 chip、实时信息**整体跳回
///    第 1 项（实测 `visualActive=3 → -1` 的同时 `selPos=3.00 → 0.00`、
///    `bladeA=13.6 → -68.0`）。用户看到的就是"高亮回到第一项"。
///
/// 本轮规则（需求 §4~§8）
/// ---------------------
/// * **唯一入口** [WheelHitTester.resolve]：悬停 / 按下 / 抬起 / 圆弧滑动全走它；
/// * 命中优先级（需求 §5）：**① 按钮圆形 → ② 该按钮自己的标签/chip →
///   ③ 有效扇形里的角度槽位 → ④ 人物保护区 → ⑤ 纯装饰 → ⑥ Region 外部**；
/// * **有效扇形**来自正式几何（[WheelPointerSector]）：角度 = 正式扇形角度域
///   （含 `fanBiasDeg`，左右镜像自动一致）；半径 = **人物保护区外缘 ~ 扇形外缘**，
///   因此"沿半径靠近/远离人物"不会掉出选择区（需求 §8）；
/// * 槽位角度**复用** `WheelMenuGeometry.rawIndexAt` + Android 的 **7° 滞回**，
///   不重新发明角度（需求 §7）。
///
/// 本文件是**纯 Dart**，可在 `flutter_tester` 直接单测。
library;

import 'dart:math' as math;
import 'dart:ui' show Offset, Rect;

import 'wheel_menu_geometry.dart'
    show
        WheelMenuGeometry,
        WheelMenuLayout,
        WheelSlotPlacement,
        WheelTextLayout,
        WheelTextSlots;

/// 命中分区（需求 §4 / §5 的六类）。
enum WheelPointerHitKind {
  /// ① 按钮圆形范围。
  buttonCircle,

  /// ② 该按钮自己的中文标签 / 文字 chip。
  buttonLabel,

  /// ③ **有效扇形**里的角度槽位（不要求落在窄环带上）。
  angularSector,

  /// ④ 人物保护区（alpha protection area）—— 不映射到任何按钮。
  petProtection,

  /// ⑤ 纯装饰（扇形之外的标题 / 阴影 / 反馈条 / 远角等）—— 不选择、不执行、不关闭。
  decoration,

  /// ⑥ Region 外部 —— 事件本层收不到（继续穿透给下层应用）。
  outside,
}

/// 一次命中结果（需求 §4）。
class WheelPointerHit {
  const WheelPointerHit(
    this.kind, {
    this.buttonIndex,
    this.slotIndex,
    this.radius = 0,
    this.angle = 0,
    this.distance = double.infinity,
  });

  final WheelPointerHitKind kind;

  /// 命中的按钮索引（④⑤⑥ 为 null）。
  final int? buttonIndex;

  /// 角度槽位推出的索引（仅 ③ 有值；= [buttonIndex]）。
  final int? slotIndex;

  /// 到轮盘中心的距离（诊断字段 `radius`）。
  final double radius;

  /// 相对轮盘中心的**绝对角度**（度；诊断字段 `angle`）。
  final double angle;

  /// 到该按钮视觉中心的距离（优先级 ④ 用）。
  final double distance;

  bool get isButton => buttonIndex != null;

  /// 中央缺口（桌宠交互区）—— 既有语义：未拖动点击 = 关闭菜单。
  bool get isNotch => kind == WheelPointerHitKind.petProtection;

  /// 既不命中按钮、也不是缺口（菜单背景：④⑤⑥ 之外的空档）。
  bool get isBackground => buttonIndex == null && kind != WheelPointerHitKind.petProtection;

  static const WheelPointerHit decoration = WheelPointerHit(WheelPointerHitKind.decoration);
  static const WheelPointerHit petProtection = WheelPointerHit(WheelPointerHitKind.petProtection);
  static const WheelPointerHit outside = WheelPointerHit(WheelPointerHitKind.outside);

  @override
  String toString() =>
      'WheelPointerHit(${kind.name}${buttonIndex == null ? '' : '#$buttonIndex'} '
      'r=${radius.toStringAsFixed(1)} a=${angle.toStringAsFixed(1)})';
}

/// 单个按钮的命中区域（**按按钮索引**建立，禁止跨按钮共用）。
class ButtonHitRegion {
  const ButtonHitRegion({
    required this.index,
    required this.center,
    required this.radius,
    this.label,
  });

  final int index;

  /// 按钮圆形（视觉中心；稳态：不含弹出 overshoot）。
  final Offset center;
  final double radius;

  /// 该按钮自己的中文标签矩形（根菜单才有；子菜单为 null）。
  final Rect? label;

  bool containsCircle(Offset p) => (p - center).distance <= radius;

  bool containsLabel(Offset p) => label?.contains(p) ?? false;

  @override
  String toString() => 'ButtonHitRegion(#$index @ '
      '${center.dx.toStringAsFixed(1)},${center.dy.toStringAsFixed(1)} '
      'r=${radius.toStringAsFixed(1)}${label == null ? '' : ' label'})';
}

/// **有效扇形**（需求 §6）：从**正式几何**算出，**不是**整个窗口 Region。
///
/// ```text
/// 角度：正式菜单起始角 ～ 正式菜单结束角（含 fanBiasDeg，镜像自动一致）
/// 半径：人物保护区外缘 ～ max(bladeLengthPx, rimOuterPx)   ← 扇形/轨道的交互外缘
/// ```
///
/// 不含扇形之外的标题 / 阴影 / 反馈条 / 纯装饰文字（那些落 [WheelPointerHitKind.decoration]）。
class WheelPointerSector {
  WheelPointerSector(this.layout);

  final WheelMenuLayout layout;

  /// 半径容差（px）：覆盖描边与抗锯齿，避免"正好压在扇形边缘"时判空。
  static const double radiusTolerancePx = 2;

  /// 角度容差（度）：同上。只影响**扇形外缘**，槽位判定仍用 7° 滞回。
  static const double angleToleranceDeg = 2;

  /// 扇形起始**绝对角**（与 Painter `_drawBaseFan` 同源）。
  double get startAngleDeg => WheelMenuGeometry.absoluteAngle(
        layout.direction,
        -layout.fanHalfSpanDeg + layout.fanBiasDeg,
      );

  /// 扇形扫过角度（**带符号**，与 Painter 同源）。
  double get sweepDeg => layout.direction.sign * layout.fanHalfSpanDeg * 2;

  /// 交互外缘：扇形 / 轨道的正式外缘（= `max(bladeLengthPx, rimOuterPx)`）。
  double get outerRadiusPx => math.max(layout.bladeLengthPx, layout.rimOuterPx);

  /// 内边界：人物保护区外缘。缺口是椭圆，这里给出**该方向**上的边界半径。
  double innerRadiusAt(double angleDeg) {
    final double rx = math.max(layout.notchRx, 1);
    final double ry = math.max(layout.notchRy, 1);
    final double rad = angleDeg * math.pi / 180;
    final double c = math.cos(rad);
    final double s = math.sin(rad);
    final double denom = math.sqrt((c / rx) * (c / rx) + (s / ry) * (s / ry));
    return denom <= 0 ? math.min(rx, ry) : 1 / denom;
  }

  /// 点是否落在扇形的**角度域**内（相对起始角、按 sweep 方向归一）。
  bool containsAngle(double angleDeg) {
    final double delta =
        WheelMenuGeometry.normalizeAngle(angleDeg - startAngleDeg) * layout.direction.sign;
    return delta >= -angleToleranceDeg && delta <= sweepDeg.abs() + angleToleranceDeg;
  }

  /// 点是否落在**有效扇形主体**内（角度域 + 半径区间 + 排除人物保护区）。
  bool contains(Offset p) {
    if (insideNotch(p)) return false;
    final double dx = p.dx - layout.centerX;
    final double dy = p.dy - layout.centerY;
    final double radius = math.sqrt(dx * dx + dy * dy);
    if (radius > outerRadiusPx + radiusTolerancePx) return false;
    return containsAngle(math.atan2(dy, dx) * 180 / math.pi);
  }

  /// 是否落在人物保护区（中央缺口）—— 与手势层同一实现（椭圆判定）。
  bool insideNotch(Offset p) {
    final double rx = math.max(layout.notchRx, 1);
    final double ry = math.max(layout.notchRy, 1);
    final double nx = (p.dx - layout.notchCenterX) / rx;
    final double ny = (p.dy - layout.notchCenterY) / ry;
    return nx * nx + ny * ny <= 1;
  }

  Map<String, Object?> describe() => <String, Object?>{
        'sectorStart': startAngleDeg.toStringAsFixed(1),
        'sectorSweep': sweepDeg.toStringAsFixed(1),
        'sectorInner': innerRadiusAt(layout.fanBiasDeg).toStringAsFixed(1),
        'sectorOuter': outerRadiusPx.toStringAsFixed(1),
        'fanBias': layout.fanBiasDeg.toStringAsFixed(1),
      };
}

/// 共享几何 HitTest（**唯一权威**：悬停 / 按下 / 抬起 / 重算都用它）。
class WheelHitTester {
  WheelHitTester(
    this.layout, {
    this.density = 1.0,
    this.showButtonLabels = true,
    this.labelSizeSp = 10,
  });

  final WheelMenuLayout layout;

  /// 逻辑密度（标签字号换算用；与 Painter 同口径）。
  final double density;

  /// 根菜单是否画按钮中文标签（与 Painter `showButtonLabels` 同口径）。
  final bool showButtonLabels;

  /// 标签最小字号（sp）—— 与 `WheelMenuRenderer.minLabelSp` 同值。
  final double labelSizeSp;

  /// 角度滞回（度）—— 与 Android `WheelMenuGesture.hysteresisDegDefault` 同值。
  static const double hysteresisDeg = 7;

  late final List<ButtonHitRegion> regions = _buildRegions();

  late final WheelPointerSector sector = WheelPointerSector(layout);

  List<ButtonHitRegion> _buildRegions() {
    final List<ButtonHitRegion> out = <ButtonHitRegion>[];
    for (final WheelSlotPlacement slot in layout.slots) {
      // 圆形范围：稳态按钮半径 + 描边余量（**不含**弹出 overshoot，
      // 否则相邻按钮会互相吞并 → 误选）。
      final double radius =
          layout.buttonDiameterPx / 2 + layout.outlineWidthPx * 1.2;
      out.add(
        ButtonHitRegion(
          index: slot.index,
          center: Offset(slot.centerX, slot.centerY),
          radius: radius,
          label: (showButtonLabels && !slot.entry.isBack)
              ? labelRectFor(slot)
              : null,
        ),
      );
    }
    return out;
  }

  /// 单个按钮的标签矩形（与 Painter `_drawButtonLabels` / 视觉包围盒**同源**）。
  ///
  /// 稳态（无 overshoot 推移），因此可作为命中区。
  Rect labelRectFor(WheelSlotPlacement slot) {
    final double size =
        math.max(layout.buttonDiameterPx * 0.30, density * labelSizeSp);
    final double radius =
        layout.buttonDiameterPx / 2 + layout.rimLobePx * 0.5 + size * 0.95;
    final double dx = slot.centerX - layout.centerX;
    final double dy = slot.centerY - layout.centerY;
    final double len = math.max(1, math.sqrt(dx * dx + dy * dy));
    final double lx = slot.centerX + dx / len * radius;
    final double ly = slot.centerY + dy / len * radius;
    final double halfW = size * 3 + layout.outlineWidthPx * 1.1;
    final double halfH = size * 0.75 + layout.outlineWidthPx * 1.1;
    return Rect.fromLTRB(lx - halfW, ly - halfH, lx + halfW, ly + halfH);
  }

  /// 当前选中项的文字 chip 矩形（与 Painter `_drawTexts` 的 chip 同源）。
  Rect? chipRectFor(int? selectedIndex) {
    if (selectedIndex == null || layout.itemCount <= 0) return null;
    if (selectedIndex < 0 || selectedIndex >= layout.itemCount) return null;
    final WheelTextSlots slots = _textSlots();
    final double offsetAngle =
        (selectedIndex - (layout.itemCount - 1) / 2) * layout.stepDeg;
    final double selection = WheelMenuGeometry.absoluteAngle(
      layout.direction,
      offsetAngle + layout.fanBiasDeg,
    );
    final double rad = selection * math.pi / 180;
    final double cx = layout.centerX + slots.chipRadius * math.cos(rad);
    final double cy = layout.centerY + slots.chipRadius * math.sin(rad);
    final double halfW = slots.chipMaxWidth / 2 + layout.outlineWidthPx;
    final double halfH = slots.chipSizePx * 0.86 + layout.outlineWidthPx;
    return Rect.fromLTRB(cx - halfW, cy - halfH, cx + halfW, cy + halfH);
  }

  WheelTextSlots _textSlots() =>
      WheelTextLayout.compute(layout, density, 13, 16, 11);

  /// **统一 HitTest 入口**（需求 §4 / §5 的六级优先）。
  ///
  /// * [previousIndex]：当前已高亮的槽位 —— 用于 **7° 滞回**（需求 §7-4/5），
  ///   相邻槽位边界附近不会来回抖动；
  /// * [selectedIndex]：用于把"当前选中项的文字 chip"并入该按钮的命中区。
  WheelPointerHit resolve(
    Offset p, {
    int? previousIndex,
    int? selectedIndex,
  }) {
    final double dx = p.dx - layout.centerX;
    final double dy = p.dy - layout.centerY;
    final double radius = math.sqrt(dx * dx + dy * dy);
    final double angle = math.atan2(dy, dx) * 180 / math.pi;

    // ⑥ Region 外部（窗口之外）—— 事件本层收不到；显式判定只用于测试 / 诊断。
    if (!_insideCanvas(p)) {
      return WheelPointerHit(
        WheelPointerHitKind.outside,
        radius: radius,
        angle: angle,
      );
    }

    // ① 按钮圆形范围（多个命中取**视觉中心最近者**）。
    final ButtonHitRegion? circle =
        _nearest(p, (ButtonHitRegion r) => r.containsCircle(p));
    if (circle != null) {
      return WheelPointerHit(
        WheelPointerHitKind.buttonCircle,
        buttonIndex: circle.index,
        radius: radius,
        angle: angle,
        distance: (p - circle.center).distance,
      );
    }

    // ② 该按钮自己的标签 / 文字 chip（同样取最近的中心）。
    final Rect? selectedChip = chipRectFor(selectedIndex);
    final ButtonHitRegion? label = _nearest(
      p,
      (ButtonHitRegion r) =>
          r.containsLabel(p) ||
          (selectedChip != null &&
              r.index == selectedIndex &&
              selectedChip.contains(p)),
    );
    if (label != null) {
      return WheelPointerHit(
        WheelPointerHitKind.buttonLabel,
        buttonIndex: label.index,
        radius: radius,
        angle: angle,
        distance: (p - label.center).distance,
      );
    }

    // ③ 有效扇形里的角度槽位（**不要求**落在窄环带上；需求 §6 / §8）。
    if (sector.contains(p)) {
      final int? index = slotIndexForAngle(angle, previousIndex: previousIndex);
      if (index != null) {
        return WheelPointerHit(
          WheelPointerHitKind.angularSector,
          buttonIndex: index,
          slotIndex: index,
          radius: radius,
          angle: angle,
          distance: (p - regions[index].center).distance,
        );
      }
    }

    // ④ 人物保护区（不映射到任何按钮；点击按既有"桌宠"规则处理）。
    if (sector.insideNotch(p)) {
      return WheelPointerHit(
        WheelPointerHitKind.petProtection,
        radius: radius,
        angle: angle,
      );
    }

    // ⑤ 纯装饰（扇形之外的标题 / 阴影 / 反馈条 / 远角）。
    return WheelPointerHit(
      WheelPointerHitKind.decoration,
      radius: radius,
      angle: angle,
    );
  }

  /// 是否落在轮盘画布之内。
  ///
  /// 本层收到的永远是**菜单窗口局部坐标**（`Listener.localPosition`），
  /// 因此画布在局部空间就是 `(0,0) ~ (width,height)`；不使用信封坐标系下的
  /// `windowRect.left/top`（那是屏幕坐标，混用会得到假阴性）。
  bool _insideCanvas(Offset p) =>
      p.dx >= 0 &&
      p.dy >= 0 &&
      p.dx < layout.windowRect.width &&
      p.dy < layout.windowRect.height;

  /// 是否落在中央缺口（椭圆判定；与手势层同一实现）。
  bool insideNotch(Offset p) => sector.insideNotch(p);

  /// 该点落在哪个**角度槽位**（纯角度 + 7° 滞回；与手势层 `indexAt` 同口径）。
  int? slotIndexAt(Offset p, {int? previousIndex}) {
    final double angle =
        math.atan2(p.dy - layout.centerY, p.dx - layout.centerX) * 180 / math.pi;
    return slotIndexForAngle(angle, previousIndex: previousIndex);
  }

  /// **绝对角度 → 槽位索引**（复用 `rawIndexAt`；需求 §7：不重新发明角度）。
  int? slotIndexForAngle(double angleDeg, {int? previousIndex}) {
    if (layout.itemCount <= 0) return null;
    if (layout.itemCount == 1) return 0;
    if (layout.stepDeg <= 0) return null;
    final double raw = WheelMenuGeometry.rawIndexAt(layout, angleDeg);
    if (previousIndex != null &&
        previousIndex >= 0 &&
        previousIndex < layout.itemCount) {
      final double hysteresisUnits = (hysteresisDeg / layout.stepDeg).clamp(0.0, 0.45);
      if ((raw - previousIndex).abs() < 0.5 + hysteresisUnits) return previousIndex;
    }
    return raw.round().clamp(0, layout.itemCount - 1);
  }

  ButtonHitRegion? _nearest(Offset p, bool Function(ButtonHitRegion region) test) {
    ButtonHitRegion? best;
    double bestDistance = double.infinity;
    for (final ButtonHitRegion region in regions) {
      if (!test(region)) continue;
      final double d = (p - region.center).distance;
      if (d < bestDistance) {
        bestDistance = d;
        best = region;
      }
    }
    return best;
  }
}

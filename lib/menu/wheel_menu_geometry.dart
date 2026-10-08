/// 轮盘参数化几何（**Android `WheelMenuGeometry.kt` 的 1:1 移植**）。
///
/// 移植纪律（增量 B 决策四）：
/// * 常量、公式、取整位置与 Android **逐字一致**，不"顺手优化"；
/// * 两段式 API 原样保留：[WheelMenuGeometry.computeEnvelope] 打开时算一次信封
///   （窗口 + 中心 + 缺口），[WheelMenuGeometry.layoutFor] 每次换层 / 切换在同一信封里
///   重算内部几何，**绝不改窗口**；
/// * 三条不变量：缺口是**椭圆**且中心**恒等于桌宠视觉锚点**；缺口由桌宠**可见尺寸**
///   决定且**不乘应急缩放**；环带反过来必须容得下缺口（`max(rx,ry)/0.88 + buttonR`）。
///
/// 本文件是**纯 Dart**（只依赖 `dart:math`），可在 `flutter_tester` 直接单测。
library;

import 'dart:math' as math;
import 'dart:ui' show Rect;

import '../character/pet_visual_bounds.dart' show PetVisualBounds;
import 'menu_contract.dart' show MenuCatalog, MenuLevel, MenuNode;
import 'wheel_expansion_side.dart';
import 'wheel_geometry_ownership.dart' show WheelGeometryJournal;

// ---------------------------------------------------------------------------
// 基础矩形 / 边界（Android OverlayRect / OverlayBounds / PetContentBounds 的最小等价物）
// ---------------------------------------------------------------------------

/// 一个屏幕矩形（逻辑像素）。构造函数四舍五入到整数，与 Android `OverlayRect.of` 同口径。
class WheelRect {
  const WheelRect(this.left, this.top, this.right, this.bottom);

  final double left;
  final double top;
  final double right;
  final double bottom;

  double get width => (right - left).clamp(0, double.infinity);

  double get height => (bottom - top).clamp(0, double.infinity);

  double get centerX => left + width / 2;

  double get centerY => top + height / 2;

  bool get isUsable => width > 0 && height > 0;

  bool contains(double x, double y) =>
      x >= left && x < right && y >= top && y < bottom;

  bool isInside(WheelBounds bounds) =>
      bounds.isUsable &&
      left >= bounds.left &&
      top >= bounds.top &&
      right <= bounds.right &&
      bottom <= bounds.bottom;

  WheelRect translate(double dx, double dy) =>
      WheelRect(left + dx, top + dy, right + dx, bottom + dy);

  WheelRect union(WheelRect other) => WheelRect(
        math.min(left, other.left),
        math.min(top, other.top),
        math.max(right, other.right),
        math.max(bottom, other.bottom),
      );

  /// 转成 `dart:ui` 的 [Rect]（诊断 / 日志 / 视觉边界计算用）。
  Rect toRect() => Rect.fromLTRB(left, top, right, bottom);

  /// 是否完整包含在 [other] 内（含容差）。
  bool isInsideRect(Rect other, {double tolerance = 0.5}) =>
      left >= other.left - tolerance &&
      top >= other.top - tolerance &&
      right <= other.right + tolerance &&
      bottom <= other.bottom + tolerance;

  /// 由四个浮点边界构造（坐标换算用）—— 与 Android 一致地**四舍五入**。
  static WheelRect of(double left, double top, double right, double bottom) =>
      WheelRect(left.roundToDouble(), top.roundToDouble(), right.roundToDouble(),
          bottom.roundToDouble());

  /// 以 `(cx, cy)` 为中心、边长 `size` 的正方形。
  static WheelRect centered(double cx, double cy, double size) {
    final double half = (size / 2).floorToDouble();
    return WheelRect(cx - half, cy - half, cx - half + size, cy - half + size);
  }

  @override
  String toString() =>
      'WheelRect(${left.toInt()},${top.toInt()},${right.toInt()},${bottom.toInt()})';
}

/// 可用区域（显示器安全带，逻辑像素）。
class WheelBounds {
  const WheelBounds(this.left, this.top, this.right, this.bottom);

  final double left;
  final double top;
  final double right;
  final double bottom;

  double get width => (right - left).clamp(0, double.infinity);

  double get height => (bottom - top).clamp(0, double.infinity);

  bool get isUsable => width > 0 && height > 0;

  static const WheelBounds unknown = WheelBounds(0, 0, 0, 0);

  static WheelBounds ofScreen(double width, double height) =>
      width > 0 && height > 0 ? WheelBounds(0, 0, width, height) : unknown;

  /// 兜底：把 `[left, top, w, h]` 归一成合法边界。
  static WheelBounds ofLTWH(double left, double top, double width, double height) =>
      WheelBounds(left, top, left + math.max(0, width), top + math.max(0, height));

  @override
  String toString() =>
      'WheelBounds(${width.toInt()}x${height.toInt()} @ ${left.toInt()},${top.toInt()})';
}

/// 桌宠素材的可见边界（相对窗口的 0~1 归一化比例）。
class WheelContentBounds {
  const WheelContentBounds(this.left, this.top, this.right, this.bottom);

  final double left;
  final double top;
  final double right;
  final double bottom;

  double get width => (right - left).clamp(0.01, 1.0);

  double get height => (bottom - top).clamp(0.01, 1.0);

  bool get isFull =>
      left <= 0.001 && top <= 0.001 && right >= 0.999 && bottom >= 0.999;

  static const WheelContentBounds full = WheelContentBounds(0, 0, 1, 1);

  /// 把相对边界换算成**屏幕绝对矩形**。
  static WheelRect toScreenRect(WheelRect petBounds, WheelContentBounds bounds) {
    final double w = petBounds.width;
    final double h = petBounds.height;
    return WheelRect.of(
      petBounds.left + w * bounds.left,
      petBounds.top + h * bounds.top,
      petBounds.left + w * bounds.right,
      petBounds.top + h * bounds.bottom,
    );
  }
}

// ---------------------------------------------------------------------------
// 方向 / 垂直模式
// ---------------------------------------------------------------------------

/// 靠边时扇形的额外偏转（正 = 向视觉下方偏）。
const double kEdgeFanBiasDeg = 26;

/// 轮盘展开方向。
enum WheelExpandDirection {
  right(1),
  left(-1);

  const WheelExpandDirection(this.sign);

  /// `right = +1` / `left = -1`。
  final int sign;

  String get labelZh => this == WheelExpandDirection.right ? '右' : '左';

  WheelExpandDirection get opposite =>
      this == WheelExpandDirection.right ? WheelExpandDirection.left : WheelExpandDirection.right;

  static WheelExpandDirection fromWire(String? raw) {
    for (final WheelExpandDirection value in WheelExpandDirection.values) {
      if (value.name == raw) return value;
    }
    return WheelExpandDirection.right;
  }
}

/// 垂直布局模式。**绝不平移轮盘中心**，只改扇形朝向 + 降实际缩放。
enum WheelVerticalMode {
  center(0),
  topEdge(kEdgeFanBiasDeg),
  bottomEdge(-kEdgeFanBiasDeg);

  const WheelVerticalMode(this.biasDeg);

  final double biasDeg;

  String get labelZh => switch (this) {
        WheelVerticalMode.center => '居中',
        WheelVerticalMode.topEdge => '靠上',
        WheelVerticalMode.bottomEdge => '靠下',
      };

  static WheelVerticalMode fromWire(String? raw) {
    for (final WheelVerticalMode value in WheelVerticalMode.values) {
      if (value.name == raw) return value;
    }
    return WheelVerticalMode.center;
  }
}

// ---------------------------------------------------------------------------
// 用户设置
// ---------------------------------------------------------------------------

/// 轮盘布局设置（**与主题分开**：主题管颜色，这里管几何）。
class WheelMenuLayoutSettings {
  const WheelMenuLayoutSettings({
    this.preferredScale = defaultScale,
    this.menuDistance = defaultDistance,
    this.buttonVisualScale = defaultButtonScale,
    this.compactMode = false,
    this.revision = 0,
  });

  /// 用户期望的轮盘大小。
  final double preferredScale;

  /// 菜单偏离桌宠可见宽度的比例（仅用于让脸部与标题错开）。
  final double menuDistance;

  /// 按钮视觉缩放的额外倍率（**默认 1.30**，Android `DEFAULT_BUTTON_SCALE`）。
  final double buttonVisualScale;

  /// 紧凑模式。
  final bool compactMode;

  final int revision;

  // --- 常量（逐字，不得改动）---
  static const double minScale = 0.50;
  static const double maxScale = 2.50;
  static const double step = 0.10;
  static const double defaultScale = 1.00;

  static const double minDistance = 0.05;
  static const double maxDistance = 0.30;
  static const double defaultDistance = 0.16;

  /// 菜单距离在**轮盘调整层**里的步进。
  ///
  /// 取 **0.01**（而不是 0.02）：默认值 0.16 与上限 0.30 都必须**落在步进网格上**，
  /// 否则"恢复到默认"与"加到最大"都到不了 —— 网格从 0.05 起算，
  /// `0.05 + k×0.02` 得到 0.05/0.07/…/0.29，既不含 0.16 也不含 0.30。
  /// 0.01 则覆盖 0.05~0.30 全区间（含两端与默认值）。
  ///
  /// 设置页的滑杆仍是连续拖动，不受此约束。
  static const double distanceStep = 0.01;

  static const double minButtonScale = 0.50;
  static const double maxButtonScale = 2.50;
  static const double buttonStep = 0.10;
  static const double defaultButtonScale = 1.30;

  /// 按钮触摸直径下界（无论视觉多小，触摸范围不低于 48dp）。
  static const double buttonTouchMinDp = 48;

  static const WheelMenuLayoutSettings defaults = WheelMenuLayoutSettings();

  WheelMenuLayoutSettings normalized() => copyWith(
        preferredScale: clampScale(preferredScale),
        menuDistance: clampDistance(menuDistance),
        buttonVisualScale: clampButtonScale(buttonVisualScale),
      );

  WheelMenuLayoutSettings copyWith({
    double? preferredScale,
    double? menuDistance,
    double? buttonVisualScale,
    bool? compactMode,
    int? revision,
  }) =>
      WheelMenuLayoutSettings(
        preferredScale: preferredScale ?? this.preferredScale,
        menuDistance: menuDistance ?? this.menuDistance,
        buttonVisualScale: buttonVisualScale ?? this.buttonVisualScale,
        compactMode: compactMode ?? this.compactMode,
        revision: revision ?? this.revision,
      );

  static double clampScale(double value) =>
      !value.isFinite ? defaultScale : value.clamp(minScale, maxScale);

  static double clampButtonScale(double value) =>
      !value.isFinite ? defaultButtonScale : value.clamp(minButtonScale, maxButtonScale);

  static double clampDistance(double value) =>
      !value.isFinite ? defaultDistance : value.clamp(minDistance, maxDistance);

  /// 把任意比例吸附到 10% 的步进（滑块的取值口径）。
  static double quantizeScale(double value) {
    final double steps = (clampScale(value) / step).roundToDouble();
    return clampScale(steps * step);
  }

  static double quantizeButtonScale(double value) {
    final double steps = (clampButtonScale(value) / buttonStep).roundToDouble();
    return clampButtonScale(steps * buttonStep);
  }

  @override
  String toString() =>
      'WheelMenuLayoutSettings(scale=$preferredScale distance=$menuDistance '
      'button=$buttonVisualScale compact=$compactMode)';
}

/// 密度换算后的轮盘尺寸参数。字段名与 Android `WheelMenuSpec` 一一对应。
class WheelMenuSpec {
  const WheelMenuSpec({
    required this.buttonDiameterPx,
    required this.compactButtonDiameterPx,
    required this.buttonGapPx,
    required this.bandPaddingPx,
    required this.rimLobePx,
    required this.outlinePx,
    required this.density,
    required this.offsetRatio,
  });

  final double buttonDiameterPx;
  final double compactButtonDiameterPx;
  final double buttonGapPx;
  final double bandPaddingPx;
  final double rimLobePx;
  final double outlinePx;
  final double density;

  /// 缺少用户设置时的默认菜单偏移比例。
  final double offsetRatio;

  static const double buttonDiameterDp = 44;
  static const double buttonDiameterCompactDp = 40;
  static const double buttonGapDp = 6;
  static const double bandPaddingDp = 8;
  static const double rimLobeDp = 7;

  /// 描边基准宽度（**收细**，避免黑圈糊住字）。
  static const double outlineDp = 2.2;
  static const double minOutlineDp = 1.2;
  static const double maxOutlineDp = 4.5;
  static const double minOutlineScale = 0.72;

  static const double defaultOffsetRatio = WheelMenuLayoutSettings.defaultDistance;

  /// 按钮可见直径（随**实际缩放**变化）。
  ///
  /// ⚠️ **按钮大小设置不在这里**：唯一来源是 `buttonVisualScale`，由 `intrinsicLayout`
  /// 乘进去。缩放上限放宽到 4.0，只防止算出荒谬值。
  double buttonDiameterFor(int itemCount, [double scale = 1]) {
    final double base = itemCount >= 7 ? compactButtonDiameterPx : buttonDiameterPx;
    return base * scale.clamp(0.20, 4.0);
  }

  double dp(double value) => value * density;

  /// 描边宽度：随缩放变化，但有上下限。
  double outlineWidthFor(double basePx, double scaled) =>
      (basePx * math.max(scaled, minOutlineScale))
          .clamp(minOutlineDp * density, maxOutlineDp * density);

  static WheelMenuSpec fromDensity(double density) {
    final double d = safeDensity(density);
    return WheelMenuSpec(
      buttonDiameterPx: buttonDiameterDp * d,
      compactButtonDiameterPx: buttonDiameterCompactDp * d,
      buttonGapPx: buttonGapDp * d,
      bandPaddingPx: bandPaddingDp * d,
      rimLobePx: rimLobeDp * d,
      outlinePx: outlineDp * d,
      density: d,
      offsetRatio: defaultOffsetRatio,
    );
  }

  /// Android `OverlayGeometry.safeDensity`：有限且 > 0，否则 1。
  static double safeDensity(double density) =>
      density.isFinite && density > 0 ? density : 1.0;
}

// ---------------------------------------------------------------------------
// 固有几何 / 槽位 / 信封 / 层级几何
// ---------------------------------------------------------------------------

/// 一个按钮槽位的落位结果（坐标为**菜单窗口内相对坐标**）。
class WheelSlotPlacement {
  const WheelSlotPlacement({
    required this.index,
    required this.entry,
    required this.offsetAngleDeg,
    required this.absoluteAngleDeg,
    required this.centerX,
    required this.centerY,
  });

  final int index;
  final MenuNode entry;
  final double offsetAngleDeg;
  final double absoluteAngleDeg;
  final double centerX;
  final double centerY;

  @override
  String toString() => 'WheelSlotPlacement($index ${entry.id} @ '
      '${centerX.toInt()},${centerY.toInt()} abs=${absoluteAngleDeg.toStringAsFixed(1)}°)';
}

/// 轮盘的**固有几何**：只由设置 / 条目数 / 桌宠**尺寸**决定，与位置无关。
class WheelIntrinsicLayout {
  const WheelIntrinsicLayout({
    required this.itemCount,
    required this.ringRadiusPx,
    required this.buttonDiameterPx,
    required this.bandOuterPx,
    required this.rimOuterPx,
    required this.bladeLengthPx,
    required this.bladeHalfSweepDeg,
    required this.stepDeg,
    required this.fanHalfSpanDeg,
    required this.outlineWidthPx,
    required this.rimLobePx,
    required this.compact,
    required this.notchRx,
    required this.notchRy,
    required this.halfWidthPx,
    required this.halfHeightPx,
  });

  final int itemCount;
  final double ringRadiusPx;
  final double buttonDiameterPx;
  final double bandOuterPx;
  final double rimOuterPx;
  final double bladeLengthPx;
  final double bladeHalfSweepDeg;
  final double stepDeg;
  final double fanHalfSpanDeg;
  final double outlineWidthPx;
  final double rimLobePx;
  final bool compact;

  /// 缺口半轴（由桌宠可见尺寸决定；**未夹取**）。
  final double notchRx;
  final double notchRy;

  /// 绘制包围盒的半宽 / 半高（含文字 AABB 与安全边距，用于设备级应急缩放）。
  final double halfWidthPx;
  final double halfHeightPx;
}

/// 菜单窗口的"信封"——打开时一次性确定，打开期间不变。
class WheelMenuEnvelope {
  const WheelMenuEnvelope({
    required this.direction,
    required this.verticalMode,
    required this.windowRect,
    required this.centerX,
    required this.centerY,
    required this.petAnchorX,
    required this.petAnchorY,
    required this.holeRx,
    required this.holeRy,
    required this.allowedOffsetPx,
    required this.maxRingRadiusPx,
    required this.buttonDiameterPx,
    required this.buttonTouchDiameterPx,
    required this.fanBiasDeg,
    required this.preferredScale,
    required this.actualScale,
    required this.compact,
    required this.degraded,
    this.fallbackReason,
  });

  final WheelExpandDirection direction;
  final WheelVerticalMode verticalMode;
  final WheelRect windowRect;

  /// 轮盘中心（屏幕绝对坐标）。
  final double centerX;
  final double centerY;

  /// 桌宠**视觉**锚点（屏幕绝对坐标）——中央缺口必须绑在它上面。
  final double petAnchorX;
  final double petAnchorY;

  /// 中央缺口椭圆半径（相对桌宠锚点）。
  final double holeRx;
  final double holeRy;

  /// 允许的视觉偏移上限。
  final double allowedOffsetPx;

  final double maxRingRadiusPx;
  final double buttonDiameterPx;
  final double buttonTouchDiameterPx;
  final double fanBiasDeg;
  final double preferredScale;
  final double actualScale;
  final bool compact;
  final bool degraded;
  final String? fallbackReason;

  double get widthPx => windowRect.width;

  double get heightPx => windowRect.height;

  /// 缺口锚点与桌宠锚点的实际距离（诊断用；恒应 ≤ [allowedOffsetPx]）。
  double get anchorDistancePx =>
      math.sqrt(math.pow(centerX - petAnchorX, 2) + math.pow(centerY - petAnchorY, 2));

  @override
  String toString() => 'WheelMenuEnvelope(dir=${direction.name} v=${verticalMode.name} '
      'win=$windowRect center=(${centerX.toInt()},${centerY.toInt()}) '
      'anchor=(${petAnchorX.toInt()},${petAnchorY.toInt()}) scale=$actualScale compact=$compact)';
}

/// 一次只读几何测量的结果（诊断 / 规划 / 测试共用）。
class WheelGeometryMeasurement {
  const WheelGeometryMeasurement({
    required this.side,
    required this.invariantPassed,
    required this.petAnchorX,
    required this.petAnchorY,
    required this.holeRx,
    required this.holeRy,
    required this.ringRadiusPx,
    required this.buttonDiameterPx,
    required this.offsetPx,
    required this.envelope,
    required this.layout,
    required this.intrinsic,
  });

  final WheelExpansionSide side;
  final bool invariantPassed;
  final double petAnchorX;
  final double petAnchorY;
  final double holeRx;
  final double holeRy;
  final double ringRadiusPx;
  final double buttonDiameterPx;
  final double offsetPx;
  final WheelMenuEnvelope envelope;
  final WheelMenuLayout layout;
  final WheelIntrinsicLayout intrinsic;

  Map<String, Object?> describe() => <String, Object?>{
        'side': side.wireName,
        'invariantPassed': invariantPassed,
        'petAnchor': '${petAnchorX.toStringAsFixed(1)},'
            '${petAnchorY.toStringAsFixed(1)}',
        'hole': '${holeRx.toStringAsFixed(1)}×${holeRy.toStringAsFixed(1)}',
        'ringRadius': ringRadiusPx,
        'buttonDiameter': buttonDiameterPx,
        'offset': offsetPx,
        'windowRect': envelope.windowRect.toString(),
      };
}

/// 某一个层级的实际几何（坐标为窗口内相对坐标）。
class WheelMenuLayout {
  const WheelMenuLayout({
    required this.direction,
    required this.verticalMode,
    required this.itemCount,
    required this.windowRect,
    required this.centerX,
    required this.centerY,
    required this.ringRadiusPx,
    required this.bandOuterPx,
    required this.notchCenterX,
    required this.notchCenterY,
    required this.notchRx,
    required this.notchRy,
    required this.bladeLengthPx,
    required this.bladeHalfSweepDeg,
    required this.stepDeg,
    required this.fanHalfSpanDeg,
    required this.fanBiasDeg,
    required this.buttonDiameterPx,
    required this.buttonTouchDiameterPx,
    required this.outlineWidthPx,
    required this.rimLobePx,
    required this.slots,
    required this.actualScale,
    required this.compact,
    required this.degraded,
  });

  final WheelExpandDirection direction;
  final WheelVerticalMode verticalMode;
  final int itemCount;
  final WheelRect windowRect;
  final double centerX;
  final double centerY;
  final double ringRadiusPx;
  final double bandOuterPx;

  /// 中央缺口椭圆：中心（窗口内坐标，**恒等于桌宠锚点**）与两个半径。
  final double notchCenterX;
  final double notchCenterY;
  final double notchRx;
  final double notchRy;

  final double bladeLengthPx;
  final double bladeHalfSweepDeg;
  final double stepDeg;
  final double fanHalfSpanDeg;
  final double fanBiasDeg;
  final double buttonDiameterPx;
  final double buttonTouchDiameterPx;
  final double outlineWidthPx;
  final double rimLobePx;
  final List<WheelSlotPlacement> slots;
  final double actualScale;
  final bool compact;
  final bool degraded;

  double get rimOuterPx => bandOuterPx + rimLobePx;

  /// 整体平移（坐标换算用；C1.1 的"唯一换算"只允许这一个入口）。
  ///
  /// 典型用法：把"窗口局部"布局平移到"相对人物 Widget"的帧去做包围盒测量。
  WheelMenuLayout shiftedBy(double dx, double dy) => WheelMenuLayout(
        direction: direction,
        verticalMode: verticalMode,
        itemCount: itemCount,
        windowRect: windowRect.translate(dx, dy),
        centerX: centerX + dx,
        centerY: centerY + dy,
        ringRadiusPx: ringRadiusPx,
        bandOuterPx: bandOuterPx,
        notchCenterX: notchCenterX + dx,
        notchCenterY: notchCenterY + dy,
        notchRx: notchRx,
        notchRy: notchRy,
        bladeLengthPx: bladeLengthPx,
        bladeHalfSweepDeg: bladeHalfSweepDeg,
        stepDeg: stepDeg,
        fanHalfSpanDeg: fanHalfSpanDeg,
        fanBiasDeg: fanBiasDeg,
        buttonDiameterPx: buttonDiameterPx,
        buttonTouchDiameterPx: buttonTouchDiameterPx,
        outlineWidthPx: outlineWidthPx,
        rimLobePx: rimLobePx,
        slots: <WheelSlotPlacement>[
          for (final WheelSlotPlacement slot in slots)
            WheelSlotPlacement(
              index: slot.index,
              entry: slot.entry,
              offsetAngleDeg: slot.offsetAngleDeg,
              absoluteAngleDeg: slot.absoluteAngleDeg,
              centerX: slot.centerX + dx,
              centerY: slot.centerY + dy,
            ),
        ],
        actualScale: actualScale,
        compact: compact,
        degraded: degraded,
      );

  double absoluteAngleFor(int index) {
    for (final WheelSlotPlacement slot in slots) {
      if (slot.index == index) return slot.absoluteAngleDeg;
    }
    return _baseAngle();
  }

  double _baseAngle() =>
      direction == WheelExpandDirection.right ? 0 : 180;

  @override
  String toString() => 'WheelMenuLayout($itemCount项 ${direction.name} '
      'r=${ringRadiusPx.toInt()} step=${stepDeg.toStringAsFixed(1)}° win=$windowRect)';
}

// ---------------------------------------------------------------------------
// 文字安全带
// ---------------------------------------------------------------------------

/// 主扇区里三层文字的**纯布局**。
class WheelTextSlots {
  const WheelTextSlots({
    required this.bandStart,
    required this.bandEnd,
    required this.titleRadius,
    required this.chipRadius,
    required this.infoRadius,
    required this.titleSizePx,
    required this.chipSizePx,
    required this.infoSizePx,
    required this.titleMaxWidth,
    required this.chipMaxWidth,
    required this.infoMaxWidth,
  });

  final double bandStart;
  final double bandEnd;
  final double titleRadius;
  final double chipRadius;
  final double infoRadius;
  final double titleSizePx;
  final double chipSizePx;
  final double infoSizePx;
  final double titleMaxWidth;
  final double chipMaxWidth;
  final double infoMaxWidth;
}

/// 三层文字的半径比例与弦宽（Android `WheelTextLayout` 1:1）。
class WheelTextLayout {
  WheelTextLayout._();

  static const double titleRadiusRatio = 0.30;
  static const double chipRadiusRatio = 0.72;
  static const double infoRadiusRatio = 0.93;
  static const double titleSizeRatio = 0.30;
  static const double chordSafety = 0.78;

  /// 文字安全带与按钮圆之间的净空（dp）。
  static const double textBandGapDp = 4;

  /// 中文名的基准字号（sp）。
  static const double minChipSp = 16;

  static WheelTextSlots compute(
    WheelMenuLayout layout,
    double density,
    double minTitleSp,
    double minChipSp,
    double minInfoSp,
  ) {
    final double d = WheelMenuSpec.safeDensity(density);
    final double bandStart =
        layout.ringRadiusPx + layout.buttonDiameterPx * 0.5 + d * textBandGapDp;
    final double bandEnd = math.max(layout.bladeLengthPx, bandStart + 1);
    final double band = bandEnd - bandStart;
    final double titleRadius = bandStart + band * titleRadiusRatio;
    final double chipRadius = bandStart + band * chipRadiusRatio;
    final double infoRadius = bandStart + band * infoRadiusRatio;
    final double titleSize = math.max(band * titleSizeRatio, minTitleSp * d);
    final double chipSize = math.max(layout.buttonDiameterPx * 0.42, minChipSp * d);
    final double infoSize = math.max(layout.buttonDiameterPx * 0.27, minInfoSp * d);
    return WheelTextSlots(
      bandStart: bandStart,
      bandEnd: bandEnd,
      titleRadius: titleRadius,
      chipRadius: chipRadius,
      infoRadius: infoRadius,
      titleSizePx: titleSize,
      chipSizePx: chipSize,
      infoSizePx: infoSize,
      titleMaxWidth: chordAt(layout, titleRadius),
      chipMaxWidth: chordAt(layout, chipRadius),
      infoMaxWidth: chordAt(layout, infoRadius),
    );
  }

  /// 半径 [radius] 处、扇形张角内的可用宽度。
  static double chordAt(WheelMenuLayout layout, double radius) =>
      2 *
      radius *
      math.sin(_rad(layout.bladeHalfSweepDeg * chordSafety));

  static double _rad(double deg) => deg * math.pi / 180.0;
}

// ---------------------------------------------------------------------------
// 几何求解（纯函数）
// ---------------------------------------------------------------------------

/// 参数化几何（**纯函数**，不碰 WindowManager / View）。
class WheelMenuGeometry {
  WheelMenuGeometry._();

  /// 角度间隔的下界。
  static const double minStepDeg = 16;

  /// 角度间隔的上界。
  static const double maxStepDeg = 30;

  /// 扇形半张角的上界（普通 / 紧凑）。
  static const double maxHalfSpanDeg = 68;
  static const double compactHalfSpanDeg = 50;

  /// 紧凑模式下扇形半张角的下限。
  static const double minHalfSpanDeg = 38;

  /// 高亮扇区的半张角。
  static const double bladeHalfSweepDeg = 30;

  static const double _bladeExtentRatio = 0.42;
  static const double bladeExtentMinDp = 40;
  static const double bladeExtentMaxDp = 88;

  /// 半径的绝对下界。
  static const double minRadiusDp = 62;

  /// 缺口相对桌宠可见尺寸的比例。
  static const double holeWidthRatio = 1.05;
  static const double holeHeightRatio = 1.05;

  /// 缺口相对桌宠可见尺寸的额外边距（dp）。
  static const double notchPaddingDp = 10;

  /// 缺口相对"按钮轨道内径"的上限比例（防"粗甜甜圈"回归）。
  static const double notchMaxInnerDiameterRatio = 0.88;

  /// 缺口与按钮之间必须保留的净空（dp）。
  static const double _holeMarginDp = 4;

  /// 窗口相对绘制内容的额外安全边距（dp）。
  static const double safetyPaddingDp = 10;

  /// 实际缩放的下限。
  static const double minActualScale = 0.60;

  /// 垂直模式滞回（相对安全区域高度的比例）。
  static const double _verticalHysteresis = 0.06;

  /// 方向滞回。
  static const double _directionHysteresis = 0.08;

  /// 窗口相对安全区域的建议上限（超出即触发紧凑模式）。
  static const double _maxWindowWidthRatio = 0.65;
  static const double _maxWindowHeightRatio = 0.70;
  static const double _maxWindowWidthRatioCompact = 0.55;
  static const double _maxWindowHeightRatioCompact = 0.60;

  /// 桌宠可见边界不可信时的兜底比例。
  static const double _fallbackVisibleRatio = 0.86;

  /// 紧凑模式下按钮视觉直径的收缩比例。
  static const double _compactButtonShrink = 0.92;

  // ------------------------------------------------------------------
  // 方向与垂直模式
  // ------------------------------------------------------------------

  static WheelExpandDirection decideDirection(
    WheelRect petRect,
    WheelBounds bounds,
    WheelExpandDirection? previousDirection,
    bool locked,
  ) {
    if (locked && previousDirection != null) return previousDirection;
    if (!bounds.isUsable || !petRect.isUsable) return WheelExpandDirection.right;
    final double leftSpace = petRect.centerX - bounds.left;
    final double rightSpace = bounds.right - petRect.centerX;
    final WheelExpandDirection natural =
        rightSpace >= leftSpace ? WheelExpandDirection.right : WheelExpandDirection.left;
    final WheelExpandDirection? previous = previousDirection;
    if (previous == null) return natural;
    final double deadZone = (bounds.width * _directionHysteresis).roundToDouble();
    final double mid = bounds.left + bounds.width / 2;
    switch (previous) {
      case WheelExpandDirection.right:
        return petRect.centerX <= mid + deadZone ? previous : WheelExpandDirection.left;
      case WheelExpandDirection.left:
        return petRect.centerX >= mid - deadZone ? previous : WheelExpandDirection.right;
    }
  }

  static WheelVerticalMode decideVerticalMode(
    WheelRect petVisible,
    WheelBounds bounds,
    WheelVerticalMode? previous,
    bool locked,
  ) {
    if (locked && previous != null) return previous;
    if (!bounds.isUsable || !petVisible.isUsable) return WheelVerticalMode.center;
    final double above = petVisible.centerY - bounds.top;
    final double below = bounds.bottom - petVisible.centerY;
    final WheelVerticalMode natural;
    if (above < below * 0.55) {
      natural = WheelVerticalMode.topEdge;
    } else if (below < above * 0.55) {
      natural = WheelVerticalMode.bottomEdge;
    } else {
      natural = WheelVerticalMode.center;
    }
    final WheelVerticalMode? prev = previous;
    if (prev == null) return natural;
    final double deadZone = (bounds.height * _verticalHysteresis).roundToDouble();
    switch (prev) {
      case WheelVerticalMode.center:
        if (natural == WheelVerticalMode.center) return prev;
        return (above - below).abs() > deadZone ? natural : prev;
      case WheelVerticalMode.topEdge:
        return above > deadZone * 2 ? natural : prev;
      case WheelVerticalMode.bottomEdge:
        return below > deadZone * 2 ? natural : prev;
    }
  }

  // ------------------------------------------------------------------
  // 桌宠可见边界
  // ------------------------------------------------------------------

  /// 桌宠的**视觉**矩形（屏幕绝对坐标）；素材带透明留白时按 alpha 包围盒裁掉。
  ///
  /// C1.1 修正的缺陷（真机验收根因之一）
  /// --------------------------------
  /// 旧实现把兜底比例 0.86 当成**下限**（`max(measured, 0.86×widget)`），
  /// 于是"实测可见 92×156"被抬回 220×165 —— 与"直接用整张素材"几乎没有区别，
  /// 缺口核半径凭空放大 2.4 倍、中心还偏 18px。
  ///
  /// `docs/37` 的本意是"**素材几乎全透明时**"才用 0.86 兜底。因此现在的口径：
  ///
  /// * [content] 为 null（从未测量）→ 按整张素材（= Android 的 `FULL` 口径），
  ///   调用方应在此之前 `await ensureVisualBounds()`；
  /// * [content] 存在但退化（span < [PetVisualBounds.minSpanRatio]，
  ///   即"几乎全透明"）→ 用 0.86 兜底；
  /// * [content] 存在且合理 → **原样采信**，绝不放大。
  static WheelRect petVisibleRect(
    WheelRect petWindowRect,
    WheelContentBounds? content,
  ) {
    if (!petWindowRect.isUsable) return petWindowRect;
    if (content == null) return petWindowRect;
    final WheelRect rect = WheelContentBounds.toScreenRect(petWindowRect, content);
    if (!rect.isUsable) return petWindowRect;

    // "几乎全透明"才兜底（docs/37 的原意）。
    final PetVisualBounds probe = PetVisualBounds(
      content.left,
      content.top,
      content.right,
      content.bottom,
    );
    final bool degenerate = rect.width < petWindowRect.width * PetVisualBounds.minSpanRatio ||
        rect.height < petWindowRect.height * PetVisualBounds.minSpanRatio;
    if (!degenerate && probe.width > 0 && probe.height > 0) return rect;

    final double fallbackWidth =
        (petWindowRect.width * _fallbackVisibleRatio).roundToDouble();
    final double fallbackHeight =
        (petWindowRect.height * _fallbackVisibleRatio).roundToDouble();
    final double cx = rect.centerX;
    final double cy = rect.centerY;
    final double left = (cx - fallbackWidth / 2)
        .roundToDouble()
        .clamp(petWindowRect.left, petWindowRect.right);
    final double top = (cy - fallbackHeight / 2)
        .roundToDouble()
        .clamp(petWindowRect.top, petWindowRect.bottom);
    return WheelRect(left, top, left + fallbackWidth, top + fallbackHeight);
  }

  /// 桌宠的**抓取区**（中心正方形）。
  static WheelRect petGrabRect(WheelRect petRect) {
    final double side =
        math.max(48, (math.min(petRect.width, petRect.height) * 0.5).roundToDouble());
    return WheelRect.centered(petRect.centerX, petRect.centerY, side);
  }

  // ------------------------------------------------------------------
  // 信封
  // ------------------------------------------------------------------

  /// **方向决议的唯一入口**（真机回归「左右展开完全反向」的修复）。
  ///
  /// 与直接调用 [computeEnvelope] 的区别：本方法在算完之后**校验方向不变量**
  /// （菜单中心确实在期望一侧 + 菜单不出 workArea），不通过就用**相反方向**重算，
  /// 只有相反方向也无效时才退回"不出工作区优先"的那一侧。
  ///
  /// 所有输入都是**屏幕坐标**（`petWindowRect` 与 [WheelBounds] 同空间），
  /// 严禁传入画布局部坐标（见需求 §2 的禁止项）。
  static WheelExpansionResolution resolveExpansion({
    required WheelBounds bounds,
    required WheelRect petWindowRect,
    WheelContentBounds? content,
    required int maxItemCount,
    required WheelMenuSpec spec,
    required WheelMenuLayoutSettings settings,
    WheelExpandDirection? previousDirection,
    WheelVerticalMode? previousVerticalMode,
    double? previousPetCenterX,
  }) {
    final WheelMenuLayoutSettings normalized = settings.normalized();
    final WheelRect visible = petVisibleRect(petWindowRect, content);
    final int count = math.max(1, maxItemCount);
    final WheelIntrinsicLayout intrinsic = intrinsicLayout(
      itemCount: count,
      spec: spec,
      settings: normalized,
      petVisibleWidth: visible.width,
      petVisibleHeight: visible.height,
    );

    // 「单侧所需宽度」取自**固有布局的绘制半宽**，与随后真正画出来的东西同源。
    final double requiredWidth = WheelMenuWidthBudget.requiredWidthFor(
      windowWidthPx: intrinsic.halfWidthPx * 2,
      petVisibleWidthPx: visible.width,
      menuDistanceRatio: normalized.menuDistance,
    );

    final WheelDirectionDecision decision = WheelDirectionPolicy.decide(
      WheelDirectionInput(
        petScreenRect: _screenRectOf(petWindowRect),
        workArea: _screenRectOfBounds(bounds),
        menuRequiredWidthPx: requiredWidth,
        previousSide: previousDirection == null
            ? null
            : WheelExpansionSideCodec.fromWireName(previousDirection.name),
        previousPetCenterX: previousPetCenterX,
      ),
    );
    final WheelExpansionSide requested = decision.side;

    final _SideAttempt first = _attempt(
      side: requested,
      bounds: bounds,
      petWindowRect: petWindowRect,
      content: content,
      maxItemCount: count,
      spec: spec,
      settings: normalized,
      previousVerticalMode: previousVerticalMode,
    );
    if (first.invariant.passed) {
      return WheelExpansionResolution(
        envelope: first.envelope,
        side: requested,
        requestedSide: requested,
        decision: decision,
        invariant: first.invariant,
        oppositeInvariant: null,
        retriedOpposite: false,
        fallbackReason: 'ok',
      );
    }

    // 首选侧违反不变量 → 试相反方向。
    final WheelExpansionSide opposite = requested.opposite;
    final _SideAttempt second = _attempt(
      side: opposite,
      bounds: bounds,
      petWindowRect: petWindowRect,
      content: content,
      maxItemCount: count,
      spec: spec,
      settings: normalized,
      previousVerticalMode: previousVerticalMode,
    );
    if (second.invariant.passed) {
      return WheelExpansionResolution(
        envelope: second.envelope,
        side: opposite,
        requestedSide: requested,
        decision: decision,
        invariant: first.invariant,
        oppositeInvariant: second.invariant,
        retriedOpposite: true,
        fallbackReason: 'opposite_side_valid',
      );
    }

    // 两侧都不通过 → 优先"不出工作区"的那一侧（其次优先"方向正确"的那一侧）。
    final bool preferFirst = _better(first.invariant, second.invariant);
    final _SideAttempt chosen = preferFirst ? first : second;
    final WheelExpansionSide chosenSide = preferFirst ? requested : opposite;
    return WheelExpansionResolution(
      envelope: chosen.envelope,
      side: chosenSide,
      requestedSide: requested,
      decision: decision,
      invariant: first.invariant,
      oppositeInvariant: second.invariant,
      retriedOpposite: !preferFirst,
      fallbackReason: 'both_sides_invalid_prefer_'
          '${preferFirst ? 'requested' : 'opposite'}',
    );
  }

  /// 用指定方向算一次信封 + 检查方向不变量。
  static _SideAttempt _attempt({
    required WheelExpansionSide side,
    required WheelBounds bounds,
    required WheelRect petWindowRect,
    WheelContentBounds? content,
    required int maxItemCount,
    required WheelMenuSpec spec,
    required WheelMenuLayoutSettings settings,
    WheelVerticalMode? previousVerticalMode,
  }) {
    final WheelExpandDirection direction = _toGeometryDirection(side);
    final WheelMenuEnvelope envelope = computeEnvelope(
      bounds: bounds,
      petWindowRect: petWindowRect,
      content: content,
      maxItemCount: maxItemCount,
      spec: spec,
      settings: settings,
      previousDirection: direction,
      previousVerticalMode: previousVerticalMode,
      lockMode: true, // 方向已经定了，禁止 decideDirection 再改
    );
    // 扇形中心（**屏幕坐标**）：`envelope.centerX` 已经是绝对坐标
    // （= 人物中心 ± 偏移，与 Android `_plan` 的 `centerX` 同口径），
    // 不能再叠加 `windowRect.left`。
    final WheelRect visible = petVisibleRect(petWindowRect, content);
    final double arcHalfSpanDeg = _arcHalfSpanOf(
      itemCount: maxItemCount,
      spec: spec,
      settings: settings,
      visible: visible,
    );
    final WheelDirectionInvariant invariant = WheelDirectionInvariants.evaluate(
      side: side,
      menuScreenBounds: _screenRectOf(envelope.windowRect),
      menuCenterScreenX: envelope.centerX,
      arcHalfSpanDeg: arcHalfSpanDeg,
      petScreenRect: _screenRectOf(visible),
      workArea: _screenRectOfBounds(bounds),
    );
    return _SideAttempt(envelope: envelope, invariant: invariant);
  }

  /// 取扇形半跨度（与 `intrinsicLayout` 同源）。
  static double _arcHalfSpanOf({
    required int itemCount,
    required WheelMenuSpec spec,
    required WheelMenuLayoutSettings settings,
    required WheelRect visible,
  }) {
    final WheelIntrinsicLayout intrinsic = intrinsicLayout(
      itemCount: math.max(1, itemCount),
      spec: spec,
      settings: settings,
      petVisibleWidth: visible.width,
      petVisibleHeight: visible.height,
    );
    return intrinsic.fanHalfSpanDeg;
  }

  /// 哪个尝试更可接受：优先"不出工作区"，其次"扇形中心在正确一侧"。
  static bool _better(
    WheelDirectionInvariant a,
    WheelDirectionInvariant b,
  ) {
    if (a.insideWorkArea != b.insideWorkArea) return a.insideWorkArea;
    if (a.centerOnSide != b.centerOnSide) return a.centerOnSide;
    return true; // 完全同质 → 保留首选侧
  }

  /// 唯一的方向枚举换算（1:1，含义逐字一致）。
  static WheelExpandDirection _toGeometryDirection(WheelExpansionSide side) =>
      side.isLeft ? WheelExpandDirection.left : WheelExpandDirection.right;

  static Rect _screenRectOf(WheelRect r) =>
      Rect.fromLTWH(r.left, r.top, r.width, r.height);

  static Rect _screenRectOfBounds(WheelBounds b) =>
      Rect.fromLTWH(b.left, b.top, b.width, b.height);

  static WheelMenuEnvelope computeEnvelope({
    required WheelBounds bounds,
    required WheelRect petWindowRect,
    WheelContentBounds? content,
    required int maxItemCount,
    required WheelMenuSpec spec,
    required WheelMenuLayoutSettings settings,
    WheelExpandDirection? previousDirection,
    WheelVerticalMode? previousVerticalMode,
    bool lockMode = false,
  }) {
    final WheelMenuLayoutSettings normalized = settings.normalized();
    final WheelRect visible = petVisibleRect(petWindowRect, content);
    final int count = math.max(1, maxItemCount);
    final WheelExpandDirection direction =
        decideDirection(visible, bounds, previousDirection, lockMode);
    final WheelVerticalMode vertical =
        decideVerticalMode(visible, bounds, previousVerticalMode, lockMode);
    final double anchorX = visible.centerX;
    final double anchorY = visible.centerY;
    final double allowedOffset =
        math.max(visible.width * normalized.menuDistance, spec.dp(_holeMarginDp));
    final double offset = allowedOffset;

    if (!bounds.isUsable || !visible.isUsable) {
      return _degenerateEnvelope(
        bounds,
        visible,
        direction,
        vertical,
        0,
        0,
        allowedOffset,
        normalized,
        spec,
      );
    }

    // 1) 固有几何：只看设置与桌宠尺寸，与位置/剩余空间无关。
    final WheelIntrinsicLayout intrinsic = intrinsicLayout(
      itemCount: count,
      spec: spec,
      settings: normalized,
      petVisibleWidth: visible.width,
      petVisibleHeight: visible.height,
    );
    // 2) 设备级应急缩放：只由"屏幕 + 固有尺寸"决定；用户把轮盘调**大**时一律不缩回。
    final double deviceScale =
        normalized.preferredScale > WheelMenuLayoutSettings.defaultScale
            ? 1.0
            : deviceEmergencyScale(bounds, intrinsic);
    // 3) 放置：只选方向、平移窗口、必要时裁装饰 —— 不改任何尺寸。
    final _WheelPlan? plan = _plan(
      bounds: bounds,
      direction: direction,
      vertical: vertical,
      anchorX: anchorX,
      anchorY: anchorY,
      intrinsic: intrinsic,
      offset: offset,
      scale: deviceScale,
      spec: spec,
    );
    if (plan == null) {
      return _forcedEnvelope(
        bounds: bounds,
        intrinsic: intrinsic,
        direction: direction,
        vertical: vertical,
        anchorX: anchorX,
        anchorY: anchorY,
        offset: offset,
        spec: spec,
        settings: normalized,
      );
    }
    final bool degraded = !plan.fits;
    return plan.toEnvelope(
      normalized,
      degraded: degraded,
      reason: degraded ? 'window-clamped' : null,
    );
  }

  /// 轮盘**固有几何**：输入里**没有**桌宠坐标 / 左右剩余空间 / 离边距离。
  static WheelIntrinsicLayout intrinsicLayout({
    required int itemCount,
    required WheelMenuSpec spec,
    required WheelMenuLayoutSettings settings,
    required double petVisibleWidth,
    required double petVisibleHeight,
  }) {
    final WheelMenuLayoutSettings normalized = settings.normalized();
    final int count = math.max(1, itemCount);
    final bool compact = normalized.compactMode;
    final double halfSpan = halfSpanFor(count, compact);
    final double step = stepDegFor(count, halfSpan);
    final double effectiveScale =
        normalized.preferredScale * (compact ? _compactButtonShrink : 1);
    // 按钮大小设置的**唯一落点**。
    final double buttonDiameter =
        spec.buttonDiameterFor(count, effectiveScale * normalized.buttonVisualScale);
    final double buttonRadius = buttonDiameter / 2;
    final double padding = spec.dp(notchPaddingDp);
    // 缺口由桌宠可见尺寸决定（含边距）；保留**未夹取**的原始值。
    final double notchRxRaw = petVisibleWidth * holeWidthRatio / 2 + padding;
    final double notchRyRaw = petVisibleHeight * holeHeightRatio / 2 + padding;
    final double minRadiusForNotch =
        math.max(notchRxRaw, notchRyRaw) / notchMaxInnerDiameterRatio + buttonRadius;
    final double spacing = spacingRadiusPx(count, step, buttonDiameter, spec);
    final double margin = spec.dp(_holeMarginDp);
    final double clearance =
        math.sqrt(math.pow(petVisibleWidth / 2, 2) + math.pow(petVisibleHeight / 2, 2)) +
            petVisibleWidth * normalized.menuDistance +
            buttonRadius +
            margin;
    final double ringRadius = math.max(
      math.max(spacing, minRadiusForNotch),
      math.max(clearance, spec.dp(minRadiusDp)),
    );
    final double bandOuter = ringRadius + buttonRadius + spec.bandPaddingPx;
    final double rimOuter = bandOuter + spec.rimLobePx;
    final double bladeExtent = (_bladeExtentRatio * ringRadius)
        .clamp(spec.dp(bladeExtentMinDp), spec.dp(bladeExtentMaxDp));
    final double bladeLength = rimOuter +
        bladeExtent *
            normalized.preferredScale
                .clamp(WheelMenuLayoutSettings.minScale, WheelMenuLayoutSettings.maxScale);

    // 绘制包围盒半宽/半高（相对轮盘中心，用于设备级应急缩放）。
    final double reachDeg = halfSpan + bladeHalfSweepDeg + kEdgeFanBiasDeg.abs();
    final double outward = math.max(bladeLength, rimOuter);
    final double inwardFactor =
        reachDeg > 90 ? -math.cos(_rad(math.min(180, reachDeg))) : 0;
    final double safety = spec.dp(safetyPaddingDp);
    final double halfW = (outward + outward * inwardFactor) / 2 + safety;
    final double halfH = outward * math.sin(_rad(math.min(90, reachDeg))) + safety;
    return WheelIntrinsicLayout(
      itemCount: count,
      ringRadiusPx: ringRadius,
      buttonDiameterPx: buttonDiameter,
      bandOuterPx: bandOuter,
      rimOuterPx: rimOuter,
      bladeLengthPx: bladeLength,
      bladeHalfSweepDeg: bladeHalfSweepDeg,
      stepDeg: step,
      fanHalfSpanDeg: halfSpan,
      outlineWidthPx: spec.outlineWidthFor(spec.outlinePx, normalized.preferredScale),
      rimLobePx: spec.rimLobePx,
      compact: compact,
      notchRx: notchRxRaw,
      notchRy: notchRyRaw,
      halfWidthPx: halfW,
      halfHeightPx: halfH,
    );
  }

  /// 设备级应急缩放：只在"整块屏幕在任何方向都放不下"时才 < 1。
  static double deviceEmergencyScale(WheelBounds bounds, WheelIntrinsicLayout intrinsic) {
    if (!bounds.isUsable) return minActualScale;
    final double needW = intrinsic.halfWidthPx * 2;
    final double needH = intrinsic.halfHeightPx * 2;
    if (needW <= 0 || needH <= 0) return 1.0;
    final double byWidth = bounds.width / needW;
    final double byHeight = bounds.height / needH;
    return math.min(1.0, math.min(byWidth, byHeight)).clamp(minActualScale, 1.0);
  }

  /// 测量用的**合成层级**（条目数决定按钮直径与扇形张角）。
  ///
  /// 规划 / 诊断 / 测试共用同一个入口 —— 不允许各自再造一个"近似的层级"，
  /// 否则测量与绘制又会分家（C1.1 §七 的教训）。
  static MenuLevel probeLevelFor(int itemCount) => MenuLevel(
        id: '__probe__',
        titleZh: 'probe',
        titleEn: 'PROBE',
        nodes: <MenuNode>[
          for (int i = 0; i < itemCount; i++)
            MenuNode(id: 'probe_$i', actionId: 'probe_$i', labelZh: '测量项$i'),
        ],
      );

  /// 一次**只读**几何测量：给定人物矩形 + alpha 边界 + 设置，算出
  /// 方向决议 / 缺口 / 环半径 / 布局。
  ///
  /// 与 `FixedCanvasProbe.open()` **同一条**生产链路（`resolveExpansion`
  /// → `layoutFor`），因此诊断 / 规划 / 测试拿到的数字就是真机会用的数字。
  static WheelGeometryMeasurement measure({
    required WheelRect petWidgetRect,
    required PetVisualBounds bounds,
    required WheelMenuLayoutSettings settings,
    required int maxItemCount,
    required WheelBounds workArea,
    required WheelMenuSpec spec,
    WheelExpandDirection? previousDirection,
    WheelVerticalMode? previousVerticalMode,
    double? previousPetCenterX,
  }) {
    final WheelExpansionResolution resolution = resolveExpansion(
      bounds: workArea,
      petWindowRect: petWidgetRect,
      content: WheelContentBounds(
        bounds.left,
        bounds.top,
        bounds.right,
        bounds.bottom,
      ),
      maxItemCount: maxItemCount,
      spec: spec,
      settings: settings,
      previousDirection: previousDirection,
      previousVerticalMode: previousVerticalMode,
      previousPetCenterX: previousPetCenterX,
    );
    final WheelMenuEnvelope envelope = resolution.envelope;
    final WheelMenuLayout layout = layoutFor(
      envelope,
      probeLevelFor(maxItemCount),
      spec,
    );
    final WheelRect visible = petVisibleRect(
      petWidgetRect,
      WheelContentBounds(
        bounds.left,
        bounds.top,
        bounds.right,
        bounds.bottom,
      ),
    );
    return WheelGeometryMeasurement(
      side: resolution.side,
      invariantPassed: resolution.invariant.passed,
      petAnchorX: envelope.petAnchorX,
      petAnchorY: envelope.petAnchorY,
      holeRx: envelope.holeRx,
      holeRy: envelope.holeRy,
      ringRadiusPx: envelope.maxRingRadiusPx,
      buttonDiameterPx: envelope.buttonDiameterPx,
      offsetPx: envelope.allowedOffsetPx,
      envelope: envelope,
      layout: layout,
      intrinsic: intrinsicLayout(
        itemCount: maxItemCount,
        spec: spec,
        settings: settings,
        petVisibleWidth: visible.width,
        petVisibleHeight: visible.height,
      ),
    );
  }

  /// 某一层级在既定信封内的实际几何（**只读信封，绝不改窗口**）。
  static WheelMenuLayout layoutFor(
    WheelMenuEnvelope envelope,
    MenuLevel level,
    WheelMenuSpec spec,
  ) {
    final int count = math.max(1, level.itemCount);
    final bool compact = envelope.compact;
    final double halfSpan = halfSpanFor(count, compact);
    final double step = stepDegFor(count, halfSpan);
    final double radius = envelope.maxRingRadiusPx;
    final double button = envelope.buttonDiameterPx;
    final double bandOuter = radius + button / 2 + spec.bandPaddingPx;
    final double rimOuter = bandOuter + spec.rimLobePx;
    final double bladeExtent = (_bladeExtentRatio * radius)
        .clamp(spec.dp(bladeExtentMinDp), spec.dp(bladeExtentMaxDp));
    final double bladeLength = rimOuter + bladeExtent * envelope.actualScale.clamp(0.6, 1.2);

    final WheelRect window = envelope.windowRect;
    final double cx = envelope.centerX - window.left;
    final double cy = envelope.centerY - window.top;
    // 缺口中心 = 桌宠视觉锚点（窗口坐标系）。
    final double notchCx = envelope.petAnchorX - window.left;
    final double notchCy = envelope.petAnchorY - window.top;
    final double half = (count - 1) / 2;
    final List<WheelSlotPlacement> slots = <WheelSlotPlacement>[];
    for (int index = 0; index < level.nodes.length; index++) {
      final MenuNode entry = level.nodes[index];
      final double offsetAngle = (index - half) * step;
      final double absolute =
          absoluteAngle(envelope.direction, offsetAngle + envelope.fanBiasDeg);
      final double rad = _rad(absolute);
      slots.add(WheelSlotPlacement(
        index: index,
        entry: entry,
        offsetAngleDeg: offsetAngle,
        absoluteAngleDeg: normalizeAngle(absolute),
        centerX: cx + radius * math.cos(rad),
        centerY: cy + radius * math.sin(rad),
      ));
    }
    return WheelMenuLayout(
      direction: envelope.direction,
      verticalMode: envelope.verticalMode,
      itemCount: count,
      windowRect: window,
      centerX: cx,
      centerY: cy,
      ringRadiusPx: radius,
      bandOuterPx: bandOuter,
      notchCenterX: notchCx,
      notchCenterY: notchCy,
      notchRx: envelope.holeRx,
      notchRy: envelope.holeRy,
      bladeLengthPx: bladeLength,
      bladeHalfSweepDeg: bladeHalfSweepDeg,
      stepDeg: step,
      fanHalfSpanDeg: halfSpan,
      fanBiasDeg: envelope.fanBiasDeg,
      buttonDiameterPx: button,
      buttonTouchDiameterPx: math.max(
        button,
        spec.dp(WheelMenuLayoutSettings.buttonTouchMinDp),
      ),
      outlineWidthPx: spec.outlineWidthFor(spec.outlinePx, envelope.actualScale),
      rimLobePx: spec.rimLobePx,
      slots: slots,
      actualScale: envelope.actualScale,
      compact: compact,
      degraded: envelope.degraded,
    );
  }

  /// 相邻按钮的角度间隔。
  static double stepDegFor(int itemCount, [double halfSpanDeg = maxHalfSpanDeg]) {
    if (itemCount <= 1) return 0;
    final double raw = halfSpanDeg * 2 / (itemCount - 1);
    return raw.clamp(minStepDeg, maxStepDeg);
  }

  /// 扇形半张角（紧凑模式更窄）。
  static double halfSpanFor(int itemCount, bool compact) {
    final double base = compact ? compactHalfSpanDeg : maxHalfSpanDeg;
    if (itemCount <= 1) return 0;
    final double needed = minStepDeg * (itemCount - 1) / 2;
    return math.max(base, math.min(needed, maxHalfSpanDeg));
  }

  /// "相邻按钮不重叠"推出的半径下界。
  static double spacingRadiusPx(
    int itemCount,
    double stepDeg,
    double buttonDiameter,
    WheelMenuSpec spec,
  ) {
    if (itemCount <= 1 || stepDeg <= 0) return 0;
    final double chordUnit = 2 * math.sin(_rad(stepDeg / 2));
    if (chordUnit <= 0) return 0;
    return (buttonDiameter + spec.buttonGapPx) / chordUnit;
  }

  /// 桌宠可见矩形到轮盘中心的**最近允许半径**。
  static double petClearanceRadius(
    WheelRect visible,
    double offset,
    double buttonRadius,
    double margin,
  ) {
    if (!visible.isUsable) return 0;
    final double cx = visible.centerX;
    final double cy = visible.centerY;
    final List<List<double>> corners = <List<double>>[
      <double>[visible.left, visible.top],
      <double>[visible.right, visible.top],
      <double>[visible.left, visible.bottom],
      <double>[visible.right, visible.bottom],
    ];
    double farthest = 0;
    for (final List<double> corner in corners) {
      final double distance =
          math.sqrt(math.pow(corner[0] - cx, 2) + math.pow(corner[1] - cy, 2));
      if (distance > farthest) farthest = distance;
    }
    return farthest + offset + buttonRadius + margin;
  }

  // ------------------------------------------------------------------
  // 角度换算
  // ------------------------------------------------------------------

  /// 把**相对展开轴**的角度换算成屏幕绝对角度（镜像时**取反**）。
  static double absoluteAngle(WheelExpandDirection direction, double offsetAngleDeg) =>
      normalizeAngle(_baseAngle(direction) + direction.sign * offsetAngleDeg);

  /// 绝对角度 → **连续的槽位下标**（0.0 = 第一项）。
  static double rawIndexAt(WheelMenuLayout layout, double absoluteAngleDeg) {
    if (layout.itemCount <= 1 || layout.stepDeg <= 0) return 0;
    final double offset =
        normalizeAngle(absoluteAngleDeg - _baseAngle(layout.direction)) * layout.direction.sign;
    return (offset - layout.fanBiasDeg) / layout.stepDeg + (layout.itemCount - 1) / 2;
  }

  /// 归一到 `(-180, 180]`。
  static double normalizeAngle(double deg) {
    double value = deg % 360;
    if (value > 180) value -= 360;
    if (value <= -180) value += 360;
    return value;
  }

  static double _baseAngle(WheelExpandDirection direction) =>
      direction == WheelExpandDirection.right ? 0 : 180;

  static double _rad(double deg) => deg * math.pi / 180.0;

  // ------------------------------------------------------------------
  // 求解器内部
  // ------------------------------------------------------------------

  static _WheelPlan? _plan({
    required WheelBounds bounds,
    required WheelExpandDirection direction,
    required WheelVerticalMode vertical,
    required double anchorX,
    required double anchorY,
    required WheelIntrinsicLayout intrinsic,
    required double offset,
    required double scale,
    required WheelMenuSpec spec,
  }) {
    final bool compact = intrinsic.compact;
    final double halfSpan = intrinsic.fanHalfSpanDeg;
    // 尺寸全部来自固有几何（只乘设备级应急缩放）——放置阶段不得改尺寸。
    final double buttonDiameter = intrinsic.buttonDiameterPx * scale;
    final double buttonRadius = buttonDiameter / 2;
    // 缺口由桌宠可见尺寸决定，也**不乘应急缩放**。
    final double notchRx = intrinsic.notchRx;
    final double notchRy = intrinsic.notchRy;
    // 反过来：环带必须始终"容得下"这个缺口。
    final double notchHost =
        math.max(notchRx, notchRy) / notchMaxInnerDiameterRatio + buttonRadius;
    final double ringRadius = math.max(intrinsic.ringRadiusPx * scale, notchHost);
    final double bandOuter = ringRadius + buttonRadius + spec.bandPaddingPx * scale;
    final double rimOuter = bandOuter + intrinsic.rimLobePx * scale;
    final double bladeLength =
        rimOuter + (intrinsic.bladeLengthPx - intrinsic.rimOuterPx) * scale;
    final double margin = spec.dp(_holeMarginDp);
    final double bias = vertical.biasDeg;

    final double centerX = (direction == WheelExpandDirection.right
            ? anchorX + offset
            : anchorX - offset)
        .roundToDouble();
    final double centerY = anchorY;

    final int sign = direction.sign;
    final double base = _baseAngle(direction);
    double left = double.maxFinite;
    double right = -double.maxFinite;
    double top = double.maxFinite;
    double bottom = -double.maxFinite;

    void include(double x, double y) {
      if (x < left) left = x;
      if (x > right) right = x;
      if (y < top) top = y;
      if (y > bottom) bottom = y;
    }

    // 环带外圈：沿扇形从一端采样到另一端（步长 4°）。
    double t = -halfSpan + bias;
    final double upper = halfSpan + bias;
    while (t <= upper + 0.001) {
      final double rad = _rad(base + sign * t);
      include(centerX + rimOuter * math.cos(rad), centerY + rimOuter * math.sin(rad));
      t += 4;
    }
    // 刀刃（跟随选中槽位，端点槽位最极端）
    for (final double slotOffset in <double>[-halfSpan + bias, halfSpan + bias]) {
      for (final double delta in <double>[-bladeHalfSweepDeg, 0, bladeHalfSweepDeg]) {
        final double rad = _rad(base + sign * (slotOffset + delta));
        include(centerX + bladeLength * math.cos(rad), centerY + bladeLength * math.sin(rad));
      }
    }
    // 环带 + 刀刃的包围盒：**"放不放得下"只看它**。
    final WheelRect ringBladeBox = WheelRect.of(left, top, right, bottom);

    // 中央缺口（绑在桌宠锚点上）—— 用来扩大窗口，保证缺口边界可见。
    include(anchorX - notchRx - margin, anchorY - notchRy - margin);
    include(anchorX + notchRx + margin, anchorY + notchRy + margin);

    // 把**旋转后的文字 AABB** 也算进窗口包围盒。
    {
      final double bandStart =
          ringRadius + buttonRadius + spec.dp(WheelTextLayout.textBandGapDp);
      final double bandEnd = math.max(bladeLength, bandStart + 1);
      final double chipRadius =
          bandStart + (bandEnd - bandStart) * WheelTextLayout.chipRadiusRatio;
      final double chipSize =
          math.max(buttonDiameter * 0.42, WheelTextLayout.minChipSp * spec.density);
      final int maxChars = _maxLabelChars();
      final double chipHalfW = (maxChars * chipSize) / 2 + chipSize * 0.55;
      final double chipHalfH = chipSize * 0.86 * 1.7;
      for (final double slotOffset in <double>[-halfSpan + bias, halfSpan + bias]) {
        for (final double delta in <double>[-bladeHalfSweepDeg, bladeHalfSweepDeg]) {
          final double rad = _rad(base + sign * (slotOffset + delta));
          final double cx = centerX + chipRadius * math.cos(rad);
          final double cy = centerY + chipRadius * math.sin(rad);
          final double tx = -math.sin(rad);
          final double ty = math.cos(rad);
          final double nx = math.cos(rad);
          final double ny = math.sin(rad);
          for (final double sw in <double>[-1, 1]) {
            for (final double sh in <double>[-1, 1]) {
              include(cx + tx * chipHalfW * sw + nx * chipHalfH * sh,
                  cy + ty * chipHalfW * sw + ny * chipHalfH * sh);
            }
          }
        }
      }
    }

    final double safety = spec.dp(safetyPaddingDp);
    final WheelRect rawWindow =
        WheelRect.of(left - safety, top - safety, right + safety, bottom + safety);
    if (!rawWindow.isUsable || !ringBladeBox.isUsable) return null;
    final WheelRect window = _clampIntoBounds(rawWindow, bounds);
    final double widthLimit = bounds.width *
        (compact ? _maxWindowWidthRatioCompact : _maxWindowWidthRatio);
    final double heightLimit = bounds.height *
        (compact ? _maxWindowHeightRatioCompact : _maxWindowHeightRatio);
    final bool fits = ringBladeBox.isInside(bounds) &&
        ringBladeBox.width <= widthLimit &&
        ringBladeBox.height <= heightLimit;

    return _WheelPlan(
      direction: direction,
      verticalMode: vertical,
      windowRect: window,
      centerX: centerX,
      centerY: centerY,
      petAnchorX: anchorX,
      petAnchorY: anchorY,
      holeRx: notchRx,
      holeRy: notchRy,
      allowedOffset: offset,
      ringRadiusPx: ringRadius,
      buttonDiameterPx: buttonDiameter,
      buttonTouchDiameterPx: math.max(
        buttonDiameter,
        spec.dp(WheelMenuLayoutSettings.buttonTouchMinDp),
      ),
      fanBiasDeg: bias,
      scale: scale,
      compact: compact,
      fits: fits,
    );
  }

  /// 兜底放置（安全区极端狭窄）：**尺寸仍然不变**，只是把窗口夹进安全区。
  static WheelMenuEnvelope _forcedEnvelope({
    required WheelBounds bounds,
    required WheelIntrinsicLayout intrinsic,
    required WheelExpandDirection direction,
    required WheelVerticalMode vertical,
    required double anchorX,
    required double anchorY,
    required double offset,
    required WheelMenuSpec spec,
    required WheelMenuLayoutSettings settings,
  }) {
    final double centerX = (direction == WheelExpandDirection.right
            ? anchorX + offset
            : anchorX - offset)
        .roundToDouble();
    final WheelRect raw = WheelRect.of(
      anchorX - intrinsic.notchRx,
      anchorY - intrinsic.halfHeightPx,
      centerX + intrinsic.halfWidthPx,
      anchorY + intrinsic.halfHeightPx,
    );
    return WheelMenuEnvelope(
      direction: direction,
      verticalMode: vertical,
      windowRect: _clampIntoBounds(raw, bounds),
      centerX: centerX,
      centerY: anchorY,
      petAnchorX: anchorX,
      petAnchorY: anchorY,
      holeRx: intrinsic.notchRx,
      holeRy: intrinsic.notchRy,
      allowedOffsetPx: offset,
      maxRingRadiusPx: intrinsic.ringRadiusPx,
      buttonDiameterPx: intrinsic.buttonDiameterPx,
      buttonTouchDiameterPx: math.max(
        intrinsic.buttonDiameterPx,
        spec.dp(WheelMenuLayoutSettings.buttonTouchMinDp),
      ),
      fanBiasDeg: vertical.biasDeg,
      preferredScale: settings.preferredScale,
      actualScale: 1.0,
      compact: intrinsic.compact,
      degraded: true,
      fallbackReason: 'window-clamped',
    );
  }

  static WheelMenuEnvelope _degenerateEnvelope(
    WheelBounds bounds,
    WheelRect visible,
    WheelExpandDirection direction,
    WheelVerticalMode vertical,
    double holeRx,
    double holeRy,
    double offset,
    WheelMenuLayoutSettings settings,
    WheelMenuSpec spec,
  ) {
    final WheelRect rect = visible.isUsable ? visible : const WheelRect(0, 0, 1, 1);
    final double button = spec.buttonDiameterFor(2, minActualScale);
    return WheelMenuEnvelope(
      direction: direction,
      verticalMode: vertical,
      windowRect: rect,
      centerX: rect.centerX,
      centerY: rect.centerY,
      petAnchorX: rect.centerX,
      petAnchorY: rect.centerY,
      holeRx: math.max(holeRx, 1),
      holeRy: math.max(holeRy, 1),
      allowedOffsetPx: offset,
      maxRingRadiusPx: spec.dp(minRadiusDp),
      buttonDiameterPx: button,
      buttonTouchDiameterPx:
          math.max(button, spec.dp(WheelMenuLayoutSettings.buttonTouchMinDp)),
      fanBiasDeg: vertical.biasDeg,
      preferredScale: settings.preferredScale,
      actualScale: minActualScale,
      compact: true,
      degraded: true,
      fallbackReason: 'no-usable-bounds',
    );
  }

  static WheelRect _clampIntoBounds(WheelRect rect, WheelBounds bounds) {
    if (!bounds.isUsable) return rect;
    final double width = math.min(rect.width, bounds.width);
    final double height = math.min(rect.height, bounds.height);
    final double left =
        rect.left.clamp(bounds.left, math.max(bounds.left, bounds.right - width));
    final double top =
        rect.top.clamp(bounds.top, math.max(bounds.top, bounds.bottom - height));
    return WheelRect(left, top, left + width, top + height);
  }

  /// 所有条目里最长的中文标签字数 —— 参与菜单窗口包围盒计算。
  ///
  /// 与 Android `WheelMenuCatalog.maxLabelChars` 同源（Windows 侧复用 `MenuCatalog`）；
  /// 因此 Windows 的 labelZh 必须与 Android 逐字一致，否则窗口尺寸会不同。
  static int _maxLabelChars() => MenuCatalog.maxLabelChars;
}

/// 一次求解的完整结果（内部使用）。
class _WheelPlan {
  const _WheelPlan({
    required this.direction,
    required this.verticalMode,
    required this.windowRect,
    required this.centerX,
    required this.centerY,
    required this.petAnchorX,
    required this.petAnchorY,
    required this.holeRx,
    required this.holeRy,
    required this.allowedOffset,
    required this.ringRadiusPx,
    required this.buttonDiameterPx,
    required this.buttonTouchDiameterPx,
    required this.fanBiasDeg,
    required this.scale,
    required this.compact,
    required this.fits,
  });

  final WheelExpandDirection direction;
  final WheelVerticalMode verticalMode;
  final WheelRect windowRect;
  final double centerX;
  final double centerY;
  final double petAnchorX;
  final double petAnchorY;
  final double holeRx;
  final double holeRy;
  final double allowedOffset;
  final double ringRadiusPx;
  final double buttonDiameterPx;
  final double buttonTouchDiameterPx;
  final double fanBiasDeg;
  final double scale;
  final bool compact;
  final bool fits;

  WheelMenuEnvelope toEnvelope(
    WheelMenuLayoutSettings settings, {
    required bool degraded,
    String? reason,
  }) =>
      WheelMenuEnvelope(
        direction: direction,
        verticalMode: verticalMode,
        windowRect: windowRect,
        centerX: centerX,
        centerY: centerY,
        petAnchorX: petAnchorX,
        petAnchorY: petAnchorY,
        holeRx: holeRx,
        holeRy: holeRy,
        allowedOffsetPx: allowedOffset,
        maxRingRadiusPx: ringRadiusPx,
        buttonDiameterPx: buttonDiameterPx,
        buttonTouchDiameterPx: buttonTouchDiameterPx,
        fanBiasDeg: fanBiasDeg,
        preferredScale: settings.preferredScale,
        actualScale: scale,
        compact: compact,
        degraded: degraded,
        fallbackReason: reason,
      );
}

// ---------------------------------------------------------------------------
// 方向决议（**唯一入口**）：契约 → 屏幕坐标判定 → 不变量 → 反向重试
// ---------------------------------------------------------------------------
//
// 真机回归「左右展开完全反向」的修复落点。
//
// 之前 `computeEnvelope` 内部直接用 `decideDirection` 的自由空间比较，**没有**
// "菜单是否真的落在那一侧 / 是否真的不出工作区"的事后校验。一旦上游坐标空间
// 有任何偏差（或渲染层与几何层对 left/right 的理解不一致），结果就会**正好反向**
// 而没有任何机制发现它。
//
// 这里把"方向"提升为一等结果对象：
//   1. `WheelExpansionSide`（唯一契约，见 wheel_expansion_side.dart）
//      → `WheelDirectionPolicy.decide`（只在屏幕坐标里判，带滞回）
//   2. 用该方向算信封 → 检查方向不变量（菜单中心在正确一侧 + 不出 workArea）
//   3. 不通过 → 用**相反方向**重算并再检查
//   4. 相反方向通过 → 采用相反方向
//   5. 两边都不通过 → 取"不出工作区"优先的那一侧，随后由应急缩放 / 夹取兜底
//
// 因此"显示出屏菜单"在契约层面就不可能发生。

/// 一次方向决议的完整结果（含全部诊断字段）。
class WheelExpansionResolution {
  const WheelExpansionResolution({
    required this.envelope,
    required this.side,
    required this.requestedSide,
    required this.decision,
    required this.invariant,
    required this.oppositeInvariant,
    required this.retriedOpposite,
    required this.fallbackReason,
  });

  /// 最终采用的信封（其 `direction` 与 [side] **恒一致**）。
  final WheelMenuEnvelope envelope;

  /// 最终采用的展开侧（**唯一方向语义**）。
  final WheelExpansionSide side;

  /// 策略给出的首选侧（未经不变量修正）。
  final WheelExpansionSide requestedSide;

  final WheelDirectionDecision decision;

  /// 首选侧的不变量检查结果。
  final WheelDirectionInvariant invariant;

  /// 相反侧的不变量检查结果（未试算时为 null）。
  final WheelDirectionInvariant? oppositeInvariant;

  /// 是否因为首选侧违反不变量而改用了相反侧。
  final bool retriedOpposite;

  /// 兜底原因（`ok` = 首选侧直接通过）。
  final String fallbackReason;

  /// 诊断：`wheel.direction.*` 字段全集。
  Map<String, Object?> diagnostics({
    required Rect petScreenRect,
    required Rect workArea,
    required Rect menuScreenBounds,
  }) =>
      <String, Object?>{
        'pet_screen_rect': WheelGeometryJournal.formatRect(petScreenRect),
        'work_area': WheelGeometryJournal.formatRect(workArea),
        'room_left': decision.roomLeft.toStringAsFixed(1),
        'room_right': decision.roomRight.toStringAsFixed(1),
        'required_width': decision.requiredWidth.toStringAsFixed(1),
        'selected_side': side.wireName,
        'requested_side': requestedSide.wireName,
        'previous_side': decision.previousSide?.wireName ?? 'none',
        'hysteresis_applied': decision.hysteresisApplied,
        'reason': decision.reason,
        'retried_opposite': retriedOpposite,
        'menu_screen_bounds': WheelGeometryJournal.formatRect(menuScreenBounds),
        'invariant_passed': invariant.passed,
        'invariant_reason': invariant.reason,
        'fallback_reason': fallbackReason,
      };
}

/// 单侧试算结果（内部用）。
class _SideAttempt {
  const _SideAttempt({required this.envelope, required this.invariant});

  final WheelMenuEnvelope envelope;
  final WheelDirectionInvariant invariant;
}

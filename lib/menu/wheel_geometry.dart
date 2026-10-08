/// 轮盘菜单的**纯 Dart 几何计算**（增量 A）。
///
/// 这里只有数学：给定桌宠当前的屏幕矩形、菜单需要的尺寸、所在显示器的可见区域，
/// 算出"窗口要扩到多大、桌宠要补偿多少、菜单画在哪里"。
///
/// 三条硬约束：
/// 1. **桌宠屏幕坐标不变**：无论菜单往右还是往左展开，`petRect` 在屏幕上的位置
///    由 [WheelGeometryResult.petScreenRect] 原样保证；
/// 2. **单窗口**：Windows 只有一个 HWND，扩窗后必须同时容纳桌宠与菜单，
///    因此窗口矩形是两个矩形的并集；
/// 3. **纯函数 / 无副作用**：不 import `window_manager` 等桌面库，
///    因此可在 `flutter_tester` 里直接单测（见 `test/wheel_geometry_test.dart`）。
///
/// 坐标系约定：全部为**逻辑像素**（与 `window_manager.getBounds` / `setBounds`
/// 的口径一致；物理↔逻辑换算见 [WheelDpi]）。
library;

import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;

/// 一块显示器的可见区域（逻辑像素）。
class WheelDisplayArea {
  const WheelDisplayArea({
    required this.id,
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    this.isPrimary = false,
  });

  final String id;
  final double left;
  final double top;
  final double width;
  final double height;

  /// 是否主显示器（`PetPositionResolver` 在保存位置不可见时回退到它）。
  final bool isPrimary;

  Rect get rect => Rect.fromLTWH(left, top, width, height);

  double get right => left + width;

  double get bottom => top + height;

  bool containsPoint(Offset point) =>
      point.dx >= left && point.dx <= right && point.dy >= top && point.dy <= bottom;

  static WheelDisplayArea fromRect(String id, Rect rect, {bool isPrimary = false}) =>
      WheelDisplayArea(
        id: id,
        left: rect.left,
        top: rect.top,
        width: rect.width,
        height: rect.height,
        isPrimary: isPrimary,
      );

  @override
  String toString() => 'WheelDisplayArea($id ${width.toInt()}x${height.toInt()} @ '
      '${left.toInt()},${top.toInt()})';
}

/// 菜单在桌宠旁边展开所需的尺寸与间距（逻辑像素）。
class WheelMenuLayout {
  const WheelMenuLayout({
    required this.menuSize,
    this.gap = 12,
  });

  /// 菜单包围盒尺寸（圆形轮盘按其外接正方形给）。
  final Size menuSize;

  /// 菜单与桌宠之间的间距。
  final double gap;
}

/// 一次几何计算的结果。
class WheelGeometryResult {
  const WheelGeometryResult({
    required this.windowRect,
    required this.petScreenRect,
    required this.petLocal,
    required this.menuLocal,
    required this.menuScreenRect,
    required this.menuOnRight,
    required this.clamped,
  });

  /// 新的窗口矩形（位置 + 尺寸，一次 `setBounds` 提交）。
  final Rect windowRect;

  /// 桌宠的屏幕矩形 —— **恒等于输入**（不变量）。
  final Rect petScreenRect;

  /// 桌宠左上角在新窗口内的局部坐标（补偿偏移）。
  final Offset petLocal;

  /// 菜单左上角在新窗口内的局部坐标。
  final Offset menuLocal;

  /// 菜单的屏幕矩形。
  final Rect menuScreenRect;

  /// 菜单是否展开在桌宠右侧。
  final bool menuOnRight;

  /// 是否因为触到显示器边缘而做过夹取。
  final bool clamped;

  @override
  String toString() => 'WheelGeometryResult(window=$windowRect petLocal=$petLocal '
      'menuLocal=$menuLocal right=$menuOnRight clamped=$clamped)';
}

/// 几何计算入口。
class WheelGeometry {
  WheelGeometry._();

  /// 计算扩窗几何。
  ///
  /// 规则：
  /// * **水平**：优先放在桌宠**右侧**（桌宠保持在窗口左上角，`petLocal=(0,0)`）；
  ///   右侧放不下时放**左侧**（`petLocal.dx = menuW + gap`）；
  ///   两侧都放不下时取空间较大的一侧，并把菜单**夹到显示器可见范围内**
  ///   （可能与桌宠重叠，但桌宠屏幕坐标绝不改变）。
  /// * **竖直**：菜单相对桌宠竖直居中，并夹到显示器可见范围内。
  /// * **窗口**：桌宠矩形与菜单矩形的并集。
  static WheelGeometryResult compute({
    required Rect petRect,
    required WheelMenuLayout layout,
    required WheelDisplayArea display,
  }) {
    final Rect dr = display.rect;
    final double menuW = layout.menuSize.width;
    final double menuH = layout.menuSize.height;
    final double gap = layout.gap;

    // --- 竖直方向：相对桌宠居中 + 夹取 ---
    bool clamped = false;
    double menuTop = petRect.center.dy - menuH / 2;
    if (menuH >= dr.height) {
      // 菜单比显示器还高：贴顶，剩下的溢出由窗口自行容纳。
      menuTop = dr.top;
      clamped = true;
    } else {
      final double maxTop = dr.bottom - menuH;
      if (menuTop < dr.top) {
        menuTop = dr.top;
        clamped = true;
      } else if (menuTop > maxTop) {
        menuTop = maxTop;
        clamped = true;
      }
    }
    final double menuBottom = menuTop + menuH;

    // --- 水平方向：优先右侧，其次左侧，最后夹取 ---
    final double roomRight = dr.right - petRect.right;
    final double roomLeft = petRect.left - dr.left;
    final bool fitsRight = roomRight >= menuW + gap;
    final bool fitsLeft = roomLeft >= menuW + gap;

    final bool menuOnRight;
    double menuLeft;
    if (fitsRight) {
      menuOnRight = true;
      menuLeft = petRect.right + gap;
    } else if (fitsLeft) {
      menuOnRight = false;
      menuLeft = petRect.left - gap - menuW;
    } else {
      menuOnRight = roomRight >= roomLeft;
      final double preferred =
          menuOnRight ? petRect.right + gap : petRect.left - gap - menuW;
      final double clampedLeft = _clampDouble(preferred, dr.left, dr.right - menuW);
      if (clampedLeft != preferred) clamped = true;
      menuLeft = clampedLeft;
    }
    final double menuRight = menuLeft + menuW;

    // --- 窗口 = 桌宠 ∪ 菜单 ---
    final double winLeft = math.min(petRect.left, menuLeft);
    final double winTop = math.min(petRect.top, menuTop);
    final double winRight = math.max(petRect.right, menuRight);
    final double winBottom = math.max(petRect.bottom, menuBottom);

    return WheelGeometryResult(
      windowRect: Rect.fromLTRB(winLeft, winTop, winRight, winBottom),
      petScreenRect: petRect,
      petLocal: Offset(petRect.left - winLeft, petRect.top - winTop),
      menuLocal: Offset(menuLeft - winLeft, menuTop - winTop),
      menuScreenRect: Rect.fromLTRB(menuLeft, menuTop, menuRight, menuBottom),
      menuOnRight: menuOnRight,
      clamped: clamped,
    );
  }

  /// 把桌宠**屏幕坐标误差**算成"绝对差之和"（诊断用）。
  ///
  /// 用于核对"补偿后桌宠是否仍在原屏幕位置"：0 表示完全一致。
  static double petScreenError({
    required Rect expected,
    required Rect actualWindowRect,
    required Offset petLocal,
  }) {
    final Offset actualPet = actualWindowRect.topLeft + petLocal;
    return (actualPet.dx - expected.left).abs() +
        (actualPet.dy - expected.top).abs();
  }

  static double _clampDouble(double value, double low, double high) {
    if (high < low) return low;
    if (value < low) return low;
    if (value > high) return high;
    return value;
  }
}

/// 一次"打开 → 关闭"会话（纯 Dart，可单测无漂移）。
///
/// 关键性质：关闭时**恢复的是打开前记录下来的原始窗口矩形**，
/// 而不是"再算一遍"，因此 open→close 的往返误差恒为 0，连续多轮也不会累积。
class WheelGeometrySession {
  WheelGeometrySession._({
    required Rect originalWindowRect,
    required WheelMenuLayout layout,
    required WheelDisplayArea display,
  })  : _originalWindowRect = originalWindowRect,
        _layout = layout,
        _display = display;

  /// 以"当前窗口矩形 = 桌宠矩形"为起点开启一次会话。
  factory WheelGeometrySession.start({
    required Rect petRect,
    required WheelMenuLayout layout,
    required WheelDisplayArea display,
  }) =>
      WheelGeometrySession._(
        originalWindowRect: petRect,
        layout: layout,
        display: display,
      );

  final Rect _originalWindowRect;
  final WheelMenuLayout _layout;
  final WheelDisplayArea _display;

  WheelGeometryResult? _openResult;

  /// 打开前的原始窗口矩形（= 桌宠矩形）。
  Rect get originalWindowRect => _originalWindowRect;

  bool get isOpen => _openResult != null;

  WheelGeometryResult? get openResult => _openResult;

  /// 计算（幂等）打开几何。
  WheelGeometryResult open() => _openResult ??= WheelGeometry.compute(
        petRect: _originalWindowRect,
        layout: _layout,
        display: _display,
      );

  /// 关闭：返回应当恢复到的窗口矩形（幂等）。
  Rect close() {
    _openResult = null;
    return _originalWindowRect;
  }
}

/// DPI / 逻辑-物理像素换算（诊断与多屏换算共用）。
class WheelDpi {
  WheelDpi._();

  /// Windows 的基准 DPI（100% 缩放）。
  static const double baselineDpi = 96;

  /// 由 `devicePixelRatio` 推 DPI（Windows 上 DPI = 96 × 缩放比）。
  static double dpiFromDevicePixelRatio(double devicePixelRatio) =>
      baselineDpi * devicePixelRatio;

  /// 物理像素矩形 → 逻辑像素矩形。
  static Rect physicalToLogicalRect(Rect physical, double devicePixelRatio) {
    if (devicePixelRatio <= 0) return physical;
    return Rect.fromLTWH(
      physical.left / devicePixelRatio,
      physical.top / devicePixelRatio,
      physical.width / devicePixelRatio,
      physical.height / devicePixelRatio,
    );
  }

  /// 逻辑像素矩形 → 物理像素矩形。
  static Rect logicalToPhysicalRect(Rect logical, double devicePixelRatio) =>
      Rect.fromLTWH(
        logical.left * devicePixelRatio,
        logical.top * devicePixelRatio,
        logical.width * devicePixelRatio,
        logical.height * devicePixelRatio,
      );
}

/// 固定画布 + 窗口 Region 的**纯 Dart 几何**（本轮新方向）。
///
/// 背景（为什么放弃旧方案）
/// ------------------------
/// 旧的"动态放大 / 缩小**同一个 HWND**"方案在真机上连续失败两次
/// （首次点击桌宠大面积消失、有时只剩一丁点菜单、再点一次才恢复）：
/// `setBounds` + Flutter surface resize + 桌宠局部补偿 + 菜单布局，这四件事
/// **无法保证落在同一个可见帧**。因此本轮改为：
///
/// > 桌宠模式下 HWND 的物理矩形**固定不变**，只在打开 / 关闭菜单时改
/// > **窗口 Region（`SetWindowRgn`）**。
///
/// 本文件只有数学与几何，不 import 任何桌面库，可在 `flutter_tester` 直接单测
/// （见 `test/fixed_canvas_geometry_test.dart`）。
///
/// 坐标系约定
/// ----------
/// * 画布局部坐标：[Rect] / [Offset]，**逻辑像素**，原点是窗口客户端区左上角；
/// * 屏幕坐标：[Rect] / [Offset]，**逻辑像素**，与 `window_manager` 同口径；
/// * `SetWindowRgn` 需要的是**客户端区物理像素**，换算见 [FixedCanvasDpi]。
library;

import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;

import 'wheel_geometry.dart' show WheelDisplayArea;

/// 固定画布配置（逻辑像素）。
///
/// 画布必须一次性容纳：桌宠**最大**尺寸、轮盘**最大**尺寸、左右镜像、
/// 按钮标签包围盒，外加安全边距。此后在桌宠模式下**绝不再放大**。
class FixedCanvasConfig {
  const FixedCanvasConfig({
    this.maxPetSide = 512,
    this.maxWheelSide = 384,
    this.margin = 24,
    this.menuGap = 12,
  });

  /// 桌宠最大边长（逻辑像素）。素材按 128 计、缩放 4× → 512。
  final double maxPetSide;

  /// 轮盘菜单外接正方形最大边长（逻辑像素）。
  final double maxWheelSide;

  /// 四周安全边距：容纳按钮标签包围盒 + 抗锯齿溢出的余量。
  final double margin;

  /// 菜单与桌宠之间的间距。
  final double menuGap;

  /// 固定画布尺寸（逻辑像素）。
  ///
  /// 公式：
  /// ```text
  /// width  = maxPetSide + 2 * (maxWheelSide + menuGap) + margin * 2
  /// height = max(maxPetSide, maxWheelSide) + margin * 2
  /// ```
  /// * 宽度里的 `2 * (…)`：桌宠居中后，**左右两侧都必须**放得下最大的菜单；
  /// * 高度取两者较大值：菜单相对桌宠竖直居中，任一者都能完整容纳；
  /// * `margin`：按钮标签包围盒与安全余量。
  Size get canvasSize => Size(
        maxPetSide + 2 * (maxWheelSide + menuGap) + margin * 2,
        math.max(maxPetSide, maxWheelSide) + margin * 2,
      );

  /// 桌宠在画布内的固定锚点（局部逻辑坐标）。
  ///
  /// 推导：把桌宠**居中**放在画布里 —— 锚点 = 画布中心 - 桌宠尺寸一半。
  /// 它在菜单打开 / 关闭期间**恒定不变**（唯一允许改变它的时机是桌宠尺寸本身变化，
  /// 且必须发生在窗口 show() 之前）。
  Offset petAnchorFor(Size petSize) => Offset(
        (canvasSize.width - petSize.width) / 2,
        (canvasSize.height - petSize.height) / 2,
      );
}

/// 一次菜单在画布内的布局结果。
class FixedCanvasMenuLayoutResult {
  const FixedCanvasMenuLayoutResult({
    required this.menuLocalRect,
    required this.menuOnRight,
    required this.clamped,
    required this.compressed,
  });

  /// 菜单在画布内的局部矩形（逻辑像素）。
  final Rect menuLocalRect;

  /// 菜单是否展开在桌宠右侧（镜像开关）。
  final bool menuOnRight;

  /// 是否因为触到画布边界而夹取过位置。
  final bool clamped;

  /// 画布是否装不下该菜单（需要压缩尺寸，绝不改窗口）。
  final bool compressed;

  String get directionLabel => menuOnRight ? 'right' : 'left';
}

/// 固定画布几何计算入口。
class FixedCanvasGeometry {
  FixedCanvasGeometry._();

  /// 由"桌宠锚点屏幕位置"推出固定画布的窗口矩形（逻辑像素）。
  ///
  /// 这是持久化与启动恢复的**唯一口径**：保存的是**桌宠锚点屏幕位置**，
  /// 而不是画布窗口左上角。
  static Rect canvasWindowRect({
    required Offset petScreenPosition,
    required Offset petAnchor,
    required Size canvas,
  }) =>
      Rect.fromLTWH(
        petScreenPosition.dx - petAnchor.dx,
        petScreenPosition.dy - petAnchor.dy,
        canvas.width,
        canvas.height,
      );

  /// 桌宠在画布内的局部矩形（逻辑像素）。
  static Rect petLocalRect({required Offset petAnchor, required Size petSize}) =>
      Rect.fromLTWH(petAnchor.dx, petAnchor.dy, petSize.width, petSize.height);

  /// 桌宠在屏幕上的矩形（逻辑像素）。
  static Rect petScreenRect({
    required Rect canvasWindowRect,
    required Offset petAnchor,
    required Size petSize,
  }) =>
      Rect.fromLTWH(
        canvasWindowRect.left + petAnchor.dx,
        canvasWindowRect.top + petAnchor.dy,
        petSize.width,
        petSize.height,
      );

  /// **仅桌宠**的交互区域（逻辑局部坐标）——不含周围透明画布。
  static List<Rect> petOnlyRegion({
    required Offset petAnchor,
    required Size petSize,
  }) =>
      <Rect>[petLocalRect(petAnchor: petAnchor, petSize: petSize)];

  /// **桌宠 + 菜单**的交互区域（逻辑局部坐标）——只含桌宠与菜单元素本身。
  static List<Rect> petAndMenuRegion({
    required Rect petLocalRect,
    required Rect? menuLocalRect,
  }) =>
      <Rect>[
        petLocalRect,
        if (menuLocalRect != null && !menuLocalRect.isEmpty) menuLocalRect,
      ];

  /// 计算菜单在**固定画布内**的位置（绝不移动窗口）。
  ///
  /// * 水平方向：优先右侧；右侧空间不足则改为左侧；两侧都不足时夹到画布内
  ///   （`clamped=true`）；
  /// * 竖直方向：相对桌宠居中，再夹到画布内；
  /// * 菜单比画布还大 → `compressed=true`，调用方必须压缩尺寸后再提交。
  static FixedCanvasMenuLayoutResult computeMenu({
    required Offset petAnchor,
    required Size petSize,
    required Size canvas,
    required Size menuSize,
    required WheelDisplayArea display,
    required Offset petScreenPosition,
    double gap = 12,
  }) {
    final Rect petScreen = Rect.fromLTWH(
      petScreenPosition.dx,
      petScreenPosition.dy,
      petSize.width,
      petSize.height,
    );

    // 依据桌宠**屏幕位置**决定镜像方向：右侧更宽就放右边。
    final double roomRight = display.right - petScreen.right;
    final double roomLeft = petScreen.left - display.left;
    bool onRight = roomRight >= roomLeft;

    final double rightLeft = petAnchor.dx + petSize.width + gap;
    final double leftLeft = petAnchor.dx - gap - menuSize.width;

    double menuLeft = onRight ? rightLeft : leftLeft;
    bool clamped = false;

    // 水平夹取：只在固定画布内做，绝不改窗口。
    if (menuLeft < 0) {
      if (rightLeft + menuSize.width <= canvas.width) {
        menuLeft = rightLeft;
        onRight = true;
        clamped = true;
      } else {
        menuLeft = 0;
        clamped = true;
      }
    }
    if (menuLeft + menuSize.width > canvas.width) {
      if (leftLeft >= 0) {
        menuLeft = leftLeft;
        onRight = false;
        clamped = true;
      } else {
        menuLeft = canvas.width - menuSize.width;
        clamped = true;
      }
    }

    // 竖直：相对桌宠居中 + 夹取。
    double menuTop = petAnchor.dy + (petSize.height - menuSize.height) / 2;
    if (menuTop < 0) {
      menuTop = 0;
      clamped = true;
    }
    if (menuTop + menuSize.height > canvas.height) {
      menuTop = canvas.height - menuSize.height;
      clamped = true;
    }

    final bool compressed =
        menuSize.width > canvas.width || menuSize.height > canvas.height;

    return FixedCanvasMenuLayoutResult(
      menuLocalRect: Rect.fromLTWH(menuLeft, menuTop, menuSize.width, menuSize.height),
      menuOnRight: onRight,
      clamped: clamped,
      compressed: compressed,
    );
  }
}

/// 逻辑像素 → **物理像素**矩形（`SetWindowRgn` 需要物理客户端像素）。
class PhysicalRect {
  const PhysicalRect(this.left, this.top, this.right, this.bottom);

  final int left;
  final int top;
  final int right;
  final int bottom;

  int get width => right - left;

  int get height => bottom - top;

  Map<String, int> toMap() => <String, int>{
        'left': left,
        'top': top,
        'right': right,
        'bottom': bottom,
      };

  /// 解析原生返回的矩形（宽容：缺键 / 类型不符 → null）。
  static PhysicalRect? fromMap(Object? raw) {
    if (raw is! Map) return null;
    int? read(String key) {
      final Object? value = raw[key];
      if (value is int) return value;
      if (value is num) return value.round();
      return null;
    }

    final int? left = read('left');
    final int? top = read('top');
    final int? right = read('right');
    final int? bottom = read('bottom');
    if (left == null || top == null || right == null || bottom == null) {
      return null;
    }
    return PhysicalRect(left, top, right, bottom);
  }

  @override
  String toString() => '$left,$top $width×$height';

  @override
  bool operator ==(Object other) =>
      other is PhysicalRect &&
      other.left == left &&
      other.top == top &&
      other.right == right &&
      other.bottom == bottom;

  @override
  int get hashCode => Object.hash(left, top, right, bottom);
}

/// DPI / 逻辑-物理换算（**唯一转换助手**，测试覆盖 100% / 125% / 150%）。
class FixedCanvasDpi {
  FixedCanvasDpi._();

  /// Windows 的基准 DPI（100% 缩放）。
  static const double baselineDpi = 96;

  /// 由 `devicePixelRatio` 推 DPI（Windows 上 DPI = 96 × 缩放比）。
  static double dpiFromDevicePixelRatio(double devicePixelRatio) =>
      baselineDpi * devicePixelRatio;

  /// 单个逻辑像素值 → 物理像素（四舍五入到整数像素）。
  static int scalePx(double logical, double devicePixelRatio) {
    if (devicePixelRatio <= 0) return logical.round();
    return (logical * devicePixelRatio).round();
  }

  /// 单个逻辑矩形 → 物理矩形。
  static PhysicalRect rectToPhysical(Rect logical, double devicePixelRatio) {
    if (devicePixelRatio <= 0) {
      return PhysicalRect(
        logical.left.round(),
        logical.top.round(),
        logical.right.round(),
        logical.bottom.round(),
      );
    }
    return PhysicalRect(
      (logical.left * devicePixelRatio).round(),
      (logical.top * devicePixelRatio).round(),
      (logical.right * devicePixelRatio).round(),
      (logical.bottom * devicePixelRatio).round(),
    );
  }

  /// 逻辑矩形列表 → 物理矩形列表（`applyInteractionRegion` 的入参）。
  static List<PhysicalRect> rectsToPhysical(
    List<Rect> rects,
    double devicePixelRatio,
  ) =>
      rects
          .map((Rect r) => rectToPhysical(r, devicePixelRatio))
          .where((PhysicalRect r) => r.right > r.left && r.bottom > r.top)
          .toList(growable: false);
}

/// 位置持久化：保存的是**桌宠锚点的屏幕位置**，不是画布窗口左上角。
class FixedCanvasPersistence {
  FixedCanvasPersistence._();

  /// 拖动结束：`petScreenPosition = windowPosition + petAnchor`。
  static Offset petScreenPositionFromWindow({
    required Offset windowPosition,
    required Offset petAnchor,
  }) =>
      Offset(
        windowPosition.dx + petAnchor.dx,
        windowPosition.dy + petAnchor.dy,
      );

  /// 启动恢复：`windowPosition = savedPetScreenPosition - petAnchor`。
  static Offset windowPositionFromPetScreen({
    required Offset petScreenPosition,
    required Offset petAnchor,
  }) =>
      Offset(
        petScreenPosition.dx - petAnchor.dx,
        petScreenPosition.dy - petAnchor.dy,
      );
}

/// 当前生效的桌宠锚点（跨模块共享）。
///
/// 用途：窗口控制器在**拖动结束**保存位置、在**启动恢复**读取位置时，
/// 都需要把"画布窗口坐标"换算成"桌宠锚点屏幕坐标"。它是纯 Dart 的，
/// 与平台实现解耦，因此 `WindowsWindowController` 可以直接读它。
class FixedCanvasAnchorState {
  Offset? _anchor;
  bool _enabled = false;

  /// 是否处于固定画布（Region）模式。
  bool get enabled => _enabled && _anchor != null;

  /// 当前锚点（未启用时为 null）。
  Offset? get anchor => _anchor;

  /// 设置 / 清除锚点。`enabled=false` 时即退出固定画布模式。
  void set(Offset? anchor, {required bool enabled}) {
    _anchor = anchor;
    _enabled = enabled && anchor != null;
  }

  void clear() {
    _anchor = null;
    _enabled = false;
  }
}

/// 模块级共享实例：探针写入、窗口控制器读取。
final FixedCanvasAnchorState fixedCanvasAnchor = FixedCanvasAnchorState();

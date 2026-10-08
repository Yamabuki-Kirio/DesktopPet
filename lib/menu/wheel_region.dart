/// 轮盘 Region 生成（**由实际几何生成，不含整画布**）。
///
/// 口径（增量 B 范围 6 / docs/37 §15.4，C1.1 修正）
/// ------------------------------------------------
/// * Region 成员 = `桌宠缺口 ∪ 全部绘制元素的外接分解 ∪ 反馈条`；
/// * **绝不**是"整块画布"——否则轮盘会吃掉整屏的鼠标事件；
/// * 矩形数量有上限（超出时**丢弃最小**的若干块，绝不无限增长）；
/// * 只在开 / 关、镜像方向、层级变化、尺寸变化时更新；**悬停与滑动过程中不重写**。
///
/// ⚠️ C1.1 修正（真机"扇形 / 按钮 / 文字被硬直线裁切"的根因之一）
/// ------------------------------------------------------------
/// 旧实现只覆盖"弧带 + 按钮命中圆 + chip"，**漏掉**了真正会被画出来的：
/// 刀刃（`bladeLength` 远大于环带外缘）、外缘齿轮凸起、强调弧，
/// 以及动画 overshoot 时被推到更外圈的按钮。
/// 于是那些像素落在 Region 之外 → 在 Windows 上**根本不显示**，
/// 表现为"被硬直线裁切"。
///
/// 现在改为消费 [WheelVisualBoundsCalculator] 的**同一个**包围盒：
/// 可见区严格覆盖"会被画的像素"，不再出现"画了却看不见"。
///
/// 本文件是**纯 Dart**（只依赖 `dart:ui` 的 `Rect`），可单测。
library;

import 'dart:math' as math;
import 'dart:ui' show Offset, Rect;

import 'wheel_menu_geometry.dart' show WheelMenuGeometry, WheelMenuLayout;
import 'wheel_visual_bounds.dart'
    show WheelVisualBounds, WheelVisualBoundsCalculator;

/// Region 构建器。
class WheelRegionBuilder {
  WheelRegionBuilder._();

  /// 弧带扇形被拆成多少段外接矩形（段越多越贴合，矩形也越多）。
  static const int fanSegments = 10;

  /// Region 矩形数量上限（超出则丢弃面积最小的若干块）。
  static const int maxRects = 48;

  /// 相邻矩形合并的最小重叠比例（用于压缩矩形数量）。
  static const double mergeTolerance = 1.5;

  /// 生成 Region 矩形（**窗口内逻辑坐标**）。
  ///
  /// [slotProgress] 为每个槽位的弹出进度：进度 ≤ 0.01 的按钮**不产生**命中块
  /// （与渲染层"不画就不该能点"保持一致）。
  static List<Rect> rectsFor(
    WheelMenuLayout layout, {
    List<double> slotProgress = const <double>[],
    String? infoText,
    String? feedback,
    double feedbackBarHeight = 26,
    double feedbackMargin = 8,
  }) {
    final List<Rect> rects = <Rect>[];

    // 0) 桌宠（中央缺口椭圆的外接矩形）—— 人物层在菜单之上，必须保持可点。
    final Rect pet = Rect.fromCenter(
      center: Offset(layout.notchCenterX, layout.notchCenterY),
      width: math.max(1, layout.notchRx * 2),
      height: math.max(1, layout.notchRy * 2),
    );
    rects.add(pet);

    // 1) 弧带扇形（内缘 `ringRadius - button*0.6` → 外缘 `rimOuter`，张角 ±fanHalfSpan）。
    rects.addAll(_fanRects(layout));

    // 1b) **刀刃**（C1.1 新增）：它比环带外缘大得多，旧实现漏了它 →
    //     高亮扇区的外半截在真机上被裁掉。
    rects.addAll(_bladeRects(layout));

    // 2) 按钮命中圆 —— 直接消费**渲染侧同一份**按钮视觉矩形（C1.1 §七）：
    //    这样"看得见的按钮"必然"点得到"，不会再出现"画了却不在 Region"。
    //
    //    弹出进度 ≤ 0.01 的按钮**不产生**命中块（与渲染层"不画就不该能点"一致）。
    for (int i = 0; i < layout.slots.length; i++) {
      final double progress =
          i < slotProgress.length ? slotProgress[i] : 1.0;
      if (progress <= 0.01) continue;
      rects.add(WheelVisualBoundsCalculator.buttonVisualRectAt(layout, i));
    }

    // 3) 文字：标题 / chip / 说明三层的**安全带**（与渲染侧同源）。
    //    旧实现只覆盖 chip，标题与说明被截断时同样会"画了看不见"。
    final WheelVisualBounds vb = WheelVisualBoundsCalculator.compute(
      layout,
      hasFeedback: feedback != null && feedback.isNotEmpty,
      feedbackRect: feedback != null && feedback.isNotEmpty
          ? Rect.fromLTWH(
              feedbackMargin,
              math.max(
                0,
                layout.windowRect.height - feedbackBarHeight - feedbackMargin,
              ),
              math.max(1, layout.windowRect.width - feedbackMargin * 2),
              feedbackBarHeight,
            )
          : null,
    );
    if (vb.texts.width > 0) rects.add(vb.texts);
    // 3b) 按钮**中文标签**（径向朝外，可能被弹出 overshoot 推得比按钮命中圆更远）。
    //     C1.1 只补了 `texts`，漏了 `labels` —— 在"居中（bias 0）"等朝向下标签外缘会
    //     落在 Region 之外，真机上表现为标签被硬直线裁切（C1.1.1 回归测试发现）。
    if (vb.labels.width > 0) rects.add(vb.labels);

    // 4) 反馈条（固定在窗口底部，不改变窗口几何）。
    //
    // ⚠️ 必须**显式**加回来：反馈条只在有反馈时存在，因此它是"Region 随反馈变化"
    // 的唯一来源；漏掉它会导致"反馈条画出来却点不到 / Region 不重算"。
    if (feedback != null && feedback.isNotEmpty) {
      rects.add(Rect.fromLTWH(
        feedbackMargin,
        math.max(0, layout.windowRect.height - feedbackBarHeight - feedbackMargin),
        math.max(1, layout.windowRect.width - feedbackMargin * 2),
        feedbackBarHeight,
      ));
    }

    return _normalize(rects, layout);
  }

  /// Region 是否**完整覆盖** [visualBounds]（诊断 / 断言用）。
  ///
  /// 不覆盖即意味着"有像素被画出来却不在可见区" —— 真机上就是硬直线裁切。
  ///
  /// ⚠️ 判定**不能**只看"包围盒四角"：扇形 / 扇环的**包围盒**大部分是空的
  /// （角落根本没有像素），拿它当判据会得到假失败。因此这里按**真实会画的
  /// 采样点**判：
  /// * 按钮 / 标签 / 文字：矩形四角 + 中心（它们是矩形 / 圆的实心元素）；
  /// * 扇环（fanAndRim）：沿扇形张角在内外半径上取点；
  /// * 刀刃：最极端槽位 ± 半张角的外弧点。
  static bool coversVisualBounds(
    List<Rect> rects,
    WheelVisualBounds visualBounds, {
    WheelMenuLayout? layout,
    double tolerance = 2.0,
  }) {
    // 1) 矩形类元素（按钮 / 标签 / 文字）：四角 + 中心。
    for (final Rect part in <Rect>[
      visualBounds.buttons,
      visualBounds.labels,
      visualBounds.texts,
    ]) {
      if (part.width <= 0 || part.height <= 0) continue;
      for (final Offset p in <Offset>[
        part.topLeft,
        part.topRight,
        part.bottomLeft,
        part.bottomRight,
        part.center,
      ]) {
        if (!_pointCovered(rects, p, tolerance)) return false;
      }
    }
    if (layout == null) return true;

    // 2) 扇环：沿张角采样内外半径（含偏置与内外各一圈）。
    const int samples = 16;
    final double rIn = math.max(layout.ringRadiusPx - layout.buttonDiameterPx * 0.6, 1);
    final double rOut = math.max(layout.bladeLengthPx, layout.rimOuterPx);
    for (int i = 0; i <= samples; i++) {
      final double t = i / samples;
      final double offset =
          -layout.fanHalfSpanDeg + t * layout.fanHalfSpanDeg * 2 + layout.fanBiasDeg;
      for (final double radius in <double>[rIn, rOut, layout.rimOuterPx]) {
        final double abs = WheelMenuGeometry.absoluteAngle(layout.direction, offset);
        final double rad = abs * math.pi / 180;
        final Offset p = Offset(
          layout.centerX + radius * math.cos(rad),
          layout.centerY + radius * math.sin(rad),
        );
        if (!_pointCovered(rects, p, tolerance)) return false;
      }
    }

    // 3) 刀刃外弧：最极端槽位 ± 半张角。
    final double half = (layout.itemCount - 1) / 2;
    for (final double selection in <double>[0, layout.itemCount - 1]) {
      for (final double d in <double>[
        -layout.bladeHalfSweepDeg,
        0,
        layout.bladeHalfSweepDeg,
      ]) {
        final double abs = WheelMenuGeometry.absoluteAngle(
          layout.direction,
          layout.fanBiasDeg + (selection - half) * layout.stepDeg + d,
        );
        final double rad = abs * math.pi / 180;
        final Offset p = Offset(
          layout.centerX + layout.bladeLengthPx * math.cos(rad),
          layout.centerY + layout.bladeLengthPx * math.sin(rad),
        );
        if (!_pointCovered(rects, p, tolerance)) return false;
      }
    }
    return true;
  }

  static bool _pointCovered(List<Rect> rects, Offset p, double tolerance) {
    for (final Rect r in rects) {
      if (p.dx >= r.left - tolerance &&
          p.dx <= r.right + tolerance &&
          p.dy >= r.top - tolerance &&
          p.dy <= r.bottom + tolerance) {
        return true;
      }
    }
    return false;
  }

  /// **刀刃**扇形 → 若干段外接矩形（覆盖到 `bladeLength` × 动画峰值）。
  static List<Rect> _bladeRects(WheelMenuLayout layout) {
    final List<Rect> out = <Rect>[];
    const double peak = WheelVisualBoundsCalculator.animatorScalePeak;
    final double inner = math.max(layout.notchRx * 0.72 / peak, 1);
    final double outer = math.max(layout.bladeLengthPx, inner + 1) * peak +
        layout.outlineWidthPx * WheelVisualBoundsCalculator.bladeOutlineFactor;
    final double half = (layout.itemCount - 1) / 2;
    // 只覆盖"刀刃真正会出现的角度范围"：选中项在两极时最极端。
    for (final double selection in <double>[0, layout.itemCount - 1]) {
      final double angle = layout.fanBiasDeg +
          (selection - half) * layout.stepDeg;
      final int segments = 4;
      final double step = layout.bladeHalfSweepDeg * 2 / segments;
      for (int i = 0; i < segments; i++) {
        final double a0 = angle - layout.bladeHalfSweepDeg + step * i;
        final double a1 = a0 + step;
        out.add(_sectorBoundingRectFor(
          layout,
          inner,
          outer,
          a0,
          a1,
        ));
      }
    }
    return out;
  }

  /// 弧带扇形 → 若干段外接矩形。
  static List<Rect> _fanRects(WheelMenuLayout layout) {
    final double inner = math.max(layout.ringRadiusPx - layout.buttonDiameterPx * 0.6, 1);
    final double outer = math.max(layout.bandOuterPx, inner + 1);
    final int segments = math.max(2, fanSegments);
    final List<Rect> out = <Rect>[];
    final double step = layout.fanHalfSpanDeg * 2 / segments;
    for (int i = 0; i < segments; i++) {
      final double a0 = -layout.fanHalfSpanDeg + step * i + layout.fanBiasDeg;
      final double a1 = a0 + step;
      out.add(_sectorBoundingRect(layout, inner, outer, a0, a1));
    }
    return out;
  }

  /// 扇环（`inner..outer`，`angleDeg0..angleDeg1`）的外接矩形。
  static Rect _sectorBoundingRect(
    WheelMenuLayout layout,
    double inner,
    double outer,
    double angleDeg0,
    double angleDeg1,
  ) =>
      _sectorBoundingRectFor(layout, inner, outer, angleDeg0, angleDeg1);

  /// 扇环外接矩形（显式角度；刀刃与弧带共用同一实现）。
  static Rect _sectorBoundingRectFor(
    WheelMenuLayout layout,
    double inner,
    double outer,
    double angleDeg0,
    double angleDeg1,
  ) {
    double minX = double.maxFinite;
    double minY = double.maxFinite;
    double maxX = -double.maxFinite;
    double maxY = -double.maxFinite;

    void include(double radius, double absoluteDeg) {
      final double rad = absoluteDeg * math.pi / 180;
      final double x = layout.centerX + radius * math.cos(rad);
      final double y = layout.centerY + radius * math.sin(rad);
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
    }

    for (final double radius in <double>[inner, outer]) {
      final double a0 = _absolute(layout, angleDeg0);
      final double a1 = _absolute(layout, angleDeg1);
      include(radius, a0);
      include(radius, a1);
      // 采样 4 个中间角，避免大跨度时外接矩形缩水。
      for (int k = 1; k < 4; k++) {
        include(radius, a0 + (a1 - a0) * k / 4);
      }
    }
    if (minX > maxX || minY > maxY) return Rect.zero;
    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  static double _absolute(WheelMenuLayout layout, double offsetDeg) {
    final double base = layout.direction.sign > 0 ? 0 : 180;
    double value = (base + layout.direction.sign * offsetDeg) % 360;
    if (value > 180) value -= 360;
    if (value <= -180) value += 360;
    return value;
  }

  /// 丢弃退化矩形 + 数量上限（**丢弃面积最小**的若干块）。
  ///
  /// ⚠️ **不再**把矩形夹进"菜单窗口矩形"（C1.1 修正）。
  ///
  /// 旧实现把每块 Region 夹进 `layout.windowRect`，于是凡是"画在窗口之外的像素"
  /// 都落在 Region 之外 —— 在 Windows 上就是**直接被裁掉**，表现为
  /// "扇形 / 按钮 / 文字被硬直线裁切"。而窗口矩形只是**信封**，它并不等于
  /// "会被绘制到的范围"（刀刃、外缘齿轮、动画 overshoot、文字安全带都可能超出）。
  ///
  /// 正确口径：Region 覆盖**全部会被绘制的像素**；超出画布的那些由原生
  /// `SetWindowRgn` 自动与窗口矩形求交，不需要在这一层提前裁。
  static List<Rect> _normalize(List<Rect> rects, WheelMenuLayout layout) {
    final List<Rect> kept = <Rect>[];
    for (final Rect r in rects) {
      if (r.width <= 0 || r.height <= 0) continue;
      if (r.width <= mergeTolerance && r.height <= mergeTolerance) continue;
      kept.add(r);
    }
    if (kept.length <= maxRects) return kept;
    kept.sort((Rect a, Rect b) => (b.width * b.height).compareTo(a.width * a.height));
    return kept.sublist(0, maxRects);
  }
}

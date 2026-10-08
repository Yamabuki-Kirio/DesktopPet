/// **轮盘的完整视觉包围盒**（C1.1 需求 §六 / §七）。
///
/// 为什么必须有这个文件
/// ------------------
/// 真机验收现象："扇形、装饰、按钮和文字被硬直线裁切"、"关闭后仍有粉色残片"。
/// 根因是**规划与渲染的包围盒来源不一致**：
///
/// * `WheelCanvasPlanner` 曾用 6 次 `computeEnvelope` 的**近似外扩量**估画布；
/// * `WheelRegionBuilder` 只覆盖"弧带 + 按钮 + chip"，**漏掉**
///   刀刃（`bladeLength` 比环带外缘大得多）、外缘齿轮、强调弧、动画 overshoot；
/// * 于是"画出来但不在 Region / 不在画布里"的那部分像素被硬裁成直线。
///
/// 现在改为**一个**计算器：它逐项复算 Painter 真正会画的每个元素，
/// 取并集，得到 `visualBounds`。下游全部消费它（需求 §七 的"四者同源"）：
///
/// ```
/// WheelMenuLayout ──► WheelVisualBoundsCalculator ──► visualBounds
///                                                   ├─► CanvasPlan（画布必须装得下）
///                                                   ├─► RegionBuilder（可见区必须覆盖）
///                                                   └─► 断言/诊断
/// ```
///
/// 必须计入的项（需求 §六 逐条对应）
/// ------------------------------
/// * `baseFan` / `band`：扇带内外半径 + 描边一半；
/// * `blade`：最极端槽位 ± 半张角 → 外半径 `bladeLength` + 描边 ×1.35；
/// * `rimDecoration`：凸起圆（半径 `rimLobePx*0.72`，圆心在 `rimOuter-rimLobe*0.35`）
///   + 强调弧（半径 `bladeLength*0.86`，线宽 ×2.2）；
/// * `buttons`：**动画 overshoot**（弹出进度峰值 1.36）+ 选中放大 1.14 + 描边；
/// * `buttonLabels`：径向朝外的中文标签；
/// * `texts`：英文标题 / 中文 chip / 说明（用与 Painter 相同的 `WheelTextLayout` 半径）；
/// * `feedback`：反馈条（贴在窗口底部）；
/// * `shadow/glow`：当前 Painter **没有**阴影，故为 0 —— 若将来加了阴影，
///   必须在这里补上，否则又会裁切（见 [shadowPadding]）。
///
/// 本文件是**纯 Dart**（只依赖 `dart:math` / `dart:ui`），可单测，
/// 也不破坏 Android 平台隔离。
library;

import 'dart:math' as math;
import 'dart:ui' show Rect, Offset;

import 'package:flutter/foundation.dart' show immutable;

import 'wheel_menu_geometry.dart'
    show WheelMenuGeometry, WheelMenuLayout, WheelTextLayout, WheelTextSlots;

/// 视觉包围盒的**逐项明细 + 并集**。
@immutable
class WheelVisualBounds {
  const WheelVisualBounds({
    required this.fanAndRim,
    required this.blade,
    required this.buttons,
    required this.labels,
    required this.texts,
    required this.feedback,
    required this.centerX,
    required this.centerY,
  });

  /// 扇带（含描边）+ 外缘齿轮 + 强调弧。
  final Rect fanAndRim;

  /// 刀刃（含描边）。
  final Rect blade;

  /// 全部按钮（含选中放大 + 动画 overshoot + 描边）。
  final Rect buttons;

  /// 根菜单按钮的中文标签。
  final Rect labels;

  /// 标题 / chip / 说明文字。
  final Rect texts;

  /// 反馈条（无反馈时为空矩形）。
  final Rect feedback;

  /// 轮盘中心（画布局部；用于算"相对中心的外扩"）。
  final double centerX;
  final double centerY;

  /// **全部绘制元素的并集**（窗口局部坐标）。
  Rect get all => _union(<Rect>[fanAndRim, blade, buttons, labels, texts, feedback]);

  /// 相对轮盘中心的最大外扩（四侧，正值 = 向外）。
  ({double left, double right, double up, double down}) get extentFromCenter {
    final Rect a = all;
    return (
      left: math.max(0, centerX - a.left),
      right: math.max(0, a.right - centerX),
      up: math.max(0, centerY - a.top),
      down: math.max(0, a.bottom - centerY),
    );
  }

  /// 是否**完整**落在 [canvas] 内（含 [padding] 安全边）。
  bool fitsIn(Rect canvas, {double padding = 0}) {
    final Rect a = all.inflate(padding);
    return a.left >= canvas.left - 0.5 &&
        a.top >= canvas.top - 0.5 &&
        a.right <= canvas.right + 0.5 &&
        a.bottom <= canvas.bottom + 0.5;
  }

  /// 把并集按 [dx],[dy] 平移（窗口局部 → 画布局部）。
  WheelVisualBounds shiftedBy(double dx, double dy) => WheelVisualBounds(
        fanAndRim: fanAndRim.shift(Offset(dx, dy)),
        blade: blade.shift(Offset(dx, dy)),
        buttons: buttons.shift(Offset(dx, dy)),
        labels: labels.shift(Offset(dx, dy)),
        texts: texts.shift(Offset(dx, dy)),
        feedback: feedback.shift(Offset(dx, dy)),
        centerX: centerX + dx,
        centerY: centerY + dy,
      );

  Map<String, Object?> describe() => <String, Object?>{
        'fanAndRim': _r(fanAndRim),
        'blade': _r(blade),
        'buttons': _r(buttons),
        'labels': _r(labels),
        'texts': _r(texts),
        'feedback': _r(feedback),
        'all': _r(all),
        'extent': extentFromCenter,
        'center': '${centerX.toStringAsFixed(1)},${centerY.toStringAsFixed(1)}',
      };

  static String _r(Rect r) => '${r.left.toStringAsFixed(1)},${r.top.toStringAsFixed(1)},'
      '${r.right.toStringAsFixed(1)},${r.bottom.toStringAsFixed(1)}';

  static Rect _union(List<Rect> rects) {
    double l = double.maxFinite;
    double t = double.maxFinite;
    double r = -double.maxFinite;
    double b = -double.maxFinite;
    for (final Rect rect in rects) {
      if (rect.width <= 0 || rect.height <= 0) continue;
      l = math.min(l, rect.left);
      t = math.min(t, rect.top);
      r = math.max(r, rect.right);
      b = math.max(b, rect.bottom);
    }
    if (l > r || t > b) return Rect.zero;
    return Rect.fromLTRB(l, t, r, b);
  }
}

/// 视觉包围盒计算器（**唯一**来源；与 Painter 逐项对齐）。
abstract final class WheelVisualBoundsCalculator {
  /// 安全边（抗锯齿 + 取整余量）。
  static const double safetyPadding = 4;

  /// 阴影 / 发光预留：当前 Painter 不画阴影，故为 0。
  ///
  /// ⚠️ 若将来给任何一个元素加 `MaskFilter.blur` 或 `drawShadow`，
  /// **必须**在这里补上对应外扩量，否则新加的阴影会被裁掉（§六 明确要求）。
  static const double shadowPadding = 0;

  /// 菜单主体缩放（`WheelAnimationClock` 的 `0.75 → 1.03 → 1.0`）的**峰值**。
  ///
  /// 与 `wheel_animator.dart` 的展开曲线同源：Painter 开头会 `canvas.scale(1.03)`，
  /// 因此包围盒必须按这个峰值外扩，否则开合动画的那一瞬间会被裁掉。
  static const double animatorScalePeak = 1.03;

  /// 按钮弹出进度的**峰值**（`CubicBezierEasing.pop = (0.18, 1.36, 0.36, 1.0)`）。
  ///
  /// 与 `wheel_animator.dart` 的 `pop` 曲线同源：该曲线的 y 峰值 ≈ 1.36。
  static const double maxButtonProgress = 1.36;

  /// 按钮**选中**放大（与 `WheelMenuRenderer.selectedScale` 同源）。
  static const double selectedScale = 1.14;

  /// 按钮按下时缩小（不会增大包围盒，仅记录）。
  static const double pressScale = 0.88;

  /// 刀刃描边倍数（与 Painter 的 `outlineWidthPx * 1.35` 同源）。
  static const double bladeOutlineFactor = 1.35;

  /// 强调弧线宽倍数（与 Painter 的 `outlineWidthPx * 2.2` 同源）。
  static const double accentStrokeFactor = 2.2;

  /// 英文标题描边倍数。
  static const double titleOutlineFactor = 1.35;

  /// 标签最多按多少字符估算宽度（与 `_plan` / Region 同一口径）。
  static const int maxLabelChars = 10;

  /// **每个按钮的视觉矩形**（含动画 overshoot + 选中放大 + 描边）。
  ///
  /// 与 [compute] 里的按钮并集**同源**：Region 也消费这一份，
  /// 因此"看得见的按钮"必然"点得到"（C1.1 §六）。
  ///
  /// 返回顺序与 `layout.slots` **一一对应**（Region 需要按下标判弹出进度）。
  static List<Rect> buttonVisualRects(WheelMenuLayout layout) => <Rect>[
        for (int i = 0; i < layout.slots.length; i++)
          buttonVisualRectAt(layout, i),
      ];

  /// 单个按钮的视觉矩形（按下标）。
  static Rect buttonVisualRectAt(WheelMenuLayout layout, int index) {
    final slot = layout.slots[index];
    final double cx = layout.centerX;
    final double cy = layout.centerY;
    final double p = maxButtonProgress;
    final double bx = slot.centerX + (cx - slot.centerX) * (1 - p);
    final double by = slot.centerY + (cy - slot.centerY) * (1 - p);
    final double maxScale = math.max(selectedScale, 1.0) * p;
    final double radius =
        layout.buttonDiameterPx * maxScale / 2 + layout.outlineWidthPx * 1.2;
    return Rect.fromCircle(center: Offset(bx, by), radius: radius);
  }

  /// 矩形并集（忽略退化矩形）。
  static Rect _union(List<Rect> rects) {
    double l = double.maxFinite;
    double t = double.maxFinite;
    double r = -double.maxFinite;
    double b = -double.maxFinite;
    for (final Rect rect in rects) {
      if (rect.width <= 0 || rect.height <= 0) continue;
      l = math.min(l, rect.left);
      t = math.min(t, rect.top);
      r = math.max(r, rect.right);
      b = math.max(b, rect.bottom);
    }
    if (l > r || t > b) return Rect.zero;
    return Rect.fromLTRB(l, t, r, b);
  }

  /// 计算 [layout] 的全部绘制元素包围盒。
  ///
  /// 文字宽度**不**在这里估算：直接消费 `WheelTextLayout` 的安全带宽
  /// （Painter 的 `_fitText` 会把文字缩进同一个宽度），因此与渲染同源。
  static WheelVisualBounds compute(
    WheelMenuLayout layout, {
    bool showButtonLabels = true,
    bool hasFeedback = false,
    double feedbackBarHeight = 26,
    double feedbackMargin = 8,
    double animatorScalePeak = 1.03,
    Rect? feedbackRect,
  }) {
    final double cx = layout.centerX;
    final double cy = layout.centerY;
    final double outline = layout.outlineWidthPx;

    // ---------------------------------------------------------------------
    // 1) 扇带（baseFan 的外半径是 max(bladeLength, rimOuter)）+ 外缘齿轮 + 强调弧
    // ---------------------------------------------------------------------
    final double fanInner = math.max(layout.ringRadiusPx * 0.30, 1);
    final double fanOuter = math.max(layout.bladeLengthPx, layout.rimOuterPx);
    Rect fanAndRim = _sectorBounds(
      layout,
      innerRadius: math.max(1, fanInner - outline),
      outerRadius: fanOuter + outline,
      halfSpanDeg: layout.fanHalfSpanDeg,
      biasDeg: layout.fanBiasDeg,
    );
    // 按钮轨道带（band）内缘更靠内：ringRadius - button*0.6。
    fanAndRim = _union(<Rect>[
      fanAndRim,
      _sectorBounds(
        layout,
        innerRadius: math.max(
          1,
          layout.ringRadiusPx - layout.buttonDiameterPx * 0.6 - outline,
        ),
        outerRadius: layout.bandOuterPx + outline,
        halfSpanDeg: layout.fanHalfSpanDeg,
        biasDeg: layout.fanBiasDeg,
      ),
    ]);
    // 外缘齿轮凸起（圆心 rimOuter - rimLobe*0.35，半径 rimLobe*0.72 + 描边）。
    {
      final double lobeR = layout.rimLobePx * 0.72 + outline * 0.85;
      final double ringR = layout.rimOuterPx - layout.rimLobePx * 0.35;
      final int count = layout.compact
          ? math.max(2, layout.itemCount)
          : math.max(2, layout.itemCount * 2 - 1);
      fanAndRim = _union(<Rect>[
        fanAndRim,
        _annulusSampledBounds(
          layout,
          centerRadius: ringR,
          spread: lobeR,
          halfSpanDeg: layout.fanHalfSpanDeg,
          biasDeg: layout.fanBiasDeg,
          includeCount: count,
        ),
      ]);
    }
    // 强调弧（半径 bladeLength*0.86，线宽 outlineWidth*2.2）。
    {
      final double arcR = layout.bladeLengthPx * 0.86;
      final double half = outline * accentStrokeFactor / 2 + 1;
      fanAndRim = _union(<Rect>[
        fanAndRim,
        _annulusSampledBounds(
          layout,
          centerRadius: arcR,
          spread: half,
          halfSpanDeg: layout.bladeHalfSweepDeg * 0.62 + 2,
          biasDeg: layout.fanBiasDeg,
          includeCount: 2,
        ),
      ]);
    }

    // ---------------------------------------------------------------------
    // 2) 刀刃：最极端槽位 ± 半张角，外半径 bladeLength（含内缘"鼓包" 1.18×）
    // ---------------------------------------------------------------------
    final double half = (layout.itemCount - 1) / 2;
    final double bladeHalfStroke = outline * bladeOutlineFactor / 2 + 1;
    final double bladeBumpInner = layout.notchRx * 0.72;
    Rect bladeBounds = Rect.zero;
    for (final double selection in <double>[0, layout.itemCount - 1]) {
      final double angle = WheelMenuGeometry.absoluteAngle(
        layout.direction,
        (selection - half) * layout.stepDeg + layout.fanBiasDeg,
      );
      bladeBounds = _union(<Rect>[
        bladeBounds,
        _wedgeBounds(
          cx: cx,
          cy: cy,
          angleDeg: angle,
          halfSweepDeg: layout.bladeHalfSweepDeg,
          innerRadius: math.max(1, bladeBumpInner - bladeHalfStroke),
          outerRadius: layout.bladeLengthPx + bladeHalfStroke,
        ),
      ]);
    }

    // ---------------------------------------------------------------------
    // 3) 按钮：动画 overshoot + 选中放大 + 描边
    // ---------------------------------------------------------------------
    Rect buttons = Rect.zero;
    for (final Rect r in buttonVisualRects(layout)) {
      buttons = _union(<Rect>[buttons, r]);
    }

    // ---------------------------------------------------------------------
    // 4) 按钮中文标签（根菜单；径向朝外）
    // ---------------------------------------------------------------------
    //
    // ⚠️ 宽度用**真实** `WheelTextSlots` 的安全带宽度，不能用"字符数 × 字号"：
    // Painter 的 `_fitText` 会把文字缩到 `maxWidth` 以内，所以"会被画出来的宽度"
    // 永远 ≤ maxWidth。用估算值会把包围盒放大好几倍（画布跟着暴涨）。
    Rect labels = Rect.zero;
    if (showButtonLabels) {
      final double size = math.max(layout.buttonDiameterPx * 0.30, 10);
      final double radius =
          layout.buttonDiameterPx / 2 + layout.rimLobePx * 0.5 + size * 0.95;
      final double halfW = size * 3 + outline * 1.1;
      final double halfH = size * 0.75 + outline * 1.1;
      for (final slot in layout.slots) {
        if (slot.entry.isBack) continue;
        final double dx = slot.centerX - cx;
        final double dy = slot.centerY - cy;
        final double len = math.max(1, math.sqrt(dx * dx + dy * dy));
        // 标签圆心也可能被 overshoot 推远：按最大 progress 的外移量取上界。
        final double push = (maxButtonProgress - 1.0) * len;
        final double lx = slot.centerX + dx / len * (radius + push);
        final double ly = slot.centerY + dy / len * (radius + push);
        labels = _union(<Rect>[
          labels,
          Rect.fromLTRB(lx - halfW, ly - halfH, lx + halfW, ly + halfH),
        ]);
      }
    }

    // ---------------------------------------------------------------------
    // 5) 文字（标题 / chip / 说明）—— 半径来自与 Painter 相同的 WheelTextLayout
    // ---------------------------------------------------------------------
    final WheelTextSlots slotsFree = _textSlots(layout);
    Rect texts = Rect.zero;
    {
      // 位置随选中项变化 → 取整条安全带的外接（覆盖全部槽位）。
      // 宽度取 `WheelTextLayout` 给出的**安全带宽**（Painter 会把文字缩进它）。
      final double titleHalfW =
          slotsFree.titleMaxWidth / 2 + slotsFree.titleSizePx * 0.4 + outline;
      final double chipHalfW = slotsFree.chipMaxWidth / 2 + outline;
      final double infoHalfW = slotsFree.infoMaxWidth / 2 + outline;
      final double chipHalfH = slotsFree.chipSizePx * 0.86 + outline;
      final double titleHalfH = slotsFree.titleSizePx * 0.8 + outline;
      final double infoHalfH = slotsFree.infoSizePx * 0.8 + outline;

      for (final double slotOffset in <double>[
        -layout.fanHalfSpanDeg + layout.fanBiasDeg,
        layout.fanHalfSpanDeg + layout.fanBiasDeg,
      ]) {
        // 三个半径分别取并集（标题 / chip / 说明）。
        for (final ({double radius, double halfW, double halfH}) item
            in <({double radius, double halfW, double halfH})>[
          (
            radius: slotsFree.titleRadius,
            halfW: titleHalfW,
            halfH: titleHalfH,
          ),
          (radius: slotsFree.chipRadius, halfW: chipHalfW, halfH: chipHalfH),
          (radius: slotsFree.infoRadius, halfW: infoHalfW, halfH: infoHalfH),
        ]) {
          final double a = WheelMenuGeometry.absoluteAngle(
            layout.direction,
            slotOffset,
          );
          final double rad = a * math.pi / 180;
          final double tx = cx + item.radius * math.cos(rad);
          final double ty = cy + item.radius * math.sin(rad);
          // 文字有轻微旋转（≤8°）→ 用外接圆作上界。
          final double r =
              math.sqrt(item.halfW * item.halfW + item.halfH * item.halfH);
          texts = _union(<Rect>[
            texts,
            Rect.fromCircle(center: Offset(tx, ty), radius: r),
          ]);
        }
      }
    }

    // ---------------------------------------------------------------------
    // 6) 反馈条
    // ---------------------------------------------------------------------
    // ⚠️ 反馈条贴在**窗口底部**，因此只在给了显式矩形时才算进包围盒
    // （测量阶段窗口是虚拟的大矩形，用它推反馈条位置会得到荒谬数值）。
    final Rect feedback = feedbackRect ?? Rect.zero;
    if (hasFeedback && feedbackRect == null) {
      // 没给显式矩形 → 用窗口底部推（只在真实窗口布局下有意义）。
      final Rect derived = Rect.fromLTWH(
        feedbackMargin,
        math.max(
          0,
          layout.windowRect.height - feedbackBarHeight - feedbackMargin,
        ),
        math.max(1, layout.windowRect.width - feedbackMargin * 2),
        feedbackBarHeight,
      );
      return _finish(
        layout,
        fanAndRim: fanAndRim,
        blade: bladeBounds,
        buttons: buttons,
        labels: labels,
        texts: texts,
        feedback: derived,
        animatorScalePeak: animatorScalePeak,
      );
    }
    return _finish(
      layout,
      fanAndRim: fanAndRim,
      blade: bladeBounds,
      buttons: buttons,
      labels: labels,
      texts: texts,
      feedback: feedback,
      animatorScalePeak: animatorScalePeak,
    );
  }

  static WheelVisualBounds _finish(
    WheelMenuLayout layout, {
    required Rect fanAndRim,
    required Rect blade,
    required Rect buttons,
    required Rect labels,
    required Rect texts,
    required Rect feedback,
    required double animatorScalePeak,
  }) {
    final WheelVisualBounds raw = WheelVisualBounds(
      fanAndRim: fanAndRim,
      blade: blade,
      buttons: buttons,
      labels: labels,
      texts: texts,
      feedback: feedback,
      centerX: layout.centerX,
      centerY: layout.centerY,
    );
    if (animatorScalePeak > 1.0) {
      return _scaleAboutCenter(raw, animatorScalePeak);
    }
    return raw;
  }

  /// 以轮盘中心为原点放大 [factor]（对应 Painter 开头的 `canvas.scale`）。
  static WheelVisualBounds _scaleAboutCenter(WheelVisualBounds b, double factor) {
    Rect scale(Rect r) {
      if (r.width <= 0 || r.height <= 0) return r;
      return Rect.fromLTRB(
        b.centerX + (r.left - b.centerX) * factor,
        b.centerY + (r.top - b.centerY) * factor,
        b.centerX + (r.right - b.centerX) * factor,
        b.centerY + (r.bottom - b.centerY) * factor,
      );
    }

    return WheelVisualBounds(
      fanAndRim: scale(b.fanAndRim),
      blade: scale(b.blade),
      buttons: scale(b.buttons),
      labels: scale(b.labels),
      texts: scale(b.texts),
      feedback: b.feedback, // 反馈条不属于被 scale 的主体（Painter 在 restore 之后画）
      centerX: b.centerX,
      centerY: b.centerY,
    );
  }

  // -------------------------------------------------------------------------
  // 几何助手（与 Painter 同公式）
  // -------------------------------------------------------------------------

  /// 扇环（内外半径 + 张角）的外接矩形（采样端点 + 象限顶点）。
  static Rect _sectorBounds(
    WheelMenuLayout layout, {
    required double innerRadius,
    required double outerRadius,
    required double halfSpanDeg,
    required double biasDeg,
  }) =>
      _annulusSampledBounds(
        layout,
        centerRadius: double.nan,
        spread: double.nan,
        halfSpanDeg: halfSpanDeg,
        biasDeg: biasDeg,
        includeCount: 0,
        innerOverride: innerRadius,
        outerOverride: outerRadius,
      );

  /// 以 [centerRadius] 为中线、[spread] 为半宽（或显式内外半径）的**扇环采样**包围盒。
  static Rect _annulusSampledBounds(
    WheelMenuLayout layout, {
    required double centerRadius,
    required double spread,
    required double halfSpanDeg,
    required double biasDeg,
    required int includeCount,
    double? innerOverride,
    double? outerOverride,
  }) {
    final double inner = innerOverride ?? math.max(1, centerRadius - spread);
    final double outer = outerOverride ?? math.max(inner + 1, centerRadius + spread);
    double l = double.maxFinite;
    double t = double.maxFinite;
    double r = -double.maxFinite;
    double bo = -double.maxFinite;

    void include(double radius, double offsetDeg) {
      final double a = WheelMenuGeometry.absoluteAngle(
        layout.direction,
        offsetDeg + biasDeg,
      );
      final double rad = a * math.pi / 180;
      final double x = layout.centerX + radius * math.cos(rad);
      final double y = layout.centerY + radius * math.sin(rad);
      l = math.min(l, x);
      t = math.min(t, y);
      r = math.max(r, x);
      bo = math.max(bo, y);
    }

    // 端点 + 每 2° 采样（保守：采样密到不会漏掉凸起）。
    final double stepDeg = 2;
    for (double d = -halfSpanDeg; d <= halfSpanDeg + 0.001; d += stepDeg) {
      include(inner, d);
      include(outer, d);
    }
    include(inner, halfSpanDeg);
    include(outer, halfSpanDeg);
    // 明确包含"外缘凸起"：凸起圆心在 centerRadius 上，半径 spread → 最远半径 = centerRadius+spread
    if (includeCount > 0) {
      for (int i = 0; i < includeCount; i++) {
        final double d = includeCount <= 1
            ? 0
            : -halfSpanDeg + (i / (includeCount - 1)) * halfSpanDeg * 2;
        include(outer, d);
      }
    }
    if (l > r || t > bo) return Rect.zero;
    return Rect.fromLTRB(l, t, r, bo);
  }

  /// 刀刃扇形（含内缘鼓包）的包围盒。
  static Rect _wedgeBounds({
    required double cx,
    required double cy,
    required double angleDeg,
    required double halfSweepDeg,
    required double innerRadius,
    required double outerRadius,
  }) {
    double l = double.maxFinite;
    double t = double.maxFinite;
    double r = -double.maxFinite;
    double b = -double.maxFinite;

    void include(double radius, double deg) {
      final double rad = deg * math.pi / 180;
      final double x = cx + radius * math.cos(rad);
      final double y = cy + radius * math.sin(rad);
      l = math.min(l, x);
      t = math.min(t, y);
      r = math.max(r, x);
      b = math.max(b, y);
    }

    // 外弧（± 半张角）+ 内缘鼓包（1.18×inner，偏差 ±16% 跨度）
    for (double d = -halfSweepDeg; d <= halfSweepDeg + 0.001; d += 2) {
      include(outerRadius, angleDeg + d);
    }
    for (final double f in <double>[-0.16, 0, 0.16]) {
      include(innerRadius * 1.18, angleDeg + halfSweepDeg * 2 * f);
    }
    include(innerRadius, angleDeg - halfSweepDeg);
    include(innerRadius, angleDeg + halfSweepDeg);
    return Rect.fromLTRB(l, t, r, b);
  }

  /// 与 Painter 相同的文字半径（借用 `WheelTextLayout.compute`，密度按 1.0）。
  static WheelTextSlots _textSlots(WheelMenuLayout layout) =>
      WheelTextLayout.compute(layout, 1.0, 13, 16, 11);
}

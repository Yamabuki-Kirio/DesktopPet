/// 正式 P3P 轮盘的**渲染器**（**Android `WheelMenuRenderer.kt` 的 1:1 移植**）。
///
/// 绘制顺序严格照抄 Android（见 docs/37 §8.1）：
///
/// ```
/// 1. verifyFan        （仅架构验证期，默认关闭）
/// 2. baseFan          （菜单底色：secondary→background 0.40，alpha 108）
/// 3. blade            （高亮扇区"刀刃"，渐变 primary→secondary + 黑描边 ×1.35）
/// 4. band             （按钮轨道带：background 填充 + outline 描边）
/// 5. rimDecoration    （外缘齿轮凸起 + 黄色强调弧）
/// 6. texts            （英文大标题 + 中文 chip + 说明）
/// 7. buttons          （圆按钮 + 原创 Path 图标）
/// 8. buttonLabels     （仅根菜单，径向朝外）
/// 9. debug            （诊断边界，默认关闭）
/// ```
///
/// **禁止**：整圆 / 整环底板、挖洞、Material 图标、硬编码色值（颜色只来自主题）。
///
/// Windows 平台差异（决策五，已记录，不改视觉）：
/// * Flutter 的文字 API 是 `TextPainter`（左上角定位）而非 `Canvas.drawText`（基线定位），
///   因此这里统一做基线对齐换算，字号 / 位置 / 描边宽度数值**不变**；
/// * Android 的 `textSkewX = -0.10`（轻微斜体）在 Flutter 用 `FontStyle.italic` 表达；
/// * Android 的 `letterSpacing` 单位是 em，Flutter 是逻辑像素，故换算为 `em × 字号`。
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../menu/menu_contract.dart' show MenuLevel, MenuNode;
import '../../menu/wheel_animator.dart' show WheelAnimationFrame;
import '../../menu/wheel_menu_geometry.dart'
    show WheelMenuGeometry, WheelMenuLayout, WheelTextLayout, WheelTextSlots;
import '../../menu/wheel_theme.dart' show WheelMenuTheme, WheelMenuThemes;
import 'wheel_icons.dart' show WheelMenuIcons;

/// 渲染输入（渲染层**不查任何数据源**，一切都从参数来）。
class WheelRenderParams {
  const WheelRenderParams({
    required this.layout,
    required this.level,
    required this.frame,
    required this.activeIndex,
    required this.theme,
    this.highlightIndex = -1,
    this.infoText,
    this.debugBounds = false,
    this.density = 1,
    this.showButtonLabels = true,
    this.verifyFan = false,
  });

  final WheelMenuLayout layout;
  final MenuLevel level;
  final WheelAnimationFrame frame;

  /// 当前高亮槽位（滑选 / 悬停中的临时项优先）。
  ///
  /// **只**驱动"弧形文字 / 实时信息"的定位锚点（恒为合法索引）。
  final int activeIndex;

  /// **按钮高亮**索引（C1.1.2 C1）：`-1` = 不高亮任何按钮。
  ///
  /// 与 [activeIndex] 分离，使"鼠标不在按钮上"既不高亮按钮、
  /// 又不会让标题 / chip 消失。
  final int highlightIndex;

  final WheelMenuTheme theme;

  /// 选中项的实时信息（只读快照；由调用方在选中变化时刷新，**不在 paint 里算**）。
  final String? infoText;

  /// 诊断模式：画出窗口矩形、环带边界与缺口椭圆。
  final bool debugBounds;

  /// 屏幕密度（最小字号按 sp 换算用）。
  final double density;

  /// 根菜单是否画出按钮中文标签。
  final bool showButtonLabels;

  /// 架构验证扇区（仅验证期）。
  final bool verifyFan;
}

/// 轮盘渲染器：每帧画一次（复用 Paint / Path，不在循环里分配画布对象）。
class WheelMenuRenderer {
  WheelMenuRenderer();

  final Paint _fill = Paint()..isAntiAlias = true;
  final Paint _stroke = Paint()
    ..isAntiAlias = true
    ..style = PaintingStyle.stroke
    ..strokeJoin = StrokeJoin.round
    ..strokeCap = StrokeCap.round;
  final Paint _iconPaint = Paint()..isAntiAlias = true;
  final Path _path = Path();

  void draw(Canvas canvas, WheelRenderParams params) {
    final WheelAnimationFrame frame = params.frame;
    if (frame.openProgress <= 0.004) return;
    final WheelMenuLayout layout = params.layout;
    final double alpha = frame.openProgress.clamp(0.0, 1.0);

    canvas.save();
    // 与 Android 同口径：围绕窗口内轮盘中心缩放 / 旋转。
    canvas.translate(layout.centerX, layout.centerY);
    canvas.scale(frame.scale);
    canvas.rotate(frame.rotationDeg * math.pi / 180);
    canvas.translate(-layout.centerX, -layout.centerY);

    // 1) 架构验证扇区（仅验证期）
    if (params.verifyFan) _drawVerifyFan(canvas, params, alpha);
    // 2) 真正的菜单底色：打开方向的连续扇面
    _drawBaseFan(canvas, params, alpha);
    // 3) 刀刃
    _drawBlade(canvas, params, alpha);
    // 4) 按钮轨道带
    _drawBand(canvas, params, alpha);
    // 5) 外缘装饰
    _drawRimDecoration(canvas, params, alpha);
    // 6) 文字
    _drawTexts(canvas, params, alpha);
    // 7) 按钮
    _drawButtons(canvas, params, alpha);
    // 8) 根菜单按钮标签
    _drawButtonLabels(canvas, params, alpha);
    // 9) 诊断
    if (params.debugBounds) _drawDebug(canvas, params, alpha);

    canvas.restore();
  }

  // ------------------------------------------------------------------
  // 底色与刀刃
  // ------------------------------------------------------------------

  void _drawVerifyFan(Canvas canvas, WheelRenderParams params, double alpha) {
    if (alpha <= 0.004) return;
    final WheelMenuLayout layout = params.layout;
    const double half = verifyFanSpanDeg / 2;
    final double start =
        WheelMenuGeometry.absoluteAngle(layout.direction, layout.fanBiasDeg - half);
    final double sweep = layout.direction.sign * verifyFanSpanDeg;
    final double inner = layout.ringRadiusPx * verifyFanInnerRatio;
    final double outer = math.max(layout.bladeLengthPx, inner + 1);
    _buildFanBand(layout, start, sweep, inner, outer);
    _fill.shader = null;
    _fill.color = _withAlpha(params.theme.highlight, (verifyFanAlpha / 255) * alpha);
    canvas.drawPath(_path, _fill);
  }

  void _drawBaseFan(Canvas canvas, WheelRenderParams params, double alpha) {
    if (alpha <= 0.004) return;
    final WheelMenuLayout layout = params.layout;
    final double inner = math.max(layout.ringRadiusPx * baseFanInnerRatio, 1);
    final double outer = math.max(layout.bladeLengthPx, layout.rimOuterPx);
    final double start = WheelMenuGeometry.absoluteAngle(
      layout.direction,
      -layout.fanHalfSpanDeg + layout.fanBiasDeg,
    );
    final double sweep = layout.direction.sign * layout.fanHalfSpanDeg * 2;
    _buildFanBand(layout, start, sweep, inner, outer);
    _fill.shader = null;
    _fill.color = _withAlpha(
      WheelMenuThemes.baseFanColor(params.theme),
      alpha,
    );
    canvas.drawPath(_path, _fill);
  }

  void _drawBlade(Canvas canvas, WheelRenderParams params, double alpha) {
    final WheelMenuLayout layout = params.layout;
    final WheelMenuTheme theme = params.theme;
    final double selection = params.frame.selectionPosition;
    final int count = math.max(1, layout.itemCount);
    final double half = (count - 1) / 2;
    final double angle = WheelMenuGeometry.absoluteAngle(
      layout.direction,
      (selection - half) * layout.stepDeg + layout.fanBiasDeg,
    );
    final double innerRadius = layout.notchRx * 0.72;

    _buildWedge(layout, angle, layout.bladeHalfSweepDeg, innerRadius, layout.bladeLengthPx);
    _fill.shader = theme.gradientEnabled
        ? _bladeGradient(params, angle, innerRadius, layout.bladeLengthPx)
        : null;
    _fill.color = Color(theme.primary);
    canvas.drawPath(_path, _fill);
    _fill.shader = null;

    _stroke.shader = null;
    _stroke.color = _withAlpha(theme.outline, alpha);
    _stroke.strokeWidth = layout.outlineWidthPx * 1.35;
    canvas.drawPath(_path, _stroke);
  }

  Shader _bladeGradient(
    WheelRenderParams params,
    double angleDeg,
    double innerRadius,
    double outerRadius,
  ) {
    final WheelMenuLayout layout = params.layout;
    final double rad = angleDeg * math.pi / 180;
    final Offset a = Offset(
      layout.centerX + innerRadius * math.cos(rad),
      layout.centerY + innerRadius * math.sin(rad),
    );
    final Offset b = Offset(
      layout.centerX + outerRadius * math.cos(rad),
      layout.centerY + outerRadius * math.sin(rad),
    );
    return ui.Gradient.linear(a, b, <Color>[
      Color(params.theme.primary),
      Color(params.theme.secondary),
    ], <double>[0.0, 1.0], TileMode.clamp);
  }

  /// 刀刃扇形路径：内缘用参数化"鼓包"表达缺口咬合。
  void _buildWedge(
    WheelMenuLayout layout,
    double angleDeg,
    double halfSweepDeg,
    double innerRadius,
    double outerRadius,
  ) {
    final double cx = layout.centerX;
    final double cy = layout.centerY;
    final double start = (angleDeg - halfSweepDeg) * math.pi / 180;
    final double end = (angleDeg + halfSweepDeg) * math.pi / 180;
    final double corner = (outerRadius - innerRadius) * 0.28;

    _path.reset();
    _path.moveTo(cx + innerRadius * math.cos(start), cy + innerRadius * math.sin(start));
    final double mid = angleDeg * math.pi / 180;
    final double bump = innerRadius * 1.18;
    _path.quadraticBezierTo(
      cx + bump * math.cos(mid + (end - start) * 0.16),
      cy + bump * math.sin(mid + (end - start) * 0.16),
      cx + bump * math.cos(mid - (end - start) * 0.16),
      cy + bump * math.sin(mid - (end - start) * 0.16),
    );
    _path.lineTo(cx + innerRadius * math.cos(end), cy + innerRadius * math.sin(end));
    _path.lineTo(
      cx + (outerRadius - corner) * math.cos(end),
      cy + (outerRadius - corner) * math.sin(end),
    );
    _path.arcTo(
      Rect.fromCircle(center: Offset(cx, cy), radius: outerRadius),
      end,
      -(halfSweepDeg * 2) * 0.94 * math.pi / 180,
      false,
    );
    _path.lineTo(
      cx + (outerRadius - corner) * math.cos(start),
      cy + (outerRadius - corner) * math.sin(start),
    );
    _path.close();
  }

  void _drawBand(Canvas canvas, WheelRenderParams params, double alpha) {
    final WheelMenuLayout layout = params.layout;
    final WheelMenuTheme theme = params.theme;
    final double inner = math.max(layout.ringRadiusPx - layout.buttonDiameterPx * 0.6, 1);
    final double start = WheelMenuGeometry.absoluteAngle(
      layout.direction,
      -layout.fanHalfSpanDeg + layout.fanBiasDeg,
    );
    final double sweep = layout.direction.sign * layout.fanHalfSpanDeg * 2;
    _buildFanBand(layout, start, sweep, inner, layout.bandOuterPx);
    _fill.shader = null;
    _fill.color = _withAlpha(theme.background, alpha);
    canvas.drawPath(_path, _fill);
    _stroke.shader = null;
    _stroke.color = _withAlpha(theme.outline, alpha);
    _stroke.strokeWidth = layout.outlineWidthPx;
    canvas.drawPath(_path, _stroke);
  }

  /// 扇形带几何（baseFan / band 复用；**不画完整大圆盘**）。
  void _buildFanBand(
    WheelMenuLayout layout,
    double startDeg,
    double sweepDeg,
    double innerRadius,
    double outerRadius,
  ) {
    final double cx = layout.centerX;
    final double cy = layout.centerY;
    final double inner = math.max(innerRadius, 1);
    final double outerR = math.max(outerRadius, inner + 1);
    final double start = startDeg * math.pi / 180;
    final double sweep = sweepDeg * math.pi / 180;

    _path.reset();
    _path.moveTo(cx + outerR * math.cos(start), cy + outerR * math.sin(start));
    _path.arcTo(Rect.fromCircle(center: Offset(cx, cy), radius: outerR), start, sweep, false);
    _path.arcTo(
      Rect.fromCircle(center: Offset(cx, cy), radius: inner),
      start + sweep,
      -sweep,
      false,
    );
    _path.close();
  }

  void _drawRimDecoration(Canvas canvas, WheelRenderParams params, double alpha) {
    final WheelMenuLayout layout = params.layout;
    final WheelMenuTheme theme = params.theme;
    final int count = layout.compact
        ? math.max(2, layout.itemCount)
        : math.max(2, layout.itemCount * 2 - 1);
    final double span = layout.fanHalfSpanDeg;
    final double bias = layout.fanBiasDeg;
    _fill.shader = null;
    _fill.color = _withAlpha(theme.background, alpha);
    _stroke.color = _withAlpha(theme.outline, alpha);
    _stroke.strokeWidth = layout.outlineWidthPx * 0.85;
    for (int i = 0; i < count; i++) {
      final double t = count <= 1 ? 0.5 : i / (count - 1);
      final double offsetAngle = -span + t * span * 2 + bias;
      final double angle = WheelMenuGeometry.absoluteAngle(layout.direction, offsetAngle) *
          math.pi /
          180;
      final double radius = layout.rimOuterPx - layout.rimLobePx * 0.35;
      final Offset center = Offset(
        layout.centerX + radius * math.cos(angle),
        layout.centerY + radius * math.sin(angle),
      );
      _fill.style = PaintingStyle.fill;
      canvas.drawCircle(center, layout.rimLobePx * 0.72, _fill);
      _stroke.style = PaintingStyle.stroke;
      canvas.drawCircle(center, layout.rimLobePx * 0.72, _stroke);
    }
    // 高亮装饰弧（"进度条"意象，用主题 highlight 色）
    final double arcRadius = layout.bladeLengthPx * 0.86;
    final Rect rect = Rect.fromCircle(center: Offset(layout.centerX, layout.centerY), radius: arcRadius);
    _stroke.color = _withAlpha(theme.highlight, alpha);
    _stroke.strokeWidth = layout.outlineWidthPx * 2.2;
    _stroke.strokeCap = StrokeCap.round;
    final double selectionAngle = WheelMenuGeometry.absoluteAngle(
      layout.direction,
      (params.frame.selectionPosition - (layout.itemCount - 1) / 2) * layout.stepDeg +
          layout.fanBiasDeg,
    );
    final double sweepDirection =
        layout.direction.sign > 0 ? 1 : -1;
    canvas.drawArc(
      rect,
      (selectionAngle - layout.bladeHalfSweepDeg * 0.62 * sweepDirection) * math.pi / 180,
      layout.bladeHalfSweepDeg * 1.24 * sweepDirection * math.pi / 180,
      false,
      _stroke,
    );
    _stroke.strokeCap = StrokeCap.round;
  }

  // ------------------------------------------------------------------
  // 按钮
  // ------------------------------------------------------------------

  void _drawButtons(Canvas canvas, WheelRenderParams params, double alpha) {
    final WheelMenuLayout layout = params.layout;
    final WheelMenuTheme theme = params.theme;
    final WheelAnimationFrame frame = params.frame;
    final int selected = params.highlightIndex;
    for (final slot in layout.slots) {
      final double progress =
          slot.index < frame.buttonProgress.length ? frame.buttonProgress[slot.index] : 1.0;
      if (progress <= 0.01) continue;
      final bool isSelected = slot.index == selected;
      final bool pressed = frame.pressIndex == slot.index;
      final double pressAmount = pressed ? frame.pressProgress : 0;
      final double scale = (isSelected ? selectedScale : 1.0) *
          (1 + (progress - 1)) *
          (1 - pressAmount * 0.12);
      final double diameter = layout.buttonDiameterPx * scale;
      final double cx = slot.centerX + (layout.centerX - slot.centerX) * (1 - progress);
      final double cy = slot.centerY + (layout.centerY - slot.centerY) * (1 - progress);

      _fill.shader = null;
      _stroke.shader = null;
      _stroke.strokeCap = StrokeCap.round;
      if (isSelected) {
        // 选中项外圈：白色底座（P3P 的"白圈大图标"）
        _fill.style = PaintingStyle.fill;
        _fill.color = _withAlpha(theme.text, alpha * 0.95);
        canvas.drawCircle(Offset(cx, cy), diameter * 0.62, _fill);
      }
      _fill.style = PaintingStyle.fill;
      // Android 的 `entry.enabled` 在 Windows 目录里全部为 true（无不可用项）；
      // 若将来出现 disabled 条目，这里改为读 MenuNode 的新字段即可。
      _fill.color = _withAlpha(theme.primary, alpha);
      canvas.drawCircle(Offset(cx, cy), diameter / 2, _fill);
      _stroke.style = PaintingStyle.stroke;
      _stroke.color = _withAlpha(theme.outline, alpha);
      _stroke.strokeWidth = layout.outlineWidthPx;
      canvas.drawCircle(Offset(cx, cy), diameter / 2, _stroke);

      final Color iconColor = _withAlpha(
        theme.text,
        alpha,
      );
      WheelMenuIcons.draw(
        canvas,
        WheelMenuIcons.iconForNodeId(slot.entry.id),
        cx,
        cy,
        diameter * iconRatio,
        iconColor,
        _iconPaint,
      );
    }
  }

  // ------------------------------------------------------------------
  // 文字
  // ------------------------------------------------------------------

  void _drawButtonLabels(Canvas canvas, WheelRenderParams params, double alpha) {
    if (!params.showButtonLabels) return;
    final WheelMenuLayout layout = params.layout;
    final WheelMenuTheme theme = params.theme;
    final double size = math.max(layout.buttonDiameterPx * labelSizeRatio, params.density * minLabelSp);
    for (final slot in layout.slots) {
      if (slot.entry.isBack) continue;
      final double progress =
          slot.index < params.frame.buttonProgress.length
              ? params.frame.buttonProgress[slot.index]
              : 1.0;
      if (progress <= 0.05) continue;
      final double dx = slot.centerX - layout.centerX;
      final double dy = slot.centerY - layout.centerY;
      final double len = math.max(1, math.sqrt(dx * dx + dy * dy));
      final double radius =
          layout.buttonDiameterPx / 2 + layout.rimLobePx * 0.5 + size * 0.95;
      final double lx = slot.centerX + dx / len * radius;
      final double ly = slot.centerY + dy / len * radius;
      final double baseline = ly + size * 0.34;
      // 描边 + 填充：压在任何底色上都读得清。
      _paintText(
        canvas,
        slot.entry.labelZh,
        lx,
        baseline,
        style: TextStyle(
          fontSize: size,
          fontWeight: FontWeight.bold,
          foreground: Paint()
            ..style = PaintingStyle.stroke
            ..strokeJoin = StrokeJoin.round
            ..strokeWidth = layout.outlineWidthPx * 1.1
            ..color = _withAlpha(theme.outline, alpha),
        ),
      );
      _paintText(
        canvas,
        slot.entry.labelZh,
        lx,
        baseline,
        style: TextStyle(
          fontSize: size,
          fontWeight: FontWeight.bold,
          color: _withAlpha(theme.text, alpha * progress.clamp(0.0, 1.0)),
        ),
      );
    }
  }

  void _drawTexts(Canvas canvas, WheelRenderParams params, double alpha) {
    final WheelMenuLayout layout = params.layout;
    final WheelMenuTheme theme = params.theme;
    final MenuNode? entry =
        params.activeIndex >= 0 && params.activeIndex < params.level.nodes.length
            ? params.level.nodes[params.activeIndex]
            : null;
    if (entry == null) return;
    final double density = params.density;
    final int sign = layout.direction.sign;
    final double offsetAngle =
        (params.frame.selectionPosition - (layout.itemCount - 1) / 2) * layout.stepDeg;
    final double selection = WheelMenuGeometry.absoluteAngle(
      layout.direction,
      offsetAngle + layout.fanBiasDeg,
    );
    final double rad = selection * math.pi / 180;

    final WheelTextSlots slots = WheelTextLayout.compute(
      layout,
      density,
      minTitleSp,
      minSubtitleSp,
      minInfoSp,
    );

    final double tiltDeg =
        (sign * (textBaseTiltDeg + offsetAngle * textArcFollow)).clamp(-maxTextTiltDeg, maxTextTiltDeg);

    final double titleRadius = slots.titleRadius;
    final double chipRotate = tiltDeg.clamp(-maxChipTiltDeg, maxChipTiltDeg);
    final double titleX = layout.centerX + titleRadius * math.cos(rad);
    final double titleY = layout.centerY + titleRadius * math.sin(rad);
    final String? englishTitle = entry.titleEn;

    if (englishTitle != null) {
      // 1) 英文大标题（描边 + 填充，轻微倾斜）
      final double titleSize = slots.titleSizePx;
      final _FittedText fitted = _fitText(
        englishTitle,
        titleSize,
        slots.titleMaxWidth,
        density * minTitleSp,
        letterSpacingEm: 0.06,
        bold: true,
        italic: true,
      );
      _paintText(
        canvas,
        fitted.text,
        titleX,
        titleY + fitted.size * 0.34,
        style: TextStyle(
          fontSize: fitted.size,
          letterSpacing: 0.06 * fitted.size,
          fontWeight: FontWeight.bold,
          fontStyle: FontStyle.italic,
          foreground: Paint()
            ..style = PaintingStyle.stroke
            ..strokeJoin = StrokeJoin.round
            ..strokeWidth = layout.outlineWidthPx * 1.35
            ..color = _withAlpha(theme.outline, alpha),
        ),
      );
      canvas.save();
      canvas.translate(titleX, titleY);
      canvas.rotate(chipRotate * math.pi / 180);
      canvas.translate(-titleX, -titleY);
      _paintText(
        canvas,
        fitted.text,
        titleX,
        titleY + fitted.size * 0.34,
        style: TextStyle(
          fontSize: fitted.size,
          letterSpacing: 0.06 * fitted.size,
          fontWeight: FontWeight.bold,
          fontStyle: FontStyle.italic,
          color: _withAlpha(theme.text, alpha),
        ),
      );
      canvas.restore();

      // 2) 中文名称（近白底圆角 chip + 深色字），与英文标题**分处两条半径**。
      final double chipRadius = slots.chipRadius;
      final _FittedText label = _fitText(
        entry.labelZh,
        slots.chipSizePx,
        slots.chipMaxWidth,
        density * minSubtitleSp,
        bold: true,
      );
      final double chipX = layout.centerX + chipRadius * math.cos(rad);
      final double chipY = layout.centerY + chipRadius * math.sin(rad);
      _drawChip(canvas, label, chipX, chipY, chipRotate, theme, layout, alpha);
    } else {
      // 只有中文标题：**画一次**（近白底 + 深色字），跳过 chip。
      final _FittedText titleText = _fitText(
        entry.labelZh,
        slots.titleSizePx,
        slots.titleMaxWidth,
        density * minTitleSp,
        bold: true,
      );
      _drawChip(canvas, titleText, titleX, titleY, chipRotate, theme, layout, alpha);
    }

    // 说明 / 实时信息
    final String? infoLine = params.infoText ?? entry.description;
    if (infoLine != null && infoLine.isNotEmpty) {
      final double infoRadius = slots.infoRadius;
      final _FittedText info = _fitText(
        infoLine,
        slots.infoSizePx,
        slots.infoMaxWidth,
        density * minInfoSp,
      );
      final double infoX = layout.centerX + infoRadius * math.cos(rad);
      final double infoY = layout.centerY + infoRadius * math.sin(rad);
      canvas.save();
      canvas.translate(infoX, infoY);
      canvas.rotate(chipRotate * math.pi / 180);
      canvas.translate(-infoX, -infoY);
      _paintText(
        canvas,
        info.text,
        infoX,
        infoY,
        style: TextStyle(
          fontSize: info.size,
          color: _withAlpha(theme.outline, alpha * 0.88),
        ),
      );
      canvas.restore();
    }
  }

  void _drawChip(
    Canvas canvas,
    _FittedText text,
    double centerX,
    double centerY,
    double rotateDeg,
    WheelMenuTheme theme,
    WheelMenuLayout layout,
    double alpha,
  ) {
    final double halfW = text.width / 2 + text.size * 0.55;
    final double halfH = text.size * 0.86;
    final Rect rect = Rect.fromCenter(
      center: Offset(centerX, centerY),
      width: halfW * 2,
      height: halfH * 2,
    );
    final double corner = halfH * 0.5;
    canvas.save();
    canvas.translate(centerX, centerY);
    canvas.rotate(rotateDeg * math.pi / 180);
    canvas.translate(-centerX, -centerY);
    _fill.shader = null;
    _fill.style = PaintingStyle.fill;
    _fill.color = _withAlpha(theme.text, alpha * 0.94);
    canvas.drawRRect(RRect.fromRectAndRadius(rect, Radius.circular(corner)), _fill);
    _stroke.style = PaintingStyle.stroke;
    _stroke.color = _withAlpha(theme.outline, alpha);
    _stroke.strokeWidth = layout.outlineWidthPx * 0.8;
    canvas.drawRRect(RRect.fromRectAndRadius(rect, Radius.circular(corner)), _stroke);
    _paintText(
      canvas,
      text.text,
      centerX,
      centerY + text.size * 0.36,
      style: TextStyle(
        fontSize: text.size,
        fontWeight: FontWeight.bold,
        color: _withAlpha(theme.outline, alpha),
      ),
    );
    canvas.restore();
  }

  /// 把文字缩到**能塞进给定宽度**；到最小字号仍放不下就逐字省略加 `…`。
  _FittedText _fitText(
    String text,
    double originalSize,
    double maxWidth,
    double minSizePx, {
    double letterSpacingEm = 0,
    bool bold = false,
    bool italic = false,
  }) {
    if (maxWidth <= 0 || text.isEmpty) {
      return _FittedText(text, originalSize, _measure(text, originalSize, letterSpacingEm, bold, italic));
    }
    double size = originalSize;
    double width = _measure(text, size, letterSpacingEm, bold, italic);
    while (size > minSizePx && width > maxWidth) {
      size = math.max(minSizePx, size * 0.92);
      width = _measure(text, size, letterSpacingEm, bold, italic);
      if (size <= minSizePx) break;
    }
    if (width <= maxWidth) return _FittedText(text, size, width);
    int end = text.length - 1;
    while (end > 1) {
      final String candidate = '${text.substring(0, end)}…';
      final double candidateWidth =
          _measure(candidate, size, letterSpacingEm, bold, italic);
      if (candidateWidth <= maxWidth) return _FittedText(candidate, size, candidateWidth);
      end -= 1;
    }
    final String single = text.substring(0, 1);
    return _FittedText(single, size, _measure(single, size, letterSpacingEm, bold, italic));
  }

  double _measure(
    String text,
    double size,
    double letterSpacingEm,
    bool bold,
    bool italic,
  ) {
    final TextPainter painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: size,
          letterSpacing: letterSpacingEm * size,
          fontWeight: bold ? FontWeight.bold : FontWeight.normal,
          fontStyle: italic ? FontStyle.italic : FontStyle.normal,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final double width = painter.width;
    painter.dispose();
    return width;
  }

  /// 按**基线**定位文字（对齐 Android `Canvas.drawText` 的 y 语义）。
  void _paintText(
    Canvas canvas,
    String text,
    double centerX,
    double baselineY, {
    required TextStyle style,
  }) {
    final TextPainter painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
    )..layout();
    final double baseline =
        painter.computeDistanceToActualBaseline(TextBaseline.alphabetic);
    painter.paint(canvas, Offset(centerX - painter.width / 2, baselineY - baseline));
    painter.dispose();
  }

  void _drawDebug(Canvas canvas, WheelRenderParams params, double alpha) {
    final WheelMenuLayout layout = params.layout;
    final Paint debug = Paint()
      ..isAntiAlias = true
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = _withAlpha(0xFFFF00FF, alpha);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, layout.windowRect.width, layout.windowRect.height),
      debug,
    );
    canvas.drawArc(
      Rect.fromCircle(center: Offset(layout.centerX, layout.centerY), radius: layout.bandOuterPx),
      -math.pi / 2,
      math.pi,
      false,
      debug,
    );
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(layout.notchCenterX, layout.notchCenterY),
        width: layout.notchRx * 2,
        height: layout.notchRy * 2,
      ),
      debug,
    );
  }

  static Color _withAlpha(int argb, double alpha) {
    final int base = (argb >> 24) & 0xFF;
    final int merged = (base * alpha.clamp(0.0, 1.0)).toInt().clamp(0, 255);
    return Color((merged << 24) | (argb & 0x00FFFFFF));
  }

  // --- 渲染常量（逐字对齐 Android `WheelMenuRenderer` companion）---
  static const double selectedScale = 1.14;
  static const double iconRatio = 0.58;
  static const double verifyFanSpanDeg = 160;
  static const double verifyFanInnerRatio = 0.22;
  static const double verifyFanAlpha = 200;
  static const double baseFanInnerRatio = 0.30;
  static const double labelSizeRatio = 0.30;
  static const double subtitleSizeRatio = 0.42;
  static const double infoSizeRatio = 0.27;
  static const double textBaseTiltDeg = -10;
  static const double textArcFollow = 0.30;
  static const double maxTextTiltDeg = 8;
  static const double maxChipTiltDeg = 3;
  static const double minTitleSp = 13;
  static const double minSubtitleSp = 16;
  static const double minInfoSp = 11;
  static const double minLabelSp = 10;
}

/// `fitText` 的结果（文字 + 实际字号 + 实际宽度）。
class _FittedText {
  const _FittedText(this.text, this.size, this.width);

  final String text;
  final double size;
  final double width;
}

/// P3P 图形语言（**只做装饰**）。
///
/// 允许：斜切色块、放射线、短黄色高光线、不规则标题底板。
/// 禁止：复制 P3P 商标 / 角色 / 图案，大面积黄色底板，复杂装饰压住正文。
///
/// 本文件里的所有装饰都必须：
/// * 包在 [IgnorePointer] 里（不得影响点击）；
/// * 画在内容**下面**（不得覆盖文字）；
/// * 低透明度（不喧宾夺主）。
///
/// 因此每个页面**最多**使用一个 [P3pPageBackdrop]。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/design_tokens.dart';
import '../../theme/petlife_theme.dart';

/// 页面顶部的主要装饰区：低透明度斜向色块 + 少量放射线。
///
/// 放在 `Stack` 的最底层，高度由 [height] 控制（默认只覆盖标题区附近）。
class P3pPageBackdrop extends StatelessWidget {
  const P3pPageBackdrop({
    super.key,
    this.height = 168,
    this.rays = 9,
    this.showSlash = true,
  });

  /// 装饰区高度。**不要**超过首屏的一半：需求要求「每屏最多一个主要装饰区域」。
  final double height;

  /// 放射线条数（8～12 之间视觉最舒服）。
  final int rays;

  /// 是否绘制斜切色块。
  final bool showSlash;

  @override
  Widget build(BuildContext context) {
    final PetLifePalette p = PetLifeTheme.of(context);
    return IgnorePointer(
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: CustomPaint(
          painter: _P3pBackdropPainter(palette: p, rays: rays, showSlash: showSlash),
        ),
      ),
    );
  }
}

class _P3pBackdropPainter extends CustomPainter {
  _P3pBackdropPainter({
    required this.palette,
    required this.rays,
    required this.showSlash,
  });

  final PetLifePalette palette;
  final int rays;
  final bool showSlash;

  @override
  void paint(Canvas canvas, Size size) {
    final double opacity = palette.isDark ? 0.16 : 0.10;

    if (showSlash) {
      // 斜切色块：从右上往左下的一条宽带，右端被裁掉（不闭合，因此不是"海报"）。
      final Path slash = Path()
        ..moveTo(size.width * 0.42, 0)
        ..lineTo(size.width, 0)
        ..lineTo(size.width, size.height * 0.32)
        ..lineTo(size.width * 0.62, size.height)
        ..lineTo(size.width * 0.30, size.height)
        ..close();
      canvas.drawPath(
        slash,
        Paint()..color = palette.accent.withValues(alpha: opacity * 0.55),
      );
    }

    // 放射线：以右上角附近为圆心，向左下扇开；线越远越淡。
    final Offset origin = Offset(size.width * 0.86, size.height * 0.12);
    final double radius = size.width * 0.72;
    final Paint rayPaint = Paint()
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round;
    for (int i = 0; i < rays; i++) {
      final double t = i / math.max(1, rays - 1);
      final double angle = math.pi * (0.42 + t * 0.46);
      final double inner = radius * (0.30 + 0.04 * (i % 3));
      final double outer = radius * (0.78 + 0.06 * (i % 2));
      rayPaint.color = palette.accent.withValues(alpha: opacity * (1.0 - t * 0.65) * 0.9);
      canvas.drawLine(
        origin + Offset(math.cos(angle) * inner, math.sin(angle) * inner),
        origin + Offset(math.cos(angle) * outer, math.sin(angle) * outer),
        rayPaint,
      );
    }
  }

  @override
  bool shouldRepaint(_P3pBackdropPainter old) =>
      old.palette.accent != palette.accent ||
      old.palette.isDark != palette.isDark ||
      old.rays != rays ||
      old.showSlash != showSlash;
}

/// 标题底板上的装饰线：一条强调色短线 + 一条**短黄色高光线**。
///
/// 黄色只做高光线（需求 §4 明令禁止大面积黄色）。
class P3pTitleAccent extends StatelessWidget {
  const P3pTitleAccent({super.key, this.width = 34, this.height = 4});

  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final PetLifePalette p = PetLifeTheme.of(context);
    return IgnorePointer(
      child: SizedBox(
        height: height,
        width: width + 12,
        child: Row(
          children: <Widget>[
            Container(
              width: width,
              height: height,
              decoration: BoxDecoration(
                color: p.accent,
                borderRadius: BorderRadius.circular(height / 2),
              ),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Container(
                height: height * 0.6,
                decoration: BoxDecoration(
                  color: p.warning,
                  borderRadius: BorderRadius.circular(height / 2),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 卡片左上角的「斜切角」装饰（P3P 常用语汇之一）。
///
/// 尺寸很小（默认 22×10），只作为卡片的识别特征，不占用正文空间。
class P3pCornerSlash extends StatelessWidget {
  const P3pCornerSlash({super.key, this.width = 22, this.height = 9, this.color});

  final double width;
  final double height;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final PetLifePalette p = PetLifeTheme.of(context);
    return IgnorePointer(
      child: CustomPaint(
        size: Size(width, height),
        painter: _SlashPainter(color: color ?? p.accent, width: width, height: height),
      ),
    );
  }
}

class _SlashPainter extends CustomPainter {
  _SlashPainter({required this.color, required this.width, required this.height});

  final Color color;
  final double width;
  final double height;

  @override
  void paint(Canvas canvas, Size size) {
    final Path path = Path()
      ..moveTo(0, size.height)
      ..lineTo(size.width * 0.55, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width * 0.42, size.height)
      ..close();
    canvas.drawPath(path, Paint()..color = color.withValues(alpha: 0.85));
  }

  @override
  bool shouldRepaint(_SlashPainter old) => old.color != color;
}

/// 「不规则标题底板」：标题左侧一块小斜切底板 + 一个圆点。
///
/// 用于分组标题（Animeko 式层级：分组标题本身带视觉锚点）。
class P3pSectionMarker extends StatelessWidget {
  const P3pSectionMarker({super.key, this.height = 18});

  final double height;

  @override
  Widget build(BuildContext context) {
    final PetLifePalette p = PetLifeTheme.of(context);
    return IgnorePointer(
      child: SizedBox(
        width: 6,
        height: height,
        child: CustomPaint(painter: _MarkerPainter(palette: p)),
      ),
    );
  }
}

class _MarkerPainter extends CustomPainter {
  _MarkerPainter({required this.palette});

  final PetLifePalette palette;

  @override
  void paint(Canvas canvas, Size size) {
    final Path path = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, size.height * 0.18)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height * 0.82)
      ..close();
    canvas.drawPath(path, Paint()..color = palette.accent);
  }

  @override
  bool shouldRepaint(_MarkerPainter old) => old.palette.accent != palette.accent;
}

/// 「卡片出现」动画：轻微淡入 + 上移（需求 §6）。
///
/// 用 [TweenAnimationBuilder] 而不是隐式动画控制器：它**只在首次出现时**播放，
/// 不会在父级因任何 setState 重建时重新播放（那会让界面一直闪）。
class PetLifeCardEntrance extends StatelessWidget {
  const PetLifeCardEntrance({
    super.key,
    required this.child,
    this.delay = Duration.zero,
    this.offset = 10,
  });

  final Widget child;
  final Duration delay;
  final double offset;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: PetLifeDurations.cardIn + delay,
      curve: Interval(
        delay.inMilliseconds /
            math.max(1, (PetLifeDurations.cardIn + delay).inMilliseconds),
        1,
        curve: PetLifeDurations.cardEasing,
      ),
      builder: (BuildContext context, double t, Widget? inner) => Opacity(
        opacity: t.clamp(0.0, 1.0),
        child: Transform.translate(
          offset: Offset(0, offset * (1 - t)),
          child: inner,
        ),
      ),
      child: child,
    );
  }
}

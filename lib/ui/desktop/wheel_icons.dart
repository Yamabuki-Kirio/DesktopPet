/// 轮盘图标（**Android `WheelMenuIcons.kt` 的 1:1 移植**，原创几何）。
///
/// 纪律（决策三）：
/// * **不使用** Material 图标、**不使用**任何图片资源、**不使用**受版权保护的 P3P 原始资产；
///   这些 Path 是项目现有原创实现，按几何迁移；
/// * 全部在归一化坐标 `[-1, 1]²` 内绘制，`STROKE = 0.16`，`CAP.ROUND` / `JOIN.ROUND`；
/// * 图标**保持直立**（不跟随圆周倒转）；**镜像时只镜像槽位布局，不镜像图标内容**；
/// * 颜色与透明度规则由调用方传入（`selected` / `disabled` / `pressed` 的取值在渲染层）；
/// * 缩放以**按钮内容框**为基准（`size` = 图标边长）。
///
/// 与 Android 的唯一技术差异：Flutter 的 `Path.arcTo` / `addArc` 角度单位是**弧度**
/// （Android 是度），因此这里在调用处显式换算；几何数值一字不改。
library;

import 'dart:math' as math;
import 'dart:ui' show Canvas, Color, Offset, Paint, PaintingStyle, Path, Radius, Rect, RRect, StrokeCap, StrokeJoin;

/// 轮盘图标 key（39 个，与 Android `WheelMenuIcon` 逐字一致）。
enum WheelMenuIcon {
  pet,
  appearance,
  record,
  tools,
  gear,
  hide,
  cycle,
  state,
  hand,
  refresh,
  pin,
  resize,
  home,
  back,
  prev,
  next,
  shuffle,
  heart,
  character,
  mapping,
  library,
  clock,
  app,
  pause,
  sync,
  cloud,
  chart,
  timer,
  bolt,
  star,
  edit,
  palette,
  opacity,
  ruler,
  vibrate,
  sound,
  info,
  restart,
  power,
}

/// 图标绘制器（纯 `Canvas + Path`）。
class WheelMenuIcons {
  WheelMenuIcons._();

  /// 归一化描边宽度。
  static const double stroke = 0.16;

  /// 条目 id → 图标（**与 Android `WheelMenuCatalog` 的每个条目逐一对齐**）。
  ///
  /// Android 的图标挂在 `WheelMenuEntry.icon` 上；Windows 的 [MenuNode] 没有 icon 字段，
  /// 因此这里按**同一套条目 id** 建立等价映射（id 是跨端稳定契约）。
  static const Map<String, WheelMenuIcon> nodeIcons = <String, WheelMenuIcon>{
    // root
    'root_pet': WheelMenuIcon.pet,
    'root_appearance': WheelMenuIcon.appearance,
    'root_records': WheelMenuIcon.record,
    'root_tools': WheelMenuIcon.tools,
    'root_settings': WheelMenuIcon.gear,
    'root_hide': WheelMenuIcon.hide,
    // pet
    'pet_size_down': WheelMenuIcon.resize,
    'pet_size_up': WheelMenuIcon.resize,
    'pet_size_reset': WheelMenuIcon.refresh,
    'pet_auto': WheelMenuIcon.cycle,
    'pet_current': WheelMenuIcon.state,
    'pet_home': WheelMenuIcon.home,
    // appearance
    'appearance_prev': WheelMenuIcon.prev,
    'appearance_next': WheelMenuIcon.next,
    'appearance_auto': WheelMenuIcon.shuffle,
    'appearance_fav': WheelMenuIcon.heart,
    'appearance_mapping': WheelMenuIcon.mapping,
    'appearance_library': WheelMenuIcon.library,
    // records
    'records_today': WheelMenuIcon.clock,
    'records_app': WheelMenuIcon.app,
    'records_stats': WheelMenuIcon.chart,
    'records_cloud': WheelMenuIcon.cloud,
    // tools
    'records_track': WheelMenuIcon.pause,
    'records_sync': WheelMenuIcon.sync,
    'records_sync_state': WheelMenuIcon.cloud,
    'tools_open_app': WheelMenuIcon.star,
    // settings
    'settings_theme': WheelMenuIcon.palette,
    'settings_wheel_size': WheelMenuIcon.ruler,
    'settings_button_size': WheelMenuIcon.resize,
    // 菜单距离（Windows 新增入口）：用"刻度尺"族里的另一个图标，
    // 与轮盘大小区分开（同一族但不同形状，用户一眼能分出两个滑块）。
    'settings_menu_distance': WheelMenuIcon.bolt,
    'settings_open': WheelMenuIcon.gear,
    // 固定返回
    'back': WheelMenuIcon.back,
  };

  /// 条目 id → 图标；未知条目回退 [WheelMenuIcon.info]（绝不返回 null，避免空按钮）。
  static WheelMenuIcon iconForNodeId(String nodeId) =>
      nodeIcons[nodeId] ?? WheelMenuIcon.info;

  /// 在 `(cx, cy)` 处画一个边长为 `size` 的图标。
  ///
  /// [paint] 由调用方复用（**不要在绘制循环里 new Paint**）。
  static void draw(
    Canvas canvas,
    WheelMenuIcon icon,
    double cx,
    double cy,
    double size,
    Color color,
    Paint paint,
  ) {
    if (size <= 0) return;
    final double half = size / 2;
    canvas.save();
    canvas.translate(cx, cy);
    canvas.scale(half, half);
    paint.color = color;
    paint.strokeWidth = stroke;
    paint.strokeCap = StrokeCap.round;
    paint.strokeJoin = StrokeJoin.round;
    _drawNormalized(canvas, icon, paint);
    canvas.restore();
  }

  static void _drawNormalized(Canvas canvas, WheelMenuIcon icon, Paint paint) {
    switch (icon) {
      case WheelMenuIcon.pet:
        _pet(canvas, paint);
      case WheelMenuIcon.appearance:
        _sparkle(canvas, paint);
      case WheelMenuIcon.record:
        _bars(canvas, paint);
      case WheelMenuIcon.tools:
        _wrench(canvas, paint);
      case WheelMenuIcon.gear:
        _gear(canvas, paint);
      case WheelMenuIcon.hide:
        _eyeOff(canvas, paint);
      case WheelMenuIcon.cycle:
        _ringArrow(canvas, paint, gapStartDeg: 20, gapEndDeg: 300);
      case WheelMenuIcon.state:
        _stateDot(canvas, paint);
      case WheelMenuIcon.hand:
        _hand(canvas, paint);
      case WheelMenuIcon.refresh:
        _doubleArc(canvas, paint);
      case WheelMenuIcon.pin:
        _lock(canvas, paint);
      case WheelMenuIcon.resize:
        _resize(canvas, paint);
      case WheelMenuIcon.home:
        _home(canvas, paint);
      case WheelMenuIcon.back:
        _back(canvas, paint);
      case WheelMenuIcon.prev:
        _chevron(canvas, paint, pointingRight: false);
      case WheelMenuIcon.next:
        _chevron(canvas, paint, pointingRight: true);
      case WheelMenuIcon.shuffle:
        _shuffle(canvas, paint);
      case WheelMenuIcon.heart:
        _heart(canvas, paint);
      case WheelMenuIcon.character:
        _people(canvas, paint);
      case WheelMenuIcon.mapping:
        _gridArrow(canvas, paint);
      case WheelMenuIcon.library:
        _folder(canvas, paint);
      case WheelMenuIcon.clock:
        _clock(canvas, paint, topButton: false);
      case WheelMenuIcon.timer:
        _clock(canvas, paint, topButton: true);
      case WheelMenuIcon.app:
        _appGrid(canvas, paint);
      case WheelMenuIcon.pause:
        _pause(canvas, paint);
      case WheelMenuIcon.sync:
        _ringArrow(canvas, paint, gapStartDeg: 150, gapEndDeg: 60);
      case WheelMenuIcon.cloud:
        _cloud(canvas, paint);
      case WheelMenuIcon.chart:
        _lineChart(canvas, paint);
      case WheelMenuIcon.bolt:
        _bolt(canvas, paint);
      case WheelMenuIcon.star:
        _star(canvas, paint);
      case WheelMenuIcon.edit:
        _pencil(canvas, paint);
      case WheelMenuIcon.palette:
        _palette(canvas, paint);
      case WheelMenuIcon.opacity:
        _opacity(canvas, paint);
      case WheelMenuIcon.ruler:
        _ruler(canvas, paint);
      case WheelMenuIcon.vibrate:
        _vibrate(canvas, paint);
      case WheelMenuIcon.sound:
        _sound(canvas, paint);
      case WheelMenuIcon.info:
        _info(canvas, paint);
      case WheelMenuIcon.restart:
        _ringArrow(canvas, paint, gapStartDeg: 300, gapEndDeg: 20);
      case WheelMenuIcon.power:
        _power(canvas, paint);
    }
  }

  // ------------------------------------------------------------------
  // 基础图元
  // ------------------------------------------------------------------

  static void _fill(Canvas canvas, Paint paint, void Function(Path) block) {
    paint.style = PaintingStyle.fill;
    canvas.drawPath(Path()..let(block), paint);
  }

  static void _stroke(Canvas canvas, Paint paint, void Function(Path) block) {
    paint.style = PaintingStyle.stroke;
    canvas.drawPath(Path()..let(block), paint);
  }

  static void _circle(
    Canvas canvas,
    Paint paint,
    double cx,
    double cy,
    double r, {
    required bool filled,
  }) {
    paint.style = filled ? PaintingStyle.fill : PaintingStyle.stroke;
    canvas.drawCircle(Offset(cx, cy), r, paint);
  }

  static void _poly(Canvas canvas, Paint paint, List<double> points) {
    _fill(canvas, paint, (Path path) {
      path.moveTo(points[0], points[1]);
      int i = 2;
      while (i < points.length) {
        path.lineTo(points[i], points[i + 1]);
        i += 2;
      }
      path.close();
    });
  }

  /// 箭头（指向由 [dx]/[dy] 决定，长度 [length]）。
  static void _arrowHead(
    Canvas canvas,
    Paint paint,
    double tipX,
    double tipY,
    double dx,
    double dy, {
    double length = 0.34,
  }) {
    final double norm = math.max(1e-4, math.sqrt(dx * dx + dy * dy));
    final double ux = dx / norm;
    final double uy = dy / norm;
    final double px = -uy;
    final double py = ux;
    const double spreadFactor = 0.62;
    final double spread = length * spreadFactor;
    _poly(canvas, paint, <double>[
      tipX, tipY,
      tipX - ux * length + px * spread, tipY - uy * length + py * spread,
      tipX - ux * length - px * spread, tipY - uy * length - py * spread,
    ]);
  }

  static double _rad(double deg) => deg * math.pi / 180.0;

  static Rect _rect(double l, double t, double r, double b) => Rect.fromLTRB(l, t, r, b);

  static void _roundRect(
    Path path,
    double l,
    double t,
    double r,
    double b,
    double radius,
  ) {
    path.addRRect(RRect.fromRectAndRadius(_rect(l, t, r, b), Radius.circular(radius)));
  }

  // ------------------------------------------------------------------
  // 具体图标
  // ------------------------------------------------------------------

  static void _pet(Canvas canvas, Paint paint) {
    // 耳朵
    _poly(canvas, paint, <double>[-0.72, -0.34, -0.34, -0.92, -0.2, -0.4]);
    _poly(canvas, paint, <double>[0.72, -0.34, 0.34, -0.92, 0.2, -0.4]);
    _circle(canvas, paint, 0, 0.12, 0.72, filled: true);
  }

  static void _sparkle(Canvas canvas, Paint paint) {
    _fill(canvas, paint, (Path path) {
      path.moveTo(0, -0.9);
      path.quadraticBezierTo(0.16, -0.16, 0.9, 0);
      path.quadraticBezierTo(0.16, 0.16, 0, 0.9);
      path.quadraticBezierTo(-0.16, 0.16, -0.9, 0);
      path.quadraticBezierTo(-0.16, -0.16, 0, -0.9);
      path.close();
    });
    _fill(canvas, paint, (Path path) {
      path.moveTo(-0.66, -0.78);
      path.quadraticBezierTo(-0.56, -0.44, -0.26, -0.34);
      path.quadraticBezierTo(-0.56, -0.24, -0.66, 0.1);
      path.quadraticBezierTo(-0.76, -0.24, -1.06, -0.34);
      path.quadraticBezierTo(-0.76, -0.44, -0.66, -0.78);
      path.close();
    });
  }

  static void _bars(Canvas canvas, Paint paint) {
    _fill(canvas, paint, (Path path) {
      path.addRect(_rect(-0.82, 0.16, -0.42, 0.86));
      path.addRect(_rect(-0.2, -0.3, 0.2, 0.86));
      path.addRect(_rect(0.42, -0.8, 0.82, 0.86));
    });
  }

  static void _wrench(Canvas canvas, Paint paint) {
    _stroke(canvas, paint, (Path path) {
      path.moveTo(-0.62, 0.66);
      path.lineTo(0.24, -0.24);
    });
    _circle(canvas, paint, 0.48, -0.5, 0.36, filled: false);
    _fill(canvas, paint, (Path path) {
      path.addRect(_rect(-0.86, 0.42, -0.36, 0.9));
    });
  }

  static void _gear(Canvas canvas, Paint paint) {
    // 齿：8 个沿圆周的小梯形
    _fill(canvas, paint, (Path path) {
      for (int i = 0; i < 8; i++) {
        final double angle = _rad(i * 45.0);
        final double cosA = math.cos(angle);
        final double sinA = math.sin(angle);
        final double px = -sinA;
        final double py = cosA;
        const double inner = 0.58;
        const double outer = 0.98;
        const double wide = 0.2;
        path.moveTo(cosA * inner + px * wide, sinA * inner + py * wide);
        path.lineTo(cosA * outer + px * wide * 0.7, sinA * outer + py * wide * 0.7);
        path.lineTo(cosA * outer - px * wide * 0.7, sinA * outer - py * wide * 0.7);
        path.lineTo(cosA * inner - px * wide, sinA * inner - py * wide);
        path.close();
      }
    });
    // 环体用描边表达"中心是孔"。
    _circle(canvas, paint, 0, 0, 0.64, filled: false);
  }

  static void _eyeOff(Canvas canvas, Paint paint) {
    _stroke(canvas, paint, (Path path) {
      path.moveTo(-0.92, 0);
      path.quadraticBezierTo(0, -0.72, 0.92, 0);
      path.quadraticBezierTo(0, 0.72, -0.92, 0);
      path.close();
    });
    _circle(canvas, paint, 0, 0, 0.26, filled: true);
    _stroke(canvas, paint, (Path path) {
      path.moveTo(-0.86, 0.82);
      path.lineTo(0.86, -0.82);
    });
  }

  static void _ringArrow(
    Canvas canvas,
    Paint paint, {
    required double gapStartDeg,
    required double gapEndDeg,
  }) {
    final Rect rect = _rect(-0.78, -0.78, 0.78, 0.78);
    _stroke(canvas, paint, (Path path) {
      path.addArc(rect, _rad(gapStartDeg), _rad((gapEndDeg - gapStartDeg + 360) % 360));
    });
    final double angle = _rad(gapEndDeg);
    final double x = math.cos(angle) * 0.78;
    final double y = math.sin(angle) * 0.78;
    final double tangent = _rad(gapEndDeg + 90.0);
    _arrowHead(canvas, paint, x, y, math.cos(tangent), math.sin(tangent));
  }

  static void _stateDot(Canvas canvas, Paint paint) {
    _circle(canvas, paint, 0, 0, 0.86, filled: false);
    _circle(canvas, paint, 0, 0, 0.38, filled: true);
  }

  static void _hand(Canvas canvas, Paint paint) {
    _fill(canvas, paint, (Path path) {
      _roundRect(path, -0.56, -0.1, 0.56, 0.9, 0.22);
      _roundRect(path, -0.6, -0.92, -0.32, 0.1, 0.14);
      _roundRect(path, -0.22, -1.0, 0.06, 0.1, 0.14);
      _roundRect(path, 0.16, -0.9, 0.44, 0.1, 0.14);
      _roundRect(path, 0.5, -0.5, 0.9, 0.1, 0.14);
    });
  }

  static void _doubleArc(Canvas canvas, Paint paint) {
    final Rect rect = _rect(-0.82, -0.82, 0.82, 0.82);
    _stroke(canvas, paint, (Path path) => path.addArc(rect, _rad(200), _rad(130)));
    _stroke(canvas, paint, (Path path) => path.addArc(rect, _rad(20), _rad(130)));
    _arrowHead(canvas, paint, -0.74, -0.36, -0.5, -0.86);
    _arrowHead(canvas, paint, 0.74, 0.36, 0.5, 0.86);
  }

  static void _lock(Canvas canvas, Paint paint) {
    _stroke(canvas, paint, (Path path) {
      path.addArc(_rect(-0.44, -0.88, 0.44, 0.02), _rad(180), _rad(180));
    });
    _fill(canvas, paint, (Path path) {
      _roundRect(path, -0.66, -0.02, 0.66, 0.86, 0.16);
    });
  }

  static void _resize(Canvas canvas, Paint paint) {
    _stroke(canvas, paint, (Path path) {
      path.moveTo(-0.66, 0.66);
      path.lineTo(0.66, -0.66);
    });
    _arrowHead(canvas, paint, -0.8, 0.8, -1, 1);
    _arrowHead(canvas, paint, 0.8, -0.8, 1, -1);
    _stroke(canvas, paint, (Path path) {
      path.moveTo(-0.92, 0.28);
      path.lineTo(-0.92, 0.92);
      path.lineTo(-0.28, 0.92);
      path.moveTo(0.92, -0.28);
      path.lineTo(0.92, -0.92);
      path.lineTo(0.28, -0.92);
    });
  }

  static void _home(Canvas canvas, Paint paint) {
    _poly(canvas, paint, <double>[0, -0.92, 0.96, 0, -0.96, 0]);
    _fill(canvas, paint, (Path path) {
      path.addRect(_rect(-0.62, 0, 0.62, 0.86));
    });
  }

  static void _back(Canvas canvas, Paint paint) {
    _stroke(canvas, paint, (Path path) {
      path.moveTo(0.72, 0.34);
      path.lineTo(-0.1, 0.34);
      path.quadraticBezierTo(-0.66, 0.34, -0.66, -0.14);
      path.lineTo(-0.66, -0.62);
    });
    _arrowHead(canvas, paint, -0.66, -0.86, 0, -1);
  }

  static void _chevron(Canvas canvas, Paint paint, {required bool pointingRight}) {
    final double dir = pointingRight ? 1 : -1;
    _stroke(canvas, paint, (Path path) {
      path.moveTo(-0.36 * dir, -0.86);
      path.lineTo(0.36 * dir, 0);
      path.lineTo(-0.36 * dir, 0.86);
    });
  }

  static void _shuffle(Canvas canvas, Paint paint) {
    _stroke(canvas, paint, (Path path) {
      path.moveTo(-0.86, -0.56);
      path.lineTo(-0.1, -0.56);
      path.lineTo(0.72, 0.56);
      path.moveTo(-0.86, 0.56);
      path.lineTo(-0.1, 0.56);
      path.lineTo(0.72, -0.56);
    });
    _arrowHead(canvas, paint, 0.94, 0.7, 1, 0.4);
    _arrowHead(canvas, paint, 0.94, -0.7, 1, -0.4);
  }

  static void _heart(Canvas canvas, Paint paint) {
    _fill(canvas, paint, (Path path) {
      path.moveTo(0, 0.9);
      path.cubicTo(-1.2, 0, -0.62, -0.98, 0, -0.34);
      path.cubicTo(0.62, -0.98, 1.2, 0, 0, 0.9);
      path.close();
    });
  }

  static void _people(Canvas canvas, Paint paint) {
    _circle(canvas, paint, -0.36, -0.36, 0.34, filled: true);
    _circle(canvas, paint, 0.42, -0.28, 0.28, filled: true);
    _fill(canvas, paint, (Path path) {
      _roundRect(path, -0.96, 0.06, 0.24, 0.88, 0.26);
      _roundRect(path, 0.16, 0.18, 0.86, 0.88, 0.24);
    });
  }

  static void _gridArrow(Canvas canvas, Paint paint) {
    _fill(canvas, paint, (Path path) {
      path.addRect(_rect(-0.92, -0.92, -0.14, -0.14));
      path.addRect(_rect(-0.92, 0.14, -0.14, 0.92));
      path.addRect(_rect(0.14, -0.92, 0.92, -0.14));
    });
    _stroke(canvas, paint, (Path path) {
      path.moveTo(0.2, 0.72);
      path.lineTo(0.82, 0.72);
    });
    _arrowHead(canvas, paint, 0.94, 0.72, 1, 0);
  }

  static void _folder(Canvas canvas, Paint paint) {
    _fill(canvas, paint, (Path path) {
      path.moveTo(-0.92, -0.6);
      path.lineTo(-0.24, -0.6);
      path.lineTo(-0.04, -0.36);
      path.lineTo(0.92, -0.36);
      path.lineTo(0.92, 0.78);
      path.lineTo(-0.92, 0.78);
      path.close();
    });
  }

  static void _clock(Canvas canvas, Paint paint, {required bool topButton}) {
    final double cy = topButton ? 0.12 : 0;
    _circle(canvas, paint, 0, cy, 0.78, filled: false);
    _stroke(canvas, paint, (Path path) {
      path.moveTo(0, cy);
      path.lineTo(0, topButton ? -0.34 : -0.46);
      path.moveTo(0, cy);
      path.lineTo(0.38, topButton ? 0.36 : 0.24);
    });
    if (topButton) {
      _fill(canvas, paint, (Path path) {
        _roundRect(path, -0.24, -0.98, 0.24, -0.7, 0.08);
      });
    }
  }

  static void _appGrid(Canvas canvas, Paint paint) {
    _fill(canvas, paint, (Path path) {
      _roundRect(path, -0.92, -0.92, 0.92, 0.92, 0.28);
    });
  }

  static void _pause(Canvas canvas, Paint paint) {
    _fill(canvas, paint, (Path path) {
      _roundRect(path, -0.6, -0.86, -0.16, 0.86, 0.1);
      _roundRect(path, 0.16, -0.86, 0.6, 0.86, 0.1);
    });
  }

  static void _cloud(Canvas canvas, Paint paint) {
    _circle(canvas, paint, -0.36, 0.06, 0.42, filled: true);
    _circle(canvas, paint, 0.16, -0.24, 0.5, filled: true);
    _circle(canvas, paint, 0.52, 0.18, 0.34, filled: true);
    _fill(canvas, paint, (Path path) {
      path.addRect(_rect(-0.36, 0.2, 0.56, 0.62));
    });
  }

  static void _lineChart(Canvas canvas, Paint paint) {
    _stroke(canvas, paint, (Path path) {
      path.moveTo(-0.86, 0.86);
      path.lineTo(-0.86, -0.86);
      path.moveTo(-0.86, 0.86);
      path.lineTo(0.86, 0.86);
    });
    _stroke(canvas, paint, (Path path) {
      path.moveTo(-0.6, 0.36);
      path.lineTo(-0.12, -0.2);
      path.lineTo(0.24, 0.16);
      path.lineTo(0.72, -0.56);
    });
  }

  static void _bolt(Canvas canvas, Paint paint) {
    _poly(canvas, paint, <double>[
      0.36, -0.96,
      -0.62, 0.1,
      -0.06, 0.1,
      -0.36, 0.96,
      0.62, -0.16,
      0.06, -0.16,
    ]);
  }

  static void _star(Canvas canvas, Paint paint) {
    _fill(canvas, paint, (Path path) {
      const int points = 5;
      for (int i = 0; i < points * 2; i++) {
        final double radius = i.isEven ? 0.98 : 0.44;
        final double angle = _rad(-90 + i * 180.0 / points);
        final double x = radius * math.cos(angle);
        final double y = radius * math.sin(angle);
        if (i == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      path.close();
    });
  }

  static void _pencil(Canvas canvas, Paint paint) {
    _fill(canvas, paint, (Path path) {
      path.moveTo(-0.86, 0.86);
      path.lineTo(-0.62, 0.24);
      path.lineTo(0.36, -0.74);
      path.lineTo(0.78, -0.32);
      path.lineTo(-0.24, 0.66);
      path.close();
    });
  }

  static void _palette(Canvas canvas, Paint paint) {
    _circle(canvas, paint, 0, 0, 0.92, filled: true);
  }

  static void _opacity(Canvas canvas, Paint paint) {
    _circle(canvas, paint, 0, 0, 0.88, filled: false);
    _fill(canvas, paint, (Path path) {
      path.moveTo(0, -0.88);
      path.arcTo(_rect(-0.88, -0.88, 0.88, 0.88), _rad(-90), _rad(180), false);
      path.close();
    });
  }

  static void _ruler(Canvas canvas, Paint paint) {
    _fill(canvas, paint, (Path path) {
      _roundRect(path, -0.96, -0.4, 0.96, 0.4, 0.12);
    });
    _stroke(canvas, paint, (Path path) {
      double x = -0.6;
      while (x <= 0.61) {
        path.moveTo(x, -0.4);
        path.lineTo(x, 0.06);
        x += 0.4;
      }
    });
  }

  static void _vibrate(Canvas canvas, Paint paint) {
    _fill(canvas, paint, (Path path) {
      _roundRect(path, -0.34, -0.9, 0.34, 0.9, 0.14);
    });
    _stroke(canvas, paint, (Path path) {
      path.moveTo(-0.62, -0.44);
      path.lineTo(-0.62, 0.44);
      path.moveTo(0.62, -0.44);
      path.lineTo(0.62, 0.44);
    });
  }

  static void _sound(Canvas canvas, Paint paint) {
    _poly(canvas, paint, <double>[
      -0.88, -0.24,
      -0.42, -0.24,
      -0.04, -0.72,
      -0.04, 0.72,
      -0.42, 0.24,
      -0.88, 0.24,
    ]);
    _stroke(canvas, paint, (Path path) {
      path.moveTo(0.24, -0.4);
      path.quadraticBezierTo(0.56, 0, 0.24, 0.4);
    });
    _stroke(canvas, paint, (Path path) {
      path.moveTo(0.5, -0.68);
      path.quadraticBezierTo(1.0, 0, 0.5, 0.68);
    });
  }

  static void _info(Canvas canvas, Paint paint) {
    _circle(canvas, paint, 0, 0, 0.9, filled: true);
    _fill(canvas, paint, (Path path) {
      path.addRect(_rect(-0.14, -0.6, 0.14, -0.3));
      path.addRect(_rect(-0.14, -0.12, 0.14, 0.6));
    });
  }

  static void _power(Canvas canvas, Paint paint) {
    _stroke(canvas, paint, (Path path) {
      path.addArc(_rect(-0.82, -0.82, 0.82, 0.82), _rad(-58), _rad(296));
    });
    _stroke(canvas, paint, (Path path) {
      path.moveTo(0, -0.92);
      path.lineTo(0, -0.12);
    });
  }
}

/// 便于 `Path()..let(block)` 的极小扩展（避免引入 `package:collection`）。
extension _PathBlock on Path {
  void let(void Function(Path) block) => block(this);
}

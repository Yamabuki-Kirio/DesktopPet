import 'dart:ui';

import 'package:screen_retriever/screen_retriever.dart';

import '../../core/logger.dart';

/// 一块可见的桌面区域。
class DisplayBounds {
  const DisplayBounds({
    required this.id,
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    required this.isPrimary,
  });

  final String id;
  final double left;
  final double top;
  final double width;
  final double height;
  final bool isPrimary;

  double get right => left + width;

  double get bottom => top + height;

  bool containsPoint(double x, double y) => x >= left && x <= right && y >= top && y <= bottom;

  @override
  String toString() => 'Display($id ${width.toInt()}x${height.toInt()} @ $left,$top'
      '${isPrimary ? ' primary' : ''})';
}

/// 多显示器拓扑。
///
/// 单独抽出来是为了把对 `screen_retriever` 的依赖限制在一个文件里：
/// 阶段 4（Android）会换掉整个实现，而 [WindowsWindowController] 里的
/// 位置夹取逻辑可以原样复用。
class DisplayTopology {
  DisplayTopology._(this.displays);

  final List<DisplayBounds> displays;

  static DisplayTopology empty() => DisplayTopology._(const <DisplayBounds>[]);

  /// 读取当前所有显示器。失败时返回空拓扑（调用方退化为不做夹取）。
  static Future<DisplayTopology> load() async {
    try {
      final List<Display> all = await screenRetriever.getAllDisplays();
      final Display primary = await screenRetriever.getPrimaryDisplay();
      final List<DisplayBounds> bounds = all
          .map((Display d) {
            // visiblePosition / visibleSize 在部分驱动下为 null（例如远程会话），
            // 此时退化为「整块屏幕都可见」。id 在 0.2.x 起为非空字段。
            final Offset? pos = d.visiblePosition;
            final Size visibleSize = d.visibleSize ?? d.size;
            final Rect visible = pos == null
                ? Rect.fromLTWH(0, 0, d.size.width, d.size.height)
                : Rect.fromLTWH(pos.dx, pos.dy, visibleSize.width, visibleSize.height);
            return DisplayBounds(
              id: d.id,
              left: visible.left,
              top: visible.top,
              width: visible.width,
              height: visible.height,
              isPrimary: d.id == primary.id,
            );
          })
          .toList(growable: false);

      Loggers.window.info('检测到 ${bounds.length} 个显示器: ${bounds.join(' | ')}');
      return DisplayTopology._(bounds);
    } catch (e, st) {
      // 多屏信息读取失败不应阻止应用启动。
      Loggers.window.warning('读取显示器拓扑失败，退化为单屏模式', e, st);
      return DisplayTopology.empty();
    }
  }

  /// 把窗口位置夹取到可见区域内，保证至少 [minVisible] 像素可见。
  ///
  /// 需求「多显示器兼容」的实质：用户在副屏放好桌宠后拔掉副屏，
  /// 下次启动不能让窗口跑到屏幕外面找不回来。
  ({double x, double y}) clamp(
    double x,
    double y, {
    required double windowWidth,
    required double windowHeight,
    double minVisible = 48,
  }) {
    if (displays.isEmpty) return (x: x, y: y);

    final double overlap = minVisible;
    final bool anyVisible = displays.any((DisplayBounds d) {
      final double ox = _overlap(
        x,
        x + windowWidth,
        d.left,
        d.right,
      );
      final double oy = _overlap(
        y,
        y + windowHeight,
        d.top,
        d.bottom,
      );
      return ox >= overlap && oy >= overlap;
    });
    if (anyVisible) return (x: x, y: y);

    // 完全不可见：放到主显示器的右下角。
    final DisplayBounds target = displays.firstWhere(
      (DisplayBounds d) => d.isPrimary,
      orElse: () => displays.first,
    );
    final double nx = target.right - windowWidth - 24;
    final double ny = target.bottom - windowHeight - 24;
    Loggers.window.warning(
      '保存的窗口位置 ($x, $y) 不在任何显示器可见范围内，已重置到 ($nx, $ny)',
    );
    return (
      x: nx.clamp(target.left, target.right - windowWidth),
      y: ny.clamp(target.top, target.bottom - windowHeight),
    );
  }

  double _overlap(double a1, double a2, double b1, double b2) {
    final double start = a1 > b1 ? a1 : b1;
    final double end = a2 < b2 ? a2 : b2;
    return end - start;
  }
}

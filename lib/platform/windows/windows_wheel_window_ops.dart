/// Windows 轮盘窗口几何操作器（增量 A）。
///
/// **唯一的生产几何提交路径**：[commitBounds] 调用 `windowManager.setBounds`
/// —— 位置与尺寸**一次原子提交**（Windows 插件在同一帧里
/// `SetWindowPos(hwnd, HWND_TOP, x, y, w, h, 0)`，见 `window_manager.cpp:742-776`）。
///
/// 刻意**不**使用 `setSize` + `setPosition`：那是两次独立提交，
/// 中间会产生"尺寸已变、位置未变"的错位与闪烁。
///
/// 本文件属于 `platform/windows/**`，是允许 import 桌面专属库的目录
/// （见 `test/platform_isolation_test.dart`）。
library;

import 'dart:ui' show Offset, Rect;

import 'package:window_manager/window_manager.dart';

import '../../core/logger.dart';
import '../../menu/wheel_geometry.dart';
import '../../menu/wheel_window_ops.dart';
import 'display_topology.dart';

/// Windows 侧窗口几何操作入口。
class WindowsWheelWindowOps implements WheelWindowOps {
  const WindowsWheelWindowOps();

  /// 读取当前窗口矩形（逻辑像素，与 `setBounds` 同口径）。
  @override
  Future<Rect> currentBounds() => windowManager.getBounds();

  /// **一次原子提交**：同时设置位置与尺寸。
  ///
  /// 绝不拆成 `setSize` + `setPosition`（两次提交会漂移 / 闪烁）。
  @override
  Future<void> commitBounds(Rect bounds) => windowManager.setBounds(bounds);

  /// 当前窗口的 devicePixelRatio（来自 Flutter 视图，不依赖原生插件）。
  @override
  double devicePixelRatio() {
    try {
      return windowManager.getDevicePixelRatio();
    } catch (e, st) {
      Loggers.window.warning('读取 devicePixelRatio 失败，退化为 1.0', e, st);
      return 1.0;
    }
  }

  /// 找到包含 [point] 的显示器可见区域；找不到时退化为"完全不可见"的 null。
  ///
  /// 复用既有 [DisplayTopology]（与窗口位置夹取同一份多屏来源），
  /// **不新增**第二条屏幕拓扑读取路径。
  @override
  Future<WheelDisplayArea?> displayForPoint(Offset point) async {
    final DisplayTopology topology = await DisplayTopology.load();
    if (topology.displays.isEmpty) return null;
    for (final DisplayBounds display in topology.displays) {
      if (display.containsPoint(point.dx, point.dy)) {
        return WheelDisplayArea(
          id: display.id,
          left: display.left,
          top: display.top,
          width: display.width,
          height: display.height,
        );
      }
    }
    // 点不在任何显示器内（理论上不该发生）：回退到主显示器。
    final DisplayBounds primary = topology.displays.firstWhere(
      (DisplayBounds d) => d.isPrimary,
      orElse: () => topology.displays.first,
    );
    return WheelDisplayArea(
      id: primary.id,
      left: primary.left,
      top: primary.top,
      width: primary.width,
      height: primary.height,
    );
  }
}

/// 窗口几何操作与尺寸写入的**中立接口**（纯 Dart）。
///
/// 为什么要有这层接口：轮盘打开 / 关闭的事务逻辑必须能在 `flutter_tester`
/// 里用假实现驱动，才能自动化验证"只提交一次 setBounds""失败必须回滚"
/// 这类竞态修复（见 `test/wheel_open_transaction_test.dart`）。
///
/// 真正的 `window_manager` 实现位于 `platform/windows/**`，
/// 本文件**绝不** import 任何桌面库。
library;

import 'dart:ui' show Offset, Rect, Size;

import 'wheel_geometry.dart' show WheelDisplayArea;

/// 轮盘几何事务需要的窗口能力。
abstract interface class WheelWindowOps {
  /// 读取当前窗口矩形（逻辑像素，与 `setBounds` 同口径）。
  Future<Rect> currentBounds();

  /// **一次原子提交**：同时设置位置与尺寸。
  Future<void> commitBounds(Rect bounds);

  /// 当前窗口的 devicePixelRatio。
  double devicePixelRatio();

  /// 找到包含 [point] 的显示器可见区域；找不到返回 null。
  Future<WheelDisplayArea?> displayForPoint(Offset point);
}

/// 桌宠尺寸写入的底层 IO（供最低层守卫记录"写入前 / 写入后"实际矩形）。
abstract interface class PetWindowSizeIo {
  /// 读取当前窗口矩形；失败返回 null。
  Future<Rect?> readBounds();

  /// 写入窗口尺寸（保持位置）。
  Future<void> setSize(Size size);
}

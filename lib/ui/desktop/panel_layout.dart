/// 控制面板窗口几何：按**桌宠所在显示器**的可用工作区适配并居中。
///
/// 背景（真机回归 #3）
/// ----------------
/// 旧实现把面板左上角放在 `windowController.position()` —— 也就是**当前窗口**
/// 的左上角。固定画布模式下窗口矩形 = 整块画布，其左上角是
/// `petScreen - petAnchor`（比桌宠整整高出一个 `petAnchor`），于是面板被放到
/// 远离桌宠的位置，再被夹取逻辑推到屏幕角落。真机现象就是
/// "双击打开的控制面板离桌宠 / 当前屏幕有效区域较远"。
///
/// 正确口径：用**进入前的桌宠屏幕位置**选显示器 → 取该显示器 workArea →
/// 尺寸适配（保留安全边距）→ 在 workArea 居中 → 一次提交。
///
/// 纯函数，可单测。
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart';

class PanelLayout {
  PanelLayout._();

  /// 首选面板尺寸（与 `DesktopShell.panelSize` 一致）。
  static const Size preferred = Size(1180, 760);

  /// 每侧安全边距（"小屏自动缩小并保留 16px 安全边距"）。
  static const double edgeMargin = 16;

  /// 尺寸下限：即使屏幕很小也不要缩到不可用。
  static const double minWidth = 480;
  static const double minHeight = 360;

  /// 由 workArea 求适配后的面板尺寸。
  ///
  /// `width = min(1180, workArea.width - 32)`、`height = min(760, workArea.height - 32)`；
  /// 若结果小于下限则退回下限，但**绝不**超过工作区本身。
  static Size sizeFor(Size workArea) {
    if (workArea.width <= 0 || workArea.height <= 0) return preferred;
    double width = math.min(preferred.width, workArea.width - edgeMargin * 2);
    if (width < minWidth) width = math.min(minWidth, workArea.width);
    double height = math.min(preferred.height, workArea.height - edgeMargin * 2);
    if (height < minHeight) height = math.min(minHeight, workArea.height);
    return Size(width, height);
  }

  /// 在 [workArea] 中居中放置 [size] 的矩形。
  ///
  /// ```
  /// left = workArea.left + (workArea.width  - size.width ) / 2
  /// top  = workArea.top  + (workArea.height - size.height) / 2
  /// ```
  ///
  /// 结果一定完整落在 workArea 内（尺寸大于工作区时按左上角对齐并夹取）。
  static Rect centeredIn(Rect workArea, Size size) {
    final double left = workArea.left + (workArea.width - size.width) / 2;
    final double top = workArea.top + (workArea.height - size.height) / 2;
    return Rect.fromLTWH(left, top, size.width, size.height);
  }

  /// 给定桌宠屏幕矩形与适配尺寸，判断是否与桌宠有重叠（仅诊断用）。
  static bool overlaps(Rect panel, Rect pet) => panel.overlaps(pet);
}

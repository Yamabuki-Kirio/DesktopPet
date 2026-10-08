/// 固定画布 × 正式轮盘的**坐标桥接**（纯 Dart，可 `flutter_tester` 直接单测）。
///
/// 职责收窄（增量 B 修正）
/// ----------------------
/// 画布**尺寸**的计算已全部搬到 `WheelCanvasPlanner`
/// （按「当前设置 + 当前显示器工作区」规划，见 `lib/menu/wheel_canvas_plan.dart`）。
/// 本文件只剩一件事：把在**屏幕坐标**里算出来的轮盘窗口矩形，**平移**到固定画布的
/// **局部坐标**，并在极端情况下兜底夹取。
///
/// 为什么需要平移
/// --------------
/// Android 的轮盘画在**全屏 Overlay** 里：它把「显示器可见区域」当画布，
/// 几何可以任意大，超出部分被屏幕自然裁掉。
/// Windows 走的是**固定画布 HWND**（增量 A 已验收）：窗口矩形在 `show()` 之前
/// 一次性确定，打开 / 关闭菜单期间**绝不** `commitBounds`。
/// 轮盘几何仍然按 **Android 原公式**在屏幕坐标里算（方向、靠边偏转、应急缩放
/// 都看显示器边）—— 这里只做一次平移，**不缩放、不改尺寸**。
///
/// dp 与逻辑像素
/// -------------
/// Android 的几何常量以 `dp` 表达，换算系数是 `density`。Windows 的逻辑像素本身
/// 已经是 DPI 无关单位，且桌宠尺寸也以逻辑像素计，因此这里取
/// `density = 1.0`（1 dp = 1 逻辑像素）。这样 `环带半径 / 桌宠可见宽度 ≈ 1.02`，
/// 与 Android 真机上的 `≈ 1.04` 基本一致 —— 观众看到的比例关系相同。
library;

import 'dart:math' as math;
import 'dart:ui' show Rect, Size;

import 'wheel_menu_geometry.dart' show WheelMenuSpec, WheelRect;

/// 固定画布 × 轮盘的坐标桥接。
class WheelCanvasBridge {
  WheelCanvasBridge._();

  /// 逻辑像素 ↔ dp 的换算系数（见文件头说明）。
  static const double density = 1.0;

  /// 轮盘尺寸参数（唯一来源）。
  static WheelMenuSpec spec([double density = density]) =>
      WheelMenuSpec.fromDensity(density);

  /// 轮盘**窗口矩形**（屏幕坐标）→ 画布局部矩形（逻辑局部坐标）。
  ///
  /// 轮盘几何在屏幕坐标里算（方向 / 靠边偏转 / 应急缩放都看显示器边），
  /// 但 widget 必须落在画布内，因此这里只做一次平移。
  static Rect windowToCanvasLocal({
    required WheelRect windowRect,
    required Rect canvasRect,
  }) =>
      Rect.fromLTWH(
        windowRect.left - canvasRect.left,
        windowRect.top - canvasRect.top,
        windowRect.width,
        windowRect.height,
      );

  /// 轮盘窗口矩形夹取到画布内（正常情况下不需要，尺寸预算已覆盖；
  /// 仅当显示器被改小 / 桌宠被搬到极端位置时兜底，避免 widget 跑到画布外）。
  static Rect clampToCanvas(Rect local, Size canvas) {
    final double w = math.min(local.width, canvas.width);
    final double h = math.min(local.height, canvas.height);
    final double left = local.left.clamp(0.0, math.max(0.0, canvas.width - w));
    final double top = local.top.clamp(0.0, math.max(0.0, canvas.height - h));
    return Rect.fromLTWH(left, top, w, h);
  }

  /// 画布是否装得下该轮盘窗口（诊断用；false = 会发生裁切）。
  static bool fitsInCanvas({required WheelRect windowRect, required Size canvas}) =>
      windowRect.width <= canvas.width + 0.5 &&
      windowRect.height <= canvas.height + 0.5;
}

/// **固定画布的坐标管线（唯一）** —— C1.1 需求 §一 / §三，C1.1.1 需求 §五。
///
/// 只允许五个坐标空间
/// ------------------
/// | 空间 | 含义 | 谁产生 |
/// | --- | --- | --- |
/// | `SpritePixelSpace` | 素材原始像素 | 解码器 |
/// | `PetVisualLocalSpace` | 桌宠 Widget 内、**基于 alpha 包围盒**的可见人物坐标 | 本文件 |
/// | `CanvasLocalSpace` | 固定画布局部逻辑像素 | 本文件 |
/// | `ScreenLogicalSpace` | Windows 屏幕逻辑像素 | 本文件 |
/// | `NativePhysicalSpace` | `SetWindowRgn` 前的物理像素 | **只有** `RegionCoordinator`（乘 DPR） |
///
/// 唯一允许的转换顺序
/// ----------------
/// ```
/// sprite alpha bounds                       （PetVisualBounds，比例）
///   → petVisualLocalRect                    （× Widget 尺寸，CanvasLocalSpace）
///   → petVisualScreenRect                   （+ canvasWindowRect.topLeft）
///   → 方向判定（只在 ScreenLogicalSpace 里比 workArea）
///   → WheelGeometry（CanvasLocalSpace）
///   → Region rects（CanvasLocalSpace）
///   → NativePhysicalSpace（RegionCoordinator 乘 DPR，**最后一步**）
/// ```
///
/// 硬禁止（违反即为缺陷，需求 §一 逐条对应）
/// ----------------------------------------
/// * 用素材文件尺寸代替人物可见区域；
/// * 用固定画布窗口左上角代替人物屏幕坐标；
/// * 把 CanvasLocal 矩形与 Screen workArea 直接比较；
/// * Painter 再次平移已经是局部坐标的 geometry；
/// * 绘制阶段再乘 DPR；
/// * Geometry / Painter / Region 各算一套位置。
///
/// 本文件是**纯 Dart**（只依赖 `dart:ui` 的几何类型），可在 `flutter_tester` 单测，
/// 也不破坏 Android 平台隔离。
library;

import 'dart:ui' show Offset, Rect, Size;

import 'package:flutter/foundation.dart' show immutable;

import '../character/pet_visual_bounds.dart';
import 'wheel_menu_geometry.dart' show WheelContentBounds;
import 'wheel_placement.dart' show WheelHorizontalSide, WheelPlacement, WheelVerticalPlacement;

/// 五个坐标空间（**类型层面的声明**：任何换算都必须写明 from/to）。
enum WheelCoordinateSpace {
  /// 素材原始像素（只用于 alpha 测量）。
  spritePixel('sprite_pixel'),

  /// 桌宠 Widget 内、基于 alpha 包围盒的可见人物坐标。
  petVisualLocal('pet_visual_local'),

  /// 固定画布局部逻辑像素。
  canvasLocal('canvas_local'),

  /// Windows 屏幕逻辑像素。
  screenLogical('screen_logical'),

  /// Windows 物理像素（只有 Region 提交用）。
  nativePhysical('native_physical');

  const WheelCoordinateSpace(this.wireName);

  final String wireName;
}

/// 一次「空间快照」：**画布几何的唯一事实**。
///
/// Painter / Region / CanvasPlan / HitTest 全部只消费这一个对象，
/// 因此"四者不同源"这类缺陷在类型层面就不可能发生。
///
/// C1.1.1 需求 §五：本快照**同时**承载这次打开所采用的**布局组合**
/// （水平侧 + 纵向模式）与由此算出的完整视觉 / 画布包围盒，
/// 使得"方向决定"与"绘制 / 命中 / Region / 画布规划"共用同一个不可变事实 ——
/// 任何模块都不允许再自行重新判断方向（缺口、Region、命中只能读这里）。
@immutable
class WheelSpaceSnapshot {
  const WheelSpaceSnapshot({
    required this.canvasWindowRect,
    required this.petAnchor,
    required this.petSize,
    required this.bounds,
    required this.positionRevision,
    required this.geometryRevision,
    required this.surfaceGeneration,
    this.placement,
    this.visualBoundsScreen,
    this.canvasBoundsScreen,
  });

  /// 固定画布窗口矩形（**屏幕逻辑像素**）。
  final Rect canvasWindowRect;

  /// 人物 Widget 左上角在画布内的位置（**画布局部**）。
  final Offset petAnchor;

  /// 人物 Widget 尺寸（= 素材尺寸 × 窗口缩放）。
  final Size petSize;

  /// 人物**视觉**边界（alpha 包围盒，归一化）。
  final PetVisualBounds bounds;

  /// 位置修订号（拖动结束 / 位置写入时自增）。
  final int positionRevision;

  /// 几何修订号（设置 / 人物尺寸 / 显示器变化时自增）。
  final int geometryRevision;

  /// 表面代际（面板 ↔ 桌宠切换时自增）。
  final int surfaceGeneration;

  // ---------------------------------------------------------------------------
  // C1.1.1 §五：布局组合 + 完整包围盒（未打开菜单时为 null）
  // ---------------------------------------------------------------------------

  /// 本次采用的布局组合（水平侧 + 纵向模式）。null = 尚未决议（菜单未打开）。
  final WheelPlacement? placement;

  /// 本次**全部绘制像素**的包围盒（屏幕逻辑像素）。
  final Rect? visualBoundsScreen;

  /// 本次轮盘所需画布的屏幕矩形（需求 §六：`visualBounds.expand(padding).roundOut()`）。
  final Rect? canvasBoundsScreen;

  /// 本次采用的**水平侧**（= 菜单像素主要落在人物的哪一侧）。
  WheelHorizontalSide? get horizontalSide => placement?.horizontalSide;

  /// 本次采用的**纵向模式**（靠上 / 居中 / 靠下）。
  WheelVerticalPlacement? get verticalPlacement => placement?.vertical;

  /// 人物 Widget 在画布内的矩形（**画布局部**）。
  Rect get petWidgetLocalRect =>
      Rect.fromLTWH(petAnchor.dx, petAnchor.dy, petSize.width, petSize.height);

  /// 人物**视觉**矩形（**画布局部**）= alpha 包围盒落在 Widget 矩形里。
  Rect get petVisualLocalRect => bounds.toRect(petWidgetLocalRect);

  /// 人物**视觉**矩形（**屏幕逻辑像素**）。
  Rect get petVisualScreenRect =>
      petVisualLocalRect.shift(canvasWindowRect.topLeft);

  /// 人物 Widget 矩形（屏幕逻辑像素）—— 只用于窗口 / 抓取区，**不可**用于缺口。
  Rect get petWidgetScreenRect =>
      petWidgetLocalRect.shift(canvasWindowRect.topLeft);

  /// 给 Android `computeEnvelope` 用的相对可见边界。
  ///
  /// 与 [petVisualLocalRect] **同源**（同一个 [bounds]），因此缺口一定对齐人物。
  WheelContentBounds get contentBounds => WheelContentBounds(
        bounds.left,
        bounds.top,
        bounds.right,
        bounds.bottom,
      );

  /// 缺口中心（画布局部）—— 必须等于 [petVisualLocalRect] 的中心。
  Offset get notchCenterLocal => petVisualLocalRect.center;

  /// 缺口中心（屏幕逻辑像素）。
  Offset get notchCenterScreen => petVisualScreenRect.center;

  /// 画布尺寸。
  Size get canvasSize => canvasWindowRect.size;

  /// 把布局组合与包围盒**补进来**（在 `open()` 决议完成后一次性附加）。
  ///
  /// 不改变任何位置 / 修订号字段，因此不会让"旧的在飞结果"变成新结果。
  WheelSpaceSnapshot withPlacement({
    WheelPlacement? placement,
    Rect? visualBoundsScreen,
    Rect? canvasBoundsScreen,
  }) =>
      WheelSpaceSnapshot(
        canvasWindowRect: canvasWindowRect,
        petAnchor: petAnchor,
        petSize: petSize,
        bounds: bounds,
        positionRevision: positionRevision,
        geometryRevision: geometryRevision,
        surfaceGeneration: surfaceGeneration,
        placement: placement ?? this.placement,
        visualBoundsScreen: visualBoundsScreen ?? this.visualBoundsScreen,
        canvasBoundsScreen: canvasBoundsScreen ?? this.canvasBoundsScreen,
      );

  // ---------------------------------------------------------------------------
  // 换算（只有这两个方向，且必须写明坐标空间）
  // ---------------------------------------------------------------------------

  /// CanvasLocalSpace → ScreenLogicalSpace。
  Rect canvasLocalToScreen(Rect local) => local.shift(canvasWindowRect.topLeft);

  Offset canvasLocalPointToScreen(Offset local) => local + canvasWindowRect.topLeft;

  /// ScreenLogicalSpace → CanvasLocalSpace。
  Rect screenToCanvasLocal(Rect screen) => screen.shift(-canvasWindowRect.topLeft);

  Offset screenPointToCanvasLocal(Offset screen) => screen - canvasWindowRect.topLeft;

  /// 该快照是否仍然对得上"当前事实"（用于丢弃晚到的异步结果）。
  bool matches({
    required int positionRevision,
    required int geometryRevision,
    required int surfaceGeneration,
  }) =>
      this.positionRevision == positionRevision &&
      this.geometryRevision == geometryRevision &&
      this.surfaceGeneration == surfaceGeneration;

  /// 日志 / 诊断快照（**不**含 DPR：本层不接触物理像素）。
  Map<String, Object?> describe() => <String, Object?>{
        'canvasLocal': _r(Rect.fromLTWH(0, 0, canvasSize.width, canvasSize.height)),
        'canvasWindowRect': _r(canvasWindowRect),
        'petAnchor': _o(petAnchor),
        'petSize': _s(petSize),
        'alphaBounds': bounds.describe(),
        'petWidgetLocalRect': _r(petWidgetLocalRect),
        'petVisualLocalRect': _r(petVisualLocalRect),
        'petVisualScreenRect': _r(petVisualScreenRect),
        'notchCenterLocal': _o(notchCenterLocal),
        'horizontalSide': horizontalSide?.wireName ?? 'none',
        'verticalPlacement': verticalPlacement?.wireName ?? 'none',
        'placement': placement?.wireName ?? 'none',
        'visualBoundsScreen': visualBoundsScreen == null ? 'none' : _r(visualBoundsScreen!),
        'canvasBoundsScreen': canvasBoundsScreen == null ? 'none' : _r(canvasBoundsScreen!),
        'positionRevision': positionRevision,
        'geometryRevision': geometryRevision,
        'surfaceGeneration': surfaceGeneration,
      };

  static String _r(Rect r) => '${r.left.toStringAsFixed(1)},${r.top.toStringAsFixed(1)},'
      '${r.width.toStringAsFixed(1)}×${r.height.toStringAsFixed(1)}';
  static String _o(Offset o) =>
      '${o.dx.toStringAsFixed(1)},${o.dy.toStringAsFixed(1)}';
  static String _s(Size s) =>
      '${s.width.toStringAsFixed(1)}×${s.height.toStringAsFixed(1)}';
}

/// 修订号计数器（三个独立维度）。
///
/// 为什么不用时间戳：时间戳在"同一毫秒内两次变化"时无法判新旧；
/// 单调自增的整数天生可判定，也不需要任何延时。
class WheelRevisionCounter {
  int _value = 0;

  int get value => _value;

  int bump() => ++_value;

  /// 该修订号是否仍是当前值。
  bool isCurrent(int revision) => revision == _value;

  void reset() => _value = 0;
}

/// 构建快照的**唯一入口**（把"顺序"写死在一个地方）。
abstract final class WheelCoordinatePipeline {
  /// 按冻结顺序构建一次空间快照。
  ///
  /// [canvasWindowRect] 与 [petAnchor] 必须来自**同一个**已提交事实
  /// （画布窗口矩形 + 画布内锚点），绝不能一个是屏幕坐标、一个是局部坐标。
  ///
  /// 布局组合（[placement]）与包围盒（[visualBoundsScreen] / [canvasBoundsScreen]）
  /// **只在"打开菜单"这一步已知**，因此是可选的：其它时刻构建的快照为 null，
  /// 由 `withPlacement` 在决议完成后补上（需求 §五）。
  static WheelSpaceSnapshot build({
    required Rect canvasWindowRect,
    required Offset petAnchor,
    required Size petSize,
    required PetVisualBounds bounds,
    required int positionRevision,
    required int geometryRevision,
    required int surfaceGeneration,
    WheelPlacement? placement,
    Rect? visualBoundsScreen,
    Rect? canvasBoundsScreen,
  }) =>
      WheelSpaceSnapshot(
        canvasWindowRect: canvasWindowRect,
        petAnchor: petAnchor,
        petSize: petSize,
        bounds: bounds,
        positionRevision: positionRevision,
        geometryRevision: geometryRevision,
        surfaceGeneration: surfaceGeneration,
        placement: placement,
        visualBoundsScreen: visualBoundsScreen,
        canvasBoundsScreen: canvasBoundsScreen,
      );
}

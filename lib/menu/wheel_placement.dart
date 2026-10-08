/// **轮盘布局方向模型（C1.1.1 需求 §二）**：由「水平侧 × 纵向模式」二元组决定。
///
/// 为什么要把纵向模式提升为一等枚举
/// ------------------------------
/// C1.1 真机验收的现象是：
/// * 人物在**左上 / 右上**时，菜单**上半部分超出工作区**被系统裁掉；
/// * 左右方向本身是正确的（菜单确实在人物的另一侧）。
///
/// 根因在 `WheelMenuGeometry.resolveExpansion` 的**纵向模式沿用上一次**：
/// `previousVerticalMode` 被 `lockMode: true` 原样锁住，于是"先在下半屏打开
/// （bottomEdge）→ 把桌宠拖到左上 → 再打开"时，菜单仍按**靠下**的偏转画，
/// 27° 的偏转方向正好把内容推到屏幕上方 → 上半截被裁。
///
/// 因此本轮把「纵向模式」从"启发式 + 滞回锁定"改为**纯函数**：
/// 每次打开都按**当前**人物位置对三种纵向模式做**溢出量**评估（见
/// `wheel_placement_solver.dart`），选择结果只依赖当前几何，不依赖历史状态。
///
/// 语义（冻结，不得与其他概念混用）
/// ------------------------------
/// * [WheelHorizontalSide]（= C1.1 冻结的 `WheelExpansionSide`）：
///   **菜单像素主要落在人物的哪一侧**；
/// * [WheelVerticalPlacement.top]：**桌宠靠近屏幕顶部 → 菜单主体向下避让**
///   （= Android 的 `topEdge`，扇形中心角向视觉下方偏 `+26°`）；
/// * [WheelVerticalPlacement.bottom]：桌宠靠近屏幕底部 → 菜单主体向上避让；
/// * [WheelVerticalPlacement.middle]：居中（= Android `center`，偏转 0°）。
///
/// 注意 [WheelVerticalPlacement.top] **不是**"菜单向上展开" —— 名字指的是
/// **桌宠所在的位置**（靠上），菜单的实际绘制方向与之相反。
///
/// 偏转常量**逐字复用 Android**（`WheelMenuGeometry.kt` 的 `EDGE_FAN_BIAS_DEG = 26`
/// 与 `WheelVerticalMode`），本轮**不重新设计角度常量**（需求 §四）。
///
/// 本文件是**纯 Dart**，只依赖 `dart:math` 与两个纯几何模块，可在 `flutter_tester`
/// 直接单测，也不破坏 Android 平台隔离。
library;

import 'package:flutter/foundation.dart' show immutable;

import 'wheel_expansion_side.dart';
import 'wheel_menu_geometry.dart' show WheelVerticalMode, kEdgeFanBiasDeg;

/// **水平侧**：菜单像素主要落在人物的哪一侧。
///
/// 这里**不新造枚举**：C1.1 已经把 [WheelExpansionSide] 冻结成"唯一方向语义"
/// （并配了"绝不二次镜像"的契约与回归测试）。再定义一个同义枚举只会制造
/// 第二个事实来源 —— 正是 C1.1 修掉的那类缺陷。因此直接给出别名。
typedef WheelHorizontalSide = WheelExpansionSide;

/// **纵向模式**：桌宠相对屏幕上下边缘的位置决定的菜单避让方向。
///
/// 与 Android [WheelVerticalMode] **一一对应**（`top → topEdge`、
/// `middle → center`、`bottom → bottomEdge`），偏转角度逐字相同。
enum WheelVerticalPlacement {
  /// 桌宠靠**屏幕顶部** → 菜单主体**向下**避让。
  top('top', '靠上', kEdgeFanBiasDeg),

  /// 居中（默认；保持普通位置的现有观感）。
  middle('middle', '居中', 0),

  /// 桌宠靠**屏幕底部** → 菜单主体**向上**避让。
  bottom('bottom', '靠下', -kEdgeFanBiasDeg);

  const WheelVerticalPlacement(this.wireName, this.labelZh, this.biasDeg);

  /// 日志 / 诊断取值（`top` / `middle` / `bottom`）。
  final String wireName;

  /// 中文标签（诊断面板）。
  final String labelZh;

  /// 扇形中心角的偏转（正 = 向视觉下方偏）。**与 Android 同源**。
  final double biasDeg;

  bool get isTop => this == WheelVerticalPlacement.top;
  bool get isMiddle => this == WheelVerticalPlacement.middle;
  bool get isBottom => this == WheelVerticalPlacement.bottom;

  /// 对应的 Android 几何枚举（唯一换算，含义逐字一致）。
  WheelVerticalMode get mode => switch (this) {
        WheelVerticalPlacement.top => WheelVerticalMode.topEdge,
        WheelVerticalPlacement.middle => WheelVerticalMode.center,
        WheelVerticalPlacement.bottom => WheelVerticalMode.bottomEdge,
      };

  /// Android 几何枚举 → 本枚举。
  static WheelVerticalPlacement fromMode(WheelVerticalMode mode) => switch (mode) {
        WheelVerticalMode.topEdge => WheelVerticalPlacement.top,
        WheelVerticalMode.center => WheelVerticalPlacement.middle,
        WheelVerticalMode.bottomEdge => WheelVerticalPlacement.bottom,
      };

  /// 日志取值 → 本枚举（非法值回退 [middle]，与"默认居中"一致）。
  static WheelVerticalPlacement fromWireName(String? raw) {
    for (final WheelVerticalPlacement value in WheelVerticalPlacement.values) {
      if (value.wireName == raw || value.name == raw) return value;
    }
    return WheelVerticalPlacement.middle;
  }
}

/// 最终布局 = 二元组 `(horizontalSide, verticalPlacement)`（需求 §二）。
@immutable
class WheelPlacement {
  const WheelPlacement({
    required this.horizontalSide,
    required this.vertical,
  });

  /// 菜单像素主要落在人物的哪一侧。
  final WheelHorizontalSide horizontalSide;

  /// 纵向避让模式。
  final WheelVerticalPlacement vertical;

  /// 日志 / 诊断取值（例如 `left+top`）。
  String get wireName => '${horizontalSide.wireName}+${vertical.wireName}';

  /// 中文标签（例如 `左靠上`）。
  String get labelZh => '${horizontalSide.isLeft ? '左' : '右'}${vertical.labelZh}';

  WheelPlacement copyWith({
    WheelHorizontalSide? horizontalSide,
    WheelVerticalPlacement? vertical,
  }) =>
      WheelPlacement(
        horizontalSide: horizontalSide ?? this.horizontalSide,
        vertical: vertical ?? this.vertical,
      );

  Map<String, Object?> describe() => <String, Object?>{
        'horizontalSide': horizontalSide.wireName,
        'verticalPlacement': vertical.wireName,
        'combined': wireName,
        'label': labelZh,
        'fanBiasDeg': vertical.biasDeg,
      };

  @override
  bool operator ==(Object other) =>
      other is WheelPlacement &&
      other.horizontalSide == horizontalSide &&
      other.vertical == vertical;

  @override
  int get hashCode => Object.hash(horizontalSide, vertical);

  @override
  String toString() => 'WheelPlacement($wireName)';
}

/// 六种组合的**完整枚举**（需求 §二："六种组合必须完整支持"）。
abstract final class WheelPlacements {
  /// `left + top` / `left + middle` / `left + bottom` /
  /// `right + top` / `right + middle` / `right + bottom`。
  static const List<WheelPlacement> all = <WheelPlacement>[
    WheelPlacement(
      horizontalSide: WheelHorizontalSide.left,
      vertical: WheelVerticalPlacement.top,
    ),
    WheelPlacement(
      horizontalSide: WheelHorizontalSide.left,
      vertical: WheelVerticalPlacement.middle,
    ),
    WheelPlacement(
      horizontalSide: WheelHorizontalSide.left,
      vertical: WheelVerticalPlacement.bottom,
    ),
    WheelPlacement(
      horizontalSide: WheelHorizontalSide.right,
      vertical: WheelVerticalPlacement.top,
    ),
    WheelPlacement(
      horizontalSide: WheelHorizontalSide.right,
      vertical: WheelVerticalPlacement.middle,
    ),
    WheelPlacement(
      horizontalSide: WheelHorizontalSide.right,
      vertical: WheelVerticalPlacement.bottom,
    ),
  ];

  /// 给定水平侧的三种纵向候选（需求 §三的评估对象）。
  static List<WheelPlacement> forSide(WheelHorizontalSide side) => <WheelPlacement>[
        for (final WheelVerticalPlacement v in WheelVerticalPlacement.values)
          WheelPlacement(horizontalSide: side, vertical: v),
      ];
}

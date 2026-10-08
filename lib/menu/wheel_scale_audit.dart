/// **缩放诊断与不变量**（C1.1 需求 §五）。
///
/// 真机症状："轮盘明显过大"。要判定它，必须能一口气看到**每一个**缩放因子
/// 以及"它被应用了几次"，而不是盯着最终像素猜。本文件把这份账做成
/// **可断言的数据**：
///
/// * 原始持久化值（`wheel.scale` / `wheel.buttonScale` / `wheel.menuDistance`）；
/// * 归一化后（0.50~2.50 / 0.50~2.50 / 0.05~0.30）；
/// * 屏幕适配系数 `screenFactor` 与最终 `effectiveScale`；
/// * `geometryDensity`（Windows 固定为 1.0，**不**乘 DPR）；
/// * 计算出来的 `buttonDiameter` / `ringRadius` / `fanBounds` / `canvasSize`；
/// * 四条不变量（违反即缺陷）：
///   1. 持久化值必须已是**归一化**值（不是 60 / 130 这种百分数）；
///   2. `effectiveScale == wheelScale × screenFactor`（且 `screenFactor ≤ 1`）；
///   3. 按钮直径**只**按一个公式算一次：
///      `spec.buttonDiameterFor(count, effectiveScale × buttonScale)`；
///   4. 逻辑像素层**不乘 DPR**（DPR 只允许出现在 `nativePhysical` 那一步）。
///
/// 本文件是**纯 Dart**，可在 `flutter_tester` 单测。
library;

import 'package:flutter/foundation.dart' show immutable;

import 'wheel_menu_geometry.dart'
    show WheelIntrinsicLayout, WheelMenuLayoutSettings, WheelMenuSpec;
/// 一次缩放诊断的快照。
@immutable
class WheelScaleAudit {
  const WheelScaleAudit({
    required this.persistedScale,
    required this.persistedButtonScale,
    required this.persistedMenuDistance,
    required this.normalizedScale,
    required this.normalizedButtonScale,
    required this.normalizedMenuDistance,
    required this.screenFactor,
    required this.effectiveScale,
    required this.effectiveButtonScale,
    required this.geometryDensity,
    required this.devicePixelRatio,
    required this.buttonDiameterPx,
    required this.ringRadiusPx,
    required this.fanBoundsWidth,
    required this.fanBoundsHeight,
    required this.itemCount,
    required this.compact,
  });

  /// 持久化原始值（**必须**是归一化值域；否则 [normalizedOk] 为 false）。
  final double persistedScale;
  final double persistedButtonScale;
  final double persistedMenuDistance;

  /// 归一化后。
  final double normalizedScale;
  final double normalizedButtonScale;
  final double normalizedMenuDistance;

  /// 屏幕适配系数（≤ 1）。
  final double screenFactor;

  /// 实际喂给几何的轮盘缩放（= 归一化 × screenFactor）。
  final double effectiveScale;

  /// 实际喂给几何的按钮倍率（用户值，**不再**乘 screenFactor）。
  final double effectiveButtonScale;

  /// 几何密度（Windows 固定 1.0 = 1dp ↔ 1 逻辑像素）。
  final double geometryDensity;

  /// 窗口 DPR（**只**用于原生 Region 转换；不得进入逻辑几何）。
  final double devicePixelRatio;

  /// 由公式算出的按钮可见直径。
  final double buttonDiameterPx;

  /// 环半径。
  final double ringRadiusPx;

  /// 扇形包围盒（宽 / 高）—— 用绘制半径推导，便于比较"占屏比例"。
  final double fanBoundsWidth;
  final double fanBoundsHeight;

  final int itemCount;
  final bool compact;

  /// 持久化值是否落在归一化值域内（false = 旧版本/异常字段）。
  bool get normalizedOk =>
      persistedScale >= WheelMenuLayoutSettings.minScale - 1e-9 &&
      persistedScale <= WheelMenuLayoutSettings.maxScale + 1e-9 &&
      persistedButtonScale >= WheelMenuLayoutSettings.minButtonScale - 1e-9 &&
      persistedButtonScale <= WheelMenuLayoutSettings.maxButtonScale + 1e-9 &&
      persistedMenuDistance >= WheelMenuLayoutSettings.minDistance - 1e-9 &&
      persistedMenuDistance <= WheelMenuLayoutSettings.maxDistance + 1e-9;

  /// 屏幕适配只允许**压缩**（`screenFactor > 1` 说明乘错了方向）。
  bool get screenFactorOk =>
      screenFactor <= 1.0 + 1e-9 && screenFactor > 0 && screenFactor.isFinite;

  /// `effectiveScale` 必须等于"归一化 × screenFactor"（**恰好一次**）。
  bool get effectiveScaleOk =>
      (effectiveScale - normalizedScale * screenFactor).abs() < 1e-9;

  /// 按钮直径必须等于**唯一公式**的结果（防止重复乘 wheelScale / DPR）。
  bool buttonDiameterOk(WheelMenuSpec spec) {
    final double expected = spec.buttonDiameterFor(
      itemCount,
      effectiveScale * effectiveButtonScale,
    );
    return (buttonDiameterPx - expected).abs() < 1e-6;
  }

  /// 诊断摘要（直接进日志 / 面板）。
  Map<String, Object?> describe() => <String, Object?>{
        'savedWheelScale': persistedScale,
        'savedButtonScale': persistedButtonScale,
        'savedMenuDistance': persistedMenuDistance,
        'normalizedWheelScale': normalizedScale,
        'normalizedButtonScale': normalizedButtonScale,
        'normalizedMenuDistance': normalizedMenuDistance,
        'effectiveWheelScale': effectiveScale,
        'effectiveButtonScale': effectiveButtonScale,
        'screenFactor': screenFactor,
        'devicePixelRatio': devicePixelRatio,
        'geometryDensity': geometryDensity,
        'buttonDiameter': buttonDiameterPx,
        'ringRadius': ringRadiusPx,
        'fanBounds': '${fanBoundsWidth.toStringAsFixed(1)}×'
            '${fanBoundsHeight.toStringAsFixed(1)}',
        'itemCount': itemCount,
        'compact': compact,
        'normalizedOk': normalizedOk,
        'screenFactorOk': screenFactorOk,
        'effectiveScaleOk': effectiveScaleOk,
      };

  /// 从"用户设置 + 屏幕适配结果 + 固有几何"构造。
  static WheelScaleAudit of({
    required WheelMenuLayoutSettings persisted,
    required WheelMenuLayoutSettings effective,
    required WheelIntrinsicLayout intrinsic,
    required WheelMenuSpec spec,
    required double screenFactor,
    required double devicePixelRatio,
  }) {
    final WheelMenuLayoutSettings normalized = persisted.normalized();
    // 扇形包围盒：由"绘制半径"推（外缘 = max(bladeLength, rimOuter)）。
    final double outward =
        intrinsic.bladeLengthPx > intrinsic.rimOuterPx
            ? intrinsic.bladeLengthPx
            : intrinsic.rimOuterPx;
    return WheelScaleAudit(
      persistedScale: persisted.preferredScale,
      persistedButtonScale: persisted.buttonVisualScale,
      persistedMenuDistance: persisted.menuDistance,
      normalizedScale: normalized.preferredScale,
      normalizedButtonScale: normalized.buttonVisualScale,
      normalizedMenuDistance: normalized.menuDistance,
      screenFactor: screenFactor,
      effectiveScale: effective.preferredScale,
      effectiveButtonScale: effective.buttonVisualScale,
      geometryDensity: spec.density,
      devicePixelRatio: devicePixelRatio,
      buttonDiameterPx: intrinsic.buttonDiameterPx,
      ringRadiusPx: intrinsic.ringRadiusPx,
      fanBoundsWidth: outward * 2,
      fanBoundsHeight: outward * 2,
      itemCount: intrinsic.itemCount,
      compact: intrinsic.compact,
    );
  }
}

/// "恢复 Android 默认"的唯一口径（需求 §五）。
///
/// 注意 [WheelMenuLayoutSettings.defaults] 与它必须一致；这里显式列出来是为了
/// 让"默认值"成为**可断言的事实**，而不是散落在各处的字面量。
///
/// ⚠️ 按钮倍率的 Android 默认值是 **1.30**（`DEFAULT_BUTTON_SCALE`），
/// 不是 1.00 —— 真机持久化的 `wheel.buttonScale = 1.3` 因此**就是默认值**，
/// 排查"轮盘过大"时不能把它当成"用户调大了按钮"。
abstract final class WheelDefaultRestore {
  static const double wheelScale = 1.00;

  /// 与 [WheelMenuLayoutSettings.buttonVisualScale] 的 Android 默认值一致。
  static const double buttonScale = WheelMenuLayoutSettings.defaultButtonScale;

  static const double menuDistance = WheelMenuLayoutSettings.defaultDistance;

  /// Android 默认主题 id（P3P 粉）。
  static const String themeId = 'p3p-pink';

  /// 是否为"全默认"（四者都吻合）。
  static bool isDefault({
    required double wheelScale,
    required double buttonScale,
    required double menuDistance,
    required String themeId,
  }) =>
      (wheelScale - WheelDefaultRestore.wheelScale).abs() < 1e-9 &&
      (buttonScale - WheelDefaultRestore.buttonScale).abs() < 1e-9 &&
      (menuDistance - WheelDefaultRestore.menuDistance).abs() < 1e-9 &&
      themeId == WheelDefaultRestore.themeId;
}

/// 稳定尺寸门（纯 Dart，增量 A 修复）。
///
/// 目的：**在提交任何窗口矩形之前**，确认菜单已经被真实测量出一个"有效且稳定"的
/// 尺寸。历史上菜单用旧窗口约束测出 0 / 1×1 / 极小尺寸就被立刻 `setBounds`，
/// 结果窗口被放大成错误的大小（表现为"菜单极小，点第二次才对"）。
///
/// 规则
/// ----
/// * 宽 / 高必须有限、大于 1px、且不小于设计下限 [minWidth] / [minHeight]；
///   **0、1×1、极小值一律判为无效**；
/// * 连续**两帧**尺寸相等或相差不超过 [tolerancePx]（默认 1px）才算稳定；
/// * 任一帧无效即清零稳定计数，绝不"带着上一帧的稳定"继续提交。
///
/// 可在 `flutter_tester` 直接单测（见 `test/wheel_measurement_gate_test.dart`）。
library;

import 'dart:ui' show Size;

/// 一次测量的判定结果。
enum WheelMeasureOutcome {
  /// 尺寸有效但尚未连续稳定两帧：继续测量。
  pending,

  /// 尺寸有效且连续两帧稳定：可以计算几何并提交。
  stable,

  /// 尺寸无效（0 / 1×1 / 过小 / 非有限）：**绝不接受**。
  invalid,
}

class WheelMeasurementGate {
  WheelMeasurementGate({
    this.minWidth = 64,
    this.minHeight = 64,
    this.tolerancePx = 1.0,
  });

  /// 菜单设计下限（逻辑像素）。低于此值一律无效。
  final double minWidth;
  final double minHeight;

  /// 连续两帧的最大允许差（px）。
  final double tolerancePx;

  Size? _last;
  int _stableFrames = 0;

  /// 最近一次被接受的"稳定尺寸"；未稳定时为 null。
  Size? get stableSize => _stableFrames >= 2 ? _last : null;

  int get stableFrameCount => _stableFrames;

  void reset() {
    _last = null;
    _stableFrames = 0;
  }

  WheelMeasureOutcome feed(Size size) {
    if (!size.width.isFinite || !size.height.isFinite) {
      reset();
      return WheelMeasureOutcome.invalid;
    }
    // 0 / 1×1 / 过小 —— 全部拒绝（"旧约束尺寸"通常也落在这个区间）。
    if (size.width <= 1 || size.height <= 1) {
      reset();
      return WheelMeasureOutcome.invalid;
    }
    if (size.width < minWidth || size.height < minHeight) {
      reset();
      return WheelMeasureOutcome.invalid;
    }

    final Size? last = _last;
    if (last != null &&
        (size.width - last.width).abs() <= tolerancePx &&
        (size.height - last.height).abs() <= tolerancePx) {
      _stableFrames++;
    } else {
      _stableFrames = 1;
    }
    _last = size;
    return _stableFrames >= 2 ? WheelMeasureOutcome.stable : WheelMeasureOutcome.pending;
  }
}

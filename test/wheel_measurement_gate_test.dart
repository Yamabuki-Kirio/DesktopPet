import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:petlife/menu/wheel_measurement_gate.dart';

/// 增量 A 修复：**稳定尺寸门**的纯 Dart 用例（需求 §3 / §5）。
///
/// 关键：0 / 1×1 / 过小 / 非有限尺寸一律无效；只有连续两帧相等（或相差 ≤1px）
/// 才算稳定 —— 这是"绝不带着不确定尺寸提交"的守门人。
void main() {
  test('0 与 1×1 一律无效', () {
    final WheelMeasurementGate gate = WheelMeasurementGate();
    expect(gate.feed(Size.zero), WheelMeasureOutcome.invalid);
    expect(gate.feed(const Size(1, 1)), WheelMeasureOutcome.invalid);
    expect(gate.feed(const Size(1, 320)), WheelMeasureOutcome.invalid);
    expect(gate.feed(const Size(320, 1)), WheelMeasureOutcome.invalid);
  });

  test('低于设计下限一律无效', () {
    final WheelMeasurementGate gate = WheelMeasurementGate(minWidth: 64, minHeight: 64);
    expect(gate.feed(const Size(63, 320)), WheelMeasureOutcome.invalid);
    expect(gate.feed(const Size(320, 63)), WheelMeasureOutcome.invalid);
  });

  test('非有限尺寸无效', () {
    final WheelMeasurementGate gate = WheelMeasurementGate();
    expect(gate.feed(const Size(double.infinity, 320)), WheelMeasureOutcome.invalid);
    expect(gate.feed(const Size(320, double.nan)), WheelMeasureOutcome.invalid);
  });

  test('单帧有效只是 pending；连续两帧相等才 stable', () {
    final WheelMeasurementGate gate = WheelMeasurementGate();
    expect(gate.feed(const Size(320, 320)), WheelMeasureOutcome.pending);
    expect(gate.stableSize, isNull);
    expect(gate.feed(const Size(320, 320)), WheelMeasureOutcome.stable);
    expect(gate.stableSize, const Size(320, 320));
  });

  test('两帧相差 1px 视为稳定；超过 1px 重新计数', () {
    final WheelMeasurementGate gate = WheelMeasurementGate();
    expect(gate.feed(const Size(320, 320)), WheelMeasureOutcome.pending);
    expect(gate.feed(const Size(321, 320)), WheelMeasureOutcome.stable);

    final WheelMeasurementGate jitter = WheelMeasurementGate();
    expect(jitter.feed(const Size(320, 320)), WheelMeasureOutcome.pending);
    expect(jitter.feed(const Size(340, 320)), WheelMeasureOutcome.pending); // 变化过大 → 重新计
    expect(jitter.feed(const Size(340, 320)), WheelMeasureOutcome.stable);
  });

  test('无效帧会清零稳定计数（不会带着上一帧的稳定继续）', () {
    final WheelMeasurementGate gate = WheelMeasurementGate();
    expect(gate.feed(const Size(320, 320)), WheelMeasureOutcome.pending);
    expect(gate.feed(const Size(1, 1)), WheelMeasureOutcome.invalid);
    expect(gate.stableSize, isNull);
    // 下一帧即使相同也只会重新回到 pending。
    expect(gate.feed(const Size(320, 320)), WheelMeasureOutcome.pending);
  });

  test('reset 清零', () {
    final WheelMeasurementGate gate = WheelMeasurementGate();
    gate.feed(const Size(320, 320));
    gate.feed(const Size(320, 320));
    expect(gate.stableFrameCount, greaterThanOrEqualTo(2));
    gate.reset();
    expect(gate.stableSize, isNull);
    expect(gate.stableFrameCount, 0);
  });
}

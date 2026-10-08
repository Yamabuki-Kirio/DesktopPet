/// 轮盘手势控制器（**Android `WheelMenuGesture.kt` 的 1:1 移植**）。
///
/// 三条硬规则：
/// 1. **角度判定**，不是水平位移：`slot = nearestSlot(atan2(dy, dx))`
///    —— 只用水平位移在轮盘下半圈会判反；
/// 2. **槽位滞回 7°**：跨槽需要越过"边界 + 滞回角度"，否则手指停在两槽之间时高亮会来回闪；
/// 3. **松手确认**：划过即执行会让"隐藏""停止服务"被误触发，所以一律抬手才生效。
///
/// 第一版**不做惯性旋转**：甩动最多按最后落点确认一项。
///
/// Windows 输入适配（决策四 / docs/37 §15.2）：触摸 → 鼠标由**调用方**映射
/// （按下 ≈ ACTION_DOWN、按住拖动 ≈ ACTION_MOVE、松开 ≈ ACTION_UP），本文件保持纯逻辑不变；
/// **悬停**与 **Esc** 也在调用方实现（悬停走 [indexAt] 只预览、不改已确认项）。
///
/// 本文件是**纯 Dart**，可在 `flutter_tester` 直接单测。
library;

import 'dart:math' as math;

import 'wheel_menu_geometry.dart'
    show WheelMenuGeometry, WheelMenuLayout, WheelMenuSpec;

/// 手指相对轮盘的位置分区。
enum WheelZone {
  /// 中央缺口：取消区。
  center,

  /// 滑选环带：可选择。
  ring,

  /// 环带之外：取消区，且**短暂离开有容差**。
  outside,
}

/// 手势判定结果。
enum WheelGestureEffect {
  none,

  /// 按在按钮/环带上（可以进入点击或滑选）。
  press,

  /// 开始沿弧线滑选。
  swipeStart,

  /// 高亮项发生变化。
  highlight,

  /// 松手确认（[WheelGestureOutcome.index] 为被选中槽位）。
  confirm,

  /// 取消（滑出环带 / 回中心 / 多指介入）。
  cancel,

  /// 落在空白处并松手 —— 关闭整个菜单。
  outsideTap,

  /// 中央桌宠区域开始拖动（由调用方转发给桌宠）。
  petDragStart,

  /// 中央桌宠区域拖动中。
  petDragMove,

  /// 中央桌宠区域拖动结束。
  petDragEnd,
}

/// 中央桌宠区域拖动的三个相位。
enum WheelPetDragPhase { start, move, end }

/// 手势判定结果（调用方据此改状态、给反馈、执行动作）。
class WheelGestureOutcome {
  const WheelGestureOutcome(this.effect, {this.index, this.haptic = false});

  final WheelGestureEffect effect;
  final int? index;

  /// 本次是否应给一次轻触觉（跨槽位各一次）。
  final bool haptic;

  static const WheelGestureOutcome none = WheelGestureOutcome(WheelGestureEffect.none);

  @override
  String toString() => 'WheelGestureOutcome(${effect.name}'
      '${index == null ? '' : ' #$index'}${haptic ? ' haptic' : ''})';
}

/// 轮盘手势控制器（**纯逻辑**）。
class WheelMenuGestureController {
  WheelMenuGestureController({
    required double touchSlopPx,
    required double swipeSlopPx,
    double hysteresisDeg = hysteresisDegDefault,
    int leaveToleranceMs = leaveToleranceMsDefault,
  })  : _touchSlopPx = touchSlopPx,
        _swipeSlopPx = swipeSlopPx,
        _hysteresisDeg = hysteresisDeg,
        _leaveToleranceMs = leaveToleranceMs;

  /// 每个槽位额外增加的滞回角度（需求 6~10°）。
  static const double hysteresisDegDefault = 7;

  /// 短暂离开环带的容差（需求 100~150ms）。
  static const int leaveToleranceMsDefault = 130;

  /// 点击判定阈值（需求 ~8dp）。
  static const double tapSlopDp = 8;

  /// 滑选启动阈值（需求 10~12dp）。
  static const double swipeSlopDp = 12;

  static WheelMenuGestureController fromDensity(double density) {
    final double d = WheelMenuSpec.safeDensity(density);
    return WheelMenuGestureController(
      touchSlopPx: tapSlopDp * d,
      swipeSlopPx: swipeSlopDp * d,
    );
  }

  final double _touchSlopPx;
  final double _swipeSlopPx;
  final double _hysteresisDeg;
  final int _leaveToleranceMs;

  WheelMenuLayout? layout;

  /// 当前已确认的选中项（滑选从它开始算滞回）。
  int selectedIndex = 0;

  _Owner _owner = _Owner.none;
  double _downX = 0;
  double _downY = 0;
  int? _highlightIndex;
  int? _leaveSinceMs;
  bool _petDragging = false;

  /// 诊断用：当前手势归属。
  String get ownerName => _owner.name;

  bool get isSwiping => _owner == _Owner.swiping;

  int? get highlightedIndex => _highlightIndex;

  void reset() {
    _owner = _Owner.none;
    _highlightIndex = null;
    _leaveSinceMs = null;
    _petDragging = false;
  }

  WheelGestureOutcome onDown(double x, double y, int timeMs, {int pointerCount = 1}) {
    final WheelMenuLayout? current = layout;
    if (current == null) return WheelGestureOutcome.none;
    reset();
    _downX = x;
    _downY = y;
    if (pointerCount > 1) {
      // 多指：所有权不明确 → 本轮一律不产生动作。
      _owner = _Owner.cancelled;
      return const WheelGestureOutcome(WheelGestureEffect.cancel);
    }
    final WheelZone zone = zoneAt(current, x, y);
    switch (zone) {
      case WheelZone.ring:
        _owner = _Owner.pressing;
        _highlightIndex = indexAt(current, x, y, selectedIndex);
        return WheelGestureOutcome(WheelGestureEffect.press, index: _highlightIndex);
      case WheelZone.center:
      case WheelZone.outside:
        // 中央缺口 = 桌宠区域（拖动由调用方转发）；落在环带之外才是"空白处"。
        _owner = zone == WheelZone.center ? _Owner.petDrag : _Owner.pendingOutside;
        return WheelGestureOutcome.none;
    }
  }

  WheelGestureOutcome onMove(double x, double y, int timeMs, {int pointerCount = 1}) {
    final WheelMenuLayout? current = layout;
    if (current == null) return WheelGestureOutcome.none;
    if (pointerCount > 1) {
      if (_owner == _Owner.pressing ||
          _owner == _Owner.swiping ||
          _owner == _Owner.pendingOutside ||
          _owner == _Owner.petDrag) {
        _owner = _Owner.cancelled;
        _highlightIndex = null;
        _petDragging = false;
        return const WheelGestureOutcome(WheelGestureEffect.cancel);
      }
      return WheelGestureOutcome.none;
    }
    final double moved = _distance(_downX, _downY, x, y);
    switch (_owner) {
      case _Owner.pendingOutside:
        if (moved > _swipeSlopPx && zoneAt(current, x, y) == WheelZone.ring) {
          _owner = _Owner.swiping;
          return _startHighlight(current, x, y);
        }
        return WheelGestureOutcome.none;
      case _Owner.pressing:
        if (moved <= _swipeSlopPx) return WheelGestureOutcome.none;
        _owner = _Owner.swiping;
        return _startHighlight(current, x, y);
      case _Owner.swiping:
        final WheelZone zone = zoneAt(current, x, y);
        if (zone != WheelZone.ring) {
          final int? since = _leaveSinceMs;
          if (since == null) {
            _leaveSinceMs = timeMs;
            // 首次离开：仍在容差窗口内（0ms ≤ 130ms），保持高亮。
            return WheelGestureOutcome.none;
          }
          if (timeMs - since <= _leaveToleranceMs) {
            // 短暂离开环带：保持当前高亮。
            return WheelGestureOutcome.none;
          }
          _highlightIndex = null;
          return const WheelGestureOutcome(WheelGestureEffect.cancel);
        }
        _leaveSinceMs = null;
        final int? next = indexAt(current, x, y, _highlightIndex);
        if (next == _highlightIndex) return WheelGestureOutcome.none;
        final bool changed = next != _highlightIndex;
        _highlightIndex = next;
        return WheelGestureOutcome(
          WheelGestureEffect.highlight,
          index: next,
          haptic: changed,
        );
      case _Owner.petDrag:
        if (moved > _swipeSlopPx) {
          if (!_petDragging) {
            _petDragging = true;
            return const WheelGestureOutcome(WheelGestureEffect.petDragStart);
          }
          return const WheelGestureOutcome(WheelGestureEffect.petDragMove);
        }
        return WheelGestureOutcome.none;
      case _Owner.cancelled:
      case _Owner.none:
        return WheelGestureOutcome.none;
    }
  }

  WheelGestureOutcome onUp(double x, double y, int timeMs, {int pointerCount = 1}) {
    final WheelMenuLayout? current = layout;
    if (current == null) return WheelGestureOutcome.none;
    final _Owner previous = _owner;
    final double moved = _distance(_downX, _downY, x, y);
    final int? index = _highlightIndex;
    // reset() 会清掉 _petDragging，因此在它之前先把"是否真的拖过"记下来。
    final bool wasPetDragging = _petDragging;
    reset();
    if (pointerCount > 1) return const WheelGestureOutcome(WheelGestureEffect.cancel);
    switch (previous) {
      case _Owner.swiping:
        if (index != null && zoneAt(current, x, y) == WheelZone.ring) {
          return WheelGestureOutcome(WheelGestureEffect.confirm, index: index);
        }
        return const WheelGestureOutcome(WheelGestureEffect.cancel);
      case _Owner.pressing:
        if (index != null && moved <= _touchSlopPx) {
          // 点击阈值内抬手 = 点击该按钮。
          return WheelGestureOutcome(WheelGestureEffect.confirm, index: index);
        }
        return const WheelGestureOutcome(WheelGestureEffect.cancel);
      case _Owner.pendingOutside:
        if (moved <= _touchSlopPx) {
          return const WheelGestureOutcome(WheelGestureEffect.outsideTap);
        }
        return WheelGestureOutcome.none;
      case _Owner.petDrag:
        if (wasPetDragging) {
          return const WheelGestureOutcome(WheelGestureEffect.petDragEnd);
        }
        // 在桌宠区域点一下（没有拖动）＝ 关闭菜单。
        return const WheelGestureOutcome(WheelGestureEffect.outsideTap);
      case _Owner.cancelled:
      case _Owner.none:
        return WheelGestureOutcome.none;
    }
  }

  WheelGestureOutcome onCancel() {
    final _Owner previous = _owner;
    reset();
    return previous == _Owner.none
        ? WheelGestureOutcome.none
        : const WheelGestureOutcome(WheelGestureEffect.cancel);
  }

  /// 位置分区。
  WheelZone zoneAt(WheelMenuLayout layout, double x, double y) {
    if (insideNotch(layout, x, y)) return WheelZone.center;
    final double distance = _distance(layout.centerX, layout.centerY, x, y);
    return distance <= layout.rimOuterPx ? WheelZone.ring : WheelZone.outside;
  }

  /// 是否落在**中央缺口**里（椭圆判定）。
  bool insideNotch(WheelMenuLayout layout, double x, double y) {
    final double rx = math.max(layout.notchRx, 1);
    final double ry = math.max(layout.notchRy, 1);
    final double nx = (x - layout.notchCenterX) / rx;
    final double ny = (y - layout.notchCenterY) / ry;
    return nx * nx + ny * ny <= 1;
  }

  /// 由**角度**推出最近的槽位；[previous] 非空时应用槽位滞回。
  int? indexAt(WheelMenuLayout layout, double x, double y, int? previous) {
    if (layout.itemCount <= 0) return null;
    if (layout.itemCount == 1) return 0;
    final double step = layout.stepDeg;
    if (step <= 0) return null;
    final double angle = math.atan2(y - layout.centerY, x - layout.centerX) * 180 / math.pi;
    final double raw = WheelMenuGeometry.rawIndexAt(layout, angle);
    if (previous != null && previous >= 0 && previous < layout.itemCount) {
      final double hysteresisUnits = (_hysteresisDeg / step).clamp(0.0, 0.45);
      if ((raw - previous).abs() < 0.5 + hysteresisUnits) return previous;
    }
    return raw.round().clamp(0, layout.itemCount - 1);
  }

  WheelGestureOutcome _startHighlight(WheelMenuLayout layout, double x, double y) {
    if (zoneAt(layout, x, y) != WheelZone.ring) {
      return const WheelGestureOutcome(WheelGestureEffect.swipeStart);
    }
    final int? before = _highlightIndex;
    final int? next = indexAt(layout, x, y, _highlightIndex);
    _highlightIndex = next;
    return WheelGestureOutcome(
      WheelGestureEffect.swipeStart,
      index: next,
      haptic: next != before,
    );
  }

  static double _distance(double x0, double y0, double x1, double y1) =>
      math.sqrt(math.pow(x1 - x0, 2) + math.pow(y1 - y0, 2));

  @override
  String toString() => 'WheelMenuGestureController(owner=$ownerName '
      'highlight=$_highlightIndex selected=$selectedIndex)';
}

enum _Owner { none, pressing, swiping, pendingOutside, petDrag, cancelled }

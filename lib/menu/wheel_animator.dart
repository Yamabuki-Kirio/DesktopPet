/// 轮盘动画（**Android `WheelMenuAnimator.kt` 的 1:1 移植**）。
///
/// 动画时序是最需要"逐毫秒打靶"的部分（错峰间隔、拖尾、接管），因此这里全部是
/// **纯函数**，可在 `flutter_tester` 直接单测：
/// * [CubicBezierEasing]：牛顿迭代 8 次 + 二分 18 次兜底（epsilon 1e-4），与 Android 同口径；
/// * [WheelAnimationTimeline]：各段毫秒数与错峰公式；
/// * [WheelAnimationClock.frame]：由 [WheelAnimationRun] 与当前时间推出每帧状态。
///
/// **禁止**使用 Windows 自创的另一套时间参数（决策四）。
library;

import 'dart:math' as math;

/// 三次贝塞尔缓动（纯 Dart）。
class CubicBezierEasing {
  const CubicBezierEasing(this.x1, this.y1, this.x2, this.y2);

  final double x1;
  final double y1;
  final double x2;
  final double y2;

  static const int _newtonIterations = 8;
  static const int _bisectionIterations = 18;
  static const double _newtonEpsilon = 1e-4;

  /// 展开：`PathInterpolator(0.16, 1.0, 0.30, 1.0)`。
  static const CubicBezierEasing open = CubicBezierEasing(0.16, 1.0, 0.30, 1.0);

  /// 切换 / 换层：`PathInterpolator(0.22, 0.85, 0.30, 1.0)`。
  static const CubicBezierEasing switchEase = CubicBezierEasing(0.22, 0.85, 0.30, 1.0);

  /// 关闭：`PathInterpolator(0.55, 0.0, 0.85, 0.35)`。
  static const CubicBezierEasing close = CubicBezierEasing(0.55, 0.0, 0.85, 0.35);

  /// 按钮弹出的轻微回弹（不是无限 Spring，避免"弹跳过度"）。
  static const CubicBezierEasing pop = CubicBezierEasing(0.18, 1.36, 0.36, 1.0);

  /// 给定时间比例 `t ∈ [0,1]`，返回缓动后的进度。
  double value(double t) {
    final double x = t.clamp(0.0, 1.0);
    if (x <= 0) return 0;
    if (x >= 1) return 1;
    return _sampleCurveY(_solveCurveX(x));
  }

  double _sampleCurveX(double t) => _cubic(t, 0, x1, x2, 1);

  double _sampleCurveY(double t) => _cubic(t, 0, y1, y2, 1);

  double _sampleDerivativeX(double t) =>
      3 * math.pow(1 - t, 2) * x1 + 6 * (1 - t) * t * (x2 - x1) + 3 * math.pow(t, 2) * (1 - x2);

  /// 牛顿迭代 + 二分兜底（与 Android 实现同口径，保证真机与单测一致）。
  double _solveCurveX(double x) {
    double t = x;
    for (int i = 0; i < _newtonIterations; i++) {
      final double error = _sampleCurveX(t) - x;
      if (error.abs() < _newtonEpsilon) return t;
      final double derivative = _sampleDerivativeX(t);
      if (derivative.abs() < 1e-6) continue;
      t -= error / derivative;
    }
    double lower = 0;
    double upper = 1;
    t = x;
    for (int i = 0; i < _bisectionIterations; i++) {
      final double current = _sampleCurveX(t);
      if (current > x) {
        upper = t;
      } else if (current < x) {
        lower = t;
      } else {
        return t;
      }
      t = (lower + upper) / 2;
    }
    return t;
  }

  double _cubic(double t, double p0, double p1, double p2, double p3) {
    final double mt = 1 - t;
    return math.pow(mt, 3) * p0 +
        3 * math.pow(mt, 2) * t * p1 +
        3 * mt * math.pow(t, 2) * p2 +
        math.pow(t, 3) * p3;
  }
}

/// 一次动画的种类。
enum WheelAnimationKind {
  open,
  close,
  selectionSwitch,
  enterLayer,
  exitLayer,
  press,
}

/// 一次动画的参数（纯数据）。
class WheelAnimationRun {
  const WheelAnimationRun({
    required this.kind,
    required this.startedAtMs,
    required this.fromSelection,
    required this.toSelection,
    required this.itemCount,
    this.previousItemCount,
    this.pressIndex = -1,
    this.mirrorProgress = 1,
  });

  final WheelAnimationKind kind;
  final int startedAtMs;

  /// 连续浮点选中位（0.0 = 第一项，切换时**连续插值**而不是瞬间换索引）。
  final double fromSelection;
  final double toSelection;
  final int itemCount;

  /// 换层动画的目标层级条目数（旧层级条目数用 [previousItemCount]）。
  final int? previousItemCount;

  /// 按下反馈的目标槽位（-1 = 无）。
  final int pressIndex;

  /// 镜像进度（0 = 向左展开，1 = 向右展开）。
  final double mirrorProgress;

  int get durationMs => WheelAnimationTimeline.durationOf(kind);
}

/// 每帧的动画状态。渲染层**只读这一个结构**。
class WheelAnimationFrame {
  const WheelAnimationFrame({
    required this.openProgress,
    required this.selectionPosition,
    required this.layerProgress,
    required this.titleProgress,
    required this.mirrorProgress,
    required this.buttonProgress,
    required this.pressIndex,
    required this.pressProgress,
    required this.rotationDeg,
    required this.scale,
  });

  /// 0 = 完全收起，1 = 完全展开。
  final double openProgress;

  /// 连续选中位（0.0 = 第一项）。
  final double selectionPosition;

  /// 0 = 还是旧层级，1 = 已完全换成新层级。
  final double layerProgress;

  /// 标题切换进度。
  final double titleProgress;

  /// 每帧的镜像进度（0 = 左展开，1 = 右展开）。
  final double mirrorProgress;

  /// 每个槽位的弹出进度（错峰）。
  final List<double> buttonProgress;

  final int pressIndex;
  final double pressProgress;

  /// 轮盘主体的旋转偏角（`-6° → 1° → 0°`）。
  final double rotationDeg;

  /// 轮盘主体的缩放（`0.75 → 1.03 → 1.0`）。
  final double scale;

  WheelAnimationFrame copyWith({
    double? openProgress,
    double? selectionPosition,
    double? layerProgress,
    double? titleProgress,
    double? mirrorProgress,
    List<double>? buttonProgress,
    int? pressIndex,
    double? pressProgress,
    double? rotationDeg,
    double? scale,
  }) =>
      WheelAnimationFrame(
        openProgress: openProgress ?? this.openProgress,
        selectionPosition: selectionPosition ?? this.selectionPosition,
        layerProgress: layerProgress ?? this.layerProgress,
        titleProgress: titleProgress ?? this.titleProgress,
        mirrorProgress: mirrorProgress ?? this.mirrorProgress,
        buttonProgress: buttonProgress ?? this.buttonProgress,
        pressIndex: pressIndex ?? this.pressIndex,
        pressProgress: pressProgress ?? this.pressProgress,
        rotationDeg: rotationDeg ?? this.rotationDeg,
        scale: scale ?? this.scale,
      );

  /// 完全收起的一帧。
  static WheelAnimationFrame hidden({
    int itemCount = 0,
    double mirrorProgress = 1,
  }) =>
      WheelAnimationFrame(
        openProgress: 0,
        selectionPosition: 0,
        layerProgress: 1,
        titleProgress: 1,
        mirrorProgress: mirrorProgress,
        buttonProgress: List<double>.filled(itemCount, 0),
        pressIndex: -1,
        pressProgress: 0,
        rotationDeg: 0,
        scale: 1,
      );
}

/// 动画时序表（逐段毫秒数，集中一处便于单测与文档引用）。
class WheelAnimationTimeline {
  WheelAnimationTimeline._();

  static const int openMs = 300;
  static const int closeMs = 180;
  static const int selectMs = 220;
  static const int enterLayerMs = 300;
  static const int exitLayerMs = 230;
  static const int pressMs = 70;

  /// 展开时按钮错峰间隔。
  static const int buttonStaggerMs = 25;

  /// 展开阶段各段的起止（相对展开开始）。
  static const int openBodyStartMs = 0;
  static const int openBodyEndMs = 120;
  static const int openButtonStartMs = 50;
  static const int openButtonEndMs = 230;
  static const int openTitleStartMs = 100;
  static const int openTitleEndMs = 300;

  /// 关闭时不允许"反向错峰"造成尾巴拖长：整体一起收。
  static const int closeButtonTailMs = 40;

  static int durationOf(WheelAnimationKind kind) => switch (kind) {
        WheelAnimationKind.open => openMs,
        WheelAnimationKind.close => closeMs,
        WheelAnimationKind.selectionSwitch => selectMs,
        WheelAnimationKind.enterLayer => enterLayerMs,
        WheelAnimationKind.exitLayer => exitLayerMs,
        WheelAnimationKind.press => pressMs,
      };

  /// 某个槽位在展开动画里的弹出进度（错峰）。
  static double buttonProgress(int elapsedMs, int index, int count) {
    const int startDelay = openButtonStartMs;
    final double span = (openButtonEndMs - openButtonStartMs).toDouble();
    // 错峰后总时长会超过 180ms —— 按总数压缩间隔，保证最后一个仍在 OPEN_BUTTON_END 内弹出。
    final double stagger = count <= 1
        ? 0
        : math.min(buttonStaggerMs.toDouble(), (span * 0.5) / (count - 1));
    final double start = startDelay + stagger * index;
    if (elapsedMs <= start) return 0;
    final double local = ((elapsedMs - start).toDouble() / span).clamp(0.0, 1.0);
    return CubicBezierEasing.pop.value(local);
  }
}

/// 由 [WheelAnimationRun] 与当前时间推出 [WheelAnimationFrame]（**纯函数**）。
class WheelAnimationClock {
  WheelAnimationClock._();

  static WheelAnimationFrame frame(WheelAnimationRun run, int nowMs) {
    final int elapsed = math.max(0, nowMs - run.startedAtMs);
    final double total = run.durationMs.toDouble();
    final double raw =
        total <= 0 ? 1.0 : (elapsed.toDouble() / total).clamp(0.0, 1.0);
    final double eased = switch (run.kind) {
      WheelAnimationKind.open => CubicBezierEasing.open.value(raw),
      WheelAnimationKind.close => CubicBezierEasing.close.value(raw),
      _ => CubicBezierEasing.switchEase.value(raw),
    };
    final int count = math.max(1, run.itemCount);
    final List<double> buttons = <double>[
      for (int index = 0; index < count; index++)
        switch (run.kind) {
          WheelAnimationKind.open =>
            WheelAnimationTimeline.buttonProgress(elapsed, index, count),
          WheelAnimationKind.close => 1 -
              CubicBezierEasing.close
                  .value(((elapsed + index * 0) / total).clamp(0.0, 1.0)),
          WheelAnimationKind.enterLayer => _staggeredPop(
              elapsed, index, count, 80, WheelAnimationTimeline.enterLayerMs),
          WheelAnimationKind.exitLayer => _staggeredPop(
              elapsed, index, count, 60, WheelAnimationTimeline.exitLayerMs),
          WheelAnimationKind.selectionSwitch || WheelAnimationKind.press => 1.0,
        },
    ];
    final double pressProgress = run.pressIndex >= 0
        ? switch (run.kind) {
            WheelAnimationKind.press => raw < 0.5
                ? CubicBezierEasing.switchEase.value(raw / 0.5)
                : 1 - CubicBezierEasing.open.value((raw - 0.5) / 0.5),
            _ => 0.0,
          }
        : 0.0;
    final double selection = switch (run.kind) {
      WheelAnimationKind.open ||
      WheelAnimationKind.close ||
      WheelAnimationKind.enterLayer ||
      WheelAnimationKind.exitLayer =>
        run.toSelection,
      _ => run.fromSelection + (run.toSelection - run.fromSelection) * eased,
    };
    return WheelAnimationFrame(
      openProgress: switch (run.kind) {
        WheelAnimationKind.open => CubicBezierEasing.open.value(raw),
        WheelAnimationKind.close => 1 - CubicBezierEasing.close.value(raw),
        _ => 1,
      },
      selectionPosition: selection,
      layerProgress: switch (run.kind) {
        WheelAnimationKind.enterLayer => eased,
        WheelAnimationKind.exitLayer => 1 - eased,
        _ => 1,
      },
      titleProgress: switch (run.kind) {
        WheelAnimationKind.selectionSwitch => eased,
        WheelAnimationKind.enterLayer => eased,
        WheelAnimationKind.exitLayer => 1 - eased,
        _ => 1,
      },
      mirrorProgress: run.mirrorProgress,
      buttonProgress: buttons,
      pressIndex: run.pressIndex,
      pressProgress: pressProgress,
      rotationDeg: _openRotation(run.kind, raw),
      scale: _openScale(run.kind, raw),
    );
  }

  static bool isFinished(WheelAnimationRun run, int nowMs) =>
      nowMs - run.startedAtMs >= run.durationMs;

  /// 展开时的 `-6° → 1° → 0°`；关闭时反向。
  static double _openRotation(WheelAnimationKind kind, double raw) => switch (kind) {
        WheelAnimationKind.open => raw < 0.5
            ? -6 + (1 - -6) * (raw / 0.5)
            : 1 - 1 * ((raw - 0.5) / 0.5),
        WheelAnimationKind.close => 6 * raw,
        _ => 0,
      };

  /// 展开时的 `0.75 → 1.03 → 1.0`；关闭时反向收缩。
  static double _openScale(WheelAnimationKind kind, double raw) => switch (kind) {
        WheelAnimationKind.open => raw < 0.55
            ? 0.75 + (1.03 - 0.75) * (raw / 0.55)
            : 1.03 - 0.03 * ((raw - 0.55) / 0.45),
        WheelAnimationKind.close => 1 - 0.25 * raw,
        _ => 1,
      };

  /// 换层动画里第 [index] 个按钮的弹出。
  static double _staggeredPop(
    int elapsedMs,
    int index,
    int count,
    int delayMs,
    int totalMs,
  ) {
    final int stagger = count <= 1
        ? 0
        : math.min(WheelAnimationTimeline.buttonStaggerMs, 120 ~/ (count - 1));
    final int start = delayMs + stagger * index;
    final int span = math.max(1, totalMs - start);
    final double local = ((elapsedMs - start).toDouble() / span).clamp(0.0, 1.0);
    return CubicBezierEasing.pop.value(local);
  }
}

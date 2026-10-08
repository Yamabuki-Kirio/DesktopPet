/// 轮盘菜单几何诊断（增量 A）。
///
/// 目标：把"打开 / 关闭"这一次事件里的**关键几何事实**记下来，供设置页展示与
/// 一键复制，而不是每帧刷屏：
///
/// * 每次打开记录：显示器 id、DPI 与 devicePixelRatio、旧窗口矩形、目标窗口矩形、
///   桌宠原始屏幕坐标、桌宠补偿后的局部坐标、提交方式（`setBounds`）、提交耗时、
///   提交后**重新读回**的实际窗口矩形、桌宠最终屏幕坐标误差；
/// * 每次关闭记录：是否已恢复、透明区域是否仍然挡住点击；
/// * **逐帧几何只在诊断模式下记录，且只记前 12 帧**。
///
/// 这一层是纯 Dart（只依赖 `dart:ui`），与平台实现无关，
/// 因此可在 `flutter_tester` 里直接断言（见 `test/wheel_menu_diagnostics_test.dart`）。
library;

import 'dart:ui' show Offset, Rect;

import 'package:flutter/foundation.dart';

/// 一次打开 / 关闭事件的诊断快照。
class WheelMenuDiagnosticSample {
  WheelMenuDiagnosticSample({
    required this.event,
    required this.timestampMs,
    this.displayId,
    this.devicePixelRatio,
    this.dpi,
    this.oldWindowRect,
    this.targetWindowRect,
    this.actualWindowRect,
    this.petScreenRect,
    this.petLocalOffset,
    this.commitMethod,
    this.commitDurationMs,
    this.petScreenErrorPx,
    this.restoredAfterClose,
    this.transparentRegionBlocksClicks,
    this.menuOnRight,
    this.clampedByDisplay,
    this.note,
    List<String>? frames,
  }) : frames = frames ?? <String>[];

  /// `open` / `close`。
  final String event;

  final int timestampMs;

  /// 当前显示器 id（`screen_retriever` 的显示器 id）。
  final String? displayId;

  final double? devicePixelRatio;

  /// 由 devicePixelRatio 推算的 DPI（96 × 缩放比）。
  final double? dpi;

  /// 变更前的窗口矩形。
  final Rect? oldWindowRect;

  /// 目标窗口矩形（一次 setBounds 提交的值）。
  final Rect? targetWindowRect;

  /// 提交后**重新读回**的实际窗口矩形。
  final Rect? actualWindowRect;

  /// 桌宠原始屏幕坐标（打开前）。
  final Rect? petScreenRect;

  /// 桌宠在新窗口内的补偿局部坐标。
  final Offset? petLocalOffset;

  /// 提交方式（本增量恒为 `setBounds`）。
  final String? commitMethod;

  /// 提交耗时（毫秒）。
  final double? commitDurationMs;

  /// 桌宠最终屏幕坐标误差（绝对差之和，0 表示完全一致）。
  final double? petScreenErrorPx;

  /// 关闭后窗口是否已恢复到桌宠矩形。
  final bool? restoredAfterClose;

  /// 透明区域是否仍然挡住点击（关闭后若窗口未还原即为 true）。
  final bool? transparentRegionBlocksClicks;

  final bool? menuOnRight;
  final bool? clampedByDisplay;

  /// 备注（例如"鼠标穿透已开启，未打开菜单"）。
  final String? note;

  /// 逐帧几何（仅诊断模式下前 12 帧）。
  final List<String> frames;

  /// 固定键（顺序固定）—— 复制文本与设置页展示共用。
  static const List<String> frozenKeys = <String>[
    'event',
    'timestamp_ms',
    'display_id',
    'device_pixel_ratio',
    'dpi',
    'old_window_rect',
    'target_window_rect',
    'actual_window_rect',
    'pet_screen_rect',
    'pet_local_offset',
    'commit_method',
    'commit_duration_ms',
    'pet_screen_error_px',
    'restored_after_close',
    'transparent_region_blocks_clicks',
    'menu_on_right',
    'clamped_by_display',
    'frame_count',
    'note',
  ];

  Map<String, Object?> toMap() => <String, Object?>{
        'event': event,
        'timestamp_ms': timestampMs,
        'display_id': displayId,
        'device_pixel_ratio':
            devicePixelRatio == null ? null : _round(devicePixelRatio!, 3),
        'dpi': dpi == null ? null : _round(dpi!, 1),
        'old_window_rect': formatRect(oldWindowRect),
        'target_window_rect': formatRect(targetWindowRect),
        'actual_window_rect': formatRect(actualWindowRect),
        'pet_screen_rect': formatRect(petScreenRect),
        'pet_local_offset': formatOffset(petLocalOffset),
        'commit_method': commitMethod,
        'commit_duration_ms': commitDurationMs == null ? null : _round(commitDurationMs!, 2),
        'pet_screen_error_px': petScreenErrorPx == null ? null : _round(petScreenErrorPx!, 3),
        'restored_after_close': restoredAfterClose,
        'transparent_region_blocks_clicks': transparentRegionBlocksClicks,
        'menu_on_right': menuOnRight,
        'clamped_by_display': clampedByDisplay,
        'frame_count': frames.length,
        'note': note,
      };

  /// 稳定的 `key=value` 文本块（每行一个键，顺序固定，便于 grep / 对账）。
  ///
  /// 缺失值统一写 `none`（与既有双窗口探针的 `none` 口径一致）。
  String toCopyText() {
    final Map<String, Object?> map = toMap();
    final StringBuffer buffer = StringBuffer();
    for (final String key in frozenKeys) {
      final Object? value = map[key];
      buffer.writeln("$key=${value ?? 'none'}");
    }
    if (frames.isNotEmpty) {
      buffer.writeln('frames=');
      for (int i = 0; i < frames.length; i++) {
        buffer.writeln('  [$i] ${frames[i]}');
      }
    }
    return buffer.toString().trimRight();
  }

  /// `left,top w×h`；null → `none`。
  static String formatRect(Rect? rect) {
    if (rect == null) return 'none';
    return '${_round(rect.left, 1)},${_round(rect.top, 1)} '
        '${_round(rect.width, 1)}×${_round(rect.height, 1)}';
  }

  static String formatOffset(Offset? offset) {
    if (offset == null) return 'none';
    return '${_round(offset.dx, 1)},${_round(offset.dy, 1)}';
  }

  /// 去掉多余小数尾巴：整数返回 int，否则返回保留 [digits] 位的 double。
  static num _round(double value, int digits) {
    final double rounded = double.parse(value.toStringAsFixed(digits));
    if (rounded == rounded.roundToDouble()) return rounded.toInt();
    return rounded;
  }
}

/// 诊断信息仓库（单例 [wheelMenuDiagnostics]，模块级共享）。
///
/// 为什么用模块级单例而不是塞进 `AppServices`：它是**只读/临时**的调试信息，
/// 不应污染应用级依赖容器（与既有的 `processMetricsAvailable` 同一思路）。
class WheelMenuDiagnostics extends ChangeNotifier {
  /// 是否开启"逐帧几何记录"（默认关闭，避免刷屏）。
  bool diagnosticMode = false;

  /// 逐帧记录上限（需求：只记前 12 帧）。
  static const int maxFrameLogs = 12;

  /// 保留的样本条数上限。
  static const int maxSamples = 20;

  final List<WheelMenuDiagnosticSample> _samples = <WheelMenuDiagnosticSample>[];

  WheelMenuDiagnosticSample? _activeOpenSample;

  /// 最新在前的样本列表。
  List<WheelMenuDiagnosticSample> get samples =>
      List<WheelMenuDiagnosticSample>.unmodifiable(_samples);

  bool get hasSamples => _samples.isNotEmpty;

  WheelMenuDiagnosticSample? get latest => _samples.isEmpty ? null : _samples.first;

  /// 打开菜单：记账一次。
  void recordOpen({
    required String displayId,
    required double devicePixelRatio,
    required Rect oldWindowRect,
    required Rect targetWindowRect,
    required Rect actualWindowRect,
    required Offset petLocalOffset,
    required double commitDurationMs,
    required double petScreenErrorPx,
    required bool menuOnRight,
    required bool clampedByDisplay,
    String commitMethod = 'setBounds',
    String? note,
  }) {
    final WheelMenuDiagnosticSample sample = WheelMenuDiagnosticSample(
      event: 'open',
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      displayId: displayId,
      devicePixelRatio: devicePixelRatio,
      dpi: 96 * devicePixelRatio,
      oldWindowRect: oldWindowRect,
      targetWindowRect: targetWindowRect,
      actualWindowRect: actualWindowRect,
      petScreenRect: oldWindowRect,
      petLocalOffset: petLocalOffset,
      commitMethod: commitMethod,
      commitDurationMs: commitDurationMs,
      petScreenErrorPx: petScreenErrorPx,
      menuOnRight: menuOnRight,
      clampedByDisplay: clampedByDisplay,
      note: note,
    );
    _insert(sample);
    _activeOpenSample = sample;
  }

  /// "未打开"记录（例如鼠标穿透开启被拒绝）—— 同样落一条，便于对账。
  void recordRejected({required String note, String? displayId}) {
    _insert(WheelMenuDiagnosticSample(
      event: 'rejected',
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      displayId: displayId,
      note: note,
    ));
  }

  /// 关闭菜单：记账一次。
  void recordClose({
    required Rect oldWindowRect,
    required Rect targetWindowRect,
    required Rect actualWindowRect,
    required bool restoredAfterClose,
    required bool transparentRegionBlocksClicks,
    required double commitDurationMs,
    required double petScreenErrorPx,
    String commitMethod = 'setBounds',
    String? note,
  }) {
    _insert(WheelMenuDiagnosticSample(
      event: 'close',
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      oldWindowRect: oldWindowRect,
      targetWindowRect: targetWindowRect,
      actualWindowRect: actualWindowRect,
      petScreenRect: targetWindowRect,
      commitMethod: commitMethod,
      commitDurationMs: commitDurationMs,
      petScreenErrorPx: petScreenErrorPx,
      restoredAfterClose: restoredAfterClose,
      transparentRegionBlocksClicks: transparentRegionBlocksClicks,
      note: note,
    ));
    _activeOpenSample = null;
  }

  /// 逐帧几何记录：**仅诊断模式**、**仅前 [maxFrameLogs] 帧**。
  ///
  /// [describe] 是这一帧的几何摘要（窗口矩形 / 桌宠预测屏幕坐标等）。
  void logFrame(int frameIndex, String describe) {
    final WheelMenuDiagnosticSample? active = _activeOpenSample;
    if (active == null) return;
    if (!diagnosticMode) return;
    if (active.frames.length >= maxFrameLogs) return;
    active.frames.add('f$frameIndex $describe');
    notifyListeners();
  }

  void clear() {
    _samples.clear();
    _activeOpenSample = null;
    notifyListeners();
  }

  /// 复制文本：表头 + 每个样本块（最新在前）。
  String toCopyText() {
    final StringBuffer buffer = StringBuffer()
      ..writeln('wheel_menu_diagnostics=1')
      ..writeln('diagnostic_mode=${diagnosticMode ? 'true' : 'false'}')
      ..writeln('sample_count=${_samples.length}');
    for (final WheelMenuDiagnosticSample sample in _samples) {
      buffer
        ..writeln('---')
        ..writeln(sample.toCopyText());
    }
    return buffer.toString().trimRight();
  }

  void _insert(WheelMenuDiagnosticSample sample) {
    _samples.insert(0, sample);
    if (_samples.length > maxSamples) {
      _samples.removeRange(maxSamples, _samples.length);
    }
    notifyListeners();
  }
}

/// 模块级共享实例（探针写入、设置页读取）。
final WheelMenuDiagnostics wheelMenuDiagnostics = WheelMenuDiagnostics();

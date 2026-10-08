/// 轮盘"打开 / 关闭"的**几何事务**（纯 Dart，增量 A 修复）。
///
/// 这是竞态修复的核心状态机：它把"测量 → 校验 → 原子提交 → 回读验证 → 呈现 /
/// 回滚"变成一次**受控事务**，并保证任一时刻只有一个事务在进行。
///
/// 与 UI 的分工
/// ------------
/// * 本类**不碰 widget**：它只负责几何、所有权、代际、事件与窗口写入（经 [WheelWindowOps]）；
/// * `WheelGeometryProbe` 负责把菜单放进 widget 树（不可见、不可点）并逐帧把
///   测量结果喂给 [offerMenuMeasurement]。
///
/// 关键不变量
/// ----------
/// 1. 测量未稳定（或无效）⇒ **绝不** `commitBounds`；
/// 2. 一次打开只允许**一次** `commitBounds`（提交前先做硬校验）；
/// 3. 提交后必须**回读**实际矩形并核对桌宠屏幕误差，偏差过大 ⇒ 回滚；
/// 4. 失败 / 超时 ⇒ 恢复原窗口矩形 + 桌宠局部偏移 + owner=pet + "轮盘布局失败"；
/// 5. 关闭顺序：owner wheel→wheelTransition（同步）⇒ 隐藏菜单 ⇒ 还原矩形 ⇒
///    回读验证 ⇒ 清理 ⇒ owner=pet。
///
/// 可在 `flutter_tester` 用假 [WheelWindowOps] 直接单测
/// （见 `test/wheel_open_transaction_test.dart`）。
library;

import 'dart:ui' show Offset, Rect, Size;

import 'wheel_geometry.dart';
import 'wheel_geometry_ownership.dart';
import 'wheel_measurement_gate.dart';
import 'wheel_window_ops.dart';

/// 事务阶段。
enum WheelOpenPhase {
  closed,
  measuring,
  committing,
  open,
  closing,
}

/// [beginOpen] 的结果。
class WheelOpenRequest {
  const WheelOpenRequest.accepted({
    required this.petRect,
    required this.display,
  })  : accepted = true,
        reason = null;

  const WheelOpenRequest.rejected(this.reason)
      : accepted = false,
        petRect = null,
        display = null;

  final bool accepted;
  final String? reason;
  final Rect? petRect;
  final WheelDisplayArea? display;
}

/// [commitOpen] 的结果。
class WheelOpenOutcome {
  const WheelOpenOutcome.opened({
    required this.geometry,
    required this.actualBounds,
    required this.petScreenErrorPx,
  })  : opened = true,
        reason = null;

  const WheelOpenOutcome.failed(this.reason)
      : opened = false,
        geometry = null,
        actualBounds = null,
        petScreenErrorPx = null;

  final bool opened;
  final String? reason;
  final WheelGeometryResult? geometry;
  final Rect? actualBounds;
  final double? petScreenErrorPx;
}

/// [finishClose] 的结果。
class WheelCloseOutcome {
  const WheelCloseOutcome({required this.restored, this.actualBounds, this.reason});

  final bool restored;
  final Rect? actualBounds;
  final String? reason;
}

/// 轮盘几何事务。
class WheelOpenTransaction {
  WheelOpenTransaction({
    required WheelWindowOps ops,
    required Future<void> Function() waitForFrame,
    WheelSurfaceGeometry? surface,
    WheelGeometryJournal? journal,
    bool Function()? diagnosticsEnabled,
    this.minMenuSide = 64,
    this.menuGap = 12,
    this.petScreenErrorTolerancePx = 2.0,
    this.boundsDriftTolerancePx = 4.0,
  })  : _ops = ops,
        _waitForFrame = waitForFrame,
        _surface = surface ?? wheelSurfaceGeometry,
        _journal = journal ?? wheelGeometryJournal,
        _diagnosticsEnabled = diagnosticsEnabled ?? (() => false);

  /// 逐帧事件上限（需求：仅诊断模式、仅前 12 帧）。
  static const int maxMeasureFrameLogs = 12;

  final WheelWindowOps _ops;
  final Future<void> Function() _waitForFrame;
  final WheelSurfaceGeometry _surface;
  final WheelGeometryJournal _journal;
  final bool Function() _diagnosticsEnabled;

  final double minMenuSide;
  final double menuGap;
  final double petScreenErrorTolerancePx;
  final double boundsDriftTolerancePx;

  WheelMeasurementGate _gate = WheelMeasurementGate();
  WheelOpenPhase _phase = WheelOpenPhase.closed;
  bool _reserved = false;
  WheelGeometryResult? _geometry;
  Rect? _originalRect;
  Rect? _petRect;
  WheelDisplayArea? _display;
  Size? _stableMenuSize;
  Rect? _lastActualBounds;
  double? _lastPetScreenError;
  int _measureFrames = 0;
  String? _lastMessage;

  WheelOpenPhase get phase => _phase;

  bool get isOpen => _phase == WheelOpenPhase.open;

  bool get isBusy => _phase != WheelOpenPhase.closed || _reserved;

  Rect? get originalRect => _originalRect;

  WheelGeometryResult? get geometry => _geometry;

  Size? get stableMenuSize => _stableMenuSize;

  WheelDisplayArea? get display => _display;

  Rect? get lastActualBounds => _lastActualBounds;

  double? get lastPetScreenError => _lastPetScreenError;

  String? get lastMessage => _lastMessage;

  /// 当前桌宠在窗口内的补偿偏移（未打开时为 0）。
  Offset get petLocal => _geometry?.petLocal ?? Offset.zero;

  /// 当前菜单在窗口内的局部坐标（未打开时为 0）。
  Offset get menuLocal => _geometry?.menuLocal ?? Offset.zero;

  /// 第 1 步：读取原始窗口矩形与显示器，切换 owner=wheelTransition。
  ///
  /// 同一时刻只允许一个事务：已在进行中直接拒绝（保证"快速连点只有一个事务"）。
  Future<WheelOpenRequest> beginOpen() async {
    // `_reserved` 在**首个 await 之前**同步置位，因此连点两次也只会有一个事务。
    if (_phase != WheelOpenPhase.closed || _reserved) {
      return const WheelOpenRequest.rejected('已有打开 / 关闭流程正在进行');
    }
    _reserved = true;
    _journal.record('wheel.open.request');
    try {
      final Rect bounds = await _ops.currentBounds();
      if (!(bounds.width > 1 && bounds.height > 1)) {
        return WheelOpenRequest.rejected('当前窗口尺寸无效：${bounds.width}×${bounds.height}');
      }
      final WheelDisplayArea? display = await _ops.displayForPoint(bounds.center);
      if (display == null) {
        return const WheelOpenRequest.rejected('未检测到可用显示器');
      }
      _originalRect = bounds;
      _petRect = bounds;
      _display = display;
      _gate = WheelMeasurementGate(minWidth: minMenuSide, minHeight: minMenuSide);
      _measureFrames = 0;
      _geometry = null;
      _stableMenuSize = null;
      _lastMessage = null;
      // 同步切换所有权：从这一刻起，任何延迟的 pet resize 都会被丢弃。
      _surface.change(WindowsSurfaceGeometryOwner.wheelTransition, source: 'wheel.beginOpen');
      _phase = WheelOpenPhase.measuring;
      return WheelOpenRequest.accepted(petRect: bounds, display: display);
    } catch (e) {
      return WheelOpenRequest.rejected('读取窗口几何失败：$e');
    } finally {
      _reserved = false;
    }
  }

  /// 第 3~4 步：喂入一帧的测量尺寸；稳定时计算几何并进入 committing。
  WheelMeasureOutcome offerMenuMeasurement(Size size) {
    if (_phase != WheelOpenPhase.measuring) return WheelMeasureOutcome.invalid;
    _measureFrames++;
    if (_diagnosticsEnabled() && _measureFrames <= maxMeasureFrameLogs) {
      _journal.record(
        'wheel.measure.frame',
        fields: <String, Object?>{
          'frame': _measureFrames,
          'size': '${size.width}×${size.height}',
        },
      );
    }
    final WheelMeasureOutcome outcome = _gate.feed(size);
    if (outcome != WheelMeasureOutcome.stable) {
      return outcome;
    }

    final Rect petRect = _petRect!;
    final WheelDisplayArea display = _display!;
    final WheelGeometryResult result = WheelGeometry.compute(
      petRect: petRect,
      layout: WheelMenuLayout(menuSize: size, gap: menuGap),
      display: display,
    );
    _stableMenuSize = size;
    _geometry = result;
    _phase = WheelOpenPhase.committing;
    _journal.record(
      'wheel.measure.stable',
      fields: <String, Object?>{
        'menu_size': '${size.width}×${size.height}',
        'window_rect': WheelGeometryJournal.formatRect(result.windowRect),
        'pet_local': WheelGeometryJournal.formatOffset(result.petLocal),
        'menu_local': WheelGeometryJournal.formatOffset(result.menuLocal),
      },
    );
    return WheelMeasureOutcome.stable;
  }

  /// 第 5~7 步：硬校验 + **一次**原子提交 + 回读验证；失败则回滚。
  Future<WheelOpenOutcome> commitOpen() async {
    final WheelGeometryResult? result = _geometry;
    if (_phase != WheelOpenPhase.committing || result == null) {
      return const WheelOpenOutcome.failed('当前状态不允许提交窗口矩形');
    }
    final String? validationError = _hardValidationError(result);
    if (validationError != null) {
      _journal.record('wheel.bounds.commit.failed', fields: <String, Object?>{'reason': validationError});
      return _rollback(validationError);
    }

    final Rect before = await _ops.currentBounds();
    _journal.record(
      'wheel.bounds.commit.start',
      fields: <String, Object?>{
        'target': WheelGeometryJournal.formatRect(result.windowRect),
        'before': WheelGeometryJournal.formatRect(before),
        'owner': _surface.owner.wireName,
        'generation': _surface.generation,
      },
    );
    _journal.recordSizeWrite(
      source: 'wheel.open.commitBounds',
      generation: _surface.generation,
      owner: _surface.owner,
      requested: result.windowRect,
      before: before,
      after: null,
    );

    try {
      await _ops.commitBounds(result.windowRect);
    } catch (e) {
      _journal.record('wheel.bounds.commit.failed', fields: <String, Object?>{'reason': '$e'});
      return _rollback('提交窗口矩形失败：$e');
    }

    // 等窗口度量真正生效（一帧提交 + 一帧确认），再回读。
    await _waitForFrame();
    await _waitForFrame();

    final Rect actual = await _ops.currentBounds();
    final double petError = WheelGeometry.petScreenError(
      expected: _petRect!,
      actualWindowRect: actual,
      petLocal: result.petLocal,
    );
    final double drift = _rectDrift(actual, result.windowRect);

    _journal.record(
      'wheel.actual_bounds',
      fields: <String, Object?>{
        'actual': WheelGeometryJournal.formatRect(actual),
        'target': WheelGeometryJournal.formatRect(result.windowRect),
        'drift': double.parse(drift.toStringAsFixed(2)),
      },
    );
    _journal.record(
      'wheel.pet_screen_error',
      fields: <String, Object?>{'error_px': double.parse(petError.toStringAsFixed(2))},
    );

    if (drift > boundsDriftTolerancePx || petError > petScreenErrorTolerancePx) {
      _journal.record(
        'wheel.bounds.commit.failed',
        fields: <String, Object?>{'drift': drift, 'pet_screen_error_px': petError},
      );
      return _rollback('窗口实际矩形与目标偏差过大（drift=${drift.toStringAsFixed(1)}px）');
    }

    _lastActualBounds = actual;
    _lastPetScreenError = petError;
    // 稳定显示：owner=wheel，允许菜单接管输入。
    _surface.change(WindowsSurfaceGeometryOwner.wheel, source: 'wheel.commitOpen');
    _phase = WheelOpenPhase.open;
    _journal.record(
      'wheel.bounds.commit.success',
      fields: <String, Object?>{
        'actual': WheelGeometryJournal.formatRect(actual),
        'pet_screen_error_px': double.parse(petError.toStringAsFixed(2)),
      },
    );
    _journal.record('wheel.present');
    return WheelOpenOutcome.opened(
      geometry: result,
      actualBounds: actual,
      petScreenErrorPx: petError,
    );
  }

  /// 关闭：第 1 步（同步）：owner wheel→wheelTransition、进入 closing。
  ///
  /// 调用后 UI 应**立即**隐藏菜单并停止接受输入。
  void beginClose() {
    if (_phase != WheelOpenPhase.open) return;
    _surface.change(WindowsSurfaceGeometryOwner.wheelTransition, source: 'wheel.beginClose');
    _phase = WheelOpenPhase.closing;
    _journal.record('wheel.close.start');
  }

  /// 关闭：第 3~6 步：还原窗口矩形（同时桌宠局部偏移归零）并回读验证。
  Future<WheelCloseOutcome> finishClose() async {
    final Rect? restore = _originalRect;
    if (restore == null) {
      _resetToClosed();
      return const WheelCloseOutcome(restored: true);
    }
    try {
      final Rect before = await _ops.currentBounds();
      _journal.recordSizeWrite(
        source: 'wheel.close.commitBounds',
        generation: _surface.generation,
        owner: _surface.owner,
        requested: restore,
        before: before,
        after: null,
      );
      await _ops.commitBounds(restore);
      await _waitForFrame();
      await _waitForFrame();
      final Rect actual = await _ops.currentBounds();
      final bool restored = _rectDrift(actual, restore) <= boundsDriftTolerancePx;
      _journal.record(
        'wheel.close.complete',
        fields: <String, Object?>{
          'actual': WheelGeometryJournal.formatRect(actual),
          'restored': restored,
        },
      );
      _lastActualBounds = actual;
      _resetToClosed();
      return WheelCloseOutcome(restored: restored, actualBounds: actual);
    } catch (e) {
      _journal.record('wheel.close.complete', fields: <String, Object?>{'error': '$e', 'restored': false});
      _resetToClosed();
      return WheelCloseOutcome(restored: false, reason: '$e');
    }
  }

  /// 测量 / 提交阶段被打断：回滚到原始矩形并结束事务。
  Future<void> abort() async {
    if (_phase == WheelOpenPhase.closed) return;
    _journal.record('wheel.rollback', fields: <String, Object?>{'reason': 'aborted'});
    await _restoreOriginal();
    _resetToClosed();
  }

  Future<WheelOpenOutcome> _rollback(String reason) async {
    await _restoreOriginal();
    _resetToClosed();
    _lastMessage = reason;
    _journal.record('wheel.rollback', fields: <String, Object?>{'reason': reason});
    return WheelOpenOutcome.failed(reason);
  }

  Future<void> _restoreOriginal() async {
    final Rect? restore = _originalRect;
    if (restore == null) return;
    try {
      final Rect before = await _ops.currentBounds();
      await _ops.commitBounds(restore);
      await _waitForFrame();
      final Rect actual = await _ops.currentBounds();
      _journal.recordSizeWrite(
        source: 'wheel.rollback.commitBounds',
        generation: _surface.generation,
        owner: _surface.owner,
        requested: restore,
        before: before,
        after: actual,
        note: 'rollback',
      );
    } catch (_) {
      // 回滚失败已无更多手段，交由 owner 兜底。
    }
  }

  void _resetToClosed() {
    _geometry = null;
    _stableMenuSize = null;
    _originalRect = null;
    _petRect = null;
    _display = null;
    _phase = WheelOpenPhase.closed;
    _reserved = false;
    // 只有仍处于轮盘相关所有权时才切回 pet，避免覆盖面板模式。
    if (_surface.owner == WindowsSurfaceGeometryOwner.wheel ||
        _surface.owner == WindowsSurfaceGeometryOwner.wheelTransition) {
      _surface.change(WindowsSurfaceGeometryOwner.pet, source: 'wheel.resetToClosed');
    }
  }

  String? _hardValidationError(WheelGeometryResult result) {
    final Size? menuSize = _stableMenuSize;
    if (menuSize == null) return '菜单尺寸尚未测得';
    if (menuSize.width < minMenuSide || menuSize.height < minMenuSide) {
      return '菜单尺寸低于设计下限：${menuSize.width}×${menuSize.height}';
    }
    final Rect petRect = _petRect!;
    final Rect window = result.windowRect;
    if (window.width < petRect.width - 0.5 || window.height < petRect.height - 0.5) {
      return '目标窗口小于桌宠矩形';
    }
    // 桌宠必须完整落在窗口内（局部偏移不能把它挤出边界）。
    final Rect petInWindow = Rect.fromLTWH(
      result.petLocal.dx,
      result.petLocal.dy,
      petRect.width,
      petRect.height,
    );
    if (petInWindow.left < -0.5 ||
        petInWindow.top < -0.5 ||
        petInWindow.right > window.width + 0.5 ||
        petInWindow.bottom > window.height + 0.5) {
      return '桌宠未完整落在目标窗口内';
    }
    return null;
  }

  static double _rectDrift(Rect a, Rect b) =>
      (a.left - b.left).abs() +
      (a.top - b.top).abs() +
      (a.width - b.width).abs() +
      (a.height - b.height).abs();
}

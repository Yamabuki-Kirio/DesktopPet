/// 窗口 Region 的**唯一协调器**（本轮：统一所有权 + 异步事务代际）。
///
/// 铁律
/// ----
/// 1. 业务层**禁止**直接调用 `applyInteractionRegion` / `restorePetOnlyRegion` /
///    `clearInteractionRegion`；只能经本类提交（静态扫描测试会强制这一点）。
/// 2. 本类**只**管理窗口命中区域：绝不 `setBounds` / `setSize` / `setPosition`、
///    绝不改 `petAnchor`、绝不重建 `PetView`、绝不改菜单尺寸。
/// 3. 每个异步操作都捕获 `transactionId + generation + expectedOwner`，并在
///    **写入前 / await 返回后 / finally 恢复前**三处重新校验；任一不符即记
///    `region.*.dropped_stale` 并**放弃写入**。
/// 4. 收敛保证：协调器维护"期望态 / 已应用态"，任何抢占、失败、过期都会触发
///    一次有界收敛，确保最终**实际 Region 与期望态一致**（失败则回滚期望态）。
///
/// 本文件是**纯 Dart**（只依赖 `dart:ui` / `foundation` / 同层纯逻辑），
/// 可在 `flutter_tester` 直接单测（见 `test/region_coordinator_test.dart`）。
library;

import 'dart:async';
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';

import 'fixed_canvas_contract.dart';
import 'fixed_canvas_geometry.dart' show PhysicalRect;
import 'region_owner.dart';
import 'wheel_geometry_ownership.dart'
    show WheelGeometryJournal, wheelGeometryJournal;
import 'windows_surface_mode.dart' show windowsSurfaceSession;

/// 一次 Region 提交的**凭据**。
///
/// 调用方在拿到它之后用它做条件式恢复（见 [RegionCoordinator.restoreIfCurrent]）：
/// 只有 `transactionId` / `generation` / `owner` 三者**都还一致**，恢复才被允许。
@immutable
class RegionLease {
  const RegionLease({
    required this.transactionId,
    required this.generation,
    required this.owner,
  });

  /// "没有凭据"（例如探针处于回退态 / 画布尚未建立）。
  const RegionLease.none()
      : transactionId = -1,
        generation = -1,
        owner = RegionOwner.pet;

  final int transactionId;
  final int generation;
  final RegionOwner owner;

  bool get isValid => transactionId >= 0;

  String get wireName =>
      'tx=$transactionId gen=$generation owner=${owner.wireName}';

  @override
  String toString() => 'RegionLease($wireName)';
}

/// 一次 Region 提交的结局。
enum RegionCommitStatus {
  /// 已写入非空 Region。
  applied('applied'),

  /// 已清除 Region。
  cleared('cleared'),

  /// 期望态与实际一致，无需写入。
  unchanged('unchanged'),

  /// 过期：owner / generation 已被更晚的操作改变。
  droppedStale('dropped_stale'),

  /// 被更高优先级所有者占据，拒绝抢占。
  rejectedLowerPriority('rejected_lower_priority'),

  /// 面板侧独占 Region 期间，非面板 owner 的写入被拒绝。
  rejectedMode('rejected_mode'),

  /// 目标矩形为空。
  rejectedEmptyRects('rejected_empty_rects'),

  /// 协调器已销毁。
  rejectedDisposed('rejected_disposed'),

  /// 原生写入失败（已回滚期望态）。
  nativeFailure('native_failure');

  const RegionCommitStatus(this.wireName);

  final String wireName;

  bool get isSuccess =>
      this == applied || this == cleared || this == unchanged;

  /// 是否属于"写入被放弃"（对应需求里的 dropped_stale 语义）。
  bool get isDroppedStale => this == droppedStale;
}

/// 一次 Region 提交的完整结果（可断言、可复制）。
@immutable
class RegionCommitOutcome {
  const RegionCommitOutcome({
    required this.status,
    required this.lease,
    required this.owner,
    required this.generation,
    required this.rects,
    required this.cleared,
    this.error,
    this.appliedOwner,
    this.appliedRects,
    this.appliedCleared = false,
  });

  final RegionCommitStatus status;

  /// 本次请求的凭据。
  final RegionLease lease;

  /// 提交**之后**的期望态 owner。
  final RegionOwner owner;

  /// 提交**之后**的 generation。
  final int generation;

  /// 期望态矩形（已清除时为空）。
  final List<Rect> rects;

  /// 期望态是否为"无 Region"。
  final bool cleared;

  final String? error;

  /// 原生**实际**已应用的 Region（用于对账）。
  final RegionOwner? appliedOwner;
  final List<Rect>? appliedRects;
  final bool appliedCleared;

  bool get success => status.isSuccess;

  /// 是否为「过期被丢弃」（对应需求里的 dropped_stale 语义）。
  bool get isDroppedStale => status.isDroppedStale;

  String get wireName => status.wireName;

  @override
  String toString() => 'RegionCommitOutcome(${status.wireName} '
      'owner=${owner.wireName} gen=$generation rects=${rects.length}'
      '${error == null ? '' : ' error=$error'})';
}

/// 协调器内部一次写入的结局。
enum _WriteResult { written, stale, failure }

/// 窗口 Region 的**唯一写入者**（模块级唯一实例由外壳构造并向下注入）。
///
/// 为什么不是模块级单例：Region 的 owner 必须由**同一条装配链**共享
/// （外壳 → 探针 → 右键菜单），而单例会污染 `flutter_tester` 的全局状态。
class RegionCoordinator {
  RegionCoordinator({
    required RegionNativeOps ops,
    required double Function() devicePixelRatio,
    WheelGeometryJournal? journal,
    this.maxConvergeAttempts = 8,
  })  : _ops = ops,
        _devicePixelRatio = devicePixelRatio,
        _journal = journal ?? wheelGeometryJournal,
        _desiredOwner = RegionOwner.pet,
        _appliedOwner = RegionOwner.pet,
        _desiredRects = const <Rect>[],
        _appliedRects = const <Rect>[],
        _desiredCleared = false,
        _appliedCleared = false {
    _modeGenerationSeen = windowsSurfaceSession.generation;
  }

  final RegionNativeOps _ops;
  final double Function() _devicePixelRatio;
  final WheelGeometryJournal _journal;

  /// 收敛尝试上限（防止恶意/异常路径下无限重写）。
  final int maxConvergeAttempts;

  // --- 期望态 ---
  RegionOwner _desiredOwner;
  List<Rect> _desiredRects;
  bool _desiredCleared;

  // --- 已应用态（原生真实结果） ---
  RegionOwner _appliedOwner;
  List<Rect> _appliedRects;
  bool _appliedCleared;

  int _generation = 0;
  int _requestSeq = 0;
  int _writeSeq = 0;
  int _modeGenerationSeen = 0;

  RegionLease _latestLease = const RegionLease.none();
  Future<void>? _convergeFuture;
  bool _disposed = false;
  String? _lastError;

  // ---------------------------------------------------------------------------
  // 只读视图
  // ---------------------------------------------------------------------------

  /// 期望态 owner（= 当前"应该"拥有 Region 的人）。
  RegionOwner get owner => _desiredOwner;

  /// 代际：owner / 目标 Region / 模式任一变化都 +1。
  int get generation => _generation;

  int get requestSequence => _requestSeq;

  int get writeSequence => _writeSeq;

  RegionLease get latestLease => _latestLease;

  List<Rect> get desiredRects => List<Rect>.unmodifiable(_desiredRects);

  bool get isDesiredCleared => _desiredCleared;

  RegionOwner get appliedOwner => _appliedOwner;

  List<Rect> get appliedRects => List<Rect>.unmodifiable(_appliedRects);

  bool get isAppliedCleared => _appliedCleared;

  bool get isDisposed => _disposed;

  String? get lastError => _lastError;

  /// 期望态与实际是否一致（"Region 与 UI 状态一致"的判定依据）。
  bool get isSynchronized =>
      _desiredCleared == _appliedCleared &&
      (_desiredCleared ||
          (_desiredOwner == _appliedOwner &&
              _sameRects(_desiredRects, _appliedRects)));

  // ---------------------------------------------------------------------------
  // 唯一提交入口
  // ---------------------------------------------------------------------------

  /// 提交一个**非空** Region（抢占式）。返回结果里带本次凭据。
  ///
  /// [stillValid] 是调用方附加的外部守卫（`mounted` / 模式检查等），会在写入前与
  /// await 返回后各求值一次。
  Future<RegionCommitOutcome> apply({
    required RegionOwner owner,
    required List<Rect> rects,
    required String source,
    bool Function()? stillValid,
  }) =>
      _submit(
        owner: owner,
        rects: rects,
        source: source,
        stillValid: stillValid,
        cleared: false,
        enforcePriority: true,
        enforceMode: true,
      );

  /// 清除 Region（owner 一般取 [RegionOwner.panelTransition] / [RegionOwner.panel]）。
  Future<RegionCommitOutcome> clear({
    required RegionOwner owner,
    required String source,
  }) =>
      _submit(
        owner: owner,
        rects: const <Rect>[],
        source: source,
        cleared: true,
        enforcePriority: false,
        enforceMode: false,
      );

  /// **条件式恢复**：仅当 [lease] 的 `transactionId / generation / owner` 三者仍
  /// 一致时才把 Region 恢复成 [owner]（通常是 pet）。否则记 `dropped_stale` 并放弃。
  ///
  /// 这是"右键菜单 finally 不得无条件恢复 pet-only"的落点；它也是**受控降级**：
  /// 从高优先级 owner 回到 pet 不算"抢占"，因此不走优先级检查。
  Future<RegionCommitOutcome> restoreIfCurrent(
    RegionLease lease, {
    required RegionOwner owner,
    required List<Rect> rects,
    required String source,
    bool Function()? stillValid,
  }) async {
    _syncModeGeneration();
    if (_disposed) {
      return _outcome(RegionCommitStatus.rejectedDisposed, source: source);
    }
    if (!isCurrent(lease)) {
      _journal.record(
        'region.restore.dropped_stale',
        fields: <String, Object?>{
          'lease': lease.wireName,
          'current': 'tx=$_requestSeq gen=$_generation '
              'owner=${_desiredOwner.wireName}',
          'source': source,
        },
      );
      return _outcome(
        RegionCommitStatus.droppedStale,
        source: source,
        lease: lease,
      );
    }
    return _submit(
      owner: owner,
      rects: rects,
      source: source,
      stillValid: stillValid,
      cleared: false,
      enforcePriority: false,
      enforceMode: true,
    );
  }

  /// 唯一真正的提交实现。[enforcePriority] / [enforceMode] 只对"抢占式"入口为真。
  Future<RegionCommitOutcome> _submit({
    required RegionOwner owner,
    required List<Rect> rects,
    required String source,
    required bool cleared,
    required bool enforcePriority,
    required bool enforceMode,
    bool Function()? stillValid,
  }) async {
    _syncModeGeneration();
    if (_disposed) {
      return _outcome(RegionCommitStatus.rejectedDisposed, source: source);
    }
    if (!cleared && rects.isEmpty) {
      return _outcome(RegionCommitStatus.rejectedEmptyRects, source: source);
    }
    // 面板侧（panel / transitioningToPanel）**独占** Region：非面板 owner 一律拒绝。
    if (enforceMode &&
        windowsSurfaceSession.mode.isPanelLike &&
        !owner.isPanelLike) {
      _journal.record(
        'region.request.rejected',
        fields: <String, Object?>{
          'reason': 'panel_exclusive',
          'owner': owner.wireName,
          'mode': windowsSurfaceSession.mode.wireName,
          'source': source,
        },
      );
      return _outcome(RegionCommitStatus.rejectedMode, source: source);
    }
    // 优先级：低优先级不得抢占**已有 Region** 的高优先级 owner。
    if (enforcePriority &&
        !RegionOwner.canTakeOver(owner, _desiredOwner) &&
        !_desiredCleared) {
      _journal.record(
        'region.request.rejected',
        fields: <String, Object?>{
          'reason': 'lower_priority',
          'owner': owner.wireName,
          'current_owner': _desiredOwner.wireName,
          'source': source,
        },
      );
      return _outcome(RegionCommitStatus.rejectedLowerPriority, source: source);
    }

    _setDesired(owner: owner, rects: rects, cleared: cleared, source: source);
    final RegionLease lease = _mintLease(owner);
    _recordRequest(lease, source: source);
    await _converge(stillValid: stillValid);
    return _outcomeFor(
      lease,
      source: source,
      requestedOwner: owner,
      requestedRects: cleared ? const <Rect>[] : rects,
      requestedCleared: cleared,
    );
  }

  /// [lease] 是否仍然有效（`transactionId / generation / owner` 三者一致）。
  ///
  /// 这是"右键 finally 不得无条件恢复"的判定：owner 一旦被别人接管就不再匹配。
  bool isCurrent(RegionLease lease) =>
      _leaseGenerationCurrent(lease) &&
      !_disposed &&
      lease.owner == _desiredOwner;

  /// 只看 `transactionId / generation`：用于判断"这次提交是否已被更晚的操作取代"。
  bool _leaseGenerationCurrent(RegionLease lease) =>
      !_disposed &&
      lease.isValid &&
      lease.transactionId == _requestSeq &&
      lease.generation == _generation;

  /// 使 [owner] 名下**尚未完成**的事务失效（generation +1）。
  ///
  /// 左键轮盘 `beginOpen` 用它先把右键事务作废；无条件刷新一次代际，确保**任何**
  /// 旧凭据（含 contextMenu 的）都彻底失配，再也无法写 Region。
  void invalidateOwner(RegionOwner owner, {required String source}) {
    if (_disposed) return;
    _makeLeaseStale(source: source);
    _bumpGeneration(reason: 'invalidate_${owner.wireName}', source: source);
  }

  /// 使**所有**未完成事务失效（面板切换用）。
  void invalidateAll({required String source}) {
    if (_disposed) return;
    _makeLeaseStale(source: source);
    _bumpGeneration(reason: 'invalidate_all', source: source);
  }

  /// 让 [lease] 立即失效（例如退出 / dispose 前）。
  void invalidateLease(RegionLease lease, {required String source}) {
    if (_disposed || !lease.isValid) return;
    _makeLeaseStale(source: source);
    _bumpGeneration(reason: 'invalidate_lease', source: source);
  }

  // ---------------------------------------------------------------------------
  // 只读诊断（转发原生；同样是"只有协调器能碰原生"）
  // ---------------------------------------------------------------------------

  Future<int?> gdiObjectCount() => _disposed ? Future<int?>.value(null) : _ops.gdiObjectCount();

  Future<PhysicalRect?> regionBoundingBox() =>
      _disposed ? Future<PhysicalRect?>.value(null) : _ops.regionBoundingBox();

  // ---------------------------------------------------------------------------
  // 生命周期
  // ---------------------------------------------------------------------------

  /// 等待在途收敛结束（外壳在关键边界可 `await` 一次）。
  Future<void> settle() async {
    while (_convergeFuture != null) {
      await _convergeFuture;
    }
  }

  /// 销毁：清 Region、让所有晚到的 Future 失效、拒绝后续写入。
  Future<void> dispose({String source = 'coordinator.dispose'}) async {
    if (_disposed) return;
    _disposed = true;
    _convergeFuture = null;
    try {
      await _ops.clearInteractionRegion();
    } catch (_) {
      // 退出路径无更多手段，交由原生兜底。
    }
    _journal.record(
      'region.disposed',
      fields: <String, Object?>{'source': source, 'generation': _generation},
    );
  }

  // ---------------------------------------------------------------------------
  // 内部：状态机
  // ---------------------------------------------------------------------------

  void _setDesired({
    required RegionOwner owner,
    required List<Rect> rects,
    required bool cleared,
    required String source,
  }) {
    final bool changed = owner != _desiredOwner ||
        cleared != _desiredCleared ||
        !_sameRects(rects, _desiredRects);
    _desiredOwner = owner;
    _desiredRects = List<Rect>.unmodifiable(rects);
    _desiredCleared = cleared;
    if (changed) {
      _bumpGeneration(reason: 'desired_changed', source: source);
    }
  }

  void _bumpGeneration({required String reason, required String source}) {
    _generation++;
    _journal.record(
      'region.generation',
      fields: <String, Object?>{
        'generation': _generation,
        'owner': _desiredOwner.wireName,
        'reason': reason,
        'source': source,
      },
    );
  }

  /// 模式变化（含面板切换）也递增 generation —— 需求 §7。
  void _syncModeGeneration() {
    final int modeGeneration = windowsSurfaceSession.generation;
    if (modeGeneration == _modeGenerationSeen) return;
    _modeGenerationSeen = modeGeneration;
    _generation++;
    _journal.record(
      'region.generation',
      fields: <String, Object?>{
        'generation': _generation,
        'owner': _desiredOwner.wireName,
        'reason': 'surface_mode_changed',
        'mode': windowsSurfaceSession.mode.wireName,
      },
    );
  }

  void _makeLeaseStale({required String source}) {
    _requestSeq++;
    _journal.record(
      'region.transaction.invalidated',
      fields: <String, Object?>{
        'transaction_id': _requestSeq,
        'generation': _generation,
        'owner': _desiredOwner.wireName,
        'source': source,
      },
    );
  }

  RegionLease _mintLease(RegionOwner owner) {
    _requestSeq++;
    final RegionLease lease = RegionLease(
      transactionId: _requestSeq,
      generation: _generation,
      owner: owner,
    );
    _latestLease = lease;
    return lease;
  }

  void _recordRequest(RegionLease lease, {required String source}) {
    _journal.record(
      'region.transaction.start',
      fields: <String, Object?>{'source': source},
    );
    _journal.record(
      'region.transaction.id',
      fields: <String, Object?>{'transaction_id': lease.transactionId},
    );
    _journal.record(
      'region.owner',
      fields: <String, Object?>{'owner': lease.owner.wireName},
    );
    _journal.record(
      'region.generation',
      fields: <String, Object?>{
        'generation': lease.generation,
        'owner': lease.owner.wireName,
      },
    );
    _journal.record(
      'region.request.source',
      fields: <String, Object?>{'source': source},
    );
    _journal.record(
      'region.request.rects',
      fields: <String, Object?>{
        'cleared': _desiredCleared,
        'rects': _formatRects(_desiredRects),
      },
    );
  }

  /// 有界收敛：把**期望态**写到原生，直到期望态 == 已应用态。
  ///
  /// 抢占 / 过期 / 原生失败都会让 `_write` 返回非 written，循环据此重试或退出。
  Future<void> _converge({bool Function()? stillValid}) async {
    for (int round = 0; round < maxConvergeAttempts && !_disposed; round++) {
      final Future<void>? inFlight = _convergeFuture;
      if (inFlight != null) {
        await inFlight;
        if (_disposed) return;
        continue;
      }
      if (isSynchronized) return;

      final Completer<void> done = Completer<void>();
      _convergeFuture = done.future;
      try {
        int attempts = 0;
        while (!_disposed && !isSynchronized && attempts < maxConvergeAttempts) {
          attempts++;
          final _WriteResult result = await _write(stillValid: stillValid);
          if (result == _WriteResult.failure) return;
          if (result == _WriteResult.stale) {
            // 期望态已被更晚的请求改写：交给下一轮（或由对方收敛）。
            break;
          }
        }
      } finally {
        _convergeFuture = null;
        done.complete();
      }
      if (isSynchronized) return;
    }
    if (!_disposed && !isSynchronized) {
      _journal.record(
        'region.converge.giveup',
        fields: <String, Object?>{
          'desired': 'owner=${_desiredOwner.wireName} cleared=$_desiredCleared '
              'rects=${_formatRects(_desiredRects)}',
          'applied': 'owner=${_appliedOwner.wireName} cleared=$_appliedCleared '
              'rects=${_formatRects(_appliedRects)}',
        },
      );
    }
  }

  /// 单次写入：**三处校验**（写入前 / await 返回后 / 失败回滚）。
  Future<_WriteResult> _write({bool Function()? stillValid}) async {
    final RegionOwner owner = _desiredOwner;
    final List<Rect> rects = List<Rect>.of(_desiredRects);
    final bool clear = _desiredCleared;
    final int generation = _generation;
    final int transactionId = _latestLease.transactionId;

    // 校验点 1：写入前。
    if (_disposed || (_staleSince(generation, owner, transactionId)) ||
        (stillValid != null && !stillValid())) {
      _recordDroppedStale(
        stage: 'before_write',
        generation: generation,
        owner: owner,
        transactionId: transactionId,
        clear: clear,
      );
      return _WriteResult.stale;
    }

    _writeSeq++;
    final bool petOnlyRestore = !clear && owner == RegionOwner.pet && rects.length == 1;
    _journal.record(
      petOnlyRestore || clear ? 'region.restore.start' : 'region.apply.start',
      fields: <String, Object?>{
        'write_id': _writeSeq,
        'transaction_id': transactionId,
        'generation': generation,
        'owner': owner.wireName,
        'cleared': clear,
        'rects': _formatRects(rects),
        'device_pixel_ratio': _devicePixelRatio(),
      },
    );

    RegionApplyResult? result;
    bool cleared = false;
    String? error;
    try {
      if (clear) {
        cleared = await _ops.clearInteractionRegion();
      } else if (petOnlyRestore) {
        result = await _ops.restorePetOnlyRegion(
          rects.single,
          devicePixelRatio: _devicePixelRatio(),
        );
      } else {
        result = await _ops.applyInteractionRegion(
          rects,
          devicePixelRatio: _devicePixelRatio(),
        );
      }
    } catch (e) {
      error = '$e';
    }

    // 校验点 2：await 返回之后（原生可能已经写入，因此必须重新判代际）。
    if (_disposed || _staleSince(generation, owner, transactionId)) {
      _recordDroppedStale(
        stage: 'after_await',
        generation: generation,
        owner: owner,
        transactionId: transactionId,
        clear: clear,
        note: 'native_write_may_have_landed',
      );
      return _WriteResult.stale;
    }

    final bool ok = clear ? cleared : (result?.success ?? false);
    if (!ok) {
      final String reason = error ??
          result?.error ??
          (clear ? '原生 clearInteractionRegion 失败' : '原生 applyInteractionRegion 失败');
      _lastError = reason;
      // 校验点 3：失败回滚 —— 期望态退回"实际已应用态"，保证两者始终一致。
      _rollbackDesiredToApplied();
      _journal.record(
        clear ? 'region.restore.failed' : 'region.apply.failed',
        fields: <String, Object?>{
          'write_id': _writeSeq,
          'generation': generation,
          'owner': owner.wireName,
          'reason': reason,
        },
      );
      return _WriteResult.failure;
    }

    _appliedOwner = owner;
    _appliedRects = List<Rect>.unmodifiable(rects);
    _appliedCleared = clear;
    _lastError = null;
    _journal.record(
      clear || petOnlyRestore ? 'region.restore.success' : 'region.apply.success',
      fields: <String, Object?>{
        'write_id': _writeSeq,
        'transaction_id': transactionId,
        'generation': generation,
        'owner': owner.wireName,
        'cleared': clear,
        'rects': _formatRects(rects),
      },
    );
    return _WriteResult.written;
  }

  bool _staleSince(int generation, RegionOwner owner, int transactionId) =>
      generation != _generation ||
      owner != _desiredOwner ||
      transactionId != _latestLease.transactionId;

  void _recordDroppedStale({
    required String stage,
    required int generation,
    required RegionOwner owner,
    required int transactionId,
    required bool clear,
    String? note,
  }) {
    _journal.record(
      clear ? 'region.restore.dropped_stale' : 'region.apply.dropped_stale',
      fields: <String, Object?>{
        'stage': stage,
        'transaction_id': transactionId,
        'lease_generation': generation,
        'lease_owner': owner.wireName,
        'current_generation': _generation,
        'current_owner': _desiredOwner.wireName,
        if (note != null) 'note': note,
      },
    );
  }

  void _rollbackDesiredToApplied() {
    _desiredOwner = _appliedOwner;
    _desiredRects = _appliedRects;
    _desiredCleared = _appliedCleared;
  }

  RegionCommitOutcome _outcome(
    RegionCommitStatus status, {
    required String source,
    RegionLease? lease,
    String? error,
  }) =>
      RegionCommitOutcome(
        status: status,
        lease: lease ?? _latestLease,
        owner: _desiredOwner,
        generation: _generation,
        rects: _desiredRects,
        cleared: _desiredCleared,
        error: error,
        appliedOwner: _appliedOwner,
        appliedRects: _appliedRects,
        appliedCleared: _appliedCleared,
      );

  RegionCommitOutcome _outcomeFor(
    RegionLease lease, {
    required String source,
    required RegionOwner requestedOwner,
    required List<Rect> requestedRects,
    required bool requestedCleared,
  }) {
    // 1) 已被更晚的请求取代（或已销毁）：本次提交作废。
    if (!_leaseGenerationCurrent(lease)) {
      return _outcome(
        RegionCommitStatus.droppedStale,
        source: source,
        lease: lease,
      );
    }
    // 2) 期望态不是我们请求的那个 → 说明写入失败并已回滚。
    final bool desiredIsRequest = _desiredCleared == requestedCleared &&
        (requestedCleared ||
            (_desiredOwner == requestedOwner &&
                _sameRects(_desiredRects, requestedRects)));
    if (!desiredIsRequest || !isSynchronized) {
      return _outcome(
        RegionCommitStatus.nativeFailure,
        source: source,
        lease: lease,
        error: _lastError ?? '收敛未完成',
      );
    }
    return _outcome(
      _desiredCleared ? RegionCommitStatus.cleared : RegionCommitStatus.applied,
      source: source,
      lease: lease,
    );
  }

  static bool _sameRects(List<Rect> a, List<Rect> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (!_sameRect(a[i], b[i])) return false;
    }
    return true;
  }

  static bool _sameRect(Rect a, Rect b) =>
      (a.left - b.left).abs() < 0.01 &&
      (a.top - b.top).abs() < 0.01 &&
      (a.width - b.width).abs() < 0.01 &&
      (a.height - b.height).abs() < 0.01;

  static String _formatRects(List<Rect> rects) {
    if (rects.isEmpty) return 'none';
    return rects.map(_formatRect).join(' | ');
  }

  static String _formatRect(Rect rect) =>
      '${rect.left.toStringAsFixed(1)},${rect.top.toStringAsFixed(1)} '
      '${rect.width.toStringAsFixed(1)}×${rect.height.toStringAsFixed(1)}';
}

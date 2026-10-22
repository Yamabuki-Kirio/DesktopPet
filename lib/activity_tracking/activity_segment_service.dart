import 'dart:math' as math;

import '../core/constants.dart';
import '../core/ids.dart';
import '../core/logger.dart';
import '../database/dao/activity_checkpoint_dao.dart';
import '../database/dao/activity_dao.dart';
import '../database/dao/daily_usage_dao.dart';
import 'app_keys.dart';
import 'application_repository.dart';
import 'local_change_sink.dart';
import 'models/activity_enums.dart';
import 'models/activity_sample.dart';
import 'models/tracking_settings.dart';
import 'tracking_clock.dart';

/// 活动段状态机。
///
/// 职责（需求「三~五、八~十一」）：
/// - 把 2 秒一次的采样**合并**成连续使用同一应用的时间段，而不是每两秒插一条记录；
/// - 判断哪些时间**可以计入**活跃时间（未锁屏、未休眠、未空闲超阈、非排除应用、未暂停）；
/// - 用单调时钟计算持续时长，并兜住系统时间跳变、休眠、进程冻结；
/// - 每 30 秒写检查点，异常退出后按检查点补齐关闭；
/// - 抑制快速 alt-tab 造成的碎片段。
///
/// 这里**不含**任何平台调用：时钟、前台应用、空闲、锁屏全部由外部注入，
/// 因此整个状态机可以用假时钟在毫秒级完成全部用例覆盖。
class ActivitySegmentService {
  ActivitySegmentService({
    required ActivityDao activityDao,
    required ActivityCheckpointDao checkpointDao,
    required DailyUsageDao dailyUsageDao,
    required ApplicationRepository applications,
    required this.ownerId,
    required this.deviceLocalId,
    MonotonicClock? monotonicClock,
    WallClock? wallClock,
    TrackingSettings settings = const TrackingSettings(),
    LocalChangeSink changeSink = const NoopLocalChangeSink(),
  }) : _activityDao = activityDao,
       _checkpointDao = checkpointDao,
       _dailyUsageDao = dailyUsageDao,
       _applications = applications,
       _monotonic = monotonicClock ?? StopwatchMonotonicClock(),
       _wall = wallClock ?? const SystemWallClock(),
       _settings = settings,
       _changeSink = changeSink;

  final ActivityDao _activityDao;
  final ActivityCheckpointDao _checkpointDao;
  final DailyUsageDao _dailyUsageDao;
  final ApplicationRepository _applications;
  final MonotonicClock _monotonic;
  final WallClock _wall;

  /// Phase 2：本地数据变更 → 待同步队列。
  ///
  /// 采集**先写本地库**，写成功后立刻声明"这条变了"（写 outbox），
  /// 网络同步完全在后台进行。回调失败会被吞掉，绝不影响计时与渲染。
  final LocalChangeSink _changeSink;

  final String ownerId;
  final String deviceLocalId;

  TrackingSettings _settings;

  TrackingSettings get settings => _settings;

  set settings(TrackingSettings value) => _settings = value.normalized();

  /// 上一次采样（用于算增量）。
  int? _lastMonoMs;
  DateTime? _lastWallTime;

  /// 当前打开的活动段。
  _OpenSegment? _open;

  /// 待确认的应用切换候选。
  _Candidate? _candidate;

  /// 上一次检查点写入的单调时刻。
  int _lastCheckpointMonoMs = 0;

  /// 当日设备级累计。
  DailyUsage? _today;

  /// 设备级用量的毫秒余数（**当前日**）。
  ///
  /// 采样间隔是 2 秒但可能带任意毫秒（1999ms / 2001ms），如果每个 tick 都
  /// 各自向下取整，长期会持续少算。这里先累计毫秒，只把完整的 1000ms 转成秒，
  /// 余数留给下一次采样。
  ///
  /// 每一天各自保存自己的余数：跨日时清零，旧日余数绝不带入新日；
  /// 午夜边界通过 [_splitAtBoundary] 做确定性的整数秒分配。
  int _sessionRemainderMs = 0;
  int _activeRemainderMs = 0;
  int _idleRemainderMs = 0;

  /// 午夜边界把 1 秒判给新日后，新日后续毫秒要先偿还的欠账。
  ///
  /// 只用非负余数会丢失“这 1 秒已经提前计入”的信息；用负数又会和 Dart 的
  /// `%` 语义打架。因此把欠账单独存放，偿还完才重新进入余数。
  int _activeDebtMs = 0;
  int _idleDebtMs = 0;

  /// 连续活跃毫秒数（空闲超阈 / 锁屏 / 休眠 / 暂停 / 退出后归零）。
  int _continuousActiveMs = 0;

  /// 当前前台应用（按采样即时更新，不受切换确认影响）。
  String? _currentAppKey;
  String? _currentAppName;

  /// 最近一次采样的空闲/锁屏/暂停状态，供 UI 与状态映射使用。
  Duration _lastIdle = Duration.zero;
  bool _lastLocked = false;
  bool _lastPaused = false;

  bool _initialized = false;
  bool _disposed = false;

  /// 连续落盘失败次数。
  ///
  /// 供状态映射判定 `error` 状态使用：偶发一次写失败不影响桌宠，
  /// 但持续失败说明数据库已经不可用，应当显式暴露而不是静默丢数据。
  int _consecutiveFailures = 0;

  int get consecutiveFailures => _consecutiveFailures;

  // ---------------------------------------------------------------------------
  // 只读状态（UI / 状态映射 / 诊断）
  // ---------------------------------------------------------------------------

  /// 当前前台应用键（按采样即时更新）。
  String? get currentAppKey => _currentAppKey;

  /// 当前前台应用显示名。
  String? get currentAppDisplayName => _currentAppName;

  /// 当前是否有一段正在进行中的活动段。
  bool get hasOpenSegment => _open != null;

  /// 当前活动段已累计秒数。
  int get currentSegmentSeconds => _open == null ? 0 : _open!.activeMs ~/ 1000;

  /// 连续活跃秒数。
  int get continuousActiveSeconds => _continuousActiveMs ~/ 1000;

  /// 今日设备级活跃秒数。
  int get todayActiveSeconds => _today?.activeSeconds ?? 0;

  /// 今日屏幕会话秒数。
  int get todaySessionSeconds => _today?.sessionSeconds ?? 0;

  /// 今日空闲秒数。
  int get todayIdleSeconds => _today?.idleSeconds ?? 0;

  /// 今日首次活跃时刻。
  DateTime? get todayFirstActiveAt => _today?.firstActiveAt;

  /// 今日最后活跃时刻。
  DateTime? get todayLastActiveAt => _today?.lastActiveAt;

  Duration get lastIdle => _lastIdle;

  /// 当前采集状态（诊断 / 统计页展示）。
  TrackingStatus get status {
    if (_disposed) return TrackingStatus.unavailable;
    if (_lastPaused) return TrackingStatus.paused;
    if (_lastLocked) return TrackingStatus.locked;
    if (_lastIdle.inMilliseconds >= _settings.idleThresholdMs) {
      return TrackingStatus.idle;
    }
    return TrackingStatus.running;
  }

  /// 当前时间（供外部构造采样），以便与状态机共用同一个时钟。
  DateTime now() => _wall.now();

  /// 单调时钟当前值。
  int nowMono() => _monotonic.nowMs();

  // ---------------------------------------------------------------------------
  // 生命周期
  // ---------------------------------------------------------------------------

  /// 初始化：先做崩溃恢复，再载入今日用量。
  ///
  /// 必须在开始采样前调用，否则上次异常退出遗留的未关闭段会一直挂着。
  Future<void> initialize() async {
    if (_initialized) return;
    await recoverInterruptedSegments();
    await _loadToday();
    _initialized = true;
  }

  /// 启动时用检查点关闭上次未正常结束的活动段（需求「五、时间准确性」）。
  ///
  /// 这条路径同时保证：**异常退出绝不会留下持续数小时的错误记录**——
  /// 没有检查点时按「起点即终点、活跃 0 秒」关闭，宁可为空也不虚报。
  Future<void> recoverInterruptedSegments() async {
    try {
      final List<ActivitySegment> open = await _activityDao.listOpen(ownerId);
      if (open.isEmpty) {
        await _checkpointDao.deleteOrphans();
        return;
      }
      for (final ActivitySegment seg in open) {
        final ActivityCheckpoint? cp = await _checkpointDao.find(seg.id);
        DateTime endedAt = cp?.wallAt ?? seg.startedAt;
        if (endedAt.isBefore(seg.startedAt)) endedAt = seg.startedAt;
        final int activeSeconds = cp?.activeSeconds ?? 0;
        await _activityDao.closeSegment(
          seg.id,
          endedAt,
          activeSeconds,
          SegmentEndReason.crashRecovery.wireName,
        );
        await _checkpointDao.delete(seg.id);
        Loggers.activity.warning(
          '检测到上次异常退出遗留的活动段 ${seg.appKey}，'
          '已按${cp == null ? '起点' : '最后检查点'}关闭：'
          '活跃 ${activeSeconds}s，原因 ${SegmentEndReason.crashRecovery.wireName}',
        );
      }
      await _checkpointDao.deleteOrphans();
    } catch (e, st) {
      // 恢复失败不能阻止采集启动。
      Loggers.activity.warning('活动段崩溃恢复失败', e, st);
    }
  }

  /// 正常退出：关闭当前段并落盘。
  Future<void> shutdown() async {
    if (_disposed) return;
    await _closeOpen(
      reason: SegmentEndReason.clientShutdown,
      endWall: _wall.now(),
      creditUpToMono: _monotonic.nowMs(),
    );
    _candidate = null;
    await _flush(force: true);
    _disposed = true;
    Loggers.activity.info('活动采集已停止（正常退出）');
  }

  /// 立即结束当前活动段（用户暂停 / 恢复记录时调用，不等下一个采样周期）。
  Future<void> endCurrentSegment(SegmentEndReason reason) async {
    await _closeOpen(
      reason: reason,
      endWall: _wall.now(),
      creditUpToMono: _monotonic.nowMs(),
    );
    _candidate = null;
    if (reason == SegmentEndReason.trackingPaused ||
        reason == SegmentEndReason.sessionLocked ||
        reason == SegmentEndReason.systemSuspend) {
      _continuousActiveMs = 0;
    }
    await _flush(force: true);
  }

  /// 更新采集设置（暂停开关、空闲阈值）。
  Future<void> updateSettings(TrackingSettings next) async {
    final TrackingSettings normalized = next.normalized();
    final bool wasPaused = _settings.paused;
    _settings = normalized;
    if (!wasPaused && normalized.paused) {
      // 暂停必须立即结束当前段，而不是等下一次采样。
      await endCurrentSegment(SegmentEndReason.trackingPaused);
      _lastPaused = true;
    }
  }

  // ---------------------------------------------------------------------------
  // 采样
  // ---------------------------------------------------------------------------

  /// 处理一次采样。绝不抛出——采集失败不能影响桌宠运行。
  Future<void> tick(ActivitySample sample) async {
    if (_disposed) return;
    try {
      await _tick(sample);
    } catch (e, st) {
      Loggers.activity.warning('活动段状态机处理采样失败', e, st);
    }
  }

  Future<void> _tick(ActivitySample sample) async {
    _lastIdle = sample.idle;
    _lastLocked = sample.sessionLocked;
    _lastPaused = sample.paused;

    final int? prevMono = _lastMonoMs;
    final DateTime? prevWall = _lastWallTime;
    _lastMonoMs = sample.monotonicMs;
    _lastWallTime = sample.wallNow;

    // --- 首次采样：只建立基线，不追溯计时 ---
    if (prevMono == null || prevWall == null) {
      await _ensureDay(sample.wallNow);
      await _considerForeground(sample, creditMs: 0, idleOverMs: 0);
      return;
    }

    final int monoDelta = sample.monotonicMs - prevMono;
    final int wallDelta = sample.wallNow.difference(prevWall).inMilliseconds;
    final int skew = wallDelta - monoDelta;

    // 上一段关闭失败时，先尝试补写关闭，避免旧段一直占着内存状态。
    // 这不是定时重试：只在有采样时顺带触发，真正的重试仍然由检查点驱动。
    if (_open?.isClosing == true) {
      await _flush(force: true);
    }

    // --- A. 中断：休眠 / 进程被冻结 / 采样长时间停摆 ---
    // 这段时间一分一秒都不计入，并按原因结束当前段。
    if (monoDelta > ActivityTracking.maxSampleGapMs ||
        wallDelta > ActivityTracking.maxSampleGapMs) {
      await _ensureDay(sample.wallNow);
      final SegmentEndReason reason = skew > ActivityTracking.suspendDetectMs
          ? SegmentEndReason.systemSuspend
          : (sample.sessionLocked
                ? SegmentEndReason.sessionLocked
                : SegmentEndReason.processUnavailable);
      await _closeOpen(
        reason: reason,
        endWall: sample.wallNow,
        creditUpToMono: _open?.lastCreditMonoMs ?? sample.monotonicMs,
      );
      _candidate = null;
      _continuousActiveMs = 0;
      await _flush(force: true);
      Loggers.activity.info(
        '采样中断（mono=${monoDelta}ms wall=${wallDelta}ms），已结束活动段：${reason.wireName}',
      );
      return;
    }

    // 单调时钟异常（倒退）时不给任何计入，避免负数记录。
    final int rawCredit = monoDelta < 0 ? 0 : monoDelta;
    final int creditMs = math.min(
      rawCredit,
      ActivityTracking.maxCreditPerTickMs,
    );

    // --- B. 系统时间大幅变化：结算后重开一段 ---
    if (skew.abs() > ActivityTracking.clockJumpThresholdMs) {
      await _ensureDay(sample.wallNow);
      final int idleOver = _idleOverMs(sample);
      // 先把设备计数按正常口径结算，避免这段时间凭空消失。
      await _addDeviceUsage(sample, creditMs: creditMs, idleOverMs: idleOver);
      await _closeOpen(
        reason: SegmentEndReason.clockChanged,
        endWall: sample.wallNow,
        creditUpToMono: sample.monotonicMs,
      );
      _candidate = null;
      Loggers.activity.warning(
        '检测到系统时间变化（wall=${wallDelta}ms，mono=${monoDelta}ms），已结束当前活动段',
      );
      // 按当前状态重新开始记录。
      await _considerForeground(sample, creditMs: 0, idleOverMs: idleOver);
      await _flush(force: true);
      return;
    }

    // --- C. 设备级计数（暂停时完全不计）---
    final int idleOverMs = _idleOverMs(sample);
    await _addDeviceUsage(sample, creditMs: creditMs, idleOverMs: idleOverMs);

    // --- D. 判断应用归属 ---
    await _considerForeground(
      sample,
      creditMs: creditMs,
      idleOverMs: idleOverMs,
    );

    // --- E. 周期落盘 ---
    await _maybeCheckpoint(sample.monotonicMs);
  }

  /// 空闲超过阈值的毫秒数（0 表示未超阈）。
  int _idleOverMs(ActivitySample sample) {
    final int idleMs = sample.idle.inMilliseconds;
    final int threshold = _settings.idleThresholdMs;
    return idleMs > threshold ? idleMs - threshold : 0;
  }

  /// 设备级（屏幕会话 / 活跃 / 空闲）计数。
  ///
  /// 只统计「未锁屏」的时间；休眠与长间隔已在 A 分支里被排除在外，
  /// 因此不会出现「锁屏一夜，早上起来多了 8 小时」的错误数据。
  ///
  /// 相邻采样跨越本地午夜时，会把这一 tick 的 credit 按**毫秒**拆到前后两天：
  /// 先累计并落盘旧日，再加载新日累计剩余部分。活动段本身不拆，查询层继续按
  /// 窗口比例裁剪。
  Future<void> _addDeviceUsage(
    ActivitySample sample, {
    required int creditMs,
    required int idleOverMs,
  }) async {
    if (sample.paused || sample.sessionLocked || creditMs <= 0) return;

    final DateTime end = sample.wallNow;
    final DateTime start = end.subtract(Duration(milliseconds: creditMs));
    // 活跃区间在 [start, activeEnd)，空闲区间在 [activeEnd, end)。
    // idleOverMs 可能大于本 tick 的 credit，此时整段都算空闲。
    final int activeMs = math.max(0, creditMs - idleOverMs);
    final int idleMs = creditMs - activeMs;
    final DateTime activeEnd = end.subtract(
      Duration(milliseconds: math.min(idleOverMs, creditMs)),
    );

    final DateTime? midnight = _midnightInWindow(start, end);
    if (midnight == null) {
      await _ensureDay(end);
      _accumulateUsage(
        at: end,
        sessionMs: creditMs,
        activeMs: activeMs,
        idleMs: idleMs,
        activeStart: activeMs > 0 ? start : null,
        activeEnd: activeMs > 0 ? activeEnd : null,
      );
      return;
    }

    // 旧日部分：区间是 [start, midnight)。
    await _ensureDay(start);
    final int oldSessionMs = midnight.difference(start).inMilliseconds;
    final int newSessionMs = end.difference(midnight).inMilliseconds;
    final int oldActiveMs = _overlapMs(start, activeEnd, start, midnight);
    final int newActiveMs = activeMs - oldActiveMs;
    final int oldIdleMs = oldSessionMs - oldActiveMs;
    final int newIdleMs = newSessionMs - newActiveMs;
    final DateTime oldActiveEnd = activeEnd.isBefore(midnight)
        ? activeEnd
        : midnight;

    // 午夜边界：每一天各自保留自己的毫秒余数，旧日余数不带入新日。
    // 整数秒按“最大余数”确定性分配：800ms + 1200ms → 旧日 1 秒、新日 1 秒，
    // 而不是把旧日的 800ms 整体转到新日变成 2 秒。
    assert(
      _sessionRemainderMs == _activeRemainderMs + _idleRemainderMs,
      '跨午夜前会话余数必须等于活跃与空闲余数之和',
    );
    final _BoundarySplit activeSplit = _splitAtBoundary(
      oldRemainderMs: _activeRemainderMs,
      oldPartMs: oldActiveMs,
      newPartMs: newActiveMs,
    );
    final _BoundarySplit idleSplit = _splitAtBoundary(
      oldRemainderMs: _idleRemainderMs,
      oldPartMs: oldIdleMs,
      newPartMs: newIdleMs,
    );

    _applyUsageSeconds(
      at: midnight,
      activeSeconds: activeSplit.oldSeconds,
      idleSeconds: idleSplit.oldSeconds,
      activeStart: oldActiveMs > 0 ? start : null,
      activeEnd: oldActiveMs > 0 ? oldActiveEnd : null,
    );

    // _ensureDay(end) 会先把旧日（含刚累计的部分）落盘，再加载新日并清零余数。
    await _ensureDay(end);
    _activeRemainderMs = activeSplit.newRemainderMs;
    _activeDebtMs = activeSplit.newDebtMs;
    _idleRemainderMs = idleSplit.newRemainderMs;
    _idleDebtMs = idleSplit.newDebtMs;
    _sessionRemainderMs = _activeRemainderMs + _idleRemainderMs;

    _applyUsageSeconds(
      at: end,
      activeSeconds: activeSplit.newSeconds,
      idleSeconds: idleSplit.newSeconds,
      activeStart: newActiveMs > 0 ? midnight : null,
      activeEnd: newActiveMs > 0 ? activeEnd : null,
    );
    _continuousActiveMs += activeMs;
  }

  /// 把一段毫秒用量并入当前日，只把完整的 1000ms 转成秒。
  ///
  /// 会话秒数恒等于活跃秒数 + 空闲秒数。三个桶的毫秒余数各自保留在**当前日**；
  /// 跨日清零，绝不把旧日余数带到新日。
  void _accumulateUsage({
    required DateTime at,
    required int sessionMs,
    required int activeMs,
    required int idleMs,
    required DateTime? activeStart,
    required DateTime? activeEnd,
  }) {
    if (sessionMs <= 0) return;
    assert(sessionMs == activeMs + idleMs, '会话毫秒必须等于活跃 + 空闲');
    final DailyUsage? today = _today;
    if (today == null) return;

    // 先偿还午夜边界提前计入的 1 秒，再进入当前日的毫秒余数。
    _activeRemainderMs += _repayDebt(activeMs, active: true);
    _idleRemainderMs += _repayDebt(idleMs, active: false);

    final int activeAdd = _activeRemainderMs ~/ 1000;
    _activeRemainderMs %= 1000;
    final int idleAdd = _idleRemainderMs ~/ 1000;
    _idleRemainderMs %= 1000;
    _sessionRemainderMs = _activeRemainderMs + _idleRemainderMs;

    _applyUsageSeconds(
      at: at,
      activeSeconds: activeAdd,
      idleSeconds: idleAdd,
      activeStart: activeMs > 0 ? activeStart : null,
      activeEnd: activeMs > 0 ? activeEnd : null,
    );
    if (activeMs > 0) _continuousActiveMs += activeMs;
  }

  /// 用本次毫秒偿还边界欠账，返回剩余可计入余数的毫秒。
  int _repayDebt(int ms, {required bool active}) {
    final int debt = active ? _activeDebtMs : _idleDebtMs;
    final int paid = math.min(ms, debt);
    final int left = debt - paid;
    if (active) {
      _activeDebtMs = left;
    } else {
      _idleDebtMs = left;
    }
    return ms - paid;
  }

  /// 把整数秒并入当日行，并按实际活跃区间更新首次 / 最后活跃时刻。
  void _applyUsageSeconds({
    required DateTime at,
    required int activeSeconds,
    required int idleSeconds,
    required DateTime? activeStart,
    required DateTime? activeEnd,
  }) {
    final DailyUsage? today = _today;
    if (today == null) return;

    DateTime? first = today.firstActiveAt;
    DateTime? last = today.lastActiveAt;
    if (activeStart != null && activeEnd != null) {
      // 首次活跃取实际活跃区间起点；最后活跃取活跃区间终点，
      // 不能写成采样结束时刻（后半段可能已经进入空闲）。
      first = (first == null || activeStart.isBefore(first))
          ? activeStart
          : first;
      last = (last == null || activeEnd.isAfter(last)) ? activeEnd : last;
    }

    _today = today.copyWith(
      sessionSeconds: today.sessionSeconds + activeSeconds + idleSeconds,
      activeSeconds: today.activeSeconds + activeSeconds,
      idleSeconds: today.idleSeconds + idleSeconds,
      firstActiveAt: first,
      lastActiveAt: last,
      updatedAt: at,
    );
  }

  /// 午夜边界上的整数秒分配结果（每一天各自独立，余数不跨日）。
  static _BoundarySplit _splitAtBoundary({
    required int oldRemainderMs,
    required int oldPartMs,
    required int newPartMs,
  }) {
    final int oldRawMs = oldRemainderMs + oldPartMs;
    final int oldBase = oldRawMs ~/ 1000;
    final int oldRemainder = oldRawMs % 1000;
    final int newBase = newPartMs ~/ 1000;
    final int newRemainder = newPartMs % 1000;

    if (oldRemainder + newRemainder >= 1000) {
      // 最大余数先拿这 1 秒；平局归旧日，保证结果确定。
      if (oldRemainder >= newRemainder) {
        return _BoundarySplit(
          oldSeconds: oldBase + 1,
          newSeconds: newBase,
          newRemainderMs: newRemainder,
          newDebtMs: 0,
        );
      }
      return _BoundarySplit(
        oldSeconds: oldBase,
        newSeconds: newBase + 1,
        // 新日先拿 1 秒，但它的 900ms 余数不能再用一次；余数从 0 起算，
        // 后续 1000-900ms 先偿还这 1 秒。
        newRemainderMs: 0,
        newDebtMs: 1000 - newRemainder,
      );
    }
    return _BoundarySplit(
      oldSeconds: oldBase,
      newSeconds: newBase,
      newRemainderMs: newRemainder,
      newDebtMs: 0,
    );
  }

  /// `[activeStart, activeEnd)` 与 `[windowStart, windowEnd)` 的重叠毫秒数。
  static int _overlapMs(
    DateTime activeStart,
    DateTime activeEnd,
    DateTime windowStart,
    DateTime windowEnd,
  ) {
    final DateTime start = activeStart.isAfter(windowStart)
        ? activeStart
        : windowStart;
    final DateTime end = activeEnd.isBefore(windowEnd) ? activeEnd : windowEnd;
    final int ms = end.difference(start).inMilliseconds;
    return ms > 0 ? ms : 0;
  }

  /// 区间 `(start, end]` 内的第一个本地午夜；没有则返回 null。
  ///
  /// 用日期分量构造而不是 `add(Duration(days: 1))`，以适配本地时区的夏令时。
  static DateTime? _midnightInWindow(DateTime start, DateTime end) {
    final DateTime next = start.isUtc
        ? DateTime.utc(start.year, start.month, start.day + 1)
        : DateTime(start.year, start.month, start.day + 1);
    if (next.isBefore(start) || next.isAfter(end)) return null;
    return next;
  }

  /// 依据当前采样决定「继续计时 / 结束 / 开新段」。
  Future<void> _considerForeground(
    ActivitySample sample, {
    required int creditMs,
    required int idleOverMs,
  }) async {
    // 上一段还在等待补写关闭：旧段状态不能被覆盖，也不能在它之前开新段。
    // 关闭成功（通常发生在下一次 flush）后，下一轮采样会自然恢复。
    if (_open?.isClosing == true) return;

    // 1. 暂停 → 结束当前段。
    if (sample.paused) {
      await _closeOpen(
        reason: SegmentEndReason.trackingPaused,
        endWall: sample.wallNow,
        creditUpToMono: _open?.lastCreditMonoMs ?? sample.monotonicMs,
      );
      _candidate = null;
      _continuousActiveMs = 0;
      return;
    }

    // 2. 锁屏 → 结束当前段。
    if (sample.sessionLocked) {
      await _closeOpen(
        reason: SegmentEndReason.sessionLocked,
        endWall: sample.wallNow,
        creditUpToMono: sample.monotonicMs,
      );
      _candidate = null;
      _continuousActiveMs = 0;
      return;
    }

    // 3. 空闲超过阈值 → 在「越过阈值的那一刻」结束当前段。
    if (idleOverMs > 0) {
      final int endMono = sample.monotonicMs - idleOverMs;
      await _closeOpen(
        reason: SegmentEndReason.userIdle,
        endWall: sample.wallNow.subtract(Duration(milliseconds: idleOverMs)),
        creditUpToMono: endMono,
      );
      _candidate = null;
      _continuousActiveMs = 0;
      return;
    }

    // 4. 前台应用不可用 → 结束当前段。
    final ForegroundAppInfo? fg = sample.foreground;
    if (fg == null) {
      await _closeOpen(
        reason: SegmentEndReason.processUnavailable,
        endWall: sample.wallNow,
        creditUpToMono: sample.monotonicMs,
      );
      _candidate = null;
      return;
    }
    final String? appKey = normalizeAppKey(fg.keySource);
    if (appKey == null) {
      await _closeOpen(
        reason: SegmentEndReason.processUnavailable,
        endWall: sample.wallNow,
        creditUpToMono: sample.monotonicMs,
      );
      _candidate = null;
      return;
    }

    // 5. 登记到应用库（排除应用也要登记，否则用户无法在列表里恢复它）。
    final TrackedApplication app = await _applications.ensureSeen(
      appKey: appKey,
      processName: fg.processName,
      executablePath: fg.executablePath,
      at: sample.wallNow,
    );
    _currentAppKey = appKey;
    _currentAppName = app.displayName;

    // 6. 排除名单（含 PetLife 自身）→ 结束当前段且不计时。
    if (_applications.isExcluded(appKey)) {
      await _closeOpen(
        reason: SegmentEndReason.appExcluded,
        endWall: sample.wallNow,
        creditUpToMono: _open?.lastCreditMonoMs ?? sample.monotonicMs,
      );
      _candidate = null;
      return;
    }

    // 7. 目前没有进行中的段：直接开段。
    //
    //    切换确认只用于「抑制已有段的碎片」；没有任何段在计时时没有碎片可抑制，
    //    反而延迟开段会白丢这段时间。
    final _OpenSegment? open = _open;
    if (open != null && open.appKey == appKey) {
      _candidate = null;
      _creditOpen(sample.monotonicMs, creditMs);
      return;
    }
    if (open == null) {
      await _openSegment(
        appKey: appKey,
        displayName: app.displayName,
        processName: fg.processName,
        atWall: sample.wallNow,
        atMono: sample.monotonicMs,
      );
      _candidate = null;
      return;
    }

    // 8. 应用切换确认：候选需持续存在 switchConfirmMs 才真正开新段。
    final _Candidate? candidate = _candidate;
    if (candidate == null || candidate.appKey != appKey) {
      // 记录候选首次出现的时刻；这段时间仍归属旧应用（抑制碎片）。
      _candidate = _Candidate(
        appKey: appKey,
        sinceMonoMs: sample.monotonicMs,
        sinceWall: sample.wallNow,
        displayName: app.displayName,
        processName: fg.processName,
      );
      _creditOpen(sample.monotonicMs, creditMs);
      return;
    }

    if (sample.monotonicMs - candidate.sinceMonoMs <
        ActivityTracking.switchConfirmMs) {
      _creditOpen(sample.monotonicMs, creditMs);
      return;
    }

    // 确认切换：旧段结束于候选首次出现的时刻，新段从该时刻起算。
    await _closeOpen(
      reason: SegmentEndReason.foregroundChanged,
      endWall: candidate.sinceWall,
      creditUpToMono: candidate.sinceMonoMs,
    );
    await _openSegment(
      appKey: candidate.appKey,
      displayName: candidate.displayName,
      processName: candidate.processName,
      atWall: candidate.sinceWall,
      atMono: candidate.sinceMonoMs,
    );
    _candidate = null;
    Loggers.activity.fine('前台应用切换为 ${candidate.displayName}（$appKey）');
  }

  /// 给当前打开的段计入时间。
  void _creditOpen(int monoNow, int creditMs) {
    final _OpenSegment? open = _open;
    if (open == null) return;
    final int delta = math.max(0, monoNow - open.lastCreditMonoMs);
    final int credited = math.min(delta, creditMs <= 0 ? delta : creditMs);
    open.activeMs += credited;
    open.lastCreditMonoMs = monoNow;
  }

  Future<void> _openSegment({
    required String appKey,
    required String displayName,
    String? processName,
    required DateTime atWall,
    required int atMono,
  }) async {
    // 等待关闭的旧段仍占着内存状态；先不覆盖它，避免待关闭信息丢失。
    if (_open?.isClosing == true) {
      Loggers.activity.warning('上一活动段仍在等待关闭，暂缓开启新段（$appKey）');
      return;
    }
    final String id = Ids.segment(ownerId, deviceLocalId, appKey, atWall);
    final _OpenSegment segment = _OpenSegment(
      id: id,
      appKey: appKey,
      appName: displayName,
      processName: processName,
      startedAt: atWall,
      lastCreditMonoMs: atMono,
      createdAt: _wall.now(),
    );
    _open = segment;
    try {
      await _persistOpen(segment);
    } catch (e, st) {
      // 数据库暂时失败不能中断采集：内存里继续计时，检查点时会再尝试。
      // 插入成功之前绝不写 outbox，避免队列里出现本地不存在的记录。
      Loggers.activity.warning('写入活动段失败（将继续在内存计时）: $id', e, st);
    }
  }

  /// 幂等写入尚未落盘的活动段（首次插入与后续重试共用）。
  Future<void> _persistOpen(_OpenSegment open, {bool notify = true}) async {
    await _activityDao.insertIfAbsent(
      ActivitySegment(
        id: open.id,
        ownerId: ownerId,
        deviceLocalId: deviceLocalId,
        appKey: open.appKey,
        appName: open.appName,
        processName: open.processName,
        startedAt: open.startedAt,
        activeSeconds: 0,
        createdAt: open.createdAt,
      ),
    );
    open.persisted = true;
    if (notify) {
      // 本地写入成功后才声明"这条变了"：保证 outbox 里不会有本地不存在的记录。
      await _notifySegment(open.id);
    }
  }

  Future<void> _closeOpen({
    required SegmentEndReason reason,
    required DateTime endWall,
    required int creditUpToMono,
  }) async {
    final _OpenSegment? open = _open;
    if (open == null || open.pendingClose != null) return;

    final int delta = math.max(0, creditUpToMono - open.lastCreditMonoMs);
    open.activeMs += math.min(delta, ActivityTracking.maxCreditPerTickMs);
    open.lastCreditMonoMs = creditUpToMono;

    final int activeSeconds = open.activeMs ~/ 1000;
    // 结束时间不得早于开始时间（时钟回拨 / 边界情况兜底）。
    final DateTime safeEnd = endWall.isBefore(open.startedAt)
        ? open.startedAt
        : endWall;

    // 关闭成功前**不清空** _open：把结束时间 / 原因 / 最终秒数挂在这段上，
    // 后续 flush 会优先补写并关闭它。
    open.pendingClose = _PendingClose(
      endedAt: safeEnd,
      activeSeconds: activeSeconds,
      reason: reason,
    );

    try {
      await _finishClose(open);
    } catch (e, st) {
      Loggers.activity.warning('关闭活动段失败，已保留待关闭状态（下次检查点重试）: ${open.id}', e, st);
    }
  }

  /// 补写并关闭一段（可重复调用：插入幂等、关闭写同一条记录）。
  ///
  /// 成功后才删除检查点、通知同步并清空内存状态；任何一步失败都把状态留在
  /// 内存里，下一次 flush 继续重试。
  Future<void> _finishClose(_OpenSegment open) async {
    final _PendingClose? pending = open.pendingClose;
    if (pending == null) return;
    if (!open.persisted) {
      // 结束时间只在关闭成功后才有，因此补写时先用未关闭行占位。
      await _persistOpen(open, notify: false);
    }
    await _activityDao.closeSegment(
      open.id,
      pending.endedAt,
      pending.activeSeconds,
      pending.reason.wireName,
    );
    await _checkpointDao.delete(open.id);
    await _notifySegment(open.id);
    open.pendingClose = null;
    if (identical(_open, open)) _open = null;
  }

  // ---------------------------------------------------------------------------
  // 检查点与每日用量
  // ---------------------------------------------------------------------------

  Future<void> _maybeCheckpoint(int monoNow) async {
    if (monoNow - _lastCheckpointMonoMs <
        ActivityTracking.checkpointIntervalMs) {
      return;
    }
    _lastCheckpointMonoMs = monoNow;
    await _flush(force: false);
  }

  /// 落盘：活动段检查点 + 当日用量 + 应用库 last_seen。
  Future<void> _flush({required bool force}) async {
    final DateTime now = _wall.now();
    try {
      final _OpenSegment? open = _open;
      if (open != null) {
        if (open.pendingClose != null) {
          // 待关闭状态优先：补写插入 + 关闭 + 清检查点 + 通知同步。
          await _finishClose(open);
        } else {
          // 开段插入失败过的段先做幂等补写，成功后才允许写检查点 / 通知同步。
          if (!open.persisted) {
            await _persistOpen(open);
          }
          final int activeSeconds = open.activeMs ~/ 1000;
          await _checkpointDao.upsert(
            ActivityCheckpoint(
              segmentId: open.id,
              appKey: open.appKey,
              wallAt: now,
              activeSeconds: activeSeconds,
              updatedAt: now,
            ),
          );
          await _activityDao.updateActiveSeconds(open.id, activeSeconds);
        }
      }
      final DailyUsage? today = _today;
      if (today != null) {
        await _dailyUsageDao.upsert(today.copyWith(updatedAt: now));
      }
      await _applications.flush();
      _consecutiveFailures = 0;

      // Phase 2：本地落盘成功后再声明变更（写 outbox）。
      // 顺序很重要——先本地后 outbox，保证队列里不会有本地不存在的记录。
      final _OpenSegment? current = _open;
      if (current != null && current.pendingClose == null) {
        await _notifySegment(current.id);
      }
      if (today != null) {
        await _notifyDaily(today.dayKey);
      }
    } catch (e, st) {
      _consecutiveFailures++;
      Loggers.activity.warning(
        '活动数据落盘失败（第 $_consecutiveFailures 次，下次检查点会重试）',
        e,
        st,
      );
    }
  }

  /// 声明活动段变更（写 outbox）。
  ///
  /// 失败只记日志：outbox 写不进去也绝不能影响本地计时与桌宠渲染。
  Future<void> _notifySegment(String segmentId) async {
    try {
      await _changeSink.onSegmentChanged(segmentId);
    } catch (e, st) {
      Loggers.sync.fine('活动段入队失败（不影响本地采集）: $segmentId', e, st);
    }
  }

  /// 声明每日用量变更（写 outbox）。
  Future<void> _notifyDaily(String dayKey) async {
    try {
      await _changeSink.onDailyUsageChanged(
        deviceLocalId: deviceLocalId,
        dayKey: dayKey,
      );
    } catch (e, st) {
      Loggers.sync.fine('每日用量入队失败（不影响本地采集）: $dayKey', e, st);
    }
  }

  /// 立即落盘。
  ///
  /// 统计页打开前调用一次，保证查询到的是最新数据（否则最多可能落后一个检查点周期）。
  Future<void> flushNow() => _flush(force: true);

  /// 保证 `_today` 指向「当前本地日期」的累计行。
  ///
  /// 跨日时会先把旧的一行落盘，再切换到新的一天，因此
  /// 「今日和跨日统计边界正确」（验收第 23 项）。
  Future<void> _ensureDay(DateTime wallNow) async {
    final String key = _dayKey(wallNow);
    if (_today != null && _today!.dayKey == key) return;

    if (_today != null) {
      try {
        await _dailyUsageDao.upsert(_today!.copyWith(updatedAt: wallNow));
      } catch (e, st) {
        Loggers.activity.warning('跨日写入上一日用量失败', e, st);
      }
    }
    // 每日累计各自保存毫秒余数：普通跨日直接清零，绝不让旧日余数进入新日。
    _resetUsageRemainders();
    await _loadToday(referenceWall: wallNow);
  }

  void _resetUsageRemainders() {
    _sessionRemainderMs = 0;
    _activeRemainderMs = 0;
    _idleRemainderMs = 0;
    _activeDebtMs = 0;
    _idleDebtMs = 0;
  }

  Future<void> _loadToday({DateTime? referenceWall}) async {
    final DateTime wallNow = referenceWall ?? _wall.now();
    final String key = _dayKey(wallNow);
    try {
      final DailyUsage? existing = await _dailyUsageDao.find(
        ownerId,
        deviceLocalId,
        key,
      );
      _today =
          existing ??
          DailyUsage(
            ownerId: ownerId,
            deviceLocalId: deviceLocalId,
            dayKey: key,
            updatedAt: wallNow,
          );
    } catch (e, st) {
      Loggers.activity.warning('载入当日用量失败，将从零开始累计', e, st);
      _today = DailyUsage(
        ownerId: ownerId,
        deviceLocalId: deviceLocalId,
        dayKey: key,
        updatedAt: wallNow,
      );
    }
  }

  static String _dayKey(DateTime wall) =>
      '${wall.year}-${wall.month.toString().padLeft(2, '0')}'
      '-${wall.day.toString().padLeft(2, '0')}';
}

/// 正在进行中的活动段（内存态）。
class _OpenSegment {
  _OpenSegment({
    required this.id,
    required this.appKey,
    required this.appName,
    required this.processName,
    required this.startedAt,
    required this.lastCreditMonoMs,
    required this.createdAt,
  });

  final String id;
  final String appKey;
  final String appName;
  final String? processName;
  final DateTime startedAt;
  final DateTime createdAt;

  /// 是否已经成功写入数据库；首次插入失败时为 false，由 flush 重试。
  bool persisted = false;

  /// 关闭失败时保存的待补写状态；非 null 表示这一段已经结束、只等落盘。
  _PendingClose? pendingClose;

  bool get isClosing => pendingClose != null;

  /// 已经计入到哪个单调时刻（避免重复计入同一段时间）。
  int lastCreditMonoMs;

  /// 已累计的活跃毫秒数。
  int activeMs = 0;
}

/// 关闭活动段时已经算好的最终结果（关闭失败后留在内存里等待重试）。
class _PendingClose {
  const _PendingClose({
    required this.endedAt,
    required this.activeSeconds,
    required this.reason,
  });

  final DateTime endedAt;
  final int activeSeconds;
  final SegmentEndReason reason;
}

/// 午夜边界的整数秒分配结果。
class _BoundarySplit {
  const _BoundarySplit({
    required this.oldSeconds,
    required this.newSeconds,
    required this.newRemainderMs,
    required this.newDebtMs,
  });

  final int oldSeconds;
  final int newSeconds;
  final int newRemainderMs;

  /// 新日多拿 1 秒后需要先偿还的毫秒数（0 = 没有欠账）。
  final int newDebtMs;
}

/// 待确认的应用切换候选。
class _Candidate {
  const _Candidate({
    required this.appKey,
    required this.sinceMonoMs,
    required this.sinceWall,
    required this.displayName,
    this.processName,
  });

  final String appKey;
  final int sinceMonoMs;
  final DateTime sinceWall;
  final String displayName;
  final String? processName;
}

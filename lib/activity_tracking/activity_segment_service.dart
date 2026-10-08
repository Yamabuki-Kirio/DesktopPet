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
  })  : _activityDao = activityDao,
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

    // 跨日/首次都要保证当日累计行存在且属于今天。
    await _ensureDay(sample.wallNow);

    // --- 首次采样：只建立基线，不追溯计时 ---
    if (prevMono == null || prevWall == null) {
      await _considerForeground(sample, creditMs: 0, idleOverMs: 0);
      return;
    }

    final int monoDelta = sample.monotonicMs - prevMono;
    final int wallDelta = sample.wallNow.difference(prevWall).inMilliseconds;
    final int skew = wallDelta - monoDelta;

    // --- A. 中断：休眠 / 进程被冻结 / 采样长时间停摆 ---
    // 这段时间一分一秒都不计入，并按原因结束当前段。
    if (monoDelta > ActivityTracking.maxSampleGapMs ||
        wallDelta > ActivityTracking.maxSampleGapMs) {
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
    final int creditMs = math.min(rawCredit, ActivityTracking.maxCreditPerTickMs);

    // --- B. 系统时间大幅变化：结算后重开一段 ---
    if (skew.abs() > ActivityTracking.clockJumpThresholdMs) {
      final int idleOver = _idleOverMs(sample);
      // 先把设备计数按正常口径结算，避免这段时间凭空消失。
      _addDeviceUsage(sample, creditMs: creditMs, idleOverMs: idleOver);
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
    _addDeviceUsage(sample, creditMs: creditMs, idleOverMs: idleOverMs);

    // --- D. 判断应用归属 ---
    await _considerForeground(sample, creditMs: creditMs, idleOverMs: idleOverMs);

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
  void _addDeviceUsage(
    ActivitySample sample, {
    required int creditMs,
    required int idleOverMs,
  }) {
    if (sample.paused || sample.sessionLocked || creditMs <= 0) return;

    final int activeMs = math.max(0, creditMs - idleOverMs);
    final int idleMs = creditMs - activeMs;
    final DailyUsage? today = _today;
    if (today == null) return;

    DateTime? first = today.firstActiveAt;
    DateTime? last = today.lastActiveAt;
    if (activeMs > 0) {
      // 活跃区间的起点：本 tick 计入窗口内、空闲开始之前。
      final DateTime activeStart =
          sample.wallNow.subtract(Duration(milliseconds: idleOverMs + activeMs));
      first = (first == null || activeStart.isBefore(first)) ? activeStart : first;
      last = (last == null || sample.wallNow.isAfter(last)) ? sample.wallNow : last;
      _continuousActiveMs += activeMs;
    }

    _today = today.copyWith(
      sessionSeconds: today.sessionSeconds + (activeMs + idleMs) ~/ 1000,
      activeSeconds: today.activeSeconds + activeMs ~/ 1000,
      idleSeconds: today.idleSeconds + idleMs ~/ 1000,
      firstActiveAt: first,
      lastActiveAt: last,
      updatedAt: sample.wallNow,
    );
  }

  /// 依据当前采样决定「继续计时 / 结束 / 开新段」。
  Future<void> _considerForeground(
    ActivitySample sample, {
    required int creditMs,
    required int idleOverMs,
  }) async {
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

    if (sample.monotonicMs - candidate.sinceMonoMs < ActivityTracking.switchConfirmMs) {
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
    final String id = Ids.segment(ownerId, deviceLocalId, appKey, atWall);
    final _OpenSegment segment = _OpenSegment(
      id: id,
      appKey: appKey,
      appName: displayName,
      processName: processName,
      startedAt: atWall,
      lastCreditMonoMs: atMono,
    );
    _open = segment;
    try {
      await _activityDao.insert(ActivitySegment(
        id: id,
        ownerId: ownerId,
        deviceLocalId: deviceLocalId,
        appKey: appKey,
        appName: displayName,
        processName: processName,
        startedAt: atWall,
        activeSeconds: 0,
        createdAt: _wall.now(),
      ));
      // 本地写入成功后才声明"这条变了"：保证 outbox 里不会有本地不存在的记录。
      await _notifySegment(id);
    } catch (e, st) {
      // 数据库暂时失败不能中断采集：内存里继续计时，检查点时会再尝试。
      Loggers.activity.warning('写入活动段失败（将继续在内存计时）: $id', e, st);
    }
  }

  Future<void> _closeOpen({
    required SegmentEndReason reason,
    required DateTime endWall,
    required int creditUpToMono,
  }) async {
    final _OpenSegment? open = _open;
    if (open == null) return;
    _open = null;

    final int delta = math.max(0, creditUpToMono - open.lastCreditMonoMs);
    open.activeMs += math.min(delta, ActivityTracking.maxCreditPerTickMs);
    open.lastCreditMonoMs = creditUpToMono;

    final int activeSeconds = open.activeMs ~/ 1000;
    // 结束时间不得早于开始时间（时钟回拨 / 边界情况兜底）。
    final DateTime safeEnd = endWall.isBefore(open.startedAt) ? open.startedAt : endWall;

    try {
      await _activityDao.closeSegment(
        open.id,
        safeEnd,
        activeSeconds,
        reason.wireName,
      );
      await _checkpointDao.delete(open.id);
      await _notifySegment(open.id);
    } catch (e, st) {
      Loggers.activity.warning('关闭活动段失败: ${open.id}', e, st);
    }
  }

  // ---------------------------------------------------------------------------
  // 检查点与每日用量
  // ---------------------------------------------------------------------------

  Future<void> _maybeCheckpoint(int monoNow) async {
    if (monoNow - _lastCheckpointMonoMs < ActivityTracking.checkpointIntervalMs) return;
    _lastCheckpointMonoMs = monoNow;
    await _flush(force: false);
  }

  /// 落盘：活动段检查点 + 当日用量 + 应用库 last_seen。
  Future<void> _flush({required bool force}) async {
    final DateTime now = _wall.now();
    try {
      final _OpenSegment? open = _open;
      if (open != null) {
        final int activeSeconds = open.activeMs ~/ 1000;
        await _checkpointDao.upsert(ActivityCheckpoint(
          segmentId: open.id,
          appKey: open.appKey,
          wallAt: now,
          activeSeconds: activeSeconds,
          updatedAt: now,
        ));
        await _activityDao.updateActiveSeconds(open.id, activeSeconds);
      }
      final DailyUsage? today = _today;
      if (today != null) {
        await _dailyUsageDao.upsert(today.copyWith(updatedAt: now));
      }
      await _applications.flush();
      _consecutiveFailures = 0;

      // Phase 2：本地落盘成功后再声明变更（写 outbox）。
      // 顺序很重要——先本地后 outbox，保证队列里不会有本地不存在的记录。
      if (open != null) {
        await _notifySegment(open.id);
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
    await _loadToday(referenceWall: wallNow);
  }

  Future<void> _loadToday({DateTime? referenceWall}) async {
    final DateTime wallNow = referenceWall ?? _wall.now();
    final String key = _dayKey(wallNow);
    try {
      final DailyUsage? existing =
          await _dailyUsageDao.find(ownerId, deviceLocalId, key);
      _today = existing ??
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
  });

  final String id;
  final String appKey;
  final String appName;
  final String? processName;
  final DateTime startedAt;

  /// 已经计入到哪个单调时刻（避免重复计入同一段时间）。
  int lastCreditMonoMs;

  /// 已累计的活跃毫秒数。
  int activeMs = 0;
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

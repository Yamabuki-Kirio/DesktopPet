import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/constants.dart';
import '../core/logger.dart';
import '../state_engine/system_state.dart';
import 'activity_segment_service.dart';
import 'activity_state_mapper.dart';
import 'application_repository.dart';
import 'foreground_app_provider.dart';
import 'idle_detector.dart';
import 'models/activity_enums.dart';
import 'models/activity_sample.dart';
import 'models/tracking_settings.dart';
import 'session_state_provider.dart';

/// 采集器：按固定间隔采样并把结果交给状态机与状态映射。
///
/// 这一层只做「编排」：
/// - 从三个平台提供者取数据，组装成一次 [ActivitySample]；
/// - 交给 [ActivitySegmentService] 做合并 / 计时 / 落盘；
/// - 用 [ActivityStateMapper] 得到桌宠状态，**只在状态与引擎当前状态不同时**
///   才发起请求，避免每 2 秒刷一条日志、也避免打断引擎自己的推迟重试。
class ActivityTracker extends ChangeNotifier {
  ActivityTracker({
    required ActivitySegmentService service,
    required ApplicationRepository applications,
    required ForegroundAppProvider foregroundProvider,
    required IdleDetector idleDetector,
    required SessionStateProvider sessionStateProvider,
    required ActivityStateMapper stateMapper,
    required SystemState Function() readCurrentState,
    required Future<void> Function(ActivityStateDecision decision) onDecision,
    TrackingSettings settings = const TrackingSettings(),
    int sampleIntervalMs = ActivityTracking.sampleIntervalMs,
  })  : _service = service,
        _applications = applications,
        _foreground = foregroundProvider,
        _idle = idleDetector,
        _session = sessionStateProvider,
        _mapper = stateMapper,
        _readCurrentState = readCurrentState,
        _onDecision = onDecision,
        _settings = settings.normalized(),
        _sampleIntervalMs = sampleIntervalMs;

  final ActivitySegmentService _service;
  final ApplicationRepository _applications;
  final ForegroundAppProvider _foreground;
  final IdleDetector _idle;
  final SessionStateProvider _session;
  final ActivityStateMapper _mapper;
  final SystemState Function() _readCurrentState;
  final Future<void> Function(ActivityStateDecision decision) _onDecision;
  final int _sampleIntervalMs;

  TrackingSettings _settings;

  Timer? _timer;
  bool _running = false;
  bool _ticking = false;
  bool _disposed = false;

  TrackingSettings get settings => _settings;

  bool get isRunning => _running;

  /// 采集是否真的可用（Win32 不可用时为 false，此时不驱动桌宠状态）。
  bool get isAvailable => _foreground.isAvailable && _session.isAvailable;

  // --- 透传的实时状态（UI / 托盘用） ---

  TrackingStatus get status => _service.status;

  String? get currentAppKey => _service.currentAppKey;

  String? get currentAppDisplayName => _service.currentAppDisplayName;

  AppCategory? get currentAppCategory {
    final String? key = _service.currentAppKey;
    if (key == null) return null;
    return _applications.find(key)?.category;
  }

  int get todayActiveSeconds => _service.todayActiveSeconds;

  int get todaySessionSeconds => _service.todaySessionSeconds;

  int get todayIdleSeconds => _service.todayIdleSeconds;

  int get continuousActiveSeconds => _service.continuousActiveSeconds;

  int get currentSegmentSeconds => _service.currentSegmentSeconds;

  bool get isPaused => _settings.paused;

  ActivitySegmentService get service => _service;

  // ---------------------------------------------------------------------------
  // 生命周期
  // ---------------------------------------------------------------------------

  /// 启动采集。幂等。
  Future<void> start() async {
    if (_disposed || _running) return;
    await _service.initialize();
    _running = true;
    // 立即采一次，让界面/桌宠不用等一个周期才有数据。
    await _tickOnce();
    _timer = Timer.periodic(Duration(milliseconds: _sampleIntervalMs), (Timer _) {
      unawaited(_tickOnce());
    });
    Loggers.activity.info(
      '活动采集已启动（间隔 ${_sampleIntervalMs}ms，空闲阈值 '
      '${_settings.idleThresholdMs ~/ 1000}s，'
      '可用=${isAvailable ? '是' : '否'}）',
    );
  }

  /// 停止采集并关闭当前活动段（正常退出）。
  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    if (!_running) return;
    _running = false;
    await _service.shutdown();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }

  /// 更新采集设置（暂停开关、空闲阈值、提醒开关）。
  Future<void> updateSettings(TrackingSettings next) async {
    final TrackingSettings normalized = next.normalized();
    _settings = normalized;
    await _service.updateSettings(normalized);
    notifyListeners();
  }

  /// 暂停 / 恢复记录。
  ///
  /// 暂停时立即结束当前活动段（需求「八、排除规则」），不等下一个采样周期。
  Future<void> setPaused(bool paused) =>
      updateSettings(_settings.copyWith(paused: paused));

  /// 立即落盘（统计页打开前调用）。
  Future<void> flushNow() => _service.flushNow();

  // ---------------------------------------------------------------------------
  // 采样
  // ---------------------------------------------------------------------------

  Future<void> _tickOnce() async {
    if (_disposed || _ticking) return;
    _ticking = true;
    try {
      // 暂停时仍然要跑状态机（它负责把「暂停」落成一次结束动作），
      // 因此这里不做短路。
      final ActivitySample sample = ActivitySample(
        wallNow: _service.now(),
        monotonicMs: _service.nowMono(),
        foreground: _foreground.current(),
        idle: _idle.idleTime(),
        sessionLocked: _session.isLocked(),
        paused: _settings.paused,
      );

      await _service.tick(sample);
      await _evaluateState(sample);
    } catch (e, st) {
      // 采集异常绝不能影响桌宠动画。
      Loggers.activity.warning('采集周期失败（已跳过本次）', e, st);
    } finally {
      _ticking = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// 依据最新上下文决定是否请求切换桌宠状态。
  Future<void> _evaluateState(ActivitySample sample) async {
    final ActivityStateDecision? decision = _mapper.decide(
      trackingAvailable: isAvailable,
      trackingPaused: _settings.paused,
      foregroundCategory: currentAppCategory,
      idle: sample.idle,
      idleThresholdMs: _settings.idleThresholdMs,
      continuousActiveSeconds: _service.continuousActiveSeconds,
      todayActiveSeconds: _service.todayActiveSeconds,
      usageAlertThresholdMs: _settings.usageAlertThresholdMs,
      continuousReminderEnabled: _settings.continuousReminderEnabled,
      hasCriticalError: _service.consecutiveFailures >= 3,
    );
    if (decision == null) return;

    // 只在「目标状态 ≠ 引擎当前状态」时才请求。
    //
    // 两个好处：
    // 1. 不会每 2 秒产生一条「状态未发生变化」的拒绝日志；
    // 2. 不会重复请求从而干扰引擎自己的「推迟后重试」计时。
    if (decision.state == _readCurrentState()) return;

    // 自动状态一律 immediate=false：保留「等当前动画播完一轮」的平滑切换。
    await _onDecision(decision);
  }
}

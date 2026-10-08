import 'dart:async';

import 'package:flutter/foundation.dart';

import '../character/character_repository.dart';
import '../character/models/character_model.dart';
import '../character/models/emotion_asset.dart';
import '../character/models/state_mapping.dart';
import '../core/constants.dart';
import '../core/logger.dart';
import 'fallback_chain.dart';
import 'state_debouncer.dart';
import 'state_engine.dart';
import 'state_snapshot.dart';
import 'system_state.dart';

/// 默认状态引擎实现。
///
/// 职责边界：
/// - **决定**显示哪个状态、哪张素材（优先级 + 防抖 + 回退链 + 权重）；
/// - **不负责**渲染，也不负责采集系统信号。
///
/// 计时器只用于「推迟重试」（最短展示时长未满时），不用于轮询。
class DefaultStateEngine implements StateEngine {
  DefaultStateEngine({
    required CharacterRepository repository,
    FallbackChain? fallbackChain,
    StateDebouncer debouncer = const StateDebouncer(),
  })  : _repository = repository,
        _fallbackChain = fallbackChain ?? FallbackChain(),
        _debouncer = debouncer;

  final CharacterRepository _repository;
  final FallbackChain _fallbackChain;
  final StateDebouncer _debouncer;

  final ValueNotifier<StateSnapshot> _snapshot =
      ValueNotifier<StateSnapshot>(StateSnapshot.initial());

  final StreamController<StateChangeEvent> _events =
      StreamController<StateChangeEvent>.broadcast();

  Timer? _pendingTimer;

  String? _characterId;

  SystemState _state = SystemState.defaultState;
  DateTime _stateSince = DateTime.now();
  DateTime _lastAppliedChangeAt = DateTime.fromMillisecondsSinceEpoch(0);
  String? _manualAssetId;

  SystemState? _pendingState;
  DateTime? _pendingSince;

  // 素材与映射的内存视图：只在角色切换或显式 refresh 时重载，
  // 避免每次状态切换都打数据库（也避免重复解码）。
  List<EmotionAsset> _renderableAssets = const <EmotionAsset>[];
  Map<SystemState, List<StateMapping>> _mappings = <SystemState, List<StateMapping>>{};
  CharacterModel? _character;

  @override
  StateSnapshot get snapshot => _snapshot.value;

  @override
  ValueListenable<StateSnapshot> get snapshots => _snapshot;

  @override
  Stream<StateChangeEvent> get events => _events.stream;

  @override
  bool get isRunning => _characterId != null;

  @override
  Future<void> start({required String ownerId, required String characterId}) async {
    await setCharacter(characterId);
    await requestState(StateChangeRequest(
      state: SystemState.defaultState,
      trigger: StateTrigger.init,
      reason: '应用启动，载入默认状态',
      force: true,
    ));
    Loggers.state.info('状态引擎已启动: owner=$ownerId character=$characterId');
  }

  @override
  Future<void> setCharacter(String characterId) async {
    if (_characterId == characterId && _character != null) return;
    _characterId = characterId;
    await _reloadLibraryViews();
    Loggers.state.info(
      '当前角色切换为 ${_character?.displayName ?? characterId}'
      '（可用素材 ${_renderableAssets.length} 个）',
    );
    await _reResolve(reason: '角色切换');
  }

  @override
  Future<void> restore({
    required String ownerId,
    required String? characterId,
    String? assetId,
  }) async {
    Loggers.state.info('恢复上次会话: owner=$ownerId character=$characterId asset=$assetId');
    if (characterId != null) {
      await setCharacter(characterId);
    }
    if (assetId != null) {
      _manualAssetId = assetId;
    }
    await requestState(StateChangeRequest(
      state: SystemState.defaultState,
      trigger: StateTrigger.init,
      reason: '应用重启后恢复',
      force: true,
      manualAssetId: assetId,
    ));
  }

  @override
  Future<void> requestState(StateChangeRequest request) async {
    if (_characterId == null) {
      Loggers.state.warning('状态引擎尚未绑定角色，忽略状态请求 ${request.state.wireName}');
      return;
    }

    final DateTime now = DateTime.now();

    // 同一个目标状态连续请求 → 稳定时长累加（用于「前台应用需稳定 10 秒」）。
    final Duration stableFor = (_pendingState == request.state && _pendingSince != null)
        ? now.difference(_pendingSince!)
        : Duration.zero;
    if (_pendingState != request.state) {
      _pendingState = request.state;
      _pendingSince = now;
    }

    final DebounceDecision decision = _debouncer.decide(
      currentState: _state,
      currentStateStartedAt: _stateSince,
      lastAppliedChangeAt: _lastAppliedChangeAt,
      request: request,
      now: now,
      appStateStableFor: stableFor,
    );

    switch (decision) {
      case ApplyNow(:final bool waitForAnimationCycle, :final String note):
        _pendingTimer?.cancel();
        _pendingTimer = null;
        await _apply(request, waitForAnimationCycle: waitForAnimationCycle, note: note);

      case DeferUntil(:final DateTime at, :final String reason):
        _updateSnapshot(snapshot.copyWith(
          lastDecisionNote: '推迟：$reason',
          pendingState: request.state,
          pendingSince: _pendingSince,
          nextAllowedChangeAt: at,
        ));
        Loggers.state.info(
          '状态切换推迟: 请求=${request.state.wireName} 原因=$reason '
          '（将于 ${at.toIso8601String()} 后重试）',
        );
        _scheduleRetry(request, at);

      case RejectChange(:final String reason):
        _updateSnapshot(snapshot.copyWith(lastDecisionNote: '拒绝：$reason'));
        Loggers.state.info('状态切换被拒绝: 请求=${request.state.wireName} 原因=$reason');
    }
  }

  @override
  Future<void> lockManual({String? assetId, String? reason}) async {
    _manualAssetId = assetId;
    Loggers.state.info('用户手动锁定表情: asset=${assetId ?? '<按映射解析>'} reason=${reason ?? '-'}');
    await requestState(StateChangeRequest(
      state: SystemState.manual,
      trigger: StateTrigger.manual,
      reason: reason ?? '用户手动锁定表情',
      force: true,
      immediate: true,
      manualAssetId: assetId,
    ));
  }

  @override
  Future<void> releaseManual() async {
    if (_state != SystemState.manual) return;
    _manualAssetId = null;
    Loggers.state.info('用户解除 manual 锁定，恢复自动状态切换');
    await requestState(StateChangeRequest(
      state: SystemState.defaultState,
      trigger: StateTrigger.manual,
      reason: '用户解除锁定，恢复自动状态切换',
      force: true,
    ));
  }

  @override
  Future<void> refresh() async {
    if (_characterId == null) return;
    await _reloadLibraryViews();
    await _reResolve(reason: '素材或映射已变更');
  }

  @override
  Future<void> dispose() async {
    _pendingTimer?.cancel();
    _pendingTimer = null;
    await _events.close();
    _snapshot.dispose();
    Loggers.state.info('状态引擎已释放');
  }

  // ---------------------------------------------------------------------------
  // 内部
  // ---------------------------------------------------------------------------

  void _scheduleRetry(StateChangeRequest request, DateTime at) {
    _pendingTimer?.cancel();
    final int delayMs = at.difference(DateTime.now()).inMilliseconds;
    _pendingTimer = Timer(
      Duration(milliseconds: delayMs < 0 ? 0 : delayMs),
      () {
        // 重试时不再降低要求：仍然走完整的防抖判断。
        unawaited(requestState(request));
      },
    );
  }

  Future<void> _apply(
    StateChangeRequest request, {
    required bool waitForAnimationCycle,
    required String note,
  }) async {
    final SystemState previous = _state;
    final DateTime now = DateTime.now();

    _state = request.state;
    _stateSince = now;
    _lastAppliedChangeAt = now;
    _pendingState = null;
    _pendingSince = null;
    if (request.state != SystemState.manual) {
      // 离开 manual 时清掉临时锁定的图片。
      _manualAssetId = null;
    }

    await _reResolve(
      reason: request.reason ?? request.trigger.label,
      trigger: request.trigger,
      decisionNote: note,
      waitForAnimationCycle: waitForAnimationCycle,
      previousState: previous,
    );
  }

  Future<void> _reResolve({
    required String reason,
    StateTrigger trigger = StateTrigger.fallback,
    String decisionNote = '',
    bool waitForAnimationCycle = false,
    SystemState? previousState,
  }) async {
    final AssetResolution resolution = _fallbackChain.resolve(
      state: _state,
      renderableAssets: _renderableAssets,
      mappingsForState: _mappings[_state] ?? const <StateMapping>[],
      characterDefaultAssetId: _character?.defaultAssetId,
      manualAssetId: _state == SystemState.manual ? _manualAssetId : null,
    );

    final int holdMs = _state.minHoldMs;
    final DateTime? nextAllowed = _state == SystemState.manual
        ? null
        : DateTime.now().add(Duration(milliseconds: holdMs < 0 ? 0 : holdMs));

    _updateSnapshot(snapshot.copyWith(
      state: _state,
      trigger: trigger,
      reason: reason,
      startedAt: _stateSince,
      currentCharacter: _character,
      resolution: resolution,
      nextAllowedChangeAt: nextAllowed,
      clearNextAllowed: nextAllowed == null,
      lastDecisionNote: decisionNote,
      manualAssetId: _manualAssetId,
      clearManualAsset: _manualAssetId == null,
      clearPending: true,
    ));

    if (previousState != null && previousState != _state) {
      final EmotionAsset? asset = resolution.asset;
      Loggers.state.info(
        '状态切换 ${previousState.wireName} -> ${_state.wireName} '
        '| 原因: $reason | 触发: ${trigger.label} '
        '| 素材: ${asset == null ? '<占位图>' : '${asset.emotionName}/${asset.variantName}'} '
        '| 回退级别: ${resolution.level.label} '
        '| 回退原因: ${resolution.reason} '
        '| 等待动画一轮: $waitForAnimationCycle',
      );
      _events.add(StateChangeEvent(
        from: previousState,
        to: _state,
        trigger: trigger,
        reason: reason,
        waitForAnimationCycle: waitForAnimationCycle,
        at: DateTime.now(),
      ));
    } else if (resolution.isPlaceholder) {
      Loggers.state.warning('状态 ${_state.wireName} 无可用素材，将显示内置占位图');
    }
  }

  Future<void> _reloadLibraryViews() async {
    final String? characterId = _characterId;
    if (characterId == null) return;
    _character = await _repository.findCharacter(characterId);
    _renderableAssets = await _repository.listRenderableAssets(characterId);
    _mappings = await _repository.groupedMappings(characterId);
  }

  void _updateSnapshot(StateSnapshot next) {
    _snapshot.value = next;
  }
}

/// 让上层可以读到防抖常量（UI 展示用）。
const int kRapidSwitchSuppressMs = StateDebounce.rapidSwitchSuppressMs;

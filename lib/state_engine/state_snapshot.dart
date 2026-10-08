import '../character/models/character_model.dart';
import '../character/models/emotion_asset.dart';
import 'fallback_chain.dart';
import 'system_state.dart';

/// 状态调试器需要展示的全部信息（需求 9.4）。
class StateSnapshot {
  const StateSnapshot({
    required this.state,
    required this.trigger,
    required this.reason,
    required this.startedAt,
    required this.currentCharacter,
    required this.resolution,
    required this.nextAllowedChangeAt,
    required this.lastDecisionNote,
    this.pendingState,
    this.pendingSince,
    required this.manualAssetId,
  });

  /// 当前系统状态。
  final SystemState state;

  /// 触发来源。
  final StateTrigger trigger;

  /// 触发原因（人可读）。
  final String reason;

  /// 当前状态开始时间。
  final DateTime startedAt;

  /// 当前角色。
  final CharacterModel? currentCharacter;

  /// 解析结果（当前素材、回退级别、回退原因）。
  final AssetResolution resolution;

  /// 下次允许切换的时间。
  ///
  /// 为 null 表示不存在自动切换计划（manual 锁定，必须由用户解除）。
  final DateTime? nextAllowedChangeAt;

  /// 最近一次防抖决策说明。
  final String lastDecisionNote;

  /// 正在等待应用稳定的目标状态（阶段 0 一般为 null）。
  final SystemState? pendingState;

  /// 目标状态首次被请求的时间。
  final DateTime? pendingSince;

  /// manual 状态临时锁定的图片。
  final String? manualAssetId;

  EmotionAsset? get currentAsset => resolution.asset;

  /// 当前展示的是哪一级回退。
  FallbackLevel get fallbackLevel => resolution.level;

  /// 当前素材是否为动态图。
  bool get isAnimated => resolution.asset?.isAnimated ?? false;

  /// 当前素材帧数。
  int get frameCount => resolution.asset?.frameCount ?? 0;

  StateSnapshot copyWith({
    SystemState? state,
    StateTrigger? trigger,
    String? reason,
    DateTime? startedAt,
    CharacterModel? currentCharacter,
    AssetResolution? resolution,
    DateTime? nextAllowedChangeAt,
    bool clearNextAllowed = false,
    String? lastDecisionNote,
    SystemState? pendingState,
    DateTime? pendingSince,
    bool clearPending = false,
    String? manualAssetId,
    bool clearManualAsset = false,
  }) =>
      StateSnapshot(
        state: state ?? this.state,
        trigger: trigger ?? this.trigger,
        reason: reason ?? this.reason,
        startedAt: startedAt ?? this.startedAt,
        currentCharacter: currentCharacter ?? this.currentCharacter,
        resolution: resolution ?? this.resolution,
        nextAllowedChangeAt:
            clearNextAllowed ? null : (nextAllowedChangeAt ?? this.nextAllowedChangeAt),
        lastDecisionNote: lastDecisionNote ?? this.lastDecisionNote,
        pendingState: clearPending ? null : (pendingState ?? this.pendingState),
        pendingSince: clearPending ? null : (pendingSince ?? this.pendingSince),
        manualAssetId: clearManualAsset ? null : (manualAssetId ?? this.manualAssetId),
      );

  /// 构造一个"空"快照，用于引擎尚未启动时。
  static StateSnapshot initial() => StateSnapshot(
        state: SystemState.defaultState,
        trigger: StateTrigger.init,
        reason: '引擎尚未启动',
        startedAt: DateTime.now(),
        currentCharacter: null,
        resolution: const AssetResolution(
          asset: null,
          level: FallbackLevel.builtinPlaceholder,
          reason: '尚未加载素材',
        ),
        nextAllowedChangeAt: null,
        lastDecisionNote: '',
        manualAssetId: null,
      );

  /// 是否必须由用户主动解除才能离开当前状态。
  bool get requiresUserRelease => state == SystemState.manual;
}

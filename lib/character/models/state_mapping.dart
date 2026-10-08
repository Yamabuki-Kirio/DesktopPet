import '../../state_engine/system_state.dart';

/// 状态映射的一条候选记录。
///
/// 需求 4.6 / 九之 9.3 要求同一状态可以配置**多个候选**并按权重选择，
/// 因此这里一个 (character, systemState) 会对应 0..N 条记录。
///
/// 两种绑定方式：
/// - 绑定情绪：[emotionName] 非空，[assetId] 为空 → 使用该情绪下的全部变体（含后续新增的变体）
/// - 绑定具体图片：[assetId] 非空 → 精确指定一张图
class StateMapping {
  const StateMapping({
    required this.id,
    required this.characterId,
    required this.systemState,
    this.assetId,
    this.emotionName,
    required this.weight,
    required this.priority,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String characterId;
  final SystemState systemState;

  /// 精确绑定到某张素材时非空（回退链第 1 级）。
  final String? assetId;

  /// 绑定到某个情绪时非空（回退链第 2 级）。
  final String? emotionName;

  /// 选择权重，必须 > 0。
  final int weight;

  /// 本条映射的优先级，默认取系统状态默认优先级，用户可覆盖。
  final int priority;

  final DateTime createdAt;
  final DateTime updatedAt;

  StateMapping copyWith({int? weight, int? priority, DateTime? updatedAt}) => StateMapping(
        id: id,
        characterId: characterId,
        systemState: systemState,
        assetId: assetId,
        emotionName: emotionName,
        weight: weight ?? this.weight,
        priority: priority ?? this.priority,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, Object?> toMap() => <String, Object?>{
        'id': id,
        'character_id': characterId,
        'system_state': systemState.wireName,
        'asset_id': assetId,
        'emotion_name': emotionName,
        'weight': weight,
        'priority': priority,
        'created_at': createdAt.millisecondsSinceEpoch,
        'updated_at': updatedAt.millisecondsSinceEpoch,
      };

  static StateMapping fromMap(Map<String, Object?> m) => StateMapping(
        id: m['id']! as String,
        characterId: m['character_id']! as String,
        systemState: SystemState.fromWire(m['system_state']! as String),
        assetId: m['asset_id'] as String?,
        emotionName: m['emotion_name'] as String?,
        weight: m['weight']! as int,
        priority: m['priority']! as int,
        createdAt: DateTime.fromMillisecondsSinceEpoch(m['created_at']! as int),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(m['updated_at']! as int),
      );
}

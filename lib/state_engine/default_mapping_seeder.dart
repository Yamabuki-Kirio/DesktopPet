import '../../core/ids.dart';
import '../character/models/emotion_asset.dart';
import '../character/models/state_mapping.dart';
import 'suggested_emotions.dart';
import 'system_state.dart';

/// 为新角色自动生成一组「建议状态映射」。
///
/// 需求「七、系统状态与情绪映射」以 Maya 为例给了一套建议
/// （default → Cheerful、focused → Thinking 或 Bench_Thinking、error → Shocked 或 Angry ...）。
/// 这里按**情绪名匹配**的方式落地这套建议：
/// - 匹配到的情绪会生成映射，因此用户导入 Ace Attorney 后**无需任何手工配置**就能看到多状态效果；
/// - 没匹配到的状态不生成映射，交给 [FallbackChain] 走 5 级回退；
/// - 生成的结果是普通的 `state_mappings` 记录，用户可以随意修改或清空。
///
/// 这样做既满足「提供默认建议」，又满足「允许用户修改」，且不会写死任何角色名。
class DefaultMappingSeeder {
  const DefaultMappingSeeder();

  /// 每个状态最多生成多少条候选，避免素材情绪特别多时把界面撑爆。
  static const int maxCandidatesPerState = 3;

  /// 生成建议映射。已存在映射的状态不会被覆盖（由调用方保证）。
  List<StateMapping> seed({
    required String characterId,
    required List<EmotionAsset> assets,
    required DateTime now,
  }) {
    final List<StateMapping> out = <StateMapping>[];

    // 情绪名 -> 可用素材（只保留可用素材，避免建议指向已损坏文件）
    final Map<String, List<EmotionAsset>> byEmotion = <String, List<EmotionAsset>>{};
    for (final EmotionAsset a in assets) {
      if (!a.isRenderable) continue;
      byEmotion.putIfAbsent(a.emotionName.toLowerCase(), () => <EmotionAsset>[]).add(a);
    }

    if (byEmotion.isEmpty) return out;

    kSuggestedEmotions.forEach((SystemState state, List<String> suggestions) {
      if (suggestions.isEmpty) return; // manual 由用户显式指定
      final List<EmotionAsset> picked = <EmotionAsset>[];
      for (final String suggestion in suggestions) {
        final List<EmotionAsset>? hit = byEmotion[suggestion.toLowerCase()];
        if (hit == null || hit.isEmpty) continue;
        // 同一情绪下多个变体只取第一个，避免候选里出现视觉重复。
        picked.add(hit.first);
        if (picked.length >= maxCandidatesPerState) break;
      }
      if (picked.isEmpty) return;

      for (int i = 0; i < picked.length; i++) {
        final EmotionAsset asset = picked[i];
        out.add(StateMapping(
          id: Ids.stateMappingId(characterId, state.wireName, i),
          characterId: characterId,
          systemState: state,
          emotionName: asset.emotionName,
          weight: 1,
          priority: state.priority,
          createdAt: now,
          updatedAt: now,
        ));
      }
    });

    // default 状态是兜底状态：即使没有任何情绪命中，也给它一张图，
    // 否则桌宠首次启动会直接显示内置占位图。
    if (!out.any((StateMapping m) => m.systemState == SystemState.defaultState)) {
      final EmotionAsset first = byEmotion.values.first.first;
      out.add(StateMapping(
        id: Ids.stateMappingId(characterId, SystemState.defaultState.wireName, 0),
        characterId: characterId,
        systemState: SystemState.defaultState,
        emotionName: first.emotionName,
        weight: 1,
        priority: SystemState.defaultState.priority,
        createdAt: now,
        updatedAt: now,
      ));
    }

    return out;
  }
}

import 'dart:math';

import '../character/models/emotion_asset.dart';
import '../character/models/state_mapping.dart';
import 'system_state.dart';

/// 回退链的级别（需求「七」，Phase 4C-6A.1 新增收藏一级）。
///
/// ⚠️ **与需求 §9 列举顺序的一处有意偏差（已在文档中标注）**：
/// 需求把「default 显式映射」排在收藏之前。但本项目里 `characterDefault` 在
/// **未显式设置默认图片**时会隐式退化为"第一张有效素材"，与 `firstValidAsset`
/// 重合 —— 若把收藏排在它之后，**收藏将永远不可达**（快照构建会认为
/// "结果等于默认素材"而跳过该状态）。因此实际顺序把收藏放在「角色默认」**之前**。
enum FallbackLevel {
  /// 1. 目标状态指定的具体图片。
  stateAsset('目标状态指定图片'),

  /// 2. 目标状态指定的情绪。
  stateEmotion('目标状态指定情绪'),

  /// 3. 角色**收藏**素材（Phase 4C-6A.1，v5 新增）。
  characterFavorite('角色收藏素材'),

  /// 4. 角色默认图片。
  characterDefault('角色默认图片'),

  /// 5. 角色第一个有效素材。
  firstValidAsset('角色第一个有效素材'),

  /// 6. 内置占位图。
  builtinPlaceholder('内置占位图');

  const FallbackLevel(this.label);

  final String label;
}

/// 一次解析的结果。
class AssetResolution {
  const AssetResolution({
    required this.asset,
    required this.level,
    required this.reason,
  });

  /// 命中的素材；为 null 表示应当显示内置占位图。
  final EmotionAsset? asset;

  final FallbackLevel level;

  /// 人可读的原因，用于写日志与状态调试器展示（需求：回退素材原因必须记录）。
  final String reason;

  bool get isPlaceholder => asset == null;
}

/// 状态 → 素材的 6 级回退链。
///
/// 需求「七」规定：
/// 1. 目标状态指定图片
/// 2. 目标状态指定情绪
/// 3. 角色**收藏**素材（Phase 4C-6A.1 新增；顺序说明见 [FallbackLevel]）
/// 4. 角色默认图片
/// 5. 角色第一个有效素材
/// 6. 内置占位图
///
/// 同时在候选多于一个时按 `weight` 加权随机选择（需求：同一状态可以从候选图片中按权重选择）。
class FallbackChain {
  FallbackChain({Random? random}) : _random = random ?? Random();

  final Random _random;

  /// 解析某状态应该显示哪张素材。
  ///
  /// [renderableAssets] 必须是**已过滤**的可用素材（`enabled = 1 且 validation_status = 'valid'`）。
  AssetResolution resolve({
    required SystemState state,
    required List<EmotionAsset> renderableAssets,
    required List<StateMapping> mappingsForState,
    required String? characterDefaultAssetId,
    String? manualAssetId,
  }) {
    if (renderableAssets.isEmpty) {
      return const AssetResolution(
        asset: null,
        level: FallbackLevel.builtinPlaceholder,
        reason: '角色没有任何可用素材',
      );
    }

    // --- 1. 目标状态指定的具体图片 ---
    // manual 状态优先使用用户在调试器/设置里临时指定的图片。
    final List<_Weighted> exact = <_Weighted>[];
    if (manualAssetId != null) {
      final EmotionAsset? forced = _findById(renderableAssets, manualAssetId);
      if (forced != null) {
        return AssetResolution(
          asset: forced,
          level: FallbackLevel.stateAsset,
          reason: '使用 manual 指定图片 ${forced.emotionName}/${forced.variantName}',
        );
      }
    }
    for (final StateMapping m in mappingsForState) {
      if (m.assetId == null) continue;
      final EmotionAsset? a = _findById(renderableAssets, m.assetId!);
      if (a == null) continue; // 素材被删除或禁用，静默跳过该候选。
      exact.add(_Weighted(a, m.weight));
    }
    if (exact.isNotEmpty) {
      final EmotionAsset picked = _pick(exact);
      return AssetResolution(
        asset: picked,
        level: FallbackLevel.stateAsset,
        reason: '命中状态 ${state.wireName} 的指定图片 '
            '（${exact.length} 个候选中按权重选中 ${picked.emotionName}/${picked.variantName}）',
      );
    }

    // --- 2. 目标状态指定的情绪 ---
    final List<_Weighted> byEmotion = <_Weighted>[];
    for (final StateMapping m in mappingsForState) {
      final String? emotion = m.emotionName;
      if (emotion == null) continue;
      for (final EmotionAsset a in renderableAssets) {
        if (a.emotionName.toLowerCase() == emotion.toLowerCase()) {
          byEmotion.add(_Weighted(a, m.weight));
        }
      }
    }
    if (byEmotion.isNotEmpty) {
      final EmotionAsset picked = _pick(byEmotion);
      return AssetResolution(
        asset: picked,
        level: FallbackLevel.stateEmotion,
        reason: '命中状态 ${state.wireName} 的情绪映射 '
            '（${byEmotion.length} 个候选中按权重选中 ${picked.emotionName}/${picked.variantName}）',
      );
    }

    // --- 3. 角色收藏素材（Phase 4C-6A.1）---
    // 没有任何收藏时直接跳过，因此**升级前已验收的行为一字不变**。
    final List<EmotionAsset> favorites =
        renderableAssets.where((EmotionAsset a) => a.favorite).toList(growable: false);
    if (favorites.isNotEmpty) {
      // 刻意取**第一张**收藏（`renderableAssets` 已按 情绪名 → 变体名 排序），
      // 不做权重随机：收藏是"钉住一张图"，随机会让同一状态在每次重建快照时换图。
      final EmotionAsset picked = favorites.first;
      return AssetResolution(
        asset: picked,
        level: FallbackLevel.characterFavorite,
        reason: '状态 ${state.wireName} 无映射，回退到角色收藏素材'
            '（共 ${favorites.length} 张收藏，使用 ${picked.emotionName}/${picked.variantName}）',
      );
    }

    // --- 4. 角色默认图片 ---
    if (characterDefaultAssetId != null) {
      final EmotionAsset? def = _findById(renderableAssets, characterDefaultAssetId);
      if (def != null) {
        return AssetResolution(
          asset: def,
          level: FallbackLevel.characterDefault,
          reason: '状态 ${state.wireName} 无映射，回退到角色默认图片',
        );
      }
    }

    // --- 4. 角色第一个有效素材 ---
    final EmotionAsset first = renderableAssets.first;
    return AssetResolution(
      asset: first,
      level: FallbackLevel.firstValidAsset,
      reason: '状态 ${state.wireName} 无映射且无默认图片，回退到第一个有效素材',
    );

    // --- 5. 内置占位图由 asset == null 表示，已在方法开头处理空素材的情况 ---
  }

  EmotionAsset? _findById(List<EmotionAsset> assets, String id) {
    for (final EmotionAsset a in assets) {
      if (a.id == id) return a;
    }
    return null;
  }

  /// 加权随机选择。
  EmotionAsset _pick(List<_Weighted> candidates) {
    int total = 0;
    for (final _Weighted c in candidates) {
      total += c.weight <= 0 ? 0 : c.weight;
    }
    if (total <= 0) return candidates.first.asset;
    int roll = _random.nextInt(total);
    for (final _Weighted c in candidates) {
      roll -= c.weight <= 0 ? 0 : c.weight;
      if (roll < 0) return c.asset;
    }
    return candidates.last.asset;
  }
}

class _Weighted {
  const _Weighted(this.asset, this.weight);

  final EmotionAsset asset;
  final int weight;
}

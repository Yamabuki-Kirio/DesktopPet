import 'dart:math';

import '../character/models/character_model.dart';
import '../character/models/emotion_asset.dart';
import '../character/models/state_mapping.dart';
import '../state_engine/fallback_chain.dart';
import '../state_engine/system_state.dart';

/// 状态 → 素材的**只读快照**（Phase 4C-5），用于下发给 Android 原生层。
///
/// 为什么要有这一层：
/// * Android 的前台服务可能在 **Flutter 进程已被回收**的情况下继续运行，
///   那时它读不到 SQLite，只能靠最近一次推送的快照做状态联动（需求 §8 / §10）；
/// * 快照由**已有的** `FallbackChain` 算出来，因此原生侧选到的素材与
///   桌面端当前的解析规则完全一致，不会出现"Android 一套、Windows 另一套"。
///
/// Phase 4C-6A 追加三项**可选的**配置（老版本原生/老快照没有它们照样工作）：
/// [automaticStateEnabled] / [categoryStateRules] / [appStateOverrides]。
class OverlayStateMapping {
  const OverlayStateMapping({
    this.schemaVersion = schemaVersionValue,
    required this.revision,
    required this.characterId,
    this.defaultAsset,
    this.states = const <String, OverlayStateAsset>{},
    this.automaticStateEnabled = true,
    this.defaultStateKey,
    this.categoryStateRules = const <String, String>{},
    this.appStateOverrides = const <String, String>{},
  });

  /// 协议版本；原生遇到未知版本会整份忽略而不是猜。
  ///
  /// Phase 4C-6A 新增字段都是**可选**的（缺失时原生有默认值），
  /// 因此**不提升版本号** —— 提升会让升级瞬间"没有可用映射"。
  static const int schemaVersionValue = 1;

  final int schemaVersion;

  /// 单调递增的版本号：原生只接受"不小于当前"的 revision（旧版本一律丢弃）。
  final int revision;

  final String characterId;

  /// 角色默认素材（回退链第 3 级）。
  final OverlayStateAsset? defaultAsset;

  /// 各状态对应的素材；键必须是 [SystemState.wireName]。
  final Map<String, OverlayStateAsset> states;

  /// 自动状态联动总开关（设置页可关；关闭后原生只保留手动覆盖）。
  final bool automaticStateEnabled;

  /// 默认状态键（诊断用；null 表示用原生内置的 `default`）。
  final String? defaultStateKey;

  /// 分类 → 状态规则（`AppCategory.wireName` → `SystemState.wireName`）。
  ///
  /// **不在表里的分类 = 保持上一个稳定状态**；为空时原生退回内置表。
  final Map<String, String> categoryStateRules;

  /// 具体应用覆盖规则（包名 → `SystemState.wireName`），优先级高于分类规则。
  ///
  /// 本阶段只提供**数据接口**（原生的解析、优先级与回退已实现并单测覆盖），
  /// 编辑入口留给后续阶段（需求 §6 明确允许）。
  final Map<String, String> appStateOverrides;

  Map<String, Object?> toJson() => <String, Object?>{
        'schemaVersion': schemaVersion,
        'revision': revision,
        'characterId': characterId,
        'defaultAsset': defaultAsset?.toJson(),
        'states': states.map(
          (String key, OverlayStateAsset value) =>
              MapEntry<String, Object?>(key, value.toJson()),
        ),
        'automaticEnabled': automaticStateEnabled,
        if (defaultStateKey != null) 'defaultStateKey': defaultStateKey,
        'categoryRules': categoryStateRules,
        'appOverrides': appStateOverrides,
      };

  /// 复制并换一个 revision（由控制器统一分配，保证单调递增）。
  OverlayStateMapping withRevision(int nextRevision) => OverlayStateMapping(
        schemaVersion: schemaVersion,
        revision: nextRevision,
        characterId: characterId,
        defaultAsset: defaultAsset,
        states: states,
        automaticStateEnabled: automaticStateEnabled,
        defaultStateKey: defaultStateKey,
        categoryStateRules: categoryStateRules,
        appStateOverrides: appStateOverrides,
      );

  /// 去重签名：内容相同就不必重复下发。
  ///
  /// **必须包含 4C-6A 的三个新字段** —— 否则"只是把自动开关关掉"这种变化
  /// 会被去重吞掉，原生永远收不到。
  String get signature {
    final List<String> parts = <String>[
      characterId,
      defaultAsset?.assetId ?? '',
      'auto=$automaticStateEnabled',
      'default=${defaultStateKey ?? ''}',
      for (final String key in categoryStateRules.keys.toList()..sort())
        'c:$key=${categoryStateRules[key]}',
      for (final String key in appStateOverrides.keys.toList()..sort())
        'a:$key=${appStateOverrides[key]}',
      for (final SystemState state in SystemState.values)
        '${state.wireName}=${states[state.wireName]?.assetId ?? ''}',
    ];
    return parts.join('|');
  }
}

/// 快照里的一个素材。
class OverlayStateAsset {
  const OverlayStateAsset({
    required this.assetId,
    required this.path,
    required this.isAnimated,
  });

  final String assetId;
  final String path;
  final bool isAnimated;

  Map<String, Object?> toJson() => <String, Object?>{
        'assetId': assetId,
        'path': path,
        'isAnimated': isAnimated,
      };
}

/// 状态 → 素材快照的**构建器**（纯函数，可单测）。
///
/// 逐条复用项目现有规则：
/// * 每个状态走 [FallbackChain]（状态指定图片 → 状态指定情绪 → 角色默认 →
///   首个有效素材），**不新写一套映射逻辑**；
/// * 与角色默认素材**结果相同**的状态不写进快照 —— 它们本来就该走
///   `defaultAsset` 那一级。这样既让原生的回退级别（1/2/3/4）真实可读，
///   也避免快照里塞 11 份重复的默认素材；
/// * 解析为"内置占位图"（没有任何可用素材）的状态同样不进快照，
///   由原生侧的回退链接管。
///
/// 加权随机在快照场景下必须**可复现**：因此默认注入固定种子，
/// 保证同样的库内容每次都得到同一份快照（否则每次推送都会换图）。
OverlayStateMapping buildOverlayStateMapping({
  required CharacterModel? character,
  required List<EmotionAsset> renderableAssets,
  required List<StateMapping> mappings,
  required int revision,
  bool automaticStateEnabled = true,
  String? defaultStateKey,
  Map<String, String> categoryStateRules = const <String, String>{},
  Map<String, String> appStateOverrides = const <String, String>{},
  Random? random,
}) {
  if (character == null) {
    return OverlayStateMapping(revision: revision, characterId: '');
  }

  final FallbackChain chain = FallbackChain(random: random ?? Random(0));
  final Map<SystemState, List<StateMapping>> grouped =
      <SystemState, List<StateMapping>>{};
  for (final StateMapping mapping in mappings) {
    grouped.putIfAbsent(mapping.systemState, () => <StateMapping>[]).add(mapping);
  }

  final OverlayStateAsset? defaultAsset =
      _defaultAssetOf(character, renderableAssets);

  final Map<String, OverlayStateAsset> states = <String, OverlayStateAsset>{};
  for (final SystemState state in SystemState.values) {
    final AssetResolution resolution = chain.resolve(
      state: state,
      renderableAssets: renderableAssets,
      mappingsForState: grouped[state] ?? const <StateMapping>[],
      characterDefaultAssetId: character.defaultAssetId,
    );
    final EmotionAsset? asset = resolution.asset;
    if (asset == null) continue;
    if (asset.id == defaultAsset?.assetId) continue;
    states[state.wireName] = _toAsset(asset);
  }

  return OverlayStateMapping(
    revision: revision,
    characterId: character.id,
    defaultAsset: defaultAsset,
    states: states,
    automaticStateEnabled: automaticStateEnabled,
    defaultStateKey: defaultStateKey,
    categoryStateRules: categoryStateRules,
    appStateOverrides: appStateOverrides,
  );
}

/// 角色默认素材：优先显式设置的那张，其次第一张可用素材。
OverlayStateAsset? _defaultAssetOf(
  CharacterModel character,
  List<EmotionAsset> renderableAssets,
) {
  final String? defaultId = character.defaultAssetId;
  if (defaultId != null) {
    for (final EmotionAsset asset in renderableAssets) {
      if (asset.id == defaultId) return _toAsset(asset);
    }
  }
  return renderableAssets.isEmpty ? null : _toAsset(renderableAssets.first);
}

OverlayStateAsset _toAsset(EmotionAsset asset) => OverlayStateAsset(
      assetId: asset.id,
      path: asset.filePath,
      isAnimated: asset.isAnimated,
    );

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:petlife/character/models/character_model.dart';
import 'package:petlife/character/models/emotion_asset.dart';
import 'package:petlife/character/models/enums.dart';
import 'package:petlife/character/models/state_mapping.dart';
import 'package:petlife/platform/overlay_state_mapping.dart';
import 'package:petlife/state_engine/system_state.dart';

/// Phase 4C-5：状态 → 素材快照的构建（纯 Dart，不碰通道）。
///
/// 关键点是**复用**已有的 `FallbackChain` 语义：这里验证的是
/// "快照里每个状态拿到的素材与既有回退链一致"，而不是另起一套。
void main() {
  EmotionAsset asset({
    required String id,
    String emotion = 'idle',
    bool animated = false,
  }) =>
      EmotionAsset(
        id: id,
        characterId: 'char-1',
        emotionName: emotion,
        variantName: 'default',
        filePath: '/data/PetLife/assets/$id.png',
        fileHash: 'hash-$id',
        mimeType: animated ? 'image/webp' : 'image/png',
        fileSize: 4,
        width: 64,
        height: 64,
        frameCount: animated ? 12 : 0,
        isAnimated: animated,
        hasAlpha: true,
        enabled: true,
        validationStatus: ValidationStatus.valid,
        createdAt: DateTime(2026, 9, 30),
      );

  CharacterModel character({String? defaultAssetId}) => CharacterModel(
        id: 'char-1',
        packId: 'pack-1',
        ownerId: 'local.default',
        internalName: 'Maya',
        displayName: 'Maya',
        defaultAssetId: defaultAssetId,
        enabled: true,
        createdAt: DateTime(2026, 9, 30),
        updatedAt: DateTime(2026, 9, 30),
      );

  StateMapping mapping({
    required SystemState state,
    String? assetId,
    String? emotionName,
    int weight = 1,
  }) =>
      StateMapping(
        id: 'map-${state.wireName}-${assetId ?? emotionName}',
        characterId: 'char-1',
        systemState: state,
        assetId: assetId,
        emotionName: emotionName,
        weight: weight,
        priority: state.priority,
        createdAt: DateTime(2026, 9, 30),
        updatedAt: DateTime(2026, 9, 30),
      );

  test('状态映射被序列化为原生约定的结构', () {
    final OverlayStateMapping snapshot = buildOverlayStateMapping(
      character: character(defaultAssetId: 'a-default'),
      renderableAssets: <EmotionAsset>[
        asset(id: 'a-default'),
        asset(id: 'a-game', animated: true),
      ],
      mappings: <StateMapping>[
        mapping(state: SystemState.gaming, assetId: 'a-game'),
      ],
      revision: 7,
    );

    expect(snapshot.schemaVersion, OverlayStateMapping.schemaVersionValue);
    expect(snapshot.revision, 7);
    expect(snapshot.characterId, 'char-1');
    expect(snapshot.defaultAsset?.assetId, 'a-default');

    final Map<String, Object?> json = snapshot.toJson();
    expect(json['revision'], 7);
    expect(json['characterId'], 'char-1');
    final Map<String, Object?> states = json['states']! as Map<String, Object?>;
    // 只有"与角色默认素材不同"的状态才进快照（其余走 defaultAsset 那一级）。
    expect(states.keys, <String>[SystemState.gaming.wireName]);
    final Map<String, Object?> gaming =
        states[SystemState.gaming.wireName]! as Map<String, Object?>;
    expect(gaming['assetId'], 'a-game');
    expect(gaming['isAnimated'], isTrue);
    expect(gaming['path'], '/data/PetLife/assets/a-game.png');
  });

  test('空素材库：状态与默认素材都为空，仍是一份合法快照', () {
    final OverlayStateMapping snapshot = buildOverlayStateMapping(
      character: character(),
      renderableAssets: const <EmotionAsset>[],
      mappings: const <StateMapping>[],
      revision: 1,
    );
    expect(snapshot.characterId, 'char-1');
    expect(snapshot.defaultAsset, isNull);
    expect(snapshot.states, isEmpty);
    expect(snapshot.toJson()['states'], isEmpty);
  });

  test('没有当前角色时返回空角色快照（原生据此走"缺映射"分支）', () {
    final OverlayStateMapping snapshot = buildOverlayStateMapping(
      character: null,
      renderableAssets: const <EmotionAsset>[],
      mappings: const <StateMapping>[],
      revision: 3,
    );
    expect(snapshot.characterId, isEmpty);
    expect(snapshot.revision, 3);
    expect(snapshot.states, isEmpty);
  });

  test('每个状态都复用既有回退链：状态映射命中、未映射的走角色默认素材', () {
    final OverlayStateMapping snapshot = buildOverlayStateMapping(
      character: character(defaultAssetId: 'a-default'),
      renderableAssets: <EmotionAsset>[
        asset(id: 'a-default'),
        asset(id: 'a-social'),
      ],
      mappings: <StateMapping>[
        mapping(state: SystemState.social, assetId: 'a-social'),
      ],
      revision: 2,
    );
    // 有映射的状态用自己的素材。
    expect(snapshot.states[SystemState.social.wireName]?.assetId, 'a-social');
    // 没有映射的状态**不进快照**：它们由 defaultAsset 那一级接管（同一个素材）。
    expect(snapshot.states.containsKey(SystemState.gaming.wireName), isFalse);
    expect(snapshot.defaultAsset?.assetId, 'a-default');
  });

  test('按情绪绑定的映射同样生效（沿用既有 FallbackChain 第 2 级）', () {
    final OverlayStateMapping snapshot = buildOverlayStateMapping(
      character: character(),
      renderableAssets: <EmotionAsset>[
        asset(id: 'a-idle', emotion: 'idle'),
        asset(id: 'a-work', emotion: 'work'),
      ],
      mappings: <StateMapping>[
        mapping(state: SystemState.focused, emotionName: 'work'),
      ],
      revision: 1,
    );
    expect(snapshot.states[SystemState.focused.wireName]?.assetId, 'a-work');
  });

  test('revision 由调用方决定，签名对内容敏感', () {
    OverlayStateMapping build(int revision, String assetId) =>
        buildOverlayStateMapping(
          character: character(),
          renderableAssets: <EmotionAsset>[asset(id: assetId)],
          mappings: const <StateMapping>[],
          revision: revision,
        );

    final OverlayStateMapping first = build(1, 'a-1');
    final OverlayStateMapping sameContent = build(2, 'a-1');
    final OverlayStateMapping changed = build(3, 'a-2');

    // 内容相同 → 签名相同（控制器据此跳过重复下发，rev 不同不影响）。
    expect(first.signature, sameContent.signature);
    expect(first.signature, isNot(changed.signature));
    expect(first.withRevision(9).revision, 9);
    expect(first.withRevision(9).signature, first.signature);
  });

  test('固定种子：同样的库内容每次都得到同一份快照（不会每次推送换图）', () {
    final List<EmotionAsset> assets = <EmotionAsset>[
      asset(id: 'a-1'),
      asset(id: 'a-2'),
      asset(id: 'a-3'),
    ];
    final List<StateMapping> mappings = <StateMapping>[
      mapping(state: SystemState.gaming, assetId: 'a-1'),
      mapping(state: SystemState.gaming, assetId: 'a-2'),
      mapping(state: SystemState.gaming, assetId: 'a-3'),
    ];
    final OverlayStateMapping first = buildOverlayStateMapping(
      character: character(),
      renderableAssets: assets,
      mappings: mappings,
      revision: 1,
    );
    final OverlayStateMapping second = buildOverlayStateMapping(
      character: character(),
      renderableAssets: assets,
      mappings: mappings,
      revision: 2,
      // 显式传同一个种子，等价于默认行为。
      random: Random(0),
    );
    expect(
      first.states[SystemState.gaming.wireName]?.assetId,
      second.states[SystemState.gaming.wireName]?.assetId,
    );
  });
}

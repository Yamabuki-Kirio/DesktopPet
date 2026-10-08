import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:petlife/character/models/emotion_asset.dart';
import 'package:petlife/character/models/enums.dart';
import 'package:petlife/character/models/state_mapping.dart';
import 'package:petlife/core/constants.dart';
import 'package:petlife/state_engine/fallback_chain.dart';
import 'package:petlife/state_engine/state_debouncer.dart';
import 'package:petlife/state_engine/system_state.dart';

EmotionAsset asset({
  required String id,
  required String characterId,
  required String emotion,
  String variant = 'default',
  bool animated = true,
  int frames = 9,
  bool enabled = true,
  ValidationStatus status = ValidationStatus.valid,
}) =>
    EmotionAsset(
      id: id,
      characterId: characterId,
      emotionName: emotion,
      variantName: variant,
      filePath: 'C:/managed/$id.webp',
      originalFilePath: 'C:/user/$id.webp',
      fileHash: 'hash-$id',
      mimeType: 'image/webp',
      fileSize: 3000,
      width: 256,
      height: 192,
      frameCount: frames,
      isAnimated: animated,
      hasAlpha: true,
      enabled: enabled,
      validationStatus: status,
      createdAt: DateTime(2026, 1, 1),
      animationDurationMs: 5000,
    );

StateMapping mapping({
  required String id,
  required String characterId,
  required SystemState state,
  String? emotion,
  String? assetId,
  int weight = 1,
}) =>
    StateMapping(
      id: id,
      characterId: characterId,
      systemState: state,
      emotionName: emotion,
      assetId: assetId,
      weight: weight,
      priority: state.priority,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    );

void main() {
  final DateTime base = DateTime(2026, 9, 27, 12, 0, 0);

  group('优先级与防抖（需求 八）', () {
    const StateDebouncer debouncer = StateDebouncer();

    DebounceDecision decide({
      required SystemState current,
      required StateChangeRequest request,
      Duration currentHold = const Duration(seconds: 60),
      Duration sinceLastChange = const Duration(seconds: 60),
      Duration appStable = const Duration(seconds: 60),
    }) =>
        debouncer.decide(
          currentState: current,
          currentStateStartedAt: base.subtract(currentHold),
          lastAppliedChangeAt: base.subtract(sinceLastChange),
          request: request,
          now: base,
          appStateStableFor: appStable,
        );

    test('manual 状态会挡住一切自动状态', () {
      final DebounceDecision d = decide(
        current: SystemState.manual,
        request: const StateChangeRequest(
          state: SystemState.error,
          trigger: StateTrigger.foregroundApp,
        ),
      );
      expect(d, isA<RejectChange>());
    });

    test('manual 可以自己顶掉自己（用户换一张锁定图）', () {
      final DebounceDecision d = decide(
        current: SystemState.manual,
        request: const StateChangeRequest(
          state: SystemState.manual,
          trigger: StateTrigger.manual,
          manualAssetId: 'a2',
          immediate: true,
        ),
      );
      expect(d, isA<ApplyNow>());
    });

    test('同一状态重复请求被拒绝（避免重启动画）', () {
      final DebounceDecision d = decide(
        current: SystemState.focused,
        request: const StateChangeRequest(
          state: SystemState.focused,
          trigger: StateTrigger.foregroundApp,
        ),
      );
      expect(d, isA<RejectChange>());
    });

    test('前台应用派生状态需要稳定 10 秒', () {
      final DebounceDecision d = decide(
        current: SystemState.defaultState,
        request: const StateChangeRequest(
          state: SystemState.focused,
          trigger: StateTrigger.foregroundApp,
        ),
        appStable: const Duration(seconds: 3),
      );
      expect(d, isA<DeferUntil>());
      expect((d as DeferUntil).reason, contains('10 秒'));
    });

    test('前台应用稳定满 10 秒后放行', () {
      final DebounceDecision d = decide(
        current: SystemState.defaultState,
        request: const StateChangeRequest(
          state: SystemState.focused,
          trigger: StateTrigger.foregroundApp,
        ),
        appStable: const Duration(milliseconds: StateDebounce.foregoundStableMs),
      );
      expect(d, isA<ApplyNow>());
    });

    test('普通状态最短展示 15 秒', () {
      final DebounceDecision d = decide(
        current: SystemState.social,
        request: const StateChangeRequest(
          state: SystemState.entertained,
          trigger: StateTrigger.debugger,
        ),
        currentHold: const Duration(seconds: 5),
      );
      expect(d, isA<DeferUntil>());
      expect((d as DeferUntil).reason, contains('15 秒'));
    });

    test('happy 最短展示 10 秒', () {
      final DebounceDecision d = decide(
        current: SystemState.happy,
        request: const StateChangeRequest(
          state: SystemState.social,
          trigger: StateTrigger.debugger,
        ),
        currentHold: const Duration(seconds: 6),
      );
      expect(d, isA<DeferUntil>());
    });

    test('tired 最短展示 5 分钟', () {
      final DebounceDecision d = decide(
        current: SystemState.tired,
        request: const StateChangeRequest(
          state: SystemState.happy,
          trigger: StateTrigger.debugger,
        ),
        currentHold: const Duration(minutes: 2),
      );
      expect(d, isA<DeferUntil>());
      expect((d as DeferUntil).reason, contains('300 秒'));
    });

    test('tired 满 5 分钟后可被替换', () {
      final DebounceDecision d = decide(
        current: SystemState.tired,
        request: const StateChangeRequest(
          state: SystemState.happy,
          trigger: StateTrigger.debugger,
        ),
        currentHold: const Duration(minutes: 5, seconds: 1),
      );
      expect(d, isA<ApplyNow>());
    });

    test('快速切换抑制窗口对强制模式同样生效（防闪烁）', () {
      final DebounceDecision d = decide(
        current: SystemState.focused,
        request: const StateChangeRequest(
          state: SystemState.error,
          trigger: StateTrigger.debugger,
          force: true,
        ),
        sinceLastChange: const Duration(milliseconds: 100),
      );
      expect(d, isA<DeferUntil>());
      expect((d as DeferUntil).reason, contains('快速切换抑制窗口'));
    });

    test('紧急状态要求跳过「等动画一轮」', () {
      final DebounceDecision d = decide(
        current: SystemState.focused,
        request: const StateChangeRequest(
          state: SystemState.error,
          trigger: StateTrigger.error,
          force: true,
        ),
      );
      expect(d, isA<ApplyNow>());
      expect((d as ApplyNow).waitForAnimationCycle, isFalse);
    });

    test('普通状态要求等待动画播完一轮', () {
      final DebounceDecision d = decide(
        current: SystemState.defaultState,
        request: const StateChangeRequest(
          state: SystemState.happy,
          trigger: StateTrigger.debugger,
          force: true,
        ),
      );
      expect(d, isA<ApplyNow>());
      expect((d as ApplyNow).waitForAnimationCycle, isTrue);
    });

    test('强制模式可以穿透最短展示时长（调试器需要触发全部状态）', () {
      final DebounceDecision d = decide(
        current: SystemState.error,
        request: const StateChangeRequest(
          state: SystemState.defaultState,
          trigger: StateTrigger.debugger,
          force: true,
        ),
        currentHold: const Duration(seconds: 1),
      );
      expect(d, isA<ApplyNow>());
    });

    test('优先级数值符合需求定义', () {
      expect(SystemState.error.priority, 100);
      expect(SystemState.manual.priority, 95);
      expect(SystemState.concerned.priority, 90);
      expect(SystemState.tired.priority, 80);
      expect(SystemState.happy.priority, 70);
      expect(SystemState.gaming.priority, 60);
      expect(SystemState.focused.priority, 50);
      expect(SystemState.social.priority, 40);
      expect(SystemState.entertained.priority, 30);
      expect(SystemState.away.priority, 20);
      expect(SystemState.defaultState.priority, 0);
    });
  });

  group('回退链（需求 七）', () {
    final List<EmotionAsset> assets = <EmotionAsset>[
      asset(id: 'a1', characterId: 'c1', emotion: 'Cheerful', variant: '1'),
      asset(id: 'a2', characterId: 'c1', emotion: 'Thinking'),
      asset(id: 'a3', characterId: 'c1', emotion: 'Worried'),
      asset(id: 'a4', characterId: 'c1', emotion: 'Broken', status: ValidationStatus.invalid),
      asset(id: 'a5', characterId: 'c1', emotion: 'Disabled', enabled: false),
    ];
    final List<EmotionAsset> renderable =
        assets.where((EmotionAsset a) => a.isRenderable).toList();

    test('第 1 级：命中状态指定图片', () {
      final FallbackChain chain = FallbackChain(random: Random(1));
      final AssetResolution r = chain.resolve(
        state: SystemState.happy,
        renderableAssets: renderable,
        mappingsForState: <StateMapping>[
          mapping(id: 'm1', characterId: 'c1', state: SystemState.happy, assetId: 'a3'),
        ],
        characterDefaultAssetId: 'a1',
      );
      expect(r.level, FallbackLevel.stateAsset);
      expect(r.asset!.id, 'a3');
    });

    test('第 2 级：命中状态指定情绪', () {
      final FallbackChain chain = FallbackChain(random: Random(1));
      final AssetResolution r = chain.resolve(
        state: SystemState.focused,
        renderableAssets: renderable,
        mappingsForState: <StateMapping>[
          mapping(id: 'm1', characterId: 'c1', state: SystemState.focused, emotion: 'Thinking'),
        ],
        characterDefaultAssetId: 'a1',
      );
      expect(r.level, FallbackLevel.stateEmotion);
      expect(r.asset!.id, 'a2');
    });

    test('第 3 级：回退到角色默认图片', () {
      final FallbackChain chain = FallbackChain(random: Random(1));
      final AssetResolution r = chain.resolve(
        state: SystemState.away,
        renderableAssets: renderable,
        mappingsForState: const <StateMapping>[],
        characterDefaultAssetId: 'a3',
      );
      expect(r.level, FallbackLevel.characterDefault);
      expect(r.asset!.id, 'a3');
    });

    test('第 4 级：回退到第一个有效素材', () {
      final FallbackChain chain = FallbackChain(random: Random(1));
      final AssetResolution r = chain.resolve(
        state: SystemState.away,
        renderableAssets: renderable,
        mappingsForState: const <StateMapping>[],
        characterDefaultAssetId: null,
      );
      expect(r.level, FallbackLevel.firstValidAsset);
      expect(r.asset!.id, 'a1');
    });

    test('第 5 级：没有任何可用素材时使用内置占位图', () {
      final FallbackChain chain = FallbackChain(random: Random(1));
      final AssetResolution r = chain.resolve(
        state: SystemState.away,
        renderableAssets: const <EmotionAsset>[],
        mappingsForState: const <StateMapping>[],
        characterDefaultAssetId: null,
      );
      expect(r.level, FallbackLevel.builtinPlaceholder);
      expect(r.asset, isNull);
      expect(r.isPlaceholder, isTrue);
    });

    test('映射指向已删除的素材时静默跳过，继续回退', () {
      final FallbackChain chain = FallbackChain(random: Random(1));
      final AssetResolution r = chain.resolve(
        state: SystemState.happy,
        renderableAssets: renderable,
        mappingsForState: <StateMapping>[
          mapping(id: 'm1', characterId: 'c1', state: SystemState.happy, assetId: 'deleted-id'),
        ],
        characterDefaultAssetId: 'a2',
      );
      expect(r.level, FallbackLevel.characterDefault);
      expect(r.asset!.id, 'a2');
    });

    test('manual 指定图片优先于任何映射', () {
      final FallbackChain chain = FallbackChain(random: Random(1));
      final AssetResolution r = chain.resolve(
        state: SystemState.manual,
        renderableAssets: renderable,
        mappingsForState: <StateMapping>[
          mapping(id: 'm1', characterId: 'c1', state: SystemState.manual, assetId: 'a1'),
        ],
        characterDefaultAssetId: 'a1',
        manualAssetId: 'a3',
      );
      expect(r.level, FallbackLevel.stateAsset);
      expect(r.asset!.id, 'a3');
    });

    test('多候选按权重可被选中（权重大的更容易命中）', () {
      // 固定种子，统计 400 次结果分布。
      final FallbackChain chain = FallbackChain(random: Random(42));
      int heavy = 0;
      for (int i = 0; i < 400; i++) {
        final AssetResolution r = chain.resolve(
          state: SystemState.happy,
          renderableAssets: renderable,
          mappingsForState: <StateMapping>[
            mapping(
                id: 'm1',
                characterId: 'c1',
                state: SystemState.happy,
                emotion: 'Cheerful',
                weight: 9),
            mapping(
                id: 'm2', characterId: 'c1', state: SystemState.happy, emotion: 'Worried', weight: 1),
          ],
          characterDefaultAssetId: null,
        );
        if (r.asset!.emotionName == 'Cheerful') heavy++;
      }
      expect(heavy, greaterThan(250), reason: '权重 9:1 时高权重项应明显占多数');
    });
  });
}

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:petlife/activity_tracking/android_usage_session.dart';
import 'package:petlife/activity_tracking/current_activity_provider.dart';
import 'package:petlife/character/models/character_model.dart';
import 'package:petlife/character/models/emotion_asset.dart';
import 'package:petlife/character/models/enums.dart';
import 'package:petlife/platform/overlay_pet.dart';
import 'package:petlife/platform/overlay_state_mapping.dart';
import 'package:petlife/state_engine/fallback_chain.dart';
import 'package:petlife/state_engine/state_snapshot.dart';
import 'package:petlife/state_engine/system_state.dart';
import 'package:petlife/ui/overlay_pet_controller.dart';

/// Phase 4C-2：状态引擎 → 原生悬浮窗的素材下发。
///
/// 这些用例全部是**纯 Dart**：不需要 Android、不需要 MethodChannel，
/// 只需要一个记录调用的假 [AndroidOverlayPet]。
/// 真实解码（PNG/JPG/WebP）由原生单测与真机验收覆盖，见 docs/35。
void main() {
  late Directory root;
  late FakeOverlayPet overlay;
  late ValueNotifier<StateSnapshot> snapshots;
  late OverlayPetController controller;

  setUp(() {
    root = Directory.systemTemp.createTempSync('petlife_overlay_ctrl');
    overlay = FakeOverlayPet();
    snapshots = ValueNotifier<StateSnapshot>(StateSnapshot.initial());
    controller = OverlayPetController(
      overlay: overlay,
      snapshots: snapshots,
      privateAssetsRoot: () => root.path,
      // 测试里不真的等原生解码
      delay: (Duration _) async {},
    );
  });

  tearDown(() async {
    controller.dispose();
    snapshots.dispose();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  /// 在临时私有目录里造一张真实存在的素材文件。
  String assetFile(String name) {
    final File file = File(p.join(root.path, 'packA', 'Maya', name));
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(<int>[0x89, 0x50, 0x4E, 0x47]);
    return file.path;
  }

  EmotionAsset buildAsset({
    String id = 'asset-1',
    String emotion = 'idle',
    String variant = 'a',
    String mimeType = 'image/png',
    bool isAnimated = false,
    int frameCount = 0,
    int animationDurationMs = 0,
    String? filePath,
  }) =>
      EmotionAsset(
        id: id,
        characterId: 'char-1',
        emotionName: emotion,
        variantName: variant,
        filePath: filePath ?? assetFile('$emotion.$variant.png'),
        fileHash: 'hash-$id',
        mimeType: mimeType,
        fileSize: 4,
        width: 64,
        height: 64,
        frameCount: frameCount,
        isAnimated: isAnimated,
        hasAlpha: true,
        enabled: true,
        validationStatus: ValidationStatus.valid,
        createdAt: DateTime(2026, 9, 29),
        animationDurationMs: animationDurationMs,
      );

  CharacterModel buildCharacter({String id = 'char-1', String name = 'Maya'}) =>
      CharacterModel(
        id: id,
        packId: 'pack-1',
        ownerId: 'local.default',
        internalName: name,
        displayName: name,
        enabled: true,
        createdAt: DateTime(2026, 9, 29),
        updatedAt: DateTime(2026, 9, 29),
      );

  StateSnapshot snapshotWith({
    CharacterModel? character,
    EmotionAsset? asset,
    String? manualAssetId,
    String reason = '测试',
  }) =>
      StateSnapshot(
        state: manualAssetId == null ? SystemState.defaultState : SystemState.manual,
        trigger: manualAssetId == null ? StateTrigger.foregroundApp : StateTrigger.manual,
        reason: reason,
        startedAt: DateTime(2026, 9, 29, 10),
        currentCharacter: character,
        resolution: AssetResolution(
          asset: asset,
          level: FallbackLevel.stateEmotion,
          reason: reason,
        ),
        nextAllowedChangeAt: null,
        lastDecisionNote: '',
        manualAssetId: manualAssetId,
      );

  group('素材下发', () {
    test('1. 按 snapshot 生成正确配置并下发', () async {
      overlay.running = true;
      final EmotionAsset asset = buildAsset(
        id: 'asset-1',
        emotion: 'idle',
        variant: 'a',
      );
      controller.attach();
      await pumpEventQueue();

      snapshots.value = snapshotWith(character: buildCharacter(), asset: asset);
      await pumpEventQueue();

      expect(overlay.calls, contains('updatePet'));
      final OverlayPetConfig config = overlay.pushedConfigs.last;
      expect(config.characterId, 'char-1');
      expect(config.assetId, 'asset-1');
      expect(config.filePath, asset.filePath);
      expect(config.mimeType, 'image/png');
      expect(config.isAnimated, isFalse);
      expect(config.schemaVersion, 1);
    });

    test('2. 相同素材不重复更新（哪怕状态引擎又发了一次快照）', () async {
      overlay.running = true;
      final EmotionAsset asset = buildAsset();
      controller.attach();
      await pumpEventQueue();

      snapshots.value = snapshotWith(character: buildCharacter(), asset: asset);
      await pumpEventQueue();
      expect(overlay.pushedConfigs, hasLength(1));

      // 同角色 + 同素材，只是状态/原因变了：不得再次下发。
      snapshots.value = snapshotWith(
        character: buildCharacter(),
        asset: asset,
        reason: '状态切换：思考',
      );
      await pumpEventQueue();

      expect(overlay.pushedConfigs, hasLength(1), reason: '相同素材不得重复解码');
    });

    test('3. 角色变化触发更新', () async {
      overlay.running = true;
      final EmotionAsset first = buildAsset(id: 'asset-maya', emotion: 'idle');
      controller.attach();
      await pumpEventQueue();

      snapshots.value = snapshotWith(
        character: buildCharacter(id: 'char-1', name: 'Maya'),
        asset: first,
      );
      await pumpEventQueue();

      final EmotionAsset second =
          buildAsset(id: 'asset-ace', emotion: 'idle', variant: 'b');
      snapshots.value = snapshotWith(
        character: buildCharacter(id: 'char-2', name: 'Ace'),
        asset: second,
      );
      await pumpEventQueue();

      expect(overlay.pushedConfigs.map((OverlayPetConfig c) => c.characterId),
          <String>['char-1', 'char-2']);
      expect(overlay.pushedConfigs.last.assetId, 'asset-ace');
    });

    test('4. 素材变化触发更新（同一角色换图）', () async {
      overlay.running = true;
      controller.attach();
      await pumpEventQueue();

      snapshots.value = snapshotWith(
        character: buildCharacter(),
        asset: buildAsset(id: 'asset-1', emotion: 'idle'),
      );
      await pumpEventQueue();
      snapshots.value = snapshotWith(
        character: buildCharacter(),
        asset: buildAsset(id: 'asset-2', emotion: 'happy'),
      );
      await pumpEventQueue();

      expect(overlay.pushedConfigs.map((OverlayPetConfig c) => c.assetId),
          <String>['asset-1', 'asset-2']);
    });

    test('5. 当前素材为空时不发送任何配置（不产生非法配置）', () async {
      overlay.running = true;
      controller.attach();
      await pumpEventQueue();

      snapshots.value = snapshotWith(character: buildCharacter(), asset: null);
      await pumpEventQueue();

      expect(overlay.pushedConfigs, isEmpty);
      expect(overlay.calls, isNot(contains('updatePet')));
    });

    test('6. 文件已被删除时不发送，并记录可读原因（保留原图由原生负责）', () async {
      overlay.running = true;
      controller.attach();
      await pumpEventQueue();

      final String missing = p.join(root.path, 'packA', 'Maya', 'deleted.png');
      snapshots.value = snapshotWith(
        character: buildCharacter(),
        asset: buildAsset(id: 'asset-gone', filePath: missing),
      );
      await pumpEventQueue();

      expect(overlay.pushedConfigs, isEmpty, reason: '文件已不存在，不得把坏路径送给原生');
      expect(controller.lastError, contains('素材文件不存在'));
    });

    test('6b. 素材被删除后状态引擎回退到另一张：直接下发回退结果', () async {
      overlay.running = true;
      controller.attach();
      await pumpEventQueue();

      snapshots.value = snapshotWith(
        character: buildCharacter(),
        asset: buildAsset(id: 'asset-1', emotion: 'idle'),
      );
      await pumpEventQueue();

      // 回退链命中「角色默认图片」
      final EmotionAsset fallback = buildAsset(id: 'asset-default', emotion: 'default');
      snapshots.value = snapshotWith(character: buildCharacter(), asset: fallback);
      await pumpEventQueue();

      expect(overlay.pushedConfigs.last.assetId, 'asset-default');
    });

    test('7. 手动（固定）素材模式下发的是被锁定的那张', () async {
      overlay.running = true;
      final EmotionAsset manual =
          buildAsset(id: 'asset-manual', emotion: 'special', variant: 'c');
      controller.attach();
      await pumpEventQueue();

      snapshots.value = snapshotWith(
        character: buildCharacter(),
        asset: manual,
        manualAssetId: 'asset-manual',
      );
      await pumpEventQueue();

      final OverlayPetConfig config = overlay.pushedConfigs.single;
      expect(config.assetId, 'asset-manual');
      expect(config.filePath, manual.filePath);
    });

    test('动态素材把动画参数一并下发，状态里带上 4C-4 播放口径', () async {
      overlay.running = true;
      final EmotionAsset animated = buildAsset(
        id: 'asset-anim',
        emotion: 'idle',
        mimeType: 'image/webp',
        isAnimated: true,
        frameCount: 12,
        animationDurationMs: 1200,
        filePath: assetFile('idle.webp'),
      );
      controller.attach();
      await pumpEventQueue();

      snapshots.value = snapshotWith(character: buildCharacter(), asset: animated);
      await pumpEventQueue();

      final OverlayPetConfig config = overlay.pushedConfigs.single;
      expect(config.isAnimated, isTrue);
      expect(config.frameCount, 12);
      expect(config.animationDurationMs, 1200);
      // 原生返回的状态里必须携带 4C-4 的动画口径（这里假件模拟 API 28+ 真机）。
      final OverlayRuntimeState state = controller.state!;
      expect(state.visualType, 'animated');
      expect(state.animationFrameMode, 'full-animation');
      expect(state.animationSupported, isTrue);
      expect(state.animationPlaying, isTrue);
      expect(state.animatedFirstFrameOnly, isFalse);
      expect(state.animationStateLabelZh,
          OverlayRuntimeState.animatedPlayingText);
      expect(state.visualTypeLabelZh, '动态 WebP');
    });

    test('服务未运行时不下发，等显示时随 start 一起带过去', () async {
      overlay.running = false;
      controller.attach();
      await pumpEventQueue();

      snapshots.value = snapshotWith(
        character: buildCharacter(),
        asset: buildAsset(id: 'asset-1'),
      );
      await pumpEventQueue();
      expect(overlay.calls, isNot(contains('updatePet')));

      await controller.show();
      expect(overlay.calls, contains('start'));
      expect(overlay.pushedConfigs.single.assetId, 'asset-1');
    });
  });

  group('状态反馈', () {
    test('正在加载中与已显示能被区分（showsExpectedAsset）', () async {
      overlay.running = true;
      overlay.displayedAssetId = null;
      overlay.isPlaceholder = true;
      controller.attach();
      await pumpEventQueue();

      final EmotionAsset asset = buildAsset(id: 'asset-1');
      snapshots.value = snapshotWith(character: buildCharacter(), asset: asset);
      await pumpEventQueue();

      // 假实现会在 updatePet 里立刻把 displayedAssetId 设为配置里的 assetId
      expect(controller.state!.showsExpectedAsset, isTrue);

      overlay.isPlaceholder = true;
      overlay.displayedAssetId = null;
      await controller.refresh();
      expect(controller.state!.showsExpectedAsset, isFalse);
    });

    test('原生报上来的加载失败会出现在控制器状态里', () async {
      overlay.running = true;
      overlay.lastLoadError = 'decode_failed: 图片解码失败';
      controller.attach();
      await pumpEventQueue();

      expect(controller.state!.lastLoadError, 'decode_failed: 图片解码失败');
      expect(controller.lastError, contains('decode_failed'));
    });

    test('当前素材显示名用于设置页展示', () async {
      controller.attach();
      await pumpEventQueue();
      snapshots.value = snapshotWith(
        character: buildCharacter(name: 'Maya'),
        asset: buildAsset(id: 'asset-1', emotion: 'idle', variant: 'a'),
      );
      await pumpEventQueue();

      expect(controller.currentAssetLabel, 'Maya / idle / a');
    });
  });

  group('窗口诊断（4C-2 真机缺陷回归）', () {
    test('服务在运行但窗口未挂载时可以被检测出来', () async {
      overlay.running = true;
      overlay.windowAttachedOverride = false;
      overlay.lastWindowError = 'addView 失败：permission denied';

      controller.attach();
      await pumpEventQueue();

      final OverlayRuntimeState state = controller.state!;
      expect(state.serviceRunning, isTrue);
      expect(state.windowAttached, isFalse);
      expect(state.windowMissing, isTrue, reason: '必须能区分"服务在跑"和"窗口挂上了"');
      expect(state.windowSummary, '未挂载');
      expect(state.lastWindowError, contains('addView 失败'));
    });

    test('窗口已挂载但尺寸为 0 时可以被检测出来', () async {
      overlay.running = true;
      overlay.viewWidth = 0;
      overlay.viewHeight = 0;

      controller.attach();
      await pumpEventQueue();

      final OverlayRuntimeState state = controller.state!;
      expect(state.hasZeroSizedWindow, isTrue);
      expect(state.windowSummary, '已挂载但尺寸为 0');
    });

    test('窗口正常时诊断摘要给出真实尺寸', () async {
      overlay.running = true;
      overlay.viewWidth = 288;
      overlay.viewHeight = 288;

      controller.attach();
      await pumpEventQueue();

      final OverlayRuntimeState state = controller.state!;
      expect(state.windowMissing, isFalse);
      expect(state.hasZeroSizedWindow, isFalse);
      expect(state.windowSummary, '已挂载 288×288');
      expect(state.windowVisible, isTrue);
    });

    test('隐藏时不算"窗口缺失"（隐藏是用户意图）', () async {
      overlay.running = true;
      overlay.hidden = true;

      controller.attach();
      await pumpEventQueue();

      final OverlayRuntimeState state = controller.state!;
      expect(state.hidden, isTrue);
      expect(state.windowMissing, isFalse);
      expect(state.windowSummary, '已隐藏');
    });

    test('窗口已挂载但根 View 尚未附着时能被识别', () async {
      overlay.running = true;
      overlay.attachedToWindow = false;

      controller.attach();
      await pumpEventQueue();

      final OverlayRuntimeState state = controller.state!;
      expect(state.windowNotAttached, isTrue, reason: 'addView 未真正生效必须看得出来');
      expect(state.windowMissing, isFalse);
      expect(state.lastWindowAction, isNotEmpty);
    });

    test('诊断模式开关走通道，并且不依赖任何素材', () async {
      overlay.running = true;
      controller.attach();
      await pumpEventQueue();

      final OverlayRuntimeState on = await controller.setDebugOverlay(true);
      expect(overlay.calls, contains('setDebugOverlay:true'));
      expect(on.debugOverlayMode, isTrue);
      expect(on.visual, 'debug');
      expect(controller.state!.debugOverlayMode, isTrue);

      final OverlayRuntimeState off = await controller.setDebugOverlay(false);
      expect(overlay.calls, contains('setDebugOverlay:false'));
      expect(off.debugOverlayMode, isFalse);
    });
  });

  group('8. 非 Android 平台不调用 MethodChannel', () {
    test('UnsupportedOverlayPet：只报"不支持"，写操作抛错而不是假装成功', () async {
      final OverlayPetController windowsController = OverlayPetController(
        overlay: const UnsupportedOverlayPet(),
        snapshots: snapshots,
        privateAssetsRoot: () => root.path,
        delay: (Duration _) async {},
      );
      addTearDown(windowsController.dispose);

      windowsController.attach();
      await pumpEventQueue();

      snapshots.value = snapshotWith(
        character: buildCharacter(),
        asset: buildAsset(id: 'asset-1'),
      );
      await pumpEventQueue();

      // 读操作给出"不支持"的事实（界面据此隐藏整个分区），不抛错、不刷错误。
      expect(windowsController.state, isNotNull);
      expect(windowsController.state!.supported, isFalse);
      expect(windowsController.state!.serviceRunning, isFalse);
      expect(windowsController.lastError, isNull);

      // 写操作必须明确失败，不能静默"看起来成功"。
      await expectLater(
        windowsController.show(),
        throwsA(isA<OverlayUnsupportedException>()),
      );
      expect(windowsController.lastError, contains('不支持'));
    });
  });

  group('大小调整（4C-3A 滑块）', () {
    test('setScale 只改大小，其余开关按当前状态原样回传（不被重置）', () async {
      await controller.refresh();
      // 用户此前关掉了自动吸附
      overlay.snapEnabled = false;
      overlay.scale = 1.0;
      await controller.refresh();

      await controller.setScale(1.5);

      expect(overlay.calls, contains('updateSettings'));
      expect(overlay.scale, 1.5);
      expect(overlay.snapEnabled, isFalse,
          reason: '调大小不能顺手把用户的吸附开关重置成默认值');
      expect(controller.state?.scale, 1.5);
    });

    test('resetScale 回到 100%', () async {
      await controller.refresh();
      await controller.setScale(2.0);
      expect(overlay.scale, 2.0);

      await controller.resetScale();
      expect(overlay.scale, OverlayPetConfig.defaultScale);
    });

    test('previewScale 失败只记日志，不抛给界面（拖动中间态不打扰用户）', () async {
      overlay.failUpdateSettings = true;
      // 不抛异常就是通过
      await controller.previewScale(1.2);
      expect(controller.state?.scale, isNot(1.2));
    });

    test('setScale 失败会向上抛错（最终一次提交必须让用户知道）', () async {
      overlay.failUpdateSettings = true;
      await expectLater(
        controller.setScale(1.2),
        throwsA(isA<OverlayPlatformException>()),
      );
      expect(controller.lastError, contains('写入设置失败'));
    });
  });

  group('状态映射下发与手动覆盖（4C-5）', () {
    late OverlayPetController mappingController;
    late List<StateSnapshot> loaderCalls;
    late List<int> loaderRevisions;

    OverlayStateMapping builtMapping(int revision) => OverlayStateMapping(
          revision: revision,
          characterId: 'char-1',
          defaultAsset: const OverlayStateAsset(
            assetId: 'asset-default',
            path: '/tmp/default.png',
            isAnimated: false,
          ),
          states: const <String, OverlayStateAsset>{
            'social': OverlayStateAsset(
              assetId: 'asset-social',
              path: '/tmp/social.png',
              isAnimated: false,
            ),
          },
        );

    setUp(() {
      loaderCalls = <StateSnapshot>[];
      loaderRevisions = <int>[];
      mappingController = OverlayPetController(
        overlay: overlay,
        snapshots: snapshots,
        privateAssetsRoot: () => root.path,
        delay: (Duration _) async {},
        stateMappingLoader: (StateSnapshot snapshot, int revision) async {
          loaderCalls.add(snapshot);
          loaderRevisions.add(revision);
          return builtMapping(revision);
        },
      );
    });

    tearDown(() {
      mappingController.dispose();
    });

    test('服务运行时下发映射，并带上单调递增的 revision', () async {
      overlay.running = true;
      await mappingController.refresh();

      await mappingController.syncStateMapping();
      await mappingController.syncStateMapping();

      // 内容没变 → 第二次是空操作（不重复推送）。
      expect(overlay.pushedMappings, hasLength(1));
      expect(overlay.pushedMappings.single.characterId, 'char-1');
      expect(overlay.pushedMappings.single.revision, 1);
      expect(loaderRevisions, <int>[1, 2]);
      expect(overlay.calls, contains('updateStateMapping'));
    });

    test('revision 从原生已生效版本续上（应用重启后不会被当成旧版本拒绝）', () async {
      overlay.running = true;
      overlay.diagnostics = OverlayStateDiagnostics(
        stateId: 'social',
        mappingRevision: 41,
      );
      await mappingController.refresh();

      await mappingController.syncStateMapping();

      expect(overlay.pushedMappings.single.revision, 42);
    });

    test('服务未运行时只记录不下发（等显示时随 start 带过去）', () async {
      overlay.running = false;
      await mappingController.refresh();

      await mappingController.syncStateMapping();

      expect(overlay.pushedMappings, isEmpty);
      expect(loaderCalls, isEmpty);
    });

    test('没有注入 loader 时（非 Android 装配）完全不下发', () async {
      overlay.running = true;
      await controller.refresh();
      await controller.syncStateMapping();
      expect(overlay.pushedMappings, isEmpty);
    });

    test('stop 之后再次同步会重新下发（去重签名被清空）', () async {
      overlay.running = true;
      await mappingController.refresh();
      await mappingController.syncStateMapping();
      expect(overlay.pushedMappings, hasLength(1));

      overlay.running = false;
      await mappingController.stop();

      overlay.running = true;
      await mappingController.refresh();
      await mappingController.syncStateMapping();
      expect(overlay.pushedMappings, hasLength(2));
    });

    test('手动覆盖：下发状态 ID 并给出提示文案', () async {
      overlay.running = true;
      await mappingController.refresh();

      await mappingController.setManualState(SystemState.concerned.wireName);

      expect(overlay.manualState, 'concerned');
      expect(mappingController.hasManualStateOverride, isTrue);
      expect(mappingController.lastNotice, contains('手动覆盖'));
      expect(mappingController.lastNotice, contains('担忧'));
    });

    test('恢复自动：清掉覆盖并提示已恢复', () async {
      overlay.running = true;
      await mappingController.refresh();
      await mappingController.setManualState(SystemState.gaming.wireName);

      await mappingController.setManualState(null);

      expect(overlay.manualState, isNull);
      expect(mappingController.hasManualStateOverride, isFalse);
      expect(mappingController.lastNotice, contains('恢复自动'));
    });

    test('未知状态 ID 由控制器兜底为"默认"文案，不抛错', () async {
      overlay.running = true;
      await mappingController.refresh();
      // SystemState.fromWire 对未知值回退 defaultState，因此文案是"默认"。
      await mappingController.setManualState('not-a-state');
      expect(mappingController.lastNotice, contains('默认'));
    });

    test('打开使用情况访问设置页转发到原生', () async {
      await mappingController.openUsageAccessSettings();
      expect(overlay.calls, contains('openUsageAccessSettings'));
    });

    // --- Phase 4C-6A.1：临时预览（§16.4）---
    // 预览与"编辑映射"、"手动覆盖"是三件不同的事，控制器必须原样转发、不做合并。

    test('开始预览：转发到原生，并把 displayMode=preview 如实暴露出来', () async {
      overlay.running = true;

      await mappingController.previewState(SystemState.focused.wireName);

      expect(overlay.calls, contains('previewState'));
      expect(overlay.previewedStateId, 'focused');
      expect(mappingController.stateDiagnostics.isPreviewing, isTrue);
      expect(mappingController.stateDiagnostics.previewState, 'focused');
      expect(mappingController.stateDiagnostics.displayModeZh, contains('临时预览'));
    });

    test('预览另一个状态会替换上一个', () async {
      overlay.running = true;
      await mappingController.previewState(SystemState.focused.wireName);
      await mappingController.previewState(SystemState.social.wireName);

      expect(overlay.previewedStateId, 'social');
      expect(mappingController.stateDiagnostics.previewState, 'social');
    });

    test('结束预览：转发到原生，并回到自动模式', () async {
      overlay.running = true;
      await mappingController.previewState(SystemState.gaming.wireName);

      await mappingController.clearPreview();

      expect(overlay.calls, contains('clearPreview'));
      expect(overlay.previewedStateId, isNull);
      expect(mappingController.stateDiagnostics.isPreviewing, isFalse);
    });

    test('预览不会写入手动覆盖（两者必须分开）', () async {
      overlay.running = true;

      await mappingController.previewState(SystemState.entertained.wireName);

      expect(overlay.manualState, isNull, reason: '预览不得写 manual-debug 覆盖');
      expect(mappingController.hasManualStateOverride, isFalse);
    });

    test('预览不会重新下发状态映射（预览只换画面，不改映射表）', () async {
      overlay.running = true;
      await mappingController.syncStateMapping();
      final int pushedBefore = overlay.pushedMappings.length;

      await mappingController.previewState(SystemState.focused.wireName);

      expect(overlay.pushedMappings.length, pushedBefore,
          reason: '预览不得触发映射重新下发');
    });
  });

  // ---------------------------------------------------------------------------
  // Phase 4C-6B-1：轮盘主题
  // ---------------------------------------------------------------------------

  group('轮盘主题（4C-6B-1）', () {
    OverlayMenuThemeState themeState({
      String themeId = 'p3p-pink',
      int revision = 3,
      String customPrimary = '#F24D96',
      bool legible = true,
    }) =>
        OverlayMenuThemeState.fromMap(<String, Object?>{
          'themeId': themeId,
          'displayName': 'P3P 粉色',
          'revision': revision,
          'customPrimary': customPrimary,
          'legible': legible,
          'contrast': 3.37,
          'current': <String, Object?>{
            'primary': '#F24D96',
            'secondary': '#FF8ABA',
            'background': '#FFD8E9',
            'highlight': '#FFD42A',
            'outline': '#111111',
            'text': '#FFFFFF',
            'disabled': '#8E7180',
            'gradientEnabled': true,
          },
          'presets': <Object?>[
            <String, Object?>{
              'themeId': 'p3p-pink',
              'displayName': 'P3P 粉色',
              'colors': <String, Object?>{'primary': '#F24D96'},
            },
            <String, Object?>{
              'themeId': 'blue',
              'displayName': '蓝色',
              'colors': <String, Object?>{'primary': '#2F7CF6'},
            },
          ],
          'menuDistanceRatio': 0.42,
          'hapticsEnabled': true,
          'soundEnabled': false,
          'swipeEnabled': true,
          'swipeSensitivity': 1,
        });

    test('解析原生主题状态：当前色板与预设列表', () {
      final OverlayMenuThemeState state = themeState();

      expect(state.themeId, 'p3p-pink');
      expect(state.revision, 3);
      expect(state.customPrimary, '#F24D96');
      expect(state.current.primary, '#F24D96');
      expect(state.current.text, '#FFFFFF');
      expect(state.current.gradientEnabled, isTrue);
      expect(state.presets.map((OverlayMenuThemePreset p) => p.themeId),
          <String>['p3p-pink', 'blue']);
      expect(state.presets.last.displayName, '蓝色');
      expect(state.legible, isTrue);
    });

    test('色板缺字段时退回黑色而不是抛错', () {
      final OverlayMenuPalette palette =
          OverlayMenuPalette.fromMap(<String, Object?>{'primary': '#123456'});

      expect(palette.primary, '#123456');
      expect(palette.text, '#000000');
      expect(palette.gradientEnabled, isTrue);
    });

    test('refreshMenuTheme 读取原生并保留 revision 供下次续接', () async {
      overlay.menuThemeState = themeState(revision: 9);

      final OverlayMenuThemeState state = await controller.refreshMenuTheme();

      expect(state.revision, 9);
      expect(controller.menuThemeState.revision, 9);
      expect(controller.menuThemeNextRevision, 10);
      expect(overlay.calls, contains('menuTheme'));
    });

    test('selectMenuTheme 用 revision+1 下发，并采用原生回报的状态', () async {
      overlay.menuThemeState = themeState(revision: 4);
      overlay.menuThemeUpdate = OverlayMenuThemeUpdate(
        accepted: true,
        state: themeState(themeId: 'blue', revision: 5),
      );
      await controller.refreshMenuTheme();

      final bool accepted =
          await controller.selectMenuTheme(themeId: 'blue');

      expect(accepted, isTrue);
      expect(overlay.calls, contains('setMenuTheme:blue@5'));
      expect(controller.menuThemeState.themeId, 'blue');
      expect(controller.menuThemeState.revision, 5);
      expect(controller.lastNotice, contains('轮盘主题已更新'));
    });

    test('自定义主色按 custom 主题下发', () async {
      overlay.menuThemeState = themeState(revision: 1);
      await controller.refreshMenuTheme();
      overlay.menuThemeUpdate = OverlayMenuThemeUpdate(
        accepted: true,
        state: themeState(themeId: 'custom', revision: 2),
      );

      await controller.selectMenuTheme(
        themeId: OverlayMenuThemeState.customThemeId,
        customPrimary: 0xFF112233,
      );

      expect(overlay.calls, contains('setMenuTheme:custom@2'));
    });

    test('被原生拒绝（旧 revision）时不谎报成功，并给出中文原因', () async {
      overlay.menuThemeState = themeState(revision: 7);
      await controller.refreshMenuTheme();
      overlay.menuThemeUpdate =
          const OverlayMenuThemeUpdate(accepted: false, errorCode: 'stale_revision');

      final bool accepted =
          await controller.selectMenuTheme(themeId: 'green');

      expect(accepted, isFalse);
      expect(controller.lastError, contains('更新的主题配置'));
    });

    test('读取失败只记错误，不抛出（界面仍能显示上次的颜色）', () async {
      overlay.failMenuTheme = true;

      await controller.refreshMenuTheme();

      expect(controller.menuThemeState.themeId,
          OverlayMenuThemeState.unsupported.themeId);
      expect(controller.lastError, isNotNull);
    });
  });
}

/// 记录调用的假实现：不碰任何通道。
class FakeOverlayPet implements AndroidOverlayPet {
  final List<String> calls = <String>[];
  final List<OverlayPetConfig> pushedConfigs = <OverlayPetConfig>[];

  // --- Phase 4C-5：状态联动 ---
  final List<OverlayStateMapping> pushedMappings = <OverlayStateMapping>[];
  OverlayStateDiagnostics diagnostics = OverlayStateDiagnostics.unavailable;
  String? manualState;

  bool running = false;
  bool hidden = false;
  String? displayedAssetId;
  bool isPlaceholder = true;
  bool animatedFirstFrameOnly = false;

  // --- Phase 4C-4：视觉与动画（假件按"API 28+ 真机"行为：动态素材完整播放）---
  String visualType = 'placeholder';
  String animationFrameMode = 'not-applicable';
  bool animationSupported = false;
  bool animationPlaying = false;
  String? animationPausedReason;
  String? decodeCode;

  String? lastLoadError;
  DateTime? lastUpdatedAt;
  bool overlayGranted = true;
  bool notificationsGranted = true;
  bool notificationsRequired = false;
  double scale = OverlayPetConfig.defaultScale;
  bool snapEnabled = true;

  /// 让 updateSettings 抛错（验证"滑块预览失败不打扰用户"）。
  bool failUpdateSettings = false;

  // --- 窗口诊断（4C-2 真机缺陷后新增）---
  bool windowAttachedOverride = true;
  bool windowVisible = true;
  bool attachedToWindow = true;
  int viewWidth = 240;
  int viewHeight = 240;
  int imageWidth = 240;
  int imageHeight = 240;
  String? lastWindowError;
  String lastWindowAction = 'addView(ok)';
  String visual = 'empty';
  bool debugOverlayMode = false;

  OverlayRuntimeState buildState() => OverlayRuntimeState(
        supported: true,
        serviceRunning: running,
        windowAttached: running && !hidden && windowAttachedOverride,
        enabled: running,
        hidden: hidden,
        overlayGranted: overlayGranted,
        notificationsGranted: notificationsGranted,
        characterId: pushedConfigs.isEmpty ? null : pushedConfigs.last.characterId,
        assetId: pushedConfigs.isEmpty ? null : pushedConfigs.last.assetId,
        mimeType: pushedConfigs.isEmpty ? null : pushedConfigs.last.mimeType,
        isAnimated: pushedConfigs.isEmpty ? false : pushedConfigs.last.isAnimated,
        scale: scale,
        snapEnabled: snapEnabled,
        displayedAssetId: displayedAssetId,
        isPlaceholder: isPlaceholder,
        lastLoadError: lastLoadError,
        lastUpdatedAt: lastUpdatedAt,
        animatedFirstFrameOnly: animatedFirstFrameOnly,
        visualType: visualType,
        animationFrameMode: animationFrameMode,
        animationSupported: animationSupported,
        animationPlaying: animationPlaying,
        animationPausedReason: animationPausedReason,
        decodeCode: decodeCode,
        windowVisible: windowVisible,
        attachedToWindow: attachedToWindow,
        viewWidth: viewWidth,
        viewHeight: viewHeight,
        imageViewWidth: imageWidth,
        imageViewHeight: imageHeight,
        lastWindowError: lastWindowError,
        lastWindowAction: lastWindowAction,
        visual: visual,
        debugOverlayMode: debugOverlayMode,
      );

  void _absorb(OverlayPetConfig config) {
    pushedConfigs.add(config);
    displayedAssetId = config.assetId;
    isPlaceholder = false;
    // API 28+ 真机：动态素材走完整动画，因此不再"只显示第一帧"。
    animatedFirstFrameOnly = false;
    visualType = config.isAnimated ? 'animated' : 'static';
    animationFrameMode =
        config.isAnimated ? 'full-animation' : 'not-applicable';
    animationSupported = true;
    animationPlaying = config.isAnimated;
    animationPausedReason = null;
    decodeCode = null;
    lastLoadError = null;
    lastUpdatedAt = DateTime(2026, 9, 29, 12);
    visual = 'asset';
  }

  @override
  Future<bool> isSupported() async => true;

  // --- Phase 4C-5：状态联动 ---

  /// 按"当前覆盖 / 映射版本"造一份诊断
  /// （`copyWith` 无法把可空字段置回 null，因此这里显式构造）。
  OverlayStateDiagnostics _diagnosticsWith(
    String? override,
    String? source, {
    int? mappingRevision,
  }) =>
      OverlayStateDiagnostics(
        stateId: override ?? diagnostics.stateId,
        stateLabel: diagnostics.stateLabel,
        stateSource: source ?? diagnostics.stateSource,
        stateReason: diagnostics.stateReason,
        foregroundPackage: diagnostics.foregroundPackage,
        foregroundLabel: diagnostics.foregroundLabel,
        category: diagnostics.category,
        categorySource: diagnostics.categorySource,
        candidateState: diagnostics.candidateState,
        candidateCount: diagnostics.candidateCount,
        manualOverride: override,
        usageAccessGranted: diagnostics.usageAccessGranted,
        monitorRunning: diagnostics.monitorRunning,
        mappingRevision: mappingRevision ?? diagnostics.mappingRevision,
        stateAssetId: diagnostics.stateAssetId,
        fallbackLevel: diagnostics.fallbackLevel,
        lastChangedAt: diagnostics.lastChangedAt,
        stateErrorCode: diagnostics.stateErrorCode,
      );

  // --- Phase 4C-5.1A：前台应用共享快照 ---

  /// 假件模拟"原生共享快照"：测试可以自由设置。
  CurrentActivity activity = const CurrentActivity(
    available: true,
    packageName: 'org.telegram.messenger',
    displayName: 'Telegram',
    category: 'social',
    detectionSource: 'activity-events',
    usageAccessAvailable: true,
    collectorRunning: true,
  );

  @override
  Future<CurrentActivity> currentActivity() async {
    calls.add('currentActivity');
    return activity;
  }

  @override
  Future<OverlayStateDiagnostics> stateDiagnostics() async {
    calls.add('stateDiagnostics');
    return diagnostics;
  }

  @override
  Future<OverlayRuntimeState> updateStateMapping(OverlayStateMapping mapping) async {
    calls.add('updateStateMapping');
    pushedMappings.add(mapping);
    diagnostics = _diagnosticsWith(
      manualState,
      null,
      mappingRevision: mapping.revision,
    );
    return buildState();
  }

  @override
  Future<OverlayRuntimeState> setManualState(String? stateId) async {
    calls.add('setManualState');
    manualState = stateId;
    diagnostics = _diagnosticsWith(stateId, stateId == null ? 'unsupported' : 'manual-debug');
    return buildState();
  }

  // --- Phase 4C-6A.1：临时预览 ---

  /// 当前预览中的状态（假件只记状态，不模拟到期）。
  String? previewedStateId;

  @override
  Future<OverlayRuntimeState> previewState(String stateId) async {
    calls.add('previewState');
    previewedStateId = stateId;
    diagnostics = OverlayStateDiagnostics(
      stateId: stateId,
      displayMode: 'preview',
      previewState: stateId,
      previewExpiresAt: DateTime.now().add(const Duration(seconds: 10)),
    );
    return buildState();
  }

  @override
  Future<OverlayRuntimeState> clearPreview() async {
    calls.add('clearPreview');
    previewedStateId = null;
    diagnostics = OverlayStateDiagnostics(stateId: manualState ?? 'default');
    return buildState();
  }

  @override
  Future<void> openUsageAccessSettings() async {
    calls.add('openUsageAccessSettings');
  }

  // --- Phase 4C-5.1B：原生使用会话采集 ---

  UsageCollectorState collectorState = UsageCollectorState.unsupported;
  List<AndroidUsageSession> pendingSessions = <AndroidUsageSession>[];
  final List<String> acknowledgedSessionIds = <String>[];
  bool? pushedPaused;
  String? pushedDeviceLocalId;

  @override
  Future<UsageCollectorState> usageCollectorState() async {
    calls.add('usageCollectorState');
    return collectorState;
  }

  @override
  Future<List<AndroidUsageSession>> readPendingUsageSessions({int limit = 200}) async {
    calls.add('readPendingUsageSessions');
    return pendingSessions.take(limit).toList(growable: false);
  }

  @override
  Future<int> acknowledgeUsageSessions(List<String> sessionIds) async {
    calls.add('acknowledgeUsageSessions');
    final int before = pendingSessions.length;
    pendingSessions = pendingSessions
        .where((AndroidUsageSession s) => !sessionIds.contains(s.sessionId))
        .toList(growable: false);
    acknowledgedSessionIds.addAll(sessionIds);
    return before - pendingSessions.length;
  }

  @override
  Future<void> setUsageCollectionPaused(bool paused) async {
    calls.add('setUsageCollectionPaused');
    pushedPaused = paused;
  }

  @override
  Future<void> updateUsageIdentity(String deviceLocalId) async {
    calls.add('updateUsageIdentity');
    pushedDeviceLocalId = deviceLocalId;
  }

  @override
  Future<OverlayPermissionState> permissionState() async {
    calls.add('permissionState');
    return OverlayPermissionState(
      supported: true,
      overlayGranted: overlayGranted,
      notificationsGranted: notificationsGranted,
      notificationsRequired: notificationsRequired,
    );
  }

  @override
  Future<OverlayPermissionState> requestOverlayPermission() async {
    calls.add('requestOverlayPermission');
    return permissionState();
  }

  @override
  Future<OverlayPermissionState> requestNotificationPermission() async {
    calls.add('requestNotificationPermission');
    return permissionState();
  }

  @override
  Future<OverlayRuntimeState> start([OverlayPetConfig? config]) async {
    calls.add('start');
    running = true;
    hidden = false;
    if (config != null) _absorb(config);
    return buildState();
  }

  @override
  Future<OverlayRuntimeState> show() async {
    calls.add('show');
    running = true;
    hidden = false;
    return buildState();
  }

  @override
  Future<OverlayRuntimeState> hide() async {
    calls.add('hide');
    hidden = true;
    // §11.2：隐藏先停动画，但保留解码结果（再次显示可恢复播放）。
    animationPlaying = false;
    animationPausedReason = 'hidden';
    return buildState();
  }

  @override
  Future<OverlayRuntimeState> stop() async {
    calls.add('stop');
    running = false;
    hidden = false;
    displayedAssetId = null;
    isPlaceholder = true;
    animatedFirstFrameOnly = false;
    visualType = 'placeholder';
    animationFrameMode = 'not-applicable';
    animationSupported = false;
    animationPlaying = false;
    animationPausedReason = null;
    decodeCode = null;
    return buildState();
  }

  @override
  Future<OverlayRuntimeState> updatePet(OverlayPetConfig config) async {
    calls.add('updatePet');
    _absorb(config);
    return buildState();
  }

  @override
  Future<OverlayRuntimeState> updateSettings(OverlayPetSettings settings) async {
    calls.add('updateSettings');
    if (failUpdateSettings) {
      throw const OverlayPlatformException('overlay_failed', '写入设置失败');
    }
    scale = settings.scale;
    snapEnabled = settings.snapEnabled;
    return buildState();
  }

  @override
  Future<OverlayRuntimeState> setDebugOverlay(bool enabled) async {
    calls.add('setDebugOverlay:$enabled');
    debugOverlayMode = enabled;
    visual = enabled ? 'debug' : (isPlaceholder ? 'empty' : 'asset');
    return buildState();
  }

  @override
  Future<OverlayRuntimeState> getState() async {
    calls.add('getState');
    return buildState();
  }

  @override
  Future<void> openBatterySettings() async {
    calls.add('openBatterySettings');
  }

  @override
  Future<void> openAppDetails() async {
    calls.add('openAppDetails');
  }

  // --- Phase 4C-6B-1：轮盘主题 ---
  OverlayMenuThemeState menuThemeState = OverlayMenuThemeState.unsupported;
  OverlayMenuThemeUpdate menuThemeUpdate = const OverlayMenuThemeUpdate(accepted: true);
  bool failMenuTheme = false;

  @override
  Future<OverlayMenuThemeState> menuTheme() async {
    calls.add('menuTheme');
    if (failMenuTheme) {
      throw const OverlayPlatformException('menu_theme_failed', '读取轮盘主题失败');
    }
    return menuThemeState;
  }

  @override
  Future<OverlayMenuThemeUpdate> setMenuTheme({
    required String themeId,
    int? customPrimary,
    required int revision,
  }) async {
    calls.add('setMenuTheme:$themeId@$revision');
    return menuThemeUpdate;
  }

  // --- Phase 4C-6B-1.1：轮盘布局 ---
  OverlayWheelLayoutSettings wheelLayoutState = OverlayWheelLayoutSettings.unsupported;
  OverlayWheelLayoutUpdate wheelLayoutUpdate =
      const OverlayWheelLayoutUpdate(accepted: true);

  @override
  Future<OverlayWheelLayoutSettings> wheelLayout() async {
    calls.add('wheelLayout');
    return wheelLayoutState;
  }

  @override
  Future<OverlayWheelLayoutUpdate> setWheelLayout({
    required double preferredScale,
    double? buttonVisualScale,
    required bool compactMode,
    required int revision,
  }) async {
    calls.add(
      'setWheelLayout:${preferredScale.toStringAsFixed(2)}'
      '/${(buttonVisualScale ?? 0).toStringAsFixed(2)}@$revision',
    );
    return wheelLayoutUpdate;
  }

  // --- Phase 4D：开机自启 ---

  OverlayAutostartStatus autostartState = const OverlayAutostartStatus(
    supported: true,
    enabled: false,
  );

  @override
  Future<OverlayAutostartStatus> autostartStatus() async {
    calls.add('autostartStatus');
    return autostartState;
  }

  @override
  Future<OverlayAutostartStatus> setAutostart(bool enabled) async {
    calls.add('setAutostart:$enabled');
    autostartState = OverlayAutostartStatus(
      supported: true,
      enabled: enabled,
      overlayGranted: autostartState.overlayGranted,
      bootResultCode: autostartState.bootResultCode,
      bootResultAt: autostartState.bootResultAt,
      bootResultDetail: autostartState.bootResultDetail,
    );
    return autostartState;
  }

  // --- 双窗口探针：只读诊断 ---

  DualWindowProbeStatus dualWindowProbeStatusState = DualWindowProbeStatus.unsupported;

  @override
  Future<DualWindowProbeStatus> dualWindowProbeStatus() async {
    calls.add('dualWindowProbeStatus');
    return dualWindowProbeStatusState;
  }

  // --- 双窗口实现开关（迁移期临时回退）---

  DualWindowModeStatus dualWindowModeState = const DualWindowModeStatus(
    supported: true,
    dualWindowEnabled: true,
  );

  @override
  Future<DualWindowModeStatus> dualWindowMode() async {
    calls.add('dualWindowMode');
    return dualWindowModeState;
  }

  @override
  Future<bool> setDualWindowMode(bool enabled) async {
    calls.add('setDualWindowMode:$enabled');
    dualWindowModeState = DualWindowModeStatus(
      supported: true,
      dualWindowEnabled: enabled,
    );
    return true;
  }
}

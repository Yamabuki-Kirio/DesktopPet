import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:petlife/activity_tracking/models/tracking_settings.dart';
import 'package:petlife/activity_tracking/models/usage_stats.dart';
import 'package:petlife/activity_tracking/usage_analytics_service.dart';
import 'package:petlife/character/character_repository.dart';
import 'package:petlife/character/models/character_model.dart';
import 'package:petlife/character/models/character_pack.dart';
import 'package:petlife/character/models/emotion_asset.dart';
import 'package:petlife/character/models/enums.dart';
import 'package:petlife/character/models/state_mapping.dart';
import 'package:petlife/core/constants.dart';
import 'package:petlife/navigation/app_navigation.dart';
import 'package:petlife/platform/android/android_overlay_menu_bridge.dart';
import 'package:petlife/settings/app_settings.dart';
import 'package:petlife/settings/settings_controller.dart';
import 'package:petlife/settings/settings_repository.dart';
import 'package:petlife/state_engine/fallback_chain.dart';
import 'package:petlife/state_engine/state_debouncer.dart';
import 'package:petlife/state_engine/state_engine.dart';
import 'package:petlife/state_engine/state_snapshot.dart';
import 'package:petlife/state_engine/system_state.dart';
import 'package:petlife/sync/models/sync_models.dart';
import 'package:petlife/ui/library_controller.dart';
import 'package:petlife/ui/overlay_menu_actions.dart';
import 'package:petlife/ui/overlay_pet_controller.dart';

import 'overlay_pet_controller_test.dart' as overlay_test;

/// Phase 4C-6B-2：轮盘菜单动作的 Dart 侧行为。
///
/// 全部是**纯 Dart / 轻量 Widget 绑定**的用例：不连原生、不连数据库
/// （唯一例外是假台账，仍然只复用既有 `MenuRequestLedger` 接口）。
/// 覆盖冻结契约里的每一条硬要求：
/// * 跳转请求 → 目的地被消费一次；
/// * 待处理请求只执行一次并回执；
/// * 重复投递的 requestId 不再执行（跨 State / 冷启动同样成立）；
/// * prev/next 循环与单素材失败；
/// * `appearance_auto` 释放 manual 锁；
/// * 收藏不改变当前素材；
/// * 今日时长取自使用统计服务（与统计页同一口径）；
/// * 大小设置走既有原生写入路径；
/// * 同步请求走既有互斥入口。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late ValueNotifier<StateSnapshot> snapshots;
  late _FakeStateEngine engine;
  late _FakeCharacterRepository repository;
  late SettingsController settings;
  late AppNavigationController navigation;

  // --- 采集 / 同步的可控读数（对应 AppServices 里的既有服务）---
  late _FakeUsageAnalytics usageAnalytics;
  TrackingSettings tracking = const TrackingSettings();
  final List<TrackingSettings> savedTracking = <TrackingSettings>[];
  bool signedIn = false;
  SyncStatus syncStatus = SyncStatus.idle;
  int syncPendingCount = 0;
  DateTime? syncLastSuccessAt;
  String? syncLastError;
  int syncEntryCalls = 0;
  Future<void> Function()? syncNowOverride;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('petlife_menu_actions');
    snapshots = ValueNotifier<StateSnapshot>(StateSnapshot.initial());
    engine = _FakeStateEngine(snapshots);
    repository = _FakeCharacterRepository();
    // 假引擎按 ID 解析素材（真实引擎这一步由回退链完成）。
    engine.resolveAsset = (String id) {
      for (final EmotionAsset a in repository.assets) {
        if (a.id == id) return a;
      }
      return null;
    };
    settings = SettingsController(
      repository: _MemorySettingsRepository(),
      ownerId: 'local.default',
    );
    await settings.load();
    navigation = AppNavigationController();

    usageAnalytics = _FakeUsageAnalytics();
    tracking = const TrackingSettings();
    savedTracking.clear();
    signedIn = false;
    syncStatus = SyncStatus.idle;
    syncPendingCount = 0;
    syncLastSuccessAt = null;
    syncLastError = null;
    syncEntryCalls = 0;
    syncNowOverride = null;
  });

  tearDown(() {
    navigation.dispose();
    snapshots.dispose();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  // ---------------------------------------------------------------------------
  // 测试用工具
  // ---------------------------------------------------------------------------

  String assetFile(String name) {
    final File file = File(p.join(root.path, 'packA', 'Maya', name));
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(<int>[0x89, 0x50, 0x4E, 0x47]);
    return file.path;
  }

  EmotionAsset buildAsset({
    required String id,
    String emotion = 'idle',
    String variant = 'a',
    String? filePath,
    bool favorite = false,
  }) =>
      EmotionAsset(
        id: id,
        characterId: 'char-1',
        emotionName: emotion,
        variantName: variant,
        filePath: filePath ?? assetFile('$emotion.$variant.png'),
        fileHash: 'hash-$id',
        mimeType: 'image/png',
        fileSize: 4,
        width: 64,
        height: 64,
        frameCount: 0,
        isAnimated: false,
        hasAlpha: true,
        enabled: true,
        validationStatus: ValidationStatus.valid,
        createdAt: DateTime(2026, 9, 30),
        favorite: favorite,
      );

  CharacterModel buildCharacter() => CharacterModel(
        id: 'char-1',
        packId: 'pack-1',
        ownerId: 'local.default',
        internalName: 'Maya',
        displayName: 'Maya',
        enabled: true,
        createdAt: DateTime(2026, 9, 30),
        updatedAt: DateTime(2026, 9, 30),
      );

  StateSnapshot snapshotWith({
    CharacterModel? character,
    EmotionAsset? asset,
    String? manualAssetId,
  }) =>
      StateSnapshot(
        state: manualAssetId == null ? SystemState.defaultState : SystemState.manual,
        trigger: manualAssetId == null ? StateTrigger.foregroundApp : StateTrigger.manual,
        reason: '测试',
        startedAt: DateTime(2026, 9, 30, 10),
        currentCharacter: character,
        resolution: AssetResolution(
          asset: asset,
          level: FallbackLevel.stateAsset,
          reason: '测试',
        ),
        nextAllowedChangeAt: null,
        lastDecisionNote: '',
        manualAssetId: manualAssetId,
      );

  OverlayMenuActionExecutor buildExecutor({
    OverlayPetController? Function()? overlay,
    LibraryController? Function()? library,
  }) =>
      OverlayMenuActionExecutor(
        snapshots: snapshots,
        stateEngine: engine,
        listRenderableAssets: repository.listRenderableAssets,
        settings: settings,
        navigation: navigation,
        usageAnalytics: usageAnalytics,
        trackingSettings: () => tracking,
        saveTrackingSettings: (TrackingSettings next) async {
          savedTracking.add(next);
          tracking = next;
        },
        isSignedIn: () => signedIn,
        syncStatus: () => syncStatus,
        syncPendingCount: () => syncPendingCount,
        syncLastSuccessAt: () => syncLastSuccessAt,
        syncLastError: () => syncLastError,
        syncNow: () async {
          syncEntryCalls++;
          final Future<void> Function()? override = syncNowOverride;
          if (override != null) await override();
        },
        overlay: overlay,
        library: library,
      );

  // ---------------------------------------------------------------------------
  // 1. 跳转请求 → 目的地
  // ---------------------------------------------------------------------------

  group('导航请求', () {
    test('AppDestination 的取值与原生字符串完全一致（冻结契约）', () {
      expect(
        AppDestination.values.map((AppDestination d) => d.wireName),
        <String>[
          'assetLibrary',
          'stateAssetMapping',
          'localStatistics',
          'cloudStatistics',
          'accountSync',
          'overlaySettings',
        ],
      );
      expect(AppDestination.fromWire('cloudStatistics'), AppDestination.cloudStatistics);
      expect(AppDestination.fromWire('nope'), isNull);
    });

    test('外壳订阅后：目的地被消费一次、队列清空、不会重复执行', () async {
      final OverlayMenuActionExecutor executor = buildExecutor();
      final List<AppDestination> handled = <AppDestination>[];
      final StreamSubscription<AppDestination> sub =
          navigation.requests.listen((AppDestination _) {
        // 外壳的消费逻辑：把队列里积压的请求逐个应用（幂等：消费即移除）。
        while (navigation.hasPending) {
          final AppDestination? next = navigation.take();
          if (next == null) break;
          handled.add(next);
        }
      });
      addTearDown(sub.cancel);

      final MenuActionResult result = await executor.execute('records_stats', const <String, Object?>{});
      await pumpEventQueue();

      expect(result.status, MenuRequestStatus.completed);
      expect(handled, <AppDestination>[AppDestination.localStatistics]);
      expect(navigation.hasPending, isFalse);
      expect(navigation.take(), isNull, reason: '同一请求不得被消费两次');
    });

    test('外壳未就绪时请求保留在控制器里，等 init 后再消费', () {
      // 没有订阅者：广播流的事件没有听众，但队列必须留着。
      navigation.request(AppDestination.overlaySettings);
      navigation.request(AppDestination.assetLibrary);

      expect(navigation.hasPending, isTrue);
      expect(navigation.pending, <AppDestination>[
        AppDestination.overlaySettings,
        AppDestination.assetLibrary,
      ]);
      expect(navigation.take(), AppDestination.overlaySettings);
      expect(navigation.take(), AppDestination.assetLibrary);
      expect(navigation.hasPending, isFalse);
    });

    test('动作 ID → 目的地的映射与冻结契约一致', () async {
      final OverlayMenuActionExecutor executor = buildExecutor();
      snapshots.value = snapshotWith(
        character: buildCharacter(),
        asset: buildAsset(id: 'a1'),
      );

      Future<void> expectDestination(String actionId, AppDestination expected) async {
        navigation.take(); // 清空
        final MenuActionResult result = await executor.execute(actionId, const <String, Object?>{});
        expect(result.status, MenuRequestStatus.completed, reason: actionId);
        expect(navigation.pending, <AppDestination>[expected], reason: actionId);
      }

      await expectDestination('appearance_mapping', AppDestination.stateAssetMapping);
      await expectDestination('appearance_library', AppDestination.assetLibrary);
      await expectDestination('records_stats', AppDestination.localStatistics);
      await expectDestination('records_cloud', AppDestination.cloudStatistics);
      await expectDestination('settings_open', AppDestination.overlaySettings);
    });

    test('没有当前角色时 appearance_mapping 返回 failed，且不入队', () async {
      final OverlayMenuActionExecutor executor = buildExecutor();

      final MenuActionResult result =
          await executor.execute('appearance_mapping', const <String, Object?>{});

      expect(result.status, MenuRequestStatus.failed);
      expect(result.message, contains('尚未选择桌宠角色'));
      expect(navigation.hasPending, isFalse);
    });

    test('未知动作返回 failed（不静默成功）', () async {
      final OverlayMenuActionExecutor executor = buildExecutor();

      final MenuActionResult result =
          await executor.execute('not-an-action', const <String, Object?>{});

      expect(result.status, MenuRequestStatus.failed);
      expect(result.message, contains('不支持的菜单动作'));
    });
  });

  // ---------------------------------------------------------------------------
  // 2. 待处理请求的消费与幂等
  // ---------------------------------------------------------------------------

  group('待处理请求消费', () {
    late _FakeBridge bridge;
    late _MemoryLedger ledger;

    setUp(() {
      bridge = _FakeBridge();
      ledger = _MemoryLedger();
    });

    OverlayMenuRequest request(String id, {String actionId = 'settings_open'}) =>
        OverlayMenuRequest(requestId: id, actionId: actionId);

    test('拉取 → 执行一次 → 回执 completed，并把 requestId 记进台账', () async {
      bridge.pending = <OverlayMenuRequest>[request('r1')];
      final OverlayMenuRequestConsumer consumer = OverlayMenuRequestConsumer(
        bridge: bridge,
        executor: buildExecutor(),
        ledger: ledger,
      );
      consumer.start();

      await pumpEventQueue();

      expect(bridge.completed, <String>['r1:completed']);
      expect(navigation.pending, <AppDestination>[AppDestination.overlaySettings]);
      expect(ledger.seen, contains('r1'));
      expect(bridge.handlerBound, isTrue);

      consumer.dispose();
      expect(bridge.handlerCleared, isTrue);
    });

    test('重新拉取（前台恢复）时重复投递不再执行，只做幂等确认', () async {
      bridge.pending = <OverlayMenuRequest>[request('r1')];
      final OverlayMenuRequestConsumer consumer = OverlayMenuRequestConsumer(
        bridge: bridge,
        executor: buildExecutor(),
        ledger: ledger,
      );
      consumer.start();
      await pumpEventQueue();
      expect(navigation.pending, hasLength(1));

      // 原生没收到回执 / 又投递了一次同一条请求。
      bridge.pending = <OverlayMenuRequest>[request('r1')];
      consumer.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await pumpEventQueue();

      expect(bridge.completed, <String>['r1:completed', 'r1:completed']);
      expect(navigation.pending, hasLength(1), reason: '同一个 requestId 不得执行第二次');

      consumer.dispose();
    });

    test('Activity 重建 / 冷启动：新消费者 + 新台账实例（同一份持久化记录）不重复执行', () async {
      // 共享的"持久化"集合：模拟 local_settings 里的台账。
      final Set<String> persisted = <String>{};
      final _MemoryLedger first = _MemoryLedger(persisted: persisted);
      bridge.pending = <OverlayMenuRequest>[request('r1')];
      final OverlayMenuRequestConsumer a = OverlayMenuRequestConsumer(
        bridge: bridge,
        executor: buildExecutor(),
        ledger: first,
      );
      a.start();
      await pumpEventQueue();
      expect(navigation.pending, hasLength(1));
      a.dispose();

      // 新的进程/新的 State：内存集合是空的，只有持久化台账能挡住重复执行。
      bridge.pending = <OverlayMenuRequest>[request('r1')];
      final _MemoryLedger second = _MemoryLedger(persisted: persisted);
      final OverlayMenuRequestConsumer b = OverlayMenuRequestConsumer(
        bridge: bridge,
        executor: buildExecutor(),
        ledger: second,
      );
      b.start();
      await pumpEventQueue();

      expect(navigation.pending, hasLength(1), reason: '冷启动后重投的请求不得再执行一次');
      expect(bridge.completed.last, 'r1:completed');
      b.dispose();
    });

    test('原生主动 menuRequest：执行一次并原样返回 {status, message}', () async {
      final OverlayMenuRequestConsumer consumer = OverlayMenuRequestConsumer(
        bridge: bridge,
        executor: buildExecutor(),
        ledger: ledger,
      );
      consumer.start();
      await pumpEventQueue();

      final Map<String, Object?> reply = await bridge.handler!(request('r7'));

      expect(reply['status'], 'completed');
      expect(navigation.pending, <AppDestination>[AppDestination.overlaySettings]);

      // 同一条 requestId 再从拉取路径投递：只确认，不再执行。
      bridge.pending = <OverlayMenuRequest>[request('r7')];
      consumer.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await pumpEventQueue();
      expect(navigation.pending, hasLength(1));

      consumer.dispose();
    });

    test('已处于终态的请求不再执行', () async {
      bridge.pending = <OverlayMenuRequest>[
        OverlayMenuRequest(
          requestId: 'r-expired',
          actionId: 'settings_open',
          status: MenuRequestStatus.expired,
        ),
      ];
      final OverlayMenuRequestConsumer consumer = OverlayMenuRequestConsumer(
        bridge: bridge,
        executor: buildExecutor(),
        ledger: ledger,
      );
      consumer.start();
      await pumpEventQueue();

      expect(navigation.hasPending, isFalse);
      expect(bridge.completed, <String>['r-expired:completed']);

      consumer.dispose();
    });

    test('执行失败也回执 failed（绝不谎报成功）', () async {
      bridge.pending = <OverlayMenuRequest>[request('r2', actionId: 'appearance_mapping')];
      final OverlayMenuRequestConsumer consumer = OverlayMenuRequestConsumer(
        bridge: bridge,
        executor: buildExecutor(),
        ledger: ledger,
      );
      consumer.start();
      await pumpEventQueue();

      expect(bridge.completed, <String>['r2:failed']);
      expect(navigation.hasPending, isFalse);

      consumer.dispose();
    });
  });

  // ---------------------------------------------------------------------------
  // 3. 素材切换（appearance_*）
  // ---------------------------------------------------------------------------

  group('素材切换', () {
    test('next / prev 围绕当前素材循环（稳定顺序）', () async {
      final List<EmotionAsset> assets = <EmotionAsset>[
        buildAsset(id: 'a1', emotion: 'angry'),
        buildAsset(id: 'a2', emotion: 'happy'),
        buildAsset(id: 'a3', emotion: 'idle'),
      ];
      repository.assets = assets;
      snapshots.value = snapshotWith(character: buildCharacter(), asset: assets[1]);
      final OverlayMenuActionExecutor executor = buildExecutor();

      final MenuActionResult next =
          await executor.execute('appearance_next', const <String, Object?>{});
      expect(next.status, MenuRequestStatus.completed);
      expect(engine.manualLocks, <String?>['a3']);

      // 回到中间再往前一张（循环的另一半）。
      snapshots.value = snapshotWith(character: buildCharacter(), asset: assets[1]);
      final MenuActionResult prev =
          await executor.execute('appearance_prev', const <String, Object?>{});
      expect(prev.status, MenuRequestStatus.completed);
      expect(engine.manualLocks, <String?>['a3', 'a1']);

      // 从最后一张再往后：绕回第一张。
      snapshots.value = snapshotWith(character: buildCharacter(), asset: assets[2]);
      await executor.execute('appearance_next', const <String, Object?>{});
      expect(engine.manualLocks.last, 'a1');
    });

    test('切换后进入既有的 manual 锁定，并持久化，自动 tick 不会悄悄回退', () async {
      final List<EmotionAsset> assets = <EmotionAsset>[
        buildAsset(id: 'a1', emotion: 'angry'),
        buildAsset(id: 'a2', emotion: 'happy'),
      ];
      repository.assets = assets;
      snapshots.value = snapshotWith(character: buildCharacter(), asset: assets[0]);

      await buildExecutor().execute('appearance_next', const <String, Object?>{});

      expect(snapshots.value.state, SystemState.manual);
      expect(snapshots.value.manualAssetId, 'a2');
      expect(settings.settings.manualAssetId, 'a2',
          reason: '冷启动要按持久化的 manualAssetId 恢复同一张图');
    });

    test('只有一张素材 → failed（不谎报成功）', () async {
      repository.assets = <EmotionAsset>[buildAsset(id: 'only')];
      snapshots.value = snapshotWith(
        character: buildCharacter(),
        asset: repository.assets.first,
      );

      final MenuActionResult result =
          await buildExecutor().execute('appearance_next', const <String, Object?>{});

      expect(result.status, MenuRequestStatus.failed);
      expect(result.message, '当前角色只有一张素材');
      expect(engine.manualLocks, isEmpty);
    });

    test('没有可用素材 → failed', () async {
      repository.assets = <EmotionAsset>[];
      snapshots.value = snapshotWith(character: buildCharacter());

      final MenuActionResult result =
          await buildExecutor().execute('appearance_next', const <String, Object?>{});

      expect(result.status, MenuRequestStatus.failed);
      expect(result.message, contains('没有可用素材'));
    });

    test('素材文件丢失 → 保持原素材并返回原因', () async {
      final EmotionAsset alive = buildAsset(id: 'a1', emotion: 'angry');
      final EmotionAsset gone = buildAsset(
        id: 'a2',
        emotion: 'happy',
        filePath: p.join(root.path, 'packA', 'Maya', 'deleted.png'),
      );
      repository.assets = <EmotionAsset>[alive, gone];
      // 当前是活着的那张；下一张（happy）的文件已被外部删除。
      snapshots.value = snapshotWith(character: buildCharacter(), asset: alive);

      final MenuActionResult result =
          await buildExecutor().execute('appearance_next', const <String, Object?>{});

      expect(result.status, MenuRequestStatus.failed);
      expect(result.message, contains('素材文件不存在'));
      expect(engine.manualLocks, isEmpty, reason: '失败时不得动当前素材');
      expect(snapshots.value.currentAsset?.id, 'a1');
    });

    test('appearance_auto 释放 manual 锁并清掉持久化锁定', () async {
      final EmotionAsset asset = buildAsset(id: 'a1');
      repository.assets = <EmotionAsset>[asset];
      snapshots.value = snapshotWith(
        character: buildCharacter(),
        asset: asset,
        manualAssetId: 'a1',
      );
      await settings.rememberSelection(
        characterId: 'char-1',
        state: SystemState.manual,
        assetId: 'a1',
        manualAssetId: 'a1',
      );
      expect(settings.settings.manualAssetId, 'a1');

      final MenuActionResult result =
          await buildExecutor().execute('appearance_auto', const <String, Object?>{});

      expect(result.status, MenuRequestStatus.completed);
      expect(engine.releaseCalls, 1);
      expect(snapshots.value.state, SystemState.defaultState);
      expect(settings.settings.manualAssetId, isNull,
          reason: '不清理的话下次冷启动又会按它把图锁回去');
    });

    test('pet_auto 打开自动联动开关并立刻下发映射', () async {
      final overlay_test.FakeOverlayPet fakeOverlay = overlay_test.FakeOverlayPet();
      fakeOverlay.running = true;
      final OverlayPetController controller = OverlayPetController(
        overlay: fakeOverlay,
        snapshots: snapshots,
        privateAssetsRoot: () => root.path,
        delay: (Duration _) async {},
      );
      addTearDown(controller.dispose);
      await settings.setOverlayAutomaticState(false);

      final MenuActionResult result = await buildExecutor(overlay: () => controller)
          .execute('pet_auto', const <String, Object?>{});

      expect(result.status, MenuRequestStatus.completed);
      expect(settings.settings.overlayAutomaticState, isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // 4. 收藏
  // ---------------------------------------------------------------------------

  group('收藏', () {
    late LibraryController library;
    late _FakeCharacterRepository repo;

    setUp(() async {
      repo = _FakeCharacterRepository();
      // 让假引擎能按 ID 解析素材（真实引擎由回退链负责这件事）。
      engine.resolveAsset = (String id) {
        for (final EmotionAsset a in repo.assets) {
          if (a.id == id) return a;
        }
        return null;
      };
      library = LibraryController(
        repository: repo,
        ownerId: 'local.default',
        stateEngine: engine,
        settings: settings,
      );
    });

    tearDown(() {
      library.dispose();
    });

    test('收藏当前素材：调用素材库控制器的既有入口，且不改变当前素材', () async {
      final List<EmotionAsset> assets = <EmotionAsset>[
        buildAsset(id: 'a1', emotion: 'angry'),
        buildAsset(id: 'a2', emotion: 'happy'),
      ];
      repo.assets = assets;
      snapshots.value = snapshotWith(character: buildCharacter(), asset: assets[1]);
      await library.load();
      library.onLibraryMutated = () async {};

      final MenuActionResult result = await buildExecutor(library: () => library)
          .execute('appearance_fav', const <String, Object?>{});

      expect(result.status, MenuRequestStatus.completed);
      expect(result.message, contains('已收藏'));
      expect(repo.favoriteCalls, <String>['a2:true']);
      expect(snapshots.value.currentAsset?.id, 'a2');
      expect(engine.manualLocks, isEmpty, reason: '画面没变就不该额外加锁');
    });

    test('收藏导致回退解析到别的素材时：把画面锁回原素材', () async {
      final List<EmotionAsset> assets = <EmotionAsset>[
        buildAsset(id: 'a1', emotion: 'angry', favorite: true),
        buildAsset(id: 'a2', emotion: 'happy'),
      ];
      repo.assets = assets;
      snapshots.value = snapshotWith(character: buildCharacter(), asset: assets[1]);
      await library.load();
      // 复刻"收藏后回退链改选另一张"的真实后果。
      library.onLibraryMutated = () async {
        snapshots.value = snapshotWith(
          character: buildCharacter(),
          asset: repo.assets.first,
        );
      };

      final MenuActionResult result = await buildExecutor(library: () => library)
          .execute('appearance_fav', const <String, Object?>{});

      expect(result.status, MenuRequestStatus.completed);
      expect(engine.manualLocks, <String?>['a2'],
          reason: '收藏不得改变正在显示的素材');
      expect(snapshots.value.currentAsset?.id, 'a2');
    });

    test('没有正在显示的素材 → failed', () async {
      repo.assets = <EmotionAsset>[];
      snapshots.value = snapshotWith(character: buildCharacter());

      final MenuActionResult result = await buildExecutor(library: () => library)
          .execute('appearance_fav', const <String, Object?>{});

      expect(result.status, MenuRequestStatus.failed);
      expect(result.message, contains('没有正在显示的素材'));
    });
  });

  // ---------------------------------------------------------------------------
  // 5. 记录（records_*）
  // ---------------------------------------------------------------------------

  group('记录', () {
    test('records_today 与统计页同口径：UsageAnalyticsService.summarize(今天) 的 appActiveSeconds', () async {
      // 「使用统计（本机）」页的「今天」总时长 = summarize(windowFor(today)).overview.appActiveSeconds。
      usageAnalytics.appActiveSeconds = 9300; // 2 小时 35 分钟
      // 干扰项：设备级活跃时间属于另一个指标，绝不能被「今日时长」采用。
      usageAnalytics.activeSeconds = 12345;

      final MenuActionResult result =
          await buildExecutor().execute('records_today', const <String, Object?>{});

      expect(result.status, MenuRequestStatus.completed);
      expect(result.message, '今日使用：2小时35分钟');
      // 与统计页用的是同一个「今天」窗口（同一个 UsageWindow）。
      final UsageWindow expected = UsageAnalyticsService.windowFor(UsageRange.today);
      final UsageWindow asked = usageAnalytics.windows.single;
      expect(asked.label, '今天');
      expect(asked.fromUtc, expected.fromUtc);
      expect(asked.toUtc, expected.toUtc);
    });

    test('records_today 的边界文案（数值同样取自统计服务）', () async {
      final OverlayMenuActionExecutor executor = buildExecutor();

      usageAnalytics.appActiveSeconds = 0;
      expect((await executor.execute('records_today', const <String, Object?>{}))
          .message, '今日使用：0分钟');

      usageAnalytics.appActiveSeconds = 35 * 60;
      expect((await executor.execute('records_today', const <String, Object?>{}))
          .message, '今日使用：35分钟');

      usageAnalytics.appActiveSeconds = 5;
      expect((await executor.execute('records_today', const <String, Object?>{}))
          .message, '今日使用：5秒');

      usageAnalytics.appActiveSeconds = 3 * 3600;
      expect((await executor.execute('records_today', const <String, Object?>{}))
          .message, '今日使用：3小时');
    });

    test('records_today：统计服务不可用时返回 failed（绝不谎报 0 分钟）', () async {
      usageAnalytics.failWith = StateError('统计库未就绪');

      final MenuActionResult result =
          await buildExecutor().execute('records_today', const <String, Object?>{});

      expect(result.status, MenuRequestStatus.failed);
      expect(result.message, contains('读取今日使用时长失败'));
      expect(result.message, isNot(contains('今日使用：')));
    });

    test('records_track 走既有的采集设置写入入口（暂停 / 恢复）', () async {
      final OverlayMenuActionExecutor executor = buildExecutor();

      final MenuActionResult paused =
          await executor.execute('records_track', const <String, Object?>{});
      expect(paused.status, MenuRequestStatus.completed);
      expect(paused.message, '已暂停记录');
      expect(savedTracking.single.paused, isTrue);

      final MenuActionResult resumed =
          await executor.execute('records_track', const <String, Object?>{});
      expect(resumed.message, '已恢复记录');
      expect(savedTracking.last.paused, isFalse);
    });

    test('records_sync：未登录直接失败，且不调用同步入口', () async {
      signedIn = false;

      final MenuActionResult result =
          await buildExecutor().execute('records_sync', const <String, Object?>{});

      expect(result.status, MenuRequestStatus.failed);
      expect(result.message, contains('尚未登录'));
      expect(syncEntryCalls, 0);
    });

    test('records_sync：按同步结果给出四类文案', () async {
      signedIn = true;
      final OverlayMenuActionExecutor executor = buildExecutor();

      syncStatus = SyncStatus.success;
      expect((await executor.execute('records_sync', const <String, Object?>{}))
          .message, '同步成功');

      syncStatus = SyncStatus.waitingForNetwork;
      final MenuActionResult offline =
          await executor.execute('records_sync', const <String, Object?>{});
      expect(offline.status, MenuRequestStatus.failed);
      expect(offline.message, '离线，已保留待上传数据');

      syncStatus = SyncStatus.failed;
      syncLastError = '服务端 500';
      expect((await executor.execute('records_sync', const <String, Object?>{}))
          .message, '同步失败：服务端 500');

      syncStatus = SyncStatus.needsReauthentication;
      expect((await executor.execute('records_sync', const <String, Object?>{}))
          .message, contains('登录已失效'));
    });

    test('records_sync：并发点两次只真正跑一次同步，不并行', () async {
      signedIn = true;
      int concurrent = 0;
      int maxConcurrent = 0;
      int runs = 0;
      Future<void>? inFlight;

      // 复刻 SyncEngine._syncOnce 的互斥语义：同一次会话内已在跑就复用那个任务，
      // 不启动第二个（真实的互斥实现在 SyncEngine，见 sync_engine_test.dart）。
      Future<void> engineSyncNow() {
        final Future<void>? existing = inFlight;
        if (existing != null) return existing;
        final Future<void> task = () async {
          runs++;
          concurrent++;
          if (concurrent > maxConcurrent) maxConcurrent = concurrent;
          await Future<void>.delayed(const Duration(milliseconds: 5));
          concurrent--;
          syncStatus = SyncStatus.success;
        }();
        inFlight = task;
        return task.whenComplete(() {
          if (identical(inFlight, task)) inFlight = null;
        });
      }

      syncNowOverride = engineSyncNow;
      final OverlayMenuActionExecutor executor = buildExecutor();

      final List<MenuActionResult> results = await Future.wait(
        <Future<MenuActionResult>>[
          executor.execute('records_sync', const <String, Object?>{}),
          executor.execute('records_sync', const <String, Object?>{}),
        ],
      );

      expect(syncEntryCalls, 2, reason: '两次点击都要走到那个互斥入口');
      expect(runs, 1, reason: '真正的同步只跑一次');
      expect(maxConcurrent, 1, reason: '不得并行同步');
      expect(results.map((MenuActionResult r) => r.message), <String>['同步成功', '同步成功']);
    });

    test('records_sync_state：回报状态 / 待上传 / 最近成功 / 最近错误', () async {
      signedIn = true;
      syncStatus = SyncStatus.waitingForNetwork;
      syncPendingCount = 7;
      // 用"今天 11:05"，避免用例在跨日运行时断言失效。
      final DateTime now = DateTime.now();
      syncLastSuccessAt = DateTime(now.year, now.month, now.day, 11, 5);
      syncLastError = 'connect timeout';

      final MenuActionResult result =
          await buildExecutor().execute('records_sync_state', const <String, Object?>{});

      expect(result.status, MenuRequestStatus.completed);
      expect(result.message, contains('等待网络'));
      expect(result.message, contains('待上传 7 条'));
      expect(result.message, contains('最近成功：11:05'));
      expect(result.message, contains('connect timeout'));
    });
  });

  // ---------------------------------------------------------------------------
  // 6. 设置（settings_*）
  // ---------------------------------------------------------------------------

  group('设置', () {
    late overlay_test.FakeOverlayPet fakeOverlay;
    late OverlayPetController overlayController;

    setUp(() {
      fakeOverlay = overlay_test.FakeOverlayPet();
      fakeOverlay.running = true;
      overlayController = OverlayPetController(
        overlay: fakeOverlay,
        snapshots: snapshots,
        privateAssetsRoot: () => root.path,
        delay: (Duration _) async {},
      );
    });

    tearDown(() {
      overlayController.dispose();
    });

    test('settings_wheel_size / settings_button_size 走既有原生写入（含 50%~250% 与 10% 步长）', () async {
      final OverlayMenuActionExecutor executor =
          buildExecutor(overlay: () => overlayController);

      final MenuActionResult up = await executor.execute(
        'settings_wheel_size',
        const <String, Object?>{'direction': 'up'},
      );
      expect(up.status, MenuRequestStatus.completed);
      expect(up.message, '轮盘大小已设为 110%');

      final MenuActionResult button = await executor.execute(
        'settings_button_size',
        const <String, Object?>{'direction': 'down'},
      );
      expect(button.message, '按钮大小已设为 120%');

      // 百分比写法与越界值都必须被归一化。
      final MenuActionResult percent = await executor.execute(
        'settings_wheel_size',
        const <String, Object?>{'percent': 250},
      );
      expect(percent.message, '轮盘大小已设为 250%');

      final MenuActionResult clamped = await executor.execute(
        'settings_wheel_size',
        const <String, Object?>{'scale': 9},
      );
      expect(clamped.message, '轮盘大小已设为 50%');

      expect(
        fakeOverlay.calls.where((String c) => c.startsWith('setWheelLayout')),
        <String>[
          'setWheelLayout:1.10/1.30@1',
          'setWheelLayout:1.00/1.20@1',
          'setWheelLayout:2.50/1.30@1',
          'setWheelLayout:0.50/1.30@1',
        ],
      );
      // 两次写入共用同一个 revision 计数器（原生是权威来源）。
      expect(fakeOverlay.calls.contains('wheelLayout'), isTrue);
    });

    test('settings_theme 用续接后的 revision 下发', () async {
      final OverlayMenuActionExecutor executor =
          buildExecutor(overlay: () => overlayController);

      final MenuActionResult result = await executor.execute(
        'settings_theme',
        const <String, Object?>{'themeId': 'blue'},
      );

      expect(result.status, MenuRequestStatus.completed);
      expect(fakeOverlay.calls, contains('setMenuTheme:blue@1'));
      expect(fakeOverlay.calls, contains('menuTheme'));
    });

    test('设置类动作在没有悬浮控制器时 failed（非 Android 不谎报成功）', () async {
      final OverlayMenuActionExecutor executor = buildExecutor();

      for (final String actionId in <String>[
        'settings_theme',
        'settings_wheel_size',
        'settings_button_size',
      ]) {
        final MenuActionResult result =
            await executor.execute(actionId, const <String, Object?>{});
        expect(result.status, MenuRequestStatus.failed, reason: actionId);
        expect(result.message, contains('不支持'), reason: actionId);
      }
    });
  });

  // ---------------------------------------------------------------------------
  // 7. 跨端动作 id 契约（canonical snake_case + 旧 camelCase 兼容）
  //    防止"原生发 camelCase、Dart 只认 snake_case"的契约错位再次发生。
  // ---------------------------------------------------------------------------

  group('跨端动作 id 契约', () {
    late overlay_test.FakeOverlayPet fakeOverlay;
    late OverlayPetController overlayController;
    late LibraryController library;
    late _FakeCharacterRepository libRepo;

    setUp(() async {
      // 让 17 个动作都有"可执行的现实前提"：角色 + 至少两张素材 + 已登录 + 拥有悬浮控制器。
      final List<EmotionAsset> assets = <EmotionAsset>[
        buildAsset(id: 'a1', emotion: 'angry'),
        buildAsset(id: 'a2', emotion: 'happy'),
      ];
      repository.assets = assets;
      snapshots.value = snapshotWith(character: buildCharacter(), asset: assets.first);
      signedIn = true;
      syncStatus = SyncStatus.success;

      fakeOverlay = overlay_test.FakeOverlayPet();
      fakeOverlay.running = true;
      overlayController = OverlayPetController(
        overlay: fakeOverlay,
        snapshots: snapshots,
        privateAssetsRoot: () => root.path,
        delay: (Duration _) async {},
      );
      libRepo = _FakeCharacterRepository()..assets = assets;
      library = LibraryController(
        repository: libRepo,
        ownerId: 'local.default',
        stateEngine: engine,
        settings: settings,
      );
      await library.load();
      library.onLibraryMutated = () async {};
      while (navigation.hasPending) {
        navigation.take();
      }
    });

    tearDown(() {
      library.dispose();
      overlayController.dispose();
    });

    OverlayMenuActionExecutor contractExecutor() => buildExecutor(
          overlay: () => overlayController,
          library: () => library,
        );

    test('MenuActionIds：canonical 恰好 17 个，旧 camelCase 双向对得上，未知 id → null', () {
      expect(MenuActionIds.canonical, hasLength(17));
      expect(MenuActionIds.canonical.toSet(), hasLength(17));
      for (final String id in MenuActionIds.canonical) {
        expect(MenuActionIds.normalize(id), id, reason: id);
      }
      // 17 个旧 id 各对应一个 canonical id，且都落在 canonical 集合里。
      expect(MenuActionIds.legacyAliases, hasLength(17));
      for (final MapEntry<String, String> entry in MenuActionIds.legacyAliases.entries) {
        expect(MenuActionIds.normalize(entry.key), entry.value, reason: entry.key);
        expect(MenuActionIds.canonical.contains(entry.value), isTrue, reason: entry.key);
        // 旧 id 不是 canonical（否则就不需要兼容表了）。
        expect(MenuActionIds.canonical.contains(entry.key), isFalse, reason: entry.key);
      }
      // 未知 / 空 id → null（调用方据此报错，绝不静默成功）。
      expect(MenuActionIds.normalize('not-an-action'), isNull);
      expect(MenuActionIds.normalize(''), isNull);
    });

    test('17 个 canonical id 逐一执行：命中真实业务，绝不出现「不支持的菜单动作」', () async {
      final OverlayMenuActionExecutor executor = contractExecutor();
      // 5 个"跳转"动作的目标页（其余走本地业务）。
      final Map<String, AppDestination> destinations = <String, AppDestination>{
        'appearance_mapping': AppDestination.stateAssetMapping,
        'appearance_library': AppDestination.assetLibrary,
        'records_stats': AppDestination.localStatistics,
        'records_cloud': AppDestination.cloudStatistics,
        'settings_open': AppDestination.overlaySettings,
      };

      expect(MenuActionIds.canonical, hasLength(17));
      for (final String actionId in MenuActionIds.canonical) {
        while (navigation.hasPending) {
          navigation.take();
        }
        final MenuActionResult result =
            await executor.execute(actionId, const <String, Object?>{});
        expect(result.message ?? '', isNot(contains('不支持的菜单动作')), reason: actionId);
        final AppDestination? expected = destinations[actionId];
        if (expected != null) {
          expect(result.status, MenuRequestStatus.completed, reason: actionId);
          expect(navigation.pending, <AppDestination>[expected], reason: actionId);
        } else {
          expect(result.status, isNot(MenuRequestStatus.pending), reason: actionId);
        }
      }
    });

    test('未知 id 显式失败（不静默成功）', () async {
      final MenuActionResult result =
          await contractExecutor().execute('mystery_action', const <String, Object?>{});
      expect(result.status, MenuRequestStatus.failed);
      expect(result.message, contains('不支持的菜单动作'));
    });

    test('旧 camelCase id 归一化为 canonical 后执行，并记录 received→normalized 日志', () async {
      final List<String> logs = <String>[];
      final StreamSubscription<LogRecord> sub =
          Logger.root.onRecord.listen((LogRecord r) => logs.add(r.message));
      addTearDown(sub.cancel);

      final MenuActionResult result =
          await contractExecutor().execute('nextAsset', const <String, Object?>{});

      expect(result.status, MenuRequestStatus.completed);
      expect(result.message ?? '', isNot(contains('不支持的菜单动作')));
      // 归一化后确实命中了"下一张"业务（换图 + 进入 manual 锁定）。
      expect(engine.manualLocks, isNotEmpty);
      expect(
        logs.any((String m) =>
            m.contains('menu.execute receivedActionId=nextAsset') &&
            m.contains('normalizedActionId=appearance_next')),
        isTrue,
        reason: '必须记录 received→normalized 的归一化日志：$logs',
      );
    });

    test('两条通道都归一化执行：menuRequest 推送 与 pullPendingMenuRequests 拉取', () async {
      final List<String> logs = <String>[];
      final StreamSubscription<LogRecord> sub =
          Logger.root.onRecord.listen((LogRecord r) => logs.add(r.message));
      addTearDown(sub.cancel);

      final _FakeBridge bridge = _FakeBridge();
      final _MemoryLedger ledger = _MemoryLedger();
      final OverlayMenuRequestConsumer consumer = OverlayMenuRequestConsumer(
        bridge: bridge,
        executor: contractExecutor(),
        ledger: ledger,
      );
      consumer.start();
      await pumpEventQueue();

      // 通道一：原生主动推送（旧 camelCase id）。
      final Map<String, Object?> pushed = await bridge.handler!(
        const OverlayMenuRequest(
          requestId: 'push-1',
          actionId: 'selectTheme',
          args: <String, Object?>{'themeId': 'blue'},
        ),
      );
      expect(pushed['status'], 'completed');
      expect(fakeOverlay.calls, contains('setMenuTheme:blue@1'));

      // 通道二：Dart 主动拉取（旧 camelCase id）。
      bridge.pending = <OverlayMenuRequest>[
        const OverlayMenuRequest(requestId: 'pull-1', actionId: 'showTodayUsage'),
      ];
      consumer.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await pumpEventQueue();
      expect(bridge.completed, contains('pull-1:completed'));

      // 两条路径都留下了 received→normalized 的归一化日志。
      expect(
        logs.any((String m) =>
            m.contains('receivedActionId=selectTheme') &&
            m.contains('normalizedActionId=settings_theme')),
        isTrue,
      );
      expect(
        logs.any((String m) =>
            m.contains('receivedActionId=showTodayUsage') &&
            m.contains('normalizedActionId=records_today')),
        isTrue,
      );
      // 完成日志带 canonical actionId（不是 enum 名 / 不是文案）。
      expect(
        logs.any((String m) =>
            m.contains('menu.complete requestId=push-1') &&
            m.contains('actionId=selectTheme') &&
            m.contains('status=completed')),
        isTrue,
      );

      consumer.dispose();
    });
  });
}

/// 假状态引擎：只关心"锁定 / 解除锁定"这两件事是否被真实调用。
class _FakeStateEngine implements StateEngine {
  _FakeStateEngine(this._snapshots);

  final ValueNotifier<StateSnapshot> _snapshots;

  final List<String?> manualLocks = <String?>[];
  int releaseCalls = 0;

  /// 按 ID 找素材（真实引擎走回退链；这里只需要"锁定到哪张"这一件事）。
  EmotionAsset? Function(String assetId)? resolveAsset;

  @override
  StateSnapshot get snapshot => _snapshots.value;

  @override
  ValueListenable<StateSnapshot> get snapshots => _snapshots;

  @override
  Stream<StateChangeEvent> get events => const Stream<StateChangeEvent>.empty();

  @override
  bool get isRunning => true;

  @override
  Future<void> start({required String ownerId, required String characterId}) async {}

  @override
  Future<void> setCharacter(String characterId) async {}

  @override
  Future<void> restore({
    required String ownerId,
    required String? characterId,
    String? assetId,
  }) async {}

  @override
  Future<void> requestState(StateChangeRequest request) async {}

  @override
  Future<void> lockManual({String? assetId, String? reason}) async {
    manualLocks.add(assetId);
    final EmotionAsset? resolved = assetId == null ? null : resolveAsset?.call(assetId);
    _snapshots.value = _snapshots.value.copyWith(
      state: SystemState.manual,
      manualAssetId: assetId,
      resolution: AssetResolution(
        asset: resolved ?? _snapshots.value.currentAsset,
        level: FallbackLevel.stateAsset,
        reason: reason ?? '手动锁定',
      ),
    );
  }

  @override
  Future<void> releaseManual() async {
    releaseCalls++;
    _snapshots.value = _snapshots.value.copyWith(
      state: SystemState.defaultState,
      clearManualAsset: true,
      clearNextAllowed: true,
    );
  }

  @override
  Future<void> refresh() async {}

  @override
  Future<void> dispose() async {}
}

/// 假素材仓库：只实现本阶段用到的那几个方法。
class _FakeCharacterRepository implements CharacterRepository {
  List<EmotionAsset> assets = <EmotionAsset>[];
  final List<String> favoriteCalls = <String>[];

  @override
  Future<List<EmotionAsset>> listRenderableAssets(String characterId) async =>
      assets.where((EmotionAsset a) => a.characterId == characterId).toList(growable: false);

  @override
  Future<LibrarySnapshot> loadSnapshot(String ownerId) async => LibrarySnapshot(
        packs: const <CharacterPack>[],
        characters: const <CharacterModel>[],
        assets: assets,
        mappings: const <StateMapping>[],
      );

  @override
  Future<void> setAssetFavorite(String assetId, bool favorite) async {
    favoriteCalls.add('$assetId:$favorite');
    assets = <EmotionAsset>[
      for (final EmotionAsset a in assets)
        if (a.id == assetId) a.copyWith(favorite: favorite) else a,
    ];
  }

  @override
  Future<EmotionAsset?> findAsset(String assetId) async {
    for (final EmotionAsset a in assets) {
      if (a.id == assetId) return a;
    }
    return null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 内存设置仓储（`SettingsController` 的真实依赖）。
class _MemorySettingsRepository implements SettingsRepository {
  AppSettings value = const AppSettings();

  @override
  Future<AppSettings> load(String ownerId) async => value;

  @override
  Future<void> save(String ownerId, AppSettings settings) async {
    value = settings.normalized();
  }

  @override
  Future<void> patch(String ownerId, Map<String, String?> values) async {
    final Map<String, String> merged = value.toKeyValues();
    values.forEach((String key, String? v) => merged[key] = v ?? '');
    value = AppSettings.fromKeyValues(merged);
  }

  @override
  Future<void> reset(String ownerId) async {
    value = const AppSettings();
  }
}

/// 内存台账。
///
/// [persisted] 可以在多个实例之间共享 —— 用来模拟"Activity 重建 / 冷启动后
/// 内存清了、但 `local_settings` 里的记录还在"。
class _MemoryLedger implements MenuRequestLedger {
  _MemoryLedger({Set<String>? persisted}) : persisted = persisted ?? <String>{};

  final Set<String> persisted;

  Set<String> get seen => persisted;

  @override
  Future<Set<String>> loadSeen() async => <String>{...persisted};

  @override
  Future<void> remember(String requestId) async {
    persisted.add(requestId);
  }
}

/// 假通道：不碰任何 MethodChannel，只记录"拉了哪些、回了哪些"。
///
/// 真实的 `AndroidOverlayMenuBridge` 由 `overlay_menu_bridge_test.dart` 覆盖；
/// 这里只验证消费者的编排逻辑。
class _FakeBridge extends AndroidOverlayMenuBridge {
  _FakeBridge() : super(channel: const MethodChannel('test/overlay-menu'));

  List<OverlayMenuRequest> pending = <OverlayMenuRequest>[];
  final List<String> completed = <String>[];

  Future<Map<String, Object?>> Function(OverlayMenuRequest request)? handler;
  bool handlerBound = false;
  bool handlerCleared = false;

  @override
  Future<List<OverlayMenuRequest>> pullPendingMenuRequests() async {
    final List<OverlayMenuRequest> out = pending;
    // 原生在回执前会一直把它算作待处理，因此这里**不**清空；
    // 重复拉取正是幂等台账要挡住的场景。
    return out;
  }

  @override
  Future<bool> completeMenuRequest({
    required String requestId,
    required MenuRequestStatus status,
    String? message,
  }) async {
    completed.add('$requestId:${status.wireName}');
    pending = pending
        .where((OverlayMenuRequest r) => r.requestId != requestId)
        .toList(growable: false);
    return true;
  }

  @override
  void bindMenuRequestHandler(
    Future<Map<String, Object?>> Function(OverlayMenuRequest request) next,
  ) {
    handler = next;
    handlerBound = true;
  }

  @override
  void clearMenuRequestHandler() {
    handler = null;
    handlerCleared = true;
  }
}

/// 假使用统计服务：只实现 `summarize`，用来钉住「今日时长」确实取自
/// **统计页同一个来源**（`UsageAnalyticsService.summarize`），而不是 Dart 采集器。
///
/// 通过 `implements`（而非继承）绕开真实构造器 —— 真实服务需要数据库 DAO，
/// 而本用例刻意不连数据库。
class _FakeUsageAnalytics implements UsageAnalyticsService {
  /// 概览里的「应用使用时间」（Android 页面的「今日总使用时长」用这一项）。
  int appActiveSeconds = 0;

  /// 概览里的「活跃使用时间」（设备级指标）—— 干扰项，不应被「今日时长」采用。
  int activeSeconds = 0;

  /// 记录被查询的窗口，用于断言与统计页用的是同一个「今天」窗口。
  final List<UsageWindow> windows = <UsageWindow>[];

  /// 非 null 时 [summarize] 抛错（模拟统计服务不可用）。
  Object? failWith;

  @override
  Future<UsageSummary> summarize(
    UsageWindow window, {
    Duration tzOffset = Duration.zero,
    DateTime? nowUtc,
  }) async {
    final Object? failure = failWith;
    if (failure != null) throw failure;
    windows.add(window);
    return UsageSummary(
      window: window,
      overview: UsageOverview(
        activeSeconds: activeSeconds,
        appActiveSeconds: appActiveSeconds,
      ),
      apps: const <AppUsageRow>[],
      categories: const <CategoryUsageRow>[],
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

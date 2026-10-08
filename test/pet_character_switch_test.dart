import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:petlife/character/character_repository.dart';
import 'package:petlife/character/models/character_model.dart';
import 'package:petlife/character/models/character_pack.dart';
import 'package:petlife/character/models/emotion_asset.dart';
import 'package:petlife/character/models/enums.dart';
import 'package:petlife/character/models/state_mapping.dart';
import 'package:petlife/character/pet_renderer.dart';
import 'package:petlife/character/sqlite_character_repository.dart';
import 'package:petlife/core/constants.dart';
import 'package:petlife/core/logger.dart';
import 'package:petlife/core/paths.dart';
import 'package:petlife/database/app_database.dart';
import 'package:petlife/settings/settings_controller.dart';
import 'package:petlife/settings/sqlite_settings_repository.dart';
import 'package:petlife/state_engine/default_state_engine.dart';
import 'package:petlife/state_engine/state_snapshot.dart';
import 'package:petlife/state_engine/system_state.dart';
import 'package:petlife/ui/library_controller.dart';
import 'package:petlife/ui/pet/pet_frame_controller.dart';
import 'package:petlife/ui/pet/pet_presenter.dart';
import 'package:petlife/ui/pet/pet_view.dart';

import 'support/sqlite_test_bootstrap.dart';
import 'package:petlife/character/pet_visual_bounds.dart';

/// Phase 4A 真机缺陷一：**激活角色后桌宠页面没有立即更新**。
///
/// 根因在 `PetPresenter`：它只订阅 `stateEngine.events`（状态切换事件），
/// 而 `DefaultStateEngine` 只在 `previousState != _state` 时才发事件。
/// "设为当前桌宠角色"只改角色、不改系统状态 → 没有事件 → 渲染器继续显示旧角色，
/// 直到重启应用（`start()` 里的首帧渲染）才更新。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SqliteTestBootstrap.ensureLoaded();

  const String ownerId = AppConstants.localOwnerId;

  late Directory dir;
  late AppDatabase db;
  late SqliteCharacterRepository repository;
  late SettingsController settings;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('petlife_char_switch');
    AppPaths.resetForTest();
    await AppPaths.initialize(overrideRoot: dir);
    await AppLog.initialize(logFile: AppPaths.instance.logFile);
    db = await AppDatabase.open(path: AppPaths.instance.databaseFile.path);
    repository = SqliteCharacterRepository.fromDatabase(db);
    settings = SettingsController(
      repository: SqliteSettingsRepository.fromDatabase(db),
      ownerId: ownerId,
    );
    await settings.load();
  });

  tearDown(() async {
    await AppDatabase.close();
    await AppLog.dispose();
    AppPaths.resetForTest();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  // ---------------------------------------------------------------------------
  // 单元测试：PetPresenter 必须跟随快照换素材
  // ---------------------------------------------------------------------------
  group('角色切换 → 渲染器立即换素材', () {
    test('仅 setCharacter（系统状态不变）也会立即切换素材', () async {
      final _CharSeed seed = await _seedCharacters(repository, dir);
      final DefaultStateEngine engine = DefaultStateEngine(repository: repository);
      final _RecordingRenderer renderer = _RecordingRenderer();
      final PetPresenter presenter =
          PetPresenter(engine: engine, renderer: renderer, settings: settings);
      addTearDown(() async {
        await presenter.dispose();
        await engine.dispose();
      });

      await engine.start(ownerId: ownerId, characterId: seed.mayaId);
      await presenter.start();
      expect(renderer.currentAssetId, seed.mayaAssetId, reason: '启动时应显示角色 A 的素材');

      await engine.setCharacter(seed.judgeId);
      await pumpEventQueue();

      expect(renderer.currentAssetId, seed.judgeAssetId,
          reason: '角色变了就必须换素材：不能等事件（状态没变时根本没有事件）');
    });

    test('同一素材的重复快照不会反复重新加载（去重，不重启动画）', () async {
      final _CharSeed seed = await _seedCharacters(repository, dir);
      final DefaultStateEngine engine = DefaultStateEngine(repository: repository);
      final _RecordingRenderer renderer = _RecordingRenderer();
      final PetPresenter presenter =
          PetPresenter(engine: engine, renderer: renderer, settings: settings);
      addTearDown(() async {
        await presenter.dispose();
        await engine.dispose();
      });

      await engine.start(ownerId: ownerId, characterId: seed.mayaId);
      await presenter.start();
      final int afterStart = renderer.displayed.length;

      // 只改设置（不换素材）→ 快照会更新，但不应重新 display。
      await settings.setScale(2.0);
      await engine.refresh();
      await pumpEventQueue();

      expect(renderer.displayed.length, afterStart,
          reason: '同一 assetId 不得重复 display（否则动画会被重新起播）');
    });

    test('通过 LibraryController.activateCharacter 激活后立即生效，重启后仍是该角色', () async {
      final _CharSeed seed = await _seedCharacters(repository, dir);
      final DefaultStateEngine engine = DefaultStateEngine(repository: repository);
      final _RecordingRenderer renderer = _RecordingRenderer();
      final PetPresenter presenter =
          PetPresenter(engine: engine, renderer: renderer, settings: settings);
      final LibraryController library = LibraryController(
        repository: repository,
        ownerId: ownerId,
        stateEngine: engine,
        settings: settings,
      )..onLibraryMutated = () async => engine.refresh();

      await engine.start(ownerId: ownerId, characterId: seed.mayaId);
      await presenter.start();
      await library.load();
      expect(renderer.currentAssetId, seed.mayaAssetId);

      // 真机操作：素材库 → 点「设为当前桌宠角色」。
      final String? error = await library.activateCharacter(seed.judgeId);
      await pumpEventQueue();

      expect(error, isNull, reason: '激活失败：$error');
      expect(renderer.currentAssetId, seed.judgeAssetId,
          reason: '激活后桌宠必须立即显示新角色（不切页、不重启）');

      await presenter.dispose();
      await engine.dispose();

      // ---- 模拟应用重启：新的引擎 / 渲染器 / 展示层 + 持久化的角色 ----
      final SettingsController restartedSettings = SettingsController(
        repository: SqliteSettingsRepository.fromDatabase(db),
        ownerId: ownerId,
      );
      await restartedSettings.load();
      final String? persisted = restartedSettings.settings.lastCharacterId ??
          restartedSettings.settings.defaultCharacterId;
      expect(persisted, seed.judgeId, reason: '激活必须持久化角色');

      final DefaultStateEngine restartedEngine = DefaultStateEngine(repository: repository);
      final _RecordingRenderer restartedRenderer = _RecordingRenderer();
      final PetPresenter restartedPresenter = PetPresenter(
        engine: restartedEngine,
        renderer: restartedRenderer,
        settings: restartedSettings,
      );
      addTearDown(() async {
        await restartedPresenter.dispose();
        await restartedEngine.dispose();
      });

      await restartedEngine.start(ownerId: ownerId, characterId: persisted!);
      await restartedPresenter.start();

      expect(restartedRenderer.currentAssetId, seed.judgeAssetId,
          reason: '重启后应恢复角色 B');
    });
  });

  // ---------------------------------------------------------------------------
  // Widget 测试：桌宠控件必须按最新快照立即重绘
  // ---------------------------------------------------------------------------
  group('桌宠页面（Widget）', () {
    testWidgets('只 pump 一次：角色 A → B 后图片组件立即使用 B 的素材', (WidgetTester tester) async {
      // 全内存装置：testWidgets 的 fake-async 里不能做真实磁盘 / 数据库 I/O。
      const String mayaId = 'c-maya';
      const String judgeId = 'c-judge';
      const String mayaAssetId = 'a-maya';
      const String judgeAssetId = 'a-judge';

      final _MemoryRepository memory = _MemoryRepository(
        characters: <String, CharacterModel>{
          mayaId: _character(mayaId, 'Maya'),
          judgeId: _character(judgeId, 'Judge'),
        },
        assets: <String, List<EmotionAsset>>{
          mayaId: <EmotionAsset>[_asset(mayaId, mayaAssetId, 'Angry')],
          judgeId: <EmotionAsset>[_asset(judgeId, judgeAssetId, 'Shocked')],
        },
      );

      final DefaultStateEngine engine = DefaultStateEngine(repository: memory);
      final _RecordingRenderer renderer = _RecordingRenderer();
      final PetPresenter presenter =
          PetPresenter(engine: engine, renderer: renderer, settings: settings);
      addTearDown(() async {
        await presenter.dispose();
        await engine.dispose();
      });

      await engine.start(ownerId: ownerId, characterId: mayaId);
      await presenter.start();

      int pageBuilds = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            // 与 MobileShell 的桌宠页同一套绑定：监听 stateEngine.snapshots。
            body: ValueListenableBuilder<StateSnapshot>(
              valueListenable: engine.snapshots,
              builder: (BuildContext context, StateSnapshot snapshot, Widget? _) {
                pageBuilds++;
                return Center(
                  child: PetView(
                    renderer: renderer,
                    scale: 1,
                    smoothScaling: false,
                    opacity: 1,
                    lockPosition: true,
                    manageWindowSize: false,
                  ),
                );
              },
            ),
          ),
        ),
      );
      await tester.pump();

      PetLayerPainter painter() => tester
          .widget<CustomPaint>(
            find.descendant(of: find.byType(PetView), matching: find.byType(CustomPaint)),
          )
          .painter! as PetLayerPainter;

      expect(renderer.currentAssetId, mayaAssetId);
      expect(painter().layers.single.assetId, mayaAssetId, reason: '初始应显示角色 A');
      final int buildsAfterFirstFrame = pageBuilds;

      // 切换角色；期间**不重新创建页面**（不再 pumpWidget）。
      await engine.setCharacter(judgeId);
      await tester.pump();

      expect(painter().layers.single.assetId, judgeAssetId,
          reason: '角色切换后图片组件必须立即使用新角色的素材');
      expect(pageBuilds, greaterThan(buildsAfterFirstFrame),
          reason: '页面必须响应 stateEngine.snapshots 的重建');
    });
  });
}

// -----------------------------------------------------------------------------
// 装置
// -----------------------------------------------------------------------------

/// 记录每次 display，供断言"渲染器到底换了没有"。
class _RecordingRenderer extends PetRenderer {
  final List<String?> displayed = <String?>[];
  String? _current;
  List<PetRenderLayer> _layers = const <PetRenderLayer>[];

  @override
  String? get currentAssetId => _current;

  @override
  bool get isAnimated => false;

  @override
  int? get currentFrameIndex => 0;

  @override
  int get remainingMsInCycle => 0;

  @override
  ui.Size? get contentSize => const ui.Size(32, 32);

  @override
  PetVisualBounds? get visualBounds =>
      PetVisualBounds.full;

  @override
  Future<PetVisualBounds> ensureVisualBounds() async => PetVisualBounds.full;

  @override
  List<PetRenderLayer> get layers => _layers;

  @override
  Future<void> display(EmotionAsset? asset, {bool immediate = false}) async {
    _current = asset?.id;
    displayed.add(asset?.id);
    _layers = <PetRenderLayer>[
      if (asset == null)
        const PlaceholderRenderLayer(opacity: 1)
      else
        _Layer(asset.id),
    ];
    notifyListeners();
  }

  @override
  void setLoop(bool loop) {}

  @override
  void setCrossFadeMs(int ms) {}

  @override
  Future<void> clear() async {
    _current = null;
    _layers = const <PetRenderLayer>[];
    notifyListeners();
  }
}

class _Layer extends PetRenderLayer {
  const _Layer(String id) : super(assetId: id, opacity: 1);

  @override
  bool get isPlaceholder => false;
}

/// 内存仓库：Widget 测试里避免真实磁盘 I/O。
class _MemoryRepository implements CharacterRepository {
  _MemoryRepository({required this.characters, required this.assets});

  final Map<String, CharacterModel> characters;
  final Map<String, List<EmotionAsset>> assets;

  @override
  Future<CharacterModel?> findCharacter(String characterId) async => characters[characterId];

  @override
  Future<List<EmotionAsset>> listRenderableAssets(String characterId) async =>
      assets[characterId] ?? const <EmotionAsset>[];

  @override
  Future<Map<SystemState, List<StateMapping>>> groupedMappings(String characterId) async =>
      <SystemState, List<StateMapping>>{};

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('测试替身未实现 ${invocation.memberName}');
}

CharacterModel _character(String id, String name) => CharacterModel(
      id: id,
      packId: 'pack',
      ownerId: AppConstants.localOwnerId,
      internalName: name,
      displayName: name,
      enabled: true,
      createdAt: DateTime(2026, 9, 29),
      updatedAt: DateTime(2026, 9, 29),
    );

EmotionAsset _asset(String characterId, String id, String emotion) => EmotionAsset(
      id: id,
      characterId: characterId,
      emotionName: emotion,
      variantName: '1',
      filePath: '/nonexistent/$id.png',
      fileHash: 'hash-$id',
      mimeType: 'image/png',
      fileSize: 128,
      width: 4,
      height: 4,
      frameCount: 1,
      isAnimated: false,
      hasAlpha: true,
      enabled: true,
      validationStatus: ValidationStatus.valid,
      createdAt: DateTime(2026, 9, 29),
    );

class _CharSeed {
  const _CharSeed({
    required this.mayaId,
    required this.judgeId,
    required this.mayaAssetId,
    required this.judgeAssetId,
  });

  final String mayaId;
  final String judgeId;
  final String mayaAssetId;
  final String judgeAssetId;
}

Future<_CharSeed> _seedCharacters(
  SqliteCharacterRepository repository,
  Directory dir,
) async {
  final CharacterPack pack = await repository.ensurePack(
    ownerId: AppConstants.localOwnerId,
    name: 'Ace Attorney',
    sourceType: PackSourceType.folder,
  );
  final String mayaId = (await repository.ensureCharacter(
    packId: pack.id,
    ownerId: AppConstants.localOwnerId,
    internalName: 'Maya',
  ))
      .id;
  final String judgeId = (await repository.ensureCharacter(
    packId: pack.id,
    ownerId: AppConstants.localOwnerId,
    internalName: 'Judge',
  ))
      .id;

  final String mayaAssetId = await _upsertAsset(repository, dir, mayaId, 'Angry');
  final String judgeAssetId = await _upsertAsset(repository, dir, judgeId, 'Shocked');
  return _CharSeed(
    mayaId: mayaId,
    judgeId: judgeId,
    mayaAssetId: mayaAssetId,
    judgeAssetId: judgeAssetId,
  );
}

Future<String> _upsertAsset(
  SqliteCharacterRepository repository,
  Directory dir,
  String characterId,
  String emotion,
) async {
  final String id = '$characterId::$emotion';
  await repository.upsertAsset(EmotionAsset(
    id: id,
    characterId: characterId,
    emotionName: emotion,
    variantName: '1',
    filePath: p.join(dir.path, 'assets', '$id.png'),
    originalFilePath: null,
    fileHash: 'hash-$id',
    mimeType: 'image/png',
    fileSize: 128,
    width: 4,
    height: 4,
    frameCount: 1,
    isAnimated: false,
    hasAlpha: true,
    enabled: true,
    validationStatus: ValidationStatus.valid,
    createdAt: DateTime(2026, 9, 29),
  ));
  return id;
}

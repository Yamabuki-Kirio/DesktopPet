import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:petlife/character/models/character_pack.dart';
import 'package:petlife/character/models/emotion_asset.dart';
import 'package:petlife/character/models/enums.dart';
import 'package:petlife/character/sqlite_character_repository.dart';
import 'package:petlife/core/constants.dart';
import 'package:petlife/core/logger.dart';
import 'package:petlife/core/paths.dart';
import 'package:petlife/database/app_database.dart';
import 'package:petlife/settings/settings_controller.dart';
import 'package:petlife/settings/sqlite_settings_repository.dart';
import 'package:petlife/state_engine/default_state_engine.dart';
import 'package:petlife/ui/library_controller.dart';

import 'support/sqlite_test_bootstrap.dart';

/// Phase 4A 真机缺陷二：**导入角色后无法作为桌宠使用**。
///
/// 根因是 `LibraryController.activateCharacter()` 只做了
/// `selectCharacter()` + `refresh()`，而 `refresh()` 只重载**已经绑定的**角色，
/// 从不切换状态引擎 —— 播放按钮看似执行，桌宠仍然绑着旧角色。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SqliteTestBootstrap.ensureLoaded();

  const String owner = AppConstants.localOwnerId;

  late Directory dir;
  late AppDatabase db;
  late SqliteCharacterRepository repository;
  late SettingsController settings;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('petlife_activate_test');
    AppPaths.resetForTest();
    await AppPaths.initialize(overrideRoot: dir);
    await AppLog.initialize(logFile: AppPaths.instance.logFile);

    db = await AppDatabase.open(path: AppPaths.instance.databaseFile.path);
    repository = SqliteCharacterRepository.fromDatabase(db);
    settings = SettingsController(
      repository: SqliteSettingsRepository.fromDatabase(db),
      ownerId: owner,
    );
    await settings.load();
  });

  tearDown(() async {
    await AppDatabase.close();
    await AppLog.dispose();
    AppPaths.resetForTest();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  /// 三个角色：Maya / Judge 各有一张合法素材，Edgeworth 没有任何素材
  /// （用来验证"没有可渲染素材时禁止激活"）。
  Future<_Seed> seedLibrary() async {
    final CharacterPack pack = await repository.ensurePack(
      ownerId: owner,
      name: 'Ace Attorney',
      sourceType: PackSourceType.folder,
    );
    final String maya = (await repository.ensureCharacter(
      packId: pack.id,
      ownerId: owner,
      internalName: 'Maya',
    ))
        .id;
    final String judge = (await repository.ensureCharacter(
      packId: pack.id,
      ownerId: owner,
      internalName: 'Judge',
    ))
        .id;
    final String edgeworth = (await repository.ensureCharacter(
      packId: pack.id,
      ownerId: owner,
      internalName: 'Edgeworth',
    ))
        .id;

    await _addAsset(repository, dir, maya, 'Angry');
    await _addAsset(repository, dir, judge, 'Shocked');
    return _Seed(maya: maya, judge: judge, edgeworth: edgeworth);
  }

  LibraryController newLibrary(DefaultStateEngine engine) => LibraryController(
        repository: repository,
        ownerId: owner,
        stateEngine: engine,
        settings: settings,
      )..onLibraryMutated = () async => engine.refresh();

  test('状态引擎未启动时，激活第一个角色会自动 start 并立即生效', () async {
    final _Seed seed = await seedLibrary();
    final DefaultStateEngine engine = DefaultStateEngine(repository: repository);
    final LibraryController library = newLibrary(engine);
    await library.load();

    expect(engine.isRunning, isFalse, reason: '激活前引擎尚未启动');

    final String? error = await library.activateCharacter(seed.maya);

    expect(error, isNull, reason: '激活失败：$error');
    expect(engine.isRunning, isTrue);
    expect(engine.snapshot.currentCharacter?.id, seed.maya);
    expect(library.activeCharacterId, seed.maya);

    await engine.dispose();
  });

  test('引擎已启动时，激活新角色 → StateEngine.currentCharacter 立即变化', () async {
    final _Seed seed = await seedLibrary();
    final DefaultStateEngine engine = DefaultStateEngine(repository: repository);
    final LibraryController library = newLibrary(engine);
    await library.load();

    await library.activateCharacter(seed.maya);
    expect(engine.snapshot.currentCharacter?.id, seed.maya);

    final String? error = await library.activateCharacter(seed.judge);

    expect(error, isNull);
    expect(engine.snapshot.currentCharacter?.id, seed.judge,
        reason: '激活后桌宠必须绑定到新角色（旧实现的 refresh() 做不到这一点）');
    expect(library.activeCharacterId, seed.judge);

    await engine.dispose();
  });

  test('选择列表项目 ≠ 设为当前桌宠角色', () async {
    final _Seed seed = await seedLibrary();
    final DefaultStateEngine engine = DefaultStateEngine(repository: repository);
    final LibraryController library = newLibrary(engine);
    await library.load();

    await library.activateCharacter(seed.maya);
    library.selectCharacter(seed.judge);

    expect(library.selectedCharacterId, seed.judge);
    expect(engine.snapshot.currentCharacter?.id, seed.maya,
        reason: '仅选中不该影响桌宠绑定');
    expect(library.activeCharacterId, seed.maya);

    await engine.dispose();
  });

  test('激活状态持久化：重启后仍使用该角色', () async {
    final _Seed seed = await seedLibrary();
    final DefaultStateEngine engine = DefaultStateEngine(repository: repository);
    final LibraryController library = newLibrary(engine);
    await library.load();

    await library.activateCharacter(seed.judge);
    await engine.dispose();

    // 模拟应用重启：设置与素材库都从同一份数据库重新读取。
    final SettingsController restartedSettings = SettingsController(
      repository: SqliteSettingsRepository.fromDatabase(db),
      ownerId: owner,
    );
    await restartedSettings.load();

    expect(restartedSettings.settings.lastCharacterId, seed.judge,
        reason: 'lastCharacterId 必须落库，否则重启后桌宠会退回旧角色');
    expect(restartedSettings.settings.defaultCharacterId, seed.judge);

    final DefaultStateEngine restartedEngine = DefaultStateEngine(repository: repository);
    final LibraryController restartedLibrary = LibraryController(
      repository: repository,
      ownerId: owner,
      stateEngine: restartedEngine,
      settings: restartedSettings,
    );
    await restartedLibrary.load();

    expect(restartedLibrary.activeCharacterId, seed.judge,
        reason: '"使用中"标记必须能在重启后恢复');

    // 与 MobileShell._bootstrap 相同：用持久化的角色启动引擎。
    final String? characterId =
        restartedSettings.settings.lastCharacterId ?? restartedSettings.settings.defaultCharacterId;
    await restartedEngine.start(ownerId: owner, characterId: characterId!);
    expect(restartedEngine.snapshot.currentCharacter?.id, seed.judge);

    await restartedEngine.dispose();
  });

  test('没有可渲染素材的角色禁止激活，并给出明确原因', () async {
    final _Seed seed = await seedLibrary();
    final DefaultStateEngine engine = DefaultStateEngine(repository: repository);
    final LibraryController library = newLibrary(engine);
    await library.load();

    final String? error = await library.activateCharacter(seed.edgeworth);

    expect(error, isNotNull);
    expect(error, contains('没有可用素材'));
    expect(engine.isRunning, isFalse, reason: '被拒绝的激活不得启动引擎');
    expect(library.activeCharacterId, isNot(seed.edgeworth));

    await engine.dispose();
  });

  test('设置默认素材后桌宠立即刷新到新的默认图片', () async {
    final _Seed seed = await seedLibrary();
    final DefaultStateEngine engine = DefaultStateEngine(repository: repository);
    final LibraryController library = newLibrary(engine);
    await library.load();

    await library.activateCharacter(seed.maya);
    // 追加第二张素材，随后把它设为默认。
    final String second = await _addAsset(repository, dir, seed.maya, 'Nod');
    await library.load();
    expect(engine.snapshot.currentCharacter?.defaultAssetId, isNull);

    await library.setDefaultAsset(seed.maya, second);

    expect(engine.snapshot.currentCharacter?.defaultAssetId, second,
        reason: '设置默认素材后桌宠必须立即刷新（refresh 重载角色）');

    await engine.dispose();
  });
}

Future<String> _addAsset(
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
    filePath: p.join(dir.path, 'assets', '$id.webp'),
    originalFilePath: null,
    fileHash: 'hash-$id',
    mimeType: 'image/webp',
    fileSize: 128,
    width: 4,
    height: 4,
    frameCount: 1,
    isAnimated: false,
    hasAlpha: true,
    enabled: true,
    validationStatus: ValidationStatus.valid,
    createdAt: DateTime.now(),
  ));
  return id;
}

class _Seed {
  const _Seed({
    required this.maya,
    required this.judge,
    required this.edgeworth,
  });

  final String maya;
  final String judge;
  final String edgeworth;
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:petlife/asset_decoder/asset_validator.dart';
import 'package:petlife/asset_decoder/flutter_asset_decoder.dart';
import 'package:petlife/asset_import/default_asset_importer.dart';
import 'package:petlife/asset_import/import_models.dart';
import 'package:petlife/character/character_repository.dart';
import 'package:petlife/character/models/character_model.dart';
import 'package:petlife/character/models/character_pack.dart';
import 'package:petlife/character/models/emotion_asset.dart';
import 'package:petlife/character/models/enums.dart';
import 'package:petlife/character/models/state_mapping.dart';
import 'package:petlife/character/sqlite_character_repository.dart';
import 'package:petlife/core/constants.dart';
import 'package:petlife/core/logger.dart';
import 'package:petlife/core/paths.dart';
import 'package:petlife/core/result.dart';
import 'package:petlife/database/app_database.dart';

import 'filename_parser_test.dart' show locateAceAttorneyFolder;
import 'support/sqlite_test_bootstrap.dart';

/// 真实素材导入的端到端集成测试。
///
/// 覆盖缺陷 D-01 暴露出来的两条链路：
/// 1. `Ids.namespace` 非法 → 每个文件都抛 `FormatException` → 13/13 全失败；
/// 2. 失败发生在 `ensurePack` / `ensureCharacter` 之后 → 可能留下孤儿 pack/character。
///
/// 这里走的是**真实代码路径**：真实的 WebP 文件、真实的 magic bytes 校验、
/// 真实的 `ui.instantiateImageCodec` 解码验证、真实的 SQLite（临时库文件）。
void main() {
  const String owner = AppConstants.localOwnerId;

  /// 回滚用例用独立 owner，避免与真实导入用例互相干扰（不依赖用例执行顺序）。
  const String rollbackOwner = 'test.rollback';

  /// 提交用例同样用独立 owner，保证「回滚后为空」的断言与用例顺序无关。
  const String commitOwner = 'test.commit';

  // 可空 + null 判断：setUpAll 若在引导阶段失败，tearDownAll 仍会被调用，
  // late 变量会再抛 LateInitializationError 把真实错误盖住。
  Directory? root;
  late SqliteCharacterRepository repository;
  late DefaultAssetImporter importer;
  final Directory? folder = locateAceAttorneyFolder();

  setUpAll(() async {
    // 图片解码与数据库都依赖引擎/原生库，先确保两者就绪。
    TestWidgetsFlutterBinding.ensureInitialized();
    SqliteTestBootstrap.ensureLoaded();

    final Directory dir = Directory.systemTemp.createTempSync('petlife_import_test');
    root = dir;
    AppPaths.resetForTest();
    await AppPaths.initialize(overrideRoot: dir);
    await AppLog.initialize(logFile: AppPaths.instance.logFile);

    final AppDatabase database =
        await AppDatabase.open(path: AppPaths.instance.databaseFile.path);
    repository = SqliteCharacterRepository.fromDatabase(database);
    importer = DefaultAssetImporter(
      repository: repository,
      validator: const DefaultAssetValidator(),
      decoder: FlutterAssetDecoder(),
    );
  });

  tearDownAll(() async {
    await AppDatabase.close();
    await AppLog.dispose();
    AppPaths.resetForTest();
    if (root != null && root!.existsSync()) root!.deleteSync(recursive: true);
  });

  test('导入 Ace Attorney 文件夹：13 个全部成功，1 包 / 1 角色 / 13 素材', () async {
    if (folder == null) {
      markTestSkipped('未找到 Ace Attorney 素材目录，跳过真实素材导入用例');
      return;
    }

    // ---------------------------------------------------------------- 第一次导入
    final Result<ImportReport> first = await importer.import(
      FolderImportRequest(ownerId: owner, folderPath: folder.path),
    );
    expect(first.isOk, isTrue, reason: '导入整体失败：${first.failureOrNull}');
    final ImportReport report = first.valueOrNull!;

    expect(report.scannedCount, 13, reason: '应扫描到 13 个候选文件');
    expect(report.skippedCount, 0, reason: '不该有被跳过的文件');
    expect(
      report.failedCount,
      0,
      reason: '有文件导入失败：\n${_describeFailures(report.failed)}',
    );
    expect(report.importedCount, 13, reason: '应成功识别 13 个素材');
    expect(report.animatedCount, 13, reason: '13 个素材都是多帧动态 WebP');
    expect(report.staticCount, 0);

    expect(report.packNames, <String>['Ace Attorney']);
    expect(report.characterNames, <String>['Maya']);

    // 界面/日志里展示的正是 summary()，逐字对齐需求里的验收话术。
    expect(report.summary(), contains('成功识别 13 个'));
    expect(report.summary(), contains('损坏或跳过 0 个'));

    // ------------------------------------------------------------- 数据库落库结果
    final List<CharacterPack> packs = await repository.listPacks(owner);
    expect(packs.length, 1, reason: '应只生成 1 个作品包');
    expect(packs.single.name, 'Ace Attorney');

    final List<CharacterModel> characters = await repository.listCharacters(owner);
    expect(characters.length, 1, reason: '应只生成 1 个角色');
    expect(characters.single.internalName, 'Maya');
    expect(characters.single.packId, packs.single.id);

    final String characterId = characters.single.id;
    final List<EmotionAsset> assets = await repository.listAllAssets(characterId);
    expect(assets.length, 13, reason: '应生成 13 个素材记录');

    // 13 个必须互不覆盖：ID 唯一、情绪唯一。
    expect(assets.map((EmotionAsset a) => a.id).toSet().length, 13, reason: '素材 ID 出现重复');
    expect(
      assets.map((EmotionAsset a) => a.emotionName).toSet().length,
      13,
      reason: '情绪名出现重复，说明文件名解析把不同文件归到了同一情绪',
    );

    final String assetsRoot = p.normalize(AppPaths.instance.assetsRoot.path);
    for (final EmotionAsset a in assets) {
      // 托管副本真实存在，且位于应用数据目录内。
      expect(File(a.filePath).existsSync(), isTrue, reason: '托管副本缺失：${a.filePath}');
      expect(
        p.isWithin(assetsRoot, p.normalize(a.filePath)),
        isTrue,
        reason: '托管副本跑到应用数据目录之外：${a.filePath}',
      );
      // 原始素材只被读取：originalFilePath 必须指向用户源目录。
      final String? original = a.originalFilePath;
      expect(original, isNotNull, reason: '导入必须记录原始素材路径（${a.emotionName}）');
      if (original != null) {
        expect(
          p.isWithin(folder.path, p.normalize(original)),
          isTrue,
          reason: '原始路径指向了源目录之外：$original',
        );
      }
    }

    // 首次导入应生成建议状态映射。
    final List<StateMapping> mappings = await repository.listMappings(characterId);
    expect(mappings, isNotEmpty, reason: '首次导入应自动生成建议状态映射');
    expect(report.seededMappingCount, greaterThan(0));

    // 「成功识别 13 个」这行日志就是界面反馈的来源。
    final String logText = AppLog.exportRecentLogText();
    expect(logText, contains('成功识别 13 个'));
    expect(logText, contains('损坏 0 个，跳过 0 个'));

    // ------------------------------------------------------------------ 二次导入
    final Result<ImportReport> second = await importer.import(
      FolderImportRequest(ownerId: owner, folderPath: folder.path),
    );
    expect(second.isOk, isTrue, reason: '二次导入整体失败：${second.failureOrNull}');
    final ImportReport again = second.valueOrNull!;
    expect(again.importedCount, 13);
    expect(again.failedCount, 0, reason: _describeFailures(again.failed));

    expect((await repository.listPacks(owner)).length, 1, reason: '二次导入产生了新的作品包');
    expect((await repository.listCharacters(owner)).length, 1, reason: '二次导入产生了新的角色');

    final List<EmotionAsset> afterSecond = await repository.listAllAssets(characterId);
    expect(afterSecond.length, 13, reason: '二次导入产生了重复素材记录');
    expect(
      afterSecond.map((EmotionAsset a) => a.id).toSet(),
      assets.map((EmotionAsset a) => a.id).toSet(),
      reason: '二次导入的素材 ID 与首次不一致，说明 ID 不是确定性的',
    );
  });

  test('写入中途失败时整批回滚：不留下孤儿 pack / character', () async {
    // 复刻缺陷 D-01 的失败形态：pack 与 character 已经写完，
    // 随后在生成 assetId / 写托管副本时抛异常。
    await expectLater(
      repository.transaction((CharacterRepository repo) async {
        final CharacterPack pack = await repo.ensurePack(
          ownerId: rollbackOwner,
          name: 'Rollback Pack',
          sourceType: PackSourceType.folder,
        );
        await repo.ensureCharacter(
          packId: pack.id,
          ownerId: rollbackOwner,
          internalName: 'Maya',
        );
        throw StateError('模拟导入中途失败（assetId 生成 / 写盘异常）');
      }),
      throwsA(isA<StateError>()),
    );

    // 事务未提交 → 三条写入都不该留下痕迹。
    expect(
      await repository.listPacks(rollbackOwner),
      isEmpty,
      reason: '回滚后仍留下孤儿作品包，重新导入时会被 ensurePack 当成「已存在」复用',
    );
    expect(
      await repository.listCharacters(rollbackOwner),
      isEmpty,
      reason: '回滚后仍留下孤儿角色',
    );
  });

  test('事务提交后数据可见（确认回滚不是因为「整个事务都不生效」）', () async {
    final CharacterPack pack = await repository.transaction(
      (CharacterRepository repo) => repo.ensurePack(
        ownerId: commitOwner,
        name: 'Committed Pack',
        sourceType: PackSourceType.folder,
      ),
    );
    expect(
      (await repository.listPacks(commitOwner)).map((CharacterPack p) => p.id),
      contains(pack.id),
    );
  });
}

String _describeFailures(List<FailedItem> failed) {
  if (failed.isEmpty) return '（无）';
  return failed
      .map((FailedItem f) =>
          '  ${p.basename(f.path)} -> ${f.failure.kind.name}: ${f.failure.message}'
          '${f.failure.detail == null ? '' : ' | ${f.failure.detail}'}')
      .join('\n');
}

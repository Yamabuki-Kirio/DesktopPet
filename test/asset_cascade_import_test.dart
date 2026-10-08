import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:petlife/asset_decoder/asset_validator.dart';
import 'package:petlife/asset_decoder/flutter_asset_decoder.dart';
import 'package:petlife/asset_import/default_asset_importer.dart';
import 'package:petlife/asset_import/import_models.dart';
import 'package:petlife/character/models/character_model.dart';
import 'package:petlife/character/models/character_pack.dart';
import 'package:petlife/character/models/emotion_asset.dart';
import 'package:petlife/character/models/enums.dart';
import 'package:petlife/character/sqlite_character_repository.dart';
import 'package:petlife/core/constants.dart';
import 'package:petlife/core/logger.dart';
import 'package:petlife/core/paths.dart';
import 'package:petlife/core/result.dart';
import 'package:petlife/database/app_database.dart';
import 'package:petlife/database/dao/character_dao.dart';
import 'package:petlife/database/dao/pack_dao.dart';
import 'package:petlife/database/schema.dart';

import 'support/sqlite_test_bootstrap.dart';

/// 真机缺陷回归：**"导入 3 张、报告成功 3 个、素材库只剩 1 个"**。
///
/// 根因（客户端 SQLite 数据层）：
/// * `character_models.pack_id` / `emotion_assets.character_id` 上带
///   `ON DELETE CASCADE`；
/// * `PackDao.upsert` / `CharacterDao.upsert` 用的是 `INSERT OR REPLACE` ——
///   SQLite 的 REPLACE **先 DELETE 冲突行再 INSERT**，于是"更新作品包"
///   会把该包下的角色与素材全部级联删除；
/// * 多文件导入时每个文件都用不同的 `p.dirname(原始路径)` 调用 `ensurePack`，
///   于是每写一张就删掉前面所有素材，最终只剩最后一张。
///
/// 这组测试全部使用**真实 SQLite + 真实外键**，因此能真正复现级联删除，
/// 这是内存替身永远发现不了的。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SqliteTestBootstrap.ensureLoaded();

  const String ownerId = AppConstants.localOwnerId;
  const String packName = '我的素材';
  const String characterName = 'Maya';

  late Directory dir;
  late AppDatabase db;
  late SqliteCharacterRepository repository;
  late DefaultAssetImporter importer;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('petlife_cascade_test');
    AppPaths.resetForTest();
    await AppPaths.initialize(overrideRoot: dir);
    await AppLog.initialize(logFile: AppPaths.instance.logFile);
    db = await AppDatabase.open(path: AppPaths.instance.databaseFile.path);
    repository = SqliteCharacterRepository.fromDatabase(db);
    importer = DefaultAssetImporter(
      repository: repository,
      validator: const DefaultAssetValidator(),
      decoder: FlutterAssetDecoder(),
    );
  });

  tearDown(() async {
    if (AppDatabase.isOpen) await AppDatabase.close();
    await AppLog.dispose();
    AppPaths.resetForTest();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  /// 直接查 SQL 统计某角色名下的素材行数（绕开 Dart 层，最接近真机事实）。
  ///
  /// 用 [AppDatabase.instance] 而不是 setUp 里捕获的句柄：本文件有一个用例
  /// 会关闭并重新打开数据库，「重开后数据还在吗」必须查新连接才算数。
  Future<int> countAssetsByCharacterName(String internalName) async {
    final List<Map<String, Object?>> rows = await AppDatabase.instance.raw.rawQuery(
      'SELECT COUNT(*) AS c FROM emotion_assets a '
      'JOIN character_models c ON c.id = a.character_id '
      'WHERE c.internal_name = ?',
      <Object?>[internalName],
    );
    return rows.first['c']! as int;
  }

  Uint8List png({int size = 4}) {
    final img.Image image = img.Image(width: size, height: size);
    img.fill(image, color: img.ColorRgb8(30, 144, 200));
    return Uint8List.fromList(img.encodePng(image));
  }

  /// 3 张普通文件名图片，每张带**不同的原始来源**（真机：Android SAF 临时副本）。
  Future<List<SelectedImportFile>> writeBatch() async {
    final List<SelectedImportFile> files = <SelectedImportFile>[];
    const List<String> names = <String>['a.png', 'b.png', 'c.png'];
    for (int i = 0; i < names.length; i++) {
      final File file = File(p.join(dir.path, 'batch', names[i]));
      await file.parent.create(recursive: true);
      await file.writeAsBytes(png(size: 4 + i));
      files.add(SelectedImportFile(
        localPath: file.path,
        originalName: names[i],
        originalSource: 'saf://${names[i]}',
      ));
    }
    return files;
  }

  Future<Result<ImportReport>> importBatch(List<SelectedImportFile> files) =>
      importer.import(FileImportRequest(
        ownerId: ownerId,
        files: files,
        packName: packName,
        characterName: characterName,
      ));

  // ---------------------------------------------------------------------------
  // 外键与父表 upsert
  // ---------------------------------------------------------------------------
  group('父表 upsert 不得级联删除子表', () {
    test('前置条件：外键约束确实处于开启状态', () async {
      final List<Map<String, Object?>> rows = await db.raw.rawQuery('PRAGMA foreign_keys');
      expect(rows.first.values.first, 1,
          reason: '外键没开的话，"级联删除"这类回归测试会假通过');
    });

    test('PackDao.upsert 更新作品包：角色与素材必须都还在', () async {
      final Result<ImportReport> result = await importBatch(await writeBatch());
      expect(result.isOk, isTrue, reason: '${result.failureOrNull}');

      final CharacterPack pack = (await repository.listPacks(ownerId)).single;
      final CharacterModel character = (await repository.listCharacters(ownerId)).single;

      // 直接走 DAO 更新父表（模拟"改写 pack 来源"）。
      await PackDao(db.raw).upsert(pack.copyWith(
        sourceType: PackSourceType.files,
        sourcePath: r'D:\somewhere_else',
        updatedAt: DateTime.now(),
      ));

      expect(await repository.listCharacters(ownerId), hasLength(1),
          reason: '更新作品包把角色级联删掉了（INSERT OR REPLACE 缺陷）');
      expect(await repository.listAllAssets(character.id), hasLength(3),
          reason: '更新作品包把素材级联删掉了（INSERT OR REPLACE 缺陷）');
    });

    test('CharacterDao.upsert 更新角色：素材必须还在', () async {
      final Result<ImportReport> result = await importBatch(await writeBatch());
      expect(result.isOk, isTrue, reason: '${result.failureOrNull}');

      final CharacterModel character = (await repository.listCharacters(ownerId)).single;
      await CharacterDao(db.raw).upsert(character.copyWith(
        displayName: 'Maya（改名）',
        updatedAt: DateTime.now(),
      ));

      expect((await repository.findCharacter(character.id))!.displayName, 'Maya（改名）');
      expect(await repository.listAllAssets(character.id), hasLength(3),
          reason: '更新角色把素材级联删掉了（INSERT OR REPLACE 缺陷）');
    });

    test('repository.ensurePack 反复改写来源：原角色与素材仍在', () async {
      final Result<ImportReport> result = await importBatch(await writeBatch());
      expect(result.isOk, isTrue, reason: '${result.failureOrNull}');
      final CharacterModel character = (await repository.listCharacters(ownerId)).single;

      // 复刻旧实现"每张图片改写一次 pack.source_path"的触发条件。
      for (final String path in <String>[r'D:\p1', r'D:\p2', r'D:\p3']) {
        await repository.ensurePack(
          ownerId: ownerId,
          name: packName,
          sourceType: PackSourceType.folder,
          sourcePath: path,
        );
      }

      expect(await repository.listAllAssets(character.id), hasLength(3));
    });

    test('反向验证：真正删除作品包时级联仍然生效（证明外键是"武装"的）', () async {
      final Result<ImportReport> result = await importBatch(await writeBatch());
      expect(result.isOk, isTrue, reason: '${result.failureOrNull}');
      final CharacterPack pack = (await repository.listPacks(ownerId)).single;
      final CharacterModel character = (await repository.listCharacters(ownerId)).single;

      // deletePack 会显式清理，这里直接删行以验证 FK 级联本身。
      await db.raw.delete(DbSchema.tablePacks, where: 'id = ?', whereArgs: <Object?>[pack.id]);

      expect(await repository.listCharacters(ownerId), isEmpty);
      expect(await repository.listAllAssets(character.id), isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // 多文件导入的端到端事实
  // ---------------------------------------------------------------------------
  group('多文件导入：3 张图片 + 同一个角色名', () {
    test('报告：新增 3、数据库确认 3；SQL 计数也是 3', () async {
      final Result<ImportReport> result = await importBatch(await writeBatch());
      expect(result.isOk, isTrue, reason: '${result.failureOrNull}');
      final ImportReport report = result.valueOrNull!;

      expect(report.importedCount, 3);
      expect(report.parsedCount, 3);
      expect(report.insertedCount, 3, reason: '3 张都应是新增');
      expect(report.updatedCount, 0);
      expect(report.confirmedCount, 3, reason: '数据库确认必须等于实际写入数');
      expect(report.isConsistent, isTrue,
          reason: '一致性校验失败：${report.consistencyIssues}');
      expect(report.failedCount, 0);

      expect(await countAssetsByCharacterName(characterName), 3,
          reason: 'SQL 直查：Maya 名下必须正好 3 条素材');
      final CharacterModel character = (await repository.listCharacters(ownerId)).single;
      final List<EmotionAsset> assets = await repository.listAllAssets(character.id);
      expect(assets.map((EmotionAsset a) => a.id).toSet(), hasLength(3));
    });

    test('关闭并重新打开数据库后仍然是 3 条', () async {
      final Result<ImportReport> result = await importBatch(await writeBatch());
      expect(result.isOk, isTrue, reason: '${result.failureOrNull}');

      await AppDatabase.close();
      final AppDatabase reopened =
          await AppDatabase.open(path: AppPaths.instance.databaseFile.path);
      repository = SqliteCharacterRepository.fromDatabase(reopened);

      expect(await countAssetsByCharacterName(characterName), 3);
      expect((await repository.listCharacters(ownerId)), hasLength(1));
    });

    test('重复导入同一批：仍然 3 条，报告显示"更新 3"', () async {
      final Result<ImportReport> first = await importBatch(await writeBatch());
      expect(first.isOk, isTrue, reason: '${first.failureOrNull}');
      final CharacterModel character = (await repository.listCharacters(ownerId)).single;
      final Set<String> idsAfterFirst = (await repository.listAllAssets(character.id))
          .map((EmotionAsset a) => a.id)
          .toSet();

      final Result<ImportReport> second = await importBatch(await writeBatch());
      expect(second.isOk, isTrue, reason: '${second.failureOrNull}');
      final ImportReport report = second.valueOrNull!;

      expect(report.insertedCount, 0);
      expect(report.updatedCount, 3);
      expect(report.confirmedCount, 3);
      expect(report.isConsistent, isTrue);
      expect(await countAssetsByCharacterName(characterName), 3,
          reason: '重复导入不得产生重复记录，也不得丢失');
      expect(
        (await repository.listAllAssets(character.id)).map((EmotionAsset a) => a.id).toSet(),
        idsAfterFirst,
        reason: '确定性 ID：同一批文件重复导入必须落在同一组素材上',
      );
    });

    test('Android SAF 临时副本（不同 originalSource）与普通路径混用也不丢数据', () async {
      // 一半"Saf 临时副本"，一半"普通路径"。
      final File plain = File(p.join(dir.path, 'plain', 'd.png'));
      await plain.parent.create(recursive: true);
      await plain.writeAsBytes(png(size: 7));

      final List<SelectedImportFile> files = await writeBatch();
      files.add(SelectedImportFile(
        localPath: plain.path,
        originalName: 'd.png',
      ));

      final Result<ImportReport> result = await importBatch(files);
      expect(result.isOk, isTrue, reason: '${result.failureOrNull}');
      expect(result.valueOrNull!.confirmedCount, 4);
      expect(await countAssetsByCharacterName(characterName), 4);

      // 普通路径文件记录真实路径；SAF 临时副本记录来源标识而不是临时路径。
      final CharacterModel character = (await repository.listCharacters(ownerId)).single;
      final List<EmotionAsset> assets = await repository.listAllAssets(character.id);
      final EmotionAsset safAsset =
          assets.firstWhere((EmotionAsset a) => a.originalFilePath?.startsWith('saf://') ?? false);
      final EmotionAsset plainAsset =
          assets.firstWhere((EmotionAsset a) => a.originalFilePath == plain.path);
      expect(safAsset.originalFilePath, 'saf://a.png');
      expect(plainAsset.originalFilePath, plain.path);
    });

    test('文件选择导入的作品包来源标记为 files 且不写死某个目录', () async {
      final Result<ImportReport> result = await importBatch(await writeBatch());
      expect(result.isOk, isTrue, reason: '${result.failureOrNull}');

      final CharacterPack pack = (await repository.listPacks(ownerId)).single;
      expect(pack.sourceType, PackSourceType.files,
          reason: '多张独立图片不属于任何"文件夹"来源');
      expect(pack.sourcePath, isNull,
          reason: '不应把作品包标记成某一张图片的父目录');
    });
  });
}

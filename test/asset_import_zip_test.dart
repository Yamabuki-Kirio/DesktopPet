import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:petlife/asset_decoder/asset_validator.dart';
import 'package:petlife/asset_decoder/flutter_asset_decoder.dart';
import 'package:petlife/asset_import/asset_importer.dart';
import 'package:petlife/asset_import/default_asset_importer.dart';
import 'package:petlife/asset_import/import_models.dart';
import 'package:petlife/asset_import/import_router.dart';
import 'package:petlife/asset_import/zip_asset_importer.dart';
import 'package:petlife/character/character_repository.dart';
import 'package:petlife/character/models/character_model.dart';
import 'package:petlife/character/models/emotion_asset.dart';
import 'package:petlife/character/sqlite_character_repository.dart';
import 'package:petlife/core/constants.dart';
import 'package:petlife/core/logger.dart';
import 'package:petlife/core/paths.dart';
import 'package:petlife/core/result.dart';
import 'package:petlife/database/app_database.dart';
import 'package:petlife/platform/android/android_file_import_provider.dart';
import 'package:petlife/platform/file_import_provider.dart';

import 'filename_parser_test.dart' show locateAceAttorneyFolder;
import 'support/sqlite_test_bootstrap.dart';

/// Phase 4A 真机缺陷一：**ZIP 导入必然失败**。
///
/// 根因是装配层同时暴露 `DefaultAssetImporter` / `ZipAssetImporter`，
/// 而界面固定调用前者，`ZipImportRequest` 被送进只认文件的导入器，
/// 用户看到的是内部类提示「ZIP 导入请使用 ZipAssetImporter」。
///
/// 这里的测试覆盖三层：
/// 1. 统一路由器按**请求类型**分派；
/// 2. 真实 ZIP（真实 WebP + 真实 SQLite）端到端成功；
/// 3. Android SAF「只有 bytes」时落地到应用私有临时文件并可清理。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ---------------------------------------------------------------------------
  // 1. 统一导入路由器
  // ---------------------------------------------------------------------------
  group('AssetImportRouter：按请求类型分派', () {
    late _RecordingImporter fileImporter;
    late _RecordingImporter zipImporter;
    late AssetImportRouter router;

    setUp(() {
      fileImporter = _RecordingImporter();
      zipImporter = _RecordingImporter();
      router = AssetImportRouter(fileImporter: fileImporter, zipImporter: zipImporter);
    });

    test('ZipImportRequest 必须进入 ZIP 导入器，绝不能进文件导入器', () async {
      final Result<ImportReport> result = await router.import(
        const ZipImportRequest(ownerId: 'owner', zipPath: 'sample.zip'),
      );

      expect(result.isOk, isTrue);
      expect(zipImporter.requests, hasLength(1));
      expect(zipImporter.requests.single, isA<ZipImportRequest>());
      expect(fileImporter.requests, isEmpty,
          reason: 'ZIP 请求被送进了文件导入器 —— 这正是真机缺陷的形态');
    });

    test('FileImportRequest / FolderImportRequest 进入文件导入器', () async {
      await router.import(
        FileImportRequest(
          ownerId: 'owner',
          files: const <SelectedImportFile>[
            SelectedImportFile(localPath: 'a.webp', originalName: 'a.webp'),
          ],
          packName: 'P',
        ),
      );
      await router.import(
        const FolderImportRequest(ownerId: 'owner', folderPath: r'C:\assets'),
      );

      expect(fileImporter.requests, hasLength(2));
      expect(zipImporter.requests, isEmpty);
    });

    test('进度回调透传到被选中的导入器', () async {
      await router.import(
        const ZipImportRequest(ownerId: 'owner', zipPath: 'sample.zip'),
        onProgress: (int current, int total, String label) {},
      );
      expect(zipImporter.receivedProgress, isTrue);
    });
  });

  test('DefaultAssetImporter 遇到 ZIP 时给出人可读原因，不再暴露内部类名', () async {
    // ZIP 的正常路径由路由器分派；这里只验证"防御分支"不会再指导用户用某个内部类。
    final DefaultAssetImporter importer = DefaultAssetImporter(
      repository: _UnusedRepository(),
      validator: const DefaultAssetValidator(),
      decoder: FlutterAssetDecoder(),
    );

    final Result<ImportReport> result = await importer.import(
      const ZipImportRequest(ownerId: 'owner', zipPath: 'sample.zip'),
    );

    expect(result.isOk, isFalse);
    expect(result.failureOrNull!.message, isNot(contains('ZipAssetImporter')));
    expect(result.failureOrNull!.message, contains('ZIP'));
  });

  // ---------------------------------------------------------------------------
  // 2. Android SAF：临时 ZIP 副本
  // ---------------------------------------------------------------------------
  group('Android SAF：ZIP 落地为可读的临时文件', () {
    late Directory temp;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('petlife_picked_zip');
    });

    tearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });

    test('只有 bytes（content:// 未落地）→ 复制到应用私有临时目录并可读', () async {
      final Uint8List bytes = _buildZip(<String, Uint8List>{
        'pack/Char_Happy_1.webp': Uint8List.fromList(<int>[1, 2, 3, 4]),
      });

      final PickedZip picked =
          await AndroidFileImportProvider.materializeZip(bytes: bytes, tempDir: temp);

      expect(picked.isTemporary, isTrue, reason: '只有字节流时必须标记为临时副本');
      final File copy = File(picked.path);
      expect(copy.existsSync(), isTrue);
      expect(await copy.readAsBytes(), bytes);
      expect(p.isWithin(temp.path, p.normalize(copy.path)), isTrue,
          reason: '临时副本必须落在应用私有临时目录内');

      // 模拟导入结束后的清理：副本被删除，且不触碰任何用户文件。
      await copy.delete();
      expect(copy.existsSync(), isFalse);
    });

    test('path 指向真实文件 → 直接使用，不建副本、不标记临时', () async {
      final File original = File(p.join(temp.path, 'user_pack.zip'));
      await original.writeAsBytes(<int>[9, 9, 9]);

      final PickedZip picked =
          await AndroidFileImportProvider.materializeZip(path: original.path, tempDir: temp);

      expect(picked.isTemporary, isFalse, reason: '用户原始文件绝不能被标记为临时并删除');
      expect(picked.path, original.path);
    });

    test('path 不可读且没有 bytes → 明确报错，而不是返回一个不可读路径', () async {
      expect(
        () => AndroidFileImportProvider.materializeZip(
          path: p.join(temp.path, 'missing.zip'),
          tempDir: temp,
        ),
        throwsA(isA<FileSystemException>()),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // 3. 真实 ZIP 端到端
  // ---------------------------------------------------------------------------
  group('ZIP 端到端（真实 WebP + 真实 SQLite）', () {
    const String ownerId = AppConstants.localOwnerId;

    Directory? root;
    late SqliteCharacterRepository repository;
    late AssetImportRouter router;
    final Directory? folder = locateAceAttorneyFolder();

    setUpAll(() async {
      SqliteTestBootstrap.ensureLoaded();
      final Directory dir = Directory.systemTemp.createTempSync('petlife_zip_e2e');
      root = dir;
      AppPaths.resetForTest();
      await AppPaths.initialize(overrideRoot: dir);
      await AppLog.initialize(logFile: AppPaths.instance.logFile);

      final AppDatabase db =
          await AppDatabase.open(path: AppPaths.instance.databaseFile.path);
      repository = SqliteCharacterRepository.fromDatabase(db);

      final DefaultAssetImporter fileImporter = DefaultAssetImporter(
        repository: repository,
        validator: const DefaultAssetValidator(),
        decoder: FlutterAssetDecoder(),
      );
      router = AssetImportRouter(
        fileImporter: fileImporter,
        zipImporter: ZipAssetImporter(
          inner: fileImporter,
          validator: const DefaultAssetValidator(),
        ),
      );
    });

    tearDownAll(() async {
      await AppDatabase.close();
      await AppLog.dispose();
      AppPaths.resetForTest();
      if (root != null && root!.existsSync()) root!.deleteSync(recursive: true);
    });

    Future<Uint8List?> sampleWebpBytes() async {
      if (folder == null) return null;
      final List<File> files = folder
          .listSync(recursive: true)
          .whereType<File>()
          .where((File f) => p.extension(f.path).toLowerCase() == '.webp')
          .toList(growable: false);
      if (files.isEmpty) return null;
      return files.first.readAsBytes();
    }

    test('合法 ZIP：多个角色与多个情绪都被正确建立', () async {
      final Uint8List? bytes = await sampleWebpBytes();
      if (bytes == null) {
        markTestSkipped('未找到 Ace Attorney 素材目录，跳过 ZIP 端到端用例');
        return;
      }

      final Uint8List zipBytes = _buildZip(<String, Uint8List>{
        'Ace Attorney/Maya_Angry_1.webp': bytes,
        'Ace Attorney/Maya_Nod_1.webp': bytes,
        'Other Pack/Edgeworth_Shocked_1.webp': bytes,
      });
      final String zipPath = p.join(root!.path, 'packs.zip');
      await File(zipPath).writeAsBytes(zipBytes);

      final Result<ImportReport> result = await router.import(
        ZipImportRequest(ownerId: ownerId, zipPath: zipPath),
      );

      expect(result.isOk, isTrue, reason: 'ZIP 导入整体失败：${result.failureOrNull}');
      final ImportReport report = result.valueOrNull!;
      expect(report.importedCount, 3, reason: '有条目未导入：${report.failed}');
      expect(report.failedCount, 0);
      expect(report.characterNames, containsAll(<String>['Maya', 'Edgeworth']));
      expect(report.packNames, containsAll(<String>['Ace Attorney', 'Other Pack']));
      expect(report.seededMappingCount, greaterThan(0),
          reason: '首次导入的角色应自动生成状态映射');

      final List<CharacterModel> characters = await repository.listCharacters(ownerId);
      expect(
        characters.map((CharacterModel c) => c.internalName).toSet(),
        containsAll(<String>{'Maya', 'Edgeworth'}),
        reason: 'ZIP 里的多个角色都应落库',
      );

      final CharacterModel maya =
          characters.firstWhere((CharacterModel c) => c.internalName == 'Maya');
      final CharacterModel edgeworth =
          characters.firstWhere((CharacterModel c) => c.internalName == 'Edgeworth');

      final List<EmotionAsset> mayaAssets = await repository.listAllAssets(maya.id);
      expect(mayaAssets.length, 2, reason: 'Maya 的 2 个情绪都应建立');
      expect(
        mayaAssets.map((EmotionAsset a) => a.emotionName).toSet(),
        <String>{'Angry', 'Nod'},
      );

      expect((await repository.listAllAssets(edgeworth.id)).length, 1);

      // ZIP 条目没有原始磁盘路径，original_file_path 必须非空（zip:// 形式），
      // 否则「删除时不动用户文件」的守卫就失去了参照。
      for (final EmotionAsset a in mayaAssets) {
        expect(a.originalFilePath, isNotNull);
        expect(a.originalFilePath, startsWith('zip://'));
        expect(File(a.filePath).existsSync(), isTrue, reason: '托管副本缺失');
      }
    });

    test('单图导入 + 勾选「设为默认图片」→ 新角色具备合法 default_asset_id', () async {
      final Uint8List? bytes = await sampleWebpBytes();
      if (bytes == null) {
        markTestSkipped('未找到 Ace Attorney 素材目录，跳过单图默认素材用例');
        return;
      }
      final File file = File(p.join(root!.path, 'single', 'Newcomer_Idle_1.webp'));
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes);

      final Result<ImportReport> result = await router.import(
        FileImportRequest(
          ownerId: ownerId,
          files: <SelectedImportFile>[
            SelectedImportFile(localPath: file.path, originalName: 'Newcomer_Idle_1.webp'),
          ],
          packName: 'Single Pack',
          characterName: 'Newcomer',
          setAsCharacterDefault: true,
        ),
      );

      expect(result.isOk, isTrue, reason: '${result.failureOrNull}');
      expect(result.valueOrNull!.importedCount, 1);

      final List<CharacterModel> characters = await repository.listCharacters(ownerId);
      final CharacterModel newcomer =
          characters.firstWhere((CharacterModel c) => c.internalName == 'Newcomer');
      expect(newcomer.defaultAssetId, isNotNull,
          reason: '勾选「设为默认图片」后，新角色必须有合法的 default_asset_id');

      final EmotionAsset? asset = await repository.findAsset(newcomer.defaultAssetId!);
      expect(asset, isNotNull, reason: 'default_asset_id 必须指向真实存在的素材');
      expect(asset!.characterId, newcomer.id);
    });

    test('损坏 ZIP：要么明确失败，要么 0 导入 —— 都不得暴露内部类名', () async {
      final String badPath = p.join(root!.path, 'broken.zip');
      // 纯 0 字节不是合法 ZIP：ZipDecoder 视作「没有条目」而不是抛错，
      // 因此这里不断言"必须失败"，而是断言**两种结果都不能出现内部类提示**。
      await File(badPath).writeAsBytes(Uint8List.fromList(List<int>.filled(128, 0)));

      final Result<ImportReport> result = await router.import(
        ZipImportRequest(ownerId: ownerId, zipPath: badPath),
      );

      if (result.isOk) {
        expect(result.valueOrNull!.importedCount, 0, reason: '损坏的 ZIP 不应导入任何素材');
      } else {
        final String message = result.failureOrNull!.message;
        expect(message, isNot(contains('ZipAssetImporter')));
        expect(message, contains('ZIP'));
      }
    });

    test('路径穿越条目：中止整包导入并给出安全原因', () async {
      final Uint8List zipBytes = _buildZip(<String, Uint8List>{
        'evil/../../escape.webp': Uint8List.fromList(<int>[1, 2, 3]),
      });
      final String zipPath = p.join(root!.path, 'traversal.zip');
      await File(zipPath).writeAsBytes(zipBytes);

      final Result<ImportReport> result = await router.import(
        ZipImportRequest(ownerId: ownerId, zipPath: zipPath),
      );

      expect(result.isOk, isFalse);
      expect(result.failureOrNull!.kind, FailureKind.unsafeArchive);
      expect(result.failureOrNull!.message, contains('不安全'));
    });

    test('不存在的 ZIP 路径：给出可理解的失败信息', () async {
      final Result<ImportReport> result = await router.import(
        ZipImportRequest(ownerId: ownerId, zipPath: p.join(root!.path, 'nope.zip')),
      );
      expect(result.isOk, isFalse);
      expect(result.failureOrNull!.message, contains('不存在'));
    });
  });
}

/// 记录收到的请求，用于验证分派。
class _RecordingImporter implements AssetImporter {
  final List<ImportRequest> requests = <ImportRequest>[];
  bool receivedProgress = false;

  @override
  Future<Result<ImportReport>> import(
    ImportRequest request, {
    ImportProgressCallback? onProgress,
  }) async {
    requests.add(request);
    if (onProgress != null) {
      receivedProgress = true;
      onProgress(0, 0, '');
    }
    return Ok<ImportReport>(_emptyReport());
  }
}

ImportReport _emptyReport() => ImportReport(
      packNames: const <String>[],
      characterNames: const <String>[],
      imported: const <ImportedAssetSummary>[],
      failed: const <FailedItem>[],
      scannedCount: 0,
      skippedCount: 0,
      elapsed: Duration.zero,
    );

/// 只用于触发"防御分支"的仓库替身：该分支在任何仓库调用之前就返回了。
class _UnusedRepository implements CharacterRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('测试替身不应被调用：${invocation.memberName}');
}

Uint8List _buildZip(Map<String, Uint8List> entries) {
  final Archive archive = Archive();
  entries.forEach((String name, Uint8List data) {
    archive.addFile(ArchiveFile.bytes(name, data));
  });
  return ZipEncoder().encodeBytes(archive);
}

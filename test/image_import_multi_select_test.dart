import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:petlife/asset_decoder/asset_validator.dart';
import 'package:petlife/asset_decoder/flutter_asset_decoder.dart';
import 'package:petlife/asset_import/default_asset_importer.dart';
import 'package:petlife/asset_import/import_models.dart';
import 'package:petlife/character/models/character_model.dart';
import 'package:petlife/character/models/emotion_asset.dart';
import 'package:petlife/character/sqlite_character_repository.dart';
import 'package:petlife/core/constants.dart';
import 'package:petlife/core/logger.dart';
import 'package:petlife/core/paths.dart';
import 'package:petlife/core/result.dart';
import 'package:petlife/database/app_database.dart';
import 'package:petlife/platform/file_import_provider.dart';

import 'support/sqlite_test_bootstrap.dart';

/// Phase 4A 真机缺陷二：**Android 多选图片只导入一张**。
///
/// 两个独立成因，这里各自覆盖：
/// 1. 页面用 `whereType<String>()` 过滤 `PlatformFile`，把 SAF 里 `path == null`
///    的文件**静默丢弃** → 由 [materializePickedImages] 负责物化（本文件第 1 组）；
/// 2. 一批普通图片在指定角色后得到完全相同的 (角色, 情绪, 变体)，
///    assetId 因此相同，后导入的覆盖前面的 → 由导入器的稳定消歧负责（第 2 组）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 生成一张确定性的 PNG（尺寸随 [size] 变化，用于得到不同的内容哈希）。
  Uint8List pngBytes({int size = 4}) {
    final img.Image image = img.Image(width: size, height: size);
    img.fill(image, color: img.ColorRgb8(200, 120, 40));
    return Uint8List.fromList(img.encodePng(image));
  }

  // ---------------------------------------------------------------------------
  // 1. 选择结果物化
  // ---------------------------------------------------------------------------
  group('选择结果物化：绝不静默丢弃用户选中的文件', () {
    late Directory temp;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('petlife_picked_img');
    });

    tearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });

    test('真实路径：直接使用，不建副本、不标临时', () async {
      final File original = File(p.join(temp.path, 'Maya_Angry_1.png'));
      await original.writeAsBytes(pngBytes());

      final ImagePickResult result = await materializePickedImages(
        <PlatformFile>[
          PlatformFile(name: 'Maya_Angry_1.png', size: 10, path: original.path),
        ],
        tempRoot: temp,
      );

      expect(result.selectedCount, 1);
      expect(result.materializedCount, 1);
      expect(result.hasRejected, isFalse);
      final SelectedImportFile file = result.files.single;
      expect(file.localPath, original.path);
      expect(file.originalName, 'Maya_Angry_1.png');
      expect(file.isTemporary, isFalse, reason: '用户原始文件绝不能被标记为临时并删除');
    });

    test('只有 bytes（SAF 的 content:// 未落地）：复制到临时目录并保留原始文件名与扩展名', () async {
      final Uint8List bytes = pngBytes();

      final ImagePickResult result = await materializePickedImages(
        <PlatformFile>[
          PlatformFile(name: '新角色_开心_1.png', size: bytes.length, bytes: bytes),
        ],
        tempRoot: temp,
      );

      expect(result.materializedCount, 1);
      final SelectedImportFile file = result.files.single;
      expect(file.isTemporary, isTrue);
      expect(file.originalName, '新角色_开心_1.png');
      // 临时副本必须保留原始文件名与扩展名：角色/情绪解析、托管文件名都依赖它。
      expect(p.basename(file.localPath), '新角色_开心_1.png');
      expect(p.extension(file.localPath), '.png');
      expect(p.isWithin(temp.path, p.normalize(file.localPath)), isTrue);
      expect(file.originalSource, 'saf://新角色_开心_1.png');

      final File copy = File(file.localPath);
      expect(copy.existsSync(), isTrue);
      expect(await copy.readAsBytes(), bytes);
    });

    test('混合选择：3 张里 1 张没有路径，也要 3 张全部物化（不丢文件）', () async {
      final File onDisk = File(p.join(temp.path, 'on_disk.png'));
      await onDisk.writeAsBytes(pngBytes(size: 4));
      final Uint8List onlyBytes = pngBytes(size: 6);

      final ImagePickResult result = await materializePickedImages(
        <PlatformFile>[
          PlatformFile(name: 'on_disk.png', size: 10, path: onDisk.path),
          PlatformFile(name: 'bytes_only.png', size: onlyBytes.length, bytes: onlyBytes),
          PlatformFile(name: 'on_disk.png', size: 10, path: onDisk.path),
        ],
        tempRoot: temp,
      );

      expect(result.selectedCount, 3, reason: '用户选了 3 张');
      expect(result.materializedCount, 3, reason: '取得内容的也是 3 张（旧实现只剩 2 张）');
      expect(result.hasRejected, isFalse);
      expect(result.summary(), contains('选择 3 张，取得内容 3 张'));
    });

    test('既无路径也无 bytes：带原因进 rejected，不算"静默跳过"', () async {
      final ImagePickResult result = await materializePickedImages(
        <PlatformFile>[
          PlatformFile(name: 'broken.png', size: 0),
        ],
        tempRoot: temp,
      );

      expect(result.materializedCount, 0);
      expect(result.rejected, hasLength(1));
      expect(result.rejected.single.name, 'broken.png');
      expect(result.rejected.single.reason, isNotEmpty);
      expect(result.summary(), contains('1 张无法读取'));
    });
  });

  // ---------------------------------------------------------------------------
  // 2. 多选导入不再互相覆盖
  // ---------------------------------------------------------------------------
  group('多选导入：一批普通图片必须生成多条素材', () {
    const String ownerId = AppConstants.localOwnerId;

    Directory? root;
    late SqliteCharacterRepository repository;
    late DefaultAssetImporter importer;

    setUpAll(() async {
      SqliteTestBootstrap.ensureLoaded();
      final Directory dir = Directory.systemTemp.createTempSync('petlife_multi_import');
      root = dir;
      AppPaths.resetForTest();
      await AppPaths.initialize(overrideRoot: dir);
      await AppLog.initialize(logFile: AppPaths.instance.logFile);

      final AppDatabase db =
          await AppDatabase.open(path: AppPaths.instance.databaseFile.path);
      repository = SqliteCharacterRepository.fromDatabase(db);
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

    /// 造 3 个"普通文件名"的图片（没有 角色_情绪_序号 规范命名）。
    Future<List<SelectedImportFile>> writeBatch(List<String> names) async {
      final List<SelectedImportFile> files = <SelectedImportFile>[];
      for (int i = 0; i < names.length; i++) {
        final File file = File(p.join(root!.path, 'batch', names[i]));
        await file.parent.create(recursive: true);
        await file.writeAsBytes(pngBytes(size: 4 + i));
        files.add(SelectedImportFile(localPath: file.path, originalName: names[i]));
      }
      return files;
    }

    test('普通文件名 + 指定角色：3 张生成 3 条不同素材，不再互相覆盖', () async {
      final List<SelectedImportFile> files =
          await writeBatch(<String>['a.png', 'b.png', 'c.png']);

      final Result<ImportReport> result = await importer.import(
        FileImportRequest(
          ownerId: ownerId,
          files: files,
          packName: 'Batch',
          characterName: 'Maya',
        ),
      );

      expect(result.isOk, isTrue, reason: '${result.failureOrNull}');
      expect(result.valueOrNull!.importedCount, 3);
      expect(result.valueOrNull!.failedCount, 0);

      final List<CharacterModel> characters = await repository.listCharacters(ownerId);
      final CharacterModel maya =
          characters.firstWhere((CharacterModel c) => c.internalName == 'Maya');
      final List<EmotionAsset> assets = await repository.listAllAssets(maya.id);

      expect(assets, hasLength(3),
          reason: '选了 3 张普通图片，素材库必须有 3 条记录（旧实现只剩 1 条）');
      expect(assets.map((EmotionAsset a) => a.id).toSet(), hasLength(3),
          reason: 'assetId 必须互不相同');
      expect(assets.map((EmotionAsset a) => a.variantName).toSet(), hasLength(3),
          reason: '变体必须互不相同');
      // 缺失 variant 的图片用**原始文件名**生成稳定变体。
      expect(
        assets.map((EmotionAsset a) => a.variantName).toSet(),
        <String>{'a', 'b', 'c'},
      );
      // 3 条托管副本都要真实存在。
      for (final EmotionAsset a in assets) {
        expect(File(a.filePath).existsSync(), isTrue, reason: '托管副本缺失：${a.filePath}');
      }
    });

    test('重复导入同一批：仍然 3 条，且 ID 不变（稳定、不是随机值）', () async {
      final List<SelectedImportFile> files =
          await writeBatch(<String>['x.png', 'y.png', 'z.png']);

      final Result<ImportReport> first = await importer.import(
        FileImportRequest(
          ownerId: ownerId,
          files: files,
          packName: 'Batch2',
          characterName: 'Edgeworth',
        ),
      );
      expect(first.isOk, isTrue, reason: '${first.failureOrNull}');
      expect(first.valueOrNull!.importedCount, 3);

      final CharacterModel character = (await repository.listCharacters(ownerId))
          .firstWhere((CharacterModel c) => c.internalName == 'Edgeworth');
      final Set<String> firstIds = (await repository.listAllAssets(character.id))
          .map((EmotionAsset a) => a.id)
          .toSet();

      final Result<ImportReport> second = await importer.import(
        FileImportRequest(
          ownerId: ownerId,
          files: files,
          packName: 'Batch2',
          characterName: 'Edgeworth',
        ),
      );
      expect(second.isOk, isTrue, reason: '${second.failureOrNull}');

      final List<EmotionAsset> after = await repository.listAllAssets(character.id);
      expect(after, hasLength(3), reason: '重复导入不得产生重复记录');
      expect(after.map((EmotionAsset a) => a.id).toSet(), firstIds,
          reason: '消歧变体必须是确定性的：重复导入同一批文件要落在同一批 ID 上');
    });

    test('单张导入保持原样：variant 仍是 default（不改变既有 ID 规则）', () async {
      final File file = File(p.join(root!.path, 'single', 'plain.png'));
      await file.parent.create(recursive: true);
      await file.writeAsBytes(pngBytes(size: 9));

      final Result<ImportReport> result = await importer.import(
        FileImportRequest(
          ownerId: ownerId,
          files: <SelectedImportFile>[
            SelectedImportFile(localPath: file.path, originalName: 'plain.png'),
          ],
          packName: 'Solo',
          characterName: 'Solo',
        ),
      );

      expect(result.isOk, isTrue, reason: '${result.failureOrNull}');
      final CharacterModel solo = (await repository.listCharacters(ownerId))
          .firstWhere((CharacterModel c) => c.internalName == 'Solo');
      final List<EmotionAsset> assets = await repository.listAllAssets(solo.id);
      expect(assets, hasLength(1));
      expect(assets.single.variantName, 'default',
          reason: '单张导入不参与消歧，ID 规则与之前完全一致');
      expect(assets.single.emotionName, 'default');
    });

    test('临时副本：索引里记录原始来源（saf://），绝不写入会被清理的临时路径', () async {
      const String originalName = 'saf_image.png';
      final ImagePickResult picked = await materializePickedImages(
        <PlatformFile>[
          PlatformFile(name: originalName, size: 4, bytes: pngBytes(size: 5)),
        ],
        tempRoot: root,
      );
      final SelectedImportFile tempFile = picked.files.single;
      expect(tempFile.isTemporary, isTrue);

      final Result<ImportReport> result = await importer.import(
        FileImportRequest(
          ownerId: ownerId,
          files: picked.files,
          packName: 'SafPack',
          characterName: 'SafChar',
        ),
      );
      expect(result.isOk, isTrue, reason: '${result.failureOrNull}');

      final CharacterModel character = (await repository.listCharacters(ownerId))
          .firstWhere((CharacterModel c) => c.internalName == 'SafChar');
      final EmotionAsset asset = (await repository.listAllAssets(character.id)).single;
      expect(asset.originalFilePath, 'saf://$originalName');
      expect(asset.originalFilePath, isNot(contains('picked_')));

      // 模拟导入结束后的清理：删掉临时副本，用户侧没有任何文件被牵连。
      final File copy = File(tempFile.localPath);
      expect(copy.existsSync(), isTrue);
      await copy.delete();
      expect(copy.existsSync(), isFalse);
      // 托管副本仍在（渲染依赖它）。
      expect(File(asset.filePath).existsSync(), isTrue);
    });
  });
}

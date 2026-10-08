import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../asset_decoder/asset_decoder.dart';
import '../asset_decoder/asset_validator.dart';
import '../character/character_repository.dart';
import '../character/models/character_model.dart';
import '../character/models/character_pack.dart';
import '../character/models/emotion_asset.dart';
import '../character/models/enums.dart';
import '../character/models/state_mapping.dart';
import '../core/ids.dart';
import '../core/logger.dart';
import '../core/paths.dart';
import '../core/result.dart';
import '../state_engine/default_mapping_seeder.dart';
import 'asset_importer.dart';
import 'filename_parser.dart';
import 'folder_scanner.dart';
import 'import_models.dart';
import 'import_scope.dart';

/// 默认导入器：负责单张 / 多张图片与整个文件夹。
///
/// ZIP 由 [ZipAssetImporter] 负责（安全校验差异较大，单独实现），
/// 但两者共用 [DefaultAssetImporter.ingestBytes]，保证写入路径与索引规则一致。
///
/// 关键约束：
/// - **绝不修改、移动或删除用户原始素材文件**：只读取，托管副本写到应用数据目录。
/// - **单个文件损坏不影响其他文件**：逐个 try/catch，失败进报告。
/// - **重复导入幂等**：素材 ID 由 (角色, 情绪, 变体) 确定性生成。
/// - **父实体不得反复 upsert**：见 [ImportScope]，以及 `PackDao.upsert` 里
///   关于 `INSERT OR REPLACE` + `ON DELETE CASCADE` 的说明。
/// - **报告必须以数据库为准**：写完后重新查询确认，不一致就报"校验失败"。
class DefaultAssetImporter implements AssetImporter {
  DefaultAssetImporter({
    required this.repository,
    required this.validator,
    required this.decoder,
    this.scanner = const FolderScanner(),
    this.seeder = const DefaultMappingSeeder(),
    this.parser = const AssetFilenameParser(),
  });

  final CharacterRepository repository;
  final AssetValidator validator;
  final AssetDecoder decoder;
  final FolderScanner scanner;
  final DefaultMappingSeeder seeder;
  final AssetFilenameParser parser;

  @override
  Future<Result<ImportReport>> import(
    ImportRequest request, {
    ImportProgressCallback? onProgress,
  }) async {
    final Stopwatch sw = Stopwatch()..start();
    try {
      return switch (request) {
        final FolderImportRequest r => await _importFolder(r, sw, onProgress),
        final FileImportRequest r => await _importFiles(r, sw, onProgress),
        // 正常路径下 ZIP 请求由 AssetImportRouter 分派给 ZipAssetImporter，
        // 不会走到这里。这条分支只是防御：万一有人直接调用本导入器导入 ZIP，
        // 也要给出人可读的原因，而不是暴露内部类名。
        final ZipImportRequest r => Err<ImportReport>(Failure(
            FailureKind.unknown,
            '无法导入 ZIP 素材包：当前入口不支持 ZIP，请改用「导入 ZIP 素材包」',
            detail: r.zipPath,
          )),
      };
    } catch (e, st) {
      Loggers.importer.severe('导入过程发生未预期异常', e, st);
      return Err<ImportReport>(Failure(FailureKind.unknown, '导入失败', detail: e.toString()));
    }
  }

  // ---------------------------------------------------------------------------
  // 文件夹导入
  // ---------------------------------------------------------------------------

  Future<Result<ImportReport>> _importFolder(
    FolderImportRequest request,
    Stopwatch sw,
    ImportProgressCallback? onProgress,
  ) async {
    if (!AppPaths.isInitialized) {
      return Err<ImportReport>(const Failure(FailureKind.unknown, '应用数据目录未初始化'));
    }

    Loggers.scan.info('素材扫描开始: folder=${request.folderPath} recursive=${request.recursive}');

    final FolderScanResult scan = await scanner.scan(
      request.folderPath,
      packNameOverride: request.packNameOverride,
      recursive: request.recursive,
    );

    final List<ImportedAssetSummary> imported = <ImportedAssetSummary>[];
    final List<FailedItem> failed = <FailedItem>[];
    final Set<String> packNames = <String>{};
    final Set<String> characterNames = <String>{};
    final List<String> warnings = <String>[];
    final Set<String> charactersNeedingSeeds = <String>{};
    final Map<String, Set<String>> expectedByCharacter = <String, Set<String>>{};
    int parsedCount = 0;
    int insertedCount = 0;
    int updatedCount = 0;

    // 来源信息由**批次**决定：文件夹导入用真实目录，不再逐文件用
    // `p.dirname(原始路径)` 改写 pack.source_path（历史缺陷的触发器）。
    final ImportScope scope = ImportScope.plain(
      repository: repository,
      ownerId: request.ownerId,
      sourceType: PackSourceType.folder,
      sourcePath: request.folderPath,
    );

    int index = 0;
    for (final ScanCandidate candidate in scan.candidates) {
      index++;
      onProgress?.call(index, scan.candidates.length, candidate.fileName);

      final ParsedAssetName parsed = parser.parse(candidate.fileName, packName: candidate.packName);
      packNames.add(parsed.packName);

      try {
        final File file = File(candidate.path);
        final Uint8List bytes = await file.readAsBytes();

        final Result<AssetProbe> probeResult = await validator.probeBytes(
          bytes,
          virtualPath: candidate.path,
          declaredExtension: parsed.extension,
        );

        if (probeResult is Err<AssetProbe>) {
          failed.add(FailedItem(path: candidate.path, failure: probeResult.failure));
          Loggers.scan.warning('素材校验未通过: ${candidate.path} -> ${probeResult.failure}');
          continue;
        }

        final AssetProbe probe = (probeResult as Ok<AssetProbe>).value;

        // 交叉验证：容器声称是动画，但解码器只给出 1 帧 → 后端可能不支持该动画。
        final Result<DecodeVerification> verify = await decoder.verifyDecodable(file);
        if (verify is Err<DecodeVerification>) {
          failed.add(FailedItem(path: candidate.path, failure: verify.failure));
          Loggers.decode.warning('素材无法解码: ${candidate.path} -> ${verify.failure}');
          continue;
        }
        final DecodeVerification verification = (verify as Ok<DecodeVerification>).value;
        if (probe.isAnimated && verification.decoderFrameCount <= 1) {
          final String msg = '容器显示为动画（${probe.frameCount} 帧），'
              '但解码器只返回 ${verification.decoderFrameCount} 帧：${candidate.fileName}';
          warnings.add(msg);
          Loggers.decode.warning(msg);
        }

        parsedCount++;
        // 文件夹可能有上千个文件：这里保持「一个文件一个事务」，
        // 避免长时间持有写锁（父实体缓存仍然跨文件复用）。
        final IngestOutcome outcome = await repository.transaction(
          (CharacterRepository tx) => ingestBytes(
            scope: scope.withRepository(tx),
            bytes: bytes,
            probe: probe,
            parsed: parsed,
            originalPath: candidate.path,
            charactersNeedingSeeds: charactersNeedingSeeds,
          ),
        );
        imported.add(outcome.summary);
        characterNames.add(parsed.characterName);
        expectedByCharacter
            .putIfAbsent(outcome.summary.characterId, () => <String>{})
            .add(outcome.summary.assetId);
        if (outcome.inserted) {
          insertedCount++;
        } else {
          updatedCount++;
        }
      } catch (e, st) {
        // 单个文件失败必须被隔离，绝不能影响同文件夹里的其他素材。
        Loggers.scan.warning('导入单个文件失败: ${candidate.path}', e, st);
        failed.add(FailedItem(
          path: candidate.path,
          failure: Failure(FailureKind.unknown, '导入失败', detail: e.toString()),
        ));
      }
    }

    final int seeded = await seedMappingsFor(charactersNeedingSeeds, repository);
    final ({int confirmed, List<String> issues}) verification =
        await verifyAssets(repository, expectedByCharacter);

    sw.stop();
    final ImportReport report = ImportReport(
      packNames: packNames.toList()..sort(),
      characterNames: characterNames.toList()..sort(),
      imported: imported,
      failed: failed,
      scannedCount: scan.candidates.length,
      skippedCount: scan.skippedCount,
      elapsed: sw.elapsed,
      seededMappingCount: seeded,
      warnings: <String>[...warnings, ...scan.notices],
      parsedCount: parsedCount,
      insertedCount: insertedCount,
      updatedCount: updatedCount,
      confirmedCount: verification.confirmed,
      consistencyIssues: verification.issues,
    );

    Loggers.scan.info('素材扫描结束: ${report.summary()}');
    Loggers.scan.info('成功识别 ${report.importedCount} 个，'
        '动态 ${report.animatedCount} 个，静态 ${report.staticCount} 个，'
        '损坏 ${report.failedCount} 个，跳过 ${report.skippedCount} 个，'
        '自动生成状态映射 $seeded 条');
    Loggers.scan.info('批次统计: ${report.batchSummary()}');
    if (!report.isConsistent) {
      Loggers.scan.severe('导入一致性校验失败: ${report.consistencyIssues.join('；')}');
    }
    for (final FailedItem f in report.failed) {
      Loggers.scan.info('  损坏文件: ${f.path} -> ${f.failure}');
    }

    return Ok<ImportReport>(report);
  }

  // ---------------------------------------------------------------------------
  // 单张 / 多张图片导入
  // ---------------------------------------------------------------------------

  Future<Result<ImportReport>> _importFiles(
    FileImportRequest request,
    Stopwatch sw,
    ImportProgressCallback? onProgress,
  ) async {
    if (!AppPaths.isInitialized) {
      return Err<ImportReport>(const Failure(FailureKind.unknown, '应用数据目录未初始化'));
    }

    final List<ImportedAssetSummary> imported = <ImportedAssetSummary>[];
    final List<FailedItem> failed = <FailedItem>[];
    final Set<String> characterNames = <String>{};
    final Set<String> charactersNeedingSeeds = <String>{};
    final Map<String, Set<String>> expectedByCharacter = <String, Set<String>>{};
    int parsedCount = 0;
    int insertedCount = 0;
    int updatedCount = 0;
    int seeded = 0;

    // ---- 第一步：读出内容并逐个校验（只读操作，放在事务外） ----
    //
    // 放在事务外的原因：读盘 + 图片头解析可能很慢，不该在持有写锁时做。
    final List<_RawImportFile> raw = <_RawImportFile>[];
    int index = 0;
    for (final SelectedImportFile file in request.files) {
      index++;
      onProgress?.call(index, request.files.length, file.originalName);

      final ParsedAssetName base = parser.parse(file.originalName, packName: request.packName);
      try {
        final Uint8List bytes = await File(file.localPath).readAsBytes();
        final Result<AssetProbe> probeResult = await validator.probeBytes(
          bytes,
          virtualPath: file.localPath,
          declaredExtension: base.extension,
        );
        if (probeResult is Err<AssetProbe>) {
          failed.add(FailedItem(path: file.originalName, failure: probeResult.failure));
          continue;
        }
        raw.add(_RawImportFile(
          file: file,
          base: base,
          bytes: bytes,
          probe: (probeResult as Ok<AssetProbe>).value,
        ));
        parsedCount++;
      } catch (e, st) {
        Loggers.importer.warning('读取素材失败: ${file.localPath}', e, st);
        failed.add(FailedItem(
          path: file.originalName,
          failure: Failure(FailureKind.unreadable, '读取失败', detail: e.toString()),
        ));
      }
    }

    // ---- 第二步：确定每张素材的 (角色, 情绪, 变体)，对同批冲突项稳定消歧 ----
    //
    // 缺陷背景：一批普通图片（如 `a.png` / `b.png` / `c.png`）在用户填了角色名之后
    // 会得到完全相同的 (角色, 情绪, 变体)，而 assetId 正是由这三者确定性生成的
    // —— 于是后导入的覆盖前面的：用户选了 3 张，素材库里只剩 1 条。
    // 这里只对**确实会冲突**的文件消歧；单张导入的 ID 完全不变。
    final List<_PreparedImportFile> planned = _resolveVariants(request, raw);

    // ---- 第三步：整批一个事务写入；任一失败则整批回滚 ----
    try {
      await ImportScope.run(
        repository: repository,
        ownerId: request.ownerId,
        // 文件选择导入没有"来源目录"：来源类型标记为 files，路径留空。
        // 绝不再逐文件用 `p.dirname(originalPath)` 改写 pack.source_path。
        sourceType: PackSourceType.files,
        body: (ImportScope scope) async {
          for (final _PreparedImportFile item in planned) {
            final IngestOutcome outcome = await ingestBytes(
              scope: scope,
              bytes: item.bytes,
              probe: item.probe,
              parsed: item.parsed,
              // 临时副本的路径会被清理，绝不能写进索引 → 用原始来源标识。
              originalPath: item.file.sourceRef,
              charactersNeedingSeeds: charactersNeedingSeeds,
            );
            imported.add(outcome.summary);
            characterNames.add(item.parsed.characterName);
            expectedByCharacter
                .putIfAbsent(outcome.summary.characterId, () => <String>{})
                .add(outcome.summary.assetId);
            if (outcome.inserted) {
              insertedCount++;
            } else {
              updatedCount++;
            }
          }

          // 用户勾选了「设为该角色默认图片」：用最后一张成功导入的素材。
          if (request.setAsCharacterDefault && imported.isNotEmpty) {
            final ImportedAssetSummary last = imported.last;
            await scope.repository.setCharacterDefaultAsset(last.characterId, last.assetId);
            Loggers.importer.info(
              '已将 ${last.fileName} 设为角色 ${last.characterName} 的默认图片',
            );
          }

          seeded = await seedMappingsFor(charactersNeedingSeeds, scope.repository);
        },
      );
    } catch (e, st) {
      // 整批回滚：必须如实告知"数据库没有写入任何素材"，
      // 而不是把已写入的部分算成成功（历史缺陷：报告成功 3 个、库里只剩 1 个）。
      Loggers.importer.severe('整批导入失败，已回滚', e, st);
      return Err<ImportReport>(Failure(
        FailureKind.unknown,
        '整批导入失败，已回滚：数据库未写入任何素材',
        detail: e.toString(),
      ));
    }

    // ---- 第四步：事务提交后重新查询数据库，确认每条素材都真实存在 ----
    final ({int confirmed, List<String> issues}) verification =
        await verifyAssets(repository, expectedByCharacter);

    sw.stop();
    final ImportReport report = ImportReport(
      packNames: <String>[request.packName],
      characterNames: characterNames.toList()..sort(),
      imported: imported,
      failed: failed,
      scannedCount: request.files.length,
      skippedCount: 0,
      elapsed: sw.elapsed,
      seededMappingCount: seeded,
      parsedCount: parsedCount,
      insertedCount: insertedCount,
      updatedCount: updatedCount,
      confirmedCount: verification.confirmed,
      consistencyIssues: verification.issues,
    );
    Loggers.importer.info('手动图片导入完成: ${report.summary()}');
    Loggers.importer.info('批次统计: ${report.batchSummary()}');
    if (!report.isConsistent) {
      Loggers.importer.severe('导入一致性校验失败: ${report.consistencyIssues.join('；')}');
    }
    return Ok<ImportReport>(report);
  }

  /// 把"读好的文件"映射成"可写入的素材"：解析出最终的角色/情绪/变体。
  List<_PreparedImportFile> _resolveVariants(
    FileImportRequest request,
    List<_RawImportFile> raw,
  ) {
    final Map<String, int> keyCounts = <String, int>{};
    for (final _RawImportFile item in raw) {
      final String key = _canonicalKey(
        character: request.characterName ?? item.base.characterName,
        emotion: request.emotionName ?? item.base.emotionName,
        variant: item.base.variantName,
      );
      keyCounts[key] = (keyCounts[key] ?? 0) + 1;
    }

    // 本批内已经确定下来的 (角色, 情绪, 变体)，保证消歧结果也互不重复。
    final Set<String> assignedKeys = <String>{};
    final List<_PreparedImportFile> out = <_PreparedImportFile>[];

    for (final _RawImportFile item in raw) {
      // 用户在 UI 上填写的作品包/角色/情绪会覆盖文件名解析结果。
      final String character = request.characterName ?? item.base.characterName;
      final String emotion = request.emotionName ?? item.base.emotionName;
      String variant = item.base.variantName;

      final String baseKey =
          _canonicalKey(character: character, emotion: emotion, variant: variant);
      if ((keyCounts[baseKey] ?? 0) > 1) {
        variant = _disambiguateVariant(
          originalName: item.file.originalName,
          bytes: item.bytes,
          character: character,
          emotion: emotion,
          taken: assignedKeys,
        );
        Loggers.importer.info(
          '同一批导入出现重复的 (角色, 情绪, 变体)，已用稳定变体消歧: '
          '${item.file.originalName} -> variant=$variant',
        );
      }
      assignedKeys.add(_canonicalKey(character: character, emotion: emotion, variant: variant));

      out.add(_PreparedImportFile(
        file: item.file,
        parsed: ParsedAssetName(
          packName: request.packName,
          characterName: character,
          emotionName: emotion,
          variantName: variant,
          extension: item.base.extension,
          sourceFileName: item.file.originalName,
        ),
        bytes: item.bytes,
        probe: item.probe,
      ));
    }
    return out;
  }

  /// 事务提交后回到数据库核对：每个"报告里说成功"的素材必须真的存在。
  ///
  /// 公开给 [ZipAssetImporter] 复用。返回 `confirmed`（真实存在的数量）与
  /// `issues`（不一致的原因，空表示校验通过）。
  ///
  /// 这是"处理 3 个、报告成功 3 个、数据库只剩 1 个"这类缺陷的最后一道防线：
  /// 只要不一致，界面就必须显示校验失败，而不是继续报"成功"。
  Future<({int confirmed, List<String> issues})> verifyAssets(
    CharacterRepository reader,
    Map<String, Set<String>> expectedByCharacter,
  ) async {
    int confirmed = 0;
    int expectedTotal = 0;
    final List<String> missing = <String>[];
    for (final MapEntry<String, Set<String>> entry in expectedByCharacter.entries) {
      expectedTotal += entry.value.length;
      final List<EmotionAsset> actual = await reader.listAllAssets(entry.key);
      final Set<String> existingIds = actual.map((EmotionAsset a) => a.id).toSet();
      for (final String id in entry.value) {
        if (existingIds.contains(id)) {
          confirmed++;
        } else {
          missing.add(id);
        }
      }
    }

    if (missing.isEmpty) {
      return (confirmed: confirmed, issues: const <String>[]);
    }
    return (
      confirmed: confirmed,
      issues: <String>[
        '导入一致性校验失败：处理 $expectedTotal 个文件，但数据库仅保存 $confirmed 个素材。',
        '缺失的素材 ID：${missing.take(5).join('、')}'
            '${missing.length > 5 ? ' 等 ${missing.length} 个' : ''}',
      ],
    );
  }

  /// 与 [Ids.assetId] 相同的判重口径（角色/情绪/变体都不区分大小写）。
  static String _canonicalKey({
    required String character,
    required String emotion,
    required String variant,
  }) =>
      '${character.toLowerCase()}\u0000${emotion.toLowerCase()}\u0000${variant.toLowerCase()}';

  /// 为「同一批内会互相覆盖」的文件生成**稳定且唯一**的变体。
  ///
  /// 取原始文件名（首个候选），同名时再挂内容哈希前缀 ——
  /// 两者都可重现，因此重复导入同一批文件仍然幂等（绝不是随机值）。
  String _disambiguateVariant({
    required String originalName,
    required Uint8List bytes,
    required String character,
    required String emotion,
    required Set<String> taken,
  }) {
    final String cleaned = p
        .basenameWithoutExtension(originalName)
        .replaceAll(RegExp(r'[\\/:*?"<>|\s]+'), '_')
        .replaceAll(RegExp(r'^[._]+'), '')
        .trim();
    String candidate = cleaned.isEmpty ? 'v' : cleaned;

    if (taken.contains(_canonicalKey(character: character, emotion: emotion, variant: candidate))) {
      // 同名文件（例如不同目录下的 a.png）：再挂内容哈希。
      final String hash = sha256.convert(bytes).toString().substring(0, 8);
      candidate = '${candidate}_$hash';
    }
    return candidate;
  }

  // ---------------------------------------------------------------------------
  // 共用：写入托管目录 + 建立索引
  // ---------------------------------------------------------------------------

  /// 把一个已通过校验的素材写入托管目录并建立索引。
  ///
  /// ZIP 导入器也调用这里，从而保证两条导入路径的落盘规则完全一致。
  ///
  /// **事务边界**：本方法**不**自己开事务，事务由调用方通过 [ImportScope] 提供：
  /// * 多文件导入：整批一个事务（见 `_importFiles`）；
  /// * 文件夹导入：一个文件一个事务（文件数可能上千，避免长时间持有写锁）；
  /// * ZIP：整包一个事务。
  ///
  /// **父实体只 ensure 一次**：`pack` / `character` 都走 [ImportScope] 的缓存。
  /// 这样既不会逐文件改写 `pack.source_path`，也不会在带 `ON DELETE CASCADE`
  /// 的父表上反复写入（历史缺陷：一次 REPLACE 就把已导入的素材级联删掉）。
  ///
  /// 托管文件的写入放在 `upsertAsset` 之前：最坏留下一个**孤儿托管副本**
  /// （下次导入同一文件即被覆盖，无害），但绝不会出现指向不存在文件的 asset 记录。
  Future<IngestOutcome> ingestBytes({
    required ImportScope scope,
    required Uint8List bytes,
    required AssetProbe probe,
    required ParsedAssetName parsed,
    required String originalPath,
    Set<String>? charactersNeedingSeeds,
  }) async {
    final CharacterRepository writer = scope.repository;
    final CharacterPack pack = await scope.pack(parsed.packName);
    final CharacterModel character = await scope.character(
      packId: pack.id,
      internalName: parsed.characterName,
    );

    final String fileName = parsed.canonicalFileName();
    final Directory target = AppPaths.instance.characterDir(
      scope.ownerId,
      parsed.packName,
      parsed.characterName,
    );
    final File targetFile = File(p.join(target.path, fileName));
    final String hash = probe.fileHash;
    final DateTime now = DateTime.now();

    // 首次出现的角色才需要跑一次建议映射，避免重复导入时把用户改过的映射覆盖掉。
    final bool needsSeed = charactersNeedingSeeds != null &&
        (await writer.listMappings(character.id)).isEmpty;

    // ID 生成放在写盘之前：uuid v5 的命名空间校验失败会抛异常，
    // 早点抛出可以少做一次无用的磁盘写入（回滚由外层事务兜底）。
    final EmotionAsset asset = EmotionAsset(
      id: Ids.assetId(character.id, parsed.emotionName, parsed.variantName),
      characterId: character.id,
      emotionName: parsed.emotionName,
      variantName: parsed.variantName,
      filePath: targetFile.path,
      originalFilePath: originalPath,
      fileHash: hash,
      mimeType: probe.mimeType,
      fileSize: probe.fileSize,
      width: probe.width,
      height: probe.height,
      frameCount: probe.frameCount,
      isAnimated: probe.isAnimated,
      hasAlpha: probe.hasAlpha,
      enabled: true,
      validationStatus: ValidationStatus.valid,
      createdAt: now,
      animationDurationMs: probe.animationDurationMs,
    );

    // 报告必须区分「新增」与「更新」：同一个确定性 ID 之前是否存在。
    final bool inserted = await writer.findAsset(asset.id) == null;

    await target.create(recursive: true);

    // 幂等写入：内容一致就不重复写盘（也避免刷新文件修改时间）。
    bool needWrite = true;
    if (await targetFile.exists()) {
      final int existingSize = await targetFile.length();
      if (existingSize == bytes.length) {
        final String existingHash = sha256.convert(await targetFile.readAsBytes()).toString();
        needWrite = existingHash != hash;
      }
    }
    if (needWrite) {
      await targetFile.writeAsBytes(bytes, flush: true);
    }

    await writer.upsertAsset(asset);

    if (needsSeed) {
      charactersNeedingSeeds.add(character.id);
    }

    Loggers.decode.info(
      '素材识别: ${parsed.sourceFileName} -> pack=${parsed.packName} character=${parsed.characterName} '
      'emotion=${parsed.emotionName} variant=${parsed.variantName} '
      '${probe.width}x${probe.height} frames=${probe.frameCount} '
      'animated=${probe.isAnimated} alpha=${probe.hasAlpha} '
      'duration=${probe.animationDurationMs}ms mime=${probe.mimeType} '
      'bytes=${probe.fileSize} ${inserted ? '新增' : '更新'}',
    );
    if (probe.webp != null) {
      Loggers.decode.info(
        '  动态 WebP 帧信息: ${probe.webp!.frames.length} 帧, '
        'loop=${probe.webp!.loopCount}, encoding=${probe.webp!.encoding}, '
        'subRect=${probe.webp!.hasSubRectFrames}',
      );
    }

    return IngestOutcome(
      inserted: inserted,
      summary: ImportedAssetSummary(
        assetId: asset.id,
        characterId: character.id,
        fileName: parsed.sourceFileName,
        packName: parsed.packName,
        characterName: parsed.characterName,
        emotionName: parsed.emotionName,
        variantName: parsed.variantName,
        isAnimated: probe.isAnimated,
        frameCount: probe.frameCount,
        width: probe.width,
        height: probe.height,
        hasAlpha: probe.hasAlpha,
        bytes: probe.fileSize,
        managedPath: targetFile.path,
        animationDurationMs: probe.animationDurationMs,
      ),
    );
  }

  /// 为「首次出现且尚无映射」的角色生成建议映射。
  ///
  /// 公开出来是为了让 [ZipAssetImporter] 在完成落盘后调用同一条逻辑，
  /// 保证两种导入路径产生完全一致的初始状态映射。
  ///
  /// [writer] 由调用方给出：多文件/ZIP 导入时传批次事务作用域的仓库，
  /// 使建议映射与素材写入落在同一个事务里。
  Future<int> seedMappingsFor(Set<String> characterIds, CharacterRepository writer) async {
    int total = 0;
    for (final String characterId in characterIds) {
      final List<EmotionAsset> assets = await writer.listRenderableAssets(characterId);
      if (assets.isEmpty) continue;
      final List<StateMapping> seeded = seeder.seed(
        characterId: characterId,
        assets: assets,
        now: DateTime.now(),
      );
      for (final StateMapping m in seeded) {
        await writer.replaceMappingsForState(characterId, m.systemState, <StateMapping>[m]);
      }
      total += seeded.length;
      Loggers.state.info('为角色 $characterId 生成建议状态映射 ${seeded.length} 条');
    }
    return total;
  }
}

/// 单个素材的写入结果。
class IngestOutcome {
  const IngestOutcome({required this.summary, required this.inserted});

  final ImportedAssetSummary summary;

  /// true = 新增；false = 按确定性 ID 覆盖了已有素材。
  final bool inserted;
}

/// 「已读入内容、尚未确定最终变体」的中间条目。
class _RawImportFile {
  const _RawImportFile({
    required this.file,
    required this.base,
    required this.bytes,
    required this.probe,
  });

  final SelectedImportFile file;
  final ParsedAssetName base;
  final Uint8List bytes;
  final AssetProbe probe;
}

/// 「已确定角色/情绪/变体、可直接写入」的条目。
class _PreparedImportFile {
  const _PreparedImportFile({
    required this.file,
    required this.parsed,
    required this.bytes,
    required this.probe,
  });

  final SelectedImportFile file;
  final ParsedAssetName parsed;
  final Uint8List bytes;
  final AssetProbe probe;
}

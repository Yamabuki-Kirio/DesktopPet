import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import '../asset_decoder/asset_validator.dart';
import '../character/models/enums.dart';
import '../core/constants.dart';
import '../core/logger.dart';
import '../core/paths.dart';
import '../core/result.dart';
import 'asset_importer.dart';
import 'default_asset_importer.dart';
import 'filename_parser.dart';
import 'import_models.dart';
import 'import_scope.dart';

/// ZIP 素材包导入。
///
/// 需求 4.5 要求 ZIP 导入必须防止：
/// - 路径穿越（zip-slip）
/// - 绝对路径写入
/// - 超大解压文件
/// - 伪造图片扩展名（由 AssetValidator 覆盖）
/// - 重复覆盖现有素材
///
/// 实现策略：**先把整个 ZIP 校验一遍，再解压**。
/// 任何一条安全校验失败都立刻中止整包导入，不写入任何文件。
class ZipAssetImporter implements AssetImporter {
  ZipAssetImporter({
    required this.inner,
    required this.validator,
    this.parser = const AssetFilenameParser(),
  });

  /// 复用默认导入器的落盘与索引逻辑（保证与文件夹导入完全一致）。
  final DefaultAssetImporter inner;
  final AssetValidator validator;
  final AssetFilenameParser parser;

  @override
  Future<Result<ImportReport>> import(
    ImportRequest request, {
    ImportProgressCallback? onProgress,
  }) async {
    if (request is! ZipImportRequest) {
      return Err<ImportReport>(const Failure(FailureKind.unknown, 'ZipAssetImporter 只接受 ZipImportRequest'));
    }
    if (!AppPaths.isInitialized) {
      return Err<ImportReport>(const Failure(FailureKind.unknown, '应用数据目录未初始化'));
    }

    final Stopwatch sw = Stopwatch()..start();
    final File zipFile = File(request.zipPath);
    if (!await zipFile.exists()) {
      return Err<ImportReport>(Failure(FailureKind.unreadable, 'ZIP 文件不存在', detail: request.zipPath));
    }

    final int zipSize = await zipFile.length();
    if (zipSize > AssetLimits.maxZipTotalBytes) {
      return Err<ImportReport>(Failure(
        FailureKind.fileTooLarge,
        'ZIP 文件超过上限',
        detail: '$zipSize > ${AssetLimits.maxZipTotalBytes}',
      ));
    }

    Loggers.importer.info('ZIP 导入开始: ${request.zipPath} ($zipSize 字节)');

    try {
      final Uint8List bytes = await zipFile.readAsBytes();
      final Archive archive = ZipDecoder().decodeBytes(bytes, verify: true);

      // ---- 第一遍：安全校验 + 体积核算 ----
      final List<_ZipEntry> accepted = <_ZipEntry>[];
      final List<FailedItem> failed = <FailedItem>[];
      final List<String> warnings = <String>[];
      int totalUncompressed = 0;
      final Set<String> seenCanonicalNames = <String>{};
      final String zipBaseName = p.basenameWithoutExtension(request.zipPath);

      if (archive.length > AssetLimits.maxZipEntries) {
        return Err<ImportReport>(Failure(
          FailureKind.unsafeArchive,
          'ZIP 条目数超过上限',
          detail: '${archive.length} > ${AssetLimits.maxZipEntries}',
        ));
      }

      for (final ArchiveFile file in archive) {
        if (!file.isFile) continue;
        final String rawName = file.name;

        final String? unsafeReason = _checkEntryPath(rawName);
        if (unsafeReason != null) {
          Loggers.importer.severe('ZIP 安全校验失败，中止导入: $rawName -> $unsafeReason');
          return Err<ImportReport>(Failure(
            FailureKind.unsafeArchive,
            'ZIP 包含不安全的条目路径，已中止导入',
            detail: '$rawName ($unsafeReason)',
          ));
        }

        final int size = file.size;
        if (size > AssetLimits.maxZipEntryBytes) {
          failed.add(FailedItem(
            path: rawName,
            failure: Failure(FailureKind.fileTooLarge, '条目超过解压上限',
                detail: '$size > ${AssetLimits.maxZipEntryBytes}'),
          ));
          continue;
        }
        totalUncompressed += size;

        final String ext = p.extension(rawName).replaceFirst('.', '').toLowerCase();
        if (!AssetLimits.allowedExtensions.contains(ext)) {
          continue; // 非图片条目（说明文件、封面等）静默忽略。
        }

        // 作品包名：优先用户指定；否则取第一个路径段；根目录下的文件用 ZIP 文件名。
        final List<String> segments = rawName.split('/').where((String s) => s.isNotEmpty).toList();
        final String packName = request.packNameOverride ??
            (segments.length >= 2 ? segments.first : zipBaseName);

        final ParsedAssetName parsed = parser.parse(p.basename(rawName), packName: packName);
        final String canonical = '${parsed.packName}/${parsed.characterName}/'
            '${parsed.emotionName}/${parsed.variantName}';

        // 重复覆盖现有素材：同一包内出现重复的 (角色, 情绪, 变体) 时只保留第一个。
        if (!seenCanonicalNames.add(canonical)) {
          warnings.add('ZIP 内存在重复素材，已跳过后续条目: $rawName');
          Loggers.importer.warning('ZIP 内重复素材，跳过: $rawName (canonical=$canonical)');
          continue;
        }

        accepted.add(_ZipEntry(file: file, rawName: rawName, parsed: parsed));
      }

      // 压缩比检查（zip bomb）。
      if (zipSize > 0 && totalUncompressed / zipSize > AssetLimits.maxZipRatio) {
        return Err<ImportReport>(Failure(
          FailureKind.unsafeArchive,
          'ZIP 压缩比异常，疑似压缩炸弹，已中止导入',
          detail: '解压预估 $totalUncompressed / 压缩 $zipSize '
              '= ${(totalUncompressed / zipSize).toStringAsFixed(1)}',
        ));
      }
      if (totalUncompressed > AssetLimits.maxZipTotalBytes) {
        return Err<ImportReport>(Failure(
          FailureKind.unsafeArchive,
          'ZIP 解压后总大小超过上限，已中止导入',
          detail: '$totalUncompressed > ${AssetLimits.maxZipTotalBytes}',
        ));
      }

      // ---- 第二遍：逐个解压 → 校验 → 落盘（整包一个事务） ----
      //
      // 整包一个事务的理由与多文件导入相同：不能出现"报告成功 N 个、
      // 数据库只剩 1 个"这种报告与事实不一致的情况；写完还要回库核对。
      final List<ImportedAssetSummary> imported = <ImportedAssetSummary>[];
      final Set<String> characterNames = <String>{};
      final Set<String> packNames = <String>{};
      final Set<String> charactersNeedingSeeds = <String>{};
      final Map<String, Set<String>> expectedByCharacter = <String, Set<String>>{};
      int parsedCount = 0;
      int insertedCount = 0;
      int updatedCount = 0;
      int seeded = 0;

      try {
        await ImportScope.run(
          repository: inner.repository,
          ownerId: request.ownerId,
          // ZIP 有明确的来源：标记为 zip + ZIP 文件路径。
          sourceType: PackSourceType.zip,
          sourcePath: request.zipPath,
          body: (ImportScope scope) async {
            int index = 0;
            for (final _ZipEntry entry in accepted) {
              index++;
              onProgress?.call(index, accepted.length, p.basename(entry.rawName));
              try {
                final Uint8List content = entry.file.readBytes() ?? Uint8List(0);
                if (content.isEmpty) {
                  failed.add(FailedItem(
                    path: entry.rawName,
                    failure: const Failure(FailureKind.emptyContent, '条目内容为空'),
                  ));
                  continue;
                }
                if (content.length != entry.file.size) {
                  // 解压后长度与声明不符，说明压缩流损坏。
                  failed.add(FailedItem(
                    path: entry.rawName,
                    failure: Failure(FailureKind.undecodable, '解压后长度与声明不符',
                        detail: '${content.length} != ${entry.file.size}'),
                  ));
                  continue;
                }

                final Result<AssetProbe> probeResult = await validator.probeBytes(
                  content,
                  virtualPath: entry.rawName,
                  declaredExtension: entry.parsed.extension,
                );
                if (probeResult is Err<AssetProbe>) {
                  failed.add(FailedItem(path: entry.rawName, failure: probeResult.failure));
                  Loggers.importer.warning('ZIP 条目校验未通过: ${entry.rawName} -> ${probeResult.failure}');
                  continue;
                }

                parsedCount++;
                final IngestOutcome outcome = await inner.ingestBytes(
                  scope: scope,
                  bytes: content,
                  probe: (probeResult as Ok<AssetProbe>).value,
                  parsed: entry.parsed,
                  // ZIP 里的文件没有原始磁盘路径，记录为 zip 内路径，
                  // 保证 original_file_path 非空且不会被误删。
                  originalPath: 'zip://${request.zipPath}!/${entry.rawName}',
                  charactersNeedingSeeds: charactersNeedingSeeds,
                );
                imported.add(outcome.summary);
                characterNames.add(entry.parsed.characterName);
                packNames.add(entry.parsed.packName);
                expectedByCharacter
                    .putIfAbsent(outcome.summary.characterId, () => <String>{})
                    .add(outcome.summary.assetId);
                if (outcome.inserted) {
                  insertedCount++;
                } else {
                  updatedCount++;
                }
              } catch (e, st) {
                Loggers.importer.warning('ZIP 条目导入失败: ${entry.rawName}', e, st);
                failed.add(FailedItem(
                  path: entry.rawName,
                  failure: Failure(FailureKind.unknown, '导入失败', detail: e.toString()),
                ));
              }
            }

            // 与文件夹导入走同一条建议映射生成逻辑。
            seeded = await inner.seedMappingsFor(charactersNeedingSeeds, scope.repository);
          },
        );
      } catch (e, st) {
        Loggers.importer.severe('ZIP 整包写入失败，已回滚: ${request.zipPath}', e, st);
        return Err<ImportReport>(Failure(
          FailureKind.unknown,
          'ZIP 导入失败，已回滚：数据库未写入任何素材',
          detail: e.toString(),
        ));
      }

      // 事务提交后核对：报告里说成功的素材必须真的在库里。
      final ({int confirmed, List<String> issues}) verification =
          await inner.verifyAssets(inner.repository, expectedByCharacter);

      sw.stop();

      return Ok<ImportReport>(ImportReport(
        packNames: packNames.toList()..sort(),
        characterNames: characterNames.toList()..sort(),
        imported: imported,
        failed: failed,
        scannedCount: accepted.length,
        skippedCount: 0,
        elapsed: sw.elapsed,
        seededMappingCount: seeded,
        warnings: warnings,
        parsedCount: parsedCount,
        insertedCount: insertedCount,
        updatedCount: updatedCount,
        confirmedCount: verification.confirmed,
        consistencyIssues: verification.issues,
      ));
    } catch (e, st) {
      Loggers.importer.severe('ZIP 解析失败: ${request.zipPath}', e, st);
      return Err<ImportReport>(Failure(
        FailureKind.unsafeArchive,
        'ZIP 解析失败（文件损坏或格式不受支持）',
        detail: e.toString(),
      ));
    }
  }

  /// 路径安全校验。返回 null 表示安全，否则返回拒绝原因。
  static String? _checkEntryPath(String rawName) {
    if (rawName.isEmpty) return '条目名为空';
    if (rawName.contains('\u0000')) return '条目名包含空字符';

    // 统一分隔符，便于识别 `..\..\` 这类 Windows 风格穿越。
    final String name = rawName.replaceAll('\\', '/');

    if (name.startsWith('/')) return '绝对路径';
    if (RegExp(r'^[a-zA-Z]:').hasMatch(name)) return '包含盘符的绝对路径';
    if (name.startsWith('//')) return 'UNC 路径';

    final List<String> segments = name.split('/');
    for (final String seg in segments) {
      if (seg == '..') return '包含上级目录引用（路径穿越）';
    }

    // 双重保险：解析后的路径必须仍在解压根内。
    final String root = p.normalize(p.join(AppPaths.instance.tmpDir.path, 'zip-root'));
    final String resolved = p.normalize(p.join(root, name));
    if (!p.isWithin(root, resolved) && resolved != root) {
      return '解析后的路径逃逸出目标目录';
    }
    return null;
  }
}

class _ZipEntry {
  const _ZipEntry({required this.file, required this.rawName, required this.parsed});

  final ArchiveFile file;
  final String rawName;
  final ParsedAssetName parsed;
}

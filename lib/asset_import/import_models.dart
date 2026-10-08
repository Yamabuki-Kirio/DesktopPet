import '../core/result.dart';

/// 导入请求（密封类，后续阶段可继续扩展而不破坏现有分支）。
sealed class ImportRequest {
  const ImportRequest({required this.ownerId});

  final String ownerId;
}

/// 一次「选择文件」操作中，**已物化、可直接交给导入器读取**的文件。
///
/// 为什么需要它：Android SAF 返回的 `PlatformFile.path` 可能为 null
/// （只有 `content://` 或字节流）。旧代码用 `whereType<String>()` 把这些文件
/// **静默丢弃**，于是用户选了 3 张、实际只有 1 张进了导入器。
/// 现在由平台层负责把它们复制到应用私有临时目录，并如实交给导入器：
///
/// * [localPath]：本进程可读的路径（可能是临时副本）；
/// * [originalName]：**原始文件名**（解析角色/情绪、生成托管文件名都基于它，
///   所以临时副本必须保留原文件名和扩展名）；
/// * [isTemporary]：true 表示导入结束后必须删除 —— 只删我们自己的副本，
///   用户原始文件永远不动；
/// * [originalSource]：原始来源标识。SAF 拿不到真实路径时用它写
///   `original_file_path`，避免把随后会被清理的临时路径写进索引。
class SelectedImportFile {
  const SelectedImportFile({
    required this.localPath,
    required this.originalName,
    this.isTemporary = false,
    this.originalSource,
  });

  final String localPath;
  final String originalName;
  final bool isTemporary;
  final String? originalSource;

  /// 写入素材索引的「原始来源」：优先真实来源，其次本地路径。
  String get sourceRef => originalSource ?? localPath;

  @override
  String toString() =>
      'SelectedImportFile($localPath, name=$originalName, temporary=$isTemporary)';
}

/// 拿不到可读内容的文件。
///
/// 这类文件**必须展示给用户**（含原因），不允许静默跳过。
class RejectedImportFile {
  const RejectedImportFile({required this.name, required this.reason});

  final String name;
  final String reason;

  @override
  String toString() => '$name：$reason';
}

/// 一次「选择图片」的结果。
class ImagePickResult {
  const ImagePickResult({
    required this.selectedCount,
    required this.files,
    this.rejected = const <RejectedImportFile>[],
  });

  /// 用户在系统选择器里**选中**的数量。
  final int selectedCount;

  /// 已物化、可直接导入的文件。
  final List<SelectedImportFile> files;

  /// 拿不到内容、被明确拒绝的文件（带原因）。
  final List<RejectedImportFile> rejected;

  int get materializedCount => files.length;

  bool get hasRejected => rejected.isNotEmpty;

  /// 一句话统计（界面必须展示，需求：不允许静默跳过）。
  String summary() {
    final StringBuffer buffer = StringBuffer()
      ..write('选择 $selectedCount 张，取得内容 $materializedCount 张');
    if (rejected.isNotEmpty) {
      buffer.write('，${rejected.length} 张无法读取');
    }
    return buffer.toString();
  }
}

/// 导入一张或多张图片。
///
/// [files] 由平台层的文件选择器物化后给出（见 [SelectedImportFile]），
/// 导入器只负责读取与入库，不再自己判断"路径是不是空"。
class FileImportRequest extends ImportRequest {
  const FileImportRequest({
    required super.ownerId,
    required this.files,
    required this.packName,
    this.characterName,
    this.emotionName,
    this.setAsCharacterDefault = false,
  });

  final List<SelectedImportFile> files;

  /// 用户输入或选择的作品包名称。
  final String packName;

  /// 用户可覆盖文件名解析出的角色名。
  final String? characterName;

  /// 用户可覆盖文件名解析出的情绪名。
  final String? emotionName;

  /// 是否把导入的图片设为该角色默认图片。
  final bool setAsCharacterDefault;
}

/// 导入整个文件夹。
class FolderImportRequest extends ImportRequest {
  const FolderImportRequest({
    required super.ownerId,
    required this.folderPath,
    this.packNameOverride,
    this.recursive = true,
  });

  final String folderPath;

  /// 为空时使用文件所在文件夹名作为作品包名（需求 4.2 规则 5）。
  final String? packNameOverride;

  final bool recursive;
}

/// 导入 ZIP 素材包。
class ZipImportRequest extends ImportRequest {
  const ZipImportRequest({
    required super.ownerId,
    required this.zipPath,
    this.packNameOverride,
  });

  final String zipPath;
  final String? packNameOverride;
}

/// 单个素材的导入结果摘要。
class ImportedAssetSummary {
  const ImportedAssetSummary({
    required this.assetId,
    required this.characterId,
    required this.fileName,
    required this.packName,
    required this.characterName,
    required this.emotionName,
    required this.variantName,
    required this.isAnimated,
    required this.frameCount,
    required this.width,
    required this.height,
    required this.hasAlpha,
    required this.bytes,
    required this.managedPath,
    required this.animationDurationMs,
  });

  final String assetId;
  final String characterId;
  final String fileName;
  final String packName;
  final String characterName;
  final String emotionName;
  final String variantName;
  final bool isAnimated;
  final int frameCount;
  final int width;
  final int height;
  final bool hasAlpha;
  final int bytes;
  final String managedPath;
  final int animationDurationMs;
}

/// 导入报告。
class ImportReport {
  ImportReport({
    required this.packNames,
    required this.characterNames,
    required this.imported,
    required this.failed,
    required this.scannedCount,
    required this.skippedCount,
    required this.elapsed,
    this.seededMappingCount = 0,
    this.warnings = const <String>[],
    this.parsedCount = 0,
    this.insertedCount = 0,
    this.updatedCount = 0,
    this.confirmedCount = 0,
    this.consistencyIssues = const <String>[],
  });

  final List<String> packNames;
  final List<String> characterNames;
  final List<ImportedAssetSummary> imported;
  final List<FailedItem> failed;

  /// 扫描到的候选文件总数（已按扩展名过滤）。
  final int scannedCount;

  /// 因扩展名不受支持等原因跳过的数量。
  final int skippedCount;

  final Duration elapsed;

  /// 自动生成的状态映射条数。
  final int seededMappingCount;

  /// 非致命告警（例如解码器帧数与容器帧数不一致）。
  final List<String> warnings;

  // ---------------------------------------------------------------------------
  // 批次级统计（需求：报告必须区分「处理」「新增」「更新」，并以数据库为准）
  // ---------------------------------------------------------------------------

  /// 成功解析并通过校验的文件数（"处理了几个"）。
  final int parsedCount;

  /// 新增的素材数（此前不存在）。
  final int insertedCount;

  /// 更新的素材数（此前已存在，按确定性 ID 覆盖）。
  final int updatedCount;

  /// 事务提交后**重新查询数据库**确认存在的素材数。
  final int confirmedCount;

  /// 一致性校验失败的原因。非空表示"报告说成功，但数据库里没有"。
  final List<String> consistencyIssues;

  int get importedCount => imported.length;

  int get failedCount => failed.length;

  bool get hasFailures => failed.isNotEmpty;

  /// 报告与数据库实际内容是否一致。
  ///
  /// 这是"成功 3 个、数据库只剩 1 个"这类缺陷的最后一道防线：
  /// 只要不一致，界面必须显示校验失败，而不是继续报"成功"。
  bool get isConsistent => consistencyIssues.isEmpty;

  int get animatedCount =>
      imported.where((ImportedAssetSummary a) => a.isAnimated).length;

  int get staticCount => imported.length - animatedCount;

  /// 生成一段人可读的汇总（日志与 UI 都用它）。
  String summary() => '扫描 $scannedCount 个文件，成功识别 ${imported.length} 个'
      '（动态 $animatedCount / 静态 $staticCount），'
      '损坏或跳过 ${failed.length + skippedCount} 个，'
      '耗时 ${elapsed.inMilliseconds} ms';

  /// 「解析 / 新增 / 更新 / 数据库确认」逐项统计。
  String batchSummary() => '成功解析 $parsedCount 个 · 新增 $insertedCount 个 · '
      '更新 $updatedCount 个 · 数据库确认 $confirmedCount 个';

  Map<String, Object?> toJson() => <String, Object?>{
        'packs': packNames,
        'characters': characterNames,
        'imported': imported.length,
        'animated': animatedCount,
        'static': staticCount,
        'failed': <Map<String, Object?>>[
          for (final FailedItem f in failed) <String, Object?>{
            'path': f.path,
            'kind': f.failure.kind.name,
            'message': f.failure.message,
            'detail': f.failure.detail,
          },
        ],
        'scanned': scannedCount,
        'skipped': skippedCount,
        'seeded_mappings': seededMappingCount,
        'warnings': warnings,
        'elapsed_ms': elapsed.inMilliseconds,
        'parsed': parsedCount,
        'inserted': insertedCount,
        'updated': updatedCount,
        'confirmed': confirmedCount,
        'consistency_issues': consistencyIssues,
      };
}

/// 导入进度回调。
typedef ImportProgressCallback = void Function(int current, int total, String label);

import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/constants.dart';
import '../core/logger.dart';

/// 一个待扫描的候选素材文件。
class ScanCandidate {
  const ScanCandidate({
    required this.path,
    required this.packName,
    required this.fileName,
  });

  final String path;

  /// 作品包名：默认取文件所在文件夹名（需求 4.2 规则 5）。
  final String packName;

  final String fileName;
}

/// 文件夹扫描结果。
class FolderScanResult {
  const FolderScanResult({
    required this.candidates,
    required this.skippedCount,
    required this.folderName,
    required this.notices,
  });

  final List<ScanCandidate> candidates;

  /// 因扩展名不受支持、隐藏文件、系统文件而跳过的数量。
  final int skippedCount;

  /// 根文件夹名（作为默认作品包名）。
  final String folderName;

  final List<String> notices;
}

/// 素材文件夹扫描器。
///
/// 只做「找出可能的图片文件」这件事，不做任何校验与写盘；
/// 校验交给 AssetValidator，写盘交给 AssetImporter。
class FolderScanner {
  const FolderScanner();

  /// 单次扫描的文件数上限，防止用户误选 C:\ 造成长时间卡死。
  static const int maxFiles = 20000;

  static const Set<String> _systemFileNames = <String>{
    'thumbs.db',
    'desktop.ini',
    '.ds_store',
  };

  Future<FolderScanResult> scan(
    String folderPath, {
    String? packNameOverride,
    bool recursive = true,
  }) async {
    final Directory dir = Directory(folderPath);
    final String folderName = p.basename(p.normalize(folderPath));
    final List<String> notices = <String>[];

    if (!await dir.exists()) {
      throw FileSystemException('素材文件夹不存在', folderPath);
    }

    final List<ScanCandidate> candidates = <ScanCandidate>[];
    int skipped = 0;

    await for (final FileSystemEntity entity in dir.list(recursive: recursive, followLinks: false)) {
      if (entity is! File) continue;
      if (candidates.length >= maxFiles) {
        notices.add('扫描文件数达到上限 $maxFiles，已停止扫描剩余文件');
        Loggers.scan.warning('扫描文件数达到上限（$maxFiles），folder=$folderPath');
        break;
      }

      final String name = p.basename(entity.path);
      if (name.startsWith('.')) {
        skipped++;
        continue;
      }
      if (_systemFileNames.contains(name.toLowerCase())) {
        skipped++;
        continue;
      }

      final String ext = p.extension(name).replaceFirst('.', '').toLowerCase();
      if (!AssetLimits.allowedExtensions.contains(ext)) {
        skipped++;
        continue;
      }

      // 作品包名：优先使用显式覆盖；否则用文件所在文件夹名。
      final String packName =
          packNameOverride ?? p.basename(p.dirname(entity.path));

      candidates.add(ScanCandidate(
        path: entity.path,
        packName: packName.isEmpty ? folderName : packName,
        fileName: name,
      ));
    }

    candidates.sort((ScanCandidate a, ScanCandidate b) => a.path.compareTo(b.path));

    Loggers.scan.info(
      '素材扫描完成: folder=$folderPath 候选=${candidates.length} 跳过=$skipped',
    );

    return FolderScanResult(
      candidates: candidates,
      skippedCount: skipped,
      folderName: folderName,
      notices: notices,
    );
  }
}

/// 素材 / 文件导入选择器（需求「Phase 4A 第 9 项」）。
///
/// 为什么需要抽象：
/// * Windows 可以选**文件夹**（`file_picker.getDirectoryPath`）；
/// * Android 上 `getDirectoryPath` 不被支持，只能通过系统文件选择器选**文件**
///   （SAF）。因此文件夹导入在移动端标记为不支持，由界面引导用户改用 ZIP 素材包。
///
/// 三条硬约束：
/// * **不依赖盘符与反斜杠**：返回的路径交给上层交给 `path` 包处理；
/// * 选不到就返回 null（用户取消），调用方不得当成错误；
/// * **绝不静默丢弃用户选中的文件**：拿不到可读路径的 SAF 文件要么被物化成
///   应用私有临时副本，要么带原因进入 [ImagePickResult.rejected]。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;

import '../asset_import/import_models.dart';
import '../core/paths.dart';

/// 素材库允许选择的图片扩展名（两端一致）。
const List<String> kImportImageExtensions = <String>['png', 'webp', 'jpg', 'jpeg', 'gif'];

/// 选中的 ZIP 素材包。
///
/// 为什么不是裸路径：Android 的 SAF 有时只给到字节流（`content://` 未落地），
/// 上层需要一个**本进程可读的普通文件路径**才能解压。此时选择器会把内容复制到
/// 应用私有临时文件，并通过 [isTemporary] 告诉调用方「用完请清理」。
class PickedZip {
  const PickedZip({required this.path, required this.isTemporary});

  /// 本进程可直接读取的 ZIP 文件路径。
  final String path;

  /// true 表示 [path] 是本应用私有临时目录里的**副本**，导入结束后应被删除。
  ///
  /// false 表示是用户选中的原始文件，**任何情况下都不能删除**。
  final bool isTemporary;

  @override
  String toString() => 'PickedZip($path, temporary=$isTemporary)';
}

abstract interface class FileImportProvider {
  /// 是否支持"选择文件夹"。
  bool get supportsFolderImport;

  /// 选择文件夹；不支持或用户取消时返回 null。
  Future<String?> pickFolderPath();

  /// 选择 ZIP 素材包；用户取消时返回 null。
  Future<PickedZip?> pickZip();

  /// 选择一张或多张图片。
  ///
  /// 返回的 [ImagePickResult.files] 都是**已物化、可直接读取**的文件；
  /// 拿不到内容的文件带原因进 [ImagePickResult.rejected]（不静默丢弃）。
  /// 用户取消（未选中任何文件）时返回 null。
  Future<ImagePickResult?> pickImages({required bool allowMultiple});
}

/// 把 `file_picker` 的选择结果物化成可直接读取的导入文件（两端共用）。
///
/// * [PlatformFile.path] 指向真实存在的文件 → 直接使用（`isTemporary=false`）；
/// * 只有 `bytes`（Android SAF 的 `content://` 未落地）→ 复制到应用私有临时目录，
///   并**保留原始文件名与扩展名**（角色/情绪解析、托管文件名都依赖它），
///   标记 `isTemporary=true`，由调用方在导入结束后清理；
/// * 两者都没有 → 记入 [ImagePickResult.rejected] 并带上原因，**绝不静默丢弃**。
Future<ImagePickResult> materializePickedImages(
  List<PlatformFile> picked, {
  Directory? tempRoot,
}) async {
  final List<SelectedImportFile> files = <SelectedImportFile>[];
  final List<RejectedImportFile> rejected = <RejectedImportFile>[];

  for (int i = 0; i < picked.length; i++) {
    final PlatformFile file = picked[i];
    final String originalName = file.name.trim().isEmpty ? 'image_$i' : file.name;

    final String? path = file.path;
    if (path != null && path.isNotEmpty) {
      final File candidate = File(path);
      if (await candidate.exists() && await candidate.length() > 0) {
        files.add(SelectedImportFile(
          localPath: candidate.path,
          originalName: originalName,
        ));
        continue;
      }
    }

    final Uint8List? bytes = file.bytes;
    if (bytes == null || bytes.isEmpty) {
      rejected.add(RejectedImportFile(
        name: originalName,
        reason: '系统既未提供可读路径，也没有提供文件内容',
      ));
      continue;
    }

    try {
      final File copy = await writeTemporaryCopy(
        bytes: bytes,
        originalName: originalName,
        index: i,
        tempRoot: tempRoot,
      );
      files.add(SelectedImportFile(
        localPath: copy.path,
        originalName: originalName,
        isTemporary: true,
        // SAF 没有真实路径：写索引时用它，避免指向随后会被清理的临时文件。
        originalSource: 'saf://$originalName',
      ));
    } catch (e) {
      rejected.add(RejectedImportFile(name: originalName, reason: '写入临时副本失败：$e'));
    }
  }

  return ImagePickResult(
    selectedCount: picked.length,
    files: files,
    rejected: rejected,
  );
}

/// 把一个文件写入应用私有临时目录，**每个文件一个独立子目录**且文件名保持原始名。
///
/// 独立子目录的作用：同名文件（不同目录下的 `a.png`）不会互相覆盖；
/// 清理时按 `dirname` 删除即可，绝不会碰到用户原始文件。
Future<File> writeTemporaryCopy({
  required Uint8List bytes,
  required String originalName,
  required int index,
  Directory? tempRoot,
}) async {
  final Directory root = tempRoot ?? AppPaths.instance.tmpDir;
  final Directory dir = Directory(
    p.join(root.path, 'picked_${DateTime.now().microsecondsSinceEpoch}_$index'),
  );
  await dir.create(recursive: true);
  final File copy = File(p.join(dir.path, safeImportFileName(originalName)));
  await copy.writeAsBytes(bytes, flush: true);
  return copy;
}

/// 把原始文件名规整成可安全落盘的名称（保留扩展名，只去掉非法字符）。
String safeImportFileName(String raw) {
  final String cleaned = raw
      .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
      .replaceAll(RegExp(r'^[._]+'), '')
      .trim();
  return cleaned.isEmpty ? 'image' : cleaned;
}

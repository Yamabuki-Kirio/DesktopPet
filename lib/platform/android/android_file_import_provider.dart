import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import '../../asset_import/import_models.dart';
import '../../core/paths.dart';
import '../file_import_provider.dart';

/// Android 文件选择器（SAF / 系统文件选择器）。
///
/// 约束与取舍（Phase 4A 第 9 项）：
/// * **ZIP 素材包**：走系统文件选择器（`ACTION_OPEN_DOCUMENT`），可用；
/// * **文件夹导入**：`file_picker.getDirectoryPath` 在 Android 上不被支持，
///   而 SAF 的目录选择（`ACTION_OPEN_DOCUMENT_TREE`）返回 `content://` URI，
///   需要一个原生通道把它递归复制到应用私有目录 —— 属于 Phase 4B 的原生工作。
///   因此本阶段 `supportsFolderImport == false`，界面据此隐藏"导入文件夹"，
///   并提示用户改用 ZIP 素材包（ZIP 导入路径两端完全一致）。
/// * **图片**：SAF 返回的 `PlatformFile.path` 可能为 null（只有 `content://` 或
///   字节流）。本实现同时请求 bytes，并把这类文件复制到应用私有临时目录，
///   绝不静默丢弃（否则"导入多张图片"只会导入一张）。
class AndroidFileImportProvider implements FileImportProvider {
  const AndroidFileImportProvider();

  @override
  bool get supportsFolderImport => false;

  @override
  Future<String?> pickFolderPath() async => null;

  @override
  Future<PickedZip?> pickZip() async {
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      dialogTitle: '选择 ZIP 素材包',
      type: FileType.custom,
      allowedExtensions: <String>['zip'],
      // SAF 可能出现「只有字节流、没有可读路径」的情况（content:// 未落地），
      // 因此同时请求 bytes 作为兜底。体积上限由 ZipAssetImporter 的安全校验兜底。
      withData: true,
    );
    if (result == null || result.files.isEmpty) return null;
    final PlatformFile file = result.files.single;
    return materializeZip(path: file.path, bytes: file.bytes);
  }

  @override
  Future<ImagePickResult?> pickImages({required bool allowMultiple}) async {
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      dialogTitle: allowMultiple ? '选择一张或多张图片' : '选择图片',
      allowMultiple: allowMultiple,
      type: FileType.custom,
      allowedExtensions: kImportImageExtensions,
      // 必须同时请求 bytes：部分 SAF 提供者只给字节流、`path` 为 null，
      // 少了它这些文件就会被丢弃（真机上表现为"选了 3 张只导入 1 张"）。
      withData: true,
    );
    if (result == null || result.files.isEmpty) return null;
    return materializePickedImages(result.files);
  }

  /// 把 SAF 选中的 ZIP 变成一个**本进程可直接读取**的普通文件路径。
  ///
  /// 规则：
  /// * [path] 指向真实存在且非空的文件 → 直接使用（用户原始文件，`isTemporary=false`）；
  /// * 否则若拿到 [bytes] → 复制到应用私有临时目录（`isTemporary=true`），
  ///   由调用方在导入结束后清理。
  ///
  /// 两者都没有时**抛异常**而不是返回一个不可读的路径 ——
  /// 让用户看到"系统没给到可读内容"，而不是在解压阶段才莫名失败。
  ///
  /// 同时公开为静态方法，便于在没有 Android 宿主的情况下做单元测试。
  static Future<PickedZip> materializeZip({
    String? path,
    Uint8List? bytes,
    Directory? tempDir,
  }) async {
    if (path != null && path.isNotEmpty) {
      final File candidate = File(path);
      if (await candidate.exists() && await candidate.length() > 0) {
        return PickedZip(path: candidate.path, isTemporary: false);
      }
    }

    final Uint8List? data = bytes;
    if (data == null || data.isEmpty) {
      throw const FileSystemException(
        '无法读取所选 ZIP 文件：系统既未提供可读路径，也没有提供文件内容',
      );
    }

    final File copy = await writeTemporaryCopy(
      bytes: data,
      originalName: 'picked.zip',
      index: 0,
      tempRoot: tempDir ?? AppPaths.instance.tmpDir,
    );
    return PickedZip(path: copy.path, isTemporary: true);
  }
}

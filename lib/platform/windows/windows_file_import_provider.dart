import 'package:file_picker/file_picker.dart';

import '../../asset_import/import_models.dart';
import '../file_import_provider.dart';

/// Windows 文件选择器：文件夹与 ZIP 都走系统对话框（`file_picker`）。
///
/// 与阶段 0/1 行为一致；返回的是普通文件系统路径，上层可以直接递归扫描。
class WindowsFileImportProvider implements FileImportProvider {
  const WindowsFileImportProvider();

  @override
  bool get supportsFolderImport => true;

  @override
  Future<String?> pickFolderPath() =>
      FilePicker.platform.getDirectoryPath(dialogTitle: '选择素材文件夹');

  @override
  Future<PickedZip?> pickZip() async {
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      dialogTitle: '选择 ZIP 素材包',
      type: FileType.custom,
      allowedExtensions: <String>['zip'],
    );
    if (result == null || result.files.isEmpty) return null;
    final String? path = result.files.single.path;
    if (path == null || path.isEmpty) return null;
    // 桌面必然给出普通文件路径：不建临时副本，也就没有需要清理的东西。
    return PickedZip(path: path, isTemporary: false);
  }

  @override
  Future<ImagePickResult?> pickImages({required bool allowMultiple}) async {
    // 桌面路径必然可读，因此**不需要** withData（避免把整张图读进内存）。
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      dialogTitle: allowMultiple ? '选择一张或多张图片' : '选择图片',
      allowMultiple: allowMultiple,
      type: FileType.custom,
      allowedExtensions: kImportImageExtensions,
    );
    if (result == null || result.files.isEmpty) return null;
    return materializePickedImages(result.files);
  }
}

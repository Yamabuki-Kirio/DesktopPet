import '../core/result.dart';
import 'asset_importer.dart';
import 'import_models.dart';

/// 统一的素材导入入口。
///
/// 背景（Phase 4A 真机缺陷）：装配层同时提供了 `DefaultAssetImporter` 与
/// `ZipAssetImporter`，而界面固定调用前者，于是 `ZipImportRequest` 被送进
/// 只认文件的导入器，用户看到的是内部类提示「ZIP 导入请使用 ZipAssetImporter」。
///
/// 修法不是让界面记住「哪个请求该喂哪个导入器」——那正是出错的形状——
/// 而是把分派收敛到**唯一入口**：界面只依赖 [AssetImporter]，
/// 由这里按请求的**静态类型**分派，页面不可能再接错。
///
/// 分派规则：
/// * [ZipImportRequest] → [zipImporter]；
/// * [FileImportRequest] / [FolderImportRequest] → [fileImporter]。
///
/// 密封类 [ImportRequest] 让这条分派在编译期就是穷尽的：
/// 以后新增请求类型时，这里会直接编译失败，而不是悄悄走进错误的分支。
class AssetImportRouter implements AssetImporter {
  const AssetImportRouter({
    required this.fileImporter,
    required this.zipImporter,
  });

  /// 单张 / 多张 / 文件夹。
  final AssetImporter fileImporter;

  /// ZIP 素材包。
  final AssetImporter zipImporter;

  @override
  Future<Result<ImportReport>> import(
    ImportRequest request, {
    ImportProgressCallback? onProgress,
  }) {
    return switch (request) {
      final ZipImportRequest r =>
        zipImporter.import(r, onProgress: onProgress),
      final FileImportRequest r =>
        fileImporter.import(r, onProgress: onProgress),
      final FolderImportRequest r =>
        fileImporter.import(r, onProgress: onProgress),
    };
  }
}

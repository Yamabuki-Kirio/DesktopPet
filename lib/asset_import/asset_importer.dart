import '../core/result.dart';
import 'import_models.dart';

/// 素材导入入口。
///
/// 抽象的目的：阶段 4（Android）与阶段 2（服务端同步）会引入不同的导入后端，
/// 但「选择文件 → 解析 → 校验 → 托管 → 建索引」这套业务语义不应重写。
abstract interface class AssetImporter {
  /// 执行导入。**不允许抛出异常**，全部失败信息通过 [ImportReport] 返回。
  Future<Result<ImportReport>> import(
    ImportRequest request, {
    ImportProgressCallback? onProgress,
  });
}

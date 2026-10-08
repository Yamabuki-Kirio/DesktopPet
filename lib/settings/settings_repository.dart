import 'app_settings.dart';

/// 设置的持久化抽象。
///
/// 阶段 0 落 SQLite 的 `local_settings` 表；
/// 阶段 2 需要跨设备同步时，只需在此之上加一层「远端优先 + 本地覆盖」的装饰器。
abstract interface class SettingsRepository {
  /// 读取某用户的全部设置（缺失字段用默认值补齐）。
  Future<AppSettings> load(String ownerId);

  /// 全量保存。
  Future<void> save(String ownerId, AppSettings settings);

  /// 局部更新（只写变化的 key，减少写放大）。
  Future<void> patch(String ownerId, Map<String, String?> values);

  /// 清空某用户的设置（恢复出厂）。
  Future<void> reset(String ownerId);
}

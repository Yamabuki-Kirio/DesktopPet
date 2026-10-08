import '../core/logger.dart';
import '../database/app_database.dart';
import '../database/dao/settings_dao.dart';
import 'app_settings.dart';
import 'settings_repository.dart';

/// 基于 SQLite `local_settings` 表的实现。
class SqliteSettingsRepository implements SettingsRepository {
  SqliteSettingsRepository(this._dao);

  factory SqliteSettingsRepository.fromDatabase(AppDatabase db) =>
      SqliteSettingsRepository(SettingsDao(db.raw));

  final SettingsDao _dao;

  @override
  Future<AppSettings> load(String ownerId) async {
    final Map<String, String> kv = await _dao.getAll(ownerId);
    final AppSettings settings = AppSettings.fromKeyValues(kv);
    Loggers.settings.fine('已加载 ${kv.length} 项设置');
    return settings;
  }

  @override
  Future<void> save(String ownerId, AppSettings settings) async {
    final AppSettings normalized = settings.normalized();
    await _dao.setAll(ownerId, normalized.toKeyValues(), DateTime.now());
    Loggers.settings.fine('设置已保存（${normalized.toKeyValues().length} 项）');
  }

  @override
  Future<void> patch(String ownerId, Map<String, String?> values) async {
    await _dao.setAll(ownerId, values, DateTime.now());
  }

  @override
  Future<void> reset(String ownerId) async {
    final Map<String, String> all = await _dao.getAll(ownerId);
    for (final String key in all.keys) {
      await _dao.delete(ownerId, key);
    }
    Loggers.settings.info('设置已重置为默认值');
  }
}

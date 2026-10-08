import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../core/constants.dart';
import '../database/app_database.dart';
import '../database/schema.dart';
import 'proxy/proxy_models.dart';

/// 同步相关的本地偏好（存在 v1 就有的 `local_settings` 里，不需要改表结构）。
///
/// 目前有两类：服务端地址与代理配置。它们都必须**在退出登录后仍然保留**，
/// 否则用户每次退出都要重新输入地址 / 重新配置 Clash。
///
/// ⚠️ 代理**密码不在**这里：本类只保存 [ProxySettings.passwordCredentialReference]，
/// 密码本体在 `CredentialStore`（Windows Credential Manager / DPAPI）。
class SyncPreferences {
  SyncPreferences(this._db);

  final AppDatabase _db;

  static const String _baseUrlKey = 'sync.serverBaseUrl';
  static const String _backfillKey = 'sync.historyBackfilledFor';

  /// 代理配置的键前缀（用于整组读写与删除）。
  static const String proxyKeyPrefix = 'sync.proxy';

  Future<String> serverBaseUrl({String ownerId = AppConstants.localOwnerId}) async {
    final String? value = await _read(_baseUrlKey, ownerId: ownerId);
    if (value == null || value.trim().isEmpty) {
      return SyncConfig.defaultServerBaseUrl;
    }
    return value.trim();
  }

  Future<void> setServerBaseUrl(
    String value, {
    String ownerId = AppConstants.localOwnerId,
  }) async {
    await _write(_baseUrlKey, value.trim(), ownerId: ownerId);
  }

  /// 历史数据回填标记：记录已经为哪个账户做过「存量数据入队」。
  ///
  /// 用它避免每次登录都把全部历史重新排一遍队（服务端虽然幂等，
  /// 但白传几千条记录既慢又浪费流量）。
  Future<String?> historyBackfillMarker({String ownerId = AppConstants.localOwnerId}) =>
      _read(_backfillKey, ownerId: ownerId);

  Future<void> setHistoryBackfillMarker(
    String userId, {
    String ownerId = AppConstants.localOwnerId,
  }) =>
      _write(_backfillKey, userId, ownerId: ownerId);

  // ---------------------------------------------------------------------------
  // 代理配置
  // ---------------------------------------------------------------------------

  /// 读取代理配置；从未配置过时返回 [ProxySettings.defaults]（= automatic）。
  Future<ProxySettings> proxySettings({
    String ownerId = AppConstants.localOwnerId,
  }) async {
    final List<Map<String, Object?>> rows = await _db.raw.query(
      DbSchema.tableSettings,
      columns: <String>['key', 'value'],
      where: 'owner_id = ? AND key LIKE ?',
      whereArgs: <Object?>[ownerId, '$proxyKeyPrefix%'],
    );
    if (rows.isEmpty) return ProxySettings.defaults;

    final Map<String, String> map = <String, String>{};
    for (final Map<String, Object?> row in rows) {
      final Object? key = row['key'];
      final Object? value = row['value'];
      if (key is String && value is String) map[key] = value;
    }
    return ProxySettings.fromStorageMap(map);
  }

  /// 整组写入代理配置。
  ///
  /// 用"先删该前缀的旧键、再写新键"的方式，这样**移除用户名/密码**这类
  /// 变更也能正确落库（否则旧值会一直留在表里）。
  Future<void> setProxySettings(
    ProxySettings settings, {
    String ownerId = AppConstants.localOwnerId,
  }) async {
    final Map<String, String> values = settings.toStorageMap();
    final int now = DateTime.now().millisecondsSinceEpoch;

    await _db.raw.transaction((Transaction txn) async {
      await txn.delete(
        DbSchema.tableSettings,
        where: 'owner_id = ? AND key LIKE ?',
        whereArgs: <Object?>[ownerId, '$proxyKeyPrefix%'],
      );
      for (final MapEntry<String, String> entry in values.entries) {
        await txn.insert(
          DbSchema.tableSettings,
          <String, Object?>{
            'owner_id': ownerId,
            'key': entry.key,
            'value': entry.value,
            'updated_at': now,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
  }

  Future<String?> _read(String key, {required String ownerId}) async {
    final List<Map<String, Object?>> rows = await _db.raw.query(
      DbSchema.tableSettings,
      columns: <String>['value'],
      where: 'owner_id = ? AND key = ?',
      whereArgs: <Object?>[ownerId, key],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['value'] as String?;
  }

  Future<void> _write(String key, String value, {required String ownerId}) async {
    await _db.raw.insert(
      DbSchema.tableSettings,
      <String, Object?>{
        'owner_id': ownerId,
        'key': key,
        'value': value,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }
}

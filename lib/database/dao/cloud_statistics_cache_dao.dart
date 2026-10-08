import 'dart:async';
import 'dart:convert';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../schema.dart';

/// 云端缓存的查询类型（缓存键的一部分）。
enum CloudCacheType {
  devices('devices'),
  summary('summary'),
  apps('apps'),
  timeline('timeline'),
  sessions('sessions');

  const CloudCacheType(this.wireName);

  final String wireName;

  static CloudCacheType? fromWire(String value) {
    for (final CloudCacheType t in CloudCacheType.values) {
      if (t.wireName == value) return t;
    }
    return null;
  }
}

/// 一条缓存记录。
class CloudCacheEntry {
  const CloudCacheEntry({
    required this.payload,
    required this.fetchedAt,
    required this.queryType,
  });

  final Map<String, Object?> payload;

  /// 服务端返回这份数据的时间（用于"最近刷新时间"与"离线数据"提示）。
  final DateTime fetchedAt;

  final CloudCacheType queryType;
}

/// `cloud_statistics_cache` 数据访问。
///
/// 三条硬约束（对应 Phase 4B 需求"数据边界"）：
/// 1. 本表**只**存从服务端读回来的统计数据，绝不写入本机采集表；
/// 2. 本表的任何写入都**不会**进入 `sync_outbox`（没有 outbox 生产者会读它）；
/// 3. 更新走显式的 `UPDATE` → `INSERT`，**绝不用 `INSERT OR REPLACE`** ——
///    项目已有一条真实故障（父表 REPLACE 触发 `ON DELETE CASCADE` 丢数据），
///    这里即使当前是叶子表也不再用 REPLACE，避免将来加了关系再踩一次。
class CloudStatisticsCacheDao {
  CloudStatisticsCacheDao(this._db);

  final DatabaseExecutor _db;

  Future<void> write({
    required String accountUserId,
    required String cacheKey,
    required CloudCacheType type,
    required String deviceKey,
    required String dayKey,
    required String timezone,
    String? appId,
    required Map<String, Object?> payload,
    required DateTime fetchedAt,
  }) async {
    final Map<String, Object?> values = <String, Object?>{
      'account_user_id': accountUserId,
      'cache_key': cacheKey,
      'query_type': type.wireName,
      'device_key': deviceKey,
      'day_key': dayKey,
      'timezone': timezone,
      'app_id': appId,
      'payload_json': jsonEncode(payload),
      'fetched_at': fetchedAt.millisecondsSinceEpoch,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    };

    final int updated = await _db.update(
      DbSchema.tableCloudCache,
      values,
      where: 'account_user_id = ? AND cache_key = ?',
      whereArgs: <Object?>[accountUserId, cacheKey],
    );
    if (updated == 0) {
      await _db.insert(
        DbSchema.tableCloudCache,
        values,
        conflictAlgorithm: ConflictAlgorithm.abort,
      );
    }
  }

  Future<CloudCacheEntry?> read({
    required String accountUserId,
    required String cacheKey,
  }) async {
    final List<Map<String, Object?>> rows = await _db.query(
      DbSchema.tableCloudCache,
      where: 'account_user_id = ? AND cache_key = ?',
      whereArgs: <Object?>[accountUserId, cacheKey],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _toEntry(rows.first);
  }

  /// 最近一次成功刷新时间（不限查询键）。
  Future<DateTime?> lastFetchedAt(String accountUserId) async {
    final List<Map<String, Object?>> rows = await _db.query(
      DbSchema.tableCloudCache,
      columns: <String>['fetched_at'],
      where: 'account_user_id = ?',
      whereArgs: <Object?>[accountUserId],
      orderBy: 'fetched_at DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final Object? value = rows.first['fetched_at'];
    if (value is! int) return null;
    return DateTime.fromMillisecondsSinceEpoch(value);
  }

  Future<int> countForAccount(String accountUserId) async {
    final List<Map<String, Object?>> rows = await _db.rawQuery(
      'SELECT COUNT(*) AS c FROM ${DbSchema.tableCloudCache} WHERE account_user_id = ?',
      <Object?>[accountUserId],
    );
    return (rows.first['c'] as int?) ?? 0;
  }

  /// 退出账户时清理该账户的缓存（**不动**本机采集数据与 outbox）。
  Future<int> deleteAccount(String accountUserId) async {
    return _db.delete(
      DbSchema.tableCloudCache,
      where: 'account_user_id = ?',
      whereArgs: <Object?>[accountUserId],
    );
  }

  Future<void> deleteAll() async {
    await _db.delete(DbSchema.tableCloudCache);
  }

  /// 解析一行；**payload 损坏时返回 null（当作未命中）而不是抛异常**。
  ///
  /// 缓存是可有可无的加速层：一行坏数据不该让整个"云端统计"页崩掉，
  /// 正确的反应是当作没有缓存 → 重新向服务端要一次 → 覆盖掉坏行。
  /// 顺手把坏行删掉，让缓存自愈。
  CloudCacheEntry? _toEntry(Map<String, Object?> row) {
    final Object? raw = row['payload_json'];
    Map<String, Object?> payload;
    try {
      payload = raw is String && raw.isNotEmpty
          ? (jsonDecode(raw) as Map).cast<String, Object?>()
          : <String, Object?>{};
    } catch (_) {
      _deleteCorruptRow(row);
      return null;
    }
    if (payload.isEmpty) return null;

    final Object? fetched = row['fetched_at'];
    return CloudCacheEntry(
      payload: payload,
      fetchedAt: fetched is int
          ? DateTime.fromMillisecondsSinceEpoch(fetched)
          : DateTime.fromMillisecondsSinceEpoch(0),
      queryType: CloudCacheType.fromWire('${row['query_type']}') ??
          CloudCacheType.summary,
    );
  }

  void _deleteCorruptRow(Map<String, Object?> row) {
    // 尽力而为：失败也不影响主流程。
    unawaited(
      _db
          .delete(
            DbSchema.tableCloudCache,
            where: 'account_user_id = ? AND cache_key = ?',
            whereArgs: <Object?>[row['account_user_id'], row['cache_key']],
          )
          .catchError((Object _) => 0),
    );
  }
}

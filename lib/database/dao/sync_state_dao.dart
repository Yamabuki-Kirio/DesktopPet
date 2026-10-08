import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../sync/models/sync_models.dart';
import '../schema.dart';

/// `sync_state` 数据访问：每类实体的游标与退避状态。
class SyncStateDao {
  SyncStateDao(this._db);

  final Database _db;

  Future<List<SyncStateRow>> loadAll() async {
    final List<Map<String, Object?>> rows =
        await _db.query(DbSchema.tableSyncState);
    return rows.map(SyncStateRow.fromMap).toList(growable: false);
  }

  Future<SyncStateRow?> load(SyncEntityType type) async {
    final List<Map<String, Object?>> rows = await _db.query(
      DbSchema.tableSyncState,
      where: 'entity_type = ?',
      whereArgs: <Object?>[type.wireName],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return SyncStateRow.fromMap(rows.first);
  }

  Future<void> save(SyncStateRow state) async {
    await _db.insert(
      DbSchema.tableSyncState,
      state.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 记录一次成功：推进游标、清零失败计数与重试时间。
  Future<void> recordSuccess(
    SyncEntityType type, {
    required int cursor,
    required DateTime at,
  }) async {
    await save(SyncStateRow(
      entityType: type,
      cursor: cursor,
      lastSuccessAt: at,
      lastError: null,
      consecutiveFailures: 0,
      nextRetryAt: null,
      updatedAt: at,
    ));
  }

  /// 记录一次失败：累加失败计数并写入下次重试时间。
  Future<void> recordFailure(
    SyncEntityType type, {
    required String error,
    required int consecutiveFailures,
    required DateTime nextRetryAt,
    required DateTime at,
  }) async {
    final SyncStateRow? existing = await load(type);
    await save(SyncStateRow(
      entityType: type,
      cursor: existing?.cursor ?? 0,
      lastSuccessAt: existing?.lastSuccessAt,
      lastError: error,
      consecutiveFailures: consecutiveFailures,
      nextRetryAt: nextRetryAt,
      updatedAt: at,
    ));
  }

  /// 解除退避（网络恢复 / 用户点「立即同步」时调用）。
  Future<void> clearBackoff(SyncEntityType type, {required DateTime at}) async {
    final SyncStateRow? existing = await load(type);
    if (existing == null) return;
    await save(SyncStateRow(
      entityType: type,
      cursor: existing.cursor,
      lastSuccessAt: existing.lastSuccessAt,
      lastError: null,
      consecutiveFailures: 0,
      nextRetryAt: null,
      updatedAt: at,
    ));
  }
}

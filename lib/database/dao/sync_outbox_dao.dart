import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../core/logger.dart';
import '../../sync/models/sync_models.dart';
import '../schema.dart';

/// `sync_outbox` 数据访问：待同步队列。
///
/// 三条硬性保证：
/// 1. **不丢数据**：失败记录只更新重试时间，绝不删除；
/// 2. **幂等排队**：同一 `(entity_type, entity_key)` 只保留一条未确认记录，
///    重复排队只是覆盖快照，靠建表时的部分唯一索引兜底；
/// 3. **幂等确认**：`acknowledge` 只对未确认行生效，重复确认不报错也不改写时间。
class SyncOutboxDao {
  SyncOutboxDao(this._db);

  final Database _db;

  /// 入队（或刷新已有未确认记录）。
  ///
  /// 返回最终生效的记录 id。已确认过的同一实体再次入队会**新建**一条记录——
  /// 这在语义上是对的：那是一份需要重新上传的新快照。
  Future<String> enqueue(OutboxEntry entry) =>
      _db.transaction((Transaction txn) => _enqueueWith(txn, entry));

  /// 批量入队（历史数据回填用）。
  ///
  /// 整批在**一个事务**里完成：要么全部入队，要么全部不入队，
  /// 不会留下"回填了一半"的中间状态。
  Future<int> enqueueAll(Iterable<OutboxEntry> entries) async {
    int count = 0;
    await _db.transaction((Transaction txn) async {
      for (final OutboxEntry entry in entries) {
        await _enqueueWith(txn, entry);
        count++;
      }
    });
    return count;
  }

  /// 在**调用方的事务**里批量入队（Phase 4C-5.1B 导入路径专用）。
  ///
  /// 为什么需要它：Android 原生会话导入要求"业务行 + outbox 记录"在**同一个事务**
  /// 里提交（需求 §6.2），而 [enqueueAll] 会自己开一个事务 —— 嵌套事务在 sqflite 上
  /// 语义微妙。这里复用同一套去重实现，只是把执行器换成调用方传进来的 [exec]。
  ///
  /// [exec] 可以是 `Transaction`（在事务内）或 `Database`（无事务），两者都满足
  /// `DatabaseExecutor`，因此这条路径既能在事务里用，也能单独用。
  Future<int> enqueueAllWith(
    DatabaseExecutor exec,
    Iterable<OutboxEntry> entries,
  ) async {
    int count = 0;
    for (final OutboxEntry entry in entries) {
      await _enqueueWith(exec, entry);
      count++;
    }
    return count;
  }

  Future<String> _enqueueWith(DatabaseExecutor exec, OutboxEntry entry) async {
    final List<Map<String, Object?>> existing = await exec.query(
      DbSchema.tableSyncOutbox,
      columns: <String>['id'],
      where: 'entity_type = ? AND entity_key = ? AND acknowledged_at IS NULL',
      whereArgs: <Object?>[entry.entityType.wireName, entry.entityKey],
      limit: 1,
    );

    final Map<String, Object?> values = entry.toMap();

    if (existing.isNotEmpty) {
      final String id = existing.first['id']! as String;
      // 只刷新快照与本地标识；**保留** attempt_count 与 next_attempt_at，
      // 否则一条总是失败的记录会被每次入队重置退避，变成忙等重试。
      await exec.update(
        DbSchema.tableSyncOutbox,
        <String, Object?>{
          'payload_json': values['payload_json'],
          'entity_local_id': values['entity_local_id'],
          'operation': values['operation'],
        },
        where: 'id = ?',
        whereArgs: <Object?>[id],
      );
      return id;
    }

    try {
      await exec.insert(DbSchema.tableSyncOutbox, values);
      return entry.id;
    } on DatabaseException catch (e, st) {
      // 并发入队撞上部分唯一索引：退化为更新
      Loggers.sync.fine('outbox 入队冲突，改为刷新鲜照: ${entry.entityKey}', e, st);
      await exec.update(
        DbSchema.tableSyncOutbox,
        <String, Object?>{
          'payload_json': values['payload_json'],
          'entity_local_id': values['entity_local_id'],
        },
        where: 'entity_type = ? AND entity_key = ? AND acknowledged_at IS NULL',
        whereArgs: <Object?>[entry.entityType.wireName, entry.entityKey],
      );
      return entry.id;
    }
  }

  /// 待同步总数（UI 展示）。
  Future<int> pendingCount() async {
    final List<Map<String, Object?>> rows = await _db.rawQuery(
      'SELECT COUNT(*) AS c FROM ${DbSchema.tableSyncOutbox} WHERE acknowledged_at IS NULL',
    );
    return (rows.first['c'] as int?) ?? 0;
  }

  /// 按实体类型统计待同步数量。
  Future<Map<SyncEntityType, int>> pendingCountByType() async {
    final List<Map<String, Object?>> rows = await _db.rawQuery(
      'SELECT entity_type, COUNT(*) AS c FROM ${DbSchema.tableSyncOutbox} '
      'WHERE acknowledged_at IS NULL GROUP BY entity_type',
    );
    final Map<SyncEntityType, int> result = <SyncEntityType, int>{};
    for (final Map<String, Object?> row in rows) {
      final SyncEntityType? type = SyncEntityType.fromWire(row['entity_type'] as String?);
      if (type != null) result[type] = (row['c'] as int?) ?? 0;
    }
    return result;
  }

  /// 取一批可以发送的记录（未确认 且 已到达重试时间），按入队时间升序。
  Future<List<OutboxEntry>> takeBatch({
    required int limit,
    required DateTime now,
  }) async {
    final List<Map<String, Object?>> rows = await _db.query(
      DbSchema.tableSyncOutbox,
      where: 'acknowledged_at IS NULL AND next_attempt_at <= ?',
      whereArgs: <Object?>[now.millisecondsSinceEpoch],
      orderBy: 'created_at ASC, id ASC',
      limit: limit,
    );
    return rows.map(OutboxEntry.fromMap).toList(growable: false);
  }

  /// 取某个实体类型的一批记录。
  Future<List<OutboxEntry>> takeBatchOfType({
    required SyncEntityType type,
    required int limit,
    required DateTime now,
  }) async {
    final List<Map<String, Object?>> rows = await _db.query(
      DbSchema.tableSyncOutbox,
      where: 'entity_type = ? AND acknowledged_at IS NULL AND next_attempt_at <= ?',
      whereArgs: <Object?>[type.wireName, now.millisecondsSinceEpoch],
      orderBy: 'created_at ASC, id ASC',
      limit: limit,
    );
    return rows.map(OutboxEntry.fromMap).toList(growable: false);
  }

  /// 标记已确认（收到服务端确认后才调用）。
  ///
  /// 只影响 `acknowledged_at IS NULL` 的行，因此**重复确认是幂等的**。
  Future<int> acknowledge(List<String> ids, {required DateTime at}) async {
    if (ids.isEmpty) return 0;
    final Batch batch = _db.batch();
    for (final String id in ids) {
      batch.update(
        DbSchema.tableSyncOutbox,
        <String, Object?>{'acknowledged_at': at.millisecondsSinceEpoch},
        where: 'id = ? AND acknowledged_at IS NULL',
        whereArgs: <Object?>[id],
      );
    }
    final List<Object?> results = await batch.commit();
    int affected = 0;
    for (final Object? r in results) {
      if (r is int) affected += r;
    }
    return affected;
  }

  /// 记录一次发送失败：累加次数、写入下次重试时间、**保留数据**。
  Future<void> markFailed(
    Iterable<String> ids, {
    required String error,
    required DateTime nextAttemptAt,
  }) async {
    if (ids.isEmpty) return;
    final Batch batch = _db.batch();
    for (final String id in ids) {
      batch.rawUpdate(
        'UPDATE ${DbSchema.tableSyncOutbox} '
        'SET attempt_count = attempt_count + 1, last_error = ?, next_attempt_at = ? '
        'WHERE id = ? AND acknowledged_at IS NULL',
        <Object?>[error, nextAttemptAt.millisecondsSinceEpoch, id],
      );
    }
    await batch.commit(noResult: true);
  }

  /// 清理已确认的历史记录（避免表无限增长）。
  Future<int> deleteAcknowledgedBefore(DateTime threshold) async {
    return _db.delete(
      DbSchema.tableSyncOutbox,
      where: 'acknowledged_at IS NOT NULL AND acknowledged_at < ?',
      whereArgs: <Object?>[threshold.millisecondsSinceEpoch],
    );
  }

  Future<int> countAcknowledged() async {
    final List<Map<String, Object?>> rows = await _db.rawQuery(
      'SELECT COUNT(*) AS c FROM ${DbSchema.tableSyncOutbox} WHERE acknowledged_at IS NOT NULL',
    );
    return (rows.first['c'] as int?) ?? 0;
  }
}

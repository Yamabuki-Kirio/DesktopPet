import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../activity_tracking/models/activity_sample.dart';
import '../schema.dart';

/// `activity_checkpoints` 数据访问。
///
/// 每个活动段最多一行（segment_id 为主键），每 30 秒覆盖写入，
/// 因此写入量恒定、不会随运行时长增长。
class ActivityCheckpointDao {
  ActivityCheckpointDao(this._db);

  final Database _db;

  Future<void> upsert(ActivityCheckpoint checkpoint) async {
    await _db.insert(
      DbSchema.tableActivityCheckpoints,
      checkpoint.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<ActivityCheckpoint?> find(String segmentId) async {
    final List<Map<String, Object?>> rows = await _db.query(
      DbSchema.tableActivityCheckpoints,
      where: 'segment_id = ?',
      whereArgs: <Object?>[segmentId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return ActivityCheckpoint.fromMap(rows.first);
  }

  Future<void> delete(String segmentId) async {
    await _db.delete(
      DbSchema.tableActivityCheckpoints,
      where: 'segment_id = ?',
      whereArgs: <Object?>[segmentId],
    );
  }

  /// 清掉已经没有对应「未关闭活动段」的孤儿检查点。
  Future<int> deleteOrphans() async {
    return _db.delete(
      DbSchema.tableActivityCheckpoints,
      where: 'segment_id NOT IN ('
          'SELECT id FROM ${DbSchema.tableActivitySegments} WHERE ended_at IS NULL)',
    );
  }

  Future<int> count() async {
    final List<Map<String, Object?>> rows =
        await _db.rawQuery('SELECT COUNT(*) AS c FROM ${DbSchema.tableActivityCheckpoints}');
    return (rows.first['c'] as int?) ?? 0;
  }
}

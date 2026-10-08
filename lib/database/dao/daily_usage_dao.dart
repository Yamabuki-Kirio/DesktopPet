import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../activity_tracking/models/tracking_settings.dart';
import '../schema.dart';

/// `daily_usage` 数据访问（设备级每日用量）。
class DailyUsageDao {
  DailyUsageDao(this._db);

  final Database _db;

  /// 写入某一天的完整计数（覆盖写：调用方持有权威计数）。
  Future<void> upsert(DailyUsage usage) async {
    await _db.insert(
      DbSchema.tableDailyUsage,
      usage.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<DailyUsage?> find(String ownerId, String deviceLocalId, String dayKey) async {
    final List<Map<String, Object?>> rows = await _db.query(
      DbSchema.tableDailyUsage,
      where: 'owner_id = ? AND device_local_id = ? AND day_key = ?',
      whereArgs: <Object?>[ownerId, deviceLocalId, dayKey],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return DailyUsage.fromMap(rows.first);
  }

  /// 读取一段日期键区间的每日用量（用于「最近 7 天 / 本周」聚合）。
  Future<List<DailyUsage>> listDays(
    String ownerId,
    String deviceLocalId,
    String fromDayKey,
    String toDayKey,
  ) async {
    final List<Map<String, Object?>> rows = await _db.query(
      DbSchema.tableDailyUsage,
      where: 'owner_id = ? AND device_local_id = ? AND day_key >= ? AND day_key <= ?',
      whereArgs: <Object?>[ownerId, deviceLocalId, fromDayKey, toDayKey],
      orderBy: 'day_key ASC',
    );
    return rows.map(DailyUsage.fromMap).toList(growable: false);
  }

  /// 按「行最后一次更新时刻」查询。
  ///
  /// 仅作为兜底：用户手工改了系统时区后，按本地日期键可能查不到当天行，
  /// 此时用更新时间落在窗口内的行补上，避免概览突然变成 0。
  Future<List<DailyUsage>> listByUpdatedRange(
    String ownerId,
    String deviceLocalId,
    DateTime from,
    DateTime to,
  ) async {
    final List<Map<String, Object?>> rows = await _db.query(
      DbSchema.tableDailyUsage,
      where: 'owner_id = ? AND device_local_id = ? AND updated_at >= ? AND updated_at < ?',
      whereArgs: <Object?>[
        ownerId,
        deviceLocalId,
        from.millisecondsSinceEpoch,
        to.millisecondsSinceEpoch,
      ],
      orderBy: 'updated_at ASC',
    );
    return rows.map(DailyUsage.fromMap).toList(growable: false);
  }

  /// 列出涉及到的全部设备 ID。
  ///
  /// 用于统计页「多设备数据不得错误合并」——同一 owner 下不同设备各自成行，
  /// 展示时按设备区分，绝不做跨设备求和。
  Future<List<String>> listDeviceIds(String ownerId) async {
    final List<Map<String, Object?>> rows = await _db.rawQuery(
      'SELECT DISTINCT device_local_id FROM ${DbSchema.tableDailyUsage} WHERE owner_id = ?',
      <Object?>[ownerId],
    );
    return rows
        .map((Map<String, Object?> r) => r['device_local_id']! as String)
        .toList(growable: false);
  }

  /// 把历史上写在**旧设备标识**下的每日行迁到当前标识（Phase 4C-5.1A）。
  ///
  /// 主键是 `(owner_id, device_local_id, day_key)`：如果目标标识当天已经有行，
  /// 就**跳过**该行（保留目标行，绝不把两行相加）—— 这正是"不重复累计"的落点。
  /// 迁移只改标识，不改时间与秒数。
  ///
  /// @return 实际迁移的行数
  Future<int> migrateDeviceLocalId(
    String fromDeviceLocalId,
    String toDeviceLocalId,
  ) async {
    if (fromDeviceLocalId == toDeviceLocalId) return 0;
    return _db.rawUpdate(
      'UPDATE ${DbSchema.tableDailyUsage} SET device_local_id = ? '
      'WHERE device_local_id = ? '
      'AND NOT EXISTS ('
      '  SELECT 1 FROM ${DbSchema.tableDailyUsage} d2 '
      '  WHERE d2.owner_id = ${DbSchema.tableDailyUsage}.owner_id '
      '    AND d2.day_key = ${DbSchema.tableDailyUsage}.day_key '
      '    AND d2.device_local_id = ?'
      ')',
      <Object?>[toDeviceLocalId, fromDeviceLocalId, toDeviceLocalId],
    );
  }
}

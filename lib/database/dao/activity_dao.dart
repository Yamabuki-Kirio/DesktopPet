import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../schema.dart';

/// 一段前台应用使用记录。
///
/// 阶段 0 **不写入**该表，仅预先建表并把读写接口打通，
/// 保证阶段 1 接入前台应用识别时不需要改动数据库结构。
class ActivitySegment {
  const ActivitySegment({
    required this.id,
    required this.ownerId,
    required this.deviceLocalId,
    required this.appKey,
    this.appName,
    this.processName,
    required this.startedAt,
    this.endedAt,
    this.activeSeconds,
    this.endReason,
    this.syncStatus = 'pending',
    required this.createdAt,
  });

  final String id;
  final String ownerId;
  final String deviceLocalId;
  final String appKey;
  final String? appName;
  final String? processName;
  final DateTime startedAt;
  final DateTime? endedAt;
  final int? activeSeconds;
  final String? endReason;

  /// 同步状态：pending / synced / failed（阶段 2 使用）。
  final String syncStatus;
  final DateTime createdAt;

  Map<String, Object?> toMap() => <String, Object?>{
        'id': id,
        'owner_id': ownerId,
        'device_local_id': deviceLocalId,
        'app_key': appKey,
        'app_name': appName,
        'process_name': processName,
        'started_at': startedAt.millisecondsSinceEpoch,
        'ended_at': endedAt?.millisecondsSinceEpoch,
        'active_seconds': activeSeconds,
        'end_reason': endReason,
        'sync_status': syncStatus,
        'created_at': createdAt.millisecondsSinceEpoch,
      };

  static ActivitySegment fromMap(Map<String, Object?> m) => ActivitySegment(
        id: m['id']! as String,
        ownerId: m['owner_id']! as String,
        deviceLocalId: m['device_local_id']! as String,
        appKey: m['app_key']! as String,
        appName: m['app_name'] as String?,
        processName: m['process_name'] as String?,
        startedAt: DateTime.fromMillisecondsSinceEpoch(m['started_at']! as int),
        endedAt: m['ended_at'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(m['ended_at']! as int),
        activeSeconds: m['active_seconds'] as int?,
        endReason: m['end_reason'] as String?,
        syncStatus: (m['sync_status'] as String?) ?? 'pending',
        createdAt: DateTime.fromMillisecondsSinceEpoch(m['created_at']! as int),
      );
}

/// `activity_segments` 数据访问（阶段 1 启用）。
class ActivityDao {
  ActivityDao(this._db);

  final Database _db;

  Future<void> insert(ActivitySegment segment) async {
    await _db.insert(
      DbSchema.tableActivitySegments,
      segment.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<ActivitySegment>> listRange(
    String ownerId,
    DateTime from,
    DateTime to,
  ) async {
    final List<Map<String, Object?>> rows = await _db.query(
      DbSchema.tableActivitySegments,
      where: 'owner_id = ? AND started_at >= ? AND started_at < ?',
      whereArgs: <Object?>[
        ownerId,
        from.millisecondsSinceEpoch,
        to.millisecondsSinceEpoch,
      ],
      orderBy: 'started_at ASC',
    );
    return rows.map(ActivitySegment.fromMap).toList(growable: false);
  }

  Future<List<ActivitySegment>> listPendingSync(String ownerId, {int limit = 500}) async {
    final List<Map<String, Object?>> rows = await _db.query(
      DbSchema.tableActivitySegments,
      where: "owner_id = ? AND sync_status = 'pending'",
      whereArgs: <Object?>[ownerId],
      orderBy: 'started_at ASC',
      limit: limit,
    );
    return rows.map(ActivitySegment.fromMap).toList(growable: false);
  }

  Future<void> closeSegment(String id, DateTime endedAt, int activeSeconds, String endReason) async {
    await _db.update(
      DbSchema.tableActivitySegments,
      <String, Object?>{
        'ended_at': endedAt.millisecondsSinceEpoch,
        'active_seconds': activeSeconds,
        'end_reason': endReason,
      },
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  /// 活动段仍在进行中时更新已累计秒数（每 30 秒一次）。
  ///
  /// 好处：统计页可以看到「正在进行中的这一段」，异常退出时也有兜底数据。
  Future<void> updateActiveSeconds(String id, int activeSeconds) async {
    await _db.update(
      DbSchema.tableActivitySegments,
      <String, Object?>{'active_seconds': activeSeconds},
      where: 'id = ? AND ended_at IS NULL',
      whereArgs: <Object?>[id],
    );
  }

  /// 查询与 `[from, to)` 有交集的活动段。
  ///
  /// 用交集而不是「起点落在区间内」，是为了让跨日/跨窗口的段也能被正确裁剪统计
  /// （验收第 23 项「今日和跨日统计边界正确」）。
  /// 走 `(owner_id, started_at)` 索引，不做全表扫描。
  Future<List<ActivitySegment>> listOverlapping(
    String ownerId,
    DateTime from,
    DateTime to, {
    String? deviceLocalId,
    int limit = 20000,
  }) async {
    final String deviceClause =
        deviceLocalId == null ? '' : ' AND device_local_id = ?';
    final List<Object?> args = <Object?>[
      ownerId,
      to.millisecondsSinceEpoch,
      from.millisecondsSinceEpoch,
      if (deviceLocalId != null) deviceLocalId,
    ];
    final List<Map<String, Object?>> rows = await _db.query(
      DbSchema.tableActivitySegments,
      where: 'owner_id = ? AND started_at < ? '
          'AND (ended_at IS NULL OR ended_at > ?)$deviceClause',
      whereArgs: args,
      orderBy: 'started_at ASC',
      limit: limit,
    );
    return rows.map(ActivitySegment.fromMap).toList(growable: false);
  }

  /// 仍未关闭的活动段（上次异常退出遗留）。
  Future<List<ActivitySegment>> listOpen(String ownerId) async {
    final List<Map<String, Object?>> rows = await _db.query(
      DbSchema.tableActivitySegments,
      where: 'owner_id = ? AND ended_at IS NULL',
      whereArgs: <Object?>[ownerId],
      orderBy: 'started_at ASC',
    );
    return rows.map(ActivitySegment.fromMap).toList(growable: false);
  }

  /// 统计某个应用在区间内的段数量（排行页展示「启动或使用段次数」）。
  Future<int> countByApp(String ownerId, String appKey, DateTime from, DateTime to) async {
    final List<Map<String, Object?>> rows = await _db.rawQuery(
      'SELECT COUNT(*) AS c FROM ${DbSchema.tableActivitySegments} '
      'WHERE owner_id = ? AND app_key = ? AND started_at < ? '
      'AND (ended_at IS NULL OR ended_at > ?)',
      <Object?>[
        ownerId,
        appKey,
        to.millisecondsSinceEpoch,
        from.millisecondsSinceEpoch,
      ],
    );
    return (rows.first['c'] as int?) ?? 0;
  }

  Future<void> markSynced(List<String> ids) async {
    if (ids.isEmpty) return;
    final String placeholders = List<String>.filled(ids.length, '?').join(',');
    await _db.update(
      DbSchema.tableActivitySegments,
      <String, Object?>{'sync_status': 'synced'},
      where: 'id IN ($placeholders)',
      whereArgs: ids,
    );
  }

  /// 把历史上写在**旧设备标识**下的行迁到当前标识（Phase 4C-5.1A）。
  ///
  /// 背景：4C-5.1A 之前本地采集表统一写常量 `desktop.local`；Android 改用
  /// `DeviceIdentity` 的稳定安装 UUID 后，旧行若不迁就会被新查询漏掉。
  /// 迁移只是改标识、不改时间与时长，因此**不会造成重复累计**。
  ///
  /// @return 实际迁移的行数
  Future<int> migrateDeviceLocalId(
    String fromDeviceLocalId,
    String toDeviceLocalId,
  ) async {
    if (fromDeviceLocalId == toDeviceLocalId) return 0;
    return _db.update(
      DbSchema.tableActivitySegments,
      <String, Object?>{'device_local_id': toDeviceLocalId},
      where: 'device_local_id = ?',
      whereArgs: <Object?>[fromDeviceLocalId],
    );
  }
}

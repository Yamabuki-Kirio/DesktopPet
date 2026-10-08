import 'package:uuid/uuid.dart';

import '../core/constants.dart';
import '../core/logger.dart';
import '../database/app_database.dart';
import '../database/dao/sync_outbox_dao.dart';
import '../database/schema.dart';
import 'models/sync_models.dart';

/// 从本地表生成 outbox 记录。
///
/// 两条设计约定：
///
/// 1. **payload 在推送时重建**（[buildPayload]），而不是发送入队时的快照。
///    这对每日用量尤其重要——它必须永远是**完整快照**，而不是增量累加；
///    入队时存下的 `payload_json` 只作为诊断快照保留。
/// 2. **`device_id` 由引擎在推送时注入**（服务端设备 UUID 可能变化，
///    例如换账号或设备被撤销后重新绑定），因此 outbox 里不固化它。
///
/// 上传字段严格限定在服务端允许的范围内：
/// **不含窗口标题、URL、文档名、可执行文件路径、截图、素材或日志。**
class OutboxProducer {
  OutboxProducer({
    required AppDatabase db,
    required SyncOutboxDao outbox,
    String ownerId = AppConstants.localOwnerId,
  })  : _db = db,
        _outbox = outbox,
        _ownerId = ownerId;

  final AppDatabase _db;
  final SyncOutboxDao _outbox;
  final String _ownerId;

  static const Uuid _uuid = Uuid();

  /// 历史回填上限：避免首次登录时一次排入过多记录导致内存与耗时不可控。
  static const int historyBackfillLimit = 20000;

  // ---------------------------------------------------------------------------
  // 入队
  // ---------------------------------------------------------------------------

  /// 活动段入队（开段 / 关段 / 检查点更新后调用）。
  Future<void> enqueueSegment(String segmentId) async {
    final Map<String, Object?>? row = await _segmentRow(segmentId);
    if (row == null) return;
    final SyncEntityType type = SyncEntityType.activitySegment;
    await _outbox.enqueue(OutboxEntry(
      id: _uuid.v4(),
      entityType: type,
      entityKey: segmentId,
      entityLocalId: segmentId,
      payload: (await buildPayloadFromRow(type, row)) ?? const <String, Object?>{},
      createdAt: DateTime.now(),
    ));
  }

  /// 每日用量入队（检查点落盘后调用）。
  ///
  /// `entity_key` 固定为 `<device_local_id>:<day_key>`，因此同一天重复入队只会
  /// 保留一条待同步记录，且推送时取的是当时的**完整快照**。
  Future<void> enqueueDailyUsage({
    required String deviceLocalId,
    required String dayKey,
  }) async {
    final Map<String, Object?>? row =
        await _dailyRow(deviceLocalId: deviceLocalId, dayKey: dayKey);
    if (row == null) return;
    final SyncEntityType type = SyncEntityType.dailyUsage;
    final String key = '$deviceLocalId:$dayKey';
    await _outbox.enqueue(OutboxEntry(
      id: _uuid.v4(),
      entityType: type,
      entityKey: key,
      entityLocalId: key,
      payload: (await buildPayloadFromRow(type, row)) ?? const <String, Object?>{},
      createdAt: DateTime.now(),
    ));
  }

  /// 应用记录入队（发现新应用 / 用户改分类或显示名后调用）。
  Future<void> enqueueApplication(String appKey) async {
    final Map<String, Object?>? row = await _applicationRow(appKey);
    if (row == null) return;
    final SyncEntityType type = SyncEntityType.application;
    await _outbox.enqueue(OutboxEntry(
      id: _uuid.v4(),
      entityType: type,
      entityKey: appKey,
      entityLocalId: appKey,
      payload: (await buildPayloadFromRow(type, row)) ?? const <String, Object?>{},
      createdAt: DateTime.now(),
    ));
  }

  /// 历史数据全量入队（首次登录后调用）。
  ///
  /// 需求：「历史数据首次登录后也应进入同步队列」。
  /// 幂等：同一实体键只会有**一条**未确认记录。
  Future<int> enqueueHistory() async {
    final List<OutboxEntry> entries = <OutboxEntry>[];
    final DateTime now = DateTime.now();

    final List<Map<String, Object?>> segments = await _db.raw.query(
      DbSchema.tableActivitySegments,
      where: 'owner_id = ?',
      whereArgs: <Object?>[_ownerId],
      orderBy: 'started_at DESC',
      limit: historyBackfillLimit,
    );
    for (final Map<String, Object?> row in segments) {
      final String id = row['id']! as String;
      entries.add(OutboxEntry(
        id: _uuid.v4(),
        entityType: SyncEntityType.activitySegment,
        entityKey: id,
        entityLocalId: id,
        payload: (await buildPayloadFromRow(SyncEntityType.activitySegment, row)) ??
            const <String, Object?>{},
        createdAt: now,
      ));
    }

    final List<Map<String, Object?>> daily = await _db.raw.query(
      DbSchema.tableDailyUsage,
      where: 'owner_id = ?',
      whereArgs: <Object?>[_ownerId],
      orderBy: 'day_key DESC',
      limit: historyBackfillLimit,
    );
    for (final Map<String, Object?> row in daily) {
      final String key = '${row['device_local_id']}:${row['day_key']}';
      entries.add(OutboxEntry(
        id: _uuid.v4(),
        entityType: SyncEntityType.dailyUsage,
        entityKey: key,
        entityLocalId: key,
        payload: (await buildPayloadFromRow(SyncEntityType.dailyUsage, row)) ??
            const <String, Object?>{},
        createdAt: now,
      ));
    }

    final List<Map<String, Object?>> apps = await _db.raw.query(
      DbSchema.tableApplications,
      orderBy: 'last_seen_at DESC',
      limit: historyBackfillLimit,
    );
    for (final Map<String, Object?> row in apps) {
      final String key = row['app_key']! as String;
      entries.add(OutboxEntry(
        id: _uuid.v4(),
        entityType: SyncEntityType.application,
        entityKey: key,
        entityLocalId: key,
        payload: (await buildPayloadFromRow(SyncEntityType.application, row)) ??
            const <String, Object?>{},
        createdAt: now,
      ));
    }

    if (entries.isEmpty) return 0;
    final int count = await _outbox.enqueueAll(entries);
    Loggers.sync.info('历史数据已排入同步队列：$count 条');
    return count;
  }

  // ---------------------------------------------------------------------------
  // 推送时构建 payload
  // ---------------------------------------------------------------------------

  /// 按 outbox 条目**重新读取本地当前数据**并生成上传体。
  ///
  /// 返回 null 表示本地记录已不存在（例如活动段被清理），此时引擎应直接确认该条，
  /// 不做无意义的重试。
  Future<Map<String, Object?>?> buildPayload(
    OutboxEntry entry, {
    required String serverDeviceId,
  }) async {
    final Map<String, Object?>? row = switch (entry.entityType) {
      SyncEntityType.activitySegment => await _segmentRow(entry.entityKey),
      SyncEntityType.dailyUsage => await _dailyRowByKey(entry.entityKey),
      SyncEntityType.application => await _applicationRow(entry.entityKey),
    };
    if (row == null) return null;
    final Map<String, Object?>? payload = await buildPayloadFromRow(entry.entityType, row);
    if (payload == null) return null;
    // device_id 由引擎注入（必须等于当前认证设备）。
    //
    // ⚠️ 只有活动段与每日用量需要它：服务端的 AppRecordIn 用 extra="forbid"
    // 校验，给应用记录多塞一个 device_id 会直接被 422 拒收。
    if (entry.entityType != SyncEntityType.application) {
      payload['device_id'] = serverDeviceId;
    }
    return payload;
  }

  /// 由本地行构建上传体（不含 device_id）。
  Future<Map<String, Object?>?> buildPayloadFromRow(
    SyncEntityType type,
    Map<String, Object?> row,
  ) async {
    switch (type) {
      case SyncEntityType.activitySegment:
        final String appKey = row['app_key']! as String;
        final int? endedAt = row['ended_at'] as int?;
        return <String, Object?>{
          'id': row['id'],
          'app_key': appKey,
          'category': await _categoryFor(appKey),
          'started_at': _iso(row['started_at'] as int?),
          'ended_at': _iso(endedAt),
          'active_seconds': (row['active_seconds'] as int?) ?? 0,
          'end_reason': row['end_reason'] as String?,
          'created_at': _iso(row['created_at'] as int?) ?? _iso(DateTime.now().millisecondsSinceEpoch),
          // 进行中的段用「现在」作为 updated_at：服务端按 Last-Write-Wins 覆盖，
          // 关闭后 ended_at 固定，后续重传自然变成幂等操作。
          'updated_at': _iso(endedAt) ?? _iso(DateTime.now().millisecondsSinceEpoch),
        };

      case SyncEntityType.dailyUsage:
        return <String, Object?>{
          'device_id': null, // 占位，由调用方覆盖
          'local_day': row['day_key'],
          // 时区偏移按**上传时**设备所在时区记录。
          // 已知限制：跨时区旅行后，历史日期的偏移会是上传时的值，
          // 但服务端只用它做展示，日期归属靠 local_day，因此不影响统计正确性。
          'timezone_offset_minutes': DateTime.now().timeZoneOffset.inMinutes,
          'session_seconds': (row['session_seconds'] as int?) ?? 0,
          'active_seconds': (row['active_seconds'] as int?) ?? 0,
          'idle_seconds': (row['idle_seconds'] as int?) ?? 0,
          'first_active_at': _iso(row['first_active_at'] as int?),
          'last_active_at': _iso(row['last_active_at'] as int?),
          'updated_at':
              _iso(row['updated_at'] as int?) ?? _iso(DateTime.now().millisecondsSinceEpoch),
        };

      case SyncEntityType.application:
        return <String, Object?>{
          'app_key': row['app_key'],
          // 只上传可公开的字段：排除标记 excluded 属于本机隐私偏好，不上传。
          'display_name': row['display_name'],
          'category': (row['category'] as String?) ?? 'other',
          'user_overridden': ((row['user_overridden'] as int?) ?? 0) != 0,
          'updated_at':
              _iso(row['last_seen_at'] as int?) ?? _iso(DateTime.now().millisecondsSinceEpoch),
        };
    }
  }

  // ---------------------------------------------------------------------------
  // 本地读取
  // ---------------------------------------------------------------------------

  Future<Map<String, Object?>?> _segmentRow(String segmentId) async {
    final List<Map<String, Object?>> rows = await _db.raw.query(
      DbSchema.tableActivitySegments,
      where: 'id = ? AND owner_id = ?',
      whereArgs: <Object?>[segmentId, _ownerId],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<Map<String, Object?>?> _dailyRow({
    required String deviceLocalId,
    required String dayKey,
  }) async {
    final List<Map<String, Object?>> rows = await _db.raw.query(
      DbSchema.tableDailyUsage,
      where: 'owner_id = ? AND device_local_id = ? AND day_key = ?',
      whereArgs: <Object?>[_ownerId, deviceLocalId, dayKey],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<Map<String, Object?>?> _dailyRowByKey(String entityKey) async {
    final int sep = entityKey.lastIndexOf(':');
    if (sep <= 0) return null;
    return _dailyRow(
      deviceLocalId: entityKey.substring(0, sep),
      dayKey: entityKey.substring(sep + 1),
    );
  }

  Future<Map<String, Object?>?> _applicationRow(String appKey) async {
    final List<Map<String, Object?>> rows = await _db.raw.query(
      DbSchema.tableApplications,
      where: 'app_key = ?',
      whereArgs: <Object?>[appKey],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// 活动段的分类取应用库里的值；应用库没有记录时归入 `other`。
  Future<String> _categoryFor(String appKey) async {
    final List<Map<String, Object?>> rows = await _db.raw.query(
      DbSchema.tableApplications,
      columns: <String>['category'],
      where: 'app_key = ?',
      whereArgs: <Object?>[appKey],
      limit: 1,
    );
    if (rows.isEmpty) return 'other';
    return (rows.first['category'] as String?) ?? 'other';
  }

  static String? _iso(int? millis) {
    if (millis == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true)
        .toUtc()
        .toIso8601String();
  }
}

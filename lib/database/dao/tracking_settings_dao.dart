import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../activity_tracking/models/tracking_settings.dart';
import '../schema.dart';

/// `tracking_settings` 数据访问（键值，按 owner + 设备隔离）。
class TrackingSettingsDao {
  TrackingSettingsDao(this._db);

  final Database _db;

  Future<Map<String, String>> loadAll(String ownerId, String deviceLocalId) async {
    final List<Map<String, Object?>> rows = await _db.query(
      DbSchema.tableTrackingSettings,
      where: 'owner_id = ? AND device_local_id = ?',
      whereArgs: <Object?>[ownerId, deviceLocalId],
    );
    return <String, String>{
      for (final Map<String, Object?> r in rows)
        r['key']! as String: (r['value'] as String?) ?? '',
    };
  }

  Future<void> save(
    String ownerId,
    String deviceLocalId,
    Map<String, String> keyValues,
  ) async {
    if (keyValues.isEmpty) return;
    final int now = DateTime.now().millisecondsSinceEpoch;
    final Batch batch = _db.batch();
    for (final MapEntry<String, String> e in keyValues.entries) {
      batch.insert(
        DbSchema.tableTrackingSettings,
        <String, Object?>{
          'owner_id': ownerId,
          'device_local_id': deviceLocalId,
          'key': e.key,
          'value': e.value,
          'updated_at': now,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  /// 读取采集设置；表为空时返回默认值。
  Future<TrackingSettings> load(String ownerId, String deviceLocalId) async {
    final Map<String, String> kv = await loadAll(ownerId, deviceLocalId);
    if (kv.isEmpty) return const TrackingSettings();
    return TrackingSettings.fromKeyValues(kv);
  }

  Future<void> saveSettings(
    String ownerId,
    String deviceLocalId,
    TrackingSettings settings,
  ) =>
      save(ownerId, deviceLocalId, settings.toKeyValues());
}

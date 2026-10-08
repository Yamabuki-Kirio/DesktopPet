import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../schema.dart';

/// `local_settings` 数据访问（按 owner 隔离的键值配置）。
class SettingsDao {
  SettingsDao(this._db);

  final Database _db;

  Future<String?> get(String ownerId, String key) async {
    final List<Map<String, Object?>> rows = await _db.query(
      DbSchema.tableSettings,
      columns: <String>['value'],
      where: 'owner_id = ? AND key = ?',
      whereArgs: <Object?>[ownerId, key],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  Future<Map<String, String>> getAll(String ownerId) async {
    final List<Map<String, Object?>> rows = await _db.query(
      DbSchema.tableSettings,
      where: 'owner_id = ?',
      whereArgs: <Object?>[ownerId],
    );
    final Map<String, String> out = <String, String>{};
    for (final Map<String, Object?> r in rows) {
      final String? v = r['value'] as String?;
      if (v != null) out[r['key']! as String] = v;
    }
    return out;
  }

  Future<void> set(String ownerId, String key, String? value, DateTime updatedAt) async {
    await _db.insert(
      DbSchema.tableSettings,
      <String, Object?>{
        'owner_id': ownerId,
        'key': key,
        'value': value,
        'updated_at': updatedAt.millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 批量写入（事务内），用于退出时一次性落盘。
  Future<void> setAll(String ownerId, Map<String, String?> values, DateTime updatedAt) async {
    if (values.isEmpty) return;
    await _db.transaction((Transaction txn) async {
      final Batch batch = txn.batch();
      values.forEach((String key, String? value) {
        batch.insert(
          DbSchema.tableSettings,
          <String, Object?>{
            'owner_id': ownerId,
            'key': key,
            'value': value,
            'updated_at': updatedAt.millisecondsSinceEpoch,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      });
      await batch.commit(noResult: true);
    });
  }

  Future<void> delete(String ownerId, String key) async {
    await _db.delete(
      DbSchema.tableSettings,
      where: 'owner_id = ? AND key = ?',
      whereArgs: <Object?>[ownerId, key],
    );
  }
}

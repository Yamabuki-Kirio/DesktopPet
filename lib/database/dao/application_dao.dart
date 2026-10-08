import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../activity_tracking/models/activity_enums.dart';
import '../../activity_tracking/models/activity_sample.dart';
import '../schema.dart';

/// `applications` 数据访问。
class ApplicationDao {
  ApplicationDao(this._db);

  final Database _db;

  Future<TrackedApplication?> find(String appKey) async {
    final List<Map<String, Object?>> rows = await _db.query(
      DbSchema.tableApplications,
      where: 'app_key = ?',
      whereArgs: <Object?>[appKey],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return TrackedApplication.fromMap(rows.first);
  }

  Future<List<TrackedApplication>> listAll() async {
    final List<Map<String, Object?>> rows = await _db.query(
      DbSchema.tableApplications,
      orderBy: 'last_seen_at DESC',
    );
    return rows.map(TrackedApplication.fromMap).toList(growable: false);
  }

  Future<void> upsert(TrackedApplication app) async {
    await _db.insert(
      DbSchema.tableApplications,
      app.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 仅更新「最近出现时间」，不动分类与用户设置。
  Future<void> touchLastSeen(String appKey, DateTime at) async {
    await _db.update(
      DbSchema.tableApplications,
      <String, Object?>{'last_seen_at': at.millisecondsSinceEpoch},
      where: 'app_key = ?',
      whereArgs: <Object?>[appKey],
    );
  }

  /// 更新用户手工设定：显示名 / 分类 / 排除。
  ///
  /// `user_overridden` 只有在用户显式改分类时才置 1，
  /// 这样内置规则永远不会覆盖人工选择（需求「七、应用分类」）。
  Future<void> updateUserSettings(
    String appKey, {
    String? displayName,
    AppCategory? category,
    bool? excluded,
  }) async {
    final Map<String, Object?> values = <String, Object?>{};
    if (displayName != null) values['display_name'] = displayName;
    if (category != null) {
      values['category'] = category.wireName;
      values['user_overridden'] = 1;
    }
    if (excluded != null) values['excluded'] = excluded ? 1 : 0;
    if (values.isEmpty) return;
    await _db.update(
      DbSchema.tableApplications,
      values,
      where: 'app_key = ?',
      whereArgs: <Object?>[appKey],
    );
  }

  /// 被排除的应用键集合（采样时的快速判断，避免每次采样都查库）。
  Future<Set<String>> excludedKeys() async {
    final List<Map<String, Object?>> rows = await _db.query(
      DbSchema.tableApplications,
      columns: <String>['app_key'],
      where: 'excluded = 1',
    );
    return rows.map((Map<String, Object?> r) => r['app_key']! as String).toSet();
  }

  Future<int> count() async {
    final List<Map<String, Object?>> rows =
        await _db.rawQuery('SELECT COUNT(*) AS c FROM ${DbSchema.tableApplications}');
    return (rows.first['c'] as int?) ?? 0;
  }
}

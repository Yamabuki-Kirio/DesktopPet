import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:petlife/core/constants.dart';
import 'package:petlife/database/app_database.dart';
import 'package:petlife/database/schema.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/sqlite_test_bootstrap.dart';

/// 真实数据库迁移测试（验收第 22 项）。
///
/// 做法是**真的建一个 v1 老库、真的写入阶段 0 数据、真的用 v2 打开它**，
/// 而不是断言迁移语句的字符串内容。只有这样才能真正发现
/// 「升级把用户素材和设置弄丢」这类事故。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SqliteTestBootstrap.ensureLoaded();

  late Directory tmp;
  late String dbPath;

  const String owner = AppConstants.localOwnerId;
  const int packCreatedAt = 1767225600000; // 2026-01-01T00:00:00Z

  setUpAll(() {
    tmp = Directory.systemTemp.createTempSync('petlife_migration_test');
  });

  tearDownAll(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  setUp(() async {
    await AppDatabase.close();
    dbPath = p.join(tmp.path, 'legacy_${DateTime.now().microsecondsSinceEpoch}.db');
    await _createV1Database(dbPath);
  });

  tearDown(() async {
    await AppDatabase.close();
  });

  test('v1 老库升级到当前版本后：阶段 0 数据完整保留，后续表已建立', () async {
    // --- 升级前：确认这是一个真正的 v1 库 ---
    final Database before = await databaseFactory.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(readOnly: true),
    );
    expect(await _userVersion(before), 1);
    expect(
      await _tableNames(before),
      isNot(contains(DbSchema.tableApplications)),
      reason: 'v1 库里不应该有 applications 表',
    );
    await before.close();

    // --- 用当前版本打开，触发 onUpgrade ---
    final AppDatabase upgraded = await AppDatabase.open(path: dbPath);
    final Database db = upgraded.raw;

    expect(await _userVersion(db), AppConstants.databaseSchemaVersion,
        reason: 'user_version 必须提升到当前 schema 版本');

    final Set<String> tables = await _tableNames(db);
    for (final String table in <String>[
      DbSchema.tableApplications,
      DbSchema.tableActivityCheckpoints,
      DbSchema.tableDailyUsage,
      DbSchema.tableTrackingSettings,
      DbSchema.tableActivitySegments,
    ]) {
      expect(tables, contains(table), reason: '缺少表 $table');
    }

    // --- 阶段 0 数据必须一条不少 ---
    final List<Map<String, Object?>> packs =
        await db.query(DbSchema.tablePacks, where: 'owner_id = ?', whereArgs: <Object?>[owner]);
    expect(packs, hasLength(1));
    expect(packs.first['name'], 'Ace Attorney');

    final List<Map<String, Object?>> characters = await db.query(DbSchema.tableCharacters);
    expect(characters, hasLength(1));
    expect(characters.first['internal_name'], 'Maya');
    final String characterId = characters.first['id']! as String;

    final List<Map<String, Object?>> assets = await db.query(
      DbSchema.tableAssets,
      where: 'character_id = ?',
      whereArgs: <Object?>[characterId],
    );
    expect(assets, hasLength(2), reason: '两个素材在升级后都必须还在');
    expect(
      assets.map((Map<String, Object?> a) => a['emotion_name']).toSet(),
      <String>{'Cheerful', 'Angry'},
    );
    // 关键字段不得被迁移改写。
    final Map<String, Object?> cheerful =
        assets.firstWhere((Map<String, Object?> a) => a['emotion_name'] == 'Cheerful');
    expect(cheerful['file_path'], r'C:\PetLife\assets\cheerful.webp');
    expect(cheerful['original_file_path'], r'D:\Ace Attorney\Maya_Cheerful_1.webp');
    expect(cheerful['frame_count'], 9);
    expect(cheerful['is_animated'], 1);
    expect(cheerful['animation_duration_ms'], 5000);

    final List<Map<String, Object?>> mappings =
        await db.query(DbSchema.tableStateMappings, where: 'character_id = ?', whereArgs: <Object?>[characterId]);
    expect(mappings, hasLength(1));
    expect(mappings.first['system_state'], 'happy');

    final List<Map<String, Object?>> settings =
        await db.query(DbSchema.tableSettings, where: 'owner_id = ?', whereArgs: <Object?>[owner]);
    expect(
      settings.map((Map<String, Object?> s) => s['key']),
      containsAll(<String>['window.scale', 'window.opacity', 'state.lastState']),
    );
    expect(
      settings.firstWhere((Map<String, Object?> s) => s['key'] == 'window.scale')['value'],
      '2.0',
    );
  });

  test('升级后的库可以正常写入新表（阶段 1 功能真的可用）', () async {
    final AppDatabase upgraded = await AppDatabase.open(path: dbPath);
    final Database db = upgraded.raw;

    await db.insert(DbSchema.tableApplications, <String, Object?>{
      'app_key': 'code',
      'display_name': 'Code',
      'process_name': 'Code.exe',
      'executable_path': r'C:\Apps\Code.exe',
      'category': 'development',
      'user_overridden': 0,
      'excluded': 0,
      'first_seen_at': packCreatedAt,
      'last_seen_at': packCreatedAt,
    });
    await db.insert(DbSchema.tableDailyUsage, <String, Object?>{
      'owner_id': owner,
      'device_local_id': AppConstants.localDeviceId,
      'day_key': '2026-01-01',
      'session_seconds': 100,
      'active_seconds': 80,
      'idle_seconds': 20,
      'updated_at': packCreatedAt,
    });

    expect(await db.query(DbSchema.tableApplications), hasLength(1));
    expect(await db.query(DbSchema.tableDailyUsage), hasLength(1));
  });

  test('重复打开已升级的库不会重复执行迁移（幂等）', () async {
    await AppDatabase.open(path: dbPath);
    await AppDatabase.close();

    final AppDatabase again = await AppDatabase.open(path: dbPath);
    expect(await _userVersion(again.raw), AppConstants.databaseSchemaVersion);
    // 迁移语句全部带 IF NOT EXISTS / IF NOT EXISTS 索引，重复执行不应报错。
    expect(await again.raw.query(DbSchema.tablePacks), hasLength(1));
  });

  test('新库直接按当前版本全量建表，与升级路径结果一致', () async {
    final String freshPath =
        p.join(tmp.path, 'fresh_${DateTime.now().microsecondsSinceEpoch}.db');
    await AppDatabase.close();
    final AppDatabase fresh = await AppDatabase.open(path: freshPath);

    expect(await _userVersion(fresh.raw), AppConstants.databaseSchemaVersion);
    final Set<String> tables = await _tableNames(fresh.raw);
    for (final String table in <String>[
      DbSchema.tablePacks,
      DbSchema.tableCharacters,
      DbSchema.tableAssets,
      DbSchema.tableStateMappings,
      DbSchema.tableSettings,
      DbSchema.tableActivitySegments,
      DbSchema.tableApplications,
      DbSchema.tableActivityCheckpoints,
      DbSchema.tableDailyUsage,
      DbSchema.tableTrackingSettings,
    ]) {
      expect(tables, contains(table), reason: '新库缺少表 $table');
    }
  });
}

/// 手工创建一个 v1 版本的老库，并写入典型的阶段 0 数据。
Future<void> _createV1Database(String path) async {
  final Database db = await databaseFactory.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: 1,
      onCreate: (Database db, int version) async {
        for (final String stmt in DbSchema.v1Statements) {
          await db.execute(stmt);
        }
      },
    ),
  );

  const String packId = 'pack-1';
  const String characterId = 'char-1';

  await db.insert(DbSchema.tablePacks, <String, Object?>{
    'id': packId,
    'owner_id': AppConstants.localOwnerId,
    'name': 'Ace Attorney',
    'source_type': 'folder',
    'source_path': r'D:\Ace Attorney',
    'created_at': 1767225600000,
    'updated_at': 1767225600000,
  });
  await db.insert(DbSchema.tableCharacters, <String, Object?>{
    'id': characterId,
    'pack_id': packId,
    'owner_id': AppConstants.localOwnerId,
    'internal_name': 'Maya',
    'display_name': 'Maya',
    'default_asset_id': 'asset-1',
    'enabled': 1,
    'created_at': 1767225600000,
    'updated_at': 1767225600000,
  });
  await db.insert(DbSchema.tableAssets, <String, Object?>{
    'id': 'asset-1',
    'character_id': characterId,
    'emotion_name': 'Cheerful',
    'variant_name': '1',
    'file_path': r'C:\PetLife\assets\cheerful.webp',
    'original_file_path': r'D:\Ace Attorney\Maya_Cheerful_1.webp',
    'file_hash': 'hash-1',
    'mime_type': 'image/webp',
    'file_size': 4321,
    'width': 256,
    'height': 192,
    'frame_count': 9,
    'is_animated': 1,
    'has_alpha': 1,
    'enabled': 1,
    'validation_status': 'valid',
    'animation_duration_ms': 5000,
    'created_at': 1767225600000,
  });
  await db.insert(DbSchema.tableAssets, <String, Object?>{
    'id': 'asset-2',
    'character_id': characterId,
    'emotion_name': 'Angry',
    'variant_name': '1',
    'file_path': r'C:\PetLife\assets\angry.webp',
    'file_hash': 'hash-2',
    'mime_type': 'image/webp',
    'file_size': 4000,
    'width': 256,
    'height': 192,
    'frame_count': 9,
    'is_animated': 1,
    'has_alpha': 1,
    'enabled': 1,
    'validation_status': 'valid',
    'animation_duration_ms': 5000,
    'created_at': 1767225600000,
  });
  await db.insert(DbSchema.tableStateMappings, <String, Object?>{
    'id': 'mapping-1',
    'character_id': characterId,
    'system_state': 'happy',
    'asset_id': 'asset-1',
    'weight': 1,
    'priority': 70,
    'created_at': 1767225600000,
    'updated_at': 1767225600000,
  });
  for (final MapEntry<String, String> e in <String, String>{
    'window.scale': '2.0',
    'window.opacity': '1.0',
    'state.lastState': 'default',
  }.entries) {
    await db.insert(DbSchema.tableSettings, <String, Object?>{
      'owner_id': AppConstants.localOwnerId,
      'key': e.key,
      'value': e.value,
      'updated_at': 1767225600000,
    });
  }

  await db.close();
}

Future<int> _userVersion(Database db) async {
  final List<Map<String, Object?>> rows = await db.rawQuery('PRAGMA user_version');
  return rows.first.values.first! as int;
}

Future<Set<String>> _tableNames(Database db) async {
  final List<Map<String, Object?>> rows = await db.rawQuery(
    "SELECT name FROM sqlite_master WHERE type = 'table'",
  );
  return rows.map((Map<String, Object?> r) => r['name']! as String).toSet();
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:petlife/core/constants.dart';
import 'package:petlife/database/app_database.dart';
import 'package:petlife/database/schema.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/sqlite_test_bootstrap.dart';

/// SQLite v2 → v3 迁移（Phase 2）。
///
/// 做法与阶段 1 的迁移测试一致：**真的建一个 v2 老库、真的写入数据、
/// 真的用 v3 打开**，然后逐字段断言旧数据没被动过。
/// 只断言迁移语句字符串是发现不了"升级把用户数据弄丢"的。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SqliteTestBootstrap.ensureLoaded();

  const String owner = AppConstants.localOwnerId;
  const String device = AppConstants.localDeviceId;
  const int t0 = 1767225600000; // 2026-01-01T00:00:00Z

  late Directory tmp;

  setUpAll(() {
    tmp = Directory.systemTemp.createTempSync('petlife_sync_v3_test');
  });

  tearDownAll(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  setUp(() async {
    await AppDatabase.close();
  });

  tearDown(() async {
    await AppDatabase.close();
  });

  /// 建一个 v2 老库并写入阶段 0 / 阶段 1 的典型数据。
  Future<String> createV2Database() async {
    final String path = p.join(tmp.path, 'v2_${DateTime.now().microsecondsSinceEpoch}.db');
    final Database db = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 2,
        onCreate: (Database db, int version) async {
          for (final String stmt in <String>[
            ...DbSchema.v1Statements,
            ...DbSchema.v2Statements,
          ]) {
            await db.execute(stmt);
          }
        },
      ),
    );

    await db.insert(DbSchema.tablePacks, <String, Object?>{
      'id': 'pack-1',
      'owner_id': owner,
      'name': 'Ace Attorney',
      'source_type': 'folder',
      'source_path': r'D:\Ace Attorney',
      'created_at': t0,
      'updated_at': t0,
    });
    await db.insert(DbSchema.tableCharacters, <String, Object?>{
      'id': 'char-1',
      'pack_id': 'pack-1',
      'owner_id': owner,
      'internal_name': 'Maya',
      'display_name': 'Maya',
      'default_asset_id': 'asset-1',
      'enabled': 1,
      'created_at': t0,
      'updated_at': t0,
    });
    await db.insert(DbSchema.tableAssets, <String, Object?>{
      'id': 'asset-1',
      'character_id': 'char-1',
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
      'created_at': t0,
    });
    await db.insert(DbSchema.tableStateMappings, <String, Object?>{
      'id': 'mapping-1',
      'character_id': 'char-1',
      'system_state': 'happy',
      'asset_id': 'asset-1',
      'weight': 1,
      'priority': 70,
      'created_at': t0,
      'updated_at': t0,
    });
    for (final MapEntry<String, String> e in <String, String>{
      'window.scale': '2.0',
      'window.opacity': '1.0',
      'state.lastState': 'default',
      'sync.deviceLocalId': 'legacy-device-local-id',
    }.entries) {
      await db.insert(DbSchema.tableSettings, <String, Object?>{
        'owner_id': owner,
        'key': e.key,
        'value': e.value,
        'updated_at': t0,
      });
    }
    await db.insert(DbSchema.tableApplications, <String, Object?>{
      'app_key': 'code',
      'display_name': 'Visual Studio Code',
      'process_name': 'Code.exe',
      'executable_path': r'C:\Apps\Code.exe',
      'category': 'development',
      'user_overridden': 1,
      'excluded': 0,
      'first_seen_at': t0,
      'last_seen_at': t0,
    });
    await db.insert(DbSchema.tableActivitySegments, <String, Object?>{
      'id': 'segment-1',
      'owner_id': owner,
      'device_local_id': device,
      'app_key': 'code',
      'app_name': 'Visual Studio Code',
      'process_name': 'Code.exe',
      'started_at': t0,
      'ended_at': t0 + 60000,
      'active_seconds': 60,
      'end_reason': 'foreground_changed',
      'sync_status': 'pending',
      'created_at': t0,
    });
    await db.insert(DbSchema.tableDailyUsage, <String, Object?>{
      'owner_id': owner,
      'device_local_id': device,
      'day_key': '2026-01-01',
      'session_seconds': 3600,
      'active_seconds': 3000,
      'idle_seconds': 600,
      'updated_at': t0,
    });

    await db.close();
    return path;
  }

  Future<int> userVersion(Database db) async {
    final List<Map<String, Object?>> rows = await db.rawQuery('PRAGMA user_version');
    return rows.first.values.first! as int;
  }

  Future<Set<String>> tableNames(Database db) async {
    final List<Map<String, Object?>> rows = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table'",
    );
    return rows.map((Map<String, Object?> r) => r['name']! as String).toSet();
  }

  test('v2 老库升级到 v3：旧数据逐字段保留，新表已建立', () async {
    final String path = await createV2Database();

    // 升级前：确认真的还是 v2
    final Database before = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(readOnly: true),
    );
    expect(await userVersion(before), 2);
    expect(await tableNames(before), isNot(contains(DbSchema.tableSyncOutbox)));
    await before.close();

    // 用当前版本（v3）打开 → 触发 onUpgrade
    final AppDatabase upgraded = await AppDatabase.open(path: path);
    final Database db = upgraded.raw;

    expect(await userVersion(db), AppConstants.databaseSchemaVersion,
        reason: 'user_version 必须提升到当前 schema 版本');

    final Set<String> tables = await tableNames(db);
    for (final String table in <String>[
      DbSchema.tableAccountSession,
      DbSchema.tableSyncState,
      DbSchema.tableSyncOutbox,
    ]) {
      expect(tables, contains(table), reason: '缺少 v3 表 $table');
    }

    // --- 阶段 0 数据 ---
    final List<Map<String, Object?>> packs = await db.query(DbSchema.tablePacks);
    expect(packs, hasLength(1));
    expect(packs.first['name'], 'Ace Attorney');

    final List<Map<String, Object?>> characters = await db.query(DbSchema.tableCharacters);
    expect(characters, hasLength(1));
    expect(characters.first['internal_name'], 'Maya');

    final List<Map<String, Object?>> assets = await db.query(DbSchema.tableAssets);
    expect(assets, hasLength(1));
    expect(assets.first['file_path'], r'C:\PetLife\assets\cheerful.webp');
    expect(assets.first['original_file_path'], r'D:\Ace Attorney\Maya_Cheerful_1.webp');
    expect(assets.first['frame_count'], 9);
    expect(assets.first['animation_duration_ms'], 5000);

    final List<Map<String, Object?>> mappings = await db.query(DbSchema.tableStateMappings);
    expect(mappings, hasLength(1));
    expect(mappings.first['system_state'], 'happy');

    final List<Map<String, Object?>> settings = await db.query(
      DbSchema.tableSettings,
      where: 'owner_id = ?',
      whereArgs: <Object?>[owner],
    );
    final Map<String, String> settingMap = <String, String>{
      for (final Map<String, Object?> r in settings)
        r['key']! as String: (r['value'] as String?) ?? '',
    };
    expect(settingMap['window.scale'], '2.0');
    expect(settingMap['window.opacity'], '1.0');
    expect(settingMap['state.lastState'], 'default');
    // v3 迁移不得改动已有设置（含阶段 1 写过的 device_local_id）
    expect(settingMap['sync.deviceLocalId'], 'legacy-device-local-id');

    // --- 阶段 1 数据 ---
    final List<Map<String, Object?>> apps = await db.query(DbSchema.tableApplications);
    expect(apps, hasLength(1));
    expect(apps.first['app_key'], 'code');
    expect(apps.first['user_overridden'], 1);
    expect(apps.first['executable_path'], r'C:\Apps\Code.exe');

    final List<Map<String, Object?>> segments =
        await db.query(DbSchema.tableActivitySegments);
    expect(segments, hasLength(1));
    expect(segments.first['id'], 'segment-1');
    expect(segments.first['active_seconds'], 60);
    expect(segments.first['end_reason'], 'foreground_changed');

    final List<Map<String, Object?>> daily = await db.query(DbSchema.tableDailyUsage);
    expect(daily, hasLength(1));
    expect(daily.first['day_key'], '2026-01-01');
    expect(daily.first['active_seconds'], 3000);
  });

  test('v3 新表可以正常读写', () async {
    final String path = await createV2Database();
    final AppDatabase upgraded = await AppDatabase.open(path: path);
    final Database db = upgraded.raw;

    await db.insert(DbSchema.tableAccountSession, <String, Object?>{
      'id': 1,
      'server_base_url': 'http://127.0.0.1:8000',
      'user_id': 'user-uuid',
      'email': 'a@example.com',
      'display_name': 'A',
      'device_server_id': 'device-uuid',
      'credential_reference': 'PetLife:account',
      'access_token_expires_at': t0,
      'updated_at': t0,
    });
    await db.insert(DbSchema.tableSyncState, <String, Object?>{
      'entity_type': 'activity_segment',
      'cursor': 42,
      'consecutive_failures': 0,
      'updated_at': t0,
    });
    await db.insert(DbSchema.tableSyncOutbox, <String, Object?>{
      'id': 'outbox-1',
      'entity_type': 'activity_segment',
      'entity_key': 'segment-1',
      'entity_local_id': 'segment-1',
      'operation': 'upsert',
      'payload_json': '{}',
      'created_at': t0,
      'attempt_count': 0,
      'next_attempt_at': t0,
    });

    expect(await db.query(DbSchema.tableAccountSession), hasLength(1));
    expect((await db.query(DbSchema.tableSyncState)).first['cursor'], 42);
    expect(await db.query(DbSchema.tableSyncOutbox), hasLength(1));
  });

  test('account_session 里没有任何令牌或密码列', () async {
    final String path = await createV2Database();
    final AppDatabase upgraded = await AppDatabase.open(path: path);
    final List<Map<String, Object?>> columns =
        await upgraded.raw.rawQuery('PRAGMA table_info(${DbSchema.tableAccountSession})');

    final Set<String> names =
        columns.map((Map<String, Object?> c) => (c['name']! as String).toLowerCase()).toSet();
    expect(names, contains('credential_reference'));
    for (final String banned in <String>[
      'access_token',
      'refresh_token',
      'token',
      'password',
      'password_hash',
      'secret',
    ]) {
      expect(names, isNot(contains(banned)),
          reason: '本地库不得出现 $banned 列（令牌只能放凭据存储）');
    }
  });

  test('重复打开已升级的库不会重复迁移（幂等）', () async {
    final String path = await createV2Database();
    await AppDatabase.open(path: path);
    await AppDatabase.close();

    final AppDatabase again = await AppDatabase.open(path: path);
    expect(await userVersion(again.raw), AppConstants.databaseSchemaVersion);
    expect(await again.raw.query(DbSchema.tablePacks), hasLength(1));
    expect(await again.raw.query(DbSchema.tableSyncOutbox), isEmpty);
  });

  test('新库直接按当前版本全量建表，包含全部 14 张表', () async {
    final String freshPath =
        p.join(tmp.path, 'fresh_${DateTime.now().microsecondsSinceEpoch}.db');
    final AppDatabase fresh = await AppDatabase.open(path: freshPath);

    expect(await userVersion(fresh.raw), AppConstants.databaseSchemaVersion);
    final Set<String> tables = await tableNames(fresh.raw);
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
      DbSchema.tableAccountSession,
      DbSchema.tableSyncState,
      DbSchema.tableSyncOutbox,
      // v4（Phase 4B）：云端统计缓存
      DbSchema.tableCloudCache,
    ]) {
      expect(tables, contains(table), reason: '新库缺少表 $table');
    }
  });

  test('待同步队列的部分唯一索引真的阻止重复入队', () async {
    final String freshPath =
        p.join(tmp.path, 'uq_${DateTime.now().microsecondsSinceEpoch}.db');
    final AppDatabase fresh = await AppDatabase.open(path: freshPath);
    final Database db = fresh.raw;

    Future<void> insert(String id, String payload) => db.insert(
          DbSchema.tableSyncOutbox,
          <String, Object?>{
            'id': id,
            'entity_type': 'activity_segment',
            'entity_key': 'same-key',
            'operation': 'upsert',
            'payload_json': payload,
            'created_at': t0,
            'attempt_count': 0,
            'next_attempt_at': t0,
          },
        );

    await insert('a', '{"v":1}');
    // 同一 (entity_type, entity_key) 未确认记录只能有一条
    await expectLater(insert('b', '{"v":2}'), throwsA(isA<DatabaseException>()));

    // 确认掉之后可以再入队
    await db.update(
      DbSchema.tableSyncOutbox,
      <String, Object?>{'acknowledged_at': t0},
      where: 'id = ?',
      whereArgs: <Object?>['a'],
    );
    await insert('b', '{"v":2}');
    expect(await db.query(DbSchema.tableSyncOutbox), hasLength(2));
  });
}

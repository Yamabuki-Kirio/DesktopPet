import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:petlife/core/constants.dart';
import 'package:petlife/core/logger.dart';
import 'package:petlife/core/paths.dart';
import 'package:petlife/database/app_database.dart';
import 'package:petlife/database/dao/cloud_statistics_cache_dao.dart';
import 'package:petlife/database/schema.dart';
import 'package:petlife/sync/cloud_statistics_cache.dart';
import 'package:petlife/sync/models/cloud_statistics_models.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/sqlite_test_bootstrap.dart';

/// Phase 4B：云端统计缓存与 v3 → v4 迁移。
///
/// 这组测试的重点是**数据边界**：
/// * 云端缓存只在 `cloud_statistics_cache` 里；
/// * 账户之间严格隔离；
/// * 退出账户只清缓存，不碰本机采集 / 素材 / outbox；
/// * 缓存永远不进入 outbox；
/// * v3 老库升级到 v4 后，素材 / 角色 / 本机统计 / 账户 / outbox 一条都不能少。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SqliteTestBootstrap.ensureLoaded();

  late Directory dir;
  late AppDatabase db;
  late CloudStatisticsCache cache;
  late CloudStatisticsCacheDao dao;

  CloudUsageQuery queryFor(String account, {String? deviceId, DateTime? date}) =>
      CloudUsageQuery(
        date: date ?? DateTime(2026, 9, 29),
        deviceId: deviceId,
        timezone: 'Asia/Shanghai',
        timezoneOffsetMinutes: 480,
      );

  CloudUsageSummary sampleSummary() => CloudUsageSummary.fromJson(<String, Object?>{
        'date': '2026-09-29',
        'timezone': 'Asia/Shanghai',
        'device_id': 'dev-1',
        'total_duration_seconds': 5100,
        'session_count': 3,
        'last_synced_at': '2026-09-29T09:20:00Z',
        'apps': <Map<String, Object?>>[
          <String, Object?>{
            'app_id': 'msedge',
            'app_name': 'Microsoft Edge',
            'duration_seconds': 5100,
            'session_count': 3,
          },
        ],
      });

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('petlife_cloud_cache');
    AppPaths.resetForTest();
    await AppPaths.initialize(overrideRoot: dir);
    await AppLog.initialize(logFile: AppPaths.instance.logFile);
    db = await AppDatabase.open(path: AppPaths.instance.databaseFile.path);
    dao = CloudStatisticsCacheDao(db.raw);
    cache = CloudStatisticsCache(dao);
  });

  tearDown(() async {
    if (AppDatabase.isOpen) await AppDatabase.close();
    await AppLog.dispose();
    AppPaths.resetForTest();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Future<int> rowCount(String table) async {
    final List<Map<String, Object?>> rows =
        await db.raw.rawQuery('SELECT COUNT(*) AS c FROM $table');
    return (rows.first['c'] as int?) ?? 0;
  }

  group('云端统计缓存', () {
    test('缓存键包含 服务端地址 + 设备 + 日期 + 视图类型（跨服务器/跨设备互不串用）', () {
      final String base = CloudStatisticsCache.buildKey(
        type: CloudCacheType.summary,
        serverBaseUrl: 'http://a.example:8000',
        deviceKey: 'dev-1',
        dayKey: '2026-09-29',
        timezone: 'Asia/Shanghai',
      );
      expect(base, contains('http://a.example:8000'));
      expect(base, contains('dev-1'));
      expect(base, contains('2026-09-29'));
      expect(base, contains('summary'));

      // 换服务器 → 必须是不同的键（否则会读到旧服务器的统计）。
      expect(
        base,
        isNot(CloudStatisticsCache.buildKey(
          type: CloudCacheType.summary,
          serverBaseUrl: 'http://b.example:8000',
          deviceKey: 'dev-1',
          dayKey: '2026-09-29',
          timezone: 'Asia/Shanghai',
        )),
      );
      // 换设备 / 换日期 / 换视图类型 → 同样是不同的键。
      expect(
        base,
        isNot(CloudStatisticsCache.buildKey(
          type: CloudCacheType.summary,
          serverBaseUrl: 'http://a.example:8000',
          deviceKey: 'dev-2',
          dayKey: '2026-09-29',
          timezone: 'Asia/Shanghai',
        )),
      );
      expect(
        base,
        isNot(CloudStatisticsCache.buildKey(
          type: CloudCacheType.summary,
          serverBaseUrl: 'http://a.example:8000',
          deviceKey: 'dev-1',
          dayKey: '2026-09-28',
          timezone: 'Asia/Shanghai',
        )),
      );
      expect(
        base,
        isNot(CloudStatisticsCache.buildKey(
          type: CloudCacheType.timeline,
          serverBaseUrl: 'http://a.example:8000',
          deviceKey: 'dev-1',
          dayKey: '2026-09-29',
          timezone: 'Asia/Shanghai',
        )),
      );
    });

    test('切换服务端地址后读不到旧服务器的缓存', () async {
      final CloudUsageQuery query = queryFor('user-a', deviceId: 'dev-1');
      await cache.saveSummary(
        accountUserId: 'user-a',
        query: query,
        summary: sampleSummary(),
      );
      expect(await cache.readSummary('user-a', query), isNotNull);

      // 同一个 account + 同一个查询，但服务端地址变了 → 必须是未命中。
      final CloudStatisticsCache other = CloudStatisticsCache(
        dao,
        serverBaseUrl: () => 'http://other.example:8000',
      );
      expect(await other.readSummary('user-a', query), isNull);
    });

    test('设备列表往返：写入后能读回，且不依赖服务端字段名', () async {
      await cache.saveDevices(
        accountUserId: 'user-a',
        devices: <CloudDevice>[
          CloudDevice.fromJson(<String, Object?>{
            'id': 'dev-1',
            'device_name': '我的电脑',
            'platform': 'windows',
            'model_name': 'XPS 15',
            'last_seen_at': '2026-09-29T09:20:00Z',
            'is_current': true,
          }),
          const CloudDevice(id: 'dev-2', name: '我的手机', platform: 'android'),
        ],
        fetchedAt: DateTime.utc(2026, 9, 29, 9, 30),
      );

      final List<CloudDevice>? devices = await cache.readDevices('user-a');
      expect(devices, isNotNull);
      expect(devices!.map((CloudDevice d) => d.displayLabel).toList(),
          <String>['我的电脑 · Windows', '我的手机 · Android']);
      expect(devices.first.isCurrent, isTrue);
      expect(devices.first.modelName, 'XPS 15');
    });

    test('汇总 / 应用排行 / 时间线 / 会话页都能往返', () async {
      final CloudUsageQuery query = queryFor('user-a', deviceId: 'dev-1');

      await cache.saveSummary(
        accountUserId: 'user-a',
        query: query,
        summary: sampleSummary(),
        fetchedAt: DateTime.utc(2026, 9, 29, 9, 30),
      );
      final CloudUsageSummary? summary = await cache.readSummary('user-a', query);
      expect(summary!.totalDuration, const Duration(seconds: 5100));
      expect(summary.apps.single.appName, 'Microsoft Edge');
      expect(summary.lastSyncedAt, DateTime.utc(2026, 9, 29, 9, 20));

      await cache.saveApps(
        accountUserId: 'user-a',
        query: query,
        apps: <CloudAppUsage>[
          const CloudAppUsage(
            appId: 'code',
            appName: 'Visual Studio Code',
            duration: Duration(minutes: 52),
            sessionCount: 2,
          ),
        ],
      );
      final List<CloudAppUsage>? apps = await cache.readApps('user-a', query);
      expect(apps!.single.duration, const Duration(minutes: 52));

      await cache.saveTimeline(
        accountUserId: 'user-a',
        query: query,
        entries: <CloudTimelineEntry>[
          CloudTimelineEntry.fromJson(<String, Object?>{
            'app_id': 'msedge',
            'app_name': 'Microsoft Edge',
            'device_id': 'dev-1',
            'device_name': '我的电脑',
            'platform': 'windows',
            'started_at': '2026-09-29T01:12:00Z',
            'ended_at': '2026-09-29T01:35:00Z',
            'duration_seconds': 1380,
            'merged_session_count': 2,
          }),
        ],
      );
      final List<CloudTimelineEntry>? timeline = await cache.readTimeline('user-a', query);
      expect(timeline!.single.mergedSessionCount, 2);
      expect(timeline.single.duration, const Duration(minutes: 23));

      await cache.saveSessions(
        accountUserId: 'user-a',
        query: query,
        page: CloudSessionPage.fromJson(<String, Object?>{
          'date': '2026-09-29',
          'timezone': 'Asia/Shanghai',
          'next_cursor': 'cursor-2',
          'items': <Map<String, Object?>>[
            <String, Object?>{
              'id': 's1',
              'device_id': 'dev-1',
              'device_name': '我的电脑',
              'platform': 'windows',
              'app_id': 'code',
              'app_name': 'Visual Studio Code',
              'started_at': '2026-09-29T01:48:00Z',
              'ended_at': '2026-09-29T02:20:00Z',
              'duration_seconds': 1920,
            },
          ],
        }),
      );
      final CloudSessionPage? page = await cache.readSessions('user-a', query);
      expect(page!.items.single.duration, const Duration(minutes: 32));
      expect(page.nextCursor, 'cursor-2');
    });

    test('相同查询重复写入是覆盖，不产生重复行', () async {
      final CloudUsageQuery query = queryFor('user-a', deviceId: 'dev-1');
      await cache.saveSummary(
        accountUserId: 'user-a',
        query: query,
        summary: sampleSummary(),
      );
      await cache.saveSummary(
        accountUserId: 'user-a',
        query: query,
        summary: sampleSummary(),
      );
      expect(await rowCount(DbSchema.tableCloudCache), 1);
      expect(await cache.countForAccount('user-a'), 1);
    });

    test('不同日期 / 不同设备是不同缓存条目', () async {
      await cache.saveSummary(
        accountUserId: 'user-a',
        query: queryFor('user-a', deviceId: 'dev-1'),
        summary: sampleSummary(),
      );
      await cache.saveSummary(
        accountUserId: 'user-a',
        query: queryFor('user-a', deviceId: 'dev-2'),
        summary: sampleSummary(),
      );
      await cache.saveSummary(
        accountUserId: 'user-a',
        query: queryFor('user-a', deviceId: 'dev-1', date: DateTime(2026, 9, 28)),
        summary: sampleSummary(),
      );
      expect(await cache.countForAccount('user-a'), 3);
    });

    test('账户之间严格隔离：看不到别人的缓存', () async {
      final CloudUsageQuery query = queryFor('user-a', deviceId: 'dev-1');
      await cache.saveSummary(
        accountUserId: 'user-a',
        query: query,
        summary: sampleSummary(),
      );

      expect(await cache.readSummary('user-b', query), isNull,
          reason: '另一个账户绝不能读到 user-a 的云端数据');
      expect(await cache.readDevices('user-b'), isNull);
    });

    test('退出账户只清该账户缓存，本机数据与 outbox 原样保留', () async {
      // 造一条本机采集记录 + 一条待同步记录
      await db.raw.insert(DbSchema.tableActivitySegments, <String, Object?>{
        'id': 'seg-1',
        'owner_id': AppConstants.localOwnerId,
        'device_local_id': 'desktop.local',
        'app_key': 'code',
        'started_at': 1,
        'active_seconds': 60,
        'sync_status': 'pending',
        'created_at': 1,
      });
      await db.raw.insert(DbSchema.tableSyncOutbox, <String, Object?>{
        'id': 'out-1',
        'entity_type': 'activity_segment',
        'entity_key': 'seg-1',
        'operation': 'upsert',
        'payload_json': '{}',
        'created_at': 1,
        'attempt_count': 0,
        'next_attempt_at': 0,
      });

      await cache.saveSummary(
        accountUserId: 'user-a',
        query: queryFor('user-a', deviceId: 'dev-1'),
        summary: sampleSummary(),
      );
      await cache.saveSummary(
        accountUserId: 'user-b',
        query: queryFor('user-b', deviceId: 'dev-9'),
        summary: sampleSummary(),
      );

      final int removed = await cache.clearAccount('user-a');
      expect(removed, 1);
      expect(await cache.countForAccount('user-a'), 0);
      expect(await cache.countForAccount('user-b'), 1, reason: '不该清掉别的账户');

      expect(await rowCount(DbSchema.tableActivitySegments), 1,
          reason: '本机采集记录必须保留');
      expect(await rowCount(DbSchema.tableSyncOutbox), 1, reason: 'outbox 必须保留');
    });

    test('云端缓存永远不会进入 outbox，也不会写入本机采集表', () async {
      final CloudUsageQuery query = queryFor('user-a', deviceId: 'dev-1');
      await cache.saveSummary(
        accountUserId: 'user-a',
        query: query,
        summary: sampleSummary(),
      );
      await cache.saveTimeline(
        accountUserId: 'user-a',
        query: query,
        entries: const <CloudTimelineEntry>[],
      );
      await cache.saveDevices(
        accountUserId: 'user-a',
        devices: const <CloudDevice>[],
      );

      expect(await rowCount(DbSchema.tableSyncOutbox), 0,
          reason: '缓存写入绝不能产生同步任务');
      expect(await rowCount(DbSchema.tableActivitySegments), 0,
          reason: '云端数据绝不能写入本机采集表');
      expect(await rowCount(DbSchema.tableDailyUsage), 0);
      expect(await rowCount(DbSchema.tableCloudCache), 3);
    });

    test('损坏的缓存不会被当成有效数据，也不会让页面崩掉', () async {
      await db.raw.insert(DbSchema.tableCloudCache, <String, Object?>{
        'account_user_id': 'user-a',
        'cache_key': CloudStatisticsCache.buildKey(
          type: CloudCacheType.summary,
          serverBaseUrl: 'http://localhost:8000',
          deviceKey: 'dev-1',
          dayKey: '2026-09-29',
          timezone: 'Asia/Shanghai',
        ),
        'query_type': 'summary',
        'device_key': 'dev-1',
        'day_key': '2026-09-29',
        'timezone': 'Asia/Shanghai',
        'app_id': null,
        'payload_json': '{不是合法 JSON',
        'fetched_at': 1,
        'updated_at': 1,
      });

      // 缓存是可有可无的加速层：坏行 = 未命中（返回 null），而不是抛异常。
      expect(await cache.readSummary('user-a', queryFor('user-a', deviceId: 'dev-1')),
          isNull);
    });
  });

  group('v3 → 最新版本迁移', () {
    test('升级后所有既有数据保留，并新增云端缓存表（v4）与素材收藏列（v5）', () async {
      // 1) 造一个真实的 v3 老库（只执行 v1+v2+v3 建表语句）。
      final String path = p.join(dir.path, 'legacy_v3.db');
      final Database legacy = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 3,
          onConfigure: (Database db) async => db.execute('PRAGMA foreign_keys = OFF'),
          onCreate: (Database db, int version) async {
            final Batch batch = db.batch();
            for (final String statement in <String>[
              ...DbSchema.v1Statements,
              ...DbSchema.v2Statements,
              ...DbSchema.v3Statements,
            ]) {
              batch.execute(statement);
            }
            await batch.commit(noResult: true);
          },
        ),
      );

      // 2) 往**每一张**表塞一行（按 PRAGMA 自动补 NOT NULL 列），
      //    这样任何"迁移把某张表重建/清空"的行为都会被抓到。
      final List<String> tables = <String>[
        ...DbSchema.tableDescriptions.keys,
      ].where((String t) => t != DbSchema.tableCloudCache).toList();
      final Map<String, int> before = <String, int>{};
      for (final String table in tables) {
        await _seedRow(legacy, table);
        before[table] = await _count(legacy, table);
        expect(before[table], 1, reason: '种子数据未写入 $table');
      }
      final int legacyVersion = await legacy.getVersion();
      expect(legacyVersion, 3);
      await legacy.close();

      // 3) 用真实的应用路径打开（逐版本升级到当前版本）。
      await AppDatabase.close();
      db = await AppDatabase.open(path: path);
      dao = CloudStatisticsCacheDao(db.raw);
      cache = CloudStatisticsCache(dao);

      expect(await db.raw.getVersion(), AppConstants.databaseSchemaVersion);
      expect(AppConstants.databaseSchemaVersion, 5,
          reason: 'v5 = emotion_assets.favorite（Phase 4C-6A.1）');

      // 4) 一条数据都不能少。
      for (final MapEntry<String, int> entry in before.entries) {
        expect(await rowCount(entry.key), entry.value,
            reason: '升级后 ${entry.key} 的数据丢失了');
      }

      // 5) 新表可用。
      expect(await rowCount(DbSchema.tableCloudCache), 0);
      await cache.saveSummary(
        accountUserId: 'user-a',
        query: queryFor('user-a', deviceId: 'dev-1'),
        summary: sampleSummary(),
      );
      expect(await cache.countForAccount('user-a'), 1);
    });

    test('新库（全新安装）直接包含云端缓存表', () async {
      expect(await rowCount(DbSchema.tableCloudCache), 0);
      // 全量建表语句里必须包含 v4
      expect(DbSchema.createStatements.any((String s) => s.contains(DbSchema.tableCloudCache)),
          isTrue);
      expect(DbSchema.migrations.containsKey(4), isTrue);
    });
  });
}

/// 少数表带 CHECK 约束，需要额外补一列才能插入一行**合法**数据。
/// 这里显式列出，而不是让测试"跳过"这些表 —— 跳过就等于不验证它的数据是否保留。
const Map<String, Map<String, Object?>> _seedOverrides =
    <String, Map<String, Object?>>{
  // CHECK (asset_id IS NOT NULL OR emotion_name IS NOT NULL)
  DbSchema.tableStateMappings: <String, Object?>{'emotion_name': 'neutral'},
};

/// 往任意表插一行：按 `PRAGMA table_info` 给所有 NOT NULL 列填合法值。
Future<void> _seedRow(Database db, String table) async {
  final List<Map<String, Object?>> columns =
      await db.rawQuery('PRAGMA table_info($table)');
  final Map<String, Object?> values = <String, Object?>{};
  for (final Map<String, Object?> column in columns) {
    final String name = column['name']! as String;
    final String type = '${column['type']}'.toUpperCase();
    final bool isNotNull = ((column['notnull'] as int?) ?? 0) == 1;
    final bool isPrimaryKey = ((column['pk'] as int?) ?? 0) > 0;
    if (!isNotNull && !isPrimaryKey) continue;
    if (isPrimaryKey && type.contains('INT')) continue; // 自增主键
    values[name] = type.contains('INT') ? 1 : 'seed-$table';
  }
  values.addAll(_seedOverrides[table] ?? const <String, Object?>{});
  await db.insert(table, values);
}

Future<int> _count(Database db, String table) async {
  final List<Map<String, Object?>> rows =
      await db.rawQuery('SELECT COUNT(*) AS c FROM $table');
  return (rows.first['c'] as int?) ?? 0;
}

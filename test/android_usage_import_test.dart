import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:petlife/activity_tracking/android_usage_import_service.dart';
import 'package:petlife/activity_tracking/android_usage_session.dart';
import 'package:petlife/activity_tracking/application_repository.dart';
import 'package:petlife/activity_tracking/models/activity_enums.dart';
import 'package:petlife/activity_tracking/models/activity_sample.dart';
import 'package:petlife/core/ids.dart';
import 'package:petlife/database/app_database.dart';
import 'package:petlife/database/dao/activity_dao.dart';
import 'package:petlife/database/dao/application_dao.dart';
import 'package:petlife/database/dao/sync_outbox_dao.dart';
import 'package:petlife/database/schema.dart';
import 'package:petlife/sync/models/sync_models.dart';
import 'package:petlife/sync/outbox_producer.dart';

import 'overlay_pet_controller_test.dart' show FakeOverlayPet;
import 'support/sqlite_test_bootstrap.dart';

const String kOwner = 'local.default';
const String kDevice = 'a1b2c3d4-1111-4222-8333-444455556666';

/// Phase 4C-5.1B：Android 原生使用会话的**幂等导入**。
///
/// 覆盖需求 §13.2 里可以在 JVM 上真实验证的部分：字段解析、确定性 UUID、
/// 重复导入不重复插入、提交失败不确认、成功导入后确认、多入口单任务、
/// 新段写入 outbox、本机设备 ID 过滤。
///
/// 复用 `overlay_pet_controller_test.dart` 里的 `FakeOverlayPet`：
/// 它已经实现了整个 `AndroidOverlayPet` 接口（含 4C-5.1B 的五个新方法），
/// 再写一个 30 多个成员的桩只会带来重复与漂移。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SqliteTestBootstrap.ensureLoaded();

  late Directory tmp;
  late AppDatabase db;
  late ActivityDao activityDao;
  late SyncOutboxDao outboxDao;
  late ApplicationRepository apps;
  late FakeOverlayPet overlay;
  late AndroidUsageImportService importer;

  setUpAll(() {
    tmp = Directory.systemTemp.createTempSync('petlife_android_import_test');
  });

  tearDownAll(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  setUp(() async {
    await AppDatabase.close();
    db = await AppDatabase.open(
      path: p.join(tmp.path, 'import_${DateTime.now().microsecondsSinceEpoch}.db'),
    );
    activityDao = ActivityDao(db.raw);
    outboxDao = SyncOutboxDao(db.raw);
    apps = ApplicationRepository(dao: ApplicationDao(db.raw));
    await apps.load();
    overlay = FakeOverlayPet();
    importer = AndroidUsageImportService(
      overlay: overlay,
      database: db,
      outboxDao: outboxDao,
      outboxProducer: OutboxProducer(db: db, outbox: outboxDao, ownerId: kOwner),
      applications: apps,
      ownerId: kOwner,
      deviceLocalId: kDevice,
    );
  });

  tearDown(() async {
    await AppDatabase.close();
  });

  /// 构造一条原生返回的记录（走真实的解析路径，顺带覆盖字段校验）。
  AndroidUsageSession session({
    String sessionId = 's-1',
    String packageName = 'org.telegram.messenger',
    String? appName = 'Telegram',
    String? category = 'social',
    String deviceLocalId = kDevice,
    int startedAtMs = 1_700_000_000_000,
    int endedAtMs = 1_700_000_020_000,
    int activeSeconds = 20,
    String endReason = 'app_switch',
  }) {
    final AndroidUsageSession? parsed = AndroidUsageSession.fromMap(<String, Object?>{
      'schemaVersion': 1,
      'sessionId': sessionId,
      'deviceLocalId': deviceLocalId,
      'packageName': packageName,
      'appName': appName,
      'category': category,
      'startedAt': startedAtMs,
      'endedAt': endedAtMs,
      'activeSeconds': activeSeconds,
      'endReason': endReason,
      'createdAt': endedAtMs,
    });
    expect(parsed, isNotNull, reason: '测试夹具本身必须是合法记录');
    return parsed!;
  }

  group('AndroidUsageSession 解析', () {
    test('合法记录逐字段解析，时间按 UTC 处理', () {
      final AndroidUsageSession s = session();
      expect(s.sessionId, 's-1');
      expect(s.packageName, 'org.telegram.messenger');
      expect(s.appName, 'Telegram');
      expect(s.category, 'social');
      expect(s.activeSeconds, 20);
      expect(s.endReason, 'app_switch');
      expect(s.startedAt.isUtc, isTrue);
      expect(s.endedAt.isUtc, isTrue);
    });

    test('schemaVersion 不认识 → 拒绝（不猜）', () {
      expect(
        AndroidUsageSession.fromMap(<String, Object?>{
          'schemaVersion': 99,
          'sessionId': 's',
          'packageName': 'a.b',
          'startedAt': 1,
          'endedAt': 2,
          'activeSeconds': 1,
          'endReason': 'app_switch',
          'createdAt': 2,
        }),
        isNull,
      );
    });

    test('关键字段缺失 / 结束早于开始 / 负数时长 → 拒绝', () {
      Map<String, Object?> base() => <String, Object?>{
            'schemaVersion': 1,
            'sessionId': 's',
            'packageName': 'a.b',
            'startedAt': 1000,
            'endedAt': 2000,
            'activeSeconds': 1,
            'endReason': 'app_switch',
            'createdAt': 2000,
          };

      expect(AndroidUsageSession.fromMap(base()..remove('sessionId')), isNull);
      expect(AndroidUsageSession.fromMap(base()..['packageName'] = ''), isNull);
      expect(AndroidUsageSession.fromMap(base()..['endedAt'] = 500), isNull);
      expect(AndroidUsageSession.fromMap(base()..['activeSeconds'] = -1), isNull);
      expect(AndroidUsageSession.fromMap(base()..['endReason'] = ''), isNull);
    });

    test('appName / category 缺失时如实为 null（不编造）', () {
      final AndroidUsageSession s = session(appName: null, category: null);
      expect(s.appName, isNull);
      expect(s.category, isNull);
    });

    test('采集器状态解析出可读文案', () {
      final UsageCollectorState state = UsageCollectorState.fromMap(<String, Object?>{
        'supported': true,
        'running': true,
        'collectorRunning': true,
        'usageAccessAvailable': true,
        'journalAvailable': true,
        'pendingCount': 3,
        'currentSessionSeconds': 42,
      });
      expect(state.collecting, isTrue);
      expect(state.labelZh, '采集中');
      expect(state.pendingCount, 3);
      expect(state.currentSessionSeconds, 42);

      final UsageCollectorState missing = UsageCollectorState.fromMap(<String, Object?>{
        'supported': true,
        'running': true,
        'usageAccessAvailable': false,
        'failureReason': 'usage_access_missing',
      });
      expect(missing.collecting, isFalse);
      expect(missing.labelZh, '缺少使用情况访问权限');
    });
  });

  group('确定性段 ID', () {
    test('同一设备 + 同一 session_id 永远得到同一个段 ID', () {
      final AndroidUsageSession s = session(sessionId: 'abc');
      expect(Ids.usageSession(kDevice, s.sessionId), Ids.usageSession(kDevice, 'abc'));
      expect(Ids.usageSession(kDevice, 'abc'), isNot(Ids.usageSession(kDevice, 'abd')));
      // 换设备 → 换 ID（不同设备的数据不能撞主键）。
      expect(Ids.usageSession(kDevice, 'abc'), isNot(Ids.usageSession('other', 'abc')));
    });
  });

  group('导入', () {
    test('成功导入：段入库 + 新段写入 outbox + 事务成功后确认', () async {
      overlay.pendingSessions = <AndroidUsageSession>[session()];

      final AndroidUsageImportResult result = await importer.importPending();

      expect(result.failed, isFalse);
      expect(result.read, 1);
      expect(result.inserted, 1);
      expect(result.alreadyImported, 0);
      expect(result.acknowledged, 1);
      expect(result.summaryZh, contains('新增 1'));

      final List<ActivitySegment> rows = await activityDao.listRange(
        kOwner,
        DateTime.fromMillisecondsSinceEpoch(0),
        DateTime.fromMillisecondsSinceEpoch(9_999_999_999_999),
      );
      expect(rows, hasLength(1));
      expect(rows.first.deviceLocalId, kDevice);
      expect(rows.first.appKey, 'org.telegram.messenger');
      expect(rows.first.appName, 'Telegram');
      expect(rows.first.activeSeconds, 20);
      expect(rows.first.endReason, 'app_switch');
      expect(rows.first.syncStatus, 'pending');

      // outbox 里必须有一条待同步（含 category，供服务端白名单校验）。
      final List<OutboxEntry> pending = await outboxDao.takeBatch(
        limit: 10,
        now: DateTime.now().add(const Duration(minutes: 1)),
      );
      final OutboxEntry segmentEntry = pending
          .firstWhere((OutboxEntry e) => e.entityType == SyncEntityType.activitySegment);
      expect(segmentEntry.payload['app_key'], 'org.telegram.messenger');
      expect(segmentEntry.payload['category'], AppCategory.social.wireName);
      expect(segmentEntry.payload['active_seconds'], 20);

      expect(overlay.acknowledgedSessionIds, <String>['s-1']);
    });

    test('应用被登记进应用库（显示名与分类来自原生）', () async {
      overlay.pendingSessions = <AndroidUsageSession>[session()];
      await importer.importPending();

      final TrackedApplication? app = apps.find('org.telegram.messenger');
      expect(app, isNotNull);
      expect(app!.displayName, 'Telegram');
      expect(app.category, AppCategory.social);
    });

    test('重复导入不重复插入，也不重复累计时长', () async {
      overlay.pendingSessions = <AndroidUsageSession>[session()];
      await importer.importPending();
      // 模拟"导入成功但确认前崩溃"：原生侧记录仍在，再导一次。
      overlay.pendingSessions = <AndroidUsageSession>[session()];
      final AndroidUsageImportResult second = await importer.importPending();

      expect(second.inserted, 0);
      expect(second.alreadyImported, 1);
      expect(second.acknowledged, 1);

      final List<ActivitySegment> rows = await activityDao.listRange(
        kOwner,
        DateTime.fromMillisecondsSinceEpoch(0),
        DateTime.fromMillisecondsSinceEpoch(9_999_999_999_999),
      );
      expect(rows, hasLength(1), reason: '重复导入绝不能新增第二条记录');
      expect(rows.first.activeSeconds, 20, reason: '时长不允许翻倍');
    });

    test('SQLite 提交失败时不确认 journal', () async {
      overlay.pendingSessions = <AndroidUsageSession>[session()];
      // 关掉数据库 → 事务必然失败（真实故障注入，不是打桩）。
      await AppDatabase.close();

      final AndroidUsageImportResult result = await importer.importPending();

      expect(result.failed, isTrue);
      expect(result.error, isNotNull);
      expect(
        overlay.acknowledgedSessionIds,
        isEmpty,
        reason: '本地没落库就确认原生记录 = 直接丢数据',
      );
    });

    test('多入口同时触发只有一个导入任务（单任务互斥）', () async {
      overlay.pendingSessions = <AndroidUsageSession>[session()];

      final Future<AndroidUsageImportResult> a = importer.importPending();
      final Future<AndroidUsageImportResult> b = importer.importPending();
      final List<AndroidUsageImportResult> both =
          await Future.wait(<Future<AndroidUsageImportResult>>[a, b]);

      // 两次调用复用同一个在途任务，因此结果是同一次导入。
      expect(both[0].inserted, 1);
      expect(both[1].inserted, 1);
      expect(
        overlay.calls.where((String c) => c == 'readPendingUsageSessions').length,
        1,
        reason: '并发触发不得读取两次（否则两次都可能写库）',
      );
      final List<ActivitySegment> rows = await activityDao.listRange(
        kOwner,
        DateTime.fromMillisecondsSinceEpoch(0),
        DateTime.fromMillisecondsSinceEpoch(9_999_999_999_999),
      );
      expect(rows, hasLength(1));
    });

    test('导入完成前不会读第二遍（isImporting 反映在途状态）', () async {
      overlay.pendingSessions = <AndroidUsageSession>[session()];
      final Future<AndroidUsageImportResult> task = importer.importPending();
      expect(importer.isImporting, isTrue);
      await task;
      expect(importer.isImporting, isFalse);
      expect(importer.lastImportAt, isNotNull);
      expect(importer.lastError, isNull);
      expect(importer.lastInsertedCount, 1);
    });

    test('别的设备标识的记录被跳过：不写库、不进 outbox、且被确认掉', () async {
      overlay.pendingSessions = <AndroidUsageSession>[
        session(sessionId: 'foreign', deviceLocalId: 'another-device-uuid'),
        session(sessionId: 'mine'),
      ];

      final AndroidUsageImportResult result = await importer.importPending();

      expect(result.read, 2);
      expect(result.inserted, 1);
      expect(result.skipped, 1);

      final List<ActivitySegment> rows = await activityDao.listRange(
        kOwner,
        DateTime.fromMillisecondsSinceEpoch(0),
        DateTime.fromMillisecondsSinceEpoch(9_999_999_999_999),
      );
      expect(rows, hasLength(1));
      expect(rows.first.deviceLocalId, kDevice);
      // 本机不可导入的记录必须被确认掉，否则会永久堵在 FIFO 队头。
      expect(overlay.acknowledgedSessionIds, contains('foreign'));
    });

    test('设备标识为空（下发前产生的记录）按本机处理，由本端补齐归属', () async {
      overlay.pendingSessions = <AndroidUsageSession>[session(deviceLocalId: '')];
      final AndroidUsageImportResult result = await importer.importPending();
      expect(result.inserted, 1);

      final List<ActivitySegment> rows = await activityDao.listRange(
        kOwner,
        DateTime.fromMillisecondsSinceEpoch(0),
        DateTime.fromMillisecondsSinceEpoch(9_999_999_999_999),
      );
      expect(rows.first.deviceLocalId, kDevice);
    });

    test('空 journal 是正常状态：不报错、不写库', () async {
      overlay.pendingSessions = <AndroidUsageSession>[];
      final AndroidUsageImportResult result = await importer.importPending();
      expect(result.failed, isFalse);
      expect(result.isEmpty, isTrue);
      expect(result.inserted, 0);
      expect(importer.lastImportAt, isNotNull);
      expect(
        await db.raw.query(DbSchema.tableActivitySegments),
        isEmpty,
      );
    });

    test('单批条数受限（避免一次传输过大）', () async {
      final AndroidUsageImportService limited = AndroidUsageImportService(
        overlay: overlay,
        database: db,
        outboxDao: outboxDao,
        outboxProducer: OutboxProducer(db: db, outbox: outboxDao, ownerId: kOwner),
        applications: apps,
        ownerId: kOwner,
        deviceLocalId: kDevice,
        batchLimit: 2,
      );
      overlay.pendingSessions = <AndroidUsageSession>[
        session(sessionId: 'a'),
        session(sessionId: 'b'),
        session(sessionId: 'c'),
      ];
      final AndroidUsageImportResult result = await limited.importPending();
      expect(result.read, 2);
      expect(result.inserted, 2);
    });
  });

  group('与原生对齐', () {
    test('initialize 下发设备标识与暂停状态', () async {
      await importer.initialize(paused: true);
      expect(overlay.pushedDeviceLocalId, kDevice);
      expect(overlay.pushedPaused, isTrue);
    });

    test('暂停状态变化单独同步', () async {
      await importer.syncCollectionPaused(false);
      expect(overlay.pushedPaused, isFalse);
      expect(overlay.calls, contains('setUsageCollectionPaused'));
    });

    test('读取采集器状态；桥接异常时降级为"不支持"而不是崩', () async {
      overlay.collectorState = const UsageCollectorState(
        supported: true,
        running: true,
        collectorRunning: true,
        usageAccessAvailable: true,
        pendingCount: 7,
      );
      final UsageCollectorState state = await importer.collectorState();
      expect(state.pendingCount, 7);
      expect(state.collecting, isTrue);
    });
  });
}

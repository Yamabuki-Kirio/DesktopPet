import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:petlife/core/constants.dart';
import 'package:petlife/database/app_database.dart';
import 'package:petlife/database/dao/account_session_dao.dart';
import 'package:petlife/database/dao/cloud_statistics_cache_dao.dart';
import 'package:petlife/database/dao/sync_outbox_dao.dart';
import 'package:petlife/database/dao/sync_state_dao.dart';
import 'package:petlife/database/schema.dart';
import 'package:petlife/sync/authenticated_api.dart';
import 'package:petlife/sync/cloud_statistics_cache.dart';
import 'package:petlife/sync/cloud_statistics_controller.dart';
import 'package:petlife/sync/credential_store.dart';
import 'package:petlife/sync/device_identity.dart';
import 'package:petlife/sync/outbox_producer.dart';
import 'package:petlife/sync/sync_engine.dart';
import 'package:petlife/sync/sync_preferences.dart';
import 'package:petlife/ui/widgets/cloud_sync_actions.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fake_cloud_statistics.dart';
import 'support/fake_petlife_server.dart';
import 'support/sqlite_test_bootstrap.dart';

/// 「账户与同步」页两个动作按钮（Phase 4B 步骤 7 / 需求「八」）。
///
/// 两个按钮的含义必须**互不混淆**：
/// * **立即上传本机记录** → 调用 [SyncEngine] 把本机 outbox 推给服务器（上行）；
/// * **刷新云端统计** → 只按当前查询条件重读服务器统计（下行，**不碰 outbox**）。
///
/// 这里刻意分两层验证：
/// * Widget 层用可观测的 host，断言"点哪个按钮就只触发哪条链路"；
/// * 适配器层用**真的** [SyncEngine] + 本地假 HTTP 服务端 / **真的** outbox 表，
///   断言按钮背后确实发生了（或确实没有发生）对 outbox 的写入。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SqliteTestBootstrap.ensureLoaded();

  const String owner = AppConstants.localOwnerId;
  const String device = AppConstants.localDeviceId;
  const int t0 = 1767225600000;

  Directory? tmp;

  setUpAll(() async {
    tmp = Directory.systemTemp.createTempSync('petlife_cloud_actions_test');
    // 真实 HTTP（本地假服务端）需要把 Flutter 测试绑定的 HttpClient 替身清掉。
    HttpOverrides.global = null;
  });

  tearDownAll(() {
    final Directory? dir = tmp;
    if (dir != null && dir.existsSync()) dir.deleteSync(recursive: true);
  });

  // ---------------------------------------------------------------------------
  // Widget 层：按钮语义
  // ---------------------------------------------------------------------------

  group('按钮语义', () {
    testWidgets('两个按钮各只触发自己那条链路，并显示待上传数量', (WidgetTester tester) async {
      final _RecordingUploadHost upload = _RecordingUploadHost()..pendingCountValue = 3;
      final _RecordingCloudHost cloud = _RecordingCloudHost();

      await tester.pumpWidget(_card(upload: upload, cloud: cloud));

      expect(find.text('立即上传本机记录'), findsOneWidget);
      expect(find.text('刷新云端统计'), findsOneWidget);
      expect(find.text('3 条'), findsOneWidget, reason: '要显示待上传数量');
      expect(find.text('我的电脑 · Windows'), findsOneWidget);

      await tester.tap(find.text('立即上传本机记录'));
      await tester.pump();
      expect(upload.uploadCalls, 1);
      expect(cloud.refreshCalls, 0, reason: '上传按钮不得触发云端查询');

      await tester.tap(find.text('刷新云端统计'));
      await tester.pump();
      expect(cloud.refreshCalls, 1);
      expect(upload.uploadCalls, 1, reason: '刷新按钮不得触发上传');
    });

    testWidgets('进行中时按钮被禁用（不重复触发）', (WidgetTester tester) async {
      final _RecordingUploadHost upload = _RecordingUploadHost()..uploading = true;
      final _RecordingCloudHost cloud = _RecordingCloudHost()..refreshing = true;

      await tester.pumpWidget(_card(upload: upload, cloud: cloud));

      expect(
        tester
            .widget<FilledButton>(
              find.ancestor(
                of: find.text('立即上传本机记录'),
                matching: find.byType(FilledButton),
              ),
            )
            .onPressed,
        isNull,
        reason: '上传中不得再次触发上传',
      );
      expect(
        tester
            .widget<OutlinedButton>(
              find.ancestor(
                of: find.text('刷新云端统计'),
                matching: find.byType(OutlinedButton),
              ),
            )
            .onPressed,
        isNull,
        reason: '查询中不得再次触发查询',
      );
    });

    testWidgets('最近上传 / 最近云端查询分别显示各自的时间，不混用', (WidgetTester tester) async {
      final _RecordingUploadHost upload = _RecordingUploadHost()
        ..pendingCountValue = 0
        ..lastUpload = DateTime(2026, 9, 29, 17, 5);
      final _RecordingCloudHost cloud = _RecordingCloudHost()
        ..lastRefresh = DateTime(2026, 9, 29, 17, 20);

      await tester.pumpWidget(_card(upload: upload, cloud: cloud));

      expect(find.textContaining('2026-09-29 17:05'), findsOneWidget);
      expect(find.textContaining('2026-09-29 17:20'), findsOneWidget);
      expect(find.text('0 条'), findsOneWidget);
    });
  });

  // ---------------------------------------------------------------------------
  // 适配器层：真的 SyncEngine / 真的 outbox 表
  // ---------------------------------------------------------------------------

  group('适配器层', () {
    late AppDatabase db;
    late SyncOutboxDao outbox;
    late SyncStateDao stateDao;
    late OutboxProducer producer;
    late InMemoryCredentialStore credentials;
    late AuthenticatedApi api;
    late SyncEngine engine;
    bool setupDone = false;

    Future<void> buildEngine() async {
      await AppDatabase.close();
      db = await AppDatabase.open(
        path: p.join(tmp!.path, 'actions_${DateTime.now().microsecondsSinceEpoch}.db'),
      );
      outbox = SyncOutboxDao(db.raw);
      stateDao = SyncStateDao(db.raw);
      producer = OutboxProducer(db: db, outbox: outbox, ownerId: owner);
      credentials = InMemoryCredentialStore();
      api = AuthenticatedApi(
        credentialStore: credentials,
        accountSessionDao: AccountSessionDao(db.raw),
        deviceIdentity: DeviceIdentity(db),
        preferences: SyncPreferences(db),
      );
      engine = SyncEngine(
        api: api,
        outboxDao: outbox,
        stateDao: stateDao,
        producer: producer,
        preferences: SyncPreferences(db),
        periodicInterval: const Duration(hours: 1),
      );
      setupDone = true;
    }

    Future<void> seedSegment(String id) async {
      await db.raw.insert(
        DbSchema.tableActivitySegments,
        <String, Object?>{
          'id': id,
          'owner_id': owner,
          'device_local_id': device,
          'app_key': 'code',
          'app_name': 'Code',
          'process_name': 'Code.exe',
          'started_at': t0,
          'ended_at': t0 + 60000,
          'active_seconds': 60,
          'end_reason': 'foreground_changed',
          'sync_status': 'pending',
          'created_at': t0,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }

    tearDown(() async {
      if (!setupDone) return;
      setupDone = false;
      await engine.stop();
      engine.dispose();
      api.dispose();
      await AppDatabase.close();
    });

    test('「立即上传本机记录」真的调用 SyncEngine 把记录推给服务器', () async {
      final FakePetLifeServer server = await FakePetLifeServer.start();
      try {
        await buildEngine();

        await api.signIn(
          baseUrl: server.baseUrl,
          email: 'tester@example.com',
          password: 'password-1234',
          registerInsteadOfLogin: false,
        );
        // 登录会顺带回填历史；此时队列应为空。
        await engine.onSignedIn();
        expect(engine.pendingCount, 0);

        // 登录后再产生一条本机记录，让它停在待上传状态。
        await seedSegment('segment-actions');
        await producer.enqueueSegment('segment-actions');
        await engine.refreshPendingCount();

        final SyncEngineUploadHost host = SyncEngineUploadHost(engine);
        expect(host.pendingCount, 1);
        final int pushesBefore = server.pushCount;

        await host.uploadNow();

        expect(engine.pendingCount, 0, reason: '上传按钮必须真正驱动 SyncEngine 上传');
        expect(server.pushCount, greaterThan(pushesBefore), reason: '必须真的推给服务器');
      } finally {
        await server.close(force: true);
      }
    });

    test('「刷新云端统计」只读服务器，绝不写 outbox', () async {
      await buildEngine();

      // 先垫两条待上传记录：如果刷新云端统计碰了 outbox，这两条一定会变。
      await seedSegment('segment-keep-1');
      await seedSegment('segment-keep-2');
      await producer.enqueueSegment('segment-keep-1');
      await producer.enqueueSegment('segment-keep-2');
      expect(await outbox.pendingCount(), 2);

      final FakeCloudStatisticsRepository repo = FakeCloudStatisticsRepository();
      final CloudStatisticsCache cache = CloudStatisticsCache(
        CloudStatisticsCacheDao(db.raw),
      );
      final CloudStatisticsController controller = CloudStatisticsController(
        repository: repo,
        cache: cache,
        currentAccountUserId: () => 'user-a',
      );

      await CloudControllerRefreshHost(controller).refreshNow();

      expect(repo.summaryCalls, 1, reason: '必须真的去读云端统计');
      expect(repo.timelineCalls, 1);

      final List<Map<String, Object?>> rows =
          await db.raw.query(DbSchema.tableSyncOutbox);
      expect(rows.length, 2, reason: '刷新云端统计不得往 outbox 写入任何记录');
      expect(await outbox.pendingCount(), 2, reason: '待上传记录不得被刷新动作改动');
      expect(await outbox.countAcknowledged(), 0, reason: '刷新云端统计不得确认任何记录');

      controller.dispose();
    });
  });
}

Widget _card({
  required UploadActionHost upload,
  required CloudRefreshHost cloud,
}) {
  return MaterialApp(
    home: Scaffold(
      body: CloudSyncActionsCard(
        upload: upload,
        cloud: cloud,
        deviceName: '我的电脑 · Windows',
      ),
    ),
  );
}

/// 记录调用次数的上行 host。
class _RecordingUploadHost implements UploadActionHost {
  final ChangeNotifier _notifier = ChangeNotifier();

  int uploadCalls = 0;
  int pendingCountValue = 0;
  bool uploading = false;
  DateTime? lastUpload;

  @override
  int get pendingCount => pendingCountValue;

  @override
  DateTime? get lastUploadAt => lastUpload;

  @override
  bool get isUploading => uploading;

  @override
  Future<void> uploadNow() async {
    uploadCalls++;
  }

  @override
  void addListener(VoidCallback listener) => _notifier.addListener(listener);

  @override
  void removeListener(VoidCallback listener) => _notifier.removeListener(listener);
}

/// 记录调用次数的下行 host。
class _RecordingCloudHost implements CloudRefreshHost {
  final ChangeNotifier _notifier = ChangeNotifier();

  int refreshCalls = 0;
  bool refreshing = false;
  DateTime? lastRefresh;

  @override
  DateTime? get lastRefreshedAt => lastRefresh;

  @override
  bool get isRefreshing => refreshing;

  @override
  Future<void> refreshNow() async {
    refreshCalls++;
  }

  @override
  void addListener(VoidCallback listener) => _notifier.addListener(listener);

  @override
  void removeListener(VoidCallback listener) => _notifier.removeListener(listener);
}

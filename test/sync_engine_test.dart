import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:petlife/core/constants.dart';
import 'package:petlife/database/app_database.dart';
import 'package:petlife/database/dao/account_session_dao.dart';
import 'package:petlife/database/dao/sync_outbox_dao.dart';
import 'package:petlife/database/dao/sync_state_dao.dart';
import 'package:petlife/database/schema.dart';
import 'package:petlife/sync/authenticated_api.dart';
import 'package:petlife/sync/credential_store.dart';
import 'package:petlife/sync/device_identity.dart';
import 'package:petlife/sync/models/sync_models.dart';
import 'package:petlife/sync/outbox_producer.dart';
import 'package:petlife/sync/sync_engine.dart';
import 'package:petlife/sync/sync_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fake_petlife_server.dart';
import 'support/sqlite_test_bootstrap.dart';

/// 同步引擎：触发、互斥、退避、认证刷新、设备撤销、离线不丢数据。
///
/// 全部通过**本地假 HTTP 服务端**跑真实网络栈，不访问公网。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SqliteTestBootstrap.ensureLoaded();

  const String owner = AppConstants.localOwnerId;
  const String device = AppConstants.localDeviceId;
  const int t0 = 1767225600000;

  late Directory tmp;
  late AppDatabase db;
  late SyncOutboxDao outbox;
  late SyncStateDao stateDao;
  late OutboxProducer producer;
  late InMemoryCredentialStore credentials;
  late AuthenticatedApi api;
  late SyncEngine engine;

  /// `engine / api / db` 都是 late，纯函数用例不会初始化它们，
  /// 因此 tearDown 需要一个显式标记，避免 "Local 'engine' has not been initialized"。
  bool setupDone = false;

  setUpAll(() {
    tmp = Directory.systemTemp.createTempSync('petlife_sync_engine_test');
    // 关键：Flutter 的 TestWidgetsFlutterBinding 会把 HttpClient 换成一个
    // "所有请求都返回 400" 的替身，真实网络请求根本发不出去。
    // 本文件要跑真实 HTTP（连本地假服务端），因此必须把 overrides 清掉。
    HttpOverrides.global = null;
  });

  tearDownAll(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// 建一套完整依赖；退避用毫秒级阶梯，让重试测试跑得快。
  Future<SyncEngine> buildEngine({List<Duration>? backoff}) async {
    await AppDatabase.close();
    db = await AppDatabase.open(
      path: p.join(tmp.path, 'engine_${DateTime.now().microsecondsSinceEpoch}.db'),
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
      backoffSteps: backoff ??
          const <Duration>[
            Duration(milliseconds: 40),
            Duration(milliseconds: 80),
            Duration(milliseconds: 160),
          ],
      periodicInterval: const Duration(hours: 1),
    );
    setupDone = true;
    return engine;
  }

  Future<void> seedSegment(String id, {int activeSeconds = 60}) async {
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
        'ended_at': t0 + activeSeconds * 1000,
        'active_seconds': activeSeconds,
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

  group('退避阶梯', () {
    test('按 5s → 15s → 1min → 5min → 15min 递增并封顶', () {
      final List<Duration> ladder = SyncEngine.defaultBackoffSteps;
      expect(ladder.map((Duration d) => d.inSeconds).toList(),
          <int>[5, 15, 60, 300, 900]);

      expect(SyncEngine.computeBackoff(1).inSeconds, 5);
      expect(SyncEngine.computeBackoff(2).inSeconds, 15);
      expect(SyncEngine.computeBackoff(3).inSeconds, 60);
      expect(SyncEngine.computeBackoff(4).inSeconds, 300);
      expect(SyncEngine.computeBackoff(5).inSeconds, 900);
      // 超过阶梯长度后封顶，且不超过 1 小时
      expect(SyncEngine.computeBackoff(6).inSeconds, 900);
      expect(SyncEngine.computeBackoff(99).inSeconds <= 3600, isTrue);
    });

    test('0 或负数按第一次处理，不越界', () {
      expect(SyncEngine.computeBackoff(0).inSeconds, 5);
      expect(SyncEngine.computeBackoff(-3).inSeconds, 5);
    });
  });

  group('登录与基本同步', () {
    test('未登录时状态为 signedOut，且不发任何网络请求', () async {
      await buildEngine();
      await engine.start();
      expect(engine.status, SyncStatus.signedOut);
      expect(api.isSignedIn, isFalse);
      await engine.syncNow();
      expect(engine.status, SyncStatus.signedOut);
    });

    test('登录 → 设备注册 → 上传历史记录 → 状态 success 且队列清空', () async {
      final FakePetLifeServer server = await FakePetLifeServer.start();
      try {
        await buildEngine();
        await seedSegment('segment-1');
        await seedSegment('segment-2');

        await api.signIn(
          baseUrl: server.baseUrl,
          email: 'tester@example.com',
          password: 'password-1234',
          registerInsteadOfLogin: false,
        );
        expect(server.registerDeviceCount, greaterThanOrEqualTo(1));
        expect(api.lastAccount?.deviceServerId, 'server-device-1');
        // 令牌只在凭据存储里，不在数据库里
        expect(credentials.keys, contains('PetLife:account'));

        await engine.onSignedIn();
        expect(engine.status, SyncStatus.success);
        expect(engine.pendingCount, 0, reason: '历史数据应当已上传并被确认');
        expect(server.pushCount, greaterThanOrEqualTo(1));
        expect(server.storedRecords.length, 2);
      } finally {
        await server.close(force: true);
      }
    });

    test('拉取会推进游标（用于与服务端对齐）', () async {
      final FakePetLifeServer server = await FakePetLifeServer.start();
      try {
        await buildEngine();
        await api.signIn(
          baseUrl: server.baseUrl,
          email: 'tester@example.com',
          password: 'password-1234',
          registerInsteadOfLogin: false,
        );
        await engine.syncNow();
        expect(server.pullCount, greaterThanOrEqualTo(1));
        final List<SyncStateRow> rows = await stateDao.loadAll();
        expect(rows, isNotEmpty);
        expect(rows.first.cursor, 7, reason: '服务端返回的游标应当被记录');
      } finally {
        await server.close(force: true);
      }
    });

    test('同一个批次重复提交不会产生重复数据（服务端幂等 + 客户端确认）', () async {
      final FakePetLifeServer server = await FakePetLifeServer.start();
      try {
        await buildEngine();
        await seedSegment('segment-1');
        await api.signIn(
          baseUrl: server.baseUrl,
          email: 'tester@example.com',
          password: 'password-1234',
          registerInsteadOfLogin: false,
        );
        await engine.onSignedIn();
        final int storedAfterFirst = server.storedRecords.length;

        // 再次强制回填并同步
        await producer.enqueueHistory();
        await engine.syncNow();
        expect(server.storedRecords.length, storedAfterFirst);
        expect(engine.pendingCount, 0);
      } finally {
        await server.close(force: true);
      }
    });
  });

  group('单任务互斥', () {
    test('并发触发时不会启动第二个同步任务', () async {
      final FakePetLifeServer server = await FakePetLifeServer.start();
      server.pushDelayMs = 150;
      try {
        await buildEngine();
        await seedSegment('segment-1');
        await api.signIn(
          baseUrl: server.baseUrl,
          email: 'tester@example.com',
          password: 'password-1234',
          registerInsteadOfLogin: false,
        );
        await producer.enqueueHistory();

        // 同时发起三次（模拟：定时器到点 + 用户点按钮 + 网络恢复）
        await Future.wait<void>(<Future<void>>[
          engine.syncNow(),
          engine.syncNow(),
          engine.syncNow(),
        ]);

        expect(server.maxConcurrentPush, 1,
            reason: '同一时刻只允许一个 push 请求在飞');
        expect(engine.pendingCount, 0);
      } finally {
        await server.close(force: true);
      }
    });
  });

  group('令牌刷新', () {
    test('Access Token 过期时自动刷新并重试一次', () async {
      final FakePetLifeServer server = await FakePetLifeServer.start();
      try {
        await buildEngine();
        await seedSegment('segment-1');
        await api.signIn(
          baseUrl: server.baseUrl,
          email: 'tester@example.com',
          password: 'password-1234',
          registerInsteadOfLogin: false,
        );
        await producer.enqueueHistory();

        // 让客户端手里的令牌变成"过期"的
        server.requireFreshAccessToken = true;
        server.accessTokenGeneration = 99;
        final int refreshBefore = server.refreshCount;

        await engine.syncNow();

        expect(engine.status, SyncStatus.success);
        expect(server.refreshCount, refreshBefore + 1, reason: '只应刷新一次');
        expect(engine.pendingCount, 0);
      } finally {
        await server.close(force: true);
      }
    });

    test('Refresh Token 失效 → 进入需要重新登录，且不会无限刷新', () async {
      final FakePetLifeServer server = await FakePetLifeServer.start();
      try {
        await buildEngine();
        await seedSegment('segment-1');
        await api.signIn(
          baseUrl: server.baseUrl,
          email: 'tester@example.com',
          password: 'password-1234',
          registerInsteadOfLogin: false,
        );
        await producer.enqueueHistory();

        server.requireFreshAccessToken = true;
        server.accessTokenGeneration = 99;
        server.rejectRefresh = true;
        final int refreshBefore = server.refreshCount;

        await engine.syncNow();

        expect(engine.status, SyncStatus.needsReauthentication);
        expect(api.needsReauthentication, isTrue);
        expect(server.refreshCount, refreshBefore + 1,
            reason: '刷新只允许尝试一次，绝不能进入无限刷新循环');
        // 令牌被清理
        expect(credentials.keys, isEmpty);
        // **本地数据与待同步队列必须保留**
        expect(engine.pendingCount, greaterThan(0));
        final int remaining = await outbox.pendingCount();
        expect(remaining, greaterThan(0), reason: '重新登录后还要补传');
      } finally {
        await server.close(force: true);
      }
    });
  });

  group('设备撤销', () {
    test('被撤销设备进入需要重新登录，但本地数据保留', () async {
      final FakePetLifeServer server = await FakePetLifeServer.start();
      try {
        await buildEngine();
        await seedSegment('segment-1');
        await api.signIn(
          baseUrl: server.baseUrl,
          email: 'tester@example.com',
          password: 'password-1234',
          registerInsteadOfLogin: false,
        );
        await producer.enqueueHistory();

        server.deviceRevoked = true;
        await engine.syncNow();

        expect(engine.status, SyncStatus.needsReauthentication);
        expect(api.needsReauthentication, isTrue);
        expect(credentials.keys, isEmpty, reason: '被撤销后应清理本地令牌');
        expect(await outbox.pendingCount(), greaterThan(0),
            reason: '待同步数据必须保留（本地采集不停）');
        // 本地活动记录一条不少
        final List<Map<String, Object?>> rows =
            await db.raw.query(DbSchema.tableActivitySegments);
        expect(rows, hasLength(1));
      } finally {
        await server.close(force: true);
      }
    });
  });

  group('离线与失败重试', () {
    test('服务端不可达 → waitingForNetwork，数据保留，并安排重试', () async {
      final FakePetLifeServer server = await FakePetLifeServer.start();
      final String baseUrl = server.baseUrl;
      await buildEngine();
      await seedSegment('segment-1');
      await api.signIn(
        baseUrl: baseUrl,
        email: 'tester@example.com',
        password: 'password-1234',
        registerInsteadOfLogin: false,
      );
      await producer.enqueueHistory();

      // 关掉服务端 = 网络中断
      await server.close(force: true);

      final int pendingBefore = await outbox.pendingCount();
      await engine.syncNow();

      expect(engine.status, SyncStatus.waitingForNetwork);
      expect(engine.consecutiveFailures, greaterThanOrEqualTo(1));
      expect(engine.nextRetryAt, isNotNull, reason: '应当安排退避重试');
      expect(await outbox.pendingCount(), pendingBefore,
          reason: '网络失败绝不能丢数据');

      // 本地采集与桌宠不受影响：新增记录照常写入
      await seedSegment('segment-2');
      expect((await db.raw.query(DbSchema.tableActivitySegments)), hasLength(2));
    });

    test('服务端 5xx → 状态 failed，但同样保留数据并重试', () async {
      final FakePetLifeServer server = await FakePetLifeServer.start();
      try {
        await buildEngine();
        await seedSegment('segment-1');
        await api.signIn(
          baseUrl: server.baseUrl,
          email: 'tester@example.com',
          password: 'password-1234',
          registerInsteadOfLogin: false,
        );
        await producer.enqueueHistory();

        server.forcedPushStatus = 500;
        await engine.syncNow();

        expect(engine.status, SyncStatus.failed);
        expect(engine.nextRetryAt, isNotNull);
        expect(await outbox.pendingCount(), greaterThan(0));
        expect(engine.lastError, isNotNull);
      } finally {
        await server.close(force: true);
      }
    });

    test('网络恢复后自动继续同步（退避被解除）', () async {
      final FakePetLifeServer server = await FakePetLifeServer.start();
      try {
        await buildEngine();
        await seedSegment('segment-1');
        await api.signIn(
          baseUrl: server.baseUrl,
          email: 'tester@example.com',
          password: 'password-1234',
          registerInsteadOfLogin: false,
        );
        await producer.enqueueHistory();

        server.forcedPushStatus = 503;
        await engine.syncNow();
        expect(engine.consecutiveFailures, greaterThanOrEqualTo(1));

        // 服务端恢复
        server.forcedPushStatus = null;
        await engine.onNetworkRestored();

        expect(engine.status, SyncStatus.success);
        expect(engine.pendingCount, 0);
        expect(engine.consecutiveFailures, 0);
      } finally {
        await server.close(force: true);
      }
    });

    test('批量超过服务端上限时按 200 条拆批', () async {
      final FakePetLifeServer server = await FakePetLifeServer.start();
      try {
        await buildEngine();
        for (int i = 0; i < 205; i++) {
          await seedSegment('segment-$i');
        }
        await api.signIn(
          baseUrl: server.baseUrl,
          email: 'tester@example.com',
          password: 'password-1234',
          registerInsteadOfLogin: false,
        );
        await engine.onSignedIn();

        expect(server.receivedPushes, isNotEmpty);
        for (final Map<String, Object?> push in server.receivedPushes) {
          final int count =
              (push['activity_segments'] as List<Object?>? ?? const <Object?>[]).length;
          expect(count, lessThanOrEqualTo(SyncConfig.maxBatchSize));
        }
        expect(engine.pendingCount, 0);
        expect(server.storedRecords.length, 205);
      } finally {
        await server.close(force: true);
      }
    });
  });

  group('退出前快速同步', () {
    test('服务端很慢时也不会长时间阻塞退出', () async {
      final FakePetLifeServer server = await FakePetLifeServer.start();
      try {
        await buildEngine();
        await seedSegment('segment-1');
        await api.signIn(
          baseUrl: server.baseUrl,
          email: 'tester@example.com',
          password: 'password-1234',
          registerInsteadOfLogin: false,
        );
        await producer.enqueueHistory();

        // 让服务端响应远慢于退出超时（5 秒）
        server.pushDelayMs = 20000;

        final Stopwatch watch = Stopwatch()..start();
        await engine.syncOnShutdown();
        watch.stop();

        expect(watch.elapsed, lessThan(const Duration(seconds: 8)),
            reason: '退出前同步必须有严格超时，不能卡住退出');
        // 数据仍在，下次启动继续传
        expect(await outbox.pendingCount(), greaterThan(0));
      } finally {
        await server.close(force: true);
      }
    });
  });

  group('退出登录', () {
    test('只清理认证信息，保留本地记录与待同步队列', () async {
      final FakePetLifeServer server = await FakePetLifeServer.start();
      try {
        await buildEngine();
        await seedSegment('segment-1');
        await api.signIn(
          baseUrl: server.baseUrl,
          email: 'tester@example.com',
          password: 'password-1234',
          registerInsteadOfLogin: false,
        );
        // 先让一条记录处于待同步状态
        await producer.enqueueHistory();
        server.forcedPushStatus = 500;
        await engine.syncNow();
        expect(await outbox.pendingCount(), greaterThan(0));

        await api.signOut();
        await engine.onSignedOut();

        expect(engine.status, SyncStatus.signedOut);
        expect(api.isSignedIn, isFalse);
        expect(credentials.keys, isEmpty, reason: '退出登录必须删除令牌');
        expect(await outbox.pendingCount(), greaterThan(0),
            reason: '待同步数据要留到下次登录后继续传');
        expect(await db.raw.query(DbSchema.tableActivitySegments), hasLength(1),
            reason: '退出登录不得删除本地使用记录');
      } finally {
        await server.close(force: true);
      }
    });

    test('退出登录时会尽力通知服务端注销', () async {
      final FakePetLifeServer server = await FakePetLifeServer.start();
      try {
        await buildEngine();
        await api.signIn(
          baseUrl: server.baseUrl,
          email: 'tester@example.com',
          password: 'password-1234',
          registerInsteadOfLogin: false,
        );
        await api.signOut();
        expect(server.logoutCount, greaterThanOrEqualTo(1));
      } finally {
        await server.close(force: true);
      }
    });
  });

  // ---------------------------------------------------------------------------
  // 增量 C2（需求 §8.1）：同步摘要 —— 轮盘「立即同步」的用户文案来源。
  // ---------------------------------------------------------------------------
  group('增量 C2：同步摘要', () {
    test('从未同步过时摘要为「没有需要同步的数据」', () async {
      await buildEngine();
      expect(engine.lastUploadedCount, 0);
      expect(engine.lastDownloadedCount, 0);
      expect(engine.lastRunSummary, '没有需要同步的数据');
    });

    test('上传 2 条历史记录后摘要含「上传 2 条」', () async {
      final FakePetLifeServer server = await FakePetLifeServer.start();
      try {
        await buildEngine();
        await seedSegment('segment-1');
        await seedSegment('segment-2');

        await api.signIn(
          baseUrl: server.baseUrl,
          email: 'tester@example.com',
          password: 'password-1234',
          registerInsteadOfLogin: false,
        );
        await engine.onSignedIn();

        expect(engine.status, SyncStatus.success);
        expect(engine.lastUploadedCount, 2);
        expect(engine.lastRunSummary, contains('上传 2 条'));
      } finally {
        await server.close(force: true);
      }
    });

    test('每轮同步都会重置摘要素数（不会跨轮累加）', () async {
      final FakePetLifeServer server = await FakePetLifeServer.start();
      try {
        await buildEngine();
        await seedSegment('segment-1');
        await api.signIn(
          baseUrl: server.baseUrl,
          email: 'tester@example.com',
          password: 'password-1234',
          registerInsteadOfLogin: false,
        );
        await engine.onSignedIn();
        expect(engine.lastUploadedCount, 1);

        // 第二轮：没有新的本地记录 → 上传条数必须归零（不是 1+0=1 的历史残留）。
        await engine.syncNow(manual: true);
        expect(engine.lastUploadedCount, 0);
      } finally {
        await server.close(force: true);
      }
    });
  });
}

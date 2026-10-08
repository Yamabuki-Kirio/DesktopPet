import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:petlife/core/constants.dart';
import 'package:petlife/database/app_database.dart';
import 'package:petlife/database/dao/account_session_dao.dart';
import 'package:petlife/database/dao/sync_outbox_dao.dart';
import 'package:petlife/database/dao/sync_state_dao.dart';
import 'package:petlife/database/schema.dart';
import 'package:petlife/sync/api_client.dart';
import 'package:petlife/sync/authenticated_api.dart';
import 'package:petlife/sync/credential_store.dart';
import 'package:petlife/sync/device_identity.dart';
import 'package:petlife/sync/models/api_key_models.dart';
import 'package:petlife/sync/models/sync_models.dart';
import 'package:petlife/sync/outbox_producer.dart';
import 'package:petlife/sync/sync_engine.dart';
import 'package:petlife/sync/sync_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fake_petlife_server.dart';
import 'support/sqlite_test_bootstrap.dart';

/// 重新登录竞态（认证 generation / 会话代次）的确定性回归测试。
///
/// 复现的是这个真实缺陷：
/// 页面已经处于「需要重新登录」，用户重新登录成功后立刻又被打回
/// 「需要重新登录」，随后任何操作都报「登录凭据已失效：尚未登录」。
///
/// 成因：上一个会话的 push / pull / refresh 还在飞，它们**随后**返回 401，
/// 而当时的实现会无条件清令牌 —— 连同刚登录得到的新令牌一起删掉。
///
/// 这里不靠 sleep 猜时序，而是用假服务端把旧请求**按请求挂住**
/// （服务端已收到、但还没回响应），等重新登录完成后再放行，
/// 从而让"旧响应晚于新登录到达"这件事变成确定性的。
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
  bool setupDone = false;

  setUpAll(() {
    tmp = Directory.systemTemp.createTempSync('petlife_relogin_race');
    // 需要真实 HTTP（连本地假服务端）：清掉测试框架对 HttpClient 的替身
    HttpOverrides.global = null;
  });

  tearDownAll(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  setUp(() async {
    await AppDatabase.close();
    db = await AppDatabase.open(
      path: p.join(tmp.path, 'race_${DateTime.now().microsecondsSinceEpoch}.db'),
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
      backoffSteps: const <Duration>[
        Duration(milliseconds: 40),
        Duration(milliseconds: 80),
      ],
      periodicInterval: const Duration(hours: 1),
    );
    setupDone = true;
  });

  tearDown(() async {
    if (!setupDone) return;
    setupDone = false;
    await engine.stop();
    engine.dispose();
    api.dispose();
    await AppDatabase.close();
  });

  // --- 助手 -----------------------------------------------------------------

  /// 轮询等待条件成立（真实时间）。
  Future<void> until(
    bool Function() predicate, {
    String reason = '条件未成立',
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final DateTime deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (predicate()) return;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    throw StateError('等待超时：$reason');
  }

  Future<void> signUp(String baseUrl) => api.signIn(
        baseUrl: baseUrl,
        email: 'race@example.com',
        password: 'password-1234',
        registerInsteadOfLogin: true,
      );

  Future<void> signInAgain(String baseUrl) => api.signIn(
        baseUrl: baseUrl,
        email: 'race@example.com',
        password: 'password-1234',
        registerInsteadOfLogin: false,
      );

  /// 走完整认证链路的一次同步请求（push），用于构造"在途旧请求"。
  Future<void> syncRequest() => api.send(
        (String token, String deviceId) => api.push(
          accessToken: token,
          deviceId: deviceId,
          records: const <SyncEntityType, List<Map<String, Object?>>>{},
        ),
      );

  /// 让服务端认为"旧令牌已失效"：下一次请求带旧令牌就会拿到 401。
  void invalidateServerSideToken(FakePetLifeServer server) {
    server.requireFreshAccessToken = true;
    server.accessTokenGeneration = 99;
  }

  /// 凭据存储里的条目名（登录后只有一个）。
  String credentialReference() => credentials.keys.single;

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

  // ---------------------------------------------------------------------------
  // 需求 5：旧请求的 401 不得清理后来登录得到的新令牌
  // ---------------------------------------------------------------------------

  test('旧会话在途请求的 401 不得清理新登录令牌，新令牌仍可用', () async {
    final FakePetLifeServer server = await FakePetLifeServer.start();
    try {
      await signUp(server.baseUrl);

      // 1) 旧会话发起同步请求，并让它在服务端**保持未完成**
      server.pushDelayMs = 600;
      invalidateServerSideToken(server);
      final Future<void> oldRequest = syncRequest();
      await until(() => server.pushCount == 1, reason: '旧请求应已到达服务端并挂住');

      // 2) 用户重新登录，得到一组新令牌
      await signInAgain(server.baseUrl);
      final String newAccessToken = await api.ensureAccessToken();
      final String storedAfterRelogin = await credentials.read(credentialReference()) ?? '';
      expect(TokenPair.decode(storedAfterRelogin)?.accessToken, newAccessToken);
      expect(api.isSignedIn, isTrue, reason: '重新登录后应当是已登录');

      // 3) 旧请求此刻才返回 401
      await expectLater(oldRequest, throwsA(isA<ApiException>()));

      // 4) 新会话仍然有效
      expect(api.isSignedIn, isTrue, reason: '旧请求的 401 不得把新会话打回未登录');
      expect(api.needsReauthentication, isFalse);

      // 5) 新令牌没有被删除
      expect(credentials.keys, isNotEmpty, reason: '新令牌不得被旧请求删除');
      expect(
        await credentials.read(credentialReference()),
        storedAfterRelogin,
        reason: '凭据存储里的令牌不得被改写',
      );
      expect(await api.ensureAccessToken(), newAccessToken);

      // 6) 新令牌可以真正用起来：AI 数据访问列表能成功加载
      server.pushDelayMs = 0;
      final int listBefore = server.apiKeyListRequests;
      final List<ApiKeySummary> keys = await api.listApiKeys();
      expect(server.apiKeyListRequests, listBefore + 1);
      expect(keys, isEmpty, reason: '该账户还没生成过密钥，空列表也是成功加载');
    } finally {
      await server.close(force: true);
    }
  });

  // ---------------------------------------------------------------------------
  // 需求 6：旧 Refresh 不得覆盖新令牌 / 不得把新会话判为失效
  // ---------------------------------------------------------------------------

  test('旧 Refresh 晚于新登录返回：不得覆盖新登录令牌', () async {
    final FakePetLifeServer server = await FakePetLifeServer.start();
    try {
      await signUp(server.baseUrl);

      // 旧令牌在服务端失效 → 旧请求 401 → 触发刷新（刷新的响应被挂住）
      invalidateServerSideToken(server);
      server.refreshDelayMs = 600;
      final Future<void> oldRequest = syncRequest();
      await until(() => server.refreshCount == 1, reason: '旧 Refresh 应已发出并挂住');

      // 重新登录（此时旧 Refresh 还在飞）
      await signInAgain(server.baseUrl);
      final String storedAfterRelogin = await credentials.read(credentialReference()) ?? '';

      // 放行旧 Refresh：它必须被丢弃
      await expectLater(oldRequest, throwsA(isA<ApiException>()));

      expect(
        await credentials.read(credentialReference()),
        storedAfterRelogin,
        reason: '旧 Refresh 的结果绝不能覆盖新登录令牌',
      );
      expect(api.isSignedIn, isTrue);
      expect(api.needsReauthentication, isFalse);

      server.pushDelayMs = 0;
      await api.listApiKeys(); // 新令牌仍可用
    } finally {
      await server.close(force: true);
    }
  });

  test('旧 Refresh 晚于新登录返回且失败：不得把新会话标记为需要重新登录', () async {
    final FakePetLifeServer server = await FakePetLifeServer.start();
    try {
      await signUp(server.baseUrl);

      invalidateServerSideToken(server);
      server.refreshDelayMs = 600;
      server.rejectRefresh = true; // 旧 Refresh 会失败
      final Future<void> oldRequest = syncRequest();
      await until(() => server.refreshCount == 1, reason: '旧 Refresh 应已发出并挂住');

      await signInAgain(server.baseUrl);
      final String storedAfterRelogin = await credentials.read(credentialReference()) ?? '';

      await expectLater(oldRequest, throwsA(isA<ApiException>()));

      expect(api.needsReauthentication, isFalse, reason: '旧会话的刷新失败不得影响新会话');
      expect(api.isSignedIn, isTrue);
      expect(credentials.keys, isNotEmpty);
      expect(await credentials.read(credentialReference()), storedAfterRelogin);
    } finally {
      await server.close(force: true);
    }
  });

  // ---------------------------------------------------------------------------
  // 反向保护：真正属于当前会话的失效仍必须进入「需要重新登录」
  // ---------------------------------------------------------------------------

  test('当前会话的 401 + Refresh 失败仍必须进入需要重新登录', () async {
    final FakePetLifeServer server = await FakePetLifeServer.start();
    try {
      await signUp(server.baseUrl);

      invalidateServerSideToken(server);
      server.rejectRefresh = true;

      final Future<void> request = syncRequest();
      await expectLater(request, throwsA(isA<ApiException>()));

      expect(api.needsReauthentication, isTrue, reason: '当前会话确实失效，必须提示重新登录');
      expect(api.isSignedIn, isFalse);
      expect(credentials.keys, isEmpty, reason: '失效后应清理本地令牌');
      expect(server.refreshCount, 1, reason: '刷新只允许尝试一次，不得无限刷新');
    } finally {
      await server.close(force: true);
    }
  });

  // ---------------------------------------------------------------------------
  // 需求 7 / 8：引擎不得替 AuthenticatedApi 再清一次令牌；旧任务不得影响新会话
  // ---------------------------------------------------------------------------

  test('旧会话任务的认证失败不得经引擎把新登录判为失效', () async {
    final FakePetLifeServer server = await FakePetLifeServer.start();
    try {
      await seedSegment('seg-old');
      await signUp(server.baseUrl);
      await producer.enqueueHistory();

      server.pushDelayMs = 600;
      invalidateServerSideToken(server);
      server.rejectRefresh = true; // 旧会话此刻连刷新也是失败的
      final Future<void> oldSync = engine.syncNow(trigger: 'old');
      await until(() => server.pushCount == 1, reason: '旧同步应已发出并挂住');

      // 重新登录，但**不**调用 onSignedIn（模拟"页面还没开始首次同步"）
      await signInAgain(server.baseUrl);

      await oldSync;

      expect(api.isSignedIn, isTrue, reason: '引擎不得替旧会话再清一次令牌');
      expect(api.needsReauthentication, isFalse);
      expect(credentials.keys, isNotEmpty);
      expect(engine.status, isNot(SyncStatus.needsReauthentication));
    } finally {
      await server.close(force: true);
    }
  });

  test('登录成功但首次同步失败：onSignedIn 不抛异常且登录状态保持有效', () async {
    final FakePetLifeServer server = await FakePetLifeServer.start();
    try {
      await seedSegment('seg-first-sync');
      await signUp(server.baseUrl);
      final String storedAfterLogin = await credentials.read(credentialReference()) ?? '';

      // 登录成功之后网络才断：首次同步必然失败（但这不是"登录失败"）
      await server.close(force: true);
      await engine.onSignedIn(); // 不得抛异常

      expect(api.isSignedIn, isTrue, reason: '首次同步失败不得影响登录状态');
      expect(api.needsReauthentication, isFalse);
      expect(
        await credentials.read(credentialReference()),
        storedAfterLogin,
        reason: '令牌不得被动过',
      );
      expect(engine.status, SyncStatus.waitingForNetwork);
      expect(engine.lastError, isNotNull, reason: '页面据此显示「已登录，但首次同步失败：…」');
      expect(await outbox.pendingCount(), greaterThan(0), reason: '数据保留，稍后重试');
    } finally {
      await server.close(force: true);
    }
  });

  test('登录时存在旧 inFlight 任务：新会话仍能完成自己的首次同步', () async {
    final FakePetLifeServer server = await FakePetLifeServer.start();
    try {
      await seedSegment('seg-new');
      await signUp(server.baseUrl);
      await producer.enqueueHistory();

      // 旧会话的同步被挂住
      server.pushDelayMs = 600;
      invalidateServerSideToken(server);
      final Future<void> oldSync = engine.syncNow(trigger: 'old');
      await until(() => server.pushCount == 1, reason: '旧同步应已发出并挂住');

      // 重新登录：服务端会发一组新令牌（accessTokenGeneration 从 99 递增），
      // 因此新会话的请求是有效的
      await signInAgain(server.baseUrl);

      // 新会话的首次同步不得复用旧任务，必须真的跑起来并成功
      await engine.onSignedIn();

      await oldSync; // 旧任务的 401 此刻才到，且必须被忽略

      expect(engine.status, SyncStatus.success, reason: '新会话的首次同步应成功');
      expect(server.pushCount, greaterThanOrEqualTo(2), reason: '应当真的发出了新会话的同步请求');
      expect(api.isSignedIn, isTrue);
      expect(api.needsReauthentication, isFalse);
      expect(await outbox.pendingCount(), 0, reason: '新会话应已把待同步数据传完');
    } finally {
      await server.close(force: true);
    }
  });
}

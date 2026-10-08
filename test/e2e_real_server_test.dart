import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:petlife/core/constants.dart';
import 'package:petlife/database/app_database.dart';
import 'package:petlife/database/dao/account_session_dao.dart';
import 'package:petlife/database/dao/sync_outbox_dao.dart';
import 'package:petlife/database/dao/sync_state_dao.dart';
import 'package:petlife/database/schema.dart';
import 'package:petlife/platform/windows/windows_credential_store_factory.dart';
import 'package:petlife/sync/api_client.dart';
import 'package:petlife/sync/authenticated_api.dart';
import 'package:petlife/sync/credential_store.dart';
import 'package:petlife/sync/device_identity.dart';
import 'package:petlife/sync/models/sync_models.dart';
import 'package:petlife/sync/outbox_producer.dart';
import 'package:petlife/sync/sync_engine.dart';
import 'package:petlife/sync/sync_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/sqlite_test_bootstrap.dart';

/// **真实联调**（需求「九、真实联调」）：客户端 ↔ 真实本地服务端。
///
/// 与 `sync_engine_test.dart` 的区别：那个用**假服务端**验证引擎逻辑；
/// 这个连**真的 uvicorn + 真的 FastAPI 服务端**，用来验证
/// 「客户端确实能和我们的服务端互通」——包括真实的 JWT、真实的 Argon2、
/// 真实的 push 校验与统计查询。
///
/// 为什么分成多个 stage：需求要求覆盖「断网 → 恢复 → 补传 → 撤销」，
/// 这需要**在两次客户端运行之间把服务端起停**，而单个测试进程做不到。
/// 因此每个 stage 是一次独立的 `flutter test` 调用，通过同一个固定路径的
/// SQLite 文件共享状态（模拟真实的"关掉客户端再打开"）。
///
/// 用法（由 `tools/e2e_client_sync.ps1` 编排）：
///
/// ```
/// $env:PETLIFE_E2E_STAGE='online'    # 注册/登录/绑定设备/上传/校验/重复上传
/// $env:PETLIFE_E2E_STAGE='offline'   # 服务端已停机：本地照常采集，同步失败但数据保留
/// $env:PETLIFE_E2E_STAGE='recover'   # 服务端已恢复：自动补传
/// $env:PETLIFE_E2E_STAGE='revoked'   # 设备被撤销：进入需要重新登录，本地采集不停
/// $env:PETLIFE_E2E_STAGE='signout'   # 退出登录：凭据被删除，本地数据保留
/// ```
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SqliteTestBootstrap.ensureLoaded();
  // 需要真实 HTTP：清掉测试框架对 HttpClient 的替身
  HttpOverrides.global = null;

  const String owner = AppConstants.localOwnerId;
  const String localDevice = AppConstants.localDeviceId;
  const int t0 = 1767225600000;

  final String? stage = Platform.environment['PETLIFE_E2E_STAGE'];
  final String baseUrl =
      Platform.environment['PETLIFE_E2E_BASE_URL'] ?? 'http://127.0.0.1:8010';
  final String email =
      Platform.environment['PETLIFE_E2E_EMAIL'] ?? 'e2e-client@example.com';
  const String password = 'E2e-client-password-1';

  final Directory workDir = Directory(p.join(Directory.current.path, 'build', 'e2e'));
  final String dbPath = p.join(workDir.path, 'e2e.db');

  late AppDatabase db;
  late SyncOutboxDao outbox;
  late SyncStateDao stateDao;
  late OutboxProducer producer;
  late CredentialStore credentials;
  late AuthenticatedApi api;
  late SyncEngine engine;

  /// 生成一个**合法 UUID** 作为本地记录 id。
  ///
  /// 必须是真的 UUID：服务端 `ActivitySegmentIn.id` 是 `uuid.UUID`，
  /// 用 "e2e-segment-1" 这种字符串会被 422 拒绝（这一点已由真实联调验证过）。
  /// 真实运行时的 id 由 `Ids.segment()` 生成，同样是合法 UUID。
  String seg(int n) =>
      'e2e00000-0000-4000-8000-${n.toString().padLeft(12, '0')}';

  Future<void> boot() async {
    workDir.createSync(recursive: true);
    await AppDatabase.close();
    db = await AppDatabase.open(path: dbPath);
    outbox = SyncOutboxDao(db.raw);
    stateDao = SyncStateDao(db.raw);
    producer = OutboxProducer(db: db, outbox: outbox, ownerId: owner);
    // Phase 4A：凭据工厂已按平台拆分，本用例跑在 Windows 上，
    // 因此显式使用 Windows 工厂（真实凭据后端里写一条测试条目）。
    credentials = await const WindowsCredentialStoreFactory().create(
      fallbackDirectory: Directory(p.join(workDir.path, 'credentials')),
    );
    api = AuthenticatedApi(
      credentialStore: credentials,
      accountSessionDao: AccountSessionDao(db.raw),
      deviceIdentity: DeviceIdentity(db),
      preferences: SyncPreferences(db),
    );
    await api.load();
    engine = SyncEngine(
      api: api,
      outboxDao: outbox,
      stateDao: stateDao,
      producer: producer,
      preferences: SyncPreferences(db),
      backoffSteps: const <Duration>[Duration(milliseconds: 200)],
      periodicInterval: const Duration(hours: 1),
    );
  }

  Future<void> shutdown() async {
    engine.dispose();
    api.dispose();
    await AppDatabase.close();
  }

  /// 往本地写一条活动段（模拟采集产生了新记录）。
  Future<void> writeLocalSegment(String id, int activeSeconds, {String appKey = 'code'}) async {
    final int started = DateTime.now().millisecondsSinceEpoch - activeSeconds * 1000;
    await db.raw.insert(
      DbSchema.tableActivitySegments,
      <String, Object?>{
        'id': id,
        'owner_id': owner,
        'device_local_id': localDevice,
        'app_key': appKey,
        'app_name': appKey,
        'process_name': '$appKey.exe',
        'started_at': started,
        'ended_at': started + activeSeconds * 1000,
        'active_seconds': activeSeconds,
        'end_reason': 'foreground_changed',
        'sync_status': 'pending',
        'created_at': started,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await db.raw.insert(
      DbSchema.tableApplications,
      <String, Object?>{
        'app_key': appKey,
        'display_name': 'Visual Studio Code',
        'process_name': '$appKey.exe',
        'executable_path': r'C:\Apps\Code.exe',
        'category': 'development',
        'user_overridden': 0,
        'excluded': 0,
        'first_seen_at': t0,
        'last_seen_at': started,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    // 采集层在真实运行时就是通过 sink 入队的，这里显式做同样的事
    await producer.enqueueSegment(id);
    await producer.enqueueApplication(appKey);
  }

  Future<bool> serverReachable() async {
    try {
      final HttpClient client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 3);
      final HttpClientRequest request = await client.getUrl(Uri.parse('$baseUrl/health'));
      final HttpClientResponse response = await request.close();
      await response.drain<void>();
      client.close(force: true);
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  test('真实联调 stage=$stage', () async {
    if (stage == null || stage.isEmpty) {
      markTestSkipped('未设置 PETLIFE_E2E_STAGE，跳过真实联调（默认测试套件不依赖外部服务端）');
      return;
    }

    await boot();
    addTearDown(shutdown);

    switch (stage) {
      // ---------------------------------------------------------------------
      case 'online':
        {
          expect(await serverReachable(), isTrue, reason: '服务端应当已在 $baseUrl 运行');

          // 1) 注册（或已存在则登录）
          try {
            await api.signIn(
              baseUrl: baseUrl,
              email: email,
              password: password,
              registerInsteadOfLogin: true,
            );
            // ignore: avoid_print
            print('[e2e] 注册成功');
          } on ApiException catch (e) {
            if (e.errorCode != 'email_taken') rethrow;
            await api.signIn(
              baseUrl: baseUrl,
              email: email,
              password: password,
              registerInsteadOfLogin: false,
            );
            // ignore: avoid_print
            print('[e2e] 账户已存在，改为登录');
          }

          expect(api.isSignedIn, isTrue);
          expect(api.lastAccount?.deviceServerId, isNotNull, reason: '登录后应完成设备注册');
          // ignore: avoid_print
          print('[e2e] 已登录 ${api.lastAccount?.email}，设备=${api.deviceServerId}');
          // ignore: avoid_print
          print('[e2e] 凭据后端=${credentials.backendName}');

          // 2) 产生本地活动记录并入队
          await writeLocalSegment(seg(1), 300);
          await writeLocalSegment(seg(2), 120, appKey: 'chrome');

          // 3) 立即同步
          await engine.syncNow(manual: true);
          if (engine.status != SyncStatus.success) {
            // ignore: avoid_print
            print('[e2e] 同步失败详情：status=${engine.status.labelZh}，'
                'lastError=${engine.lastError}，'
                'rejected=${engine.lastRejectedNote}，'
                'pending=${await outbox.pendingCount()}');
          }
          expect(engine.status, SyncStatus.success, reason: '同步应当成功');
          expect(engine.pendingCount, 0, reason: '上传后队列应清空');
          // ignore: avoid_print
          print('[e2e] 首次同步完成，待同步=0');

          // 4) 从服务端查询确认数据一致
          final Map<String, Object?> summary = await api.stats(endpoint: 'summary');
          expect(summary['device_count'], greaterThanOrEqualTo(1));
          final Map<String, Object?> apps = await api.stats(endpoint: 'apps');
          final List<Object?> items = (apps['items'] as List<Object?>?) ?? const <Object?>[];
          expect(items, isNotEmpty, reason: '服务端应当能查到应用使用记录');
          // ignore: avoid_print
          print('[e2e] 服务端统计：设备数=${summary['device_count']}，'
              '应用数=${items.length}，应用使用时间=${apps['total_app_active_seconds']}s');

          // 5) 重复同步：不得产生重复统计
          final Object? activeBefore = summary['app_active_seconds'];
          await producer.enqueueHistory();
          await engine.syncNow(manual: true);
          final Map<String, Object?> summaryAfter = await api.stats(endpoint: 'summary');
          expect(summaryAfter['app_active_seconds'], activeBefore,
              reason: '重复上传不得让服务端统计变多');
          // ignore: avoid_print
          print('[e2e] 重复同步后统计未变：app_active=${summaryAfter['app_active_seconds']}s');
        }

      // ---------------------------------------------------------------------
      case 'offline':
        {
          expect(api.isSignedIn, isTrue, reason: '需要先跑 online 阶段');
          expect(await serverReachable(), isFalse, reason: '本阶段服务端应当已停机');

          await writeLocalSegment(seg(3), 240);
          await writeLocalSegment(seg(4), 180);

          final int pendingBefore = await outbox.pendingCount();
          await engine.syncNow();

          expect(engine.status, SyncStatus.waitingForNetwork);
          expect(engine.nextRetryAt, isNotNull, reason: '应安排退避重试');
          expect(await outbox.pendingCount(), pendingBefore,
              reason: '网络失败绝不能丢数据');
          // 本地记录照常写入（采集不受影响）
          final List<Map<String, Object?>> rows =
              await db.raw.query(DbSchema.tableActivitySegments);
          expect(rows.length, greaterThanOrEqualTo(4));
          // ignore: avoid_print
          print('[e2e] 离线正常：状态=${engine.status.labelZh}，'
              '待同步=$pendingBefore 条，本地活动段=${rows.length} 条');
        }

      // ---------------------------------------------------------------------
      case 'recover':
        {
          expect(await serverReachable(), isTrue, reason: '本阶段服务端应当已恢复');
          final int pendingBefore = await outbox.pendingCount();
          expect(pendingBefore, greaterThan(0), reason: '应当还有离线期间的积压');

          await engine.onNetworkRestored();

          expect(engine.status, SyncStatus.success, reason: '网络恢复后应自动补传成功');
          expect(engine.pendingCount, 0);
          // ignore: avoid_print
          print('[e2e] 网络恢复补传成功：$pendingBefore 条 → 0 条');

          final Map<String, Object?> summary = await api.stats(endpoint: 'summary');
          // ignore: avoid_print
          print('[e2e] 服务端统计：设备数=${summary['device_count']}，'
              '活跃=${summary['active_seconds']}s，应用使用=${summary['app_active_seconds']}s');
        }

      // ---------------------------------------------------------------------
      case 'revoked':
        {
          expect(await serverReachable(), isTrue);
          final String? currentDevice = api.deviceServerId;
          expect(currentDevice, isNotNull);

          // 另起一个会话（模拟"在别处登录后撤销这台设备"）
          final ApiClient admin = ApiClient(baseUrl: baseUrl);
          addTearDown(admin.close);
          final AuthResult adminAuth = await admin.login(
            email: email,
            password: password,
          );
          await admin.revokeDevice(
            accessToken: adminAuth.tokens.accessToken,
            deviceId: currentDevice!,
          );
          // ignore: avoid_print
          print('[e2e] 已从另一会话撤销设备 $currentDevice');

          // 被撤销后同步必须停止并提示重新登录
          await writeLocalSegment(seg(5), 60);
          await engine.syncNow();

          expect(engine.status, SyncStatus.needsReauthentication);
          expect(api.needsReauthentication, isTrue);
          // 直接问凭据后端要：真实后端（Credential Manager / DPAPI）里必须已经没有了
          expect(await credentials.read('PetLife:account'), isNull,
              reason: '被撤销后应清理本地令牌');
          // 本地采集继续：数据都还在
          final List<Map<String, Object?>> rows =
              await db.raw.query(DbSchema.tableActivitySegments);
          expect(rows, isNotEmpty);
          expect(await outbox.pendingCount(), greaterThan(0),
              reason: '待同步数据必须保留，等重新登录后补传');
          // ignore: avoid_print
          print('[e2e] 设备撤销后：状态=${engine.status.labelZh}，'
              '本地活动段=${rows.length} 条（采集未停止），待同步=${engine.pendingCount} 条');
        }

      // ---------------------------------------------------------------------
      case 'signout':
        {
          expect(await serverReachable(), isTrue);
          // 上一阶段（设备撤销）会清掉令牌，这里按真实流程重新登录一次
          if (!api.isSignedIn) {
            await api.signIn(
              baseUrl: baseUrl,
              email: email,
              password: password,
              registerInsteadOfLogin: false,
            );
            // ignore: avoid_print
            print('[e2e] 重新登录以验证退出登录流程');
          }

          await writeLocalSegment(seg(6), 30);
          final int pendingBefore = await outbox.pendingCount();

          await api.signOut();
          await engine.onSignedOut();

          expect(api.isSignedIn, isFalse);
          expect(engine.status, SyncStatus.signedOut);
          expect(await credentials.read('PetLife:account'), isNull,
              reason: '退出登录必须删除令牌');
          expect(await outbox.pendingCount(), pendingBefore,
              reason: '待同步数据要留到下次登录');
          final List<Map<String, Object?>> rows =
              await db.raw.query(DbSchema.tableActivitySegments);
          expect(rows, isNotEmpty, reason: '退出登录不得删除本地使用记录');
          // ignore: avoid_print
          print('[e2e] 退出登录完成：凭据已删除，'
              '本地活动段=${rows.length} 条，待同步=$pendingBefore 条仍保留');
        }

      default:
        fail('未知 stage: $stage');
    }
  });
}

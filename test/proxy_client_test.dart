import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:petlife/database/app_database.dart';
import 'package:petlife/database/dao/account_session_dao.dart';
import 'package:petlife/sync/api_client.dart';
import 'package:petlife/sync/authenticated_api.dart';
import 'package:petlife/sync/credential_store.dart';
import 'package:petlife/sync/device_identity.dart';
import 'package:petlife/sync/models/sync_models.dart';
import 'package:petlife/sync/proxy/proxy_models.dart';
import 'package:petlife/sync/proxy/proxy_probe.dart';
import 'package:petlife/sync/proxy/proxy_resolver.dart';
import 'package:petlife/sync/proxy/system_proxy.dart';
import 'package:petlife/sync/sync_preferences.dart';

import 'support/fake_http_proxy.dart';
import 'support/fake_petlife_server.dart';
import 'support/sqlite_test_bootstrap.dart';

/// 代理支持的**真实网络**测试：经本地假代理访问本地假服务端，
/// 以及 `ProxyProbe` 的分阶段诊断（407 / TLS 失败 / health 失败）。
///
/// 全程只连 127.0.0.1，不访问公网。
/// 注意：这里的代理决策都把 `bypassLocalhost` 设为 **false**，
/// 否则 127.0.0.1 会被 `<local>` 规则直接绕过，就测不到代理了。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SqliteTestBootstrap.ensureLoaded();
  // 需要真实 HTTP：清掉测试框架对 HttpClient 的替身
  HttpOverrides.global = null;

  late FakePetLifeServer server;
  late FakeHttpProxy proxy;
  late Directory tmp;

  setUpAll(() {
    tmp = Directory.systemTemp.createTempSync('petlife_proxy_client');
  });

  tearDownAll(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  setUp(() async {
    server = await FakePetLifeServer.start();
    proxy = await FakeHttpProxy.start();
  });

  tearDown(() async {
    await proxy.close();
    await server.close(force: true);
  });

  ProxyResolution resolutionOf(FakeHttpProxy p) => ProxyResolution.proxy(
    settings: ProxySettings(
      mode: ProxyMode.manualHttp,
      host: '127.0.0.1',
      port: p.port,
      bypassLocalhost: false,
    ),
    host: '127.0.0.1',
    port: p.port,
    sourceLabel: '测试用手动代理',
  );

  // ---------------------------------------------------------------------------

  group('ApiClient 经代理', () {
    test('注册/登录/刷新/设备/同步/统计/注销 全部走同一个代理', () async {
      final ApiClient client = ApiClient(
        baseUrl: server.baseUrl,
        proxyResolver: FixedProxyResolver(resolutionOf(proxy)),
      );
      addTearDown(client.close);

      // 每一步都带上下文：失败时能直接看出是**哪个请求**、服务端为什么 500。
      Future<void> step(String label, Future<void> Function() action) async {
        try {
          await action();
        } on ApiException catch (e) {
          fail('$label 失败：$e\n'
              '  服务端处理异常：${server.lastHandlerError ?? '<无>'}\n'
              '  代理已转发：${proxy.forwardTargets.join(', ')}\n'
              '  服务端已收到：${server.receivedPaths.join(', ')}');
        }
      }

      await step(
        '注册',
        () => client.register(
          email: 'a@example.com',
          password: 'password-123',
          displayName: 'A',
        ),
      );
      await step(
        '登录',
        () => client.login(email: 'a@example.com', password: 'password-123'),
      );
      await step('刷新令牌', () => client.refresh('refresh-1'));
      await step(
        '注册设备',
        () => client.registerDevice(
          accessToken: 'access-1',
          device: const DeviceRegistration(deviceLocalId: 'local-1', deviceName: '测试机'),
        ),
      );
      await step('设备列表', () => client.listDevices(accessToken: 'access-1'));
      await step(
        '同步上传',
        () => client.push(
          accessToken: 'access-1',
          deviceId: 'server-device-1',
          records: <SyncEntityType, List<Map<String, Object?>>>{},
        ),
      );
      await step(
        '同步拉取',
        () => client.pull(
          accessToken: 'access-1',
          deviceId: 'server-device-1',
          cursor: 0,
        ),
      );
      await step(
        '统计查询',
        () => client.stats(accessToken: 'access-1', endpoint: 'summary'),
      );
      await step('注销', () => client.logout(refreshToken: 'refresh-1'));

      expect(proxy.forwardTargets, hasLength(9),
          reason: '9 个请求都必须经代理转发，不能有任何一个直连');
      for (final String path in <String>[
        '/api/v1/auth/register',
        '/api/v1/auth/login',
        '/api/v1/auth/refresh',
        '/api/v1/devices/register',
        '/api/v1/devices',
        '/api/v1/sync/push',
        '/api/v1/sync/pull',
        '/api/v1/stats/summary',
        '/api/v1/auth/logout',
      ]) {
        expect(
          proxy.forwardTargets.any((String t) => t.contains(path)),
          isTrue,
          reason: '应当经代理请求 $path',
        );
      }

      // 服务端确实收到了 → 证明是真转发，而不是代理自己编的响应
      expect(server.lastHandlerError, isNull);
      expect(server.loginCount, 2);
      expect(server.refreshCount, 1);
      expect(server.registerDeviceCount, 1);
      expect(server.pushCount, 1);
      expect(server.pullCount, 1);
      expect(server.logoutCount, 1);
    });

    test('代理连接被拒绝 → proxyUnreachable（而不是笼统的网络错误）', () async {
      // 拿一个确定没有人监听的端口
      final ServerSocket spare = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final int deadPort = spare.port;
      await spare.close();

      final ApiClient client = ApiClient(
        baseUrl: server.baseUrl,
        connectTimeout: const Duration(seconds: 3),
        proxyResolver: FixedProxyResolver(
          ProxyResolution.proxy(
            settings: ProxySettings(
              mode: ProxyMode.manualHttp,
              host: '127.0.0.1',
              port: deadPort,
              bypassLocalhost: false,
            ),
            host: '127.0.0.1',
            port: deadPort,
            sourceLabel: '测试用死端口',
          ),
        ),
      );
      addTearDown(client.close);

      await expectLater(
        client.listDevices(accessToken: 'a'),
        throwsA(
          isA<ApiException>().having(
            (ApiException e) => e.kind,
            'kind',
            SyncFailureKind.proxyUnreachable,
          ),
        ),
      );
      expect(proxy.forwardTargets, isEmpty);
    });

    test('从不设置 badCertificateCallback（不绕过 TLS 校验）', () {
      final ApiClient client = ApiClient(
        baseUrl: server.baseUrl,
        proxyResolver: FixedProxyResolver(resolutionOf(proxy)),
      );
      addTearDown(client.close);

      expect(client.bypassesTlsCertificateValidation, isFalse);
      // 重建连接池之后依然不能有
      client.updateProxy(
        proxyResolver: FixedProxyResolver(resolutionOf(proxy)),
      );
      expect(client.bypassesTlsCertificateValidation, isFalse);
    });
  });

  // ---------------------------------------------------------------------------

  group('AuthenticatedApi 代理重配', () {
    test('代理配置变化 → 旧 HttpClient 被关闭并重建', () async {
      final String path = p.join(
        tmp.path,
        'reconf_${DateTime.now().microsecondsSinceEpoch}.db',
      );
      await AppDatabase.close();
      final AppDatabase db = await AppDatabase.open(path: path);
      addTearDown(() async {
        await AppDatabase.close();
      });

      final ProxySettings manualSettings = ProxySettings(
        mode: ProxyMode.manualHttp,
        host: '127.0.0.1',
        port: proxy.port,
        bypassLocalhost: false,
      );
      final ProxySettingsResolver resolver = ProxySettingsResolver(
        settings: manualSettings,
        systemReader: const StaticSystemProxyReader(
          SystemProxyInfo(source: '测试', available: true, enabled: false),
        ),
      );

      final SyncPreferences preferences = SyncPreferences(db);
      await preferences.setProxySettings(manualSettings);
      final AuthenticatedApi api = AuthenticatedApi(
        credentialStore: InMemoryCredentialStore(),
        accountSessionDao: AccountSessionDao(db.raw),
        deviceIdentity: DeviceIdentity(db),
        preferences: preferences,
        proxyResolver: resolver,
      );
      addTearDown(api.dispose);
      await api.load();

      expect(api.proxyResolution.usesProxy, isTrue);
      final int before = api.networkGeneration;

      // 切到直连
      await api.applyProxySettings(const ProxySettings(mode: ProxyMode.direct));
      expect(
        api.networkGeneration,
        before + 1,
        reason: '代理配置变化必须关闭旧 HttpClient 并重建连接池',
      );
      expect(api.proxyResolution.usesProxy, isFalse);

      // 再切回手动代理
      await api.applyProxySettings(
        ProxySettings(
          mode: ProxyMode.manualHttp,
          host: '127.0.0.1',
          port: proxy.port,
          bypassLocalhost: false,
        ),
      );
      expect(api.networkGeneration, before + 2);
      expect(api.proxyResolution.usesProxy, isTrue);
      expect(api.proxyResolution.authority, '127.0.0.1:${proxy.port}');

      // 配置确实落到了本地偏好（退出登录也不会丢）
      final ProxySettings persisted = await SyncPreferences(db).proxySettings();
      expect(persisted.mode, ProxyMode.manualHttp);
      expect(persisted.port, proxy.port);
    });
  });

  // ---------------------------------------------------------------------------

  group('ProxyProbe 分阶段诊断', () {
    test('TCP + CONNECT 成功', () async {
      final ProxyProbeResult r = await const ProxyProbe().probe(
        baseUri: Uri.parse(server.baseUrl),
        resolution: resolutionOf(proxy),
        includeHealthCheck: false,
      );
      expect(r.tcpOk, isTrue);
      expect(r.connectOk, isTrue);
      expect(r.failure, isNull);
      expect(proxy.connectTargets, isNotEmpty);
      expect(r.summary, contains('代理可用'));
    });

    test('CONNECT 407 → proxyAuthenticationRequired', () async {
      proxy.requireAuth = true;

      final ProxyProbeResult r = await const ProxyProbe().probe(
        baseUri: Uri.parse(server.baseUrl),
        resolution: resolutionOf(proxy),
        includeHealthCheck: false,
      );

      expect(r.tcpOk, isTrue);
      expect(r.connectOk, isFalse);
      expect(r.failure, ProxyProbeFailure.proxyAuthenticationRequired);
      expect(r.proxyStatusCode, 407);
      expect(r.summary, contains('407'));
      expect(proxy.authChallenges, 1);
    });

    test('带上正确代理凭据后 CONNECT 成功（凭据只走请求头）', () async {
      proxy.requireAuth = true;

      final ProxyProbeResult r =
          await ProxyProbe(
            proxyUsername: proxy.username,
            proxyPassword: proxy.password,
          ).probe(
            baseUri: Uri.parse(server.baseUrl),
            resolution: resolutionOf(proxy),
            includeHealthCheck: false,
          );

      expect(r.failure, isNull);
      expect(proxy.authChallenges, 0);
      expect(proxy.authorizedRequests, 1);
      expect(proxy.sawProxyAuthorizationHeader, isTrue);
    });

    test('代理建隧道后立刻断开 → tlsHandshakeFailed（且不绕过证书校验）', () async {
      proxy.acceptConnectThenClose = true;

      final ProxyProbeResult r = await const ProxyProbe().probe(
        baseUri: Uri.parse('https://127.0.0.1:${server.port}'),
        resolution: resolutionOf(proxy),
        includeHealthCheck: true,
      );

      expect(r.tcpOk, isTrue, reason: 'TCP 到代理是通的');
      expect(r.connectOk, isTrue, reason: 'CONNECT 拿到了 200');
      expect(r.tlsOk, isFalse);
      expect(r.failure, ProxyProbeFailure.tlsHandshakeFailed);
    });

    test('测试服务端：TCP → CONNECT → TLS → /health 全绿', () async {
      final ProxyProbeResult r = await const ProxyProbe().probe(
        baseUri: Uri.parse(server.baseUrl),
        resolution: resolutionOf(proxy),
        includeHealthCheck: true,
      );
      expect(r.tcpOk, isTrue);
      expect(r.connectOk, isTrue);
      expect(r.tlsOk, isTrue);
      expect(r.healthOk, isTrue);
      expect(r.healthStatusCode, 200);
      expect(r.allOk, isTrue);
      expect(r.steps, hasLength(4));
    });

    test('/health 非 200 → healthCheckFailed', () async {
      final ProxyProbeResult r = await const ProxyProbe().probe(
        baseUri: Uri.parse('${server.baseUrl}/wrong'),
        resolution: resolutionOf(proxy),
        includeHealthCheck: true,
      );
      expect(r.healthOk, isFalse);
      expect(r.healthStatusCode, 404);
      expect(r.failure, ProxyProbeFailure.healthCheckFailed);
    });

    test('直连模式不经代理', () async {
      final ProxyProbeResult r = await const ProxyProbe().probe(
        baseUri: Uri.parse(server.baseUrl),
        resolution: ProxyResolution.direct(
          settings: const ProxySettings(mode: ProxyMode.direct),
          sourceLabel: '测试直连',
        ),
        includeHealthCheck: false,
      );
      expect(r.usedProxy, isFalse);
      expect(r.tcpOk, isTrue);
      expect(proxy.forwardTargets, isEmpty);
      expect(proxy.connectTargets, isEmpty);
    });
  });
}

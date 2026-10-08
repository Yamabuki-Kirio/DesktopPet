import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:petlife/core/logger.dart';
import 'package:petlife/database/app_database.dart';
import 'package:petlife/sync/proxy/proxy_models.dart';
import 'package:petlife/sync/proxy/proxy_resolver.dart';
import 'package:petlife/sync/proxy/system_proxy.dart';
import 'package:petlife/sync/sync_preferences.dart';

import 'support/sqlite_test_bootstrap.dart';

/// 代理支持的**纯逻辑**测试：解析、决策、绕过规则、持久化与脱敏。
///
/// 真实连代理的行为在 `proxy_client_test.dart` 里用本地假代理验证。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SqliteTestBootstrap.ensureLoaded();

  // ---------------------------------------------------------------------------

  group('findProxy 决策', () {
    final Uri target = Uri.parse('https://petlife.akechi.asia/health');

    test('direct 返回 DIRECT', () {
      final ProxyResolution r = ProxyResolution.direct(
        settings: const ProxySettings(mode: ProxyMode.direct),
        sourceLabel: '手动选择直连',
      );
      expect(r.findProxyFor(target), 'DIRECT');
      expect(r.usesProxy, isFalse);
    });

    test('manualHttp 返回 PROXY host:port', () {
      final ProxyResolution r = ProxyResolution.proxy(
        settings: const ProxySettings(
          mode: ProxyMode.manualHttp,
          host: '127.0.0.1',
          port: 7877,
        ),
        host: '127.0.0.1',
        port: 7877,
        sourceLabel: '手动 HTTP 代理',
      );
      expect(r.findProxyFor(target), 'PROXY 127.0.0.1:7877');
    });

    test('localhost 根据 bypassLocalhost 决定是否走代理', () {
      const ProxySettings withBypass = ProxySettings(
        mode: ProxyMode.manualHttp,
        host: '127.0.0.1',
        port: 7877,
      );
      const ProxySettings withoutBypass = ProxySettings(
        mode: ProxyMode.manualHttp,
        host: '127.0.0.1',
        port: 7877,
        bypassLocalhost: false,
      );
      ProxyResolution build(ProxySettings s) => ProxyResolution.proxy(
            settings: s,
            host: s.host,
            port: s.port,
            sourceLabel: '手动 HTTP 代理',
          );

      for (final String local in <String>[
        'http://localhost:8000/health',
        'http://127.0.0.1:8000/health',
        'http://127.0.0.1/health',
        'http://[::1]:8000/health',
        'http://my-pc:8000/health',
      ]) {
        final Uri uri = Uri.parse(local);
        expect(build(withBypass).findProxyFor(uri), 'DIRECT', reason: local);
        expect(build(withoutBypass).findProxyFor(uri), 'PROXY 127.0.0.1:7877',
            reason: local);
      }

      // 公网域名必须走代理
      expect(build(withBypass).findProxyFor(target), 'PROXY 127.0.0.1:7877');
    });

    test('单标签主机名按 <local> 语义绕过，带点的内网域名不绕过', () {
      final ProxyResolution r = ProxyResolution.proxy(
        settings: const ProxySettings(mode: ProxyMode.manualHttp, host: '127.0.0.1', port: 7877),
        host: '127.0.0.1',
        port: 7877,
        sourceLabel: '手动',
      );
      expect(r.findProxyFor(Uri.parse('http://nas:5000/')), 'DIRECT');
      expect(r.findProxyFor(Uri.parse('http://nas.corp.lan:5000/')),
          'PROXY 127.0.0.1:7877');
    });
  });

  // ---------------------------------------------------------------------------

  group('ProxyServer 解析', () {
    test('解析 127.0.0.1:7877', () {
      final ProxyServerParse parsed = ProxyServerParse.parseProxyServer('127.0.0.1:7877');
      expect(parsed.entries, hasLength(1));
      expect(parsed.entries.first.scheme, 'http');
      expect(parsed.entries.first.host, '127.0.0.1');
      expect(parsed.entries.first.port, 7877);
      expect(parsed.preferredHttp?.authority, '127.0.0.1:7877');
      expect(parsed.note, isNull);
    });

    test('解析 http=...;https=... 形式', () {
      final ProxyServerParse parsed = ProxyServerParse.parseProxyServer(
        'http=127.0.0.1:7877;https=127.0.0.1:7877',
      );
      expect(parsed.entries, hasLength(2));
      expect(parsed.entries.map((ProxyServerEntry e) => e.scheme).toSet(),
          <String>{'http', 'https'});
      expect(parsed.preferredHttp?.scheme, 'http');
      expect(parsed.hasSocksOnly, isFalse);
    });

    test('容忍带 scheme 与尾随路径的写法', () {
      final ProxyServerParse parsed =
          ProxyServerParse.parseProxyServer('http://127.0.0.1:7877/');
      expect(parsed.preferredHttp?.authority, '127.0.0.1:7877');
    });

    test('SOCKS 条目能被解析但不会被选中，并给出明确说明', () {
      final ProxyServerParse parsed =
          ProxyServerParse.parseProxyServer('socks=127.0.0.1:7897');
      expect(parsed.entries, hasLength(1));
      expect(parsed.entries.first.isSocks, isTrue);
      expect(parsed.hasSocksOnly, isTrue);
      expect(parsed.preferredHttp, isNull);
      expect(parsed.note, isNotNull);
      expect(parsed.note, contains('SOCKS'));
      expect(parsed.note, contains('Mixed Port'));
    });

    test('http 与 socks 并存时选 http', () {
      final ProxyServerParse parsed = ProxyServerParse.parseProxyServer(
        'http=127.0.0.1:7877;socks=127.0.0.1:7897',
      );
      expect(parsed.preferredHttp?.port, 7877);
      expect(parsed.hasSocksOnly, isFalse);
    });

    test('IPv6 字面量与非法输入', () {
      expect(ProxyServerParse.parseProxyServer('[::1]:7877').preferredHttp?.host, '::1');
      expect(ProxyServerParse.parseProxyServer('').isEmpty, isTrue);
      expect(ProxyServerParse.parseProxyServer(null).isEmpty, isTrue);
      expect(ProxyServerParse.parseProxyServer('127.0.0.1').isEmpty, isTrue);
      expect(ProxyServerParse.parseProxyServer('127.0.0.1:0').isEmpty, isTrue);
      expect(ProxyServerParse.parseProxyServer('127.0.0.1:70000').isEmpty, isTrue);
    });
  });

  // ---------------------------------------------------------------------------

  group('ProxySettingsResolver', () {
    ProxySettingsResolver build(ProxySettings settings, SystemProxyInfo info) =>
        ProxySettingsResolver(
          settings: settings,
          systemReader: StaticSystemProxyReader(info),
        );

    const SystemProxyInfo enabledStatic = SystemProxyInfo(
      source: 'WinHTTP',
      available: true,
      enabled: true,
      proxyServer: '127.0.0.1:7877',
    );

    const SystemProxyInfo disabled = SystemProxyInfo(
      source: 'WinHTTP',
      available: true,
      enabled: false,
    );

    const SystemProxyInfo pacOnly = SystemProxyInfo(
      source: 'WinHTTP',
      available: true,
      autoConfigUrl: 'http://127.0.0.1:9090/proxy.pac',
    );

    const SystemProxyInfo wpadOnly = SystemProxyInfo(
      source: 'WinHTTP',
      available: true,
      autoDetect: true,
    );

    test('automatic + 系统代理已启用 → 用系统代理', () async {
      final ProxyResolution r = await build(
        const ProxySettings(mode: ProxyMode.automatic),
        enabledStatic,
      ).refresh();
      expect(r.usesProxy, isTrue);
      expect(r.authority, '127.0.0.1:7877');
      expect(r.detectedFromSystem, isTrue);
      expect(r.findProxyFor(Uri.parse('https://petlife.akechi.asia/health')),
          'PROXY 127.0.0.1:7877');
    });

    test('automatic + 系统未启用代理 → 回退直连（不算错误）', () async {
      final ProxyResolution r =
          await build(const ProxySettings(mode: ProxyMode.automatic), disabled).refresh();
      expect(r.usesProxy, isFalse);
      expect(r.blockedReason, isNull, reason: '自动模式下不该报错');
      expect(r.warning, isNotNull);
    });

    test('system + 未检测到代理 → 明确错误（不静默直连）', () async {
      final ProxyResolution r =
          await build(const ProxySettings(mode: ProxyMode.system), disabled).refresh();
      expect(r.usesProxy, isFalse);
      expect(r.blockedReason, isNotNull);
      expect(r.blockedReason, contains('System Proxy'));
    });

    test('system + SOCKS-only → 提示改用 Mixed Port', () async {
      final ProxyResolution r = await build(
        const ProxySettings(mode: ProxyMode.system),
        const SystemProxyInfo(
          source: '注册表',
          available: true,
          enabled: true,
          proxyServer: 'socks=127.0.0.1:7897',
        ),
      ).refresh();
      expect(r.usesProxy, isFalse);
      expect(r.blockedReason, contains('SOCKS'));
    });

    test('PAC 明确标记为不支持，不静默误判', () async {
      final ProxyResolution auto = await build(
        const ProxySettings(mode: ProxyMode.automatic),
        pacOnly,
      ).refresh();
      expect(auto.usesProxy, isFalse);
      expect(auto.warning, isNotNull);
      expect(auto.warning, contains('PAC'));

      final ProxyResolution forced = await build(
        const ProxySettings(mode: ProxyMode.system),
        pacOnly,
      ).refresh();
      expect(forced.blockedReason, isNotNull);
      expect(forced.blockedReason, contains('PAC'));
    });

    test('WPAD（自动检测）也明确不支持', () async {
      final ProxyResolution r = await build(
        const ProxySettings(mode: ProxyMode.automatic),
        wpadOnly,
      ).refresh();
      expect(r.usesProxy, isFalse);
      expect(r.warning, contains('WPAD'));
    });

    test('检测到 <local> 时自动开启本地绕过', () async {
      final ProxyResolution r = await build(
        const ProxySettings(mode: ProxyMode.system, bypassLocalhost: false),
        const SystemProxyInfo(
          source: '注册表',
          available: true,
          enabled: true,
          proxyServer: '127.0.0.1:7877',
          proxyBypass: '<local>;*.corp.example.com',
        ),
      ).refresh();
      expect(r.settings.bypassLocalhost, isTrue);
      expect(r.findProxyFor(Uri.parse('http://localhost:8000/')), 'DIRECT');
    });

    test('读不到系统代理时不抛异常，只回退直连', () async {
      final ProxyResolution r = await build(
        const ProxySettings(mode: ProxyMode.automatic),
        const SystemProxyInfo(source: '不可用', available: false, error: '注册表读取失败'),
      ).refresh();
      expect(r.usesProxy, isFalse);
      expect(r.warning, isNotNull);
    });

    test('手动模式配置不完整时给出明确原因', () async {
      final ProxyResolution r = await build(
        const ProxySettings(mode: ProxyMode.manualHttp, host: '  ', port: 7877),
        disabled,
      ).refresh();
      expect(r.usesProxy, isFalse);
      expect(r.blockedReason, contains('配置不完整'));
    });

    test('direct 模式即使系统有代理也不使用', () async {
      final ProxyResolution r = await build(
        const ProxySettings(mode: ProxyMode.direct),
        enabledStatic,
      ).refresh();
      expect(r.usesProxy, isFalse);
      expect(r.findProxyFor(Uri.parse('https://petlife.akechi.asia/health')), 'DIRECT');
    });
  });

  // ---------------------------------------------------------------------------

  group('持久化与安全', () {
    late Directory tmp;

    setUpAll(() {
      tmp = Directory.systemTemp.createTempSync('petlife_proxy_prefs');
    });

    tearDownAll(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    String newDbPath(String tag) =>
        p.join(tmp.path, '${tag}_${DateTime.now().microsecondsSinceEpoch}.db');

    test('ProxySettings 存储往返（含清除用户名/密码）', () async {
      final ProxySettings original = ProxySettings(
        mode: ProxyMode.manualHttp,
        host: '127.0.0.1',
        port: 7877,
        username: 'clash-user',
        passwordCredentialReference: 'PetLife:proxy',
        bypassLocalhost: false,
      );
      final ProxySettings restored = ProxySettings.fromStorageMap(original.toStorageMap());
      expect(restored.mode, ProxyMode.manualHttp);
      expect(restored.host, '127.0.0.1');
      expect(restored.port, 7877);
      expect(restored.username, 'clash-user');
      expect(restored.passwordCredentialReference, 'PetLife:proxy');
      expect(restored.bypassLocalhost, isFalse);
    });

    test('代理配置可读可写，且移除用户名后不会残留旧值', () async {
      final String path = newDbPath('proxy');
      await AppDatabase.close();
      AppDatabase db = await AppDatabase.open(path: path);
      SyncPreferences prefs = SyncPreferences(db);

      // 默认是 automatic（至少不启用代理）
      expect((await prefs.proxySettings()).mode, ProxyMode.automatic);

      await prefs.setProxySettings(ProxySettings(
        mode: ProxyMode.manualHttp,
        host: '127.0.0.1',
        port: 7877,
        username: 'u1',
        passwordCredentialReference: 'PetLife:proxy',
      ));
      await AppDatabase.close();

      db = await AppDatabase.open(path: path);
      prefs = SyncPreferences(db);
      ProxySettings loaded = await prefs.proxySettings();
      expect(loaded.mode, ProxyMode.manualHttp);
      expect(loaded.username, 'u1');
      expect(loaded.hasSavedPassword, isTrue);

      // 用户清空用户名与密码后保存
      await prefs.setProxySettings(const ProxySettings(
        mode: ProxyMode.direct,
        host: '127.0.0.1',
        port: 7877,
      ));
      loaded = await prefs.proxySettings();
      expect(loaded.mode, ProxyMode.direct);
      expect(loaded.username, isNull);
      expect(loaded.hasSavedPassword, isFalse);
      await AppDatabase.close();
    });

    test('代理密码不落 SQLite（扫描数据库文件字节）', () async {
      final String path = newDbPath('nosecret');
      await AppDatabase.close();
      final AppDatabase db = await AppDatabase.open(path: path);
      final SyncPreferences prefs = SyncPreferences(db);

      // 只有引用名进库；密码本体在 CredentialStore（本测试不写它）
      await prefs.setProxySettings(ProxySettings(
        mode: ProxyMode.manualHttp,
        host: '127.0.0.1',
        port: 7877,
        username: 'clash-user',
        passwordCredentialReference: 'PetLife:proxy',
      ));
      await AppDatabase.close();

      final String raw = String.fromCharCodes(await File(path).readAsBytes());
      expect(raw, isNot(contains('hunter2-proxy-password')));
      expect(raw, contains('PetLife:proxy'));
      expect(raw, contains('clash-user'));
    });

    test('describe() 与 toString() 都不含密码', () {
      const ProxySettings s = ProxySettings(
        mode: ProxyMode.manualHttp,
        host: '127.0.0.1',
        port: 7877,
        username: 'clash-user',
        passwordCredentialReference: 'PetLife:proxy',
      );
      expect(s.describe(), contains('127.0.0.1:7877'));
      expect(s.describe(), contains('clash-user'));
      expect(s.describe(), isNot(contains('hunter2')));
      expect(s.toString(), isNot(contains('hunter2')));
    });
  });

  // ---------------------------------------------------------------------------

  group('日志脱敏（代理相关）', () {
    test('Proxy-Authorization 与代理密码被抹掉', () {
      for (final String raw in <String>[
        'Proxy-Authorization: Basic dXNlcjpwYXNzd29yZA==',
        'proxy_authorization=Basic dXNlcjpwYXNzd29yZA==',
        'proxy_password=hunter2',
        'proxyPassword: hunter2',
      ]) {
        final String cleaned = AppLog.redact(raw);
        expect(cleaned, isNot(contains('dXNlcjpwYXNzd29yZA==')), reason: raw);
        expect(cleaned, isNot(contains('hunter2')), reason: raw);
      }
    });

    test('AppLog.format 对代理日志同样脱敏', () {
      final LogRecord record = LogRecord(
        Level.INFO,
        'proxy auth=Basic dXNlcjpwYXNzd29yZA==',
        'petlife.proxy',
      );
      final String line = AppLog.format(record);
      expect(line, isNot(contains('dXNlcjpwYXNzd29yZA==')));
      expect(line, contains('<redacted>'));
    });

    test('正常代理日志（地址与阶段）不被破坏', () {
      const String text = '代理决策：代理（127.0.0.1:7877），来源=Windows 系统代理（WinHTTP）';
      expect(AppLog.redact(text), text);
    });
  });
}

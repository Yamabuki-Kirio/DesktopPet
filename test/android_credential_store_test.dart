import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:petlife/platform/android/android_credential_store.dart';
import 'package:petlife/platform/android/android_keystore_credential_store.dart';
import 'package:petlife/platform/windows/windows_credential_store_factory.dart';
import 'package:petlife/sync/credential_store.dart';
import 'package:petlife/sync/credential_store_factory.dart';

/// Phase 4A：凭据后端**工厂选择**。
///
/// 这里只回答一个问题：两个平台各自挑到了哪个后端。
/// 通道合约与落盘格式见 `android_keystore_credential_store_test.dart`。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel =
      MethodChannel(androidCredentialStoreChannelName);

  void installWorkingChannel() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      // 只为让工厂的写入探测成功；行为细节在合约测试里覆盖。
      final Map<Object?, Object?> args =
          call.arguments! as Map<Object?, Object?>;
      if (call.method == 'write') {
        _echo[args['key']! as String] = args['secret']! as String;
      } else if (call.method == 'delete') {
        _echo.remove(args['key']! as String);
      }
      return call.method == 'read' ? _echo[args['key']! as String] : null;
    });
  }

  void uninstallChannel() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    _echo.clear();
  }

  late Directory tmp;

  setUpAll(() {
    tmp = Directory.systemTemp.createTempSync('petlife_cred_factory');
  });

  tearDownAll(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  setUp(installWorkingChannel);
  tearDown(uninstallChannel);

  group('Android 工厂', () {
    test('选择 Android Keystore 后端（不再是内存后端）', () async {
      final CredentialStore store =
          await const AndroidCredentialStoreFactory().create(fallbackDirectory: tmp);

      expect(store, isA<AndroidKeystoreCredentialStore>());
      expect(store, isNot(isA<InMemoryCredentialStore>()));
      expect(store.backendName, contains('Android Keystore'));

      // 探测留下的那个键必须被清理掉
      expect(_echo.containsKey(credentialProbeKey), isFalse);
    });

    test('原生通道不可用时仍然返回 Keystore 后端，不静默降级为内存', () async {
      uninstallChannel();

      final CredentialStore store =
          await const AndroidCredentialStoreFactory().create(fallbackDirectory: tmp);

      expect(store, isA<AndroidKeystoreCredentialStore>(),
          reason: '静默降级会让"重启后仍保持登录"变成没人发现的假象');
      expect(store, isNot(isA<InMemoryCredentialStore>()));
    });

    test('工厂返回的后端满足 CredentialStore 契约', () async {
      final CredentialStore store =
          await const AndroidCredentialStoreFactory().create(fallbackDirectory: tmp);

      await store.write('PetLife:account', 'token-value');
      expect(await store.read('PetLife:account'), 'token-value');
      await store.delete('PetLife:account');
      expect(await store.read('PetLife:account'), isNull);
      await store.delete('PetLife:account'); // 幂等
    });
  });

  group('Windows 工厂', () {
    test('仍然选择原有后端（Credential Manager / DPAPI / 内存），不是 Keystore', () async {
      final CredentialStore store =
          await const WindowsCredentialStoreFactory().create(fallbackDirectory: tmp);

      expect(store, isNot(isA<AndroidKeystoreCredentialStore>()));
      expect(
        store.backendName,
        anyOf(
          contains('Windows Credential Manager'),
          contains('DPAPI'),
          contains('memory'),
        ),
        reason: 'Windows 侧的三级降级链必须保持不变',
      );
      expect(store.isAvailable, isTrue);
    });

    test('Windows 工厂不引用任何 Android 实现（静态契约）', () {
      final String source = File(p.join(
        Directory.current.path,
        'lib',
        'platform',
        'windows',
        'windows_credential_store_factory.dart',
      )).readAsStringSync();

      expect(source, isNot(contains('AndroidKeystore')));
      expect(source, isNot(contains('platform/android')));
      expect(source, contains('WindowsCredentialManagerStore'));
      expect(source, contains('DpapiFileCredentialStore'));
      expect(source, contains('InMemoryCredentialStore'));
    });

    test('两个平台的装配点各自绑定自己的工厂（静态契约）', () {
      final String windows = File(p.join(
        Directory.current.path,
        'lib',
        'platform',
        'windows',
        'windows_platform_services.dart',
      )).readAsStringSync();
      expect(windows, contains('WindowsCredentialStoreFactory'));

      final String android = File(p.join(
        Directory.current.path,
        'lib',
        'platform',
        'android',
        'android_platform_services.dart',
      )).readAsStringSync();
      expect(android, contains('AndroidCredentialStoreFactory'));
      expect(android, isNot(contains('WindowsCredentialStoreFactory')));
    });
  });

  group('探测协议', () {
    test('接口可替换：任意 CredentialStore 实现都能通过探测', () async {
      final _SpyCredentialStore spy = _SpyCredentialStore();
      expect(await probeCredentialStore(spy), isTrue);
      expect(spy.writes, 1);
      expect(spy.deletes, 1, reason: '探针必须自己清理，不能留下 PetLife:probe');
    });

    test('探测失败时不得留下残留条目', () async {
      final _FailingCredentialStore broken = _FailingCredentialStore();
      expect(await probeCredentialStore(broken), isFalse);
      expect(broken.deletes, 1, reason: '读回不一致也要清理');
    });
  });
}

/// 模拟通道另一端的最小存储（仅工厂探测用）。
final Map<String, String> _echo = <String, String>{};

/// 最小替身：只验证 [probeCredentialStore] 的写-读-删流程。
class _SpyCredentialStore implements CredentialStore {
  final Map<String, String> entries = <String, String>{};
  int writes = 0;
  int deletes = 0;

  @override
  String get backendName => 'spy';

  @override
  bool get isAvailable => true;

  @override
  Future<void> write(String key, String secret) async {
    writes++;
    entries[key] = secret;
  }

  @override
  Future<String?> read(String key) async => entries[key];

  @override
  Future<void> delete(String key) async {
    deletes++;
    entries.remove(key);
  }
}

/// 读回值与写入值不一致的后端（模拟"写了但读不出来"的系统存储）。
class _FailingCredentialStore implements CredentialStore {
  int deletes = 0;

  @override
  String get backendName => 'failing';

  @override
  bool get isAvailable => true;

  @override
  Future<void> write(String key, String secret) async {}

  @override
  Future<String?> read(String key) async => 'something-else';

  @override
  Future<void> delete(String key) async {
    deletes++;
  }
}

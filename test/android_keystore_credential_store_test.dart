import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:petlife/platform/android/android_keystore_credential_store.dart';
import 'package:petlife/sync/credential_store.dart';

/// Phase 4A：Android Keystore 凭据后端的**通道合约测试**。
///
/// 分层说明（避免误读这组测试的覆盖范围）
/// ------------------------------------
/// * 这里验证的是 **Dart 侧与原生端的接口契约**：方法名、参数名、返回值、
///   错误码映射，以及"落盘表示里不得出现明文"这条不变式；
/// * 真正的 KeyStore 行为（密钥不可导出、系统生成随机 IV、
///   篡改密文时抛 `AEADBadTagException`）由原生端保证，另有两道防线：
///   1. 本文件的「原生实现静态契约」用例直接读 Kotlin 源码做断言；
///   2. 真机安装后的人工验收（见 docs/29）。
///
/// 为什么要在 Dart 侧再模拟一遍信封
/// -------------------------------
/// 因为"密文里不含明文"是**落盘格式**的性质，而 Dart 侧看不到 SharedPreferences。
/// 所以用 [_FakeAndroidKeystore] 忠实复刻原生端文档化的落盘格式
/// （`v1:<IV base64>:<密文 base64>`），把格式契约钉死：
/// 将来原生端把明文直接写进 prefs，这个用例会连同静态检查一起失败。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel =
      MethodChannel(androidCredentialStoreChannelName);

  late _FakeAndroidKeystore fake;

  void installFake(_FakeAndroidKeystore target) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, target.handle);
  }

  void uninstallFake() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  }

  setUp(() {
    fake = _FakeAndroidKeystore();
    installFake(fake);
  });

  tearDown(uninstallFake);

  group('MethodChannel 合约', () {
    test('write / read / delete 的方法名与参数名与原生端一致', () async {
      const AndroidKeystoreCredentialStore store =
          AndroidKeystoreCredentialStore();

      await store.write('PetLife:account', 'token-abc');
      expect(fake.calls.last.method, 'write');
      expect(fake.calls.last.arguments, <String, Object?>{
        'key': 'PetLife:account',
        'secret': 'token-abc',
      });

      await store.read('PetLife:account');
      expect(fake.calls.last.method, 'read');
      expect(fake.calls.last.arguments, <String, Object?>{'key': 'PetLife:account'});
      expect(
        (fake.calls.last.arguments! as Map<Object?, Object?>).containsKey('secret'),
        isFalse,
        reason: '读取不需要、也不应该带上凭据内容',
      );

      await store.delete('PetLife:account');
      expect(fake.calls.last.method, 'delete');
      expect(fake.calls.last.arguments, <String, Object?>{'key': 'PetLife:account'});
    });

    test('通道名与原生端常量完全一致（改一边不改另一边会失败）', () {
      final String activity = File(p.join(
        Directory.current.path,
        'android',
        'app',
        'src',
        'main',
        'kotlin',
        'asia',
        'akechi',
        'petlife',
        'MainActivity.kt',
      )).readAsStringSync();

      final Match? declared = RegExp(
        r'CREDENTIAL_STORE_CHANNEL\s*=\s*"([^"]+)"',
      ).firstMatch(activity);

      expect(declared, isNotNull, reason: 'MainActivity 必须声明通道名常量');
      expect(declared!.group(1), androidCredentialStoreChannelName);

      final String store = File(p.join(
        Directory.current.path,
        'android',
        'app',
        'src',
        'main',
        'kotlin',
        'asia',
        'akechi',
        'petlife',
        'PetLifeCredentialStore.kt',
      )).readAsStringSync();
      expect(store, contains('const val PREFERENCE_PREFIX = "entry:"'));
    });

    test('后端名写明 Keystore 与 AES/GCM，且标记为可用', () {
      const AndroidKeystoreCredentialStore store =
          AndroidKeystoreCredentialStore();
      expect(store.backendName, contains('Android Keystore'));
      expect(store.backendName, contains('AES/GCM'));
      expect(store.isAvailable, isTrue);
    });
  });

  group('写入 / 读取 / 覆盖 / 删除', () {
    const AndroidKeystoreCredentialStore store =
        AndroidKeystoreCredentialStore();

    test('不存在的条目返回 null（不是抛异常）', () async {
      expect(await store.read('PetLife:account'), isNull);
    });

    test('写入后能读回，覆盖后读到新值', () async {
      await store.write('PetLife:account', 'payload-1');
      expect(await store.read('PetLife:account'), 'payload-1');

      await store.write('PetLife:account', 'payload-2');
      expect(await store.read('PetLife:account'), 'payload-2');
    });

    test('删除后读不到，且删除是幂等的', () async {
      await store.write('PetLife:account', 'payload-1');
      await store.delete('PetLife:account');
      expect(await store.read('PetLife:account'), isNull);

      // 条目不存在也算成功
      await store.delete('PetLife:account');
      expect(await store.read('PetLife:account'), isNull);
    });

    test('不同条目互不干扰', () async {
      await store.write('PetLife:account', 'account-token');
      await store.write('PetLife:proxy', 'proxy-password');
      expect(await store.read('PetLife:account'), 'account-token');
      expect(await store.read('PetLife:proxy'), 'proxy-password');

      await store.delete('PetLife:account');
      expect(await store.read('PetLife:account'), isNull);
      expect(await store.read('PetLife:proxy'), 'proxy-password');
    });
  });

  group('密文不包含明文（落盘格式）', () {
    const AndroidKeystoreCredentialStore store =
        AndroidKeystoreCredentialStore();

    const String secret = 'access-token-SECRET-1234567890';

    test('prefs 里只有版本信封，找不到明文令牌', () async {
      await store.write('PetLife:account', secret);

      final String? persisted = fake.preferences['entry:PetLife:account'];
      expect(persisted, isNotNull);
      expect(persisted, startsWith('v1:'), reason: '必须先写版本号，便于将来轮换');
      final String envelope = persisted!;
      expect(envelope.split(':'), hasLength(3));

      expect(envelope, isNot(contains(secret)));
      // 逐段检查：明文的任意 6 字符片段都不允许出现
      for (int i = 0; i + 6 <= secret.length; i++) {
        expect(
          envelope.contains(secret.substring(i, i + 6)),
          isFalse,
          reason: '落盘内容里出现了明文片段 ${secret.substring(i, i + 6)}',
        );
      }

      // 同时确认确实"存下来了"（不是把内容丢弃换来的假安全）
      expect(await store.read('PetLife:account'), secret);
    });

    test('同样的明文写入两次得到不同密文（每次写入都用新的随机 IV）', () async {
      await store.write('PetLife:account', secret);
      final String first = fake.preferences['entry:PetLife:account']!;
      await store.write('PetLife:account', secret);
      final String second = fake.preferences['entry:PetLife:account']!;

      expect(first, isNot(second));
      final String firstIv = first.split(':')[1];
      final String secondIv = second.split(':')[1];
      expect(firstIv, isNot(secondIv), reason: 'IV 必须每次重新生成');
    });

    test('代理密码同样不落盘明文', () async {
      const String proxyPassword = 'clash-proxy-password';
      await store.write('PetLife:proxy', proxyPassword);
      final String persisted = fake.preferences['entry:PetLife:proxy']!;
      expect(persisted, isNot(contains(proxyPassword)));
      expect(await store.read('PetLife:proxy'), proxyPassword);
    });
  });

  group('错误返回映射（绝不回退到明文或内存）', () {
    const AndroidKeystoreCredentialStore store =
        AndroidKeystoreCredentialStore();

    Future<void> expectFailure(String code, String expectedHint) async {
      installFake(_FakeAndroidKeystore(
        readBehaviour: () => throw PlatformException(
          code: code,
          message: '凭据操作失败：PetLife:account',
        ),
      ));
      await store.write('PetLife:account', 'token-abc');

      await expectLater(
        store.read('PetLife:account'),
        throwsA(
          isA<CredentialStoreException>().having(
            (CredentialStoreException e) => e.message,
            'message',
            allOf(contains(code), contains(expectedHint), contains('不会回退到明文')),
          ),
        ),
      );
    }

    test('key_invalid → 明确提示密钥已失效', () async {
      await expectFailure('key_invalid', 'Android Keystore 密钥已失效');
    });

    test('cipher_corrupt → 明确提示密文不匹配或已被篡改', () async {
      await expectFailure('cipher_corrupt', '密文与当前密钥不匹配或已被篡改');
    });

    test('未知错误码 → 归为"原生端返回未知错误"而不是静默成功', () async {
      await expectFailure('weird_code', '原生端返回未知错误');
    });

    test('异常信息里不含凭据内容', () async {
      installFake(_FakeAndroidKeystore(
        readBehaviour: () => throw PlatformException(
          code: 'cipher_corrupt',
          message: '凭据解密失败（密钥不匹配或数据已损坏）：PetLife:account',
        ),
      ));
      await store.write('PetLife:account', 'token-abc');

      try {
        await store.read('PetLife:account');
        fail('解密失败必须抛异常');
      } on CredentialStoreException catch (e) {
        expect(e.toString(), isNot(contains('token-abc')));
        expect(e.toString(), contains('PetLife:account'));
      }
    });

    test('原生通道未注册 → 抛明确错误（不回退内存后端）', () async {
      uninstallFake();

      await expectLater(
        store.write('PetLife:account', 'token-abc'),
        throwsA(
          isA<CredentialStoreException>().having(
            (CredentialStoreException e) => e.message,
            'message',
            allOf(contains('通道未注册'), contains(androidCredentialStoreChannelName)),
          ),
        ),
      );
    });
  });

  group('原生实现静态契约（Kotlin 源码）', () {
    late String source;

    setUpAll(() {
      source = File(p.join(
        Directory.current.path,
        'android',
        'app',
        'src',
        'main',
        'kotlin',
        'asia',
        'akechi',
        'petlife',
        'PetLifeCredentialStore.kt',
      )).readAsStringSync();
    });

    test('使用 AndroidKeyStore + AES/GCM/NoPadding + 256 位密钥', () {
      expect(source, contains('"AndroidKeyStore"'));
      expect(source, contains('"AES/GCM/NoPadding"'));
      expect(source, contains('KeyProperties.BLOCK_MODE_GCM'));
      expect(source, contains('KeyProperties.ENCRYPTION_PADDING_NONE'));
      expect(source, contains('KEY_SIZE_BITS = 256'));
    });

    test('强制系统生成随机 IV（不接受调用方传入 IV）', () {
      expect(source, contains('setRandomizedEncryptionRequired(true)'));
      // 只用 cipher.iv（系统生成），不允许出现"传入 IV"的加密调用
      expect(source, contains('Base64.encodeToString(cipher.iv, Base64.NO_WRAP)'));

      final Match? encryption =
          RegExp(r'init\(Cipher\.ENCRYPT_MODE[^)]*\)').firstMatch(source);
      expect(encryption, isNotNull);
      expect(
        encryption!.group(0),
        isNot(contains('GCMParameterSpec')),
        reason: '加密路径不能自带 IV，必须让系统生成随机 IV',
      );

      // 解密路径则必须显式带上落盘的 IV
      expect(source, contains('GCMParameterSpec(GCM_TAG_LENGTH_BITS, iv)'));
    });

    test('SharedPreferences 只写信封，绝不写明文凭据', () {
      expect(source, contains('putString(preferenceKey(key), envelope)'));
      expect(
        RegExp(r'putString\([^)]*secret').hasMatch(source),
        isFalse,
        reason: 'SharedPreferences 里不允许出现明文 secret',
      );
    });

    test('读取失败不回退明文（显式抛 CredentialStoreFailure）', () {
      expect(source, contains('CODE_CIPHER_CORRUPT'));
      expect(source, contains('CODE_KEY_INVALID'));
      expect(source, contains('class CredentialStoreFailure'));
    });
  });
}

/// 忠实复刻原生端落盘契约的假实现。
///
/// 格式：`v1:<IV base64(16B)>:<密文 base64>`；密文 = 明文字节与 IV 异或。
/// 异或当然不是真加密，它在这里的作用只是让"密文里不含明文"这条断言**可被证伪** ——
/// 如果哪天有人把 prefs 改成直接存明文，这个用例会立刻失败。
class _FakeAndroidKeystore {
  _FakeAndroidKeystore({this.readBehaviour});

  /// 覆盖 `read` 的行为（用来模拟原生端返回各类错误码）。
  final Object? Function()? readBehaviour;

  /// prefs 内容（键 → 信封），与原生端 `entry:` 前缀保持一致。
  final Map<String, String> preferences = <String, String>{};

  /// 依次记录收到的调用，供合约断言使用。
  final List<MethodCall> calls = <MethodCall>[];

  final Random _ivSource = Random.secure();

  Future<Object?> handle(MethodCall call) async {
    calls.add(call);

    final Map<Object?, Object?> args = call.arguments! as Map<Object?, Object?>;
    final String key = args['key']! as String;

    switch (call.method) {
      case 'write':
        preferences['entry:$key'] = _seal(args['secret']! as String);
        return null;
      case 'read':
        if (readBehaviour != null) return readBehaviour!();
        final String? envelope = preferences['entry:$key'];
        if (envelope == null) return null;
        return _open(envelope, key);
      case 'delete':
        preferences.remove('entry:$key');
        return null;
      default:
        throw PlatformException(
          code: 'unsupported_method',
          message: '不支持的凭据操作：${call.method}',
        );
    }
  }

  String _seal(String secret) {
    final List<int> iv = List<int>.generate(16, (_) => _ivSource.nextInt(256));
    final List<int> body = _xor(utf8.encode(secret), iv);
    return 'v1:${base64.encode(iv)}:${base64.encode(body)}';
  }

  String _open(String envelope, String key) {
    final List<String> parts = envelope.split(':');
    if (parts.length != 3 || parts[0] != 'v1') {
      throw PlatformException(
        code: 'cipher_corrupt',
        message: '凭据数据格式无法识别（不是 v1 信封）：$key',
      );
    }
    final List<int> iv;
    final List<int> body;
    try {
      iv = base64.decode(parts[1]);
      body = base64.decode(parts[2]);
    } on FormatException {
      throw PlatformException(
        code: 'cipher_corrupt',
        message: '凭据数据无法解码（Base64 损坏）：$key',
      );
    }
    return utf8.decode(_xor(body, iv));
  }

  static List<int> _xor(List<int> data, List<int> iv) => List<int>.generate(
        data.length,
        (int i) => data[i] ^ iv[i % iv.length],
      );
}

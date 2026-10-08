import 'package:flutter/services.dart';

import '../../sync/credential_store.dart';

/// 与 Android 原生通信的通道名。
///
/// 必须与 `android/app/src/main/kotlin/asia/akechi/petlife/MainActivity.kt`
/// 里的 `CREDENTIAL_STORE_CHANNEL` 完全一致。
const String androidCredentialStoreChannelName =
    'asia.akechi.petlife/credential_store';

/// Android 凭据后端：**Android Keystore + AES/GCM/NoPadding**（Phase 4A）。
///
/// 原生实现见 `PetLifeCredentialStore.kt`（`android/app/src/main/kotlin/`）：
/// * 密钥由 AndroidKeyStore 生成，**不可导出**；
/// * 每次写入由系统生成随机 IV；
/// * `SharedPreferences` 里只保存 `v1:<IV>:<密文>` 信封，不保存明文；
/// * 解密失败 / 密钥失效时抛明确错误，**绝不回退到明文**。
///
/// 为什么不用 `flutter_secure_storage`
/// ----------------------------------
/// 它在 Windows 侧会编译一个依赖 ATL（`atlstr.h`）的 C++ 插件，本机 VS Build Tools
/// 未安装 ATL，引入它会让 **Windows Release 构建直接失败**。
/// 因此这里用项目内的原生通道实现，Windows 侧完全不受影响
/// （Windows 继续走 Credential Manager / DPAPI）。
///
/// 平台隔离
/// --------
/// 通道对象在 Dart 侧是惰性的：**没有 Android 原生实现时调用会抛
/// [MissingPluginException]**，而不是静默成功。这个类只会被
/// `AndroidCredentialStoreFactory` 创建，Windows 装配点不会碰它。
class AndroidKeystoreCredentialStore implements CredentialStore {
  const AndroidKeystoreCredentialStore({
    MethodChannel channel = const MethodChannel(androidCredentialStoreChannelName),
  }) : _channel = channel;

  final MethodChannel _channel;

  @override
  String get backendName => 'Android Keystore（AES/GCM/NoPadding）';

  /// AndroidKeyStore 自 API 23 起就是系统必备组件，而本工程 minSdk 远高于 23，
  /// 因此在 Android 上它总是可用。真正的可用性由工厂的写入探测确认。
  @override
  bool get isAvailable => true;

  @override
  Future<void> write(String key, String secret) async {
    await _invoke<void>('write', <String, Object?>{'key': key, 'secret': secret});
  }

  @override
  Future<String?> read(String key) async =>
      _invoke<String>('read', <String, Object?>{'key': key});

  @override
  Future<void> delete(String key) async {
    await _invoke<void>('delete', <String, Object?>{'key': key});
  }

  Future<T?> _invoke<T>(String method, Map<String, Object?> arguments) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on MissingPluginException catch (e) {
      throw CredentialStoreException(
        'Android 凭据通道未注册（操作=$method）：原生端必须在 MainActivity 里注册 '
        '$androidCredentialStoreChannelName（${e.runtimeType}）。'
        '出于安全考虑不会回退到明文或内存存储。',
      );
    } on PlatformException catch (e) {
      throw CredentialStoreException(_describePlatformError(e, method));
    }
  }

  /// 把原生错误码翻译成明确的失败原因。
  ///
  /// 注意：[PlatformException.message] 由原生端构造，**只包含条目名与失败原因**，
  /// 不含令牌明文（见 `PetLifeCredentialStore.kt` 的类文档）。
  static String _describePlatformError(PlatformException e, String method) {
    final String detail = switch (e.code) {
      'key_invalid' => 'Android Keystore 密钥已失效（可能被系统清除或用户重置了锁屏）',
      'cipher_corrupt' => '密文与当前密钥不匹配或已被篡改',
      'encrypt_failed' => '加密失败',
      'write_failed' => '写入 SharedPreferences 失败',
      'invalid_arguments' => '通道参数不合法',
      'unsupported_method' => '原生端不支持该操作',
      _ => '原生端返回未知错误',
    };
    final String native = e.message?.trim() ?? '';
    return 'Android 凭据存储失败（操作=$method，错误码=${e.code}）：$detail'
        '${native.isEmpty ? '' : '｜$native'}。'
        '出于安全考虑不会回退到明文或内存存储。';
  }

  @override
  String toString() => 'AndroidKeystoreCredentialStore(backend=$backendName)';
}

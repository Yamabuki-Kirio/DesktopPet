import 'dart:io';

import '../../core/logger.dart';
import '../../sync/credential_store.dart';
import '../../sync/credential_store_factory.dart';
import 'android_keystore_credential_store.dart';

/// Android 凭据后端选择（Phase 4A）。
///
/// 后端固定为 [AndroidKeystoreCredentialStore]：AndroidKeyStore 在 minSdk 之上
/// 是系统必备组件，不需要"降级链"。这里只做一次写入探测，用来在启动日志里
/// 明确写出原生通道是否真的可用。
///
/// ⚠️ **故意不降级到内存**
/// ----------------------
/// 若探测失败（例如原生端忘记注册 MethodChannel），本工厂**仍然返回 Keystore 后端**。
/// 理由是需求明确要求 Android 用 Keystore 持久化令牌、且不允许把内存后端当作
/// 正式后端：静默降级会让"重启后仍保持登录"变成一个没人发现的假象，
/// 而明确报错能让问题在第一时间暴露。
class AndroidCredentialStoreFactory implements CredentialStoreFactory {
  const AndroidCredentialStoreFactory();

  @override
  Future<CredentialStore> create({required Directory fallbackDirectory}) async {
    // fallbackDirectory 用不到：Android 不做"加密文件"降级。
    const AndroidKeystoreCredentialStore store = AndroidKeystoreCredentialStore();

    if (await probeCredentialStore(store)) {
      Loggers.credential.info('凭据后端：${store.backendName}');
    } else {
      Loggers.credential.warning(
        'Android Keystore 写入探测失败（原生通道可能未注册或系统拒绝密钥生成）。'
        '仍然使用 Keystore 后端，不降级为内存存储：令牌要么加密落盘，要么明确报错。',
      );
    }
    return store;
  }
}

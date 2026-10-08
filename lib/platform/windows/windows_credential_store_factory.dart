import 'dart:io';

import '../../core/logger.dart';
import '../../sync/credential_store.dart';
import '../../sync/credential_store_factory.dart';
import 'dpapi_file_credential_store.dart';
import 'win32_credential_native.dart';

/// Windows 凭据后端选择（Credential Manager → DPAPI 文件 → 内存）。
///
/// 行为与阶段 2 完全一致，只是从 `sync/` 搬到了平台层：
/// 这样 Android 编译单元不必 import `win32_credential_native` / DPAPI。
class WindowsCredentialStoreFactory implements CredentialStoreFactory {
  const WindowsCredentialStoreFactory();

  @override
  Future<CredentialStore> create({required Directory fallbackDirectory}) async {
    final CredentialStore? manager = await _tryWindowsCredentialManager();
    if (manager != null) return manager;

    final CredentialStore? dpapi = await _tryDpapiFile(fallbackDirectory);
    if (dpapi != null) return dpapi;

    Loggers.credential.warning(
      '所有系统凭据后端均不可用，退化为内存存储：'
      '本次运行登录状态不会保留到下次启动（使用记录与采集不受影响）',
    );
    return InMemoryCredentialStore(backendName: 'memory（系统凭据不可用）');
  }

  Future<CredentialStore?> _tryWindowsCredentialManager() async {
    const WindowsCredentialManagerStore store = WindowsCredentialManagerStore();
    if (!store.isAvailable) return null;
    if (await probeCredentialStore(store)) {
      Loggers.credential.info('凭据后端：${store.backendName}');
      return store;
    }
    return null;
  }

  Future<CredentialStore?> _tryDpapiFile(Directory directory) async {
    final DpapiFileCredentialStore store = DpapiFileCredentialStore(directory: directory);
    if (!store.isAvailable) return null;
    if (await probeCredentialStore(store)) {
      Loggers.credential.info('凭据后端：${store.backendName}');
      return store;
    }
    return null;
  }
}

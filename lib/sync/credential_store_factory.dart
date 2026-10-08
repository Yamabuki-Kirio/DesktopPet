/// 凭据存储工厂（Phase 4A 抽成接口）。
///
/// 平台实现：
/// * Windows：`platform/windows/windows_credential_store_factory.dart`
///   —— Credential Manager → DPAPI 文件 → 内存 三级降级（行为与阶段 2 完全一致）；
/// * Android：`platform/android/android_credential_store_factory.dart`
///   —— Android Keystore（`flutter_secure_storage`）；
/// * 测试：`InMemoryCredentialStore`（见 `credential_store.dart`）。
///
/// 判定原则：**真实探测**（写 → 读 → 比对 → 删）而不是"看平台名"，
/// 这样在被策略限制的设备上也能正确降级。
library;

import 'dart:io';

import 'credential_store.dart';

abstract interface class CredentialStoreFactory {
  /// 按优先级创建一个可用后端。
  ///
  /// [fallbackDirectory] 只有"加密文件"这类后端会用（写密文）。
  Future<CredentialStore> create({required Directory fallbackDirectory});
}

/// 探针用的固定条目名（平台实现共用）。
const String credentialProbeKey = 'PetLife:probe';

/// 探测一个后端是否真的可用：写 → 读 → 比对 → 删。任何一步异常都视为不可用。
///
/// 放在中立层而不是平台实现里，是为了让两个平台的工厂用**同一套**判定标准。
Future<bool> probeCredentialStore(CredentialStore store, {String key = credentialProbeKey}) async {
  const String probeValue = 'probe-value';
  try {
    await store.write(key, probeValue);
    final String? readBack = await store.read(key);
    await store.delete(key);
    return readBack == probeValue;
  } catch (_) {
    try {
      await store.delete(key);
    } catch (_) {
      // 忽略清理失败
    }
    return false;
  }
}

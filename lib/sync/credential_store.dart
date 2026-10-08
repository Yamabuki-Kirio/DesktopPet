/// 凭据存储抽象（Phase 2）。
///
/// 目标：**令牌永远不落 SQLite、永远不进日志**。
/// SQLite 的 `account_session_state` 只保存一个 [CredentialStore] 用的条目名
/// （`credential_reference`），凭据内容交给系统级存储。
///
/// 后端优先级（见 `docs/19-隐私与安全说明.md`）：
/// 1. Windows Credential Manager（`CredWriteW` / `CredReadW` / `CredDeleteW`）；
/// 2. 不可用时退化为 DPAPI（`CryptProtectData`）加密后写入本地文件，密文绑定当前 Windows 用户；
/// 3. 测试使用内存实现，**不访问真实系统凭据**。
library;

/// 凭据存储失败。
///
/// 注意：[message] 里**只允许出现条目名与后端名**，
/// 绝不能带上凭据内容，否则令牌会顺着异常信息泄露到日志或 UI。
class CredentialStoreException implements Exception {
  const CredentialStoreException(this.message);

  final String message;

  @override
  String toString() => 'CredentialStoreException: $message';
}

/// 凭据存储接口。
abstract interface class CredentialStore {
  /// 后端名称，仅用于诊断展示（例如「Windows Credential Manager」）。
  String get backendName;

  /// 后端是否可用。
  bool get isAvailable;

  /// 写入（覆盖）一条凭据。
  Future<void> write(String key, String secret);

  /// 读取凭据；不存在时返回 null。
  Future<String?> read(String key);

  /// 删除凭据；条目不存在也算成功（幂等）。
  Future<void> delete(String key);
}

/// 测试与降级用的内存实现。
///
/// 供单元测试使用，**不触碰真实系统凭据**；
/// 也在所有原生后端都不可用时作为最后兜底（此时凭据只在进程内存中，
/// 退出即丢失，行为上等价于「每次都需重新登录」，但不会写坏任何数据）。
class InMemoryCredentialStore implements CredentialStore {
  InMemoryCredentialStore({this.backendName = 'memory'});

  final Map<String, String> _entries = <String, String>{};

  @override
  final String backendName;

  @override
  bool get isAvailable => true;

  /// 当前保存的条目名（测试断言用；不暴露内容）。
  List<String> get keys => _entries.keys.toList(growable: false);

  @override
  Future<void> write(String key, String secret) async {
    _entries[key] = secret;
  }

  @override
  Future<String?> read(String key) async => _entries[key];

  @override
  Future<void> delete(String key) async {
    _entries.remove(key);
  }

  @override
  String toString() => 'InMemoryCredentialStore(entries=${_entries.length})';
}

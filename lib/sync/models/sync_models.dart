import 'dart:convert';

/// Phase 2 同步相关的领域模型与枚举。
///
/// 约定：
/// * 远程身份一律用**稳定 UUID 或稳定业务键**，绝不用 SQLite 自增 ID；
/// * 本文件里不存在任何令牌字段——令牌只存在于 `CredentialStore` 中。

/// 可同步的实体类型（`entity_type` 的取值）。
enum SyncEntityType {
  activitySegment('activity_segment'),
  dailyUsage('daily_usage'),
  application('application');

  const SyncEntityType(this.wireName);

  /// 与服务端 `app/models/activity.py` 的 `ENTITY_*` 完全一致。
  final String wireName;

  static SyncEntityType? fromWire(String? value) {
    for (final SyncEntityType t in SyncEntityType.values) {
      if (t.wireName == value) return t;
    }
    return null;
  }
}

/// outbox 操作类型。当前只上传（不做远端删除），保留 delete 以便后续扩展。
enum SyncOperation {
  upsert('upsert'),
  delete('delete');

  const SyncOperation(this.wireName);

  final String wireName;

  static SyncOperation fromWire(String? value) =>
      value == 'delete' ? SyncOperation.delete : SyncOperation.upsert;
}

/// 同步引擎对外的状态（需求「六、同步引擎」）。
enum SyncStatus {
  /// 未登录。
  signedOut('未登录'),

  /// 已登录且没有进行中的任务。
  idle('空闲'),

  /// 正在同步。
  syncing('正在同步'),

  /// 上一次同步成功。
  success('同步成功'),

  /// 网络不可达或超时，会按指数退避重试。
  waitingForNetwork('等待网络'),

  /// Refresh Token 失效 / 设备被撤销，需要用户重新登录。
  needsReauthentication('需要重新登录'),

  /// 其它失败（服务端 5xx、格式错误等）。
  failed('同步失败');

  const SyncStatus(this.labelZh);

  final String labelZh;

  /// 是否属于「本地采集必须继续」的状态。
  ///
  /// 需求：Refresh Token 失效后提示重新登录，但**本地采集不停止**。
  /// 所有状态都要求本地采集继续，这里只是给 UI 一个显式语义。
  bool get keepsLocalTracking => true;
}

/// 同步失败的分类，决定是否重试以及退避策略。
enum SyncFailureKind {
  /// 连不上 / DNS 失败 / 连接被拒。
  network('网络不可达', retryable: true),

  /// 请求超时。
  timeout('请求超时', retryable: true),

  /// 代理不可达（Clash 没开、端口写错等）。
  ///
  /// 与普通 [network] 分开，是为了让界面能直说"连不上代理"，
  /// 而不是笼统地说"网络不可达"——两者的处置方式完全不同。
  proxyUnreachable('代理不可达', retryable: true),

  /// 代理要求认证（HTTP 407），但本地没有可用凭据或凭据被拒。
  proxyAuthRequired('代理需要认证', retryable: false),

  /// TLS 握手或证书校验失败。
  ///
  /// ⚠️ 客户端**不会**绕过证书校验，因此这个错误是"必须修好"的信号，
  /// 而不是"点一下忽略就行了"。
  tlsHandshakeFailed('TLS 握手失败', retryable: true),

  /// 401 且刷新后仍然失败。
  unauthorized('登录已失效', retryable: false, needsReauth: true),

  /// Refresh Token 失效（服务端明确告知）。
  refreshFailed('登录凭据已失效', retryable: false, needsReauth: true),

  /// 403 设备被撤销。
  deviceRevoked('设备已被撤销', retryable: false, needsReauth: true),

  /// 404（例如设备不存在）。
  notFound('资源不存在', retryable: false, needsReauth: true),

  /// 422 / 413 等请求本身有问题。
  requestRejected('请求被拒绝', retryable: false),

  /// 5xx。
  server('服务端错误', retryable: true),

  /// 响应无法解析。
  malformedResponse('响应格式异常', retryable: true),

  /// 其它未归类问题。
  unknown('未知错误', retryable: true);

  const SyncFailureKind(this.labelZh, {this.retryable = true, this.needsReauth = false});

  final String labelZh;

  /// 是否值得按指数退避重试。
  final bool retryable;

  /// 是否应进入「需要重新登录」。
  final bool needsReauth;

  /// 是否属于「网络类」问题（UI 上归入「等待网络」而不是「同步失败」）。
  ///
  /// 代理不可达与 TLS 失败都归到这里：它们同样是"环境问题，等一下/修一下就好"，
  /// 需要的是退避重试而不是提示用户重新登录。
  bool get isNetworkIssue =>
      this == SyncFailureKind.network ||
      this == SyncFailureKind.timeout ||
      this == SyncFailureKind.proxyUnreachable ||
      this == SyncFailureKind.tlsHandshakeFailed;
}

/// 本地账户会话（`account_session_state` 单行表）。
///
/// **不含任何令牌明文**：令牌只保存在 Windows 凭据存储里，
/// 这里仅保存它的引用名与过期时间（过期时间不敏感，且能让 UI 提前刷新）。
class AccountSession {
  const AccountSession({
    required this.serverBaseUrl,
    required this.userId,
    required this.email,
    this.displayName,
    this.deviceServerId,
    required this.credentialReference,
    this.accessTokenExpiresAt,
    required this.updatedAt,
  });

  final String serverBaseUrl;
  final String userId;
  final String email;
  final String? displayName;

  /// 服务端设备 UUID（登录后注册设备得到）。
  final String? deviceServerId;

  /// 凭据条目名（例如 `PetLife:account`），**不是**凭据内容。
  final String credentialReference;

  final DateTime? accessTokenExpiresAt;
  final DateTime updatedAt;

  AccountSession copyWith({
    String? serverBaseUrl,
    String? userId,
    String? email,
    String? displayName,
    String? deviceServerId,
    String? credentialReference,
    DateTime? accessTokenExpiresAt,
    DateTime? updatedAt,
  }) =>
      AccountSession(
        serverBaseUrl: serverBaseUrl ?? this.serverBaseUrl,
        userId: userId ?? this.userId,
        email: email ?? this.email,
        displayName: displayName ?? this.displayName,
        deviceServerId: deviceServerId ?? this.deviceServerId,
        credentialReference: credentialReference ?? this.credentialReference,
        accessTokenExpiresAt: accessTokenExpiresAt ?? this.accessTokenExpiresAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, Object?> toMap() => <String, Object?>{
        // 单行表：id 固定为 1（建表语句里有 CHECK (id = 1)）
        'id': 1,
        'server_base_url': serverBaseUrl,
        'user_id': userId,
        'email': email,
        'display_name': displayName,
        'device_server_id': deviceServerId,
        'credential_reference': credentialReference,
        'access_token_expires_at': accessTokenExpiresAt?.millisecondsSinceEpoch,
        'updated_at': updatedAt.millisecondsSinceEpoch,
      };

  static AccountSession fromMap(Map<String, Object?> m) => AccountSession(
        serverBaseUrl: m['server_base_url']! as String,
        userId: m['user_id']! as String,
        email: m['email']! as String,
        displayName: m['display_name'] as String?,
        deviceServerId: m['device_server_id'] as String?,
        credentialReference: m['credential_reference']! as String,
        accessTokenExpiresAt: m['access_token_expires_at'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(m['access_token_expires_at']! as int),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(m['updated_at']! as int),
      );
}

/// 每类实体的同步状态（`sync_state`）。
class SyncStateRow {
  const SyncStateRow({
    required this.entityType,
    this.cursor = 0,
    this.lastSuccessAt,
    this.lastError,
    this.consecutiveFailures = 0,
    this.nextRetryAt,
    required this.updatedAt,
  });

  final SyncEntityType entityType;

  /// 上次 pull 到的服务端游标。
  final int cursor;

  final DateTime? lastSuccessAt;
  final String? lastError;
  final int consecutiveFailures;
  final DateTime? nextRetryAt;
  final DateTime updatedAt;

  SyncStateRow copyWith({
    int? cursor,
    DateTime? lastSuccessAt,
    String? lastError,
    int? consecutiveFailures,
    DateTime? nextRetryAt,
    DateTime? updatedAt,
  }) =>
      SyncStateRow(
        entityType: entityType,
        cursor: cursor ?? this.cursor,
        lastSuccessAt: lastSuccessAt ?? this.lastSuccessAt,
        lastError: lastError,
        consecutiveFailures: consecutiveFailures ?? this.consecutiveFailures,
        nextRetryAt: nextRetryAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, Object?> toMap() => <String, Object?>{
        'entity_type': entityType.wireName,
        'cursor': cursor,
        'last_success_at': lastSuccessAt?.millisecondsSinceEpoch,
        'last_error': lastError,
        'consecutive_failures': consecutiveFailures,
        'next_retry_at': nextRetryAt?.millisecondsSinceEpoch,
        'updated_at': updatedAt.millisecondsSinceEpoch,
      };

  static SyncStateRow fromMap(Map<String, Object?> m) => SyncStateRow(
        entityType: SyncEntityType.fromWire(m['entity_type'] as String?) ??
            SyncEntityType.activitySegment,
        cursor: (m['cursor'] as int?) ?? 0,
        lastSuccessAt: m['last_success_at'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(m['last_success_at']! as int),
        lastError: m['last_error'] as String?,
        consecutiveFailures: (m['consecutive_failures'] as int?) ?? 0,
        nextRetryAt: m['next_retry_at'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(m['next_retry_at']! as int),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(m['updated_at']! as int),
      );
}

/// 待同步队列中的一条记录（`sync_outbox`）。
class OutboxEntry {
  const OutboxEntry({
    required this.id,
    required this.entityType,
    required this.entityKey,
    this.entityLocalId,
    this.operation = SyncOperation.upsert,
    required this.payload,
    required this.createdAt,
    this.attemptCount = 0,
    this.nextAttemptAt,
    this.lastError,
    this.acknowledgedAt,
  });

  /// 稳定 UUID（不是自增 ID）。
  final String id;
  final SyncEntityType entityType;

  /// 同一份远端记录的稳定业务键，用于去重排队。
  final String entityKey;

  /// 本地记录标识（活动段 UUID / `<device>:<day>` / app_key），便于诊断。
  final String? entityLocalId;

  final SyncOperation operation;

  /// 与服务端 push 体一致的单条 JSON。
  final Map<String, Object?> payload;

  final DateTime createdAt;
  final int attemptCount;
  final DateTime? nextAttemptAt;
  final String? lastError;

  /// 服务端确认后才置位；非空表示这条不用再传。
  final DateTime? acknowledgedAt;

  bool get isPending => acknowledgedAt == null;

  String get payloadJson => jsonEncode(payload);

  Map<String, Object?> toMap() => <String, Object?>{
        'id': id,
        'entity_type': entityType.wireName,
        'entity_key': entityKey,
        'entity_local_id': entityLocalId,
        'operation': operation.wireName,
        'payload_json': payloadJson,
        'created_at': createdAt.millisecondsSinceEpoch,
        'attempt_count': attemptCount,
        'next_attempt_at': (nextAttemptAt ?? createdAt).millisecondsSinceEpoch,
        'last_error': lastError,
        'acknowledged_at': acknowledgedAt?.millisecondsSinceEpoch,
      };

  static OutboxEntry fromMap(Map<String, Object?> m) => OutboxEntry(
        id: m['id']! as String,
        entityType:
            SyncEntityType.fromWire(m['entity_type'] as String?) ?? SyncEntityType.application,
        entityKey: m['entity_key']! as String,
        entityLocalId: m['entity_local_id'] as String?,
        operation: SyncOperation.fromWire(m['operation'] as String?),
        payload: (jsonDecode(m['payload_json']! as String) as Map<String, dynamic>)
            .cast<String, Object?>(),
        createdAt: DateTime.fromMillisecondsSinceEpoch(m['created_at']! as int),
        attemptCount: (m['attempt_count'] as int?) ?? 0,
        nextAttemptAt: m['next_attempt_at'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(m['next_attempt_at']! as int),
        lastError: m['last_error'] as String?,
        acknowledgedAt: m['acknowledged_at'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(m['acknowledged_at']! as int),
      );
}

/// 令牌对（只存在于内存与凭据存储之间，**绝不落 SQLite、绝不写日志**）。
class TokenPair {
  const TokenPair({
    required this.accessToken,
    required this.refreshToken,
    this.accessTokenExpiresAt,
  });

  final String accessToken;
  final String refreshToken;
  final DateTime? accessTokenExpiresAt;

  /// 凭据存储里的序列化形式。
  ///
  /// 注意：`toString()` 被刻意重写为不含令牌内容的字符串，
  /// 避免令牌通过异常信息或调试输出泄露（需求「不允许在异常对象中泄露令牌」）。
  String encode() => jsonEncode(<String, Object?>{
        'access_token': accessToken,
        'refresh_token': refreshToken,
        'access_token_expires_at': accessTokenExpiresAt?.millisecondsSinceEpoch,
      });

  static TokenPair? decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final Map<String, dynamic> map = jsonDecode(raw) as Map<String, dynamic>;
      final String? access = map['access_token'] as String?;
      final String? refresh = map['refresh_token'] as String?;
      if (access == null || refresh == null) return null;
      final Object? expires = map['access_token_expires_at'];
      return TokenPair(
        accessToken: access,
        refreshToken: refresh,
        accessTokenExpiresAt:
            expires is int ? DateTime.fromMillisecondsSinceEpoch(expires) : null,
      );
    } catch (_) {
      return null;
    }
  }

  @override
  String toString() => 'TokenPair(<redacted>)';
}

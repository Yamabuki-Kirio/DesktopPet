/// Phase 3（改版）：AI 数据访问密钥的客户端模型。
///
/// 约定
/// ----
/// * **明文密钥只在生成响应里出现一次**，因此它只活在 [ApiKeyCreated] 里，
///   而 [ApiKeyCreated] 只活在页面的内存中：不写 SQLite、不写偏好、退出登录即丢弃；
/// * 列表接口只回显 `key_prefix`（`plk_` + 8 位），因此 [ApiKeySummary]
///   里**没有**完整密钥字段——这是一条结构性保证，不是靠自觉；
/// * 两个类的 `toString()` 都刻意脱敏：密钥一旦进了日志，
///   等于把"读取全部使用统计"的凭据写进磁盘。
library;

/// 一把密钥的展示信息（不含明文）。
class ApiKeySummary {
  const ApiKeySummary({
    required this.id,
    required this.name,
    required this.keyPrefix,
    required this.scopes,
    this.createdAt,
    this.lastUsedAt,
    this.revokedAt,
  });

  /// 密钥记录 ID（用于撤销）
  final String id;

  /// 用户起的名字（例如「AstrBot」）
  final String name;

  /// 明文前 12 个字符，仅用于区分是哪把钥匙
  final String keyPrefix;

  final List<String> scopes;

  final DateTime? createdAt;

  /// 最近一次被用于鉴权的时间；从未用过时为 null
  final DateTime? lastUsedAt;

  final DateTime? revokedAt;

  bool get isActive => revokedAt == null;

  /// 权限的中文说明。当前服务端只发放只读统计权限。
  String get scopesLabel {
    if (scopes.isEmpty) return '无权限';
    return scopes
        .map((String s) => s == 'stats:read' ? '只读统计' : s)
        .join('、');
  }

  static ApiKeySummary fromJson(Map<String, Object?> json) => ApiKeySummary(
        id: (json['id'] as String?) ?? '',
        name: (json['name'] as String?) ?? '',
        keyPrefix: (json['key_prefix'] as String?) ?? '',
        scopes: _parseScopes(json['scopes']),
        createdAt: _parseIso(json['created_at']),
        lastUsedAt: _parseIso(json['last_used_at']),
        revokedAt: _parseIso(json['revoked_at']),
      );

  static List<ApiKeySummary> listFromEnvelope(Map<String, Object?> body) {
    final Object? items = body['items'];
    if (items is! List) return const <ApiKeySummary>[];
    return items
        .whereType<Map<dynamic, dynamic>>()
        .map((Map<dynamic, dynamic> e) =>
            ApiKeySummary.fromJson(e.cast<String, Object?>()))
        .toList(growable: false);
  }

  /// 只出现前缀与状态，永不出现完整密钥。
  @override
  String toString() => 'ApiKeySummary($keyPrefix…, active=$isActive)';
}

/// 生成响应：**唯一**携带明文密钥的地方。
class ApiKeyCreated {
  const ApiKeyCreated({required this.summary, required this.key});

  final ApiKeySummary summary;

  /// 完整密钥（`plk_...`）。只应存在于当前页面的内存中。
  final String key;

  static ApiKeyCreated fromJson(Map<String, Object?> json) => ApiKeyCreated(
        summary: ApiKeySummary.fromJson(json),
        key: (json['key'] as String?) ?? '',
      );

  /// 不暴露密钥本身（日志 / 异常里只会看到 `<redacted>`）。
  @override
  String toString() => 'ApiKeyCreated(${summary.keyPrefix}…, <redacted>)';
}

List<String> _parseScopes(Object? value) {
  if (value is! List) return const <String>[];
  return value
      .whereType<String>()
      .where((String s) => s.trim().isNotEmpty)
      .toList(growable: false);
}

DateTime? _parseIso(Object? value) {
  if (value is! String || value.isEmpty) return null;
  final DateTime? parsed = DateTime.tryParse(value);
  return parsed?.toUtc();
}

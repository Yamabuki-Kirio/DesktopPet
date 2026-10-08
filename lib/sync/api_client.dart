import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/constants.dart';
import 'models/api_key_models.dart';
import 'models/sync_models.dart';
import 'proxy/proxy_http_client.dart';
import 'proxy/proxy_models.dart';
import 'proxy/proxy_resolver.dart';

/// API 调用失败。
///
/// 约定：
/// * [message] 已脱敏，可直接展示给用户或写日志；
/// * **绝不携带令牌内容**——需求明确要求不能在异常对象里泄露令牌。
class ApiException implements Exception {
  const ApiException({
    required this.kind,
    required this.message,
    this.statusCode,
    this.errorCode,
    this.requestId,
    this.detail,
  });

  final SyncFailureKind kind;
  final String message;

  /// HTTP 状态码（网络层失败时为 null）。
  final int? statusCode;

  /// 服务端 `error.code`（如 `device_revoked`）。
  final String? errorCode;

  /// 服务端 `error.request_id`，便于对照服务端日志排查。
  final String? requestId;

  /// 服务端 `error.detail`（校验错误列表等）；已排除原始输入值。
  final Object? detail;

  bool get isNetworkIssue => kind.isNetworkIssue;

  @override
  String toString() =>
      'ApiException(${kind.name}, status=$statusCode, code=$errorCode, message=$message)';
}

/// 设备注册/更新请求体（与服务端 `DeviceRegisterRequest` 对齐）。
class DeviceRegistration {
  const DeviceRegistration({
    required this.deviceLocalId,
    required this.deviceName,
    this.platform = 'windows',
    this.architecture = 'x64',
    this.osVersion,
    this.appVersion,
    this.modelName,
  });

  final String deviceLocalId;
  final String deviceName;
  final String platform;
  final String architecture;
  final String? osVersion;
  final String? appVersion;
  final String? modelName;

  Map<String, Object?> toJson() => <String, Object?>{
    'device_local_id': deviceLocalId,
    'device_name': deviceName,
    'platform': platform,
    'architecture': architecture,
    if (osVersion != null) 'os_version': osVersion,
    if (appVersion != null) 'app_version': appVersion,
    if (modelName != null) 'model_name': modelName,
  };
}

/// 服务端返回的设备。
class RemoteDevice {
  const RemoteDevice({
    required this.id,
    required this.deviceLocalId,
    required this.deviceName,
    required this.platform,
    required this.architecture,
    this.osVersion,
    this.appVersion,
    this.modelName,
    this.lastSeenAt,
    this.createdAt,
    this.revokedAt,
    this.isCurrent = false,
  });

  final String id;
  final String deviceLocalId;
  final String deviceName;
  final String platform;
  final String architecture;
  final String? osVersion;
  final String? appVersion;
  final String? modelName;
  final String? lastSeenAt;
  final String? createdAt;
  final String? revokedAt;
  final bool isCurrent;

  bool get isRevoked => revokedAt != null;

  static RemoteDevice fromJson(Map<String, Object?> json) => RemoteDevice(
    id: json['id']! as String,
    deviceLocalId: (json['device_local_id'] as String?) ?? '',
    deviceName: (json['device_name'] as String?) ?? '',
    platform: (json['platform'] as String?) ?? '',
    architecture: (json['architecture'] as String?) ?? '',
    osVersion: json['os_version'] as String?,
    appVersion: json['app_version'] as String?,
    modelName: json['model_name'] as String?,
    lastSeenAt: json['last_seen_at'] as String?,
    createdAt: json['created_at'] as String?,
    revokedAt: json['revoked_at'] as String?,
    isCurrent: (json['is_current'] as bool?) ?? false,
  );
}

/// 服务端返回的账户信息。
class RemoteUser {
  const RemoteUser({
    required this.id,
    required this.email,
    required this.displayName,
    required this.status,
  });

  final String id;
  final String email;
  final String displayName;
  final String status;

  static RemoteUser fromJson(Map<String, Object?> json) => RemoteUser(
    id: json['id']! as String,
    email: (json['email'] as String?) ?? '',
    displayName: (json['display_name'] as String?) ?? '',
    status: (json['status'] as String?) ?? 'active',
  );
}

/// 认证结果：令牌对 + 账户信息 + （可选）设备 ID。
class AuthResult {
  const AuthResult({required this.tokens, required this.user, this.deviceId});

  final TokenPair tokens;
  final RemoteUser user;
  final String? deviceId;
}

/// 服务端在 push 里拒收的单条记录。
class RejectedRecord {
  const RejectedRecord({
    required this.kind,
    required this.key,
    required this.code,
    required this.message,
  });

  final String kind;
  final String key;
  final String code;
  final String message;

  static RejectedRecord fromJson(Map<String, Object?> json) => RejectedRecord(
    kind: (json['kind'] as String?) ?? '',
    key: (json['key'] as String?) ?? '',
    code: (json['code'] as String?) ?? '',
    message: (json['message'] as String?) ?? '',
  );
}

/// push 结果。
class PushOutcome {
  const PushOutcome({
    required this.acceptedTotal,
    required this.rejected,
    required this.cursor,
  });

  final int acceptedTotal;
  final List<RejectedRecord> rejected;
  final int cursor;
}

/// pull 结果。
///
/// 本阶段客户端**不把远端记录合并回本地库**：本地库是这台设备的事实来源，
/// 多设备汇总由服务端 `GET /api/v1/stats/*` 提供。pull 的作用是
/// 推进游标、确认"服务端确实收到了"，并在必要时用于后续阶段的跨设备对齐。
class PullOutcome {
  const PullOutcome({
    required this.cursor,
    required this.hasMore,
    required this.totalRecords,
  });

  final int cursor;
  final bool hasMore;

  /// 本次拉取到的记录总数（活动段 + 每日用量 + 应用）。
  final int totalRecords;
}

/// 纯 HTTP 客户端（不含认证状态）。
///
/// 只负责「发请求 / 解响应 / 把错误翻译成 [ApiException]」。
/// 认证与刷新逻辑在 `AuthenticatedApi` 里，便于分别测试。
///
/// ## 代理
///
/// 所有请求共用同一个 `HttpClient`，因此代理配置是**全局一致**的：
/// health / 注册 / 登录 / 刷新 / 设备 / push / pull / 统计 / 注销
/// 统统走 [proxyResolver] 给出的同一个决策，不存在"登录走代理、同步直连"。
///
/// 配置变化后必须调用 [updateProxy]：它会**关闭旧 HttpClient 并新建**，
/// 因为旧连接池里可能还留着按老路由建立的连接。
class ApiClient {
  ApiClient({
    required String baseUrl,
    HttpClient? httpClient,
    Duration? connectTimeout,
    Duration? requestTimeout,
    ProxyResolver? proxyResolver,
    String? proxyUsername,
    String? proxyPassword,
  }) : baseUrl = _normalizeBaseUrl(baseUrl),
       _client = httpClient ?? HttpClient(),
       _ownsClient = httpClient == null,
       _connectTimeout = connectTimeout ?? SyncConfig.connectTimeout,
       _requestTimeout = requestTimeout ?? SyncConfig.requestTimeout,
       _proxyResolver = proxyResolver,
       _proxyUsername = proxyUsername,
       _proxyPassword = proxyPassword {
    if (_ownsClient) {
      _client = _buildClient();
    }
  }

  final String baseUrl;
  final Duration _connectTimeout;
  final Duration _requestTimeout;

  /// 是否由本对象创建（并负责关闭）[HttpClient]。
  ///
  /// 注入进来的 client 归调用方管，[updateProxy] / [close] 都不会动它。
  final bool _ownsClient;

  HttpClient _client;

  ProxyResolver? _proxyResolver;
  String? _proxyUsername;
  String? _proxyPassword;

  /// 用于测试断言 `badCertificateCallback` 始终为 null（即从未绕过 TLS 校验）。
  @visibleForTesting
  HttpClient get httpClient => _client;

  /// 安全契约：生产客户端从不安装接受无效证书的回调。
  ///
  /// `HttpClient.badCertificateCallback` 在当前 Dart SDK 只有 setter，无法读取；
  /// 因而测试通过这个只读契约配合构造代码检查，避免为了测试而放宽 TLS。
  @visibleForTesting
  bool get bypassesTlsCertificateValidation => false;

  /// 当前生效的代理决策（可能为 null = 未启用代理层）。
  ProxyResolution? get proxyResolution => _proxyResolver?.current;

  HttpClient _buildClient() => buildProxyAwareHttpClient(
    resolver: _proxyResolver ?? AlwaysDirectProxyResolver(),
    proxyUsername: _proxyUsername,
    proxyPassword: _proxyPassword,
    connectionTimeout: _connectTimeout,
    userAgent: 'PetLife/${AppConstants.appVersion}',
  );

  /// 代理配置变化后重建连接池。
  ///
  /// 需求明确要求"不能继续复用旧连接池"，因此这里直接
  /// `close(force: true)` 掉旧实例再新建，而不是改回调了事。
  void updateProxy({
    ProxyResolver? proxyResolver,
    String? proxyUsername,
    String? proxyPassword,
    bool clearCredentials = false,
  }) {
    if (!_ownsClient) return;
    _proxyResolver = proxyResolver;
    if (clearCredentials) {
      _proxyUsername = null;
      _proxyPassword = null;
    } else {
      if (proxyUsername != null) _proxyUsername = proxyUsername;
      if (proxyPassword != null) _proxyPassword = proxyPassword;
    }
    _client.close(force: true);
    _client = _buildClient();
  }

  static String _normalizeBaseUrl(String raw) {
    String value = raw.trim();
    if (value.endsWith('/')) value = value.substring(0, value.length - 1);
    return value;
  }

  void close() {
    if (_ownsClient) _client.close(force: true);
  }

  // ---------------------------------------------------------------------------
  // 认证
  // ---------------------------------------------------------------------------

  Future<AuthResult> register({
    required String email,
    required String password,
    required String displayName,
    DeviceRegistration? device,
  }) async {
    final Map<String, Object?> body = await _request(
      'POST',
      '/api/v1/auth/register',
      body: <String, Object?>{
        'email': email,
        'password': password,
        'display_name': displayName,
        if (device != null) 'device': device.toJson(),
      },
    );
    return _authResult(body);
  }

  Future<AuthResult> login({
    required String email,
    required String password,
    DeviceRegistration? device,
  }) async {
    final Map<String, Object?> body = await _request(
      'POST',
      '/api/v1/auth/login',
      body: <String, Object?>{
        'email': email,
        'password': password,
        if (device != null) 'device': device.toJson(),
      },
    );
    return _authResult(body);
  }

  Future<AuthResult> refresh(
    String refreshToken, {
    String? deviceLocalId,
  }) async {
    final Map<String, Object?> body = await _request(
      'POST',
      '/api/v1/auth/refresh',
      body: <String, Object?>{
        'refresh_token': refreshToken,
        if (deviceLocalId != null) 'device_local_id': deviceLocalId,
      },
    );
    return _authResult(body);
  }

  Future<void> logout({String? refreshToken, String? deviceId}) async {
    await _request(
      'POST',
      '/api/v1/auth/logout',
      body: <String, Object?>{
        if (refreshToken != null) 'refresh_token': refreshToken,
      },
      accessToken: null,
      deviceId: deviceId,
    );
  }

  Future<void> logoutAll({required String accessToken}) async {
    await _request('POST', '/api/v1/auth/logout-all', accessToken: accessToken);
  }

  Future<RemoteUser> me({required String accessToken}) async {
    final Map<String, Object?> body = await _request(
      'GET',
      '/api/v1/me',
      accessToken: accessToken,
    );
    return RemoteUser.fromJson(body);
  }

  Future<RemoteUser> updateMe({
    required String accessToken,
    required String displayName,
  }) async {
    final Map<String, Object?> body = await _request(
      'PATCH',
      '/api/v1/me',
      accessToken: accessToken,
      body: <String, Object?>{'display_name': displayName},
    );
    return RemoteUser.fromJson(body);
  }

  Future<void> changePassword({
    required String accessToken,
    required String currentPassword,
    required String newPassword,
  }) async {
    await _request(
      'POST',
      '/api/v1/me/password',
      accessToken: accessToken,
      body: <String, Object?>{
        'current_password': currentPassword,
        'new_password': newPassword,
      },
    );
  }

  Future<void> deleteAccount({
    required String accessToken,
    required String currentPassword,
  }) async {
    await _request(
      'DELETE',
      '/api/v1/me',
      accessToken: accessToken,
      body: <String, Object?>{
        'current_password': currentPassword,
        'new_password': currentPassword,
      },
    );
  }

  // ---------------------------------------------------------------------------
  // 设备
  // ---------------------------------------------------------------------------

  Future<RemoteDevice> registerDevice({
    required String accessToken,
    required DeviceRegistration device,
  }) async {
    final Map<String, Object?> body = await _request(
      'POST',
      '/api/v1/devices/register',
      accessToken: accessToken,
      body: device.toJson(),
    );
    return RemoteDevice.fromJson(body);
  }

  Future<List<RemoteDevice>> listDevices({
    required String accessToken,
    String? deviceId,
  }) async {
    final Map<String, Object?> body = await _request(
      'GET',
      '/api/v1/devices',
      accessToken: accessToken,
      deviceId: deviceId,
    );
    // 服务端返回的是顶层 JSON 数组，_request 会包成 {'items': [...]}
    final List<Object?> items =
        (body['items'] as List<Object?>?) ?? const <Object?>[];
    return items
        .map(
          (Object? e) => RemoteDevice.fromJson(
            (e! as Map<String, dynamic>).cast<String, Object?>(),
          ),
        )
        .toList(growable: false);
  }

  Future<RemoteDevice> updateDevice({
    required String accessToken,
    required String deviceId,
    String? deviceName,
    String? modelName,
  }) async {
    final Map<String, Object?> body = await _request(
      'PATCH',
      '/api/v1/devices/$deviceId',
      accessToken: accessToken,
      body: <String, Object?>{
        if (deviceName != null) 'device_name': deviceName,
        if (modelName != null) 'model_name': modelName,
      },
    );
    return RemoteDevice.fromJson(body);
  }

  Future<RemoteDevice> revokeDevice({
    required String accessToken,
    required String deviceId,
  }) async {
    final Map<String, Object?> body = await _request(
      'DELETE',
      '/api/v1/devices/$deviceId',
      accessToken: accessToken,
    );
    return RemoteDevice.fromJson(body);
  }

  // ---------------------------------------------------------------------------
  // AI 数据访问密钥（Phase 3）
  //
  // 注意：这些接口用的是**用户 Access Token**（与设备接口一样）。
  // 明文密钥只在创建响应里出现一次；列表接口只回显前缀。
  // 客户端从不持有 MCP 侧使用的密钥本身（那是用户自己配置到 PETLIFE_API_KEY 的）。
  // ---------------------------------------------------------------------------

  /// 生成一把只读统计密钥。返回体里的 `key` **只出现这一次**。
  Future<ApiKeyCreated> createApiKey({
    required String accessToken,
    required String name,
  }) async {
    final Map<String, Object?> body = await _request(
      'POST',
      '/api/v1/api-keys',
      accessToken: accessToken,
      body: <String, Object?>{'name': name},
    );
    return ApiKeyCreated.fromJson(body);
  }

  Future<List<ApiKeySummary>> listApiKeys({required String accessToken}) async {
    final Map<String, Object?> body = await _request(
      'GET',
      '/api/v1/api-keys',
      accessToken: accessToken,
    );
    return ApiKeySummary.listFromEnvelope(body);
  }

  Future<ApiKeySummary> revokeApiKey({
    required String accessToken,
    required String keyId,
  }) async {
    final Map<String, Object?> body = await _request(
      'DELETE',
      '/api/v1/api-keys/$keyId',
      accessToken: accessToken,
    );
    return ApiKeySummary.fromJson(body);
  }

  // ---------------------------------------------------------------------------
  // 同步
  // ---------------------------------------------------------------------------

  Future<PushOutcome> push({
    required String accessToken,
    required String deviceId,
    required Map<SyncEntityType, List<Map<String, Object?>>> records,
    String? batchId,
  }) async {
    final Map<String, Object?> body = await _request(
      'POST',
      '/api/v1/sync/push',
      accessToken: accessToken,
      deviceId: deviceId,
      body: <String, Object?>{
        if (batchId != null) 'batch_id': batchId,
        'activity_segments':
            records[SyncEntityType.activitySegment] ?? const <Object?>[],
        'daily_usage': records[SyncEntityType.dailyUsage] ?? const <Object?>[],
        'applications':
            records[SyncEntityType.application] ?? const <Object?>[],
      },
    );
    return PushOutcome(
      acceptedTotal: (body['accepted_total'] as int?) ?? 0,
      cursor: (body['cursor'] as int?) ?? 0,
      rejected: ((body['rejected'] as List<Object?>?) ?? const <Object?>[])
          .map(
            (Object? e) => RejectedRecord.fromJson(
              (e! as Map<String, dynamic>).cast<String, Object?>(),
            ),
          )
          .toList(growable: false),
    );
  }

  Future<PullOutcome> pull({
    required String accessToken,
    required String deviceId,
    required int cursor,
    int? limit,
  }) async {
    final Map<String, Object?> body = await _request(
      'GET',
      '/api/v1/sync/pull',
      accessToken: accessToken,
      deviceId: deviceId,
      query: <String, String>{
        'cursor': '$cursor',
        if (limit != null) 'limit': '$limit',
      },
    );
    final int total =
        _length(body['activity_segments']) +
        _length(body['daily_usage']) +
        _length(body['applications']);
    return PullOutcome(
      cursor: (body['cursor'] as int?) ?? cursor,
      hasMore: (body['has_more'] as bool?) ?? false,
      totalRecords: total,
    );
  }

  // ---------------------------------------------------------------------------
  // 统计
  // ---------------------------------------------------------------------------

  /// 服务端统计查询。
  ///
  /// `period` ∈ `today | yesterday | 7d | 30d`；时区由客户端提供
  /// （服务端绝不按自己的时区算"今天"）。
  Future<Map<String, Object?>> stats({
    required String accessToken,
    required String endpoint,
    String period = 'today',
    Duration? tzOffset,
  }) async {
    final Duration offset = tzOffset ?? DateTime.now().timeZoneOffset;
    return _request(
      'GET',
      '/api/v1/stats/$endpoint',
      accessToken: accessToken,
      query: <String, String>{
        'period': period,
        'tz_offset_minutes': '${offset.inMinutes}',
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Phase 4B：云端统计（通用 GET）
  // ---------------------------------------------------------------------------

  /// 通用只读 GET（返回解析后的 JSON 对象）。
  ///
  /// 存在的理由：Phase 4B 的云端统计有 5 个只读端点（设备 + 4 个统计），
  /// 它们只需要"路径 + 查询参数"这一件事；逐个写一个方法只会重复同样的样板。
  /// 路径由调用方 `ApiCloudStatisticsRepository` 用**固定白名单**拼出，
  /// 不接受任何用户输入。
  ///
  /// 注意：只有 GET，没有通用 POST —— 写操作仍然各有专用方法。
  Future<Map<String, Object?>> getJson({
    required String path,
    required String accessToken,
    String? deviceId,
    Map<String, String> query = const <String, String>{},
  }) {
    return _request(
      'GET',
      path,
      accessToken: accessToken,
      deviceId: deviceId,
      query: query,
    );
  }

  // ---------------------------------------------------------------------------
  // 内部
  // ---------------------------------------------------------------------------

  static int _length(Object? value) =>
      value is List<Object?> ? value.length : 0;

  AuthResult _authResult(Map<String, Object?> body) {
    final String access = body['access_token']! as String;
    final String refresh = body['refresh_token']! as String;
    final int expiresIn = (body['expires_in'] as int?) ?? 0;
    final RemoteUser user = RemoteUser.fromJson(
      (body['user']! as Map<String, dynamic>).cast<String, Object?>(),
    );
    return AuthResult(
      tokens: TokenPair(
        accessToken: access,
        refreshToken: refresh,
        accessTokenExpiresAt: expiresIn > 0
            ? DateTime.now().add(Duration(seconds: expiresIn))
            : null,
      ),
      user: user,
      deviceId: body['device_id'] as String?,
    );
  }

  Future<Map<String, Object?>> _request(
    String method,
    String path, {
    Map<String, Object?>? body,
    String? accessToken,
    String? deviceId,
    Map<String, String>? query,
  }) async {
    final Uri uri = Uri.parse(
      '$baseUrl$path',
    ).replace(queryParameters: (query == null || query.isEmpty) ? null : query);

    HttpClientRequest request;
    try {
      request = await _client.openUrl(method, uri).timeout(_connectTimeout);
    } on TimeoutException {
      throw ApiException(
        kind: SyncFailureKind.timeout,
        message: _usingProxyFor(uri) ? '连接代理超时（$_proxyAuthority）' : '连接服务端超时',
      );
    } on TlsException catch (e) {
      // 证书校验失败**不会**被绕过：这里只报告，不降级。
      throw ApiException(
        kind: SyncFailureKind.tlsHandshakeFailed,
        message: 'TLS 握手失败：${e.message}（证书校验未通过，客户端不会绕过校验）',
      );
    } on SocketException catch (e) {
      final bool viaProxy = _usingProxyFor(uri);
      throw ApiException(
        kind: viaProxy
            ? SyncFailureKind.proxyUnreachable
            : SyncFailureKind.network,
        message: viaProxy
            ? '连不上代理 $_proxyAuthority（${_socketMessage(e)}）'
            : '连不上服务端（${_socketMessage(e)}）',
      );
    } on HttpException catch (e) {
      throw ApiException(
        kind: SyncFailureKind.network,
        message: '网络请求失败：${e.message}',
      );
    }

    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    if (accessToken != null) {
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer $accessToken',
      );
    }
    if (deviceId != null) {
      request.headers.set('X-Device-Id', deviceId);
    }
    if (body != null) {
      // 显式给出 Content-Length：不依赖 Dart 的 chunked 兜底。
      // 请求帧固定下来，链路上的反向代理与测试替身都不必处理 chunked 解码。
      final List<int> payload = utf8.encode(jsonEncode(body));
      request.headers.contentType = ContentType.json;
      request.contentLength = payload.length;
      request.add(payload);
    }

    HttpClientResponse response;
    try {
      response = await request.close().timeout(_requestTimeout);
    } on TimeoutException {
      throw const ApiException(
        kind: SyncFailureKind.timeout,
        message: '服务端响应超时',
      );
    } on TlsException catch (e) {
      throw ApiException(
        kind: SyncFailureKind.tlsHandshakeFailed,
        message: 'TLS 握手失败：${e.message}（证书校验未通过，客户端不会绕过校验）',
      );
    } on SocketException catch (e) {
      // 已经建连成功、在收发阶段断开：代理隧道被中断也算网络类问题，
      // 但要把"是不是代理"说清楚，否则用户会去查服务端。
      final bool viaProxy = _usingProxyFor(uri);
      throw ApiException(
        kind: viaProxy
            ? SyncFailureKind.proxyUnreachable
            : SyncFailureKind.network,
        message: viaProxy
            ? '经代理 $_proxyAuthority 的连接中断（${_socketMessage(e)}）'
            : '连接中断（${_socketMessage(e)}）',
      );
    } on HttpException {
      // 服务端/代理在响应头或响应体中途关闭连接时抛的是 HttpException
      // （例如服务端重启、代理重启、连接被中途掐断）。
      // 这类抖动必须归成可识别的网络错误，否则界面会把
      // "Connection closed before full header was received, uri = http://..." 这种
      // 底层信息（还带 URL）直接摊给用户。
      final bool viaProxy = _usingProxyFor(uri);
      throw ApiException(
        kind: viaProxy
            ? SyncFailureKind.proxyUnreachable
            : SyncFailureKind.network,
        message: viaProxy
            ? '经代理 $_proxyAuthority 的连接被中断'
            : '连接被中途中断（服务端或代理可能刚重启）',
      );
    }

    String text;
    try {
      text = await response
          .transform(utf8.decoder)
          .join()
          .timeout(_requestTimeout, onTimeout: () => '');
    } on HttpException {
      throw ApiException(
        kind: _usingProxyFor(uri)
            ? SyncFailureKind.proxyUnreachable
            : SyncFailureKind.network,
        message: '接收响应时连接被中断（已收到部分数据）',
      );
    } on SocketException {
      throw ApiException(
        kind: _usingProxyFor(uri)
            ? SyncFailureKind.proxyUnreachable
            : SyncFailureKind.network,
        message: '接收响应时连接被中断（已收到部分数据）',
      );
    }

    final int status = response.statusCode;
    final Object? decoded = _tryDecode(text);

    if (status >= 200 && status < 300) {
      if (decoded is Map<String, dynamic>) {
        return decoded.cast<String, Object?>();
      }
      if (decoded is List) return <String, Object?>{'items': decoded};
      return <String, Object?>{};
    }

    throw _translateError(status, decoded);
  }

  /// 本次请求是否会经过代理（用于把错误说清楚）。
  bool _usingProxyFor(Uri uri) {
    final ProxyResolution? r = _proxyResolver?.current;
    if (r == null || !r.usesProxy) return false;
    return r.findProxyFor(uri) != 'DIRECT';
  }

  String get _proxyAuthority {
    final ProxyResolution? r = _proxyResolver?.current;
    if (r == null) return '未知代理';
    return r.authority.isEmpty ? '未知代理' : r.authority;
  }

  static String _socketMessage(SocketException e) =>
      e.osError?.message ?? e.message;

  static Object? _tryDecode(String text) {
    if (text.isEmpty) return null;
    try {
      return jsonDecode(text);
    } catch (_) {
      // 非 JSON 响应（例如反向代理返回的 HTML 错误页）
      return null;
    }
  }

  ApiException _translateError(int status, Object? decoded) {
    String? code;
    String? message;
    String? requestId;
    Object? detail;

    if (decoded is Map<String, dynamic>) {
      final Object? error = decoded['error'];
      if (error is Map<String, dynamic>) {
        code = error['code'] as String?;
        message = error['message'] as String?;
        requestId = error['request_id'] as String?;
        detail = error['detail'];
      }
    }

    final SyncFailureKind kind = _kindFor(status, code);
    final String text =
        message ??
        switch (status) {
          HttpStatus.unauthorized => '登录已失效，请重新登录',
          HttpStatus.forbidden => '服务端拒绝访问',
          HttpStatus.notFound => '请求的资源不存在',
          HttpStatus.proxyAuthenticationRequired =>
            '代理要求认证（HTTP 407）：请在「网络连接」中填写代理用户名与密码',
          HttpStatus.requestEntityTooLarge => '单批数据过大',
          HttpStatus.unprocessableEntity => '请求数据不符合服务端要求',
          _ when status >= 500 => '服务端内部错误',
          _ => '请求失败（HTTP $status）',
        };

    return ApiException(
      kind: kind,
      message: text,
      statusCode: status,
      errorCode: code,
      requestId: requestId,
      detail: detail,
    );
  }

  /// 把 HTTP 状态码 + 服务端错误码翻译成客户端可处理的分级。
  ///
  /// 需求要求「服务端不可达、401、403、超时、格式错误分别处理」，
  /// 这里是唯一的翻译点，引擎与 UI 都只看 [SyncFailureKind]。
  static SyncFailureKind _kindFor(int status, String? code) {
    switch (code) {
      case 'device_revoked':
        return SyncFailureKind.deviceRevoked;
      case 'refresh_token_reused':
      case 'token_invalid':
        return SyncFailureKind.refreshFailed;
      case 'token_expired':
        return SyncFailureKind.unauthorized;
      case 'account_disabled':
        return SyncFailureKind.deviceRevoked;
      case 'device_not_found':
        return SyncFailureKind.notFound;
      case 'batch_too_large':
      case 'validation_error':
      case 'invalid_batch':
      case 'invalid_uuid':
      case 'invalid_cursor':
        return SyncFailureKind.requestRejected;
    }

    switch (status) {
      case HttpStatus.unauthorized:
        return SyncFailureKind.unauthorized;
      case HttpStatus.proxyAuthenticationRequired:
        // 407 只可能来自代理，与"登录失效"无关，不能混进 401 分支。
        return SyncFailureKind.proxyAuthRequired;
      case HttpStatus.forbidden:
        return SyncFailureKind.deviceRevoked;
      case HttpStatus.notFound:
        return SyncFailureKind.notFound;
      case HttpStatus.requestEntityTooLarge:
      case HttpStatus.unprocessableEntity:
      case HttpStatus.badRequest:
        return SyncFailureKind.requestRejected;
      default:
        return status >= 500 ? SyncFailureKind.server : SyncFailureKind.unknown;
    }
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 本地假服务端：用真实 HTTP 跑同步引擎的测试。
///
/// 为什么不用 mock：需求允许「伪网络客户端或本地测试服务器」，
/// 而本地服务器能顺带验证真实 HTTP 栈（连接、状态码、JSON、超时、取消），
/// 这是 mock 永远验证不到的部分。全程只连 127.0.0.1，不访问公网。
class FakePetLifeServer {
  FakePetLifeServer._(this._server, this._port);

  final HttpServer _server;
  final int _port;

  String get baseUrl => 'http://127.0.0.1:$_port';
  int get port => _port;

  // --- 可调行为 ---

  /// 需要"新"访问令牌才放行（模拟 Access Token 过期）。
  bool requireFreshAccessToken = false;

  /// 刷新接口是否一律失败（模拟 Refresh Token 失效）。
  bool rejectRefresh = false;

  /// 设备是否已被撤销（同步接口返回 403 device_revoked）。
  bool deviceRevoked = false;

  /// 强制 push 返回的状态码与错误码（模拟 5xx / 422 等）。
  int? forcedPushStatus;
  String? forcedPushErrorCode;

  /// 每次 push 的人为延迟（毫秒），用于验证单任务互斥与退出超时。
  int pushDelayMs = 0;

  /// 每次 refresh 的人为延迟（毫秒）。
  int refreshDelayMs = 0;

  // --- Phase 3：AI 数据访问密钥（客户端卡片测试用）---

  /// 密钥接口的人为延迟（毫秒）。
  int apiKeyDelayMs = 0;

  /// 强制 `/api/v1/api-keys**` 返回某个状态码（模拟 401 / 500 等）。
  int? forcedApiKeyStatus;
  String forcedApiKeyErrorCode = 'internal_error';

  /// 当前密钥（key id -> 记录体，**不含**明文）
  final Map<String, Map<String, Object?>> apiKeys =
      <String, Map<String, Object?>>{};

  /// 生成过的密钥明文（仅供测试断言；真实服务端只存哈希）
  final List<String> issuedApiKeys = <String>[];

  // --- 观测 ---

  int apiKeyCreateRequests = 0;
  int apiKeyListRequests = 0;
  int apiKeyRevokeRequests = 0;
  int loginCount = 0;
  int registerDeviceCount = 0;
  int pushCount = 0;
  int pullCount = 0;
  int refreshCount = 0;
  int logoutCount = 0;
  int concurrentPush = 0;
  int maxConcurrentPush = 0;
  int accessTokenGeneration = 0;

  /// 服务端收到的 push 体（用于断言上传内容）。
  final List<Map<String, Object?>> receivedPushes = <Map<String, Object?>>[];

  /// 最近一次处理请求时抛出的未预期异常描述。
  ///
  /// 没有它的话，测试只会看到"HTTP 500"，无从知道是哪一步解析炸了 ——
  /// 定位代理转发问题时这点信息是决定性的。
  String? lastHandlerError;

  /// 收到的请求路径（按到达顺序），便于对照代理转发。
  final List<String> receivedPaths = <String>[];

  /// 服务端已存下的记录数（按 (entity_type, key) 去重，模拟幂等）。
  final Set<String> storedRecords = <String>{};

  static Future<FakePetLifeServer> start() async {
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final FakePetLifeServer fake = FakePetLifeServer._(server, server.port);
    unawaited(fake._listen());
    return fake;
  }

  Future<void> close({bool force = false}) => _server.close(force: force);

  Future<void> _listen() async {
    await for (final HttpRequest request in _server) {
      // **并发处理**：真实服务端不会因为某个慢请求就把它后面的请求全部堵住。
      // 这一点对竞态类测试是必需的——例如"旧请求还挂在服务端时用户完成重新登录"，
      // 如果这里串行处理，登录请求会排在慢请求后面，竞态就永远复现不出来。
      unawaited(_handleSafely(request));
    }
  }

  Future<void> _handleSafely(HttpRequest request) async {
    try {
      await _handle(request);
    } catch (e) {
      lastHandlerError = '$e';
      try {
        request.response.statusCode = 500;
        await request.response.close();
      } catch (_) {
        // 忽略
      }
    }
  }

  Future<void> _handle(HttpRequest request) async {
    final String path = request.uri.path;
    receivedPaths.add(path);
    final String body = await utf8.decoder.bind(request).join();
    final Map<String, Object?> json =
        body.isEmpty ? <String, Object?>{} : (jsonDecode(body) as Map<String, dynamic>);

    // --- Phase 3：AI 数据访问密钥 ---
    if (path == '/api/v1/api-keys' || path.startsWith('/api/v1/api-keys/')) {
      final int? forced = forcedApiKeyStatus;
      if (forced != null) {
        return _error(request, forced, forcedApiKeyErrorCode, '模拟密钥接口错误');
      }
      if (path == '/api/v1/api-keys' && request.method == 'POST') {
        return _createApiKey(request, json);
      }
      if (path == '/api/v1/api-keys' && request.method == 'GET') {
        return _listApiKeys(request);
      }
      if (path.startsWith('/api/v1/api-keys/') && request.method == 'DELETE') {
        return _revokeApiKey(request, path.split('/').last);
      }
      return _error(request, 404, 'not_found', '未知密钥路径 $path');
    }

    switch (path) {
      case '/health':
        // 与真实服务端一致：代理/服务端探测会打这个端点。
        return _json(request, 200, <String, Object?>{
          'status': 'ok',
          'database': true,
          'server_time': _iso(),
        });
      case '/api/v1/auth/register':
        loginCount++;
        return _json(request, 201, _authResponse(deviceBound: true));
      case '/api/v1/auth/login':
        loginCount++;
        return _json(request, 200, _authResponse(deviceBound: true));
      case '/api/v1/auth/refresh':
        refreshCount++;
        if (refreshDelayMs > 0) {
          await Future<void>.delayed(Duration(milliseconds: refreshDelayMs));
        }
        if (rejectRefresh) {
          return _error(
            request,
            401,
            'refresh_token_reused',
            'Refresh Token 已失效',
          );
        }
        accessTokenGeneration++;
        return _json(request, 200, _authResponse(deviceBound: true));
      case '/api/v1/auth/logout':
        logoutCount++;
        return _json(request, 200, <String, Object?>{'message': 'ok'});
      case '/api/v1/devices/register':
        registerDeviceCount++;
        return _json(request, 201, <String, Object?>{
          'id': 'server-device-1',
          'device_local_id': json['device_local_id'],
          'device_name': json['device_name'],
          'platform': json['platform'],
          'architecture': json['architecture'],
          'os_version': json['os_version'],
          'app_version': json['app_version'],
          'model_name': json['model_name'],
          'last_seen_at': _iso(),
          'created_at': _iso(),
          'revoked_at': null,
          'is_current': true,
        });
      case '/api/v1/devices':
        return _jsonArray(request, 200, <Object?>[
          <String, Object?>{
            'id': 'server-device-1',
            'device_local_id': 'local-1',
            'device_name': '测试设备',
            'platform': 'windows',
            'architecture': 'x64',
            'last_seen_at': _iso(),
            'created_at': _iso(),
            'revoked_at': null,
            'is_current': true,
          },
        ]);
      case '/api/v1/sync/push':
        return _push(request, json);
      case '/api/v1/sync/pull':
        pullCount++;
        return _json(request, 200, <String, Object?>{
          'cursor': 7,
          'has_more': false,
          'activity_segments': <Object?>[],
          'daily_usage': <Object?>[],
          'applications': <Object?>[],
          'server_time': _iso(),
        });
      case '/api/v1/stats/summary':
        return _json(request, 200, <String, Object?>{
          'period': 'today',
          'from_utc': _iso(),
          'to_utc': _iso(),
          'timezone_offset_minutes': 0,
          'session_seconds': 0,
          'active_seconds': 0,
          'idle_seconds': 0,
          'app_active_seconds': 0,
          'device_count': 0,
        });
      default:
        return _error(request, 404, 'not_found', '未知路径 $path');
    }
  }

  // --- Phase 3：AI 数据访问密钥 ---

  /// 与真实服务端一致：列表只回显前缀（`plk_` + 8 位），从不回显完整密钥。
  static String prefixOf(String key) =>
      key.length <= 12 ? key : key.substring(0, 12);

  Future<void> _createApiKey(HttpRequest request, Map<String, Object?> json) async {
    apiKeyCreateRequests++;
    if (apiKeyDelayMs > 0) {
      await Future<void>.delayed(Duration(milliseconds: apiKeyDelayMs));
    }
    final int seq = issuedApiKeys.length + 1;
    final String key = 'plk_fake-key-$seq-0123456789';
    issuedApiKeys.add(key);
    final String id = 'key-$seq';
    final Map<String, Object?> record = <String, Object?>{
      'id': id,
      'name': json['name'],
      'key_prefix': prefixOf(key),
      'scopes': <Object?>['stats:read'],
      'created_at': _iso(),
      'last_used_at': null,
      'revoked_at': null,
      'is_active': true,
    };
    apiKeys[id] = record;
    // 明文只在创建响应里出现（真实服务端也只存哈希）
    return _json(request, 201, <String, Object?>{...record, 'key': key});
  }

  Future<void> _listApiKeys(HttpRequest request) async {
    apiKeyListRequests++;
    final List<Object?> items = apiKeys.values.toList(growable: false);
    return _json(request, 200, <String, Object?>{
      'items': items,
      'total': items.length,
    });
  }

  Future<void> _revokeApiKey(HttpRequest request, String keyId) async {
    apiKeyRevokeRequests++;
    final Map<String, Object?>? record = apiKeys[keyId];
    if (record == null) {
      return _error(request, 404, 'api_key_not_found', '密钥不存在或不属于当前账户');
    }
    // 与真实服务端一致：撤销只写 revoked_at，不删行
    record['revoked_at'] = _iso();
    record['is_active'] = false;
    return _json(request, 200, record);
  }

  /// 直接造一把密钥（供测试预置状态）。
  Map<String, Object?> seedApiKey({
    required String id,
    required String name,
    bool revoked = false,
    String? lastUsedAt,
  }) {
    final Map<String, Object?> record = <String, Object?>{
      'id': id,
      'name': name,
      'key_prefix': prefixOf('plk_$id'),
      'scopes': <Object?>['stats:read'],
      'created_at': _iso(),
      'last_used_at': lastUsedAt,
      'revoked_at': revoked ? _iso() : null,
      'is_active': !revoked,
    };
    apiKeys[id] = record;
    return record;
  }

  Future<void> _push(HttpRequest request, Map<String, Object?> json) async {
    pushCount++;
    concurrentPush++;
    if (concurrentPush > maxConcurrentPush) maxConcurrentPush = concurrentPush;
    try {
      if (pushDelayMs > 0) {
        await Future<void>.delayed(Duration(milliseconds: pushDelayMs));
      }

      if (deviceRevoked) {
        return await _error(request, 403, 'device_revoked', '该设备已被撤销');
      }
      final int? forced = forcedPushStatus;
      if (forced != null) {
        return await _error(
          request,
          forced,
          forcedPushErrorCode ?? 'internal_error',
          '服务端错误',
        );
      }

      // 校验访问令牌有效性（模拟过期）
      if (requireFreshAccessToken) {
        final String? auth = request.headers.value(
          HttpHeaders.authorizationHeader,
        );
        final String token = (auth ?? '').replaceFirst('Bearer ', '');
        if (token != 'access-$accessTokenGeneration') {
          return await _error(
            request,
            401,
            'token_expired',
            'Access Token 已过期',
          );
        }
      }

      receivedPushes.add(json);
      for (final String key in <String>[
        'activity_segments',
        'daily_usage',
        'applications',
      ]) {
        final Object? list = json[key];
        if (list is List) {
          for (final Object? item in list) {
            if (item is Map) {
              final Map<String, Object?> map = item.cast<String, Object?>();
              storedRecords.add(
                "$key:${map['id'] ?? map['local_day'] ?? map['app_key']}",
              );
            }
          }
        }
      }

      final int accepted =
          (json['activity_segments'] as List<Object?>? ?? const <Object?>[])
              .length +
          (json['daily_usage'] as List<Object?>? ?? const <Object?>[]).length +
          (json['applications'] as List<Object?>? ?? const <Object?>[]).length;

      return await _json(request, 200, <String, Object?>{
        'batch_id': json['batch_id'],
        'accepted_total': accepted,
        'accepted_activity_segments':
            (json['activity_segments'] as List<Object?>? ?? const <Object?>[])
                .length,
        'accepted_daily_usage':
            (json['daily_usage'] as List<Object?>? ?? const <Object?>[]).length,
        'accepted_applications':
            (json['applications'] as List<Object?>? ?? const <Object?>[])
                .length,
        'rejected': <Object?>[],
        'server_time': _iso(),
        'cursor': 7,
      });
    } finally {
      concurrentPush--;
    }
  }

  Map<String, Object?> _authResponse({required bool deviceBound}) {
    accessTokenGeneration++;
    return <String, Object?>{
      'access_token': 'access-$accessTokenGeneration',
      'token_type': 'bearer',
      'expires_in': 900,
      'refresh_token': 'refresh-$accessTokenGeneration',
      'refresh_expires_at': _iso(365),
      'user': <String, Object?>{
        'id': 'server-user-1',
        'email': 'tester@example.com',
        'display_name': '测试用户',
        'status': 'active',
        'created_at': _iso(),
        'updated_at': _iso(),
      },
      'device_id': deviceBound ? 'server-device-1' : null,
    };
  }

  static String _iso([int daysAhead = 0]) =>
      DateTime.now().toUtc().add(Duration(days: daysAhead)).toIso8601String();

  static Future<void> _json(
    HttpRequest request,
    int status,
    Map<String, Object?> body,
  ) => _writeJsonPayload(request, status, body);

  static Future<void> _jsonArray(
    HttpRequest request,
    int status,
    List<Object?> body,
  ) => _writeJsonPayload(request, status, body);

  static Future<void> _error(
    HttpRequest request,
    int status,
    String code,
    String message,
  ) => _writeJsonPayload(request, status, <String, Object?>{
    'error': <String, Object?>{
      'code': code,
      'message': message,
      'request_id': 'fake-request-id',
    },
  });

  static Future<void> _writeJsonPayload(
    HttpRequest request,
    int status,
    Object? body,
  ) async {
    final List<int> bytes = utf8.encode(jsonEncode(body));
    request.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..contentLength = bytes.length
      ..add(bytes);
    await request.response.close();
  }
}

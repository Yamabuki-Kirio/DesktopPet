import 'api_client.dart';
import 'authenticated_api.dart';
import 'models/cloud_statistics_models.dart';

/// 云端统计读取失败（已转成用户可理解的信息，绝不透传服务器堆栈）。
class CloudStatisticsException implements Exception {
  const CloudStatisticsException(this.kind, this.message);

  final CloudStatisticsErrorKind kind;
  final String message;

  bool get isNetwork => kind == CloudStatisticsErrorKind.network;

  bool get needsSignIn => kind == CloudStatisticsErrorKind.auth;

  @override
  String toString() => message;
}

enum CloudStatisticsErrorKind {
  /// 网络不可达 / 超时（可用缓存兜底）。
  network,

  /// 登录失效（需要重新登录，不重试）。
  auth,

  /// 服务端返回错误（4xx/5xx）。
  server,

  /// 响应结构不符合预期（字段缺失 / 类型错误 / 时间非法）。
  malformed,
}

/// 云端统计数据访问。
///
/// **只读**：本接口没有任何写方法，因此"云端数据不会写回本机采集表、
/// 也不会进入 outbox"是结构性的，而不是靠约定。
///
/// 身份与令牌刷新完全复用 [AuthenticatedApi]（含 401 → 刷新 → 只重试一次），
/// 因此这里不重复实现鉴权。
abstract interface class CloudStatisticsRepository {
  Future<List<CloudDevice>> listDevices();

  Future<CloudUsageSummary> getSummary(CloudUsageQuery query);

  Future<List<CloudAppUsage>> getApps(CloudUsageQuery query);

  Future<CloudSessionPage> getSessions(CloudUsageQuery query);

  Future<List<CloudTimelineEntry>> getTimeline(CloudUsageQuery query);
}

/// 走服务端 HTTP 接口的实现。
///
/// 端点白名单（**不接受任何外部输入拼路径**）：
/// * `GET /api/v1/devices` —— 设备列表（Phase 2 既有端点，含名称/平台/型号/最近在线）
/// * `GET /api/v1/statistics/{summary,apps,sessions,timeline}` —— Phase 4B 统计
class ApiCloudStatisticsRepository implements CloudStatisticsRepository {
  ApiCloudStatisticsRepository({required AuthenticatedApi api}) : _api = api;

  static const String _devicesPath = '/api/v1/devices';
  static const String _statisticsPrefix = '/api/v1/statistics';

  final AuthenticatedApi _api;

  @override
  Future<List<CloudDevice>> listDevices() async {
    final Map<String, Object?> body =
        await _get(_devicesPath, const <String, String>{});
    final Object? items = body['items'];
    if (items is! List) {
      throw const CloudStatisticsException(
        CloudStatisticsErrorKind.malformed,
        '设备列表格式不正确',
      );
    }
    return <CloudDevice>[
      for (final Object? item in items) CloudDevice.fromJson(_asMap(item, '设备列表')),
    ];
  }

  @override
  Future<CloudUsageSummary> getSummary(CloudUsageQuery query) async {
    final Map<String, Object?> body = await _get(
      '$_statisticsPrefix/summary',
      query.toQueryParameters(),
    );
    return CloudUsageSummary.fromJson(body);
  }

  @override
  Future<List<CloudAppUsage>> getApps(CloudUsageQuery query) async {
    // 服务端 /statistics/apps 与 /statistics/summary 是同一份聚合结果，
    // 这里复用 summary 的解析路径，保证两处口径完全一致。
    final Map<String, Object?> body = await _get(
      '$_statisticsPrefix/apps',
      query.toQueryParameters(),
    );
    return CloudUsageSummary.fromJson(body).apps;
  }

  @override
  Future<CloudSessionPage> getSessions(CloudUsageQuery query) async {
    final Map<String, Object?> body = await _get(
      '$_statisticsPrefix/sessions',
      query.toQueryParameters(includeCursor: true),
    );
    return CloudSessionPage.fromJson(body);
  }

  @override
  Future<List<CloudTimelineEntry>> getTimeline(CloudUsageQuery query) async {
    final Map<String, Object?> body = await _get(
      '$_statisticsPrefix/timeline',
      query.toQueryParameters(),
    );
    return parseTimelineItems(body);
  }

  /// 统一出口：把底层异常翻译成 [CloudStatisticsException]。
  Future<Map<String, Object?>> _get(
    String path,
    Map<String, String> query,
  ) async {
    try {
      return await _api.cloudStatisticsJson(path, query);
    } on CloudDataException catch (e) {
      throw CloudStatisticsException(
        CloudStatisticsErrorKind.malformed,
        '云端数据格式异常：${e.toString()}',
      );
    } on ApiException catch (e) {
      throw CloudStatisticsException(_kindOf(e), _messageOf(e));
    }
  }

  static CloudStatisticsErrorKind _kindOf(ApiException e) {
    // e.kind.needsReauth 覆盖 unauthorized / refreshFailed / deviceRevoked / notFound，
    // 与 SyncEngine 的状态机口径一致：这些都要用户重新登录，不该反复重试。
    if (e.kind.needsReauth || e.statusCode == 401) {
      return CloudStatisticsErrorKind.auth;
    }
    if (e.isNetworkIssue) return CloudStatisticsErrorKind.network;
    return CloudStatisticsErrorKind.server;
  }

  static String _messageOf(ApiException e) {
    if (e.statusCode == 401 || e.kind.needsReauth) {
      return '登录已失效，请重新登录后再查看云端统计';
    }
    if (e.statusCode == 403) return '当前账户无权查看该设备的数据';
    if (e.statusCode == 404) return '找不到该设备（可能已被撤销或不属于当前账户）';
    if (e.statusCode == 422) return '查询条件不被服务端接受（可能是时区或日期格式）';
    if (e.isNetworkIssue) return '网络不可用，暂时无法刷新云端统计';
    if (e.statusCode != null && e.statusCode! >= 500) {
      return '服务端暂时不可用，请稍后重试';
    }
    return '云端统计读取失败：${e.message}';
  }

  static Map<String, Object?> _asMap(Object? item, String field) {
    if (item is Map<String, Object?>) return item;
    if (item is Map) return item.cast<String, Object?>();
    throw CloudStatisticsException(
      CloudStatisticsErrorKind.malformed,
      '$field 结构不正确',
    );
  }
}

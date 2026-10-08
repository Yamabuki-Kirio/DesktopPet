import '../database/dao/cloud_statistics_cache_dao.dart';
import 'models/cloud_statistics_models.dart';

/// 云端统计缓存的**类型化**读写层。
///
/// 缓存内容与用途：
/// * 设备列表、每日汇总、应用排行、时间线、会话页、最近成功刷新时间；
/// * 打开页面先展示缓存 → 后台请求 → 成功后覆盖缓存 → 无网络时保留旧数据并标记"离线数据"；
/// * 退出账号时按账户整表清理；不同账户**严格隔离**（主键第一列就是 account_user_id）；
/// * 缓存**绝不进入 outbox**：本类不依赖任何同步组件，只碰
///   [CloudStatisticsCacheDao] 这一张专用表。
class CloudStatisticsCache {
  CloudStatisticsCache(this._dao, {String Function()? serverBaseUrl})
      : _serverBaseUrl = serverBaseUrl ?? _noServer;

  final CloudStatisticsCacheDao _dao;

  /// 当前登录所用的服务端地址（进缓存键，避免"换服务器后读到旧服务器的缓存"）。
  ///
  /// 由装配层接到 `AuthenticatedApi.baseUrl`；测试可注入固定值。
  final String Function() _serverBaseUrl;

  static String _noServer() => '';

  /// 统一的缓存键：`query_type|server_base_url|device|date|timezone|app_id`。
  ///
  /// 与需求「缓存键必须至少包含 account_id + server_base_url + device_id +
  /// date_range + view_type」对齐：
  /// * `account_id` —— 由表主键第一列 `account_user_id` 承担（同名查询在不同账户下互不可见）；
  /// * `server_base_url` —— 本键第 2 段（同一个 userId 在不同服务器上必须分开）；
  /// * `device_id` / `date_range` / `view_type` —— `deviceKey` / `dayKey` / `type`。
  ///
  /// [serverBaseUrl] 为必填：漏传会让"换服务器读到旧缓存"这类问题**静默复活**，
  /// 因此宁可让调用点显式传值，也不给默认空串。
  static String buildKey({
    required CloudCacheType type,
    required String serverBaseUrl,
    required String deviceKey,
    required String dayKey,
    required String timezone,
    String? appId,
  }) =>
      '${type.wireName}|$serverBaseUrl|$deviceKey|$dayKey|$timezone|${appId ?? ''}';

  String _keyFor(CloudCacheType type, CloudUsageQuery query) => buildKey(
        type: type,
        serverBaseUrl: _serverBaseUrl(),
        deviceKey: query.deviceKey,
        dayKey: query.dateKey,
        timezone: query.timezone,
        appId: query.appId,
      );

  String _devicesKey() => buildKey(
        type: CloudCacheType.devices,
        serverBaseUrl: _serverBaseUrl(),
        deviceKey: kCloudDeviceAll,
        dayKey: '*',
        timezone: '*',
      );

  // --- 设备列表 ---

  Future<void> saveDevices({
    required String accountUserId,
    required List<CloudDevice> devices,
    DateTime? fetchedAt,
  }) =>
      _dao.write(
        accountUserId: accountUserId,
        cacheKey: _devicesKey(),
        type: CloudCacheType.devices,
        deviceKey: kCloudDeviceAll,
        dayKey: '*',
        timezone: '*',
        payload: <String, Object?>{
          'items': <Map<String, Object?>>[
            for (final CloudDevice d in devices)
              <String, Object?>{
                'id': d.id,
                'device_name': d.name,
                'platform': d.platform,
                'model_name': d.modelName,
                'last_seen_at': d.lastSeenAt?.toIso8601String(),
                'revoked': d.revoked,
                'is_current': d.isCurrent,
              },
          ],
        },
        fetchedAt: fetchedAt ?? DateTime.now(),
      );

  Future<List<CloudDevice>?> readDevices(String accountUserId) async {
    final CloudCacheEntry? entry =
        await _dao.read(accountUserId: accountUserId, cacheKey: _devicesKey());
    if (entry == null) return null;
    final Object? items = entry.payload['items'];
    if (items is! List) return null;
    return <CloudDevice>[
      for (final Object? item in items) CloudDevice.fromJson(_map(item, 'devices')),
    ];
  }

  // --- 汇总（含应用排行） ---

  Future<void> saveSummary({
    required String accountUserId,
    required CloudUsageQuery query,
    required CloudUsageSummary summary,
    DateTime? fetchedAt,
  }) =>
      _dao.write(
        accountUserId: accountUserId,
        cacheKey: _keyFor(CloudCacheType.summary, query),
        type: CloudCacheType.summary,
        deviceKey: query.deviceKey,
        dayKey: query.dateKey,
        timezone: query.timezone,
        appId: query.appId,
        payload: <String, Object?>{
          'date': summary.date,
          'timezone': summary.timezone,
          'device_id': summary.deviceId,
          'total_duration_seconds': summary.totalDuration.inSeconds,
          'session_count': summary.sessionCount,
          'app_count': summary.appCount,
          'last_synced_at': summary.lastSyncedAt?.toIso8601String(),
          'overlap_warning': summary.overlapWarning,
          'apps': <Map<String, Object?>>[
            for (final CloudAppUsage a in summary.apps) _appToJson(a),
          ],
        },
        fetchedAt: fetchedAt ?? DateTime.now(),
      );

  Future<CloudUsageSummary?> readSummary(
    String accountUserId,
    CloudUsageQuery query,
  ) async {
    final CloudCacheEntry? entry = await _dao.read(
      accountUserId: accountUserId,
      cacheKey: _keyFor(CloudCacheType.summary, query),
    );
    return entry == null ? null : CloudUsageSummary.fromJson(entry.payload);
  }

  // --- 应用排行（单独缓存，供不带 summary 的查询复用） ---

  Future<void> saveApps({
    required String accountUserId,
    required CloudUsageQuery query,
    required List<CloudAppUsage> apps,
    DateTime? fetchedAt,
  }) =>
      _dao.write(
        accountUserId: accountUserId,
        cacheKey: _keyFor(CloudCacheType.apps, query),
        type: CloudCacheType.apps,
        deviceKey: query.deviceKey,
        dayKey: query.dateKey,
        timezone: query.timezone,
        appId: query.appId,
        payload: <String, Object?>{
          'items': <Map<String, Object?>>[for (final CloudAppUsage a in apps) _appToJson(a)],
        },
        fetchedAt: fetchedAt ?? DateTime.now(),
      );

  Future<List<CloudAppUsage>?> readApps(
    String accountUserId,
    CloudUsageQuery query,
  ) async {
    final CloudCacheEntry? entry = await _dao.read(
      accountUserId: accountUserId,
      cacheKey: _keyFor(CloudCacheType.apps, query),
    );
    if (entry == null) return null;
    final Object? items = entry.payload['items'];
    if (items is! List) return null;
    return <CloudAppUsage>[
      for (final Object? item in items) CloudAppUsage.fromJson(_map(item, 'apps')),
    ];
  }

  // --- 时间线 ---

  Future<void> saveTimeline({
    required String accountUserId,
    required CloudUsageQuery query,
    required List<CloudTimelineEntry> entries,
    DateTime? fetchedAt,
  }) =>
      _dao.write(
        accountUserId: accountUserId,
        cacheKey: _keyFor(CloudCacheType.timeline, query),
        type: CloudCacheType.timeline,
        deviceKey: query.deviceKey,
        dayKey: query.dateKey,
        timezone: query.timezone,
        appId: query.appId,
        payload: <String, Object?>{
          'items': <Map<String, Object?>>[
            for (final CloudTimelineEntry e in entries)
              <String, Object?>{
                'app_id': e.appId,
                'app_name': e.appName,
                'category': e.category,
                'device_id': e.deviceId,
                'device_name': e.deviceName,
                'platform': e.platform,
                'started_at': e.startedAt.toIso8601String(),
                'ended_at': e.endedAt?.toIso8601String(),
                'duration_seconds': e.duration.inSeconds,
                'merged_session_count': e.mergedSessionCount,
              },
          ],
        },
        fetchedAt: fetchedAt ?? DateTime.now(),
      );

  Future<List<CloudTimelineEntry>?> readTimeline(
    String accountUserId,
    CloudUsageQuery query,
  ) async {
    final CloudCacheEntry? entry = await _dao.read(
      accountUserId: accountUserId,
      cacheKey: _keyFor(CloudCacheType.timeline, query),
    );
    if (entry == null) return null;
    final Object? items = entry.payload['items'];
    if (items is! List) return null;
    return <CloudTimelineEntry>[
      for (final Object? item in items)
        CloudTimelineEntry.fromJson(_map(item, 'timeline')),
    ];
  }

  // --- 会话页（只缓存第一页，避免游标语义复杂化） ---

  Future<void> saveSessions({
    required String accountUserId,
    required CloudUsageQuery query,
    required CloudSessionPage page,
    DateTime? fetchedAt,
  }) =>
      _dao.write(
        accountUserId: accountUserId,
        cacheKey: _keyFor(CloudCacheType.sessions, query.copyWith(clearCursor: true)),
        type: CloudCacheType.sessions,
        deviceKey: query.deviceKey,
        dayKey: query.dateKey,
        timezone: query.timezone,
        appId: query.appId,
        payload: <String, Object?>{
          'date': page.date,
          'timezone': page.timezone,
          'next_cursor': page.nextCursor,
          'items': <Map<String, Object?>>[
            for (final CloudUsageSession s in page.items)
              <String, Object?>{
                'id': s.id,
                'local_record_id': s.localRecordId,
                'device_id': s.deviceId,
                'device_name': s.deviceName,
                'platform': s.platform,
                'app_id': s.appId,
                'app_name': s.appName,
                'category': s.category,
                'started_at': s.startedAt.toIso8601String(),
                'ended_at': s.endedAt?.toIso8601String(),
                'duration_seconds': s.duration.inSeconds,
              },
          ],
        },
        fetchedAt: fetchedAt ?? DateTime.now(),
      );

  Future<CloudSessionPage?> readSessions(
    String accountUserId,
    CloudUsageQuery query,
  ) async {
    final CloudCacheEntry? entry = await _dao.read(
      accountUserId: accountUserId,
      cacheKey: _keyFor(CloudCacheType.sessions, query.copyWith(clearCursor: true)),
    );
    return entry == null ? null : CloudSessionPage.fromJson(entry.payload);
  }

  // --- 刷新时间与清理 ---

  Future<DateTime?> lastFetchedAt(String accountUserId) =>
      _dao.lastFetchedAt(accountUserId);

  Future<int> countForAccount(String accountUserId) =>
      _dao.countForAccount(accountUserId);

  /// 退出账户时调用：只清云端缓存，**不动**本机采集数据与 outbox。
  Future<int> clearAccount(String accountUserId) => _dao.deleteAccount(accountUserId);

  Future<void> clearAll() => _dao.deleteAll();

  static Map<String, Object?> _map(Object? item, String field) {
    if (item is Map<String, Object?>) return item;
    if (item is Map) return item.cast<String, Object?>();
    throw CloudDataException('缓存条目结构损坏', field: field);
  }

  static Map<String, Object?> _appToJson(CloudAppUsage app) => <String, Object?>{
        'app_id': app.appId,
        'app_name': app.appName,
        'category': app.category,
        'duration_seconds': app.duration.inSeconds,
        'session_count': app.sessionCount,
      };
}

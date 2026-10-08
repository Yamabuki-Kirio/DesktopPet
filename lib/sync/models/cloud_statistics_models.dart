/// Phase 4B：云端统计的客户端模型。
///
/// 三层边界（务必遵守，否则会出现循环同步与重复累计）：
///
/// 1. **本机采集数据**：`activity_segments` / `daily_usage`（本机实时采集）；
/// 2. **上传队列**：`sync_outbox`（只放**本机**产生的数据）；
/// 3. **云端统计数据**：本文件描述的模型，只从服务端读、只进
///    `cloud_statistics_cache`，**绝不写入 1 或 2**。
///
/// 解析约定：
/// * 缺字段 / 类型错误 / 无效时间 / 负数时长 / 结束早于开始 / 空设备 ID /
///   未知平台 → 抛 [CloudDataException]，由上层转成用户可读文案；
/// * **未知字段一律忽略**（服务端新增字段不该让旧客户端整页崩掉）；
/// * 所有时间在解析时统一转成 UTC 的 [DateTime]。
library;

/// 平台标识 → 展示名。
const Map<String, String> kCloudPlatformLabels = <String, String>{
  'windows': 'Windows',
  'android': 'Android',
  'macos': 'macOS',
  'linux': 'Linux',
};

/// 「全部设备」在缓存键里的占位符。
const String kCloudDeviceAll = 'all';

/// 云端数据解析失败（含具体字段，便于给出可读错误）。
class CloudDataException implements Exception {
  const CloudDataException(this.message, {this.field});

  final String message;
  final String? field;

  @override
  String toString() => field == null ? message : '$field：$message';
}

// ---------------------------------------------------------------------------
// 解析原语
// ---------------------------------------------------------------------------

Map<String, Object?> _asMap(Object? value, String field) {
  if (value is Map<String, Object?>) return value;
  if (value is Map) return value.cast<String, Object?>();
  throw CloudDataException('期望对象，实际是 ${value.runtimeType}', field: field);
}

String _requireString(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  if (value is String && value.trim().isNotEmpty) return value;
  if (value == null) throw CloudDataException('缺少字段', field: key);
  throw CloudDataException('期望非空字符串，实际是 ${value.runtimeType}', field: key);
}

String? _optionalString(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  if (value == null) return null;
  if (value is String) return value.isEmpty ? null : value;
  throw CloudDataException('期望字符串，实际是 ${value.runtimeType}', field: key);
}

int _optionalInt(Map<String, Object?> json, String key, int fallback) {
  final Object? value = json[key];
  if (value == null) return fallback;
  if (value is int) return value;
  if (value is num) return value.toInt();
  throw CloudDataException('期望整数，实际是 ${value.runtimeType}', field: key);
}

bool _optionalBool(Map<String, Object?> json, String key, bool fallback) {
  final Object? value = json[key];
  if (value == null) return fallback;
  if (value is bool) return value;
  throw CloudDataException('期望布尔值，实际是 ${value.runtimeType}', field: key);
}

/// 时间尾部必须带显式时区（`Z` 或 `±HH:MM`）。
///
/// 为什么必须严格：Dart 的 `DateTime.tryParse('2026-09-29 01:00')` 会把它当成
/// **本机时区**的时间。云端统计是跨设备数据，一条"没有时区"的时间戳如果被
/// 按手机所在时区解释，整天的归属都会错位（例如中国的 00:20 会被算到前一天）。
/// 服务端始终返回 `...Z`，因此缺失时区说明数据本身有问题，应当报错而不是猜。
final RegExp _explicitZoneTail = RegExp(r'(?:[Zz]|[+-]\d{2}:?\d{2})$');

bool _hasExplicitZone(String raw) => _explicitZoneTail.hasMatch(raw.trim());

/// 解析 ISO8601 时间并统一转 UTC。
DateTime _requireUtc(Map<String, Object?> json, String key) {
  final String raw = _requireString(json, key);
  if (!_hasExplicitZone(raw)) {
    throw CloudDataException('时间缺少时区信息（应为 UTC）：$raw', field: key);
  }
  final DateTime? parsed = DateTime.tryParse(raw);
  if (parsed == null) {
    throw CloudDataException('时间格式无法解析：$raw', field: key);
  }
  return parsed.toUtc();
}

DateTime? _optionalUtc(Map<String, Object?> json, String key) {
  final String? raw = _optionalString(json, key);
  if (raw == null) return null;
  if (!_hasExplicitZone(raw)) {
    throw CloudDataException('时间缺少时区信息（应为 UTC）：$raw', field: key);
  }
  final DateTime? parsed = DateTime.tryParse(raw);
  if (parsed == null) {
    throw CloudDataException('时间格式无法解析：$raw', field: key);
  }
  return parsed.toUtc();
}

/// 时长的统一校验：不允许负数。
Duration _durationFromSeconds(int seconds, String field) {
  if (seconds < 0) {
    throw CloudDataException('时长不能为负数：$seconds', field: field);
  }
  return Duration(seconds: seconds);
}

/// 启动时把「结束早于开始」这类自相矛盾的数据挡在模型层之外。
void _assertOrdered(DateTime start, DateTime? end, String field) {
  if (end != null && end.isBefore(start)) {
    throw CloudDataException('结束时间早于开始时间', field: field);
  }
}

List<Map<String, Object?>> _itemsOf(Map<String, Object?> body, String field) {
  final Object? raw = body['items'];
  if (raw == null) return const <Map<String, Object?>>[];
  if (raw is! List) {
    throw CloudDataException('期望数组，实际是 ${raw.runtimeType}', field: field);
  }
  return <Map<String, Object?>>[
    for (int i = 0; i < raw.length; i++)
      _asMap(raw[i], '$field[$i]'),
  ];
}

/// 平台展示名；未知平台在解析阶段已被拒绝（见 [CloudDevice.fromJson]）。
String platformLabel(String platform) =>
    kCloudPlatformLabels[platform] ?? platform;

/// 把设备/应用标识拼成"名称 · 平台"的展示串。
String deviceLabel({required String name, required String platform}) =>
    '$name · ${platformLabel(platform)}';

// ---------------------------------------------------------------------------
// 时区
// ---------------------------------------------------------------------------

/// 常见 UTC 偏移 → IANA 时区名（与服务端内置回退表口径一致）。
///
/// 客户端拿不到可靠的 IANA 名（Dart 只有缩写，如 `CST`），
/// 因此这里按偏移量给一个**推荐名**用于展示与缓存键；
/// 真正决定"哪一天"的始终是 `tz_offset_minutes`（由设备时钟精确算出）。
const Map<int, String> kCloudTimezoneNamesByOffset = <int, String>{
  480: 'Asia/Shanghai',
  540: 'Asia/Tokyo',
  420: 'Asia/Bangkok',
  330: 'Asia/Kolkata',
  240: 'Asia/Dubai',
  0: 'Europe/London',
  60: 'Europe/Berlin',
  -300: 'America/New_York',
  -480: 'America/Los_Angeles',
  600: 'Australia/Sydney',
};

String _offsetLabel(int minutes) {
  final String sign = minutes >= 0 ? '+' : '-';
  final int total = minutes.abs();
  return 'UTC$sign${total ~/ 60 >= 10 ? '' : '0'}${total ~/ 60}:'
      '${(total % 60).toString().padLeft(2, '0')}';
}

/// 偏移 → 展示/缓存用的时区键：优先推荐名，否则 `UTC±HH:MM`。
String timezoneKeyForOffset(int offsetMinutes) =>
    kCloudTimezoneNamesByOffset[offsetMinutes] ?? _offsetLabel(offsetMinutes);

/// 是否是服务端可识别的 IANA 名（只有这类才放进 `timezone` 查询参数，
/// 其余一律只发 `tz_offset_minutes`，避免服务端 422）。
bool isIanaTimezone(String value) => value.contains('/');

// ---------------------------------------------------------------------------
// 查询
// ---------------------------------------------------------------------------

/// 云端统计查询条件。
///
/// 缓存键（account 由缓存层补上）：
/// `device|date|timezone|app_id`，与需求"缓存键至少包含 account/device/date/timezone/query_type/app_id"一致。
class CloudUsageQuery {
  CloudUsageQuery({
    required DateTime date,
    this.deviceId,
    required this.timezone,
    required this.timezoneOffsetMinutes,
    this.appId,
    this.cursor,
    this.limit = 100,
  }) : date = DateTime(date.year, date.month, date.day);

  /// 本地日期（只取年月日）。
  final DateTime date;

  /// null / [kCloudDeviceAll] = 全部设备。
  final String? deviceId;

  /// 展示与缓存用的时区键（IANA 名或 `UTC±HH:MM`）。
  final String timezone;

  /// 权威的时区偏移（服务端据此划分"当地日期"）。
  final int timezoneOffsetMinutes;

  final String? appId;
  final String? cursor;
  final int limit;

  String get deviceKey =>
      (deviceId == null || deviceId!.isEmpty) ? kCloudDeviceAll : deviceId!;

  String get dateKey =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';

  /// 不含 cursor 的稳定键（分页请求共用同一条缓存键语义）。
  String get baseCacheKey =>
      '$deviceKey|$dateKey|$timezone|${appId ?? ''}';

  CloudUsageQuery copyWith({
    DateTime? date,
    Object? deviceId = _unset,
    String? timezone,
    int? timezoneOffsetMinutes,
    Object? appId = _unset,
    String? cursor,
    bool clearCursor = false,
    int? limit,
  }) {
    return CloudUsageQuery(
      date: date ?? this.date,
      deviceId: identical(deviceId, _unset) ? this.deviceId : deviceId as String?,
      timezone: timezone ?? this.timezone,
      timezoneOffsetMinutes: timezoneOffsetMinutes ?? this.timezoneOffsetMinutes,
      appId: identical(appId, _unset) ? this.appId : appId as String?,
      cursor: clearCursor ? null : (cursor ?? this.cursor),
      limit: limit ?? this.limit,
    );
  }

  /// 用设备当前时钟构造"某一天的本地查询"。
  factory CloudUsageQuery.forLocalDay(
    DateTime day, {
    String? deviceId,
    String? appId,
    DateTime? now,
  }) {
    final int offset = (now ?? DateTime.now()).timeZoneOffset.inMinutes;
    return CloudUsageQuery(
      date: day,
      deviceId: deviceId,
      timezone: timezoneKeyForOffset(offset),
      timezoneOffsetMinutes: offset,
      appId: appId,
    );
  }

  /// 服务端查询参数。
  Map<String, String> toQueryParameters({
    bool includeCursor = false,
    bool includeAppId = true,
  }) {
    return <String, String>{
      'device_id': deviceKey,
      'date': dateKey,
      if (isIanaTimezone(timezone)) 'timezone': timezone,
      'tz_offset_minutes': '$timezoneOffsetMinutes',
      if (includeAppId && appId != null && appId!.isNotEmpty) 'app_id': appId!,
      if (includeCursor && cursor != null && cursor!.isNotEmpty) 'cursor': cursor!,
      if (includeCursor) 'limit': '$limit',
    };
  }

  @override
  String toString() => 'CloudUsageQuery($baseCacheKey, offset=$timezoneOffsetMinutes)';
}

const Object _unset = Object();

// ---------------------------------------------------------------------------
// 设备
// ---------------------------------------------------------------------------

class CloudDevice {
  const CloudDevice({
    required this.id,
    required this.name,
    required this.platform,
    this.modelName,
    this.lastSeenAt,
    this.revoked = false,
    this.isCurrent = false,
  });

  final String id;
  final String name;
  final String platform;
  final String? modelName;
  final DateTime? lastSeenAt;
  final bool revoked;
  final bool isCurrent;

  bool get isWindows => platform == 'windows';

  /// 展示串：`我的电脑 · Windows`
  String get displayLabel => deviceLabel(name: name, platform: platform);

  factory CloudDevice.fromJson(Map<String, Object?> json) {
    final String id = _requireString(json, 'id');
    final String platform = _requireString(json, 'platform').toLowerCase();
    if (!kCloudPlatformLabels.containsKey(platform)) {
      throw CloudDataException('未知平台：$platform', field: 'platform');
    }
    return CloudDevice(
      id: id,
      name: _requireString(json, 'device_name'),
      platform: platform,
      modelName: _optionalString(json, 'model_name'),
      lastSeenAt: _optionalUtc(json, 'last_seen_at'),
      // 服务端给 revoked_at（非空即已撤销）；本地缓存写的是布尔 revoked。
      revoked: _optionalBool(json, 'revoked', json['revoked_at'] != null),
      isCurrent: _optionalBool(json, 'is_current', false),
    );
  }
}

// ---------------------------------------------------------------------------
// 汇总 / 应用
// ---------------------------------------------------------------------------

class CloudAppUsage {
  const CloudAppUsage({
    required this.appId,
    required this.appName,
    this.category = 'other',
    this.duration = Duration.zero,
    this.sessionCount = 0,
  });

  final String appId;
  final String appName;
  final String category;
  final Duration duration;
  final int sessionCount;

  factory CloudAppUsage.fromJson(Map<String, Object?> json) {
    return CloudAppUsage(
      appId: _requireString(json, 'app_id'),
      appName: _requireString(json, 'app_name'),
      category: _optionalString(json, 'category') ?? 'other',
      duration: _durationFromSeconds(
        _optionalInt(json, 'duration_seconds', 0),
        'duration_seconds',
      ),
      sessionCount: _optionalInt(json, 'session_count', 0),
    );
  }
}

class CloudUsageSummary {
  const CloudUsageSummary({
    required this.date,
    required this.timezone,
    this.deviceId,
    this.totalDuration = Duration.zero,
    this.sessionCount = 0,
    this.appCount = 0,
    this.lastSyncedAt,
    this.apps = const <CloudAppUsage>[],
    this.overlapWarning,
  });

  final String date;
  final String timezone;
  final String? deviceId;
  final Duration totalDuration;
  final int sessionCount;
  final int appCount;

  /// 该账户在窗口内**最后一次收到上传**的时间（"最近同步时间"）。
  final DateTime? lastSyncedAt;

  /// 已按时长降序。
  final List<CloudAppUsage> apps;

  /// 「全部设备」时非空：各设备时长相加可能重叠。
  final String? overlapWarning;

  factory CloudUsageSummary.fromJson(Map<String, Object?> json) {
    final List<CloudAppUsage> apps = <CloudAppUsage>[
      for (final Map<String, Object?> item in _itemsOf(
        <String, Object?>{'items': json['apps']},
        'apps',
      ))
        CloudAppUsage.fromJson(item),
    ]..sort((CloudAppUsage a, CloudAppUsage b) => b.duration.compareTo(a.duration));

    return CloudUsageSummary(
      date: _requireString(json, 'date'),
      timezone: _requireString(json, 'timezone'),
      deviceId: _optionalString(json, 'device_id'),
      totalDuration: _durationFromSeconds(
        _optionalInt(json, 'total_duration_seconds', 0),
        'total_duration_seconds',
      ),
      sessionCount: _optionalInt(json, 'session_count', 0),
      appCount: _optionalInt(json, 'app_count', apps.length),
      lastSyncedAt: _optionalUtc(json, 'last_synced_at'),
      apps: apps,
      overlapWarning: _optionalString(json, 'overlap_warning'),
    );
  }
}

// ---------------------------------------------------------------------------
// 会话（逐条）
// ---------------------------------------------------------------------------

class CloudUsageSession {
  const CloudUsageSession({
    required this.id,
    required this.localRecordId,
    required this.deviceId,
    required this.deviceName,
    required this.platform,
    required this.appId,
    required this.appName,
    this.category = 'other',
    required this.startedAt,
    this.endedAt,
    this.duration = Duration.zero,
  });

  final String id;
  final String localRecordId;
  final String deviceId;
  final String deviceName;
  final String platform;
  final String appId;
  final String appName;
  final String category;
  final DateTime startedAt;
  final DateTime? endedAt;
  final Duration duration;

  String get deviceDisplay => deviceLabel(name: deviceName, platform: platform);

  factory CloudUsageSession.fromJson(Map<String, Object?> json) {
    final DateTime startedAt = _requireUtc(json, 'started_at');
    final DateTime? endedAt = _optionalUtc(json, 'ended_at');
    _assertOrdered(startedAt, endedAt, 'ended_at');
    final String id = _requireString(json, 'id');
    return CloudUsageSession(
      id: id,
      localRecordId: _optionalString(json, 'local_record_id') ?? id,
      deviceId: _requireString(json, 'device_id'),
      deviceName: _optionalString(json, 'device_name') ?? '',
      platform: _optionalString(json, 'platform') ?? 'unknown',
      appId: _requireString(json, 'app_id'),
      appName: _requireString(json, 'app_name'),
      category: _optionalString(json, 'category') ?? 'other',
      startedAt: startedAt,
      endedAt: endedAt,
      duration: _durationFromSeconds(
        _optionalInt(json, 'duration_seconds', 0),
        'duration_seconds',
      ),
    );
  }
}

class CloudSessionPage {
  const CloudSessionPage({
    required this.items,
    this.nextCursor,
    required this.date,
    required this.timezone,
  });

  final List<CloudUsageSession> items;
  final String? nextCursor;
  final String date;
  final String timezone;

  bool get hasMore => nextCursor != null && nextCursor!.isNotEmpty;

  factory CloudSessionPage.fromJson(Map<String, Object?> json) {
    final List<Map<String, Object?>> raw = _itemsOf(json, 'items');
    return CloudSessionPage(
      items: <CloudUsageSession>[
        for (final Map<String, Object?> item in raw) CloudUsageSession.fromJson(item),
      ],
      nextCursor: _optionalString(json, 'next_cursor'),
      date: _requireString(json, 'date'),
      timezone: _requireString(json, 'timezone'),
    );
  }
}

// ---------------------------------------------------------------------------
// 时间线
// ---------------------------------------------------------------------------

class CloudTimelineEntry {
  const CloudTimelineEntry({
    required this.appId,
    required this.appName,
    this.category = 'other',
    required this.deviceId,
    required this.deviceName,
    this.platform = 'unknown',
    required this.startedAt,
    this.endedAt,
    this.duration = Duration.zero,
    this.mergedSessionCount = 1,
  });

  final String appId;
  final String appName;
  final String category;
  final String deviceId;
  final String deviceName;
  final String platform;
  final DateTime startedAt;
  final DateTime? endedAt;

  /// 已按区间并集计算（不是首尾相减）。
  final Duration duration;

  /// 这条展示项由几条原始会话合并而来。
  final int mergedSessionCount;

  String get deviceDisplay => deviceLabel(name: deviceName, platform: platform);

  factory CloudTimelineEntry.fromJson(Map<String, Object?> json) {
    final DateTime startedAt = _requireUtc(json, 'started_at');
    final DateTime? endedAt = _optionalUtc(json, 'ended_at');
    _assertOrdered(startedAt, endedAt, 'ended_at');
    return CloudTimelineEntry(
      appId: _requireString(json, 'app_id'),
      appName: _requireString(json, 'app_name'),
      category: _optionalString(json, 'category') ?? 'other',
      deviceId: _requireString(json, 'device_id'),
      deviceName: _optionalString(json, 'device_name') ?? '',
      platform: _optionalString(json, 'platform') ?? 'unknown',
      startedAt: startedAt,
      endedAt: endedAt,
      duration: _durationFromSeconds(
        _optionalInt(json, 'duration_seconds', 0),
        'duration_seconds',
      ),
      mergedSessionCount: _optionalInt(json, 'merged_session_count', 1),
    );
  }
}

/// 时间线列表解析（按开始时间升序，服务端已排序，这里再兜一层）。
List<CloudTimelineEntry> parseTimelineItems(Map<String, Object?> json) {
  final List<CloudTimelineEntry> items = <CloudTimelineEntry>[
    for (final Map<String, Object?> item in _itemsOf(json, 'items'))
      CloudTimelineEntry.fromJson(item),
  ];
  items.sort((CloudTimelineEntry a, CloudTimelineEntry b) =>
      a.startedAt.compareTo(b.startedAt));
  return items;
}

/// 把云端时间戳格式化成"当地 HH:MM"（用给定偏移，不依赖机器时区）。
String formatLocalHm(DateTime utc, int offsetMinutes) {
  final DateTime local = utc.toUtc().add(Duration(minutes: offsetMinutes));
  return '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';
}

/// 秒 → "X小时Y分钟" / "Y分钟"。
String formatDurationZh(Duration duration) {
  final int totalMinutes = duration.inMinutes;
  if (totalMinutes <= 0) return '不到 1 分钟';
  final int hours = totalMinutes ~/ 60;
  final int minutes = totalMinutes % 60;
  if (hours == 0) return '$minutes 分钟';
  if (minutes == 0) return '$hours 小时';
  return '$hours 小时 $minutes 分钟';
}

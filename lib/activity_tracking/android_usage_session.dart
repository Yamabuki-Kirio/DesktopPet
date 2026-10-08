/// 原生（Android）应用使用会话的跨层模型（Phase 4C-5.1B）。
///
/// 这一层只做一件事：把原生 journal 里的记录**严格解析**成 Dart 对象，
/// 解析不了一律返回 null（绝不"猜一个默认值"）。字段名与
/// `PetOverlayBridge` 的桥接表示一一对应。
library;

/// 一条**已结束**的原生使用会话。
class AndroidUsageSession {
  const AndroidUsageSession({
    required this.sessionId,
    required this.deviceLocalId,
    required this.packageName,
    this.appName,
    this.category,
    required this.startedAt,
    required this.endedAt,
    required this.activeSeconds,
    required this.endReason,
    required this.createdAt,
    this.schemaVersion = supportedSchemaVersion,
  });

  /// 原生生成的会话 ID（**稳定**：同一次会话在重复读取里保持不变）。
  final String sessionId;

  /// 原生记录里的本机设备标识（Flutter 下发；可能为空 = 下发前产生的记录）。
  final String deviceLocalId;

  /// 包名（导入时映射为 `activity_segments.app_key`）。
  final String packageName;

  /// 应用标签（可为空）。
  final String? appName;

  /// 分类（`AppCategory.wireName`）。
  final String? category;

  /// 开始时间（**UTC**；数据库与同步一律存 UTC，展示时再转本地时区）。
  final DateTime startedAt;

  /// 结束时间（UTC）。
  final DateTime endedAt;

  /// 有效秒数（非负）。
  final int activeSeconds;

  /// 结束原因（`app_switch` / `screen_off` / `service_stopped` / `collection_paused` /
  /// `permission_revoked` / `collector_unavailable` / `process_recovery`）。
  final String endReason;

  /// 记录创建时间（UTC）。
  final DateTime createdAt;

  /// journal 记录的结构版本。
  final int schemaVersion;

  /// 本端能理解的 journal 版本。
  static const int supportedSchemaVersion = 1;

  /// 严格解析；不合格返回 null（调用方会跳过并计数，绝不写入半真半假的记录）。
  ///
  /// **刻意不做"时长不得超过跨度"这类严格校验**：原生状态机在确认切换时把旧会话
  /// 结束于"候选首次出现"的时刻，秒级取整可能让 `activeSeconds` 与墙钟跨度差 1 秒；
  /// 用这种校验去拒绝记录会导致一条坏数据永久卡在队列头部。
  static AndroidUsageSession? fromMap(Map<String, Object?> map) {
    final int version = _int(map['schemaVersion'], -1);
    if (version != supportedSchemaVersion) return null;

    final String sessionId = _string(map['sessionId']);
    final String packageName = _string(map['packageName']);
    if (sessionId.isEmpty || packageName.isEmpty) return null;

    final DateTime? startedAt = _utc(map['startedAt']);
    final DateTime? endedAt = _utc(map['endedAt']);
    final DateTime? createdAt = _utc(map['createdAt']);
    if (startedAt == null || endedAt == null || createdAt == null) return null;
    if (endedAt.isBefore(startedAt)) return null;

    final int activeSeconds = _int(map['activeSeconds'], -1);
    if (activeSeconds < 0) return null;

    final String endReason = _string(map['endReason']);
    if (endReason.isEmpty) return null;

    return AndroidUsageSession(
      sessionId: sessionId,
      deviceLocalId: _string(map['deviceLocalId']),
      packageName: packageName,
      appName: _nullableString(map['appName']),
      category: _nullableString(map['category']),
      startedAt: startedAt,
      endedAt: endedAt,
      activeSeconds: activeSeconds,
      endReason: endReason,
      createdAt: createdAt,
      schemaVersion: version,
    );
  }

  /// 界面用的中文说明由 `UsageSegmentRow.endReasonLabelZh` 统一提供
  /// （导入后它的 wire 值就存在 `activity_segments.end_reason` 里），
  /// 因此这里**不再写第二份映射**。
  static String _string(Object? value) => value is String ? value : '';

  static String? _nullableString(Object? value) {
    if (value is! String) return null;
    return value.isEmpty ? null : value;
  }

  static int _int(Object? value, int fallback) => value is num ? value.toInt() : fallback;

  static DateTime? _utc(Object? value) {
    if (value is! num) return null;
    final int millis = value.toInt();
    if (millis <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true);
  }
}

/// 原生使用会话采集器的状态（设置页诊断区 + 统计页顶部提示）。
class UsageCollectorState {
  const UsageCollectorState({
    this.supported = false,
    this.running = false,
    this.paused = false,
    this.usageAccessAvailable = false,
    this.collectorRunning = false,
    this.journalAvailable = false,
    this.deviceLocalIdSet = false,
    this.pendingCount = 0,
    this.currentSessionSeconds = 0,
    this.corruptLines = 0,
    this.droppedForCapacity = 0,
    this.failureReason,
  });

  /// 当前平台是否支持原生使用会话采集。
  final bool supported;

  /// 悬浮服务是否在运行（采集依附于它）。
  final bool running;

  /// 用户是否暂停了采集。
  final bool paused;

  /// 使用情况访问权限是否可用。
  final bool usageAccessAvailable;

  /// 轮询任务是否在跑。
  final bool collectorRunning;

  /// journal 目录是否可写。
  final bool journalAvailable;

  /// 原生是否已拿到本机设备标识（未拿到时记录里的该字段为空串，导入时按本端标识补齐）。
  final bool deviceLocalIdSet;

  /// journal 里待导入的会话条数。
  final int pendingCount;

  /// 当前会话已持续秒数（没有进行中会话时为 0）。
  final int currentSessionSeconds;

  /// 最近一次读取时被隔离的损坏行数。
  final int corruptLines;

  /// 因超过上限被丢弃的记录数（累计）。
  final int droppedForCapacity;

  /// **单一**的失败原因：`usage_access_missing` / `collector_not_running` /
  /// `collector_paused_or_stopped`；正常时为 null。
  final String? failureReason;

  /// 采集是否真的在产生记录。
  bool get collecting =>
      supported && running && collectorRunning && usageAccessAvailable && !paused;

  /// 采集状态的中文说明。
  String get labelZh {
    if (!supported) return '当前平台不支持';
    if (paused) return '已暂停';
    return switch (failureReason) {
      'usage_access_missing' => '缺少使用情况访问权限',
      'collector_not_running' => '未采集（桌宠未运行）',
      'collector_paused_or_stopped' => '未采集（已隐藏或已停止）',
      _ => '采集中',
    };
  }

  static UsageCollectorState fromMap(Map<String, Object?> map) => UsageCollectorState(
        supported: map['supported'] == true,
        running: map['running'] == true,
        paused: map['paused'] == true,
        usageAccessAvailable: map['usageAccessAvailable'] == true,
        collectorRunning: map['collectorRunning'] == true,
        journalAvailable: map['journalAvailable'] == true,
        deviceLocalIdSet: map['deviceLocalIdSet'] == true,
        pendingCount: _int(map['pendingCount']),
        currentSessionSeconds: _int(map['currentSessionSeconds']),
        corruptLines: _int(map['corruptLines']),
        droppedForCapacity: _int(map['droppedForCapacity']),
        failureReason: map['failureReason'] as String?,
      );

  /// 非 Android 平台的安全默认。
  static const UsageCollectorState unsupported = UsageCollectorState();

  static int _int(Object? value) => value is num ? value.toInt() : 0;
}

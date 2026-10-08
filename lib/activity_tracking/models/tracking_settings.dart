import '../../core/constants.dart';

/// 采集设置（`tracking_settings` 表，键值存储）。
///
/// 与 [AppSettings] 分开存放，避免阶段 0 的设置表被阶段 1 字段污染，
/// 也让「暂停记录」这类运行时开关可以独立于窗口设置持久化。
class TrackingSettings {
  const TrackingSettings({
    this.paused = false,
    this.idleThresholdMs = ActivityTracking.defaultIdleThresholdMs,
    this.continuousReminderEnabled = true,
    this.usageAlertThresholdMs = 0,
  });

  /// 用户暂停全部记录。
  final bool paused;

  /// 空闲阈值（毫秒）。超过该值即认为用户离开，不计入活跃时间。
  final int idleThresholdMs;

  /// 是否启用「连续使用过久」的轻提醒（第一版只改变桌宠表情）。
  final bool continuousReminderEnabled;

  /// 今日活跃时间的 concerned 阈值（毫秒）。0 = 关闭该规则。
  final int usageAlertThresholdMs;

  TrackingSettings copyWith({
    bool? paused,
    int? idleThresholdMs,
    bool? continuousReminderEnabled,
    int? usageAlertThresholdMs,
  }) =>
      TrackingSettings(
        paused: paused ?? this.paused,
        idleThresholdMs: idleThresholdMs ?? this.idleThresholdMs,
        continuousReminderEnabled: continuousReminderEnabled ?? this.continuousReminderEnabled,
        usageAlertThresholdMs: usageAlertThresholdMs ?? this.usageAlertThresholdMs,
      );

  /// 约束到合法的可选项，避免手工改库或旧版本配置产生异常值。
  TrackingSettings normalized() => copyWith(
        idleThresholdMs: ActivityTracking.idleThresholdOptionsMs.contains(idleThresholdMs)
            ? idleThresholdMs
            : ActivityTracking.defaultIdleThresholdMs,
        usageAlertThresholdMs: usageAlertThresholdMs < 0 ? 0 : usageAlertThresholdMs,
      );

  Map<String, String> toKeyValues() => <String, String>{
        'tracking.paused': paused ? '1' : '0',
        'tracking.idleThresholdMs': '$idleThresholdMs',
        'tracking.continuousReminderEnabled': continuousReminderEnabled ? '1' : '0',
        'tracking.usageAlertThresholdMs': '$usageAlertThresholdMs',
      };

  static TrackingSettings fromKeyValues(Map<String, String> kv) {
    const TrackingSettings base = TrackingSettings();
    return TrackingSettings(
      paused: _bool(kv['tracking.paused'], base.paused),
      idleThresholdMs: _int(kv['tracking.idleThresholdMs'], base.idleThresholdMs),
      continuousReminderEnabled: _bool(
        kv['tracking.continuousReminderEnabled'],
        base.continuousReminderEnabled,
      ),
      usageAlertThresholdMs:
          _int(kv['tracking.usageAlertThresholdMs'], base.usageAlertThresholdMs),
    ).normalized();
  }

  static bool _bool(String? raw, bool fallback) {
    if (raw == null || raw.isEmpty) return fallback;
    return raw == '1' || raw.toLowerCase() == 'true';
  }

  static int _int(String? raw, int fallback) => int.tryParse(raw ?? '') ?? fallback;
}

/// 设备级的每日用量累计（`daily_usage` 表）。
///
/// 与 `activity_segments` 的分工：
/// - `daily_usage` 记录**设备级**的屏幕会话 / 活跃 / 空闲秒数（不含应用归属）；
/// - `activity_segments` 记录应用归属，用于排行与分类统计。
///
/// 需求「九、屏幕使用时长」明确要求区分这两类指标，因此不能只靠应用段推导。
class DailyUsage {
  const DailyUsage({
    required this.ownerId,
    required this.deviceLocalId,
    required this.dayKey,
    this.sessionSeconds = 0,
    this.activeSeconds = 0,
    this.idleSeconds = 0,
    this.firstActiveAt,
    this.lastActiveAt,
    required this.updatedAt,
  });

  final String ownerId;
  final String deviceLocalId;

  /// 本地日期键，格式 `YYYY-MM-DD`。
  ///
  /// 按**写入当时的本地时区**归一，历史记录不因用户之后改时区而被改写。
  final String dayKey;

  /// 解锁且未休眠的总时间。
  final int sessionSeconds;

  /// 屏幕会话中用户未超过空闲阈值的时间。
  final int activeSeconds;

  /// 解锁但用户超过空闲阈值的时间。
  final int idleSeconds;

  final DateTime? firstActiveAt;
  final DateTime? lastActiveAt;
  final DateTime updatedAt;

  DailyUsage copyWith({
    int? sessionSeconds,
    int? activeSeconds,
    int? idleSeconds,
    DateTime? firstActiveAt,
    DateTime? lastActiveAt,
    DateTime? updatedAt,
  }) =>
      DailyUsage(
        ownerId: ownerId,
        deviceLocalId: deviceLocalId,
        dayKey: dayKey,
        sessionSeconds: sessionSeconds ?? this.sessionSeconds,
        activeSeconds: activeSeconds ?? this.activeSeconds,
        idleSeconds: idleSeconds ?? this.idleSeconds,
        firstActiveAt: firstActiveAt ?? this.firstActiveAt,
        lastActiveAt: lastActiveAt ?? this.lastActiveAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, Object?> toMap() => <String, Object?>{
        'owner_id': ownerId,
        'device_local_id': deviceLocalId,
        'day_key': dayKey,
        'session_seconds': sessionSeconds,
        'active_seconds': activeSeconds,
        'idle_seconds': idleSeconds,
        'first_active_at': firstActiveAt?.millisecondsSinceEpoch,
        'last_active_at': lastActiveAt?.millisecondsSinceEpoch,
        'updated_at': updatedAt.millisecondsSinceEpoch,
      };

  static DailyUsage fromMap(Map<String, Object?> m) => DailyUsage(
        ownerId: m['owner_id']! as String,
        deviceLocalId: m['device_local_id']! as String,
        dayKey: m['day_key']! as String,
        sessionSeconds: (m['session_seconds'] as int?) ?? 0,
        activeSeconds: (m['active_seconds'] as int?) ?? 0,
        idleSeconds: (m['idle_seconds'] as int?) ?? 0,
        firstActiveAt: m['first_active_at'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(m['first_active_at']! as int),
        lastActiveAt: m['last_active_at'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(m['last_active_at']! as int),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(m['updated_at']! as int),
      );
}

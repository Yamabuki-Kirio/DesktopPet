import 'activity_enums.dart';

/// 一次采样的结果（纯数据，便于单测直接构造）。
///
/// 刻意不包含窗口标题、文档名、网页标题等任何内容信息——见需求「六、应用标识」隐私要求。
class ActivitySample {
  const ActivitySample({
    required this.wallNow,
    required this.monotonicMs,
    required this.foreground,
    required this.idle,
    required this.sessionLocked,
    required this.paused,
  });

  /// 墙上时钟（带时区语义的本地时间），用于写库。
  final DateTime wallNow;

  /// 单调时钟毫秒数，用于计算持续时长（不受系统时间调整影响）。
  final int monotonicMs;

  /// 当前前台应用；无法取得时为 null。
  final ForegroundAppInfo? foreground;

  /// 用户空闲时长（自最后一次键鼠输入起）。
  final Duration idle;

  /// Windows 是否处于锁屏 / 无输入桌面状态。
  final bool sessionLocked;

  /// 用户是否暂停了记录。
  final bool paused;
}

/// 前台应用信息。
///
/// [executablePath] 在无权限读取高权限进程时为 null，此时仍保留进程名，
/// 绝不用窗口标题顶替（需求「十五、异常处理」）。
class ForegroundAppInfo {
  const ForegroundAppInfo({
    required this.windowHandle,
    required this.processId,
    this.processName,
    this.executablePath,
  });

  final int windowHandle;
  final int processId;

  /// 进程可执行文件名（例如 `Code.exe`）；可能为 null。
  final String? processName;

  /// 可执行文件完整路径；无权限或读取失败时为 null。
  final String? executablePath;

  /// 用于生成 `app_key` 的原始字符串：优先完整路径，其次进程名。
  String? get keySource {
    final String? path = executablePath;
    if (path != null && path.trim().isNotEmpty) return path;
    final String? name = processName;
    if (name != null && name.trim().isNotEmpty) return name;
    return null;
  }

  @override
  String toString() => 'ForegroundAppInfo(pid=$processId, name=$processName)';
}

/// 应用库中的一条记录（`applications` 表）。
class TrackedApplication {
  const TrackedApplication({
    required this.appKey,
    required this.displayName,
    this.processName,
    this.executablePath,
    required this.category,
    this.userOverridden = false,
    this.excluded = false,
    required this.firstSeenAt,
    required this.lastSeenAt,
  });

  final String appKey;
  final String displayName;
  final String? processName;
  final String? executablePath;
  final AppCategory category;

  /// 分类是否由用户手工设定。为 true 时内置规则不得覆盖。
  final bool userOverridden;

  /// 是否排除记录。
  final bool excluded;

  final DateTime firstSeenAt;
  final DateTime lastSeenAt;

  TrackedApplication copyWith({
    String? displayName,
    AppCategory? category,
    bool? userOverridden,
    bool? excluded,
    DateTime? lastSeenAt,
    String? executablePath,
    String? processName,
  }) =>
      TrackedApplication(
        appKey: appKey,
        displayName: displayName ?? this.displayName,
        processName: processName ?? this.processName,
        executablePath: executablePath ?? this.executablePath,
        category: category ?? this.category,
        userOverridden: userOverridden ?? this.userOverridden,
        excluded: excluded ?? this.excluded,
        firstSeenAt: firstSeenAt,
        lastSeenAt: lastSeenAt ?? this.lastSeenAt,
      );

  Map<String, Object?> toMap() => <String, Object?>{
        'app_key': appKey,
        'display_name': displayName,
        'process_name': processName,
        'executable_path': executablePath,
        'category': category.wireName,
        'user_overridden': userOverridden ? 1 : 0,
        'excluded': excluded ? 1 : 0,
        'first_seen_at': firstSeenAt.millisecondsSinceEpoch,
        'last_seen_at': lastSeenAt.millisecondsSinceEpoch,
      };

  static TrackedApplication fromMap(Map<String, Object?> m) => TrackedApplication(
        appKey: m['app_key']! as String,
        displayName: (m['display_name'] as String?) ?? (m['app_key']! as String),
        processName: m['process_name'] as String?,
        executablePath: m['executable_path'] as String?,
        category: AppCategory.fromWire(m['category'] as String?),
        userOverridden: ((m['user_overridden'] as int?) ?? 0) != 0,
        excluded: ((m['excluded'] as int?) ?? 0) != 0,
        firstSeenAt: DateTime.fromMillisecondsSinceEpoch(m['first_seen_at']! as int),
        lastSeenAt: DateTime.fromMillisecondsSinceEpoch(m['last_seen_at']! as int),
      );
}

/// 活动检查点（`activity_checkpoints` 表）。
///
/// 每 30 秒保存一次，用于「异常退出后按最后检查点关闭时间段」。
class ActivityCheckpoint {
  const ActivityCheckpoint({
    required this.segmentId,
    required this.appKey,
    required this.wallAt,
    required this.activeSeconds,
    required this.updatedAt,
  });

  /// 关联的活动段 ID。
  final String segmentId;
  final String appKey;

  /// 检查点对应的墙上时刻（异常退出时用作 ended_at）。
  final DateTime wallAt;

  /// 检查点时刻已累计的活跃秒数。
  final int activeSeconds;

  final DateTime updatedAt;

  Map<String, Object?> toMap() => <String, Object?>{
        'segment_id': segmentId,
        'app_key': appKey,
        'wall_at': wallAt.millisecondsSinceEpoch,
        'active_seconds': activeSeconds,
        'updated_at': updatedAt.millisecondsSinceEpoch,
      };

  static ActivityCheckpoint fromMap(Map<String, Object?> m) => ActivityCheckpoint(
        segmentId: m['segment_id']! as String,
        appKey: m['app_key']! as String,
        wallAt: DateTime.fromMillisecondsSinceEpoch(m['wall_at']! as int),
        activeSeconds: m['active_seconds']! as int,
        updatedAt: DateTime.fromMillisecondsSinceEpoch(m['updated_at']! as int),
      );
}

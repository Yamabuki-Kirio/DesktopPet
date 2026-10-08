import 'activity_enums.dart';

/// 使用统计的时间窗口。
///
/// **显式携带时区偏移**而不是依赖 `DateTime.now()` 的本地时区，
/// 这样「跨日边界」「不同时区下日期统计」都能被单元测试直接构造与断言。
class UsageWindow {
  const UsageWindow({
    required this.fromUtc,
    required this.toUtc,
    required this.label,
  });

  /// 窗口起点（UTC 时刻，含）。
  final DateTime fromUtc;

  /// 窗口终点（UTC 时刻，不含）。
  final DateTime toUtc;

  final String label;

  Duration get duration => toUtc.difference(fromUtc);

  /// 计算「本地某一天」的窗口 `[00:00, 次日 00:00)`。
  ///
  /// [nowUtc] 当前 UTC 时刻；[tzOffset] 相对 UTC 的偏移（例如 +08:00）。
  static UsageWindow dayContaining(
    DateTime nowUtc,
    Duration tzOffset, {
    int dayOffset = 0,
    String? label,
  }) {
    final DateTime localNow = nowUtc.toUtc().add(tzOffset);
    final DateTime localMidnight = DateTime.utc(
      localNow.year,
      localNow.month,
      localNow.day,
    ).add(Duration(days: dayOffset));
    final DateTime startUtc = localMidnight.subtract(tzOffset);
    return UsageWindow(
      fromUtc: startUtc,
      toUtc: startUtc.add(const Duration(days: 1)),
      label: label ?? '${localMidnight.year}-'
          '${localMidnight.month.toString().padLeft(2, '0')}-'
          '${localMidnight.day.toString().padLeft(2, '0')}',
    );
  }

  /// 最近 N 天（含今天）的窗口。
  static UsageWindow lastDays(
    DateTime nowUtc,
    Duration tzOffset, {
    int days = 7,
    String? label,
  }) {
    final UsageWindow today = dayContaining(nowUtc, tzOffset);
    return UsageWindow(
      fromUtc: today.fromUtc.subtract(Duration(days: days - 1)),
      toUtc: today.toUtc,
      label: label ?? '最近 $days 天',
    );
  }

  /// 本周（周一 00:00 起）。
  static UsageWindow weekContaining(
    DateTime nowUtc,
    Duration tzOffset, {
    String? label,
  }) {
    final UsageWindow today = dayContaining(nowUtc, tzOffset);
    final DateTime localToday = nowUtc.toUtc().add(tzOffset);
    // DateTime.weekday: 周一 = 1。
    final int back = localToday.weekday - 1;
    final DateTime startUtc = today.fromUtc.subtract(Duration(days: back));
    return UsageWindow(
      fromUtc: startUtc,
      toUtc: today.toUtc,
      label: label ?? '本周',
    );
  }

  /// 该窗口覆盖的本地日期键列表（`YYYY-MM-DD`）。
  List<String> localDayKeys(Duration tzOffset) {
    final List<String> keys = <String>[];
    DateTime cursor = fromUtc;
    while (cursor.isBefore(toUtc)) {
      final DateTime local = cursor.add(tzOffset);
      keys.add('${local.year}-'
          '${local.month.toString().padLeft(2, '0')}-'
          '${local.day.toString().padLeft(2, '0')}');
      cursor = cursor.add(const Duration(days: 1));
    }
    return keys;
  }
}

/// 今日 / 任意窗口的设备级概览。
class UsageOverview {
  const UsageOverview({
    this.sessionSeconds = 0,
    this.activeSeconds = 0,
    this.idleSeconds = 0,
    this.appActiveSeconds = 0,
    this.longestContinuousSeconds = 0,
    this.firstActiveAt,
    this.lastActiveAt,
    this.deviceMetricsAvailable = false,
  });

  /// 屏幕会话时间：解锁且未休眠。
  final int sessionSeconds;

  /// 活跃使用时间：屏幕会话中用户未超过空闲阈值。
  final int activeSeconds;

  /// 空闲时间：解锁但用户超过空闲阈值。
  final int idleSeconds;

  /// 应用使用时间：活跃时间中归属到有效前台应用的部分。
  final int appActiveSeconds;

  /// 最长连续使用时间。
  final int longestContinuousSeconds;

  final DateTime? firstActiveAt;
  final DateTime? lastActiveAt;

  /// 是否**真的**有设备级指标（`daily_usage` 行）。
  ///
  /// Android 的原生采集只产出应用会话（`activity_segments`），没有设备级
  /// 屏幕会话 / 空闲来源 —— 因此界面对这一项为 false 的情况必须**如实说明**，
  /// 而不是显示三个 0 让人以为"今天没用过"（Phase 4C-5.1B）。
  final bool deviceMetricsAvailable;

  static const UsageOverview empty = UsageOverview();
}

/// 应用排行的一行。
class AppUsageRow {
  const AppUsageRow({
    required this.appKey,
    required this.displayName,
    required this.category,
    required this.activeSeconds,
    required this.segmentCount,
    required this.ratioOfAppTime,
  });

  final String appKey;
  final String displayName;
  final AppCategory category;
  final int activeSeconds;

  /// 使用段次数。
  final int segmentCount;

  /// 占「应用使用时间」的比例（0~1）。
  final double ratioOfAppTime;
}

/// 分类统计的一行。
class CategoryUsageRow {
  const CategoryUsageRow({
    required this.category,
    required this.activeSeconds,
    required this.ratioOfAppTime,
  });

  final AppCategory category;
  final int activeSeconds;
  final double ratioOfAppTime;
}

/// 使用时间段列表的一行（Phase 4C-5.1B，需求 §8.2）。
///
/// 与 [AppUsageRow] 的区别：这里保留**真实的起止时刻**，因此跨小时 / 跨午夜
/// 的时间段可以如实展示；时长用记录值，不按窗口比例折算。
class UsageSegmentRow {
  const UsageSegmentRow({
    required this.segmentId,
    required this.appKey,
    required this.displayName,
    required this.category,
    required this.startedAtUtc,
    required this.endedAtUtc,
    required this.activeSeconds,
    required this.endReason,
    required this.running,
  });

  final String segmentId;
  final String appKey;
  final String displayName;
  final AppCategory category;

  /// 真实开始 / 结束时刻（UTC；展示时转本地时区）。
  final DateTime startedAtUtc;
  final DateTime endedAtUtc;

  final int activeSeconds;

  /// 结束原因（`app_switch` / `screen_off` / …；进行中为空）。
  final String? endReason;

  /// 是否仍在进行中（进行中的段**不写结束时间**，只在界面标「使用中」）。
  final bool running;

  /// 结束原因的中文说明（进行中时为「使用中」）。
  ///
  /// 先查**已有的** [SegmentEndReason]（Windows 采集器写的那套），
  /// 再兜底到 Android 原生会话的结束原因 —— 避免同一份映射写两遍。
  String get endReasonLabelZh {
    if (running) return '使用中';
    final String? known = SegmentEndReason.fromWire(endReason)?.labelZh;
    if (known != null) return known;
    return switch (endReason) {
      'app_switch' => '切换到其他应用',
      'screen_off' => '熄屏 / 锁屏',
      'service_stopped' => '桌宠服务停止',
      'collection_paused' => '暂停采集',
      'permission_revoked' => '权限被撤销',
      'collector_unavailable' => '暂时无法识别',
      'process_recovery' => '异常退出后恢复',
      null => '已结束',
      _ => endReason!,
    };
  }
}

/// 一次统计查询的完整结果。
class UsageSummary {
  const UsageSummary({
    required this.window,
    required this.overview,
    required this.apps,
    required this.categories,
  });

  final UsageWindow window;
  final UsageOverview overview;
  final List<AppUsageRow> apps;
  final List<CategoryUsageRow> categories;

  static UsageSummary emptyFor(UsageWindow window) => UsageSummary(
        window: window,
        overview: UsageOverview.empty,
        apps: const <AppUsageRow>[],
        categories: const <CategoryUsageRow>[],
      );
}

/// 把秒数格式化为「2 小时 14 分」这类可读文本。
String formatDurationZh(int seconds) {
  if (seconds <= 0) return '0 分';
  final int h = seconds ~/ 3600;
  final int m = (seconds % 3600) ~/ 60;
  final int s = seconds % 60;
  if (h > 0) return m > 0 ? '$h 小时 $m 分' : '$h 小时';
  if (m > 0) return '$m 分';
  return '$s 秒';
}

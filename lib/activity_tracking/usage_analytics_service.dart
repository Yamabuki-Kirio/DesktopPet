import 'dart:math' as math;

import '../core/constants.dart';
import '../database/dao/activity_dao.dart';
import '../database/dao/daily_usage_dao.dart';
import 'application_repository.dart';
import 'models/activity_enums.dart';
import 'models/activity_sample.dart';
import 'models/tracking_settings.dart';
import 'models/usage_stats.dart';

/// 使用统计查询服务（需求「九、十三」）。
///
/// 口径（详见 `docs/12-使用统计口径.md`）：
/// - **屏幕会话时间**：设备解锁且未休眠的时间（来自 `daily_usage`）；
/// - **活跃使用时间**：屏幕会话中用户未超过空闲阈值的时间（来自 `daily_usage`）；
/// - **空闲时间**：解锁但用户超过空闲阈值的时间（来自 `daily_usage`）；
/// - **应用使用时间**：活跃时间中归属到有效前台应用的部分（来自 `activity_segments`）。
///
/// 后两者刻意分开：只要没有可用的前台应用（例如锁屏前的一瞬、系统弹窗），
/// 设备可能仍算「活跃」，但没有应用可归属，因此不能混为一谈。
///
/// 所有查询都按 **owner + 设备** 过滤，绝不跨设备求和（验收第 25 项）。
class UsageAnalyticsService {
  UsageAnalyticsService({
    required ActivityDao activityDao,
    required DailyUsageDao dailyUsageDao,
    required ApplicationRepository applications,
    required this.ownerId,
    required this.deviceLocalId,
  })  : _activityDao = activityDao,
        _dailyUsageDao = dailyUsageDao,
        _applications = applications;

  final ActivityDao _activityDao;
  final DailyUsageDao _dailyUsageDao;
  final ApplicationRepository _applications;

  final String ownerId;
  final String deviceLocalId;

  /// 计算某个时间窗口的完整统计。
  Future<UsageSummary> summarize(
    UsageWindow window, {
    Duration tzOffset = Duration.zero,
    DateTime? nowUtc,
  }) async {
    final DateTime now = nowUtc ?? DateTime.now().toUtc();

    final List<ActivitySegment> segments = await _activityDao.listOverlapping(
      ownerId,
      window.fromUtc,
      window.toUtc,
      deviceLocalId: deviceLocalId,
    );

    // 1. 把跨界段裁剪到窗口内，并给出「按墙钟比例折算的活跃秒数」。
    //
    //    折算而不是直接累加 active_seconds，是为了让跨零点的一段在两天里
    //    各自只算属于自己的那部分（验收第 23 项）。
    final Map<String, _AppAccumulator> byApp = <String, _AppAccumulator>{};
    final List<_Clipped> clipped = <_Clipped>[];

    for (final ActivitySegment seg in segments) {
      final DateTime segEnd = seg.endedAt ?? now;
      final DateTime start = seg.startedAt.isAfter(window.fromUtc) ? seg.startedAt : window.fromUtc;
      final DateTime end = segEnd.isBefore(window.toUtc) ? segEnd : window.toUtc;
      if (!end.isAfter(start)) continue;

      final int totalWallMs = segEnd.difference(seg.startedAt).inMilliseconds;
      final int overlapMs = end.difference(start).inMilliseconds;
      final int activeSeconds = seg.activeSeconds ?? 0;
      final int credited = totalWallMs <= 0
          ? 0
          : (activeSeconds * overlapMs / totalWallMs).round();

      clipped.add(_Clipped(start: start, end: end, activeSeconds: credited));

      final _AppAccumulator acc = byApp.putIfAbsent(
        seg.appKey,
        () => _AppAccumulator(appKey: seg.appKey),
      );
      acc.activeSeconds += credited;
      acc.segmentCount += 1;
    }

    final int appActiveSeconds =
        byApp.values.fold<int>(0, (int sum, _AppAccumulator a) => sum + a.activeSeconds);

    // 2. 应用排行（按活跃秒数倒序）。
    final List<AppUsageRow> appRows = byApp.values.map((_AppAccumulator a) {
      final TrackedApplication? app = _applications.find(a.appKey);
      return AppUsageRow(
        appKey: a.appKey,
        displayName: app?.displayName ?? a.appKey,
        category: app?.category ?? AppCategory.other,
        activeSeconds: a.activeSeconds,
        segmentCount: a.segmentCount,
        ratioOfAppTime: appActiveSeconds <= 0 ? 0 : a.activeSeconds / appActiveSeconds,
      );
    }).toList()
      ..sort((AppUsageRow a, AppUsageRow b) => b.activeSeconds.compareTo(a.activeSeconds));

    // 3. 分类统计。
    final Map<AppCategory, int> byCategory = <AppCategory, int>{};
    for (final _AppAccumulator a in byApp.values) {
      final AppCategory category =
          _applications.find(a.appKey)?.category ?? AppCategory.other;
      byCategory[category] = (byCategory[category] ?? 0) + a.activeSeconds;
    }
    final List<CategoryUsageRow> categoryRows = byCategory.entries
        .map((MapEntry<AppCategory, int> e) => CategoryUsageRow(
              category: e.key,
              activeSeconds: e.value,
              ratioOfAppTime: appActiveSeconds <= 0 ? 0 : e.value / appActiveSeconds,
            ))
        .toList()
      ..sort((CategoryUsageRow a, CategoryUsageRow b) =>
          b.activeSeconds.compareTo(a.activeSeconds));

    // 4. 设备级会话 / 活跃 / 空闲（来自 daily_usage）。
    final _DeviceTotals device = await _deviceTotals(window, tzOffset, clipped);

    final UsageOverview overview = UsageOverview(
      sessionSeconds: device.sessionSeconds,
      activeSeconds: device.activeSeconds,
      idleSeconds: device.idleSeconds,
      appActiveSeconds: appActiveSeconds,
      longestContinuousSeconds: _longestContinuousSeconds(clipped),
      firstActiveAt: device.firstActiveAt,
      lastActiveAt: device.lastActiveAt,
      deviceMetricsAvailable: device.available,
    );

    return UsageSummary(
      window: window,
      overview: overview,
      apps: appRows,
      categories: categoryRows,
    );
  }

  /// 使用时间段列表（Phase 4C-5.1B，需求 §8.2）。
  ///
  /// 与 [summarize] 的**同一套过滤**（owner + 设备 + 同一个 [window]），
  /// 因此"累计时长"和"时间段列表"永远说的是同一批数据（需求 §8.3）。
  ///
  /// * 按开始时间**倒序**；
  /// * **不裁剪**跨界段：跨小时 / 跨午夜的时间段原样显示真实起止时刻；
  /// * `activeSeconds` 用记录值，不按窗口比例折算。
  Future<List<UsageSegmentRow>> timeline(UsageWindow window, {int limit = 200}) async {
    final List<ActivitySegment> segments = await _activityDao.listOverlapping(
      ownerId,
      window.fromUtc,
      window.toUtc,
      deviceLocalId: deviceLocalId,
    );
    final List<UsageSegmentRow> rows = segments.map((ActivitySegment seg) {
      final TrackedApplication? app = _applications.find(seg.appKey);
      return UsageSegmentRow(
        segmentId: seg.id,
        appKey: seg.appKey,
        displayName: app?.displayName ?? seg.appName ?? seg.appKey,
        category: app?.category ?? AppCategory.other,
        startedAtUtc: seg.startedAt.toUtc(),
        endedAtUtc: (seg.endedAt ?? seg.startedAt).toUtc(),
        activeSeconds: seg.activeSeconds ?? 0,
        endReason: seg.endReason,
        running: seg.endedAt == null,
      );
    }).toList(growable: false)
      ..sort((UsageSegmentRow a, UsageSegmentRow b) =>
          b.startedAtUtc.compareTo(a.startedAtUtc));
    return rows.length > limit ? rows.sublist(0, limit) : rows;
  }

  /// 把 [UsageRange] 换算成具体窗口。
  ///
  /// 抽成公开静态方法的原因：界面要把**同一个窗口**同时用于累计统计与
  /// 时间段列表（需求 §8.3「累计时长和时间段列表必须使用同一筛选范围」），
  /// 各自换算一次就可能因跨越零点而错位。
  static UsageWindow windowFor(
    UsageRange range, {
    DateTime? nowUtc,
    Duration? tzOffset,
  }) {
    final DateTime now = nowUtc ?? DateTime.now().toUtc();
    final Duration offset = tzOffset ?? DateTime.now().timeZoneOffset;
    return switch (range) {
      UsageRange.today => UsageWindow.dayContaining(now, offset, label: '今天'),
      UsageRange.yesterday => UsageWindow.dayContaining(
          now,
          offset,
          dayOffset: -1,
          label: '昨天',
        ),
      UsageRange.last7Days => UsageWindow.lastDays(now, offset, days: 7),
      UsageRange.thisWeek => UsageWindow.weekContaining(now, offset),
    };
  }

  /// 按 [UsageRange] 便捷取数。
  Future<UsageSummary> summarizeRange(
    UsageRange range, {
    DateTime? nowUtc,
    Duration? tzOffset,
  }) async {
    final DateTime now = nowUtc ?? DateTime.now().toUtc();
    final Duration offset = tzOffset ?? DateTime.now().timeZoneOffset;
    return summarize(
      windowFor(range, nowUtc: now, tzOffset: offset),
      tzOffset: offset,
      nowUtc: now,
    );
  }

  /// 汇总窗口内涉及到的每日用量行。
  ///
  /// 没有任何 `daily_usage` 行时（Android：原生采集只产出应用会话），
  /// **如实标记 `available = false`**，并用活动段推出「首次 / 最后活跃」，
  /// 让界面既能显示有意义的首末活跃时间，又不会把 0 当成真实值。
  Future<_DeviceTotals> _deviceTotals(
    UsageWindow window,
    Duration tzOffset,
    List<_Clipped> clipped,
  ) async {
    final List<String> keys = window.localDayKeys(tzOffset);
    List<DailyUsage> rows = <DailyUsage>[];
    for (final String key in keys) {
      final DailyUsage? row = await _dailyUsageDao.find(ownerId, deviceLocalId, key);
      if (row != null) rows.add(row);
    }

    // 兜底：一个都没命中时（例如用户在两次运行之间改了时区），
    // 用「最后更新时间落在窗口内」的行补上，避免概览突然显示 0。
    if (rows.isEmpty) {
      rows = await _dailyUsageDao.listByUpdatedRange(
        ownerId,
        deviceLocalId,
        window.fromUtc,
        window.toUtc,
      );
    }

    int session = 0;
    int active = 0;
    int idle = 0;
    DateTime? first;
    DateTime? last;
    for (final DailyUsage row in rows) {
      session += row.sessionSeconds;
      active += row.activeSeconds;
      idle += row.idleSeconds;
      final DateTime? f = row.firstActiveAt;
      if (f != null && (first == null || f.isBefore(first))) first = f;
      final DateTime? l = row.lastActiveAt;
      if (l != null && (last == null || l.isAfter(last))) last = l;
    }
    if (rows.isEmpty) {
      // 没有设备级来源：首末活跃从活动段推出（与"应用使用时间"同一批数据）。
      for (final _Clipped item in clipped) {
        if (first == null || item.start.isBefore(first)) first = item.start;
        if (last == null || item.end.isAfter(last)) last = item.end;
      }
    }
    return _DeviceTotals(
      sessionSeconds: session,
      activeSeconds: active,
      idleSeconds: idle,
      firstActiveAt: first,
      lastActiveAt: last,
      available: rows.isNotEmpty,
    );
  }

  /// 最长连续使用时间。
  ///
  /// 把窗口内被裁剪过的活动段按时间排序，相邻间隔小于
  /// [ActivityTracking.continuousGapToleranceMs] 视为「同一段连续使用」，
  /// 取其中活跃秒数之和的最大值。
  int _longestContinuousSeconds(List<_Clipped> clipped) {
    if (clipped.isEmpty) return 0;
    clipped.sort((_Clipped a, _Clipped b) => a.start.compareTo(b.start));

    int best = 0;
    int current = clipped.first.activeSeconds;
    DateTime prevEnd = clipped.first.end;
    best = current;

    for (int i = 1; i < clipped.length; i++) {
      final _Clipped item = clipped[i];
      final int gapMs = item.start.difference(prevEnd).inMilliseconds;
      if (gapMs <= ActivityTracking.continuousGapToleranceMs) {
        current += item.activeSeconds;
      } else {
        current = item.activeSeconds;
      }
      best = math.max(best, current);
      if (item.end.isAfter(prevEnd)) prevEnd = item.end;
    }
    return best;
  }
}

/// 被裁剪到统计窗口内的一段。
class _Clipped {
  const _Clipped({
    required this.start,
    required this.end,
    required this.activeSeconds,
  });

  final DateTime start;
  final DateTime end;
  final int activeSeconds;
}

/// 单个应用的累计器。
class _AppAccumulator {
  _AppAccumulator({required this.appKey});

  final String appKey;
  int activeSeconds = 0;
  int segmentCount = 0;
}

/// 设备级汇总（不含应用归属）。
class _DeviceTotals {
  const _DeviceTotals({
    this.sessionSeconds = 0,
    this.activeSeconds = 0,
    this.idleSeconds = 0,
    this.firstActiveAt,
    this.lastActiveAt,
    this.available = false,
  });

  final int sessionSeconds;
  final int activeSeconds;
  final int idleSeconds;
  final DateTime? firstActiveAt;
  final DateTime? lastActiveAt;

  /// 是否真的有设备级数据行（false = 本窗口内的数字不具代表性，界面要如实说明）。
  final bool available;
}

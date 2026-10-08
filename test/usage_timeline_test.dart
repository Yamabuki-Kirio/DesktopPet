import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:petlife/activity_tracking/application_repository.dart';
import 'package:petlife/activity_tracking/models/activity_enums.dart';
import 'package:petlife/activity_tracking/models/usage_stats.dart';
import 'package:petlife/activity_tracking/usage_analytics_service.dart';
import 'package:petlife/core/constants.dart';
import 'package:petlife/database/app_database.dart';
import 'package:petlife/database/dao/activity_dao.dart';
import 'package:petlife/database/dao/application_dao.dart';
import 'package:petlife/database/dao/daily_usage_dao.dart';

import 'support/sqlite_test_bootstrap.dart';

const String kOwner = 'local.default';
const String kDevice = 'android-install-uuid';
const String kOtherDevice = 'desktop.local';

/// Phase 4C-5.1B：使用时间段列表与"Android 无设备级指标"的如实呈现。
///
/// 覆盖需求 §13.2 的：时间段排序、日期边界、本机设备 ID 过滤、今日累计口径。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SqliteTestBootstrap.ensureLoaded();

  late Directory tmp;
  late AppDatabase db;
  late ActivityDao activityDao;
  late ApplicationRepository apps;
  late UsageAnalyticsService analytics;

  // 固定"现在"：2026-03-10 12:00 UTC = 本地（+08:00）20:00。
  final DateTime nowUtc = DateTime.utc(2026, 3, 10, 12);
  const Duration tz = Duration(hours: 8);

  setUpAll(() {
    tmp = Directory.systemTemp.createTempSync('petlife_timeline_test');
  });

  tearDownAll(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  setUp(() async {
    await AppDatabase.close();
    db = await AppDatabase.open(
      path: p.join(tmp.path, 'timeline_${DateTime.now().microsecondsSinceEpoch}.db'),
    );
    activityDao = ActivityDao(db.raw);
    apps = ApplicationRepository(dao: ApplicationDao(db.raw));
    await apps.load();
    analytics = UsageAnalyticsService(
      activityDao: activityDao,
      dailyUsageDao: DailyUsageDao(db.raw),
      applications: apps,
      ownerId: kOwner,
      deviceLocalId: kDevice,
    );
  });

  tearDown(() async {
    await AppDatabase.close();
  });

  /// 写入一段活动记录（用真实 DAO，与导入路径落库结果一致）。
  Future<void> seed({
    required String id,
    required String appKey,
    required DateTime startedAtUtc,
    DateTime? endedAtUtc,
    int? activeSeconds,
    String? endReason = 'app_switch',
    String device = kDevice,
  }) async {
    await activityDao.insert(ActivitySegment(
      id: id,
      ownerId: kOwner,
      deviceLocalId: device,
      appKey: appKey,
      appName: appKey,
      processName: appKey,
      startedAt: startedAtUtc,
      endedAt: endedAtUtc,
      activeSeconds: activeSeconds,
      endReason: endReason,
      createdAt: startedAtUtc,
    ));
  }

  UsageWindow today() =>
      UsageAnalyticsService.windowFor(UsageRange.today, nowUtc: nowUtc, tzOffset: tz);

  group('使用时间段', () {
    test('按开始时间倒序，且保留真实起止时刻（跨小时）', () async {
      await seed(
        id: 'a',
        appKey: 'chrome',
        startedAtUtc: DateTime.utc(2026, 3, 10, 1, 10),
        endedAtUtc: DateTime.utc(2026, 3, 10, 1, 25),
        activeSeconds: 900,
      );
      await seed(
        id: 'b',
        appKey: 'org.telegram.messenger',
        startedAtUtc: DateTime.utc(2026, 3, 10, 3, 0),
        endedAtUtc: DateTime.utc(2026, 3, 10, 3, 30),
        activeSeconds: 1800,
      );
      await seed(
        id: 'c',
        appKey: 'chrome',
        startedAtUtc: DateTime.utc(2026, 3, 10, 2, 0),
        endedAtUtc: DateTime.utc(2026, 3, 10, 2, 5),
        activeSeconds: 300,
      );

      final List<UsageSegmentRow> rows = await analytics.timeline(today());
      expect(rows.map((UsageSegmentRow r) => r.segmentId), <String>['b', 'c', 'a']);
      expect(rows.first.startedAtUtc, DateTime.utc(2026, 3, 10, 3, 0));
      expect(rows.first.endedAtUtc, DateTime.utc(2026, 3, 10, 3, 30));
      expect(rows.first.activeSeconds, 1800);
      expect(rows.first.endReasonLabelZh, '切换到其他应用');
      expect(rows.first.running, isFalse);
    });

    test('跨午夜的段保留真实起止，不按窗口裁剪', () async {
      // 本地 3/9 23:50 → 3/10 00:20（UTC 15:50 → 16:20）。
      await seed(
        id: 'midnight',
        appKey: 'chrome',
        startedAtUtc: DateTime.utc(2026, 3, 9, 15, 50),
        endedAtUtc: DateTime.utc(2026, 3, 9, 16, 20),
        activeSeconds: 1800,
      );
      final List<UsageSegmentRow> rows = await analytics.timeline(today());
      expect(rows, hasLength(1));
      // 起点在"昨天"，但真实起点必须原样保留（需求 §8.2）。
      expect(rows.first.startedAtUtc, DateTime.utc(2026, 3, 9, 15, 50));
      expect(rows.first.endedAtUtc, DateTime.utc(2026, 3, 9, 16, 20));
    });

    test('进行中的段标「使用中」且不写结束时间', () async {
      await seed(
        id: 'running',
        appKey: 'chrome',
        startedAtUtc: DateTime.utc(2026, 3, 10, 3, 0),
        endedAtUtc: null,
        activeSeconds: 60,
        endReason: null,
      );
      final List<UsageSegmentRow> rows = await analytics.timeline(today());
      expect(rows.single.running, isTrue);
      expect(rows.single.endReasonLabelZh, '使用中');
      expect(rows.single.endedAtUtc, rows.single.startedAtUtc);
    });

    test('只查本机设备标识的数据（不同设备不混入）', () async {
      await seed(
        id: 'mine',
        appKey: 'chrome',
        startedAtUtc: DateTime.utc(2026, 3, 10, 1, 0),
        endedAtUtc: DateTime.utc(2026, 3, 10, 1, 5),
        activeSeconds: 300,
      );
      await seed(
        id: 'other',
        appKey: 'code',
        startedAtUtc: DateTime.utc(2026, 3, 10, 1, 0),
        endedAtUtc: DateTime.utc(2026, 3, 10, 9, 0),
        activeSeconds: 28800,
        device: kOtherDevice,
      );

      final List<UsageSegmentRow> rows = await analytics.timeline(today());
      expect(rows.map((UsageSegmentRow r) => r.segmentId), <String>['mine']);

      final UsageSummary summary = await analytics.summarize(today());
      expect(summary.overview.appActiveSeconds, 300);
      expect(summary.apps.single.appKey, 'chrome');
    });

    test('日期边界：昨天 / 最近 7 天各取各的', () async {
      await seed(
        id: 'yesterday',
        appKey: 'chrome',
        startedAtUtc: DateTime.utc(2026, 3, 9, 2, 0),
        endedAtUtc: DateTime.utc(2026, 3, 9, 2, 10),
        activeSeconds: 600,
      );
      await seed(
        id: 'today',
        appKey: 'chrome',
        startedAtUtc: DateTime.utc(2026, 3, 10, 2, 0),
        endedAtUtc: DateTime.utc(2026, 3, 10, 2, 20),
        activeSeconds: 1200,
      );

      final List<UsageSegmentRow> yesterdayRows = await analytics.timeline(
        UsageAnalyticsService.windowFor(UsageRange.yesterday, nowUtc: nowUtc, tzOffset: tz),
      );
      expect(yesterdayRows.map((UsageSegmentRow r) => r.segmentId), <String>['yesterday']);

      final List<UsageSegmentRow> weekRows = await analytics.timeline(
        UsageAnalyticsService.windowFor(UsageRange.last7Days, nowUtc: nowUtc, tzOffset: tz),
      );
      expect(weekRows.map((UsageSegmentRow r) => r.segmentId), containsAll(<String>['yesterday', 'today']));
    });

    test('累计统计与时间段列表使用同一个窗口（同一批数据）', () async {
      await seed(
        id: 'x',
        appKey: 'chrome',
        startedAtUtc: DateTime.utc(2026, 3, 10, 1, 0),
        endedAtUtc: DateTime.utc(2026, 3, 10, 1, 30),
        activeSeconds: 1800,
      );
      final UsageWindow window = today();
      final UsageSummary summary = await analytics.summarize(window);
      final List<UsageSegmentRow> rows = await analytics.timeline(window);
      expect(rows, hasLength(1));
      expect(summary.overview.appActiveSeconds, rows.single.activeSeconds);
    });
  });

  group('Android 无设备级指标的如实呈现', () {
    test('只有应用会话时 deviceMetricsAvailable 为 false，首末活跃由会话推出', () async {
      await seed(
        id: 'a',
        appKey: 'chrome',
        startedAtUtc: DateTime.utc(2026, 3, 10, 1, 0),
        endedAtUtc: DateTime.utc(2026, 3, 10, 1, 10),
        activeSeconds: 600,
      );
      await seed(
        id: 'b',
        appKey: 'chrome',
        startedAtUtc: DateTime.utc(2026, 3, 10, 4, 0),
        endedAtUtc: DateTime.utc(2026, 3, 10, 4, 20),
        activeSeconds: 1200,
      );

      final UsageSummary summary = await analytics.summarize(today());
      expect(summary.overview.deviceMetricsAvailable, isFalse);
      // 今日总使用时长 = 应用使用时间（Android 的唯一口径）。
      expect(summary.overview.appActiveSeconds, 1800);
      expect(summary.overview.activeSeconds, 0);
      // 首末活跃不从 0 摆烂，而是用会话推导（比较的是时刻，时区表示无关）。
      expect(summary.overview.firstActiveAt!.toUtc(), DateTime.utc(2026, 3, 10, 1, 0));
      expect(summary.overview.lastActiveAt!.toUtc(), DateTime.utc(2026, 3, 10, 4, 20));
    });

    test('完全没有记录时安全返回空结果，不报错', () async {
      final UsageSummary summary = await analytics.summarize(today());
      expect(summary.overview.appActiveSeconds, 0);
      expect(summary.overview.deviceMetricsAvailable, isFalse);
      expect(summary.apps, isEmpty);
      expect(await analytics.timeline(today()), isEmpty);
    });
  });

  group('分类与显示名', () {
    test('时间段用应用库里的显示名与分类（用户在统计页改过就跟着变）', () async {
      await apps.ensureSeenFromPlatform(
        appKey: 'org.telegram.messenger',
        displayName: 'Telegram',
        category: AppCategory.social,
        at: DateTime.utc(2026, 3, 10),
      );
      await seed(
        id: 'tg',
        appKey: 'org.telegram.messenger',
        startedAtUtc: DateTime.utc(2026, 3, 10, 1, 0),
        endedAtUtc: DateTime.utc(2026, 3, 10, 1, 5),
        activeSeconds: 300,
      );
      await apps.setDisplayName('org.telegram.messenger', '电报');
      await apps.setCategory('org.telegram.messenger', AppCategory.entertainment);

      final List<UsageSegmentRow> rows = await analytics.timeline(today());
      expect(rows.single.displayName, '电报');
      expect(rows.single.category, AppCategory.entertainment);
    });

    test('未登记的应用退回 app_key，不编造显示名', () async {
      await seed(
        id: 'unknown',
        appKey: 'com.example.unknown',
        startedAtUtc: DateTime.utc(2026, 3, 10, 1, 0),
        endedAtUtc: DateTime.utc(2026, 3, 10, 1, 5),
        activeSeconds: 300,
      );
      final List<UsageSegmentRow> rows = await analytics.timeline(today());
      expect(rows.single.displayName, 'com.example.unknown');
      expect(rows.single.category, AppCategory.other);
    });
  });
}

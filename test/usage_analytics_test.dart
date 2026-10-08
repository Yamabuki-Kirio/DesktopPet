import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:petlife/activity_tracking/application_repository.dart';
import 'package:petlife/activity_tracking/models/activity_enums.dart';
import 'package:petlife/activity_tracking/models/tracking_settings.dart';
import 'package:petlife/activity_tracking/models/usage_stats.dart';
import 'package:petlife/activity_tracking/usage_analytics_service.dart';
import 'package:petlife/core/constants.dart';
import 'package:petlife/database/app_database.dart';
import 'package:petlife/database/dao/activity_dao.dart';
import 'package:petlife/database/dao/application_dao.dart';
import 'package:petlife/database/dao/daily_usage_dao.dart';

import 'support/sqlite_test_bootstrap.dart';

const String kOwner = 'local.default';
const String kDevice = 'desktop.local';
const String kOtherDevice = 'desktop.other';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SqliteTestBootstrap.ensureLoaded();

  late Directory tmp;
  late AppDatabase db;
  late ActivityDao activityDao;
  late DailyUsageDao dailyUsageDao;
  late ApplicationRepository apps;
  late UsageAnalyticsService analytics;

  setUpAll(() {
    tmp = Directory.systemTemp.createTempSync('petlife_analytics_test');
  });

  tearDownAll(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  setUp(() async {
    await AppDatabase.close();
    db = await AppDatabase.open(
      path: p.join(tmp.path, 'usage_${DateTime.now().microsecondsSinceEpoch}.db'),
    );
    activityDao = ActivityDao(db.raw);
    dailyUsageDao = DailyUsageDao(db.raw);
    apps = ApplicationRepository(dao: ApplicationDao(db.raw));
    await apps.load();
    // 预先把要断言的应用登记进应用库（统计要以应用库里的显示名与分类为准）。
    final DateTime seed = DateTime.utc(2026, 1, 1);
    await apps.ensureSeen(
        appKey: 'code',
        processName: 'Code.exe',
        executablePath: r'C:\Apps\Code.exe',
        at: seed);
    await apps.ensureSeen(
        appKey: 'bilibili',
        processName: 'bilibili.exe',
        executablePath: r'C:\Apps\bilibili.exe',
        at: seed);
    await apps.ensureSeen(
        appKey: 'chrome',
        processName: 'chrome.exe',
        executablePath: r'C:\Apps\chrome.exe',
        at: seed);
    analytics = UsageAnalyticsService(
      activityDao: activityDao,
      dailyUsageDao: dailyUsageDao,
      applications: apps,
      ownerId: kOwner,
      deviceLocalId: kDevice,
    );
  });

  tearDown(() async {
    await AppDatabase.close();
  });

  group('统计口径（需求 九 / 十三）', () {
    test('应用排行、分类统计与占比计算正确', () async {
      // code.exe 属于开发工具，bilibili 属于娱乐。
      await _insertSegment(
        activityDao,
        appKey: 'code',
        appName: 'Code',
        startedAt: DateTime.utc(2026, 9, 27, 1, 0),
        endedAt: DateTime.utc(2026, 9, 27, 2, 0),
        activeSeconds: 3600,
      );
      await _insertSegment(
        activityDao,
        appKey: 'bilibili',
        appName: 'bilibili',
        startedAt: DateTime.utc(2026, 9, 27, 2, 0),
        endedAt: DateTime.utc(2026, 9, 27, 2, 30),
        activeSeconds: 1800,
      );

      final DateTime now = DateTime.utc(2026, 9, 27, 12, 0);
      final UsageWindow window = UsageWindow.dayContaining(now, Duration.zero);
      final UsageSummary summary = await analytics.summarize(window, nowUtc: now);

      expect(summary.overview.appActiveSeconds, 3600 + 1800);
      expect(summary.apps, hasLength(2));
      expect(summary.apps.first.appKey, 'code');
      expect(summary.apps.first.displayName, 'Code');
      expect(summary.apps.first.ratioOfAppTime, closeTo(3600 / 5400, 0.001));
      expect(summary.apps.first.segmentCount, 1);

      final CategoryUsageRow dev = summary.categories
          .firstWhere((CategoryUsageRow c) => c.category == AppCategory.development);
      expect(dev.activeSeconds, 3600);
      final CategoryUsageRow ent = summary.categories
          .firstWhere((CategoryUsageRow c) => c.category == AppCategory.entertainment);
      expect(ent.activeSeconds, 1800);
    });

    test('23. 跨日边界：跨零点的一段只把属于当天的部分算进当天', () async {
      // 23:30 ~ 次日 00:30，共 1 小时，活跃 3600 秒（全活跃）。
      await _insertSegment(
        activityDao,
        appKey: 'code',
        appName: 'Code',
        startedAt: DateTime.utc(2026, 9, 27, 23, 30),
        endedAt: DateTime.utc(2026, 9, 28, 0, 30),
        activeSeconds: 3600,
      );

      final DateTime now = DateTime.utc(2026, 9, 28, 8, 0);
      final UsageSummary today =
          await analytics.summarizeRange(UsageRange.today, nowUtc: now, tzOffset: Duration.zero);
      final UsageSummary yesterday = await analytics
          .summarizeRange(UsageRange.yesterday, nowUtc: now, tzOffset: Duration.zero);

      // 一半落在今天（00:00~00:30），一半落在昨天（23:30~24:00）。
      expect(today.overview.appActiveSeconds, 1800);
      expect(yesterday.overview.appActiveSeconds, 1800);
      expect(today.overview.appActiveSeconds + yesterday.overview.appActiveSeconds, 3600,
          reason: '跨日裁剪不得凭空增加或丢失时间');
    });

    test('24. 不同时区下日期归属正确', () async {
      // UTC 2026-09-27 17:00 → UTC+8 是 09-28 01:00（属于 28 日），
      //                    → UTC-5 是 09-27 12:00（属于 27 日）。
      final DateTime base = DateTime.utc(2026, 9, 27, 16, 0);
      await _insertSegment(
        activityDao,
        appKey: 'code',
        appName: 'Code',
        startedAt: base,
        endedAt: base.add(const Duration(hours: 2)),
        activeSeconds: 7200,
      );

      const Duration plus8 = Duration(hours: 8);
      const Duration minus5 = Duration(hours: -5);

      final UsageSummary inPlus8 = await analytics.summarizeRange(
        UsageRange.today,
        nowUtc: DateTime.utc(2026, 9, 28, 2, 0),
        tzOffset: plus8,
      );
      final UsageSummary inMinus5 = await analytics.summarizeRange(
        UsageRange.today,
        nowUtc: DateTime.utc(2026, 9, 27, 20, 0),
        tzOffset: minus5,
      );

      // UTC+8 的「今天」是 09-28，该段 16:00~18:00 UTC = 09-28 00:00~02:00 本地，全部落进今天。
      expect(inPlus8.overview.appActiveSeconds, 7200);
      // UTC-5 的「今天」是 09-27，该段 16:00~18:00 UTC = 11:00~13:00 本地，同样全部落进今天。
      expect(inMinus5.overview.appActiveSeconds, 7200);

      // 但把 UTC+8 的查询挪到它的「昨天」，就不应命中。
      final UsageSummary plus8Yesterday = await analytics.summarizeRange(
        UsageRange.yesterday,
        nowUtc: DateTime.utc(2026, 9, 28, 2, 0),
        tzOffset: plus8,
      );
      expect(plus8Yesterday.overview.appActiveSeconds, 0,
          reason: '时区决定日期归属，不能一概按 UTC 日期统计');
    });

    test('25. 多个设备 ID 的数据不会错误合并', () async {
      await _insertSegment(
        activityDao,
        appKey: 'code',
        appName: 'Code',
        startedAt: DateTime.utc(2026, 9, 27, 1, 0),
        endedAt: DateTime.utc(2026, 9, 27, 2, 0),
        activeSeconds: 3600,
        deviceLocalId: kDevice,
      );
      await _insertSegment(
        activityDao,
        appKey: 'code',
        appName: 'Code',
        startedAt: DateTime.utc(2026, 9, 27, 1, 0),
        endedAt: DateTime.utc(2026, 9, 27, 4, 0),
        activeSeconds: 10800,
        deviceLocalId: kOtherDevice,
      );

      final DateTime now = DateTime.utc(2026, 9, 27, 12, 0);
      final UsageSummary summary = await analytics.summarize(
        UsageWindow.dayContaining(now, Duration.zero),
        nowUtc: now,
      );

      expect(summary.overview.appActiveSeconds, 3600,
          reason: '只能统计本设备的数据，不得把另一台设备的时长合并进来');
      expect(summary.apps.single.activeSeconds, 3600);

      // 每日用量同样按设备隔离。
      await _insertDaily(dailyUsageDao, kDevice, '2026-09-27', active: 3600, idle: 600);
      await _insertDaily(dailyUsageDao, kOtherDevice, '2026-09-27', active: 9999, idle: 9999);
      final UsageSummary after = await analytics.summarize(
        UsageWindow.dayContaining(now, Duration.zero),
        nowUtc: now,
      );
      expect(after.overview.activeSeconds, 3600);
      expect(after.overview.idleSeconds, 600);
      expect(after.overview.sessionSeconds, 4200,
          reason: '屏幕会话时间 = 活跃 + 空闲，并且只算本设备');
    });

    test('设备级指标与应用级指标分开呈现', () async {
      await _insertSegment(
        activityDao,
        appKey: 'code',
        appName: 'Code',
        startedAt: DateTime.utc(2026, 9, 27, 1, 0),
        endedAt: DateTime.utc(2026, 9, 27, 2, 0),
        activeSeconds: 3600,
      );
      // 设备活跃 5 小时，其中只有 1 小时归属到应用（其余时间没有有效前台应用）。
      await _insertDaily(dailyUsageDao, kDevice, '2026-09-27',
          active: 5 * 3600, idle: 1800, session: 5 * 3600 + 1800);

      final DateTime now = DateTime.utc(2026, 9, 27, 12, 0);
      final UsageSummary summary = await analytics.summarize(
        UsageWindow.dayContaining(now, Duration.zero),
        nowUtc: now,
      );

      expect(summary.overview.activeSeconds, 5 * 3600);
      expect(summary.overview.appActiveSeconds, 3600);
      expect(summary.overview.appActiveSeconds,
          lessThanOrEqualTo(summary.overview.activeSeconds),
          reason: '应用使用时间不可能超过设备活跃时间');
    });

    test('最长连续使用时间按容差合并相邻段', () async {
      final DateTime base = DateTime.utc(2026, 9, 27, 1, 0);
      // 三段相邻（间隔 10 秒 < 容差 60 秒）→ 视为一段连续使用。
      await _insertSegment(activityDao,
          appKey: 'code',
          appName: 'Code',
          startedAt: base,
          endedAt: base.add(const Duration(minutes: 10)),
          activeSeconds: 600);
      await _insertSegment(activityDao,
          appKey: 'chrome',
          appName: 'Chrome',
          startedAt: base.add(const Duration(minutes: 10, seconds: 10)),
          endedAt: base.add(const Duration(minutes: 20)),
          activeSeconds: 590);
      // 然后隔了 2 小时再使用一次。
      await _insertSegment(activityDao,
          appKey: 'code',
          appName: 'Code',
          startedAt: base.add(const Duration(hours: 2)),
          endedAt: base.add(const Duration(hours: 2, minutes: 5)),
          activeSeconds: 300);

      final DateTime now = DateTime.utc(2026, 9, 27, 12, 0);
      final UsageSummary summary = await analytics.summarize(
        UsageWindow.dayContaining(now, Duration.zero),
        nowUtc: now,
      );

      expect(summary.overview.longestContinuousSeconds, 1190,
          reason: '相邻段应合并计算，间隔 2 小时的那段要另起一段');
    });

    test('未知应用回退到 other 分类而不是报错', () async {
      await _insertSegment(
        activityDao,
        appKey: 'mystery',
        appName: 'Mystery',
        startedAt: DateTime.utc(2026, 9, 27, 3, 0),
        endedAt: DateTime.utc(2026, 9, 27, 3, 10),
        activeSeconds: 600,
      );
      final DateTime now = DateTime.utc(2026, 9, 27, 12, 0);
      final UsageSummary summary = await analytics.summarize(
        UsageWindow.dayContaining(now, Duration.zero),
        nowUtc: now,
      );
      expect(summary.apps.single.category, AppCategory.other);
    });

    test('格式化时长符合界面展示习惯', () {
      expect(formatDurationZh(0), '0 分');
      expect(formatDurationZh(59), '59 秒');
      expect(formatDurationZh(60), '1 分');
      expect(formatDurationZh(3600), '1 小时');
      expect(formatDurationZh(2 * 3600 + 14 * 60), '2 小时 14 分');
    });
  });
}

/// 插入一段活动记录。
Future<void> _insertSegment(
  ActivityDao dao, {
  required String appKey,
  required String appName,
  required DateTime startedAt,
  required DateTime endedAt,
  required int activeSeconds,
  String deviceLocalId = kDevice,
}) async {
  await dao.insert(ActivitySegment(
    id: '$appKey-${startedAt.microsecondsSinceEpoch}-$deviceLocalId',
    ownerId: kOwner,
    deviceLocalId: deviceLocalId,
    appKey: appKey,
    appName: appName,
    processName: '$appKey.exe',
    startedAt: startedAt,
    endedAt: endedAt,
    activeSeconds: activeSeconds,
    endReason: SegmentEndReason.foregroundChanged.wireName,
    createdAt: startedAt,
  ));
}

Future<void> _insertDaily(
  DailyUsageDao dao,
  String deviceLocalId,
  String dayKey, {
  required int active,
  required int idle,
  int? session,
}) async {
  await dao.upsert(DailyUsage(
    ownerId: kOwner,
    deviceLocalId: deviceLocalId,
    dayKey: dayKey,
    sessionSeconds: session ?? (active + idle),
    activeSeconds: active,
    idleSeconds: idle,
    updatedAt: DateTime.utc(2026, 9, 27, 12, 0),
  ));
}

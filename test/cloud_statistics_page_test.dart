import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:petlife/core/logger.dart';
import 'package:petlife/core/paths.dart';
import 'package:petlife/database/app_database.dart';
import 'package:petlife/database/dao/cloud_statistics_cache_dao.dart';
import 'package:petlife/sync/cloud_statistics_cache.dart';
import 'package:petlife/sync/cloud_statistics_controller.dart';
import 'package:petlife/sync/cloud_statistics_repository.dart';
import 'package:petlife/sync/models/cloud_statistics_models.dart';
import 'package:petlife/ui/pages/cloud_statistics_page.dart';

import 'support/fake_cloud_statistics.dart';
import 'support/sqlite_test_bootstrap.dart';

/// Phase 4B：云端统计页面（Widget 测试）。
///
/// 这里用的是"真控制器 + 真缓存表 + 假仓库"：既验证页面渲染，
/// 也验证缓存优先、离线标记、请求去重等真实行为。
/// 真实 sqflite 是异步 I/O，因此每次都需要 `tester.runAsync` 让 I/O 真正推进。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SqliteTestBootstrap.ensureLoaded();

  late Directory dir;
  late AppDatabase db;
  late CloudStatisticsCache cache;
  late FakeCloudStatisticsRepository repo;
  late CloudStatisticsController controller;
  String? account = 'user-a';
  final DateTime today = DateTime(2026, 9, 29, 18, 30);

  Future<void> boot() async {
    dir = Directory.systemTemp.createTempSync('petlife_cloud_ui');
    AppPaths.resetForTest();
    await AppPaths.initialize(overrideRoot: dir);
    await AppLog.initialize(logFile: AppPaths.instance.logFile);
    db = await AppDatabase.open(path: AppPaths.instance.databaseFile.path);
    cache = CloudStatisticsCache(CloudStatisticsCacheDao(db.raw));
    repo = FakeCloudStatisticsRepository();
    account = 'user-a';
    controller = CloudStatisticsController(
      repository: repo,
      cache: cache,
      currentAccountUserId: () => account,
      clock: () => today,
    );
  }

  Future<void> shutdown() async {
    controller.dispose();
    if (AppDatabase.isOpen) await AppDatabase.close();
    await AppLog.dispose();
    AppPaths.resetForTest();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  }

  /// 让真实 I/O 推进并刷新界面（不能用 pumpAndSettle：加载态有无限动画）。
  ///
  /// 至少推 10 轮；之后**只要控制器还在"加载/刷新中"就继续推**（上限 40 轮）。
  /// 原因：`flutter test` 会并行跑多个测试文件，真 sqflite I/O 在高负载下
  /// 可能超过固定轮次；固定预算会让"数据已加载"的断言随机失败。
  Future<void> settle(WidgetTester tester) async {
    for (int i = 0; i < 40; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 10));
      final bool busy = controller.status == CloudStatsStatus.loading ||
          controller.status == CloudStatsStatus.refreshing;
      if (i >= 9 && !busy) return;
    }
  }

  Widget page({
    bool signedIn = true,
    VoidCallback? onOpenAccount,
    double textScale = 1.0,
    bool active = true,
    Key? key,
  }) {
    return MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
        child: Scaffold(
          body: CloudStatisticsPage(
            // key 变化会重建 State，用于模拟"重新打开页面"（否则复用同一 State，
            // `_started` 已为 true 就不会再初始化，页面会停在空状态）。
            key: key,
            controller: controller,
            isSignedIn: () => signedIn,
            onOpenAccount: onOpenAccount,
            clock: () => today,
            active: active,
          ),
        ),
      ),
    );
  }

  Future<void> pumpPage(
    WidgetTester tester, {
    bool signedIn = true,
    VoidCallback? onOpenAccount,
    Size? size,
    double textScale = 1.0,
    Key? key,
  }) async {
    if (size != null) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
    }
    await tester.pumpWidget(page(
      signedIn: signedIn,
      onOpenAccount: onOpenAccount,
      textScale: textScale,
      key: key,
    ));
    await settle(tester);
  }

  group('未登录与首次加载', () {
    testWidgets('未登录显示登录提示，且不发起任何统计请求', (WidgetTester tester) async {
      await tester.runAsync(boot);
      addTearDown(() => tester.runAsync(shutdown));

      await pumpPage(tester, signedIn: false, onOpenAccount: () {});

      expect(find.text('登录后即可查看其他设备的云端使用统计'), findsOneWidget);
      expect(find.text('去登录'), findsOneWidget);
      expect(repo.calls, isEmpty, reason: '未登录不得请求云端统计');
    });

    testWidgets('首次进入只初始化一次，切换子页回来不会重复请求', (WidgetTester tester) async {
      await tester.runAsync(boot);
      addTearDown(() => tester.runAsync(shutdown));

      await pumpPage(tester);
      expect(repo.devicesCalls, 1);
      expect(repo.summaryCalls, 1);
      expect(repo.timelineCalls, 1);

      // 模拟"切走再切回"：active 变 false 再变 true，不应再发请求
      await tester.pumpWidget(page(active: false));
      await settle(tester);
      await tester.pumpWidget(page(active: true));
      await settle(tester);

      expect(repo.summaryCalls, 1, reason: '同一查询不应因切换子页而重复请求');
    });
  });

  group('筛选栏', () {
    testWidgets('显示日期、设备下拉（含全部设备）、刷新按钮', (WidgetTester tester) async {
      await tester.runAsync(boot);
      addTearDown(() => tester.runAsync(shutdown));

      await pumpPage(tester);

      expect(find.text('2026-09-29'), findsOneWidget);
      expect(find.text('今天'), findsOneWidget);
      expect(find.text('设备：'), findsOneWidget);
      // 默认选中"全部设备"
      expect(find.text('全部设备'), findsWidgets);
      expect(find.byTooltip('刷新云端统计'), findsOneWidget);
    });

    testWidgets('设备下拉列出全部设备与已撤销标记，切换设备会重查', (WidgetTester tester) async {
      await tester.runAsync(boot);
      addTearDown(() => tester.runAsync(shutdown));

      await pumpPage(tester);
      await tester.tap(find.byType(DropdownButton<String?>));
      // 打开菜单只有一段有限时长的过场动画。这里不用 pumpAndSettle：
      // 若此刻恰好在刷新中，刷新按钮的无限进度条会让它永远等不到静止。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('我的电脑 · Windows'), findsWidgets);
      expect(find.text('我的手机 · Android'), findsWidgets);

      await tester.tap(find.text('我的电脑 · Windows').last);
      // 选中设备会触发一次真实刷新：此时刷新按钮是无限旋转的进度条，
      // pumpAndSettle 永远等不到静止，必须用 settle 推进真实 I/O。
      await settle(tester);

      expect(repo.calls.contains('summary|2026-09-29|dev-pc'), isTrue,
          reason: '切换设备后必须带 device_id 重新查询');
    });

    testWidgets('切到前一天 / 回到今天；已是今天时"后一天"被禁用（不产生未来日期请求）',
        (WidgetTester tester) async {
      await tester.runAsync(boot);
      addTearDown(() => tester.runAsync(shutdown));

      await pumpPage(tester);

      // 今天 → 下一天按钮应为禁用态
      final Finder nextButton = find.ancestor(
        of: find.byIcon(Icons.chevron_right),
        matching: find.byType(IconButton),
      );
      expect(tester.widget<IconButton>(nextButton).onPressed, isNull,
          reason: '未来日期不允许产生请求');

      await tester.tap(find.byIcon(Icons.chevron_left));
      await settle(tester);
      expect(find.text('2026-09-28'), findsOneWidget);
      expect(repo.calls.contains('summary|2026-09-28|all'), isTrue);

      await tester.tap(find.text('今天'));
      await settle(tester);
      expect(find.text('2026-09-29'), findsOneWidget);
    });
  });

  group('汇总卡与应用统计', () {
    testWidgets('汇总卡显示累计时长、设备、应用/会话数、最近同步与刷新', (WidgetTester tester) async {
      await tester.runAsync(boot);
      addTearDown(() => tester.runAsync(shutdown));
      repo.lastSyncedAt = DateTime.utc(2026, 9, 29, 9, 20);
      repo.apps = <CloudAppUsage>[
        const CloudAppUsage(
          appId: 'msedge',
          appName: 'Microsoft Edge',
          duration: Duration(minutes: 85),
          sessionCount: 2,
        ),
        const CloudAppUsage(
          appId: 'code',
          appName: 'Visual Studio Code',
          duration: Duration(minutes: 52),
          sessionCount: 1,
        ),
      ];

      await pumpPage(tester);

      expect(find.text('今日累计 2 小时 17 分钟'), findsOneWidget);
      expect(find.text('全部设备'), findsWidgets);
      expect(find.text('2 个应用 · 3 段记录'), findsOneWidget);
      expect(find.textContaining('最近同步'), findsOneWidget);
      expect(find.textContaining('最近刷新'), findsOneWidget);
    });

    testWidgets('应用按时长降序显示，点击展开时间段并支持加载更多', (WidgetTester tester) async {
      await tester.runAsync(boot);
      addTearDown(() => tester.runAsync(shutdown));
      repo.apps = <CloudAppUsage>[
        const CloudAppUsage(
          appId: 'code',
          appName: 'Visual Studio Code',
          duration: Duration(minutes: 52),
          sessionCount: 1,
        ),
        const CloudAppUsage(
          appId: 'msedge',
          appName: 'Microsoft Edge',
          duration: Duration(minutes: 85),
          sessionCount: 2,
        ),
      ];

      await pumpPage(tester);

      // 降序：Edge 在前
      final double edgeY = tester.getTopLeft(find.text('Microsoft Edge')).dy;
      final double codeY = tester.getTopLeft(find.text('Visual Studio Code')).dy;
      expect(edgeY, lessThan(codeY));
      expect(find.text('1 小时 25 分钟'), findsOneWidget);
      expect(find.text('52 分钟'), findsOneWidget);

      // 展开 Edge
      await tester.tap(find.text('Microsoft Edge'));
      await settle(tester);
      expect(repo.sessionCalls, 1);
      expect(find.textContaining('09:12–09:35'), findsOneWidget);
      expect(find.text('23 分钟'), findsWidgets);
      expect(find.text('加载更多'), findsOneWidget, reason: '有 next_cursor 时显示加载更多');

      await tester.tap(find.text('加载更多'));
      await settle(tester);
      expect(repo.sessionCalls, 2, reason: '第二页应带 cursor 再查一次');
      expect(repo.calls.contains('sessions|msedge|cursor-2'), isTrue);
    });

    testWidgets('展开时只有该应用显示局部加载状态，页面其余部分不消失', (WidgetTester tester) async {
      await tester.runAsync(boot);
      addTearDown(() => tester.runAsync(shutdown));

      await pumpPage(tester);

      // 初始加载完成之后才挂起，这样只影响接下来的 sessions 请求。
      repo.hold = Completer<void>();
      await tester.tap(find.text('Microsoft Edge'));
      await settle(tester);

      expect(find.text('正在加载时间段…'), findsOneWidget, reason: '展开的应用要有局部加载状态');
      expect(find.textContaining('今日累计'), findsOneWidget, reason: '加载中页面主体不得被清空');
      expect(find.text('Visual Studio Code'), findsOneWidget, reason: '其他应用必须仍在');

      repo.hold!.complete();
      await settle(tester);

      expect(find.text('正在加载时间段…'), findsNothing);
      expect(find.textContaining('09:12–09:35'), findsOneWidget);
    });

    testWidgets('进行中的会话显示"进行中"而不是时长', (WidgetTester tester) async {
      await tester.runAsync(boot);
      addTearDown(() => tester.runAsync(shutdown));
      repo.sessions = <CloudUsageSession>[
        CloudUsageSession(
          id: 's-open',
          localRecordId: 's-open',
          deviceId: 'dev-pc',
          deviceName: '我的电脑',
          platform: 'windows',
          appId: 'msedge',
          appName: 'Microsoft Edge',
          startedAt: DateTime.utc(2026, 9, 29, 9, 12),
        ),
      ];

      await pumpPage(tester);
      await tester.tap(find.text('Microsoft Edge'));
      await settle(tester);

      expect(find.text('进行中'), findsOneWidget);
    });

    testWidgets('时间线按开始时间升序并显示设备与段数', (WidgetTester tester) async {
      await tester.runAsync(boot);
      addTearDown(() => tester.runAsync(shutdown));
      repo.timeline = <CloudTimelineEntry>[
        CloudTimelineEntry(
          appId: 'msedge',
          appName: 'Microsoft Edge',
          deviceId: 'dev-pc',
          deviceName: '我的电脑',
          platform: 'windows',
          startedAt: DateTime.utc(2026, 9, 29, 1, 12),
          endedAt: DateTime.utc(2026, 9, 29, 1, 35),
          duration: const Duration(minutes: 23),
          mergedSessionCount: 2,
        ),
        CloudTimelineEntry(
          appId: 'code',
          appName: 'Visual Studio Code',
          deviceId: 'dev-pc',
          deviceName: '我的电脑',
          platform: 'windows',
          startedAt: DateTime.utc(2026, 9, 29, 1, 48),
          endedAt: DateTime.utc(2026, 9, 29, 2, 20),
          duration: const Duration(minutes: 32),
        ),
      ];

      await pumpPage(tester);
      await tester.tap(find.text('时间线'));
      await tester.pumpAndSettle();

      expect(find.textContaining('09:12–09:35'), findsOneWidget);
      expect(find.textContaining('09:48–10:20'), findsOneWidget);
      expect(find.textContaining('我的电脑 · Windows · 2 段'), findsOneWidget);

      final double first = tester.getTopLeft(find.text('Microsoft Edge')).dy;
      final double second = tester.getTopLeft(find.text('Visual Studio Code')).dy;
      expect(first, lessThan(second), reason: '时间线必须按开始时间升序');
    });
  });

  group('页面状态', () {
    testWidgets('空数据显示引导文案', (WidgetTester tester) async {
      await tester.runAsync(boot);
      addTearDown(() => tester.runAsync(shutdown));
      repo.apps = const <CloudAppUsage>[];
      repo.timeline = const <CloudTimelineEntry>[];
      repo.totalSeconds = 0;

      await pumpPage(tester);

      // 空态文案必须带上"哪台设备"，否则用户无法区分"这台设备没数据"
      // 与"选错了设备"（真机排查踩过这个坑）。
      expect(find.textContaining('在这一天还没有云端使用记录'), findsOneWidget);
      expect(
        find.textContaining('请确认选中的是真正在用的那台设备'),
        findsOneWidget,
      );
    });

    testWidgets('无网络且无缓存 → 错误卡 + 重试按钮', (WidgetTester tester) async {
      await tester.runAsync(boot);
      addTearDown(() => tester.runAsync(shutdown));
      repo.failure = const CloudStatisticsException(
        CloudStatisticsErrorKind.network,
        '网络不可用，暂时无法刷新云端统计',
      );

      await pumpPage(tester);

      expect(find.text('网络不可用，暂时无法刷新云端统计'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
    });

    testWidgets('登录失效显示中文提示与去登录入口（不显示堆栈）', (WidgetTester tester) async {
      await tester.runAsync(boot);
      addTearDown(() => tester.runAsync(shutdown));
      repo.failure = const CloudStatisticsException(
        CloudStatisticsErrorKind.auth,
        '登录已失效，请重新登录后再查看云端统计',
      );

      await pumpPage(tester, onOpenAccount: () {});

      expect(find.text('登录已失效，请重新登录后再查看云端统计'), findsOneWidget);
      expect(find.text('去登录'), findsOneWidget);
      expect(find.textContaining('Exception'), findsNothing, reason: '不得把异常原文显示给用户');
    });

    testWidgets('离线缓存：显示缓存内容并标记"当前显示离线缓存"', (WidgetTester tester) async {
      await tester.runAsync(boot);
      addTearDown(() => tester.runAsync(shutdown));

      // 先成功一次写入缓存
      await tester.runAsync(() => controller.initialize());
      expect(controller.summary, isNotNull);

      // 断网后用新控制器打开页面：应展示缓存 + 离线标记
      repo.failure = const CloudStatisticsException(
        CloudStatisticsErrorKind.network,
        '网络不可用，暂时无法刷新云端统计',
      );
      controller.dispose();
      controller = CloudStatisticsController(
        repository: repo,
        cache: cache,
        currentAccountUserId: () => account,
        clock: () => today,
      );

      await pumpPage(tester);

      expect(find.text('当前显示离线缓存'), findsOneWidget);
      expect(find.textContaining('上次刷新：'), findsOneWidget);
      expect(find.text('Microsoft Edge'), findsWidgets, reason: '离线仍要显示缓存中的应用');
    });

    testWidgets('刷新中保留旧数据，不回到首屏加载态', (WidgetTester tester) async {
      await tester.runAsync(boot);
      addTearDown(() => tester.runAsync(shutdown));

      await pumpPage(tester);
      expect(find.textContaining('今日累计'), findsOneWidget);

      // 挂起下一次刷新，让它一直处于"刷新中"。
      repo.hold = Completer<void>();
      await tester.tap(find.byTooltip('刷新云端统计'));
      await settle(tester);

      expect(find.text('正在加载云端统计…'), findsNothing, reason: '有数据时不得回到首屏加载态');
      expect(find.textContaining('今日累计'), findsOneWidget, reason: '旧数据必须保留');
      expect(find.text('Microsoft Edge'), findsWidgets, reason: '旧列表必须保留');

      repo.hold!.complete();
      await settle(tester);

      expect(repo.summaryCalls, 2);
      expect(find.textContaining('今日累计'), findsOneWidget);
      expect(find.text('正在加载云端统计…'), findsNothing);
    });

    testWidgets('旧响应不会覆盖新选择（切换设备后到达的旧结果被丢弃）',
        (WidgetTester tester) async {
      await tester.runAsync(boot);
      addTearDown(() => tester.runAsync(shutdown));

      await pumpPage(tester);
      expect(controller.deviceId, isNull);

      // 「全部设备」的刷新被挂在网络上。
      final Completer<void> slowAll = Completer<void>();
      repo.hold = slowAll;
      await tester.tap(find.byTooltip('刷新云端统计'));
      await settle(tester);

      // 旧请求还没回来就切到 dev-pc：新查询立即返回。
      repo.hold = null;
      await tester.runAsync(() => controller.setDevice('dev-pc'));
      await settle(tester);
      expect(controller.summary?.deviceId, 'dev-pc');

      // 旧响应此刻才到达，必须被代次守卫丢弃。
      slowAll.complete();
      await settle(tester);

      expect(controller.deviceId, 'dev-pc');
      expect(controller.summary?.deviceId, 'dev-pc', reason: '旧响应覆盖了新设备的数据');
    });
  });

  group('布局与回归', () {
    testWidgets('窄屏 / 横屏 / 字体放大 / 长名称 / 50 条时间线都不溢出', (WidgetTester tester) async {
      await tester.runAsync(boot);
      addTearDown(() => tester.runAsync(shutdown));

      const String longApp = '这是一个非常非常长的应用名称用来验证省略号与布局不会溢出溢出溢出';
      const String longDevice = '这是一台名字特别长的电脑设备名称用于验证布局不会溢出溢出';
      repo.devices = <CloudDevice>[
        const CloudDevice(id: 'dev-pc', name: longDevice, platform: 'windows'),
      ];
      repo.apps = <CloudAppUsage>[
        const CloudAppUsage(
          appId: 'long',
          appName: longApp,
          duration: Duration(minutes: 85),
          sessionCount: 2,
        ),
      ];
      repo.timeline = <CloudTimelineEntry>[
        for (int i = 0; i < 50; i++)
          CloudTimelineEntry(
            appId: 'app$i',
            appName: '$longApp $i',
            deviceId: 'dev-pc',
            deviceName: longDevice,
            platform: 'windows',
            startedAt: DateTime.utc(2026, 9, 29, 1).add(Duration(minutes: i * 5)),
            endedAt: DateTime.utc(2026, 9, 29, 1).add(Duration(minutes: i * 5 + 3)),
            duration: const Duration(minutes: 3),
          ),
      ];
      repo.sessions = <CloudUsageSession>[
        CloudUsageSession(
          id: 's1',
          localRecordId: 's1',
          deviceId: 'dev-pc',
          deviceName: longDevice,
          platform: 'windows',
          appId: 'long',
          appName: longApp,
          startedAt: DateTime.utc(2026, 9, 29, 1, 12),
          endedAt: DateTime.utc(2026, 9, 29, 1, 35),
          duration: const Duration(minutes: 23),
        ),
      ];

      final List<({Size size, double scale})> cases = <({Size size, double scale})>[
        (size: const Size(360, 640), scale: 1.0),
        (size: const Size(393, 851), scale: 1.0),
        (size: const Size(412, 915), scale: 1.0),
        (size: const Size(780, 360), scale: 1.0), // 横屏
        (size: const Size(360, 640), scale: 1.3),
        (size: const Size(360, 640), scale: 1.5),
        (size: const Size(320, 568), scale: 1.0),
      ];

      for (final ({Size size, double scale}) testCase in cases) {
        controller.reset();
        // 每轮换一个 key：强制重建页面 State，等价于"重新打开云端页"。
        await pumpPage(
          tester,
          size: testCase.size,
          textScale: testCase.scale,
          key: ValueKey<String>(
            '${testCase.size.width}x${testCase.size.height}@${testCase.scale}',
          ),
        );
        expect(tester.takeException(), isNull,
            reason: '${testCase.size} @${testCase.scale}x 出现了布局异常');

        // 展开应用（含长名称）也不能溢出。
        // 横屏等矮视口下应用行可能在折叠区外，先滚动到可见再点，确保真的展开了。
        final Finder appTile = find.text(longApp).first;
        await tester.ensureVisible(appTile);
        await tester.pump();
        await tester.tap(appTile);
        await settle(tester);
        expect(tester.takeException(), isNull,
            reason: '展开应用后 ${testCase.size} @${testCase.scale}x 溢出');

        // 时间线（50 条）
        final Finder timelineTab = find.text('时间线');
        await tester.ensureVisible(timelineTab);
        await tester.pump();
        await tester.tap(timelineTab);
        await settle(tester);
        expect(tester.takeException(), isNull,
            reason: '时间线 ${testCase.size} @${testCase.scale}x 溢出');
      }
    });
  });

  // ---------------------------------------------------------------------------
  // 跨端一致性补充修复（4C-5.1B）
  // ---------------------------------------------------------------------------

  group('跨端一致性补充修复', () {
    testWidgets('设备下拉能区分同名设备（本机 / 已撤销 / 型号 / 最近活动）',
        (WidgetTester tester) async {
      await tester.runAsync(boot);
      addTearDown(() => tester.runAsync(shutdown));
      // 真机场景：同一台手机重装后留下两条同名同平台的设备记录，
      // 只有真正在用的那条有数据 —— 下拉必须能区分它们。
      repo.devices = <CloudDevice>[
        CloudDevice(
          id: 'dev-phone-current',
          name: 'PLF110',
          platform: 'android',
          modelName: 'PLF110',
          lastSeenAt: DateTime.utc(2026, 9, 29, 12, 1),
          isCurrent: true,
        ),
        CloudDevice(
          id: 'dev-phone-old',
          name: '手机',
          platform: 'android',
          modelName: 'PLF110',
          lastSeenAt: DateTime.utc(2026, 9, 29, 8, 59),
          revoked: true,
        ),
      ];

      await pumpPage(tester);
      await tester.tap(find.byType(DropdownButton<String?>));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.textContaining('本机'), findsWidgets,
          reason: '必须标出哪一台是当前设备');
      expect(find.textContaining('已撤销'), findsWidgets,
          reason: '历史设备必须标注已撤销');
      expect(find.textContaining('手机 · Android · PLF110'), findsWidgets,
          reason: '名称里没有型号时要补上型号，便于辨认同名设备');
    });

    testWidgets('退出登录再重新登录（复用同一个 State）会自动重新初始化',
        (WidgetTester tester) async {
      await tester.runAsync(boot);
      addTearDown(() => tester.runAsync(shutdown));

      // 1) 登录态打开：正常加载
      await pumpPage(tester);
      expect(find.text('Microsoft Edge'), findsWidgets);

      // 2) 退出登录
      await tester.pumpWidget(page(signedIn: false));
      await settle(tester);
      expect(find.text('登录后即可查看其他设备的云端使用统计'), findsOneWidget);

      // 3) 重新登录：State 被复用（key 不变），必须自己重新发起请求，
      //    而不是永远停在空态（这是真机"退出重登后看不到数据"的根因）。
      final int before = repo.summaryCalls;
      await tester.pumpWidget(page(signedIn: true));
      await settle(tester);
      await settle(tester);

      expect(repo.summaryCalls, greaterThan(before),
          reason: '重新登录后必须重新发起云端统计请求');
      expect(find.text('Microsoft Edge'), findsWidgets);
    });
  });
}

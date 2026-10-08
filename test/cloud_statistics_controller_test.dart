import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:petlife/core/logger.dart';
import 'package:petlife/core/paths.dart';
import 'package:petlife/database/app_database.dart';
import 'package:petlife/database/dao/cloud_statistics_cache_dao.dart';
import 'package:petlife/sync/cloud_statistics_cache.dart';
import 'package:petlife/sync/cloud_statistics_controller.dart';
import 'package:petlife/sync/cloud_statistics_repository.dart';
import 'package:petlife/sync/models/cloud_statistics_models.dart';

import 'support/sqlite_test_bootstrap.dart';

/// 可编程的假仓库：记录调用、可以挂起（用于测并发与串页）、可以抛错。
class _FakeRepository implements CloudStatisticsRepository {
  final List<String> calls = <String>[];

  /// 挂起中的请求：key = 'summary|2026-09-29|all' 等。
  ///
  /// 值是一个**队列**：同一个键可能同时有多个在途请求（例如"强制刷新"刻意
  /// 绕过去重再发一次），用队列才能分别放行，也才能验证"旧的那个被丢弃"。
  final Map<String, List<Completer<Object?>>> pending =
      <String, List<Completer<Object?>>>{};

  bool failWithNetwork = false;

  /// 只让**设备列表**接口失败（统计接口正常），用于验证降级行为。
  bool failDevicesOnly = false;

  bool timelineEmpty = false;
  CloudStatisticsSummaryBuilder? summaryBuilder;

  List<CloudDevice> devices = <CloudDevice>[
    const CloudDevice(id: 'dev-pc', name: '我的电脑', platform: 'windows'),
    const CloudDevice(id: 'dev-phone', name: '我的手机', platform: 'android'),
  ];

  void _record(String call) => calls.add(call);

  int countOf(String prefix) =>
      calls.where((String c) => c.startsWith(prefix)).length;

  Future<T> _gate<T>(String key, T Function() build) {
    if (failWithNetwork) {
      return Future<T>.error(const CloudStatisticsException(
        CloudStatisticsErrorKind.network,
        '网络不可用，暂时无法刷新云端统计',
      ));
    }
    final Completer<Object?> completer = Completer<Object?>();
    pending.putIfAbsent(key, () => <Completer<Object?>>[]).add(completer);
    return completer.future.then((Object? _) => build());
  }

  /// 放行该键**最早**的一个在途请求。
  void resolve(String key) {
    final List<Completer<Object?>>? queue = pending[key];
    if (queue == null || queue.isEmpty) return;
    final Completer<Object?> completer = queue.removeAt(0);
    if (queue.isEmpty) pending.remove(key);
    completer.complete(null);
  }

  /// 放行该键**全部**在途请求（同一查询有多个并发请求时用）。
  void resolveAll(String key) {
    final List<Completer<Object?>>? queue = pending.remove(key);
    for (final Completer<Object?> completer
        in queue ?? const <Completer<Object?>>[]) {
      completer.complete(null);
    }
  }

  @override
  Future<List<CloudDevice>> listDevices() async {
    _record('devices');
    if (failWithNetwork || failDevicesOnly) {
      throw const CloudStatisticsException(
        CloudStatisticsErrorKind.network,
        '网络不可用',
      );
    }
    return devices;
  }

  @override
  Future<CloudUsageSummary> getSummary(CloudUsageQuery query) {
    _record('summary|${query.dateKey}|${query.deviceKey}');
    return _gate<CloudUsageSummary>(
      'summary|${query.dateKey}|${query.deviceKey}',
      () => (summaryBuilder ?? _defaultSummary)(query),
    );
  }

  @override
  Future<List<CloudAppUsage>> getApps(CloudUsageQuery query) {
    _record('apps|${query.dateKey}');
    return _gate<List<CloudAppUsage>>(
      'apps|${query.dateKey}',
      () => <CloudAppUsage>[
        const CloudAppUsage(
          appId: 'code',
          appName: 'Visual Studio Code',
          duration: Duration(minutes: 52),
          sessionCount: 1,
        ),
      ],
    );
  }

  @override
  Future<CloudSessionPage> getSessions(CloudUsageQuery query) {
    _record('sessions|${query.appId}|${query.cursor ?? ''}');
    return _gate<CloudSessionPage>(
      'sessions|${query.appId}|${query.cursor ?? ''}',
      () => CloudSessionPage(
        date: query.dateKey,
        timezone: query.timezone,
        nextCursor: query.cursor == null ? 'cursor-2' : null,
        items: <CloudUsageSession>[
          CloudUsageSession(
            id: 's-${query.cursor ?? '1'}',
            localRecordId: 's-${query.cursor ?? '1'}',
            deviceId: 'dev-pc',
            deviceName: '我的电脑',
            platform: 'windows',
            appId: query.appId ?? 'code',
            appName: 'Visual Studio Code',
            startedAt: DateTime.utc(2026, 9, 29, 1, 48),
            endedAt: DateTime.utc(2026, 9, 29, 2, 20),
            duration: const Duration(minutes: 32),
          ),
        ],
      ),
    );
  }

  @override
  Future<List<CloudTimelineEntry>> getTimeline(CloudUsageQuery query) {
    _record('timeline|${query.dateKey}|${query.deviceKey}');
    return _gate<List<CloudTimelineEntry>>(
      'timeline|${query.dateKey}|${query.deviceKey}',
      () => timelineEmpty
          ? const <CloudTimelineEntry>[]
          : <CloudTimelineEntry>[
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
            ],
    );
  }
}

/// 按日期返回不同总时长，用于验证"旧响应不覆盖新结果"。
typedef CloudStatisticsSummaryBuilder = CloudUsageSummary Function(
    CloudUsageQuery query);

CloudUsageSummary _defaultSummary(CloudUsageQuery query) {
  final int minutes = query.dateKey == '2026-09-29' ? 85 : 7;
  return CloudUsageSummary(
    date: query.dateKey,
    timezone: query.timezone,
    deviceId: query.deviceId,
    totalDuration: Duration(minutes: minutes),
    lastSyncedAt: DateTime.utc(2026, 9, 29, 9, 20),
    apps: <CloudAppUsage>[
      CloudAppUsage(
        appId: 'msedge',
        appName: 'Microsoft Edge',
        duration: Duration(minutes: minutes),
        sessionCount: 1,
      ),
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SqliteTestBootstrap.ensureLoaded();

  late Directory dir;
  late AppDatabase db;
  late CloudStatisticsCache cache;
  late _FakeRepository repository;
  late String? account;
  late DateTime now;

  CloudStatisticsController build() => CloudStatisticsController(
        repository: repository,
        cache: cache,
        currentAccountUserId: () => account,
        clock: () => now,
      );

  /// 轮询等待某个条件成立（sqflite 是真实异步 I/O，不能只靠 yield 微任务队列）。
  Future<void> waitUntil(bool Function() condition, {String? reason}) async {
    for (int i = 0; i < 600; i++) {
      if (condition()) return;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    fail('等待条件超时${reason == null ? '' : '：$reason'}');
  }

  /// 等到某个请求真的发出（在假仓库里挂起）为止。
  Future<void> waitForGate(String key) =>
      waitUntil(() => repository.pending.containsKey(key), reason: '请求未发出 $key');

  /// 放行某一天、某台设备的 summary + timeline（先等它们发出）。
  ///
  /// [deviceKey] 默认 `all`（未选具体设备）；切换设备后必须显式传入设备 id，
  /// 否则会去等一个永远不会出现的键。
  Future<void> releaseDay(String day, [String deviceKey = 'all']) async {
    await waitForGate('summary|$day|$deviceKey');
    await waitForGate('timeline|$day|$deviceKey');
    repository.resolve('summary|$day|$deviceKey');
    repository.resolve('timeline|$day|$deviceKey');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('petlife_cloud_ctl');
    AppPaths.resetForTest();
    await AppPaths.initialize(overrideRoot: dir);
    await AppLog.initialize(logFile: AppPaths.instance.logFile);
    db = await AppDatabase.open(path: AppPaths.instance.databaseFile.path);
    cache = CloudStatisticsCache(CloudStatisticsCacheDao(db.raw));
    repository = _FakeRepository();
    account = 'user-a';
    now = DateTime(2026, 9, 29, 10, 0);
  });

  tearDown(() async {
    if (AppDatabase.isOpen) await AppDatabase.close();
    await AppLog.dispose();
    AppPaths.resetForTest();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  group('首次加载与缓存优先', () {
    test('没有缓存时先 loading，成功后 loaded 并写入缓存', () async {
      final CloudStatisticsController controller = build();
      addTearDown(controller.dispose);

      final Future<void> init = controller.initialize();
      await waitUntil(() => controller.status == CloudStatsStatus.loading,
          reason: '无缓存时应进入 loading');
      expect(controller.isOfflineData, isFalse);

      await releaseDay('2026-09-29');
      await init;

      expect(controller.status, CloudStatsStatus.loaded);
      expect(controller.summary!.totalDuration, const Duration(minutes: 85));
      expect(controller.devices, hasLength(2));
      expect(controller.timeline, hasLength(1));
      expect(controller.lastRefreshedAt, now);

      // 缓存已写入：换一个控制器实例也能先读到缓存
      final CloudStatisticsController second = build();
      addTearDown(second.dispose);
      final Future<void> init2 = second.initialize();
      await waitUntil(() => second.summary != null, reason: '应先把缓存渲染出来');
      // 先展示缓存（offlineCache），紧接着进入后台刷新（refreshing）——
      // 两者都说明"界面已经有内容了"，关键是 isOfflineData 必须为 true。
      expect(
        second.status,
        anyOf(CloudStatsStatus.offlineCache, CloudStatsStatus.refreshing),
        reason: '有缓存时应先渲染缓存，再在后台刷新',
      );
      expect(second.isOfflineData, isTrue, reason: '来自缓存的数据必须标记为离线数据');
      expect(second.summary!.totalDuration, const Duration(minutes: 85));

      await releaseDay('2026-09-29');
      await init2;
      expect(second.status, CloudStatsStatus.loaded);
      expect(second.isOfflineData, isFalse);
    });

    test('未登录时给出明确提示，不发起请求', () async {
      account = null;
      final CloudStatisticsController controller = build();
      addTearDown(controller.dispose);

      await controller.initialize();
      expect(controller.status, CloudStatsStatus.error);
      expect(controller.errorMessage, contains('登录'));
      expect(repository.calls, isEmpty);
    });

    test('数据为空时状态是 empty', () async {
      repository.summaryBuilder = (CloudUsageQuery q) => CloudUsageSummary(
            date: q.dateKey,
            timezone: q.timezone,
            totalDuration: Duration.zero,
          );
      repository.timelineEmpty = true;
      final CloudStatisticsController controller = build();
      addTearDown(controller.dispose);

      final Future<void> init = controller.initialize();
      await waitUntil(() => controller.status == CloudStatsStatus.loading);
      await releaseDay('2026-09-29');
      await init;

      expect(controller.timeline, isEmpty);
      expect(controller.status, CloudStatsStatus.empty);
    });
  });

  group('离线缓存', () {
    test('无网络且无缓存 → error；错误文案可读', () async {
      repository.failWithNetwork = true;
      final CloudStatisticsController controller = build();
      addTearDown(controller.dispose);

      await controller.initialize();
      expect(controller.status, CloudStatsStatus.error);
      expect(controller.errorMessage, contains('网络'));
    });

    test('网络失败但已有缓存 → offlineCache，保留旧数据并标记离线', () async {
      final CloudStatisticsController warmer = build();
      addTearDown(warmer.dispose);
      final Future<void> warm = warmer.initialize();
      await waitUntil(() => warmer.status == CloudStatsStatus.loading);
      await releaseDay('2026-09-29');
      await warm;

      repository.failWithNetwork = true;
      final CloudStatisticsController controller = build();
      addTearDown(controller.dispose);
      await controller.initialize();

      expect(controller.status, CloudStatsStatus.offlineCache);
      expect(controller.isOfflineData, isTrue);
      expect(controller.summary!.totalDuration, const Duration(minutes: 85),
          reason: '离线时必须保留缓存内容');
      expect(controller.errorMessage, contains('网络'));
    });

    test('网络恢复后刷新成功，离线标记被清除', () async {
      final CloudStatisticsController controller = build();
      addTearDown(controller.dispose);
      final Future<void> init = controller.initialize();
      await waitUntil(() => controller.status == CloudStatsStatus.loading);
      await releaseDay('2026-09-29');
      await init;

      repository.failWithNetwork = true;
      await controller.refresh(manual: true);
      expect(controller.isOfflineData, isTrue);

      repository.failWithNetwork = false;
      final Future<void> recovered = controller.onNetworkRestored();
      await releaseDay('2026-09-29');
      await recovered;

      expect(controller.isOfflineData, isFalse);
      expect(controller.status, CloudStatsStatus.loaded);
    });
  });

  group('请求去重与串页防护', () {
    test('相同查询的并发刷新只发一次请求', () async {
      final CloudStatisticsController controller = build();
      addTearDown(controller.dispose);

      final Future<void> first = controller.refresh();
      final Future<void> second = controller.refresh();
      final Future<void> third = controller.refresh();
      await releaseDay('2026-09-29');

      expect(repository.countOf('summary|'), 1,
          reason: '同一查询键只能有一个在途请求');
      expect(repository.countOf('devices'), 1, reason: '设备列表只拉一次');

      await Future.wait<void>(<Future<void>>[first, second, third]);
    });

    test('切换日期后，旧日期的响应不会覆盖新查询结果', () async {
      final CloudStatisticsController controller = build();
      addTearDown(controller.dispose);

      // 9-29 的请求先发出去并挂起
      final Future<void> oldRequest = controller.refresh();
      await waitForGate('summary|2026-09-29|all');
      expect(controller.date!.day, 29);

      // 切到 9-30：新查询立即发出
      final Future<void> switched = controller.setDate(DateTime(2026, 9, 30));
      await waitForGate('summary|2026-09-30|all');

      // 先放行 9-30，让界面处于新日期
      repository.resolve('summary|2026-09-30|all');
      repository.resolve('timeline|2026-09-30|all');
      await switched;
      expect(controller.summary!.date, '2026-09-30');
      expect(controller.summary!.totalDuration, const Duration(minutes: 7));

      // 再放行早已过期的 9-29
      repository.resolve('summary|2026-09-29|all');
      repository.resolve('timeline|2026-09-29|all');
      await oldRequest;

      expect(controller.summary!.date, '2026-09-30',
          reason: '过期响应必须被丢弃，不能把界面改回旧日期');
      expect(controller.summary!.totalDuration, const Duration(minutes: 7));
    });

    test('切换设备会重新查询并带上 device_id', () async {
      final CloudStatisticsController controller = build();
      addTearDown(controller.dispose);
      final Future<void> init = controller.initialize();
      await waitUntil(() => controller.status == CloudStatsStatus.loading);
      await releaseDay('2026-09-29');
      await init;
      expect(controller.deviceKey, 'all');

      final Future<void> change = controller.setDevice('dev-pc');
      await waitUntil(() => repository.calls.contains('summary|2026-09-29|dev-pc'),
          reason: '应带 device_id 重查');
      repository.resolve('summary|2026-09-29|dev-pc');
      repository.resolve('timeline|2026-09-29|dev-pc');
      await change;

      expect(controller.deviceKey, 'dev-pc');
      expect(controller.selectedDevice!.displayLabel, '我的电脑 · Windows');
    });

    test('上一天 / 下一天 / 回到今天', () async {
      final CloudStatisticsController controller = build();
      addTearDown(controller.dispose);
      final Future<void> init = controller.initialize();
      await waitUntil(() => controller.status == CloudStatsStatus.loading);
      await releaseDay('2026-09-29');
      await init;

      final Future<void> prev = controller.shiftDay(-1);
      await releaseDay('2026-09-28');
      await prev;
      expect(controller.date!.day, 28);

      final Future<void> next = controller.shiftDay(1);
      await releaseDay('2026-09-29');
      await next;
      expect(controller.date!.day, 29);

      final Future<void> tomorrow = controller.shiftDay(1);
      await releaseDay('2026-09-30');
      await tomorrow;
      expect(controller.date!.day, 30);

      final Future<void> today = controller.goToToday();
      await releaseDay('2026-09-29');
      await today;
      expect(controller.date!.day, 29);
    });
  });

  // ---------------------------------------------------------------------------
  // 跨端一致性补充修复（4C-5.1B）
  // ---------------------------------------------------------------------------

  group('切换设备不得显示上一个设备的数据', () {
    test('切设备的瞬间就清掉旧设备的数据（不出现"新设备名 + 旧数字"）', () async {
      final CloudStatisticsController controller = build();
      addTearDown(controller.dispose);

      final Future<void> init = controller.initialize();
      await waitUntil(() => controller.status == CloudStatsStatus.loading);
      // 先让"全部设备"有数据
      await releaseDay('2026-09-29');
      await init;
      expect(controller.hasData, isTrue);

      // 切到 dev-pc：新请求还没回来之前，旧数据必须已经消失
      final Future<void> change = controller.setDevice('dev-pc');
      expect(controller.hasData, isFalse,
          reason: '切设备后旧设备的汇总/时间线必须立刻清空');
      expect(controller.status, CloudStatsStatus.loading);

      await releaseDay('2026-09-29', 'dev-pc');
      await change;
      expect(controller.hasData, isTrue);
      expect(controller.deviceKey, 'dev-pc');
    });

    test('切回之前查过的设备会重新发请求，而不是复用旧的在途任务', () async {
      final CloudStatisticsController controller = build();
      addTearDown(controller.dispose);

      // all 的请求挂着不返回
      final Future<void> first = controller.refresh();
      await waitForGate('summary|2026-09-29|all');

      // 切到 dev-pc 并让它成功
      final Future<void> toDevice = controller.setDevice('dev-pc');
      await releaseDay('2026-09-29', 'dev-pc');
      await toDevice;

      // 切回 all：必须**重新发起**请求（旧的在途任务属于上一个代次，复用它会让界面永远停在旧数据）
      final Future<void> back = controller.setDevice(null);
      await waitUntil(
        () => repository.countOf('summary|2026-09-29|all') >= 2,
        reason: '切回旧设备必须重新请求，不能复用上一个代次的在途任务',
      );
      expect(controller.deviceKey, 'all');

      // 收尾：放行全部在途请求，确认过期响应不会污染结果。
      repository.resolveAll('summary|2026-09-29|all');
      repository.resolveAll('timeline|2026-09-29|all');
      await back;
      await first;
      expect(controller.deviceKey, 'all');
    });
  });

  group('强制刷新', () {
    test('manual=true 会重新拉设备列表，并在有在途请求时仍发起新请求', () async {
      final CloudStatisticsController controller = build();
      addTearDown(controller.dispose);

      final Future<void> first = controller.refresh();
      await waitForGate('summary|2026-09-29|all');
      final int devicesBefore = repository.countOf('devices');

      // 在途时再点一次「刷新」（manual）——必须真的再发一次，而不是被去重吞掉
      final Future<void> manual = controller.refresh(manual: true);
      await waitUntil(
        () => repository.countOf('summary|2026-09-29|all') >= 2,
        reason: '强制刷新必须真的再请求一次',
      );
      await waitUntil(
        () => repository.countOf('devices') > devicesBefore,
        reason: '强制刷新必须重新拉设备列表',
      );

      repository.resolveAll('summary|2026-09-29|all');
      repository.resolveAll('timeline|2026-09-29|all');
      await manual;
      await first;
      expect(controller.hasData, isTrue);
    });

    test('普通并发刷新仍然只发一次请求（去重没有被破坏）', () async {
      final CloudStatisticsController controller = build();
      addTearDown(controller.dispose);

      final Future<void> a = controller.refresh();
      final Future<void> b = controller.refresh();
      await releaseDay('2026-09-29');
      expect(repository.countOf('summary|2026-09-29|all'), 1);
      await Future.wait<void>(<Future<void>>[a, b]);
    });
  });

  group('设备列表刷新与降级', () {
    test('每次刷新都会重新拉设备列表（新注册的设备不需要重启就能看到）', () async {
      final CloudStatisticsController controller = build();
      addTearDown(controller.dispose);

      final Future<void> init = controller.initialize();
      await releaseDay('2026-09-29');
      await init;
      expect(repository.countOf('devices'), 1);

      repository.devices = <CloudDevice>[
        ...repository.devices,
        const CloudDevice(id: 'dev-phone2', name: 'PLF110', platform: 'android'),
      ];
      final Future<void> second = controller.refresh();
      await releaseDay('2026-09-29');
      await second;

      expect(repository.countOf('devices'), 2);
      expect(controller.devices, hasLength(3),
          reason: '新注册的设备必须在列表里立刻可见');
    });

    test('设备列表拉取失败不影响统计主体（沿用上一次列表）', () async {
      final CloudStatisticsController controller = build();
      addTearDown(controller.dispose);

      final Future<void> init = controller.initialize();
      await releaseDay('2026-09-29');
      await init;
      expect(controller.devices, hasLength(2));
      expect(controller.hasData, isTrue);

      // 让设备列表接口失败：统计仍必须能刷新成功
      repository.failDevicesOnly = true;
      final Future<void> second = controller.refresh();
      await releaseDay('2026-09-29');
      await second;

      expect(controller.hasData, isTrue, reason: '设备列表失败不得拖垮统计');
      expect(controller.status, CloudStatsStatus.loaded);
      expect(controller.devices, hasLength(2), reason: '沿用上一次的设备列表');
    });
  });

  group('账户隔离', () {
    test('换账户会清空上一个账户的数据（新账户不会看到旧账户的记录）', () async {
      final CloudStatisticsController controller = build();
      addTearDown(controller.dispose);

      final Future<void> init = controller.initialize();
      await releaseDay('2026-09-29');
      await init;
      expect(controller.hasData, isTrue);

      // 换号
      account = 'user-b';
      final Future<void> second = controller.initialize();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(controller.hasData, isFalse,
          reason: '换账户后必须立刻清空上一个账户的数据');
      await releaseDay('2026-09-29');
      await second;
    });
  });

  group('展开应用的时间段与分页', () {
    test('展开应用加载第一页，再滚动加载第二页', () async {
      final CloudStatisticsController controller = build();
      addTearDown(controller.dispose);
      final Future<void> init = controller.initialize();
      await waitUntil(() => controller.status == CloudStatsStatus.loading);
      await releaseDay('2026-09-29');
      await init;

      final Future<void> expand = controller.expandApp('code');
      await waitUntil(() => controller.isLoadingSessions('code'),
          reason: '应进入加载态');
      await waitForGate('sessions|code|');
      repository.resolve('sessions|code|');
      await expand;

      expect(controller.sessionsOf('code'), hasLength(1));
      expect(controller.hasMoreSessions('code'), isTrue);

      final Future<void> more = controller.loadMoreSessions('code');
      await waitForGate('sessions|code|cursor-2');
      repository.resolve('sessions|code|cursor-2');
      await more;

      expect(controller.sessionsOf('code'), hasLength(2));
      expect(controller.hasMoreSessions('code'), isFalse);
    });

    test('展开失败时记录可读错误，不抛异常', () async {
      final CloudStatisticsController controller = build();
      addTearDown(controller.dispose);
      final Future<void> init = controller.initialize();
      await waitUntil(() => controller.status == CloudStatsStatus.loading);
      await releaseDay('2026-09-29');
      await init;

      repository.failWithNetwork = true;
      await controller.expandApp('code');
      expect(controller.errorMessage, contains('网络'));
      expect(controller.sessionsOf('code'), isEmpty);
    });

    test('切换日期会清掉已展开的时间段', () async {
      final CloudStatisticsController controller = build();
      addTearDown(controller.dispose);
      final Future<void> init = controller.initialize();
      await waitUntil(() => controller.status == CloudStatsStatus.loading);
      await releaseDay('2026-09-29');
      await init;

      final Future<void> expand = controller.expandApp('code');
      await waitForGate('sessions|code|');
      repository.resolve('sessions|code|');
      await expand;
      expect(controller.sessionsOf('code'), isNotEmpty);

      final Future<void> switched = controller.setDate(DateTime(2026, 9, 28));
      await releaseDay('2026-09-28');
      await switched;

      expect(controller.sessionsOf('code'), isEmpty,
          reason: '换日期后旧的展开结果必须丢弃');
    });
  });

  group('刷新时机与账户', () {
    test('回到前台：距上次刷新不足 2 分钟不刷新，超过则刷新', () async {
      final CloudStatisticsController controller = build();
      addTearDown(controller.dispose);
      final Future<void> init = controller.initialize();
      await waitUntil(() => controller.status == CloudStatsStatus.loading);
      await releaseDay('2026-09-29');
      await init;
      final int baseline = repository.countOf('summary|');

      now = now.add(const Duration(seconds: 30));
      await controller.onAppResumed();
      expect(repository.countOf('summary|'), baseline, reason: '30 秒内不该重复请求');

      now = now.add(const Duration(minutes: 3));
      final Future<void> resumed = controller.onAppResumed();
      await releaseDay('2026-09-29');
      await resumed;
      expect(repository.countOf('summary|'), baseline + 1);
    });

    test('本机同步成功后自动刷新', () async {
      final CloudStatisticsController controller = build();
      addTearDown(controller.dispose);
      final Future<void> init = controller.initialize();
      await waitUntil(() => controller.status == CloudStatsStatus.loading);
      await releaseDay('2026-09-29');
      await init;
      final int baseline = repository.countOf('summary|');

      final Future<void> synced = controller.onLocalSyncSucceeded();
      await releaseDay('2026-09-29');
      await synced;
      expect(repository.countOf('summary|'), baseline + 1);
    });

    test('退出账户清掉该账户缓存，且不触碰本机数据', () async {
      final CloudStatisticsController controller = build();
      addTearDown(controller.dispose);
      final Future<void> init = controller.initialize();
      await waitUntil(() => controller.status == CloudStatsStatus.loading);
      await releaseDay('2026-09-29');
      await init;
      expect(await cache.countForAccount('user-a'), greaterThan(0));

      await controller.onSignedOut();

      expect(await cache.countForAccount('user-a'), 0);
      expect(controller.status, CloudStatsStatus.idle);
      expect(controller.summary, isNull);
    });

    test('切换账户不会看到上一个账户的缓存', () async {
      final CloudStatisticsController first = build();
      addTearDown(first.dispose);
      final Future<void> init = first.initialize();
      await waitUntil(() => first.status == CloudStatsStatus.loading);
      await releaseDay('2026-09-29');
      await init;

      // 换成另一个账户且断网：必须没有缓存可展示
      account = 'user-b';
      repository.failWithNetwork = true;
      final CloudStatisticsController second = build();
      addTearDown(second.dispose);
      await second.initialize();

      expect(second.summary, isNull, reason: '不同账户的云端缓存必须隔离');
      expect(second.status, CloudStatsStatus.error);
    });
  });
}

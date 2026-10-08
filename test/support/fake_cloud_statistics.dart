import 'dart:async';

import 'package:petlife/sync/cloud_statistics_repository.dart';
import 'package:petlife/sync/models/cloud_statistics_models.dart';

/// 云端统计仓库的假实现（测试用）。
///
/// 支持三种行为，够覆盖控件测试需要的全部场景：
/// * 正常返回可配置的数据；
/// * 立即失败（[failure]）；
/// * 挂起（[hold]），用于验证"刷新中保留旧数据""旧响应不覆盖新查询"。
class FakeCloudStatisticsRepository implements CloudStatisticsRepository {
  FakeCloudStatisticsRepository({
    List<CloudDevice>? devices,
    List<CloudAppUsage>? apps,
    List<CloudTimelineEntry>? timeline,
    List<CloudUsageSession>? sessions,
    this.deviceName = '我的电脑',
  })  : devices = devices ??
            <CloudDevice>[
              const CloudDevice(id: 'dev-pc', name: '我的电脑', platform: 'windows'),
              const CloudDevice(id: 'dev-phone', name: '我的手机', platform: 'android'),
            ],
        apps = apps ??
            <CloudAppUsage>[
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
            ],
        timeline = timeline ??
            <CloudTimelineEntry>[
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
            ],
        sessions = sessions ??
            <CloudUsageSession>[
              CloudUsageSession(
                id: 's1',
                localRecordId: 's1',
                deviceId: 'dev-pc',
                deviceName: '我的电脑',
                platform: 'windows',
                appId: 'msedge',
                appName: 'Microsoft Edge',
                startedAt: DateTime.utc(2026, 9, 29, 1, 12),
                endedAt: DateTime.utc(2026, 9, 29, 1, 35),
                duration: const Duration(minutes: 23),
              ),
            ];

  List<CloudDevice> devices;
  List<CloudAppUsage> apps;
  List<CloudTimelineEntry> timeline;
  List<CloudUsageSession> sessions;

  /// 汇总里的总时长（秒）。null 表示按 apps 求和。
  int? totalSeconds;
  int? sessionCount;
  DateTime? lastSyncedAt;

  /// 非空时每次调用都抛这个错误。
  CloudStatisticsException? failure;

  /// 非空时调用会等待它完成（用于测试并发/串页/刷新中状态）。
  Completer<void>? hold;

  /// 会话分页：返回的 next_cursor（null = 没有更多）。
  String? nextCursor;

  final List<String> calls = <String>[];
  final String deviceName;

  int get summaryCalls => calls.where((String c) => c.startsWith('summary')).length;
  int get devicesCalls => calls.where((String c) => c == 'devices').length;
  int get timelineCalls => calls.where((String c) => c.startsWith('timeline')).length;
  int get sessionCalls => calls.where((String c) => c.startsWith('sessions')).length;

  Future<void> _wait() async {
    final Completer<void>? gate = hold;
    if (gate != null) await gate.future;
  }

  void _maybeFail() {
    final CloudStatisticsException? error = failure;
    if (error != null) throw error;
  }

  @override
  Future<List<CloudDevice>> listDevices() async {
    calls.add('devices');
    await _wait();
    _maybeFail();
    return devices;
  }

  @override
  Future<CloudUsageSummary> getSummary(CloudUsageQuery query) async {
    calls.add('summary|${query.dateKey}|${query.deviceKey}');
    await _wait();
    _maybeFail();
    final int total = totalSeconds ??
        apps.fold<int>(0, (int sum, CloudAppUsage a) => sum + a.duration.inSeconds);
    // 与真实解析路径一致：服务端契约是"按时长降序"，这里保持同样的不变式。
    final List<CloudAppUsage> sorted = <CloudAppUsage>[...apps]
      ..sort((CloudAppUsage a, CloudAppUsage b) => b.duration.compareTo(a.duration));
    return CloudUsageSummary(
      date: query.dateKey,
      timezone: query.timezone,
      deviceId: query.deviceId,
      totalDuration: Duration(seconds: total),
      sessionCount:
          sessionCount ?? apps.fold<int>(0, (int s, CloudAppUsage a) => s + a.sessionCount),
      appCount: apps.length,
      lastSyncedAt: lastSyncedAt,
      apps: sorted,
    );
  }

  @override
  Future<List<CloudAppUsage>> getApps(CloudUsageQuery query) async {
    calls.add('apps|${query.dateKey}');
    await _wait();
    _maybeFail();
    return apps;
  }

  @override
  Future<CloudSessionPage> getSessions(CloudUsageQuery query) async {
    calls.add('sessions|${query.appId}|${query.cursor ?? ''}');
    await _wait();
    _maybeFail();
    final bool firstPage = query.cursor == null;
    return CloudSessionPage(
      date: query.dateKey,
      timezone: query.timezone,
      nextCursor: firstPage ? 'cursor-2' : null,
      items: sessions,
    );
  }

  @override
  Future<List<CloudTimelineEntry>> getTimeline(CloudUsageQuery query) async {
    calls.add('timeline|${query.dateKey}');
    await _wait();
    _maybeFail();
    return timeline;
  }
}

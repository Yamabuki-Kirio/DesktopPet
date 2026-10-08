import 'package:flutter_test/flutter_test.dart';
import 'package:petlife/sync/models/cloud_statistics_models.dart';

/// Phase 4B：云端统计模型的严格解析与时间/时区处理。
void main() {
  group('设备列表解析', () {
    test('解析服务端 DeviceOut：名称 / 平台 / 型号 / 最近在线 / 是否本机', () {
      final CloudDevice device = CloudDevice.fromJson(<String, Object?>{
        'id': '11111111-1111-4111-8111-111111111111',
        'device_local_id': 'desktop.local',
        'device_name': '我的电脑',
        'platform': 'windows',
        'architecture': 'x64',
        'model_name': 'XPS 15',
        'last_seen_at': '2026-09-29T09:20:00Z',
        'revoked_at': null,
        'is_current': true,
      });

      expect(device.id, '11111111-1111-4111-8111-111111111111');
      expect(device.name, '我的电脑');
      expect(device.platform, 'windows');
      expect(device.modelName, 'XPS 15');
      expect(device.lastSeenAt, DateTime.utc(2026, 9, 29, 9, 20));
      expect(device.revoked, isFalse);
      expect(device.isCurrent, isTrue);
      expect(device.displayLabel, '我的电脑 · Windows');
    });

    test('Android 设备与撤销标记', () {
      final CloudDevice device = CloudDevice.fromJson(<String, Object?>{
        'id': 'd2',
        'device_name': '我的手机',
        'platform': 'android',
        'revoked_at': '2026-09-01T00:00:00Z',
      });
      expect(device.displayLabel, '我的手机 · Android');
      expect(device.revoked, isTrue);
    });

    test('未知字段被忽略（服务端新增字段不应让旧客户端崩掉）', () {
      final CloudDevice device = CloudDevice.fromJson(<String, Object?>{
        'id': 'd3',
        'device_name': '我的电脑',
        'platform': 'windows',
        'brand_new_field': 42,
        'another': <String, Object?>{'nested': true},
      });
      expect(device.platform, 'windows');
    });

    test('空设备 ID 被拒绝', () {
      expect(
        () => CloudDevice.fromJson(<String, Object?>{
          'id': '',
          'device_name': '我的电脑',
          'platform': 'windows',
        }),
        throwsA(isA<CloudDataException>()),
      );
    });

    test('缺少设备名 / 未知平台被拒绝', () {
      expect(
        () => CloudDevice.fromJson(<String, Object?>{'id': 'd', 'platform': 'windows'}),
        throwsA(isA<CloudDataException>()),
      );
      expect(
        () => CloudDevice.fromJson(<String, Object?>{
          'id': 'd',
          'device_name': 'x',
          'platform': 'solaris',
        }),
        throwsA(isA<CloudDataException>()),
      );
    });
  });

  group('汇总与应用排行解析', () {
    Map<String, Object?> summaryJson() => <String, Object?>{
          'date': '2026-09-29',
          'timezone': 'Asia/Shanghai',
          'device_id': 'dev-1',
          'total_duration_seconds': 5100,
          'session_count': 3,
          'last_synced_at': '2026-09-29T09:20:00Z',
          'apps': <Map<String, Object?>>[
            <String, Object?>{
              'app_id': 'code',
              'app_name': 'Visual Studio Code',
              'category': 'development',
              'duration_seconds': 3120,
              'session_count': 2,
            },
            <String, Object?>{
              'app_id': 'msedge',
              'app_name': 'Microsoft Edge',
              'category': 'browser',
              'duration_seconds': 5100,
              'session_count': 3,
            },
          ],
        };

    test('解析汇总，并把应用按时长降序排列', () {
      final CloudUsageSummary summary = CloudUsageSummary.fromJson(summaryJson());

      expect(summary.date, '2026-09-29');
      expect(summary.timezone, 'Asia/Shanghai');
      expect(summary.totalDuration, const Duration(seconds: 5100));
      expect(summary.lastSyncedAt, DateTime.utc(2026, 9, 29, 9, 20));
      expect(summary.apps.map((CloudAppUsage a) => a.appId).toList(),
          <String>['msedge', 'code'], reason: '必须按时长降序');
      expect(summary.apps.first.duration, const Duration(seconds: 5100));
    });

    test('单应用解析：缺可选字段时用默认值', () {
      final CloudAppUsage app = CloudAppUsage.fromJson(<String, Object?>{
        'app_id': 'wechat',
        'app_name': '微信',
      });
      expect(app.category, 'other');
      expect(app.duration, Duration.zero);
      expect(app.sessionCount, 0);
    });

    test('负数时长被拒绝', () {
      expect(
        () => CloudAppUsage.fromJson(<String, Object?>{
          'app_id': 'code',
          'app_name': 'Code',
          'duration_seconds': -1,
        }),
        throwsA(isA<CloudDataException>()),
      );
      expect(
        () => CloudUsageSummary.fromJson(<String, Object?>{
          'date': '2026-09-29',
          'timezone': 'Asia/Shanghai',
          'total_duration_seconds': -5,
        }),
        throwsA(isA<CloudDataException>()),
      );
    });

    test('「全部设备」的重叠提示被保留', () {
      final CloudUsageSummary summary = CloudUsageSummary.fromJson(<String, Object?>{
        'date': '2026-09-29',
        'timezone': 'Asia/Shanghai',
        'total_duration_seconds': 3600,
        'overlap_warning': '可能包含同时使用',
      });
      expect(summary.overlapWarning, '可能包含同时使用');
    });
  });

  group('会话与时间线解析', () {
    test('会话：UTC 时间解析 + 时长', () {
      final CloudUsageSession session = CloudUsageSession.fromJson(<String, Object?>{
        'id': 's1',
        'local_record_id': 'local-1',
        'device_id': 'dev-1',
        'device_name': '我的电脑',
        'platform': 'windows',
        'app_id': 'msedge',
        'app_name': 'Microsoft Edge',
        'started_at': '2026-09-29T01:12:00Z',
        'ended_at': '2026-09-29T01:35:00Z',
        'duration_seconds': 1380,
      });

      expect(session.localRecordId, 'local-1');
      expect(session.startedAt, DateTime.utc(2026, 9, 29, 1, 12));
      expect(session.endedAt, DateTime.utc(2026, 9, 29, 1, 35));
      expect(session.duration, const Duration(minutes: 23));
      expect(session.deviceDisplay, '我的电脑 · Windows');
    });

    test('会话：结束早于开始被拒绝', () {
      expect(
        () => CloudUsageSession.fromJson(<String, Object?>{
          'id': 's1',
          'device_id': 'dev-1',
          'app_id': 'msedge',
          'app_name': 'Edge',
          'started_at': '2026-09-29T02:00:00Z',
          'ended_at': '2026-09-29T01:00:00Z',
        }),
        throwsA(isA<CloudDataException>()),
      );
    });

    test('会话：缺少时区信息 / 非法时间格式被拒绝', () {
      // Dart 会把无时区的时间当成本机时区，跨设备数据因此必须显式带 Z 或偏移。
      expect(
        () => CloudUsageSession.fromJson(<String, Object?>{
          'id': 's1',
          'device_id': 'dev-1',
          'app_id': 'msedge',
          'app_name': 'Edge',
          'started_at': '2026-09-29 01:00',
        }),
        throwsA(isA<CloudDataException>()),
      );
      expect(
        () => CloudUsageSession.fromJson(<String, Object?>{
          'id': 's1',
          'device_id': 'dev-1',
          'app_id': 'msedge',
          'app_name': 'Edge',
          'started_at': '2026/09/29 01:00Z',
        }),
        throwsA(isA<CloudDataException>()),
      );
    });

    test('分页：next_cursor 缺失表示没有更多', () {
      final CloudSessionPage page = CloudSessionPage.fromJson(<String, Object?>{
        'date': '2026-09-29',
        'timezone': 'Asia/Shanghai',
        'items': <Object?>[],
      });
      expect(page.items, isEmpty);
      expect(page.hasMore, isFalse);

      final CloudSessionPage more = CloudSessionPage.fromJson(<String, Object?>{
        'date': '2026-09-29',
        'timezone': 'Asia/Shanghai',
        'next_cursor': 'abc',
        'items': <Object?>[],
      });
      expect(more.hasMore, isTrue);
    });

    test('时间线：按开始时间升序，并保留合并条数', () {
      final List<CloudTimelineEntry> items = parseTimelineItems(<String, Object?>{
        'items': <Map<String, Object?>>[
          <String, Object?>{
            'app_id': 'code',
            'app_name': 'Visual Studio Code',
            'device_id': 'dev-1',
            'device_name': '我的电脑',
            'platform': 'windows',
            'started_at': '2026-09-29T01:48:00Z',
            'ended_at': '2026-09-29T02:20:00Z',
            'duration_seconds': 1920,
            'merged_session_count': 2,
          },
          <String, Object?>{
            'app_id': 'msedge',
            'app_name': 'Microsoft Edge',
            'device_id': 'dev-1',
            'device_name': '我的电脑',
            'platform': 'windows',
            'started_at': '2026-09-29T01:12:00Z',
            'ended_at': '2026-09-29T01:35:00Z',
            'duration_seconds': 1380,
          },
        ],
      });

      expect(items.map((CloudTimelineEntry e) => e.appId).toList(),
          <String>['msedge', 'code']);
      expect(items.last.mergedSessionCount, 2, reason: '合并条数默认 1');
      expect(items.first.mergedSessionCount, 1);
    });

    test('时间线：结束早于开始被拒绝', () {
      expect(
        () => parseTimelineItems(<String, Object?>{
          'items': <Map<String, Object?>>[
            <String, Object?>{
              'app_id': 'code',
              'app_name': 'Code',
              'device_id': 'dev-1',
              'started_at': '2026-09-29T02:00:00Z',
              'ended_at': '2026-09-29T01:00:00Z',
            },
          ],
        }),
        throwsA(isA<CloudDataException>()),
      );
    });
  });

  group('时区与展示', () {
    test('UTC 转换为 Asia/Shanghai 的本地时刻', () {
      // 01:12Z == 09:12 (+08:00)
      expect(formatLocalHm(DateTime.utc(2026, 9, 29, 1, 12), 480), '09:12');
      expect(formatLocalHm(DateTime.utc(2026, 9, 29, 6, 41), 480), '14:41');
    });

    test('跨午夜：UTC 时间落到次日的当地时刻', () {
      // 16:20Z == 次日 00:20 (+08:00)
      expect(formatLocalHm(DateTime.utc(2026, 9, 29, 16, 20), 480), '00:20');
      // 15:50Z == 23:50 (+08:00)
      expect(formatLocalHm(DateTime.utc(2026, 9, 29, 15, 50), 480), '23:50');
    });

    test('偏移 → 时区键：中国用户得到 Asia/Shanghai', () {
      expect(timezoneKeyForOffset(480), 'Asia/Shanghai');
      expect(isIanaTimezone(timezoneKeyForOffset(480)), isTrue);
      // 没有推荐名的偏移退化成 UTC±HH:MM，此时不放进 timezone 参数
      expect(timezoneKeyForOffset(495), 'UTC+08:15');
      expect(isIanaTimezone(timezoneKeyForOffset(495)), isFalse);
    });

    test('时长文案', () {
      expect(formatDurationZh(const Duration(minutes: 85)), '1 小时 25 分钟');
      expect(formatDurationZh(const Duration(minutes: 52)), '52 分钟');
      expect(formatDurationZh(const Duration(hours: 2)), '2 小时');
      expect(formatDurationZh(const Duration(seconds: 30)), '不到 1 分钟');
    });
  });

  group('查询参数', () {
    test('缓存键包含 device/date/timezone/app，且与 cursor 无关', () {
      final CloudUsageQuery q = CloudUsageQuery(
        date: DateTime(2026, 9, 29, 13),
        deviceId: 'dev-1',
        timezone: 'Asia/Shanghai',
        timezoneOffsetMinutes: 480,
      );
      expect(q.deviceKey, 'dev-1');
      expect(q.dateKey, '2026-09-29');
      expect(q.baseCacheKey, 'dev-1|2026-09-29|Asia/Shanghai|');

      final CloudUsageQuery page2 = q.copyWith(cursor: 'next', clearCursor: false);
      expect(page2.baseCacheKey, q.baseCacheKey, reason: '翻页共用同一条缓存键语义');
    });

    test('未选设备时缓存键用 all', () {
      final CloudUsageQuery q = CloudUsageQuery(
        date: DateTime(2026, 9, 29),
        timezone: 'Asia/Shanghai',
        timezoneOffsetMinutes: 480,
      );
      expect(q.deviceKey, 'all');
      expect(q.baseCacheKey, 'all|2026-09-29|Asia/Shanghai|');
    });

    test('查询参数：IANA 名才发 timezone，偏移始终发', () {
      final CloudUsageQuery shanghai = CloudUsageQuery(
        date: DateTime(2026, 9, 29),
        timezone: 'Asia/Shanghai',
        timezoneOffsetMinutes: 480,
      );
      final Map<String, String> params = shanghai.toQueryParameters();
      expect(params['device_id'], 'all');
      expect(params['date'], '2026-09-29');
      expect(params['timezone'], 'Asia/Shanghai');
      expect(params['tz_offset_minutes'], '480');

      final CloudUsageQuery offsetOnly = CloudUsageQuery(
        date: DateTime(2026, 9, 29),
        timezone: 'UTC+08:15',
        timezoneOffsetMinutes: 495,
      );
      expect(offsetOnly.toQueryParameters().containsKey('timezone'), isFalse);
      expect(offsetOnly.toQueryParameters()['tz_offset_minutes'], '495');
    });
  });
}

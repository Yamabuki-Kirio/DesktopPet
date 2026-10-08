import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:petlife/activity_tracking/current_activity_provider.dart';

/// Phase 4C-5.1A：「当前前台应用」模型与提供者。
///
/// 这一层修的是真机缺陷 D：设置页能显示当前应用、**使用统计页显示空** ——
/// 原因是统计页读的是 Windows 专用链路。现在两页共用同一套模型。
void main() {
  group('CurrentActivity 解析与文案', () {
    test('正常识别：包名 / 标签 / 分类 / 来源', () {
      final CurrentActivity a = CurrentActivity.fromMap(<String, Object?>{
        'available': true,
        'packageName': 'org.telegram.messenger',
        'appLabel': 'Telegram',
        'category': 'social',
        'detectionSource': 'activity-events',
        'usageAccessAvailable': true,
        'collectorRunning': true,
        'eventTime': 1700000000000,
        'detectedAt': 1700000001000,
      });
      expect(a.available, isTrue);
      expect(a.packageName, 'org.telegram.messenger');
      expect(a.displayName, 'Telegram');
      expect(a.label, 'Telegram');
      expect(a.category, 'social');
      expect(a.sourceLabelZh, '前台事件');
      expect(a.displayLabelZh, 'Telegram');
      expect(a.hintZh, isNull);
      expect(a.eventTime, isNotNull);
      expect(a.detectedAt, isNotNull);
    });

    test('无权限：文案为"不可用"并给出原因', () {
      final CurrentActivity a = CurrentActivity.fromMap(<String, Object?>{
        'available': false,
        'usageAccessAvailable': false,
        'collectorRunning': true,
        'failureReason': 'usage_access_missing',
      });
      expect(a.displayLabelZh, '不可用');
      expect(a.hintZh, contains('未授予使用情况访问权限'));
    });

    test('悬浮服务未运行（Android 采集依附于悬浮服务）：明确提示而不是空字符串', () {
      final CurrentActivity a = CurrentActivity.fromMap(<String, Object?>{
        'available': false,
        'usageAccessAvailable': true,
        'collectorRunning': false,
        'failureReason': 'collector_not_running',
      });
      expect(a.displayLabelZh, '未采集');
      expect(a.hintZh, contains('悬浮桌宠'));
    });

    test('桌面 / 系统界面这类"识别不到外部应用"的场景也给出可读状态', () {
      final CurrentActivity a = CurrentActivity.fromMap(<String, Object?>{
        'available': false,
        'usageAccessAvailable': true,
        'collectorRunning': true,
        'failureReason': 'foreground_unavailable',
        'detectionReason': 'last-event-is-system-noise',
      });
      expect(a.displayLabelZh, '暂时无法识别');
      expect(a.hintZh, contains('暂时无法确定当前应用'));
      // 检测原因原样保留，便于真机排查"最后一条到底是谁"。
      expect(a.detectionReason, 'last-event-is-system-noise');
    });

    test('桌面（launcher）被识别为系统分类时仍然是"有明确结果"的状态', () {
      final CurrentActivity a = CurrentActivity.fromMap(<String, Object?>{
        'available': true,
        'packageName': 'com.android.launcher3',
        'appLabel': 'Launcher3',
        'category': 'system',
        'detectionSource': 'activity-events',
        'usageAccessAvailable': true,
        'collectorRunning': true,
      });
      expect(a.displayLabelZh, 'Launcher3');
      expect(a.category, 'system');
      expect(a.hintZh, isNull);
    });

    test('缺字段时退回安全默认（旧版原生不回报也不能崩）', () {
      final CurrentActivity a =
          CurrentActivity.fromMap(<String, Object?>{});
      expect(a.available, isFalse);
      expect(a.packageName, isNull);
      expect(a.detectionSource, 'unavailable');
      expect(a.sourceLabelZh, '不可用');
      expect(a.displayLabelZh, '未采集');
      expect(a.eventTime, isNull);
      expect(a.detectedAt, isNull);
    });

    test('显示名缺失时退回包名，绝不显示空字符串', () {
      final CurrentActivity a = CurrentActivity.fromMap(<String, Object?>{
        'available': true,
        'packageName': 'com.example.app',
        'appLabel': null,
      });
      expect(a.label, 'com.example.app');
      expect(a.displayLabelZh, 'com.example.app');
    });

    test('四种检测来源的中文名，未知值退化为"不可用"', () {
      const Map<String, String> expected = <String, String>{
        'activity-events': '前台事件',
        'usage-stats-fallback': '使用统计兜底',
        'cache': '最近有效应用',
        'win32-foreground': 'Windows 前台窗口',
        'bogus': '不可用',
      };
      expected.forEach((String raw, String label) {
        expect(
          CurrentActivity.fromMap(<String, Object?>{
            'detectionSource': raw,
          }).sourceLabelZh,
          label,
        );
      });
    });
  });

  group('UnsupportedCurrentActivityProvider', () {
    test('非 Windows / 非 Android 平台安全降级', () async {
      const UnsupportedCurrentActivityProvider provider =
          UnsupportedCurrentActivityProvider();
      expect(provider.isSupported, isFalse);
      final CurrentActivity a = await provider.current();
      expect(a.available, isFalse);
      expect(a.failureReason, 'unsupported-platform-provider');
      expect(a.hintZh, contains('当前平台不支持'));
      // watch() 返回空流（不建立任何定时器）。
      expect(await provider.watch().isEmpty, isTrue);
    });
  });

  group('pollCurrentActivity', () {
    test('订阅后立即读一次，并按间隔持续读取；取消订阅后停止', () async {
      int reads = 0;
      final Stream<CurrentActivity> stream = pollCurrentActivity(
        () async {
          reads += 1;
          return CurrentActivity(
            available: true,
            packageName: 'app-$reads',
          );
        },
        interval: const Duration(milliseconds: 20),
      );

      final List<CurrentActivity> seen = <CurrentActivity>[];
      final StreamSubscription<CurrentActivity> sub = stream.listen(seen.add);
      await Future<void>.delayed(const Duration(milliseconds: 70));
      await sub.cancel();

      expect(seen, isNotEmpty, reason: '订阅后必须立刻推一次，界面不能等一个周期');
      expect(seen.first.packageName, 'app-1');
      expect(reads, greaterThanOrEqualTo(2));

      final int afterCancel = reads;
      await Future<void>.delayed(const Duration(milliseconds: 70));
      expect(reads, afterCancel, reason: '取消订阅后必须停止轮询（页面销毁不留定时器）');
    });

    test('单次读取抛错不打断流，下一次继续', () async {
      int reads = 0;
      final Stream<CurrentActivity> stream = pollCurrentActivity(
        () async {
          reads += 1;
          if (reads == 1) throw StateError('boom');
          return const CurrentActivity(available: true, packageName: 'ok');
        },
        interval: const Duration(milliseconds: 20),
      );

      final List<CurrentActivity> seen = <CurrentActivity>[];
      final StreamSubscription<CurrentActivity> sub = stream.listen(seen.add);
      await Future<void>.delayed(const Duration(milliseconds: 90));
      await sub.cancel();

      expect(seen, isNotEmpty);
      expect(seen.last.packageName, 'ok');
    });

    test('一次都没成功时给出明确状态，界面不会长期停在"读取中"', () async {
      final Stream<CurrentActivity> stream = pollCurrentActivity(
        () async => throw StateError('channel missing'),
        interval: const Duration(milliseconds: 20),
      );

      final List<CurrentActivity> seen = <CurrentActivity>[];
      final StreamSubscription<CurrentActivity> sub = stream.listen(seen.add);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await sub.cancel();

      expect(seen, isNotEmpty);
      expect(seen.first.available, isFalse);
      expect(seen.first.displayLabelZh, '暂时无法识别');
      expect(seen.first.hintZh, isNotNull);
    });
  });
}

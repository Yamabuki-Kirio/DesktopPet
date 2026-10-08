import 'package:flutter_test/flutter_test.dart';
import 'package:petlife/activity_tracking/activity_state_mapper.dart';
import 'package:petlife/activity_tracking/models/activity_enums.dart';
import 'package:petlife/core/constants.dart';
import 'package:petlife/state_engine/system_state.dart';

void main() {
  const ActivityStateMapper mapper = ActivityStateMapper();

  ActivityStateDecision? decide({
    bool trackingAvailable = true,
    bool trackingPaused = false,
    AppCategory? category = AppCategory.development,
    Duration idle = Duration.zero,
    int idleThresholdMs = ActivityTracking.defaultIdleThresholdMs,
    int continuousActiveSeconds = 0,
    int todayActiveSeconds = 0,
    int usageAlertThresholdMs = 0,
    bool continuousReminderEnabled = true,
    bool hasCriticalError = false,
  }) =>
      mapper.decide(
        trackingAvailable: trackingAvailable,
        trackingPaused: trackingPaused,
        foregroundCategory: category,
        idle: idle,
        idleThresholdMs: idleThresholdMs,
        continuousActiveSeconds: continuousActiveSeconds,
        todayActiveSeconds: todayActiveSeconds,
        usageAlertThresholdMs: usageAlertThresholdMs,
        continuousReminderEnabled: continuousReminderEnabled,
        hasCriticalError: hasCriticalError,
      );

  group('应用分类 → 桌宠状态（需求 十）', () {
    test('17. 开发工具 → focused', () {
      final ActivityStateDecision d = decide(category: AppCategory.development)!;
      expect(d.state, SystemState.focused);
      expect(d.trigger, StateTrigger.foregroundApp);
      expect(d.isUrgent, isFalse);
    });

    test('办公软件 → focused', () {
      expect(decide(category: AppCategory.productivity)!.state, SystemState.focused);
    });

    test('16. 游戏 → gaming', () {
      final ActivityStateDecision d = decide(category: AppCategory.gaming)!;
      expect(d.state, SystemState.gaming);
      expect(d.isUrgent, isFalse);
    });

    test('18. 通信应用 → social', () {
      expect(decide(category: AppCategory.social)!.state, SystemState.social);
    });

    test('娱乐应用 → entertained', () {
      expect(decide(category: AppCategory.entertainment)!.state, SystemState.entertained);
    });

    test('15. 浏览器 → focused（4C-6A：阅读/浏览即专注）', () {
      final ActivityStateDecision d = decide(category: AppCategory.browser)!;
      // 4C-6A 有意变更：此前浏览器 → default 会让"打开浏览器桌宠毫无反应"。
      // 既有 11 个状态里没有 reading/curious，语义上最接近的就是 focused。
      expect(d.state, SystemState.focused);
      expect(d.reason, contains('浏览器'));
    });

    test('系统应用 → 保持上一个稳定状态（返回 null = 不干预）', () {
      // 系统设置页 / 权限弹窗无法判断用户意图，硬给状态会让桌宠在系统页之间乱跳。
      expect(decide(category: AppCategory.system), isNull);
    });

    test('未归类 → default（明确回退，而不是"不干预"）', () {
      expect(decide(category: AppCategory.other)!.state, SystemState.defaultState);
    });

    test('规则表与原生下发内容一致（同一张表，两端不会漂移）', () {
      final Map<String, String> rules = ActivityStateMapper.categoryStateRules;
      expect(rules['development'], 'focused');
      expect(rules['productivity'], 'focused');
      expect(rules['browser'], 'focused');
      expect(rules['gaming'], 'gaming');
      expect(rules['social'], 'social');
      expect(rules['entertainment'], 'entertained');
      expect(rules['other'], 'default');
      // system 刻意不在表里 → 原生按"保持上一个状态"处理。
      expect(rules.containsKey('system'), isFalse);
    });
  });

  group('空闲 / 连续使用 / 今日用量（需求 十/十一）', () {
    test('19. 空闲超过阈值 → away', () {
      final ActivityStateDecision d = decide(
        idle: const Duration(minutes: 6),
        idleThresholdMs: 5 * 60 * 1000,
      )!;
      expect(d.state, SystemState.away);
      expect(d.trigger, StateTrigger.idle);
    });

    test('空闲未超过阈值 → 仍然按前台应用判定', () {
      expect(
        decide(idle: const Duration(minutes: 4), idleThresholdMs: 5 * 60 * 1000)!.state,
        SystemState.focused,
      );
    });

    test('20. 连续活跃超过 90 分钟 → tired', () {
      final ActivityStateDecision d = decide(
        continuousActiveSeconds: ActivityTracking.continuousUsageTiredMs ~/ 1000,
      )!;
      expect(d.state, SystemState.tired);
      expect(d.reason, contains('90'));
    });

    test('连续活跃 89 分钟不触发 tired', () {
      expect(
        decide(continuousActiveSeconds: ActivityTracking.continuousUsageTiredMs ~/ 1000 - 60)!.state,
        SystemState.focused,
      );
    });

    test('提醒关闭后不再触发 tired', () {
      expect(
        decide(
          continuousActiveSeconds: ActivityTracking.continuousUsageTiredMs ~/ 1000,
          continuousReminderEnabled: false,
        )!.state,
        SystemState.focused,
      );
    });

    test('今日活跃超过用户阈值 → concerned（优先于 tired）', () {
      final ActivityStateDecision d = decide(
        todayActiveSeconds: 4 * 3600,
        usageAlertThresholdMs: 4 * 3600 * 1000,
        continuousActiveSeconds: ActivityTracking.continuousUsageTiredMs ~/ 1000,
      )!;
      expect(d.state, SystemState.concerned);
    });

    test('阈值为 0 表示关闭 concerned', () {
      expect(
        decide(todayActiveSeconds: 20 * 3600, usageAlertThresholdMs: 0)!.state,
        SystemState.focused,
      );
    });

    test('严重错误 → error（最高优先，且为紧急状态）', () {
      final ActivityStateDecision d = decide(
        hasCriticalError: true,
        todayActiveSeconds: 20 * 3600,
        usageAlertThresholdMs: 3600 * 1000,
      )!;
      expect(d.state, SystemState.error);
      expect(d.trigger, StateTrigger.error);
      expect(d.isUrgent, isTrue);
    });
  });

  group('不干预与暂停', () {
    test('采集不可用时不干预状态', () {
      expect(decide(trackingAvailable: false), isNull,
          reason: '采集不可用时不得把桌宠钉在某个状态上');
    });

    test('暂停记录时回到 default，不做应用相关猜测', () {
      final ActivityStateDecision d = decide(trackingPaused: true)!;
      expect(d.state, SystemState.defaultState);
    });

    test('无法确定前台应用时回到 default', () {
      expect(decide(category: null)!.state, SystemState.defaultState);
    });

    test('所有自动判定都不是紧急状态（保留平滑切换）', () {
      for (final AppCategory c in AppCategory.values) {
        // 4C-6A：`system` 分类返回 null = "保持上一个稳定状态"（不干预），
        // 其余分类必须给出**非紧急**的明确状态。
        final ActivityStateDecision? d = decide(category: c);
        if (d == null) continue;
        expect(d.isUrgent, isFalse, reason: '${c.wireName} 不应打断当前动画');
      }
      expect(decide(idle: const Duration(minutes: 30))!.isUrgent, isFalse);
    });

    test('永远不会返回 manual（manual 由用户与状态引擎掌握）', () {
      for (final AppCategory c in AppCategory.values) {
        final ActivityStateDecision? d = decide(category: c);
        if (d == null) continue;
        expect(d.state, isNot(SystemState.manual));
      }
    });
  });
}

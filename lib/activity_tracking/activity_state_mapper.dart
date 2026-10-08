import '../core/constants.dart';
import '../state_engine/system_state.dart';
import 'models/activity_enums.dart';

/// 一次自动状态判定结果。
class ActivityStateDecision {
  const ActivityStateDecision({
    required this.state,
    required this.trigger,
    required this.reason,
    required this.isUrgent,
  });

  final SystemState state;
  final StateTrigger trigger;

  /// 判定依据，写入日志与状态调试器的「触发原因」。
  final String reason;

  /// 是否属于紧急状态（`error` 才允许打断当前动画立即切换）。
  final bool isUrgent;

  @override
  String toString() => 'ActivityStateDecision(${state.wireName}, $reason)';
}

/// 采集上下文 → 桌宠状态的映射器（需求「十、桌宠自动状态联动」）。
///
/// 纯函数：不读系统、不写库，因此映射规则可以被单元测试逐条覆盖。
///
/// 优先级（从高到低，互斥关系已在 [decide] 中说明）：
/// `error` → `concerned` → `tired` → `away` → `gaming` → `social`
/// → `entertained` → `focused` → `default`。
///
/// 注意：`manual` **不在这里判定**——它由状态引擎自己的优先级与
/// 最短展示时长（-1 = 直到用户解除）保证，自动状态永远顶不掉它。
class ActivityStateMapper {
  const ActivityStateMapper();

  /// 判定当前应显示的系统状态；返回 null 表示「采集不可用，不做干预」。
  ActivityStateDecision? decide({
    required bool trackingAvailable,
    required bool trackingPaused,
    AppCategory? foregroundCategory,
    required Duration idle,
    int idleThresholdMs = ActivityTracking.defaultIdleThresholdMs,
    int continuousActiveSeconds = 0,
    int todayActiveSeconds = 0,
    int usageAlertThresholdMs = 0,
    bool continuousReminderEnabled = true,
    bool hasCriticalError = false,
  }) {
    // 采集不可用时不干预状态，避免把桌宠永久钉在某个状态上。
    if (!trackingAvailable) return null;

    // 1. 严重错误（采集器或数据库不可用）。
    if (hasCriticalError) {
      return const ActivityStateDecision(
        state: SystemState.error,
        trigger: StateTrigger.error,
        reason: '活动采集或数据库发生严重错误',
        isUrgent: true,
      );
    }

    // 2. 今日活跃时间超过用户阈值。
    if (usageAlertThresholdMs > 0 && todayActiveSeconds * 1000 >= usageAlertThresholdMs) {
      return ActivityStateDecision(
        state: SystemState.concerned,
        trigger: StateTrigger.foregroundApp,
        reason: '今日活跃时间已达 ${todayActiveSeconds ~/ 60} 分钟，'
            '超过设定阈值 ${usageAlertThresholdMs ~/ 60000} 分钟',
        isUrgent: false,
      );
    }

    // 3. 连续活跃过久（用户离开时长超过阈值后该计数会归零，
    //    因此与下面的 away 互斥）。
    if (continuousReminderEnabled &&
        continuousActiveSeconds * 1000 >= ActivityTracking.continuousUsageTiredMs) {
      return ActivityStateDecision(
        state: SystemState.tired,
        trigger: StateTrigger.foregroundApp,
        reason: '连续活跃已达 ${continuousActiveSeconds ~/ 60} 分钟（阈值 '
            '${ActivityTracking.continuousUsageTiredMs ~/ 60000} 分钟）',
        isUrgent: false,
      );
    }

    // 4. 用户空闲超过阈值。
    if (idle.inMilliseconds >= idleThresholdMs) {
      return ActivityStateDecision(
        state: SystemState.away,
        trigger: StateTrigger.idle,
        reason: '用户已空闲 ${idle.inMilliseconds ~/ 1000} 秒，'
            '超过阈值 ${idleThresholdMs ~/ 1000} 秒',
        isUrgent: false,
      );
    }

    // 5. 暂停记录时保持 default，不做应用相关的猜测。
    if (trackingPaused || foregroundCategory == null) {
      return const ActivityStateDecision(
        state: SystemState.defaultState,
        trigger: StateTrigger.foregroundApp,
        reason: '未记录或无法确定前台应用',
        isUrgent: false,
      );
    }

    // 6. 按应用分类映射。
    final (SystemState? state, String note) = _stateForCategory(foregroundCategory);
    if (state == null) {
      // 「保持上一个稳定状态」（系统界面 / 桌面这类无法判断意图的场景）：
      // 返回 null = **不干预**，由状态引擎继续维持当前状态（需求 4C-6A §4.2）。
      return null;
    }
    return ActivityStateDecision(
      state: state,
      trigger: StateTrigger.foregroundApp,
      reason: '前台应用分类为「${foregroundCategory.labelZh}」$note',
      isUrgent: false,
    );
  }

  /// 分类 → 状态的**唯一规则表**（Phase 4C-6A）。
  ///
  /// * key = `AppCategory.wireName`，value = `SystemState.wireName`；
  /// * **不在表里的分类 = 保持上一个稳定状态**（`system` 刻意不在此表：
  ///   系统设置页 / 权限弹窗无法判断用户意图，硬给状态会让桌宠在系统页之间乱跳）；
  /// * Android 原生通过 `OverlayStateMapping.categoryStateRules` 收到**同一张表**，
  ///   因此两端不会出现"同一分类映射到不同状态"。
  ///
  /// 4C-6A 相对 4C-5 的两处有意变更：
  /// * `browser → focused`：既有 11 个状态里没有 reading/curious，而"看网页"
  ///   在语义上最接近"专注"。此前 browser→default 会让"打开浏览器桌宠毫无反应"；
  /// * `system → 保持上一个状态`：见上。
  static final Map<String, String> categoryStateRules = <String, String>{
    AppCategory.development.wireName: SystemState.focused.wireName,
    AppCategory.productivity.wireName: SystemState.focused.wireName,
    AppCategory.browser.wireName: SystemState.focused.wireName,
    AppCategory.gaming.wireName: SystemState.gaming.wireName,
    AppCategory.social.wireName: SystemState.social.wireName,
    AppCategory.entertainment.wireName: SystemState.entertained.wireName,
    AppCategory.other.wireName: SystemState.defaultState.wireName,
  };

  /// 规则说明（写进判定原因，与原生 `AppCategoryStateMapper.noteForCategory` 对齐）。
  static const Map<String, String> categoryStateNotes = <String, String>{
    'development': '（开发工具）',
    'productivity': '（办公软件）',
    'browser': '（浏览器 / 阅读）',
    'gaming': '（游戏）',
    'social': '（通信软件）',
    'entertainment': '（娱乐）',
    'other': '（未归类）',
  };

  /// 分类 → 状态；返回 null 表示"保持上一个稳定状态"。
  (SystemState?, String) _stateForCategory(AppCategory category) {
    final String? wire = categoryStateRules[category.wireName];
    if (wire == null) {
      return (null, '（系统界面 / 桌面，保持上一个稳定状态）');
    }
    return (SystemState.fromWire(wire), categoryStateNotes[category.wireName] ?? '');
  }
}

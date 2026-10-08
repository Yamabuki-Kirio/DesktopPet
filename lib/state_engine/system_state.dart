import '../core/constants.dart';

/// 系统状态。
///
/// 关键设计：**系统状态**与素材里作者写的**原始情绪名**是两个独立概念。
/// 素材侧可以有任意情绪（Angry / Bench_Thinking / Nod ...），
/// 系统侧只认这 11 个状态；两者通过 `state_mappings` 表由用户绑定。
///
/// 阶段 0 不接入真实应用统计，全部状态由「状态调试器」手动触发。
enum SystemState {
  error('error', priority: 100),
  manual('manual', priority: 95),
  concerned('concerned', priority: 90),
  tired('tired', priority: 80),
  happy('happy', priority: 70),
  gaming('gaming', priority: 60),
  focused('focused', priority: 50),
  social('social', priority: 40),
  entertained('entertained', priority: 30),
  away('away', priority: 20),
  defaultState('default', priority: 0);

  const SystemState(this.wireName, {required this.priority});

  /// 持久化 / API 中使用的稳定名称。
  final String wireName;

  /// 默认优先级，数值越大越优先。用户可在状态映射页覆盖。
  final int priority;

  /// 紧急状态：允许打断当前动画立即切换。
  bool get isUrgent => this == SystemState.error || this == SystemState.manual;

  /// 由「前台应用 / 空闲 / 锁屏」派生的状态。
  ///
  /// 这类状态受“前台应用需稳定 10 秒”规则约束（阶段 1 才会真正触发）。
  bool get isAppDerived => const <SystemState>{
        SystemState.focused,
        SystemState.gaming,
        SystemState.social,
        SystemState.entertained,
        SystemState.away,
      }.contains(this);

  /// 最短展示时长（毫秒）。
  ///
  /// -1 表示“无限，直到用户解除”。
  int get minHoldMs => switch (this) {
        SystemState.error => 0, // 紧急：允许立即被更高优先级替换
        SystemState.manual => -1, // 直到用户解除
        SystemState.tired => StateDebounce.tiredMinHoldMs,
        SystemState.happy => StateDebounce.happyMinHoldMs,
        _ => StateDebounce.normalMinHoldMs,
      };

  /// 人类可读标签（UI 用，保持与需求文档一致）。
  String get label => switch (this) {
        SystemState.defaultState => 'default',
        _ => wireName,
      };

  String get descriptionZh => switch (this) {
        SystemState.defaultState => '默认',
        SystemState.focused => '专注',
        SystemState.gaming => '游戏',
        SystemState.social => '社交',
        SystemState.entertained => '娱乐',
        SystemState.tired => '疲惫',
        SystemState.away => '离开',
        SystemState.happy => '开心',
        SystemState.concerned => '担忧',
        SystemState.error => '错误',
        SystemState.manual => '手动锁定',
      };

  /// 从持久化名称解析；未知值回退到 [defaultState]。
  static SystemState fromWire(String value) {
    for (final SystemState s in SystemState.values) {
      if (s.wireName == value) return s;
    }
    return SystemState.defaultState;
  }
}

/// 状态触发来源，用于调试面板展示“触发原因”。
enum StateTrigger {
  /// 应用启动时的初始状态。
  init('启动初始化'),

  /// 前台应用变化（阶段 1）。
  foregroundApp('前台应用'),

  /// 空闲检测（阶段 1）。
  idle('空闲检测'),

  /// 锁屏（阶段 1）。
  lockScreen('锁屏'),

  /// 用户手动锁定表情。
  manual('用户手动'),

  /// 状态调试器手动触发。
  debugger('状态调试器'),

  /// 系统错误。
  error('错误事件'),

  /// 回退到默认状态。
  fallback('回退');

  const StateTrigger(this.label);

  final String label;
}

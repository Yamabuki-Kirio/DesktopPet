import '../core/constants.dart';
import 'system_state.dart';

/// 一次状态切换请求。
class StateChangeRequest {
  const StateChangeRequest({
    required this.state,
    required this.trigger,
    this.reason,
    this.force = false,
    this.immediate = false,
    this.manualAssetId,
  });

  final SystemState state;
  final StateTrigger trigger;

  /// 触发原因描述，会显示在状态调试器里。
  final String? reason;

  /// 忽略优先级与「最短展示时长」。
  ///
  /// 阶段 0 的**状态调试器就是靠它来触发全部 11 个状态**——
  /// 否则 `default`（优先级 0）在 `error` 之后会被永久挡住，验收第 14 项无法通过。
  /// 后续阶段接入真实统计时，自动切换一律使用 force=false。
  final bool force;

  /// 跳过「等当前动画播完一轮」（紧急状态使用）。
  final bool immediate;

  /// manual 状态显式指定的图片。
  final String? manualAssetId;

  StateChangeRequest copyWith({bool? force, bool? immediate}) => StateChangeRequest(
        state: state,
        trigger: trigger,
        reason: reason,
        force: force ?? this.force,
        immediate: immediate ?? this.immediate,
        manualAssetId: manualAssetId,
      );
}

/// 防抖决策。
sealed class DebounceDecision {
  const DebounceDecision();
}

/// 立即切换。
class ApplyNow extends DebounceDecision {
  const ApplyNow({required this.waitForAnimationCycle, required this.note});

  /// 是否应等待当前动画播完一轮再淡入新图。
  final bool waitForAnimationCycle;

  /// 决策说明，写入日志。
  final String note;
}

/// 推迟到某个时刻再尝试。
class DeferUntil extends DebounceDecision {
  const DeferUntil({required this.at, required this.reason});

  final DateTime at;
  final String reason;
}

/// 拒绝。
class RejectChange extends DebounceDecision {
  const RejectChange(this.reason);

  final String reason;
}

/// 状态防抖规则（需求「八、状态优先级与防抖」）。
///
/// 这是一个**纯函数对象**：不持有计时器、不访问数据库，因此可以被单测穷举覆盖。
/// 计时器由 [DefaultStateEngine] 负责。
class StateDebouncer {
  const StateDebouncer();

  DebounceDecision decide({
    required SystemState currentState,
    required DateTime currentStateStartedAt,
    required DateTime lastAppliedChangeAt,
    required StateChangeRequest request,
    required DateTime now,

    /// 请求的状态（若为前台应用派生状态）已经稳定了多久。
    required Duration appStateStableFor,
  }) {
    // 1. manual 锁定：直到用户主动解除，任何自动状态都不能顶掉它。
    if (currentState == SystemState.manual &&
        request.state != SystemState.manual &&
        !request.force) {
      return const RejectChange('manual 状态已锁定，需用户先解除（恢复自动状态切换）');
    }

    // 2. 同状态重复请求：不重新加载素材、不重启动画（需求：同一张图片不得反复重新加载）。
    if (request.state == currentState &&
        request.manualAssetId == null &&
        !request.immediate) {
      return const RejectChange('状态未发生变化');
    }

    if (!request.force) {
      // 3. 前台应用需稳定 10 秒（阶段 1 接入，阶段 0 由调试器模拟）。
      if (request.state.isAppDerived &&
          appStateStableFor < const Duration(milliseconds: StateDebounce.foregoundStableMs)) {
        final Duration remaining =
            const Duration(milliseconds: StateDebounce.foregoundStableMs) - appStateStableFor;
        return DeferUntil(
          at: now.add(remaining),
          reason: '前台应用尚未稳定 10 秒（还需 ${remaining.inMilliseconds} ms）',
        );
      }

      // 4. 当前状态最短展示时长。
      final int holdMs = currentState.minHoldMs;
      if (holdMs > 0) {
        final int elapsed = now.difference(currentStateStartedAt).inMilliseconds;
        if (elapsed < holdMs) {
          return DeferUntil(
            at: currentStateStartedAt.add(Duration(milliseconds: holdMs)),
            reason: '当前状态 ${currentState.wireName} 需至少展示 ${holdMs ~/ 1000} 秒'
                '（已展示 ${elapsed ~/ 1000} 秒）',
          );
        }
      }
    }

    // 5. 快速切换抑制：永远生效，包括强制模式——
    //    这正是「快速切换窗口时不得连续闪烁」的落点。
    final int sinceLastChange = now.difference(lastAppliedChangeAt).inMilliseconds;
    if (sinceLastChange < StateDebounce.rapidSwitchSuppressMs) {
      return DeferUntil(
        at: lastAppliedChangeAt.add(
          const Duration(milliseconds: StateDebounce.rapidSwitchSuppressMs),
        ),
        reason: '处于快速切换抑制窗口（${StateDebounce.rapidSwitchSuppressMs} ms）',
      );
    }

    // 通过全部规则。
    final bool waitCycle = !request.immediate && !request.state.isUrgent;
    return ApplyNow(
      waitForAnimationCycle: waitCycle,
      note: waitCycle
          ? '通过防抖检查，等待当前动画播完一轮后切换'
          : '通过防抖检查，紧急/立即生效',
    );
  }
}

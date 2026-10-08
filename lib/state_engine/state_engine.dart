import 'package:flutter/foundation.dart';

import 'system_state.dart';
import 'state_debouncer.dart';
import 'state_snapshot.dart';

/// 一次成功生效的状态切换事件。
///
/// 渲染层订阅它来做淡入淡出与「等当前动画播完一轮」。
class StateChangeEvent {
  const StateChangeEvent({
    required this.from,
    required this.to,
    required this.trigger,
    required this.reason,
    required this.waitForAnimationCycle,
    required this.at,
  });

  final SystemState from;
  final SystemState to;
  final StateTrigger trigger;
  final String reason;

  /// 渲染层是否应等当前动画播完一轮再切换。
  final bool waitForAnimationCycle;

  final DateTime at;

  bool get isCrossFade => from != to;
}

/// 状态引擎抽象。
///
/// 阶段 1 会为它接上真实的前台应用 / 空闲 / 锁屏信号；
/// 阶段 0 全部信号来自状态调试器。引擎本身不关心信号从哪来。
abstract interface class StateEngine {
  /// 当前状态快照。
  StateSnapshot get snapshot;

  /// 状态快照的可监听视图（UI 直接监听它重建即可）。
  ValueListenable<StateSnapshot> get snapshots;

  /// 状态切换事件流（广播）。
  Stream<StateChangeEvent> get events;

  /// 是否已启动。
  bool get isRunning;

  /// 启动引擎并绑定默认角色。
  Future<void> start({required String ownerId, required String characterId});

  /// 切换当前角色（保留用户对状态的锁定）。
  Future<void> setCharacter(String characterId);

  /// 应用启动后恢复上次的角色与表情。
  Future<void> restore({required String ownerId, required String? characterId, String? assetId});

  /// 请求切换状态。
  Future<void> requestState(StateChangeRequest request);

  /// 用户手动锁定到某张图片（`manual` 状态）。
  Future<void> lockManual({String? assetId, String? reason});

  /// 解除手动锁定，恢复自动状态切换。
  Future<void> releaseManual();

  /// 重新解析当前状态应显示的素材。
  ///
  /// 在「状态映射被修改」「素材被启用/禁用/删除」后调用。
  Future<void> refresh();

  /// 释放资源。
  Future<void> dispose();
}

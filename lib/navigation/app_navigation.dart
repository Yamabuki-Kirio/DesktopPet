import 'dart:async';

import 'package:flutter/foundation.dart';

/// 应用级「跳转目的地」（Phase 4C-6B-2：轮盘菜单 → 页面）。
///
/// 名字（`name`）就是原生下发的字符串，与冻结契约一一对应：
/// `assetLibrary | stateAssetMapping | localStatistics | cloudStatistics |
/// accountSync | overlaySettings`。
enum AppDestination {
  /// 素材库（底部第 4 页）。
  assetLibrary,

  /// 状态素材映射编辑器（以**当前角色**为上下文打开）。
  stateAssetMapping,

  /// 使用统计 · 本机（底部第 2 页）。
  localStatistics,

  /// 使用统计 · 云端（底部第 2 页并切到云端子页）。
  cloudStatistics,

  /// 账户与同步（底部第 3 页）。
  accountSync,

  /// 设置（底部第 5 页；悬浮桌宠相关设置都在这一页）。
  overlaySettings;

  /// 原生侧使用的字符串形式。
  String get wireName => name;

  /// 解析原生字符串；未知取值返回 null（调用方据此报"无法识别"，绝不猜）。
  static AppDestination? fromWire(String? raw) {
    if (raw == null) return null;
    for (final AppDestination destination in AppDestination.values) {
      if (destination.name == raw) return destination;
    }
    return null;
  }
}

/// 跳转请求的控制器。
///
/// 为什么需要它，而不是让调用方直接去改外壳的下标：
/// * 原生（悬浮窗轮盘菜单）与 Dart 侧的动作执行器都**不认识外壳的私有状态**
///   （`_MobileShellState._index`）；直接反射/trampoline 会让"外壳该怎么响应"
///   散落在多个页面里；
/// * 页面尚未就绪时的请求**必须有个地方先存着**（需求：外壳未就绪时保持待处理，
///   等 init 后再消费），否则用户点了菜单却什么都不发生；
/// * 同一个目的地会被多个入口请求（轮盘菜单 / 设置页 / 托盘），
///   集中在一处才能保证"消费一次、不重复触发"。
///
/// 语义：
/// * [request] 只**登记**目的地，不做任何 UI 操作（外壳可以还没起来）；
/// * [pending] / [hasPending] / [take] 供外壳在就绪后逐个消费；
/// * [requests] 是同一件事的流式视图，外壳也可以只订阅它。
class AppNavigationController extends ChangeNotifier {
  final List<AppDestination> _pending = <AppDestination>[];
  final StreamController<AppDestination> _requests =
      StreamController<AppDestination>.broadcast();

  /// 尚未被外壳消费的目的地（按请求顺序）。
  List<AppDestination> get pending => List<AppDestination>.unmodifiable(_pending);

  bool get hasPending => _pending.isNotEmpty;

  /// 跳转请求事件流（广播）。外壳订阅它即可即时响应。
  Stream<AppDestination> get requests => _requests.stream;

  /// 登记一次跳转请求。
  void request(AppDestination destination) {
    _pending.add(destination);
    if (!_requests.isClosed) _requests.add(destination);
    notifyListeners();
  }

  /// 取出最早的一次请求；没有则返回 null。
  ///
  /// 消费即移除 —— 外壳执行成功后不需要再"确认回来"，避免同一目的地被处理两次。
  AppDestination? take() => _pending.isEmpty ? null : _pending.removeAt(0);

  @override
  void dispose() {
    unawaited(_requests.close());
    super.dispose();
  }
}

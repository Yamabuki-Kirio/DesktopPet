/// 应用生命周期原生桥的**中立契约**（单实例唤醒 + 统一退出协作）。
///
/// 为什么要有这层
/// --------------
/// Windows Runner 在 `wWinMain` 里完成单实例仲裁（命名互斥体），
/// 第二实例通过消息窗口把「唤醒桌宠 / 请求退出」信号投给主实例；
/// 主实例的 Runner 再经 MethodChannel 转发给 Dart。同时，系统注销 /
/// 关机（`WM_QUERYENDSESSION` / `WM_ENDSESSION`）也要求 Dart 先走完
/// 统一退出事务再放行。这些信号都需要一个平台无关的出口给装配层使用。
///
/// Android 没有这套机制（系统按包名保证单实例、也没有命名互斥体），
/// 平台装配返回 null，装配层直接跳过。
///
/// 设计约束
/// --------
/// * 本文件不得 import 任何平台专属库（flutter/services 除外——通道
///   类型属于 Flutter 框架本身）；
/// * 所有回调必须**快速返回**：主实例侧还要应答第二实例的
///   `SendMessageTimeout` 探测（3 秒无应答即判定无响应）；
/// * `markShuttingDown` / `markShutdownComplete` 失败必须**静默降级**：
///   它们只影响第二实例的判定文案与会话结束等待，不影响退出事务本身。
library;

/// 原生 → Dart 的生命周期回调集合。
class AppLifecycleHandlers {
  const AppLifecycleHandlers({
    required this.onSecondInstanceWake,
    required this.onExitRequested,
  });

  /// 第二实例请求唤醒：显示桌宠或控制面板（规格§六）。
  final Future<void> Function() onSecondInstanceWake;

  /// 退出请求（`--shutdown` 第二实例 / 更新程序 / 系统注销关机）。
  ///
  /// [reason] 仅用于日志与诊断，取值：
  /// `shutdown-request` / `system-session-end`。
  final Future<void> Function(String reason) onExitRequested;
}

/// 应用生命周期桥。
abstract interface class AppLifecycleBridge {
  /// 注册原生回调。必须在窗口 / 托盘就绪前调用（引擎就绪即可）。
  Future<void> initialize(AppLifecycleHandlers handlers);

  /// 通知原生：统一退出事务**开始**（置命名事件，
  /// 第二实例据此判定「正在退出」而不是「无响应」）。
  Future<void> markShuttingDown();

  /// 通知原生：统一退出事务**完成**（解除 `WM_ENDSESSION` 的泵等待）。
  Future<void> markShutdownComplete();
}

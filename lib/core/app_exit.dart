import 'dart:async';

import 'logger.dart';

/// 统一退出事务协调器（规格§二）。
///
/// 所有退出入口（控制面板退出按钮 / 托盘退出 / 窗口关闭 / 系统注销关机 /
/// 更新程序请求）只能经由 [run] 进入，它保证：
///
/// 1. **事务只执行一次**——并发或重复触发等待同一次完成，不再排队第二次；
/// 2. **正常退出 3 秒内进程归零**——[watchdogTimeout] 到点后调用
///    [onForceExit]（生产代码传 `exit(0)`）强制结束进程，超时只记录一次
///    退出诊断，不产生后台常驻副本；
/// 3. 事务抛出的任何异常都被记录并吞掉——退出路径绝不能因清理失败而卡住。
class ShutdownCoordinator {
  ShutdownCoordinator({
    this.watchdogTimeout = const Duration(milliseconds: 2500),
    this.onForceExit,
  });

  /// 看门狗预算：事务必须在此之前完成（含网络同步的严格超时），
  /// 预留约 500ms 给进程终止，满足「3 秒内进程数归零」。
  final Duration watchdogTimeout;

  /// 看门狗触发时的强制结束动作；null（测试注入）时只记录日志。
  final void Function()? onForceExit;

  Future<void>? _running;

  /// 事务是否已经触发（入口层据此丢弃退出过程中的新任务）。
  bool get isShutdownStarted => _running != null;

  /// 执行（或加入）正在进行的退出事务。
  ///
  /// [source] 仅用于日志：`panel.exit` / `tray.exit` / `window.close` /
  /// `native.shutdown-request` / `native.system-session-end` ...
  Future<void> run(String source, Future<void> Function() transaction) {
    final Future<void>? running = _running;
    if (running != null) {
      // 已有事务在跑：等待它（并发入口只等不重入）。
      return running;
    }

    Loggers.app.info('统一退出事务开始（source=$source）');
    final Completer<void> done = Completer<void>();
    _running = done.future;

    final Timer watchdog = Timer(watchdogTimeout, () {
      if (!done.isCompleted) {
        Loggers.app.warning(
          '统一退出事务超时（${watchdogTimeout.inMilliseconds}ms），强制结束进程'
          '（本条为唯一一次退出诊断，不产生后台副本）',
        );
        done.complete();
        onForceExit?.call();
      }
    });

    () async {
      try {
        await transaction();
      } catch (e, st) {
        // 任何一步失败都不能阻止后续清理与进程结束。
        Loggers.app.warning('统一退出事务步骤异常（继续结束进程）', e, st);
      } finally {
        if (!done.isCompleted) done.complete();
        watchdog.cancel();
        Loggers.app.info('统一退出事务完成（source=$source）');
      }
    }();

    return done.future;
  }

  /// 重置一次性状态（AppServices.resetForTest 在测试间调用）。
  void resetForTest() {
    _running = null;
  }
}

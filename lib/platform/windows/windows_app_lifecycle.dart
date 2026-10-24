/// Windows 应用生命周期桥（`asia.akechi.petlife/app_lifecycle` 通道）。
///
/// 原生侧（`windows/runner/flutter_window.cpp`）：
/// * Dart → 原生：`markShuttingDown` / `shutdownComplete`
///   （统一退出事务与 Runner 单实例协调器协作）；
/// * 原生 → Dart：`onSecondInstance`（第二实例唤醒）、
///   `onExitRequested{reason}`（`--shutdown` / 更新程序）、
///   `onSystemSessionEnd`（注销 / 关机）。
///
/// 三条 Dart→原生调用失败时**静默降级**：它们只影响第二实例判定文案与
/// 会话结束等待，绝不能反过来打断退出事务。
library;

import 'package:flutter/services.dart';

import '../app_lifecycle.dart';

/// 通道名：与原生侧 `kLifecycleChannelName` 逐字一致。
const String appLifecycleChannelName = 'asia.akechi.petlife/app_lifecycle';

class WindowsAppLifecycleBridge implements AppLifecycleBridge {
  WindowsAppLifecycleBridge({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(appLifecycleChannelName);

  final MethodChannel _channel;

  AppLifecycleHandlers? _handlers;

  @override
  Future<void> initialize(AppLifecycleHandlers handlers) async {
    _handlers = handlers;
    _channel.setMethodCallHandler((MethodCall call) async {
      final AppLifecycleHandlers? active = _handlers;
      if (active == null) return null;
      switch (call.method) {
        case 'onSecondInstance':
          await active.onSecondInstanceWake();
          return null;
        case 'onExitRequested':
          final Object? raw = call.arguments;
          final String reason = raw is Map && raw['reason'] is String
              ? raw['reason']! as String
              : 'unknown';
          await active.onExitRequested(reason);
          return null;
        case 'onSystemSessionEnd':
          await active.onExitRequested('system-session-end');
          return null;
      }
      return null;
    });
  }

  @override
  Future<void> markShuttingDown() async {
    try {
      await _channel.invokeMethod<void>('markShuttingDown');
    } catch (_) {
      // 通道不可用（引擎正在销毁等）：退出事务不受影响。
    }
  }

  @override
  Future<void> markShutdownComplete() async {
    try {
      await _channel.invokeMethod<void>('shutdownComplete');
    } catch (_) {
      // 同上：只影响 WM_ENDSESSION 的等待，进程即将结束。
    }
  }
}

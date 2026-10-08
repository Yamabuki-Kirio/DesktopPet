import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import 'logger.dart';

/// 未处理异常的统一兜底。
///
/// 需求「十二、错误处理与日志」要求记录未处理异常。
/// 这里只做“记录 + 通知 UI”，不改变异常语义。
/// Zone 级兜底由 `main.dart` 用 `runZonedGuarded` 包裹 `runApp` 完成。
class ErrorHandler {
  ErrorHandler._();

  /// 累计未处理异常次数（诊断页展示）。
  static final ValueNotifier<int> unhandledCount = ValueNotifier<int>(0);

  /// 最近一次未处理异常（已脱敏）。
  static final ValueNotifier<String?> lastError = ValueNotifier<String?>(null);

  /// 安装 Flutter 与平台层兜底。应在 `runApp` 之前调用。
  static void install() {
    final FlutterExceptionHandler? previous = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      record('FlutterError', details.exception, details.stack);
      previous?.call(details);
    };

    final ui.ErrorCallback? previousPlatform = ui.PlatformDispatcher.instance.onError;
    ui.PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
      record('平台异常', error, stack);
      if (previousPlatform != null) return previousPlatform(error, stack);
      return true; // 已记录，避免直接崩溃。
    };
  }

  /// 记录一条未处理异常。
  static void record(String scope, Object error, StackTrace? stack) {
    AppLog.of('app').severe('未处理异常[$scope]: $error', error, stack);
    lastError.value = AppLog.redact(error.toString());
    unhandledCount.value += 1;
  }
}

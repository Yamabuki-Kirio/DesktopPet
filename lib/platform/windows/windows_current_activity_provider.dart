import 'dart:async';

import '../../activity_tracking/activity_tracker.dart';
import '../../activity_tracking/current_activity_provider.dart';
import '../../activity_tracking/models/activity_enums.dart';

/// Windows 的「当前前台应用」（Phase 4C-5.1A）。
///
/// **刻意不新增第二个 Win32 轮询**：直接跟随现有 [ActivityTracker]
/// （它已经每 2 秒采一次 Win32 前台窗口），只是在它通知时把结果映射成本接口的模型。
/// 这样"采集器"与"界面显示"仍然是同一份真相。
class WindowsCurrentActivityProvider implements CurrentActivityProvider {
  WindowsCurrentActivityProvider(this._tracker);

  final ActivityTracker _tracker;

  @override
  bool get isSupported => _tracker.isAvailable;

  @override
  Future<CurrentActivity> current() async => _snapshot();

  @override
  Stream<CurrentActivity> watch() {
    late StreamController<CurrentActivity> controller;
    void emit() {
      if (!controller.isClosed) controller.add(_snapshot());
    }

    controller = StreamController<CurrentActivity>(
      onListen: () {
        _tracker.addListener(emit);
        emit();
      },
      onCancel: () {
        _tracker.removeListener(emit);
      },
    );
    return controller.stream;
  }

  CurrentActivity _snapshot() {
    final String? appKey = _tracker.currentAppKey;
    final AppCategory? category = _tracker.currentAppCategory;
    final bool providerAvailable = _tracker.isAvailable;
    final bool hasApp = providerAvailable && appKey != null;
    return CurrentActivity(
      available: hasApp,
      packageName: appKey,
      displayName: _tracker.currentAppDisplayName,
      category: category?.wireName,
      detectionSource: hasApp ? 'win32-foreground' : 'unavailable',
      failureReason: !providerAvailable
          ? 'unsupported-platform-provider'
          : (appKey == null ? 'no-foreground-window' : null),
      detectedAt: DateTime.now(),
      // Windows 不需要"使用情况访问"权限：这里恒为 true，界面不会显示授权入口。
      usageAccessAvailable: true,
      collectorRunning: _tracker.isRunning,
    );
  }
}

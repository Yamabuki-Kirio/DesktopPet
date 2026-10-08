import '../../activity_tracking/current_activity_provider.dart';
import '../overlay_pet.dart';

/// Android 的「当前前台应用」（Phase 4C-5.1A）。
///
/// 数据来自**原生共享快照**（`ForegroundAppRegistry`）：
/// * 原生侧唯一的检测任务（悬浮服务里的 1.5 秒轮询）负责更新它；
/// * 本实现只读快照，**不新增第二个 `UsageStatsManager` 轮询器**；
/// * 只有快照过期（>5 秒）时，原生才会补一次真正的检测 —— 因此
///   界面每秒刷新一次也不会造成高频系统查询（需求 §3.3）。
class AndroidCurrentActivityProvider implements CurrentActivityProvider {
  AndroidCurrentActivityProvider(
    this._overlay, {
    Duration interval = const Duration(seconds: 1),
  }) : _interval = interval;

  final AndroidOverlayPet _overlay;
  final Duration _interval;

  @override
  bool get isSupported => true;

  @override
  Future<CurrentActivity> current() => _overlay.currentActivity();

  @override
  Stream<CurrentActivity> watch() =>
      pollCurrentActivity(current, interval: _interval);
}

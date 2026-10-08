import 'models/activity_sample.dart';

/// 前台应用提供者。
///
/// 抽象成接口的目的：
/// 1. 单元测试可以注入固定序列，无需真的切换窗口；
/// 2. Android（Phase 4B 走 `UsageStatsManager`）可换实现而不动采集器与统计逻辑。
///
/// 平台实现放在各自目录：
/// * Windows：[Win32ForegroundAppProvider]（`activity_tracking/windows/win32_providers.dart`）；
/// * Android：Phase 4B 新增，本阶段只有 [UnavailableForegroundAppProvider]。
abstract interface class ForegroundAppProvider {
  /// 当前前台应用；无法获取时返回 null。
  ForegroundAppInfo? current();

  /// 该实现是否真的可用（不可用时采集器应停用而不是记录垃圾数据）。
  bool get isAvailable;
}

/// 永远返回 null 的实现（非 Windows 平台 / 原生库不可用时使用）。
class UnavailableForegroundAppProvider implements ForegroundAppProvider {
  const UnavailableForegroundAppProvider();

  @override
  ForegroundAppInfo? current() => null;

  @override
  bool get isAvailable => false;
}

/// 测试用：按脚本返回前台应用。
class ScriptedForegroundAppProvider implements ForegroundAppProvider {
  ScriptedForegroundAppProvider(this._script);

  /// 每个元素代表一次采样返回的应用；用尽后返回最后一个。
  /// 元素为 null 表示「无前台应用」。
  final List<ForegroundAppInfo?> _script;

  int _index = 0;

  @override
  ForegroundAppInfo? current() {
    if (_script.isEmpty) return null;
    final ForegroundAppInfo? value =
        _script[_index < _script.length ? _index : _script.length - 1];
    _index++;
    return value;
  }

  @override
  bool get isAvailable => true;
}

/// 用户空闲检测。
///
/// 平台实现：Windows 走 `GetLastInputInfo`（见 `windows/win32_providers.dart`）。
/// Android **没有**等价精度的全局输入空闲来源，因此 Phase 4A/4B 使用
/// [UnavailableIdleDetector]，并在统计口径上标记为"平台口径不同"。
abstract interface class IdleDetector {
  /// 距最后一次键盘 / 鼠标输入的时长。
  Duration idleTime();

  bool get isAvailable;
}

/// 永远返回「不空闲」的实现。
///
/// 不可用时宁可认为用户在场（会记录时间），也不要误判为离开而不记录——
/// 前者最多多记，后者会静默丢数据。
class UnavailableIdleDetector implements IdleDetector {
  const UnavailableIdleDetector();

  @override
  Duration idleTime() => Duration.zero;

  @override
  bool get isAvailable => false;
}

/// 测试用：可任意设定的空闲时长。
class FakeIdleDetector implements IdleDetector {
  FakeIdleDetector([this._idle = Duration.zero]);

  Duration _idle;

  void set(Duration idle) => _idle = idle;

  @override
  Duration idleTime() => _idle;

  @override
  bool get isAvailable => true;
}

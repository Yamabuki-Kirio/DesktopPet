/// 会话状态（锁屏 / 解锁）提供者。
///
/// 阶段 1 用轮询探测输入桌面，而不是注册 `WTSRegisterSessionNotification`：
/// 后者需要一个真实窗口句柄，会侵入 runner 的窗口实现；
/// 而采集本身已经是 2 秒轮询，探测成本极低且不需要改原生窗口代码。
///
/// 平台实现：Windows 见 `windows/win32_providers.dart`；
/// Android Phase 4B 会用 `KeyguardManager`，本阶段用 [UnavailableSessionStateProvider]。
abstract interface class SessionStateProvider {
  /// 是否处于锁屏 / 安全桌面。
  bool isLocked();

  bool get isAvailable;
}

/// 不可用时永远返回「未锁屏」。
///
/// 与空闲检测同理：宁可多记也不要静默丢数据；休眠由采样间隔突增兜住。
class UnavailableSessionStateProvider implements SessionStateProvider {
  const UnavailableSessionStateProvider();

  @override
  bool isLocked() => false;

  @override
  bool get isAvailable => false;
}

/// 测试用：可任意设定的锁定状态。
class FakeSessionStateProvider implements SessionStateProvider {
  FakeSessionStateProvider([this._locked = false]);

  bool _locked;

  void set(bool locked) => _locked = locked;

  @override
  bool isLocked() => _locked;

  @override
  bool get isAvailable => true;
}

/// 系统托盘抽象（需求「六、桌宠窗口」；Phase 4A 抽成接口）。
///
/// Windows 实现见 `platform/windows/windows_tray_service.dart`（基于 `tray_manager`）。
/// Android **没有系统托盘**，`PlatformServices` 直接返回 null，
/// 因此 Android 编译单元不会 import `tray_manager`。
abstract interface class TrayHost {
  bool get isReady;

  /// 初始化托盘图标与菜单。[iconPath] 指向打包进 assets 的图标文件。
  Future<void> initialize({required String iconPath});

  /// 同步「暂停 / 恢复记录」菜单文案。
  Future<void> refreshTrackingState(bool paused);

  Future<void> setTooltipText(String text);

  Future<void> dispose();
}

/// 托盘菜单项到宿主动作的回调集合。
///
/// 单独一个数据类而不是一堆构造参数：装配层只需要一次传完，
/// 平台实现也不必知道这些动作背后的业务含义。
class TrayCallbacks {
  const TrayCallbacks({
    required this.onTogglePet,
    required this.onTogglePanel,
    required this.onResetPosition,
    required this.onExit,
    required this.onToggleTracking,
    required this.onOpenUsageStats,
  });

  final Future<void> Function() onTogglePet;
  final Future<void> Function() onTogglePanel;
  final Future<void> Function() onResetPosition;
  final Future<void> Function() onExit;
  final Future<void> Function() onToggleTracking;
  final Future<void> Function() onOpenUsageStats;
}

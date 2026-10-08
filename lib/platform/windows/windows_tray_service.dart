import 'package:tray_manager/tray_manager.dart';

import '../../core/logger.dart';
import '../../desktop_window/tray_host.dart';

/// 系统托盘（Windows 实现，基于 `tray_manager`）。
///
/// 托盘菜单项：
/// - 显示 / 隐藏桌宠
/// - 显示 / 隐藏控制面板
/// - 打开使用统计
/// - 暂停 / 恢复记录
/// - 重置位置到屏幕右下角
/// - 退出
class WindowsTrayService with TrayListener implements TrayHost {
  WindowsTrayService({required TrayCallbacks callbacks}) : _callbacks = callbacks;

  final TrayCallbacks _callbacks;

  bool _ready = false;
  bool _trackingPaused = false;

  /// 菜单元数据，避免在回调里解析字符串。
  static const String keyTogglePet = 'petlife.togglePet';
  static const String keyTogglePanel = 'petlife.togglePanel';
  static const String keyResetPosition = 'petlife.resetPosition';
  static const String keyExit = 'petlife.exit';
  static const String keyToggleTracking = 'petlife.toggleTracking';
  static const String keyOpenUsageStats = 'petlife.openUsageStats';

  @override
  bool get isReady => _ready;

  @override
  Future<void> initialize({required String iconPath}) async {
    if (_ready) return;
    try {
      await trayManager.setIcon(iconPath);
      await trayManager.setToolTip('PetLife 桌宠');
      await _installMenu();
      trayManager.addListener(this);
      _ready = true;
      Loggers.window.info('系统托盘已就绪');
    } catch (e, st) {
      // 托盘失败不应阻止桌宠运行，只是少一个入口。
      Loggers.window.warning('系统托盘初始化失败（桌宠仍可使用）', e, st);
    }
  }

  Future<void> _installMenu() async {
    final Menu menu = Menu(
      items: <MenuItem>[
        MenuItem(key: keyTogglePet, label: '显示 / 隐藏桌宠'),
        MenuItem(key: keyTogglePanel, label: '显示 / 隐藏控制面板'),
        MenuItem.separator(),
        MenuItem(key: keyOpenUsageStats, label: '打开使用统计'),
        MenuItem(
          key: keyToggleTracking,
          label: _trackingPaused ? '恢复记录' : '暂停记录',
        ),
        MenuItem.separator(),
        MenuItem(key: keyResetPosition, label: '把桌宠移回屏幕右下角'),
        MenuItem.separator(),
        MenuItem(key: keyExit, label: '退出 PetLife'),
      ],
    );
    await trayManager.setContextMenu(menu);
  }

  /// 同步「暂停 / 恢复记录」菜单文案。
  ///
  /// 只在状态真的变化时重建菜单，避免每次采样都调用原生 API。
  @override
  Future<void> refreshTrackingState(bool paused) async {
    if (!_ready || _trackingPaused == paused) return;
    _trackingPaused = paused;
    try {
      await _installMenu();
    } catch (e, st) {
      Loggers.window.fine('刷新托盘菜单失败', e, st);
    }
  }

  @override
  Future<void> setTooltipText(String text) async {
    if (!_ready) return;
    try {
      await trayManager.setToolTip(text);
    } catch (_) {
      // 忽略。
    }
  }

  @override
  Future<void> dispose() async {
    if (!_ready) return;
    try {
      trayManager.removeListener(this);
      await trayManager.destroy();
    } catch (e, st) {
      Loggers.window.warning('托盘释放失败', e, st);
    }
    _ready = false;
  }

  // ---------------------------------------------------------------------------
  // TrayListener
  // ---------------------------------------------------------------------------

  @override
  void onTrayIconMouseDown() {
    // 左键单击 = 切换桌宠显示（与原生托盘惯例一致）。
    _guard(_callbacks.onTogglePet, 'onTrayIconMouseDown');
  }

  @override
  void onTrayIconRightMouseDown() {
    // 右键弹菜单。
    _guard(trayManager.popUpContextMenu, 'onTrayIconRightMouseDown');
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case keyTogglePet:
        _guard(_callbacks.onTogglePet, keyTogglePet);
      case keyTogglePanel:
        _guard(_callbacks.onTogglePanel, keyTogglePanel);
      case keyOpenUsageStats:
        _guard(_callbacks.onOpenUsageStats, keyOpenUsageStats);
      case keyToggleTracking:
        _guard(_callbacks.onToggleTracking, keyToggleTracking);
      case keyResetPosition:
        _guard(_callbacks.onResetPosition, keyResetPosition);
      case keyExit:
        Loggers.window.info('用户从系统托盘选择退出');
        _guard(_callbacks.onExit, keyExit);
      default:
        break;
    }
  }

  void _guard(Future<void> Function() action, String label) {
    action().catchError((Object e, StackTrace st) {
      Loggers.window.warning('托盘动作执行失败: $label', e, st);
    });
  }
}

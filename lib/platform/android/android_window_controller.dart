import 'dart:ui' show Size;

import '../../desktop_window/window_controller.dart';
import '../../settings/app_settings.dart';

/// Android 的"无原生窗口"实现。
///
/// Android 是普通应用形态：没有透明无边框置顶窗口、没有鼠标穿透、
/// 也没有需要程序化移动的窗口。因此所有窗口操作都是 **no-op**，
/// 但接口语义完整保留（返回值给安全默认：不可见位置返回 null、可见性返回 true）。
///
/// 这样 [AppServices] / 桌宠组件不必为平台写分支：
/// 它们照常调用窗口接口，只是这些调用在 Android 上什么也不做。
class HeadlessWindowController implements WindowController {
  HeadlessWindowController();

  bool _visible = true;
  bool _preventClose = false;
  void Function(double x, double y)? _onPosition;
  void Function()? _onClose;

  @override
  Future<void> initialize({required AppSettings settings}) async {}

  @override
  Future<void> applySettings(AppSettings settings) async {}

  @override
  Future<void> resizeForContent({
    required double contentWidth,
    required double contentHeight,
  }) async {}

  @override
  Future<void> resizeTo(Size size) async {}

  @override
  Future<void> setResizable(bool resizable) async {}

  @override
  Future<void> moveTo(double x, double y) async {
    // Android 上没有可移动的桌宠窗口；保留回调语义供未来悬浮窗复用。
    _onPosition?.call(x, y);
  }

  @override
  Future<({double x, double y})?> position() async => null;

  @override
  Future<void> setVisible(bool visible) async {
    _visible = visible;
  }

  @override
  Future<bool> isVisible() async => _visible;

  @override
  Future<void> setPreventClose(bool prevent) async {
    _preventClose = prevent;
  }

  /// Android 上"阻止关闭"无意义（返回键由系统处理），仅记录状态。
  bool get preventClose => _preventClose;

  @override
  void onPositionCommitted(void Function(double x, double y) callback) {
    _onPosition = callback;
  }

  @override
  void onCloseRequested(void Function() callback) {
    _onClose = callback;
  }

  /// Android 上没有程序化的窗口几何提交（无轮盘扩窗），no-op。
  @override
  void setExternalBoundsChangeActive(bool active) {}

  /// 供宿主在收到系统返回 / 退出请求时调用（当前未使用，保留接口对称性）。
  void requestClose() => _onClose?.call();

  /// Android 上没有"销毁窗口"这一步：进程退出即结束。
  @override
  Future<void> destroy() async {}

  @override
  Future<void> dispose() async {}
}

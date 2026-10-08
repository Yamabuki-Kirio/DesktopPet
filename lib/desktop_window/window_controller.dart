import 'dart:ui';

import '../settings/app_settings.dart';

/// 桌宠窗口控制抽象（需求「六、桌宠窗口」）。
///
/// 抽象的意义：阶段 4 的 Android 悬浮窗需要完全不同的实现，
/// 但「应用设置 / 显示隐藏 / 记忆位置」这些语义应当保持一致。
abstract interface class WindowController {
  /// 应用启动时初始化窗口（透明、无边框、置顶）。
  Future<void> initialize({required AppSettings settings});

  /// 把设置应用到窗口（置顶、鼠标穿透、尺寸、位置约束等）。
  Future<void> applySettings(AppSettings settings);

  /// 按缩放倍率与素材尺寸调整窗口大小。
  Future<void> resizeForContent({required double contentWidth, required double contentHeight});

  /// 直接设置窗口尺寸（控制面板模式使用）。
  Future<void> resizeTo(Size size);

  /// 是否允许用户拉伸窗口。桌宠模式必须关闭。
  Future<void> setResizable(bool resizable);

  /// 移动窗口到指定位置（会自动夹取到可见显示器范围内）。
  Future<void> moveTo(double x, double y);

  /// 当前窗口位置；失败返回 null。
  Future<({double x, double y})?> position();

  Future<void> setVisible(bool visible);

  Future<bool> isVisible();

  /// 是否阻止关闭按钮（关闭时隐藏到托盘而不是退出）。
  Future<void> setPreventClose(bool prevent);

  /// 关闭窗口（真正退出前调用）。
  Future<void> destroy();

  /// 用户拖动窗口结束的回调（用于记忆位置）。
  void onPositionCommitted(void Function(double x, double y) callback);

  /// 窗口被请求关闭的回调（用于「隐藏到托盘」）。
  void onCloseRequested(void Function() callback);

  /// 标记「程序化改窗口」区间（例如轮盘菜单展开 / 收起）。
  ///
  /// 该区间内的窗口移动 / 尺寸变化属于几何提交，**不得**被当成用户拖动
  /// 写回持久化位置 —— 否则菜单会把桌宠"记忆"到放大后的矩形。
  void setExternalBoundsChangeActive(bool active);

  Future<void> dispose();
}

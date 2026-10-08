/// 平台能力描述（Phase 4A）。
///
/// 这一层只描述"这个平台能不能做某件事"，**不引用任何平台专属库**：
/// 它是 UI 与装配层共用的唯一事实来源，避免到处写 `Platform.isWindows`。
///
/// 约定：能力为 false 时，调用方必须走**降级路径**（隐藏入口或使用替代实现），
/// 而不是"试一试，失败了再说"。
library;

/// 形态因子：决定使用哪套应用外壳。
enum FormFactor {
  /// 桌面（Windows）：桌宠窗口 + 托盘 + 控制面板。
  desktop,

  /// 移动（Android）：普通 Material 应用 + 底部导航。
  mobile,
}

/// 平台能力集合。
class PlatformCapabilities {
  const PlatformCapabilities({
    required this.platformName,
    required this.formFactor,
    required this.supportsWindowManagement,
    required this.supportsTray,
    required this.supportsSystemActivityTracking,
    required this.supportsPreciseIdleDetection,
    required this.supportsSystemProxyDetection,
    required this.supportsProcessDiagnostics,
    required this.supportsFloatingPet,
    required this.requiresUsageAccessPermission,
    required this.supportsFolderImport,
    required this.supportsLaunchAtStartup,
  });

  /// 上报给服务端的平台标识：`windows` / `android`。
  final String platformName;

  final FormFactor formFactor;

  /// 能否控制原生窗口（透明、无边框、置顶、鼠标穿透、尺寸）。
  final bool supportsWindowManagement;

  /// 是否有系统托盘。
  final bool supportsTray;

  /// 是否支持"自动采集系统前台应用使用时长"（Windows 阶段 1 / Android Phase 4B）。
  final bool supportsSystemActivityTracking;

  /// 是否有与 Windows `GetLastInputInfo` 等价的**精确空闲**来源。
  final bool supportsPreciseIdleDetection;

  /// 能否自动读取系统代理设置。
  final bool supportsSystemProxyDetection;

  /// 能否读取进程 CPU / 句柄等诊断指标。
  final bool supportsProcessDiagnostics;

  /// 是否支持系统级悬浮桌宠（Phase 4D，当前恒为 false）。
  final bool supportsFloatingPet;

  /// 是否需要用户手动授予"使用情况访问权限"（Android）。
  final bool requiresUsageAccessPermission;

  /// 素材导入是否支持"选择文件夹"。
  final bool supportsFolderImport;

  /// 能否注册"登录 Windows 后自动启动"（写 `HKCU\...\Run`）。
  ///
  /// Android 没有等价概念，恒为 false；界面据此**隐藏**该选项。
  final bool supportsLaunchAtStartup;

  bool get isDesktop => formFactor == FormFactor.desktop;
  bool get isMobile => formFactor == FormFactor.mobile;

  @override
  String toString() => 'PlatformCapabilities($platformName, $formFactor)';
}

import '../../activity_tracking/activity_tracker.dart';
import '../../activity_tracking/current_activity_provider.dart';
import '../../activity_tracking/foreground_app_provider.dart';
import '../../activity_tracking/idle_detector.dart';
import '../../activity_tracking/session_state_provider.dart';
import '../../core/logger.dart';
import '../../desktop_window/tray_host.dart';
import '../../desktop_window/window_controller.dart';
import '../../diagnostics/process_metrics.dart';
import '../../sync/credential_store_factory.dart';
import '../../sync/device_identity.dart';
import '../../sync/proxy/system_proxy.dart';
import '../../ui/pet/pet_host.dart';
import '../device_info_provider.dart';
import '../file_import_provider.dart';
import '../overlay_pet.dart';
import '../platform_capabilities.dart';
import '../platform_database.dart';
import '../platform_services_contract.dart';
import '../startup_registrar.dart';
import 'android_credential_store.dart';
import 'android_current_activity_provider.dart';
import 'android_database.dart';
import 'android_device_info.dart';
import 'android_file_import_provider.dart';
import 'android_overlay_pet.dart';
import 'android_window_controller.dart';

/// Android 平台装配。
///
/// Phase 4A 的能力边界（**不做什么**，与需求一致）：
/// * 不初始化 window_manager / tray_manager / screen_retriever；
/// * 不初始化 Win32 单实例互斥体、进程性能采样、鼠标穿透、窗口拖动缩放；
/// * **不采集应用使用时长**（那是 Phase 4B 的 `UsageStatsManager`），
///   因此所有采集提供者都是"不可用"实现，采集器据此不驱动桌宠状态；
/// * 不申请任何权限就能启动、登录、同步与查看已有统计
///   （Phase 4C 的悬浮窗权限只在你真的开启悬浮桌宠时才申请）。
class AndroidPlatformServices implements PlatformServices {
  AndroidPlatformServices();

  static const PlatformCapabilities _capabilities = PlatformCapabilities(
    platformName: 'android',
    formFactor: FormFactor.mobile,
    supportsWindowManagement: false,
    supportsTray: false,
    supportsSystemActivityTracking: false, // Phase 4B
    supportsPreciseIdleDetection: false,
    supportsSystemProxyDetection: false,
    supportsProcessDiagnostics: false,
    supportsFloatingPet: true, // Phase 4C：系统级悬浮桌宠（需用户授权 SYSTEM_ALERT_WINDOW）
    requiresUsageAccessPermission: true,
    supportsFolderImport: false, // 需要原生 SAF 目录通道，Phase 4B
    supportsLaunchAtStartup: false, // Android 没有"登录时启动"概念
  );

  DeviceEnvironment _device = DeviceEnvironment.detect();

  /// 悬浮桌宠桥是**无状态**的，创建一个复用即可（原生端只注册一次处理器）。
  late final AndroidOverlayPet _overlayPet = AndroidOverlayPetBridge();

  @override
  PlatformCapabilities get capabilities => _capabilities;

  @override
  DeviceEnvironment get device => _device;

  @override
  AndroidOverlayPet get overlayPet => _overlayPet;

  @override
  PlatformDatabase get database => const AndroidSqfliteDatabase();

  @override
  ProcessDiagnostics get processDiagnostics => const UnavailableProcessDiagnostics();

  @override
  CredentialStoreFactory get credentialStoreFactory =>
      const AndroidCredentialStoreFactory();

  @override
  SystemProxyReader get systemProxyReader => const UnavailableSystemProxyReader();

  @override
  FileImportProvider get fileImportProvider => const AndroidFileImportProvider();

  /// Android 没有"登录后自动启动"的等价机制，界面据此隐藏该选项。
  @override
  StartupRegistrar get startupRegistrar => const UnsupportedStartupRegistrar();

  @override
  Future<bool> prepareForStartup() async {
    await database.configure();

    // 补齐机型 / 系统版本（读不到也不阻塞启动）。
    _device = await const AndroidDeviceInfoProvider().detect();
    Loggers.app.info('设备环境：$_device');
    // Android 由系统按包名保证单实例，无需互斥体。
    return true;
  }

  @override
  WindowController createWindowController() => HeadlessWindowController();

  /// Android 没有系统托盘。
  @override
  TrayHost? createTrayHost({required TrayCallbacks callbacks}) => null;

  @override
  PetHost createPetHost({required WindowController windowController}) =>
      const NoopPetHost();

  @override
  ForegroundAppProvider createForegroundAppProvider() =>
      const UnavailableForegroundAppProvider();

  @override
  IdleDetector createIdleDetector() => const UnavailableIdleDetector();

  @override
  SessionStateProvider createSessionStateProvider() =>
      const UnavailableSessionStateProvider();

  /// 「当前前台应用」读**原生共享快照**（Phase 4C-5.1A）。
  ///
  /// 刻意不接收 `activityTracker`：Android 上 Dart 采集器不可用，
  /// 前台识别完全在原生侧（`ForegroundAppRegistry`）完成 ——
  /// 这正是"设置页与统计页显示同一个应用"的结构性保证。
  @override
  CurrentActivityProvider createCurrentActivityProvider({
    required ActivityTracker activityTracker,
  }) =>
      AndroidCurrentActivityProvider(_overlayPet);

  /// Android 的本地统计设备 ID：`DeviceIdentity` 持久化的稳定安装 UUID。
  ///
  /// 与 Windows（`desktop.local` 常量）分开，避免同一账户下
  /// Windows / Android 以及不同 Android 设备的使用记录混在一起（docs §12.1 第 9 条）。
  @override
  Future<String> resolveTrackingDeviceLocalId({
    required DeviceIdentity deviceIdentity,
  }) =>
      deviceIdentity.ensureDeviceLocalId();

  @override
  Future<String> resolveTrayIconPath() async => '';

  @override
  Future<void> dispose() async {}
}

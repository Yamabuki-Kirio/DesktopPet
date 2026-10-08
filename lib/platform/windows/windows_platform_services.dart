import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../activity_tracking/activity_tracker.dart';
import '../../activity_tracking/current_activity_provider.dart';
import '../../activity_tracking/foreground_app_provider.dart';
import '../../activity_tracking/idle_detector.dart';
import '../../activity_tracking/session_state_provider.dart';
import '../../activity_tracking/windows/win32_providers.dart';
import '../../core/constants.dart';
import '../../core/logger.dart';
import '../../desktop_window/tray_host.dart';
import '../../desktop_window/window_controller.dart';
import '../../sync/device_identity.dart';
import 'windows_current_activity_provider.dart';
import 'windows_window_controller.dart';
import 'win32_process_stats.dart';
import '../../sync/credential_store_factory.dart';
import 'winhttp_system_proxy.dart';
import '../../ui/pet/pet_host.dart';
import '../device_info_provider.dart';
import '../file_import_provider.dart';
import '../overlay_pet.dart';
import '../platform_capabilities.dart';
import '../platform_database.dart';
import '../platform_services_contract.dart';
import '../startup_registrar.dart';
import 'windows_credential_store_factory.dart';
import 'windows_database.dart';
import 'windows_file_import_provider.dart';
import 'windows_pet_host.dart';
import 'windows_single_instance.dart';
import 'windows_startup_registrar.dart';
import 'windows_tray_service.dart';

/// Windows 平台装配。
///
/// 这里是**所有** Windows 专属能力的唯一出口：Win32 采集、window_manager、
/// tray_manager、FFI 凭据、FFI SQLite、WinHTTP 代理探测、FFI 进程指标。
class WindowsPlatformServices implements PlatformServices {
  WindowsPlatformServices();

  static const PlatformCapabilities _capabilities = PlatformCapabilities(
    platformName: 'windows',
    formFactor: FormFactor.desktop,
    supportsWindowManagement: true,
    supportsTray: true,
    supportsSystemActivityTracking: true,
    supportsPreciseIdleDetection: true,
    supportsSystemProxyDetection: true,
    supportsProcessDiagnostics: true,
    supportsFloatingPet: false,
    requiresUsageAccessPermission: false,
    supportsFolderImport: true,
    supportsLaunchAtStartup: true,
  );

  DeviceEnvironment _device = DeviceEnvironment.detect();

  @override
  PlatformCapabilities get capabilities => _capabilities;

  @override
  DeviceEnvironment get device => _device;

  /// Windows 没有（也不需要）系统级悬浮窗 —— 桌宠本身就是独立窗口。
  /// 返回不支持实现，界面按 [PlatformCapabilities.supportsFloatingPet]
  /// 直接隐藏「悬浮桌宠」分区。
  @override
  AndroidOverlayPet get overlayPet => const UnsupportedOverlayPet();

  @override
  PlatformDatabase get database => const WindowsFfiDatabase();

  @override
  ProcessDiagnostics get processDiagnostics => const Win32ProcessDiagnostics();

  @override
  CredentialStoreFactory get credentialStoreFactory =>
      const WindowsCredentialStoreFactory();

  @override
  SystemProxyReader get systemProxyReader => const WinHttpSystemProxyReader();

  @override
  FileImportProvider get fileImportProvider => const WindowsFileImportProvider();

  @override
  StartupRegistrar get startupRegistrar => const WindowsStartupRegistrar();

  @override
  Future<bool> prepareForStartup() async {
    // 单实例互斥体必须最先判定：两个实例同时写 activity_segments 会把
    // 同一段时间记录两次，而且第二个实例打开 SQLite 也可能与第一个抢锁。
    final bool? single = WindowsSingleInstanceGuard.checkAtStartup();
    if (single == false) return false;

    await database.configure();

    // Windows 的 `dart:io` 已能给出完整设备信息，这里只是固化下来。
    _device = DeviceEnvironment.detect();
    Loggers.app.info('设备环境：$_device');
    return true;
  }

  @override
  WindowController createWindowController() => WindowsWindowController();

  @override
  TrayHost? createTrayHost({required TrayCallbacks callbacks}) =>
      WindowsTrayService(callbacks: callbacks);

  @override
  PetHost createPetHost({required WindowController windowController}) =>
      const WindowsPetHost();

  @override
  ForegroundAppProvider createForegroundAppProvider() =>
      win32ActivityNativeAvailable
          ? const Win32ForegroundAppProvider()
          : const UnavailableForegroundAppProvider();

  @override
  IdleDetector createIdleDetector() => win32ActivityNativeAvailable
      ? const Win32IdleDetector()
      : const UnavailableIdleDetector();

  @override
  SessionStateProvider createSessionStateProvider() => win32ActivityNativeAvailable
      ? const Win32SessionStateProvider()
      : const UnavailableSessionStateProvider();

  /// Windows 的「当前前台应用」= 现有采集器（**不新增第二个 Win32 轮询**）。
  @override
  CurrentActivityProvider createCurrentActivityProvider({
    required ActivityTracker activityTracker,
  }) =>
      WindowsCurrentActivityProvider(activityTracker);

  /// Windows 保持现有本地设备 ID（`desktop.local` 常量），本阶段不做数据迁移。
  @override
  Future<String> resolveTrackingDeviceLocalId({
    required DeviceIdentity deviceIdentity,
  }) async =>
      AppConstants.localDeviceId;

  /// 解析托盘图标路径。
  ///
  /// 打包后图标位于可执行文件同级的 `data/flutter_assets/assets/`；
  /// 开发期直接用工程内的 assets 目录。找不到时返回空串，
  /// 托盘初始化会失败但不会影响桌宠。
  @override
  Future<String> resolveTrayIconPath() async {
    const String relative = 'assets/tray_icon.ico';
    try {
      final String exeDir = p.dirname(Platform.resolvedExecutable);
      final String bundled = p.join(exeDir, 'data', 'flutter_assets', relative);
      if (File(bundled).existsSync()) return bundled;

      final Directory support = await getApplicationSupportDirectory();
      final String devPath = p.join(support.path, AppConstants.appDataFolder, relative);
      if (File(devPath).existsSync()) return devPath;
    } catch (e) {
      Loggers.window.warning('解析托盘图标路径失败', e);
    }
    return relative;
  }

  @override
  Future<void> dispose() async {}
}

/// `PlatformServices` 契约（Phase 4A）。
///
/// 这是"平台装配层"的唯一接口：所有平台专属能力（窗口、托盘、凭据、数据库、
/// 代理探测、进程诊断、活动采集提供者、文件选择）都从这里取。
///
/// 设计约束
/// --------
/// * 本文件**不得** import 任何平台专属库（win32 / window_manager / tray_manager /
///   screen_retriever / sqflite_common_ffi / flutter_secure_storage ...）；
/// * 上层（业务 / UI / 装配）只依赖这个接口，因此 Android 编译单元不会被迫
///   拉进 Windows 专属实现；
/// * 能力为 `false` 时必须走降级路径，而不是"调用后捕获异常"。
library;

import '../activity_tracking/activity_tracker.dart';
import '../activity_tracking/current_activity_provider.dart';
import '../activity_tracking/foreground_app_provider.dart';
import '../activity_tracking/idle_detector.dart';
import '../activity_tracking/session_state_provider.dart';
import '../desktop_window/tray_host.dart';
import '../desktop_window/window_controller.dart';
import '../diagnostics/process_metrics.dart';
import '../sync/credential_store_factory.dart';
import '../sync/device_identity.dart';
import '../sync/proxy/system_proxy.dart';
import '../ui/pet/pet_host.dart';
import 'device_info_provider.dart';
import 'file_import_provider.dart';
import 'overlay_pet.dart';
import 'platform_capabilities.dart';
import 'platform_database.dart';
import 'startup_registrar.dart';

abstract interface class PlatformServices {
  /// 平台能力（UI 与装配据此选择降级路径）。
  PlatformCapabilities get capabilities;

  /// 设备环境（登录 / 注册设备时上报）。
  DeviceEnvironment get device;

  /// 系统级悬浮桌宠（Android Phase 4C）。
  ///
  /// Windows 与桩实现一律返回 [UnsupportedOverlayPet] —— 因此任何平台都能
  /// 编译同一份装配代码，而**悬浮窗专属逻辑只存在于 Android 编译单元**。
  AndroidOverlayPet get overlayPet;

  /// 平台 SQLite 后端。
  PlatformDatabase get database;

  /// 进程资源诊断实现（Android 为不可用实现）。
  ProcessDiagnostics get processDiagnostics;

  /// 凭据存储工厂（Windows 三级降级 / Android Keystore）。
  CredentialStoreFactory get credentialStoreFactory;

  /// 系统代理读取器（Android 为不可用实现，使用应用内代理设置）。
  SystemProxyReader get systemProxyReader;

  /// 素材导入选择器。
  FileImportProvider get fileImportProvider;

  /// 开机自启注册器（Windows 真实写 `HKCU\...\Run`；Android 为不支持实现）。
  StartupRegistrar get startupRegistrar;

  /// 启动期平台准备。
  ///
  /// 返回值语义：
  /// * `true` → 可以继续启动；
  /// * `false` → **已有实例在运行，调用方应立刻退出**（Windows 单实例互斥体）。
  ///
  /// 同时负责：初始化 SQLite 后端、补齐设备信息（Android 机型 / 系统版本）。
  Future<bool> prepareForStartup();

  /// 创建窗口控制器（Android 返回空实现，不操作任何原生窗口）。
  WindowController createWindowController();

  /// 创建系统托盘；**该平台没有托盘时返回 null**（Android）。
  TrayHost? createTrayHost({required TrayCallbacks callbacks});

  /// 创建桌宠宿主机。
  PetHost createPetHost({required WindowController windowController});

  /// 前台应用提供者（Windows 为 Win32；Android Phase 4A 为不可用实现）。
  ForegroundAppProvider createForegroundAppProvider();

  /// 空闲检测（Android 无等价精度来源，用不可用实现并标记平台口径）。
  IdleDetector createIdleDetector();

  /// 会话（锁屏）状态提供者。
  SessionStateProvider createSessionStateProvider();

  /// 「当前前台应用」提供者（Phase 4C-5.1A）。
  ///
  /// * Windows：跟随现有 Dart 采集器（不新增 Win32 轮询）；
  /// * Android：读原生共享快照（不新增 `UsageStatsManager` 轮询）；
  /// * 桩实现：返回"不支持"，界面走降级文案。
  CurrentActivityProvider createCurrentActivityProvider({
    required ActivityTracker activityTracker,
  });

  /// 本机使用统计使用的**本地设备 ID**（Phase 4C-5.1A）。
  ///
  /// * Android：`DeviceIdentity` 生成并持久化的稳定安装 UUID（重启不变、每台设备唯一）；
  /// * Windows：保持现有常量 `AppConstants.localDeviceId`（本阶段不做数据迁移）。
  ///
  /// 为什么把 [deviceIdentity] 作为参数传进来：它需要已经打开的数据库，
  /// 而平台装配层不持有数据库句柄 —— 由装配方（AppScope）注入，
  /// **平台分支仍然留在平台层**，调用方不做 `if (Platform.isAndroid)`。
  ///
  /// 注意：这是**本地统计口径**的标识，与服务端注册设备 ID（`X-Device-Id`）不是同一个东西，
  /// 不要混用（见 docs/35 §12.2）。
  Future<String> resolveTrackingDeviceLocalId({
    required DeviceIdentity deviceIdentity,
  });

  /// 解析托盘图标路径（Android 返回空串，因为没有托盘）。
  Future<String> resolveTrayIconPath();

  /// 释放平台资源（Android 用于释放安全存储句柄等）。
  Future<void> dispose();
}

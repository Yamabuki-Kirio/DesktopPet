# 25 - Phase 4 Android 总体架构

> 本文只描述**已经实施并验证**的内容：Phase 4A（Android 工程与跨平台基础）。
> Phase 4B / 4C / 4D 尚未实施，文中一律显式标注"未实现"。

## 1. 目标与范围

Phase 4A 的目标是让 Android 成为"**可以安装、打开、登录并同步的普通应用**"：

| 能力 | Phase 4A 状态 |
|---|---|
| Android 工程与构建隔离（官方模板版本矩阵 + 镜像下载源） | ✅ 已实现 |
| 平台编译隔离（Android 不依赖 Win32 / 桌面插件） | ✅ 已实现 |
| SQLite / 设备信息 / 文件导入的平台适配 | ✅ 已实现 |
| Android Material 应用外壳（底部导航五页） | ✅ 已实现 |
| 登录、设备注册、手动同步、查看已有统计 | ✅ 复用既有 Phase 2/3 能力 |
| 安全凭据存储（Android Keystore） | ✅ 已实现（原生 MethodChannel + AES/GCM，见 docs/26 §4） |
| Debug APK 产出 | ✅ 已产出（`build/app/outputs/flutter-apk/app-debug.apk`，见 docs/28 §2） |
| 真机安装与人工验收 | ⏳ 未执行（本机无设备 / 无可用模拟器，见 docs/29 §4.0） |
| 应用使用时长采集（`UsageStatsManager`） | ❌ **未实现**（Phase 4B） |
| 应用内桌宠的状态化打磨 | ❌ **未实现**（Phase 4C，本阶段仅有基础展示） |
| 系统悬浮窗桌宠 | ❌ **未实现**（Phase 4D） |
| iOS | ❌ 不做（需求明确第一阶段只支持 Android） |

## 2. 目录结构

```
lib/
  platform/                      # 平台装配层（Phase 4A 新增）
    platform_capabilities.dart   # 能力表（不依赖任何平台库）
    platform_services_contract.dart  # PlatformServices 契约
    platform_services.dart       # 句柄 + 条件导入工厂
    platform_services_io.dart    # 装配点：Windows / Android 二选一
    platform_services_stub.dart  # 非 IO 平台占位
    device_info_provider.dart    # DeviceEnvironment（中立数据类）
    platform_database.dart       # PlatformDatabase 接口
    file_import_provider.dart    # 文件 / 文件夹选择接口
    startup_registrar.dart       # 开机自启接口 + 不支持实现（Windows 专属能力的中立抽象）
    windows/                     # ← 所有桌面专属实现
      windows_platform_services.dart
      windows_database.dart            # sqflite_common_ffi
      windows_credential_store_factory.dart  # Credential Manager → DPAPI → 内存
      win32_credential_native.dart
      dpapi_file_credential_store.dart
      windows_window_controller.dart   # window_manager
      windows_pet_host.dart            # window_manager 拖动
      windows_tray_service.dart        # tray_manager
      winhttp_system_proxy.dart        # WinHTTP 系统代理
      win32_process_stats.dart         # FFI 进程指标
      windows_single_instance.dart     # Win32 命名互斥体
      windows_startup_registrar.dart   # HKCU\...\Run 开机自启（FFI）
      windows_file_import_provider.dart
      display_topology.dart            # screen_retriever
    android/                     # ← Android 专属实现
      android_platform_services.dart
      android_database.dart            # sqflite（系统 SQLite）
      android_credential_store.dart    # 工厂：固定选 Keystore 后端
      android_keystore_credential_store.dart  # Keystore 后端的 Dart 侧（MethodChannel）
      android_device_info.dart         # device_info_plus
      android_window_controller.dart   # Headless（no-op）
      android_file_import_provider.dart

  activity_tracking/
    foreground_app_provider.dart   # 接口 + Unavailable + 测试替身
    idle_detector.dart
    session_state_provider.dart
    windows/                       # ← Win32 实现（原 win32/ 目录已合并到此处）
      win32_activity_native.dart
      win32_providers.dart
    android/                       # ← Phase 4B 采集实现的位置（当前为空）

  ui/
    desktop/                       # 桌面外壳
      desktop_shell.dart           # 桌宠窗口 ⇄ 控制面板
      control_panel.dart           # 七页签控制面板
    mobile/                        # Android 外壳
      mobile_shell.dart            # 底部导航五页
      mobile_platform_notice.dart  # 平台能力说明（可单测的展示组件）
    pet/                           # 两端共用的桌宠渲染组件

android/app/src/main/kotlin/asia/akechi/petlife/   # ← Android 原生侧（只被 Android 构建编译）
  MainActivity.kt                  # 注册 asia.akechi.petlife/credential_store
  PetLifeCredentialStore.kt        # AndroidKeyStore + AES/GCM/NoPadding
```

## 3. PlatformServices：平台的唯一入口

`PlatformServices` 是"平台装配层"的接口，业务、UI 与装配代码只依赖它：

| 成员 | Windows | Android |
|---|---|---|
| `capabilities` | 桌面能力全开 | 仅移动端能力（见 §4） |
| `device` | `windows` / `x64` / 主机名 | `android` / `arm64-v8a` 等 / 机型 |
| `database` | `sqflite_common_ffi` | `sqflite`（`android.database.sqlite`） |
| `processDiagnostics` | Win32 FFI 指标 | 不可用实现 |
| `credentialStoreFactory` | Credential Manager → DPAPI → 内存 | **Android Keystore（AES/GCM）**，不降级内存 |
| `systemProxyReader` | WinHTTP + 注册表 | 不可用（用应用内代理设置） |
| `fileImportProvider` | 文件夹 + ZIP | 仅 ZIP（SAF） |
| `startupRegistrar` | `HKCU\...\Run` 开机自启（FFI） | 不支持实现（Android 无此概念） |
| `prepareForStartup()` | 单实例互斥体 + FFI SQLite + 设备信息 | SQLite 后端 + 设备信息（幂等） |
| `createWindowController()` | `WindowsWindowController` | `HeadlessWindowController`（no-op） |
| `createTrayHost()` | `WindowsTrayService` | **null**（没有托盘） |
| `createPetHost()` | `WindowsPetHost`（拖动窗口） | `NoopPetHost` |
| 采集提供者 | Win32 三个提供者 | 三个"不可用"实现 |

## 4. 能力表（PlatformCapabilities）

能力为 `false` 时，调用方**必须走降级路径**（隐藏入口或换实现），而不是"调用后捕获异常"。

| 能力 | Windows | Android（Phase 4A） |
|---|---|---|
| `formFactor` | desktop | mobile |
| `supportsWindowManagement` | ✅ | ❌ |
| `supportsTray` | ✅ | ❌ |
| `supportsSystemActivityTracking` | ✅ | ❌（Phase 4B） |
| `supportsPreciseIdleDetection` | ✅ | ❌（无等价来源，见 docs/27） |
| `supportsSystemProxyDetection` | ✅ | ❌ |
| `supportsProcessDiagnostics` | ✅ | ❌ |
| `supportsFloatingPet` | ❌ | ✅（Phase 4C：系统级悬浮窗，需用户授权 `SYSTEM_ALERT_WINDOW`） |
| `requiresUsageAccessPermission` | ❌ | ✅（Phase 4B 才使用） |
| `supportsFolderImport` | ✅ | ❌（需原生 SAF 目录通道） |
| `supportsLaunchAtStartup` | ✅（写 `HKCU\...\Run`） | ❌（Android 无"登录时启动"概念，界面隐藏该选项） |

## 5. 平台隔离：做到了什么、做不到什么

### 5.1 做不到的：编译期按平台排除

Dart 的条件导入只能按**库是否存在**（`dart.library.*`）判断，而 Windows 与 Android
**都是 `dart.library.io`**。因此在一个单入口的 Flutter 工程里，**无法**在编译期把
Windows 代码整体排除出 Android 构建（业界通用做法也是如此）。

### 5.2 做到的：模块边界 + 静态契约

隔离落在**模块边界**上，并且由 `test/platform_isolation_test.dart` 静态固化：

1. 桌面专属实现（`package:window_manager` / `package:tray_manager` /
   `package:screen_retriever` / `package:ffi`、以及 `win32_*` / `windows_*` /
   `display_topology.dart` 等文件）**只允许**出现在：
   * `lib/platform/windows/**`
   * `lib/ui/desktop/**`
   * `lib/activity_tracking/windows/**`
   * 两个装配点：`lib/platform/platform_services_io.dart`、`lib/app/app_shell.dart`
2. `Platform.isWindows` / `Platform.isAndroid` **只允许**出现在 `lib/platform/**`
   （即全工程没有任何"散落的平台分支"）。
3. Android 编译单元（`lib/platform/android/**`、`lib/ui/mobile/**`）不得出现上述任何特征串。
4. Android 只声明 `INTERNET` 权限；不得出现 `PACKAGE_USAGE_STATS` / `SYSTEM_ALERT_WINDOW`。

> 为什么这条测试很重要：模块边界只能靠约定维持，而这个测试把约定变成会失败的断言。
> 一旦有人在 `ui/mobile/` 里 `import 'package:window_manager/...'`，CI 立刻红。

### 5.3 中立接口清单

| 接口 | 文件 | 桌面实现 | Android 实现 |
|---|---|---|---|
| `WindowController`（WindowHost） | `desktop_window/window_controller.dart` | `windows_window_controller.dart` | `HeadlessWindowController` |
| `TrayHost` | `desktop_window/tray_host.dart` | `windows_tray_service.dart` | ——（null） |
| `PetHost` | `ui/pet/pet_host.dart` | `WindowsPetHost` | `NoopPetHost` |
| `CredentialStoreFactory` | `sync/credential_store_factory.dart` | `WindowsCredentialStoreFactory` | `AndroidCredentialStoreFactory`（→ `AndroidKeystoreCredentialStore`） |
| `PlatformDatabase` | `platform/platform_database.dart` | `WindowsFfiDatabase` | `AndroidSqfliteDatabase` |
| `SystemProxyReader` | `sync/proxy/system_proxy.dart` | `WinHttpSystemProxyReader` | `UnavailableSystemProxyReader` |
| `ProcessDiagnostics` | `diagnostics/process_metrics.dart` | `Win32ProcessDiagnostics` | `UnavailableProcessDiagnostics` |
| `ForegroundAppProvider` / `IdleDetector` / `SessionStateProvider` | `activity_tracking/*.dart` | `activity_tracking/windows/` | 不可用实现（Phase 4B 换实现） |
| `FileImportProvider` | `platform/file_import_provider.dart` | 文件夹 + ZIP | 仅 ZIP |
| `StartupRegistrar` | `platform/startup_registrar.dart` | `windows_startup_registrar.dart`（HKCU Run） | `UnsupportedStartupRegistrar` |

## 6. 启动流程（两端同一段代码）

```
main()
  └─ WidgetsFlutterBinding.ensureInitialized()
  └─ platformServices.prepareForStartup()
        Windows: Win32 单实例互斥体 → 若已有实例 → exit(0)
                 sqfliteFfiInit() + databaseFactory = ffi
                 DeviceEnvironment.detect()
        Android: database.configure()（no-op）
                 device_info_plus 补齐机型 / 系统版本
  └─ ErrorHandler.install()
  └─ AppServices.bootstrap(platform:)
        1. Ids.assertNamespaceValid()
        2. AppPaths.initialize()（Android 走应用私有目录）
        3. AppLog.initialize()
        4. platform.prepareForStartup()（幂等）+ DeviceIdentity.configureEnvironment()
        5. AppDatabase.open()（后端由平台决定，Schema / 迁移完全共用）
        6. 仓储 / 素材 / 设置 / 状态引擎 / 采集器 / 同步引擎
        6.5 开机自启对齐：偏好为"开启"时按当前 exe 重写 HKCU Run 项
            （发布目录被移动后路径自动修正；Android 上是空操作）
        7. trayHost = platform.createTrayHost()（Android 为 null）
  └─ runApp(PetLifeApp)
        AppShell 选择器：capabilities.isMobile ? MobileShell : DesktopShell
```

## 7. 两端外壳

| | DesktopShell | MobileShell |
|---|---|---|
| 形态 | 桌宠窗口（透明无边框置顶）⇄ 控制面板窗口 | 普通 Material 应用 + 底部导航 |
| 导航 | 七页签 TabBar（素材库 / 映射 / 调试器 / 使用统计 / 账户与同步 / 诊断 / 设置） | 底部导航五页（桌宠 / 使用统计 / 账户与同步 / 素材库 / 设置） |
| 桌宠 | 独立窗口，`window_manager` 拖动 | 页面内展示（`PetView` + `manageWindowSize: false`） |
| 托盘 | 有（显示隐藏 / 统计 / 暂停记录 / 退出） | 无 |

Android 比需求多了一个「素材库」页：没有它就无法导入素材，桌宠页会永远是占位图。

## 8. 复用了什么（没有第二套实现）

* **同步协议**：`AuthenticatedApi` / `SyncEngine` / outbox / 增量拉取，两端完全同一份代码；
* **数据库 Schema 与迁移**：`database/schema.dart` 是唯一来源，平台只决定"用哪个原生库打开"；
* **统计口径**：`UsageAnalyticsService` 与服务端 `stats_service` 均未改动；
* **桌宠渲染**：`PetRenderer` / `PetFrameController` / `PetView` / 状态引擎与状态映射全部复用，
  两端只换宿主（窗口 vs 页面）。

## 9. 与 Windows 的关系（不回归的保证）

* Windows 的行为逐项保持：FFI SQLite、Credential Manager/DPAPI 三级降级、WinHTTP 代理探测、
  Win32 采集、托盘、桌宠窗口拖动与鼠标穿透，均为**原实现搬位置**，逻辑未改；
* 两处有意的行为变化（都已记录在 docs/29）：
  1. `PetView` 不再直接调用 `window_manager`，改由 `PetHost` 注入；
     控制面板里的"实时预览"因此不再能拖动真实窗口（此前会误拖）。
  2. `DeviceRegistration.modelName` 在 Windows 上仍为 null（与 Phase 2 一致），
     Android 上会带上机型。

## 10. 明确的未完成项

* **真机安装与 16 步人工验收**：本机没有 Android 设备，也无法启动模拟器
  （无 AVD / 无系统镜像 / WHPX 处于 Disabled），因此"安装、启动、登录、
  注册为独立设备、重启后仍登录、手动同步"这 6 条**尚未在本机验证**，
  步骤见 docs/29 §4；
* **服务端测试全绿**：1 项既有用例（`test_tool_stops_working_after_key_revoked`）
  因"灌数据用 UTC 零点、查询用本地时区"的缺陷，在本地时间 00:00–08:00 必失败，
  见 docs/29 §3.5（**与本阶段改动无关**）；
* **Release APK 与正式签名**：release 仍用 debug 签名，**不可上架**，见 docs/28 §5；
* **Phase 4B**：`UsageStatsManager` 采集、授权引导、前台服务与通知、事件切段、
  崩溃恢复、Android 空闲指标口径；
* **Phase 4C**：应用内桌宠的完整交互（缩放 / 拖动 / 素材选择 / 状态驱动打磨）；
* **Phase 4D**：系统悬浮窗桌宠；
* **Android 文件夹导入**：需要 Kotlin 侧 `ACTION_OPEN_DOCUMENT_TREE` + 把 SAF 树复制到应用私有目录
  （Phase 4A 已具备写原生通道的能力，可直接沿用本轮的 MethodChannel 骨架）；
* **整壳 Widget 测试**：`MobileShell` 会启动采集定时器与同步引擎并在构建期读数据库，
  与 `testWidgets` 的 fake-async / pending-timer 契约冲突；本阶段改为测试可独立覆盖的
  展示组件（`MobilePlatformNotice`）与能力表，整壳联调放在真机验收步骤（docs/29 §4）。


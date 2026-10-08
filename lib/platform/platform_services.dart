/// 平台服务装配入口（Phase 4A）。
///
/// 条件导入说明
/// ------------
/// `dart.library.io` 为真时使用 `platform_services_io.dart`（Windows / Android
/// 都走它），否则使用 stub（Web 等无 IO 平台，本项目不支持但仍保持可编译）。
///
/// 为什么不用"条件导入区分 Windows 与 Android"：Dart 的条件导入只能按
/// **库是否存在**（`dart.library.*`）判断，Windows 与 Android 都是 `dart.library.io`，
/// 无法在编译期区分。因此真正的隔离落在**模块边界**上：
/// * `platform/android/**`、`activity_tracking/android/**`、`ui/mobile/**`
///   这些"Android 编译单元"永远不 import Win32 / window_manager / tray_manager；
/// * 只有本文件与 `platform_services_io.dart`（装配点）同时认识两个平台；
/// * 该约束由 `test/platform_isolation_test.dart` 静态检查。
library;

import 'platform_services_contract.dart';
import 'platform_services_stub.dart' if (dart.library.io) 'platform_services_io.dart' as impl;

export 'platform_services_contract.dart';

/// 创建当前平台的服务实现。
PlatformServices createPlatformServices() => impl.createPlatformServices();

PlatformServices? _instance;

/// 进程内当前的平台服务（惰性创建）。
///
/// 惰性创建让"没有 bootstrap 的单元测试"也能拿到正确的平台后端
/// （例如 `AppDatabase.open` 直接取平台 SQLite），无需额外初始化。
PlatformServices get platformServices => _instance ??= createPlatformServices();

/// 覆盖平台服务（测试专用）。
void setPlatformServicesForTest(PlatformServices services) => _instance = services;

/// 清除覆盖（测试专用）。
void resetPlatformServicesForTest() => _instance = null;

/// 是否已经显式设置过（诊断用）。
bool get hasPlatformServices => _instance != null;

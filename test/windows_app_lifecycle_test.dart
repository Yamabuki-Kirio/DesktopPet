import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common/sqlite_api.dart' as sqflite;

import 'package:petlife/app/app_scope.dart';
import 'package:petlife/activity_tracking/activity_tracker.dart';
import 'package:petlife/activity_tracking/current_activity_provider.dart';
import 'package:petlife/activity_tracking/foreground_app_provider.dart';
import 'package:petlife/activity_tracking/idle_detector.dart';
import 'package:petlife/activity_tracking/session_state_provider.dart';
import 'package:petlife/asset_import/import_models.dart';
import 'package:petlife/core/logger.dart';
import 'package:petlife/core/paths.dart';
import 'package:petlife/database/storage_preflight.dart';
import 'package:petlife/desktop_window/tray_host.dart';
import 'package:petlife/desktop_window/window_controller.dart';
import 'package:petlife/diagnostics/process_metrics.dart';
import 'package:petlife/platform/app_lifecycle.dart';
import 'package:petlife/platform/device_info_provider.dart';
import 'package:petlife/platform/file_import_provider.dart';
import 'package:petlife/platform/overlay_pet.dart';
import 'package:petlife/platform/platform_capabilities.dart';
import 'package:petlife/platform/platform_database.dart';
import 'package:petlife/platform/platform_services_contract.dart';
import 'package:petlife/platform/startup_registrar.dart';
import 'package:petlife/sync/credential_store.dart';
import 'package:petlife/sync/credential_store_factory.dart';
import 'package:petlife/sync/device_identity.dart';
import 'package:petlife/sync/proxy/system_proxy.dart';
import 'package:petlife/ui/pet/pet_host.dart';
import 'package:petlife/platform/windows/windows_app_lifecycle.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('WindowsAppLifecycleBridge（唤醒 / 退出协作通道）', () {
    const MethodChannel channel = MethodChannel(appLifecycleChannelName);
    final List<MethodCall> nativeReceived = <MethodCall>[];

    setUp(() {
      nativeReceived.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        nativeReceived.add(call);
        return null;
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    WindowsAppLifecycleBridge createBridge() => WindowsAppLifecycleBridge();

    Future<void> deliverFromNative(String method, [Object? args]) {
      final StandardMethodCodec codec = const StandardMethodCodec();
      return TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .handlePlatformMessage(
        appLifecycleChannelName,
        codec.encodeMethodCall(MethodCall(method, args)),
        (ByteData? data) {},
      );
    }

    test('第二实例唤醒信号转发到 onSecondInstanceWake', () async {
      int wakes = 0;
      final WindowsAppLifecycleBridge bridge = createBridge();
      await bridge.initialize(AppLifecycleHandlers(
        onSecondInstanceWake: () async => wakes++,
        onExitRequested: (_) async => fail('不应触发退出'),
      ));

      await deliverFromNative('onSecondInstance');

      expect(wakes, 1);
    });

    test('退出请求携带 reason，系统会话结束映射为 system-session-end', () async {
      final List<String> reasons = <String>[];
      final WindowsAppLifecycleBridge bridge = createBridge();
      await bridge.initialize(AppLifecycleHandlers(
        onSecondInstanceWake: () async {},
        onExitRequested: (String reason) async => reasons.add(reason),
      ));

      await deliverFromNative(
          'onExitRequested', <String, Object?>{'reason': 'shutdown-request'});
      await deliverFromNative('onSystemSessionEnd');

      expect(reasons, <String>['shutdown-request', 'system-session-end']);
    });

    test('markShuttingDown / markShutdownComplete 发送到原生且失败静默', () async {
      final WindowsAppLifecycleBridge bridge = createBridge();
      await bridge.initialize(AppLifecycleHandlers(
        onSecondInstanceWake: () async {},
        onExitRequested: (_) async {},
      ));

      await bridge.markShuttingDown();
      await bridge.markShutdownComplete();
      expect(nativeReceived.map((MethodCall c) => c.method).toList(),
          <String>['markShuttingDown', 'shutdownComplete']);

      // 通道彻底不可用时也不抛（退出事务不受影响）。
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              channel,
              (MethodCall call) async =>
                  throw PlatformException(code: 'gone'));
      await bridge.markShuttingDown();
    });
  });

  group('bootstrap 门禁（规格§四/§九：第二实例与 SQLite 失败）', () {
    late Directory tempRoot;

    setUp(() async {
      AppServices.resetForTest();
      AppPaths.resetForTest();
      tempRoot = await Directory.systemTemp.createTemp('petlife_gate_');
      await AppLog.dispose();
    });

    tearDown(() async {
      AppServices.resetForTest();
      AppPaths.resetForTest();
      await AppLog.dispose();
      try {
        await tempRoot.delete(recursive: true);
      } catch (_) {}
    });

    test('已有实例在运行（prepareForStartup=false）：不触发数据库工厂、不建窗口托盘',
        () async {
      final GateFakePlatform platform = GateFakePlatform(
        platformName: 'windows',
        prepareResult: false,
      );

      await expectLater(
        AppServices.bootstrap(platform: platform, dataRoot: tempRoot),
        throwsA(isA<StateError>()),
      );

      expect(platform.databaseOpenCalls, 0,
          reason: '第二实例绝不能触发数据库工厂');
      expect(platform.windowControllerCreated, isFalse);
      expect(platform.trayHostCreated, isFalse);
    });

    test('SQLite 打开失败：映射为存储预检失败，且不继续创建窗口和托盘', () async {
      final GateFakePlatform platform = GateFakePlatform(
        platformName: 'windows',
        prepareResult: true,
        failDatabaseOpen: true,
      );

      await expectLater(
        AppServices.bootstrap(platform: platform, dataRoot: tempRoot),
        throwsA(isA<StoragePreflightFailure>()),
      );

      expect(platform.windowControllerCreated, isFalse,
          reason: 'SQLite 初始化失败不继续创建窗口');
      expect(platform.trayHostCreated, isFalse,
          reason: 'SQLite 初始化失败不继续创建托盘');
      expect(platform.databaseOpenCalls, 1);
    });
  });
}

/// 门禁测试用的最小平台桩：所有 create* 都不应在失败路径上被调用。
class GateFakePlatform implements PlatformServices {
  GateFakePlatform({
    required this.platformName,
    required this.prepareResult,
    this.failDatabaseOpen = false,
  });

  final String platformName;
  final bool prepareResult;
  final bool failDatabaseOpen;

  int databaseOpenCalls = 0;
  bool windowControllerCreated = false;
  bool trayHostCreated = false;

  @override
  PlatformCapabilities get capabilities => PlatformCapabilities(
        platformName: platformName,
        formFactor: FormFactor.desktop,
        supportsWindowManagement: true,
        supportsTray: true,
        supportsSystemActivityTracking: false,
        supportsPreciseIdleDetection: false,
        supportsSystemProxyDetection: false,
        supportsProcessDiagnostics: false,
        supportsFloatingPet: false,
        requiresUsageAccessPermission: false,
        supportsFolderImport: false,
        supportsLaunchAtStartup: false,
      );

  @override
  DeviceEnvironment get device => DeviceEnvironment.detect();

  @override
  AndroidOverlayPet get overlayPet => const UnsupportedOverlayPet();

  @override
  PlatformDatabase get database => _GateFakeDatabase(
        openCalls: () => databaseOpenCalls++,
        fail: failDatabaseOpen,
      );

  @override
  ProcessDiagnostics get processDiagnostics => UnavailableProcessDiagnostics();

  @override
  CredentialStoreFactory get credentialStoreFactory =>
      const _PubFakeCredFactory();

  @override
  SystemProxyReader get systemProxyReader => UnavailableSystemProxyReader();

  @override
  FileImportProvider get fileImportProvider => _PubFakeFileImport();

  @override
  StartupRegistrar get startupRegistrar => const UnsupportedStartupRegistrar();

  @override
  AppLifecycleBridge? get appLifecycleBridge => null;

  @override
  Future<bool> prepareForStartup() async => prepareResult;

  @override
  WindowController createWindowController() {
    windowControllerCreated = true;
    throw UnimplementedError('失败路径不应创建窗口控制器');
  }

  @override
  TrayHost? createTrayHost({required TrayCallbacks callbacks}) {
    trayHostCreated = true;
    throw UnimplementedError('失败路径不应创建托盘');
  }

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

  @override
  CurrentActivityProvider createCurrentActivityProvider({
    required ActivityTracker activityTracker,
  }) =>
      const UnsupportedCurrentActivityProvider();

  @override
  Future<String> resolveTrackingDeviceLocalId({
    required DeviceIdentity deviceIdentity,
  }) async =>
      'desktop.test';

  @override
  Future<String> resolveTrayIconPath() async => '';

  @override
  Future<void> dispose() async {}
}

class _PubFakeCredFactory implements CredentialStoreFactory {
  const _PubFakeCredFactory();

  @override
  Future<CredentialStore> create({required Directory fallbackDirectory}) =>
      throw UnimplementedError('失败路径不应创建凭据后端');
}

class _PubFakeFileImport implements FileImportProvider {
  @override
  bool get supportsFolderImport => false;

  @override
  Future<String?> pickFolderPath() async => null;

  @override
  Future<PickedZip?> pickZip() async => null;

  @override
  Future<ImagePickResult?> pickImages({required bool allowMultiple}) async =>
      null;
}

class _GateFakeDatabase implements PlatformDatabase {
  _GateFakeDatabase({required this.openCalls, required this.fail});

  final void Function() openCalls;
  final bool fail;

  @override
  String get backendName => 'gate-fake';

  @override
  Future<void> configure() async {}

  @override
  Future<sqflite.Database> open(
    String path, {
    required sqflite.OpenDatabaseOptions options,
  }) async {
    openCalls();
    if (fail) {
      throw const FileSystemException('模拟：SQLite 打开失败（只读或锁定）');
    }
    throw UnimplementedError('门禁测试不真正打开数据库');
  }
}

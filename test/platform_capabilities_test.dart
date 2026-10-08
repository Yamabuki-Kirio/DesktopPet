import 'package:flutter_test/flutter_test.dart';
import 'package:petlife/desktop_window/tray_host.dart';
import 'package:petlife/platform/android/android_platform_services.dart';
import 'package:petlife/platform/platform_capabilities.dart';
import 'package:petlife/platform/windows/windows_platform_services.dart';
import 'package:petlife/ui/pet/pet_host.dart';

/// Phase 4A：平台能力检测。
///
/// 能力表是 UI 与装配层**唯一**的事实来源：能力为 false 时必须走降级路径。
/// 这些断言把"Android 不做哪些事"固化成可执行契约，避免以后有人顺手
/// 在 Android 上打开一个本阶段不该有的能力。
void main() {
  group('Android 能力（Phase 4A）', () {
    final AndroidPlatformServices android = AndroidPlatformServices();
    final PlatformCapabilities caps = android.capabilities;

    test('平台标识与形态', () {
      expect(caps.platformName, 'android');
      expect(caps.formFactor, FormFactor.mobile);
      expect(caps.isMobile, isTrue);
      expect(caps.isDesktop, isFalse);
    });

    test('不提供桌面专属能力（窗口 / 托盘 / 代理探测 / 进程指标）', () {
      expect(caps.supportsWindowManagement, isFalse);
      expect(caps.supportsTray, isFalse);
      expect(caps.supportsSystemProxyDetection, isFalse);
      expect(caps.supportsProcessDiagnostics, isFalse);
    });

    test('Phase 4A 不采集使用时长，也没有精确空闲来源', () {
      expect(caps.supportsSystemActivityTracking, isFalse,
          reason: '采集是 Phase 4B 的 UsageStatsManager');
      expect(caps.supportsPreciseIdleDetection, isFalse,
          reason: 'Android 没有与 GetLastInputInfo 等价的全局输入空闲来源');
    });

    test('Phase 4C 起支持系统级悬浮窗，文件夹导入仍留给原生 SAF 通道', () {
      expect(caps.supportsFloatingPet, isTrue,
          reason: 'Phase 4C：需要用户授权 SYSTEM_ALERT_WINDOW 后显示在其他应用上层');
      expect(caps.supportsFolderImport, isFalse);
    });

    test('需要用户手动授予使用情况访问权限（Phase 4B 才用）', () {
      expect(caps.requiresUsageAccessPermission, isTrue);
    });

    test('平台装配给出无托盘、无桌宠窗口的宿主', () {
      expect(android.createTrayHost(callbacks: _noopCallbacks), isNull,
          reason: 'Android 没有系统托盘');
      expect(
        android.createPetHost(windowController: android.createWindowController()),
        isA<NoopPetHost>(),
      );
      // 采集提供者必须是"不可用"实现，采集器据此不驱动桌宠状态。
      expect(android.createForegroundAppProvider().isAvailable, isFalse);
      expect(android.createIdleDetector().isAvailable, isFalse);
      expect(android.createSessionStateProvider().isAvailable, isFalse);
      expect(android.processDiagnostics.isAvailable, isFalse);
    });

    test('数据库后端是移动端 sqflite，而不是桌面 FFI', () {
      expect(android.database.backendName, contains('sqflite'));
      expect(android.database.backendName, isNot(contains('ffi')));
    });
  });

  group('Windows 能力（回归保护）', () {
    final WindowsPlatformServices windows = WindowsPlatformServices();
    final PlatformCapabilities caps = windows.capabilities;

    test('平台标识与形态', () {
      expect(caps.platformName, 'windows');
      expect(caps.formFactor, FormFactor.desktop);
      expect(caps.isDesktop, isTrue);
    });

    test('桌面专属能力全部保留', () {
      expect(caps.supportsWindowManagement, isTrue);
      expect(caps.supportsTray, isTrue);
      expect(caps.supportsSystemActivityTracking, isTrue);
      expect(caps.supportsPreciseIdleDetection, isTrue);
      expect(caps.supportsSystemProxyDetection, isTrue);
      expect(caps.supportsProcessDiagnostics, isTrue);
      expect(caps.supportsFolderImport, isTrue);
    });

    test('两端的数据库后端名不同（证明没走同一条实现）', () {
      expect(windows.database.backendName, contains('ffi'));
      expect(
        windows.database.backendName,
        isNot(AndroidPlatformServices().database.backendName),
      );
    });

    test('Windows 仍然提供托盘与桌面桌宠宿主', () {
      expect(windows.createTrayHost(callbacks: _noopCallbacks), isNotNull);
      expect(
        windows.createPetHost(windowController: windows.createWindowController()),
        isNot(isA<NoopPetHost>()),
        reason: '桌面桌宠仍然由 window_manager 拖动窗口',
      );
    });
  });
}

final TrayCallbacks _noopCallbacks = TrayCallbacks(
  onTogglePet: () async {},
  onTogglePanel: () async {},
  onResetPosition: () async {},
  onExit: () async {},
  onToggleTracking: () async {},
  onOpenUsageStats: () async {},
);

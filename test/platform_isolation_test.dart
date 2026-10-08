import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Phase 4A：平台隔离的**静态契约检查**。
///
/// 为什么需要它
/// ------------
/// Dart 的条件导入只能按 `dart.library.*` 判断，而 Windows 与 Android 都是
/// `dart.library.io`，无法在编译期把 Windows 代码排除出 Android 构建。
/// 因此隔离必须落在**模块边界**上，而模块边界只能靠约定维持 ——
/// 这个测试把那条约定变成会失败的断言。
///
/// 规则
/// ----
/// 1. 桌面专属实现（Win32 FFI / window_manager / tray_manager / screen_retriever）
///    只允许出现在 `platform/windows/**`、`ui/desktop/**`、
///    `activity_tracking/windows/**` 以及两个装配点里；
/// 2. `Platform.is*` 只允许出现在 `platform/**`（唯一的平台判定处）；
/// 3. Android 编译单元（`platform/android/**`、`ui/mobile/**`）连中立接口以外的
///    桌面实现都不能出现。
void main() {
  final String root = Directory.current.path;
  final Directory lib = Directory(p.join(root, 'lib'));

  /// 桌面专属实现的特征串。
  const List<String> desktopOnly = <String>[
    'package:window_manager/',
    'package:tray_manager/',
    'package:screen_retriever/',
    'package:ffi/',
    'win32_activity_native.dart',
    'windows_window_controller.dart',
    'win32_process_stats.dart',
    'winhttp_system_proxy.dart',
    'win32_credential_native.dart',
    'dpapi_file_credential_store.dart',
    'display_topology.dart',
    'windows_startup_registrar.dart',
  ];

  /// 允许出现桌面专属实现的目录前缀。
  const List<String> desktopAllowedPrefixes = <String>[
    'platform/windows/',
    'ui/desktop/',
    'activity_tracking/windows/',
  ];

  /// 允许同时认识两个平台的装配点。
  const Set<String> assemblyPoints = <String>{
    'platform/platform_services_io.dart',
    'app/app_shell.dart',
  };

  /// 允许做平台判定的文件（`Platform.is*`）。
  const List<String> platformDecisionAllowed = <String>[
    'platform/device_info_provider.dart',
    'platform/platform_services_io.dart',
    'platform/windows/',
  ];

  List<File> allLibFiles() => lib
      .listSync(recursive: true)
      .whereType<File>()
      .where((File f) => f.path.endsWith('.dart'))
      .toList(growable: false);

  String rel(File f) => p.relative(f.path, from: lib.path).replaceAll('\\', '/');

  bool allowedDesktop(String name) =>
      assemblyPoints.contains(name) ||
      desktopAllowedPrefixes.any((String prefix) => name.startsWith(prefix));

  bool allowedPlatformDecision(String name) =>
      platformDecisionAllowed.any((String prefix) =>
          prefix.endsWith('/') ? name.startsWith(prefix) : name == prefix);

  test('桌面专属实现只出现在平台层 / 桌面 UI / 装配点', () {
    final List<String> violations = <String>[];
    for (final File file in allLibFiles()) {
      final String name = rel(file);
      if (allowedDesktop(name)) continue;
      final String source = file.readAsStringSync();
      for (final String banned in desktopOnly) {
        if (source.contains(banned)) {
          violations.add('$name → $banned');
        }
      }
    }
    expect(
      violations,
      isEmpty,
      reason: '桌面专属依赖泄漏到共享层：\n${violations.join('\n')}',
    );
  });

  test('Platform.is* 只在平台层出现（不存在散落的平台分支）', () {
    final List<String> violations = <String>[];
    for (final File file in allLibFiles()) {
      final String name = rel(file);
      if (allowedPlatformDecision(name)) continue;
      final String source = file.readAsStringSync();
      // 只检查真实调用，注释里的说明文字不算。
      for (final String line in source.split('\n')) {
        final String trimmed = line.trim();
        if (trimmed.startsWith('///') || trimmed.startsWith('//')) continue;
        if (RegExp(r'Platform\.is(Windows|Android|Linux|MacOS|IOS|Fuchsia)')
            .hasMatch(trimmed)) {
          violations.add('$name → $trimmed');
        }
      }
    }
    expect(
      violations,
      isEmpty,
      reason: '平台判定散落在业务代码里（应该走 PlatformCapabilities）：\n'
          '${violations.join('\n')}',
    );
  });

  test('Android 编译单元只依赖中立接口', () {
    final List<String> violations = <String>[];
    for (final String unit in <String>['platform/android/', 'ui/mobile/']) {
      final Directory dir = Directory(p.join(lib.path, unit));
      if (!dir.existsSync()) continue;
      for (final File file in dir
          .listSync(recursive: true)
          .whereType<File>()
          .where((File f) => f.path.endsWith('.dart'))) {
        final String source = file.readAsStringSync();
        for (final String banned in desktopOnly) {
          if (source.contains(banned)) {
            violations.add('${rel(file)} → $banned');
          }
        }
      }
    }
    expect(violations, isEmpty, reason: 'Android 编译单元出现桌面专属依赖：\n${violations.join('\n')}');
  });

  test('平台装配点确实同时认识两个平台（否则隔离只是假象）', () {
    final String source = File(p.join(lib.path, 'platform', 'platform_services_io.dart'))
        .readAsStringSync();
    expect(source, contains('WindowsPlatformServices'));
    expect(source, contains('AndroidPlatformServices'));
    expect(source, contains('Platform.isWindows'));

    final String shell =
        File(p.join(lib.path, 'app', 'app_shell.dart')).readAsStringSync();
    expect(shell, contains('DesktopShell'));
    expect(shell, contains('MobileShell'));
  });

  test('窗口与托盘是中立接口，实现在平台层', () {
    final String controller =
        File(p.join(lib.path, 'desktop_window', 'window_controller.dart')).readAsStringSync();
    expect(controller, contains('abstract interface class WindowController'));
    // 只看 import（文档里提到实现文件名是正常的，不算耦合）。
    expect(controller.contains("import 'package:window_manager"), isFalse);

    final String tray =
        File(p.join(lib.path, 'desktop_window', 'tray_host.dart')).readAsStringSync();
    expect(tray, contains('abstract interface class TrayHost'));
    expect(tray.contains("import 'package:tray_manager"), isFalse);

    expect(
      File(p.join(lib.path, 'platform', 'windows', 'windows_tray_service.dart')).existsSync(),
      isTrue,
    );
    expect(
      File(p.join(lib.path, 'platform', 'windows', 'windows_window_controller.dart')).existsSync(),
      isTrue,
    );
    final String credentialFactory =
        File(p.join(lib.path, 'sync', 'credential_store_factory.dart')).readAsStringSync();
    expect(credentialFactory, contains('abstract interface class CredentialStoreFactory'));
  });

  test('Android 权限清单精确可控（Phase 4C 只有悬浮窗 / 前台服务 / 使用情况访问）', () {
    final File manifest = File(p.join(
      root,
      'android',
      'app',
      'src',
      'main',
      'AndroidManifest.xml',
    ));
    expect(manifest.existsSync(), isTrue, reason: 'Android 平台目录应已生成');
    final String text = manifest.readAsStringSync();
    // 只解析**真正的** uses-permission 声明（注释里提到权限名不算），
    // 并支持跨行的声明写法（`<uses-permission` 与 `android:name` 分两行）。
    final List<String> declared = RegExp(
      r'<uses-permission\s[^>]*android:name="([^"]+)"',
      multiLine: true,
      dotAll: true,
    )
        .allMatches(text)
        .map((RegExpMatch m) => m.group(1)!)
        .toList(growable: false);

    // 允许集合是**精确**的：多申请任何一条都会让这个断言失败。
    for (final String allowed in <String>[
      'android.permission.INTERNET',
      'android.permission.SYSTEM_ALERT_WINDOW',
      'android.permission.FOREGROUND_SERVICE',
      'android.permission.FOREGROUND_SERVICE_SPECIAL_USE',
      'android.permission.POST_NOTIFICATIONS',
      // Phase 4C-5：状态联动需要读"当前前台应用包名"。
      // 这是**特殊权限**，只能由用户在系统设置里授予，应用无法自行开启；
      // 未授予时桌宠仍正常显示与播放动画，只是状态保持默认（需求 §6）。
      // 它只给到「包名 + 应用标签」这一层，不涉及任何内容读取。
      'android.permission.PACKAGE_USAGE_STATS',
      // Phase 4D：开机自启。普通权限，安装即授予；只有用户在设置页显式
      // 打开「开机自动启动」时才会在 BOOT_COMPLETED 后启动服务。
      // 它本身不读任何数据，只用于接收系统开机广播。
      'android.permission.RECEIVE_BOOT_COMPLETED',
    ]) {
      expect(declared, contains(allowed), reason: '缺少必需的权限声明：$allowed');
    }
    expect(declared, hasLength(7),
        reason: '权限数量必须精确为 7 条（多申请一条都要先改这个测试并说明理由）：$declared');

    // **明确禁止**的能力（需求第四、十八节）：无障碍 / 定位 /
    // 安装未知应用 / 全量包可见性 / 电池优化白名单。
    //
    // 注意两处**显式**变动（都各自有理由）：
    // * `PACKAGE_USAGE_STATS` 进入允许集合：Phase 4C-5 的状态联动必须知道前台应用是谁；
    // * `RECEIVE_BOOT_COMPLETED` 进入允许集合：Phase 4D 的开机自启需要接收开机广播；
    // 两者都读不到任何屏幕内容 / 输入 / 通知 / 聊天 / 文件。
    for (final String forbidden in <String>[
      'android.permission.BIND_ACCESSIBILITY_SERVICE',
      'android.permission.ACCESS_FINE_LOCATION',
      'android.permission.ACCESS_COARSE_LOCATION',
      'android.permission.REQUEST_INSTALL_PACKAGES',
      'android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS',
      'android.permission.QUERY_ALL_PACKAGES',
    ]) {
      expect(declared, isNot(contains(forbidden)), reason: '不得申请 $forbidden');
    }

    // 悬浮桌宠前后台服务：必须是 specialUse（targetSdk 36 的硬要求），
    // 且划掉任务卡不停止服务。
    expect(text.contains('android:foregroundServiceType="specialUse"'), isTrue,
        reason: '必须声明 specialUse 前台服务类型（读到的文本文档长度=${text.length}）');
    expect(text.contains('android:stopWithTask="false"'), isTrue);
    expect(text.contains('PROPERTY_SPECIAL_USE_FGS_SUBTYPE'), isTrue);
    expect(text.contains('.overlay.PetOverlayService'), isTrue);

    // Phase 4D：开机自启接收器必须声明，且只接收系统开机广播。
    expect(text.contains('.overlay.BootCompletedReceiver'), isTrue,
        reason: '必须声明开机自启接收器');
    expect(text.contains('android.intent.action.BOOT_COMPLETED'), isTrue,
        reason: '接收器必须处理 BOOT_COMPLETED');
    expect(text.contains('android.intent.action.MY_PACKAGE_REPLACED'), isTrue,
        reason: '接收器应处理应用被覆盖安装（等价于一次重启）');
    expect(text.contains('android.intent.action.LOCKED_BOOT_COMPLETED'), isFalse,
        reason: '不得处理 LOCKED_BOOT_COMPLETED：未解锁时读不到凭据加密的标志');
  });

  test('Android 应用标识与最低版本已按 Phase 4A 要求配置', () {
    final File gradle = File(p.join(root, 'android', 'app', 'build.gradle.kts'));
    final String kts = gradle.readAsStringSync();
    expect(kts, contains('asia.akechi.petlife'));
    expect(kts, contains('minSdk'));

    // 不允许硬编码低于 23 的值（flutter_secure_storage 需要 API 23+）。
    // 用 flutter.minSdkVersion（Flutter 3.47 默认 24）不算硬编码，直接通过。
    final Match? hardcoded =
        RegExp(r'minSdk\s*=\s*(\d+)').firstMatch(kts);
    if (hardcoded != null) {
      expect(
        int.parse(hardcoded.group(1)!),
        greaterThanOrEqualTo(23),
        reason: '硬编码的 minSdk 不得低于 23',
      );
    }

    // 签名材料不得进仓库（由 android/.gitignore 保证）。
    final String gitignore =
        File(p.join(root, 'android', '.gitignore')).readAsStringSync();
    expect(gitignore, contains('key.properties'));
    expect(gitignore, contains('**/*.jks'));
  });
}

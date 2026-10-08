import 'package:flutter/material.dart';

import '../ui/desktop/desktop_shell.dart';
import '../ui/mobile/mobile_shell.dart';
import 'app_scope.dart';

/// 应用根组件。
class PetLifeApp extends StatelessWidget {
  const PetLifeApp({super.key, required this.services});

  final AppServices services;

  @override
  Widget build(BuildContext context) {
    // 字体：Windows 用微软雅黑；Android 上没有该字体，交给系统默认字体，
    // 否则中文会回退到不含中文的字形而显示成方框。
    final bool desktop = services.platform.capabilities.isDesktop;
    return MaterialApp(
      title: 'PetLife',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF4A7EBB)),
        fontFamily: desktop ? 'Microsoft YaHei' : null,
      ),
      home: AppShell(services: services),
    );
  }
}

/// 应用外壳选择器（**平台外壳的唯一装配点**）。
///
/// 这里是除 `platform/platform_services_io.dart` 之外**唯一**同时认识两套外壳的
/// 文件：桌面外壳依赖 `window_manager` / `tray_manager`，
/// Android 外壳只依赖 Material 组件。
///
/// 之所以不能在编译期彻底分开：Dart 的条件导入只能按 `dart.library.*` 判断，
/// 而 Windows 与 Android 都是 `dart.library.io`。因此隔离落在**模块边界**上：
/// `ui/mobile/**`、`platform/android/**`、`activity_tracking/android/**`
/// 这些 Android 编译单元永远不 import 桌面专属实现，
/// 由 `test/platform_isolation_test.dart` 静态检查固化。
class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.services});

  final AppServices services;

  @override
  Widget build(BuildContext context) {
    if (services.platform.capabilities.isMobile) {
      return MobileShell(services: services);
    }
    return DesktopShell(services: services);
  }
}

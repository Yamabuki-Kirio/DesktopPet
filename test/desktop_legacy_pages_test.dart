import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:petlife/ui/desktop/desktop_panel_flags.dart';
import 'package:petlife/ui/theme/design_tokens.dart';
import 'package:petlife/ui/theme/petlife_theme.dart';

/// **Legacy 回退与平台边界**的回归防线（需求 §12 / §11）。
///
/// 历史（两轮增量的边界变更，必须记住）：
/// 1. 只做 Android 时，四个共享页面（使用统计 / 账户与同步 / 素材库 / 设置）
///    被 Windows 控制面板复用，而桌面主题没装 `PetLifeTheme`，
///    于是共享页面会掉到默认白 + 粉调色板 → 等于偷偷改了 Windows 外观。
///    当时的修法是"**主题缺失就当桌面**，静默回退到 legacy 页面"。
/// 2. 本轮（Windows 同步新视觉）反过来了：Windows 也要用新 UI，
///    因此**静默回退被取消**，改由显式开关 `useLegacyDesktopControlPanel` 决定。
///
/// 这两条规则互补，缺一不可：
/// * 桌面外壳**必须**装配主题（否则新页面会掉到兜底调色板）；
/// * 回退**必须**由开关显式决定（否则"看起来没变"与"真的坏了"无法区分）。
void main() {
  final String root = Directory.current.path;

  String readLib(String relative) =>
      File(p.join(root, 'lib', relative)).readAsStringSync();

  File libFile(String relative) => File(p.join(root, 'lib', relative));

  /// 四个共享页面 → 它们对应的桌面 legacy 实现。
  const Map<String, String> sharedPages = <String, String>{
    'ui/pages/usage_stats_page.dart':
        'ui/desktop/legacy/legacy_usage_stats_page.dart',
    'ui/pages/account_sync_page.dart':
        'ui/desktop/legacy/legacy_account_sync_page.dart',
    'ui/pages/asset_library_page.dart':
        'ui/desktop/legacy/legacy_asset_library_page.dart',
    'ui/pages/settings_page.dart':
        'ui/desktop/legacy/legacy_settings_page.dart',
  };

  const List<String> newDesignSystemImports = <String>[
    'theme/petlife_theme.dart',
    'theme/design_tokens.dart',
    'widgets/petlife/',
  ];

  group('桌面外壳明确装配 PetLifeTheme（需求 §12）', () {
    testWidgets('桌面与 Android 走同一套主题生成器，桌面额外带微软雅黑',
        (WidgetTester tester) async {
      // 复刻 app_shell.dart 的两条分支。
      await tester.pumpWidget(
        MaterialApp(
          theme: buildPetLifeThemeData(
            primary: PetLifeColors.primaryDefault,
            accent: PetLifeColors.accentDefault,
            brightness: Brightness.light,
            fontFamily: 'Microsoft YaHei',
            // 桌面禁止"逐卡片依次播放"。
            cardEntranceAnimated: false,
          ),
          home: const Scaffold(body: SizedBox.shrink()),
        ),
      );
      final BuildContext ctx = tester.element(find.byType(Scaffold));
      expect(PetLifeTheme.isInstalled(ctx), isTrue,
          reason: '桌面主题必须装 PetLifeTheme，否则新页面会掉到兜底调色板');
      expect(PetLifeTheme.of(ctx).accent, PetLifeColors.accentDefault);
      expect(PetLifeTheme.cardEntranceAnimatedOf(ctx), isFalse,
          reason: '桌面端必须关闭卡片进场动画');
    });

    testWidgets('Android 侧仍保留卡片进场动画（本轮不影响 Android）',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildPetLifeThemeData(
            primary: PetLifeColors.primaryDefault,
            accent: PetLifeColors.accentDefault,
            brightness: Brightness.light,
          ),
          home: const Scaffold(body: SizedBox.shrink()),
        ),
      );
      final BuildContext ctx = tester.element(find.byType(Scaffold));
      expect(PetLifeTheme.cardEntranceAnimatedOf(ctx), isTrue);
    });

    test('app_shell 两条分支都用 buildPetLifeThemeData，且监听设置变化', () {
      final String shell = readLib('app/app_shell.dart');
      // 旧版深蓝色 seed 必须已经消失（需求 §4：不使用旧版深蓝色实心横条）。
      expect(shell.contains('0xFF4A7EBB'), isFalse,
          reason: '桌面主题仍在使用旧的蓝色 seed');
      // 两次 buildPetLifeThemeData（light + dark），且都带字体参数。
      expect('buildPetLifeThemeData'.allMatches(shell).length, 2);
      expect(shell, contains("fontFamily: fontFamily"));
      expect(shell, contains("desktop ? 'Microsoft YaHei' : null"));
      // 主题跟随持久化设置实时重建（改配色立即生效，不重启窗口）。
      expect(shell, contains('listenable: services.settings'));
      expect(shell, contains('themeAnimationDuration'));
    });
  });

  group('Legacy 回退由显式开关决定（不允许静默回退）', () {
    test('开关默认关闭', () {
      expect(defaultUseLegacyDesktopControlPanel, isFalse);
      expect(useLegacyDesktopControlPanel, isFalse,
          reason: '默认必须是新界面；用 --dart-define 才打开回退');
    });

    test('开关文档说明了 --dart-define 打开方式', () {
      final String source = readLib('ui/desktop/desktop_panel_flags.dart');
      expect(source, contains('petlife.legacyDesktopPanel'));
      expect(source, contains('默认关闭'));
    });

    test('四个共享页面里**不再**有"主题缺失就回退"的静默逻辑', () {
      for (final String page in sharedPages.keys) {
        final String source = readLib(page);
        expect(
          source.contains('PetLifeTheme.maybeOf(context) == null'),
          isFalse,
          reason: '$page 仍然根据主题缺失静默回退 —— 本轮已改为显式开关',
        );
        expect(
          source.contains('desktop/legacy/'),
          isFalse,
          reason: '$page 不应直接认识 legacy 实现（由控制面板按开关选择）',
        );
      }
    });

    test('控制面板按开关同时引用两套页面实现', () {
      final String panel = readLib('ui/desktop/control_panel.dart');
      expect(panel, contains('useLegacyDesktopControlPanel'));
      // 开关两侧都要有真实页面：新实现与 legacy 实现。
      for (final String cls in <String>[
        'AssetLibraryPage(',
        'LegacyAssetLibraryPage(',
        'UsageStatsPage(',
        'LegacyUsageStatsPage(',
        'AccountSyncPage(',
        'LegacyAccountSyncPage(',
        'SettingsPage(',
        'LegacySettingsPage(',
      ]) {
        expect(panel, contains(cls), reason: '开关分支缺少 $cls');
      }
      // 状态映射 / 状态调试器 / 诊断是 Windows 专属页面，没有第二套实现。
      expect(panel, contains('StateMappingPage('));
      expect(panel, contains('StateDebuggerPage('));
      expect(panel, contains('DiagnosticsPage('));
    });

    test('legacy 实现仍然保留、且不依赖新设计系统', () {
      for (final MapEntry<String, String> e in sharedPages.entries) {
        expect(libFile(e.value).existsSync(), isTrue, reason: '缺少 ${e.value}');
        final String source = readLib(e.value);
        for (final String banned in newDesignSystemImports) {
          expect(source.contains(banned), isFalse,
              reason: '${e.value} 引用了新设计系统（$banned）');
        }
      }
    });
  });

  group('Android 侧不受本轮 Windows 增量影响', () {
    test('移动端外壳没有引入任何桌面专属文件', () {
      final String shell = readLib('ui/mobile/mobile_shell.dart');
      expect(shell.contains('desktop/'), isFalse);
      expect(shell.contains('window_manager'), isFalse);
      final String home = readLib('ui/mobile/mobile_home_page.dart');
      expect(home.contains('desktop/'), isFalse);
    });

    test('桌面导航组件本身与平台无关（可在 Android 上编译）', () {
      final String widgets = readLib('ui/widgets/petlife/petlife_desktop.dart');
      expect(widgets.contains('package:window_manager'), isFalse);
      expect(widgets.contains('package:tray_manager'), isFalse);
      expect(widgets.contains('Platform.isWindows'), isFalse);
      // 拖拽必须通过回调注入。
      expect(widgets, contains('onTitleBarDrag'));
    });

    test('桌面外壳仍然调用同一批页面类（Android 的页面代码没有被 fork）', () {
      // 共享页面只有**一份**实现：桌面通过主题 + 桌面外壳得到桌面布局，
      // 而不是复制一份"桌面版页面"。
      for (final String page in sharedPages.keys) {
        final String source = readLib(page);
        // 不允许在页面里挑第二套实现，也不允许散落的平台判定。
        expect(source.contains('Legacy'), isFalse, reason: page);
        expect(source.contains('Platform.is'), isFalse, reason: page);
      }
    });
  });

  group('控制面板定位算法与桌宠几何完全冻结（需求 §11）', () {
    test('panel_layout 没有被改动（定位算法冻结）', () {
      final String layout = readLib('ui/desktop/panel_layout.dart');
      // 首选尺寸 / 安全边距 / 下限仍然是改造前的常量。
      expect(layout, contains('Size(1180, 760)'));
      expect(layout, contains('edgeMargin = 16'));
      expect(layout, contains('minWidth = 480'));
      expect(layout, contains('minHeight = 360'));
      // 居中公式未变。
      expect(layout, contains('workArea.left + (workArea.width - size.width) / 2'));
      expect(layout, contains('workArea.top + (workArea.height - size.height) / 2'));
    });

    test('控制面板不写任何桌宠坐标 / Region / 轮盘 API', () {
      final String panel = readLib('ui/desktop/control_panel.dart');
      for (final String banned in <String>[
        'setBounds',
        'rememberWindowPosition',
        'RegionCoordinator',
        'wheelMenu',
        'startDragging()', // 只允许标题栏拖拽；这里用注释外的调用检查
      ]) {
        if (banned == 'startDragging()') continue; // 标题栏拖拽是唯一允许的窗口调用
        expect(panel.contains(banned), isFalse,
            reason: '控制面板出现了不该有的窗口/Region 调用：$banned');
      }
      // 允许的窗口调用只有"标题栏拖拽"。
      expect('windowManager.'.allMatches(panel).length, 1);
      expect(panel, contains('windowManager.startDragging()'));
    });

    test('冻结模块仍然存在且没有被控制面板引用', () {
      for (final String file in <String>[
        'menu/region_coordinator.dart',
        'menu/wheel_menu_geometry.dart',
        'menu/wheel_canvas_plan.dart',
        'platform/overlay_pet.dart',
        'ui/pet/pet_view.dart',
      ]) {
        expect(libFile(file).existsSync(), isTrue, reason: '冻结模块丢失：$file');
      }
      final String panel = readLib('ui/desktop/control_panel.dart');
      expect(panel.contains('menu/'), isFalse);
      expect(panel.contains('region_coordinator'), isFalse);
    });
  });
}

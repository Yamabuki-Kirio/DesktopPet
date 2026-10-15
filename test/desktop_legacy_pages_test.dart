import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:petlife/ui/theme/design_tokens.dart';
import 'package:petlife/ui/theme/petlife_theme.dart';

/// **Windows UI 不受影响**的回归防线。
///
/// 背景（一个真实发生过的缺陷）
/// --------------------------
/// 本轮 Android UI 增量重写了四个页面：
/// 使用统计 / 账户与同步 / 素材库 / 设置。
/// 但这四个类**同时被 Windows 控制面板复用**
/// （`lib/ui/desktop/control_panel.dart`），而桌面外壳刻意沿用改造前的主题
/// （没有装 `PetLifeTheme` 扩展）—— 结果是共享页面会在 Windows 上
/// 悄悄回落到新主题的**默认白 + 粉**调色板，等于改了 Windows UI。
///
/// 修法：把改造前的实现原样保留在 `lib/ui/desktop/legacy/`，
/// 四个共享页面在"当前主题没有 PetLifeTheme 扩展"时**直接委托**过去。
/// 桌面外壳因此一行都不用改，行为与外观与改造前完全一致。
///
/// 这些断言的作用是让"以后又有人把 Windows 一起改了"变成会失败的测试。
void main() {
  final String root = Directory.current.path;

  String readLib(String relative) =>
      File(p.join(root, 'lib', relative)).readAsStringSync();

  File libFile(String relative) => File(p.join(root, 'lib', relative));

  /// 四个共享页面 → 它们各自的桌面回落实现。
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

  /// legacy 页面里**不允许**出现的、属于新设计系统的导入。
  const List<String> newDesignSystemImports = <String>[
    'theme/petlife_theme.dart',
    'theme/design_tokens.dart',
    'widgets/petlife/',
  ];

  group('主题是否装载 = 新旧 UI 的唯一开关', () {
    testWidgets('桌面主题（改造前原样）：没有 PetLifeTheme 扩展',
        (WidgetTester tester) async {
      // 完全复刻 app_shell.dart 的桌面分支。
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            useMaterial3: true,
            colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF4A7EBB)),
            fontFamily: 'Microsoft YaHei',
          ),
          home: const Scaffold(body: SizedBox.shrink()),
        ),
      );
      final BuildContext ctx = tester.element(find.byType(Scaffold));
      expect(PetLifeTheme.maybeOf(ctx), isNull,
          reason: '桌面主题带了 PetLifeTheme 扩展 → 共享页面会走新 UI');
      // of() 仍然必须给出兜底调色板（否则老组件会崩），但不代表桌面走新 UI。
      expect(PetLifeTheme.of(ctx).accent, PetLifeColors.accentDefault);
    });

    testWidgets('Android 新主题：带 PetLifeTheme 扩展，且颜色来自设置',
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
      final PetLifePalette? palette = PetLifeTheme.maybeOf(ctx);
      expect(palette, isNotNull,
          reason: 'Android 主题没装扩展 → 新 UI 不会被启用');
      expect(palette!.accent, PetLifeColors.accentDefault);
      expect(palette.surface, PetLifeColors.primaryDefault);
    });

    test('桌面分支确实没有安装扩展（源码级确认）', () {
      final String shell = readLib('app/app_shell.dart');
      // 桌面分支：原来的蓝色 seed + 微软雅黑，且没有 extensions。
      expect(
        RegExp(r'if \(desktop\) \{[\s\S]{0,300}?return MaterialApp'
                r'[\s\S]{0,300}?0xFF4A7EBB')
            .hasMatch(shell),
        isTrue,
        reason: '桌面分支应沿用改造前的蓝色 seed 主题',
      );
      // 移动分支：使用新主题生成器（它内部会装 PetLifeTheme 扩展）。
      expect(shell, contains('buildPetLifeThemeData'));
      final String theme = readLib('ui/theme/petlife_theme.dart');
      expect(theme, contains('extensions: <ThemeExtension<dynamic>>[PetLifeTheme(palette: p)]'));
    });
  });

  group('四个共享页面都有桌面回落守卫', () {
    for (final MapEntry<String, String> entry in sharedPages.entries) {
      test('${entry.key} 在桌面主题下委托给 ${p.basename(entry.value)}', () {
        final String source = readLib(entry.key);
        expect(
          source,
          contains('PetLifeTheme.maybeOf(context) == null'),
          reason: '${entry.key} 缺少桌面回落判定',
        );
        // 判定语句必须**在 build 的最前面**，且紧跟着返回 legacy 实现。
        expect(
          RegExp(
            r'Widget build\(BuildContext context\) \{[\s\S]{0,400}?'
            r'PetLifeTheme\.maybeOf\(context\) == null\)[\s\S]{0,900}?'
            r'return (Legacy\w+)\(',
          ).hasMatch(source),
          isTrue,
          reason: '${entry.key} 的回落分支没有立刻返回 Legacy* 实现',
        );
        expect(source, contains("import '../desktop/legacy/"),
            reason: '${entry.key} 没有导入桌面回落实现');
      });
    }
  });

  group('桌面回落实现与改造前一致（不掺入新设计系统）', () {
    test('四个 legacy 文件都存在并声明了 Legacy* 类', () {
      const Map<String, String> expectedClass = <String, String>{
        'ui/desktop/legacy/legacy_usage_stats_page.dart': 'LegacyUsageStatsPage',
        'ui/desktop/legacy/legacy_account_sync_page.dart': 'LegacyAccountSyncPage',
        'ui/desktop/legacy/legacy_asset_library_page.dart':
            'LegacyAssetLibraryPage',
        'ui/desktop/legacy/legacy_settings_page.dart': 'LegacySettingsPage',
      };
      for (final MapEntry<String, String> e in expectedClass.entries) {
        expect(libFile(e.key).existsSync(), isTrue, reason: '缺少 ${e.key}');
        expect(readLib(e.key), contains('class ${e.value}'));
      }
    });

    test('legacy 实现不依赖新设计系统（否则 Windows 又会被新配色染色）', () {
      for (final String path in sharedPages.values) {
        final String source = readLib(path);
        for (final String banned in newDesignSystemImports) {
          expect(source.contains(banned), isFalse,
              reason: '$path 引用了新设计系统（$banned），Windows 外观会变');
        }
        expect(source.contains('PetLifeCard('), isFalse, reason: path);
        expect(source.contains('PetLifePage('), isFalse, reason: path);
      }
    });

    test('legacy 实现保留改造前的视觉特征（没有被新实现顶替）', () {
      final String usage = readLib('ui/desktop/legacy/legacy_usage_stats_page.dart');
      expect(usage, contains('SegmentedButton<UsageRange>'));
      expect(usage, contains('Table('));

      final String account =
          readLib('ui/desktop/legacy/legacy_account_sync_page.dart');
      expect(account, contains('CloudSyncActionsCard('));
      expect(account, contains('CheckboxListTile'));

      final String library =
          readLib('ui/desktop/legacy/legacy_asset_library_page.dart');
      expect(library, contains('Icons.star_border'));
      expect(library, contains('_kWideBreakpoint'));

      final String settings = readLib('ui/desktop/legacy/legacy_settings_page.dart');
      expect(settings, contains('SwitchListTile'));
      expect(settings, contains('class LegacyStartupSwitchTile'));
      expect(settings, contains('Widget _section(String title)'));
    });

    test('legacy 设置页的旧类名已隔离，不会与新的 StartupSwitchTile 冲突', () {
      final String settings = readLib('ui/desktop/legacy/legacy_settings_page.dart');
      expect(settings.contains('class StartupSwitchTile'), isFalse,
          reason: '旧类名会与新设置页的同名类在同一编译单元里冲突');
      // 新设置页仍然导出 StartupSwitchTile（test/startup_registration_test 依赖它）。
      expect(readLib('ui/pages/settings_page.dart'),
          contains('class StartupSwitchTile'));
    });
  });

  group('桌面外壳本身一行未改', () {
    test('control_panel 仍然调用四个未加前缀的页面类，且不直接依赖 legacy', () {
      final String panel = readLib('ui/desktop/control_panel.dart');
      for (final String cls in <String>[
        'UsageStatsPage(',
        'AccountSyncPage(',
        'AssetLibraryPage(',
        'SettingsPage(',
      ]) {
        expect(panel, contains(cls), reason: '桌面外壳的调用点被改动了：$cls');
      }
      expect(panel.contains('desktop/legacy/'), isFalse,
          reason: '桌面外壳不应该直接认识回落实现（回落由页面自己决定）');
    });

    test('桌面外壳没有误用移动端外壳 / 新组件', () {
      final String panel = readLib('ui/desktop/control_panel.dart');
      expect(panel.contains('MobileShell'), isFalse);
      expect(panel.contains('widgets/petlife/'), isFalse);
      // 平台隔离测试也检查桌面专属依赖不泄漏到 Android 侧，这里反向钉一次。
      final String shell = readLib('ui/mobile/mobile_shell.dart');
      expect(shell.contains('desktop/'), isFalse);
    });
  });
}

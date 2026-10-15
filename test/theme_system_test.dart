import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:petlife/core/logger.dart';
import 'package:petlife/core/paths.dart';
import 'package:petlife/database/app_database.dart';
import 'package:petlife/settings/app_settings.dart';
import 'package:petlife/settings/settings_controller.dart';
import 'package:petlife/settings/settings_repository.dart';
import 'package:petlife/settings/sqlite_settings_repository.dart';
import 'package:petlife/ui/theme/design_tokens.dart';
import 'package:petlife/ui/theme/petlife_theme.dart';

import 'support/sqlite_test_bootstrap.dart';

/// 主题系统测试（本轮 Android UI 增量的核心契约）。
///
/// 覆盖需求 §3「配色功能」与 §11「主题默认值与持久化 / 主色与强调色独立修改」：
/// * 默认值必须是 **白色主色 + P3P 粉强调色**；
/// * 主色与强调色**独立修改、独立保存**，任何一处都不会覆盖另一处；
/// * 系统根据背景亮度自动生成可读文字色 —— **禁止白字白底 / 同色按钮**；
/// * 非法取值（手改数据库 / 旧版本残留）必须安全回落，绝不抛异常。
void main() {
  group('默认值（需求：默认是白色 + P3P 粉）', () {
    test('AppSettings 的默认主题字段', () {
      const AppSettings s = AppSettings();
      expect(s.themeMode, AppSettings.themeModeLight, reason: '默认必须是浅色');
      expect(s.themePrimaryColor, '#FFFFFF');
      expect(s.themeAccentColor, '#F24D96');
    });

    test('持久化默认值与设计令牌一致（防止两处各写一份而漂移）', () {
      expect(
        petLifeColorToHex(PetLifeColors.primaryDefault),
        AppSettings.defaultThemePrimaryColor,
      );
      expect(
        petLifeColorToHex(PetLifeColors.accentDefault),
        AppSettings.defaultThemeAccentColor,
      );
    });

    test('默认主题解析出来就是白色界面 + 粉色强调', () {
      final PetLifePalette p = PetLifePalette.resolve(
        primary: PetLifeColors.primaryDefault,
        accent: PetLifeColors.accentDefault,
        brightness: Brightness.light,
      );
      expect(p.surface, const Color(0xFFFFFFFF));
      expect(p.card, const Color(0xFFFFFFFF));
      expect(p.accent, const Color(0xFFF24D96));
      expect(p.textPrimary, PetLifeColors.textPrimaryDefault);
      // 强调色上的文字由对比度自动选择（粉色上使用白字）。
      expect(p.onAccent, const Color(0xFFFFFFFF));
    });

    test('次级背景由主色 + 强调色派生（白底时≈#FFF7FB）', () {
      final PetLifePalette p = PetLifePalette.resolve(
        primary: PetLifeColors.primaryDefault,
        accent: PetLifeColors.accentDefault,
        brightness: Brightness.light,
      );
      // 与需求给出的 #FFF7FB 每个通道相差不超过 8。
      expect((p.muted.r * 255 - 0xFF).abs(), lessThan(8));
      expect((p.muted.g * 255 - 0xF7).abs(), lessThan(8));
      expect((p.muted.b * 255 - 0xFB).abs(), lessThan(8));
    });
  });

  group('对比度自动调整（禁止白字白底 / 同色按钮）', () {
    // 刻意包含"对抗性"组合：强调色等于主色、强调色是纯白、主色是深色等。
    const List<(String, int, int)> combos = <(String, int, int)>[
      ('默认白 + P3P 粉', 0xFFFFFFFF, 0xFFF24D96),
      ('浅蓝主色 + 蓝色强调', 0xFFEEF4FF, 0xFF3B82F6),
      ('深色主色 + 粉色强调', 0xFF1B1620, 0xFFF24D96),
      ('强调色与主色相同（纯白）', 0xFFFFFFFF, 0xFFFFFFFF),
      ('强调色与主色相同（黑）', 0xFF000000, 0xFF000000),
      ('浅黄强调色（白字会隐形）', 0xFFFFFFFF, 0xFFFFE066),
      ('中等灰主色', 0xFF7C8FB0, 0xFF8B5CF6),
      ('纯黑主色 + 纯白强调', 0xFF000000, 0xFFFFFFFF),
    ];

    for (final (String name, int primary, int accent) in combos) {
      test('$name：正文 / 次要文字 / 强调色上的文字都可读', () {
        for (final Brightness brightness in Brightness.values) {
          final PetLifePalette p = PetLifePalette.resolve(
            primary: Color(primary),
            accent: Color(accent),
            brightness: brightness,
          );
          expect(
            petLifeContrastRatio(p.textPrimary, p.card),
            greaterThanOrEqualTo(4.5),
            reason: '$name / $brightness：主要文字与卡片背景对比度不足',
          );
          expect(
            petLifeContrastRatio(p.onAccent, p.accent),
            greaterThanOrEqualTo(3.0),
            reason: '$name / $brightness：强调色上的文字/图标不可读',
          );
          expect(
            petLifeContrastRatio(p.onAccentSoft, p.accentSoft),
            greaterThanOrEqualTo(3.0),
            reason: '$name / $brightness：柔和强调底上的文字不可读',
          );
          expect(
            petLifeContrastRatio(p.textSecondary, p.card),
            greaterThanOrEqualTo(3.0),
            reason: '$name / $brightness：次要文字太浅',
          );
        }
      });
    }

    test('白字白底被明确避免（极端：主色与强调色都是白色）', () {
      final PetLifePalette p = PetLifePalette.resolve(
        primary: const Color(0xFFFFFFFF),
        accent: const Color(0xFFFFFFFF),
        brightness: Brightness.light,
      );
      // onAccent 必须自动变成深色，而不是白色。
      expect(p.onAccent, isNot(const Color(0xFFFFFFFF)));
      expect(petLifeContrastRatio(p.onAccent, p.accent), greaterThanOrEqualTo(3.0));
    });

    test('深色模式下表面色自动变深、文字自动变亮', () {
      final PetLifePalette p = PetLifePalette.resolve(
        primary: PetLifeColors.primaryDefault,
        accent: PetLifeColors.accentDefault,
        brightness: Brightness.dark,
      );
      expect(p.isDark, isTrue);
      expect(p.card.computeLuminance(), lessThan(0.2));
      expect(p.textPrimary.computeLuminance(), greaterThan(0.6));
    });
  });

  group('主色与强调色独立修改 / 独立保存', () {
    late _MemorySettingsRepository repo;
    late SettingsController controller;

    setUp(() async {
      repo = _MemorySettingsRepository();
      controller = SettingsController(repository: repo, ownerId: 'theme.test');
      await controller.load();
    });

    test('改主色不会动强调色', () async {
      final String accentBefore = controller.settings.themeAccentColor;
      await controller.setThemePrimaryColor('#EEF4FF');
      expect(controller.settings.themePrimaryColor, '#EEF4FF');
      expect(controller.settings.themeAccentColor, accentBefore,
          reason: '改主色把强调色一起改掉了');
    });

    test('改强调色不会动主色', () async {
      await controller.setThemePrimaryColor('#FFF0F7');
      final String primaryBefore = controller.settings.themePrimaryColor;
      await controller.setThemeAccentColor('#3B82F6');
      expect(controller.settings.themeAccentColor, '#3B82F6');
      expect(controller.settings.themePrimaryColor, primaryBefore,
          reason: '改强调色把主色一起改掉了');
    });

    test('两次修改互不覆盖，且都能落盘（模拟重启后读回）', () async {
      await controller.setThemePrimaryColor('#1B1620');
      await controller.setThemeAccentColor('#10B981');

      final SettingsController restarted = SettingsController(
        repository: repo,
        ownerId: 'theme.test',
      );
      await restarted.load();
      expect(restarted.settings.themePrimaryColor, '#1B1620');
      expect(restarted.settings.themeAccentColor, '#10B981');
      expect(restarted.settings.themeMode, AppSettings.themeModeLight);
    });

    test('明暗模式独立于颜色，单独保存', () async {
      await controller.setThemeMode(AppSettings.themeModeDark);
      expect(controller.settings.themeMode, AppSettings.themeModeDark);
      expect(controller.settings.themePrimaryColor, '#FFFFFF');
      expect(controller.settings.themeAccentColor, '#F24D96');
    });

    test('恢复默认只复位颜色，不动明暗模式', () async {
      await controller.setThemeMode(AppSettings.themeModeSystem);
      await controller.setThemePrimaryColor('#1B1620');
      await controller.setThemeAccentColor('#10B981');

      await controller.resetThemeColors();
      expect(controller.settings.themePrimaryColor, '#FFFFFF');
      expect(controller.settings.themeAccentColor, '#F24D96');
      expect(controller.settings.themeMode, AppSettings.themeModeSystem);
    });

    test('颜色会被归一化成大写 #RRGGBB', () async {
      await controller.setThemePrimaryColor('#eef4ff');
      expect(controller.settings.themePrimaryColor, '#EEF4FF');
    });
  });

  group('非法取值安全回落（手改数据库 / 旧版本残留）', () {
    test('非法主色 / 强调色回落默认值', () {
      final AppSettings s = const AppSettings(
        themePrimaryColor: 'banana',
        themeAccentColor: '#12345',
      ).normalized();
      expect(s.themePrimaryColor, AppSettings.defaultThemePrimaryColor);
      expect(s.themeAccentColor, AppSettings.defaultThemeAccentColor);
    });

    test('非法明暗模式回落 light（不是跟随系统）', () {
      expect(
        const AppSettings(themeMode: 'neon').normalized().themeMode,
        AppSettings.themeModeLight,
      );
    });

    test('petLifeColorFromHex 对脏值返回 null 而不是抛异常', () {
      expect(petLifeColorFromHex(null), isNull);
      expect(petLifeColorFromHex(''), isNull);
      expect(petLifeColorFromHex('#12345'), isNull);
      expect(petLifeColorFromHex('zzzzzz'), isNull);
      expect(petLifeColorFromHex('#f24d96'), const Color(0xFFF24D96));
      expect(petLifeColorFromHex('F24D96'), const Color(0xFFF24D96));
    });

    test('明暗模式解析：未知值回落 light', () {
      expect(PetLifeThemeMode.fromWire('dark'), PetLifeThemeMode.dark);
      expect(PetLifeThemeMode.fromWire('system'), PetLifeThemeMode.system);
      expect(PetLifeThemeMode.fromWire('nope'), PetLifeThemeMode.light);
      expect(PetLifeThemeMode.fromWire(null), PetLifeThemeMode.light);
    });
  });

  group('ThemeData 生成', () {
    test('构建出的主题带有 PetLifeTheme 扩展，且颜色来自主色 / 强调色', () {
      final ThemeData theme = buildPetLifeThemeData(
        primary: const Color(0xFFEEF4FF),
        accent: const Color(0xFF3B82F6),
        brightness: Brightness.light,
      );
      final PetLifePalette p = theme.extension<PetLifeTheme>()!.palette;
      expect(p.surface, const Color(0xFFEEF4FF));
      expect(p.accent, const Color(0xFF3B82F6));
      expect(theme.colorScheme.primary, const Color(0xFF3B82F6));
      expect(theme.scaffoldBackgroundColor, const Color(0xFFEEF4FF));
      // 按钮圆角必须满足视觉规范。
      final OutlinedBorder? shape =
          theme.filledButtonTheme.style?.shape?.resolve(<WidgetState>{});
      expect(shape, isA<RoundedRectangleBorder>());
    });

    test('主题插值可在两种配色之间平滑过渡（颜色渐变，不整页闪白）', () {
      final PetLifePalette a = PetLifePalette.resolve(
        primary: const Color(0xFFFFFFFF),
        accent: const Color(0xFFF24D96),
        brightness: Brightness.light,
      );
      final PetLifePalette b = PetLifePalette.resolve(
        primary: const Color(0xFF1B1620),
        accent: const Color(0xFF3B82F6),
        brightness: Brightness.dark,
      );
      final PetLifePalette mid = PetLifePalette.lerp(a, b, 0.5);
      expect(mid.accent, isNot(a.accent));
      expect(mid.accent, isNot(b.accent));
    });
  });

  // ---------------------------------------------------------------------------
  // 真实 SQLite 往返（与 settings_persistence_test 同一个"关库再重开"口径）
  // ---------------------------------------------------------------------------
  group('重启后保留主色 / 强调色 / 主题模式', () {
    Directory? root;

    setUpAll(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SqliteTestBootstrap.ensureLoaded();
      final Directory dir =
          Directory.systemTemp.createTempSync('petlife_theme_test');
      root = dir;
      AppPaths.resetForTest();
      await AppPaths.initialize(overrideRoot: dir);
      await AppLog.initialize(logFile: AppPaths.instance.logFile);
    });

    tearDownAll(() async {
      await AppDatabase.close();
      await AppLog.dispose();
      AppPaths.resetForTest();
      if (root != null && root!.existsSync()) root!.deleteSync(recursive: true);
    });

    Future<SqliteSettingsRepository> openRepository() async {
      final AppDatabase db =
          await AppDatabase.open(path: AppPaths.instance.databaseFile.path);
      return SqliteSettingsRepository.fromDatabase(db);
    }

    test('save → 关库 → 重开：三个主题字段逐项一致', () async {
      const String owner = 'theme.roundtrip';
      final SettingsController controller = SettingsController(
        repository: await openRepository(),
        ownerId: owner,
      );
      await controller.load();

      await controller.setThemePrimaryColor('#F4EFFF');
      await controller.setThemeAccentColor('#8B5CF6');
      await controller.setThemeMode(AppSettings.themeModeDark);

      // 模拟"退出应用再启动"。
      await AppDatabase.close();
      final SettingsController restarted = SettingsController(
        repository: await openRepository(),
        ownerId: owner,
      );
      await restarted.load();

      expect(restarted.settings.themePrimaryColor, '#F4EFFF');
      expect(restarted.settings.themeAccentColor, '#8B5CF6');
      expect(restarted.settings.themeMode, AppSettings.themeModeDark);
    });

    test('改主题不会影响原有业务设置（不丢字段）', () async {
      const String owner = 'theme.keepbusiness';
      final SettingsController controller = SettingsController(
        repository: await openRepository(),
        ownerId: owner,
      );
      await controller.load();
      await controller.setScale(3.0);
      await controller.setOpacity(0.6);
      await controller.setUsageStatsTab(AppSettings.usageStatsTabCloud);
      await controller.setThemePrimaryColor('#EEF4FF');
      await controller.setThemeAccentColor('#10B981');

      await AppDatabase.close();
      final SettingsController restarted = SettingsController(
        repository: await openRepository(),
        ownerId: owner,
      );
      await restarted.load();

      expect(restarted.settings.scale, 3.0);
      expect(restarted.settings.opacity, 0.6);
      expect(restarted.settings.usageStatsTab, AppSettings.usageStatsTabCloud);
      expect(restarted.settings.themePrimaryColor, '#EEF4FF');
      expect(restarted.settings.themeAccentColor, '#10B981');
    });

    test('恢复默认设置会把主题也复位（主色回白、强调色回粉）', () async {
      const String owner = 'theme.reset';
      final SettingsController controller = SettingsController(
        repository: await openRepository(),
        ownerId: owner,
      );
      await controller.load();
      await controller.setThemePrimaryColor('#1B1620');
      await controller.setThemeAccentColor('#EF4444');
      await controller.resetToDefaults();

      await AppDatabase.close();
      final SettingsController restarted = SettingsController(
        repository: await openRepository(),
        ownerId: owner,
      );
      await restarted.load();
      expect(restarted.settings.themePrimaryColor, '#FFFFFF');
      expect(restarted.settings.themeAccentColor, '#F24D96');
      expect(restarted.settings.themeMode, AppSettings.themeModeLight);
    });
  });
}

/// 内存版设置仓储（纯逻辑用例用；真实落盘由上面的 SQLite 组覆盖）。
class _MemorySettingsRepository implements SettingsRepository {
  final Map<String, AppSettings> _store = <String, AppSettings>{};

  @override
  Future<AppSettings> load(String ownerId) async =>
      _store[ownerId] ?? const AppSettings();

  @override
  Future<void> save(String ownerId, AppSettings settings) async {
    _store[ownerId] = settings;
  }

  @override
  Future<void> patch(String ownerId, Map<String, String?> values) async {
    final AppSettings current = await load(ownerId);
    final Map<String, String> merged = current.toKeyValues()
      ..addAll(<String, String>{
        for (final MapEntry<String, String?> e in values.entries)
          if (e.value != null) e.key: e.value!,
      });
    _store[ownerId] = AppSettings.fromKeyValues(merged);
  }

  @override
  Future<void> reset(String ownerId) async {
    _store.remove(ownerId);
  }
}

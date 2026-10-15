import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

import 'design_tokens.dart';

/// 主题模式（需求 §3「跟随系统明暗模式」）。
///
/// 默认 [light]：需求 §13 明确要求「默认是白色＋P3P 粉色」，并且验收要求
/// 「默认界面一眼可判定为白色主题」。若默认跟随系统，在深色系统上首次启动
/// 就会是暗色界面，直接与验收冲突 —— 因此「跟随系统」必须由用户显式选择。
enum PetLifeThemeMode {
  light('light', '浅色'),
  dark('dark', '深色'),
  system('system', '跟随系统');

  const PetLifeThemeMode(this.wireName, this.labelZh);

  final String wireName;
  final String labelZh;

  /// 解析持久化取值；非法值一律回落到 [light]（与设置归一化同口径）。
  static PetLifeThemeMode fromWire(String? raw) {
    for (final PetLifeThemeMode mode in PetLifeThemeMode.values) {
      if (mode.wireName == raw) return mode;
    }
    return PetLifeThemeMode.light;
  }

  static List<String> get wireNames =>
      <String>[for (final PetLifeThemeMode m in PetLifeThemeMode.values) m.wireName];
}

// -----------------------------------------------------------------------------
// 颜色工具
// -----------------------------------------------------------------------------

/// 解析 `#RRGGBB` / `#AARRGGBB`（大小写与 `#` 都可省略）。
///
/// 解析失败返回 null —— 调用方负责回落到默认值，**绝不抛异常**：
/// 一个手改数据库的脏值不应该让整个应用起不来。
Color? petLifeColorFromHex(String? raw) {
  if (raw == null) return null;
  String text = raw.trim();
  if (text.isEmpty) return null;
  if (text.startsWith('#')) text = text.substring(1);
  if (text.length == 6) text = 'FF$text';
  if (text.length != 8) return null;
  final int? value = int.tryParse(text, radix: 16);
  if (value == null) return null;
  return Color(value);
}

/// 序列化成 `#RRGGBB`（丢弃 alpha：主题色只关心 RGB）。
String petLifeColorToHex(Color color) {
  final int rgb = color.toARGB32() & 0x00FFFFFF;
  return '#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}';
}

/// 相对亮度（WCAG 2.1）。
double _luminance(Color c) => c.computeLuminance();

/// WCAG 对比度，范围 1.0 ~ 21.0。
double petLifeContrastRatio(Color a, Color b) {
  final double la = _luminance(a);
  final double lb = _luminance(b);
  final double hi = math.max(la, lb);
  final double lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

/// 按背景亮度自动生成**可读**的文字 / 图标色。
///
/// 需求：「系统必须根据背景亮度自动生成可读文字色，禁止出现白字白底或同色按钮」，
/// 以及「对比度不足时自动调整文字和图标颜色，而不是拒绝用户选择」。
///
/// 规则：从 [candidates] 里挑第一个达到 [target] 对比度的；都不达标时挑对比度
/// 最高的那个 —— 于是**永远**返回一个可读结果，而不是抛错或返回隐形颜色。
Color petLifeReadableOn(
  Color background, {
  required List<Color> candidates,
  double target = 4.5,
}) {
  Color best = candidates.first;
  double bestRatio = petLifeContrastRatio(best, background);
  for (final Color candidate in candidates) {
    final double ratio = petLifeContrastRatio(candidate, background);
    if (ratio >= target) return candidate;
    if (ratio > bestRatio) {
      best = candidate;
      bestRatio = ratio;
    }
  }
  return best;
}

/// 把 [foreground] 朝更亮 / 更暗方向微调，直到与 [background] 达到 [target]。
///
/// 用于危险 / 成功 / 警告这类**语义固定**的颜色：它们在深色表面上不能直接照搬，
/// 但也不该换成别的颜色（那就不再是「危险色」了）。
Color petLifeEnsureReadable(
  Color foreground,
  Color background, {
  double target = 4.5,
}) {
  if (petLifeContrastRatio(foreground, background) >= target) return foreground;
  final bool towardsWhite = _luminance(background) < 0.5;
  final Color pole = towardsWhite ? const Color(0xFFFFFFFF) : const Color(0xFF000000);
  Color best = foreground;
  double bestRatio = petLifeContrastRatio(best, background);
  for (int i = 1; i <= 20; i++) {
    final Color candidate = Color.lerp(foreground, pole, i / 20)!;
    final double ratio = petLifeContrastRatio(candidate, background);
    if (ratio >= target) return candidate;
    if (ratio > bestRatio) {
      best = candidate;
      bestRatio = ratio;
    }
  }
  return best;
}

// -----------------------------------------------------------------------------
// 调色板
// -----------------------------------------------------------------------------

/// 由「主色 + 强调色 + 明暗」派生出的完整调色板。
///
/// **所有**页面颜色都必须从这里取（通过 `PetLifeTheme.of(context)`），
/// 不允许任何页面硬编码粉色 / 灰色。
@immutable
class PetLifePalette {
  const PetLifePalette({
    required this.brightness,
    required this.primary,
    required this.accent,
    required this.surface,
    required this.card,
    required this.muted,
    required this.border,
    required this.divider,
    required this.accentSoft,
    required this.onAccent,
    required this.onAccentSoft,
    required this.textPrimary,
    required this.textSecondary,
    required this.textDisabled,
    required this.danger,
    required this.success,
    required this.warning,
    required this.onDanger,
    required this.shadow,
  });

  final Brightness brightness;

  /// 用户选择的原始主色（未派生）。
  final Color primary;

  /// 用户选择的原始强调色（未派生）。
  final Color accent;

  /// 页面背景 / 顶部栏 / 底部导航表面 / 弹窗表面。
  final Color surface;

  /// 卡片表面。
  final Color card;

  /// 次级背景（#FFF7FB 同族）。
  final Color muted;

  /// 普通卡片描边（主色派生的低对比色）。
  final Color border;

  /// 分割线（**只在必要时**使用；需求要求不再用大量灰色分割线组织内容）。
  final Color divider;

  /// 强调色的柔和载体（选中标签底、图标底）。
  final Color accentSoft;

  /// 强调色上的文字 / 图标（按对比度自动选择）。
  final Color onAccent;

  /// 强调色柔和底上的文字（仍是强调色本身，但已保证可读）。
  final Color onAccentSoft;

  final Color textPrimary;
  final Color textSecondary;
  final Color textDisabled;

  final Color danger;
  final Color success;
  final Color warning;
  final Color onDanger;

  /// 卡片阴影色（极轻）。
  final Color shadow;

  bool get isDark => brightness == Brightness.dark;

  /// 由主色与强调色解析出调色板。
  ///
  /// 派生规则（需求 §3）：
  /// * **主色**决定 [surface] / [card]；
  /// * **强调色**决定 [accent]，并参与 [muted] 的着色；
  /// * 文字色由背景亮度**自动**生成，因此永远不会出现白字白底。
  factory PetLifePalette.resolve({
    required Color primary,
    required Color accent,
    required Brightness brightness,
  }) {
    final bool dark = brightness == Brightness.dark;

    final Color surface = dark ? _darkSurface(primary, accent) : primary;
    final Color card = dark ? _lift(surface, 0.06) : primary;

    // 次级背景：强调色 5% 叠在主色上（#FFFFFF + #F24D96 5% ≈ #FEF6FA，
    // 与需求给出的 #FFF7FB 基本一致，且对任意主色都成立）。
    final Color muted = dark
        ? _lift(surface, 0.10)
        : Color.alphaBlend(accent.withValues(alpha: 0.05), surface);

    final Color textPrimary = petLifeReadableOn(
      card,
      candidates: <Color>[PetLifeColors.textPrimaryDefault, Colors.white, Colors.black],
    );
    final Color textSecondary = dark
        ? Color.alphaBlend(textPrimary.withValues(alpha: 0.72), card)
        : petLifeReadableOn(
            card,
            candidates: <Color>[
              PetLifeColors.textSecondaryDefault,
              textPrimary,
            ],
          );

    // 描边从**主色**派生："低对比"即可，不需要额外装饰。
    final Color border = dark ? _lift(surface, 0.16) : _mix(primary, textPrimary, 0.10);
    final Color divider = dark ? _lift(surface, 0.12) : _mix(primary, textPrimary, 0.07);

    // 强调色上的文字：优先白色（设计意图），但必须达到 3.0 对比度；
    // 达不到时自动改用深色 —— 这样「浅黄强调色 + 白字」不会变成隐形按钮。
    final Color onAccent = petLifeReadableOn(
      accent,
      candidates: <Color>[Colors.white, textPrimary, Colors.black],
      target: 3.0,
    );
    final Color accentSoft = dark
        ? Color.alphaBlend(accent.withValues(alpha: 0.22), card)
        : Color.alphaBlend(accent.withValues(alpha: 0.12), card);
    // 柔和底上的强调色文字：色相仍然是强调色，只调整明度以满足对比度。
    final Color onAccentSoft = petLifeEnsureReadable(
      dark ? _lift(accent, 0.20) : accent,
      accentSoft,
      target: 4.5,
    );

    final Color danger = petLifeEnsureReadable(
      PetLifeColors.dangerDefault,
      card,
    );
    final Color success = petLifeEnsureReadable(
      PetLifeColors.successDefault,
      card,
    );
    final Color warning = dark
        ? PetLifeColors.warningDefault
        : _mix(PetLifeColors.warningDefault, Colors.black, 0.10);

    return PetLifePalette(
      brightness: brightness,
      primary: primary,
      accent: accent,
      surface: surface,
      card: card,
      muted: muted,
      border: border,
      divider: divider,
      accentSoft: accentSoft,
      onAccent: onAccent,
      onAccentSoft: onAccentSoft,
      textPrimary: textPrimary,
      textSecondary: textSecondary,
      textDisabled: textSecondary.withValues(alpha: 0.45),
      danger: danger,
      success: success,
      warning: warning,
      onDanger: petLifeReadableOn(
        danger,
        candidates: <Color>[Colors.white, Colors.black],
        target: 3.0,
      ),
      shadow: textPrimary.withValues(alpha: dark ? 0.30 : 0.06),
    );
  }

  /// 深色模式下的表面色：由主色的**色相**推导，而不是简单反色。
  ///
  /// 用户显式选了深色主色时直接沿用；选了浅色 / 白色时借用强调色色相生成
  /// 带一点粉调的深色底，避免死灰。
  static Color _darkSurface(Color primary, Color accent) {
    if (_luminance(primary) < 0.42) return primary;
    final HSLColor hsl = HSLColor.fromColor(primary);
    final HSLColor accentHsl = HSLColor.fromColor(accent);
    final bool achromatic = hsl.saturation < 0.06;
    return HSLColor.fromAHSL(
      1.0,
      achromatic ? accentHsl.hue : hsl.hue,
      achromatic ? 0.16 : math.min(hsl.saturation, 0.30),
      0.10,
    ).toColor();
  }

  static Color _mix(Color a, Color b, double t) => Color.lerp(a, b, t) ?? a;

  /// 在保持色相的前提下提亮。
  static Color _lift(Color base, double amount) {
    final HSLColor hsl = HSLColor.fromColor(base);
    return hsl
        .withLightness((hsl.lightness + amount).clamp(0.0, 1.0))
        .toColor();
  }

  /// 线性插值：主题切换时用，实现「颜色渐变，不整页闪白」。
  static PetLifePalette lerp(PetLifePalette a, PetLifePalette b, double t) {
    Color c(Color x, Color y) => Color.lerp(x, y, t) ?? x;
    return PetLifePalette(
      brightness: t < 0.5 ? a.brightness : b.brightness,
      primary: c(a.primary, b.primary),
      accent: c(a.accent, b.accent),
      surface: c(a.surface, b.surface),
      card: c(a.card, b.card),
      muted: c(a.muted, b.muted),
      border: c(a.border, b.border),
      divider: c(a.divider, b.divider),
      accentSoft: c(a.accentSoft, b.accentSoft),
      onAccent: c(a.onAccent, b.onAccent),
      onAccentSoft: c(a.onAccentSoft, b.onAccentSoft),
      textPrimary: c(a.textPrimary, b.textPrimary),
      textSecondary: c(a.textSecondary, b.textSecondary),
      textDisabled: c(a.textDisabled, b.textDisabled),
      danger: c(a.danger, b.danger),
      success: c(a.success, b.success),
      warning: c(a.warning, b.warning),
      onDanger: c(a.onDanger, b.onDanger),
      shadow: c(a.shadow, b.shadow),
    );
  }
}

/// 兜底调色板：只有当组件被放在**没有安装 [PetLifeTheme] 的** `MaterialApp`
/// 下时才会用到（例如既有测试直接 pump 单个页面）。
///
/// 它必须等于默认主题，否则「同一个页面在测试里和在应用里长得不一样」。
final PetLifePalette petLifeFallbackPalette = PetLifePalette.resolve(
  primary: PetLifeColors.primaryDefault,
  accent: PetLifeColors.accentDefault,
  brightness: Brightness.light,
);

/// 把调色板挂到 [ThemeData.extensions]，页面用 `PetLifeTheme.of(context)` 取。
@immutable
class PetLifeTheme extends ThemeExtension<PetLifeTheme> {
  const PetLifeTheme({
    required this.palette,
    this.cardEntranceAnimated = true,
  });

  final PetLifePalette palette;

  /// 卡片是否播放"淡入 + 上移"的进场动画。
  ///
  /// * Android：`true`（首屏卡片有轻微入场，属于移动端习惯）；
  /// * Windows 控制面板：`false` —— 需求 §9 明确禁止桌面端
  ///   「启动时逐卡片依次播放」，桌面要的是"打开即就绪"。
  ///
  /// 由主题统一下发，因此**同一份页面代码**在两个平台各自得到正确行为，
  /// 不需要页面自己判断平台。
  final bool cardEntranceAnimated;

  static PetLifePalette of(BuildContext context) =>
      Theme.of(context).extension<PetLifeTheme>()?.palette ?? petLifeFallbackPalette;

  /// 「当前是否安装了 PetLife 主题」。
  ///
  /// 用于诊断与测试；**不再**作为"要不要回退旧界面"的依据 ——
  /// 回退只由 `useLegacyDesktopControlPanel` 显式开关决定（见
  /// `ui/desktop/desktop_panel_flags.dart`），不允许静默回退。
  static PetLifePalette? maybeOf(BuildContext context) =>
      Theme.of(context).extension<PetLifeTheme>()?.palette;

  /// 卡片进场动画开关（没有装主题时按"有动画"处理，与移动端默认一致）。
  static bool cardEntranceAnimatedOf(BuildContext context) =>
      Theme.of(context).extension<PetLifeTheme>()?.cardEntranceAnimated ?? true;

  /// 当前是否已装配 PetLife 主题（桌面外壳必须装配，见需求 §12）。
  static bool isInstalled(BuildContext context) =>
      Theme.of(context).extension<PetLifeTheme>() != null;

  @override
  PetLifeTheme copyWith({PetLifePalette? palette, bool? cardEntranceAnimated}) =>
      PetLifeTheme(
        palette: palette ?? this.palette,
        cardEntranceAnimated: cardEntranceAnimated ?? this.cardEntranceAnimated,
      );

  @override
  PetLifeTheme lerp(ThemeExtension<PetLifeTheme>? other, double t) {
    if (other is! PetLifeTheme) return this;
    return PetLifeTheme(
      palette: PetLifePalette.lerp(palette, other.palette, t),
      // 布尔开关不插值：过半即切换，避免动画中途来回跳。
      cardEntranceAnimated: t < 0.5 ? cardEntranceAnimated : other.cardEntranceAnimated,
    );
  }
}

// -----------------------------------------------------------------------------
// ThemeData 生成
// -----------------------------------------------------------------------------

/// 生成 Android / Windows 控制面板共用的完整 [ThemeData]。
///
/// [primary] 控制表面色，[accent] 控制交互高亮；两者**互相独立**——
/// 任何一处改动都不会覆盖另一处。
///
/// [fontFamily] 只有 Windows 需要传（微软雅黑）；Android 传 null 交给系统默认字体，
/// 否则中文会回退到不含中文的字形而显示成方框。
ThemeData buildPetLifeThemeData({
  required Color primary,
  required Color accent,
  required Brightness brightness,
  String? fontFamily,
  bool cardEntranceAnimated = true,
}) {
  final PetLifePalette p = PetLifePalette.resolve(
    primary: primary,
    accent: accent,
    brightness: brightness,
  );

  final ColorScheme scheme = ColorScheme.fromSeed(
    seedColor: accent,
    brightness: brightness,
  ).copyWith(
    primary: accent,
    onPrimary: p.onAccent,
    primaryContainer: p.accentSoft,
    onPrimaryContainer: p.onAccentSoft,
    secondary: p.onAccentSoft,
    onSecondary: p.onAccent,
    surface: p.surface,
    onSurface: p.textPrimary,
    surfaceContainerLowest: p.card,
    surfaceContainerLow: p.card,
    surfaceContainer: p.card,
    surfaceContainerHigh: p.muted,
    surfaceContainerHighest: p.muted,
    onSurfaceVariant: p.textSecondary,
    outline: p.border,
    outlineVariant: p.divider,
    error: p.danger,
    onError: p.onDanger,
    shadow: p.shadow,
    scrim: p.textPrimary.withValues(alpha: 0.4),
  );

  final TextTheme text = _textTheme(p);
  final ButtonStyle filled = FilledButton.styleFrom(
    backgroundColor: accent,
    foregroundColor: p.onAccent,
    disabledBackgroundColor: p.border,
    disabledForegroundColor: p.textDisabled,
    minimumSize: const Size(0, PetLifeSpacing.minTouch),
    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
    shape: const RoundedRectangleBorder(borderRadius: PetLifeRadii.buttonBorder),
    textStyle: const TextStyle(fontSize: PetLifeText.body, fontWeight: FontWeight.w600),
  );
  final ButtonStyle outlined = OutlinedButton.styleFrom(
    foregroundColor: p.textPrimary,
    side: BorderSide(color: p.border),
    minimumSize: const Size(0, PetLifeSpacing.minTouch),
    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
    shape: const RoundedRectangleBorder(borderRadius: PetLifeRadii.buttonBorder),
    textStyle: const TextStyle(fontSize: PetLifeText.body, fontWeight: FontWeight.w600),
  );
  final ButtonStyle text2 = TextButton.styleFrom(
    foregroundColor: p.onAccentSoft,
    minimumSize: const Size(PetLifeSpacing.minTouch, PetLifeSpacing.minTouch),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    shape: const RoundedRectangleBorder(borderRadius: PetLifeRadii.buttonBorder),
    textStyle: const TextStyle(fontSize: PetLifeText.body, fontWeight: FontWeight.w600),
  );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    fontFamily: fontFamily,
    colorScheme: scheme,
    scaffoldBackgroundColor: p.surface,
    canvasColor: p.surface,
    cardColor: p.card,
    dividerColor: p.divider,
    shadowColor: p.shadow,
    splashColor: accent.withValues(alpha: 0.10),
    highlightColor: accent.withValues(alpha: 0.06),
    extensions: <ThemeExtension<dynamic>>[
      PetLifeTheme(palette: p, cardEntranceAnimated: cardEntranceAnimated),
    ],
    textTheme: text,
    primaryTextTheme: text,
    // 顶部栏不做厚重纯色 AppBar：本应用用自绘标题区，这里只兜底。
    appBarTheme: AppBarTheme(
      backgroundColor: p.surface,
      foregroundColor: p.textPrimary,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontSize: PetLifeText.pageTitle,
        fontWeight: FontWeight.w700,
        color: p.textPrimary,
      ),
    ),
    cardTheme: CardThemeData(
      color: p.card,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: PetLifeRadii.cardBorder,
        side: BorderSide(color: p.border),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: p.surface,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(borderRadius: PetLifeRadii.dialogBorder),
      titleTextStyle: TextStyle(
        fontSize: PetLifeText.cardTitle,
        fontWeight: FontWeight.w700,
        color: p.textPrimary,
      ),
      contentTextStyle: TextStyle(fontSize: PetLifeText.bodySmall, color: p.textPrimary),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: p.surface,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: PetLifeRadii.radiusDialog),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: p.surface,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(borderRadius: PetLifeRadii.cardBorder),
      textStyle: TextStyle(fontSize: PetLifeText.bodySmall, color: p.textPrimary),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: p.textPrimary,
      contentTextStyle: TextStyle(fontSize: PetLifeText.bodySmall, color: p.surface),
      actionTextColor: p.onAccentSoft,
      behavior: SnackBarBehavior.floating,
      shape: const RoundedRectangleBorder(borderRadius: PetLifeRadii.buttonBorder),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.muted,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      hintStyle: TextStyle(color: p.textDisabled, fontSize: PetLifeText.bodySmall),
      labelStyle: TextStyle(color: p.textSecondary, fontSize: PetLifeText.bodySmall),
      helperStyle: TextStyle(color: p.textSecondary, fontSize: PetLifeText.caption),
      errorStyle: TextStyle(color: p.danger, fontSize: PetLifeText.caption),
      border: OutlineInputBorder(
        borderRadius: PetLifeRadii.fieldBorder,
        borderSide: BorderSide(color: p.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: PetLifeRadii.fieldBorder,
        borderSide: BorderSide(color: p.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: PetLifeRadii.fieldBorder,
        borderSide: BorderSide(color: accent, width: 1.6),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: PetLifeRadii.fieldBorder,
        borderSide: BorderSide(color: p.danger),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: PetLifeRadii.fieldBorder,
        borderSide: BorderSide(color: p.danger, width: 1.6),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(style: filled),
    outlinedButtonTheme: OutlinedButtonThemeData(style: outlined),
    textButtonTheme: TextButtonThemeData(style: text2),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: accent,
      foregroundColor: p.onAccent,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((Set<WidgetState> states) {
        if (states.contains(WidgetState.disabled)) return p.textDisabled;
        return states.contains(WidgetState.selected) ? p.onAccent : p.card;
      }),
      trackColor: WidgetStateProperty.resolveWith((Set<WidgetState> states) {
        if (states.contains(WidgetState.disabled)) return p.border;
        return states.contains(WidgetState.selected) ? accent : p.muted;
      }),
      trackOutlineColor: WidgetStateProperty.resolveWith(
        (Set<WidgetState> states) =>
            states.contains(WidgetState.selected) ? accent : p.border,
      ),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (Set<WidgetState> states) =>
            states.contains(WidgetState.selected) ? accent : Colors.transparent,
      ),
      checkColor: WidgetStatePropertyAll<Color>(p.onAccent),
      side: BorderSide(color: p.border, width: 1.5),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(6)),
      ),
    ),
    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (Set<WidgetState> states) =>
            states.contains(WidgetState.selected) ? accent : p.border,
      ),
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: accent,
      inactiveTrackColor: p.muted,
      thumbColor: accent,
      overlayColor: accent.withValues(alpha: 0.14),
      valueIndicatorColor: accent,
      valueIndicatorTextStyle: TextStyle(color: p.onAccent),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: accent,
      linearTrackColor: p.muted,
      circularTrackColor: p.muted,
    ),
    chipTheme: ChipThemeData(
      backgroundColor: p.muted,
      selectedColor: p.accentSoft,
      side: BorderSide(color: p.border),
      labelStyle: TextStyle(fontSize: PetLifeText.caption, color: p.textPrimary),
      secondaryLabelStyle: TextStyle(fontSize: PetLifeText.caption, color: p.onAccentSoft),
      shape: const StadiumBorder(),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith(
          (Set<WidgetState> states) =>
              states.contains(WidgetState.selected) ? p.accentSoft : p.card,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (Set<WidgetState> states) =>
              states.contains(WidgetState.selected) ? p.onAccentSoft : p.textSecondary,
        ),
        side: WidgetStatePropertyAll<BorderSide>(BorderSide(color: p.border)),
        minimumSize: const WidgetStatePropertyAll<Size>(
          Size(0, PetLifeSpacing.minTouch),
        ),
        textStyle: const WidgetStatePropertyAll<TextStyle>(
          TextStyle(fontSize: PetLifeText.caption, fontWeight: FontWeight.w600),
        ),
      ),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: p.textSecondary,
      textColor: p.textPrimary,
      titleTextStyle: TextStyle(fontSize: PetLifeText.bodySmall, color: p.textPrimary),
      subtitleTextStyle: TextStyle(fontSize: PetLifeText.caption, color: p.textSecondary),
    ),
    dividerTheme: DividerThemeData(color: p.divider, thickness: 1, space: 1),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: p.textPrimary,
        borderRadius: PetLifeRadii.buttonBorder,
      ),
      textStyle: TextStyle(fontSize: PetLifeText.caption, color: p.surface),
    ),
    // 页面切换用自定义动画（见 PetLifeAnimatedSwitcher），这里只兜底。
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: <TargetPlatform, PageTransitionsBuilder>{
        TargetPlatform.android: FadeUpwardsPageTransitionsBuilder(),
      },
    ),
  );
}

TextTheme _textTheme(PetLifePalette p) {
  TextStyle style(double size, FontWeight weight, Color color, {double? height}) =>
      TextStyle(fontSize: size, fontWeight: weight, color: color, height: height);
  return TextTheme(
    displayLarge: style(PetLifeText.displayLarge, FontWeight.w700, p.textPrimary),
    displayMedium: style(PetLifeText.display, FontWeight.w700, p.textPrimary),
    displaySmall: style(PetLifeText.pageTitle, FontWeight.w700, p.textPrimary),
    headlineMedium: style(PetLifeText.pageTitle, FontWeight.w700, p.textPrimary),
    headlineSmall: style(PetLifeText.cardTitle, FontWeight.w600, p.textPrimary),
    titleLarge: style(PetLifeText.cardTitle, FontWeight.w600, p.textPrimary),
    titleMedium: style(PetLifeText.body, FontWeight.w600, p.textPrimary),
    titleSmall: style(PetLifeText.bodySmall, FontWeight.w600, p.textPrimary),
    bodyLarge: style(PetLifeText.body, FontWeight.w400, p.textPrimary),
    bodyMedium: style(PetLifeText.bodySmall, FontWeight.w400, p.textPrimary),
    bodySmall: style(PetLifeText.caption, FontWeight.w400, p.textSecondary),
    labelLarge: style(PetLifeText.bodySmall, FontWeight.w600, p.textPrimary),
    labelMedium: style(PetLifeText.caption, FontWeight.w600, p.textPrimary),
    labelSmall: style(PetLifeText.captionSmall, FontWeight.w500, p.textSecondary),
  );
}

/// 供动画插值使用的 double 工具（主题切换的圆角 / 阴影过渡）。
double petLifeLerpDouble(double a, double b, double t) => lerpDouble(a, b, t) ?? a;

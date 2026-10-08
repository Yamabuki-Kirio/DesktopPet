/// 轮盘主题（**Android `WheelMenuTheme.kt` / `WheelMenuThemes` 的 1:1 移植**）。
///
/// 移植纪律（增量 B 决策四）：
/// * 全部颜色用 **`int` ARGB** 表达（与 Android 完全相同），不引入 Android 不存在的
///   "深色 / 次文字"等自创字段 —— 只有 Android 有的七个颜色 + 两个开关；
/// * P3P 粉色的六个颜色是需求给定的，**逐字一致**，不得改动；
/// * 其余预设只钉一个**主色**，其余全部派生 —— 于是"新增预设"不会引入一整套手抄常量；
/// * `themeId` 的 wire 取值与 Android 逐字一致（`p3p-pink`，不是 `p3p_pink`）。
///
/// 本文件是**纯 Dart**（只依赖 `dart:math`），可在 `flutter_tester` 直接单测。
library;

import 'dart:math' as math;

/// 动画风格取值（Android `WheelMenuTheme.ANIMATION_STANDARD` / `ANIMATION_CALM`）。
class WheelAnimationStyles {
  WheelAnimationStyles._();

  static const String standard = 'standard';
  static const String calm = 'calm';
}

/// 主题 id 的 wire 取值（Android `WheelMenuThemes.ID_*`，逐字一致）。
class WheelThemeIds {
  WheelThemeIds._();

  static const String p3pPink = 'p3p-pink';
  static const String blue = 'blue';
  static const String red = 'red';
  static const String purple = 'purple';
  static const String green = 'green';

  /// 自定义主题的固定 id（用户选了自定义主色后用它）。
  static const String custom = 'custom';
}

/// 一套轮盘配色（不可变）—— 字段与 Android `WheelMenuTheme` **一一对应**。
class WheelMenuTheme {
  const WheelMenuTheme({
    required this.themeId,
    required this.displayName,
    required this.primary,
    required this.secondary,
    required this.background,
    required this.highlight,
    required this.outline,
    required this.text,
    required this.disabled,
    this.gradientEnabled = true,
    this.animationStyle = WheelAnimationStyles.standard,
    this.revision = 0,
  });

  /// 稳定 id（`p3p-pink` / `blue` / `custom` …），绝不随文案变化。
  final String themeId;

  /// 展示名（设置页用，**任何业务判断都不得依赖它**）。
  final String displayName;

  /// 主色：按钮底、高亮扇区主调。
  final int primary;

  /// 派生亮色：扇区渐变外端。
  final int secondary;

  /// 环带底色（浅色，保证白色图标可辨）。
  final int background;

  /// 强调色（装饰弧 / 实时数值）。
  final int highlight;

  /// 粗黑描边。
  final int outline;

  /// 大标题与中文名文字色。
  final int text;

  /// 不可用项。
  final int disabled;

  /// 是否启用刀刃渐变。
  final bool gradientEnabled;

  /// 动画风格（[WheelAnimationStyles]）。
  final String animationStyle;

  /// 配置版本号：防止旧配置覆盖新配置。
  final int revision;

  WheelMenuTheme copyWith({
    String? themeId,
    String? displayName,
    int? primary,
    int? secondary,
    int? background,
    int? highlight,
    int? outline,
    int? text,
    int? disabled,
    bool? gradientEnabled,
    String? animationStyle,
    int? revision,
  }) =>
      WheelMenuTheme(
        themeId: themeId ?? this.themeId,
        displayName: displayName ?? this.displayName,
        primary: primary ?? this.primary,
        secondary: secondary ?? this.secondary,
        background: background ?? this.background,
        highlight: highlight ?? this.highlight,
        outline: outline ?? this.outline,
        text: text ?? this.text,
        disabled: disabled ?? this.disabled,
        gradientEnabled: gradientEnabled ?? this.gradientEnabled,
        animationStyle: animationStyle ?? this.animationStyle,
        revision: revision ?? this.revision,
      );

  /// 解析持久化值（Android `WheelMenuTheme.fromWire`）。
  ///
  /// * 空 → P3P 粉；
  /// * `custom` → 用 [customPrimary] 派生；
  /// * 其它 → 命中预设则用预设，未命中回退 P3P 粉。
  static WheelMenuTheme fromWire(
    String? themeId,
    int customPrimary, {
    int revision = 0,
  }) {
    final String id = themeId?.trim() ?? '';
    final WheelMenuTheme resolved;
    if (id.isEmpty) {
      resolved = WheelMenuThemes.p3pPink();
    } else if (id == WheelThemeIds.custom) {
      resolved = WheelMenuThemes.custom(customPrimary);
    } else {
      resolved = WheelMenuThemes.preset(id) ?? WheelMenuThemes.p3pPink();
    }
    return resolved.copyWith(revision: revision);
  }

  @override
  String toString() =>
      'WheelMenuTheme($themeId primary=${WheelMenuThemes.toHex(primary)})';
}

/// 主题预设与派生算法（**纯函数**，Android `WheelMenuThemes` 1:1）。
class WheelMenuThemes {
  WheelMenuThemes._();

  // --- 预设 id ---
  static const String idP3p = WheelThemeIds.p3pPink;
  static const String idBlue = WheelThemeIds.blue;
  static const String idRed = WheelThemeIds.red;
  static const String idPurple = WheelThemeIds.purple;
  static const String idGreen = WheelThemeIds.green;
  static const String idCustom = WheelThemeIds.custom;

  // --- 需求给定的默认色板（逐字一致，不得改动）---
  static const int p3pPrimary = 0xFFF24D96;
  static const int p3pSecondary = 0xFFFF8ABA;
  static const int p3pBackground = 0xFFFFD8E9;
  static const int p3pHighlight = 0xFFFFD42A;
  static const int p3pOutline = 0xFF111111;
  static const int p3pText = 0xFFFFFFFF;
  static const int p3pDisabled = 0xFF8E7180;

  // --- 其它预设的主色（各自派生完整色板）---
  static const int bluePrimary = 0xFF2F7CF6;
  static const int redPrimary = 0xFFE23B3B;
  static const int purplePrimary = 0xFF8B4DE0;
  static const int greenPrimary = 0xFF1FA463;

  /// 强调色固定为 P3P 黄（各主题共用，保证"黄色高光"这一视觉语言一致）。
  static const int accentHighlight = p3pHighlight;

  /// 描边固定为近黑（P3P 的"粗黑描边"）。
  static const int outlineBlack = p3pOutline;

  /// 文字与背景的最小对比度（WCAG 大号粗体阈值）。
  static const double minTextContrast = 3.0;

  /// 底色扇面的混合比例（0 = 纯 secondary，1 = 纯 background）。
  static const double baseFanBlendToBackground = 0.40;

  /// 底色扇面的 alpha（约 40% 透明，压在人物层下方）。
  static const int baseFanAlpha = 108;

  static const int _white = 0xFFFFFFFF;
  static const int _ink = 0xFF000000;
  static const int _greyMid = 0xFF808080;

  /// 所有内置预设（顺序即设置页展示顺序）。
  static final List<WheelMenuTheme> presets = <WheelMenuTheme>[
    p3pPink(),
    _derivedPreset(idBlue, '蓝色', bluePrimary),
    _derivedPreset(idRed, '红色', redPrimary),
    _derivedPreset(idPurple, '紫色', purplePrimary),
    _derivedPreset(idGreen, '绿色', greenPrimary),
  ];

  /// 默认主题 = P3P 粉色。
  static WheelMenuTheme defaultTheme() => p3pPink();

  static WheelMenuTheme p3pPink() => const WheelMenuTheme(
        themeId: idP3p,
        displayName: 'P3P 粉色',
        primary: p3pPrimary,
        secondary: p3pSecondary,
        background: p3pBackground,
        highlight: p3pHighlight,
        outline: p3pOutline,
        text: p3pText,
        disabled: p3pDisabled,
      );

  static WheelMenuTheme? preset(String? themeId) {
    for (final WheelMenuTheme theme in presets) {
      if (theme.themeId == themeId) return theme;
    }
    return null;
  }

  /// 用户自定义主色 → 完整主题（其余颜色派生，文字色按对比度自动选择）。
  static WheelMenuTheme custom(int primaryColor) {
    final int primary = opaque(primaryColor);
    return WheelMenuTheme(
      themeId: idCustom,
      displayName: '自定义',
      primary: primary,
      secondary: lighten(primary, 0.42),
      background: mix(primary, _white, 0.84),
      highlight: accentHighlight,
      outline: outlineBlack,
      text: autoTextColor(primary),
      disabled: mix(primary, _greyMid, 0.55),
    );
  }

  static WheelMenuTheme _derivedPreset(String id, String name, int primary) =>
      custom(primary).copyWith(themeId: id, displayName: name);

  /// 文字色自动选择：只要白字达到大号粗体可读阈值就用白色（规则刻意偏向白字）。
  static int autoTextColor(int onSurface) =>
      contrastRatio(_white, onSurface) >= minTextContrast ? _white : _ink;

  /// 主题是否"可辨认"：文字对主色的对比度达标。
  static bool isLegible(WheelMenuTheme theme) =>
      contrastRatio(theme.text, theme.primary) >= minTextContrast;

  /// 相对亮度（WCAG 2.x 定义）。
  static double relativeLuminance(int color) {
    final int r = channel(color, 16);
    final int g = channel(color, 8);
    final int b = channel(color, 0);
    return 0.2126 * _linearize(r) + 0.7152 * _linearize(g) + 0.0722 * _linearize(b);
  }

  /// 对比度（1.0 ~ 21.0）。
  static double contrastRatio(int a, int b) {
    final double la = relativeLuminance(a);
    final double lb = relativeLuminance(b);
    final double lighter = math.max(la, lb);
    final double darker = math.min(la, lb);
    return (lighter + 0.05) / (darker + 0.05);
  }

  /// 菜单**底色扇面**的颜色：`secondary` 向 `background` 混 40%，再压 alpha=108。
  ///
  /// 调用方只把它填在**打开方向的扇形**上 —— 不返回整圆的颜色语义。
  static int baseFanColor(WheelMenuTheme theme) =>
      withAlpha(mix(theme.secondary, theme.background, baseFanBlendToBackground), baseFanAlpha);

  /// 给不透明 RGB 补上 alpha（越界自动夹取）。
  static int withAlpha(int color, int alpha) =>
      ((alpha.clamp(0, 255)) << 24) | (color & 0x00FFFFFF);

  /// 线性混合：`t = 0` 取 [a]，`t = 1` 取 [b]。
  static int mix(int a, int b, double t) {
    final double ratio = t.clamp(0.0, 1.0);
    int blend(int shift) {
      final int va = channel(a, shift);
      final int vb = channel(b, shift);
      return (va + (vb - va) * ratio).round().clamp(0, 255);
    }

    return _argb(blend(16), blend(8), blend(0));
  }

  /// 向白色靠拢（保留色相）。
  static int lighten(int color, double amount) => mix(color, _white, amount);

  /// 向黑色靠拢。
  static int darken(int color, double amount) => mix(color, _ink, amount);

  /// 完全透明的判定（自定义色若带 alpha=0 视为非法）。
  static bool isUsableColor(int color) => (color >> 24) & 0xFF != 0;

  /// 去掉用户可能带进来的 alpha，统一按不透明处理。
  static int opaque(int color) => color | 0xFF000000;

  /// `#RRGGBB` / `#AARRGGBB` → int；非法返回 null（**不抛异常**）。
  static int? parseHex(String? raw) {
    if (raw == null) return null;
    final String text = raw.trim().replaceFirst('#', '');
    if (text.length != 6 && text.length != 8) return null;
    if (text.split('').any((String unit) => int.tryParse(unit, radix: 16) == null)) {
      return null;
    }
    final int value = int.parse(text, radix: 16);
    return text.length == 6 ? (0xFF000000 | value) : value;
  }

  /// int → `#RRGGBB`（写进持久化 / 传给界面用的稳定文本形式）。
  static String toHex(int color) {
    final int r = channel(color, 16);
    final int g = channel(color, 8);
    final int b = channel(color, 0);
    return '#${_hex2(r)}${_hex2(g)}${_hex2(b)}';
  }

  static String _hex2(int value) => value.toRadixString(16).padLeft(2, '0').toUpperCase();

  static int channel(int color, int shift) => (color >> shift) & 0xFF;

  static int _argb(int r, int g, int b) => 0xFF000000 | (r << 16) | (g << 8) | b;

  static double _linearize(int raw) {
    final double c = raw / 255.0;
    return c <= 0.03928 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
  }

  /// 供测试断言"派生算法是确定的"。
  static int channelDistance(int a, int b) {
    int sum = 0;
    for (final int shift in <int>[16, 8, 0]) {
      sum += (channel(a, shift) - channel(b, shift)).abs();
    }
    return sum;
  }
}

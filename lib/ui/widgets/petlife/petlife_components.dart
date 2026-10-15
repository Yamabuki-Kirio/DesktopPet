/// PetLife 公共组件（Android 控制面板统一视觉语言）。
///
/// 页面只允许用这里的组件搭界面：
/// 读取状态 → 展示状态 → 调用现有动作 → 展示结果。
/// 颜色一律来自 [PetLifeTheme.of]，**禁止**页面硬编码颜色 / 圆角 / 间距。
library;

import 'package:flutter/material.dart';

import '../../theme/design_tokens.dart';
import '../../theme/petlife_theme.dart';
import 'petlife_decor.dart';

/// 通用卡片（Kazumi 式卡片布局的基础单元）。
///
/// * [large] 用 20dp 圆角（状态卡 / 概览卡 / 素材大卡），否则 16dp；
/// * [selected] 打开强调色描边 + 右上角对勾（需求 §2.5「当前使用素材」）；
/// * [onTap] 存在时可点击，并保证 ≥48dp 触摸区；
/// * [corner] 在左上角画一个 P3P 斜切角（装饰，不影响点击）。
class PetLifeCard extends StatelessWidget {
  const PetLifeCard({
    super.key,
    required this.child,
    this.padding = PetLifeSpacing.cardInsets,
    this.large = false,
    this.selected = false,
    this.onTap,
    this.onLongPress,
    this.corner = false,
    this.accentStripe = false,
    this.color,
    this.borderColor,
    this.semanticLabel,
    this.margin = EdgeInsets.zero,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final bool large;
  final bool selected;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool corner;
  final bool accentStripe;
  final Color? color;
  final Color? borderColor;
  final String? semanticLabel;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    final PetLifePalette p = PetLifeTheme.of(context);
    final BorderRadius radius =
        large ? PetLifeRadii.largeCardBorder : PetLifeRadii.cardBorder;
    final Color effectiveBorder = selected ? p.accent : (borderColor ?? p.border);

    // ⚠ 卡片表面必须是 **Material**（而不是带颜色的 DecoratedBox）：
    // 否则内部的 ListTile / InkWell 的水波纹会被不透明背景挡住，
    // Flutter 会在 debug 下直接抛断言（"ListTile background color or ink
    // splashes may be invisible"）。用 Material 的 color + shape 表达
    // 背景、圆角与描边，既保留极轻阴影又让点击反馈真实可见。
    Widget content = Padding(padding: padding, child: child);
    if (onTap != null || onLongPress != null) {
      content = InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: content,
      );
    }

    final Widget surface = Stack(
      children: <Widget>[
        Material(
          color: color ?? p.card,
          surfaceTintColor: Colors.transparent,
          shadowColor: p.shadow,
          elevation: large ? 2 : 1,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: radius,
            side: BorderSide(color: effectiveBorder, width: selected ? 2 : 1),
          ),
          child: content,
        ),
        if (accentStripe)
          Positioned(
            left: 0,
            top: large ? 22 : 18,
            child: IgnorePointer(
              child: Container(
                width: 3,
                height: large ? 30 : 24,
                decoration: BoxDecoration(
                  color: p.accent,
                  borderRadius: const BorderRadius.horizontal(
                    right: Radius.circular(3),
                  ),
                ),
              ),
            ),
          ),
        if (corner)
          Positioned(
            left: 14,
            top: 10,
            child: P3pCornerSlash(color: p.accent),
          ),
        if (selected)
          Positioned(
            right: 8,
            top: 8,
            child: _SelectedCheck(color: p.accent, onColor: p.onAccent),
          ),
      ],
    );

    return Semantics(
      label: semanticLabel,
      container: true,
      button: onTap != null || onLongPress != null,
      child: Padding(padding: margin, child: surface),
    );
  }
}

class _SelectedCheck extends StatelessWidget {
  const _SelectedCheck({required this.color, required this.onColor});

  final Color color;
  final Color onColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      child: Icon(Icons.check, size: 14, color: onColor),
    );
  }
}

/// 分组标题（Animeko 式层级：小色块 + 标题 + 可选右侧动作）。
class PetLifeSectionTitle extends StatelessWidget {
  const PetLifeSectionTitle({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
    this.marker = true,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;
  final bool marker;

  @override
  Widget build(BuildContext context) {
    final PetLifePalette p = PetLifeTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: PetLifeSpacing.cardGap),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          if (marker) ...<Widget>[
            const P3pSectionMarker(),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  title,
                  style: TextStyle(
                    fontSize: PetLifeText.cardTitle,
                    fontWeight: FontWeight.w700,
                    color: p.textPrimary,
                  ),
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    style: TextStyle(
                      fontSize: PetLifeText.caption,
                      color: p.textSecondary,
                    ),
                  ),
              ],
            ),
          ),
          if (trailing != null) ...<Widget>[
            const SizedBox(width: 8),
            trailing!,
          ],
        ],
      ),
    );
  }
}

/// 主按钮（强调色实心）。
///
/// 自带 48dp 最小高度；宽度不足时文字自动换行，**不会**溢出。
class PetLifePrimaryButton extends StatelessWidget {
  const PetLifePrimaryButton({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
    this.busy = false,
    this.expand = false,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool busy;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final PetLifePalette p = PetLifeTheme.of(context);
    // 强调色与页面背景太接近时补一圈描边，避免出现「同色按钮」。
    final bool lowContrast = petLifeContrastRatio(p.accent, p.card) < 1.35;
    final Widget button = FilledButton(
      onPressed: busy ? null : onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: p.accent,
        foregroundColor: p.onAccent,
        side: lowContrast ? BorderSide(color: p.border) : BorderSide.none,
      ),
      child: _ButtonContent(label: label, icon: icon, busy: busy),
    );
    return expand ? SizedBox(width: double.infinity, child: button) : button;
  }
}

/// 次按钮（描边）。
class PetLifeSecondaryButton extends StatelessWidget {
  const PetLifeSecondaryButton({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
    this.busy = false,
    this.expand = false,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool busy;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final Widget button = OutlinedButton(
      onPressed: busy ? null : onPressed,
      child: _ButtonContent(label: label, icon: icon, busy: busy),
    );
    return expand ? SizedBox(width: double.infinity, child: button) : button;
  }
}

/// 危险操作按钮（**固定红色，不跟随主题强调色** —— 需求 §2.4）。
class PetLifeDangerButton extends StatelessWidget {
  const PetLifeDangerButton({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
    this.filled = true,
    this.expand = false,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool filled;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final PetLifePalette p = PetLifeTheme.of(context);
    final ButtonStyle style = ButtonStyle(
      backgroundColor: WidgetStatePropertyAll<Color>(
        filled ? p.danger : Colors.transparent,
      ),
      foregroundColor: WidgetStatePropertyAll<Color>(
        filled ? p.onDanger : p.danger,
      ),
      side: WidgetStatePropertyAll<BorderSide>(
        BorderSide(color: p.danger),
      ),
      minimumSize: const WidgetStatePropertyAll<Size>(
        Size(0, PetLifeSpacing.minTouch),
      ),
      padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
        EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      ),
      shape: const WidgetStatePropertyAll<OutlinedBorder>(
        RoundedRectangleBorder(borderRadius: PetLifeRadii.buttonBorder),
      ),
    );
    final Widget button = filled
        ? FilledButton(style: style, onPressed: onPressed, child: _ButtonContent(label: label, icon: icon))
        : OutlinedButton(style: style, onPressed: onPressed, child: _ButtonContent(label: label, icon: icon));
    return expand ? SizedBox(width: double.infinity, child: button) : button;
  }
}

class _ButtonContent extends StatelessWidget {
  const _ButtonContent({required this.label, this.icon, this.busy = false});

  final String label;
  final IconData? icon;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (busy)
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        else if (icon != null)
          Icon(icon, size: 18),
        if (busy || icon != null) const SizedBox(width: 8),
        Flexible(
          child: Text(label, overflow: TextOverflow.ellipsis, maxLines: 2),
        ),
      ],
    );
  }
}

/// 胶囊标签（需求：标签高度的一半做圆角）。
///
/// [selected] 时使用强调色柔和底 + 自动对比的文字色。
class PetLifeTag extends StatelessWidget {
  const PetLifeTag({
    super.key,
    required this.label,
    this.icon,
    this.selected = false,
    this.color,
    this.onTap,
    this.dense = false,
  });

  final String label;
  final IconData? icon;
  final bool selected;
  final Color? color;
  final VoidCallback? onTap;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final PetLifePalette p = PetLifeTheme.of(context);
    final Color tint = color ?? p.accent;
    // ⚠ 背景必须先**合成成不透明色**再拿去算对比度。
    // 曾经的缺陷：直接拿 `tint.withValues(alpha: 0.12)` 当背景，
    // 而 `computeLuminance()` 会**忽略 alpha** —— 半透明灰被当成实心灰，
    // 自动配色于是把文字推向白色，最终在浅灰底上渲染出看不见的字
    // （Windows 顶部栏的同步状态标签就是这么变成一只空胶囊的）。
    final Color background = selected
        ? p.accentSoft
        : (color == null
            ? p.muted
            : Color.alphaBlend(tint.withValues(alpha: 0.14), p.card));
    final Color foreground = selected
        ? p.onAccentSoft
        : (color == null ? p.textSecondary : petLifeEnsureReadable(tint, background));

    final Widget body = AnimatedContainer(
      duration: PetLifeDurations.press,
      curve: PetLifeDurations.easing,
      padding: EdgeInsets.symmetric(
        horizontal: dense ? 8 : 12,
        vertical: dense ? 4 : 7,
      ),
      constraints: const BoxConstraints(minHeight: 28),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(PetLifeRadii.pill),
        border: Border.all(
          color: selected ? p.accent : Colors.transparent,
          width: selected ? 1.4 : 0,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(icon, size: dense ? 12 : 14, color: foreground),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: dense ? PetLifeText.captionSmall : PetLifeText.caption,
              fontWeight: FontWeight.w600,
              color: foreground,
            ),
          ),
        ],
      ),
    );

    if (onTap == null) return body;
    // 触摸区补足到 48dp，但视觉上仍然是紧凑的胶囊。
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: InkWell(
        borderRadius: BorderRadius.circular(PetLifeRadii.pill),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: body,
        ),
      ),
    );
  }
}

/// 状态点 + 文案（同步状态 / 悬浮服务状态等）。
class PetLifeStatusDot extends StatelessWidget {
  const PetLifeStatusDot({
    super.key,
    required this.label,
    required this.color,
    this.icon,
  });

  final String label;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (icon != null)
          Icon(icon, size: 13, color: color)
        else
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            label,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: PetLifeText.caption,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ),
      ],
    );
  }
}

/// 重要数据（大号数字 + 说明）。
///
/// 用 [Column] + 可换行文本，字体放大时靠布局自动增高，**不设固定高度**。
class PetLifeStat extends StatelessWidget {
  const PetLifeStat({
    super.key,
    required this.label,
    required this.value,
    this.note,
    this.valueColor,
    this.large = false,
  });

  final String label;
  final String value;
  final String? note;
  final Color? valueColor;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final PetLifePalette p = PetLifeTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          value,
          style: TextStyle(
            fontSize: large ? PetLifeText.displayLarge : PetLifeText.display,
            fontWeight: FontWeight.w700,
            color: valueColor ?? p.textPrimary,
            height: 1.1,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: TextStyle(
            fontSize: PetLifeText.caption,
            fontWeight: FontWeight.w600,
            color: p.textSecondary,
          ),
        ),
        if (note != null)
          Text(
            note!,
            style: TextStyle(
              fontSize: PetLifeText.captionSmall,
              color: p.textSecondary,
              height: 1.25,
            ),
          ),
      ],
    );
  }
}

/// 横向进度条（应用排行 / 分类占比）。
class PetLifeProgressBar extends StatelessWidget {
  const PetLifeProgressBar({
    super.key,
    required this.value,
    this.height = 8,
    this.color,
  });

  final double value;
  final double height;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final PetLifePalette p = PetLifeTheme.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(height / 2),
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(begin: 0, end: value.clamp(0.0, 1.0)),
        duration: PetLifeDurations.cardIn,
        curve: PetLifeDurations.easing,
        builder: (BuildContext context, double v, Widget? _) => LinearProgressIndicator(
          value: v,
          minHeight: height,
          backgroundColor: p.muted,
          valueColor: AlwaysStoppedAnimation<Color>(color ?? p.accent),
        ),
      ),
    );
  }
}

/// 「键 — 值」一行（自适应换行，不做固定宽度标签，避免大字体下截断）。
class PetLifeKeyValue extends StatelessWidget {
  const PetLifeKeyValue({
    super.key,
    required this.label,
    required this.value,
    this.selectable = false,
    this.valueColor,
    this.labelWidth = 92,
  });

  final String label;
  final String value;
  final bool selectable;
  final Color? valueColor;
  final double labelWidth;

  @override
  Widget build(BuildContext context) {
    final PetLifePalette p = PetLifeTheme.of(context);
    final TextStyle labelStyle = TextStyle(
      fontSize: PetLifeText.caption,
      color: p.textSecondary,
    );
    final TextStyle valueStyle = TextStyle(
      fontSize: PetLifeText.bodySmall,
      color: valueColor ?? p.textPrimary,
    );
    final Widget valueWidget = selectable
        ? SelectableText(value, style: valueStyle)
        : Text(value, style: valueStyle);

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 1.5 倍字体 + 360dp 时横排会截断：窄到放不下就改成上下两行。
        final double scale = MediaQuery.textScalerOf(context).scale(1.0);
        final bool stack = constraints.maxWidth < (labelWidth + 140) * scale;
        if (stack) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(label, style: labelStyle),
                const SizedBox(height: 2),
                valueWidget,
              ],
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              SizedBox(
                width: labelWidth,
                child: Text(label, style: labelStyle),
              ),
              const SizedBox(width: 8),
              Expanded(child: valueWidget),
            ],
          ),
        );
      },
    );
  }
}

/// 设置类页面的一行：左文右控件；窄屏 / 大字体时自动改成上下两段。
///
/// 这是「不再连续堆叠大量灰色设置行」的关键：行本身没有分割线，
/// 靠卡片分组与间距组织层级。
class PetLifeSettingRow extends StatelessWidget {
  const PetLifeSettingRow({
    super.key,
    required this.label,
    this.note,
    required this.control,
    this.stackThreshold = 320,
  });

  final String label;
  final String? note;
  final Widget control;

  /// 可用宽度低于 `stackThreshold × 字体缩放` 时改为上下布局。
  final double stackThreshold;

  @override
  Widget build(BuildContext context) {
    final PetLifePalette p = PetLifeTheme.of(context);
    final Widget text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          label,
          style: TextStyle(
            fontSize: PetLifeText.bodySmall,
            fontWeight: FontWeight.w600,
            color: p.textPrimary,
          ),
        ),
        if (note != null)
          Text(
            note!,
            style: TextStyle(
              fontSize: PetLifeText.captionSmall,
              color: p.textSecondary,
              height: 1.35,
            ),
          ),
      ],
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final double scale = MediaQuery.textScalerOf(context).scale(1.0);
          if (constraints.maxWidth < stackThreshold * scale) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                text,
                const SizedBox(height: 8),
                Align(alignment: Alignment.centerLeft, child: control),
              ],
            );
          }
          return Row(
            children: <Widget>[
              Expanded(child: text),
              const SizedBox(width: 12),
              control,
            ],
          );
        },
      ),
    );
  }
}

/// 开关行（统一缓动曲线，触摸区 ≥48dp）。
class PetLifeSwitchRow extends StatelessWidget {
  const PetLifeSwitchRow({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.note,
  });

  final String label;
  final String? note;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) => PetLifeSettingRow(
        label: label,
        note: note,
        control: Switch(value: value, onChanged: onChanged),
      );
}

/// 可点击的一行（右侧箭头 / 自定义尾部）。
class PetLifeActionRow extends StatelessWidget {
  const PetLifeActionRow({
    super.key,
    required this.label,
    this.note,
    this.icon,
    this.trailing,
    this.onTap,
    this.danger = false,
  });

  final String label;
  final String? note;
  final IconData? icon;
  final Widget? trailing;

  /// null 表示禁用（但**仍然渲染**，让用户看得见功能存在）。
  final VoidCallback? onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final PetLifePalette p = PetLifeTheme.of(context);
    final Color tone = danger ? p.danger : p.textPrimary;
    return Semantics(
      button: onTap != null,
      enabled: onTap != null,
      child: InkWell(
        borderRadius: PetLifeRadii.buttonBorder,
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: PetLifeSpacing.minTouch),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: <Widget>[
                if (icon != null) ...<Widget>[
                  Icon(
                    icon,
                    size: 18,
                    color: onTap == null ? p.textDisabled : (danger ? p.danger : p.accent),
                  ),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        label,
                        style: TextStyle(
                          fontSize: PetLifeText.bodySmall,
                          fontWeight: FontWeight.w600,
                          color: onTap == null ? p.textDisabled : tone,
                        ),
                      ),
                      if (note != null)
                        Text(
                          note!,
                          style: TextStyle(
                            fontSize: PetLifeText.captionSmall,
                            color: p.textSecondary,
                          ),
                        ),
                    ],
                  ),
                ),
                if (trailing != null)
                  trailing!
                else if (onTap != null)
                  Icon(Icons.chevron_right, size: 20, color: p.textSecondary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 滑杆行（透明度 / 淡入淡出 / 缩放等）。
class PetLifeSliderRow extends StatelessWidget {
  const PetLifeSliderRow({
    super.key,
    required this.label,
    required this.valueLabel,
    required this.slider,
    this.note,
  });

  final String label;
  final String valueLabel;
  final Widget slider;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final PetLifePalette p = PetLifeTheme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: PetLifeText.bodySmall,
                    fontWeight: FontWeight.w600,
                    color: p.textPrimary,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                valueLabel,
                style: TextStyle(
                  fontSize: PetLifeText.caption,
                  fontWeight: FontWeight.w600,
                  color: p.onAccentSoft,
                ),
              ),
            ],
          ),
          slider,
          if (note != null)
            Text(
              note!,
              style: TextStyle(fontSize: PetLifeText.captionSmall, color: p.textSecondary),
            ),
        ],
      ),
    );
  }
}

/// 空状态（插画式：圆形底 + 图标 + 标题 + 说明 + 可选主按钮）。
class PetLifeEmptyState extends StatelessWidget {
  const PetLifeEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.actionLabel,
    this.onAction,
    this.compact = false,
    this.scrollable = true,
  });

  final IconData icon;
  final String title;
  final String? message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final bool compact;

  /// 是否自带滚动。
  ///
  /// 放在 `Expanded`（有界高度）里时应为 true；
  /// 已经处在 `ListView` 这类**无界**滚动容器里时必须为 false ——
  /// 否则会出现"滚动里再套滚动"并在无界高度下布局异常。
  final bool scrollable;

  @override
  Widget build(BuildContext context) {
    final PetLifePalette p = PetLifeTheme.of(context);
    final Widget content = Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          width: compact ? 64 : 88,
          height: compact ? 64 : 88,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: p.accentSoft,
            border: Border.all(color: p.border),
          ),
          child: Icon(icon, size: compact ? 28 : 38, color: p.onAccentSoft),
        ),
        const SizedBox(height: 14),
        Text(
          title,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: PetLifeText.cardTitle,
            fontWeight: FontWeight.w700,
            color: p.textPrimary,
          ),
        ),
        if (message != null) ...<Widget>[
          const SizedBox(height: 6),
          Text(
            message!,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: PetLifeText.caption,
              color: p.textSecondary,
              height: 1.4,
            ),
          ),
        ],
        if (actionLabel != null && onAction != null) ...<Widget>[
          const SizedBox(height: 16),
          PetLifePrimaryButton(
            label: actionLabel!,
            icon: Icons.add,
            onPressed: onAction,
          ),
        ],
      ],
    );

    if (!scrollable) {
      return Padding(
        padding: const EdgeInsets.all(PetLifeSpacing.page),
        child: Center(child: content),
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(PetLifeSpacing.page),
      child: Center(child: content),
    );
  }
}

/// 错误状态：**明确文本**，不只显示红色（需求 §2.4 / §7）。
class PetLifeErrorState extends StatelessWidget {
  const PetLifeErrorState({
    super.key,
    required this.title,
    required this.detail,
    this.hint,
    this.onRetry,
    this.retryLabel = '重试',
  });

  final String title;
  final String detail;
  final String? hint;
  final VoidCallback? onRetry;
  final String retryLabel;

  @override
  Widget build(BuildContext context) {
    final PetLifePalette p = PetLifeTheme.of(context);
    return PetLifeCard(
      color: p.danger.withValues(alpha: 0.06),
      borderColor: p.danger.withValues(alpha: 0.4),
      padding: const EdgeInsets.all(PetLifeSpacing.cardInner),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(Icons.error_outline, size: 18, color: p.danger),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: PetLifeText.bodySmall,
                    fontWeight: FontWeight.w700,
                    color: p.danger,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          SelectableText(
            detail,
            style: TextStyle(fontSize: PetLifeText.caption, color: p.textPrimary),
          ),
          if (hint != null) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              hint!,
              style: TextStyle(fontSize: PetLifeText.captionSmall, color: p.textSecondary),
            ),
          ],
          if (onRetry != null) ...<Widget>[
            const SizedBox(height: 10),
            PetLifeSecondaryButton(
              label: retryLabel,
              icon: Icons.refresh,
              onPressed: onRetry,
            ),
          ],
        ],
      ),
    );
  }
}

/// 加载状态（统一的粉色加载条）。
class PetLifeLoading extends StatelessWidget {
  const PetLifeLoading({super.key, this.label = '加载中…'});

  final String label;

  @override
  Widget build(BuildContext context) {
    final PetLifePalette p = PetLifeTheme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 18),
      child: Column(
        children: <Widget>[
          SizedBox(
            width: 120,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                minHeight: 4,
                backgroundColor: p.muted,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            label,
            style: TextStyle(fontSize: PetLifeText.caption, color: p.textSecondary),
          ),
        ],
      ),
    );
  }
}

/// 胶囊选择器（本机 / 云端，时间线 / 应用统计等「卡片式切换」）。
///
/// 用自绘胶囊而不是 `SegmentedButton`：需求要求「胶囊标签」与平滑移动的选中底，
/// 并且要保证 48dp 触摸高度与 1.5 倍字体下的自适应换行。
class PetLifePillSelector<T> extends StatelessWidget {
  const PetLifePillSelector({
    super.key,
    required this.options,
    required this.selected,
    required this.onSelected,
    this.labelOf,
  });

  final List<T> options;
  final T selected;
  final ValueChanged<T> onSelected;
  final String Function(T value)? labelOf;

  @override
  Widget build(BuildContext context) {
    final PetLifePalette p = PetLifeTheme.of(context);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        for (final T option in options)
          _Pill(
            label: labelOf?.call(option) ?? '$option',
            selected: option == selected,
            palette: p,
            onTap: () => onSelected(option),
          ),
      ],
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({
    required this.label,
    required this.selected,
    required this.palette,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final PetLifePalette palette;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      child: InkWell(
        borderRadius: BorderRadius.circular(PetLifeRadii.pill),
        onTap: onTap,
        child: AnimatedContainer(
          duration: PetLifeDurations.navPill,
          curve: PetLifeDurations.easing,
          constraints: const BoxConstraints(minHeight: PetLifeSpacing.minTouch),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? palette.accent : palette.card,
            borderRadius: BorderRadius.circular(PetLifeRadii.pill),
            border: Border.all(color: selected ? palette.accent : palette.border),
          ),
          child: Center(
            widthFactor: 1,
            child: Text(
              label,
              style: TextStyle(
                fontSize: PetLifeText.bodySmall,
                fontWeight: FontWeight.w600,
                color: selected ? palette.onAccent : palette.textSecondary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

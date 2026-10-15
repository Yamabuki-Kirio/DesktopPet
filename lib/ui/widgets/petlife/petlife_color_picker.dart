import 'package:flutter/material.dart';

import '../../theme/design_tokens.dart';
import '../../theme/petlife_theme.dart';
import 'petlife_components.dart';

/// 一个可选颜色（预设）。
@immutable
class PetLifeColorPreset {
  const PetLifeColorPreset({required this.name, required this.color});

  final String name;
  final Color color;
}

/// 「外观与主题」里的配色选择区（需求 §3 配色功能 / §9 设置页）。
///
/// 主色与强调色各自拥有一个独立的 [PetLifeColorPicker]：
/// **两者独立修改、独立保存**，任何一处改动都不会覆盖另一处。
///
/// 提供：预设颜色、自定义颜色、恢复默认。取消自定义时**不修改**当前主题。
class PetLifeColorPicker extends StatelessWidget {
  const PetLifeColorPicker({
    super.key,
    required this.title,
    required this.value,
    required this.presets,
    required this.defaultColor,
    required this.onChanged,
    this.subtitle,
    this.allowDarkPreset = false,
  });

  final String title;
  final String? subtitle;

  /// 当前颜色。
  final Color value;

  /// 预设列表（顺序即展示顺序）。
  final List<PetLifeColorPreset> presets;

  /// 「恢复默认」的目标色。
  final Color defaultColor;

  final ValueChanged<Color> onChanged;

  /// 主色允许选到深色（深色主色会整体切换到深色表面）。
  final bool allowDarkPreset;

  @override
  Widget build(BuildContext context) {
    final PetLifePalette p = PetLifeTheme.of(context);
    final bool isPreset = presets.any(
      (PetLifeColorPreset preset) => _sameColor(preset.color, value),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: PetLifeText.bodySmall,
                      fontWeight: FontWeight.w600,
                      color: p.textPrimary,
                    ),
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle!,
                      style: TextStyle(
                        fontSize: PetLifeText.captionSmall,
                        color: p.textSecondary,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            _Swatch(color: value, size: 22, selected: false),
            const SizedBox(width: 6),
            Text(
              petLifeColorToHex(value),
              style: TextStyle(
                fontSize: PetLifeText.caption,
                fontFamily: 'monospace',
                color: p.textSecondary,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: <Widget>[
            for (final PetLifeColorPreset preset in presets)
              _PresetChip(
                preset: preset,
                selected: _sameColor(preset.color, value),
                palette: p,
                onTap: () => onChanged(preset.color),
              ),
            _CustomChip(
              palette: p,
              active: !isPreset,
              color: value,
              onTap: () => _pickCustom(context),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _sameColor(value, defaultColor) ? null : () => onChanged(defaultColor),
            icon: const Icon(Icons.restart_alt, size: 16),
            label: const Text('恢复默认'),
          ),
        ),
      ],
    );
  }

  static bool _sameColor(Color a, Color b) =>
      (a.toARGB32() & 0x00FFFFFF) == (b.toARGB32() & 0x00FFFFFF);

  /// 自定义颜色弹窗。
  ///
  /// 只有点了「应用」才回调 [onChanged]；取消 / 关闭都**不修改**当前主题
  /// （需求 §9：「用户取消自定义颜色选择时，不修改当前主题」）。
  Future<void> _pickCustom(BuildContext context) async {
    final Color? picked = await showDialog<Color>(
      context: context,
      builder: (BuildContext ctx) => _CustomColorDialog(
        initial: value,
        allowDark: allowDarkPreset,
      ),
    );
    if (picked != null) onChanged(picked);
  }
}

class _PresetChip extends StatelessWidget {
  const _PresetChip({
    required this.preset,
    required this.selected,
    required this.palette,
    required this.onTap,
  });

  final PetLifeColorPreset preset;
  final bool selected;
  final PetLifePalette palette;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: '${preset.name}${selected ? '（已选）' : ''}',
      child: InkWell(
        borderRadius: BorderRadius.circular(PetLifeRadii.pill),
        onTap: onTap,
        child: AnimatedContainer(
          duration: PetLifeDurations.press,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          constraints: const BoxConstraints(minHeight: 40),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(PetLifeRadii.pill),
            color: selected
                ? Color.alphaBlend(preset.color.withValues(alpha: 0.16), palette.card)
                : palette.card,
            border: Border.all(
              color: selected ? palette.accent : palette.border,
              width: selected ? 1.6 : 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              _Swatch(color: preset.color, size: 16, selected: false),
              const SizedBox(width: 6),
              Text(
                preset.name,
                style: TextStyle(
                  fontSize: PetLifeText.caption,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: palette.textPrimary,
                ),
              ),
              if (selected) ...<Widget>[
                const SizedBox(width: 4),
                Icon(Icons.check, size: 14, color: palette.accent),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _CustomChip extends StatelessWidget {
  const _CustomChip({
    required this.palette,
    required this.active,
    required this.color,
    required this.onTap,
  });

  final PetLifePalette palette;
  final bool active;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '自定义颜色',
      child: InkWell(
        borderRadius: BorderRadius.circular(PetLifeRadii.pill),
        onTap: onTap,
        child: AnimatedContainer(
          duration: PetLifeDurations.press,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          constraints: const BoxConstraints(minHeight: 40),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(PetLifeRadii.pill),
            color: active ? palette.accentSoft : palette.card,
            border: Border.all(
              color: active ? palette.accent : palette.border,
              width: active ? 1.6 : 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.colorize, size: 16, color: active ? palette.onAccentSoft : palette.textSecondary),
              const SizedBox(width: 6),
              Text(
                '自定义',
                style: TextStyle(
                  fontSize: PetLifeText.caption,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                  color: palette.textPrimary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({required this.color, required this.size, required this.selected});

  final Color color;
  final double size;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final PetLifePalette p = PetLifeTheme.of(context);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: p.border),
      ),
    );
  }
}

/// 自定义颜色弹窗：HSL 滑杆 + 十六进制输入 + 实时预览。
///
/// 控制器由本 State 持有并在 [dispose] 中释放 —— 调用方不持有任何控制器，
/// 因此不存在"弹窗退场动画期间控制器已被销毁"的问题（见 docs/32）。
class _CustomColorDialog extends StatefulWidget {
  const _CustomColorDialog({required this.initial, required this.allowDark});

  final Color initial;
  final bool allowDark;

  @override
  State<_CustomColorDialog> createState() => _CustomColorDialogState();
}

class _CustomColorDialogState extends State<_CustomColorDialog> {
  late HSLColor _hsl = HSLColor.fromColor(widget.initial);
  late final TextEditingController _hex =
      TextEditingController(text: petLifeColorToHex(widget.initial));

  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  Color get _color => _hsl.toColor();

  void _update(HSLColor next) {
    setState(() {
      _hsl = next;
      _hex.text = petLifeColorToHex(next.toColor());
    });
  }

  @override
  Widget build(BuildContext context) {
    final PetLifePalette p = PetLifeTheme.of(context);
    final double minLightness = widget.allowDark ? 0.04 : 0.72;
    final double maxLightness = widget.allowDark ? 0.96 : 1.0;

    return AlertDialog(
      title: const Text('自定义颜色'),
      content: SizedBox(
        width: 320,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Container(
                height: 56,
                decoration: BoxDecoration(
                  color: _color,
                  borderRadius: PetLifeRadii.cardBorder,
                  border: Border.all(color: p.border),
                ),
                alignment: Alignment.center,
                child: Text(
                  petLifeColorToHex(_color),
                  style: TextStyle(
                    fontFamily: 'monospace',
                    color: petLifeReadableOn(
                      _color,
                      candidates: <Color>[p.textPrimary, Colors.white],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              _slider('色相', _hsl.hue, 0, 360, (double v) => _update(_hsl.withHue(v))),
              _slider('饱和度', _hsl.saturation, 0, 1, (double v) => _update(_hsl.withSaturation(v))),
              _slider(
                '明度',
                _hsl.lightness.clamp(minLightness, maxLightness),
                minLightness,
                maxLightness,
                (double v) => _update(_hsl.withLightness(v)),
              ),
              const SizedBox(height: 6),
              TextField(
                controller: _hex,
                decoration: const InputDecoration(
                  labelText: '十六进制（#RRGGBB）',
                  isDense: true,
                ),
                onSubmitted: (String text) {
                  final Color? parsed = petLifeColorFromHex(text);
                  if (parsed != null) {
                    setState(() {
                      _hsl = HSLColor.fromColor(parsed);
                      _hex.text = petLifeColorToHex(parsed);
                    });
                  }
                },
              ),
              if (!widget.allowDark)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    '主色越浅，界面越接近白色主题；深色请用「设置 → 外观与主题 → 浅色/深色」切换。',
                    style: TextStyle(fontSize: PetLifeText.captionSmall, color: p.textSecondary),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        PetLifePrimaryButton(
          label: '应用',
          onPressed: () => Navigator.pop(context, _color),
        ),
      ],
    );
  }

  Widget _slider(
    String label,
    double value,
    double min,
    double max,
    ValueChanged<double> onChanged,
  ) {
    final PetLifePalette p = PetLifeTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            label,
            style: TextStyle(fontSize: PetLifeText.caption, color: p.textSecondary),
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(trackHeight: 6),
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }
}

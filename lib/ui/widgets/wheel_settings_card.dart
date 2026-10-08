/// 「桌宠轮盘」设置卡片（增量 B，仅桌面）。
///
/// 三个滑块 + 主题选择，字段语义与 Android `WheelMenuLayoutSettings` 逐字一致：
/// * 轮盘大小 `wheelScale`：0.50 ~ 2.50，步进 0.10，默认 1.00；
/// * 按钮大小 `wheelButtonScale`：0.50 ~ 2.50，步进 0.10，默认 1.30；
/// * 菜单距离 `wheelMenuDistance`：0.05 ~ 0.30，默认 0.16
///   （菜单中心相对桌宠**可见宽度**的偏移比例）。
///
/// ⚠️ **不暴露** Android 内部的 `BUTTON_GAP_DP = 6`（相邻按钮净空，不可调）。
library;

import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../menu/wheel_canvas_plan.dart'
    show WheelCanvasFit, WheelCanvasPlan, WheelCanvasPlanner, wheelCanvasFit;
import '../../menu/wheel_menu_geometry.dart' show WheelMenuLayoutSettings;
import '../../menu/wheel_theme.dart' show WheelMenuTheme, WheelMenuThemes, WheelThemeIds;
import '../../settings/app_settings.dart';

class WheelSettingsCard extends StatelessWidget {
  const WheelSettingsCard({super.key, required this.services});

  final AppServices services;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: services.settings,
      builder: (BuildContext context, Widget? _) {
        final AppSettings s = services.settings.settings;
        // 屏幕适配结果由探针广播；这里再包一层，保证「实际显示」即时刷新。
        return ValueListenableBuilder<WheelCanvasFit?>(
          valueListenable: wheelCanvasFit,
          builder: (BuildContext context, WheelCanvasFit? _, Widget? __) =>
              Card(
          color: const Color(0xFFF7F3F6),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text(
                  '单击桌宠打开轮盘菜单。以下设置与 Android 版同一套口径，'
                  '修改后立即生效（无需重启）。',
                  style: TextStyle(fontSize: 11, color: Colors.black54),
                ),
                const SizedBox(height: 10),
                _themeRow(context, s),
                const SizedBox(height: 6),
                _wheelScaleRow(s),
                _ratioSlider(
                  title: '按钮大小',
                  value: s.wheelButtonScale,
                  min: WheelMenuLayoutSettings.minButtonScale,
                  max: WheelMenuLayoutSettings.maxButtonScale,
                  step: WheelMenuLayoutSettings.buttonStep,
                  defaultValue: WheelMenuLayoutSettings.defaultButtonScale,
                  onChanged: services.settings.setWheelButtonScale,
                ),
                _distanceSlider(s),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: services.settings.resetWheelSettings,
                    icon: const Icon(Icons.restart_alt, size: 16),
                    label: const Text('轮盘设置恢复默认'),
                  ),
                ),
              ],
            ),
          ),
        ),
        );
      },
    );
  }

  // ------------------------------------------------------------------
  // 主题
  // ------------------------------------------------------------------

  Widget _themeRow(BuildContext context, AppSettings s) {
    final List<WheelMenuTheme> presets = WheelMenuThemes.presets;
    final bool isCustom = s.wheelThemeId == WheelThemeIds.custom;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Text('轮盘主题', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            for (final WheelMenuTheme theme in presets)
              _themeChip(
                theme: theme,
                selected: !isCustom && s.wheelThemeId == theme.themeId,
                onTap: () => services.settings.setWheelThemeId(theme.themeId),
              ),
            _customChip(context, s, isCustom),
          ],
        ),
      ],
    );
  }

  Widget _themeChip({
    required WheelMenuTheme theme,
    required bool selected,
    required VoidCallback onTap,
  }) =>
      InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: selected ? Color(theme.primary) : Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: selected ? Color(theme.outline) : const Color(0x22000000),
              width: selected ? 2 : 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: Color(theme.primary),
                  shape: BoxShape.circle,
                  border: Border.all(color: Color(theme.outline), width: 1),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                theme.displayName,
                style: TextStyle(
                  fontSize: 12,
                  color: selected ? Colors.white : Colors.black87,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      );

  Widget _customChip(BuildContext context, AppSettings s, bool selected) => InkWell(
        onTap: () => _editCustomPrimary(context, s),
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: selected ? Color(s.wheelTheme.primary) : Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: selected ? const Color(0xFF111111) : const Color(0x22000000),
              width: selected ? 2 : 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.colorize, size: 14, color: Colors.black87),
              const SizedBox(width: 6),
              Text(
                '自定义',
                style: TextStyle(
                  fontSize: 12,
                  color: selected ? Colors.white : Colors.black87,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      );

  Future<void> _editCustomPrimary(BuildContext context, AppSettings s) async {
    final TextEditingController controller = TextEditingController(
      text: s.wheelCustomPrimary.isEmpty
          ? WheelMenuThemes.toHex(WheelMenuThemes.p3pPrimary)
          : s.wheelCustomPrimary,
    );
    final String? result = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('自定义轮盘主色'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '主色（#RRGGBB）',
            helperText: '其余颜色由主色派生，与 Android 同一套算法',
          ),
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (result == null) return;
    final int? parsed = WheelMenuThemes.parseHex(result);
    if (parsed == null) return;
    await services.settings.setWheelCustomPrimary(WheelMenuThemes.toHex(parsed));
    await services.settings.setWheelThemeId(WheelThemeIds.custom);
  }

  // ------------------------------------------------------------------
  // 滑块
  // ------------------------------------------------------------------

  Widget _ratioSlider({
    required String title,
    required double value,
    required double min,
    required double max,
    required double step,
    required double defaultValue,
    required Future<void> Function(double) onChanged,
    Widget? Function(double current)? footer,
  }) {
    final int divisions = ((max - min) / step).round();
    final double current = value.clamp(min, max).toDouble();
    final Widget? extra = footer?.call(current);
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text('$title  ${(current * 100).round()}%'),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Slider(
            min: min,
            max: max,
            divisions: divisions,
            value: current,
            label: '${(current * 100).round()}%',
            onChanged: (double v) => onChanged(v),
          ),
          Text(
            '范围 ${(min * 100).round()}% ~ ${(max * 100).round()}%，'
            '步进 ${(step * 100).round()}%，默认 ${(defaultValue * 100).round()}%',
            style: const TextStyle(fontSize: 11),
          ),
          if (extra != null) ...<Widget>[const SizedBox(height: 2), extra],
        ],
      ),
    );
  }

  /// 「轮盘大小」行：显示**用户设置值**，并额外给出**当前屏幕实际显示**与压缩原因。
  ///
  /// 语义（操作者决策五）：
  /// * 保存的永远是用户选择的值（250% 就存 250%）；
  /// * 屏幕放不下时由 `WheelCanvasPlanner` 自动压缩实际显示；
  /// * 换到更大的显示器会自动恢复更大的实际值。
  Widget _wheelScaleRow(AppSettings s) => _ratioSlider(
        title: '轮盘大小',
        value: s.wheelScale,
        min: WheelMenuLayoutSettings.minScale,
        max: WheelMenuLayoutSettings.maxScale,
        step: WheelMenuLayoutSettings.step,
        defaultValue: WheelMenuLayoutSettings.defaultScale,
        onChanged: services.settings.setWheelScale,
        footer: (double current) {
          final WheelCanvasFit? base = wheelCanvasFit.value;
          if (base == null) return null;
          // 面板打开时探针不会广播，这里按**当前设置**本地重算，显示不滞后。
          final WheelCanvasPlan plan = WheelCanvasPlanner.plan(
            petSize: base.petSize,
            workArea: base.workArea,
            settings: s.wheelLayoutSettings.copyWith(preferredScale: current),
          );
          final int requested = (current * 100).round();
          final int actual = (plan.effectiveScale * 100).round();
          if (!plan.compressed) {
            return Text(
              '当前屏幕实际显示：$actual%（未触发屏幕适配压缩）',
              style: const TextStyle(fontSize: 11, color: Colors.black54),
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                '当前屏幕实际显示：$actual%',
                style: const TextStyle(
                  fontSize: 11,
                  color: Color(0xFFB3261E),
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                '原因：受当前显示器可用空间限制（请求 $requested%）',
                style: const TextStyle(fontSize: 11, color: Colors.black54),
              ),
              const Text(
                '保存的仍是所选值；换到更大的显示器会自动恢复更大的实际值',
                style: TextStyle(fontSize: 11, color: Colors.black54),
              ),
            ],
          );
        },
      );

  Widget _distanceSlider(AppSettings s) {
    final double current = s.wheelMenuDistance
        .clamp(WheelMenuLayoutSettings.minDistance, WheelMenuLayoutSettings.maxDistance)
        .toDouble();
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text('菜单距离  ${current.toStringAsFixed(2)}'),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Slider(
            min: WheelMenuLayoutSettings.minDistance,
            max: WheelMenuLayoutSettings.maxDistance,
            divisions: 25,
            value: current,
            label: current.toStringAsFixed(2),
            onChanged: (double v) => services.settings.setWheelMenuDistance(v),
          ),
          const Text(
            '菜单中心相对桌宠可见宽度的偏移比例（0.05 ~ 0.30，默认 0.16）。'
            '调小更贴近桌宠。',
            style: TextStyle(fontSize: 11),
          ),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';

import '../../theme/design_tokens.dart';
import '../../theme/petlife_theme.dart';

/// 底部导航栏的一个业务入口。
@immutable
class PetLifeNavDestination {
  const PetLifeNavDestination({
    required this.label,
    required this.icon,
    required this.selectedIcon,
  });

  final String label;

  /// 未选中：深色**线性**图标（需求 §2.1）。
  final IconData icon;

  /// 选中：实心图标 + 强调色胶囊底。
  final IconData selectedIcon;
}

/// 底部导航栏（需求 §4「底部导航」）。
///
/// * 白色 / 用户主色背景；
/// * 当前项使用**强调色胶囊背景**（真实平移，200ms）；
/// * 未选中项使用深色线性图标；
/// * 触摸区 ≥48dp；字体放大时栏高自动增高（不截断文字）。
class PetLifeBottomNav extends StatelessWidget {
  const PetLifeBottomNav({
    super.key,
    required this.destinations,
    required this.selectedIndex,
    required this.onSelected,
  });

  final List<PetLifeNavDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  /// 按字体缩放计算栏高：图标区固定，文字区随系统字体增长（最多 2 行）。
  static double heightFor(BuildContext context) {
    final double scale = MediaQuery.textScalerOf(context).scale(1.0);
    final double labelLine = 11.5 * 1.3 * scale;
    final double lines = scale >= 1.25 ? 2 : 1;
    return 10 + 24 + 4 + labelLine * lines + 10;
  }

  @override
  Widget build(BuildContext context) {
    final PetLifePalette p = PetLifeTheme.of(context);
    final double barHeight = heightFor(context);

    return Material(
      color: p.surface,
      child: SafeArea(
        top: false,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: p.divider)),
          ),
          child: SizedBox(
            height: barHeight,
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                final double width = constraints.maxWidth / destinations.length;
                const double inset = 6;
                return Stack(
                  children: <Widget>[
                    // 平滑移动的强调色胶囊。
                    AnimatedPositioned(
                      duration: PetLifeDurations.navPill,
                      curve: PetLifeDurations.easing,
                      left: width * selectedIndex + inset,
                      top: 5,
                      bottom: 5,
                      width: (width - inset * 2).clamp(0.0, double.infinity),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: p.accent,
                          borderRadius: BorderRadius.circular(PetLifeRadii.pill),
                        ),
                      ),
                    ),
                    Row(
                      children: <Widget>[
                        for (int i = 0; i < destinations.length; i++)
                          SizedBox(
                            width: width,
                            child: _NavItem(
                              destination: destinations[i],
                              selected: i == selectedIndex,
                              palette: p,
                              onTap: () => onSelected(i),
                            ),
                          ),
                      ],
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.destination,
    required this.selected,
    required this.palette,
    required this.onTap,
  });

  final PetLifeNavDestination destination;
  final bool selected;
  final PetLifePalette palette;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Color foreground = selected ? palette.onAccent : palette.textPrimary;
    return Semantics(
      button: true,
      selected: selected,
      label: destination.label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(PetLifeRadii.pill),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 5),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                selected ? destination.selectedIcon : destination.icon,
                size: 23,
                color: foreground,
              ),
              const SizedBox(height: 4),
              Flexible(
                child: Text(
                  destination.label,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.25,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: foreground,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Windows 控制面板的桌面布局组件（需求 §8）。
///
/// **只处理布局**，不含任何业务逻辑：
/// * 导航入口、标题、状态标签、动作按钮都由调用方以数据 / Widget 传入；
/// * 不 import `window_manager`（标题栏拖拽通过 [PetLifeDesktopToolbar.onTitleBarDrag]
///   回调交给外壳，这样本文件在 Android 上也能编译，平台隔离检查继续通过）。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/design_tokens.dart';
import '../../theme/petlife_theme.dart';
import 'petlife_components.dart';

/// 桌面导航的一个入口。
@immutable
class PetLifeDesktopDestination {
  const PetLifeDesktopDestination({
    required this.label,
    required this.icon,
    required this.selectedIcon,
  });

  final String label;

  /// 未选中：线性图标。
  final IconData icon;

  /// 选中：实心图标。
  final IconData selectedIcon;
}

/// 桌面布局断点（需求 §3 / §10）。
///
/// 控制面板窗口最小宽度是 480（见 `PanelLayout.minWidth`），因此三档必须覆盖到 480：
/// * `>= fullRail`：完整侧栏（图标 + 文字，200px）；
/// * `>= iconRail`：收窄为仅图标侧栏（76px）；
/// * `< iconRail`：顶部紧凑导航（横向可滚动的胶囊，**不会横向溢出**）。
abstract final class PetLifeDesktopBreakpoints {
  static const double fullRail = 1120;
  static const double iconRail = 900;

  /// 侧栏宽度（需求 §3：184～220px）。
  static const double railWidth = 200;

  /// 仅图标模式的侧栏宽度。
  static const double iconRailWidth = 76;

  /// 内容最大宽度（需求 §6：使用统计 / 素材库建议 1440px，居中）。
  static const double contentMaxWidth = 1440;

  /// 设置类页面的内容最大宽度（需求 §6：960～1100px，避免设置项横跨整屏）。
  static const double settingsContentMaxWidth = 1040;
}

/// 内容宽度约束：**避免窗口放大后内容无限横向拉伸**。
///
/// 超过 [maxWidth] 时居中，未超过时占满可用宽度（不额外留白）。
class PetLifeDesktopContentWidth extends StatelessWidget {
  const PetLifeDesktopContentWidth({
    super.key,
    required this.child,
    this.maxWidth = PetLifeDesktopBreakpoints.contentMaxWidth,
    this.padding = const EdgeInsets.all(PetLifeSpacing.page),
  });

  final Widget child;
  final double maxWidth;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final double width = math.min(maxWidth, constraints.maxWidth);
          return Center(
            child: SizedBox(
              width: width,
              // 高度有界时撑满（页面里的 Expanded / ListView 需要确定高度）。
              height: constraints.maxHeight.isFinite ? constraints.maxHeight : null,
              child: child,
            ),
          );
        },
      ),
    );
  }
}

/// 控制面板顶部栏（需求 §4）。
///
/// 高度 56～64px、白色 / 主色表面、**不使用旧版深蓝色实心横条**。
class PetLifeDesktopToolbar extends StatelessWidget {
  const PetLifeDesktopToolbar({
    super.key,
    required this.title,
    this.pageName,
    this.icon = Icons.pets,
    this.statusTag,
    this.actions = const <Widget>[],
    this.onTitleBarDrag,
    this.height = 58,
  });

  /// 应用名（"PetLife 控制面板"）。
  final String title;

  /// 当前页面名称（可选；窄窗口下自动隐藏，避免挤压动作区）。
  final String? pageName;

  /// 左上角应用图标。
  final IconData icon;

  /// 同步状态小标签（由调用方构造，组件本身不认识同步业务）。
  final Widget? statusTag;

  /// 右侧动作（"回到桌宠"、退出等）。
  final List<Widget> actions;

  /// 标题栏按下时触发（由外壳接到 `windowManager.startDragging`）。
  final VoidCallback? onTitleBarDrag;

  final double height;

  @override
  Widget build(BuildContext context) {
    final PetLifePalette p = PetLifeTheme.of(context);
    return Material(
      color: p.surface,
      child: SizedBox(
        height: height,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: p.divider)),
          ),
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              // 宽度不足时逐步收起：先收页面名，再收状态标签，最后收应用名。
              final double w = constraints.maxWidth;
              final bool showPageName = pageName != null && w >= 760;
              final bool showStatusTag = statusTag != null && w >= 620;
              final bool showTitle = w >= 520;

              return Row(
                children: <Widget>[
                  // 拖拽区：无边框窗口需要自己提供标题栏拖动。
                  Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onPanStart: onTitleBarDrag == null
                          ? null
                          : (DragStartDetails _) => onTitleBarDrag!(),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        child: Row(
                          children: <Widget>[
                            Icon(icon, size: 20, color: p.accent),
                            if (showTitle) ...<Widget>[
                              const SizedBox(width: 8),
                              Flexible(
                                child: Text(
                                  title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: PetLifeText.bodySmall,
                                    fontWeight: FontWeight.w700,
                                    color: p.textPrimary,
                                  ),
                                ),
                              ),
                            ],
                            if (showPageName) ...<Widget>[
                              const SizedBox(width: 10),
                              PetLifeTag(label: pageName!, dense: true),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (showStatusTag) ...<Widget>[
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: statusTag!,
                    ),
                  ],
                  ...actions,
                  const SizedBox(width: 10),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// 左侧导航栏（需求 §3）：白色 / 主色表面、当前项强调色胶囊、图标与文字水平排列。
class PetLifeDesktopNavigationRail extends StatelessWidget {
  const PetLifeDesktopNavigationRail({
    super.key,
    required this.destinations,
    required this.selectedIndex,
    required this.onSelected,
    this.compact = false,
    this.footer,
  });

  final List<PetLifeDesktopDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  /// true = 仅图标模式（窗口较窄时自动切换）。
  final bool compact;

  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final PetLifePalette p = PetLifeTheme.of(context);
    return Material(
      color: p.surface,
      child: SizedBox(
        width: compact
            ? PetLifeDesktopBreakpoints.iconRailWidth
            : PetLifeDesktopBreakpoints.railWidth,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border(right: BorderSide(color: p.divider)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 12,
                  ),
                  children: <Widget>[
                    for (int i = 0; i < destinations.length; i++)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: _RailItem(
                          destination: destinations[i],
                          selected: i == selectedIndex,
                          compact: compact,
                          onTap: () => onSelected(i),
                        ),
                      ),
                  ],
                ),
              ),
              if (footer != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
                  child: footer!,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RailItem extends StatelessWidget {
  const _RailItem({
    required this.destination,
    required this.selected,
    required this.compact,
    required this.onTap,
  });

  final PetLifeDesktopDestination destination;
  final bool selected;
  final bool compact;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final PetLifePalette p = PetLifeTheme.of(context);
    final Color foreground = selected ? p.onAccent : p.textPrimary;
    final Widget body = AnimatedContainer(
      duration: PetLifeDurations.desktopNavSelect,
      curve: PetLifeDurations.easing,
      height: PetLifeSpacing.minTouch,
      padding: EdgeInsets.symmetric(horizontal: compact ? 0 : 12),
      decoration: BoxDecoration(
        color: selected ? p.accent : Colors.transparent,
        borderRadius: BorderRadius.circular(PetLifeRadii.pill),
      ),
      child: Row(
        mainAxisAlignment:
            compact ? MainAxisAlignment.center : MainAxisAlignment.start,
        children: <Widget>[
          Icon(
            selected ? destination.selectedIcon : destination.icon,
            size: 20,
            color: foreground,
          ),
          if (!compact) ...<Widget>[
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                destination.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: PetLifeText.bodySmall,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: foreground,
                ),
              ),
            ),
          ],
        ],
      ),
    );

    return Tooltip(
      message: destination.label,
      waitDuration: const Duration(milliseconds: 400),
      child: Semantics(
        button: true,
        selected: selected,
        label: destination.label,
        child: InkWell(
          borderRadius: BorderRadius.circular(PetLifeRadii.pill),
          onTap: onTap,
          child: body,
        ),
      ),
    );
  }
}

/// 窄窗口下的顶部紧凑导航（需求 §3：窗口较窄时自动变为顶部紧凑导航，不能溢出）。
class PetLifeDesktopTopNavigation extends StatelessWidget {
  const PetLifeDesktopTopNavigation({
    super.key,
    required this.destinations,
    required this.selectedIndex,
    required this.onSelected,
  });

  final List<PetLifeDesktopDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final PetLifePalette p = PetLifeTheme.of(context);
    return Material(
      color: p.surface,
      child: SizedBox(
        height: 52,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: p.divider)),
          ),
          // 横向滚动：窗口再窄也不会把导航挤到溢出。
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            child: Row(
              children: <Widget>[
                for (int i = 0; i < destinations.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: _TopNavItem(
                      destination: destinations[i],
                      selected: i == selectedIndex,
                      onTap: () => onSelected(i),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TopNavItem extends StatelessWidget {
  const _TopNavItem({
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  final PetLifeDesktopDestination destination;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final PetLifePalette p = PetLifeTheme.of(context);
    return Semantics(
      button: true,
      selected: selected,
      label: destination.label,
      child: InkWell(
        borderRadius: BorderRadius.circular(PetLifeRadii.pill),
        onTap: onTap,
        child: AnimatedContainer(
          duration: PetLifeDurations.desktopNavSelect,
          curve: PetLifeDurations.easing,
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: selected ? p.accent : p.card,
            borderRadius: BorderRadius.circular(PetLifeRadii.pill),
            border: Border.all(color: selected ? p.accent : p.border),
          ),
          child: Row(
            children: <Widget>[
              Icon(
                selected ? destination.selectedIcon : destination.icon,
                size: 16,
                color: selected ? p.onAccent : p.textSecondary,
              ),
              const SizedBox(width: 6),
              Text(
                destination.label,
                style: TextStyle(
                  fontSize: PetLifeText.caption,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected ? p.onAccent : p.textPrimary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 桌面控制面板外壳（需求 §3 的结构图）。
///
/// ```
/// ┌────────────────────────────────────────────┐
/// │ 顶部栏：PetLife 控制面板      回到桌宠  电源 │
/// ├──────────────┬─────────────────────────────┤
/// │  左侧导航     │        当前页面内容          │
/// ├──────────────┴─────────────────────────────┤
/// │ 可选底部状态条                               │
/// └────────────────────────────────────────────┘
/// ```
///
/// **页面状态保留**：用 [IndexedStack] 而不是条件构建，切走的页面不会被销毁；
/// 但**只构建访问过的页面**（懒加载），因此打开面板不会一次性拉起七个页面的
/// 数据库查询与网络请求。
class PetLifeDesktopScaffold extends StatefulWidget {
  const PetLifeDesktopScaffold({
    super.key,
    required this.destinations,
    required this.selectedIndex,
    required this.onSelected,
    required this.pages,
    required this.toolbar,
    this.footer,
  });

  final List<PetLifeDesktopDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  /// 与 [destinations] 一一对应的页面。
  final List<Widget> pages;

  final PetLifeDesktopToolbar toolbar;

  /// 底部状态条（当前设备 / 同步状态 / 版本信息）。
  final Widget? footer;

  @override
  State<PetLifeDesktopScaffold> createState() => _PetLifeDesktopScaffoldState();
}

class _PetLifeDesktopScaffoldState extends State<PetLifeDesktopScaffold> {
  /// 已经访问过的页面下标（懒加载 + 之后常驻，保留各自的滚动与筛选状态）。
  final Set<int> _visited = <int>{};

  @override
  void initState() {
    super.initState();
    _visited.add(widget.selectedIndex);
  }

  @override
  void didUpdateWidget(PetLifeDesktopScaffold oldWidget) {
    super.didUpdateWidget(oldWidget);
    _visited.add(widget.selectedIndex);
  }

  @override
  Widget build(BuildContext context) {
    final PetLifePalette p = PetLifeTheme.of(context);
    return Material(
      color: p.surface,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final double width = constraints.maxWidth;
          final bool showsRail =
              width >= PetLifeDesktopBreakpoints.iconRail;
          final bool compactRail =
              width < PetLifeDesktopBreakpoints.fullRail;

          return Column(
            children: <Widget>[
              widget.toolbar,
              if (!showsRail)
                PetLifeDesktopTopNavigation(
                  destinations: widget.destinations,
                  selectedIndex: widget.selectedIndex,
                  onSelected: widget.onSelected,
                ),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    if (showsRail)
                      PetLifeDesktopNavigationRail(
                        destinations: widget.destinations,
                        selectedIndex: widget.selectedIndex,
                        onSelected: widget.onSelected,
                        compact: compactRail,
                      ),
                    Expanded(
                      child: _DesktopPageHost(
                        index: widget.selectedIndex,
                        visited: _visited,
                        children: widget.pages,
                      ),
                    ),
                  ],
                ),
              ),
              if (widget.footer != null) widget.footer!,
            ],
          );
        },
      ),
    );
  }
}

/// 懒加载 + 保留状态的页面宿主。
class _DesktopPageHost extends StatefulWidget {
  const _DesktopPageHost({
    required this.index,
    required this.visited,
    required this.children,
  });

  final int index;
  final Set<int> visited;
  final List<Widget> children;

  @override
  State<_DesktopPageHost> createState() => _DesktopPageHostState();
}

class _DesktopPageHostState extends State<_DesktopPageHost>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: PetLifeDurations.desktopPageSwitch,
    value: 1,
  );
  late final Animation<double> _fade =
      CurvedAnimation(parent: _controller, curve: Curves.easeOut);

  @override
  void didUpdateWidget(_DesktopPageHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index != widget.index) {
      // 桌面只用淡入，不做位移（需求 §9 禁止页面大幅滑动）。
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fade,
      child: IndexedStack(
        index: widget.index,
        children: <Widget>[
          for (int i = 0; i < widget.children.length; i++)
            if (widget.visited.contains(i))
              widget.children[i]
            else
              const SizedBox.shrink(),
        ],
      ),
    );
  }
}

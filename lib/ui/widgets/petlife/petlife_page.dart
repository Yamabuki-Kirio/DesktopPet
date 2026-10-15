import 'package:flutter/material.dart';

import '../../theme/design_tokens.dart';
import '../../theme/petlife_theme.dart';
import 'petlife_decor.dart';

/// 根页面的统一骨架（需求 §3「页面结构」）。
///
/// 结构固定为：页面标题区 → 页面内容滚动区。
/// 底部导航栏由外壳（`MobileShell`）统一提供，页面本身不创建 `Scaffold`。
///
/// 刻意**不用**厚重的纯色 `AppBar`：
/// 标题左对齐、深色粗体，右侧只放当前页面必要的操作。
class PetLifePage extends StatelessWidget {
  const PetLifePage({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.actions = const <Widget>[],
    this.backdrop = true,
    this.padding = PetLifeSpacing.pageInsets,
    this.headerTrailing,
  });

  /// 页面标题（22sp 粗体，左对齐）。
  final String title;

  /// 标题下方的补充说明（例如「本机统计」这类口径提示）。
  final String? subtitle;

  /// 右侧操作区。**只放当前页面必要的操作**。
  final List<Widget> actions;

  /// 页面内容（通常是 `ListView` / `CustomScrollView`）。
  final Widget child;

  /// 是否绘制顶部 P3P 装饰区（每屏最多一个）。
  final bool backdrop;

  /// 内容区内边距。
  final EdgeInsetsGeometry padding;

  /// 标题右侧、操作区下方的附加内容（例如状态标签）。
  final Widget? headerTrailing;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: <Widget>[
        if (backdrop)
          Positioned(top: 0, left: 0, right: 0, child: P3pPageBackdrop()),
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _Header(
              title: title,
              subtitle: subtitle,
              actions: actions,
              trailing: headerTrailing,
            ),
            Expanded(
              child: Padding(
                padding: padding,
                child: child,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.title,
    this.subtitle,
    this.actions = const <Widget>[],
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final List<Widget> actions;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final PetLifePalette p = PetLifeTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        PetLifeSpacing.page,
        PetLifeSpacing.topContent,
        PetLifeSpacing.page - 8,
        10,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  title,
                  style: TextStyle(
                    fontSize: PetLifeText.pageTitle,
                    fontWeight: FontWeight.w700,
                    color: p.textPrimary,
                    height: 1.15,
                  ),
                ),
                const SizedBox(height: 5),
                const P3pTitleAccent(),
                if (subtitle != null) ...<Widget>[
                  const SizedBox(height: 6),
                  Text(
                    subtitle!,
                    style: TextStyle(
                      fontSize: PetLifeText.caption,
                      color: p.textSecondary,
                    ),
                  ),
                ],
                if (trailing != null) ...<Widget>[
                  const SizedBox(height: 8),
                  trailing!,
                ],
              ],
            ),
          ),
          if (actions.isNotEmpty)
            Wrap(
              spacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: actions,
            ),
        ],
      ),
    );
  }
}

/// 页面头部的圆形图标按钮（触摸区 ≥48dp）。
class PetLifeHeaderAction extends StatelessWidget {
  const PetLifeHeaderAction({
    super.key,
    required this.icon,
    required this.tooltip,
    this.onPressed,
    this.badge = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool badge;

  @override
  Widget build(BuildContext context) {
    final PetLifePalette p = PetLifeTheme.of(context);
    return Stack(
      children: <Widget>[
        IconButton(
          tooltip: tooltip,
          onPressed: onPressed,
          iconSize: 22,
          constraints: const BoxConstraints(
            minWidth: PetLifeSpacing.minTouch,
            minHeight: PetLifeSpacing.minTouch,
          ),
          color: p.textPrimary,
          icon: Icon(icon),
        ),
        if (badge)
          Positioned(
            right: 10,
            top: 10,
            child: Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: p.accent, shape: BoxShape.circle),
            ),
          ),
      ],
    );
  }
}

/// 页面内容的统一滚动容器。
class PetLifeScrollView extends StatelessWidget {
  const PetLifeScrollView({
    super.key,
    required this.children,
    this.padding = EdgeInsets.zero,
    this.controller,
    this.header,
  });

  final List<Widget> children;
  final EdgeInsetsGeometry padding;
  final ScrollController? controller;

  /// 不参与滚动区域裁剪的固定头部（例如工具条）。
  final Widget? header;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (header != null) header!,
        Expanded(
          child: ListView(
            controller: controller,
            padding: padding,
            children: children,
          ),
        ),
      ],
    );
  }
}

/// 根页面之间的切换动画（需求 §6：180～240ms，快速但平滑）。
///
/// 用 [IndexedStack] 保留每个页面的状态（滚动位置、展开状态、控制器），
/// 同时在切换时对**当前页**播放淡入 + 轻微上移 —— 不复制页面、不重建状态，
/// 因此不会出现「切回来又发一次网络请求」。
class PetLifePageSwitcher extends StatefulWidget {
  const PetLifePageSwitcher({
    super.key,
    required this.index,
    required this.children,
  });

  final int index;
  final List<Widget> children;

  @override
  State<PetLifePageSwitcher> createState() => _PetLifePageSwitcherState();
}

class _PetLifePageSwitcherState extends State<PetLifePageSwitcher>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: PetLifeDurations.pageSwitch,
    value: 1,
  );
  late final Animation<double> _fade = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOut,
  );
  late final Animation<Offset> _slide = Tween<Offset>(
    begin: const Offset(0, 0.018),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: _controller, curve: PetLifeDurations.easing));

  @override
  void didUpdateWidget(PetLifePageSwitcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index != widget.index) {
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
      child: SlideTransition(
        position: _slide,
        child: IndexedStack(index: widget.index, children: widget.children),
      ),
    );
  }
}

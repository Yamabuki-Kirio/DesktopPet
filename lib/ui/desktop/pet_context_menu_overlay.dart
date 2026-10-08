/// 受约束的右键菜单（替换 `showMenu`；修复真机回归 #2）。
///
/// 为什么不用 `showMenu`
/// --------------------
/// `showMenu` 的默认 `constraints` 只有 minWidth / maxWidth（见
/// [ContextMenuLayout] 的类注释），会把 popup route 自带的"overlay - 8px"高度约束
/// 覆盖掉，导致 `SingleChildScrollView` 拿到无限高：条目全部摊开、超出屏幕、
/// 且**不能滚动**。真机现象就是"右键旧菜单所有项目一次性展开，超出可用高度
/// 且不能滚动"。
///
/// 本实现自建 `OverlayEntry`：
/// * 尺寸由 [ContextMenuLayout.plan] 依 **鼠标所在显示器 workArea** 规划，
///   **规划值 == 最终渲染值**，因此调用方可以先用同一个矩形去扩 Region；
/// * `SingleChildScrollView` 拿到的是**有限高度**，滚轮 / 拖动条都能滚；
/// * 上下键移动高亮、Enter 激活、Esc 关闭；打开时把当前状态项滚入可见区；
/// * 打开 / 关闭都不动 HWND 矩形，只动 Region。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/scheduler.dart';

import '../../menu/context_menu_layout.dart';

/// 右键菜单的显示入口。
class PetContextMenuOverlay {
  PetContextMenuOverlay._();

  /// 弹出菜单并等待用户选择。
  ///
  /// 返回选中的 [ContextMenuItem.value]；被 dismiss（Esc / 点击外部 / 外壳切面板）
  /// 时返回 null。
  ///
  /// [onPresented] 在菜单**已经插入 overlay**（但尚未等结果）时回调，并交付一个
  /// "主动关闭"句柄 —— 外壳切面板前要靠它 dismiss 菜单（`ContextMenuBridge`）。
  static Future<String?> show({
    required OverlayState overlay,
    required List<ContextMenuItem> items,
    required ContextMenuPlan plan,
    String? initialValue,
    void Function(VoidCallback dismiss)? onPresented,
  }) {
    final Completer<String?> done = Completer<String?>();
    // `entry` 用可空持有是为了让 `finish` 能在移除后置空（防重入）。
    OverlayEntry? current;

    void finish(String? value) {
      if (done.isCompleted) return;
      final OverlayEntry? toRemove = current;
      current = null;
      if (toRemove != null) {
        // 极端情况下（例如插入后第一帧内就被 dismiss）不能在 layout / build 期间
        // 移除 entry，退到帧末执行。
        final SchedulerPhase phase = SchedulerBinding.instance.schedulerPhase;
        if (phase == SchedulerPhase.persistentCallbacks) {
          SchedulerBinding.instance.addPostFrameCallback((_) => toRemove.remove());
        } else {
          toRemove.remove();
        }
      }
      done.complete(value);
    }

    final OverlayEntry entry = OverlayEntry(
      builder: (BuildContext context) => _PetContextMenuLayer(
        items: items,
        plan: plan,
        initialValue: initialValue,
        onSelected: (String value) => finish(value),
        onDismissed: () => finish(null),
      ),
    );
    current = entry;
    overlay.insert(entry);
    onPresented?.call(() => finish(null));
    return done.future;
  }
}

class _PetContextMenuLayer extends StatefulWidget {
  const _PetContextMenuLayer({
    required this.items,
    required this.plan,
    required this.onSelected,
    required this.onDismissed,
    this.initialValue,
  });

  final List<ContextMenuItem> items;
  final ContextMenuPlan plan;
  final String? initialValue;
  final ValueChanged<String> onSelected;
  final VoidCallback onDismissed;

  @override
  State<_PetContextMenuLayer> createState() => _PetContextMenuLayerState();
}

class _PetContextMenuLayerState extends State<_PetContextMenuLayer> {
  late final ScrollController _scroll = ScrollController(
    initialScrollOffset: widget.plan.initialScrollOffset,
  );
  final FocusNode _focusNode = FocusNode(debugLabel: 'pet-context-menu');
  late int _highlight = _initialHighlight();

  static const Color _surface = Color(0xFFFFFFFF);
  static const Color _highlightColor = Color(0xFFFFD8E9);
  static const Color _dividerColor = Color(0x1A000000);

  int _initialHighlight() {
    final String? value = widget.initialValue;
    if (value != null) {
      for (int i = 0; i < widget.items.length; i++) {
        if (widget.items[i].value == value && widget.items[i].actionable) return i;
      }
    }
    return ContextMenuLayout.firstActionable(widget.items);
  }

  @override
  void initState() {
    super.initState();
    // 菜单是通过 `OverlayEntry` 插入的，`autofocus` 不保证一定拿到焦点
    // （父 FocusScope 可能已经聚焦别处）。这里显式再请求一次，保证
    // Esc / ↑↓ / Enter 一定生效。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _move(int step) {
    final int next = ContextMenuLayout.nextActionable(
      widget.items,
      _highlight < 0 ? (step > 0 ? -1 : widget.items.length) : _highlight,
      step,
    );
    if (next == _highlight || next < 0) return;
    setState(() => _highlight = next);
    _ensureVisible(next);
  }

  void _ensureVisible(int index) {
    if (!_scroll.hasClients) return;
    final double viewport = widget.plan.rect.height;
    final double maxOffset =
        (widget.plan.contentExtent - viewport).clamp(0.0, double.infinity);
    final double start = ContextMenuLayout.extentBefore(widget.items, index);
    final double end = start + ContextMenuLayout.extentOf(widget.items[index]);
    final double offset = _scroll.offset;
    double next = offset;
    if (start < offset) {
      next = start;
    } else if (end > offset + viewport) {
      next = end - viewport;
    }
    next = next.clamp(0.0, maxOffset);
    if ((next - offset).abs() > 0.5) _scroll.jumpTo(next);
  }

  void _activate() {
    if (_highlight < 0 || _highlight >= widget.items.length) return;
    final ContextMenuItem item = widget.items[_highlight];
    if (!item.actionable) return;
    widget.onSelected(item.value!);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final LogicalKeyboardKey key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      widget.onDismissed();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      _move(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _move(-1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.space) {
      _activate();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: <Widget>[
        // 点击菜单之外：关闭（与 `showMenu` 的 modal barrier 行为一致）。
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onDismissed,
            child: const SizedBox.expand(),
          ),
        ),
        Positioned.fromRect(
          rect: widget.plan.rect,
          child: Focus(
            focusNode: _focusNode,
            autofocus: true,
            onKeyEvent: _onKey,
            child: Material(
              elevation: 8,
              color: _surface,
              borderRadius: BorderRadius.circular(10),
              clipBehavior: Clip.antiAlias,
              child: ConstrainedBox(
                // 高度**有限**：这正是滚动生效的前提。
                constraints: BoxConstraints(
                  maxHeight: widget.plan.maxHeight,
                  maxWidth: widget.plan.width,
                ),
                child: SingleChildScrollView(
                  controller: _scroll,
                  padding: const EdgeInsets.symmetric(
                    vertical: ContextMenuLayout.verticalPadding,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      for (int i = 0; i < widget.items.length; i++)
                        _buildItem(i, widget.items[i]),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildItem(int index, ContextMenuItem item) {
    if (item.divider) {
      return SizedBox(
        height: ContextMenuLayout.dividerExtent,
        child: Center(child: Container(height: 1, color: _dividerColor)),
      );
    }
    final bool highlighted = item.actionable && index == _highlight;
    return SizedBox(
      height: ContextMenuLayout.itemExtent,
      child: InkWell(
        onTap: item.actionable ? () => widget.onSelected(item.value!) : null,
        onHover: (bool hovering) {
          if (!hovering) return;
          if (item.actionable && index != _highlight) {
            setState(() => _highlight = index);
          }
        },
        child: Container(
          color: highlighted ? _highlightColor : null,
          padding: const EdgeInsets.symmetric(
            horizontal: ContextMenuLayout.itemHorizontalPadding,
          ),
          alignment: Alignment.centerLeft,
          child: Text(
            item.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              color: item.enabled ? const Color(0xFF111111) : const Color(0xFF8E7180),
            ),
          ),
        ),
      ),
    );
  }
}

/// 按真实文本量出菜单首选宽度（供 [ContextMenuLayout.plan] 使用）。
///
/// 与渲染使用同一套字体参数，因此规划宽度与最终 `IntrinsicWidth` 无关、
/// 完全确定 —— Region 才能精确贴合菜单。
double measureContextMenuWidth({
  required List<ContextMenuItem> items,
  required TextStyle style,
  required double maxWidth,
}) {
  double widest = 0;
  for (final ContextMenuItem item in items) {
    if (item.divider) continue;
    final TextPainter painter = TextPainter(
      text: TextSpan(text: item.label, style: style),
      maxLines: 1,
      textDirection: TextDirection.ltr,
    )..layout();
    if (painter.width > widest) widest = painter.width;
    painter.dispose();
  }
  return widest +
      ContextMenuLayout.itemHorizontalPadding * 2 +
      ContextMenuLayout.itemIconSlot;
}

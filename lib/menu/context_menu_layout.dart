/// 右键（上下文）菜单的**纯几何规划**：受 workArea 约束、可滚动、锚在鼠标附近。
///
/// 背景（真机回归 #2）
/// ----------------
/// 旧实现直接用 `showMenu`，而 Flutter 的默认 `constraints` **只有 minWidth /
/// maxWidth，没有 maxHeight**：
///
/// ```dart
/// const BoxConstraints(minWidth: 2.0 * 56.0, maxWidth: 5.0 * 56.0)
/// ```
///
/// 这个 `ConstrainedBox` 会把 `_PopupMenuRouteLayout` 计算出的"overlay 减去 8px"
/// 高度约束**覆盖掉**，于是内部的 `SingleChildScrollView` 拿到的是**无限高** ——
/// 菜单把所有条目一次性撑开、超出屏幕，而且**无法滚动**。
///
/// 本文件把"菜单该多大、该放哪里"抽成纯函数：给定时长可完整单测，且**与实际
/// 渲染共用同一组常量**（`PetContextMenuOverlay` 的条目高度、内边距都取这里），
/// 因此规划出来的矩形就是最终弹出的矩形 —— Region 才能精确覆盖它，
/// 不用再退化到"整块固定画布"。
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// 一个菜单条目。
class ContextMenuItem {
  const ContextMenuItem({
    required this.label,
    this.value,
    this.enabled = true,
    this.divider = false,
  });

  /// 分隔线（忽略 [label] / [value]）。
  const ContextMenuItem.divider()
      : label = '',
        value = null,
        enabled = false,
        divider = true;

  final String label;

  /// 选中后回传的值；null = 纯展示 / 不可点。
  final String? value;

  final bool enabled;
  final bool divider;

  /// 是否可被点击 / 键盘激活。
  bool get actionable => !divider && enabled && value != null;
}

/// 菜单几何规划结果。
class ContextMenuPlan {
  const ContextMenuPlan({
    required this.rect,
    required this.contentExtent,
    required this.scrolls,
    required this.initialScrollOffset,
    required this.width,
    required this.maxHeight,
  });

  /// 菜单在 **overlay 局部坐标系**里的矩形（规划值与最终渲染值一致）。
  final Rect rect;

  /// 内容自然高度（未受约束时）。
  final double contentExtent;

  /// 内容是否装不下（需要滚动）。
  final bool scrolls;

  /// 打开时的初始滚动偏移（把 [ContextMenuPlan] 的"当前状态项"滚入可见区）。
  final double initialScrollOffset;

  /// 最终宽度（== `rect.width`）。
  final double width;

  /// 本次允许的最大高度。
  final double maxHeight;

  /// Region 用：菜单实际占位矩形。
  Rect get regionRect => rect;
}

class ContextMenuLayout {
  ContextMenuLayout._();

  /// 普通条目高度（与 `PetContextMenuOverlay` 的 `SizedBox` 严格一致）。
  static const double itemExtent = 40;

  /// 分隔线高度。
  static const double dividerExtent = 9;

  /// 上下内边距（`SingleChildScrollView` 的 `padding.vertical`）。
  static const double verticalPadding = 8;

  /// 内容总内边距（上 + 下）。
  static const double totalVerticalPadding = verticalPadding * 2;

  static const double minWidth = 200;
  static const double maxWidthCap = 360;

  /// 高度上限（用户建议值）：`min(workArea.height - 32, 560)`。
  static const double maxHeightCap = 560;

  /// 上下 / 左右的**总**安全边距（`maxHeight = workArea.height - capMargin`）。
  static const double capMargin = 32;

  /// 定位时的额外安全边距（每侧）。
  static const double screenMargin = 8;

  /// 锚点与菜单之间的间隙。
  static const double anchorGap = 4;

  /// 条目文本的左右内边距 + 图标槽位（用于宽度估算）。
  static const double itemHorizontalPadding = 16;
  static const double itemIconSlot = 28;

  /// 条目自然高度。
  static double extentOf(ContextMenuItem item) =>
      item.divider ? dividerExtent : itemExtent;

  /// 内容自然高度。
  static double contentExtentFor(List<ContextMenuItem> items) {
    double total = totalVerticalPadding;
    for (final ContextMenuItem item in items) {
      total += extentOf(item);
    }
    return total;
  }

  /// 第 [index] 个条目起点相对内容顶部的偏移。
  static double extentBefore(List<ContextMenuItem> items, int index) {
    double total = verticalPadding;
    for (int i = 0; i < index && i < items.length; i++) {
      total += extentOf(items[i]);
    }
    return total;
  }

  /// 菜单允许的最大高度：`min(workArea.height - 32, 560)`。
  static double maxHeightFor(Size workArea) {
    final double byScreen = workArea.height - capMargin;
    final double cap = math.min(maxHeightCap, byScreen);
    return math.max(itemExtent, cap);
  }

  /// 菜单允许的最大宽度：`min(workArea.width - 32, 360)`。
  static double maxWidthFor(Size workArea) {
    final double byScreen = workArea.width - capMargin;
    final double cap = math.min(maxWidthCap, byScreen);
    return math.max(minWidth, cap);
  }

  /// 规划菜单几何。
  ///
  /// * [anchor]：鼠标在 **overlay 局部坐标**里的位置；
  /// * [overlaySize]：overlay 尺寸（固定画布模式下 == 整块画布）；
  /// * [workArea]：鼠标所在显示器的**可用工作区**，已平移到 overlay 局部坐标；
  /// * [preferredWidth]：按文本量出来的首选宽度（会再被上下限夹取）。
  static ContextMenuPlan plan({
    required Offset anchor,
    required Size overlaySize,
    required Rect workArea,
    required List<ContextMenuItem> items,
    double? preferredWidth,
    int initialIndex = 0,
  }) {
    // 可用范围 = 工作区 ∩ overlay，再各侧内缩安全边距。
    Rect usable = workArea.intersect(Offset.zero & overlaySize);
    if (usable.width <= 0 || usable.height <= 0) {
      usable = Offset.zero & overlaySize;
    }
    usable = usable.deflate(screenMargin);
    if (usable.width <= 0 || usable.height <= 0) {
      usable = Offset.zero & overlaySize;
    }

    // --- 尺寸 ---
    // 上限口径统一到"当前显示器工作区"，**不再**对已内缩的 usable 二次扣减。
    final double widthLimit = math.max(1.0, math.min(maxWidthFor(workArea.size), usable.width));
    double width = preferredWidth ?? minWidth;
    if (width < minWidth) width = math.min(minWidth, widthLimit);
    if (width > widthLimit) width = widthLimit;

    final double contentExtent = contentExtentFor(items);
    final double heightLimit =
        math.max(1.0, math.min(maxHeightFor(workArea.size), usable.height));
    final double height = math.min(contentExtent, heightLimit);
    final bool scrolls = contentExtent > height + 0.5;

    // --- 位置：优先锚点右下；放不下就往左上翻；最后夹进可用范围 ---
    double left = anchor.dx;
    if (left + width > usable.right) left = anchor.dx - width;
    left = left.clamp(usable.left, math.max(usable.left, usable.right - width));

    double top = anchor.dy + anchorGap;
    if (top + height > usable.bottom) top = anchor.dy - anchorGap - height;
    top = top.clamp(usable.top, math.max(usable.top, usable.bottom - height));

    final double initialOffset = scrolls
        ? ensureVisibleOffset(
            items: items,
            index: initialIndex,
            viewport: height,
            contentExtent: contentExtent,
          )
        : 0;

    return ContextMenuPlan(
      rect: Rect.fromLTWH(left, top, width, height),
      contentExtent: contentExtent,
      scrolls: scrolls,
      initialScrollOffset: initialOffset,
      width: width,
      maxHeight: heightLimit,
    );
  }

  /// 让第 [index] 个条目落进 `[0, viewport]` 所需的最小滚动偏移
  /// （"打开时默认把当前状态项滚入可见区域"）。
  static double ensureVisibleOffset({
    required List<ContextMenuItem> items,
    required int index,
    required double viewport,
    required double contentExtent,
  }) {
    if (index < 0 || index >= items.length) return 0;
    final double maxOffset = math.max(0, contentExtent - viewport);
    if (maxOffset <= 0) return 0;
    final double start = extentBefore(items, index);
    final double end = start + extentOf(items[index]);
    if (start < 0) return 0;
    if (end > viewport) {
      return (end - viewport).clamp(0.0, maxOffset);
    }
    return 0;
  }

  /// 键盘导航：把高亮移到下一个 / 上一个**可点**条目；没有则返回原值。
  static int nextActionable(List<ContextMenuItem> items, int from, int step) {
    int index = from;
    for (int i = 0; i < items.length; i++) {
      index += step;
      if (index < 0 || index >= items.length) return from;
      if (items[index].actionable) return index;
    }
    return from;
  }

  /// 第一个可点条目（没有则 -1）。
  static int firstActionable(List<ContextMenuItem> items) {
    for (int i = 0; i < items.length; i++) {
      if (items[i].actionable) return i;
    }
    return -1;
  }
}

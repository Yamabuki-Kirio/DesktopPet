/// C1.1.2：轮盘的**指针交互态**（与 [WheelMenuStateMachine] 并列，互不混用）。
///
/// 背景（真机缺陷）
/// ----------------
/// 旧实现把「键盘焦点 / 鼠标悬停 / 圆弧滑选 / 当前动画按钮 / 默认按钮」全部挤在
/// `WheelMenuStateMachine.selectedIndex`（经 `previewIndex` 覆盖）一个索引里：
/// * 鼠标停在按钮上时高亮 **不跟随**（动画结束后无人重算 hover）；
/// * 切子菜单 / 重算几何时无法区分"这次高亮是鼠标给的吗"；
/// * 于是"移入按钮 → 高亮回跳第一项 → 静止单击只关菜单"。
///
/// 修复（需求 §三）
/// --------------
/// 把交互态**拆开**，视觉高亮只做**纯派生**，且**绝不由动画帧写入**：
///
/// ```text
/// visualActiveIndex = f(pressedIndex, gestureSelectedIndex, hoveredIndex, activeInputKind)
/// ```
///
/// * 鼠标没有落在任何按钮命中区时，[visualActiveIndex] 为 null →
///   上层取 [visualActiveIndexOrNone] 得到 `-1` = **不高亮任何按钮**（需求 C1）。
/// * `WheelMenuStateMachine.selectedIndex` **保留**，但语义收窄为
///   "已确认项 / 弧形文字定位锚点"，**不再是**默认视觉高亮。
///
/// 本文件是**纯 Dart**（只依赖 `dart:ui` 的 [Offset] 与 `PointerDeviceKind`），
/// 可在 `flutter_tester` 直接单测。
library;

import 'dart:ui' show Offset;

import 'package:flutter/gestures.dart' show PointerDeviceKind;

/// 轮盘指针交互态（可变；由 [WheelMenuController] 独占写入）。
class WheelPointerState {
  /// 鼠标悬停到的按钮（Region 内真实 HitTest 结果；null = 不在任何按钮上）。
  ///
  /// **只能**由鼠标 HitTest 写入（需求 §11）：动画帧 / rebuild / Region 提交 /
  /// 键盘焦点 / 子菜单默认项 / activeIndex / 动作结果一律不得写它。
  int? hoveredIndex;

  /// **视觉锚点**（扇叶角度 / 弧形文字 / 实时信息跟着谁排布）。
  ///
  /// 由鼠标 HitTest（或鼠标手势）更新；鼠标**离开有效扇形时保持不变**（粘性），
  /// 因此"取消高亮"**不会**把扇叶 / 标题跳回第一项（需求 §1 / §3 / §11-5）。
  /// 只有换层 / 关闭 / 失活才清空。
  int? anchorIndex;

  /// 键盘焦点（**只有键盘输入后**才允许进入视觉，见 [keyboardMode]）。
  int? keyboardFocusedIndex;

  /// 圆弧滑选当前项。
  int? gestureSelectedIndex;

  /// 本次按下（PointerDown 实时 HitTest）命中的按钮。
  int? pressedIndex;

  /// 最近一次参与交互的输入类型。
  PointerDeviceKind? activeInputKind;

  /// 是否处于"键盘模式"（键盘输入过一次即置 true，鼠标输入则清零）。
  bool keyboardMode = false;

  /// **最近一次**指针位置（**CanvasLocalSpace / 菜单窗口局部坐标**，唯一口径）。
  ///
  /// 打开动画期间收到的位置也**必须**保存（需求 §七 强制约束），
  /// 动画完成 / 几何刷新时用它重新 HitTest，而不是丢弃或默认第一项。
  Offset? lastPointerLocal;

  /// 最近一次 HitTest 得到的按钮（诊断用；null = 不在按钮上）。
  int? lastHitIndex;

  /// 最近一次 HitTest 的分区名（需求 §2 日志字段 `hitZone`）。
  String? lastHitZone;

  /// 最近一次 HitTest 的半径 / 绝对角度（需求 §2 日志字段 `radius` / `angle`）。
  double lastHitRadius = 0;
  double lastHitAngle = 0;

  /// 视觉高亮的按钮索引（派生；null = 无高亮）。
  ///
  /// **不由动画帧写入**：只由输入事件 / 几何重算改变。
  ///
  /// 需求 §3（鼠标输入模式粘性）：只要当前处于鼠标（或触摸）交互，取值**只能**
  /// 来自该输入源（按下 → 滑选 → 悬停），**严禁**回落到 `keyboardFocusedIndex`、
  /// `activeIndex`、`firstEnabledIndex` 或 `0`。只有收到真实键盘导航事件后才切到
  /// 键盘模式。
  int? get visualActiveIndex {
    if (keyboardMode) return keyboardFocusedIndex;
    return pressedIndex ?? gestureSelectedIndex ?? hoveredIndex;
  }

  /// 本次视觉高亮的**来源**（日志 / 诊断；`none` = 无高亮）。
  String get highlightSource {
    if (keyboardMode) return 'keyboard';
    if (pressedIndex != null) return 'press';
    if (gestureSelectedIndex != null) return 'gesture';
    if (hoveredIndex != null) return 'hover';
    return 'none';
  }

  /// 供渲染层直接消费的 `int`：无高亮 = `-1`（`WheelRenderParams.highlightIndex` 口径）。
  int visualActiveIndexOrNone(int itemCount) {
    final int? index = visualActiveIndex;
    if (index == null || index < 0 || index >= itemCount) return -1;
    return index;
  }

  /// 是否有任何指针来源的高亮。
  bool get hasPointerHighlight =>
      pressedIndex != null || gestureSelectedIndex != null || hoveredIndex != null;

  /// 清掉"指针选择类"状态（保留最近位置，供几何刷新后重算）。
  ///
  /// **换层时也会调用**（需求 §8）：旧层的 hover / press / 锚点一律作废，
  /// 之后用**新几何** + 最近指针位置重新 HitTest（绝不默认赋值 0）。
  void clearPointer() {
    hoveredIndex = null;
    gestureSelectedIndex = null;
    pressedIndex = null;
    anchorIndex = null;
    lastHitIndex = null;
    lastHitZone = null;
  }

  /// 键盘焦点落地（需求 §四：只有键盘输入后才允许进入视觉）。
  void focusFirst(int? index) {
    keyboardFocusedIndex = index;
  }

  /// 全部清空（关闭菜单 / 失活）。
  void reset() {
    hoveredIndex = null;
    keyboardFocusedIndex = null;
    gestureSelectedIndex = null;
    pressedIndex = null;
    anchorIndex = null;
    activeInputKind = null;
    keyboardMode = false;
    lastPointerLocal = null;
    lastHitIndex = null;
    lastHitZone = null;
    lastHitRadius = 0;
    lastHitAngle = 0;
  }

  /// 诊断快照（进日志 / 进测试断言）。
  Map<String, Object?> describe() => <String, Object?>{
        'hoveredIndex': hoveredIndex,
        'keyboardFocusedIndex': keyboardFocusedIndex,
        'gestureSelectedIndex': gestureSelectedIndex,
        'pressedIndex': pressedIndex,
        'anchorIndex': anchorIndex,
        'inputKind': activeInputKind?.name,
        'keyboardMode': keyboardMode,
        'pointerLocal': lastPointerLocal == null
            ? 'none'
            : '${lastPointerLocal!.dx.toStringAsFixed(1)},'
                '${lastPointerLocal!.dy.toStringAsFixed(1)}',
        'lastHitIndex': lastHitIndex,
        'hitZone': lastHitZone,
        'radius': lastHitRadius.toStringAsFixed(1),
        'angle': lastHitAngle.toStringAsFixed(1),
        'visualActiveIndex': visualActiveIndex,
        'highlightSource': highlightSource,
      };

  @override
  String toString() => 'WheelPointerState(hover=$hoveredIndex '
      'anchor=$anchorIndex '
      'kbd=$keyboardFocusedIndex gesture=$gestureSelectedIndex '
      'press=$pressedIndex kind=${activeInputKind?.name} '
      'kbdMode=$keyboardMode)';
}

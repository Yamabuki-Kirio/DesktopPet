/// 正式 P3P 轮盘的**视图与交互层**（增量 B）。
///
/// 结构（与 Android `WheelMenuView` + `WheelMenuRenderer` 的分工一致）：
/// * [WheelMenuController] —— 纯逻辑：状态机（[WheelMenuStateMachine]）、手势
///   （[WheelMenuGestureController]）、动画时钟（[WheelAnimationClock]）、几何（[WheelMenuLayout]）。
///   **不依赖任何 Widget / 桌面库**，可用注入时钟直接单测。
/// * [WheelMenuView] —— 装配：一个 `Ticker` 驱动 [WheelMenuController.tick]；
///   一个 `Listener` 收鼠标按下 / 移动 / 松开；一个 `MouseRegion` 收**悬停**；
///   一个 `Focus` 收 **Esc**。渲染交给 [WheelMenuRenderer]。
///
/// 输入映射（决策四 / docs/37 §15.2）：
///
/// | Android 触摸 | Windows 鼠标 |
/// | --- | --- |
/// | `ACTION_DOWN` | 左键按下 |
/// | `ACTION_MOVE`（按住拖动） | 按住左键拖动 |
/// | `ACTION_UP` | 松开左键 |
/// | `ACTION_CANCEL` / 多指 | Esc / 指针取消 / 失焦 |
/// | （无） | **额外**：悬停按 ring 分区更新高亮（只预览、不确认） |
/// | （无） | **额外**：Esc 先取消预览 → 子菜单则返回 → 根菜单则关闭 |
library;

import 'dart:math' as math;

import 'package:flutter/gestures.dart' show PointerDeviceKind, PointerHoverEvent;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart' show KeyDownEvent, LogicalKeyboardKey;

import '../../menu/menu_contract.dart' show MenuCatalog, MenuLevel, MenuNode;
import '../../menu/wheel_adjustment_layer.dart' show WheelAdjustmentKind, WheelAdjustmentLayer;
import '../../menu/wheel_animator.dart'
    show WheelAnimationClock, WheelAnimationFrame, WheelAnimationKind, WheelAnimationRun;
import '../../menu/wheel_button_hit.dart'
    show WheelHitTester, WheelPointerHit;
import '../../menu/wheel_geometry_ownership.dart' show wheelGeometryJournal;
import '../../menu/wheel_menu_geometry.dart'
    show WheelMenuEnvelope, WheelMenuGeometry, WheelMenuLayout, WheelMenuLayoutSettings, WheelMenuSpec;
import '../../menu/wheel_menu_state.dart' show WheelMenuPhase, WheelMenuStateMachine;
import '../../menu/wheel_pointer_state.dart' show WheelPointerState;
import '../../menu/wheel_selection_controller.dart'
    show
        WheelGestureEffect,
        WheelGestureOutcome,
        WheelMenuGestureController,
        WheelPetDragPhase;
import '../../menu/wheel_theme.dart' show WheelMenuTheme;
import '../../menu/wheel_region.dart' show WheelRegionBuilder;
import 'wheel_menu_painter.dart' show WheelMenuRenderer, WheelRenderParams;

/// 轮盘控制器（纯逻辑 + [ChangeNotifier]）。
class WheelMenuController extends ChangeNotifier {
  WheelMenuController({
    required WheelMenuSpec spec,
    required WheelMenuTheme theme,
    required double density,
    int Function()? clock,
    WheelMenuGestureController? gesture,
  })  : _spec = spec,
        _theme = theme,
        density = density,
        _clock = clock ?? _systemClock,
        gesture = gesture ?? WheelMenuGestureController.fromDensity(density);

  static int _systemClock() => DateTime.now().millisecondsSinceEpoch;

  final WheelMenuSpec _spec;
  final double density;
  final int Function() _clock;
  final WheelMenuGestureController gesture;

  WheelMenuTheme _theme;
  WheelMenuEnvelope? _envelope;
  WheelMenuLayout? _layout;

  /// 共享几何 HitTest（与当前 [_layout] 同生共死；C1.1.2 §五/§六）。
  WheelHitTester? _hitTester;

  /// 几何修订号（每次绑定布局 +1；进时间线日志）。
  int _geometryRevision = 0;

  WheelAnimationFrame _frame = WheelAnimationFrame.hidden();
  WheelAnimationRun? _run;
  WheelAnimationRun? _pressRun;
  double? _liveSelection;
  bool _interactive = false;
  bool _suppressed = false;

  /// 本次按下的命中索引（PointerDown 实时 HitTest 的结果，**不依赖 hover**）。
  int? _downHitIndex;

  /// 交互时间线的事务号（每次 PointerDown +1；进日志）。
  int _inputSeq = 0;

  /// 是否已被 `dispose()`。用于让 `tick()` 在"控制器先销毁、Widget 后出树"的
  /// 那一帧里安全地变成 no-op（见 [tick] 的注释）。
  bool _disposed = false;
  String? _infoText;
  String? _infoKey;
  String? _feedback;

  final WheelMenuStateMachine state = WheelMenuStateMachine();

  /// **指针交互态**（C1.1.2 §三）：与 [state] 并列，绝不复用同一个索引。
  ///
  /// `hoveredIndex / keyboardFocusedIndex / gestureSelectedIndex / pressedIndex /
  /// activeInputKind / lastPointerLocal` 各自独立；视觉高亮只做纯派生。
  final WheelPointerState pointer = WheelPointerState();

  /// 条目被确认（点击或滑选松手）。B 阶段只登记 / 提示，不执行真实业务。
  void Function(MenuNode entry, int index)? onEntryConfirmed;

  /// 请求关闭整个菜单（空白处点击 / 桌宠处点击 / 根菜单 Esc）。
  VoidCallback? onRequestClose;

  /// 一次动画播完（父层据此同步窗口级状态与诊断）。
  void Function(WheelAnimationKind kind)? onAnimationFinished;

  /// 几何变化（开 / 关 / 换层 / 尺寸变化）—— 父层据此**重算 Region**。
  VoidCallback? onGeometryChanged;

  /// 中央桌宠区域拖动（转发给桌宠窗口）。
  void Function(double x, double y, WheelPetDragPhase phase)? onPetDrag;

  /// 过渡提示（B 阶段"该功能将在下一阶段接入"）。
  void Function(String message)? onFeedback;

  /// 选中项实时信息提供者（只读快照）。
  String? Function(MenuNode entry)? infoProvider;

  /// **调整层的当前值读取器**（增量 C1）：由外壳接持久化设置。
  ///
  /// 只有"当前值"这一行需要它；层级的 5 个条目与数值范围都在
  /// [WheelAdjustmentLayer] 里声明，视图不重复定义。
  double Function(WheelAdjustmentKind kind)? adjustValueReader;

  /// **动态层级提供者**：外壳可以覆盖调整层的构建（例如把主题列表换成实际可用列表）。
  /// 返回 null 时回退到 [WheelAdjustmentLayer.build]。
  MenuLevel? Function(String levelId)? dynamicLevelProvider;

  WheelMenuTheme get theme => _theme;

  WheelMenuEnvelope? get envelope => _envelope;

  WheelMenuLayout? get layout => _layout;

  WheelAnimationFrame get frame => _frame;

  bool get interactive => _interactive;

  bool get hasActiveAnimation => _run != null || _pressRun != null;

  String? get feedback => _feedback;

  WheelMenuPhase get phase => state.phase;

  String get phaseName => state.phase.name;

  String get levelIdName => state.levelId ?? 'none';

  MenuLevel? get level => state.currentLevel;

  /// 弧形文字 / 实时信息 / 扇叶的定位锚点（C1.1.3 §1 / §3）。
  ///
  /// **粘性**：鼠标进入有效扇形时跟随悬停项；鼠标离开有效扇形（无高亮）时
  /// **保持不变**，因此扇叶 / 标题 chip / 实时信息**不会回落到第一项**。
  /// 只有换层 / 关闭 / 失活才清空（清空后回落到 `state.selectedIndex`）。
  int get activeIndexNow {
    final int count = state.itemCount;
    if (count <= 0) return 0;
    final int? anchor = pointer.anchorIndex;
    if (anchor != null && anchor >= 0 && anchor < count) return anchor;
    return state.selectedIndex.clamp(0, count - 1);
  }

  /// **视觉高亮**的按钮索引：`-1` = 不高亮任何按钮（需求 C1）。
  ///
  /// 与 [activeIndexNow] **分离**：前者是"按钮被点亮"，后者是"弧形文字跟谁排布"。
  /// 鼠标不在任何按钮命中区时前者为 -1、后者仍指向已确认项，因此
  /// "不高亮"**不会**让标题 / chip 消失。
  int get highlightIndexNow => pointer.visualActiveIndexOrNone(state.itemCount);

  int? get highlightIndex => state.activeIndex;

  String get gestureOwnerName => gesture.ownerName;

  String get animationName => _run?.kind.name ?? 'idle';

  /// 主题即时预览（修改后立即生效，不重开菜单）。
  void applyTheme(WheelMenuTheme theme) {
    _theme = theme;
    notifyListeners();
  }

  void setInfoProvider(String? Function(MenuNode entry)? provider) {
    infoProvider = provider;
    _refreshInfo(force: true);
    notifyListeners();
  }

  /// 门控交互（关闭请求被接受的那一刻由父层置 false）。
  void setInteractive(bool value) {
    if (_interactive == value) return;
    _interactive = value;
    if (!value) {
      _clearPress();
      _run = null;
      _pressRun = null;
      state.setPreview(null);
      _liveSelection = null;
      gesture.reset();
      // C1.1.2 §十-14：关闭菜单后清空 hover / pressed / 最近指针位置。
      pointer.reset();
      _downHitIndex = null;
    }
    notifyListeners();
  }

  /// 打开序列**准备内容**（无动画、不可交互）：信封与几何一次确定，帧置为"完全收起"。
  bool prepareContent(WheelMenuEnvelope envelope, WheelMenuTheme theme) {
    final MenuLevel? level = MenuCatalog.level(MenuCatalog.rootId);
    if (level == null) return false;
    _envelope = envelope;
    _theme = theme;
    final WheelMenuLayout layout = WheelMenuGeometry.layoutFor(envelope, level, _spec);
    _layout = layout;
    // 动态层级解析器（调整层）：状态机与控制器读同一条路径。
    state.dynamicLevel = _resolveDynamicLevel;
    if (!state.open(envelope.direction)) return false;
    _bindLayout(layout);
    _liveSelection = null;
    _pressRun = null;
    _suppressed = false;
    _frame = WheelAnimationFrame.hidden(
      itemCount: layout.itemCount,
      mirrorProgress: _mirrorOf(envelope.direction),
    );
    // C1.1.2 §四：打开完成**不再**自动选中第一个按钮。
    // 键盘焦点可以落到第一项，但只有发生**键盘输入**后才允许成为视觉高亮。
    pointer.keyboardMode = false;
    pointer.keyboardFocusedIndex = _firstEnabledIndex(layout);
    pointer.hoveredIndex = null;
    pointer.pressedIndex = null;
    pointer.gestureSelectedIndex = null;
    pointer.anchorIndex = null;
    _refreshInfo(force: true);
    _feedback = null;
    onGeometryChanged?.call();
    notifyListeners();
    return true;
  }

  /// 布局达标后起一次展开动画（**恰好一次**）。
  void beginOpenAnimation() {
    final WheelMenuLayout? current = _layout;
    if (current == null) return;
    _startRun(
      WheelAnimationKind.open,
      from: 0,
      to: 0,
      count: current.itemCount,
    );
  }

  /// 布局超时**降级**：立即以"完全展开"帧呈现，不播展开动画。
  void presentOpened() {
    final WheelMenuLayout? current = _layout;
    if (current == null) return;
    _run = null;
    _pressRun = null;
    _frame = WheelAnimationFrame.hidden(
      itemCount: current.itemCount,
      mirrorProgress: _mirrorOf(state.direction),
    ).copyWith(
      openProgress: 1,
      selectionPosition: _frame.selectionPosition,
      buttonProgress: List<double>.filled(current.itemCount, 1),
    );
    state.markOpened();
    _bindLayout(current);
    notifyListeners();
  }

  void requestClose() {
    final WheelMenuLayout? current = _layout;
    if (current == null) return;
    state.beginClosing();
    _startRun(
      WheelAnimationKind.close,
      from: _frame.selectionPosition,
      to: _frame.selectionPosition,
      count: current.itemCount,
    );
  }

  /// 进入子菜单：层级**立即**切换，窗口不动，只做过渡动画。
  bool enterLayerByAction(String actionId) {
    final MenuLevel? target = _levelForAction(actionId);
    if (target == null) return false;
    final WheelMenuEnvelope? env = _envelope;
    if (env == null) return false;
    final WheelMenuLayout next = WheelMenuGeometry.layoutFor(env, target, _spec);
    // 调整层是**动态**层（不在 MenuCatalog 里）→ 走动态入层；
    // 静态层仍走原有的"按导航动作入层"。
    final bool entered = WheelAdjustmentKind.fromLevelId(target.id) != null
        ? state.enterDynamicLevel(target.id)
        : state.enterLayerByAction(actionId);
    if (!entered) return false;
    _applyLevelLayout(next);
    return true;
  }

  /// 动态层级解析（状态机与 `_levelForAction` 共用同一实现）。
  MenuLevel? _resolveDynamicLevel(String levelId) {
    final WheelAdjustmentKind? kind = WheelAdjustmentKind.fromLevelId(levelId);
    if (kind == null) return null;
    return dynamicLevelProvider?.call(levelId) ??
        WheelAdjustmentLayer.build(kind, _currentAdjustValue(kind));
  }

  /// **恢复到指定层级**（调整后自动重开用）。
  ///
  /// 层级路径必须是当前菜单树里的合法路径；非法时返回 false（调用方保持根层）。
  bool restoreLevel(String levelId, {int? index}) {
    final WheelMenuEnvelope? env = _envelope;
    if (env == null) return false;
    final MenuLevel? target = MenuCatalog.level(levelId) ??
        dynamicLevelProvider?.call(levelId) ??
        _levelForActionFor(levelId);
    if (target == null) return false;
    final WheelMenuLayout next = WheelMenuGeometry.layoutFor(env, target, _spec);
    if (!state.restoreToLevel(target.id)) return false;
    _applyLevelLayout(next);
    if (index != null && index >= 0 && index < next.itemCount) {
      state.setPreview(index);
      _frame = _frame.copyWith(selectionPosition: index.toDouble());
      _refreshInfo(force: true);
    }
    notifyListeners();
    return true;
  }

  /// 由层级 id 找到层级对象（含**动态**调整层）。
  MenuLevel? _levelForActionFor(String levelId) {
    final WheelAdjustmentKind? kind = WheelAdjustmentKind.fromLevelId(levelId);
    if (kind == null) return null;
    return dynamicLevelProvider?.call(levelId) ??
        WheelAdjustmentLayer.build(kind, _currentAdjustValue(kind));
  }

  /// 刷新动态层（调整后"当前值"那一行要跟着变）。
  void refreshAdjustmentLevel() {
    final MenuLevel? current = state.currentLevel;
    if (current == null) return;
    final WheelAdjustmentKind? kind = WheelAdjustmentKind.fromLevelId(current.id);
    if (kind == null) return;
    final WheelMenuEnvelope? env = _envelope;
    if (env == null) return;
    final MenuLevel refreshed = dynamicLevelProvider?.call(current.id) ??
        WheelAdjustmentLayer.build(kind, _currentAdjustValue(kind));
    _applyLevelLayout(WheelMenuGeometry.layoutFor(env, refreshed, _spec));
    notifyListeners();
  }

  /// 返回上一层。
  bool back() {
    final WheelMenuEnvelope? env = _envelope;
    if (env == null) return false;
    if (state.depth < 2) return false;
    final List<String> path = state.path();
    final MenuLevel? target =
        path.length >= 2 ? MenuCatalog.level(path[path.length - 2]) : null;
    if (target == null) return false;
    final WheelMenuLayout next = WheelMenuGeometry.layoutFor(env, target, _spec);
    if (!state.exitLayer()) return false;
    _applyLevelLayout(next);
    return true;
  }

  /// 根选项切换（沿弧线滑动）。
  void animateSelectionTo(int index) {
    final WheelMenuLayout? current = _layout;
    if (current == null) return;
    if (index < 0 || index >= current.itemCount) return;
    final double from = _liveSelection ?? _frame.selectionPosition;
    _liveSelection = null;
    state.setPreview(null);
    state.beginSwitch(index);
    _startRun(
      WheelAnimationKind.selectionSwitch,
      from: from,
      to: index.toDouble(),
      count: current.itemCount,
    );
    state.finishSwitch(index);
    _refreshInfo(force: true);
  }

  // ------------------------------------------------------------------
  // 输入（C1.1.3：**唯一入口** `resolvePointerHit`；按下 / 抬起各自实时 HitTest）
  // ------------------------------------------------------------------

  /// **统一 HitTest 入口**（需求 §4）：悬停 / 按下 / 抬起 / 圆弧滑动全走它。
  ///
  /// 几何来源是 `_hitTester`，它在 [_bindLayout] 时与**当前快照的布局**同时重建
  /// —— 即"快照里的最终角度 / 方向 / 位置"就是这里的判定依据，不存在第二套几何。
  WheelPointerHit? resolvePointerHit(Offset local, {int? previousIndex}) {
    final WheelHitTester? tester = _hitTester;
    if (tester == null) return null;
    return tester.resolve(
      local,
      previousIndex: previousIndex,
      selectedIndex: state.selectedIndex,
    );
  }

  /// 兼容别名（C1.1.2 的旧名）——判定完全一致。
  WheelPointerHit? hitTestAt(Offset local) => resolvePointerHit(local);

  /// 记录一次 HitTest（需求 §2 的 `wheel.hit.resolve` 时间线）。
  void _logHitResolve(String phase, WheelPointerHit hit) {
    pointer.lastHitIndex = hit.buttonIndex;
    pointer.lastHitZone = hit.kind.name;
    pointer.lastHitRadius = hit.radius;
    pointer.lastHitAngle = hit.angle;
    _log('wheel.hit.resolve', extra: <String, Object?>{
      'hitPhase': phase,
      'hitZone': hit.kind.name,
      'hitIndex': hit.buttonIndex,
      'slotIndex': hit.slotIndex,
    });
  }

  void pointerDown(Offset local, {int pointerCount = 1}) {
    final WheelMenuLayout? current = _layout;
    if (current == null || !_interactive) return;
    // §七 强制约束：打开动画期间收到的位置也必须保存，不能直接丢弃。
    pointer.lastPointerLocal = local;
    _inputSeq++;
    _setInputKind(PointerDeviceKind.mouse);
    _log('wheel.pointer.down', extra: <String, Object?>{'pointerCount': pointerCount});
    // 展开 / 收起动画期间拦下点击（防"还没张开就被点掉"）。
    if (state.phase.transitioning) return;
    final WheelPointerHit hit =
        resolvePointerHit(local) ?? WheelPointerHit.decoration;
    _logHitResolve('down', hit);
    _log('wheel.hit.down', extra: <String, Object?>{
      'hitIndex': hit.buttonIndex,
      'zone': hit.kind.name,
    });
    if (pointerCount > 1) {
      _handleOutcome(
        current,
        gesture.onDown(local.dx, local.dy, _clock(), pointerCount: pointerCount),
      );
      return;
    }
    if (hit.isNotch) {
      // 中央缺口 = 桌宠交互区（拖动由手势层转发；未拖动则关闭菜单）。
      _handleOutcome(
        current,
        gesture.onDown(local.dx, local.dy, _clock(), pointerCount: 1),
      );
      return;
    }
    if (hit.isButton) {
      final int pressedIndex = hit.buttonIndex!;
      _downHitIndex = pressedIndex;
      pointer.pressedIndex = pressedIndex;
      pointer.gestureSelectedIndex = null;
      _setHovered(pressedIndex, local: local);
      // 手势层同步置为"按在该按钮上"，使按住拖动可转滑选。
      gesture.onDown(local.dx, local.dy, _clock(), pointerCount: 1);
      _pressRun = WheelAnimationRun(
        kind: WheelAnimationKind.press,
        startedAtMs: _clock(),
        fromSelection: _frame.selectionPosition,
        toSelection: _frame.selectionPosition,
        itemCount: current.itemCount,
        pressIndex: pressedIndex,
        mirrorProgress: _mirrorOf(current.direction),
      );
      _logHighlightDerived('pointerDown');
      notifyListeners();
      return;
    }
    // 决策 A1 / §10：菜单背景与纯装饰（Region 内、非按钮、非缺口）
    // —— 不选择、不执行、也不关闭；Region 外继续穿透给下层应用。
    _downHitIndex = null;
    pointer.pressedIndex = null;
    gesture.reset(); // 背景按下不产生任何手势归属，避免上一次的归属残留
    notifyListeners();
  }

  void pointerMove(Offset local, {int pointerCount = 1}) {
    final WheelMenuLayout? current = _layout;
    if (current == null || !_interactive) return;
    pointer.lastPointerLocal = local;
    _setInputKind(PointerDeviceKind.mouse);
    if (state.phase.transitioning) return;
    if (pointerCount > 1) {
      _handleOutcome(
        current,
        gesture.onMove(local.dx, local.dy, _clock(), pointerCount: pointerCount),
      );
      return;
    }
    final WheelGestureOutcome outcome =
        gesture.onMove(local.dx, local.dy, _clock(), pointerCount: 1);
    if (gesture.ownerName == 'swiping') {
      // 已转滑选 → 本次"点击"作废（§六-2 / §十-7）。
      pointer.pressedIndex = null;
      _downHitIndex = null;
      _handleOutcome(current, outcome);
      // 需求 §4：**圆弧滑动也走统一入口**（高亮 = 该点所在的有效扇形角度槽位）。
      _applySwipeHighlight(local);
      return;
    }
    if (gesture.ownerName != 'none') {
      _handleOutcome(current, outcome);
      return;
    }
    if (outcome.effect != WheelGestureEffect.none) _handleOutcome(current, outcome);
    // 未拖动：按**当前坐标**实时重算 hover（§五 / §七）。
    _recomputeHover(local);
  }

  /// **滑选**中的高亮落地（需求 §4：圆弧滑动同样走统一 HitTest 入口）。
  ///
  /// 手势层（Android 1:1 移植）负责"是否还算滑选"（远离窄环带超过 130ms 即取消），
  /// 本方法只负责**高亮取谁** —— 与悬停 / 按下 / 抬起同一条判定。
  void _applySwipeHighlight(Offset local) {
    final WheelPointerHit hit =
        resolvePointerHit(local, previousIndex: pointer.gestureSelectedIndex) ??
            WheelPointerHit.decoration;
    _logHitResolve('swipe.move', hit);
    if (!hit.isButton) return;
    final int index = hit.buttonIndex!;
    if (pointer.gestureSelectedIndex == index) return;
    pointer.gestureSelectedIndex = index;
    pointer.anchorIndex = index;
    state.setPreview(index);
    _liveSelection = index.toDouble();
    _frame = _frame.copyWith(selectionPosition: index.toDouble());
    _refreshInfo(force: false);
    _logHighlightDerived('swipe.move');
    notifyListeners();
  }

  void pointerUp(Offset local, {int pointerCount = 1}) {
    final WheelMenuLayout? current = _layout;
    if (current == null || !_interactive) return;
    pointer.lastPointerLocal = local;
    if (state.phase.transitioning) return;
    // §9：抬起**独立实时 HitTest**（不依赖 down 的 hover / 子区域）。
    final WheelPointerHit released =
        resolvePointerHit(local, previousIndex: pointer.hoveredIndex) ??
            WheelPointerHit.decoration;
    _log('wheel.pointer.up', extra: <String, Object?>{'pointerCount': pointerCount});
    _logHitResolve('up', released);
    _log('wheel.hit.up', extra: <String, Object?>{
      'hitIndex': released.buttonIndex,
      'zone': released.kind.name,
    });

    final String owner = gesture.ownerName;
    // ① 手势已接管（滑选 / 桌宠拖动 / 多指）→ 交给原有收敛逻辑。
    if (owner == 'swiping' || owner == 'petDrag' || pointerCount > 1) {
      _handleOutcome(
        current,
        gesture.onUp(local.dx, local.dy, _clock(), pointerCount: pointerCount),
      );
      _afterPointerUp();
      return;
    }
    // ② 本次是"点击候选"：用**按下 / 抬起的实时 HitTest** 判定（§5 / §9）。
    //    down 在扇形角度槽位、up 在按钮圆形 —— 同一按钮也算命中（§9）。
    final int? pressed = _downHitIndex ?? pointer.pressedIndex;
    if (pressed != null && released.buttonIndex == pressed) {
      // 按下与抬起命中**同一按钮** → 执行（§六-1）。
      _handleOutcome(
        current,
        WheelGestureOutcome(WheelGestureEffect.confirm, index: pressed),
      );
      gesture.onCancel();
      pointer.hoveredIndex = pressed;
      pointer.anchorIndex = pressed;
      pointer.gestureSelectedIndex = null;
      _logHighlightDerived('pointerUp.confirm');
      _afterPointerUp();
      return;
    }
    if (pressed != null && released.buttonIndex != pressed) {
      // 按下按钮、抬起在按钮外 → 取消，**不执行、不关闭**（§六-2 / §9）。
      gesture.onCancel();
      _afterPointerUp();
      return;
    }
    // ③ 缺口 / 背景：缺口（未拖动）由 ① 关闭（§10：再次点击桌宠 = 关闭）；
    //    背景与装饰按 A1 / §10 什么都不做。
    if (released.isNotch) {
      _handleOutcome(
        current,
        gesture.onUp(local.dx, local.dy, _clock(), pointerCount: 1),
      );
    } else {
      gesture.onCancel();
    }
    _afterPointerUp();
  }

  void pointerCancel() {
    final WheelMenuLayout? current = _layout;
    if (current == null || !_interactive) return;
    _handleOutcome(current, gesture.onCancel());
    _afterPointerUp();
  }

  void _afterPointerUp() {
    pointer.pressedIndex = null;
    _downHitIndex = null;
    notifyListeners();
  }

  /// **悬停**（Windows 额外能力）：只更新预览高亮，**不确认、不改已确认项**。
  void hover(Offset local) {
    final WheelMenuLayout? current = _layout;
    if (current == null || !_interactive) return;
    // §七：打开动画期间也**保存**位置（不丢），动画完成后用它重算。
    pointer.lastPointerLocal = local;
    if (pointer.activeInputKind != PointerDeviceKind.touch) {
      _setInputKind(PointerDeviceKind.mouse);
    } else {
      pointer.keyboardMode = false;
    }
    if (state.phase.transitioning) return;
    if (gesture.ownerName != 'none') return; // 拖动中不抢指令
    _recomputeHover(local, logMove: true);
  }

  /// 指针离开菜单层：清掉悬停高亮（与 Android 的 cancel 语义区分：hover 只是预览）。
  void hoverExit() {
    if (!_interactive) return;
    if (gesture.ownerName != 'none') return;
    if (pointer.hoveredIndex == null && state.previewIndex == null) return;
    _setHovered(null);
  }

  /// 按**当前坐标**实时重算 hover（真实 HitTest，绝不默认第一项）。
  void _recomputeHover(Offset local, {bool logMove = false}) {
    final WheelPointerHit hit =
        resolvePointerHit(local, previousIndex: pointer.hoveredIndex) ??
            WheelPointerHit.decoration;
    final int? index = hit.isButton ? hit.buttonIndex : null;
    if (logMove) {
      _logHitResolve('move', hit);
      _log('wheel.pointer.move', extra: <String, Object?>{
        'pointerLocal': '${local.dx.toStringAsFixed(1)},${local.dy.toStringAsFixed(1)}',
        'hitIndex': index,
        'previousHoveredIndex': pointer.hoveredIndex,
      });
    }
    _setHovered(index, local: local);
  }

  /// 用**最近一次**指针位置按**当前几何**重算 hover（§七 的四个确定性时机）。
  ///
  /// 没有最近位置 / 不在任何按钮上 → **无高亮**（绝不默认第一项）。
  void recomputeHoverFromLastPointer() {
    if (!_interactive) return;
    if (gesture.ownerName != 'none') return;
    final Offset? local = pointer.lastPointerLocal;
    if (local == null) {
      _setHovered(null);
      return;
    }
    _recomputeHover(local);
  }

  /// 落地一次 hover（同时推进"粘性视觉锚点"）。
  ///
  /// * [index] 非空 → 更新锚点（扇叶 / 标题 chip / 实时信息跟着它）；
  /// * [index] 为空（离开有效扇形）→ hover 清空，但**锚点保持**（需求 §1 / §3），
  ///   因此不会跳回第一项。
  void _setHovered(int? index, {Offset? local}) {
    final int? previous = pointer.hoveredIndex;
    pointer.hoveredIndex = index;
    pointer.gestureSelectedIndex = null;
    if (index != null) pointer.anchorIndex = index;
    if (local != null) {
      pointer.lastHitIndex = index;
      pointer.lastPointerLocal = local;
    }
    final int anchor = activeIndexNow;
    if (state.previewIndex != index) {
      state.setPreview(index);
    }
    // 锚点变了 / 预览变了 → 同步扇叶与文字角度（**用锚点**，不用 selectedIndex）。
    if (_liveSelection != anchor.toDouble() || previous != index) {
      _liveSelection = anchor.toDouble();
      _frame = _frame.copyWith(selectionPosition: anchor.toDouble());
      _refreshInfo(force: false);
    }
    if (previous != index) {
      _log('wheel.hover.changed', extra: <String, Object?>{
        'hoveredIndex': index,
        'previousHoveredIndex': previous,
      });
      _logHighlightDerived('hover.changed');
    }
    notifyListeners();
  }

  /// 需求 §2：`wheel.highlight.derived` —— 每次派生值变化都留痕，
  /// 以便验收时证明"动画完成后 hoveredIndex 没有被写成 0"。
  void _logHighlightDerived(String source) {
    _log('wheel.highlight.derived', extra: <String, Object?>{
      'source': source,
      'previousHoveredIndex': pointer.hoveredIndex,
      'resolvedHoveredIndex': pointer.hoveredIndex,
      'visualActiveIndex': pointer.visualActiveIndexOrNone(state.itemCount),
      'derivedActiveIndex': activeIndexNow,
      'highlightSource': pointer.highlightSource,
    });
  }

  /// **Esc**（Windows 额外能力）：先取消预览 → 子菜单则返回 → 根菜单则关闭。
  void escape() {
    if (!_interactive) return;
    final WheelMenuLayout? current = _layout;
    if (current == null) return;
    if (state.previewIndex != null) {
      _handleOutcome(current, gesture.onCancel());
      return;
    }
    if (state.canGoBack) {
      back();
      return;
    }
    onRequestClose?.call();
  }

  // ------------------------------------------------------------------
  // 动画时钟
  // ------------------------------------------------------------------

  /// 推进到当前时刻；返回是否仍在动画中。
  bool tick() {
    // ⚠️ 控制器可能已经被父层 `dispose()`（关闭收尾），而本 Widget 要到**本帧
    // 的 build 阶段**才会被移出树、`Ticker` 才会被销毁 —— 但 `Ticker` 的 tick
    // 发生在 build **之前** 的 beginFrame。因此这里必须容忍"已销毁"，
    // 否则会抛 `A WheelMenuController was used after being disposed.`
    // （真机 debug 下会直接报错；真机回归 #1 的附带修复）。
    if (_disposed) return false;
    final int now = _clock();
    WheelAnimationFrame next = _frame;
    final WheelAnimationRun? active = _run;
    if (active != null) {
      // ⚠️ 真机回归 #1 的第二层根因：这里**必须**无条件用 `WheelAnimationClock.frame`
      // 计算这一帧 —— 它内部把进度 clamp 到 [0,1]，因此"已经过时长"时返回的是
      // 动画的**终态**（open → `openProgress = 1`）。
      //
      // 旧写法是「已结束 → 保留旧 `_frame`」，于是当第一个观测到的 tick 就已经
      // 超过时长（挂载前 beginOpenAnimation + 首帧间隔较长时必然发生）时，
      // `_frame` 会永远停在 `prepareContent` 留下的 `openProgress = 0`，
      // 画笔开头 `if (openProgress <= 0.004) return;` 直接整帧不画 ——
      // 用户看到的就是"左键点了什么都没有"。
      next = WheelAnimationClock.frame(active, now);
    }
    final WheelAnimationRun? press = _pressRun;
    if (press != null) {
      final WheelAnimationFrame pressFrame = WheelAnimationClock.frame(press, now);
      next = next.copyWith(
        pressIndex: press.pressIndex,
        pressProgress: pressFrame.pressProgress,
      );
      if (WheelAnimationClock.isFinished(press, now)) _pressRun = null;
    }
    final double? live = _liveSelection;
    if (live != null) next = next.copyWith(selectionPosition: live);
    _frame = next;

    if (active != null && WheelAnimationClock.isFinished(active, now)) {
      _run = null;
      _finishRun(active);
    }
    notifyListeners();
    return hasActiveAnimation;
  }

  /// 立即停下一切动画并把当前帧定格。
  void freeze() {
    final WheelAnimationRun? active = _run;
    if (active != null) _frame = WheelAnimationClock.frame(active, _clock());
    _run = null;
    _pressRun = null;
    gesture.reset();
    _liveSelection = null;
    state.settleAfterInterruption();
    notifyListeners();
  }

  // ------------------------------------------------------------------
  // 内部
  // ------------------------------------------------------------------

  void _applyLevelLayout(WheelMenuLayout next) {
    _layout = next;
    _bindLayout(next);
    _log('wheel.items.changed', extra: <String, Object?>{
      'level': state.levelId ?? 'none',
      'itemCount': next.itemCount,
    });
    _clearPress();
    _refreshInfo(force: true);
    onGeometryChanged?.call();
    _startRun(WheelAnimationKind.enterLayer, from: 0, to: 0, count: next.itemCount);
  }

  void _bindLayout(WheelMenuLayout layout) {
    gesture.layout = layout;
    gesture.selectedIndex = state.selectedIndex;
    _hitTester = WheelHitTester(
      layout,
      density: density,
      showButtonLabels: state.isRootLevel,
    );
    _geometryRevision++;
    // 换几何 → 旧的 hover / press 一律作废（坐标口径可能已变）；
    // 但**保留** `lastPointerLocal`，供换层/动画完成后按**新几何**重算（§七 / §八）。
    pointer.clearPointer();
    _downHitIndex = null;
  }

  /// 第一项可用条目（键盘默认焦点；**只有键盘输入后才进入视觉**）。
  int _firstEnabledIndex(WheelMenuLayout layout) {
    for (final slot in layout.slots) {
      if (!slot.entry.isBack) return slot.index;
    }
    return 0;
  }

  /// C1.1.2 §九 时间线日志（字段与需求逐条对齐）。
  void _log(String event, {Map<String, Object?> extra = const <String, Object?>{}}) {
    wheelGeometryJournal.record(
      event,
      fields: <String, Object?>{
        'transactionId': _inputSeq,
        'phase': state.phase.name,
        'menuLevel': state.levelId ?? 'none',
        'geometryRevision': _geometryRevision,
        ...pointer.describe(),
        ...extra,
      },
    );
  }

  /// 切换输入类型（鼠标 / 触摸 / 键盘）并记录一次模式变化日志（需求 §2 / §3）。
  void _setInputKind(PointerDeviceKind kind) {
    final bool wasKeyboard = pointer.keyboardMode;
    pointer.keyboardMode = false;
    if (wasKeyboard) {
      _log('wheel.pointer.mode', extra: <String, Object?>{
        'inputKind': kind.name,
        'keyboardMode': false,
      });
      _logHighlightDerived('input_mode.keyboard_released');
    }
    if (pointer.activeInputKind == kind) return;
    pointer.activeInputKind = kind;
    _log('wheel.pointer.mode', extra: <String, Object?>{'inputKind': kind.name});
    _log('wheel.input_mode.changed', extra: <String, Object?>{'inputKind': kind.name});
  }

  void _handleOutcome(WheelMenuLayout current, WheelGestureOutcome outcome) {
    switch (outcome.effect) {
      case WheelGestureEffect.none:
        return;
      case WheelGestureEffect.press:
        final int? index = outcome.index;
        if (index == null) return;
        pointer.pressedIndex = index;
        pointer.hoveredIndex = index;
        pointer.anchorIndex = index;
        pointer.gestureSelectedIndex = null;
        _pressRun = WheelAnimationRun(
          kind: WheelAnimationKind.press,
          startedAtMs: _clock(),
          fromSelection: _frame.selectionPosition,
          toSelection: _frame.selectionPosition,
          itemCount: current.itemCount,
          pressIndex: index,
          mirrorProgress: _mirrorOf(current.direction),
        );
        notifyListeners();
        return;
      case WheelGestureEffect.swipeStart:
      case WheelGestureEffect.highlight:
        final int? index = outcome.index;
        if (index == null) return;
        pointer.gestureSelectedIndex = index;
        pointer.pressedIndex = null;
        pointer.hoveredIndex = null;
        pointer.anchorIndex = index;
        state.setPreview(index);
        _liveSelection = index.toDouble();
        _frame = _frame.copyWith(
          selectionPosition: index.toDouble(),
          mirrorProgress: _mirrorOf(current.direction),
        );
        _refreshInfo(force: false);
        notifyListeners();
        return;
      case WheelGestureEffect.confirm:
        final int? index = outcome.index;
        if (index == null) return;
        pointer.pressedIndex = null;
        pointer.gestureSelectedIndex = null;
        pointer.hoveredIndex = index;
        pointer.anchorIndex = index;
        _log('wheel.action.confirmed', extra: <String, Object?>{'index': index});
        state.setPreview(index);
        final MenuNode? entry = state.confirmSelection();
        if (entry == null) return;
        _liveSelection = null;
        _clearPress();
        _refreshInfo(force: true);
        notifyListeners();
        onEntryConfirmed?.call(entry, index);
        return;
      case WheelGestureEffect.cancel:
        pointer.pressedIndex = null;
        pointer.gestureSelectedIndex = null;
        // **唯一**允许"锚点回落到已确认项"的路径：这是一次**显式取消**
        // （Esc 取消预览 / 按下后拖出按钮再抬起 / pointerCancel），
        // 与"鼠标离开有效扇形"（需求 §1：锚点必须粘住、不得跳回第一项）不同。
        pointer.anchorIndex = state.selectedIndex;
        state.setPreview(null);
        _liveSelection = null;
        _clearPress();
        _refreshInfo(force: true);
        _logHighlightDerived('cancel');
        if (state.phase == WheelMenuPhase.open) {
          _startRun(
            WheelAnimationKind.selectionSwitch,
            from: _frame.selectionPosition,
            to: state.selectedIndex.toDouble(),
            count: current.itemCount,
          );
        } else {
          notifyListeners();
        }
        return;
      case WheelGestureEffect.outsideTap:
        // 只有"中央缺口（桌宠）未拖动点击"会走到这里；Region 内背景由决策 A1
        // 在 pointerUp 里拦下，不会到达本分支。
        _log('wheel.close.requested', extra: <String, Object?>{'reason': 'notch_tap'});
        pointer.clearPointer();
        notifyListeners();
        onRequestClose?.call();
        return;
      case WheelGestureEffect.petDragStart:
        _suppressed = true;
        _run = null;
        _pressRun = null;
        pointer.clearPointer();
        notifyListeners();
        onPetDrag?.call(0, 0, WheelPetDragPhase.start);
        return;
      case WheelGestureEffect.petDragMove:
        onPetDrag?.call(0, 0, WheelPetDragPhase.move);
        return;
      case WheelGestureEffect.petDragEnd:
        onPetDrag?.call(0, 0, WheelPetDragPhase.end);
        return;
    }
  }

  void _startRun(
    WheelAnimationKind kind, {
    required double from,
    required double to,
    required int count,
  }) {
    final double mirror = _mirrorOf(state.direction);
    final WheelAnimationRun? previous = _run;
    if (previous != null) {
      // 新动画**接管**旧动画：先按旧动画当前帧收敛，避免位置误差累积。
      _frame = WheelAnimationClock.frame(previous, _clock()).copyWith(mirrorProgress: mirror);
    }
    _run = WheelAnimationRun(
      kind: kind,
      startedAtMs: _clock(),
      fromSelection: from,
      toSelection: to,
      itemCount: count,
      mirrorProgress: mirror,
    );
    notifyListeners();
  }

  void _finishRun(WheelAnimationRun active) {
    switch (active.kind) {
      case WheelAnimationKind.open:
        state.markOpened();
      case WheelAnimationKind.close:
        state.markClosed();
      case WheelAnimationKind.selectionSwitch:
        state.finishSwitch(active.toSelection.toInt());
      case WheelAnimationKind.enterLayer:
      case WheelAnimationKind.exitLayer:
        state.finishLayerTransition();
      case WheelAnimationKind.press:
        break;
    }
    _log('wheel.animation.completed', extra: <String, Object?>{'kind': active.kind.name});
    onAnimationFinished?.call(active.kind);
    // §七-3 / §七-4：打开动画结束、菜单层级切换完成 —— 明确的重算 hover 时机。
    // （**不**在 selectionSwitch 后重算：Esc 取消滑选后不得被"再高亮一次"抵消。）
    switch (active.kind) {
      case WheelAnimationKind.open:
      case WheelAnimationKind.enterLayer:
      case WheelAnimationKind.exitLayer:
        recomputeHoverFromLastPointer();
      case WheelAnimationKind.close:
      case WheelAnimationKind.selectionSwitch:
      case WheelAnimationKind.press:
        break;
    }
  }

  void _clearPress() {
    _pressRun = null;
    if (_frame.pressIndex >= 0) {
      _frame = _frame.copyWith(pressIndex: -1, pressProgress: 0);
    }
  }

  void _refreshInfo({required bool force}) {
    final String? Function(MenuNode entry)? provider = infoProvider;
    // C1.1.3：实时信息跟着**粘性锚点**走（= 扇叶 / 标题 chip 指向的那一项），
    // 因此"鼠标离开有效扇形"时信息不会跳回第一项的内容。
    final MenuLevel? level = state.currentLevel;
    final int anchor = activeIndexNow;
    final MenuNode? entry = (level != null && anchor >= 0 && anchor < level.nodes.length)
        ? level.nodes[anchor]
        : null;
    if (provider == null || entry == null) {
      _infoText = null;
      _infoKey = null;
      return;
    }
    final String key = '${entry.id}#$anchor';
    if (!force && key == _infoKey) return;
    _infoKey = key;
    _infoText = provider(entry);
  }

  String? get infoText => _infoText;

  bool get suppressed => _suppressed;

  MenuLevel? _levelForAction(String actionId) {
    // ① 轮盘内调整层（增量 C1）：由**动态层提供者**按当前值现场生成，
    //    这样"当前值"条目永远显示最新数字。
    final WheelAdjustmentKind? adjust = _adjustmentKindForAction(actionId);
    if (adjust != null) {
      return dynamicLevelProvider?.call(adjust.levelId) ??
          WheelAdjustmentLayer.build(adjust, _currentAdjustValue(adjust));
    }
    // ② 静态层级（MenuCatalog）。
    final String? levelId = _targetLevelOf(actionId);
    if (levelId == null) return null;
    return MenuCatalog.level(levelId);
  }

  /// 该动作是否是调整层入口（`settings_theme` / `settings_wheel_size` /
  /// `settings_button_size` / `settings_menu_distance`）。
  /// 该动作是否是调整层入口（**公开**：外壳 / 探针据此区分"进层"与"执行"）。
  static WheelAdjustmentKind? adjustmentKindForAction(String actionId) =>
      _adjustmentKindForAction(actionId);

  static WheelAdjustmentKind? _adjustmentKindForAction(String actionId) =>
      switch (actionId) {
        'settings_theme' => WheelAdjustmentKind.theme,
        'settings_wheel_size' => WheelAdjustmentKind.wheelScale,
        'settings_button_size' => WheelAdjustmentKind.buttonScale,
        'settings_menu_distance' => WheelAdjustmentKind.menuDistance,
        _ => null,
      };

  /// 调整层的当前值（由外壳注入的读取器提供）。
  double _currentAdjustValue(WheelAdjustmentKind kind) =>
      (adjustValueReader ?? _identityReader)(kind);

  static double _identityReader(WheelAdjustmentKind kind) => kind.defaultValue;

  static String? _targetLevelOf(String actionId) => switch (actionId) {
        'open_pet' => MenuCatalog.petLevelId,
        'open_appearance' => MenuCatalog.appearanceLevelId,
        'open_records' => MenuCatalog.recordsLevelId,
        'open_tools' => MenuCatalog.toolsLevelId,
        'open_settings' => MenuCatalog.settingsLevelId,
        _ => null,
      };

  static double _mirrorOf(Object direction) =>
      direction.toString().endsWith('right') ? 1 : 0;

  /// 当前 Region 矩形（由实际几何生成，不含整画布）。
  ///
  /// 返回**物理像素**（Region API 的口径）；[devicePixelRatio] 缺省 1。
  List<Rect> regionRects([double devicePixelRatio = 1]) {
    final WheelMenuLayout? current = _layout;
    if (current == null) return const <Rect>[];
    final List<Rect> logical = WheelRegionBuilder.rectsFor(
      current,
      slotProgress: _frame.buttonProgress,
      infoText: _infoText,
      feedback: _feedback,
      feedbackBarHeight: WheelMenuMetrics.feedbackBarHeightDp,
      feedbackMargin: WheelMenuMetrics.feedbackMarginDp,
    );
    if (devicePixelRatio == 1 || devicePixelRatio <= 0) return logical;
    return <Rect>[
      for (final Rect r in logical)
        Rect.fromLTRB(
          r.left * devicePixelRatio,
          r.top * devicePixelRatio,
          r.right * devicePixelRatio,
          r.bottom * devicePixelRatio,
        ),
    ];
  }

  void setFeedback(String? message) {
    _feedback = message;
    notifyListeners();
  }

  /// 释放控制器。
  ///
  /// 置 [_disposed] 之后，`Ticker` 在本帧 beginFrame 里对已销毁控制器的那一次
  /// `tick()` 会安全地变成 no-op（Widget 要到本帧 build 阶段才出树）。
  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// 轮盘视图（装配 + 输入 + 渲染）。
class WheelMenuView extends StatefulWidget {
  const WheelMenuView({
    super.key,
    required this.controller,
    this.debugBounds = false,
    this.verifyFan = false,
    this.regionVisualization = false,
    this.regionRects = const <Rect>[],
  });

  final WheelMenuController controller;
  final bool debugBounds;
  final bool verifyFan;
  final bool regionVisualization;
  final List<Rect> regionRects;

  @override
  State<WheelMenuView> createState() => _WheelMenuViewState();
}

class _WheelMenuViewState extends State<WheelMenuView>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_onTick);
  final FocusNode _focusNode = FocusNode(debugLabel: 'wheel-menu');
  final WheelMenuRenderer _renderer = WheelMenuRenderer();
  bool _ticking = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
    // ⚠️ 真机回归 #1（左键完全无反应）的根因就在这里。
    //
    // 生产的打开顺序是：`beginOpenAnimation()` → 外层 `setState` 才把本 Widget
    // 插进树里。于是本 Widget 挂载时控制器**已经**有一个活动动画，而
    // `_syncTicker()` 之前只由 `_onControllerChanged`（即 `notifyListeners`）
    // 触发 —— 挂载后不会再有通知，`Ticker` 永不启动。
    // 结果：`tick()` 从不被调用 → `_frame` 停在 `openProgress = 0`
    // → 画笔开头的 `if (openProgress <= 0.004) return;` 整帧不画
    // → 用户看到"点了没有任何反应"（但 Region 其实已经扩开了）。
    //
    // 因此挂载 / 换控制器时必须主动同步一次 ticker 状态。
    _syncTicker();
    // C1.1.2 §七-2：**第一帧可见**时按最近指针位置主动重算一次 hover。
    // Windows 上菜单可能直接在静止鼠标下方展开，此时不会产生新的 move 事件；
    // 若不重算，高亮就会"看起来没跟上鼠标"。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.controller.recomputeHoverFromLastPointer();
    });
  }

  @override
  void didUpdateWidget(covariant WheelMenuView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
      _syncTicker();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _ticker.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
    _syncTicker();
  }

  void _syncTicker() {
    final bool shouldTick = widget.controller.hasActiveAnimation;
    if (shouldTick && !_ticking) {
      _ticking = true;
      _ticker.start();
    } else if (!shouldTick && _ticking) {
      _ticking = false;
      _ticker.stop();
    }
  }

  void _onTick(Duration _) {
    final bool stillAnimating = widget.controller.tick();
    if (!stillAnimating && _ticking) {
      _ticking = false;
      _ticker.stop();
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape) {
      widget.controller.escape();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final WheelMenuController c = widget.controller;
    // 输入层级与绘制层级**分开**（真机回归 #1 的加固）：
    //   * closed / closing：轮盘这一层必须彻底退出命中测试 —— 不得抢桌宠的
    //     单击 / 双击 / 右键 / 拖动；
    //   * opening / open / switching / enteringLayer / exitingLayer：才允许接收输入
    //     （是否真的生效另有 `controller.interactive` 门控）。
    //
    // 注意 `IgnorePointer` **只**影响命中测试，不影响绘制，因此关闭动画期间
    // 仍然画得出来。
    final WheelMenuPhase phase = c.phase;
    final bool ignoring =
        phase == WheelMenuPhase.closed || phase == WheelMenuPhase.closing;
    return IgnorePointer(
      ignoring: ignoring,
      child: Focus(
        focusNode: _focusNode,
        autofocus: !ignoring,
        onKeyEvent: _onKey,
        child: MouseRegion(
          onHover: (PointerHoverEvent e) => c.hover(e.localPosition),
          onExit: (_) => c.hoverExit(),
          child: Listener(
            onPointerDown: (PointerDownEvent e) => c.pointerDown(e.localPosition),
            onPointerMove: (PointerMoveEvent e) => c.pointerMove(e.localPosition),
            onPointerUp: (PointerUpEvent e) => c.pointerUp(e.localPosition),
            onPointerCancel: (_) => c.pointerCancel(),
            child: CustomPaint(
              painter: _WheelPainter(
                controller: c,
                renderer: _renderer,
                debugBounds: widget.debugBounds,
                verifyFan: widget.verifyFan,
              ),
              foregroundPainter: widget.regionVisualization
                  ? _RegionBorderPainter(rects: widget.regionRects)
                  : null,
              // SizedBox.expand() 不参与命中测试；CustomPaint 自身是否会命中由
              // painter.hitTest 决定（`_WheelPainter` 继承默认实现）。
              // 关闭态由外层 IgnorePointer 兜住，因此这里无需再退化 behavior。
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ),
    );
  }
}

class _WheelPainter extends CustomPainter {
  _WheelPainter({
    required this.controller,
    required this.renderer,
    required this.debugBounds,
    required this.verifyFan,
  }) : super(repaint: controller);

  final WheelMenuController controller;
  final WheelMenuRenderer renderer;
  final bool debugBounds;
  final bool verifyFan;

  @override
  void paint(Canvas canvas, Size size) {
    final MenuLevel? level = controller.level;
    final layout = controller.layout;
    if (level == null || layout == null) return;
    if (controller.frame.openProgress <= 0.004) return;
    renderer.draw(
      canvas,
      WheelRenderParams(
        layout: layout,
        level: level,
        frame: controller.frame,
        activeIndex: controller.activeIndexNow,
        highlightIndex: controller.highlightIndexNow,
        theme: controller.theme,
        infoText: controller.infoText,
        debugBounds: debugBounds,
        density: controller.density,
        showButtonLabels: controller.state.isRootLevel,
        verifyFan: verifyFan,
      ),
    );
  }

  @override
  bool shouldRepaint(covariant _WheelPainter oldDelegate) => false;
}

/// 诊断：Region 边界（绿框）。
class _RegionBorderPainter extends CustomPainter {
  const _RegionBorderPainter({required this.rects});

  final List<Rect> rects;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint border = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = const Color(0xFF00E676);
    for (final Rect r in rects) {
      canvas.drawRect(r, border);
    }
  }

  @override
  bool shouldRepaint(covariant _RegionBorderPainter oldDelegate) =>
      oldDelegate.rects != rects;
}

/// 便于测试与诊断：轮盘尺寸常量（避免魔法数字散落）。
class WheelMenuMetrics {
  WheelMenuMetrics._();

  static const double minScale = WheelMenuLayoutSettings.minScale;
  static const double maxScale = WheelMenuLayoutSettings.maxScale;
  static const double scaleStep = WheelMenuLayoutSettings.step;
  static const double defaultScale = WheelMenuLayoutSettings.defaultScale;
  static const double minDistance = WheelMenuLayoutSettings.minDistance;
  static const double maxDistance = WheelMenuLayoutSettings.maxDistance;
  static const double defaultDistance = WheelMenuLayoutSettings.defaultDistance;
  static const double minButtonScale = WheelMenuLayoutSettings.minButtonScale;
  static const double maxButtonScale = WheelMenuLayoutSettings.maxButtonScale;
  static const double defaultButtonScale = WheelMenuLayoutSettings.defaultButtonScale;

  /// 反馈条高度（与 Android `MenuFeedback.BAR_HEIGHT_DP` 同口径）。
  static const double feedbackBarHeightDp = 26;

  /// 反馈条与边缘的间距（Android `MenuFeedback.MARGIN_DP`）。
  static const double feedbackMarginDp = 8;

  static double distanceOf(double ratio) => ratio;

  static double degreesToRadians(double deg) => deg * math.pi / 180;
}

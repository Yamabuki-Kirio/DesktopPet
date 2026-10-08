/// 轮盘的**界面状态机**（增量 B）与一致性不变量。
///
/// 为什么不另起一套：需求 §6 明确要求 `WheelUiState` 必须与既有的
/// `WheelInteractionState`（[WheelInteractionGate]）和 `RegionOwner` **保持一致**，
/// 不允许各自独立失控。因此本文件采取**派生**而非"第二套状态机"：
///
/// * 过渡态（opening / closing）**只**由 [WheelInteractionGate] 决定；
/// * 层级（root / submenu / transitioningLevel）**只**由 [MenuStack] + 过渡标志决定；
/// * [WheelUiController] 是唯一同时持有两者的对象，[uiState] 是它们的纯函数。
///
/// 这样"不一致"在构造上就不可能发生；[WheelUiInvariants] 再把不变量写成可断言的
/// 纯函数，供真机自检与单测使用。
///
/// 本文件是**纯 Dart**，可在 `flutter_tester` 直接单测。
library;

import 'menu_contract.dart' show MenuLevel, MenuStack;
import 'region_owner.dart' show RegionOwner;
import 'wheel_geometry_ownership.dart'
    show WheelGeometryJournal, wheelGeometryJournal;
import 'wheel_interaction_state.dart' show WheelInteractionGate, WheelInteractionState;
import 'windows_surface_mode.dart' show WindowsSurfaceMode;

/// 轮盘的界面状态（需求 §6）。
enum WheelUiState {
  closed('closed'),
  opening('opening'),
  root('root'),
  transitioningLevel('transitioning_level'),
  submenu('submenu'),
  closing('closing');

  const WheelUiState(this.wireName);

  final String wireName;

  /// 是否正在过渡（过渡期间输入必须被门控）。
  bool get isTransitioning =>
      this == WheelUiState.opening ||
      this == WheelUiState.closing ||
      this == WheelUiState.transitioningLevel;

  /// 是否"菜单在屏幕上可见"（含过渡）。
  bool get isOpenish =>
      this == WheelUiState.root ||
      this == WheelUiState.submenu ||
      this == WheelUiState.transitioningLevel;

  /// 期望的 Region 所有者（过渡态返回 null 表示"不作判定"）。
  RegionOwner? get expectedOwner => switch (this) {
        WheelUiState.closed => RegionOwner.pet,
        WheelUiState.root => RegionOwner.wheel,
        WheelUiState.submenu => RegionOwner.wheel,
        WheelUiState.transitioningLevel => RegionOwner.wheel,
        WheelUiState.opening => null,
        WheelUiState.closing => null,
      };
}

/// 轮盘界面控制器：**唯一**同时持有交互门与菜单栈的对象。
class WheelUiController {
  WheelUiController({
    WheelInteractionGate? gate,
    WheelGeometryJournal? journal,
    String tag = 'wheel',
  })  : gate = gate ?? WheelInteractionGate(tag: tag),
        _journal = journal ?? wheelGeometryJournal,
        _tag = tag;

  final WheelInteractionGate gate;
  final WheelGeometryJournal _journal;
  final String _tag;

  /// 菜单层级栈（复用已冻结的 [MenuStack]，**绝不另建菜单协议**）。
  final MenuStack stack = MenuStack();

  bool _levelTransitioning = false;
  int _levelTransitionSeq = 0;

  WheelInteractionState get interactionState => gate.state;

  String? get levelId => stack.currentId;

  MenuLevel? get level => stack.current;

  /// 是否处于层级切换过渡。
  bool get levelTransitioning => _levelTransitioning;

  int get levelTransitionSeq => _levelTransitionSeq;

  bool get isRootLevel => stack.depth <= 1;

  /// 派生的界面状态（与交互门 / 菜单栈保持一致，构造上不可能不一致）。
  WheelUiState get uiState {
    switch (gate.state) {
      case WheelInteractionState.closed:
        return WheelUiState.closed;
      case WheelInteractionState.opening:
        return WheelUiState.opening;
      case WheelInteractionState.closing:
        return WheelUiState.closing;
      case WheelInteractionState.open:
        if (_levelTransitioning) return WheelUiState.transitioningLevel;
        return isRootLevel ? WheelUiState.root : WheelUiState.submenu;
    }
  }

  /// `closed → opening`，并把层级复位到根菜单。**同步**执行。
  bool beginOpen() {
    if (!gate.beginOpen()) return false;
    stack.clear();
    stack.open(); // 加入 root
    _levelTransitioning = false;
    return true;
  }

  /// `opening → open`。
  bool completeOpen() => gate.completeOpen();

  /// `opening → closed`（失败）。
  bool failOpen() {
    final bool ok = gate.failOpen();
    stack.clear();
    _levelTransitioning = false;
    return ok;
  }

  /// `open → closing`。
  bool beginClose() => gate.beginClose();

  /// `closing → closed`。
  bool completeClose() {
    final bool ok = gate.completeClose();
    stack.clear();
    _levelTransitioning = false;
    return ok;
  }

  /// 无论处于什么状态都回到 closed（面板切换 / 销毁 / 安全回退）。
  bool forceClosed({String reason = 'force_closed'}) {
    final bool changed = gate.forceClosed(reason: reason);
    stack.clear();
    _levelTransitioning = false;
    return changed;
  }

  /// 由导航动作 id 进入子菜单（`open_*`）。
  ///
  /// 返回是否真的进入了新层级；进入时标记层级过渡（视图据此播放切换动画）。
  bool enterLevelByAction(String actionId) {
    if (!uiState.isOpenish) return false;
    if (!stack.pushByAction(actionId)) return false;
    _startLevelTransition('enter:${stack.currentId}');
    return true;
  }

  /// 返回上一层；在根菜单返回 false（**不关闭**，关闭是另一个动作）。
  bool back() {
    if (!uiState.isOpenish) return false;
    if (!stack.pop()) return false;
    _startLevelTransition('back:${stack.currentId}');
    return true;
  }

  /// 层级切换动画结束（视图回调）。
  void completeLevelTransition() {
    if (!_levelTransitioning) return;
    _levelTransitioning = false;
    _journal.record(
      '$_tag.level.transition.complete',
      fields: <String, Object?>{'level': stack.currentId ?? 'none'},
    );
  }

  void _startLevelTransition(String reason) {
    _levelTransitioning = true;
    _levelTransitionSeq++;
    _journal.record(
      '$_tag.level.transition.start',
      fields: <String, Object?>{
        'level': stack.currentId ?? 'none',
        'depth': stack.depth,
        'reason': reason,
        'seq': _levelTransitionSeq,
      },
    );
  }

  /// 记录一次被忽略的重入。
  void recordReentryIgnored({required String action}) =>
      gate.recordReentryIgnored(action: action);

  @override
  String toString() => 'WheelUiController(ui=${uiState.wireName} '
      'level=${stack.currentId ?? 'none'} gate=${gate.state.wireName})';
}

/// `WheelUiState` × `RegionOwner` × `WindowsSurfaceMode` 的**一致性不变量**。
class WheelUiInvariants {
  WheelUiInvariants._();

  /// 返回 null = 一致；否则返回可直接进日志的违规原因。
  static String? evaluate({
    required WheelUiState uiState,
    required RegionOwner owner,
    required bool desiredCleared,
    required WindowsSurfaceMode surfaceMode,
    required bool contextMenuOpen,
  }) {
    // 面板侧独占：轮盘必须关闭。
    if (surfaceMode.isPanelLike && uiState != WheelUiState.closed) {
      return 'panel_but_wheel=${uiState.wireName}';
    }
    switch (uiState) {
      case WheelUiState.closed:
        // 空闲：Region 必须是"仅桌宠"；右键菜单打开时允许 contextMenu 级 owner。
        if (contextMenuOpen) {
          if (owner.priority < RegionOwner.contextMenu.priority ||
              desiredCleared) {
            return 'wheel_closed_context_menu_but_region='
                'owner:${owner.wireName} cleared:$desiredCleared';
          }
          return null;
        }
        if (owner.isPanelLike) {
          // 面板事务期间允许"已清除"。
          return desiredCleared ? null : 'wheel_closed_but_panel_region';
        }
        if (owner != RegionOwner.pet || desiredCleared) {
          return 'wheel_closed_but_region=owner:${owner.wireName} '
              'cleared:$desiredCleared';
        }
        return null;
      case WheelUiState.opening:
      case WheelUiState.closing:
        // 过渡态：Region 正在被改写，不作判定（与既有 RegionUiConsistency 一致）。
        return null;
      case WheelUiState.root:
      case WheelUiState.submenu:
      case WheelUiState.transitioningLevel:
        if (owner != RegionOwner.wheel || desiredCleared) {
          return 'wheel_${uiState.wireName}_but_region='
              'owner:${owner.wireName} cleared:$desiredCleared';
        }
        return null;
    }
  }
}

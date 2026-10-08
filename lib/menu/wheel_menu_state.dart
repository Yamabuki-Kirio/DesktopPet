/// 轮盘状态机（**Android `WheelMenuState.kt` 的 1:1 移植**）。
///
/// 三件必须由它独占的事：
/// 1. **菜单栈** —— 复用已冻结的 [MenuStack]（与 Android `WheelMenuStack` 同语义），
///    绝不另建菜单协议；
/// 2. **当前层级与选中项** —— 界面与渲染都只读它，不再各自维护一份索引；
/// 3. **展开方向** —— 打开时决定一次，**打开期间锁定**。
///
/// 非法请求（重复打开、根菜单返回、不存在的层级）一律**幂等拒绝**，绝不产生非法路径。
///
/// 本文件是**纯 Dart**，可在 `flutter_tester` 直接单测。
library;

import 'menu_contract.dart' show MenuCatalog, MenuLevel, MenuNode, MenuStack;
import 'wheel_menu_geometry.dart' show WheelExpandDirection;

/// 轮盘的交互阶段（**唯一权威**，不用多个松散布尔量表达"正在开/在切换/在返回"）。
enum WheelMenuPhase {
  closed,
  opening,
  open,

  /// 根选项切换（沿弧线滑动）。
  switching,

  /// 进入子菜单。
  enteringLayer,

  /// 返回上一层。
  exitingLayer,

  closing;

  /// 是否占据窗口（= 不是 closed）。
  bool get occupiesWindow => this != WheelMenuPhase.closed;

  /// 是否正处于"动画进行中"。
  bool get animating =>
      this == WheelMenuPhase.opening ||
      this == WheelMenuPhase.switching ||
      this == WheelMenuPhase.enteringLayer ||
      this == WheelMenuPhase.exitingLayer ||
      this == WheelMenuPhase.closing;

  /// 过渡态：输入必须被拦下（防"还没张开就被点掉"）。
  bool get transitioning =>
      this == WheelMenuPhase.opening || this == WheelMenuPhase.closing;
}

/// 轮盘状态机（纯逻辑）。
class WheelMenuStateMachine {
  final MenuStack stack = MenuStack();

  WheelMenuPhase _phase = WheelMenuPhase.closed;

  WheelExpandDirection _direction = WheelExpandDirection.right;

  int _selectedIndex = 0;

  int? _previewIndex;

  WheelMenuPhase get phase => _phase;

  WheelExpandDirection get direction => _direction;

  /// 已确认的选中项（根菜单 = 0..5）。
  int get selectedIndex => _selectedIndex;

  /// 滑选中的临时高亮（null = 没有临时项，用 [selectedIndex]）。
  int? get previewIndex => _previewIndex;

  String? get levelId => stack.currentId;

  /// **动态层级解析器**（轮盘内调整层等不在 `MenuCatalog.levels` 里的层）。
  ///
  /// 与静态层级同一条读取路径，避免"动态层拿不到内容 → 画空"。
  MenuLevel? Function(String levelId)? dynamicLevel;

  /// 进入一个动态层级（调整层）。
  bool enterDynamicLevel(String levelId) {
    if (_phase != WheelMenuPhase.open && _phase != WheelMenuPhase.switching) {
      return false;
    }
    if (!stack.pushDynamic(levelId)) return false;
    _selectedIndex = 0;
    _previewIndex = null;
    _phase = WheelMenuPhase.enteringLayer;
    return true;
  }

  /// **恢复到指定层级**（调整后自动重开；动态 / 静态都可）。
  ///
  /// 与 [enterDynamicLevel] 的差别（**关键**）：
  /// * 入层是**用户输入**，只能在 `open` / `switching` 被接受 —— 展开动画期间
  ///   必须拦下输入，否则会出现"动画还没铺开就已经进了两层"。
  /// * 恢复层级是**打开序列内部的装配步骤**（画布重建后自动重开），此时相位本来
  ///   就是 `opening`。因此这里**额外允许** `opening`，并且**不改相位** ——
  ///   让 `opening → open` 由展开动画自己收尾。若在这里把相位改成
  ///   `enteringLayer`，动画结束回调会把层级重新压回根层（"重建后掉回根菜单"）。
  bool restoreToLevel(String levelId) {
    final bool duringOpening = _phase == WheelMenuPhase.opening;
    if (!duringOpening &&
        _phase != WheelMenuPhase.open &&
        _phase != WheelMenuPhase.switching) {
      return false;
    }
    if (!stack.restoreTo(levelId)) return false;
    _selectedIndex = 0;
    _previewIndex = null;
    if (!duringOpening) _phase = WheelMenuPhase.enteringLayer;
    return true;
  }

  MenuLevel? get currentLevel {
    final String? id = stack.currentId;
    if (id == null) return null;
    return dynamicLevel?.call(id) ?? stack.current;
  }

  int get itemCount => currentLevel?.itemCount ?? 0;

  bool get isOpen => _phase.occupiesWindow;

  /// 当前高亮项 = 滑选中的临时项优先。
  int get activeIndex =>
      (_previewIndex ?? _selectedIndex).clamp(0, _max(0, itemCount - 1));

  /// 是否能返回（根菜单不能）。
  bool get canGoBack => stack.depth > 1;

  int get depth => stack.depth;

  List<String> path() => stack.path();

  MenuNode? get activeEntry => _nodeAt(activeIndex);

  MenuNode? get selectedEntry => _nodeAt(_selectedIndex);

  MenuNode? _nodeAt(int index) {
    final MenuLevel? level = currentLevel;
    if (level == null) return null;
    if (index < 0 || index >= level.nodes.length) return null;
    return level.nodes[index];
  }

  /// 打开菜单：只在 `closed` / `closing` 生效（幂等）。方向在此**锁定**。
  bool open(WheelExpandDirection direction) {
    if (_phase != WheelMenuPhase.closed && _phase != WheelMenuPhase.closing) {
      return false;
    }
    _direction = direction;
    stack.clear();
    stack.open();
    _selectedIndex = 0;
    _previewIndex = null;
    _phase = WheelMenuPhase.opening;
    return true;
  }

  /// 关闭：任何阶段都收敛到 `closed`（幂等）。
  bool close() {
    if (_phase == WheelMenuPhase.closed) return false;
    stack.clear();
    _previewIndex = null;
    _selectedIndex = 0;
    _phase = WheelMenuPhase.closed;
    return true;
  }

  /// 展开动画结束 → `open`。
  void markOpened() {
    if (_phase == WheelMenuPhase.opening) _phase = WheelMenuPhase.open;
  }

  /// 收起动画结束（幂等）。
  void markClosed() {
    _phase = WheelMenuPhase.closed;
  }

  /// 根选项切换开始；目标索引非法或本来就选中则拒绝。
  bool beginSwitch(int index) {
    if (_phase != WheelMenuPhase.open) return false;
    if (index < 0 || index >= itemCount) return false;
    if (index == _selectedIndex) return false;
    _phase = WheelMenuPhase.switching;
    return true;
  }

  /// 根选项切换结束：落到确定状态。
  void finishSwitch(int index) {
    if (index >= 0 && index < itemCount) _selectedIndex = index;
    if (_phase == WheelMenuPhase.switching) _phase = WheelMenuPhase.open;
  }

  /// 进入子菜单（层级立即切换，动画只负责过渡）。
  bool enterLayer(String targetLevelId) {
    if (_phase != WheelMenuPhase.open && _phase != WheelMenuPhase.switching) {
      return false;
    }
    if (!stack.push(targetLevelId)) return false;
    _selectedIndex = 0;
    _previewIndex = null;
    _phase = WheelMenuPhase.enteringLayer;
    return true;
  }

  /// 按导航动作 id 进入子菜单（`open_*`）。
  bool enterLayerByAction(String actionId) {
    if (_phase != WheelMenuPhase.open && _phase != WheelMenuPhase.switching) {
      return false;
    }
    if (!stack.pushByAction(actionId)) return false;
    _selectedIndex = 0;
    _previewIndex = null;
    _phase = WheelMenuPhase.enteringLayer;
    return true;
  }

  /// 返回上一层；在根菜单返回 `false`（**不关闭菜单**）。
  bool exitLayer() {
    if (_phase != WheelMenuPhase.open && _phase != WheelMenuPhase.switching) {
      return false;
    }
    if (!stack.pop()) return false;
    _selectedIndex = 0;
    _previewIndex = null;
    _phase = WheelMenuPhase.exitingLayer;
    return true;
  }

  /// 换层动画结束（进入 / 返回共用）。
  void finishLayerTransition() {
    if (_phase == WheelMenuPhase.enteringLayer || _phase == WheelMenuPhase.exitingLayer) {
      _phase = WheelMenuPhase.open;
    }
  }

  /// 收起动画开始。
  void beginClosing() {
    if (_phase != WheelMenuPhase.closed) _phase = WheelMenuPhase.closing;
  }

  /// 滑选：设置临时高亮（越界一律夹到合法范围；`null` = 取消区）。
  void setPreview(int? index) {
    _previewIndex = index?.clamp(0, _max(0, itemCount - 1));
  }

  /// 松手确认：把临时高亮变成已确认项，返回**被选中的条目**。
  MenuNode? confirmSelection() {
    final int? index = _previewIndex;
    if (index != null && index >= 0 && index < itemCount) {
      _selectedIndex = index;
    }
    _previewIndex = null;
    return selectedEntry;
  }

  /// 动画被外力打断：收敛到确定状态（绝不卡在中间态）。
  void settleAfterInterruption() {
    switch (_phase) {
      case WheelMenuPhase.opening:
        _phase = WheelMenuPhase.open;
      case WheelMenuPhase.switching:
      case WheelMenuPhase.enteringLayer:
      case WheelMenuPhase.exitingLayer:
        _phase = WheelMenuPhase.open;
      case WheelMenuPhase.closing:
        _phase = WheelMenuPhase.closed;
      case WheelMenuPhase.closed:
      case WheelMenuPhase.open:
        break;
    }
    _previewIndex = null;
  }

  /// 供几何层判根菜单。
  bool get isRootLevel => stack.currentId == MenuCatalog.rootId;

  static int _max(int a, int b) => a > b ? a : b;

  @override
  String toString() => 'WheelMenuStateMachine(phase=${_phase.name} '
      'level=${stack.currentId ?? 'none'} dir=${_direction.name} '
      'selected=$_selectedIndex preview=$_previewIndex)';
}

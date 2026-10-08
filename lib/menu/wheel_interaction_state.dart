/// 左键轮盘入口的**四态状态机**（本轮：并发重入修复）。
///
/// 背景（真机缺陷）
/// ----------------
/// 旧实现用 `bool _menuOpen` 记"是否打开"，而 `open()` 在**第一次 `await` 之后**
/// 才把 `_menuOpen` 置为 true。于是两次快速左键都能通过 `if (_menuOpen) return`，
/// 并发提交两次 `pet+menu` Region —— 真机上表现为"要再点一次才正常"。
///
/// 修复
/// ----
/// * 只有 `closed` 可以 `beginOpen()`，且**在首个 await 之前同步**进入 `opening`；
/// * `opening` / `closing` 期间的重复点击一律**忽略**（不允许作为布局修复手段）；
/// * `open` 期间点击菜单内部按钮**不得**再次触发 `open()`；
/// * 任何失败路径都回到 `closed`（由调用方通过 `RegionCoordinator` 恢复正确 owner）。
///
/// 本文件是**纯 Dart**，可在 `flutter_tester` / `dart test` 直接单测。
library;

import 'region_owner.dart';
import 'wheel_geometry_ownership.dart'
    show WheelGeometryJournal, wheelGeometryJournal;

/// 左键轮盘的交互状态。
enum WheelInteractionState {
  /// 未打开（唯一允许开始打开的状态）。
  closed('closed'),

  /// 正在打开（已经进入同步段，未完成前不允许重入）。
  opening('opening'),

  /// 已打开（Region 已由 wheel 提交）。
  open('open'),

  /// 正在关闭（拒绝一切新的打开请求）。
  closing('closing');

  const WheelInteractionState(this.wireName);

  final String wireName;

  /// 是否处于"过渡中"（重入必须被拒绝）。
  bool get isTransitioning =>
      this == WheelInteractionState.opening || this == WheelInteractionState.closing;
}

/// 左键轮盘入口状态机（无 widget 依赖，可纯逻辑单测）。
class WheelInteractionGate {
  WheelInteractionGate({
    WheelGeometryJournal? journal,
    String tag = 'wheel',
  })  : _journal = journal ?? wheelGeometryJournal,
        _tag = tag;

  final WheelGeometryJournal _journal;
  final String _tag;

  WheelInteractionState _state = WheelInteractionState.closed;
  int _transitionSeq = 0;

  WheelInteractionState get state => _state;

  /// 状态迁移序号（每次成功迁移 +1；用于诊断"是否发生了非预期重入"）。
  int get transitionSeq => _transitionSeq;

  bool get isOpen => _state == WheelInteractionState.open;

  bool get isTransitioning => _state.isTransitioning;

  bool get isBusy => _state != WheelInteractionState.closed;

  /// `closed → opening`。**同步**返回，调用方必须在首个 await 之前调用它。
  ///
  /// 返回 false 表示当前状态不允许打开（重入被忽略）。
  bool beginOpen() => _move(
        from: WheelInteractionState.closed,
        to: WheelInteractionState.opening,
        reason: 'begin_open',
      );

  /// `opening → open`。
  bool completeOpen() => _move(
        from: WheelInteractionState.opening,
        to: WheelInteractionState.open,
        reason: 'complete_open',
      );

  /// `opening → closed`（打开失败 / 被拒绝）。
  bool failOpen() => _move(
        from: WheelInteractionState.opening,
        to: WheelInteractionState.closed,
        reason: 'fail_open',
      );

  /// `open → closing`。
  bool beginClose() => _move(
        from: WheelInteractionState.open,
        to: WheelInteractionState.closing,
        reason: 'begin_close',
      );

  /// `closing → closed`。
  bool completeClose() => _move(
        from: WheelInteractionState.closing,
        to: WheelInteractionState.closed,
        reason: 'complete_close',
      );

  /// 无论当前处于什么状态，强制回到 `closed`（用于外壳销毁 / 面板切换 / 回退）。
  bool forceClosed({String reason = 'force_closed'}) {
    if (_state == WheelInteractionState.closed) return false;
    _transition(WheelInteractionState.closed, reason: reason);
    return true;
  }

  /// 记录一次"被忽略的重入"（只写日志，不改状态）。
  void recordReentryIgnored({required String action}) {
    _journal.record(
      '$_tag.reentry_ignored',
      fields: <String, Object?>{'action': action, 'state': _state.wireName},
    );
  }

  bool _move({
    required WheelInteractionState from,
    required WheelInteractionState to,
    required String reason,
  }) {
    if (_state != from) return false;
    _transition(to, reason: reason);
    return true;
  }

  void _transition(WheelInteractionState next, {required String reason}) {
    final WheelInteractionState previous = _state;
    _state = next;
    _transitionSeq++;
    _journal.record(
      '$_tag.state',
      fields: <String, Object?>{
        'from': previous.wireName,
        'state': next.wireName,
        'reason': reason,
        'seq': _transitionSeq,
      },
    );
  }

  @override
  String toString() => 'WheelInteractionGate(${_state.wireName} seq=$_transitionSeq)';
}

/// **可见 UI / RegionOwner / WheelInteractionState 三者一致性**判定（纯逻辑）。
///
/// 验收要求"可见 UI、RegionOwner、WheelInteractionState 三者一致"；把它抽成纯函数，
/// 既能在单测里穷举，也能在真机诊断里直接对账。
class RegionUiConsistency {
  RegionUiConsistency._();

  /// 返回 null 表示一致；否则返回不一致原因（可直接进日志）。
  static String? evaluate({
    required RegionOwner owner,
    required bool desiredCleared,
    required WheelInteractionState wheelState,
    required bool contextMenuOpen,
  }) {
    // 轮盘已稳定打开：Region 必须归 wheel，且不能是"已清除"。
    if (wheelState == WheelInteractionState.open) {
      if (owner != RegionOwner.wheel || desiredCleared) {
        return 'wheel_open_but_region=owner:${owner.wireName}'
            ' cleared:$desiredCleared';
      }
      return null;
    }
    // 过渡态（opening / closing）：Region 正在被改写，不做判定。
    if (wheelState.isTransitioning) return null;
    // 面板侧独占：只允许"已清除"。
    if (owner.isPanelLike) {
      if (!desiredCleared) {
        return 'panel_owner_but_region_present=${owner.wireName}';
      }
      if (contextMenuOpen) return 'panel_owner_but_context_menu_open';
      return null;
    }
    // 右键菜单开着：Region 至少要是 contextMenu 级别（整块画布）。
    if (contextMenuOpen) {
      if (owner.priority < RegionOwner.contextMenu.priority || desiredCleared) {
        return 'context_menu_open_but_region=owner:${owner.wireName}'
            ' cleared:$desiredCleared';
      }
      return null;
    }
    // 空闲：必须回到"仅桌宠"。
    if (owner != RegionOwner.pet || desiredCleared) {
      return 'idle_but_region=owner:${owner.wireName} cleared:$desiredCleared';
    }
    return null;
  }
}

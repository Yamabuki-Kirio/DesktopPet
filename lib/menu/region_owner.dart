/// 窗口 Region（`SetWindowRgn`）的**唯一所有者**与优先级（本轮：Region 所有权统一）。
///
/// 背景（真机缺陷）
/// ----------------
/// 右键菜单的 `try/finally` 与左键轮盘**各自**直接写同一个 HWND 的 Region，
/// 没有任何仲裁者：右键事务关闭时的 `restorePetOnlyRegion` 可能在轮盘已经打开之后
/// 才执行，把 `pet+menu` 覆盖成 `pet-only`，表现为"轮盘打开了但没有 / 只剩一小块 /
/// 再点一次才恢复"。
///
/// 修复思路
/// --------
/// 1. 任一时刻只有一个 [RegionOwner] 拥有窗口 Region；
/// 2. 所有者或**目标 Region**任一变化都递增 generation；
/// 3. 优先级决定谁可以抢占谁：
///    `panelTransition / panel > wheel > contextMenu > pet`；
/// 4. 所有写入必须经 `RegionCoordinator`，并携带
///    `transactionId + generation + expectedOwner` 三元组。
///
/// 本文件是**纯 Dart**，不 import 任何桌面库，可在 `flutter_tester` 直接单测。
library;

/// 窗口 Region 的所有者。
///
/// * [pet]：只保留桌宠矩形（透明画布不参与命中）；
/// * [contextMenu]：右键 Overlay 需要**整块画布**可命中可渲染；
/// * [wheel]：左键轮盘已打开，Region = 桌宠 + 菜单；
/// * [panelTransition]：正在切到控制面板 / 返回桌宠，**不得**有 Region（应为 none）；
/// * [panel]：控制面板稳定态，普通矩形窗口，**不得**有 Region。
enum RegionOwner {
  /// 仅桌宠矩形。
  pet(0, 'pet'),

  /// 右键菜单（整块画布）。
  contextMenu(1, 'context_menu'),

  /// 左键轮盘（桌宠 + 菜单）。
  wheel(2, 'wheel'),

  /// 面板过渡：独占 Region（只允许 clear）。
  panelTransition(3, 'panel_transition'),

  /// 面板稳定态：独占 Region（普通矩形窗口）。
  panel(3, 'panel');

  const RegionOwner(this.priority, this.wireName);

  /// 优先级：数值大者可以抢占数值小者。
  final int priority;

  /// 线上 / 日志取值（snake_case）。
  final String wireName;

  /// 是否要求"没有 Region"（clear）。
  ///
  /// 面板侧的两个形态都必须是普通矩形窗口，Region 必须被清除。
  bool get requiresClearedRegion =>
      this == RegionOwner.panelTransition || this == RegionOwner.panel;

  /// 是否属于面板侧（与 `WindowsSurfaceMode.isPanelLike` 同口径）。
  bool get isPanelLike => requiresClearedRegion;

  /// [a] 是否可以直接抢占 [b]（同 owner 永远允许，用于更新目标 Region）。
  static bool canTakeOver(RegionOwner a, RegionOwner b) =>
      a.priority >= b.priority;

  /// 由线上取值反解；未知返回 null。
  static RegionOwner? fromWireName(String name) {
    for (final RegionOwner owner in RegionOwner.values) {
      if (owner.wireName == name) return owner;
    }
    return null;
  }
}

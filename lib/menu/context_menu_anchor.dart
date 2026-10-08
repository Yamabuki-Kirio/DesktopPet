/// 右键菜单的**锚点解析**与 **Region 事务**（修复：菜单错位到画布右下角）。
///
/// 背景（真机回归）
/// ----------------
/// 启用固定画布后，Overlay 尺寸 = 整块画布（例如 1352×560），而旧代码用
/// `RelativeRect.fromLTRB(overlaySize.width, overlaySize.height, 0, 0)` 把菜单
/// 钉在**画布右下角**。桌宠位于画布中央，于是菜单弹到离桌宠很远的地方。
///
/// 修复：以**指针的全局坐标**为锚点（由 `onSecondaryTapDown` 捕获），换算到
/// Overlay 局部坐标；指针不可用时退化为"桌宠矩形的右下角"，**绝不**再用画布右下角。
///
/// 本文件是纯逻辑（只依赖 `dart:async` / `flutter/widgets` 的类型），可单测。
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

import 'region_coordinator.dart' show RegionLease;

/// 右键菜单锚点解析。
class ContextMenuAnchor {
  ContextMenuAnchor._();

  /// 解析 `showMenu` 需要的 [RelativeRect]。
  ///
  /// * [overlayLocalPosition]：指针在 Overlay 局部坐标系的坐标（首选）；
  /// * [petOverlayRect]：桌宠在 Overlay 局部坐标系的矩形（指针缺失时的回退）；
  /// * [overlaySize]：Overlay 尺寸（定义"可用空间"，决定菜单是否翻转 / 夹取）。
  ///
  /// 锚点被**夹取**到 Overlay 内，保证 1×1 锚点不会落到窗口外；
  /// 菜单自身的方向翻转由 `showMenu` 依据锚点与 [overlaySize] 自动完成。
  static RelativeRect resolve({
    required Offset? overlayLocalPosition,
    required Size overlaySize,
    Rect? petOverlayRect,
  }) {
    final Rect anchor;
    if (overlayLocalPosition != null) {
      anchor = Rect.fromLTWH(overlayLocalPosition.dx, overlayLocalPosition.dy, 1, 1);
    } else if (petOverlayRect != null) {
      anchor = Rect.fromLTWH(petOverlayRect.right, petOverlayRect.bottom, 1, 1);
    } else {
      // 最后兜底：仍取 Overlay 右下角，但这是"没有桌宠矩形"时才可能发生。
      anchor = Rect.fromLTWH(overlaySize.width, overlaySize.height, 1, 1);
    }
    final double dx = _clampAxis(anchor.left, overlaySize.width);
    final double dy = _clampAxis(anchor.top, overlaySize.height);
    return RelativeRect.fromRect(
      Rect.fromLTWH(dx, dy, 1, 1),
      Offset.zero & overlaySize,
    );
  }

  static double _clampAxis(double value, double extent) {
    final double max = extent > 1 ? extent - 1 : 0;
    if (value < 0) return 0;
    if (value > max) return max;
    return value;
  }
}

/// 右键菜单的 **Region 事务端口**（由外壳注入；null = 不做 Region 事务）。
///
/// 它是 `ui/pet/pet_view_wrapper.dart` 与 `RegionCoordinator` 之间的唯一桥：
/// * [expandTo] 打开前把 Region 切成 `pet ∪ 实际菜单矩形`（owner=contextMenu），
///   返回凭据；
/// * [restore] 关闭后**按凭据**恢复 pet-only —— 凭据失效就什么都不做。
///
/// ⚠️ 真机回归 #2 的口径修正：**不再**把 Region 放大到"整块固定画布"。
/// 菜单矩形由调用方按 `ContextMenuLayout` 规划后原样传入，Region 因此精确贴合
/// 弹出的菜单（外加桌宠本身），不再让整块透明画布变成可命中区域。
abstract interface class ContextMenuRegionPort {
  /// 本次右键能否弹出菜单。
  ///
  /// false = 已有更高优先级的 owner（左键轮盘）正在占用 Region；此时弹出的菜单
  /// 会被 Region 裁掉、并与轮盘争夺命中区，因此**直接不弹**。
  bool get canOpenContextMenu;

  /// 菜单打开**之前**调用，[menuLocalRect] 是菜单在**固定画布局部坐标**里的矩形
  /// （固定画布模式下 overlay 局部坐标 == 画布局部坐标）。
  /// 返回本次事务凭据；未做任何写入时为 `RegionLease.none()`。
  Future<RegionLease> expandTo(Rect menuLocalRect);

  /// 菜单关闭**之后**调用。返回是否真的恢复了 pet-only。
  Future<bool> restore(RegionLease lease);
}

/// 右键菜单 Region 事务：**先**把 Region 放大到整块画布，body 结束后**按凭据**恢复。
///
/// 与旧版本的唯一区别：恢复不再是"无条件执行"，而是把 [expandRegion] 返回的凭据
/// 交给 [restoreRegion]，由 `RegionCoordinator` 校验
/// `owner / generation / transactionId` 三者是否仍然一致 ——
/// 这样"右键 finally 晚于左键轮盘 apply 返回"就**不会**再覆盖轮盘 Region。
///
/// `try/finally` 仍然保留：异常路径（`showMenu` 抛错 / 页面切换 / 窗口销毁）
/// 也一样会把凭据交还给恢复逻辑。
Future<T> runContextMenuRegionTransaction<T>({
  required Future<RegionLease> Function()? expandRegion,
  required Future<void> Function(RegionLease lease)? restoreRegion,
  required Future<T> Function() body,
}) async {
  final RegionLease lease =
      await expandRegion?.call() ?? const RegionLease.none();
  try {
    return await body();
  } finally {
    await restoreRegion?.call(lease);
  }
}

/// 当前打开的右键菜单句柄（供外壳在切面板前**主动 dismiss 并等待**）。
///
/// 回归根因之一：菜单是通过 `showMenu`（PopupRoute）弹出的，外壳没有句柄可以
/// 关闭它；切面板时菜单可能仍开着，随后其 `finally` 会把"仅桌宠 Region"
/// 重新写回面板模式，破坏面板显示。
class ContextMenuBridge {
  bool _open = false;
  VoidCallback? _dismiss;
  Completer<void>? _closed;

  bool get isOpen => _open;

  /// 菜单打开时登记：`dismiss` 必须能真正关闭 PopupRoute。
  void register({required VoidCallback dismiss}) {
    _open = true;
    _dismiss = dismiss;
    _closed = Completer<void>();
  }

  /// 菜单关闭后登记注销（由菜单的 `finally` 调用）。
  void unregister() {
    _open = false;
    _dismiss = null;
    final Completer<void>? closed = _closed;
    _closed = null;
    if (closed != null && !closed.isCompleted) closed.complete();
  }

  /// 主动关闭菜单并**等待其真正关闭**（PopupRoute 动画结束）。
  Future<void> dismissAndWait() async {
    final VoidCallback? dismiss = _dismiss;
    final Future<void>? closed = _closed?.future;
    dismiss?.call();
    if (closed != null) await closed;
  }

  @visibleForTesting
  void resetForTest() {
    _open = false;
    _dismiss = null;
    _closed = null;
  }
}

/// 模块级共享实例：`PetViewWrapper` 登记，`DesktopShell` 在切换前关闭。
final ContextMenuBridge contextMenuBridge = ContextMenuBridge();

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:petlife/menu/fixed_canvas_contract.dart';
import 'package:petlife/menu/fixed_canvas_geometry.dart' show PhysicalRect;
import 'package:petlife/menu/region_coordinator.dart';
import 'package:petlife/menu/region_owner.dart';
import 'package:petlife/menu/wheel_geometry_ownership.dart' show WheelGeometryJournal;
import 'package:petlife/menu/wheel_interaction_state.dart';
import 'package:petlife/menu/windows_surface_mode.dart';
import 'dart:ui' show Rect;

/// 需求 §7-5（连续右键→左键 50 次）与额外要求（**随机交替 100 次**）：
/// 无论怎么乱点，最终 Region 必须与"当前 UI 状态"一致，且可判定。
void main() {
  const Rect wholeCanvas = Rect.fromLTWH(0, 0, 1352, 560);
  const Rect petLocal = Rect.fromLTWH(548, 152, 256, 256);
  const Rect menuLocal = Rect.fromLTWH(828, 100, 360, 360);
  const List<Rect> petAndMenu = <Rect>[petLocal, menuLocal];
  const List<Rect> petOnly = <Rect>[petLocal];

  late _FakeOps ops;
  late RegionCoordinator coordinator;
  late WheelInteractionGate gate;

  setUp(() {
    windowsSurfaceSession.resetForTest();
    ops = _FakeOps();
    coordinator = RegionCoordinator(
      ops: ops,
      devicePixelRatio: () => 1.0,
      journal: WheelGeometryJournal(capacity: 20000),
    );
    gate = WheelInteractionGate(journal: WheelGeometryJournal(capacity: 20000));
  });

  tearDown(() {
    windowsSurfaceSession.resetForTest();
  });

  test('#5 连续"右键→左键"50 轮：最终 Region 与 UI 状态一致', () async {
    final _Ui ui = _Ui(coordinator, gate, petOnly: petOnly, petAndMenu: petAndMenu, wholeCanvas: wholeCanvas);

    for (int i = 0; i < 50; i++) {
      final RegionLease lease = await ui.openContextMenu();
      await ui.leftClick(); // 抢占
      await ui.restoreContextMenu(lease); // 迟到的 finally
      await ui.leftClick(); // 关闭轮盘
      ui.expectConsistent('round $i');
      expect(ui.uiOwnerIsPet, isTrue, reason: 'round $i 收尾后应回到 pet');
    }

    expect(coordinator.owner, RegionOwner.pet);
    expect(coordinator.appliedRects, petOnly);
    expect(coordinator.isSynchronized, isTrue);
  });

  test('随机交替左键 / 右键 / 双击 100 次：最终状态可判定', () async {
    final _Ui ui = _Ui(coordinator, gate, petOnly: petOnly, petAndMenu: petAndMenu, wholeCanvas: wholeCanvas);
    final math.Random random = math.Random(20261005);

    for (int i = 0; i < 100; i++) {
      final int action = random.nextInt(3);
      switch (action) {
        case 0:
          await ui.leftClick();
        case 1:
          await ui.rightClickCycle();
        case 2:
          await ui.doubleClickPanelRoundTrip();
      }
      ui.expectConsistent('op $i action $action');
    }

    // 收尾：把 UI 关干净，验证最终可判定。
    await ui.forceCloseEverything();

    expect(coordinator.owner, RegionOwner.pet);
    expect(coordinator.appliedRects, petOnly);
    expect(coordinator.isDesiredCleared, isFalse);
    expect(coordinator.isSynchronized, isTrue);
    expect(gate.state, WheelInteractionState.closed);
    expect(ui.contextMenuOpen, isFalse);
    ui.expectConsistent('final');
  });

  test('opening / closing 期间的重复点击一律被忽略（不重入）', () async {
    final _Ui ui = _Ui(coordinator, gate, petOnly: petOnly, petAndMenu: petAndMenu, wholeCanvas: wholeCanvas);

    // 模拟"打开进行中"：手工进入 opening。
    expect(gate.beginOpen(), isTrue);
    expect(gate.state, WheelInteractionState.opening);
    // 第二次左键：必须被忽略。
    expect(gate.beginOpen(), isFalse);
    gate.recordReentryIgnored(action: 'left_click');
    await ui.leftClick(); // 走 UI 路径也不得改变 Region
    expect(gate.state, WheelInteractionState.opening);

    // 收尾。
    expect(gate.failOpen(), isTrue);
    expect(gate.state, WheelInteractionState.closed);
    expect(coordinator.owner, RegionOwner.pet);
  });

  test('closing 期间的点击排队/忽略：不产生第二个事务', () async {
    final _Ui ui = _Ui(coordinator, gate, petOnly: petOnly, petAndMenu: petAndMenu, wholeCanvas: wholeCanvas);
    await ui.leftClick(); // open
    expect(gate.state, WheelInteractionState.open);

    expect(gate.beginClose(), isTrue);
    expect(gate.beginOpen(), isFalse, reason: 'closing 不允许重新打开');
    expect(gate.beginClose(), isFalse, reason: 'closing 不允许重复关闭');
    await ui.leftClick(); // UI 路径：closing 时忽略
    expect(gate.state, WheelInteractionState.closing);

    gate.completeClose();
    await ui.forceCloseEverything();
    expect(coordinator.owner, RegionOwner.pet);
  });
}

/// 一份"用户操作 → Region 事务"的最小模型，用于把 UI 状态与 Region 所有权对账。
class _Ui {
  _Ui(
    this.coordinator,
    this.gate, {
    required this.petOnly,
    required this.petAndMenu,
    required this.wholeCanvas,
  });

  final RegionCoordinator coordinator;
  final WheelInteractionGate gate;
  final List<Rect> petOnly;
  final List<Rect> petAndMenu;
  final Rect wholeCanvas;

  bool contextMenuOpen = false;
  RegionLease? _contextLease;
  RegionLease? _wheelLease;
  bool wheelOpen = false;

  bool get uiOwnerIsPet => !wheelOpen && !contextMenuOpen;

  /// 左键：`closed → 打开` / `open → 关闭`；过渡态一律忽略。
  Future<void> leftClick() async {
    if (gate.state == WheelInteractionState.open) {
      await leftClose();
      return;
    }
    await leftOpen();
  }

  Future<void> leftOpen() async {
    if (!gate.beginOpen()) {
      gate.recordReentryIgnored(action: 'left_click');
      return;
    }
    // beginOpen 第一步：让 contextMenu 事务失效（并等待 / 主动 dismiss popup）。
    if (contextMenuOpen) {
      coordinator.invalidateOwner(RegionOwner.contextMenu, source: 'wheel.beginOpen');
      final RegionLease? stale = _contextLease;
      _contextLease = null;
      contextMenuOpen = false;
      if (stale != null) {
        await coordinator.restoreIfCurrent(
          stale,
          owner: RegionOwner.pet,
          rects: petOnly,
          source: 'context_menu.restore',
        );
      }
    }
    final RegionCommitOutcome outcome = await coordinator.apply(
      owner: RegionOwner.wheel,
      rects: petAndMenu,
      source: 'wheel.open',
    );
    if (!outcome.success) {
      gate.failOpen();
      return;
    }
    _wheelLease = outcome.lease;
    wheelOpen = true;
    gate.completeOpen();
  }

  Future<void> leftClose() async {
    if (!gate.beginClose()) {
      gate.recordReentryIgnored(action: 'left_click');
      return;
    }
    wheelOpen = false;
    final RegionLease? lease = _wheelLease;
    _wheelLease = null;
    if (lease != null) {
      await coordinator.restoreIfCurrent(
        lease,
        owner: RegionOwner.pet,
        rects: petOnly,
        source: 'wheel.close',
      );
    }
    gate.completeClose();
  }

  Future<RegionLease> openContextMenu() async {
    if (wheelOpen) {
      // 优先级：wheel > contextMenu —— 右键在轮盘打开时被拒绝。
      return const RegionLease.none();
    }
    final RegionCommitOutcome outcome = await coordinator.apply(
      owner: RegionOwner.contextMenu,
      rects: <Rect>[wholeCanvas],
      source: 'context_menu.open',
    );
    contextMenuOpen = true;
    _contextLease = outcome.lease;
    return outcome.lease;
  }

  Future<void> restoreContextMenu(RegionLease lease) async {
    if (!contextMenuOpen) return;
    contextMenuOpen = false;
    _contextLease = null;
    await coordinator.restoreIfCurrent(
      lease,
      owner: RegionOwner.pet,
      rects: petOnly,
      source: 'context_menu.restore',
    );
  }

  Future<void> rightClickCycle() async {
    if (wheelOpen) return; // 被拒绝
    if (contextMenuOpen) {
      final RegionLease? lease = _contextLease;
      if (lease != null) await restoreContextMenu(lease);
      return;
    }
    await openContextMenu();
  }

  Future<void> doubleClickPanelRoundTrip() async {
    // 双击 = 进面板 → 返回桌宠。面板侧独占 Region。
    gate.forceClosed(reason: 'panel_transition');
    wheelOpen = false;
    contextMenuOpen = false;
    _wheelLease = null;
    _contextLease = null;

    windowsSurfaceSession.changeTo(
      WindowsSurfaceMode.transitioningToPanel,
      source: 'ui.double_click',
    );
    coordinator.invalidateAll(source: 'panel.enterPanel');
    await coordinator.clear(
      owner: RegionOwner.panelTransition,
      source: 'panel.clear',
    );

    windowsSurfaceSession.changeTo(
      WindowsSurfaceMode.transitioningToPet,
      source: 'ui.return_to_pet',
    );
    await coordinator.apply(owner: RegionOwner.pet, rects: petOnly, source: 'panel.adopt');
    windowsSurfaceSession.changeTo(
      WindowsSurfaceMode.petFixedCanvas,
      source: 'ui.return_to_pet.complete',
    );
  }

  Future<void> forceCloseEverything() async {
    final RegionLease? contextLease = _contextLease;
    final RegionLease? wheelLease = _wheelLease;
    gate.forceClosed(reason: 'force_close');
    wheelOpen = false;
    contextMenuOpen = false;
    _wheelLease = null;
    _contextLease = null;

    if (wheelLease != null) {
      await coordinator.restoreIfCurrent(
        wheelLease,
        owner: RegionOwner.pet,
        rects: petOnly,
        source: 'wheel.close',
      );
    }
    if (contextLease != null) {
      await coordinator.restoreIfCurrent(
        contextLease,
        owner: RegionOwner.pet,
        rects: petOnly,
        source: 'context_menu.restore',
      );
    }
    // 兜底：无论中间发生过什么，最终都回到"仅桌宠"。
    await coordinator.apply(owner: RegionOwner.pet, rects: petOnly, source: 'final');
  }

  void expectConsistent(String label) {
    expect(
      coordinator.isSynchronized,
      isTrue,
      reason: '$label: 期望态与实际 Region 必须一致',
    );
    final String? violation = RegionUiConsistency.evaluate(
      owner: coordinator.owner,
      desiredCleared: coordinator.isDesiredCleared,
      wheelState: gate.state,
      contextMenuOpen: contextMenuOpen,
    );
    expect(violation, isNull, reason: '$label: UI 与 Region 归属不一致 → $violation');
  }
}

class _FakeOps implements RegionNativeOps {
  final List<String> trace = <String>[];

  @override
  Future<RegionApplyResult> applyInteractionRegion(
    List<Rect> logicalRects, {
    required double devicePixelRatio,
  }) async {
    trace.add('apply:${logicalRects.length}');
    return RegionApplyResult(
      success: true,
      rectCount: logicalRects.length,
      boundingBox: const PhysicalRect(0, 0, 100, 100),
    );
  }

  @override
  Future<RegionApplyResult> restorePetOnlyRegion(
    Rect logicalPetRect, {
    required double devicePixelRatio,
  }) async {
    trace.add('petOnly');
    return const RegionApplyResult(
      success: true,
      rectCount: 1,
      boundingBox: PhysicalRect(0, 0, 100, 100),
    );
  }

  @override
  Future<bool> clearInteractionRegion() async {
    trace.add('clear');
    return true;
  }

  @override
  Future<int?> gdiObjectCount() async => 512;

  @override
  Future<PhysicalRect?> regionBoundingBox() async => null;
}

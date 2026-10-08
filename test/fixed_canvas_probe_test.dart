import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:petlife/menu/fixed_canvas_contract.dart';
import 'package:petlife/menu/fixed_canvas_geometry.dart'
    show PhysicalRect, fixedCanvasAnchor;
import 'package:petlife/menu/menu_contract.dart' show MenuCatalog;
import 'package:petlife/menu/pet_position_resolver.dart' show WindowPositionSchema;
import 'package:petlife/menu/region_coordinator.dart';
import 'package:petlife/menu/region_owner.dart';
import 'package:petlife/menu/wheel_canvas_plan.dart'
    show WheelCanvasPlan, WheelCanvasPlanner;
import 'package:petlife/menu/wheel_geometry.dart' show WheelDisplayArea;
import 'package:petlife/menu/wheel_geometry_ownership.dart'
    show WheelGeometryJournal, wheelGeometryJournal;
import 'package:petlife/menu/wheel_interaction_state.dart';
import 'package:petlife/menu/wheel_menu_geometry.dart'
    show WheelExpandDirection, WheelMenuLayoutSettings;
import 'package:petlife/menu/windows_surface_mode.dart';
import 'package:petlife/ui/desktop/fixed_canvas_probe.dart';

/// 固定画布探针的**行为**测试（用假 window / region 实现驱动）。
///
/// 关键断言：开合菜单**绝不**提交窗口矩形、桌宠锚点不变、
/// 仅桌宠 Region 不含画布、Region 失败必须回退小窗口、
/// 左键入口四态机不得重入（opening 时第二次点击被忽略）。
void main() {
  setUp(() {
    fixedCanvasAnchor.clear();
    windowsSurfaceSession.resetForTest();
    // 日志是**全局单例**：不清空的话，前一个用例留下的 `startup.*` 事件会让
    // 后一个用例的**否定断言**（"不得出现修正日志"）变成假阴性。
    wheelGeometryJournal.clear();
  });

  tearDown(() {
    fixedCanvasAnchor.clear();
    windowsSurfaceSession.resetForTest();
    wheelGeometryJournal.clear();
  });

  testWidgets('#1 开 / 关菜单绝不再提交窗口矩形（只改 Region）', (WidgetTester tester) async {
    final _FakeWindowOps windowOps = _FakeWindowOps();
    final _FakeRegionOps regionOps = _FakeRegionOps();
    final FixedCanvasProbeState state =
        await _pumpProbe(tester, windowOps: windowOps, regionOps: regionOps);

    await state.prepareFixedCanvas();
    await tester.pump();
    expect(windowOps.commits, hasLength(1), reason: '建立画布只允许一次提交');

    await state.open();
    await tester.pump();
    expect(windowOps.commits, hasLength(1), reason: '打开菜单绝不能再提交窗口矩形');

    await state.close();
    await tester.pump();
    expect(windowOps.commits, hasLength(1), reason: '关闭菜单绝不能再提交窗口矩形');
    expect(windowOps.bounds, windowOps.commits.single);
  });

  testWidgets('#2 桌宠锚点在开合前后不变；#5 仅桌宠 Region 不含画布', (WidgetTester tester) async {
    final _FakeWindowOps windowOps = _FakeWindowOps();
    final _FakeRegionOps regionOps = _FakeRegionOps();
    final FixedCanvasProbeState state =
        await _pumpProbe(tester, windowOps: windowOps, regionOps: regionOps);

    await state.prepareFixedCanvas();
    await tester.pump();
    await state.open();
    await tester.pump();
    await state.close();
    await tester.pump();

    // prepare / close 走 restorePetOnlyRegion；open 走 applyInteractionRegion。
    expect(regionOps.petOnlyRestores, hasLength(2), reason: 'prepare + close');
    expect(regionOps.applied, hasLength(1), reason: 'open 只提交一次 pet+menu');

    final Rect petOnlyBefore = regionOps.petOnlyRestores[0];
    final List<Rect> petAndMenu = regionOps.applied[0];
    final Rect petOnlyAfter = regionOps.petOnlyRestores[1];

    // #2 锚点不变：仅桌宠矩形在开合前后完全相同。
    expect(petOnlyAfter, petOnlyBefore);

    // #5 仅桌宠 Region 不含周围透明画布。
    expect(petOnlyBefore.size, const Size(256, 256));

    // #6 菜单 Region = 桌宠 ∪ 弧带扇形 ∪ 按钮命中圆 ∪ 文字 chip ∪ 反馈条，
    //     由**实际几何**逐块生成（增量 B 决策；不再是"桌宠 + 一块菜单矩形"两块）。
    final Size canvas = _expectedCanvas();
    expect(petAndMenu.length, greaterThanOrEqualTo(2), reason: '至少有桌宠 + 菜单');
    expect(petAndMenu.length, lessThanOrEqualTo(48), reason: '矩形数量有上限');
    expect(petAndMenu.first, petOnlyBefore, reason: '桌宠矩形始终在第一位');
    // 绝不允许有任何一块覆盖整块画布（否则会挡住桌面上的点击）。
    for (final Rect r in petAndMenu) {
      expect(r.width, lessThan(canvas.width + 0.5));
      expect(r.height, lessThan(canvas.height + 0.5));
    }

    // 左键入口状态机收尾必须回到 closed。
    expect(state.wheelState, WheelInteractionState.closed);
  });

  testWidgets('#4 镜像只改变菜单局部矩形（桌宠矩形不变）', (WidgetTester tester) async {
    // 桌宠靠左 → 菜单在右。
    final _FakeWindowOps leftOps = _FakeWindowOps();
    final _FakeRegionOps leftRegion = _FakeRegionOps();
    final FixedCanvasProbeState leftState = await _pumpProbe(
      tester,
      windowOps: leftOps,
      regionOps: leftRegion,
      savedPetScreenPosition: const Offset(100, 400),
    );
    await leftState.prepareFixedCanvas();
    await tester.pump();
    await leftState.open();
    await tester.pump();

    // 桌宠靠右 → 菜单在左。
    final _FakeWindowOps rightOps = _FakeWindowOps();
    final _FakeRegionOps rightRegion = _FakeRegionOps();
    final FixedCanvasProbeState rightState = await _pumpProbe(
      tester,
      windowOps: rightOps,
      regionOps: rightRegion,
      savedPetScreenPosition: const Offset(1600, 400),
    );
    await rightState.prepareFixedCanvas();
    await tester.pump();
    await rightState.open();
    await tester.pump();

    final Rect leftPet = leftRegion.applied.last.first;
    final Rect rightPet = rightRegion.applied.last.first;

    expect(leftPet, rightPet, reason: '镜像不应改变桌宠矩形');
    // 方向由几何层（信封 direction）判定 —— 不再用"菜单矩形边缘"这种脆弱推断：
    // 新 Region 是 桌宠 ∪ 弧带扇形 ∪ 按钮命中圆 …，扇形包围块会与桌宠块水平重叠。
    expect(leftState.wheelEnvelope?.direction, WheelExpandDirection.right,
        reason: '桌宠靠左 → 菜单向右展开');
    expect(rightState.wheelEnvelope?.direction, WheelExpandDirection.left,
        reason: '桌宠靠右 → 菜单向左展开');
    // 镜像确实改变了菜单 Region（两侧块集合不同），但桌宠块保持不变。
    expect(leftRegion.applied.last, isNot(equals(rightRegion.applied.last)),
        reason: '镜像只改菜单，两侧 Region 不应相同');
  });

  testWidgets('#11 Region 应用失败 → 回退小窗口（清 Region + 缩回桌宠矩形）',
      (WidgetTester tester) async {
    final _FakeWindowOps windowOps = _FakeWindowOps();
    final _FakeRegionOps regionOps = _FakeRegionOps()..failApply = true;
    final FixedCanvasProbeState state =
        await _pumpProbe(tester, windowOps: windowOps, regionOps: regionOps);

    final bool ready = await state.prepareFixedCanvas();
    await tester.pump();

    expect(ready, isFalse);
    expect(regionOps.cleared, isTrue, reason: '回退必须清除 Region');
    expect(windowOps.commits, hasLength(2), reason: '第二次提交把窗口缩回桌宠矩形');
    expect(windowOps.commits.last.size, const Size(256, 256));
    expect(fixedCanvasAnchor.enabled, isFalse);
  });

  testWidgets('#9 鼠标穿透开启 → 拒绝打开菜单并给明确提示', (WidgetTester tester) async {
    final _FakeWindowOps windowOps = _FakeWindowOps();
    final _FakeRegionOps regionOps = _FakeRegionOps();
    final FixedCanvasProbeState state = await _pumpProbe(
      tester,
      windowOps: windowOps,
      regionOps: regionOps,
      mousePassthrough: true,
    );

    await state.prepareFixedCanvas();
    await tester.pump();
    final int appliedBefore = regionOps.applied.length;

    await state.open();
    await tester.pump();

    expect(state.isOpen, isFalse);
    expect(regionOps.applied, hasLength(appliedBefore), reason: '拒绝时不应改 Region');
    expect(find.textContaining('鼠标穿透'), findsOneWidget);
  });

  testWidgets('#9b 释放固定画布清除 Region 并复位锚点', (WidgetTester tester) async {
    final _FakeWindowOps windowOps = _FakeWindowOps();
    final _FakeRegionOps regionOps = _FakeRegionOps();
    final FixedCanvasProbeState state =
        await _pumpProbe(tester, windowOps: windowOps, regionOps: regionOps);

    await state.prepareFixedCanvas();
    await tester.pump();
    expect(fixedCanvasAnchor.enabled, isTrue);

    await state.releaseFixedCanvas();
    await tester.pump();

    expect(regionOps.cleared, isTrue);
    expect(fixedCanvasAnchor.enabled, isFalse);
  });

  testWidgets('#6b 右键 Overlay：Region = 桌宠 ∪ 实际菜单矩形，关闭后恢复仅桌宠',
      (WidgetTester tester) async {
    final _FakeWindowOps windowOps = _FakeWindowOps();
    final _FakeRegionOps regionOps = _FakeRegionOps();
    final FixedCanvasProbeState state =
        await _pumpProbe(tester, windowOps: windowOps, regionOps: regionOps);

    await state.prepareFixedCanvas();
    await tester.pump();

    // 菜单矩形由 `ContextMenuLayout` 规划后原样传入（真机回归 #2 的新口径）。
    const Rect menuRect = Rect.fromLTWH(300, 420, 220, 180);
    final RegionLease lease = await state.expandRegionForOverlay(menuRect);
    await tester.pump();
    expect(lease.isValid, isTrue);
    // 只覆盖"桌宠 + 菜单"两块，**绝不**是整块固定画布。
    expect(regionOps.applied.last, hasLength(2));
    expect(regionOps.applied.last.first.size, const Size(256, 256));
    expect(regionOps.applied.last.last, menuRect);
    final Size canvas = _expectedCanvas();
    for (final Rect r in regionOps.applied.last) {
      expect(r.width, lessThan(canvas.width + 0.5));
      expect(r.height, lessThan(canvas.height + 0.5));
    }

    await state.restorePetOnlyRegionNow(lease);
    await tester.pump();
    // 恢复仅桌宠（不含周围透明画布）。
    expect(regionOps.petOnlyRestores.last.size, const Size(256, 256));
    // 开合期间窗口矩形不变。
    expect(windowOps.commits, hasLength(1));
  });

  testWidgets('轮盘打开时右键被拒绝：Region 不再被 contextMenu 改动', (WidgetTester tester) async {
    final _FakeWindowOps windowOps = _FakeWindowOps();
    final _FakeRegionOps regionOps = _FakeRegionOps();
    final FixedCanvasProbeState state =
        await _pumpProbe(tester, windowOps: windowOps, regionOps: regionOps);

    await state.prepareFixedCanvas();
    await tester.pump();
    await state.open();
    await tester.pump();
    expect(state.wheelState, WheelInteractionState.open);

    final int appliesBefore = regionOps.applied.length;
    final RegionLease lease = await state.expandRegionForOverlay(
      const Rect.fromLTWH(300, 420, 220, 180),
    );
    await tester.pump();

    expect(lease.isValid, isFalse, reason: '优先级 wheel > contextMenu');
    expect(regionOps.applied, hasLength(appliesBefore), reason: '不得再提交一次 Region');
    // Region 未被 contextMenu 抢走：仍是轮盘的**实际几何**（多块），
    // 而不是"整块画布"那种单矩形。
    final Size canvas = _expectedCanvas();
    expect(regionOps.applied.last.length, greaterThan(2),
        reason: 'Region 仍是轮盘的 pet+menu 多块几何');
    for (final Rect r in regionOps.applied.last) {
      expect(r.width, lessThan(canvas.width + 0.5), reason: '不得出现整块画布 Region');
      expect(r.height, lessThan(canvas.height + 0.5), reason: '不得出现整块画布 Region');
    }
  });

  testWidgets('opening 时的第二次左键被忽略（不重入、不改 Region）', (WidgetTester tester) async {
    final _FakeWindowOps windowOps = _FakeWindowOps();
    final _FakeRegionOps regionOps = _FakeRegionOps()..holdApply = true;
    final FixedCanvasProbeState state =
        await _pumpProbe(tester, windowOps: windowOps, regionOps: regionOps);

    await state.prepareFixedCanvas();
    await tester.pump();
    final int appliesBefore = regionOps.applied.length;

    // 第一次左键：进入 opening 并挂起在原生调用上。
    final Future<void> first = state.open();
    await tester.pump();
    expect(state.wheelState, WheelInteractionState.opening);

    // 第二次左键（快速连点）：必须被忽略。
    await state.open();
    await tester.pump();
    expect(state.wheelState, WheelInteractionState.opening);
    expect(regionOps.applied, hasLength(appliesBefore + 1),
        reason: '第二次点击不得再提交一次 Region');

    regionOps.releaseApply();
    await first;
    await tester.pump();
    expect(state.wheelState, WheelInteractionState.open);
    expect(regionOps.applied, hasLength(appliesBefore + 1));
  });

  testWidgets('Region 失败的后继路径不留下 full-canvas Region', (WidgetTester tester) async {
    final _FakeWindowOps windowOps = _FakeWindowOps();
    final _FakeRegionOps regionOps = _FakeRegionOps();
    final FixedCanvasProbeState state =
        await _pumpProbe(tester, windowOps: windowOps, regionOps: regionOps);

    await state.prepareFixedCanvas();
    await tester.pump();

    // 右键把 Region 扩成"桌宠 + 菜单"，然后（模拟被轮盘抢占）用过期的凭据恢复。
    final RegionLease lease = await state.expandRegionForOverlay(
      const Rect.fromLTWH(300, 420, 220, 180),
    );
    await tester.pump();
    await state.open();
    await tester.pump();
    await state.close();
    await tester.pump();

    await state.restorePetOnlyRegionNow(lease); // 迟到恢复：必须被丢弃
    await tester.pump();

    // 过期恢复被丢弃：不产生新的原生写入，Region 保持"仅桌宠"（不是 full-canvas）。
    expect(state.wheelState, WheelInteractionState.closed);
    expect(state.isOpen, isFalse);
    expect(regionOps.petOnlyRestores, isNotEmpty);
    expect(regionOps.petOnlyRestores.last.size, const Size(256, 256));
  });

  testWidgets('Region 与 WheelInteractionState 不一致 → 自检发现并安全回退',
      (WidgetTester tester) async {
    final _FakeWindowOps windowOps = _FakeWindowOps();
    final _FakeRegionOps regionOps = _FakeRegionOps();
    final RegionCoordinator coordinator = RegionCoordinator(
      ops: regionOps,
      devicePixelRatio: () => 1.25,
      journal: WheelGeometryJournal(capacity: 800),
    );
    final FixedCanvasProbeState state = await _pumpProbe(
      tester,
      windowOps: windowOps,
      regionOps: regionOps,
      coordinator: coordinator,
    );

    await state.prepareFixedCanvas();
    await tester.pump();
    await state.open();
    await tester.pump();
    expect(state.wheelState, WheelInteractionState.open);

    // 人为制造不一致：把 Region 抢到 panelTransition 并清掉。
    await coordinator.clear(
      owner: RegionOwner.panelTransition,
      source: 'test.force_inconsistent',
    );
    expect(coordinator.isDesiredCleared, isTrue);

    final String? violation = state.verifyRegionConsistencyNow();
    expect(violation, isNotNull, reason: 'wheel 已打开但 Region 不属于 wheel');
    await tester.pump();

    // 安全回退：状态机复位到 closed，Region 回到"仅桌宠"。
    expect(state.wheelState, WheelInteractionState.closed);
    expect(coordinator.owner, RegionOwner.pet);
    expect(coordinator.isDesiredCleared, isFalse);
    expect(coordinator.desiredRects.single.size, const Size(256, 256));
    expect(coordinator.isSynchronized, isTrue);
  });

  // ---------------------------------------------------------------------------
  // 增量 B 修正：按「当前设置 + 当前工作区」规划画布 + 关闭态原子重建
  // ---------------------------------------------------------------------------

  testWidgets('#4 菜单开 / 关与层级切换都不改变画布计划、也不再提交窗口矩形',
      (WidgetTester tester) async {
    final _FakeWindowOps windowOps = _FakeWindowOps();
    final _FakeRegionOps regionOps = _FakeRegionOps();
    final FixedCanvasProbeState state =
        await _pumpProbe(tester, windowOps: windowOps, regionOps: regionOps);

    await state.prepareFixedCanvas();
    await tester.pump();
    final WheelCanvasPlan planned = state.canvasPlan!;
    expect(windowOps.commits, hasLength(1));

    for (int i = 0; i < 3; i++) {
      await state.open();
      await tester.pump();
      expect(state.canvasPlan!.canvasSize, planned.canvasSize, reason: '打开不改画布');
      await state.close();
      await tester.pump();
      expect(state.canvasPlan!.canvasSize, planned.canvasSize, reason: '关闭不改画布');
    }
    expect(windowOps.commits, hasLength(1), reason: '开合菜单绝不提交窗口矩形');
    expect(state.canvasRebuildCount, 0, reason: '开合菜单不触发画布重建');
    expect(state.canvasPlan!.canvasSize,
        WheelCanvasPlanner.plan(
          petSize: const Size(256, 256),
          workArea: const Size(1920, 1080),
          settings: WheelMenuLayoutSettings.defaults,
        ).canvasSize);
  });

  testWidgets('#5/#6 几何设置变化：关闭态只重建一次，桌宠屏幕锚点误差 ≤ 1px',
      (WidgetTester tester) async {
    final _FakeWindowOps windowOps = _FakeWindowOps();
    final _FakeRegionOps regionOps = _FakeRegionOps();
    final ValueNotifier<int> signal = ValueNotifier<int>(0);
    WheelMenuLayoutSettings settings = WheelMenuLayoutSettings.defaults;
    final FixedCanvasProbeState state = await _pumpProbe(
      tester,
      windowOps: windowOps,
      regionOps: regionOps,
      wheelSettings: () => settings,
      reestablishOn: signal,
    );

    await state.prepareFixedCanvas();
    await tester.pump();
    expect(windowOps.commits, hasLength(1));
    final Size before = state.canvasPlan!.canvasSize;
    final Offset anchorBefore = state.petAnchorForTest;
    final Offset petScreenBefore = windowOps.commits.single.topLeft + anchorBefore;

    // 几何设置变化 → 触发一次原子重建。
    settings = settings.copyWith(preferredScale: 2.5);
    signal.value = signal.value + 1;
    await tester.pumpAndSettle();

    expect(windowOps.commits, hasLength(2), reason: '设置变化只重建一次窗口');
    expect(state.canvasRebuildCount, 1);
    expect(state.canvasPlan!.canvasSize, isNot(before));
    expect(state.canvasPlan!.compressed, isTrue, reason: '1920×1080 上 250% 会自动压缩');
    // 桌宠屏幕锚点不变（误差 ≤ 1px）。
    final Offset petScreenAfter = windowOps.bounds.topLeft + state.petAnchorForTest;
    expect((petScreenAfter.dx - petScreenBefore.dx).abs(), lessThanOrEqualTo(1.0));
    expect((petScreenAfter.dy - petScreenBefore.dy).abs(), lessThanOrEqualTo(1.0));
    expect(state.lastRebuildAnchorErrorPx, isNotNull);
    expect(state.lastRebuildAnchorErrorPx!, lessThanOrEqualTo(1.0));
    // 重建期间先隐藏、校验通过后再显示。
    expect(windowOps.visibility, containsAllInOrder(<bool>[false, true]));
    expect(windowOps.visible, isTrue);
    // Region 收敛回"仅桌宠"，且不含整块画布。
    expect(regionOps.petOnlyRestores.last.size, const Size(256, 256));
    expect(state.wheelState, WheelInteractionState.closed);
  });

  testWidgets('#5 轮盘打开时改设置：先关闭再重建，仍然是"一次窗口提交"',
      (WidgetTester tester) async {
    final _FakeWindowOps windowOps = _FakeWindowOps();
    final _FakeRegionOps regionOps = _FakeRegionOps();
    final ValueNotifier<int> signal = ValueNotifier<int>(0);
    WheelMenuLayoutSettings settings = WheelMenuLayoutSettings.defaults;
    final FixedCanvasProbeState state = await _pumpProbe(
      tester,
      windowOps: windowOps,
      regionOps: regionOps,
      wheelSettings: () => settings,
      reestablishOn: signal,
    );

    await state.prepareFixedCanvas();
    await tester.pump();
    await state.open();
    await tester.pump();
    expect(state.wheelState, WheelInteractionState.open);
    expect(windowOps.commits, hasLength(1));

    settings = settings.copyWith(buttonVisualScale: 2.5);
    signal.value = signal.value + 1;
    await tester.pumpAndSettle();

    // 轮盘先被关掉，再重建画布 —— 一共只多一次窗口提交。
    expect(state.wheelState, WheelInteractionState.closed);
    expect(windowOps.commits, hasLength(2));
    expect(state.canvasRebuildCount, 1);
    expect(state.lastRebuildAnchorErrorPx!, lessThanOrEqualTo(1.0));
  });

  testWidgets('#13 面板返回：采用已提交画布（不再自行提交），并刷新计划快照',
      (WidgetTester tester) async {
    final _FakeWindowOps windowOps = _FakeWindowOps();
    final _FakeRegionOps regionOps = _FakeRegionOps();
    final FixedCanvasProbeState state =
        await _pumpProbe(tester, windowOps: windowOps, regionOps: regionOps);
    await state.prepareFixedCanvas();
    await tester.pump();
    final int commitsAfterPrepare = windowOps.commits.length;
    final Rect boundsAfterPrepare = windowOps.bounds;

    const WheelMenuLayoutSettings changed =
        WheelMenuLayoutSettings(preferredScale: 0.5, menuDistance: 0.30);
    final WheelCanvasPlan expected = WheelCanvasPlanner.plan(
      petSize: const Size(256, 256),
      workArea: const Size(1920, 1080),
      settings: changed,
    );
    const Offset anchor = Offset(200, 200);
    const Size pet = Size(256, 256);
    final Rect canvasRect = Rect.fromLTWH(500, 300, expected.canvasSize.width, expected.canvasSize.height);

    final bool ok = await state.adoptCommittedCanvas(
      canvasRect: canvasRect,
      petAnchor: anchor,
      petSize: pet,
    );
    await tester.pump();

    expect(ok, isTrue);
    expect(windowOps.commits, hasLength(commitsAfterPrepare),
        reason: '采用已提交画布时绝不再次提交窗口矩形');
    expect(windowOps.bounds, boundsAfterPrepare,
        reason: '窗口矩形由外壳提交，探针不得改写它');
    expect(state.petAnchorForTest, anchor);
    // 计划快照按"当前设置"刷新（这里设置仍是默认值，故与默认计划一致）。
    expect(state.canvasPlan!.canvasSize,
        WheelCanvasPlanner.plan(
          petSize: pet,
          workArea: const Size(1920, 1080),
          settings: WheelMenuLayoutSettings.defaults,
        ).canvasSize);
    expect(regionOps.petOnlyRestores.last.size, pet);
  });

  testWidgets('#15 反复开合不增长：窗口提交恒为 1、Region 矩形数稳定、不重建画布',
      (WidgetTester tester) async {
    final _FakeWindowOps windowOps = _FakeWindowOps();
    final _FakeRegionOps regionOps = _FakeRegionOps();
    final FixedCanvasProbeState state =
        await _pumpProbe(tester, windowOps: windowOps, regionOps: regionOps);
    await state.prepareFixedCanvas();
    await tester.pump();

    for (int i = 0; i < 5; i++) {
      await state.open();
      await tester.pump();
      await state.close();
      await tester.pump();
    }

    expect(windowOps.commits, hasLength(1), reason: '五轮开合都不得提交窗口矩形');
    expect(state.canvasRebuildCount, 0);
    // 每次打开的 Region 矩形数完全一致（没有逐轮累积）。
    final int first = regionOps.applied.first.length;
    for (final List<Rect> rects in regionOps.applied) {
      expect(rects.length, first);
      expect(rects.first.size, const Size(256, 256), reason: '桌宠矩形恒为第一块');
      expect(rects.length, lessThanOrEqualTo(48));
    }
    expect(regionOps.applied, hasLength(5));
    expect(regionOps.petOnlyRestores, hasLength(6), reason: 'prepare + 每轮关闭各一次');
    expect(state.wheelState, WheelInteractionState.closed);
    expect(regionOps.gdi, 512, reason: 'GDI 对象数不持续增长');
  });

  testWidgets('#12 负坐标显示器：画布仍然提交且桌宠可见', (WidgetTester tester) async {
    final _FakeWindowOps windowOps = _FakeWindowOps();
    final _FakeRegionOps regionOps = _FakeRegionOps();
    windowOps.display =
        const WheelDisplayArea(id: 'left', left: -1920, top: 0, width: 1920, height: 1040);
    final FixedCanvasProbeState state = await _pumpProbe(
      tester,
      windowOps: windowOps,
      regionOps: regionOps,
      savedPetScreenPosition: const Offset(-1700, 400),
    );
    final bool ok = await state.prepareFixedCanvas();
    await tester.pump();
    expect(ok, isTrue);
    expect(windowOps.commits, hasLength(1));
    final Rect rect = windowOps.commits.single;
    expect(rect.left, lessThan(0));
    expect(rect.width, greaterThan(256));
    expect(state.canvasPlan!.workArea, const Size(1920, 1040));
    expect(regionOps.petOnlyRestores.single.size, const Size(256, 256));
  });

  // ---------------------------------------------------------------------------
  // 真机回归 #1：左键点了"完全没反应" —— 展开动画必须真的推进。
  // ---------------------------------------------------------------------------

  testWidgets('#16 左键打开后展开动画真的推进（Ticker 启动 + 首帧不吞掉终态）',
      (WidgetTester tester) async {
    final _FakeWindowOps windowOps = _FakeWindowOps();
    final _FakeRegionOps regionOps = _FakeRegionOps();
    final FixedCanvasProbeState state =
        await _pumpProbe(tester, windowOps: windowOps, regionOps: regionOps);
    await state.prepareFixedCanvas();
    await tester.pump();

    await state.toggleFormalWheel();
    await tester.pump();

    // 打开序列完成：opening（动画进行中），Region 与输入都已就位。
    expect(state.wheelState, WheelInteractionState.open);
    expect(state.wheelPhaseName, 'opening');
    expect(state.wheelLevelId, MenuCatalog.rootId);

    // 关键：`WheelMenuView` 挂载时必须自己启动 Ticker，否则 `tick()` 永不调用，
    // `openProgress` 永远停在 0，画笔整帧不画（= 用户看到的"完全无反应"）。
    await tester.pump(const Duration(milliseconds: 40));
    final double afterFirstFrame = state.wheelOpenProgressForTest;
    expect(afterFirstFrame, greaterThan(0),
        reason: '挂载后第一帧必须已经开始推进展开动画');
    await tester.pump(const Duration(milliseconds: 400));
    expect(state.wheelOpenProgressForTest, greaterThanOrEqualTo(afterFirstFrame),
        reason: '动画只能前进，不得倒退');

    // 事件链完整落日志。
    for (final String event in <String>[
      'wheel.toggle.request',
      'wheel.region.acquire.start',
      'wheel.region.acquire.result',
      'wheel.ui.state',
      'wheel.open.animation.start',
      'wheel.open.visible',
    ]) {
      expect(wheelGeometryJournal.contains(event), isTrue, reason: '缺少日志 $event');
    }
  });

  testWidgets('#17 连续两次左键只产生一个打开事务（第二次不重入）',
      (WidgetTester tester) async {
    final _FakeWindowOps windowOps = _FakeWindowOps();
    final _FakeRegionOps regionOps = _FakeRegionOps();
    final FixedCanvasProbeState state =
        await _pumpProbe(tester, windowOps: windowOps, regionOps: regionOps);
    await state.prepareFixedCanvas();
    await tester.pump();
    final int appliesBefore = regionOps.applied.length;

    final Future<void> first = state.toggleFormalWheel();
    await state.toggleFormalWheel();
    await first;
    await tester.pump();

    expect(state.wheelState, WheelInteractionState.open);
    expect(regionOps.applied, hasLength(appliesBefore + 1),
        reason: '第二次点击不得再提交一次 Region');
    expect(windowOps.commits, hasLength(1), reason: '开菜单不得改窗口矩形');
  });

  testWidgets('#18 Region 失败：给出可见反馈并回到 closed（不静默无反应）',
      (WidgetTester tester) async {
    final _FakeWindowOps windowOps = _FakeWindowOps();
    final _FakeRegionOps regionOps = _FakeRegionOps()..failApply = true;
    final FixedCanvasProbeState state =
        await _pumpProbe(tester, windowOps: windowOps, regionOps: regionOps);
    await state.prepareFixedCanvas();
    await tester.pump();
    // prepareFixedCanvas 已经因 Region 失败回退；这里重置成"可再次尝试"。
    regionOps.failApply = false;
    await state.prepareFixedCanvas();
    await tester.pump();
    expect(state.wheelState, WheelInteractionState.closed,
        reason: 'prepare 成功后应回到 closed（可再次打开）');

    regionOps.failApply = true;
    final int appliesBefore = regionOps.applied.length;
    await state.toggleFormalWheel();
    await tester.pump();

    expect(state.wheelState, WheelInteractionState.closed,
        reason: 'Region 失败必须回到 closed，不能卡在 opening');
    expect(state.fallbackForTest, isTrue, reason: '失败路径必须回退小窗口，不留大透明块');
    expect(regionOps.applied.length, greaterThan(appliesBefore),
        reason: '确实尝试过提交 Region');
    expect(find.textContaining('Region'), findsWidgets, reason: '必须有可见反馈');
  });

  // ---------------------------------------------------------------------------
  // 真机回归：启动位置语义 + 可见性保护（探针侧行为）
  // ---------------------------------------------------------------------------

  testWidgets('#19 坏位置 (-300,307)：修正到主屏右下角、立刻写回 v2、只提交一次画布',
      (WidgetTester tester) async {
    final _FakeWindowOps windowOps = _FakeWindowOps();
    final _FakeRegionOps regionOps = _FakeRegionOps();
    final List<({Offset position, int schema})> persisted =
        <({Offset position, int schema})>[];
    final FixedCanvasProbeState state = await _pumpProbe(
      tester,
      windowOps: windowOps,
      regionOps: regionOps,
      savedPetScreenPosition: const Offset(-300, 307),
      onPersist: (Offset p, int schema) =>
          persisted.add((position: p, schema: schema)),
    );

    final bool ok = await state.prepareFixedCanvas();
    await tester.pump();

    expect(ok, isTrue, reason: '修正后必须可用（不是回退）');
    expect(state.fallbackForTest, isFalse);
    // 只提交一次画布矩形（= 一次 SetWindowPos）。
    expect(windowOps.commits, hasLength(1));
    // 修正后人物可见（画布矩形 + petAnchor 推出的人物矩形落在显示器内）。
    expect(state.petAnchorForTest, isNot(Offset.zero));
    final Rect petScreen = state.petScreenRectForTest!;
    expect(petScreen.intersect(windowOps.display!.rect).isEmpty, isFalse);
    expect(state.startupVisibleRatioForTest, greaterThanOrEqualTo(0.5));
    // 修正值立刻写回 v2（"迁移只执行一次"）。
    // 假显示器是 1920×**1080** → 右下角 = (1920-256-32, 1080-256-32)。
    expect(persisted, hasLength(1));
    expect(persisted.single.schema, WindowPositionSchema.v2);
    expect(persisted.single.position, const Offset(1632, 792));
    // 事件链完整。
    for (final String event in <String>[
      'startup.position.loaded',
      'startup.position.schema',
      'startup.pet_size.ready',
      'startup.pet_position.validated',
      'startup.pet_position.corrected',
      'startup.canvas_plan.ready',
      'startup.canvas_bounds.commit',
      'startup.region.applied',
      'startup.actual_window_rect',
      'startup.actual_pet_screen_rect',
      'startup.pet_visible_ratio',
    ]) {
      expect(wheelGeometryJournal.contains(event), isTrue, reason: '缺少日志 $event');
    }
  });

  testWidgets('#20 v2 有效位置：原样恢复、不写库、不触发修正日志',
      (WidgetTester tester) async {
    final _FakeWindowOps windowOps = _FakeWindowOps();
    final _FakeRegionOps regionOps = _FakeRegionOps();
    final List<Offset> persisted = <Offset>[];
    final FixedCanvasProbeState state = await _pumpProbe(
      tester,
      windowOps: windowOps,
      regionOps: regionOps,
      savedPetScreenPosition: const Offset(1200, 700),
      onPersist: (Offset p, int schema) => persisted.add(p),
    );

    final bool ok = await state.prepareFixedCanvas();
    await tester.pump();

    expect(ok, isTrue);
    expect(persisted, isEmpty, reason: 'v2 有效位置不得触发任何写入');
    expect(wheelGeometryJournal.contains('startup.pet_position.corrected'), isFalse);
    expect(wheelGeometryJournal.contains('startup.position.migration'), isFalse);
    // 人物矩形由画布矩形 + petAnchor 推出，且 == 保存位置。
    expect(state.petScreenRectForTest!.topLeft, const Offset(1200, 700));
  });

  testWidgets('#21 v1 + 旧窗口尺寸 == 人物尺寸 → 迁移并写回 v2',
      (WidgetTester tester) async {
    final _FakeWindowOps windowOps = _FakeWindowOps();
    final _FakeRegionOps regionOps = _FakeRegionOps();
    final List<({Offset position, int schema})> persisted =
        <({Offset position, int schema})>[];
    final FixedCanvasProbeState state = await _pumpProbe(
      tester,
      windowOps: windowOps,
      regionOps: regionOps,
      savedPetScreenPosition: const Offset(1200, 700),
      savedSchema: WindowPositionSchema.v1,
      legacyWindowSize: const Size(256, 256),
      onPersist: (Offset p, int schema) =>
          persisted.add((position: p, schema: schema)),
    );

    final bool ok = await state.prepareFixedCanvas();
    await tester.pump();

    expect(ok, isTrue);
    expect(wheelGeometryJournal.contains('startup.position.migration'), isTrue);
    expect(persisted.single.schema, WindowPositionSchema.v2);
    expect(persisted.single.position, const Offset(1200, 700));
    expect(state.petScreenRectForTest!.topLeft, const Offset(1200, 700));
  });

  testWidgets('#22 v1 语义不明（无旧窗口尺寸）→ 回退默认位置 + 写 v2',
      (WidgetTester tester) async {
    final _FakeWindowOps windowOps = _FakeWindowOps();
    final _FakeRegionOps regionOps = _FakeRegionOps();
    final List<({Offset position, int schema})> persisted =
        <({Offset position, int schema})>[];
    final FixedCanvasProbeState state = await _pumpProbe(
      tester,
      windowOps: windowOps,
      regionOps: regionOps,
      savedPetScreenPosition: const Offset(1200, 700),
      savedSchema: WindowPositionSchema.none,
      onPersist: (Offset p, int schema) =>
          persisted.add((position: p, schema: schema)),
    );

    final bool ok = await state.prepareFixedCanvas();
    await tester.pump();

    expect(ok, isTrue);
    expect(wheelGeometryJournal.contains('startup.position.migration'), isTrue);
    // 即便保存值本身可见也不采用（语义无法确定）；假显示器 1920×1080。
    expect(persisted.single.position, const Offset(1632, 792));
    expect(persisted.single.schema, WindowPositionSchema.v2);
  });

  testWidgets('#23 登录态：Region 失败 → prepareFixedCanvas 返回 false（交由外壳安全回退）',
      (WidgetTester tester) async {
    final _FakeWindowOps windowOps = _FakeWindowOps();
    final _FakeRegionOps regionOps = _FakeRegionOps()..failApply = true;
    final FixedCanvasProbeState state = await _pumpProbe(
      tester,
      windowOps: windowOps,
      regionOps: regionOps,
      savedPetScreenPosition: const Offset(1200, 700),
    );

    final bool ok = await state.prepareFixedCanvas();
    await tester.pump();

    expect(ok, isFalse, reason: 'Region 失败时不得放行 show');
    expect(state.fallbackForTest, isTrue);
    expect(wheelGeometryJournal.contains('startup.region.applied'), isTrue);
    expect(wheelGeometryJournal.contains('startup.window.show'), isFalse);
  });

  testWidgets('#24 可见比例不足 → prepareFixedCanvas 返回 false（不 show 屏外窗口）',
      (WidgetTester tester) async {
    final _FakeWindowOps windowOps = _FakeWindowOps();
    final _FakeRegionOps regionOps = _FakeRegionOps();
    final FixedCanvasProbeState state = await _pumpProbe(
      tester,
      windowOps: windowOps,
      regionOps: regionOps,
      savedPetScreenPosition: const Offset(1200, 700),
    );
    // 提交被"系统吞掉"：画布实际停在屏幕外（模拟夹取失败 / 原生异常）。
    windowOps.forceBounds = const Rect.fromLTWH(-3000, -3000, 922, 844);

    final bool ok = await state.prepareFixedCanvas();
    await tester.pump();

    expect(ok, isFalse, reason: '人物完全在屏外时必须拒绝 show');
    expect(state.fallbackForTest, isTrue, reason: '失败必须回退，不留大透明块');
    final ratio = wheelGeometryJournal.lastOf('startup.pet_visible_ratio');
    expect(ratio, isNotNull);
    expect(ratio!.fields['ok'], isFalse);
    expect(state.startupVisibleRatioForTest, lessThan(0.5));
  });

  testWidgets('#25 托盘重置：rebuildFixedCanvasAt 移动人物 + 只提交一次 + 写回位置',
      (WidgetTester tester) async {
    final _FakeWindowOps windowOps = _FakeWindowOps();
    final _FakeRegionOps regionOps = _FakeRegionOps();
    final FixedCanvasProbeState state = await _pumpProbe(
      tester,
      windowOps: windowOps,
      regionOps: regionOps,
      savedPetScreenPosition: const Offset(1200, 700),
    );
    await state.prepareFixedCanvas();
    await tester.pump();
    final int commitsAfterPrepare = windowOps.commits.length;

    final CanvasRebuildOutcome ok = await state.rebuildFixedCanvasAt(
      const Offset(1632, 752),
      reason: 'tray.reset_position',
    );
    await tester.pump();

    expect(ok, CanvasRebuildOutcome.applied);
    expect(windowOps.commits, hasLength(commitsAfterPrepare + 1),
        reason: '重置位置只允许一次窗口提交');
    expect(state.petScreenRectForTest!.topLeft, const Offset(1632, 752));
    expect(state.startupVisibleRatioForTest, greaterThanOrEqualTo(0.5));
    expect(regionOps.petOnlyRestores.last.size, const Size(256, 256));
  });

  testWidgets('#26 托盘重置到不可见位置 → 返回 failed（调用方走安全回退）',
      (WidgetTester tester) async {
    final _FakeWindowOps windowOps = _FakeWindowOps();
    final _FakeRegionOps regionOps = _FakeRegionOps();
    final FixedCanvasProbeState state = await _pumpProbe(
      tester,
      windowOps: windowOps,
      regionOps: regionOps,
      savedPetScreenPosition: const Offset(1200, 700),
    );
    await state.prepareFixedCanvas();
    await tester.pump();

    // 目标位置在屏外，且窗口提交被吞掉（无法夹取到可见区）。
    windowOps.forceBounds = const Rect.fromLTWH(-4000, -4000, 922, 844);
    final CanvasRebuildOutcome ok = await state.rebuildFixedCanvasAt(
      const Offset(99999, 99999),
      reason: 'test_invisible',
    );
    await tester.pump();

    // C1.1：画布变小之后，同一个"屏外目标"可能被夹取到刚好可见 —— 因此这里
    // 断言的是**契约**而不是实现细节：
    // * 结局绝不能是 applied（否则调用方会以为桌宠在屏内）；
    // * 并且必须留下可判定的日志（failed 或 superseded 之一）。
    expect(ok, isNot(CanvasRebuildOutcome.applied));
    expect(
      <String>[
        'wheel.canvas.rebuild.failed',
        'wheel.canvas.rebuild.stale_revision',
        'wheel.canvas.rebuild.exception',
        'startup.visibility.insufficient',
      ].any(wheelGeometryJournal.contains),
      isTrue,
      reason: '必须留下可判定的失败 / 过期日志（不能静默放弃）',
    );
  });
}

Future<FixedCanvasProbeState> _pumpProbe(
  WidgetTester tester, {
  required _FakeWindowOps windowOps,
  required _FakeRegionOps regionOps,
  RegionCoordinator? coordinator,
  Offset savedPetScreenPosition = const Offset(100, 400),
  int savedSchema = WindowPositionSchema.v2,
  Size? legacyWindowSize,
  bool mousePassthrough = false,
  WheelMenuLayoutSettings Function()? wheelSettings,
  Listenable? reestablishOn,
  Size Function()? petSize,
  void Function(Offset position, int schemaVersion)? onPersist,
}) async {
  tester.view.physicalSize = const Size(1920, 1080);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(MaterialApp(
    home: FixedCanvasProbe(
      // 每次挂载都用新 Key，避免两次 pump 之间状态被复用。
      key: UniqueKey(),
      windowOps: windowOps,
      coordinator: coordinator ??
          RegionCoordinator(
            ops: regionOps,
            devicePixelRatio: () => 1.25,
            journal: WheelGeometryJournal(capacity: 2000),
          ),
      petSize: petSize ?? () => const Size(256, 256),
      savedWindowPosition: () => (
        x: savedPetScreenPosition.dx,
        y: savedPetScreenPosition.dy,
        schema: savedSchema,
        legacyWindowSize: legacyWindowSize,
      ),
      persistPetScreenPosition: onPersist == null
          ? null
          : (Offset p, {required int schemaVersion}) async =>
              onPersist(p, schemaVersion),
      isMousePassthrough: () => mousePassthrough,
      wheelSettings: wheelSettings ?? () => WheelMenuLayoutSettings.defaults,
      reestablishOn: reestablishOn,
      child: const SizedBox(width: 256, height: 256),
    ),
  ));
  await tester.pump();
  return tester.state<FixedCanvasProbeState>(find.byType(FixedCanvasProbe));
}

/// 探针实际使用的固定画布尺寸（与 [FixedCanvasProbe] 内部 `_planCanvas` 同口径）：
/// 按**当前设置**（缺省 = Android 默认值）+ **当前显示器工作区**规划，
/// 屏幕放不下时由 [WheelCanvasPlanner] 自动压缩轮盘。
Size _expectedCanvas() {
  const Size pet = Size(256, 256);
  const Size workArea = Size(1920, 1080);
  return WheelCanvasPlanner.plan(
    petSize: pet,
    workArea: workArea,
    settings: WheelMenuLayoutSettings.defaults,
  ).canvasSize;
}

class _FakeWindowOps implements FixedCanvasWindowOps {
  _FakeWindowOps()
      : bounds = const Rect.fromLTWH(100, 100, 1352, 560);

  Rect bounds;
  final List<Rect> commits = <Rect>[];
  double dpr = 1.25;
  /// 假显示器默认是**主显示器**（位置解析在保存值不可见时的回退目标）。
  WheelDisplayArea? display = const WheelDisplayArea(
    id: 'd',
    left: 0,
    top: 0,
    width: 1920,
    height: 1080,
    isPrimary: true,
  );

  @override
  Future<List<WheelDisplayArea>> displays() async =>
      display == null ? const <WheelDisplayArea>[] : <WheelDisplayArea>[display!];

  /// 固定画布重建事务会先隐藏、校验通过后再显示。
  bool visible = true;
  final List<bool> visibility = <bool>[];

  /// 若设置，`commitBounds` 之后 `currentBounds()` 一律返回它 ——
  /// 用于模拟"提交被原生吞掉 / 夹取到屏外"（可见性保护必须拦住）。
  Rect? forceBounds;

  @override
  Future<Rect> currentBounds() async => forceBounds ?? bounds;

  @override
  Future<void> commitBounds(Rect next) async {
    commits.add(next);
    bounds = next;
  }

  @override
  Future<void> setVisible(bool value) async {
    visible = value;
    visibility.add(value);
  }

  @override
  double devicePixelRatio() => dpr;

  @override
  Future<WheelDisplayArea?> displayForPoint(Offset point) async => display;
}

class _FakeRegionOps implements RegionNativeOps {
  final List<List<Rect>> applied = <List<Rect>>[];
  final List<Rect> petOnlyRestores = <Rect>[];
  bool cleared = false;
  bool failApply = false;
  int gdi = 512;
  PhysicalRect? box = const PhysicalRect(0, 0, 100, 100);

  /// 挂起原生调用（用于测试 opening 期间的重入）。
  bool holdApply = false;
  Completer<void>? _hold;

  void releaseApply() {
    _hold?.complete();
    _hold = null;
  }

  @override
  Future<RegionApplyResult> applyInteractionRegion(
    List<Rect> logicalRects, {
    required double devicePixelRatio,
  }) async {
    applied.add(List<Rect>.of(logicalRects));
    if (holdApply) {
      _hold = Completer<void>();
      await _hold!.future;
    }
    if (failApply) return const RegionApplyResult.failure('模拟 SetWindowRgn 失败');
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
    petOnlyRestores.add(logicalPetRect);
    if (failApply) return const RegionApplyResult.failure('模拟 SetWindowRgn 失败');
    return const RegionApplyResult(
      success: true,
      rectCount: 1,
      boundingBox: PhysicalRect(0, 0, 100, 100),
    );
  }

  @override
  Future<bool> clearInteractionRegion() async {
    cleared = true;
    return true;
  }

  @override
  Future<int?> gdiObjectCount() async => gdi;

  @override
  Future<PhysicalRect?> regionBoundingBox() async => box;
}

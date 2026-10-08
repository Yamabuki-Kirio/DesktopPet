import 'dart:async';
import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:petlife/menu/fixed_canvas_contract.dart';
import 'package:petlife/menu/fixed_canvas_geometry.dart' show PhysicalRect;
import 'package:petlife/menu/region_coordinator.dart';
import 'package:petlife/menu/region_owner.dart';
import 'package:petlife/menu/wheel_geometry_ownership.dart' show WheelGeometryJournal;
import 'package:petlife/menu/wheel_interaction_state.dart';
import 'package:petlife/menu/windows_surface_mode.dart';

/// 本轮核心：**Region 所有权 + 异步事务代际**的纯逻辑用例。
///
/// 覆盖需求 §7 的 1/2/3/4/6/8/9 条，以及额外要求的：
/// contextMenu→wheel→panelTransition 连续抢占、await 返回时代际已变化、
/// apply 失败回滚、dispose 后晚到 Future 失效。
void main() {
  const Rect wholeCanvas = Rect.fromLTWH(0, 0, 1352, 560);
  const Rect petLocal = Rect.fromLTWH(548, 152, 256, 256);
  const Rect menuLocal = Rect.fromLTWH(828, 100, 360, 360);
  const List<Rect> petAndMenu = <Rect>[petLocal, menuLocal];
  const List<Rect> petOnly = <Rect>[petLocal];

  late _FakeRegionOps ops;
  late WheelGeometryJournal journal;
  late RegionCoordinator coordinator;

  setUp(() {
    windowsSurfaceSession.resetForTest();
    ops = _FakeRegionOps();
    journal = WheelGeometryJournal(capacity: 4000);
    coordinator = RegionCoordinator(
      ops: ops,
      devicePixelRatio: () => 1.0,
      journal: journal,
    );
  });

  tearDown(() {
    windowsSurfaceSession.resetForTest();
  });

  group('冷启动与基本开关', () {
    test('#6 左键冷启动直接打开：一次写入 pet+menu，owner=wheel', () async {
      final RegionCommitOutcome outcome = await coordinator.apply(
        owner: RegionOwner.wheel,
        rects: petAndMenu,
        source: 'wheel.open',
      );

      expect(outcome.status, RegionCommitStatus.applied);
      expect(outcome.success, isTrue);
      expect(coordinator.owner, RegionOwner.wheel);
      expect(ops.trace.last, 'apply:${petAndMenu.length}');
      expect(coordinator.appliedRects, petAndMenu);
      expect(coordinator.isSynchronized, isTrue);
    });

    test('#8 轮盘关闭后最终 owner=pet，且只用 restorePetOnlyRegion 写桌宠矩形', () async {
      final RegionCommitOutcome opened = await coordinator.apply(
        owner: RegionOwner.wheel,
        rects: petAndMenu,
        source: 'wheel.open',
      );
      final RegionCommitOutcome closed = await coordinator.restoreIfCurrent(
        opened.lease,
        owner: RegionOwner.pet,
        rects: petOnly,
        source: 'wheel.close',
      );

      expect(closed.status, RegionCommitStatus.applied);
      expect(coordinator.owner, RegionOwner.pet);
      expect(ops.trace.last, 'petOnly');
      expect(ops.petOnlyRestores.single, petLocal);
      expect(coordinator.isSynchronized, isTrue);
    });
  });

  group('右键 finally 与左键轮盘的竞态', () {
    test('#1 右键关闭后再开轮盘：旧 restore 被丢弃（dropped_stale）', () async {
      final RegionCommitOutcome opened = await coordinator.apply(
        owner: RegionOwner.contextMenu,
        rects: const <Rect>[wholeCanvas],
        source: 'context_menu.open',
      );
      final RegionLease contextLease = opened.lease;

      // 左键轮盘抢占（此时右键事务尚未 finally）。
      await coordinator.apply(
        owner: RegionOwner.wheel,
        rects: petAndMenu,
        source: 'wheel.open',
      );

      // 迟到的右键 restore：必须被丢弃。
      final RegionCommitOutcome late = await coordinator.restoreIfCurrent(
        contextLease,
        owner: RegionOwner.pet,
        rects: petOnly,
        source: 'context_menu.restore',
      );

      expect(late.status, RegionCommitStatus.droppedStale);
      expect(
        journal.contains('region.restore.dropped_stale'),
        isTrue,
        reason: '必须留下 dropped_stale 埋点',
      );
      // 关键：Region 仍是 pet+menu，没有被覆盖成 pet-only。
      expect(coordinator.appliedRects, petAndMenu);
      expect(coordinator.owner, RegionOwner.wheel);
    });

    test('#2 右键 finally 晚于 wheel apply 返回：不覆盖 wheel Region', () async {
      final RegionCommitOutcome opened = await coordinator.apply(
        owner: RegionOwner.contextMenu,
        rects: const <Rect>[wholeCanvas],
        source: 'context_menu.open',
      );

      // 先让 wheel 的 native apply 真正返回，再执行右键 finally。
      await coordinator.apply(
        owner: RegionOwner.wheel,
        rects: petAndMenu,
        source: 'wheel.open',
      );
      final int writesAfterWheel = ops.trace.length;

      await coordinator.restoreIfCurrent(
        opened.lease,
        owner: RegionOwner.pet,
        rects: petOnly,
        source: 'context_menu.restore',
      );

      expect(ops.trace.length, writesAfterWheel, reason: '过期恢复不得触发任何原生写入');
      expect(ops.trace.last, 'apply:2');
    });

    test('#3 轮盘打开时关闭右键事务：最终 owner=wheel', () async {
      final RegionCommitOutcome opened = await coordinator.apply(
        owner: RegionOwner.contextMenu,
        rects: const <Rect>[wholeCanvas],
        source: 'context_menu.open',
      );

      // beginOpen 的第一步：让 contextMenu 事务失效。
      coordinator.invalidateOwner(RegionOwner.contextMenu, source: 'wheel.beginOpen');
      final RegionCommitOutcome readFailed = await coordinator.restoreIfCurrent(
        opened.lease,
        owner: RegionOwner.pet,
        rects: petOnly,
        source: 'context_menu.restore',
      );
      expect(readFailed.status, RegionCommitStatus.droppedStale);

      final RegionCommitOutcome wheelOpened = await coordinator.apply(
        owner: RegionOwner.wheel,
        rects: petAndMenu,
        source: 'wheel.open',
      );

      expect(wheelOpened.status, RegionCommitStatus.applied);
      expect(coordinator.owner, RegionOwner.wheel);
      expect(coordinator.appliedRects, petAndMenu);
    });

    test('右键 owner 仍为 contextMenu 时，恢复是被允许的（未过期路径）', () async {
      final RegionCommitOutcome opened = await coordinator.apply(
        owner: RegionOwner.contextMenu,
        rects: const <Rect>[wholeCanvas],
        source: 'context_menu.open',
      );

      final RegionCommitOutcome restored = await coordinator.restoreIfCurrent(
        opened.lease,
        owner: RegionOwner.pet,
        rects: petOnly,
        source: 'context_menu.restore',
      );

      expect(restored.status, RegionCommitStatus.applied);
      expect(coordinator.owner, RegionOwner.pet);
      expect(ops.trace.last, 'petOnly');
    });
  });

  group('优先级与面板独占', () {
    test('#4 面板切换：旧 Region 事务全部失效，且 panelTransition 独占', () async {
      final RegionCommitOutcome wheelOpened = await coordinator.apply(
        owner: RegionOwner.wheel,
        rects: petAndMenu,
        source: 'wheel.open',
      );
      final RegionCommitOutcome contextOpened = await coordinator.apply(
        owner: RegionOwner.contextMenu,
        rects: const <Rect>[wholeCanvas],
        source: 'context_menu.open',
      );

      // 面板切换：先让所有事务失效，再由 panelTransition 清 Region。
      windowsSurfaceSession.changeTo(
        WindowsSurfaceMode.transitioningToPanel,
        source: 'test.enterPanel',
      );
      coordinator.invalidateAll(source: 'panel.enterPanel');
      final RegionCommitOutcome cleared = await coordinator.clear(
        owner: RegionOwner.panelTransition,
        source: 'panel.clear',
      );

      expect(cleared.status, RegionCommitStatus.cleared);
      expect(ops.trace.last, 'clear');
      expect(coordinator.owner, RegionOwner.panelTransition);
      expect(coordinator.isDesiredCleared, isTrue);

      // 旧的两个人都不许再写。
      expect(
        (await coordinator.restoreIfCurrent(
          wheelOpened.lease,
          owner: RegionOwner.pet,
          rects: petOnly,
          source: 'wheel.close',
        ))
            .status,
        RegionCommitStatus.droppedStale,
      );
      expect(
        (await coordinator.restoreIfCurrent(
          contextOpened.lease,
          owner: RegionOwner.pet,
          rects: petOnly,
          source: 'context_menu.restore',
        ))
            .status,
        RegionCommitStatus.droppedStale,
      );

      // 面板独占：wake 任何非面板 owner 都被拒绝。
      final RegionCommitOutcome blocked = await coordinator.apply(
        owner: RegionOwner.wheel,
        rects: petAndMenu,
        source: 'wheel.open',
      );
      expect(blocked.status, RegionCommitStatus.rejectedMode);
    });

    test('contextMenu 不能抢占已打开的 wheel（优先级）', () async {
      await coordinator.apply(
        owner: RegionOwner.wheel,
        rects: petAndMenu,
        source: 'wheel.open',
      );
      final RegionCommitOutcome rejected = await coordinator.apply(
        owner: RegionOwner.contextMenu,
        rects: const <Rect>[wholeCanvas],
        source: 'context_menu.open',
      );

      expect(rejected.status, RegionCommitStatus.rejectedLowerPriority);
      expect(coordinator.appliedRects, petAndMenu);
    });

    test('contextMenu → wheel → panelTransition 连续抢占，最终一致', () async {
      await coordinator.apply(
        owner: RegionOwner.contextMenu,
        rects: const <Rect>[wholeCanvas],
        source: 'cm',
      );
      await coordinator.apply(owner: RegionOwner.wheel, rects: petAndMenu, source: 'w');
      expect(coordinator.owner, RegionOwner.wheel);

      windowsSurfaceSession.changeTo(
        WindowsSurfaceMode.transitioningToPanel,
        source: 'test',
      );
      coordinator.invalidateAll(source: 'panel');
      await coordinator.clear(owner: RegionOwner.panelTransition, source: 'p');

      expect(coordinator.owner, RegionOwner.panelTransition);
      expect(coordinator.isSynchronized, isTrue);
      expect(ops.trace.last, 'clear');
    });
  });

  group('异步事务代际', () {
    test('native apply 已成功但 await 返回时代际已变化 → dropped_stale，不认领', () async {
      final Completer<void> gate = Completer<void>();
      ops.beforeApplyReturn = () => gate.future;

      final Future<RegionCommitOutcome> pending = coordinator.apply(
        owner: RegionOwner.wheel,
        rects: petAndMenu,
        source: 'wheel.open',
      );
      // 让 apply 真正进入原生调用（此时窗口 Region 可能已经被写入）。
      await Future<void>.delayed(Duration.zero);
      expect(ops.trace, <String>['apply:2'], reason: '原生已收到写入');

      // 面板切换抢占（代际 +1，并清 Region）。
      windowsSurfaceSession.changeTo(
        WindowsSurfaceMode.transitioningToPanel,
        source: 'test',
      );
      coordinator.invalidateAll(source: 'panel');
      gate.complete();

      final RegionCommitOutcome outcome = await pending;
      expect(outcome.status, RegionCommitStatus.droppedStale);
      expect(
        journal.contains('region.apply.dropped_stale'),
        isTrue,
        reason: 'await 返回后的校验必须留下埋点',
      );
      // 期望态最终由更高优先级 owner 决定，实际与期望保持一致。
      expect(coordinator.owner, RegionOwner.wheel);
      expect(coordinator.isSynchronized, isTrue);
    });

    test('apply 失败 → 期望态回滚到实际态，owner/Region 保持一致', () async {
      await coordinator.apply(
        owner: RegionOwner.wheel,
        rects: petAndMenu,
        source: 'wheel.open',
      );
      ops.failApply = true;

      final RegionCommitOutcome failed = await coordinator.apply(
        owner: RegionOwner.wheel,
        rects: <Rect>[petLocal, const Rect.fromLTWH(900, 100, 300, 300)],
        source: 'wheel.open.retry',
      );

      expect(failed.status, RegionCommitStatus.nativeFailure);
      expect(journal.contains('region.apply.failed'), isTrue);
      // 回滚：期望态 == 实际态（旧的 pet+menu）。
      expect(coordinator.appliedRects, petAndMenu);
      expect(coordinator.desiredRects, petAndMenu);
      expect(coordinator.isSynchronized, isTrue);
    });

    test('dispose 之后所有晚到 Future 都失效', () async {
      final Completer<void> gate = Completer<void>();
      ops.beforeApplyReturn = () => gate.future;

      final Future<RegionCommitOutcome> pending = coordinator.apply(
        owner: RegionOwner.wheel,
        rects: petAndMenu,
        source: 'wheel.open',
      );
      await Future<void>.delayed(Duration.zero);

      await coordinator.dispose();
      gate.complete();

      final RegionCommitOutcome outcome = await pending;
      expect(outcome.status, RegionCommitStatus.droppedStale);
      expect(coordinator.isDisposed, isTrue);

      // 后续任何提交都被拒绝，且不再触发原生写入。
      ops.trace.clear();
      final RegionCommitOutcome after = await coordinator.apply(
        owner: RegionOwner.wheel,
        rects: petAndMenu,
        source: 'late',
      );
      expect(after.status, RegionCommitStatus.rejectedDisposed);
      expect(ops.trace, isEmpty);
    });
  });

  group('#9 异常路径不留下整块画布 Region', () {
    test('失败回滚 + 条件恢复：最终不是 full-canvas', () async {
      final RegionCommitOutcome opened = await coordinator.apply(
        owner: RegionOwner.contextMenu,
        rects: const <Rect>[wholeCanvas],
        source: 'context_menu.open',
      );
      expect(coordinator.appliedRects.single, wholeCanvas);

      // 模拟"异常路径"：恢复被更晚的请求抢占 → 丢弃。
      coordinator.invalidateOwner(RegionOwner.contextMenu, source: 'wheel.beginOpen');
      final RegionCommitOutcome dropped = await coordinator.restoreIfCurrent(
        opened.lease,
        owner: RegionOwner.pet,
        rects: petOnly,
        source: 'context_menu.restore',
      );
      expect(dropped.status, RegionCommitStatus.droppedStale);

      // 由更高优先级 owner 收敛到非 full-canvas。
      final RegionCommitOutcome wheelOutcome = await coordinator.apply(
        owner: RegionOwner.wheel,
        rects: petAndMenu,
        source: 'w',
      );
      await coordinator.restoreIfCurrent(
        wheelOutcome.lease,
        owner: RegionOwner.pet,
        rects: petOnly,
        source: 'w.close',
      );

      expect(coordinator.appliedRects, petOnly);
      expect(coordinator.appliedRects.single, isNot(wholeCanvas));
      expect(coordinator.isSynchronized, isTrue);
    });

    test('clear 失败时保持可控（不谎报成功）', () async {
      await coordinator.apply(owner: RegionOwner.wheel, rects: petAndMenu, source: 'w');
      ops.failClear = true;

      final RegionCommitOutcome outcome = await coordinator.clear(
        owner: RegionOwner.panelTransition,
        source: 'panel.clear',
      );

      expect(outcome.status, RegionCommitStatus.nativeFailure);
      expect(coordinator.isSynchronized, isTrue, reason: '失败必须回滚到实际态');
      expect(coordinator.appliedRects, petAndMenu);
    });
  });

  group('三者一致性判定（纯函数）', () {
    test('wheel open 但 Region 不属于 wheel → 报不一致', () {
      expect(
        RegionUiConsistency.evaluate(
          owner: RegionOwner.pet,
          desiredCleared: false,
          wheelState: WheelInteractionState.open,
          contextMenuOpen: false,
        ),
        isNotNull,
      );
      expect(
        RegionUiConsistency.evaluate(
          owner: RegionOwner.wheel,
          desiredCleared: false,
          wheelState: WheelInteractionState.open,
          contextMenuOpen: false,
        ),
        isNull,
      );
    });

    test('过渡态不做判定；空闲态必须回到 pet', () {
      expect(
        RegionUiConsistency.evaluate(
          owner: RegionOwner.contextMenu,
          desiredCleared: false,
          wheelState: WheelInteractionState.opening,
          contextMenuOpen: false,
        ),
        isNull,
      );
      expect(
        RegionUiConsistency.evaluate(
          owner: RegionOwner.contextMenu,
          desiredCleared: false,
          wheelState: WheelInteractionState.closed,
          contextMenuOpen: false,
        ),
        isNotNull,
      );
      expect(
        RegionUiConsistency.evaluate(
          owner: RegionOwner.pet,
          desiredCleared: false,
          wheelState: WheelInteractionState.closed,
          contextMenuOpen: false,
        ),
        isNull,
      );
    });

    test('面板 owner 必须"无 Region"', () {
      expect(
        RegionUiConsistency.evaluate(
          owner: RegionOwner.panelTransition,
          desiredCleared: true,
          wheelState: WheelInteractionState.closed,
          contextMenuOpen: false,
        ),
        isNull,
      );
      expect(
        RegionUiConsistency.evaluate(
          owner: RegionOwner.panelTransition,
          desiredCleared: false,
          wheelState: WheelInteractionState.closed,
          contextMenuOpen: false,
        ),
        isNotNull,
      );
    });
  });
}

/// 假的原生 Region 能力：记录调用轨迹，可注入失败 / 挂起。
class _FakeRegionOps implements RegionNativeOps {
  final List<String> trace = <String>[];
  final List<List<Rect>> applies = <List<Rect>>[];
  final List<Rect> petOnlyRestores = <Rect>[];
  int clearCount = 0;
  bool failApply = false;
  bool failClear = false;
  Future<void> Function()? beforeApplyReturn;
  Future<void> Function()? beforeClearReturn;

  @override
  Future<RegionApplyResult> applyInteractionRegion(
    List<Rect> logicalRects, {
    required double devicePixelRatio,
  }) async {
    applies.add(List<Rect>.of(logicalRects));
    trace.add('apply:${logicalRects.length}');
    final Future<void> Function()? hook = beforeApplyReturn;
    if (hook != null) await hook();
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
    trace.add('petOnly');
    final Future<void> Function()? hook = beforeApplyReturn;
    if (hook != null) await hook();
    if (failApply) return const RegionApplyResult.failure('模拟 SetWindowRgn 失败');
    return const RegionApplyResult(
      success: true,
      rectCount: 1,
      boundingBox: PhysicalRect(0, 0, 100, 100),
    );
  }

  @override
  Future<bool> clearInteractionRegion() async {
    clearCount++;
    trace.add('clear');
    final Future<void> Function()? hook = beforeClearReturn;
    if (hook != null) await hook();
    return !failClear;
  }

  @override
  Future<int?> gdiObjectCount() async => 512;

  @override
  Future<PhysicalRect?> regionBoundingBox() async => null;
}

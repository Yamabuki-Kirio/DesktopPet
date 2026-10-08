import 'dart:ui' show Offset, Rect, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:petlife/menu/wheel_geometry.dart';
import 'package:petlife/menu/wheel_geometry_ownership.dart';
import 'package:petlife/menu/wheel_measurement_gate.dart';
import 'package:petlife/menu/wheel_open_transaction.dart';
import 'package:petlife/menu/wheel_window_ops.dart';

/// 增量 A 修复：轮盘**打开 / 关闭几何事务**的纯 Dart 用例。
///
/// 用假 [WheelWindowOps] 驱动，覆盖需求点名的场景：
/// 第一次单击就正确打开、测量无效不提交、两帧稳定只提交一次、失败全量回滚、
/// 连点只允许一个事务、关闭后旧代际失效、诊断模式不改变窗口行为。
void main() {
  const Rect petRect = Rect.fromLTWH(600, 400, 256, 192);
  const Size stableMenu = Size(320, 320);

  late _FakeOps ops;
  late WheelSurfaceGeometry surface;
  late WheelGeometryJournal journal;

  setUp(() {
    ops = _FakeOps(petRect);
    journal = WheelGeometryJournal();
    surface = WheelSurfaceGeometry(journal: journal);
  });

  WheelOpenTransaction buildTransaction({bool diagnostics = false}) =>
      WheelOpenTransaction(
        ops: ops,
        waitForFrame: () async {},
        surface: surface,
        journal: journal,
        diagnosticsEnabled: () => diagnostics,
        minMenuSide: 64,
        menuGap: 12,
      );

  Future<WheelOpenTransaction> openedWith({bool diagnostics = false}) async {
    final WheelOpenTransaction tx = buildTransaction(diagnostics: diagnostics);
    final WheelOpenRequest request = await tx.beginOpen();
    expect(request.accepted, isTrue);
    expect(tx.offerMenuMeasurement(stableMenu), WheelMeasureOutcome.pending);
    expect(tx.offerMenuMeasurement(stableMenu), WheelMeasureOutcome.stable);
    return tx;
  }

  test('#5 第一次单击即可正确打开（无需第二次点击），且只提交一次 setBounds', () async {
    final WheelOpenTransaction tx = await openedWith();
    final WheelOpenOutcome outcome = await tx.commitOpen();

    expect(outcome.opened, isTrue, reason: outcome.reason);
    expect(tx.phase, WheelOpenPhase.open);
    expect(tx.isOpen, isTrue);
    expect(surface.owner, WindowsSurfaceGeometryOwner.wheel);
    expect(ops.commitCount, 1, reason: '一次打开只允许一次 setBounds');
    expect(ops.commits.single.width, greaterThanOrEqualTo(petRect.width));
    expect(journal.contains('wheel.present'), isTrue);
    expect(journal.contains('wheel.bounds.commit.success'), isTrue);
  });

  test('#4 连续两帧稳定后只提交一次；再次 commit 不会产生第二次写入', () async {
    final WheelOpenTransaction tx = await openedWith();
    await tx.commitOpen();
    await tx.commitOpen(); // 状态已不是 committing
    expect(ops.commitCount, 1);
  });

  test('#3 首帧 0 / 1×1：菜单不显示、绝不提交任何尺寸', () async {
    final WheelOpenTransaction tx = buildTransaction();
    final WheelOpenRequest request = await tx.beginOpen();
    expect(request.accepted, isTrue);

    expect(tx.offerMenuMeasurement(const Size(1, 1)), WheelMeasureOutcome.invalid);
    expect(tx.offerMenuMeasurement(Size.zero), WheelMeasureOutcome.invalid);
    expect(tx.phase, WheelOpenPhase.measuring);
    expect(tx.isOpen, isFalse);

    final WheelOpenOutcome outcome = await tx.commitOpen();
    expect(outcome.opened, isFalse);
    expect(ops.commitCount, 0, reason: '测量无效时绝不允许提交窗口矩形');
  });

  test('#7 打开失败（回读偏差过大）→ 完整回滚桌宠与窗口', () async {
    ops.actualAfterCommit = (Rect requested) {
      // 第一次提交（放大）后，窗口被"第三者"缩回 / 改错。
      if (ops.commitCount == 1) {
        return Rect.fromLTWH(requested.left + 500, requested.top + 500, 256, 192);
      }
      return requested;
    };

    final WheelOpenTransaction tx = await openedWith();
    final WheelOpenOutcome outcome = await tx.commitOpen();

    expect(outcome.opened, isFalse);
    expect(outcome.reason, contains('偏差'));
    expect(surface.owner, WindowsSurfaceGeometryOwner.pet, reason: '失败后必须回到 pet');
    expect(tx.isOpen, isFalse);
    expect(ops.commitCount, 2, reason: '一次放大 + 一次回滚还原');
    expect(ops.commits.last, petRect, reason: '回滚必须还原到原始窗口矩形');
    expect(journal.contains('wheel.rollback'), isTrue);
    expect(journal.contains('wheel.bounds.commit.failed'), isTrue);
  });

  test('#7b 提交抛异常 → 回滚并还原', () async {
    ops.throwOnFirstCommit = true;
    final WheelOpenTransaction tx = await openedWith();
    final WheelOpenOutcome outcome = await tx.commitOpen();

    expect(outcome.opened, isFalse);
    expect(surface.owner, WindowsSurfaceGeometryOwner.pet);
    expect(ops.commits.last, petRect);
  });

  test('#8 快速连点：只允许一个打开事务', () async {
    final WheelOpenTransaction tx = buildTransaction();
    final WheelOpenRequest first = await tx.beginOpen(); // 见下：先同步占用
    final WheelOpenRequest second = await tx.beginOpen();
    expect(first.accepted, isTrue);
    expect(second.accepted, isFalse);
    expect(second.reason, contains('正在进行'));
  });

  test('#8b 未 await 的并发 beginOpen 也只有一个被接受（_reserved 同步占位）', () async {
    final WheelOpenTransaction tx = buildTransaction();
    final Future<WheelOpenRequest> a = tx.beginOpen();
    final Future<WheelOpenRequest> b = tx.beginOpen();
    final List<WheelOpenRequest> results =
        await Future.wait(<Future<WheelOpenRequest>>[a, b]);
    expect(results.where((WheelOpenRequest r) => r.accepted).length, 1);
  });

  test('#关闭：还原矩形 + 回读验证 + owner 回到 pet', () async {
    final WheelOpenTransaction tx = await openedWith();
    await tx.commitOpen();
    final int generationAtOpen = surface.generation;

    tx.beginClose();
    expect(tx.phase, WheelOpenPhase.closing);
    expect(surface.owner, WindowsSurfaceGeometryOwner.wheelTransition);

    final WheelCloseOutcome outcome = await tx.finishClose();
    expect(outcome.restored, isTrue);
    expect(surface.owner, WindowsSurfaceGeometryOwner.pet);
    expect(ops.commits.last, petRect);
    expect(journal.contains('wheel.close.start'), isTrue);
    expect(journal.contains('wheel.close.complete'), isTrue);

    // #10 关闭后，旧代际的延迟回调不能改窗口。
    final String? drop = PetResizeDecision.evaluate(
      mounted: true,
      scheduledGeneration: generationAtOpen,
      surface: surface,
    );
    expect(drop, 'generation_changed');
  });

  test('#11 关闭后正常尺寸跟随仍然可用（新代际、owner=pet）', () async {
    final WheelOpenTransaction tx = await openedWith();
    await tx.commitOpen();
    tx.beginClose();
    await tx.finishClose();

    final String? drop = PetResizeDecision.evaluate(
      mounted: true,
      scheduledGeneration: surface.generation,
      surface: surface,
    );
    expect(drop, isNull);
    expect(surface.allowsPetResize, isTrue);
  });

  test('#9 打开过程中（过渡期）所有权不被素材变化抢走', () async {
    final WheelOpenTransaction tx = buildTransaction();
    await tx.beginOpen();
    // 过渡期：pet 尺寸跟随被禁止。
    expect(surface.allowsPetResize, isFalse);
    expect(surface.isTransitioning, isTrue);
    // 即便此刻有人尝试 pet resize，判定也必须是"丢弃"。
    expect(
      PetResizeDecision.evaluate(
        mounted: true,
        scheduledGeneration: surface.generation,
        surface: surface,
      ),
      'owner_wheel_transition',
    );
  });

  test('#6 诊断模式开关不改变窗口几何行为', () async {
    final WheelOpenTransaction plain = await openedWith(diagnostics: false);
    final WheelOpenOutcome plainOutcome = await plain.commitOpen();

    final _FakeOps ops2 = _FakeOps(petRect);
    final WheelGeometryJournal journal2 = WheelGeometryJournal();
    final WheelSurfaceGeometry surface2 = WheelSurfaceGeometry(journal: journal2);
    final WheelOpenTransaction debug = WheelOpenTransaction(
      ops: ops2,
      waitForFrame: () async {},
      surface: surface2,
      journal: journal2,
      diagnosticsEnabled: () => true,
      minMenuSide: 64,
      menuGap: 12,
    );
    await debug.beginOpen();
    debug.offerMenuMeasurement(stableMenu);
    debug.offerMenuMeasurement(stableMenu);
    final WheelOpenOutcome debugOutcome = await debug.commitOpen();

    expect(debugOutcome.opened, plainOutcome.opened);
    expect(ops2.commits, ops.commits);
    expect(ops2.commitCount, 1);
    // 诊断模式只增加逐帧事件，不改变几何。
    expect(journal2.countOf('wheel.measure.frame'), greaterThan(0));
    expect(journal.countOf('wheel.measure.frame'), 0);
  });

  test('测量超时前 abort 会回滚窗口并放弃事务', () async {
    final WheelOpenTransaction tx = buildTransaction();
    await tx.beginOpen();
    tx.offerMenuMeasurement(const Size(1, 1));
    await tx.abort();
    expect(tx.isOpen, isFalse);
    expect(tx.isBusy, isFalse);
    expect(surface.owner, WindowsSurfaceGeometryOwner.pet);
    expect(ops.commits.last, petRect);
    expect(journal.contains('wheel.rollback'), isTrue);
  });
}

/// 假窗口操作：记录每次 `commitBounds`，并可模拟"提交后被改错 / 抛错"。
class _FakeOps implements WheelWindowOps {
  _FakeOps(this._bounds);

  Rect _bounds;
  Rect Function(Rect requested)? actualAfterCommit;
  bool throwOnFirstCommit = false;

  final List<Rect> commits = <Rect>[];

  int get commitCount => commits.length;

  WheelDisplayArea? display =
      const WheelDisplayArea(id: 'DISPLAY1', left: 0, top: 0, width: 1920, height: 1080);

  @override
  Future<Rect> currentBounds() async => _bounds;

  @override
  Future<void> commitBounds(Rect bounds) async {
    commits.add(bounds);
    if (throwOnFirstCommit && commits.length == 1) {
      throw StateError('模拟提交失败');
    }
    _bounds = actualAfterCommit?.call(bounds) ?? bounds;
  }

  @override
  double devicePixelRatio() => 1.0;

  @override
  Future<WheelDisplayArea?> displayForPoint(Offset point) async => display;
}

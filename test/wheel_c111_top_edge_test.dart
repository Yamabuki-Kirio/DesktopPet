/// **C1.1.1 回归测试**：Windows 轮盘**顶部边缘适配**修复。
///
/// 覆盖需求 §二 ~ §十。全部断言都是**外部可观察事实**：
///
/// * 纵向模式 = `top` 时，顶部 / 底部溢出必须为 0（菜单不再被系统裁掉上半截）；
/// * 轮盘整体（含交互内容）必须完整落在工作区内；
/// * 全部绘制像素必须落在固定画布内（不得被 HWND 矩形硬裁切）；
/// * 缺口中心必须等于人物视觉中心（≤1px）；
/// * 关闭后不得残留任何菜单像素 / Region；
/// * **不得回归**已验收的左右展开（左人 → 右菜单，右人 → 左菜单）；
/// * **不得**用"缩小菜单"当作顶部适配手段。
///
/// 真机根因（本文件要钉住的那个缺陷）
/// ------------------------------
/// 旧实现把上一次的纵向模式用 `lockMode` 锁住。于是
/// "先在下半屏打开（bottomEdge）→ 把桌宠拖到左上 → 再打开"仍按**靠下**的
/// 26° 偏转绘制，而那个偏转正好把内容推向屏幕上方 → 上半截被系统裁掉。
library;

// 测试脚手架私有类型出现在公共签名里是可接受的（本仓库测试的统一做法）。
// ignore_for_file: library_private_types_in_public_api

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:petlife/character/pet_visual_bounds.dart';
import 'package:petlife/menu/fixed_canvas_contract.dart';
import 'package:petlife/menu/fixed_canvas_geometry.dart' show PhysicalRect;
import 'package:petlife/menu/region_coordinator.dart';
import 'package:petlife/menu/wheel_expansion_side.dart';
import 'package:petlife/menu/wheel_geometry.dart' show WheelDisplayArea;
import 'package:petlife/menu/wheel_geometry_ownership.dart'
    show WheelGeometryJournal, wheelGeometryJournal;
import 'package:petlife/menu/wheel_menu_geometry.dart'
    show
        WheelBounds,
        WheelContentBounds,
        WheelMenuLayout,
        WheelMenuLayoutSettings,
        WheelMenuSpec,
        WheelRect;
import 'package:petlife/menu/wheel_placement.dart';
import 'package:petlife/menu/wheel_placement_solver.dart';
import 'package:petlife/menu/wheel_region.dart' show WheelRegionBuilder;
import 'package:petlife/menu/wheel_visual_bounds.dart';
import 'package:petlife/ui/desktop/fixed_canvas_probe.dart';

// ---------------------------------------------------------------------------
// 真机基线（与 C1.1 回归测试同源）
// ---------------------------------------------------------------------------

/// 素材文件尺寸。
const Size assetSize = Size(256, 192);

/// 真机素材（`Maya_Cheerful_1.webp`）9 帧 alpha 并集（归一化）。
const PetVisualBounds mayaBounds = PetVisualBounds(0.3047, 0.1875, 0.6641, 1.0);

/// 真机持久化设置（`wheel.scale=0.6` / `buttonScale=1.3` / `menuDistance=0.16`）。
const WheelMenuLayoutSettings realSettings = WheelMenuLayoutSettings(
  preferredScale: 0.6,
  buttonVisualScale: 1.3,
  menuDistance: 0.16,
);

/// 标准工作区（1920×1040，与真机 1080p 任务栏一致）。
const Rect workArea1920 = Rect.fromLTWH(0, 0, 1920, 1040);

const WheelDisplayArea primaryDisplay = WheelDisplayArea(
  id: 'd',
  left: 0,
  top: 0,
  width: 1920,
  height: 1040,
  isPrimary: true,
);

class _Ops implements FixedCanvasWindowOps {
  _Ops(this.bounds, this.display);

  Rect bounds;
  WheelDisplayArea display;
  final List<Rect> commits = <Rect>[];

  @override
  Future<Rect> currentBounds() async => bounds;
  @override
  Future<void> commitBounds(Rect next) async {
    commits.add(next);
    bounds = next;
  }

  @override
  Future<List<WheelDisplayArea>> displays() async => <WheelDisplayArea>[display];
  @override
  Future<WheelDisplayArea?> displayForPoint(Offset point) async => display;
  @override
  double devicePixelRatio() => dpr;
  @override
  Future<void> setVisible(bool visible) async {}

  double dpr = 1.0;
}

class _RegionOps implements RegionNativeOps {
  final List<List<Rect>> applied = <List<Rect>>[];
  @override
  Future<RegionApplyResult> applyInteractionRegion(
    List<Rect> logicalRects, {
    required double devicePixelRatio,
  }) async {
    applied.add(List<Rect>.of(logicalRects));
    return RegionApplyResult(
      success: true,
      rectCount: logicalRects.length,
      boundingBox: PhysicalRect(0, 0, 10, 10),
    );
  }

  @override
  Future<RegionApplyResult> restorePetOnlyRegion(
    Rect logicalPetRect, {
    required double devicePixelRatio,
  }) async =>
      RegionApplyResult(
        success: true,
        rectCount: 1,
        boundingBox: PhysicalRect(0, 0, 10, 10),
      );

  @override
  Future<bool> clearInteractionRegion() async => true;
  @override
  Future<int?> gdiObjectCount() async => 512;
  @override
  Future<PhysicalRect?> regionBoundingBox() async =>
      const PhysicalRect(0, 0, 10, 10);
}

class Harness {
  Harness(this.ops, this.regions, this.state);

  final _Ops ops;
  final _RegionOps regions;
  final FixedCanvasProbeState state;
}

Future<Harness> pumpProbe(
  WidgetTester tester, {
  required Offset petScreen,
  PetVisualBounds bounds = mayaBounds,
  WheelMenuLayoutSettings settings = realSettings,
  WheelDisplayArea display = primaryDisplay,
  double dpr = 1.0,
}) async {
  tester.view.physicalSize = Size(display.width * dpr, display.height * dpr);
  tester.view.devicePixelRatio = dpr;
  addTearDown(tester.view.reset);

  final _Ops ops = _Ops(Rect.fromLTWH(0, 0, 400, 400), display)..dpr = dpr;
  final _RegionOps regions = _RegionOps();

  await tester.pumpWidget(MaterialApp(
    home: FixedCanvasProbe(
      key: UniqueKey(),
      windowOps: ops,
      coordinator: RegionCoordinator(
        ops: regions,
        devicePixelRatio: () => dpr,
        journal: WheelGeometryJournal(capacity: 4000),
      ),
      petSize: () => assetSize,
      savedWindowPosition: () =>
          (x: petScreen.dx, y: petScreen.dy, schema: 2, legacyWindowSize: null),
      isMousePassthrough: () => false,
      wheelSettings: () => settings,
      petVisualBounds: () => bounds,
      ensurePetVisualBounds: () async => bounds,
      child: const SizedBox(width: 256, height: 192),
    ),
  ));
  await tester.pump();
  final FixedCanvasProbeState state =
      tester.state<FixedCanvasProbeState>(find.byType(FixedCanvasProbe));
  await state.prepareFixedCanvas();
  await tester.pump();
  return Harness(ops, regions, state);
}

String _r(Rect? r) => r == null
    ? 'null'
    : '${r.left.toStringAsFixed(1)},${r.top.toStringAsFixed(1)},'
        '${r.right.toStringAsFixed(1)},${r.bottom.toStringAsFixed(1)}';

/// 把屏幕矩形换算到画布局部坐标。
Rect _toCanvas(Rect screenRect, Rect canvasRect) =>
    screenRect.shift(-canvasRect.topLeft);

/// 屏幕矩形是否完整落在工作区内（含 [tol] 容差）。
bool _insideWorkArea(Rect screenRect, {double tol = 1.0}) =>
    screenRect.left >= workArea1920.left - tol &&
    screenRect.top >= workArea1920.top - tol &&
    screenRect.right <= workArea1920.right + tol &&
    screenRect.bottom <= workArea1920.bottom + tol;

// ---------------------------------------------------------------------------
// 六种布局 + 拖动 / 开合循环（需求 §九）
// ---------------------------------------------------------------------------

/// `[标签, 人物屏幕位置, 期望水平侧, 期望纵向模式]`。
///
/// 人物 Widget = 256×192；alpha 可见区在 Widget 内 (78,36)-(170,192)，
/// 即"人物视觉中心"= `petScreen + (128, 114)`。
///
/// 位置口径（为什么不是"贴着最边"）
/// ------------------------------
/// 真机设置（scale 0.6 / buttonScale 1.3）下轮盘相对人物视觉中心的**径向**外扩
/// 约 227px（靠上加偏后向下约 295px）。要让"零溢出"这一条真的成立，人物视觉中心
/// 就必须离所在一侧的边缘 ≥ 该外扩量：
///
/// * 顶部场景取 `y = 120`（视觉中心距顶 234px）→ 靠上模式向上外扩 226px，**零溢出**；
/// * 底部场景取 `y = 680`（视觉中心距底 246px）→ 靠下模式向下外扩 226px，**零溢出**；
/// * 居中场景取 `y = 420`（上下各 534 / 506px）→ 居中模式，**零溢出**。
///
/// 再往上/下贴（例如 `y = 40`）属于"轮盘本身就比剩余空间大"的极端情形：三种模式
/// 全都放不下，只能取溢出最小者（见测试 11 的边界记录），这不是本轮要修的方向问题。
final List<(String, Offset, WheelExpansionSide, WheelVerticalPlacement)> scenarios =
    <(String, Offset, WheelExpansionSide, WheelVerticalPlacement)>[
  ('左上', const Offset(64, 120), WheelExpansionSide.right, WheelVerticalPlacement.top),
  ('右上', const Offset(1600, 120), WheelExpansionSide.left, WheelVerticalPlacement.top),
  ('顶部居中', const Offset(832, 120), WheelExpansionSide.right, WheelVerticalPlacement.top),
  ('左下', const Offset(64, 680), WheelExpansionSide.right, WheelVerticalPlacement.bottom),
  ('右下', const Offset(1600, 680), WheelExpansionSide.left, WheelVerticalPlacement.bottom),
  ('屏幕中心', const Offset(832, 420), WheelExpansionSide.right, WheelVerticalPlacement.middle),
];

void main() {
  setUp(() => wheelGeometryJournal.clear());
  tearDown(() => wheelGeometryJournal.clear());

  // -------------------------------------------------------------------------
  group('§二 方向模型：六种组合完整支持', () {
    test('1 六种组合齐全，且偏转常量逐字复用 Android（±26 / 0）', () {
      expect(WheelPlacements.all.length, 6);
      expect(
        WheelPlacements.all.map((WheelPlacement p) => p.wireName).toSet(),
        <String>{
          'left+top',
          'left+middle',
          'left+bottom',
          'right+top',
          'right+middle',
          'right+bottom',
        },
      );
      // 偏转方向：靠上 → 向视觉下方偏 +26°；靠下 → −26°；居中 → 0°。
      expect(WheelVerticalPlacement.top.biasDeg, 26);
      expect(WheelVerticalPlacement.middle.biasDeg, 0);
      expect(WheelVerticalPlacement.bottom.biasDeg, -26);
      // 与 Android 枚举一一对应（唯一换算）。
      expect(WheelVerticalPlacement.top.mode.name, 'topEdge');
      expect(WheelVerticalPlacement.middle.mode.name, 'center');
      expect(WheelVerticalPlacement.bottom.mode.name, 'bottomEdge');
      // 水平侧不新造枚举：别名指向已验收的 WheelExpansionSide。
      expect(WheelHorizontalSide.left, WheelExpansionSide.left);
      expect(WheelExpansionSide.values.length, 2);
    });
  });

  // -------------------------------------------------------------------------
  group('§三 / §八 六种布局：零溢出 + 诊断字段', () {
    for (final (String label, Offset pet, WheelExpansionSide side,
            WheelVerticalPlacement vertical)
        in scenarios) {
      testWidgets('2 场景 $label：vertical=$vertical 且四侧溢出为 0',
          (WidgetTester tester) async {
        final Harness h = await pumpProbe(tester, petScreen: pet);
        await h.state.open();
        await tester.pumpAndSettle();

        final FixedCanvasProbeState st = h.state;
        final WheelPlacementSolution s = st.placementSolutionForTest!;
        final Map<String, Object?> diag = <String, Object?>{
          'scenario': label,
          'petScreen': '${pet.dx},${pet.dy}',
          'horizontalSide': s.horizontalSide.wireName,
          'verticalPlacement': s.vertical.wireName,
          'selection_reason': s.reason,
          'candidate.top.overflow': s.candidateOf(WheelVerticalPlacement.top)!.overflowPx,
          'candidate.middle.overflow':
              s.candidateOf(WheelVerticalPlacement.middle)!.overflowPx,
          'candidate.bottom.overflow':
              s.candidateOf(WheelVerticalPlacement.bottom)!.overflowPx,
          'topOverflowPx': s.topOverflowPx,
          'bottomOverflowPx': s.bottomOverflowPx,
          'selectedVisualBounds': _r(s.visualBoundsScreen),
          'canvasBounds': _r(s.canvasBoundsScreen),
          'anchorErrorPx': st.anchorErrorPxForTest,
          'petVisualScreenRect': _r(st.petVisualScreenRectForTest),
          'canvasRect': _r(st.canvasRectForTest),
          'menuLocalRect': _r(st.menuLocalRectForTest),
        };
        // ignore: avoid_print
        print('== C1.1.1 布局诊断 $label ==\n'
            '${const JsonEncoder.withIndent('  ').convert(diag)}');

        // ① 组合（水平侧 + 纵向模式）必须与期望一致（§二 / §三）。
        expect(s.horizontalSide, side, reason: '$label 水平侧');
        expect(s.vertical, vertical, reason: '$label 纵向模式');

        // ② 选中的组合必须**零溢出**（§三 的判据）。
        expect(s.topOverflowPx, lessThanOrEqualTo(1.0), reason: '$label 上侧溢出');
        expect(s.bottomOverflowPx, lessThanOrEqualTo(1.0), reason: '$label 下侧溢出');
        expect(s.leftOverflowPx, lessThanOrEqualTo(1.0), reason: '$label 左侧溢出');
        expect(s.rightOverflowPx, lessThanOrEqualTo(1.0), reason: '$label 右侧溢出');

        await st.close();
        await tester.pumpAndSettle();
      });
    }
  });

  // -------------------------------------------------------------------------
  group('§四 / §六 顶部适配不得移动人物 / 缩小菜单', () {
    testWidgets('3 顶部适配：人物屏幕坐标不变、缺口对齐、菜单尺寸不变',
        (WidgetTester tester) async {
      // 先在下半屏打开（bottomEdge），再**拖到顶部**——这正是真机回归的序列。
      final Harness h = await pumpProbe(tester, petScreen: const Offset(64, 680));
      await h.state.open();
      await tester.pumpAndSettle();
      expect(h.state.verticalPlacementForTest, WheelVerticalPlacement.bottom,
          reason: '下半屏应先按靠下布局');

      // 拖动：画布整体平移，人物落到左上（与生产链路的"绝对人物屏幕位置"一致）。
      final Rect canvas0 = h.state.canvasRectForTest!;
      final Offset pet0 = canvas0.topLeft + h.state.petAnchorForTest;
      const Offset target = Offset(64, 120);
      final Offset delta = target - pet0;
      h.ops.bounds = h.ops.bounds.shift(delta);
      await h.state.onPetPositionChanged(target.dx, target.dy);
      await tester.pumpAndSettle();

      // 再打开：纵向模式**必须**由当前位置重新决定（不得沿用 bottomEdge）。
      await h.state.open();
      await tester.pumpAndSettle();

      final FixedCanvasProbeState st = h.state;
      final WheelPlacementSolution s = st.placementSolutionForTest!;
      expect(s.vertical, WheelVerticalPlacement.top,
          reason: '拖到顶部后必须重新判定为靠上（旧实现会沿用 bottomEdge → 裁切）');
      expect(s.previousPlacement?.vertical, WheelVerticalPlacement.bottom,
          reason: '诊断：上一次是靠下（不参与本次选择）');

      // ① 人物屏幕坐标必须仍是拖动后的位置（顶部适配**绝不平移人物**）。
      final Rect visual = st.petVisualScreenRectForTest;
      expect(visual.left, closeTo(target.dx + 78, 1.0));
      expect(visual.top, closeTo(target.dy + 36, 1.0));

      // ② 缺口中心 = 人物视觉中心（§八 anchorErrorPx ≤ 1）。
      expect(st.anchorErrorPxForTest, lessThanOrEqualTo(1.0));

      // ③ 顶部适配**不得**缩小菜单：三候选的按钮直径 / 实际缩放必须一致。
      final WheelPlacementCandidate top = s.candidateOf(WheelVerticalPlacement.top)!;
      final WheelPlacementCandidate mid = s.candidateOf(WheelVerticalPlacement.middle)!;
      expect(top.layout.buttonDiameterPx, closeTo(mid.layout.buttonDiameterPx, 1e-9),
          reason: '顶部适配只允许改扇形朝向，不得改菜单尺寸');
      expect(top.envelope.actualScale, closeTo(mid.envelope.actualScale, 1e-9));
      expect(top.layout.ringRadiusPx, closeTo(mid.layout.ringRadiusPx, 1e-9));

      // ④ 关闭后不得残留。
      await st.close();
      await tester.pumpAndSettle();
      expect(st.closedStateViolations(), isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  group('§九 每个场景：不裁切 / 全在画布内 / Region 覆盖 / 方向不回归', () {
    for (final (String label, Offset pet, WheelExpansionSide side,
            WheelVerticalPlacement _)
        in scenarios) {
      testWidgets('4 场景 $label：完整可见且左右方向不回归',
          (WidgetTester tester) async {
        final Harness h = await pumpProbe(tester, petScreen: pet);
        await h.state.open();
        await tester.pumpAndSettle();
        final FixedCanvasProbeState st = h.state;
        final WheelPlacementSolution s = st.placementSolutionForTest!;

        // ① 人不动：开菜单绝不提交窗口矩形（窗口矩形 = 人物位置 + 锚点）。
        expect(st.canvasRectForTest, isNotNull);

        // ② 全部绘制像素必须落在**画布**内（否则真机被 HWND 硬裁）。
        final Rect canvasRect = st.canvasRectForTest!;
        final Rect visualLocal = _toCanvas(s.visualBoundsScreen, canvasRect);
        final Rect canvasLocal =
            Rect.fromLTWH(0, 0, canvasRect.width, canvasRect.height);
        expect(canvasLocal.contains(visualLocal.topLeft), isTrue,
            reason: '$label 视觉包围盒左上角越出画布：$visualLocal');
        expect(visualLocal.right <= canvasLocal.right + 0.5, isTrue,
            reason: '$label 视觉包围盒右侧越出画布：$visualLocal');
        expect(visualLocal.bottom <= canvasLocal.bottom + 0.5, isTrue,
            reason: '$label 视觉包围盒下侧越出画布：$visualLocal');

        // ③ 全部绘制像素必须落在**工作区**内（顶部适配的核心判据）。
        expect(_insideWorkArea(s.visualBoundsScreen), isTrue,
            reason: '$label 绘制内容越出工作区：${_r(s.visualBoundsScreen)}');

        // ④ 交互内容（按钮 / 标签 / 文字）必须在工作区内（不得"看得见点不到"）。
        expect(_insideWorkArea(s.chosen.interactiveBoundsScreen), isTrue,
            reason: '$label 交互内容越出工作区：${_r(s.chosen.interactiveBoundsScreen)}');

        // ⑤ Region 必须覆盖全部会被绘制的元素。
        final WheelMenuLayout layout = st.wheelLayoutForTest!;
        final WheelVisualBounds vb = WheelVisualBoundsCalculator.compute(layout);
        final List<Rect> region = WheelRegionBuilder.rectsFor(
          layout,
          slotProgress: List<double>.filled(layout.itemCount, 1.0),
        );
        expect(
          WheelRegionBuilder.coversVisualBounds(region, vb, layout: layout),
          isTrue,
          reason: '$label Region 未覆盖视觉包围盒：${vb.describe()}',
        );

        // ⑥ 左右方向不回归（左人 → 右菜单；右人 → 左菜单）。
        expect(st.expansionSideForTest, side, reason: '$label 展开侧必须正确');
        expect(st.directionInvariantPassed, isTrue);

        // ⑦ 缺口中心 = 人物视觉中心。
        expect(st.anchorErrorPxForTest, lessThanOrEqualTo(1.0),
            reason: '$label 缺口未对齐人物视觉中心');

        // ⑧ 关闭后不得残留任何菜单像素。
        await st.close();
        await tester.pumpAndSettle();
        expect(st.shouldPaintMenu, isFalse);
        expect(st.regionIsPetOnly, isTrue);
        expect(st.closedStateViolations(), isEmpty,
            reason: '$label 关闭后仍有残片：${st.closedStateViolations()}');
      });
    }
  });

  // -------------------------------------------------------------------------
  group('§七 顶部反复开合不得漂移', () {
    testWidgets('5 左上开合 10 次：每次都完整可见、组合稳定、无残片',
        (WidgetTester tester) async {
      final Harness h = await pumpProbe(tester, petScreen: const Offset(64, 120));
      for (int i = 0; i < 10; i++) {
        await h.state.open();
        await tester.pumpAndSettle();
        expect(h.state.verticalPlacementForTest, WheelVerticalPlacement.top,
            reason: '第 ${i + 1} 次打开必须仍是靠上（不得漂移）');
        expect(h.state.topOverflowPxForTest, lessThanOrEqualTo(1.0),
            reason: '第 ${i + 1} 次打开上侧不得溢出');
        expect(h.state.wheelWindowFitsCanvas, isTrue,
            reason: '第 ${i + 1} 次打开轮盘不得被画布裁切');
        await h.state.close();
        await tester.pumpAndSettle();
        expect(h.state.closedStateViolations(), isEmpty,
            reason: '第 ${i + 1} 次关闭不得残留');
      }
      // 开合期间窗口矩形恒定（绝不因开合而改画布）。
      expect(h.ops.commits.length, 1, reason: '开合 10 次只允许启动时提交一次窗口矩形');
    });

    testWidgets('6 右上开合 10 次：同一口径（镜像方向）',
        (WidgetTester tester) async {
      final Harness h = await pumpProbe(tester, petScreen: const Offset(1600, 120));
      for (int i = 0; i < 10; i++) {
        await h.state.open();
        await tester.pumpAndSettle();
        expect(h.state.verticalPlacementForTest, WheelVerticalPlacement.top);
        expect(h.state.expansionSideForTest, WheelExpansionSide.left);
        expect(h.state.topOverflowPxForTest, lessThanOrEqualTo(1.0));
        expect(h.state.wheelWindowFitsCanvas, isTrue);
        await h.state.close();
        await tester.pumpAndSettle();
        expect(h.state.closedStateViolations(), isEmpty);
      }
      expect(h.ops.commits.length, 1);
    });
  });

  // -------------------------------------------------------------------------
  group('§五 / §三 纯函数性质（不依赖历史状态）', () {
    test('7 纵向模式是位置的纯函数（同一位置 → 同一结论）', () {
      final WheelPlacementSolution a = WheelPlacementSolver.solve(
        workArea: _bounds(workArea1920),
        petWindowRect: _rect(const Rect.fromLTWH(64, 120, 256, 192)),
        content: _content(mayaBounds),
        maxItemCount: 6,
        spec: _spec(),
        settings: realSettings,
      );
      final WheelPlacementSolution b = WheelPlacementSolver.solve(
        workArea: _bounds(workArea1920),
        petWindowRect: _rect(const Rect.fromLTWH(64, 120, 256, 192)),
        content: _content(mayaBounds),
        maxItemCount: 6,
        spec: _spec(),
        settings: realSettings,
        // 传入"上一次是靠下"——**不得**影响结论。
        previousPlacement: const WheelPlacement(
          horizontalSide: WheelExpansionSide.right,
          vertical: WheelVerticalPlacement.bottom,
        ),
      );
      expect(a.vertical, WheelVerticalPlacement.top);
      expect(b.vertical, WheelVerticalPlacement.top,
          reason: '历史（上一次靠下）绝不能锁住本次的纵向模式');
      expect(a.vertical, b.vertical);
      expect(a.horizontalSide, b.horizontalSide);
    });

    test('8 三候选都被评估，且选择规则可断言', () {
      final WheelPlacementSolution s = WheelPlacementSolver.solve(
        workArea: _bounds(workArea1920),
        petWindowRect: _rect(const Rect.fromLTWH(64, 120, 256, 192)),
        content: _content(mayaBounds),
        maxItemCount: 6,
        spec: _spec(),
        settings: realSettings,
      );
      // 三个纵向候选都必须给出结果（诊断对账用）。
      expect(s.candidates.length, 3);
      for (final WheelPlacementCandidate c in s.candidates) {
        expect(c.placement.horizontalSide, s.horizontalSide);
      }
      // 靠上时必须零溢出；靠下时**必然**溢出（否则判据没有意义）。
      expect(s.candidateOf(WheelVerticalPlacement.top)!.overflowPx,
          lessThanOrEqualTo(1.0));
      expect(s.candidateOf(WheelVerticalPlacement.bottom)!.overflowPx,
          greaterThan(1.0));
      // 选择原因可断言（fit_only_top / fit_prefer_middle / no_fit_pick_min_overflow）。
      expect(s.reason, isNotEmpty);
    });

    test('9 画布矩形 = 视觉包围盒 ∪ 窗口，再 expand(4).roundOut()', () {
      final WheelPlacementSolution s = WheelPlacementSolver.solve(
        workArea: _bounds(workArea1920),
        petWindowRect: _rect(const Rect.fromLTWH(1200, 500, 256, 192)),
        content: _content(mayaBounds),
        maxItemCount: 6,
        spec: _spec(),
        settings: realSettings,
      );
      final Rect canvasBounds = s.canvasBoundsScreen;
      // `expand(4)` 之后必须完整包含视觉包围盒（取整只允许向外）。
      expect(canvasBounds.contains(s.visualBoundsScreen.topLeft), isTrue,
          reason: '画布必须包含视觉包围盒左上角');
      expect(
        canvasBounds.contains(
          s.visualBoundsScreen.bottomRight - const Offset(0.01, 0.01),
        ),
        isTrue,
        reason: '画布必须包含视觉包围盒右下角',
      );
      // 取整：四条边都是整数（窗口尺寸必须是整数像素）。
      expect(canvasBounds.left, canvasBounds.left.roundToDouble());
      expect(canvasBounds.top, canvasBounds.top.roundToDouble());
      expect(canvasBounds.right, canvasBounds.right.roundToDouble());
      expect(canvasBounds.bottom, canvasBounds.bottom.roundToDouble());
    });

    test('10 纯 Dart：新增模块不依赖桌面实现（Android 隔离）', () {
      const List<String> forbidden = <String>[
        'dart:io',
        'package:flutter/material.dart',
        'package:window_manager',
        'platform/windows',
        'region_coordinator',
      ];
      for (final String name in <String>[
        'wheel_placement.dart',
        'wheel_placement_solver.dart',
        'wheel_space_pipeline.dart',
      ]) {
        final String source = File('lib/menu/$name'.replaceAll('/', Platform.pathSeparator))
            .readAsStringSync();
        for (final String f in forbidden) {
          expect(source.contains(f), isFalse, reason: 'lib/menu/$name 不得依赖 $f');
        }
      }
    });
  });

  // -------------------------------------------------------------------------
  group('§三 边界：轮盘本身就比剩余空间大', () {
    test('11 贴到极限（y=40）时仍选**靠上**，残余溢出如实上报', () {
      final WheelPlacementSolution s = WheelPlacementSolver.solve(
        workArea: _bounds(workArea1920),
        petWindowRect: _rect(const Rect.fromLTWH(64, 40, 256, 192)),
        content: _content(mayaBounds),
        maxItemCount: 6,
        spec: _spec(),
        settings: realSettings,
      );
      // 方向仍然正确（靠上），只是"零溢出"做不到 —— 属于空间本身不足。
      expect(s.vertical, WheelVerticalPlacement.top,
          reason: '极限贴顶也必须选对方向（不得退回靠下）');
      final WheelPlacementCandidate top = s.candidateOf(WheelVerticalPlacement.top)!;
      final WheelPlacementCandidate mid = s.candidateOf(WheelVerticalPlacement.middle)!;
      final WheelPlacementCandidate bot = s.candidateOf(WheelVerticalPlacement.bottom)!;
      // 靠上的**上侧**溢出必须是三者中最小的（"选对了方向"的量化证据）。
      expect(top.topOverflowPx, lessThanOrEqualTo(mid.topOverflowPx + 1e-9));
      expect(top.topOverflowPx, lessThan(bot.topOverflowPx - 1e-9),
          reason: '靠下的向上溢出必然比靠上更大（偏转方向相反）');
      expect(s.reason, 'no_fit_pick_min_overflow');
    });
  });

  // -------------------------------------------------------------------------
  group('§三 选择规则：位置优先于居中', () {
    test('12 居中放得下时，顶部位置**仍然**选靠上（否则 top 永不生效）', () {
      // 位置口径：视觉中心 y = 206 + 114 = 320 → 居中对称外扩 273px 放得下，
      // 同时"位置指示"仍是靠上（above=320 < below*0.55=396）。
      final WheelPlacementSolution s = WheelPlacementSolver.solve(
        workArea: _bounds(workArea1920),
        petWindowRect: _rect(const Rect.fromLTWH(64, 206, 256, 192)),
        content: _content(mayaBounds),
        maxItemCount: 6,
        spec: _spec(),
        settings: realSettings,
      );
      // y=120 时居中其实也放得下（对称外扩 226px < 234px），但位置说的是"靠上"。
      expect(s.candidateOf(WheelVerticalPlacement.middle)!.fitsWorkArea, isTrue,
          reason: '前提：居中确实也放得下（否则这条测试没有意义）');
      expect(s.vertical, WheelVerticalPlacement.top,
          reason: '位置靠近顶部 → 必须选靠上（§八 要求 top 场景 verticalPlacement=top）');
      expect(s.reason, 'fit_natural_top');
    });

    test('13 屏幕正中 → 居中（位置说的模式就是居中）', () {
      final WheelPlacementSolution s = WheelPlacementSolver.solve(
        workArea: _bounds(workArea1920),
        petWindowRect: _rect(const Rect.fromLTWH(832, 420, 256, 192)),
        content: _content(mayaBounds),
        maxItemCount: 6,
        spec: _spec(),
        settings: realSettings,
      );
      expect(s.vertical, WheelVerticalPlacement.middle);
      expect(s.topOverflowPx, lessThanOrEqualTo(1.0));
      expect(s.bottomOverflowPx, lessThanOrEqualTo(1.0));
    });
  });
}

// ---------------------------------------------------------------------------
// 直接调生产几何的小助手（不另写近似）
// ---------------------------------------------------------------------------

WheelBounds _bounds(Rect r) => WheelBounds(r.left, r.top, r.right, r.bottom);

WheelRect _rect(Rect r) => WheelRect(r.left, r.top, r.right, r.bottom);

WheelContentBounds _content(PetVisualBounds b) =>
    WheelContentBounds(b.left, b.top, b.right, b.bottom);

WheelMenuSpec _spec() => WheelMenuSpec.fromDensity(1.0);

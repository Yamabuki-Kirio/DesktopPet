/// **C1.1 回归测试**：坐标管线 / alpha 边界 / 裁切 / 残片 / 缩放。
///
/// 覆盖需求 §二、§三、§四、§五、§六、§八、§九、§十、§十一 的各项。
/// 断言的都是**外部可观察事实**：缺口中心是否等于人物视觉中心、轮盘是否完整
/// 落在画布里、Region 是否覆盖全部被绘制的元素、关闭后是否还画菜单、
/// 拖动后是否用新位置、旧修订号结果是否被丢弃。
library;

// 测试脚手架私有类型出现在公共签名里是可接受的（本仓库测试的统一做法）。
// ignore_for_file: library_private_types_in_public_api

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:petlife/character/pet_visual_bounds.dart';
import 'package:petlife/menu/fixed_canvas_contract.dart';
import 'package:petlife/menu/fixed_canvas_geometry.dart' show PhysicalRect;
import 'package:petlife/menu/region_coordinator.dart';
import 'package:petlife/menu/wheel_canvas_bridge.dart';
import 'package:petlife/menu/wheel_canvas_plan.dart';
import 'package:petlife/menu/wheel_expansion_side.dart';
import 'package:petlife/menu/wheel_geometry.dart' show WheelDisplayArea;
import 'package:petlife/menu/wheel_geometry_ownership.dart'
    show WheelGeometryJournal, wheelGeometryJournal;
import 'package:petlife/menu/wheel_menu_geometry.dart'
    show
        WheelBounds,
        WheelGeometryMeasurement,
        WheelMenuGeometry,
        WheelMenuLayoutSettings,
        WheelRect;
import 'package:petlife/menu/wheel_region.dart' show WheelRegionBuilder;
import 'package:petlife/menu/wheel_scale_audit.dart';
import 'package:petlife/menu/wheel_space_pipeline.dart';
import 'package:petlife/menu/wheel_visual_bounds.dart';
import 'package:petlife/ui/desktop/fixed_canvas_probe.dart';

// ---------------------------------------------------------------------------
// 真机基线（2026-10-07）
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
  WheelDisplayArea display = const WheelDisplayArea(
    id: 'd',
    left: 0,
    top: 0,
    width: 1920,
    height: 1040,
    isPrimary: true,
  ),
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

/// 四张真机截图对应的几何场景。
const Map<String, Offset> screenshotScenarios = <String, Offset>{
  // 场景 A：人物靠右下 → 菜单应完整向左上展开、不出屏、不裁切。
  'A-右下': Offset(1376, 534),
  // 场景 B：人物靠左下 → 菜单应完整向右上展开。
  'B-左下': Offset(64, 780),
  // 场景 C：人物移动后关闭菜单 → 不得在旧位置残留粉色扇形。
  'C-左上': Offset(64, 120),
  // 场景 D：人物在右侧关闭菜单 → 不得在画布另一端残留扇形。
  'D-中右': Offset(1500, 500),
};

// ---------------------------------------------------------------------------
// 测量助手：直接调**生产**几何（`WheelMenuGeometry.measure`），不另写近似
// ---------------------------------------------------------------------------

WheelGeometryMeasurement measureGeometry({
  required Rect petWidgetScreenRect,
  required PetVisualBounds bounds,
  required WheelMenuLayoutSettings settings,
  required int maxItemCount,
  Rect workArea = const Rect.fromLTWH(0, 0, 1920, 1040),
}) =>
    WheelMenuGeometry.measure(
      petWidgetRect: WheelRect(
        petWidgetScreenRect.left,
        petWidgetScreenRect.top,
        petWidgetScreenRect.right,
        petWidgetScreenRect.bottom,
      ),
      bounds: bounds,
      settings: settings,
      maxItemCount: maxItemCount,
      workArea: WheelBounds(
        workArea.left,
        workArea.top,
        workArea.right,
        workArea.bottom,
      ),
      spec: WheelCanvasBridge.spec(),
    );

/// 读源文件（"Android 隔离"类断言用）。
String readSource(String relativePath) =>
    File(relativePath.replaceAll('/', Platform.pathSeparator)).readAsStringSync();

String _r(Rect? r) => r == null
    ? 'null'
    : '${r.left.toStringAsFixed(1)},${r.top.toStringAsFixed(1)},'
        '${r.right.toStringAsFixed(1)},${r.bottom.toStringAsFixed(1)}';

String _sz(Size? s) =>
    s == null ? 'null' : '${s.width.toStringAsFixed(1)}x${s.height.toStringAsFixed(1)}';

void main() {
  setUp(() => wheelGeometryJournal.clear());
  tearDown(() => wheelGeometryJournal.clear());

  // -------------------------------------------------------------------------
  group('§一/§二 alpha 边界与坐标管线', () {
    test('1 alpha 包围盒：只认非透明像素，阈值 12', () {
      // 4×4 图，只有 (1,1)-(2,2) 不透明（alpha=255），其余 alpha=5。
      final List<int> px = List<int>.filled(4 * 4 * 4, 0);
      for (int y = 0; y < 4; y++) {
        for (int x = 0; x < 4; x++) {
          px[(y * 4 + x) * 4 + 3] = 5;
        }
      }
      for (int y = 1; y <= 2; y++) {
        for (int x = 1; x <= 2; x++) {
          px[(y * 4 + x) * 4 + 3] = 255;
        }
      }
      final PetVisualBounds b = PetAlphaBoundsScanner.measureRgba(
        Uint8List.fromList(px),
        width: 4,
        height: 4,
      );
      expect(b.left, closeTo(0.25, 1e-9));
      expect(b.top, closeTo(0.25, 1e-9));
      expect(b.right, closeTo(0.75, 1e-9));
      expect(b.bottom, closeTo(0.75, 1e-9));
    });

    test('1b 全透明素材 → 回退整张图（不返回 0 面积）', () {
      final Uint8List rgba = Uint8List.fromList(
        List<int>.filled(8 * 8 * 4, 0),
      );
      final PetVisualBounds b = PetAlphaBoundsScanner.measureRgba(
        rgba,
        width: 8,
        height: 8,
      );
      expect(b.isFull, isTrue);
    });

    test('2 动画多帧取**稳定并集**（不会因为某帧变小而缩回）', () {
      final PetVisualBoundsCache cache = PetVisualBoundsCache();
      cache.record('a', 0, const PetVisualBounds(0.4, 0.4, 0.5, 0.5));
      cache.record('a', 1, const PetVisualBounds(0.1, 0.2, 0.9, 0.8));
      cache.record('a', 2, const PetVisualBounds(0.45, 0.45, 0.5, 0.5));
      final PetVisualBounds? u = cache.boundsOf('a');
      expect(u, isNotNull);
      expect(u!.left, closeTo(0.1, 1e-9));
      expect(u.right, closeTo(0.9, 1e-9));
      // 同一帧重复记录不改变并集，也不重复计数。
      cache.record('a', 2, const PetVisualBounds(0.0, 0.0, 1.0, 1.0));
      expect(cache.boundsOf('a')!.left, closeTo(0.1, 1e-9));
      expect(cache.measuredFrames('a'), 3);
    });

    test('3 人物视觉锚点 = alpha 中心，而不是素材 / Widget 中心', () {
      const Rect petRect = Rect.fromLTWH(0, 0, 256, 192);
      const WheelSpaceSnapshot space = WheelSpaceSnapshot(
        canvasWindowRect: Rect.fromLTWH(1000, 500, 800, 700),
        petAnchor: Offset(400, 300),
        petSize: assetSize,
        bounds: mayaBounds,
        positionRevision: 1,
        geometryRevision: 1,
        surfaceGeneration: 1,
      );
      final Rect visual = space.petVisualLocalRect;
      // 可见人物 = 92×156，落在 Widget 里的 (78,36)-(170,192)。
      expect(visual.width, closeTo(92, 0.5));
      expect(visual.height, closeTo(156, 0.5));
      expect(visual.left, closeTo(478, 0.5));
      expect(visual.top, closeTo(336, 0.5));
      // 视觉中心 ≠ Widget 中心（Widget 中心是 528,396）。
      expect(space.notchCenterLocal.dx, closeTo(524, 0.5));
      expect(space.notchCenterLocal.dy, closeTo(414, 0.5));
      expect(space.notchCenterLocal, isNot(const Offset(528, 396)));
      // 屏幕坐标 = 画布局部 + 画布左上角（含小数，不做取整）。
      expect(space.petVisualScreenRect.left, closeTo(1478, 0.05));
      expect(space.petVisualScreenRect.top, closeTo(836, 0.05));
      expect(petRect.width, 256);
    });

    test('4 缺口中心必须等于人物视觉中心（几何不变量）', () {
      final WheelGeometryMeasurement probe = measureGeometry(
        petWidgetScreenRect: const Rect.fromLTWH(1000, 500, 256, 192),
        bounds: mayaBounds,
        settings: realSettings,
        maxItemCount: 6,
      );
      final double expectedCx =
          mayaBounds.toRect(const Rect.fromLTWH(1000, 500, 256, 192)).center.dx;
      expect(probe.petAnchorX, closeTo(expectedCx, 1.5));
      // 而且**不**等于 Widget 中心（1128）。
      expect(probe.petAnchorX, isNot(closeTo(1128, 1.0)));
    });
  });

  // -------------------------------------------------------------------------
  group('§九 视觉比例（对比 Android 基准）', () {
    test('10 默认设置下 ringRadius 与人物可见尺寸同量级（不是 2.4 倍）', () {
      const WheelMenuLayoutSettings defaults = WheelMenuLayoutSettings();
      final WheelGeometryMeasurement p = measureGeometry(
        petWidgetScreenRect: const Rect.fromLTWH(0, 0, 256, 192),
        bounds: mayaBounds,
        settings: defaults,
        maxItemCount: 6,
      );
      final double visibleH = mayaBounds.toRect(
        const Rect.fromLTWH(0, 0, 256, 192),
      ).height;
      // Android 基准：环半径 ≈ 人物可见高度 × 0.7~1.4 之间。
      expect(p.ringRadiusPx / visibleH, greaterThan(0.55));
      expect(p.ringRadiusPx / visibleH, lessThan(1.6));
      // 缺口核半径必须来自**可见**尺寸（92/156），而不是 256/192。
      expect(p.holeRx, closeTo(92 * 1.05 / 2 + 10, 1.0));
      expect(p.holeRy, closeTo(156 * 1.05 / 2 + 10, 1.0));
    });

    test('11 视觉包围盒完整落在画布内（§六 的核心判据）', () {
      final WheelCanvasPlan plan = WheelCanvasPlanner.plan(
        petSize: assetSize,
        workArea: const Size(1920, 1040),
        settings: realSettings,
        petVisualBounds: mayaBounds,
      );
      expect(plan.compressed, isFalse, reason: '1920×1040 不需要压缩');
      expect(plan.visualFitsCanvas, isTrue,
          reason: 'visualBounds + safetyPadding 必须装得进画布');
      expect(plan.interactiveFitsCanvas, isTrue);
      // 画布不能离谱地大（旧口径 2054 那种）。
      expect(plan.canvasSize.width, lessThan(1000));
      expect(plan.canvasSize.height, lessThan(1000));
      // 锚点必须取整（否则 Region / 位置出现 0.9999 漂移）。
      expect(plan.petAnchor.dx, plan.petAnchor.dx.roundToDouble());
      expect(plan.petAnchor.dy, plan.petAnchor.dy.roundToDouble());
    });
  });

  // -------------------------------------------------------------------------
  group('§三 方向判定', () {
    test('5 左侧人物 → 菜单在右手侧', () {
      final WheelGeometryMeasurement p = measureGeometry(
        petWidgetScreenRect: const Rect.fromLTWH(64, 500, 256, 192),
        bounds: mayaBounds,
        settings: realSettings,
        maxItemCount: 6,
        workArea: const Rect.fromLTWH(0, 0, 1920, 1040),
      );
      expect(p.side, WheelExpansionSide.right);
      expect(p.invariantPassed, isTrue);
    });

    test('6 右侧人物 → 菜单在左手侧', () {
      final WheelGeometryMeasurement p = measureGeometry(
        petWidgetScreenRect: const Rect.fromLTWH(1600, 500, 256, 192),
        bounds: mayaBounds,
        settings: realSettings,
        maxItemCount: 6,
        workArea: const Rect.fromLTWH(0, 0, 1920, 1040),
      );
      expect(p.side, WheelExpansionSide.left);
      expect(p.invariantPassed, isTrue);
    });

    test('7 两侧都放得下 → 选空间更大的一侧', () {
      // 人物略偏左（中心 700 < 960）→ 右侧空间更大。
      final WheelGeometryMeasurement p = measureGeometry(
        petWidgetScreenRect: const Rect.fromLTWH(600, 500, 256, 192),
        bounds: mayaBounds,
        settings: realSettings,
        maxItemCount: 6,
        workArea: const Rect.fromLTWH(0, 0, 1920, 1040),
      );
      expect(p.side, WheelExpansionSide.right);
    });

    test('8 Painter 绝不二次镜像（契约恒为 false）', () {
      for (final WheelExpansionSide side in WheelExpansionSide.values) {
        expect(side.requiresRendererMirror, isFalse);
      }
    });
  });

  // -------------------------------------------------------------------------
  group('§四 拖动后的实时刷新', () {
    testWidgets('12 拖动结束使用**新位置**（空间快照随之更新）',
        (WidgetTester tester) async {
      final Harness h = await pumpProbe(tester, petScreen: const Offset(300, 400));
      final Rect beforeVisual = h.state.petVisualScreenRectForTest;
      final Rect beforeCanvas = h.state.canvasRectForTest!;
      final int revBefore = h.state.positionRevision;

      // 模拟"用户把桌宠拖到别处"：窗口矩形整体平移 + 位置提交回调
      // （回调参数是**绝对** petScreenPosition，与生产链路一致）。
      const Offset delta = Offset(700, 300);
      h.ops.bounds = h.ops.bounds.shift(delta);
      final Offset newPetScreen =
          (beforeCanvas.topLeft + h.state.canvasPlanForTest!.petAnchor) + delta;
      await h.state.onPetPositionChanged(newPetScreen.dx, newPetScreen.dy);
      await tester.pump();

      final Rect after = h.state.petVisualScreenRectForTest;
      expect(after, isNot(beforeVisual), reason: '必须使用新位置');
      expect(after.left, closeTo(beforeVisual.left + delta.dx, 1.0));
      expect(after.top, closeTo(beforeVisual.top + delta.dy, 1.0));
      expect(h.state.positionRevision, revBefore + 1,
          reason: '位置修订号必须 +1（旧的在飞计算作废）');
      expect(
        wheelGeometryJournal.contains('pet.position.changed'),
        isTrue,
      );
    });

    testWidgets('13 拖动时轮盘先收起（Region 收敛到 pet，不残留菜单）',
        (WidgetTester tester) async {
      final Harness h = await pumpProbe(tester, petScreen: const Offset(300, 400));
      await h.state.open();
      await tester.pumpAndSettle();
      expect(h.state.shouldPaintMenu, isTrue);

      final Rect canvas = h.state.canvasRectForTest!;
      const Offset move = Offset(400, 0);
      h.ops.bounds = h.ops.bounds.shift(move);
      final Offset petScreen =
          canvas.topLeft + h.state.canvasPlanForTest!.petAnchor + move;
      await h.state.onPetPositionChanged(petScreen.dx, petScreen.dy);
      await tester.pumpAndSettle();

      expect(h.state.shouldPaintMenu, isFalse, reason: '拖动后不得继续绘制菜单');
      expect(h.state.regionIsPetOnly, isTrue);
      expect(h.state.closedStateViolations(), isEmpty);
    });

    test('14 旧 positionRevision 结果被丢弃（快照 matches 判定）', () {
      const WheelSpaceSnapshot old = WheelSpaceSnapshot(
        canvasWindowRect: Rect.fromLTWH(0, 0, 400, 400),
        petAnchor: Offset(100, 100),
        petSize: assetSize,
        bounds: mayaBounds,
        positionRevision: 3,
        geometryRevision: 5,
        surfaceGeneration: 2,
      );
      expect(
        old.matches(positionRevision: 3, geometryRevision: 5, surfaceGeneration: 2),
        isTrue,
      );
      expect(
        old.matches(positionRevision: 4, geometryRevision: 5, surfaceGeneration: 2),
        isFalse,
        reason: '位置变了 → 旧快照必须被判过期',
      );
      expect(
        old.matches(positionRevision: 3, geometryRevision: 6, surfaceGeneration: 2),
        isFalse,
      );
      expect(
        old.matches(positionRevision: 3, geometryRevision: 5, surfaceGeneration: 3),
        isFalse,
      );
      final WheelRevisionCounter c = WheelRevisionCounter();
      expect(c.bump(), 1);
      expect(c.bump(), 2);
      expect(c.isCurrent(2), isTrue);
      expect(c.isCurrent(1), isFalse);
    });
  });

  // -------------------------------------------------------------------------
  group('§五 缩放：只应用一次', () {
    test('15 默认设置不重复缩放（按钮直径 = 唯一公式）', () {
      const WheelMenuLayoutSettings defaults = WheelMenuLayoutSettings();
      final WheelGeometryMeasurement p = measureGeometry(
        petWidgetScreenRect: const Rect.fromLTWH(0, 0, 256, 192),
        bounds: mayaBounds,
        settings: defaults,
        maxItemCount: 6,
      );
      final WheelScaleAudit audit = WheelScaleAudit.of(
        persisted: defaults,
        effective: defaults,
        intrinsic: p.intrinsic,
        spec: WheelCanvasBridge.spec(),
        screenFactor: 1.0,
        devicePixelRatio: 1.25,
      );
      expect(audit.normalizedOk, isTrue);
      expect(audit.screenFactorOk, isTrue);
      expect(audit.effectiveScaleOk, isTrue);
      expect(audit.buttonDiameterOk(WheelCanvasBridge.spec()), isTrue,
          reason: '按钮直径只允许按一个公式算一次');
      expect(audit.geometryDensity, 1.0, reason: '几何密度恒为 1（不乘 DPR）');
      expect(audit.devicePixelRatio, 1.25, reason: 'DPR 只记录，不进几何');
    });

    test('16 persisted 2.50 能正确显示并触发 emergencyScale', () {
      const WheelMenuLayoutSettings big = WheelMenuLayoutSettings(
        preferredScale: 2.5,
        buttonVisualScale: 2.5,
        menuDistance: 0.30,
      );
      final WheelCanvasPlan plan = WheelCanvasPlanner.plan(
        petSize: assetSize,
        workArea: const Size(1920, 1040),
        settings: big,
        petVisualBounds: mayaBounds,
      );
      // 250% 在 1920×1040 上放不下 → 被压缩（screenFactor < 1）。
      expect(plan.compressed, isTrue);
      expect(plan.screenFactor, lessThan(1.0));
      expect(plan.effectiveScale, lessThan(2.5));
      expect(plan.effectiveScale,
          greaterThanOrEqualTo(WheelMenuLayoutSettings.minScale - 1e-9));
      // 压缩后仍必须装得下（否则就是"看起来能用其实被裁"）。
      expect(plan.canvasSize.width,
          lessThanOrEqualTo(1920 * 1.06 + 1));
    });

    test('17 恢复 Android 默认：口径唯一', () {
      const WheelMenuLayoutSettings defaults = WheelMenuLayoutSettings();
      expect(defaults.preferredScale, WheelDefaultRestore.wheelScale);
      expect(defaults.buttonVisualScale, WheelDefaultRestore.buttonScale);
      expect(defaults.buttonVisualScale, 1.30,
          reason: 'Android DEFAULT_BUTTON_SCALE = 1.30');
      expect(defaults.menuDistance, WheelDefaultRestore.menuDistance);
      // Android 默认按钮倍率是 1.30（不是 1.00）。
      expect(WheelDefaultRestore.buttonScale,
          WheelMenuLayoutSettings.defaultButtonScale);
      expect(WheelDefaultRestore.isDefault(
        wheelScale: 1.0,
        buttonScale: WheelMenuLayoutSettings.defaultButtonScale,
        menuDistance: 0.16,
        themeId: 'p3p-pink',
      ), isTrue);
      expect(WheelDefaultRestore.isDefault(
        wheelScale: 0.6,
        buttonScale: 1.3,
        menuDistance: 0.16,
        themeId: 'p3p-pink',
      ), isFalse, reason: '真机当前值不是默认（必须能被识别出来）');
    });

    test('18 归一化会夹住越界值（旧版本字段异常 → 迁移到合法域）', () {
      const WheelMenuLayoutSettings weird = WheelMenuLayoutSettings(
        preferredScale: 60,
        buttonVisualScale: 130,
        menuDistance: 5,
      );
      final WheelMenuLayoutSettings n = weird.normalized();
      expect(n.preferredScale,
          inInclusiveRange(WheelMenuLayoutSettings.minScale,
              WheelMenuLayoutSettings.maxScale));
      expect(n.buttonVisualScale,
          inInclusiveRange(WheelMenuLayoutSettings.minButtonScale,
              WheelMenuLayoutSettings.maxButtonScale));
      expect(n.menuDistance,
          inInclusiveRange(WheelMenuLayoutSettings.minDistance,
              WheelMenuLayoutSettings.maxDistance));
      expect(n.preferredScale, isNot(60));
    });
  });

  // -------------------------------------------------------------------------
  group('§六 Region 覆盖全部绘制元素', () {
    test('19 Region 覆盖 fan/blade/buttons/labels/texts（不再硬裁切）', () {
      final WheelGeometryMeasurement p = measureGeometry(
        petWidgetScreenRect: const Rect.fromLTWH(0, 0, 256, 192),
        bounds: mayaBounds,
        settings: realSettings,
        maxItemCount: 6,
      );
      final WheelVisualBounds vb =
          WheelVisualBoundsCalculator.compute(p.layout);
      final List<Rect> region = WheelRegionBuilder.rectsFor(
        p.layout,
        slotProgress: List<double>.filled(p.layout.itemCount, 1.0),
      );
      expect(
        WheelRegionBuilder.coversVisualBounds(region, vb, layout: p.layout),
        isTrue,
        reason: 'Region 必须覆盖全部会被绘制的元素：${vb.describe()}',
      );
      // 刀刃确实比环带外缘大（旧的 Region 漏掉的那部分）。
      expect(p.layout.bladeLengthPx, greaterThan(p.layout.rimOuterPx));
      expect(vb.all.height, greaterThan(0));
    });

    test('20 交互内容在 Region 之内（按钮不可能"看得见点不到"）', () {
      final WheelGeometryMeasurement p = measureGeometry(
        petWidgetScreenRect: const Rect.fromLTWH(0, 0, 256, 192),
        bounds: mayaBounds,
        settings: realSettings,
        maxItemCount: 6,
      );
      final List<Rect> region = WheelRegionBuilder.rectsFor(
        p.layout,
        slotProgress: List<double>.filled(p.layout.itemCount, 1.0),
      );
      for (final slot in p.layout.slots) {
        bool inside = false;
        for (final Rect r in region) {
          if (r.contains(Offset(slot.centerX, slot.centerY))) {
            inside = true;
            break;
          }
        }
        expect(inside, isTrue, reason: '按钮 ${slot.index} 的中心必须可点');
      }
    });

    test('21 overshoot 预留：按钮被推到 1.36× 时仍在包围盒内', () {
      final WheelGeometryMeasurement p = measureGeometry(
        petWidgetScreenRect: const Rect.fromLTWH(0, 0, 256, 192),
        bounds: mayaBounds,
        settings: realSettings,
        maxItemCount: 6,
      );
      final WheelVisualBounds vb =
          WheelVisualBoundsCalculator.compute(p.layout);
      // 按钮包围盒必须比"静态落位"更大（含 overshoot）。
      double maxStaticRadius = 0;
      for (final slot in p.layout.slots) {
        final double d = math.sqrt(
          math.pow(slot.centerX - p.layout.centerX, 2) +
              math.pow(slot.centerY - p.layout.centerY, 2),
        );
        maxStaticRadius = math.max(maxStaticRadius, d);
      }
      final double buttonOuter = math.max(
        (vb.buttons.right - p.layout.centerX).abs(),
        (p.layout.centerX - vb.buttons.left).abs(),
      );
      expect(buttonOuter, greaterThan(maxStaticRadius),
          reason: '包围盒必须为弹出 overshoot 留出余量');
      expect(WheelVisualBoundsCalculator.maxButtonProgress, greaterThan(1.2));
    });
  });

  // -------------------------------------------------------------------------
  group('§八 关闭后不再绘制（残片）', () {
    testWidgets('22 关闭后：不绘制 + Region 仅 pet + 状态 closed',
        (WidgetTester tester) async {
      final Harness h = await pumpProbe(tester, petScreen: const Offset(1200, 600));
      await h.state.open();
      await tester.pumpAndSettle();
      expect(h.state.shouldPaintMenu, isTrue);

      await h.state.close();
      await tester.pumpAndSettle();

      expect(h.state.shouldPaintMenu, isFalse);
      expect(h.state.wheelOpenProgressForTest, 0.0);
      expect(h.state.wheelMenuLocalRectForTest, isNull);
      expect(h.state.regionIsPetOnly, isTrue);
      expect(h.state.closedStateViolations(), isEmpty);
      expect(
        wheelGeometryJournal.contains('wheel.close.invariants'),
        isTrue,
      );
      expect(
        wheelGeometryJournal.contains('wheel.close.invariants.violated'),
        isFalse,
      );
    });
  });

  // -------------------------------------------------------------------------
  group('§十 截图回归（四个场景）', () {
    for (final MapEntry<String, Offset> s in screenshotScenarios.entries) {
      testWidgets('23 场景 ${s.key}：轮盘完整落在画布内、方向正确、关闭无残片',
          (WidgetTester tester) async {
        final Harness h = await pumpProbe(tester, petScreen: s.value);
        await h.state.open();
        await tester.pumpAndSettle();

        final FixedCanvasProbeState st = h.state;
        final Map<String, Object?> snapshot = <String, Object?>{
          'scenario': s.key,
          'petScreen': '${s.value.dx},${s.value.dy}',
          'canvasRect': _r(st.canvasRectForTest),
          'canvasSize': _sz(st.canvasPlanForTest?.canvasSize),
          'petVisualScreenRect': _r(st.petVisualScreenRectForTest),
          'alphaBounds': st.petVisualBounds.describe(),
          'side': st.expansionSideForTest?.wireName,
          'menuLocalRect': _r(st.menuLocalRectForTest),
          'visualBounds': st.canvasPlanForTest == null
              ? null
              : _r(st.canvasPlanForTest!.visualBoundsInCanvas),
          'interactiveBounds': st.canvasPlanForTest == null
              ? null
              : _r(st.canvasPlanForTest!.interactiveBoundsInCanvas),
          'regionRects': <String>[
            for (final Rect r in st.wheelRegionRects) _r(r),
          ],
          'envelopeWindow': st.wheelEnvelopeForTest == null
              ? null
              : _r(st.wheelEnvelopeForTest!.windowRect.toRect()),
          'ringRadius': st.wheelLayoutForTest?.ringRadiusPx,
          'buttonDiameter': st.wheelLayoutForTest?.buttonDiameterPx,
          'holeRx': st.wheelLayoutForTest?.notchRx,
          'holeRy': st.wheelLayoutForTest?.notchRy,
        };
        // ignore: avoid_print
        print('== 截图回归 ${s.key} ==\n'
            '${const JsonEncoder.withIndent('  ').convert(snapshot)}');

        // ① 轮盘窗口必须完整落在画布内（否则真机硬裁切）。
        expect(st.wheelWindowFitsCanvas, isTrue, reason: '轮盘不得被画布裁切');
        // ② 画布不得越界（画布必须装得下视觉包围盒）。
        expect(st.canvasPlanForTest!.visualFitsCanvas, isTrue);
        expect(st.canvasPlanForTest!.interactiveFitsCanvas, isTrue);
        // ③ 方向必须正确（靠右 → 左展开；靠左 → 右展开）。
        final WheelExpansionSide expected =
            s.value.dx + 128 > 960 ? WheelExpansionSide.left : WheelExpansionSide.right;
        expect(st.expansionSideForTest, expected, reason: '展开侧必须正确');
        // ④ 缺口中心 = 人物视觉中心。
        final Rect visual = st.petVisualScreenRectForTest;
        final Rect canvas = st.canvasRectForTest!;
        final Rect menuLocal = st.menuLocalRectForTest!;
        // 缺口坐标是**菜单窗口局部**的：屏幕坐标 = 缺口 + 菜单窗口局部 + 画布左上角。
        final Offset notchScreen = Offset(
              st.wheelLayoutForTest!.notchCenterX,
              st.wheelLayoutForTest!.notchCenterY,
            ) +
            menuLocal.topLeft +
            canvas.topLeft;
        expect(
          (notchScreen - visual.center).distance,
          lessThan(2.0),
          reason: '缺口中心必须等于人物视觉中心'
              '（缺口=$notchScreen 视觉中心=${visual.center}）',
        );
        // ⑤ 关闭后无残片。
        await st.close();
        await tester.pumpAndSettle();
        expect(st.closedStateViolations(), isEmpty);
      });
    }
  });

  // -------------------------------------------------------------------------
  group('§十一 分辨率 / DPI / 多屏', () {
    test('24 三种分辨率 + 三种 DPI：视觉包围盒都装得进画布', () {
      for (final Size area in <Size>[
        const Size(1920, 1040),
        const Size(1280, 720),
        const Size(3840, 2160),
      ]) {
        for (final double dpr in <double>[1.0, 1.25, 1.5]) {
          final WheelCanvasPlan plan = WheelCanvasPlanner.plan(
            petSize: assetSize,
            workArea: area,
            settings: realSettings,
            petVisualBounds: mayaBounds,
          );
          expect(plan.visualFitsCanvas, isTrue,
              reason: 'area=$area dpr=$dpr');
          expect(plan.interactiveFitsCanvas, isTrue,
              reason: 'area=$area dpr=$dpr');
          // 逻辑像素：DPR 不影响计划（plan 不接收 DPR 参数）。
          expect(plan.canvasSize.width, lessThanOrEqualTo(area.width * 1.06 + 1));
        }
      }
    });

    testWidgets('25 负坐标副屏（左侧屏）：画布提交后人物仍可见',
        (WidgetTester tester) async {
      // 副屏在左侧：x ∈ [-1280, 0)。
      const WheelDisplayArea leftMonitor = WheelDisplayArea(
        id: 'left',
        left: -1280,
        top: 0,
        width: 1280,
        height: 1024,
        isPrimary: false,
      );
      final Harness h = await pumpProbe(
        tester,
        petScreen: const Offset(-900, 500),
        display: leftMonitor,
      );
      expect(h.ops.commits, isNotEmpty);
      final Rect canvas = h.ops.commits.last;
      expect(canvas.left, lessThan(0), reason: '负坐标屏的窗口矩形可以是负的');
      final Rect visual = h.state.petVisualScreenRectForTest;
      expect(visual.left, greaterThanOrEqualTo(-1280));
      expect(visual.right, lessThanOrEqualTo(0));
      await h.state.open();
      await tester.pumpAndSettle();
      expect(h.state.wheelWindowFitsCanvas, isTrue);
    });

    testWidgets('26 HWND 矩形在菜单开关期间不变（三次回读一致）',
        (WidgetTester tester) async {
      final Harness h = await pumpProbe(tester, petScreen: const Offset(900, 500));
      final int commitsBefore = h.ops.commits.length;
      final Rect before = h.ops.bounds;
      await h.state.open();
      await tester.pumpAndSettle();
      expect(h.ops.bounds, before);
      await h.state.close();
      await tester.pumpAndSettle();
      expect(h.ops.bounds, before);
      expect(h.ops.commits.length, commitsBefore,
          reason: '开 / 关菜单绝不提交窗口矩形');
    });

    test('27 新增坐标模块不依赖桌面实现（Android 隔离）', () {
      // 纯 Dart 模块不允许 import Flutter 桌面 / windows 平台实现。
      final List<String> forbidden = <String>[
        'dart:io',
        'package:flutter/material.dart',
        'package:window_manager',
        'platform/windows',
        'region_coordinator',
      ];
      final List<String> pure = <String>[
        'wheel_space_pipeline.dart',
        'wheel_visual_bounds.dart',
        'wheel_scale_audit.dart',
        'pet_visual_bounds.dart',
      ];
      for (final String name in pure) {
        final String path = name == 'pet_visual_bounds.dart'
            ? 'lib/character/$name'
            : 'lib/menu/$name';
        final String source = readSource(path);
        for (final String f in forbidden) {
          expect(source.contains(f), isFalse, reason: '$path 不得依赖 $f');
        }
      }
    });
  });
}


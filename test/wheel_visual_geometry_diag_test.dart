/// **C1.1 步骤 A：几何 / 缩放诊断**（真机验收失败后的第一份"事实清单"）。
// 测试脚手架私有类型出现在公共签名里是可接受的（本仓库测试的统一做法）。
// ignore_for_file: library_private_types_in_public_api
///
/// 这一份测试**只打印与断言客观事实**（画布装不装得下轮盘、缺口中心是不是人物
/// 视觉中心、比例是否与 Android 同量级）。作用是把"凭截图猜"换成"看数字"：
///
/// * 真机实际持久化设置：`wheel.scale=0.6` / `wheel.buttonScale=1.3` /
///   `wheel.menuDistance=0.16`，素材 `256×192` 立绘、**可见区仅 92×156**；
/// * 当前代码在 1920×1040 工作区上算出的：画布尺寸 / 锚点 / 四侧预留 /
///   屏幕适配系数 / 轮盘窗口 / 环半径 / 按钮直径 / 缺口半径 / Region；
/// * 轮盘窗口是否**完整**落在画布内（false = 真机上会被 HWND 矩形硬裁切）。
///
/// 它同时是 §十「四张截图回归场景」的几何 JSON 快照来源。
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:petlife/character/pet_visual_bounds.dart';
import 'package:petlife/menu/fixed_canvas_contract.dart';
import 'package:petlife/menu/fixed_canvas_geometry.dart' show PhysicalRect;
import 'package:petlife/menu/region_coordinator.dart';
import 'package:petlife/menu/wheel_canvas_plan.dart';
import 'package:petlife/menu/wheel_geometry.dart' show WheelDisplayArea;
import 'package:petlife/menu/wheel_geometry_ownership.dart'
    show WheelGeometryJournal, wheelGeometryJournal;
import 'package:petlife/menu/wheel_menu_geometry.dart' show WheelMenuLayoutSettings;
import 'package:petlife/ui/desktop/fixed_canvas_probe.dart';

// ---------------------------------------------------------------------------
// 真机实测值（2026-10-07 从 petlife.db 的 local_settings 读出 / 从素材量出）
// ---------------------------------------------------------------------------

/// 素材文件尺寸（`Maya_Cheerful_1.webp` = 256×192）。
const Size realAssetSize = Size(256, 192);

/// 素材 alpha 包围盒（9 帧并集，归一化）：可见人物只有 92×156，且**偏下**。
const double realAlphaL = 0.3047;
const double realAlphaT = 0.1875;
const double realAlphaR = 0.6641;
const double realAlphaB = 1.0;
const Rect realAlphaBounds =
    Rect.fromLTRB(realAlphaL, realAlphaT, realAlphaR, realAlphaB);

/// 真机持久化的设置。
const WheelMenuLayoutSettings realSettings = WheelMenuLayoutSettings(
  preferredScale: 0.6,
  buttonVisualScale: 1.3,
  menuDistance: 0.16,
);

/// 真机工作区（1920×1040）。
const WheelDisplayArea realDisplay = WheelDisplayArea(
  id: 'real',
  left: 0,
  top: 0,
  width: 1920,
  height: 1040,
  isPrimary: true,
);

// ---------------------------------------------------------------------------
// 假实现
// ---------------------------------------------------------------------------

class _Ops implements FixedCanvasWindowOps {
  _Ops(this.bounds, this.display);

  Rect bounds;
  final WheelDisplayArea display;
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
  double devicePixelRatio() => 1.0;
  @override
  Future<void> setVisible(bool visible) async {}
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

class DiagHarness {
  DiagHarness(this.ops, this.regions, this.state);

  final _Ops ops;
  final _RegionOps regions;
  final FixedCanvasProbeState state;
}

Future<DiagHarness> pumpProbe(
  WidgetTester tester, {
  required Offset petScreen,
  PetVisualBounds bounds = const PetVisualBounds(
    realAlphaL,
    realAlphaT,
    realAlphaR,
    realAlphaB,
  ),
}) async {
  tester.view.physicalSize = const Size(1920, 1040);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final _Ops ops = _Ops(Rect.fromLTWH(0, 0, 400, 400), realDisplay);
  final _RegionOps regions = _RegionOps();

  await tester.pumpWidget(MaterialApp(
    home: FixedCanvasProbe(
      key: UniqueKey(),
      windowOps: ops,
      coordinator: RegionCoordinator(
        ops: regions,
        devicePixelRatio: () => 1.0,
        journal: WheelGeometryJournal(capacity: 4000),
      ),
      petSize: () => realAssetSize,
      savedWindowPosition: () =>
          (x: petScreen.dx, y: petScreen.dy, schema: 2, legacyWindowSize: null),
      isMousePassthrough: () => false,
      wheelSettings: () => realSettings,
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
  return DiagHarness(ops, regions, state);
}

/// 把一次打开后的几何链收成一份可打印 / 可 golden 的 JSON 快照。
Map<String, Object?> geometrySnapshot(
  FixedCanvasProbeState state, {
  required String label,
}) {
  final WheelCanvasPlan? plan = state.canvasPlanForTest;
  return <String, Object?>{
    'label': label,
    'persisted': <String, Object?>{
      'wheelScale': state.effectiveWheelSettingsForTest.preferredScale,
      'buttonScale': state.effectiveWheelSettingsForTest.buttonVisualScale,
      'menuDistance': state.effectiveWheelSettingsForTest.menuDistance,
    },
    'petSize': _sz(realAssetSize),
    'petAlphaBounds': _r4(realAlphaBounds),
    'petScreenRect': _r(state.petScreenRectForTest),
    'canvasRect': _r(state.canvasRectForTest),
    'canvasSize': plan == null ? null : _sz(plan.canvasSize),
    'petAnchor': plan == null ? null : _o(plan.petAnchor),
    'reach': plan == null
        ? null
        : <String, Object?>{
            'left': plan.reachLeft,
            'right': plan.reachRight,
            'up': plan.reachUp,
            'down': plan.reachDown,
          },
    'screenFactor': plan?.screenFactor,
    'effectiveScale': plan?.effectiveScale,
    'compressed': plan?.compressed,
    'truncated': plan?.truncated,
    'menuLocalRect': _r(state.menuLocalRectForTest),
    'expansionSide': state.expansionSideForTest?.wireName,
    'envelope': state.wheelEnvelopeForTest == null
        ? null
        : <String, Object?>{
            'windowRect': _r(state.wheelEnvelopeForTest!.windowRect.toRect()),
            'centerX': state.wheelEnvelopeForTest!.centerX,
            'centerY': state.wheelEnvelopeForTest!.centerY,
            'petAnchorX': state.wheelEnvelopeForTest!.petAnchorX,
            'petAnchorY': state.wheelEnvelopeForTest!.petAnchorY,
            'holeRx': state.wheelEnvelopeForTest!.holeRx,
            'holeRy': state.wheelEnvelopeForTest!.holeRy,
            'ringRadiusPx': state.wheelEnvelopeForTest!.maxRingRadiusPx,
            'buttonDiameterPx': state.wheelEnvelopeForTest!.buttonDiameterPx,
            'allowedOffsetPx': state.wheelEnvelopeForTest!.allowedOffsetPx,
            'actualScale': state.wheelEnvelopeForTest!.actualScale,
            'degraded': state.wheelEnvelopeForTest!.degraded,
            'fallbackReason': state.wheelEnvelopeForTest!.fallbackReason,
          },
    'layout': state.wheelLayoutForTest == null
        ? null
        : <String, Object?>{
            'ringRadiusPx': state.wheelLayoutForTest!.ringRadiusPx,
            'bandOuterPx': state.wheelLayoutForTest!.bandOuterPx,
            'rimOuterPx': state.wheelLayoutForTest!.rimOuterPx,
            'bladeLengthPx': state.wheelLayoutForTest!.bladeLengthPx,
            'buttonDiameterPx': state.wheelLayoutForTest!.buttonDiameterPx,
            'fanHalfSpanDeg': state.wheelLayoutForTest!.fanHalfSpanDeg,
            'fanBiasDeg': state.wheelLayoutForTest!.fanBiasDeg,
            'stepDeg': state.wheelLayoutForTest!.stepDeg,
            'notchCenterX': state.wheelLayoutForTest!.notchCenterX,
            'notchCenterY': state.wheelLayoutForTest!.notchCenterY,
            'notchRx': state.wheelLayoutForTest!.notchRx,
            'notchRy': state.wheelLayoutForTest!.notchRy,
            'itemCount': state.wheelLayoutForTest!.itemCount,
          },
    'regionRects': <String>[
      for (final Rect r in state.wheelRegionRects) _r(r),
    ],
    // 关键判据：轮盘窗口必须完整落在画布内，否则真机会被 HWND 矩形硬裁切。
    'wheelWindowFitsCanvas': state.wheelWindowFitsCanvas,
  };
}

String _r(Rect? r) => r == null
    ? 'null'
    : '${r.left.toStringAsFixed(1)},${r.top.toStringAsFixed(1)},'
        '${r.right.toStringAsFixed(1)},${r.bottom.toStringAsFixed(1)}';
String _r4(Rect r) => '${r.left.toStringAsFixed(4)},${r.top.toStringAsFixed(4)},'
    '${r.right.toStringAsFixed(4)},${r.bottom.toStringAsFixed(4)}';
String _sz(Size s) =>
    '${s.width.toStringAsFixed(1)}x${s.height.toStringAsFixed(1)}';
String _o(Offset o) =>
    '${o.dx.toStringAsFixed(1)},${o.dy.toStringAsFixed(1)}';

void main() {
  setUp(() {
    wheelGeometryJournal.clear();
  });
  tearDown(() {
    wheelGeometryJournal.clear();
  });

  testWidgets('A1 真机设置 + 真机素材：画布能否装下轮盘（四个位置）',
      (WidgetTester tester) async {
    const Map<String, Offset> scenarios = <String, Offset>{
      'A-right-bottom': Offset(1376, 534),
      'B-left-bottom': Offset(64, 780),
      'C-left-top': Offset(64, 120),
      'D-center': Offset(900, 500),
    };
    for (final MapEntry<String, Offset> s in scenarios.entries) {
      final DiagHarness h = await pumpProbe(tester, petScreen: s.value);
      await h.state.open();
      await tester.pumpAndSettle();
      final Map<String, Object?> snap =
          geometrySnapshot(h.state, label: s.key);
      // ignore: avoid_print
      print('== A1 ${s.key} ==\n'
          '${const JsonEncoder.withIndent('  ').convert(snap)}');
      expect(h.ops.commits, isNotEmpty);
      await h.state.close();
      await tester.pumpAndSettle();
    }
  });
}

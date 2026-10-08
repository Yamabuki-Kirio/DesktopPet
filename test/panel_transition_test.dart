import 'dart:ui' show Offset, Rect, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:petlife/menu/fixed_canvas_geometry.dart'
    show PhysicalRect, FixedCanvasPersistence, fixedCanvasAnchor;
import 'package:petlife/menu/wheel_geometry_ownership.dart';
import 'package:petlife/menu/windows_surface_mode.dart';
import 'package:petlife/ui/desktop/surface_mode_controller.dart';

/// 回归 #B：控制面板必须是**完整、隔离的窗口形态事务**（进入 14 步 / 返回 10 步）。
///
/// 用假宿主驱动 [SurfaceModeController]，覆盖"清 Region 时机 / 面板尺寸写入 /
/// 不被桌宠回调缩回 / 命中区域 / 返回恢复 / 快速双击只切一次 / 无位置漂移"。
void main() {
  const Size canvasSize = Size(1352, 560);
  const Size panelSize = Size(1180, 760);

  late _FakeHost host;
  late SurfaceModeController controller;

  setUp(() {
    windowsSurfaceSession.resetForTest();
    wheelSurfaceGeometry.resetForTest();
    wheelGeometryJournal.clear();
    fixedCanvasAnchor.clear();
    host = _FakeHost(canvasSize: canvasSize);
    controller = SurfaceModeController(host);
  });

  test('#5 Region 在进入面板前先被清除；#11 先 dismiss 弹窗再清 Region', () async {
    final SurfaceTransitionResult r =
        await controller.enterPanel(panelSize: panelSize);

    expect(r.success, isTrue, reason: r.error);
    final int iDismiss = host.order.indexOf('dismissContextMenu');
    final int iClear = host.order.indexOf('clearRegion');
    final int iBounds = host.order.indexOf('commitPanelBounds');
    expect(iDismiss, greaterThanOrEqualTo(0));
    expect(iClear, greaterThan(iDismiss), reason: '必须先 dismiss 弹窗再清 Region');
    expect(iBounds, greaterThan(iClear), reason: '必须先清 Region 再写面板 bounds');
    // #8 Region 已清 → 面板整块矩形可命中。
    expect(host.regionBox, isNull);
  });

  test('#6 面板态允许 1180×760 写入；模式提交为 panel', () async {
    final SurfaceTransitionResult r =
        await controller.enterPanel(panelSize: panelSize);

    expect(r.success, isTrue, reason: r.error);
    expect(windowsSurfaceSession.mode, WindowsSurfaceMode.panel);
    expect(host.windowBounds.size, panelSize);
    expect(host.order, contains('panelWidget'));
    expect(host.order, contains('showFocus'));
    expect(host.order, contains('visible:false'));
  });

  test('进入过程中 Region 未清干净 → 回滚且不进入面板', () async {
    host.keepRegionAfterClear = true;
    final SurfaceTransitionResult r =
        await controller.enterPanel(panelSize: panelSize);

    expect(r.success, isFalse);
    expect(r.error, 'region_not_cleared');
    expect(host.order.any((String s) => s.startsWith('rollback:')), isTrue);
    expect(windowsSurfaceSession.mode, WindowsSurfaceMode.petFixedCanvas);
  });

  test('#10 快速双击：只允许一次事务', () async {
    final Future<SurfaceTransitionResult> first =
        controller.enterPanel(panelSize: panelSize);
    final SurfaceTransitionResult second =
        await controller.enterPanel(panelSize: panelSize);

    expect(second.success, isFalse);
    await first;
    expect(windowsSurfaceSession.mode, WindowsSurfaceMode.panel);
    expect(wheelGeometryJournal.countOf('panel.transition.start'), 1);
  });

  test('#9 返回桌宠：恢复固定画布 + 仅桌宠 Region + 锚点', () async {
    await controller.enterPanel(panelSize: panelSize);
    final SurfaceTransitionResult r = await controller.returnToPet();

    expect(r.success, isTrue, reason: r.error);
    expect(windowsSurfaceSession.mode, WindowsSurfaceMode.petFixedCanvas);
    expect(host.windowBounds.size, canvasSize);
    expect(host.regionBox, isNotNull, reason: '必须重新应用仅桌宠 Region');
    expect(fixedCanvasAnchor.enabled, isTrue);
    expect(host.order, contains('petWidget'));
  });

  test('返回失败（Region 应用失败）→ 回滚到普通矩形窗口并给显式错误', () async {
    await controller.enterPanel(panelSize: panelSize);
    host.failPetRegion = true;

    final SurfaceTransitionResult r = await controller.returnToPet();

    expect(r.success, isFalse);
    expect(r.error, 'pet_canvas_invalid');
    expect(host.order.any((String s) => s.startsWith('rollback:')), isTrue);
    expect(host.order.any((String s) => s.startsWith('status:')), isTrue);
    expect(windowsSurfaceSession.mode, WindowsSurfaceMode.petFixedCanvas);
    expect(host.regionBox, isNull);
  });

  test('#12 20 次往返不积累位置漂移（画布矩形恒定）', () async {
    const Offset savedPetScreen = Offset(900, 480);
    const Offset anchor = Offset(548, 152);
    final double expectedLeft = savedPetScreen.dx - anchor.dx;
    final double expectedTop = savedPetScreen.dy - anchor.dy;

    // 纯几何口径：每次往返都从同一个"保存的桌宠屏幕位置"换算。
    for (int i = 0; i < 20; i++) {
      final Offset win = FixedCanvasPersistence.windowPositionFromPetScreen(
        petScreenPosition: savedPetScreen,
        petAnchor: anchor,
      );
      expect(win.dx, expectedLeft);
      expect(win.dy, expectedTop);
    }

    // 端到端：20 次 进入 / 返回 后仍稳定在桌宠固定画布态。
    for (int i = 0; i < 20; i++) {
      final SurfaceTransitionResult enter =
          await controller.enterPanel(panelSize: panelSize);
      expect(enter.success, isTrue, reason: '第 $i 次进入失败：${enter.error}');
      final SurfaceTransitionResult back = await controller.returnToPet();
      expect(back.success, isTrue, reason: '第 $i 次返回失败：${back.error}');
    }
    expect(windowsSurfaceSession.mode, WindowsSurfaceMode.petFixedCanvas);
    expect(host.windowBounds.size, canvasSize);
  });
}

class _FakeHost implements SurfaceTransactionHost {
  _FakeHost({required this.canvasSize})
      : windowBounds = Rect.fromLTWH(100, 100, canvasSize.width, canvasSize.height),
        regionBox = const PhysicalRect(500, 300, 756, 556);

  final Size canvasSize;

  final List<String> order = <String>[];
  Rect windowBounds;
  PhysicalRect? regionBox;
  bool keepRegionAfterClear = false;
  bool failPetRegion = false;

  @override
  Future<void> closeWheelMenu() async => order.add('closeWheelMenu');

  @override
  Future<void> dismissContextMenuAndWait() async => order.add('dismissContextMenu');

  @override
  Future<void> suspendFixedCanvas() async {
    order.add('suspendFixedCanvas');
    fixedCanvasAnchor.clear();
  }

  @override
  Future<void> invalidateAllRegionTransactions(String reason) async {
    order.add('invalidateAll:$reason');
  }

  @override
  Future<bool> clearRegionForPanel() async {
    order.add('clearRegion');
    if (!keepRegionAfterClear) regionBox = null;
    return true;
  }

  @override
  Future<PhysicalRect?> readRegionBoundingBox() async => regionBox;

  @override
  Future<void> setWindowVisible(bool visible) async => order.add('visible:$visible');

  @override
  Future<void> restorePanelWindowAttributes() async => order.add('panelAttrs');

  @override
  Future<Rect> commitPanelBounds() async {
    order.add('commitPanelBounds');
    windowBounds = Rect.fromLTWH(100, 100, 1180, 760);
    return windowBounds;
  }

  @override
  Future<void> showPanelWidgetAndSettle() async => order.add('panelWidget');

  @override
  Future<Rect> readWindowBounds() async => windowBounds;

  @override
  Future<bool> isBoundsFullyVisible(Rect bounds) async => true;

  @override
  Future<void> showWindowAndFocus() async => order.add('showFocus');

  @override
  Future<Rect> commitFixedCanvasBounds() async {
    order.add('commitCanvas');
    windowBounds = Rect.fromLTWH(100, 100, canvasSize.width, canvasSize.height);
    fixedCanvasAnchor.set(const Offset(548, 152), enabled: true);
    return windowBounds;
  }

  @override
  Future<void> showPetWidgetAndSettle() async => order.add('petWidget');

  @override
  Future<bool> applyPetOnlyRegion() async {
    order.add('petRegion');
    if (!failPetRegion) {
      regionBox = const PhysicalRect(500, 300, 756, 556);
    }
    return !failPetRegion;
  }

  @override
  Future<Rect> readPetScreenRect() async => const Rect.fromLTWH(648, 252, 256, 256);

  @override
  Future<void> rollbackToRectangularPet(String reason) async {
    order.add('rollback:$reason');
    regionBox = null;
    windowBounds = Rect.fromLTWH(100, 100, 256, 256);
  }

  @override
  Future<void> showStatusMessage(String message) async => order.add('status:$message');

  @override
  Size get petLogicalSize => const Size(256, 256);

  @override
  Size get fixedCanvasSize => canvasSize;
}

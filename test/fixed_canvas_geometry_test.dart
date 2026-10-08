import 'dart:ui' show Offset, Rect, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:petlife/menu/fixed_canvas_geometry.dart';
import 'package:petlife/menu/wheel_geometry.dart' show WheelDisplayArea;

/// 固定画布 + Region 的**纯 Dart 几何**单测。
///
/// 覆盖：画布尺寸公式、petAnchor、画布窗口矩形、Region（仅桌宠 / 桌宠+菜单）、
/// 菜单镜像与夹取、DPI 换算（100% / 125% / 150%）、位置持久化与负坐标。
void main() {
  const FixedCanvasConfig config = FixedCanvasConfig();
  final Size canvas = config.canvasSize;

  group('画布尺寸公式与 petAnchor', () {
    test('画布容纳"桌宠 + 两侧最大菜单 + 边距"', () {
      // width = maxPet + 2*(maxWheel + gap) + margin*2
      final double expectedW =
          config.maxPetSide + 2 * (config.maxWheelSide + config.menuGap) + config.margin * 2;
      final double expectedH =
          (config.maxPetSide > config.maxWheelSide ? config.maxPetSide : config.maxWheelSide) +
              config.margin * 2;
      expect(canvas.width, expectedW);
      expect(canvas.height, expectedH);
    });

    test('最大桌宠左右两侧都放得下最大菜单（镜像前提）', () {
      final Size pet = Size(config.maxPetSide, config.maxPetSide);
      final Offset anchor = config.petAnchorFor(pet);
      final double leftRoom = anchor.dx;
      final double rightRoom = canvas.width - anchor.dx - pet.width;
      expect(leftRoom, greaterThanOrEqualTo(config.maxWheelSide + config.menuGap));
      expect(rightRoom, greaterThanOrEqualTo(config.maxWheelSide + config.menuGap));
    });

    test('petAnchor = 画布中心 - 桌宠一半（尺寸无关的居中）', () {
      final Offset anchor = config.petAnchorFor(const Size(256, 256));
      expect(anchor.dx, (canvas.width - 256) / 2);
      expect(anchor.dy, (canvas.height - 256) / 2);
    });
  });

  group('画布窗口矩形与 Region', () {
    const Offset petScreen = Offset(1200, 700);
    const Size pet = Size(256, 256);
    final Offset anchor = config.petAnchorFor(pet);
    final Rect canvasRect = FixedCanvasGeometry.canvasWindowRect(
      petScreenPosition: petScreen,
      petAnchor: anchor,
      canvas: canvas,
    );

    test('画布窗口矩形 = 桌宠屏幕位置 - petAnchor', () {
      expect(canvasRect.left, petScreen.dx - anchor.dx);
      expect(canvasRect.top, petScreen.dy - anchor.dy);
      expect(canvasRect.size, canvas);
    });

    test('桌宠屏幕矩形与输入完全一致（不变量）', () {
      final Rect petScreenRect = FixedCanvasGeometry.petScreenRect(
        canvasWindowRect: canvasRect,
        petAnchor: anchor,
        petSize: pet,
      );
      expect(petScreenRect.left, petScreen.dx);
      expect(petScreenRect.top, petScreen.dy);
      expect(petScreenRect.size, pet);
    });

    test('仅桌宠 Region 不含周围透明画布', () {
      final List<Rect> region =
          FixedCanvasGeometry.petOnlyRegion(petAnchor: anchor, petSize: pet);
      expect(region, hasLength(1));
      expect(region.single.size, pet);
      expect(region.single.width, lessThan(canvas.width));
      expect(region.single.height, lessThan(canvas.height));
    });

    test('桌宠 + 菜单 Region 只含这两块', () {
      final Rect petLocal =
          FixedCanvasGeometry.petLocalRect(petAnchor: anchor, petSize: pet);
      final Rect menu = Rect.fromLTWH(anchor.dx + pet.width + 12, anchor.dy, 384, 360);
      final List<Rect> region = FixedCanvasGeometry.petAndMenuRegion(
        petLocalRect: petLocal,
        menuLocalRect: menu,
      );
      expect(region, hasLength(2));
      expect(region.first, petLocal);
      expect(region.last, menu);
    });
  });

  group('菜单在固定画布内的布局（镜像 / 夹取）', () {
    const Size pet = Size(256, 256);
    final Offset anchor = config.petAnchorFor(pet);
    const Size menu = Size(320, 300);
    const WheelDisplayArea display =
        WheelDisplayArea(id: 'd', left: 0, top: 0, width: 1920, height: 1080);

    test('桌宠靠左 → 菜单在右侧', () {
      final FixedCanvasMenuLayoutResult r = FixedCanvasGeometry.computeMenu(
        petAnchor: anchor,
        petSize: pet,
        canvas: canvas,
        menuSize: menu,
        display: display,
        petScreenPosition: const Offset(100, 400),
        gap: config.menuGap,
      );
      expect(r.menuOnRight, isTrue);
      expect(r.menuLocalRect.left, anchor.dx + pet.width + config.menuGap);
    });

    test('桌宠靠右 → 菜单在左侧（镜像）', () {
      final FixedCanvasMenuLayoutResult r = FixedCanvasGeometry.computeMenu(
        petAnchor: anchor,
        petSize: pet,
        canvas: canvas,
        menuSize: menu,
        display: display,
        petScreenPosition: const Offset(1600, 400),
        gap: config.menuGap,
      );
      expect(r.menuOnRight, isFalse);
      expect(r.menuLocalRect.left, anchor.dx - config.menuGap - menu.width);
    });

    test('菜单始终落在固定画布内（不溢出，绝不改窗口）', () {
      for (final Offset p in <Offset>[
        const Offset(0, 0),
        const Offset(1800, 1000),
        const Offset(-500, -300),
        const Offset(960, 540),
      ]) {
        final FixedCanvasMenuLayoutResult r = FixedCanvasGeometry.computeMenu(
          petAnchor: anchor,
          petSize: pet,
          canvas: canvas,
          menuSize: menu,
          display: display,
          petScreenPosition: p,
          gap: config.menuGap,
        );
        expect(r.menuLocalRect.left, greaterThanOrEqualTo(0));
        expect(r.menuLocalRect.top, greaterThanOrEqualTo(0));
        expect(r.menuLocalRect.right, lessThanOrEqualTo(canvas.width + 0.001));
        expect(r.menuLocalRect.bottom, lessThanOrEqualTo(canvas.height + 0.001));
      }
    });

    test('镜像只改变菜单局部矩形，不改桌宠锚点', () {
      final Offset anchorBefore = anchor;
      FixedCanvasGeometry.computeMenu(
        petAnchor: anchor,
        petSize: pet,
        canvas: canvas,
        menuSize: menu,
        display: display,
        petScreenPosition: const Offset(100, 400),
        gap: config.menuGap,
      );
      FixedCanvasGeometry.computeMenu(
        petAnchor: anchor,
        petSize: pet,
        canvas: canvas,
        menuSize: menu,
        display: display,
        petScreenPosition: const Offset(1600, 400),
        gap: config.menuGap,
      );
      expect(anchor, anchorBefore);
    });
  });

  group('DPI 换算（100% / 125% / 150%）', () {
    const Rect logical = Rect.fromLTWH(100, 50, 256, 256);

    test('100%：devicePixelRatio = 1.0', () {
      final PhysicalRect r = FixedCanvasDpi.rectToPhysical(logical, 1.0);
      expect(r, const PhysicalRect(100, 50, 356, 306));
      expect(FixedCanvasDpi.dpiFromDevicePixelRatio(1.0), 96);
    });

    test('125%：devicePixelRatio = 1.25', () {
      final PhysicalRect r = FixedCanvasDpi.rectToPhysical(logical, 1.25);
      expect(r, const PhysicalRect(125, 63, 445, 383));
      expect(FixedCanvasDpi.dpiFromDevicePixelRatio(1.25), 120);
    });

    test('150%：devicePixelRatio = 1.5', () {
      final PhysicalRect r = FixedCanvasDpi.rectToPhysical(logical, 1.5);
      expect(r, const PhysicalRect(150, 75, 534, 459));
      expect(FixedCanvasDpi.dpiFromDevicePixelRatio(1.5), 144);
    });

    test('矩形列表换算会过滤空矩形', () {
      final List<PhysicalRect> rects = FixedCanvasDpi.rectsToPhysical(
        <Rect>[logical, Rect.zero],
        2.0,
      );
      expect(rects, hasLength(1));
      expect(rects.single, const PhysicalRect(200, 100, 712, 612));
    });
  });

  group('位置持久化（保存桌宠锚点屏幕位置）', () {
    const Offset anchor = Offset(548, 152);
    const Offset petScreen = Offset(1200, 700);
    const Offset windowPos = Offset(652, 548);

    test('拖动结束：petScreen = window + petAnchor', () {
      expect(
        FixedCanvasPersistence.petScreenPositionFromWindow(
          windowPosition: windowPos,
          petAnchor: anchor,
        ),
        petScreen,
      );
    });

    test('启动恢复：window = petScreen - petAnchor', () {
      expect(
        FixedCanvasPersistence.windowPositionFromPetScreen(
          petScreenPosition: petScreen,
          petAnchor: anchor,
        ),
        windowPos,
      );
    });

    test('往返无损（正坐标）', () {
      final Offset back = FixedCanvasPersistence.windowPositionFromPetScreen(
        petScreenPosition: FixedCanvasPersistence.petScreenPositionFromWindow(
          windowPosition: windowPos,
          petAnchor: anchor,
        ),
        petAnchor: anchor,
      );
      expect(back, windowPos);
    });

    test('负坐标（副屏在左侧 / 上方）往返无损', () {
      const Offset negativeWindow = Offset(-2000, -1400);
      final Offset pet = FixedCanvasPersistence.petScreenPositionFromWindow(
        windowPosition: negativeWindow,
        petAnchor: anchor,
      );
      expect(pet.dx, lessThan(0));
      final Offset restored = FixedCanvasPersistence.windowPositionFromPetScreen(
        petScreenPosition: pet,
        petAnchor: anchor,
      );
      expect(restored, negativeWindow);
    });
  });

  group('锚点共享状态', () {
    test('set / clear 语义', () {
      final FixedCanvasAnchorState a = FixedCanvasAnchorState();
      expect(a.enabled, isFalse);
      a.set(const Offset(10, 20), enabled: true);
      expect(a.enabled, isTrue);
      expect(a.anchor, const Offset(10, 20));
      a.set(const Offset(10, 20), enabled: false);
      expect(a.enabled, isFalse);
      a.set(const Offset(1, 2), enabled: true);
      a.clear();
      expect(a.enabled, isFalse);
      expect(a.anchor, isNull);
    });
  });
}

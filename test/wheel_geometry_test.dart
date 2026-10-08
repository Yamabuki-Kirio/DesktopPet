import 'dart:ui' show Rect, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:petlife/menu/wheel_geometry.dart';

/// 增量 A：轮盘几何**纯 Dart** 用例（可在 flutter_tester 直接跑）。
///
/// 覆盖需求点名要过的几类：
/// * 左 / 右展开；
/// * 上 / 下边缘夹取；
/// * 负坐标（副屏在主屏左侧 / 上方）；
/// * DPI 换算（100% / 125% / 150%）；
/// * open→close 往返无漂移；
/// * 连续 20 轮无累积误差；
/// * 桌宠屏幕矩形不变量；
/// * 关闭后窗口回到桌宠矩形。
void main() {
  const WheelMenuLayout layout = WheelMenuLayout(menuSize: Size(320, 320), gap: 12);

  WheelDisplayArea display() =>
      const WheelDisplayArea(id: '1', left: 0, top: 0, width: 1920, height: 1080);

  group('左右展开', () {
    test('空间足够 → 菜单在右侧，桌宠留在窗口左上角', () {
      const Rect pet = Rect.fromLTWH(600, 400, 256, 192);
      final WheelGeometryResult r =
          WheelGeometry.compute(petRect: pet, layout: layout, display: display());

      expect(r.menuOnRight, isTrue);
      expect(r.clamped, isFalse);
      // 菜单在右侧：桌宠水平补偿为 0（窗口左边界 = 桌宠左边界）。
      expect(r.windowRect.left, 600);
      expect(r.petLocal.dx, 0);
      // 竖直方向菜单相对桌宠居中，可能把窗口顶边抬高（桌宠因此有 dy 补偿）。
      expect(r.windowRect.top + r.petLocal.dy, 400);
      // 菜单在桌宠右侧 + gap。
      expect(r.menuScreenRect.left, 600 + 256 + 12);
      // 窗口必须同时容纳桌宠与菜单。
      expect(r.windowRect.contains(r.petScreenRect.topLeft), isTrue);
      expect(r.windowRect.right, greaterThanOrEqualTo(r.menuScreenRect.right));
      expect(r.windowRect.bottom, greaterThanOrEqualTo(r.menuScreenRect.bottom));
    });

    test('右侧放不下 → 菜单在左侧，桌宠补偿 dx = 菜单宽 + gap', () {
      const Rect pet = Rect.fromLTWH(1700, 400, 200, 192);
      final WheelGeometryResult r =
          WheelGeometry.compute(petRect: pet, layout: layout, display: display());

      expect(r.menuOnRight, isFalse);
      expect(r.menuScreenRect.right, 1700 - 12);
      expect(r.petLocal.dx, 320 + 12);
      // 补偿后桌宠屏幕坐标不变。
      expect(r.windowRect.left + r.petLocal.dx, 1700);
    });
  });

  group('上下边缘夹取', () {
    test('贴近上边缘 → 菜单贴顶，桌宠补偿 dy=0', () {
      const Rect pet = Rect.fromLTWH(600, 0, 200, 200);
      final WheelGeometryResult r =
          WheelGeometry.compute(petRect: pet, layout: layout, display: display());

      expect(r.clamped, isTrue);
      expect(r.menuScreenRect.top, 0);
      expect(r.windowRect.top, 0);
      expect(r.petLocal.dy, 0);
    });

    test('贴近下边缘 → 菜单贴底，仍在显示器内', () {
      const Rect pet = Rect.fromLTWH(600, 980, 200, 100);
      final WheelGeometryResult r =
          WheelGeometry.compute(petRect: pet, layout: layout, display: display());

      expect(r.clamped, isTrue);
      expect(r.menuScreenRect.bottom, lessThanOrEqualTo(1080));
      expect(r.windowRect.bottom, greaterThanOrEqualTo(r.menuScreenRect.bottom));
      // 桌宠屏幕坐标不变量。
      expect(r.windowRect.top + r.petLocal.dy, 980);
    });
  });

  group('负坐标（副屏在主屏左侧 / 上方）', () {
    const WheelDisplayArea leftTop =
        WheelDisplayArea(id: '2', left: -1920, top: -200, width: 1920, height: 1080);

    test('菜单保持在负坐标显示器可见范围内，桌宠不动', () {
      const Rect pet = Rect.fromLTWH(-300, -100, 200, 200);
      final WheelGeometryResult r =
          WheelGeometry.compute(petRect: pet, layout: layout, display: leftTop);

      expect(r.menuScreenRect.left, greaterThanOrEqualTo(-1920));
      expect(r.menuScreenRect.top, greaterThanOrEqualTo(-200));
      expect(r.menuScreenRect.bottom, lessThanOrEqualTo(-200 + 1080));
      expect(r.petScreenRect, pet);
      expect(r.windowRect.topLeft + r.petLocal, pet.topLeft);
    });

    test('两侧都放不下 → 夹到显示器内且桌宠坐标不变', () {
      // 显示器很窄（400 宽），桌宠几乎占满，菜单无论左右都放不下。
      const WheelDisplayArea narrow =
          WheelDisplayArea(id: '3', left: -400, top: 0, width: 400, height: 1080);
      const Rect pet = Rect.fromLTWH(-250, 400, 200, 200);
      final WheelGeometryResult r =
          WheelGeometry.compute(petRect: pet, layout: layout, display: narrow);

      expect(r.clamped, isTrue);
      expect(r.windowRect.topLeft + r.petLocal, pet.topLeft);
    });
  });

  group('DPI / 逻辑-物理换算', () {
    test('100% / 125% / 150% 的物理→逻辑换算', () {
      const Rect physical = Rect.fromLTWH(0, 0, 1920, 1080);
      expect(WheelDpi.physicalToLogicalRect(physical, 1.0), physical);
      expect(
        WheelDpi.physicalToLogicalRect(physical, 1.25),
        const Rect.fromLTWH(0, 0, 1536, 864),
      );
      expect(
        WheelDpi.physicalToLogicalRect(physical, 1.5),
        const Rect.fromLTWH(0, 0, 1280, 720),
      );
    });

    test('逻辑→物理→逻辑 往返一致', () {
      const Rect logical = Rect.fromLTWH(100, 50, 320, 200);
      for (final double dpr in <double>[1.0, 1.25, 1.5]) {
        final Rect roundTrip = WheelDpi.physicalToLogicalRect(
          WheelDpi.logicalToPhysicalRect(logical, dpr),
          dpr,
        );
        expect(roundTrip.left, closeTo(logical.left, 1e-9));
        expect(roundTrip.top, closeTo(logical.top, 1e-9));
        expect(roundTrip.width, closeTo(logical.width, 1e-9));
        expect(roundTrip.height, closeTo(logical.height, 1e-9));
      }
    });

    test('DPI = 96 × 缩放比', () {
      expect(WheelDpi.dpiFromDevicePixelRatio(1.0), 96);
      expect(WheelDpi.dpiFromDevicePixelRatio(1.25), 120);
      expect(WheelDpi.dpiFromDevicePixelRatio(1.5), 144);
    });
  });

  group('open→close 往返', () {
    test('往返一次无漂移：close 精确回到打开前的窗口矩形', () {
      const Rect pet = Rect.fromLTWH(600, 400, 256, 192);
      final WheelGeometrySession session = WheelGeometrySession.start(
        petRect: pet,
        layout: layout,
        display: display(),
      );

      final WheelGeometryResult open = session.open();
      expect(session.isOpen, isTrue);
      expect(open.petScreenRect, pet);
      expect(open.windowRect.topLeft + open.petLocal, pet.topLeft);

      final Rect restored = session.close();
      expect(session.isOpen, isFalse);
      expect(restored, pet);
    });

    test('连续 20 轮无累积误差', () {
      const Rect pet = Rect.fromLTWH(600, 400, 256, 192);
      Rect? firstOpen;
      for (int i = 0; i < 20; i++) {
        final WheelGeometrySession session = WheelGeometrySession.start(
          petRect: pet,
          layout: layout,
          display: display(),
        );
        final WheelGeometryResult open = session.open();
        firstOpen ??= open.windowRect;
        // 每一轮的扩窗结果都完全一致（不随轮次漂移）。
        expect(open.windowRect, firstOpen);
        expect(open.petScreenRect, pet);
        // 关闭后精确回到桌宠矩形。
        expect(session.close(), pet);
      }
    });

    test('桌宠屏幕矩形不变量：多组位置都成立', () {
      const List<Rect> pets = <Rect>[
        Rect.fromLTWH(0, 0, 256, 192),
        Rect.fromLTWH(1660, 900, 256, 192),
        Rect.fromLTWH(960, 540, 128, 96),
        Rect.fromLTWH(1900, 0, 20, 20),
      ];
      for (final Rect pet in pets) {
        final WheelGeometryResult r =
            WheelGeometry.compute(petRect: pet, layout: layout, display: display());
        expect(r.petScreenRect, pet, reason: '桌宠屏幕矩形必须恒定');
        expect(r.windowRect.topLeft + r.petLocal, pet.topLeft);
      }
    });
  });
}

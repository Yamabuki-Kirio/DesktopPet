import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:petlife/menu/fixed_canvas_geometry.dart' show fixedCanvasAnchor;
import 'package:petlife/menu/wheel_geometry_ownership.dart';
import 'package:petlife/menu/windows_surface_mode.dart';
import 'package:petlife/platform/windows/windows_surface_channel.dart';

/// 回归 #B：显式模式机 + 代际，保证切换是一次"完整、隔离"的事务。
void main() {
  setUp(() {
    windowsSurfaceSession.resetForTest();
    wheelSurfaceGeometry.resetForTest();
    wheelGeometryJournal.clear();
    fixedCanvasAnchor.clear();
  });

  group('模式语义', () {
    test('wireName 与模式一一对应', () {
      expect(WindowsSurfaceMode.petFixedCanvas.wireName, 'pet_fixed_canvas');
      expect(WindowsSurfaceMode.transitioningToPanel.wireName, 'transitioning_to_panel');
      expect(WindowsSurfaceMode.panel.wireName, 'panel');
      expect(WindowsSurfaceMode.transitioningToPet.wireName, 'transitioning_to_pet');
    });

    test('只有稳定的桌宠态允许素材尺寸写窗口', () {
      expect(WindowsSurfaceMode.petFixedCanvas.allowsPetResize, isTrue);
      expect(WindowsSurfaceMode.transitioningToPanel.allowsPetResize, isFalse);
      expect(WindowsSurfaceMode.panel.allowsPetResize, isFalse);
      expect(WindowsSurfaceMode.transitioningToPet.allowsPetResize, isFalse);
    });

    test('只有面板侧允许面板几何', () {
      expect(WindowsSurfaceMode.panel.allowsPanelGeometry, isTrue);
      expect(WindowsSurfaceMode.transitioningToPanel.allowsPanelGeometry, isTrue);
      expect(WindowsSurfaceMode.petFixedCanvas.allowsPanelGeometry, isFalse);
      expect(WindowsSurfaceMode.transitioningToPet.allowsPanelGeometry, isFalse);
    });

    test('isPanelLike / isPetLike 互斥且完整', () {
      for (final WindowsSurfaceMode m in WindowsSurfaceMode.values) {
        expect(m.isPanelLike || m.isPetLike, isTrue, reason: m.wireName);
        expect(m.isPanelLike && m.isPetLike, isFalse, reason: m.wireName);
      }
    });
  });

  group('代际（generation）门控', () {
    test('每次切换都递增代际并记录诊断事件', () {
      final int g0 = windowsSurfaceSession.generation;
      final int g1 = windowsSurfaceSession.changeTo(
        WindowsSurfaceMode.transitioningToPanel,
        source: 'test',
      );
      final int g2 = windowsSurfaceSession.changeTo(
        WindowsSurfaceMode.panel,
        source: 'test',
      );

      expect(g1, g0 + 1);
      expect(g2, g1 + 1);
      expect(wheelGeometryJournal.contains('surface.mode.changed'), isTrue);
      expect(wheelGeometryJournal.contains('surface.generation'), isTrue);
      expect(
        wheelGeometryJournal.countOf('surface.mode.changed'),
        2,
        reason: '每次切换都必须记录一次',
      );
    });

    test('isCurrent：过期代际 / 不匹配模式都必须判否', () {
      final int gen = windowsSurfaceSession.changeTo(
        WindowsSurfaceMode.transitioningToPanel,
        source: 'test',
      );
      expect(
        windowsSurfaceSession.isCurrent(gen, mode: WindowsSurfaceMode.transitioningToPanel),
        isTrue,
      );
      // 模式不符。
      expect(
        windowsSurfaceSession.isCurrent(gen, mode: WindowsSurfaceMode.panel),
        isFalse,
      );
      // 代际已过期。
      windowsSurfaceSession.changeTo(WindowsSurfaceMode.panel, source: 'test');
      expect(
        windowsSurfaceSession.isCurrent(gen, mode: WindowsSurfaceMode.transitioningToPanel),
        isFalse,
      );
    });
  });

  group('几何守卫必须先看模式', () {
    test('面板态：PetResizeDecision 丢弃（旧 pet 回调不得写窗口）', () {
      windowsSurfaceSession.changeTo(WindowsSurfaceMode.panel, source: 'test');
      wheelSurfaceGeometry.change(WindowsSurfaceGeometryOwner.panel, source: 'test');

      final String? drop = PetResizeDecision.evaluate(
        mounted: true,
        scheduledGeneration: wheelSurfaceGeometry.generation,
        surface: wheelSurfaceGeometry,
      );

      expect(drop, 'surface_panel');
    });

    test('过渡态：PetResizeDecision 丢弃', () {
      windowsSurfaceSession.changeTo(
        WindowsSurfaceMode.transitioningToPanel,
        source: 'test',
      );
      final String? drop = PetResizeDecision.evaluate(
        mounted: true,
        scheduledGeneration: wheelSurfaceGeometry.generation,
        surface: wheelSurfaceGeometry,
      );
      expect(drop, 'surface_transitioning_to_panel');
    });

    test('#7 面板态：固定画布 commitBounds 被丢弃（不会把 1180×760 缩回 1352×560）', () async {
      windowsSurfaceSession.changeTo(WindowsSurfaceMode.panel, source: 'test');
      const WindowsFixedCanvasWindowOps ops = WindowsFixedCanvasWindowOps();

      // 面板态下即使调用固定画布的提交点，也必须被守卫拦下（不触碰原生窗口）。
      await ops.commitBounds(const Rect.fromLTWH(10, 10, 1352, 560));

      expect(wheelGeometryJournal.contains('geometry.size.write.dropped'), isTrue);
      expect(
        wheelGeometryJournal.lastOf('geometry.size.write.dropped')?.fields['reason'],
        'surface_panel',
      );
    });

    test('桌宠态：允许按素材尺寸写窗口（守卫放行）', () {
      windowsSurfaceSession.changeTo(WindowsSurfaceMode.petFixedCanvas, source: 'test');
      final String? drop = PetResizeDecision.evaluate(
        mounted: true,
        scheduledGeneration: wheelSurfaceGeometry.generation,
        surface: wheelSurfaceGeometry,
      );
      expect(drop, isNull);
    });
  });
}

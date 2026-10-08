import 'dart:ui' show Rect, Offset;

import 'package:flutter_test/flutter_test.dart';
import 'package:petlife/menu/wheel_geometry_ownership.dart';

/// 增量 A 修复：几何**所有权 / 代际 / 事件日志**的纯 Dart 用例。
///
/// 覆盖需求 §1 / §2 的核心不变量：
/// * 每次所有权切换 generation++;
/// * 只有 owner=pet 才允许 pet resize；
/// * 过渡 / 菜单期，延迟回调全部被判为"过期"而丢弃；
/// * 每次尺寸写入都能看出是谁覆盖了谁。
void main() {
  late WheelSurfaceGeometry surface;
  late WheelGeometryJournal journal;

  setUp(() {
    journal = WheelGeometryJournal();
    surface = WheelSurfaceGeometry(journal: journal);
  });

  group('所有权与代际', () {
    test('初始为 pet，允许 pet resize', () {
      expect(surface.owner, WindowsSurfaceGeometryOwner.pet);
      expect(surface.generation, 0);
      expect(surface.allowsPetResize, isTrue);
      expect(surface.isMenuOpen, isFalse);
    });

    test('每次切换 generation 递增，且写入 owner.changed + generation 事件', () {
      expect(surface.change(WindowsSurfaceGeometryOwner.wheelTransition), 1);
      expect(surface.change(WindowsSurfaceGeometryOwner.wheel), 2);
      expect(surface.change(WindowsSurfaceGeometryOwner.pet), 3);
      expect(surface.generation, 3);
      expect(journal.countOf('geometry.owner.changed'), 3);
      expect(journal.countOf('geometry.generation'), 3);
    });

    test('切到同值不递增、不发事件（避免无意义代际跳变）', () {
      surface.change(WindowsSurfaceGeometryOwner.wheel);
      final int g = surface.generation;
      expect(surface.change(WindowsSurfaceGeometryOwner.wheel), g);
      expect(surface.generation, g);
      expect(journal.countOf('geometry.owner.changed'), 1);
    });

    test('只有 pet 允许 resize；wheelTransition / wheel / panel 全部禁止', () {
      for (final WindowsSurfaceGeometryOwner owner in <WindowsSurfaceGeometryOwner>[
        WindowsSurfaceGeometryOwner.wheelTransition,
        WindowsSurfaceGeometryOwner.wheel,
        WindowsSurfaceGeometryOwner.panel,
      ]) {
        surface.change(owner);
        expect(surface.allowsPetResize, isFalse, reason: owner.wireName);
      }
      expect(surface.change(WindowsSurfaceGeometryOwner.pet), greaterThan(0));
      expect(surface.allowsPetResize, isTrue);
    });

    test('isMenuOpen 覆盖 wheelTransition 与 wheel', () {
      surface.change(WindowsSurfaceGeometryOwner.wheelTransition);
      expect(surface.isMenuOpen, isTrue);
      expect(surface.isTransitioning, isTrue);
      surface.change(WindowsSurfaceGeometryOwner.wheel);
      expect(surface.isMenuOpen, isTrue);
      expect(surface.isTransitioning, isFalse);
      surface.change(WindowsSurfaceGeometryOwner.pet);
      expect(surface.isMenuOpen, isFalse);
    });
  });

  group('延迟 resize 判定（PetResizeDecision）', () {
    test('generation 变化 → 丢弃', () {
      surface.change(WindowsSurfaceGeometryOwner.wheelTransition); // gen 1
      final String? reason = PetResizeDecision.evaluate(
        mounted: true,
        scheduledGeneration: 0,
        surface: surface,
      );
      expect(reason, 'generation_changed');
    });

    test('owner 不是 pet → 丢弃', () {
      final int gen = surface.change(WindowsSurfaceGeometryOwner.wheel);
      final String? reason = PetResizeDecision.evaluate(
        mounted: true,
        scheduledGeneration: gen,
        surface: surface,
      );
      expect(reason, 'owner_wheel');
    });

    test('未挂载 → 丢弃', () {
      final String? reason = PetResizeDecision.evaluate(
        mounted: false,
        scheduledGeneration: surface.generation,
        surface: surface,
      );
      expect(reason, 'unmounted');
    });

    test('owner=pet 且代际一致 → 允许执行', () {
      final String? reason = PetResizeDecision.evaluate(
        mounted: true,
        scheduledGeneration: surface.generation,
        surface: surface,
      );
      expect(reason, isNull);
    });
  });

  group('事件日志与尺寸写入', () {
    test('recordSizeWrite 记录 source/generation/owner/requested/before/after', () {
      journal.recordSizeWrite(
        source: 'WindowsPetHost.resizeForPet',
        generation: 2,
        owner: WindowsSurfaceGeometryOwner.pet,
        requested: const Rect.fromLTWH(100, 100, 256, 192),
        before: const Rect.fromLTWH(100, 100, 256, 192),
        after: const Rect.fromLTWH(100, 100, 256, 192),
      );
      final WheelGeometryEvent event = journal.lastOf('geometry.size.write')!;
      expect(event.fields['source'], 'WindowsPetHost.resizeForPet');
      expect(event.fields['generation'], 2);
      expect(event.fields['owner'], 'pet');
      expect(event.fields['requested'], contains('256'));
      expect(event.fields['overwrote_previous'], isFalse);
    });

    test('两次写入之间若窗口被第三者改过，overwrote_previous=true（能看出谁覆盖谁）', () {
      journal.recordSizeWrite(
        source: 'wheel.open.commitBounds',
        generation: 1,
        owner: WindowsSurfaceGeometryOwner.wheelTransition,
        requested: const Rect.fromLTWH(600, 336, 588, 320),
        before: const Rect.fromLTWH(600, 400, 256, 192),
        after: const Rect.fromLTWH(600, 336, 588, 320),
      );
      // 第二次写入的 before 是"被缩回"的桌宠尺寸，而不是上一次的 after。
      journal.recordSizeWrite(
        source: 'WindowsPetHost.resizeForPet',
        generation: 2,
        owner: WindowsSurfaceGeometryOwner.pet,
        requested: const Rect.fromLTWH(600, 400, 256, 192),
        before: const Rect.fromLTWH(600, 400, 256, 192),
        after: const Rect.fromLTWH(600, 400, 256, 192),
      );
      expect(journal.lastOf('geometry.size.write')!.fields['overwrote_previous'], isTrue);
    });

    test('事件日志有界（不刷屏）', () {
      for (int i = 0; i < WheelGeometryJournal.maxEvents + 50; i++) {
        journal.record('pet.resize.dropped', fields: <String, Object?>{'i': i});
      }
      expect(journal.events.length, WheelGeometryJournal.maxEvents);
    });

    test('toCopyText 幂等且包含事件名', () {
      journal.record('wheel.present');
      expect(journal.toCopyText(), contains('wheel.present'));
      expect(journal.toCopyText(), journal.toCopyText());
    });
  });

  test('formatRect / formatOffset', () {
    expect(WheelGeometryJournal.formatRect(null), 'none');
    expect(
      WheelGeometryJournal.formatRect(const Rect.fromLTWH(1.5, 2, 10, 20)),
      '1.5,2 10×20',
    );
    expect(WheelGeometryJournal.formatOffset(const Offset(3, 4.25)), '3,4.3');
  });
}

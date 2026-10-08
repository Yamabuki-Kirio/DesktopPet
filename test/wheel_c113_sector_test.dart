/// C1.1.3 **扇形角度选择与鼠标移动回落修复** —— 定向回归（需求 §12 的 20 项）。
///
/// 覆盖两组东西：
/// 1. **有效扇形**（§6 / §7 / §8）：不要求落在窄环带上；角度槽位 + 7° 滞回；
///    沿半径向内 / 向外都保持同一按钮；左右镜像与 top/middle/bottom 全都正确；
/// 2. **高亮派生与粘性锚点**（§1 / §3 / §11）：移出有效扇形 → `hoveredIndex=null`、
///    `visualActiveIndex=-1`，且**扇叶 / 标题 chip / 实时信息不回落到第一项**。
library;

import 'dart:math' as math;

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:petlife/menu/menu_contract.dart';
import 'package:petlife/menu/wheel_animator.dart';
import 'package:petlife/menu/wheel_button_hit.dart';
import 'package:petlife/menu/wheel_geometry_ownership.dart';
import 'package:petlife/menu/wheel_menu_geometry.dart'
    show
        WheelBounds,
        WheelMenuEnvelope,
        WheelMenuGeometry,
        WheelMenuLayout,
        WheelMenuLayoutSettings,
        WheelMenuSpec,
        WheelRect;
import 'package:petlife/menu/wheel_menu_state.dart';
import 'package:petlife/menu/wheel_theme.dart';
import 'package:petlife/ui/desktop/wheel_menu_view.dart';

// ---------------------------------------------------------------------------
// 六个场景（与 C1.1 / C1.1.1 同一套真机坐标）
// ---------------------------------------------------------------------------

/// 桌宠窗口尺寸（256×192 素材）。
const double _petW = 256;
const double _petH = 192;

/// 场景：桌宠窗口左上角（屏幕坐标）→ 由几何自己决定左右与 top/middle/bottom。
const List<(String, Offset)> _scenarios = <(String, Offset)>[
  ('左上(右展开/靠上)', Offset(64, 120)),
  ('顶部居中', Offset(832, 120)),
  ('右上(左展开/靠上)', Offset(1600, 120)),
  ('中部居中', Offset(832, 420)),
  ('左下(右展开/靠下)', Offset(64, 680)),
  ('右下(左展开/靠下)', Offset(1600, 680)),
];

/// 单个场景的测试台：几何 + 控制器 + 断言辅助。
class _Bench {
  _Bench._(
    this.label,
    this.layout,
    this.controller,
    this.confirmed,
    this.closes,
    this._clockBox,
  );

  final String label;
  final WheelMenuLayout layout;
  final WheelMenuController controller;
  final List<String> confirmed;
  final List<int> closes;

  /// 与控制器共用的假时钟（控制器先于本对象创建，因此用 1 元素盒子传递）。
  final List<int> _clockBox;

  int get now => _clockBox[0];
  set now(int value) => _clockBox[0] = value;

  late final WheelHitTester tester =
      WheelHitTester(layout, density: 1, showButtonLabels: true);

  WheelPointerSector get sector => tester.sector;

  int get itemCount => layout.itemCount;

  bool insideWindow(Offset p) =>
      p.dx >= 0 &&
      p.dy >= 0 &&
      p.dx < layout.windowRect.width &&
      p.dy < layout.windowRect.height;

  /// 第 [i] 个槽位的**绝对角度**（与 Painter / 扇形同源）。
  double slotAngle(int i) => WheelMenuGeometry.absoluteAngle(
        layout.direction,
        (i - (layout.itemCount - 1) / 2) * layout.stepDeg + layout.fanBiasDeg,
      );

  Offset polar(double angleDeg, double radius) {
    final double rad = angleDeg * math.pi / 180;
    return Offset(
      layout.centerX + radius * math.cos(rad),
      layout.centerY + radius * math.sin(rad),
    );
  }

  Offset slotCenter(int i) =>
      Offset(layout.slots[i].centerX, layout.slots[i].centerY);

  void open() {
    controller.beginOpenAnimation();
    now = now + WheelAnimationTimeline.openMs + 20;
    controller.tick();
  }

  /// 扫描出一个指定分区的点（用于"装饰区 / 人物保护区"这类需要实证的点）。
  Offset findPoint(WheelPointerHitKind kind) {
    for (double y = 2; y < layout.windowRect.height - 2; y += 5) {
      for (double x = 2; x < layout.windowRect.width - 2; x += 5) {
        final Offset p = Offset(x, y);
        if (tester.resolve(p).kind == kind) return p;
      }
    }
    throw StateError('[$label] 找不到 $kind 采样点（几何异常）');
  }

  /// 紧贴扇形角度域之外、仍在窗口内的点（用于 §12-6"移出有效扇形"）。
  Offset outsideFanPoint() {
    final double outward = sector.sweepDeg.sign;
    for (double off = 2; off <= 90; off += 2) {
      for (final double a in <double>[
        sector.startAngleDeg - off,
        sector.startAngleDeg + sector.sweepDeg + outward * off,
      ]) {
        final Offset p = polar(a, layout.ringRadiusPx);
        if (!insideWindow(p)) continue;
        if (tester.resolve(p).kind == WheelPointerHitKind.decoration) return p;
      }
    }
    throw StateError('[$label] 找不到扇形外的装饰点（几何异常）');
  }

  /// 第 [i] 个槽位角度上**确实走"角度槽位"**的一点（环带之外、标签带之外）。
  ///
  /// 从扇形外缘向内扫描，只接受 `angularSector` —— 因此这个点不可能落在
  /// 按钮圆形或标签上，能确切证明"不要求落在窄环带上也能选中"（需求 §1 / §6）。
  Offset sectorPoint(int i) {
    for (double r = sector.outerRadiusPx - 4; r > layout.rimOuterPx; r -= 4) {
      final Offset p = polar(slotAngle(i), r);
      if (tester.resolve(p).kind == WheelPointerHitKind.angularSector) return p;
    }
    throw StateError('[$label] 槽位$i 在环带外找不到角度槽位采样点（几何异常）');
  }
}

_Bench _bench(Offset petTopLeft) {
  final WheelMenuSpec spec = WheelMenuSpec.fromDensity(1);
  final WheelMenuEnvelope envelope = WheelMenuGeometry.computeEnvelope(
    bounds: const WheelBounds(0, 0, 1920, 1040),
    petWindowRect: WheelRect(
      petTopLeft.dx,
      petTopLeft.dy,
      petTopLeft.dx + _petW,
      petTopLeft.dy + _petH,
    ),
    maxItemCount: MenuCatalog.maxItems,
    spec: spec,
    settings: WheelMenuLayoutSettings.defaults,
  );
  final WheelMenuLayout layout =
      WheelMenuGeometry.layoutFor(envelope, MenuCatalog.root, spec);
  final List<String> confirmed = <String>[];
  final List<int> closes = <int>[];
  final List<int> clockBox = <int>[1000];
  final WheelMenuController controller = WheelMenuController(
    spec: spec,
    theme: WheelMenuThemes.p3pPink(),
    density: 1,
    clock: () => clockBox[0],
  );
  controller.onEntryConfirmed = (MenuNode node, int index) => confirmed.add(node.id);
  controller.onRequestClose = () => closes.add(1);
  // 注意：本函数可能在**收集期**（test 之外）被调用，因此不能用 `expect`。
  if (!controller.prepareContent(envelope, WheelMenuThemes.p3pPink())) {
    throw StateError('prepareContent 失败（几何不可用）');
  }
  controller.setInteractive(true);
  return _Bench._(
    '${petTopLeft.dx.toInt()},${petTopLeft.dy.toInt()}',
    layout,
    controller,
    confirmed,
    closes,
    clockBox,
  );
}

void main() {
  group('§12 全场景（左右镜像 × top/middle/bottom）', () {
    for (final (String name, Offset pet) in _scenarios) {
      // 每个用例一套全新状态（避免用例间互相污染）。
      late _Bench b;
      setUp(() => b = _bench(pet));

      test('[$name] §12-1/2/3 悬停第 3 项后微动 / 沿半径向内 / 向外都仍是第 3 项', () {
        b.open();
        final WheelMenuController c = b.controller;

        // ① 扇形角度槽位上的点（不是按钮圆心）。
        final Offset far = b.polar(b.slotAngle(3), b.sector.outerRadiusPx - 6);
        c.hover(far);
        expect(c.pointer.hoveredIndex, 3, reason: '扇形主体内必须选中该角度槽位的按钮');
        expect(c.highlightIndexNow, 3);

        // ② 轻微移动（同角度、略变半径）。
        c.hover(b.polar(b.slotAngle(3), b.sector.outerRadiusPx - 14));
        expect(c.pointer.hoveredIndex, 3, reason: '§12-1 轻微移动不得掉出选择');

        // ③ 沿半径**向内**（靠近人物，但未进入保护区）。
        final double inner =
            b.sector.innerRadiusAt(b.slotAngle(3)) + 12;
        expect(inner, lessThan(b.layout.ringRadiusPx));
        c.hover(b.polar(b.slotAngle(3), inner));
        expect(c.pointer.hoveredIndex, 3,
            reason: '§12-2 沿半径向内（仍在有效扇形内）必须保持同一按钮');

        // ④ 沿半径**向外**（扇形外缘以内、窄环带之外 —— C1.1.3 修复的核心）。
        c.hover(b.polar(b.slotAngle(3), b.layout.rimOuterPx + 30));
        expect(c.pointer.hoveredIndex, 3,
            reason: '§12-3 环带之外、扇形之内必须仍命中同一按钮');
        expect(c.pointer.anchorIndex, 3);
      });

      test('[$name] §12-4 沿圆弧移动到第 4 项 → 高亮切到第 4 项', () {
        b.open();
        final WheelMenuController c = b.controller;
        c.hover(b.polar(b.slotAngle(3), b.layout.ringRadiusPx));
        expect(c.pointer.hoveredIndex, 3);
        c.hover(b.polar(b.slotAngle(4), b.layout.ringRadiusPx));
        expect(c.pointer.hoveredIndex, 4, reason: '跨过槽位边界后必须切到新槽位');
        expect(c.highlightIndexNow, 4);
      });

      test('[$name] §12-5 相邻槽位边界附近受 7° 滞回保护', () {
        b.open();
        final WheelHitTester tester = b.tester;
        // raw = 3.7：落在第 4 槽的责任区（>3.5），但距第 3 槽 < 0.5+滞回单位。
        final double rawAngle = WheelMenuGeometry.absoluteAngle(
          b.layout.direction,
          (3.7 - (b.itemCount - 1) / 2) * b.layout.stepDeg + b.layout.fanBiasDeg,
        );
        final Offset p = b.polar(rawAngle, b.layout.ringRadiusPx);
        expect(tester.resolve(p, previousIndex: 3).buttonIndex, 3,
            reason: '§12-5 已有第 3 项时必须滞回保持，不得抖动');
        expect(tester.resolve(p, previousIndex: null).buttonIndex, 4,
            reason: '没有前一项时应取最近的槽位（第 4 项）');
      });

      test('[$name] §12-6/7 移出有效扇形 → 高亮 -1，且**不回到第一项**', () {
        b.open();
        final WheelMenuController c = b.controller;
        // 先悬停第 3 项，让锚点落在 3。
        c.hover(b.polar(b.slotAngle(3), b.layout.ringRadiusPx));
        expect(c.pointer.anchorIndex, 3);
        expect(c.activeIndexNow, 3);

        // 移出有效扇形：角度落在扇形之外（仍在窗口内）。
        final Offset out = b.outsideFanPoint();
        expect(b.tester.resolve(out).kind, WheelPointerHitKind.decoration,
            reason: '扇形角度域之外必须判为装饰（不是按钮）');
        c.hover(out);

        expect(c.pointer.hoveredIndex, isNull, reason: '§12-6 移出后必须无悬停');
        expect(c.highlightIndexNow, -1, reason: '§12-6 高亮必须是 -1');
        expect(c.pointer.anchorIndex, 3, reason: '§12-7 锚点必须粘住');
        expect(c.activeIndexNow, 3,
            reason: '§12-7 扇叶 / 标题 / 实时信息的锚点不得回落到第一项');
        expect(c.state.previewIndex, isNull, reason: '预览（语义）必须清空');
      });

      test('[$name] §12-9/10 扇形中但不在环带上 → 能选中，且静止单击执行该按钮', () {
        b.open();
        final WheelMenuController c = b.controller;
        // 该点由扫描保证落在"角度槽位"这一路（不是按钮圆形、也不是标签）。
        final Offset p = b.sectorPoint(4);
        final WheelPointerHit hit = b.tester.resolve(p, previousIndex: null);
        expect(hit.kind, WheelPointerHitKind.angularSector,
            reason: '§12-9 环带之外、扇形之内属于角度槽位');
        expect(hit.buttonIndex, 4, reason: '扇形角度槽位必须命中该槽位');

        c.pointerDown(p);
        c.pointerUp(p);
        expect(b.confirmed, <String>[MenuCatalog.root.nodes[4].id],
            reason: '§12-10 扇形体内静止单击必须执行该按钮');
        expect(b.closes, isEmpty, reason: '不得关闭菜单');
      });

      test('[$name] §12-13/14 人物保护区与装饰区都不映射到按钮', () {
        b.open();
        final WheelHitTester tester = b.tester;

        // 保护区：缺口中心 + 缺口内一点。
        final Offset notch = Offset(b.layout.notchCenterX, b.layout.notchCenterY);
        final WheelPointerHit notchHit = tester.resolve(notch);
        expect(notchHit.kind, WheelPointerHitKind.petProtection);
        expect(notchHit.buttonIndex, isNull);

        // 装饰区：扫描出来一个真实存在的装饰点。
        final Offset deco = b.findPoint(WheelPointerHitKind.decoration);
        final WheelPointerHit decoHit = tester.resolve(deco);
        expect(decoHit.kind, WheelPointerHitKind.decoration);
        expect(decoHit.buttonIndex, isNull);

        // 装饰区单击：不执行、不关闭（A1 / §10）。
        b.controller.pointerDown(deco);
        b.controller.pointerUp(deco);
        expect(b.confirmed, isEmpty);
        expect(b.closes, isEmpty, reason: '§10 装饰区不得关闭菜单');
      });

      test('[$name] §12-15/16 每个槽位：圆心 / 扇形角度槽位都命中它自己', () {
        b.open();
        final WheelHitTester tester = b.tester;
        for (int i = 0; i < b.itemCount; i++) {
          // ① 按钮圆心。
          expect(tester.resolve(b.slotCenter(i)).buttonIndex, i,
              reason: '按钮圆心必须命中自己');
          // ② 该角度的扇形主体（不落在按钮圆上）。
          final Offset p = b.polar(b.slotAngle(i), b.layout.rimOuterPx + 20);
          final WheelPointerHit hit = tester.resolve(p, previousIndex: null);
          expect(hit.isButton, isTrue, reason: '扇形主体内必须有命中（槽位$i）');
          expect(hit.buttonIndex, i, reason: '扇形角度槽位必须命中该槽位（不得错选）');
        }
      });
    }
  });

  group('§12 单场景（右展开 / 居中）的交互细节', () {
    late _Bench b;
    setUp(() => b = _bench(const Offset(832, 420)));

    test('§2/§3/§11-8 鼠标模式下键盘默认焦点不接管高亮', () {
      b.open();
      final WheelMenuController c = b.controller;
      expect(c.pointer.keyboardFocusedIndex, 0, reason: '键盘默认焦点仍可落在第一项');
      c.hover(b.polar(b.slotAngle(3), b.layout.ringRadiusPx));
      expect(c.pointer.keyboardMode, isFalse);
      expect(c.pointer.visualActiveIndex, 3, reason: '鼠标交互期间不得回落到键盘焦点');
      expect(c.highlightIndexNow, 3);
    });

    test('§12-11 down 在扇形、up 在同一按钮圆形 → 只执行一次', () {
      b.open();
      final WheelMenuController c = b.controller;
      c.pointerDown(b.polar(b.slotAngle(4), b.layout.rimOuterPx + 20));
      c.pointerUp(b.slotCenter(4));
      expect(b.confirmed, <String>[MenuCatalog.root.nodes[4].id],
          reason: '同一按钮的不同命中子区域也算同一次点击');
      expect(b.confirmed.length, 1);
    });

    test('§12-12 down / up 落在不同槽位 → 不执行（也不关闭）', () {
      b.open();
      final WheelMenuController c = b.controller;
      c.pointerDown(b.polar(b.slotAngle(4), b.layout.rimOuterPx + 20));
      c.pointerUp(b.polar(b.slotAngle(0), b.layout.rimOuterPx + 20));
      expect(b.confirmed, isEmpty, reason: '§9 不同按钮必须取消，不得误执行');
      expect(b.closes, isEmpty);
    });

    test('§8 保护区点击不映射按钮（按桌宠规则处理）', () {
      b.open();
      final WheelMenuController c = b.controller;
      c.pointerDown(Offset(b.layout.notchCenterX, b.layout.notchCenterY));
      c.pointerUp(Offset(b.layout.notchCenterX, b.layout.notchCenterY));
      expect(b.confirmed, isEmpty);
      expect(b.closes.length, 1, reason: '缺口未拖动点击 = 关闭菜单（既有规则）');
    });

    test('§12-17 进入子菜单后用当前鼠标位置重新计算命中', () {
      b.open();
      final WheelMenuController c = b.controller;
      final Offset p = b.polar(b.slotAngle(3), b.layout.ringRadiusPx);
      c.hover(p);
      expect(c.pointer.hoveredIndex, 3);

      expect(c.enterLayerByAction('open_pet'), isTrue);
      expect(c.pointer.hoveredIndex, isNull, reason: '换层必须清掉旧 hover');
      expect(c.pointer.anchorIndex, isNull, reason: '换层必须清掉旧锚点');

      b.now += WheelAnimationTimeline.enterLayerMs + 20;
      c.tick();
      // 换层完成后按"最近鼠标位置 + 新几何"重算 —— 绝不默认赋值 0。
      expect(c.pointer.hoveredIndex, isNotNull,
          reason: '鼠标仍在扇形内 → 必须重新命中');
      expect(c.pointer.anchorIndex, c.pointer.hoveredIndex);
      expect(c.highlightIndexNow, isNot(-1));
    });

    test('§12-18 打开动画期间移动 → 打开完成后高亮正确', () {
      final WheelMenuController c = b.controller;
      // 打开动画**未**结束（phase = opening）。
      c.beginOpenAnimation();
      final Offset p = b.polar(b.slotAngle(2), b.layout.ringRadiusPx);
      c.hover(p);
      expect(c.phase, WheelMenuPhase.opening);
      expect(c.pointer.lastPointerLocal, isNotNull, reason: '动画期间位置不得丢弃');
      expect(c.pointer.hoveredIndex, isNull, reason: '动画期间不产生高亮');

      b.now += WheelAnimationTimeline.openMs + 20;
      c.tick();
      expect(c.phase, WheelMenuPhase.open);
      expect(c.pointer.hoveredIndex, 2, reason: '§12-18 打开完成后按最近位置重算');
      expect(c.highlightIndexNow, 2);
    });

    test('§12-20 连续移动 500 次无异常、无越界', () {
      b.open();
      final WheelMenuController c = b.controller;
      final int count = b.itemCount;
      double angle = b.sector.startAngleDeg + 2;
      for (int i = 0; i < 500; i++) {
        // 在扇形角度域内来回扫，半径也在环带内外来回。
        angle += 3;
        if (angle > b.sector.startAngleDeg + b.sector.sweepDeg.abs() - 2) {
          angle = b.sector.startAngleDeg + 2;
        }
        final double radius = i.isEven
            ? b.layout.ringRadiusPx
            : b.layout.rimOuterPx + (i % 5) * 12;
        c.hover(b.polar(angle, radius));
        final int? hovered = c.pointer.hoveredIndex;
        if (hovered != null) {
          expect(hovered, inInclusiveRange(0, count - 1));
        }
        expect(c.activeIndexNow, inInclusiveRange(0, count - 1));
        expect(c.highlightIndexNow, inInclusiveRange(-1, count - 1));
      }
      // 收尾：停在第 0 项的角度上，必须命中第 0 项。
      c.hover(b.polar(b.slotAngle(0), b.layout.ringRadiusPx));
      expect(c.pointer.hoveredIndex, 0);
    });

    test('§2 时间线日志：pointer.move / pointer.mode / hit.resolve / hover.changed / highlight.derived', () {
      wheelGeometryJournal.clear();
      b.open();
      b.controller.hover(b.polar(b.slotAngle(3), b.layout.rimOuterPx + 20));
      for (final String event in <String>[
        'wheel.pointer.move',
        'wheel.pointer.mode',
        'wheel.hit.resolve',
        'wheel.hover.changed',
        'wheel.highlight.derived',
      ]) {
        expect(wheelGeometryJournal.contains(event), isTrue,
            reason: '缺少时间线事件：$event');
      }
      // 验收硬指标：动画完成后 hoveredIndex **没有**被写成 0。
      final WheelGeometryEvent? last = wheelGeometryJournal.lastOf('wheel.hover.changed');
      expect(last, isNotNull);
      expect(last!.fields['hoveredIndex'], 3);
    });
  });

  group('§12-19 widget 层：rebuild 不把鼠标状态打回第一项', () {
    testWidgets('rebuild + 悬停第 3 项后状态保持', (WidgetTester tester) async {
      final _Bench b = _bench(const Offset(832, 420));
      tester.view.physicalSize = const Size(1920, 1040);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      Widget harness() => MaterialApp(
            home: Center(
              child: SizedBox(
                width: b.layout.windowRect.width,
                height: b.layout.windowRect.height,
                child: WheelMenuView(controller: b.controller),
              ),
            ),
          );

      await tester.pumpWidget(harness());
      b.open();
      await tester.pump();

      final Offset origin = tester.getTopLeft(find.byType(WheelMenuView));
      final Offset p = b.polar(b.slotAngle(3), b.layout.rimOuterPx + 20);
      final TestGesture hover = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await hover.addPointer(location: Offset.zero);
      addTearDown(hover.removePointer);
      await hover.moveTo(origin + p);
      await tester.pump();
      expect(b.controller.pointer.hoveredIndex, 3);

      // 触发 rebuild（同一个 controller 实例）。
      await tester.pumpWidget(harness());
      await tester.pump();
      expect(b.controller.pointer.hoveredIndex, 3,
          reason: '§12-19 rebuild 不得把鼠标状态打回第一项');
      expect(b.controller.highlightIndexNow, 3);
      expect(b.controller.activeIndexNow, 3);
    });
  });
}

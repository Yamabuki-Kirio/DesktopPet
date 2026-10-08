/// 真机回归 #2：右键菜单必须受**鼠标所在显示器 workArea** 约束、可滚动、可键盘导航，
/// 且 Region 只覆盖实际菜单矩形（不再整块固定画布）。
///
/// 覆盖用户验收清单的 9 ~ 14 项。
library;

import 'dart:async';

import 'package:flutter/gestures.dart' show PointerScrollEvent;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:petlife/menu/context_menu_layout.dart';
import 'package:petlife/ui/desktop/pet_context_menu_overlay.dart';

/// 生成 [count] 个可点条目。
List<ContextMenuItem> itemsOf(int count) => <ContextMenuItem>[
      for (int i = 0; i < count; i++)
        ContextMenuItem(label: '条目 $i', value: 'v$i'),
    ];

void main() {
  const Size fhd = Size(1920, 1040);

  group('尺寸与滚动（9 / 10）', () {
    test('9. 高度上限 = min(workArea.height - 32, 560)', () {
      expect(
        ContextMenuLayout.maxHeightFor(const Size(1920, 1040)),
        ContextMenuLayout.maxHeightCap,
      );
      // 小屏：由工作区高度决定（-32 安全边距）。
      expect(ContextMenuLayout.maxHeightFor(const Size(1920, 400)), 400 - 32);
      // 宽度上限同理。
      expect(ContextMenuLayout.maxWidthFor(fhd), ContextMenuLayout.maxWidthCap);
      expect(ContextMenuLayout.maxWidthFor(const Size(300, 400)), 300 - 32);
    });

    test('9b. 菜单实际高度受 workArea 夹取，绝不超出', () {
      final ContextMenuPlan plan = ContextMenuLayout.plan(
        anchor: const Offset(100, 100),
        overlaySize: fhd,
        workArea: Offset.zero & fhd,
        items: itemsOf(30),
      );
      expect(plan.rect.height, ContextMenuLayout.maxHeightCap);
      expect(plan.rect.bottom, lessThanOrEqualTo(fhd.height));
    });

    test('10. 条目装不下时 scrolls = true，且内容高度 > 视口高度', () {
      final ContextMenuPlan plan = ContextMenuLayout.plan(
        anchor: const Offset(100, 100),
        overlaySize: const Size(1920, 400),
        workArea: const Rect.fromLTWH(0, 0, 1920, 400),
        items: itemsOf(20),
      );
      expect(plan.scrolls, isTrue);
      expect(plan.contentExtent, greaterThan(plan.rect.height));
      expect(plan.rect.height, 400 - 32);
    });

    test('10b. 条目装得下时不滚动', () {
      final ContextMenuPlan plan = ContextMenuLayout.plan(
        anchor: const Offset(100, 100),
        overlaySize: fhd,
        workArea: Offset.zero & fhd,
        items: itemsOf(3),
      );
      expect(plan.scrolls, isFalse);
      expect(plan.rect.height, plan.contentExtent);
    });

    test('10c. 打开时把"当前状态项"滚入可见区', () {
      final List<ContextMenuItem> items = itemsOf(30);
      final ContextMenuPlan plan = ContextMenuLayout.plan(
        anchor: const Offset(100, 100),
        overlaySize: const Size(1920, 400),
        workArea: const Rect.fromLTWH(0, 0, 1920, 400),
        items: items,
        initialIndex: 25,
      );
      expect(plan.initialScrollOffset, greaterThan(0));
      final double start = ContextMenuLayout.extentBefore(items, 25);
      final double end = start + ContextMenuLayout.extentOf(items[25]);
      expect(start, greaterThanOrEqualTo(plan.initialScrollOffset - 0.5));
      expect(end, lessThanOrEqualTo(plan.initialScrollOffset + plan.rect.height + 0.5));
    });
  });

  group('四角锚点不出屏（12）', () {
    test('12. 四个角 + 四个边中点：菜单都完整落在 workArea 内', () {
      const Rect area = Rect.fromLTWH(0, 0, 1920, 1040);
      const List<Offset> anchors = <Offset>[
        Offset(0, 0),
        Offset(1919, 0),
        Offset(0, 1039),
        Offset(1919, 1039),
        Offset(960, 0),
        Offset(0, 520),
        Offset(1919, 520),
        Offset(960, 1039),
      ];
      for (final Offset anchor in anchors) {
        final ContextMenuPlan plan = ContextMenuLayout.plan(
          anchor: anchor,
          overlaySize: area.size,
          workArea: area,
          items: itemsOf(12),
        );
        expect(plan.rect.left, greaterThanOrEqualTo(area.left),
            reason: '锚点 $anchor 左越界');
        expect(plan.rect.top, greaterThanOrEqualTo(area.top),
            reason: '锚点 $anchor 上越界');
        expect(plan.rect.right, lessThanOrEqualTo(area.right + 0.001),
            reason: '锚点 $anchor 右越界');
        expect(plan.rect.bottom, lessThanOrEqualTo(area.bottom + 0.001),
            reason: '锚点 $anchor 下越界');
      }
    });

    test('12b. 负坐标副屏：锚点与菜单都在副屏内', () {
      const Rect area = Rect.fromLTWH(-1920, 0, 1920, 1040);
      final ContextMenuPlan plan = ContextMenuLayout.plan(
        // overlay 局部坐标（画布在副屏上时同样是 0 基）。
        anchor: const Offset(10, 10),
        overlaySize: const Size(1920, 1040),
        workArea: area,
        items: itemsOf(1),
      );
      expect(plan.rect.left, greaterThanOrEqualTo(10));
      expect(plan.rect.top, greaterThanOrEqualTo(10));
      expect(plan.rect.right, lessThanOrEqualTo(1920.0));
    });

    test('12c. workArea 小于 overlay 时也夹在 workArea 内', () {
      const Rect area = Rect.fromLTWH(200, 100, 600, 400);
      final ContextMenuPlan plan = ContextMenuLayout.plan(
        anchor: const Offset(500, 300),
        overlaySize: const Size(1920, 1040),
        workArea: area,
        items: itemsOf(20),
      );
      expect(plan.rect.left, greaterThanOrEqualTo(area.left));
      expect(plan.rect.top, greaterThanOrEqualTo(area.top));
      expect(plan.rect.right, lessThanOrEqualTo(area.right + 0.001));
      expect(plan.rect.bottom, lessThanOrEqualTo(area.bottom + 0.001));
    });
  });

  group('键盘导航（11）', () {
    test('11. 上下键在可点条目之间移动，跳过不可点条目', () {
      final List<ContextMenuItem> items = <ContextMenuItem>[
        const ContextMenuItem(label: '只读 A', value: 'a', enabled: false),
        const ContextMenuItem(label: '只读 B', value: 'b', enabled: false),
        const ContextMenuItem.divider(),
        const ContextMenuItem(label: '动作 1', value: 'p'),
        const ContextMenuItem(label: '动作 2', value: 'q'),
      ];
      expect(ContextMenuLayout.firstActionable(items), 3);
      expect(ContextMenuLayout.nextActionable(items, 3, 1), 4);
      expect(ContextMenuLayout.nextActionable(items, 4, 1), 4, reason: '到底不动');
      expect(ContextMenuLayout.nextActionable(items, 4, -1), 3);
      expect(ContextMenuLayout.nextActionable(items, 3, -1), 3, reason: '到顶不动');
    });
  });

  group('Overlay 真实行为（10 / 11）', () {
    testWidgets('10d. 内容可滚动：滚轮改变滚动偏移', (WidgetTester tester) async {
      final List<ContextMenuItem> items = itemsOf(30);
      late OverlayState overlay;
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (BuildContext context) {
          overlay = Overlay.of(context);
          return const SizedBox.expand();
        }),
      ));
      final ContextMenuPlan plan = ContextMenuLayout.plan(
        anchor: const Offset(100, 100),
        overlaySize: const Size(1920, 400),
        workArea: const Rect.fromLTWH(0, 0, 1920, 400),
        items: items,
      );
      unawaited(PetContextMenuOverlay.show(
        overlay: overlay,
        items: items,
        plan: plan,
      ));
      await tester.pumpAndSettle();

      final Finder scroll = find.byType(SingleChildScrollView);
      expect(scroll, findsOneWidget);
      final ScrollableState state =
          tester.state<ScrollableState>(find.byType(Scrollable).first);
      expect(state.position.maxScrollExtent, greaterThan(0),
          reason: '内容超出视口 → 必须存在可滚动区间');
      final double before = state.position.pixels;

      // 鼠标滚轮。
      final Offset center = tester.getCenter(scroll);
      await tester.sendEventToBinding(
        PointerScrollEvent(position: center, scrollDelta: const Offset(0, 120)),
      );
      await tester.pumpAndSettle();
      final double after = tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position
          .pixels;
      expect(after, greaterThan(before), reason: '滚轮必须能滚动菜单');
    });

    testWidgets('11b. Esc 关闭菜单', (WidgetTester tester) async {
      final List<ContextMenuItem> items = itemsOf(5);
      String? result;
      late OverlayState overlay;
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (BuildContext context) {
          overlay = Overlay.of(context);
          return const SizedBox.expand();
        }),
      ));
      final ContextMenuPlan plan = ContextMenuLayout.plan(
        anchor: const Offset(100, 100),
        overlaySize: const Size(1920, 1040),
        workArea: const Rect.fromLTWH(0, 0, 1920, 1040),
        items: items,
      );
      unawaited(PetContextMenuOverlay.show(
        overlay: overlay,
        items: items,
        plan: plan,
      ).then((String? v) => result = v));
      await tester.pumpAndSettle();
      expect(find.byType(SingleChildScrollView), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(SingleChildScrollView), findsNothing);
      expect(result, isNull);
    });

    testWidgets('11c. 上下键 + Enter 选中条目', (WidgetTester tester) async {
      final List<ContextMenuItem> items = itemsOf(6);
      String? result;
      late OverlayState overlay;
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (BuildContext context) {
          overlay = Overlay.of(context);
          return const SizedBox.expand();
        }),
      ));
      final ContextMenuPlan plan = ContextMenuLayout.plan(
        anchor: const Offset(100, 100),
        overlaySize: const Size(1920, 1040),
        workArea: const Rect.fromLTWH(0, 0, 1920, 1040),
        items: items,
      );
      unawaited(PetContextMenuOverlay.show(
        overlay: overlay,
        items: items,
        plan: plan,
      ).then((String? v) => result = v));
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(result, 'v1', reason: '首项高亮 v0，下键到 v1，回车确认');
    });
  });
}

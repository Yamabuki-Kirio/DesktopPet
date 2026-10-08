import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:petlife/menu/context_menu_anchor.dart';

/// 回归 #A：右键菜单锚点必须**贴近指针**，而不是固定画布的右下角。
void main() {
  group('锚点解析（纯逻辑）', () {
    test('#1 有指针坐标时，锚点 = 指针（不是画布右下角）', () {
      const Size canvas = Size(1352, 560);
      const Offset pointer = Offset(700, 300);

      final RelativeRect r = ContextMenuAnchor.resolve(
        overlayLocalPosition: pointer,
        overlaySize: canvas,
      );

      expect(r.left, pointer.dx);
      expect(r.top, pointer.dy);
      // 关键回归断言：绝不等于画布右下角。
      expect(r.left, isNot(canvas.width));
      expect(r.top, isNot(canvas.height));
      // 锚点是 1×1 矩形：到右 / 下边的距离 = 画布 - 指针 - 1。
      expect(r.right, canvas.width - pointer.dx - 1);
      expect(r.bottom, canvas.height - pointer.dy - 1);
    });

    test('#4 指针缺失 → 回退到桌宠矩形右下角（绝不用画布右下角）', () {
      const Size canvas = Size(1352, 560);
      const Rect petRect = Rect.fromLTWH(500, 220, 256, 256);

      final RelativeRect r = ContextMenuAnchor.resolve(
        overlayLocalPosition: null,
        overlaySize: canvas,
        petOverlayRect: petRect,
      );

      expect(r.left, petRect.right);
      expect(r.top, petRect.bottom);
      expect(r.left, isNot(canvas.width));
    });

    test('锚点被夹取到 Overlay 内（不会整体跑到窗口外）', () {
      const Size canvas = Size(1352, 560);
      final RelativeRect r = ContextMenuAnchor.resolve(
        overlayLocalPosition: const Offset(-40, 99999),
        overlaySize: canvas,
      );
      expect(r.left, 0);
      expect(r.top, canvas.height - 1);
    });
  });

  group('真实 showMenu 定位（不再钉在画布右下角 + 自动翻转不越界）', () {
    Future<void> openAt(WidgetTester tester, Offset pointer, Size overlaySize) async {
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (BuildContext context) => GestureDetector(
            key: const Key('open'),
            behavior: HitTestBehavior.opaque,
            onTap: () {
              final RelativeRect anchor = ContextMenuAnchor.resolve(
                overlayLocalPosition: pointer,
                overlaySize: overlaySize,
              );
              unawaited(showMenu<String>(
                context: context,
                position: anchor,
                items: const <PopupMenuEntry<String>>[
                  PopupMenuItem<String>(value: 'a', child: Text('菜单项')),
                ],
              ));
            },
            child: const SizedBox.expand(),
          ),
        ),
      ));
      await tester.tap(find.byKey(const Key('open')));
      await tester.pumpAndSettle();
    }

    testWidgets('#2a 桌宠靠左下：菜单贴近指针且完整落在窗口内', (WidgetTester tester) async {
      const Size overlay = Size(1352, 560);
      tester.view.physicalSize = overlay;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      const Offset pointer = Offset(120, 480);
      await openAt(tester, pointer, overlay);

      final Rect menuRect = tester.getRect(find.text('菜单项'));
      // 菜单整体在窗口内（自动翻转 / 夹取生效）。
      expect(menuRect.left, greaterThanOrEqualTo(-0.5));
      expect(menuRect.right, lessThanOrEqualTo(overlay.width + 0.5));
      expect(menuRect.top, greaterThanOrEqualTo(-0.5));
      expect(menuRect.bottom, lessThanOrEqualTo(overlay.height + 0.5));
      // 不再贴到画布右下角。
      expect(menuRect.right, isNot(closeTo(overlay.width, 1.0)));
    });

    testWidgets('#2b 桌宠靠右下：菜单自动避开右下角并保持完整可见', (WidgetTester tester) async {
      const Size overlay = Size(1352, 560);
      tester.view.physicalSize = overlay;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      const Offset pointer = Offset(1300, 520);
      await openAt(tester, pointer, overlay);

      final Rect menuRect = tester.getRect(find.text('菜单项'));
      expect(menuRect.left, greaterThanOrEqualTo(-0.5));
      expect(menuRect.right, lessThanOrEqualTo(overlay.width + 0.5));
      expect(menuRect.top, greaterThanOrEqualTo(-0.5));
      expect(menuRect.bottom, lessThanOrEqualTo(overlay.height + 0.5));
    });
  });
}

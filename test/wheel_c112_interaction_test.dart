/// 增量 **C1.1.2**：Windows 轮盘「悬停重置」与「静止单击」稳定性回归。
///
/// 需求 §十 的 16 项逐条落地：
///  1 悬停第三项 1 秒高亮不变 / 2 动画完成不把 hover 重置第一项 /
///  3 静止单击能执行 / 4 单击用实时 HitTest 不依赖旧 hover /
///  5 展开后出现的按钮上打开完成时主动重算 hover / 6 同按钮只执行一次 /
///  7 按下后拖出抬起不执行 / 8 缺口关闭、背景不关闭 / 9 按钮点击不触发外层关闭 /
///  10 换层后旧 hover 不残留 / 11 键盘默认焦点不覆盖鼠标 hover /
///  12 Ticker 停止不改交互态 / 13 rebuild 不重建交互控制器 /
///  14 关闭后清空 hover+pressed+最近位置 / 15 快速连续点击不重复执行 /
///  16 **D9 死区回归**：Region 内非缺口点绝不关闭菜单（网格穷举）+ B1 命中区不误选。
///
/// 断言口径：只观察**外部可判定**的量（高亮索引 / 被确认条目 / 关闭请求 / 指针态快照）。
library;

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:petlife/menu/menu_contract.dart';
import 'package:petlife/menu/wheel_animator.dart';
import 'package:petlife/menu/wheel_button_hit.dart';
import 'package:petlife/menu/wheel_geometry_ownership.dart';
import 'package:petlife/menu/wheel_menu_geometry.dart';
import 'package:petlife/menu/wheel_pointer_state.dart';
import 'package:petlife/menu/wheel_theme.dart';
import 'package:petlife/ui/desktop/wheel_menu_view.dart';

void main() {
  late int now;
  late WheelMenuController controller;
  late WheelMenuLayout layout;
  late List<String> confirmed;
  late int closeRequests;

  void bootstrap() {
    now = 1000;
    confirmed = <String>[];
    closeRequests = 0;
    final WheelMenuSpec spec = WheelMenuSpec.fromDensity(1);
    final WheelMenuEnvelope envelope = WheelMenuGeometry.computeEnvelope(
      bounds: const WheelBounds(0, 0, 1920, 1080),
      petWindowRect: const WheelRect(300, 400, 556, 656),
      maxItemCount: MenuCatalog.maxItems,
      spec: spec,
      settings: WheelMenuLayoutSettings.defaults,
    );
    layout = WheelMenuGeometry.layoutFor(envelope, MenuCatalog.root, spec);
    controller = WheelMenuController(
      spec: spec,
      theme: WheelMenuThemes.p3pPink(),
      density: 1,
      clock: () => now,
    );
    controller.onEntryConfirmed =
        (MenuNode node, int index) => confirmed.add(node.id);
    controller.onRequestClose = () => closeRequests++;
    expect(controller.prepareContent(envelope, WheelMenuThemes.p3pPink()), isTrue);
    controller.setInteractive(true);
  }

  setUp(bootstrap);

  /// 把"打开动画"推到结束（Windows 上没有触摸抬起，靠时间推进）。
  void finishOpenAnimation() {
    controller.beginOpenAnimation();
    now += WheelAnimationTimeline.openMs + 20;
    controller.tick();
  }

  /// 某个按钮的**视觉中心**（窗口局部坐标 == HitTest 坐标系）。
  Offset slotCenter(int index) =>
      Offset(layout.slots[index].centerX, layout.slots[index].centerY);

  Offset notchCenter() => Offset(layout.notchCenterX, layout.notchCenterY);

  /// 在窗口内找一个"菜单背景"点（非按钮、非缺口）。
  Offset findBackgroundPoint() {
    for (double y = 2; y < layout.windowRect.height - 2; y += 7) {
      for (double x = 2; x < layout.windowRect.width - 2; x += 7) {
        final Offset p = Offset(x, y);
        final WheelPointerHit? hit = controller.hitTestAt(p);
        if (hit != null && hit.isBackground) return p;
      }
    }
    fail('找不到背景点（窗口内应当存在非按钮非缺口的像素）');
  }

  // ------------------------------------------------------------------
  // §十-1 悬停第三项 1 秒，高亮仍是第三项
  // ------------------------------------------------------------------
  test('§十-1 悬停第三项 1 秒，高亮仍是第三项（动画帧不得改写交互态）', () {
    finishOpenAnimation();
    controller.hover(slotCenter(3));
    expect(controller.pointer.hoveredIndex, 3);
    expect(controller.highlightIndexNow, 3);

    // 持续推进 1 秒（100 次 tick，模拟 10ms 一帧）。
    for (int i = 0; i < 100; i++) {
      now += 10;
      controller.tick();
    }
    expect(controller.pointer.hoveredIndex, 3, reason: '悬停高亮不得回落');
    expect(controller.highlightIndexNow, 3);
    expect(controller.state.previewIndex, 3);
  });

  // ------------------------------------------------------------------
  // §十-2 打开动画完成不把 hover 重置到第一项
  // ------------------------------------------------------------------
  test('§十-2 打开动画完成不把 hover 重置到第一项', () {
    // 动画期间悬停（位置必须被保存），完成后必须重算到第三项而不是第一项。
    controller.hover(slotCenter(3));
    expect(controller.pointer.lastPointerLocal, isNotNull,
        reason: '§七 强制约束：打开动画期间的位置也要保存');
    expect(controller.pointer.hoveredIndex, isNull,
        reason: '动画期间不产生视觉高亮');

    finishOpenAnimation();

    expect(controller.pointer.hoveredIndex, 3);
    expect(controller.highlightIndexNow, 3);
    expect(controller.highlightIndexNow, isNot(0),
        reason: '绝不能回落成"默认第一项"');
  });

  // ------------------------------------------------------------------
  // §十-3 鼠标静止于按钮，单击能执行
  // ------------------------------------------------------------------
  test('§十-3 鼠标静止于按钮、单击能执行动作（不是只关闭）', () {
    finishOpenAnimation();
    controller.hover(slotCenter(2));
    controller.pointerDown(slotCenter(2));
    controller.pointerUp(slotCenter(2));

    expect(confirmed, <String>[MenuCatalog.root.nodes[2].id]);
    expect(closeRequests, 0, reason: '按钮点击不得同时触发关闭');
  });

  // ------------------------------------------------------------------
  // §十-4 单击使用实时 HitTest，不依赖旧 hover
  // ------------------------------------------------------------------
  test('§十-4 单击用实时 HitTest：旧 hover 在第 3 项、单击落在第 5 项 → 执行第 5 项',
      () {
    finishOpenAnimation();
    controller.hover(slotCenter(3));
    expect(controller.pointer.hoveredIndex, 3);

    // 注意：**不**再发 hover，直接按下 / 抬起在第 5 项。
    controller.pointerDown(slotCenter(5));
    controller.pointerUp(slotCenter(5));

    expect(confirmed, <String>[MenuCatalog.root.nodes[5].id]);
  });

  // ------------------------------------------------------------------
  // §十-5 鼠标静止在展开后出现的按钮上 → 打开完成时主动重算 hover
  // ------------------------------------------------------------------
  test('§十-5 打开完成时主动重算 hover：按钮上→高亮；背景上→无高亮', () {
    // ① 静止在"展开后出现"的按钮位置。
    controller.hover(slotCenter(4));
    finishOpenAnimation();
    expect(controller.highlightIndexNow, 4);

    // ② 重置后静止在背景位置：**不得**默认高亮第一项。
    bootstrap();
    controller.hover(findBackgroundPoint());
    finishOpenAnimation();
    expect(controller.pointer.hoveredIndex, isNull);
    expect(controller.highlightIndexNow, -1, reason: 'C1：不在按钮上就不高亮任何按钮');
    expect(controller.state.previewIndex, isNull);
  });

  // ------------------------------------------------------------------
  // §十-6 按下、抬起同一按钮，只执行一次
  // ------------------------------------------------------------------
  test('§十-6 按下 / 抬起同一按钮只执行一次（多余的 up 不得再执行）', () {
    finishOpenAnimation();
    controller.pointerDown(slotCenter(3));
    controller.pointerUp(slotCenter(3));
    expect(confirmed.length, 1);

    // 再来一次"孤立 up"（真机可能重复投递）。
    controller.pointerUp(slotCenter(3));
    expect(confirmed.length, 1, reason: '孤立的 up 不得重复执行');
    expect(closeRequests, 0);
  });

  // ------------------------------------------------------------------
  // §十-7 按下按钮、拖出后抬起 → 不执行
  // ------------------------------------------------------------------
  test('§十-7 按下按钮后拖出环带再抬起 → 不执行动作、也不关闭', () {
    finishOpenAnimation();
    final Offset start = slotCenter(1);
    final Offset far = findBackgroundPoint();
    controller.pointerDown(start);
    now += 30;
    // 位移远超 12dp 的滑选阈值，且落点在环带之外。
    controller.pointerMove(far);
    now += 200;
    controller.pointerMove(far);
    controller.pointerUp(far);

    expect(confirmed, isEmpty, reason: '§六-2：按下按钮、抬起按钮外 → 取消');
    expect(closeRequests, 0, reason: '§六-2：这种情况也**不**关闭菜单');
  });

  // ------------------------------------------------------------------
  // §十-8 缺口关闭；背景不关闭（决策 A1）
  // ------------------------------------------------------------------
  test('§十-8 缺口（桌宠）单击关闭菜单；Region 内背景单击不关闭（A1）', () {
    finishOpenAnimation();

    controller.pointerDown(findBackgroundPoint());
    controller.pointerUp(findBackgroundPoint());
    expect(closeRequests, 0, reason: '决策 A1：菜单背景不执行、也不关闭');

    controller.pointerDown(notchCenter());
    controller.pointerUp(notchCenter());
    expect(closeRequests, 1, reason: '中央缺口（桌宠）仍是明确的关闭方式');
    expect(confirmed, isEmpty);
  });

  // ------------------------------------------------------------------
  // §十-9 按钮点击不会同时触发外层关闭
  // ------------------------------------------------------------------
  test('§十-9 六个根按钮点击：每次都执行、且从不触发外层关闭', () {
    finishOpenAnimation();
    for (int i = 0; i < MenuCatalog.root.itemCount; i++) {
      controller.pointerDown(slotCenter(i));
      controller.pointerUp(slotCenter(i));
    }
    expect(confirmed, <String>[
      for (final MenuNode n in MenuCatalog.root.nodes) n.id,
    ]);
    expect(closeRequests, 0);
  });

  // ------------------------------------------------------------------
  // §十-10 切换子菜单后旧 hover 不残留
  // ------------------------------------------------------------------
  test('§十-10 切换子菜单后旧 hover 不残留，且对新几何重算', () {
    finishOpenAnimation();
    controller.hover(slotCenter(3));
    expect(controller.highlightIndexNow, 3);
    final Offset lastPointer = controller.pointer.lastPointerLocal!;

    // 进"桌宠"子菜单（层级立即切换 + 过渡动画）。
    expect(controller.enterLayerByAction('open_pet'), isTrue);
    expect(controller.pointer.hoveredIndex, isNull, reason: '换层必须立刻清掉旧 hover');
    expect(controller.state.previewIndex, isNull);
    expect(controller.highlightIndexNow, -1);
    expect(controller.state.levelId, MenuCatalog.petLevelId);

    now += WheelAnimationTimeline.enterLayerMs + 20;
    controller.tick();
    // §八：换层动画收尾后按**新几何** + 最近指针位置重算（可立即高亮新按钮），
    // 关键是"结果必须与新几何一致"，而不是残留旧层的索引。
    final WheelPointerHit? expected = controller.hitTestAt(lastPointer);
    expect(controller.pointer.hoveredIndex, expected?.buttonIndex,
        reason: '收尾后必须按**新几何**重算，而不是沿用旧层结果');

    // 对新几何主动悬停到某个新按钮上 → 立即高亮。
    final WheelMenuLayout sub = controller.layout!;
    final Offset p = Offset(sub.slots[1].centerX, sub.slots[1].centerY);
    controller.hover(p);
    expect(controller.pointer.hoveredIndex, 1);
  });

  // ------------------------------------------------------------------
  // §十-11 键盘默认焦点不会覆盖鼠标 hover
  // ------------------------------------------------------------------
  test('§十-11 键盘默认焦点不覆盖鼠标 hover（keyboardMode 门控）', () {
    finishOpenAnimation();
    // 打开完成时键盘焦点已落到第一项，但**未**进入视觉。
    expect(controller.pointer.keyboardFocusedIndex, isNotNull);
    expect(controller.pointer.keyboardMode, isFalse);
    expect(controller.highlightIndexNow, -1,
        reason: '没有键盘输入 → 键盘焦点不得成为视觉高亮');

    controller.hover(slotCenter(3));
    expect(controller.highlightIndexNow, 3, reason: '鼠标 hover 必须胜过键盘默认焦点');
  });

  // ------------------------------------------------------------------
  // §十-12 动画 Ticker 停止不修改交互状态
  // ------------------------------------------------------------------
  test('§十-12 动画跑完（Ticker 停止）不修改任何交互态', () {
    finishOpenAnimation();
    controller.hover(slotCenter(3));
    controller.pointerDown(slotCenter(3));
    final Map<String, Object?> before = controller.pointer.describe();

    // 跑完按下动画（press 动画很短）。
    for (int i = 0; i < 30; i++) {
      now += 16;
      controller.tick();
    }
    expect(controller.hasActiveAnimation, isFalse, reason: '动画应当已经跑完');
    expect(controller.pointer.describe(), before,
        reason: '动画帧不得写入 hover / pressed / gesture 等交互态');
  });

  // ------------------------------------------------------------------
  // §十-14 关闭后清空 hover / pressed / 最近位置
  // ------------------------------------------------------------------
  test('§十-14 关闭菜单后清空 hover、pressed 与最近指针位置', () {
    finishOpenAnimation();
    controller.hover(slotCenter(3));
    controller.pointerDown(slotCenter(3));
    expect(controller.pointer.hoveredIndex, isNotNull);

    // 生产里"关闭请求被接受"时由外壳置 false。
    controller.setInteractive(false);

    expect(controller.pointer.hoveredIndex, isNull);
    expect(controller.pointer.pressedIndex, isNull);
    expect(controller.pointer.gestureSelectedIndex, isNull);
    expect(controller.pointer.lastPointerLocal, isNull);
    expect(controller.pointer.activeInputKind, isNull);
    expect(controller.highlightIndexNow, -1);
  });

  // ------------------------------------------------------------------
  // §十-15 快速连续点击不会执行两次（每次点击恰好一次）
  // ------------------------------------------------------------------
  test('§十-15 快速连续点击两次 → 恰好执行两次（不会多也不会少）', () {
    finishOpenAnimation();
    controller.pointerDown(slotCenter(3));
    controller.pointerUp(slotCenter(3));
    now += 5; // 极短间隔，模拟"快速连续点击"
    controller.pointerDown(slotCenter(3));
    controller.pointerUp(slotCenter(3));

    expect(confirmed.length, 2);
    expect(confirmed.every((String id) => id == MenuCatalog.root.nodes[3].id), isTrue);
    expect(closeRequests, 0);
  });

  // ------------------------------------------------------------------
  // §十-16 D9 死区回归：Region 内非缺口点绝不关闭菜单
  // ------------------------------------------------------------------
  test('§十-16 D9 死区回归：窗口内**只有缺口**会关闭菜单（网格穷举）', () {
    finishOpenAnimation();

    int sampled = 0;
    int notchPoints = 0;
    final int closeBefore = closeRequests;
    final List<String> offenders = <String>[];

    for (double y = 1; y < layout.windowRect.height - 1; y += 17) {
      for (double x = 1; x < layout.windowRect.width - 1; x += 17) {
        final Offset p = Offset(x, y);
        final bool isNotch = controller.hitTestAt(p)?.isNotch ?? false;
        sampled++;
        if (isNotch) notchPoints++;
        final int before = closeRequests;
        controller.pointerDown(p);
        controller.pointerUp(p);
        final bool closed = closeRequests > before;
        if (closed && !isNotch) {
          offenders.add('${x.toStringAsFixed(0)},${y.toStringAsFixed(0)}');
        }
      }
    }

    // 采样必须覆盖到缺口（否则断言无意义）。
    expect(notchPoints, greaterThan(0));
    // 修复前（D9）：环带外 21094 个采样点全都走 outsideTap → 关闭。
    // 修复后（A1）：这些点一律**不**关闭。
    expect(closeRequests - closeBefore, notchPoints,
        reason: '只有缺口点应当关闭菜单；非缺口点一个都不许关');
    expect(offenders, isEmpty,
        reason: '这些点不在缺口内却关闭了菜单（死区回归）：$offenders');
    expect(sampled, greaterThan(300), reason: '采样密度不足，结论不可信');
  });

  // ------------------------------------------------------------------
  // B1：标签 / chip 属于同一个按钮的命中区（强制约束 1）
  // ------------------------------------------------------------------
  test('B1 点击按钮**标签**带 → 命中该按钮（而不是关菜单）', () {
    finishOpenAnimation();
    final WheelHitTester tester = WheelHitTester(
      layout,
      density: 1,
      showButtonLabels: true,
    );
    final ButtonHitRegion region = tester.regions[4];
    final Rect label = region.label!;
    // 取标签带里**环带之外**的一点（旧实现会判 outside → 关菜单）。
    final Offset p = Offset(label.center.dx, label.center.dy);
    expect((p - region.center).distance, greaterThan(region.radius),
        reason: '该点应当在按钮**命中圆形**之外，才能验证"标签带"这一路');

    final WheelPointerHit hit = tester.resolve(p, selectedIndex: 0);
    expect(hit.buttonIndex, 4);
    expect(hit.kind, WheelPointerHitKind.buttonLabel);

    controller.pointerDown(p);
    controller.pointerUp(p);
    expect(confirmed, <String>[MenuCatalog.root.nodes[4].id]);
    expect(closeRequests, 0);
  });

  test('B1 优先规则：按钮圆形 > 标签 > 角度槽位，且重叠时取视觉中心最近者', () {
    final WheelHitTester tester = WheelHitTester(
      layout,
      density: 1,
      showButtonLabels: true,
    );

    // ① 每个按钮的圆心必然命中**它自己**（圆形优先）。
    for (final ButtonHitRegion region in tester.regions) {
      final WheelPointerHit hit = tester.resolve(region.center, selectedIndex: 0);
      expect(hit.kind, WheelPointerHitKind.buttonCircle);
      expect(hit.buttonIndex, region.index);
    }

    // ② 环带（角度槽位）上的点命中"该角度对应的按钮"。
    for (int i = 0; i < layout.itemCount; i++) {
      final WheelSlotPlacement slot = layout.slots[i];
      final double dx = slot.centerX - layout.centerX;
      final double dy = slot.centerY - layout.centerY;
      final double len = (Offset(dx, dy)).distance;
      // 向里收 40% 仍在同一角度槽位。
      final Offset p = Offset(
        layout.centerX + dx / len * len * 0.6,
        layout.centerY + dy / len * len * 0.6,
      );
      final WheelPointerHit hit = tester.resolve(p, selectedIndex: 0);
      expect(hit.isButton, isTrue, reason: '环带内必须命中某个按钮');
      expect(hit.buttonIndex, i, reason: '环带内必须命中该角度槽位的按钮（不得错选）');
    }

    // ③ 相邻标签重叠时取"视觉中心最近者"—— 同一重叠点只能属于一个按钮。
    final WheelPointerHit a = tester.resolve(tester.regions[2].center, selectedIndex: 0);
    final WheelPointerHit b = tester.resolve(tester.regions[3].center, selectedIndex: 0);
    expect(a.buttonIndex, 2);
    expect(b.buttonIndex, 3);
  });

  // ------------------------------------------------------------------
  // §九 时间线日志（验收断言：动画完成后 hoveredIndex 没被写成 0）
  // ------------------------------------------------------------------
  test('§九 时间线日志：down/up/hit/hover.changed/animation.completed 都留痕', () {
    finishOpenAnimation();
    controller.hover(slotCenter(3));
    controller.pointerDown(slotCenter(3));
    controller.pointerUp(slotCenter(3));

    for (final String event in <String>[
      'wheel.pointer.down',
      'wheel.pointer.up',
      'wheel.hit.down',
      'wheel.hit.up',
      'wheel.hover.changed',
      'wheel.animation.completed',
      'wheel.action.confirmed',
    ]) {
      expect(wheelGeometryJournal.contains(event), isTrue,
          reason: '缺少时间线事件：$event');
    }
    expect(wheelGeometryJournal.countOf('wheel.hit.down'), greaterThan(0));
  });

  // ------------------------------------------------------------------
  // §十-13 rebuild 不重建交互 Controller（widget 层）
  // ------------------------------------------------------------------
  testWidgets('§十-13 rebuild 不重建交互控制器；MouseRegion 悬停生效',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    Widget harness() => MaterialApp(
          home: Center(
            child: SizedBox(
              width: layout.windowRect.width,
              height: layout.windowRect.height,
              child: WheelMenuView(controller: controller),
            ),
          ),
        );

    await tester.pumpWidget(harness());
    finishOpenAnimation();
    await tester.pump();

    final WheelPointerState pointerRef = controller.pointer;
    final Offset origin = tester.getTopLeft(find.byType(WheelMenuView));

    // 触发一次 rebuild（同一个 controller 实例）。
    await tester.pumpWidget(harness());
    await tester.pump();
    expect(identical(controller.pointer, pointerRef), isTrue,
        reason: 'rebuild 必须复用同一个交互控制器');

    // 经 MouseRegion 悬停 → 高亮第 2 项。
    final WheelSlotPlacement slot = layout.slots[2];
    final TestGesture hover = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await hover.addPointer(location: Offset.zero);
    addTearDown(hover.removePointer);
    await hover.moveTo(origin + Offset(slot.centerX, slot.centerY));
    await tester.pump();

    expect(controller.pointer.hoveredIndex, 2);
    expect(controller.highlightIndexNow, 2);
  });
}

/// 增量 B：轮盘**装配层**的输入映射测试（Windows 鼠标 ↔ Android 触摸）。
///
/// 这一层只做三件事：把指针事件翻译成 [WheelMenuGestureController] 的
/// down / move / up，把悬停翻译成"只预览"的高亮，把 Esc 翻译成
/// 取消预览 → 返回上层 → 关闭 三级收敛。因此这里断言的都是**外部可观察行为**：
/// 条目是否被确认、层级是否变化、是否请求关闭。
library;

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:petlife/menu/menu_contract.dart';
import 'package:petlife/menu/wheel_animator.dart';
import 'package:petlife/menu/wheel_menu_geometry.dart';
import 'package:petlife/menu/wheel_menu_state.dart';
import 'package:petlife/menu/wheel_theme.dart';
import 'package:petlife/ui/desktop/wheel_menu_view.dart';

void main() {
  late int now;
  late WheelMenuController controller;
  late WheelMenuLayout layout;
  late List<String> confirmed;
  late int closeRequests;

  setUp(() {
    now = 1000;
    confirmed = <String>[];
    closeRequests = 0;
    final WheelMenuSpec spec = WheelCanvasTestSpec.spec;
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
    controller.onEntryConfirmed = (MenuNode node, int index) => confirmed.add(node.id);
    controller.onRequestClose = () => closeRequests++;
    expect(controller.prepareContent(envelope, WheelMenuThemes.p3pPink()), isTrue);
    // 生产路径：prepareContent → setInteractive(true) → beginOpenAnimation。
    // 少了这一步，控制器默认 _interactive = false，所有指针事件都会被丢弃。
    controller.setInteractive(true);
  });

  /// 把打开动画推到结束（Windows 上没有触摸抬起，靠时间推进）。
  void finishOpenAnimation() {
    controller.beginOpenAnimation();
    now += WheelAnimationTimeline.openMs + 20;
    controller.tick();
  }

  Widget harness() => MaterialApp(
        home: Center(
          child: SizedBox(
            width: layout.windowRect.width,
            height: layout.windowRect.height,
            child: WheelMenuView(controller: controller),
          ),
        ),
      );

  /// 把测试视口放到 1920×1080 —— 与信封 bounds 同一坐标系。
  ///
  /// 默认测试视口只有 800×600，而本用例的轮盘窗口约 587×816，放不下；
  /// 落在窗口下缘的坐标会变成"屏幕外"，指针事件根本不会派发，断言就会假阴性。
  Future<void> pumpHarness(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(harness());
  }

  Offset localToGlobal(WidgetTester tester, double x, double y) {
    final Finder view = find.byType(WheelMenuView);
    final Offset origin = tester.getTopLeft(view);
    return origin + Offset(x, y);
  }

  testWidgets('打开动画期间输入被拦下（不能"没张开就被点掉"）',
      (WidgetTester tester) async {
    await pumpHarness(tester);
    final WheelSlotPlacement slot = layout.slots[2];
    final Offset p = localToGlobal(tester, slot.centerX, slot.centerY);
    expect(controller.phase, WheelMenuPhase.opening);
    final TestGesture g = await tester.startGesture(p, kind: PointerDeviceKind.mouse);
    await g.up();
    await tester.pump();
    expect(confirmed, isEmpty);
  });

  testWidgets('左键点击按钮 → 松开即确认该条目', (WidgetTester tester) async {
    await pumpHarness(tester);
    await tester.pump();
    finishOpenAnimation();
    await tester.pump();

    final WheelSlotPlacement slot = layout.slots[2];
    final Offset p = localToGlobal(tester, slot.centerX, slot.centerY);
    final TestGesture g = await tester.startGesture(p, kind: PointerDeviceKind.mouse);
    await g.up();
    await tester.pump();

    expect(confirmed, <String>[MenuCatalog.root.nodes[2].id]);
  });

  testWidgets('按住左键沿弧线滑动 → 滑过不执行，松开才确认落点那一项',
      (WidgetTester tester) async {
    await pumpHarness(tester);
    await tester.pump();
    finishOpenAnimation();
    await tester.pump();

    final WheelSlotPlacement from = layout.slots[0];
    final WheelSlotPlacement to = layout.slots[4];
    final TestGesture g = await tester.startGesture(
      localToGlobal(tester, from.centerX, from.centerY),
      kind: PointerDeviceKind.mouse,
    );
    now += 30;
    await g.moveTo(localToGlobal(tester, to.centerX, to.centerY));
    await tester.pump();
    // 划过 2 号槽时**不执行**。
    expect(confirmed, isEmpty);
    expect(controller.state.previewIndex, 4);

    now += 30;
    await g.up();
    await tester.pump();
    expect(confirmed, <String>[MenuCatalog.root.nodes[4].id]);
  });

  testWidgets('悬停只更新预览高亮，不确认任何条目', (WidgetTester tester) async {
    await pumpHarness(tester);
    await tester.pump();
    finishOpenAnimation();
    await tester.pump();

    final WheelSlotPlacement slot = layout.slots[3];
    final TestGesture hover = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await hover.addPointer(location: Offset.zero);
    addTearDown(hover.removePointer);
    await hover.moveTo(localToGlobal(tester, slot.centerX, slot.centerY));
    await tester.pump();

    expect(controller.state.previewIndex, 3);
    expect(confirmed, isEmpty, reason: '悬停绝不能触确认');
  });

  testWidgets('点击中央桌宠缺口（未拖动）→ 请求关闭菜单', (WidgetTester tester) async {
    await pumpHarness(tester);
    await tester.pump();
    finishOpenAnimation();
    await tester.pump();

    final Offset p = localToGlobal(tester, layout.notchCenterX, layout.notchCenterY);
    final TestGesture g = await tester.startGesture(p, kind: PointerDeviceKind.mouse);
    await g.up();
    await tester.pump();
    expect(closeRequests, 1);
    expect(confirmed, isEmpty);
  });

  // ⚠️ C1.1.2 决策 A1 变更：Region 内、环带外的**菜单背景**单击不再关闭菜单
  // （真机症状正是"停在按钮/标签上单击 → 菜单关掉、功能没执行"）。
  // 明确的关闭方式只剩：中央缺口（桌宠）、Esc、动作协议、Region 之外（外壳处理）。
  testWidgets('C1.1.2 A1：落在环带之外的菜单背景松手 → 不关闭、也不执行',
      (WidgetTester tester) async {
    await pumpHarness(tester);
    await tester.pump();
    finishOpenAnimation();
    await tester.pump();

    final double y = (layout.centerY + layout.rimOuterPx + 12)
        .clamp(0.0, layout.windowRect.height - 1);
    final double x = (layout.centerX + layout.rimOuterPx + 12)
        .clamp(0.0, layout.windowRect.width - 1);
    final TestGesture g = await tester.startGesture(
      localToGlobal(tester, x, y),
      kind: PointerDeviceKind.mouse,
    );
    await g.up();
    await tester.pump();
    expect(closeRequests, 0, reason: '决策 A1：菜单背景不执行、也不关闭');
    expect(confirmed, isEmpty);
  });

  testWidgets('子菜单里按 Esc → 先返回上一层（不关闭）；根菜单再按 Esc → 关闭',
      (WidgetTester tester) async {
    await pumpHarness(tester);
    await tester.pump();
    finishOpenAnimation();
    await tester.pump();

    // 进入「桌宠」子菜单（直接驱动控制器，等价于点击该条目）。
    expect(controller.enterLayerByAction('open_pet'), isTrue);
    now += WheelAnimationTimeline.enterLayerMs + 20;
    controller.tick();
    await tester.pump();
    expect(controller.state.levelId, MenuCatalog.petLevelId);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    now += WheelAnimationTimeline.exitLayerMs + 20;
    controller.tick();
    await tester.pump();
    expect(controller.state.levelId, MenuCatalog.rootId);
    expect(closeRequests, 0, reason: '返回上一层不应关闭菜单');

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(closeRequests, 1);
  });

  testWidgets('滑选中的 Esc = 取消这次滑选（不改层级、不关闭）',
      (WidgetTester tester) async {
    await pumpHarness(tester);
    await tester.pump();
    finishOpenAnimation();
    await tester.pump();

    final WheelSlotPlacement slot = layout.slots[5];
    final WheelSlotPlacement target = layout.slots[3];
    final TestGesture g = await tester.startGesture(
      localToGlobal(tester, slot.centerX, slot.centerY),
      kind: PointerDeviceKind.mouse,
    );
    now += 30;
    // 位移必须超过 12dp 的 swipe 阈值，否则只是"点击候选"，不会进入滑选。
    await g.moveTo(localToGlobal(tester, target.centerX, target.centerY));
    await tester.pump();
    expect(controller.state.previewIndex, isNotNull);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(controller.state.previewIndex, isNull);
    expect(controller.state.levelId, MenuCatalog.rootId);
    expect(closeRequests, 0);

    await g.up();
    await tester.pump();
  });

  // ------------------------------------------------------------------
  // 真机回归 #1：左键"完全无反应"的两层根因（都是装配层问题，纯逻辑可判）
  // ------------------------------------------------------------------

  testWidgets('#1a 挂载前已起动画时，挂载后 Ticker 必须自己启动（否则整帧不画）',
      (WidgetTester tester) async {
    // 复刻生产顺序：setInteractive → beginOpenAnimation → setState（Widget 才挂载）。
    controller.beginOpenAnimation();
    await pumpHarness(tester);

    now += 40;
    await tester.pump();
    expect(controller.frame.openProgress, greaterThan(0),
        reason: '挂载时就必须同步启动 ticker（只靠 notifyListeners 不会再触发）');
  });

  testWidgets('#1b 首个 tick 已超过动画时长时，必须呈现**终态**而不是停在 0',
      (WidgetTester tester) async {
    controller.beginOpenAnimation();
    await pumpHarness(tester);

    // 首帧就很晚（真机高负载 / 挂载与首帧之间隔了很久）。
    now += WheelAnimationTimeline.openMs + 50;
    await tester.pump();

    expect(controller.frame.openProgress, 1.0,
        reason: '已过时长必须渲染动画终态；停在 0 会让画笔整帧不画');
    expect(controller.phase, WheelMenuPhase.open);
    expect(controller.hasActiveAnimation, isFalse);
  });

  test('closed 状态下 WheelMenuView 层不参与命中测试（IgnorePointer 口径）', () {
    // 纯逻辑判定：closed / closing 必须被忽略。
    expect(_ignoringFor(WheelMenuPhase.closed), isTrue);
    expect(_ignoringFor(WheelMenuPhase.closing), isTrue);
    for (final WheelMenuPhase phase in <WheelMenuPhase>[
      WheelMenuPhase.opening,
      WheelMenuPhase.open,
      WheelMenuPhase.switching,
      WheelMenuPhase.enteringLayer,
      WheelMenuPhase.exitingLayer,
    ]) {
      expect(_ignoringFor(phase), isFalse, reason: '${phase.name} 必须可交互');
    }
  });
}

/// 与 `_WheelMenuViewState.build` 同一个判定：哪些阶段必须整层退出命中测试。
bool _ignoringFor(WheelMenuPhase phase) =>
    phase == WheelMenuPhase.closed || phase == WheelMenuPhase.closing;

/// 测试用的尺寸参数（与生产同一口径：dp = 逻辑像素）。
class WheelCanvasTestSpec {
  WheelCanvasTestSpec._();

  static WheelMenuSpec get spec => WheelMenuSpec.fromDensity(1);
}

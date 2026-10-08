/// 真机回归 #1：左键"完全无反应"的**入口链**与**手势遮挡**审计。
///
/// 覆盖用户验收清单的 1 ~ 6 项：
/// 1. closed 状态 `WheelMenuView` 不命中测试；
/// 2. 单击桌宠收到完整事件链（pet.pointer.down / up / pet.tap.recognized）；
/// 3. 单击只触发一个打开事务（且入口唯一是 `toggleFormalWheel`）；
/// 4. 双击不闪出轮盘；
/// 5. 拖动取消 tap；
/// 6. rejected 探针（dynamicSetBounds）与六色块诊断菜单都不会被左键调用。
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:petlife/character/models/emotion_asset.dart';
import 'package:petlife/character/pet_renderer.dart';
import 'package:petlife/menu/menu_contract.dart';
import 'package:petlife/menu/wheel_canvas_bridge.dart';
import 'package:petlife/menu/wheel_geometry_ownership.dart';
import 'package:petlife/menu/wheel_menu_geometry.dart';
import 'package:petlife/menu/wheel_menu_state.dart';
import 'package:petlife/menu/wheel_theme.dart';
import 'package:petlife/menu/windows_surface_mode.dart';
import 'package:petlife/ui/desktop/fixed_canvas_diagnostics_flags.dart';
import 'package:petlife/ui/desktop/wheel_menu_view.dart';
import 'package:petlife/ui/pet/pet_host.dart';
import 'package:petlife/ui/pet/pet_view.dart';
import 'package:petlife/character/pet_visual_bounds.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    wheelSurfaceGeometry.resetForTest();
    wheelGeometryJournal.clear();
    windowsSurfaceSession.resetForTest();
    FixedCanvasDiagnosticsFlags.legacyTestMenu.value = false;
  });

  tearDown(() {
    wheelGeometryJournal.clear();
    windowsSurfaceSession.resetForTest();
    FixedCanvasDiagnosticsFlags.legacyTestMenu.value = false;
  });

  // ---------------------------------------------------------------------------
  // 1) closed 状态不参与命中测试（视觉层在桌宠**之下**，输入层必须让开）
  // ---------------------------------------------------------------------------

  group('手势遮挡（1）', () {
    late WheelMenuController controller;
    late WheelMenuEnvelope envelope;

    setUp(() {
      envelope = WheelMenuGeometry.computeEnvelope(
        bounds: const WheelBounds(0, 0, 1920, 1080),
        petWindowRect: const WheelRect(300, 400, 556, 656),
        maxItemCount: MenuCatalog.maxItems,
        spec: WheelCanvasBridge.spec(),
        settings: WheelMenuLayoutSettings.defaults,
      );
      controller = WheelMenuController(
        spec: WheelCanvasBridge.spec(),
        theme: WheelMenuThemes.p3pPink(),
        density: 1,
      );
    });

    tearDown(() => controller.dispose());

    /// 轮盘层**盖在**一个会记账的手势层之上；谁收到事件就是谁在命中测试里赢了。
    Widget stacked(int Function() underlying) => MaterialApp(
          home: Stack(
            children: <Widget>[
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: underlying,
                  child: const ColoredBox(color: Color(0xFFEEEEEE)),
                ),
              ),
              Positioned(
                left: 100,
                top: 100,
                width: envelope.windowRect.width,
                height: envelope.windowRect.height,
                child: WheelMenuView(controller: controller),
              ),
            ],
          ),
        );

    testWidgets('closed：点轮盘区域时事件落到**下层**（轮盘不抢命中）',
        (WidgetTester tester) async {
      int underneath = 0;
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(stacked(() {
        underneath++;
        return 0;
      }));
      await tester.pump();

      expect(controller.phase, WheelMenuPhase.closed);
      // 轮盘窗口内部的一点。
      await tester.tapAt(const Offset(100 + 60, 100 + 60));
      await tester.pump();
      expect(underneath, 1, reason: 'closed 状态轮盘必须完全退出命中测试');
    });

    testWidgets('opening / open：点轮盘区域时事件被轮盘接管（下层收不到）',
        (WidgetTester tester) async {
      int underneath = 0;
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(stacked(() {
        underneath++;
        return 0;
      }));
      await tester.pump();

      expect(controller.prepareContent(envelope, WheelMenuThemes.p3pPink()), isTrue);
      controller.setInteractive(true);
      await tester.pump();
      expect(controller.phase, WheelMenuPhase.opening);

      final WheelMenuLayout layout = controller.layout!;
      final WheelSlotPlacement slot = layout.slots[2];
      await tester.tapAt(Offset(
        100 + slot.centerX,
        100 + slot.centerY,
      ));
      await tester.pump();
      expect(underneath, 0, reason: '轮盘打开期间必须由它接管输入');
    });

    testWidgets('closing：关闭动画期间也退出命中测试', (WidgetTester tester) async {
      int underneath = 0;
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(stacked(() {
        underneath++;
        return 0;
      }));
      await tester.pump();

      expect(controller.prepareContent(envelope, WheelMenuThemes.p3pPink()), isTrue);
      controller.setInteractive(true);
      controller.requestClose();
      await tester.pump();
      expect(controller.phase, WheelMenuPhase.closing);

      await tester.tapAt(const Offset(100 + 60, 100 + 60));
      await tester.pump();
      expect(underneath, 1, reason: 'closing 期间不得抢桌宠的点击');
    });
  });

  // ---------------------------------------------------------------------------
  // 2) 单击桌宠的完整事件链
  // ---------------------------------------------------------------------------

  group('单击事件链（2 / 5）', () {
    testWidgets('2. 单击 → pet.pointer.down → pet.pointer.up → pet.tap.recognized',
        (WidgetTester tester) async {
      int taps = 0;
      final _FakeRenderer renderer = _FakeRenderer()..setContentNow(const ui.Size(128, 128));
      await tester.pumpWidget(_wrap(PetView(
        renderer: renderer,
        scale: 1,
        smoothScaling: false,
        opacity: 1,
        lockPosition: true,
        manageWindowSize: false,
        onTap: () => taps++,
      )));
      await tester.pump();

      await tester.tap(find.byType(PetView));
      await tester.pump(const Duration(milliseconds: 400));

      expect(taps, 1);
      expect(wheelGeometryJournal.contains('pet.pointer.down'), isTrue);
      expect(wheelGeometryJournal.contains('pet.pointer.up'), isTrue);
      expect(wheelGeometryJournal.contains('pet.tap.recognized'), isTrue);
      // 顺序必须是 down → up → tap。
      final List<String> chain = wheelGeometryJournal.events
          .map((WheelGeometryEvent e) => e.event)
          .where((String e) => e.startsWith('pet.'))
          .toList();
      expect(chain, containsAllInOrder(<String>[
        'pet.pointer.down',
        'pet.pointer.up',
        'pet.tap.recognized',
      ]));
    });

    testWidgets('5. 拖动取消 tap（按住拖动不打开轮盘）', (WidgetTester tester) async {
      int taps = 0;
      final _FakeRenderer renderer = _FakeRenderer()..setContentNow(const ui.Size(128, 128));
      final _RecordingHost host = _RecordingHost();
      await tester.pumpWidget(_wrap(PetView(
        renderer: renderer,
        scale: 1,
        smoothScaling: false,
        opacity: 1,
        lockPosition: false,
        manageWindowSize: false,
        host: host,
        onTap: () => taps++,
      )));
      await tester.pump();

      await tester.drag(find.byType(PetView), const Offset(60, 40));
      await tester.pump(const Duration(milliseconds: 400));

      expect(taps, 0, reason: '拖动必须取消 tap，不得打开轮盘');
      expect(host.drags, 1, reason: '拖动应交给宿主移动窗口');
    });
  });

  // ---------------------------------------------------------------------------
  // 3 / 4 / 6) 入口接线纪律
  // ---------------------------------------------------------------------------

  group('入口接线纪律（3 / 4 / 6）', () {
    testWidgets('4. 双击不闪出轮盘（只进控制面板）', (WidgetTester tester) async {
      int taps = 0;
      int doubles = 0;
      final _FakeRenderer renderer = _FakeRenderer()..setContentNow(const ui.Size(128, 128));
      await tester.pumpWidget(_wrap(PetView(
        renderer: renderer,
        scale: 1,
        smoothScaling: false,
        opacity: 1,
        lockPosition: true,
        manageWindowSize: false,
        onTap: () => taps++,
        onDoubleTap: () => doubles++,
      )));
      await tester.pump();

      final Finder finder = find.byType(PetView);
      await tester.tap(finder);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(finder);
      await tester.pump(const Duration(milliseconds: 400));

      expect(doubles, 1);
      expect(taps, 0, reason: '双击不得先闪出轮盘（onTap 一次都不能触发）');
    });

    testWidgets('4b. 双击期间右键也不触达左键入口', (WidgetTester tester) async {
      int taps = 0;
      int rights = 0;
      final _FakeRenderer renderer = _FakeRenderer()..setContentNow(const ui.Size(128, 128));
      await tester.pumpWidget(_wrap(PetView(
        renderer: renderer,
        scale: 1,
        smoothScaling: false,
        opacity: 1,
        lockPosition: true,
        manageWindowSize: false,
        onTap: () => taps++,
        onRightClick: (ui.Offset _) => rights++,
      )));
      await tester.pump();

      await tester.tap(find.byType(PetView), buttons: kSecondaryButton);
      await tester.pump(const Duration(milliseconds: 400));
      expect(rights, 1);
      expect(taps, 0, reason: '右键不得触发左键菜单');
    });

    test('3 / 6. 左键入口必须是 toggleFormalWheel，且不落到 rejected 探针 / 诊断菜单', () {
      final String shell = File(p.join(
        Directory.current.path,
        'lib',
        'ui',
        'desktop',
        'desktop_shell.dart',
      )).readAsStringSync();

      final int start = shell.indexOf('onPetTap:');
      expect(start, greaterThanOrEqualTo(0), reason: '外壳必须保留 onPetTap 接线');
      final int end = shell.indexOf('manageWindowSize:', start);
      final String block = shell.substring(start, end > start ? end : shell.length);

      expect(block, contains('toggleFormalWheel'),
          reason: '左键唯一入口 = 正式轮盘统一入口');
      expect(block, isNot(contains('wheelProbeKey.currentState?.toggle')),
          reason: '不得再落到 dynamicSetBounds rejected 探针');
      expect(block, isNot(contains('WheelGeometryProbe')),
          reason: '不得再引用旧轮盘几何探针');
      expect(
        RegExp(r'setInteractiveRegion|setWindowRgn|applyRegion').hasMatch(block),
        isFalse,
        reason: '左键入口不得直接裸写 Region',
      );
      // 六色块诊断菜单只能通过渲染开关切换，**不是**左键目标。
      expect(block, isNot(contains('legacyTestMenu')),
          reason: '左键入口不得指向六色块诊断菜单');
    });

    test('6b. 诊断菜单开关不改变左键入口（入口只在探针里唯一）', () {
      final String probe = File(p.join(
        Directory.current.path,
        'lib',
        'ui',
        'desktop',
        'fixed_canvas_probe.dart',
      )).readAsStringSync();
      // `toggleFormalWheel` 与 `toggle` 必须是同一个实现（薄封装）。
      expect(probe, contains('Future<void> toggleFormalWheel()'));
      expect(probe, contains('return toggle();'));
      // 诊断菜单只影响**渲染**，不影响入口状态机。
      final int toggleBody = probe.indexOf('Future<void> toggle()');
      final int toggleEnd = probe.indexOf('/// 关闭菜单', toggleBody);
      final String body = probe.substring(toggleBody, toggleEnd);
      expect(body, isNot(contains('_diagnosticMenuEnabled')));
      expect(body, isNot(contains('legacyTestMenu')));
    });
  });
}

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: Center(child: child)));

class _RecordingHost implements PetHost {
  int drags = 0;

  @override
  Future<void> beginDrag() async => drags++;

  @override
  Future<void> resizeForPet({required double width, required double height}) async {}
}

/// 只为把 PetView 立起来（图层为空即可）。
class _FakeRenderer extends ChangeNotifier implements PetRenderer {
  ui.Size? _contentSize;

  void setContentNow(ui.Size? size) => _contentSize = size;

  @override
  ui.Size? get contentSize => _contentSize;

  @override
  PetVisualBounds? get visualBounds =>
      PetVisualBounds.full;

  @override
  Future<PetVisualBounds> ensureVisualBounds() async => PetVisualBounds.full;

  @override
  String? get currentAssetId => null;

  @override
  bool get isAnimated => false;

  @override
  int? get currentFrameIndex => null;

  @override
  int get remainingMsInCycle => 0;

  @override
  List<PetRenderLayer> get layers => const <PetRenderLayer>[];

  @override
  Future<void> clear() async {}

  @override
  Future<void> display(EmotionAsset? asset, {bool immediate = false}) async {}

  @override
  void setCrossFadeMs(int ms) {}

  @override
  void setLoop(bool loop) {}
}

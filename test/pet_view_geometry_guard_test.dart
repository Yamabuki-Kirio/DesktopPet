import 'dart:ui' as ui;

import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:petlife/character/models/emotion_asset.dart';
import 'package:petlife/character/pet_renderer.dart';
import 'package:petlife/menu/wheel_geometry_ownership.dart';
import 'package:petlife/menu/windows_surface_mode.dart';
import 'package:petlife/ui/pet/pet_host.dart';
import 'package:petlife/ui/pet/pet_view.dart';
import 'package:petlife/character/pet_visual_bounds.dart';

/// 增量 A 修复：`PetView` 的**延迟 resize 守卫**与右键 / 双击入口不回归。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    wheelSurfaceGeometry.resetForTest();
    wheelGeometryJournal.clear();
    windowsSurfaceSession.resetForTest();
  });

  testWidgets('#1 打开菜单后，已入队的 pet resize 回调必须被丢弃（不再把窗口缩回）', (WidgetTester tester) async {
    final _FakeRenderer renderer = _FakeRenderer()..setContentNow(const ui.Size(128, 128));
    final _RecordingHost host = _RecordingHost();

    await tester.pumpWidget(_wrap(_petView(renderer, host)));
    await tester.pump(); // 初始 resize（owner=pet）执行
    expect(host.calls, isNotEmpty, reason: '正常 pet 态应能跟随素材尺寸');
    host.calls.clear();

    // 素材尺寸变化 → 触发一次调度；本帧结束前先切到过渡态（菜单正在打开）。
    renderer.setContent(const ui.Size(200, 160));
    tester.binding.addPostFrameCallback((Duration _) {
      wheelSurfaceGeometry.change(WindowsSurfaceGeometryOwner.wheelTransition, source: 'test');
    });
    await tester.pump();

    expect(host.calls, isEmpty, reason: '过渡期已排队的 resize 必须被丢弃，绝不能把窗口缩回');
    expect(wheelGeometryJournal.contains('pet.resize.dropped'), isTrue);
  });

  testWidgets('#11 关闭菜单（owner 回到 pet）后，pet 尺寸跟随仍正常工作', (WidgetTester tester) async {
    final _FakeRenderer renderer = _FakeRenderer()..setContentNow(const ui.Size(128, 128));
    final _RecordingHost host = _RecordingHost();
    await tester.pumpWidget(_wrap(_petView(renderer, host)));
    await tester.pump();
    host.calls.clear();

    wheelSurfaceGeometry.change(WindowsSurfaceGeometryOwner.wheel, source: 'test');
    renderer.setContent(const ui.Size(200, 160));
    await tester.pump();
    expect(host.calls, isEmpty, reason: '菜单开放期间不应写窗口');

    wheelSurfaceGeometry.resetForTest();
    renderer.setContent(const ui.Size(222, 111));
    await tester.pump();
    await tester.pump();
    expect(host.calls.single, const ui.Size(222, 111));
  });

  testWidgets('#12 单击 / 双击 / 右键回调仍接线（右键菜单与双击面板入口不回归）', (WidgetTester tester) async {
    int taps = 0;
    int doubles = 0;
    int rights = 0;
    final _FakeRenderer renderer = _FakeRenderer()..setContentNow(const ui.Size(128, 128));
    final _RecordingHost host = _RecordingHost();

    await tester.pumpWidget(_wrap(PetView(
      renderer: renderer,
      scale: 1,
      smoothScaling: false,
      opacity: 1,
      lockPosition: false,
      manageWindowSize: true,
      host: host,
      onTap: () => taps++,
      onDoubleTap: () => doubles++,
      onRightClick: (ui.Offset _) => rights++,
    )));
    await tester.pump();

    final Finder finder = find.byType(PetView);

    // 单击
    await tester.tap(finder);
    await tester.pump(const Duration(milliseconds: 400));
    expect(taps, 1);

    // 右键（二级键）
    await tester.tap(finder, buttons: kSecondaryButton);
    await tester.pump();
    expect(rights, 1);

    // 双击
    await tester.tap(finder);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(finder);
    await tester.pump(const Duration(milliseconds: 400));
    expect(doubles, 1);
    expect(taps, 1, reason: '双击不应额外触发单击');
  });
}

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: Center(child: child)));

Widget _petView(PetRenderer renderer, PetHost host) => PetView(
      renderer: renderer,
      scale: 1,
      smoothScaling: false,
      opacity: 1,
      lockPosition: false,
      manageWindowSize: true,
      host: host,
    );

class _RecordingHost implements PetHost {
  final List<ui.Size> calls = <ui.Size>[];

  @override
  Future<void> beginDrag() async {}

  @override
  Future<void> resizeForPet({required double width, required double height}) async {
    calls.add(ui.Size(width, height));
  }
}

class _FakeRenderer extends ChangeNotifier implements PetRenderer {
  ui.Size? _contentSize;

  void setContentNow(ui.Size? size) {
    _contentSize = size;
  }

  void setContent(ui.Size? size) {
    _contentSize = size;
    notifyListeners();
  }

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
  Future<void> display(EmotionAsset? asset, {bool immediate = false}) async {}

  @override
  void setLoop(bool loop) {}

  @override
  void setCrossFadeMs(int ms) {}

  @override
  Future<void> clear() async {}
}

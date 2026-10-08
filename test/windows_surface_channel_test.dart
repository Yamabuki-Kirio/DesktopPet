import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:petlife/menu/fixed_canvas_contract.dart';
import 'package:petlife/menu/fixed_canvas_geometry.dart' show PhysicalRect;
import 'package:petlife/platform/windows/windows_surface_channel.dart';

/// Windows Region 原生桥的**通道协议**单测。
///
/// 只验证 Dart ↔ 原生的方法名 / 参数 / 返回解析，不需要真的建窗口。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<MethodCall> calls;
  late MethodChannel channel;
  late Object? Function(MethodCall call) responder;

  setUp(() {
    calls = <MethodCall>[];
    channel = const MethodChannel(windowsSurfaceChannelName);
    responder = (MethodCall call) => null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      calls.add(call);
      return responder(call);
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('通道名与三条可调用方法名（+ 两条诊断）冻结', () {
    expect(windowsSurfaceChannelName, 'asia.akechi.petlife/windows_surface');
    expect(windowsSurfaceApplyRegion, 'applyInteractionRegion');
    expect(windowsSurfaceClearRegion, 'clearInteractionRegion');
    expect(windowsSurfaceRestorePetOnly, 'restorePetOnlyRegion');
    expect(windowsSurfaceGdiObjectCount, 'gdiObjectCount');
    expect(windowsSurfaceRegionBoundingBox, 'regionBoundingBox');
  });

  test('applyInteractionRegion：逻辑矩形按 dpr 换算成物理像素', () async {
    responder = (MethodCall call) => <String, Object?>{
          'success': true,
          'rectCount': 1,
          'boundingBox': <String, Object?>{
            'left': 250,
            'top': 125,
            'right': 890,
            'bottom': 765,
          },
        };
    final WindowsSurfaceBridge bridge = WindowsSurfaceBridge(channel: channel);

    final RegionApplyResult r = await bridge.applyInteractionRegion(
      <Rect>[const Rect.fromLTWH(100, 50, 256, 256)],
      devicePixelRatio: 1.25,
    );

    expect(calls.single.method, 'applyInteractionRegion');
    final Map<Object?, Object?> args =
        calls.single.arguments as Map<Object?, Object?>;
    final List<Object?> rects = args['rects']! as List<Object?>;
    expect(rects, hasLength(1));
    expect(rects.single, <String, int>{
      'left': 125,
      'top': 63,
      'right': 445,
      'bottom': 383,
    });
    expect(r.success, isTrue);
    expect(r.boundingBox, const PhysicalRect(250, 125, 890, 765));
  });

  test('restorePetOnlyRegion：走同名原生方法', () async {
    responder = (MethodCall call) => <String, Object?>{'success': true, 'rectCount': 1};
    final WindowsSurfaceBridge bridge = WindowsSurfaceBridge(channel: channel);

    final RegionApplyResult r = await bridge.restorePetOnlyRegion(
      const Rect.fromLTWH(0, 0, 256, 256),
      devicePixelRatio: 1.0,
    );

    expect(calls.single.method, 'restorePetOnlyRegion');
    expect(r.success, isTrue);
  });

  test('clearInteractionRegion：解析 bool 与 Map 两种返回', () async {
    final WindowsSurfaceBridge bridge = WindowsSurfaceBridge(channel: channel);

    responder = (MethodCall call) => true;
    expect(await bridge.clearInteractionRegion(), isTrue);
    expect(calls.last.method, 'clearInteractionRegion');

    responder = (MethodCall call) => <String, Object?>{'success': false};
    expect(await bridge.clearInteractionRegion(), isFalse);
  });

  test('原生报错（PlatformException）→ Region 失败，触发回退', () async {
    responder = (MethodCall call) =>
        throw PlatformException(code: 'set_window_rgn_failed', message: 'boom');
    final WindowsSurfaceBridge bridge = WindowsSurfaceBridge(channel: channel);

    final RegionApplyResult r = await bridge.applyInteractionRegion(
      <Rect>[const Rect.fromLTWH(0, 0, 10, 10)],
      devicePixelRatio: 1.0,
    );
    expect(r.success, isFalse);
    expect(r.error, contains('set_window_rgn_failed'));
  });

  test('通道缺失（未实现）→ 失败，不抛错（可回退小窗口）', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    final WindowsSurfaceBridge bridge = WindowsSurfaceBridge(channel: channel);

    final RegionApplyResult r = await bridge.applyInteractionRegion(
      <Rect>[const Rect.fromLTWH(0, 0, 10, 10)],
      devicePixelRatio: 1.0,
    );
    expect(r.success, isFalse);
    expect(await bridge.clearInteractionRegion(), isFalse);
    expect(await bridge.gdiObjectCount(), isNull);
    expect(await bridge.regionBoundingBox(), isNull);
  });

  test('空矩形列表 → 直接失败，不调用原生', () async {
    final WindowsSurfaceBridge bridge = WindowsSurfaceBridge(channel: channel);
    final RegionApplyResult r =
        await bridge.applyInteractionRegion(<Rect>[], devicePixelRatio: 1.0);
    expect(r.success, isFalse);
    expect(calls, isEmpty);
  });

  test('gdiObjectCount / regionBoundingBox 解析', () async {
    final WindowsSurfaceBridge bridge = WindowsSurfaceBridge(channel: channel);

    responder = (MethodCall call) => 1234;
    expect(await bridge.gdiObjectCount(), 1234);
    expect(calls.last.method, 'gdiObjectCount');

    responder = (MethodCall call) => <String, Object?>{
          'left': 0,
          'top': 0,
          'right': 100,
          'bottom': 80,
        };
    expect(await bridge.regionBoundingBox(), const PhysicalRect(0, 0, 100, 80));
    expect(calls.last.method, 'regionBoundingBox');
  });
}

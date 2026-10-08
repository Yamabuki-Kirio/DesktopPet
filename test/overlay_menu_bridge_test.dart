import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:petlife/platform/android/android_overlay_menu_bridge.dart';
import 'package:petlife/platform/android/android_overlay_pet.dart'
    show androidOverlayChannelName;
import 'package:petlife/platform/overlay_pet.dart';

/// Phase 4C-6B-2：轮盘菜单通道的**契约**测试。
///
/// 这一层只关心"两边说的是不是同一套话"：
/// * 通道名必须与原生 `PetOverlayBridge.CHANNEL_NAME` 完全一致；
/// * 方法名与参数/返回结构必须与冻结契约逐字对应；
/// * 注册原生 → Dart 处理器**不得**影响同一个通道上 Dart → 原生的调用
///   （两者共用通道名，这是本阶段最容易被写坏的一处）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodCodec codec = StandardMethodCodec();
  final MethodChannel channel = const MethodChannel(androidOverlayChannelName);
  final List<MethodCall> outgoing = <MethodCall>[];

  /// 测试里动态指定"原生"对某个调用的答复。
  Object? Function(MethodCall call) responder = (MethodCall call) => null;

  late AndroidOverlayMenuBridge bridge;

  setUp(() {
    outgoing.clear();
    responder = (MethodCall call) => null;
    bridge = AndroidOverlayMenuBridge(channel: channel);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      outgoing.add(call);
      return responder(call);
    });
  });

  tearDown(() {
    bridge.clearMenuRequestHandler();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  /// 模拟原生 → Dart 的一次调用，返回 Dart 侧的答复。
  Future<Map<String, Object?>?> callFromNative(String method, Object? args) async {
    final ByteData data = codec.encodeMethodCall(MethodCall(method, args));
    final ByteData? reply = await TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .handlePlatformMessage(channel.name, data, (ByteData? _) {});
    if (reply == null) return null;
    final Object? decoded = codec.decodeEnvelope(reply);
    if (decoded is! Map) return null;
    return decoded.map<String, Object?>(
      (Object? key, Object? value) => MapEntry<String, Object?>('$key', value),
    );
  }

  test('通道名与原生 PetOverlayBridge 完全一致（复用既有通道）', () {
    expect(androidOverlayChannelName, 'asia.akechi.petlife/overlay');
    expect(AndroidOverlayMenuBridge.methodMenuRequest, 'menuRequest');
    expect(AndroidOverlayMenuBridge.methodPullPending, 'pullPendingMenuRequests');
    expect(AndroidOverlayMenuBridge.methodComplete, 'completeMenuRequest');
  });

  test('pullPendingMenuRequests：方法名 + requests 数组解析', () async {
    responder = (MethodCall call) => <String, Object?>{
          'requests': <Object?>[
            <String, Object?>{
              'requestId': 'r1',
              'actionId': 'records_today',
              'args': <String, Object?>{'x': 1},
              'createdAt': 123,
              'status': 'pending',
            },
            // 坏数据：缺 actionId → 跳过，不影响整批。
            <String, Object?>{'requestId': 'bad'},
          ],
        };

    final List<OverlayMenuRequest> requests = await bridge.pullPendingMenuRequests();

    expect(outgoing.single.method, 'pullPendingMenuRequests');
    expect(requests, hasLength(1));
    expect(requests.single.requestId, 'r1');
    expect(requests.single.actionId, 'records_today');
    expect(requests.single.args['x'], 1);
    expect(requests.single.createdAt, 123);
    expect(requests.single.status, MenuRequestStatus.pending);
  });

  test('completeMenuRequest：方法名 + 参数结构 + ok 读取', () async {
    responder = (MethodCall call) => <String, Object?>{'ok': true};

    final bool ok = await bridge.completeMenuRequest(
      requestId: 'r1',
      status: MenuRequestStatus.completed,
      message: '已执行',
    );

    expect(outgoing.single.method, 'completeMenuRequest');
    expect(outgoing.single.arguments, <String, Object?>{
      'requestId': 'r1',
      'status': 'completed',
      'message': '已执行',
    });
    expect(ok, isTrue);
  });

  test('注册原生 → Dart 处理器后，同一通道的 Dart → 原生调用仍然可用', () async {
    // 这一条是审计项：`setMethodCallHandler` 按 (messenger, 通道名) 注册，
    // 不会覆盖/影响同名的 `invokeMethod`（原生仍有 invokeMethod 进来的路径）。
    bridge.bindMenuRequestHandler(
      (OverlayMenuRequest request) async => <String, Object?>{'status': 'completed'},
    );
    responder = (MethodCall call) => <String, Object?>{'requests': <Object?>[]};

    expect(await bridge.pullPendingMenuRequests(), isEmpty);
    expect(outgoing.map((MethodCall c) => c.method), <String>['pullPendingMenuRequests']);
  });

  test('原生 menuRequest：解析请求并原样返回 {status, message}', () async {
    final List<String> handled = <String>[];
    bridge.bindMenuRequestHandler((OverlayMenuRequest request) async {
      handled.add('${request.actionId}/${request.args['themeId']}');
      return <String, Object?>{'status': 'completed', 'message': '已处理'};
    });

    final Map<String, Object?>? reply = await callFromNative('menuRequest', <String, Object?>{
      'requestId': 'r9',
      'actionId': 'settings_theme',
      'args': <String, Object?>{'themeId': 'blue'},
      'createdAt': 1,
      'status': 'pending',
    });

    expect(handled, <String>['settings_theme/blue']);
    expect(reply, isNotNull);
    expect(reply!['status'], 'completed');
    expect(reply['message'], '已处理');
    // 原生 → Dart 的调用不占用 Dart → 原生的通道（没有产生任何出站调用）。
    expect(outgoing, isEmpty);
  });

  test('原生 menuRequest 参数不完整时如实报 failed，不崩', () async {
    bridge.bindMenuRequestHandler(
      (OverlayMenuRequest request) async => <String, Object?>{'status': 'completed'},
    );

    final Map<String, Object?>? reply =
        await callFromNative('menuRequest', <String, Object?>{'actionId': 'pet_auto'});

    expect(reply, isNotNull);
    expect(reply!['status'], 'failed');
  });

  test('未知原生方法返回 null（不抛错、不谎报成功）', () async {
    bridge.bindMenuRequestHandler(
      (OverlayMenuRequest request) async => <String, Object?>{'status': 'completed'},
    );

    final Map<String, Object?>? reply = await callFromNative('somethingElse', null);

    expect(reply, isNull);
    expect(outgoing, isEmpty);
  });

  test('通道不存在（非 Android / 原生未注册）→ OverlayUnsupportedException', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);

    await expectLater(
      bridge.pullPendingMenuRequests(),
      throwsA(isA<OverlayUnsupportedException>()),
    );
  });
}

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:petlife/platform/android/android_overlay_pet.dart';
import 'package:petlife/platform/overlay_pet.dart';
import 'package:petlife/state_engine/state_snapshot.dart';
import 'package:petlife/ui/overlay_pet_controller.dart';

/// 迁移期临时回退开关「双窗口实现」（Frozen contract：`get/setDualWindowMode`）。
///
/// 覆盖四件事：
/// * 返回值解析（true / false / 坏值 → 安全默认）；
/// * 通道协议（复用既有通道、方法名与参数）；
/// * 非 Android 的安全默认（读写都不抛错）；
/// * 控制器「写后回读」的失败回退（被拒绝 / 抛错都不能谎报成功）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('解析与往返（宽容，不因坏数据崩溃）', () {
    test('true / false 原样解析，supported 恒为 true', () {
      expect(DualWindowModeStatus.fromValue(true).supported, isTrue);
      expect(DualWindowModeStatus.fromValue(true).dualWindowEnabled, isTrue);
      expect(DualWindowModeStatus.fromValue(false).dualWindowEnabled, isFalse);
    });

    test('坏值 → 安全默认（true = 双窗口），不抛错', () {
      for (final Object? bad in <Object?>[
        null,
        'yes',
        1,
        0.0,
        <String, Object?>{'enabled': false},
      ]) {
        final DualWindowModeStatus s = DualWindowModeStatus.fromValue(bad);
        expect(s.supported, isTrue, reason: '坏值：$bad');
        expect(s.dualWindowEnabled, isTrue,
            reason: '坏值应回退到默认双窗口，实际：$bad');
      }
    });

    test('unsupported 常量：supported=false，安全默认 true', () {
      expect(DualWindowModeStatus.unsupported.supported, isFalse);
      expect(DualWindowModeStatus.unsupported.dualWindowEnabled, isTrue);
    });

    test('modeLabelZh 与取值一致', () {
      expect(
        const DualWindowModeStatus(supported: true, dualWindowEnabled: true)
            .modeLabelZh,
        '双窗口（新实现）',
      );
      expect(
        const DualWindowModeStatus(supported: true, dualWindowEnabled: false)
            .modeLabelZh,
        '单窗口（回退）',
      );
    });
  });

  group('MethodChannel 协议（复用既有通道常量）', () {
    late List<MethodCall> calls;
    late MethodChannel channel;
    late Object? Function(MethodCall call) responder;

    setUp(() {
      calls = <MethodCall>[];
      channel = const MethodChannel(androidOverlayChannelName);
      responder = (MethodCall call) => true;
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

    test('通道名复用既有常量（不硬编码第二份）', () {
      expect(androidOverlayChannelName, 'asia.akechi.petlife/overlay');
    });

    test('getDualWindowMode：无参数；原生回 true 解析为启用', () async {
      responder = (MethodCall call) => true;
      final AndroidOverlayPetBridge bridge =
          AndroidOverlayPetBridge(channel: channel);

      final DualWindowModeStatus s = await bridge.dualWindowMode();

      expect(calls.single.method, 'getDualWindowMode');
      expect(calls.single.arguments, isNull);
      expect(s.supported, isTrue);
      expect(s.dualWindowEnabled, isTrue);
    });

    test('getDualWindowMode：原生回 false 解析为回退单窗口', () async {
      responder = (MethodCall call) => false;
      final AndroidOverlayPetBridge bridge =
          AndroidOverlayPetBridge(channel: channel);

      final DualWindowModeStatus s = await bridge.dualWindowMode();

      expect(s.dualWindowEnabled, isFalse);
    });

    test('getDualWindowMode：原生回坏值 → 安全默认双窗口', () async {
      responder = (MethodCall call) => 'nope';
      final AndroidOverlayPetBridge bridge =
          AndroidOverlayPetBridge(channel: channel);

      final DualWindowModeStatus s = await bridge.dualWindowMode();

      expect(s.supported, isTrue);
      expect(s.dualWindowEnabled, isTrue);
    });

    test('setDualWindowMode：以 bool 为参数；原生回 true = 已接受', () async {
      responder = (MethodCall call) => true;
      final AndroidOverlayPetBridge bridge =
          AndroidOverlayPetBridge(channel: channel);

      final bool accepted = await bridge.setDualWindowMode(false);

      expect(calls.single.method, 'setDualWindowMode');
      expect(calls.single.arguments, false);
      expect(accepted, isTrue);
    });

    test('setDualWindowMode：原生未接受（非 true）→ false，不谎报成功', () async {
      responder = (MethodCall call) => null;
      final AndroidOverlayPetBridge bridge =
          AndroidOverlayPetBridge(channel: channel);

      expect(await bridge.setDualWindowMode(true), isFalse);
    });

    test('通道缺失 → OverlayUnsupportedException（构建配置错误）', () async {
      final AndroidOverlayPetBridge bridge = AndroidOverlayPetBridge(
        channel: const MethodChannel('asia.akechi.petlife/overlay-missing'),
      );

      await expectLater(
        bridge.dualWindowMode(),
        throwsA(isA<OverlayUnsupportedException>()),
      );
    });
  });

  group('非 Android 平台（安全默认，不抛错）', () {
    test('读：返回"不支持"的安全默认', () async {
      const UnsupportedOverlayPet overlay = UnsupportedOverlayPet();

      final DualWindowModeStatus s = await overlay.dualWindowMode();

      expect(s.supported, isFalse);
      expect(s.dualWindowEnabled, isTrue);
    });

    test('写：返回 false（安全值），不抛错', () async {
      const UnsupportedOverlayPet overlay = UnsupportedOverlayPet();

      expect(await overlay.setDualWindowMode(true), isFalse);
      expect(await overlay.setDualWindowMode(false), isFalse);
    });
  });

  group('Controller 透传与失败回退（写后回读）', () {
    late _FakeDualWindowOverlay overlay;
    late ValueNotifier<StateSnapshot> snapshots;
    late OverlayPetController controller;

    setUp(() {
      overlay = _FakeDualWindowOverlay();
      snapshots = ValueNotifier<StateSnapshot>(StateSnapshot.initial());
      controller = OverlayPetController(
        overlay: overlay,
        snapshots: snapshots,
        privateAssetsRoot: () => 'unused',
        delay: (Duration _) async {},
      );
    });

    tearDown(() {
      controller.dispose();
      snapshots.dispose();
    });

    test('refresh 透传原生真值', () async {
      overlay.current = false;

      final DualWindowModeStatus s = await controller.refreshDualWindowMode();

      expect(s.dualWindowEnabled, isFalse);
      expect(controller.dualWindowModeState.dualWindowEnabled, isFalse);
      expect(overlay.calls, contains('getDualWindowMode'));
    });

    test('写入被接受 → 回读真值更新', () async {
      overlay
        ..current = true
        ..accept = true;

      final DualWindowModeStatus s = await controller.setDualWindowMode(false);

      expect(s.dualWindowEnabled, isFalse);
      expect(controller.dualWindowModeState.dualWindowEnabled, isFalse);
      expect(overlay.calls, contains('setDualWindowMode:false'));
      // 写后必须回读一次原生真值。
      expect(overlay.calls, contains('getDualWindowMode'));
    });

    test('写入被拒绝 → 回读真值不变（开关回退），并给提示', () async {
      overlay
        ..current = true
        ..accept = false;

      final DualWindowModeStatus s = await controller.setDualWindowMode(false);

      expect(s.dualWindowEnabled, isTrue, reason: '被拒绝时真值应保持原值');
      expect(controller.dualWindowModeState.dualWindowEnabled, isTrue);
      expect(controller.lastNotice, isNotNull);
      expect(controller.lastNotice, contains('未接受'));
    });

    test('写入抛错 → 异常上抛（由 UI 捕获回退），状态保持原值', () async {
      overlay
        ..current = true
        ..throwOnSet = true;

      await expectLater(
        controller.setDualWindowMode(false),
        throwsA(isA<OverlayPlatformException>()),
      );
      expect(controller.dualWindowModeState.dualWindowEnabled, isTrue);
    });
  });
}

/// 只实现双窗口开关相关成员的最小假实现（其余成员不会被调用）。
class _FakeDualWindowOverlay implements AndroidOverlayPet {
  bool current = true;
  bool accept = true;
  bool throwOnSet = false;

  final List<String> calls = <String>[];

  @override
  Future<DualWindowModeStatus> dualWindowMode() async {
    calls.add('getDualWindowMode');
    return DualWindowModeStatus(supported: true, dualWindowEnabled: current);
  }

  @override
  Future<bool> setDualWindowMode(bool enabled) async {
    calls.add('setDualWindowMode:$enabled');
    if (throwOnSet) {
      throw const OverlayPlatformException('rejected', '原生拒绝切换');
    }
    if (accept) current = enabled;
    return accept;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('未预期的调用：${invocation.memberName}');
}

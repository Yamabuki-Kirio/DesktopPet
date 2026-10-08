import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:petlife/platform/android/android_overlay_pet.dart';
import 'package:petlife/platform/overlay_pet.dart';

/// 双窗口探针只读诊断（Frozen contract）：
/// 模型解析 / 失败行判定 / 复制文本 / 通道协议。
///
/// 这一层是纯只读展示，硬约束只有一个：**原生返回什么都不能让界面崩**，
/// 缺键、类型不符、探针没跑都要退化成安全默认。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 一份"探针有效且一切正常"的完整原生返回。
  Map<String, Object?> healthyMap() => <String, Object?>{
        'probeValid': true,
        'productionWindowAttached': false,
        'probeWindowCount': 2,
        'expectedProbeWindowCount': 2,
        'totalKnownOverlayWindowCount': 3,
        'petAddCount': 2,
        'menuAddCount': 1,
        'petLastAddSequence': 1,
        'menuLastAddSequence': 3,
        'addSequence': 3,
        'currentExpectedTopWindow': 'menu',
        'actualVisualTop': 'menu',
        'menuWasReaddedAfterPet': false,
        'menuAttached': true,
        'menuTouchable': false,
        'menuAnchorPetRect': '100,200 120×120',
        'currentPetScreenRect': '100,200 120×120',
        'currentMenuWindowRect': '60,160 200×200',
        'anchorMatchesCurrentPet': true,
        'menuDirection': 'right',
        'verticalMode': false,
        'clampedByScreen': false,
        'lastWindowOperation': 'updateViewLayout(menu)',
        'lastTouchReceiver': 'menu-window',
        'orientation': 'landscape',
        'deviceModel': 'Pixel 7',
        'sdkInt': 34,
      };

  group('解析（宽容，不因坏数据崩溃）', () {
    test('完整 Map：全部键被逐字解析', () {
      final DualWindowProbeStatus s =
          DualWindowProbeStatus.fromMap(healthyMap());

      expect(s.supported, isTrue);
      expect(s.probeValid, isTrue);
      expect(s.productionWindowAttached, isFalse);
      expect(s.probeWindowCount, 2);
      expect(s.expectedProbeWindowCount, 2);
      expect(s.totalKnownOverlayWindowCount, 3);
      expect(s.petAddCount, 2);
      expect(s.menuAddCount, 1);
      expect(s.petLastAddSequence, 1);
      expect(s.menuLastAddSequence, 3);
      expect(s.addSequence, 3);
      expect(s.currentExpectedTopWindow, 'menu');
      expect(s.actualVisualTop, 'menu');
      expect(s.menuWasReaddedAfterPet, isFalse);
      expect(s.menuAttached, isTrue);
      expect(s.menuTouchable, isFalse);
      expect(s.menuAnchorPetRect, '100,200 120×120');
      expect(s.currentPetScreenRect, '100,200 120×120');
      expect(s.currentMenuWindowRect, '60,160 200×200');
      expect(s.anchorMatchesCurrentPet, isTrue);
      expect(s.menuDirection, 'right');
      expect(s.verticalMode, isFalse);
      expect(s.clampedByScreen, isFalse);
      expect(s.lastWindowOperation, 'updateViewLayout(menu)');
      expect(s.lastTouchReceiver, 'menu-window');
      expect(s.orientation, 'landscape');
      expect(s.deviceModel, 'Pixel 7');
      expect(s.sdkInt, 34);
    });

    test('缺键：退化为 false / 0 / null，不抛错', () {
      final DualWindowProbeStatus s =
          DualWindowProbeStatus.fromMap(<String, Object?>{});

      expect(s.probeValid, isFalse);
      expect(s.probeWindowCount, 0);
      expect(s.sdkInt, 0);
      expect(s.currentPetScreenRect, isNull);
      expect(s.deviceModel, isNull);
      // 探针没跑时（原生契约）也应能安全解析。
      expect(s.failureKeys, contains('probeValid'));
    });

    test('类型不符：非 bool / 非 num / 非字符串各自退化', () {
      final DualWindowProbeStatus s =
          DualWindowProbeStatus.fromMap(<String, Object?>{
        'probeValid': 'yes', // 非 bool → false
        'probeWindowCount': 'two', // 非 num → 0
        'sdkInt': 33.9, // num → toInt
        'menuDirection': 123, // 非字符串 → null
        'currentPetScreenRect': '', // 空串 → null
        'menuAttached': 1, // 非 bool → false
      });

      expect(s.probeValid, isFalse);
      expect(s.probeWindowCount, 0);
      expect(s.sdkInt, 33);
      expect(s.menuDirection, isNull);
      expect(s.currentPetScreenRect, isNull);
      expect(s.menuAttached, isFalse);
    });

    test('矩形为 none：原样保留（属于契约内的合法取值）', () {
      final DualWindowProbeStatus s =
          DualWindowProbeStatus.fromMap(<String, Object?>{
        'currentPetScreenRect': 'none',
        'menuAnchorPetRect': 'none',
        'currentMenuWindowRect': 'none',
      });

      expect(s.currentPetScreenRect, 'none');
      expect(s.menuAnchorPetRect, 'none');
      expect(s.currentMenuWindowRect, 'none');
    });
  });

  group('失败行判定（哪些行应高亮）', () {
    test('探针无效：probeValid 高亮；不因默认 false 误报锚点行', () {
      final DualWindowProbeStatus s =
          DualWindowProbeStatus.fromMap(<String, Object?>{'probeValid': false});

      expect(s.highlightsFailure('probeValid'), isTrue);
      // 探针没跑时 anchorMatchesCurrentPet 只是默认 false，不算失败。
      expect(s.highlightsFailure('anchorMatchesCurrentPet'), isFalse);
    });

    test('生产窗口被附着 → 高亮', () {
      final DualWindowProbeStatus s = DualWindowProbeStatus.fromMap(
        healthyMap()..['productionWindowAttached'] = true,
      );
      expect(s.highlightsFailure('productionWindowAttached'), isTrue);
    });

    test('菜单在桌宠之后被重新 add → 高亮', () {
      final DualWindowProbeStatus s = DualWindowProbeStatus.fromMap(
        healthyMap()..['menuWasReaddedAfterPet'] = true,
      );
      expect(s.highlightsFailure('menuWasReaddedAfterPet'), isTrue);
    });

    test('探针有效但锚点与桌宠矩形不一致 → 高亮', () {
      final DualWindowProbeStatus s = DualWindowProbeStatus.fromMap(
        healthyMap()..['anchorMatchesCurrentPet'] = false,
      );
      expect(s.highlightsFailure('anchorMatchesCurrentPet'), isTrue);

      final DualWindowProbeStatus ok =
          DualWindowProbeStatus.fromMap(healthyMap());
      expect(ok.highlightsFailure('anchorMatchesCurrentPet'), isFalse);
    });

    test('菜单未附着却仍可触摸（幽灵触摸窗）→ 高亮', () {
      final DualWindowProbeStatus ghost = DualWindowProbeStatus.fromMap(
        healthyMap()
          ..['menuAttached'] = false
          ..['menuTouchable'] = true,
      );
      expect(ghost.highlightsFailure('menuTouchable'), isTrue);

      final DualWindowProbeStatus open = DualWindowProbeStatus.fromMap(
        healthyMap()..['menuTouchable'] = true,
      );
      expect(open.highlightsFailure('menuTouchable'), isFalse);
    });

    test('健康快照没有任何高亮行', () {
      final DualWindowProbeStatus s =
          DualWindowProbeStatus.fromMap(healthyMap());
      expect(s.failureKeys, isEmpty);
    });
  });

  group('复制文本（稳定、可 grep）', () {
    test('每行一个 key=value，且包含全部冻结键、顺序固定', () {
      final DualWindowProbeStatus s =
          DualWindowProbeStatus.fromMap(healthyMap());
      final List<String> lines = s.toCopyText().split('\n');

      expect(lines.length, DualWindowProbeStatus.frozenKeys.length);
      expect(lines.length, 27);
      for (int i = 0; i < DualWindowProbeStatus.frozenKeys.length; i++) {
        final String key = DualWindowProbeStatus.frozenKeys[i];
        expect(lines[i].startsWith('$key='), isTrue,
            reason: '第 $i 行应以 $key= 开头，实际：${lines[i]}');
      }
      expect(s.toCopyText(), contains('probeValid=true'));
      expect(s.toCopyText(), contains('currentPetScreenRect=100,200 120×120'));
      expect(s.toCopyText(), contains('sdkInt=34'));
    });

    test('缺失的文本键在复制文本里写成 none（与原生契约口径一致）', () {
      final DualWindowProbeStatus s =
          DualWindowProbeStatus.fromMap(<String, Object?>{
        'probeValid': false,
        'sdkInt': 0,
      });
      final Map<String, String> parsed = <String, String>{
        for (final String line in s.toCopyText().split('\n'))
          line.split('=').first: line.substring(line.indexOf('=') + 1),
      };

      expect(parsed['probeValid'], 'false');
      expect(parsed['deviceModel'], 'none');
      expect(parsed['currentPetScreenRect'], 'none');
      expect(parsed['menuDirection'], 'none');
      // 每个冻结键都在复制文本里出现。
      for (final String key in DualWindowProbeStatus.frozenKeys) {
        expect(parsed.containsKey(key), isTrue, reason: '$key 必须出现在复制文本里');
      }
    });

    test('同样的状态复制出同样的文本（幂等）', () {
      final DualWindowProbeStatus s =
          DualWindowProbeStatus.fromMap(healthyMap());
      expect(s.toCopyText(), s.toCopyText());
    });
  });

  group('非 Android 平台', () {
    test('UnsupportedOverlayPet 返回"不支持"的安全默认，不抛错', () async {
      const UnsupportedOverlayPet overlay = UnsupportedOverlayPet();
      final DualWindowProbeStatus s = await overlay.dualWindowProbeStatus();

      expect(s.supported, isFalse);
      expect(s.probeValid, isFalse);
      // 即使不支持，复制文本仍然结构完整（全部冻结键都在）。
      expect(s.toCopyText().split('\n').length,
          DualWindowProbeStatus.frozenKeys.length);
    });
  });

  group('MethodChannel 协议', () {
    late List<MethodCall> calls;
    late MethodChannel channel;

    setUp(() {
      calls = <MethodCall>[];
      channel = const MethodChannel(androidOverlayChannelName);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        calls.add(call);
        return <String, Object?>{
          'probeValid': true,
          'productionWindowAttached': false,
          'probeWindowCount': 2,
          'expectedProbeWindowCount': 2,
          'totalKnownOverlayWindowCount': 3,
          'menuAttached': true,
          'anchorMatchesCurrentPet': true,
        };
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('通道名复用既有常量（不硬编码第二份）', () {
      expect(androidOverlayChannelName, 'asia.akechi.petlife/overlay');
    });

    test('dualWindowProbeStatus 走 getDualWindowProbeStatus 且不带参数', () async {
      final AndroidOverlayPetBridge bridge =
          AndroidOverlayPetBridge(channel: channel);

      final DualWindowProbeStatus s = await bridge.dualWindowProbeStatus();

      expect(calls.single.method, 'getDualWindowProbeStatus');
      expect(calls.single.arguments, isNull);
      expect(s.supported, isTrue);
      expect(s.probeValid, isTrue);
      expect(s.probeWindowCount, 2);
      expect(s.menuAttached, isTrue);
      // 原生没回的键退化为安全默认。
      expect(s.sdkInt, 0);
      expect(s.deviceModel, isNull);
    });

    test('原生返回非 Map 时抛 OverlayPlatformException（协议被破坏）', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async => 'oops');
      final AndroidOverlayPetBridge bridge =
          AndroidOverlayPetBridge(channel: channel);

      await expectLater(
        bridge.dualWindowProbeStatus(),
        throwsA(isA<OverlayPlatformException>()),
      );
    });
  });
}

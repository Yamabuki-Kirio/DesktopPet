import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:petlife/platform/android/android_overlay_pet.dart';
import 'package:petlife/platform/overlay_pet.dart';
import 'package:petlife/platform/windows/windows_platform_services.dart';

/// Phase 4C-1：悬浮桌宠的配置模型、状态解析与平台隔离。
///
/// 这一层是"送到原生之前"的最后一道闸：
/// 校验不过的配置**绝不允许**进入 MethodChannel，否则原生要么崩、要么
/// 在真机上出现"看不见但确实在跑"的窗口。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late String assetFile;

  setUp(() {
    root = Directory.systemTemp.createTempSync('petlife_overlay_test');
    final Directory characterDir = Directory(p.join(root.path, 'packA', 'Maya'))
      ..createSync(recursive: true);
    assetFile = File(p.join(characterDir.path, 'idle.png')).path;
    File(assetFile).writeAsBytesSync(<int>[0x89, 0x50, 0x4E, 0x47]);
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  OverlayPetConfig validConfig({
    String? characterId,
    String? assetId,
    String? filePath,
    String? mimeType,
    double scale = 1.0,
    int schemaVersion = 1,
  }) =>
      OverlayPetConfig(
        schemaVersion: schemaVersion,
        characterId: characterId ?? 'char-1',
        assetId: assetId ?? 'asset-1',
        filePath: filePath ?? assetFile,
        mimeType: mimeType ?? 'image/png',
        scale: scale,
      );

  group('配置模型', () {
    test('JSON 往返：字段逐一保持一致', () {
      final OverlayPetConfig config = OverlayPetConfig(
        characterId: 'char-1',
        assetId: 'asset-1',
        filePath: assetFile,
        mimeType: 'image/webp',
        isAnimated: true,
        frameCount: 12,
        animationDurationMs: 1200,
        scale: 1.5,
        snapEnabled: false,
        fixedAssetMode: true,
      );

      final OverlayPetConfig restored =
          OverlayPetConfig.fromJson(config.toJson());

      expect(restored.schemaVersion, 1);
      expect(restored.characterId, 'char-1');
      expect(restored.assetId, 'asset-1');
      expect(restored.filePath, assetFile);
      expect(restored.mimeType, 'image/webp');
      expect(restored.isAnimated, isTrue);
      expect(restored.frameCount, 12);
      expect(restored.animationDurationMs, 1200);
      expect(restored.scale, 1.5);
      expect(restored.snapEnabled, isFalse);
      expect(restored.fixedAssetMode, isTrue);
      expect(restored.toJson(), config.toJson());
    });

    test('缺字段直接报错，不猜默认值', () {
      expect(
        () => OverlayPetConfig.fromJson(<String, Object?>{
          'schemaVersion': 1,
          'assetId': 'a',
          'filePath': assetFile,
          'mimeType': 'image/png',
        }),
        throwsA(isA<OverlayConfigException>()),
      );
    });

    test('合法配置通过校验', () {
      expect(
        () => validConfig().validate(privateAssetsRoot: root.path),
        returnsNormally,
      );
    });
  });

  group('配置校验（送到原生之前的闸门）', () {
    test('空角色 ID / 空素材 ID 被拒绝', () {
      expect(
        () => validConfig(characterId: '  ').validate(privateAssetsRoot: root.path),
        throwsA(isA<OverlayConfigException>()
            .having((OverlayConfigException e) => e.code, 'code', 'empty_character_id')),
      );
      expect(
        () => validConfig(assetId: '').validate(privateAssetsRoot: root.path),
        throwsA(isA<OverlayConfigException>()
            .having((OverlayConfigException e) => e.code, 'code', 'empty_asset_id')),
      );
    });

    test('缩放超出 50%~200% 被拒绝', () {
      for (final double bad in <double>[0.49, 2.01, 0, -1]) {
        expect(
          () => validConfig(scale: bad).validate(privateAssetsRoot: root.path),
          throwsA(isA<OverlayConfigException>().having(
            (OverlayConfigException e) => e.code,
            'code',
            'scale_out_of_range',
          )),
          reason: 'scale=$bad 必须被拒绝',
        );
      }
      for (final double ok in <double>[0.5, 1.0, 2.0]) {
        expect(
          () => validConfig(scale: ok).validate(privateAssetsRoot: root.path),
          returnsNormally,
        );
      }
    });

    test('非应用私有路径被拒绝（含跨目录的合法路径）', () {
      final File outside = File(p.join(root.parent.path, 'outside.png'))
        ..writeAsBytesSync(<int>[1, 2, 3]);
      addTearDown(() {
        if (outside.existsSync()) outside.deleteSync();
      });

      expect(
        () => validConfig(filePath: outside.path).validate(privateAssetsRoot: root.path),
        throwsA(isA<OverlayConfigException>().having(
          (OverlayConfigException e) => e.code,
          'code',
          'outside_private_root',
        )),
      );
    });

    test('路径穿越（..）被拒绝', () {
      expect(
        () => validConfig(filePath: '${root.path}/packA/Maya/../../../etc/passwd')
            .validate(privateAssetsRoot: root.path),
        throwsA(isA<OverlayConfigException>().having(
          (OverlayConfigException e) => e.code,
          'code',
          'path_traversal',
        )),
      );
    });

    test('文件不存在被拒绝（不能让原生去加载一个空路径）', () {
      final String missing = p.join(root.path, 'packA', 'Maya', 'nope.png');
      expect(
        () => validConfig(filePath: missing).validate(privateAssetsRoot: root.path),
        throwsA(isA<OverlayConfigException>().having(
          (OverlayConfigException e) => e.code,
          'code',
          'file_missing',
        )),
      );
    });

    test('MIME 白名单之外的类型被拒绝', () {
      expect(
        () => validConfig(mimeType: 'image/svg+xml').validate(privateAssetsRoot: root.path),
        throwsA(isA<OverlayConfigException>().having(
          (OverlayConfigException e) => e.code,
          'code',
          'unsupported_mime',
        )),
      );
      for (final String ok in OverlayPetConfig.allowedMimeTypes) {
        expect(
          () => validConfig(mimeType: ok).validate(privateAssetsRoot: root.path),
          returnsNormally,
          reason: '$ok 应当被允许',
        );
      }
    });

    test('未知 schemaVersion 被拒绝', () {
      expect(
        () => validConfig(schemaVersion: 99).validate(privateAssetsRoot: root.path),
        throwsA(isA<OverlayConfigException>().having(
          (OverlayConfigException e) => e.code,
          'code',
          'unsupported_schema',
        )),
      );
    });

    test('外观设置的缩放与锚点同样受限', () {
      expect(
        () => const OverlayPetSettings(scale: 3.0).validate(),
        throwsA(isA<OverlayConfigException>()),
      );
      expect(
        () => const OverlayPetSettings(scale: 1.0, xRatio: 1.5).validate(),
        throwsA(isA<OverlayConfigException>()),
      );
      expect(
        () => const OverlayPetSettings(scale: 1.0, xRatio: 0.0, yRatio: 1.0)
            .validate(),
        returnsNormally,
      );
    });
  });

  group('状态解析', () {
    test('运行时状态映射正确，并能推出 已停止/运行中/已隐藏', () {
      final OverlayRuntimeState running = OverlayRuntimeState.fromMap(
        <String, Object?>{
          'supported': true,
          'serviceRunning': true,
          'windowAttached': true,
          'enabled': true,
          'hidden': false,
          'overlayGranted': true,
          'notificationsGranted': true,
          'characterId': 'char-1',
          'assetId': 'asset-1',
          'scale': 1.5,
          'frameCount': 8,
        },
      );
      expect(running.status, OverlayPetStatus.running);
      expect(running.characterId, 'char-1');
      expect(running.scale, 1.5);
      expect(running.frameCount, 8);
      expect(running.status.labelZh, '运行中');

      final OverlayRuntimeState hidden = OverlayRuntimeState.fromMap(
        <String, Object?>{'serviceRunning': true, 'hidden': true},
      );
      expect(hidden.status, OverlayPetStatus.hidden);
      expect(hidden.windowAttached, isFalse);

      final OverlayRuntimeState stopped =
          OverlayRuntimeState.fromMap(<String, Object?>{});
      expect(stopped.status, OverlayPetStatus.stopped);
      expect(stopped.scale, 1.0, reason: '缺字段用安全默认值');
    });

    test('授权状态解析（含"是否需要申请通知权限"）', () {
      final OverlayPermissionState state =
          OverlayPermissionState.fromMap(<String, Object?>{
        'supported': true,
        'overlayGranted': false,
        'notificationsGranted': true,
        'notificationsRequired': true,
      });
      expect(state.supported, isTrue);
      expect(state.overlayGranted, isFalse);
      expect(state.notificationsGranted, isTrue);
      expect(state.notificationsRequired, isTrue);
    });

    test('窗口诊断字段解析（服务在跑但窗口没挂上必须能看出来）', () {
      final OverlayRuntimeState state =
          OverlayRuntimeState.fromMap(<String, Object?>{
        'supported': true,
        'serviceRunning': true,
        'windowAttached': false,
        'hidden': false,
        'windowVisible': false,
        'viewWidth': 0,
        'viewHeight': 0,
        'imageViewWidth': 0,
        'imageViewHeight': 0,
        'lastWindowError': 'addView 失败：permission denied',
        'visual': 'empty',
      });
      expect(state.windowMissing, isTrue);
      expect(state.windowSummary, '未挂载');
      expect(state.lastWindowError, contains('permission denied'));
      expect(state.visual, 'empty');
      expect(state.debugOverlayMode, isFalse);

      final OverlayRuntimeState healthy =
          OverlayRuntimeState.fromMap(<String, Object?>{
        'supported': true,
        'serviceRunning': true,
        'windowAttached': true,
        'attachedToWindow': true,
        'windowVisible': true,
        'viewWidth': 240,
        'viewHeight': 240,
        'imageViewWidth': 240,
        'imageViewHeight': 240,
        'lastWindowAction': 'addView(ok)',
        'visual': 'asset',
      });
      expect(healthy.windowMissing, isFalse);
      expect(healthy.windowNotAttached, isFalse);
      expect(healthy.hasZeroSizedWindow, isFalse);
      expect(healthy.windowSummary, '已挂载 240×240');
      expect(healthy.lastWindowAction, 'addView(ok)');
    });

    test('诊断模式状态解析（洋红方块，不依赖素材）', () {
      final OverlayRuntimeState state =
          OverlayRuntimeState.fromMap(<String, Object?>{
        'supported': true,
        'serviceRunning': true,
        'windowAttached': true,
        'attachedToWindow': true,
        'viewWidth': 600,
        'viewHeight': 600,
        'visual': 'debug',
        'debugOverlayMode': true,
      });
      expect(state.debugOverlayMode, isTrue);
      expect(state.visual, 'debug');
      expect(state.windowSummary, '已挂载 600×600');
    });
  });

  group('非 Android 平台', () {
    test('UnsupportedOverlayPet 明确返回不支持，写操作抛错而不是假装成功', () async {
      const UnsupportedOverlayPet overlay = UnsupportedOverlayPet();

      expect(await overlay.isSupported(), isFalse);
      expect((await overlay.permissionState()).supported, isFalse);
      expect((await overlay.getState()).supported, isFalse);
      expect((await overlay.getState()).status, OverlayPetStatus.stopped);

      // 写操作必须是"明确的失败"，不能静默返回成功。
      await expectLater(overlay.start(), throwsA(isA<OverlayUnsupportedException>()));
      await expectLater(overlay.show(), throwsA(isA<OverlayUnsupportedException>()));
      await expectLater(overlay.hide(), throwsA(isA<OverlayUnsupportedException>()));
      await expectLater(overlay.stop(), throwsA(isA<OverlayUnsupportedException>()));
      await expectLater(
        overlay.updateSettings(const OverlayPetSettings(scale: 1.0)),
        throwsA(isA<OverlayUnsupportedException>()),
      );
      await expectLater(
        overlay.requestOverlayPermission(),
        throwsA(isA<OverlayUnsupportedException>()),
      );
    });

    test('Windows 平台不暴露悬浮窗能力，也不会加载 Android 实现', () async {
      final WindowsPlatformServices windows = WindowsPlatformServices();

      expect(windows.capabilities.supportsFloatingPet, isFalse);
      expect(windows.overlayPet, isA<UnsupportedOverlayPet>());
      expect(await windows.overlayPet.isSupported(), isFalse);
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
        switch (call.method) {
          case 'isSupported':
            return true;
          case 'getPermissionStatus':
          case 'requestOverlayPermission':
          case 'requestNotificationPermission':
            return <String, Object?>{
              'supported': true,
              'overlayGranted': true,
              'notificationsGranted': false,
              'notificationsRequired': true,
            };
          default:
            return <String, Object?>{
              'supported': true,
              'serviceRunning': true,
              'windowAttached': true,
              'enabled': true,
              'hidden': false,
              'overlayGranted': true,
              'notificationsGranted': false,
              'assetId': 'asset-1',
            };
        }
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('通道名与原生常量一致', () {
      expect(androidOverlayChannelName, 'asia.akechi.petlife/overlay');
    });

    test('start 会把配置原样下发（含文件路径与动画参数），并解析返回状态', () async {
      final AndroidOverlayPetBridge bridge = AndroidOverlayPetBridge(channel: channel);

      final OverlayRuntimeState state = await bridge.start(
        OverlayPetConfig(
          characterId: 'char-1',
          assetId: 'asset-1',
          filePath: assetFile,
          mimeType: 'image/webp',
          isAnimated: true,
          frameCount: 12,
          animationDurationMs: 900,
          scale: 1.25,
        ),
      );

      expect(calls.single.method, 'start');
      final Map<Object?, Object?> sent = calls.single.arguments as Map<Object?, Object?>;
      expect(sent['characterId'], 'char-1');
      expect(sent['assetId'], 'asset-1');
      expect(sent['filePath'], assetFile);
      expect(sent['mimeType'], 'image/webp');
      expect(sent['isAnimated'], isTrue);
      expect(sent['frameCount'], 12);
      expect(sent['animationDurationMs'], 900);
      expect(sent['scale'], 1.25);

      expect(state.status, OverlayPetStatus.running);
      expect(state.serviceRunning, isTrue);
      expect(state.assetId, 'asset-1');
    });

    test('start 不带配置时不下发参数（用原生已保存的配置显示占位图）', () async {
      final AndroidOverlayPetBridge bridge = AndroidOverlayPetBridge(channel: channel);
      await bridge.start();
      expect(calls.single.method, 'start');
      expect(calls.single.arguments, isNull);
    });

    test('show / hide / stop / updateSettings 走各自的方法名', () async {
      final AndroidOverlayPetBridge bridge = AndroidOverlayPetBridge(channel: channel);

      await bridge.show();
      await bridge.hide();
      await bridge.stop();
      await bridge.updateSettings(
        const OverlayPetSettings(
          scale: 1.5,
          touchThrough: true,
          snapEnabled: false,
          hideOnLockScreen: true,
          xRatio: 0.0,
        ),
      );

      expect(
        calls.map((MethodCall c) => c.method).toList(),
        <String>['show', 'hide', 'stop', 'updateSettings'],
      );
      final Map<Object?, Object?> settings =
          calls.last.arguments as Map<Object?, Object?>;
      expect(settings['scale'], 1.5);
      expect(settings['touchThrough'], isTrue);
      expect(settings['snapEnabled'], isFalse);
      expect(settings['xRatio'], 0.0);
      expect(settings.containsKey('yRatio'), isFalse,
          reason: '没有指定 yRatio 时不下发，避免原生把位置重置');
    });

    test('大小与吸附参数按原生约定的字段名下发', () async {
      final AndroidOverlayPetBridge bridge = AndroidOverlayPetBridge(channel: channel);
      await bridge.updateSettings(
        const OverlayPetSettings(
          scale: 1.5,
          snapEnabled: true,
          xRatio: 0.25,
          yRatio: 0.75,
        ),
      );

      final Map<Object?, Object?> sent =
          calls.last.arguments as Map<Object?, Object?>;
      expect(sent['scale'], 1.5);
      expect(sent['snapEnabled'], isTrue);
      expect(sent['xRatio'], 0.25);
      expect(sent['yRatio'], 0.75);
    });

    test('原生未注册通道时抛 OverlayUnsupportedException（而不是崩溃）', () async {
      final AndroidOverlayPetBridge bridge = AndroidOverlayPetBridge(
        channel: const MethodChannel('asia.akechi.petlife/overlay.missing'),
      );
      expect(
        () => bridge.isSupported(),
        throwsA(isA<OverlayUnsupportedException>()),
      );
    });
  });

  group('大小与位置（4C-3A）', () {
    test('滑块区间与步长：50% ~ 200%，步长 10%，共 15 档', () {
      expect(OverlayPetConfig.minScale, 0.5);
      expect(OverlayPetConfig.maxScale, 2.0);
      expect(OverlayPetConfig.scaleStep, 0.1);
      expect(OverlayPetConfig.defaultScale, 1.0);

      final int divisions =
          ((OverlayPetConfig.maxScale - OverlayPetConfig.minScale) /
                  OverlayPetConfig.scaleStep)
              .round();
      expect(divisions, 15);
      // 每一档都落在区间内，且百分比都是 10 的整数倍
      for (int i = 0; i <= divisions; i++) {
        final double v =
            OverlayPetConfig.minScale + i * OverlayPetConfig.scaleStep;
        expect(v, greaterThanOrEqualTo(OverlayPetConfig.minScale));
        expect(v, lessThanOrEqualTo(OverlayPetConfig.maxScale));
        expect((v * 100).round() % 10, 0);
      }
    });

    test('百分比显示与滑块位置映射', () {
      expect(OverlayRuntimeState.fromMap(<String, Object?>{'scale': 0.5}).scalePercent, 50);
      expect(OverlayRuntimeState.fromMap(<String, Object?>{'scale': 1.0}).scalePercent, 100);
      expect(OverlayRuntimeState.fromMap(<String, Object?>{'scale': 2.0}).scalePercent, 200);
      expect(OverlayRuntimeState.fromMap(<String, Object?>{'scale': 1.0}).scaleSliderValue,
          closeTo(1 / 3, 0.0001));
      expect(OverlayRuntimeState.fromMap(<String, Object?>{'scale': 0.5}).scaleSliderValue, 0.0);
      expect(OverlayRuntimeState.fromMap(<String, Object?>{'scale': 2.0}).scaleSliderValue, 1.0);
      // 原生给了非法类型也不能让界面崩：解析层退回默认值
      expect(OverlayRuntimeState.fromMap(<String, Object?>{'scale': 'bad'}).scalePercent, 100);
    });

    test('原生回报的位置/尺寸/手势字段被正确解析', () {
      final OverlayRuntimeState state = OverlayRuntimeState.fromMap(<String, Object?>{
        'snapEnabled': false,
        'snapEdge': 'right',
        'snapOrientation': 'landscape',
        'xRatio': 0.25,
        'yRatio': 0.75,
        'petWidth': 320,
        'petHeight': 160,
        'gestureState': 'DRAGGING',
      });
      expect(state.snapEnabled, isFalse);
      expect(state.snapEdge, 'right');
      expect(state.snapEdgeLabelZh, '右');
      expect(state.snapOrientation, 'landscape');
      expect(state.xRatio, 0.25);
      expect(state.yRatio, 0.75);
      expect(state.petWidth, 320);
      expect(state.petHeight, 160);
      expect(state.gestureState, 'DRAGGING');
    });

    test('缺字段时给出安全默认值（旧版原生不回报也不能崩）', () {
      final OverlayRuntimeState state = OverlayRuntimeState.fromMap(<String, Object?>{});
      expect(state.snapEnabled, isTrue, reason: '自动吸附默认开启');
      expect(state.snapEdge, 'none');
      expect(state.snapEdgeLabelZh, '无');
      expect(state.gestureState, 'IDLE');
      expect(state.petWidth, 0);
      expect(state.petHeight, 0);
    });

    test('未知的吸附边不会渲染成奇怪文案', () {
      expect(
        OverlayRuntimeState.fromMap(<String, Object?>{'snapEdge': 'diagonal'}).snapEdgeLabelZh,
        '无',
      );
    });
  });

  group('圆盘菜单（4C-3B）', () {
    test('菜单状态、按钮数量与最近动作被正确解析', () {
      final OverlayRuntimeState state = OverlayRuntimeState.fromMap(<String, Object?>{
        'menuState': 'open',
        'menuButtonCount': 6,
        'lastMenuAction': 'slot_1 → 功能尚未配置',
      });
      expect(state.menuState, 'open');
      expect(state.menuStateLabelZh, '已展开');
      expect(state.menuButtonCount, 6);
      expect(state.menuOccupiesWindow, isTrue);
      expect(state.lastMenuAction, contains('功能尚未配置'));
    });

    test('缺字段时默认"已关闭"，且不占用窗口', () {
      final OverlayRuntimeState state = OverlayRuntimeState.fromMap(<String, Object?>{});
      expect(state.menuState, 'closed');
      expect(state.menuStateLabelZh, '已关闭');
      expect(state.menuOccupiesWindow, isFalse);
      expect(state.menuButtonCount, 0);
      expect(state.lastMenuAction, isNull);
    });

    test('四种菜单状态都有中文标签，未知值退化为"已关闭"', () {
      const Map<String, String> expected = <String, String>{
        'opening': '展开中',
        'open': '已展开',
        'closing': '收起中',
        'closed': '已关闭',
        'bogus': '已关闭',
      };
      expected.forEach((String raw, String label) {
        expect(
          OverlayRuntimeState.fromMap(<String, Object?>{'menuState': raw}).menuStateLabelZh,
          label,
        );
      });
    });

    test('关闭态不占用窗口（透明区域只在菜单打开期间存在）', () {
      for (final String open in <String>['opening', 'open', 'closing']) {
        expect(
          OverlayRuntimeState.fromMap(<String, Object?>{'menuState': open}).menuOccupiesWindow,
          isTrue,
        );
      }
      expect(
        OverlayRuntimeState.fromMap(<String, Object?>{'menuState': 'closed'}).menuOccupiesWindow,
        isFalse,
      );
    });
  });

  group('视觉与动画（4C-4）', () {
    test('visualType / animationFrameMode / animationSupported / animationPlaying 被正确解析', () {
      final OverlayRuntimeState state = OverlayRuntimeState.fromMap(<String, Object?>{
        'visualType': 'animated',
        'animationFrameMode': 'full-animation',
        'animationSupported': true,
        'animationPlaying': true,
      });
      expect(state.visualType, 'animated');
      expect(state.animationFrameMode, 'full-animation');
      expect(state.animationSupported, isTrue);
      expect(state.animationPlaying, isTrue);
      expect(state.animatedFirstFrameOnly, isFalse);
    });

    test('animationPausedReason 与 decodeCode 被解析（只读诊断字段）', () {
      final OverlayRuntimeState state = OverlayRuntimeState.fromMap(<String, Object?>{
        'visualType': 'animated',
        'animationFrameMode': 'full-animation',
        'animationPlaying': false,
        'animationPausedReason': 'screen-off',
        'decodeCode': 'decode_failed',
      });
      expect(state.animationPausedReason, 'screen-off');
      expect(state.decodeCode, 'decode_failed');
    });

    test('缺字段时给出安全默认（旧版原生不回报也不能崩）', () {
      final OverlayRuntimeState state = OverlayRuntimeState.fromMap(<String, Object?>{});
      expect(state.visualType, 'placeholder');
      expect(state.animationFrameMode, 'not-applicable');
      expect(state.animationSupported, isFalse);
      expect(state.animationPlaying, isFalse);
      expect(state.animationPausedReason, isNull);
      expect(state.decodeCode, isNull);
      expect(state.animatedFirstFrameOnly, isFalse);
    });

    test('视觉类型中文标签（未知值退化为占位）', () {
      const Map<String, String> expected = <String, String>{
        'animated': '动态 WebP',
        'static': '静态图片',
        'placeholder': '占位（无可显示素材）',
        'bogus': '占位（无可显示素材）',
      };
      expected.forEach((String raw, String label) {
        expect(
          OverlayRuntimeState.fromMap(<String, Object?>{'visualType': raw}).visualTypeLabelZh,
          label,
        );
      });
    });

    test('低版本第一帧回退：animatedFirstFrameOnly 为真且文案如实说明', () {
      final OverlayRuntimeState state = OverlayRuntimeState.fromMap(<String, Object?>{
        'visualType': 'animated',
        'animationFrameMode': 'first-frame-fallback',
        'animationSupported': false,
        'animationPlaying': false,
      });
      expect(state.animatedFirstFrameOnly, isTrue);
      expect(state.animationStateLabelZh, OverlayRuntimeState.animatedFirstFrameFallbackText);
      expect(state.showsAnimationHint, isTrue);
    });

    test('API 28+ 完整动画：文案为"动态素材正在播放"', () {
      final OverlayRuntimeState state = OverlayRuntimeState.fromMap(<String, Object?>{
        'visualType': 'animated',
        'animationFrameMode': 'full-animation',
        'animationSupported': true,
        'animationPlaying': true,
      });
      expect(state.animationStateLabelZh, OverlayRuntimeState.animatedPlayingText);
    });

    test('解码失败优先显示"素材加载失败"，不被动态文案覆盖', () {
      final OverlayRuntimeState state = OverlayRuntimeState.fromMap(<String, Object?>{
        'visualType': 'animated',
        'animationFrameMode': 'full-animation',
        'animationSupported': true,
        'animationPlaying': false,
        'decodeCode': 'decode_failed',
      });
      expect(state.animationStateLabelZh, '素材加载失败');
    });

    test('静态素材不显示动态提示', () {
      final OverlayRuntimeState state = OverlayRuntimeState.fromMap(<String, Object?>{
        'visualType': 'static',
        'animationFrameMode': 'not-applicable',
        'animationSupported': true,
      });
      expect(state.animationStateLabelZh, '静态素材（无需播放）');
      expect(state.showsAnimationHint, isFalse);
    });

    test('4C-4 字段不影响原有大小 / 位置 / 菜单状态', () {
      final OverlayRuntimeState state = OverlayRuntimeState.fromMap(<String, Object?>{
        'visualType': 'animated',
        'animationFrameMode': 'full-animation',
        'scale': 1.5,
        'xRatio': 0.25,
        'yRatio': 0.75,
        'menuState': 'open',
      });
      expect(state.scalePercent, 150);
      expect(state.xRatio, 0.25);
      expect(state.yRatio, 0.75);
      expect(state.menuState, 'open');
    });
  });

  group('状态联动（4C-5）', () {
    test('状态诊断字段被正确解析', () {
      final OverlayStateDiagnostics d =
          OverlayStateDiagnostics.fromMap(<String, Object?>{
        'stateId': 'social',
        'stateLabel': '社交',
        'stateSource': 'foreground-app',
        'stateReason': '前台应用「Telegram」分类为「社交」',
        'foregroundPackage': 'org.telegram.messenger',
        'foregroundLabel': 'Telegram',
        'category': 'social',
        'categorySource': 'built-in-rule',
        'candidateState': 'gaming',
        'candidateCount': 1,
        'manualOverride': null,
        'usageAccessGranted': true,
        'monitorRunning': true,
        'mappingRevision': 12,
        'stateAssetId': 'asset-social',
        'fallbackLevel': 1,
        'lastChangedAt': 1700000000000,
        'stateErrorCode': null,
      });
      expect(d.stateId, 'social');
      expect(d.stateLabel, '社交');
      expect(d.stateSource, 'foreground-app');
      expect(d.sourceLabelZh, '前台应用');
      expect(d.foregroundPackage, 'org.telegram.messenger');
      expect(d.foregroundAppLabel, 'Telegram');
      expect(d.category, 'social');
      expect(d.candidateState, 'gaming');
      expect(d.candidateCount, 1);
      expect(d.mappingRevision, 12);
      expect(d.stateAssetId, 'asset-social');
      expect(d.fallbackLevel, 1);
      expect(d.lastChangedAt, isNotNull);
    });

    test('前台应用拿不到标签时退回显示包名', () {
      final OverlayStateDiagnostics d =
          OverlayStateDiagnostics.fromMap(<String, Object?>{
        'foregroundPackage': 'com.example.app',
        'foregroundLabel': null,
      });
      expect(d.foregroundAppLabel, 'com.example.app');
    });

    test('缺字段时给出安全默认（旧版原生不回报也不能崩）', () {
      final OverlayStateDiagnostics d =
          OverlayStateDiagnostics.fromMap(<String, Object?>{});
      expect(d.stateId, 'default');
      expect(d.stateSource, 'unsupported');
      expect(d.sourceLabelZh, '不可用');
      expect(d.mappingRevision, 0);
      expect(d.fallbackLevel, 0);
      expect(d.usageAccessGranted, isFalse);
      expect(d.monitorRunning, isFalse);
      expect(d.lastChangedAt, isNull);
    });

    test('未授权时"自动联动"为不可用，并给出原因文案', () {
      final OverlayStateDiagnostics d =
          OverlayStateDiagnostics.fromMap(<String, Object?>{
        'usageAccessGranted': false,
        'monitorRunning': true,
        'stateSource': 'unsupported',
      });
      expect(d.linkageLabelZh, '不可用');
      expect(d.linkageHintZh, contains('未授予使用情况访问权限'));
    });

    test('已授权且监听运行中时"自动联动"为运行中，且没有原因文案', () {
      final OverlayStateDiagnostics d =
          OverlayStateDiagnostics.fromMap(<String, Object?>{
        'usageAccessGranted': true,
        'monitorRunning': true,
      });
      expect(d.linkageLabelZh, '运行中');
      expect(d.linkageHintZh, isNull);
    });

    test('已授权但监听未运行时"自动联动"为未运行', () {
      final OverlayStateDiagnostics d =
          OverlayStateDiagnostics.fromMap(<String, Object?>{
        'usageAccessGranted': true,
        'monitorRunning': false,
      });
      expect(d.linkageLabelZh, '未运行');
    });

    test('手动覆盖时来源显示"手动覆盖"，并保留覆盖的状态 ID', () {
      final OverlayStateDiagnostics d =
          OverlayStateDiagnostics.fromMap(<String, Object?>{
        'stateId': 'concerned',
        'stateSource': 'manual-debug',
        'manualOverride': 'concerned',
      });
      expect(d.manualOverride, 'concerned');
      expect(d.sourceLabelZh, '手动覆盖');
    });

    test('四种来源都有中文标签，未知值退化为默认', () {
      const Map<String, String> expected = <String, String>{
        'manual-debug': '手动覆盖',
        'foreground-app': '前台应用',
        'idle': '空闲判断',
        'screen-off': '屏幕关闭',
        'unsupported': '不可用',
        'bogus': '默认',
      };
      expected.forEach((String raw, String label) {
        expect(
          OverlayStateDiagnostics.fromMap(<String, Object?>{'stateSource': raw})
              .sourceLabelZh,
          label,
        );
      });
    });

    test('回退级别只有第 2 级以上才提示（第 1 级为正常命中）', () {
      expect(
        OverlayStateDiagnostics.fromMap(<String, Object?>{'fallbackLevel': 1})
            .fallbackLabelZh,
        isNull,
      );
      expect(
        OverlayStateDiagnostics.fromMap(<String, Object?>{'fallbackLevel': 2})
            .fallbackLabelZh,
        contains('角色默认素材'),
      );
      expect(
        OverlayStateDiagnostics.fromMap(<String, Object?>{'fallbackLevel': 4})
            .fallbackLabelZh,
        contains('占位'),
      );
    });

    test('非 Android 平台安全降级：返回不可用而不是抛错', () async {
      const UnsupportedOverlayPet overlay = UnsupportedOverlayPet();
      final OverlayStateDiagnostics d = await overlay.stateDiagnostics();
      expect(d.usageAccessGranted, isFalse);
      expect(d.monitorRunning, isFalse);
      expect(d.stateId, 'default');
    });

    test('原有动画 / 菜单 / 大小字段不退化', () {
      final OverlayRuntimeState state = OverlayRuntimeState.fromMap(<String, Object?>{
        'visualType': 'animated',
        'animationPlaying': true,
        'menuState': 'open',
        'scale': 2.0,
        'petWidth': 320,
        'petHeight': 160,
      });
      expect(state.visualType, 'animated');
      expect(state.animationPlaying, isTrue);
      expect(state.menuState, 'open');
      expect(state.scalePercent, 200);
      expect(state.petWidth, 320);
      expect(state.petHeight, 160);
    });

    // --- 真机缺陷 C：前台应用识别的诊断解析 ---

    test('前台识别诊断被正确解析（检测来源 / 计数 / 最后原始包名）', () {
      final OverlayStateDiagnostics d =
          OverlayStateDiagnostics.fromMap(<String, Object?>{
        'foregroundDetectionSource': 'activity-events',
        'foregroundDetectionReason': null,
        'foregroundEventCount': 7,
        'foregroundResumedEventCount': 3,
        'foregroundUsableEventCount': 1,
        'foregroundStatsCount': 0,
        'foregroundLastRawPackage': 'asia.akechi.petlife',
        'foregroundAppOpsAllowed': true,
      });
      expect(d.detectionSource, 'activity-events');
      expect(d.detectionSourceLabelZh, '前台事件');
      expect(d.detectionReasonZh, isNull);
      expect(d.eventCount, 7);
      expect(d.resumedEventCount, 3);
      expect(d.usableEventCount, 1);
      expect(d.lastRawPackage, 'asia.akechi.petlife');
      expect(d.appOpsAllowed, isTrue);
      expect(d.eventSummaryZh, '7 / 3 / 1（统计 0）');
    });

    test('缺字段时前台识别诊断退回安全默认（旧版原生不回报也不能崩）', () {
      final OverlayStateDiagnostics d =
          OverlayStateDiagnostics.fromMap(<String, Object?>{});
      expect(d.detectionSource, 'unavailable');
      expect(d.detectionSourceLabelZh, '不可用');
      expect(d.detectionReasonZh, isNull);
      expect(d.eventCount, 0);
      expect(d.statsCount, 0);
      expect(d.lastRawPackage, isNull);
      expect(d.appOpsAllowed, isFalse);
    });

    test('四种检测来源都有中文名，未知值退化为不可用', () {
      const Map<String, String> expected = <String, String>{
        'activity-events': '前台事件',
        'usage-stats-fallback': '使用统计兜底',
        'cache': '最近有效外部应用',
        'unavailable': '不可用',
        'bogus': '不可用',
      };
      expected.forEach((String raw, String label) {
        expect(
          OverlayStateDiagnostics.fromMap(
            <String, Object?>{'foregroundDetectionSource': raw},
          ).detectionSourceLabelZh,
          label,
        );
      });
    });

    test('每个失败原因都有可读中文，未知原因原样显示', () {
      const Map<String, String> expected = <String, String>{
        'no-event-in-window': '查询窗口内没有前台事件',
        'last-event-is-self': '最后一条事件是 PetLife 自己（分屏或返回设置页）',
        'last-event-is-system-noise': '最后一条事件是系统界面或输入法',
        'no-usable-external-event': '窗口内没有可用的外部应用事件',
        'cache-expired': '最近有效外部应用已过期',
        'usage_access_missing': '未授予使用情况访问权限',
      };
      expected.forEach((String raw, String label) {
        expect(
          OverlayStateDiagnostics.fromMap(
            <String, Object?>{'foregroundDetectionReason': raw},
          ).detectionReasonZh,
          label,
        );
      });
      expect(
        OverlayStateDiagnostics.fromMap(
          <String, Object?>{'foregroundDetectionReason': 'something-new'},
        ).detectionReasonZh,
        'something-new',
      );
    });

    test('统计兜底来源的说明不伪装成精确事件', () {
      final OverlayStateDiagnostics d =
          OverlayStateDiagnostics.fromMap(<String, Object?>{
        'foregroundDetectionSource': 'usage-stats-fallback',
        'foregroundDetectionReason': 'usage-stats-fallback',
      });
      expect(d.detectionSourceLabelZh, '使用统计兜底');
      expect(d.detectionReasonZh, contains('不是精确事件'));
    });
  });

  group('Phase 4C-6A 真机诊断：状态提交链路的原生真值', () {
    test('17 项诊断字段被完整解析（设置页按这些字段名显示）', () {
      final OverlayStateDiagnostics d =
          OverlayStateDiagnostics.fromMap(<String, Object?>{
        'automaticStateEnabled': true,
        'collectorRunning': true,
        'foregroundPackage': 'com.android.chrome',
        'foregroundLabel': 'Chrome',
        'category': 'browser',
        'foregroundDetectionSource': 'activity-events',
        'resolvedTargetState': 'focused',
        'candidateState': 'focused',
        'candidateCount': 2,
        'candidateSince': 1700000001000,
        'candidateElapsedMs': 1100,
        'stableState': 'focused',
        'matchedRule': 'built-in',
        'mappingRevision': 12,
        'mappingReceivedAt': 1700000000000,
        'manualOverride': null,
        'lastTransitionResult': 'committed',
        'lastTransitionReason': '候选稳定 1100ms，状态从 default 提交为 focused',
        'lastCommittedAt': 1700000002100,
        'categoryDetail': 'exact:com.android.chrome',
        'platformAppCategory': -1,
      });

      expect(d.automaticStateEnabled, isTrue);
      expect(d.collectorRunning, isTrue);
      expect(d.foregroundPackage, 'com.android.chrome');
      expect(d.foregroundLabel, 'Chrome');
      expect(d.category, 'browser');
      expect(d.detectionSource, 'activity-events');
      expect(d.resolvedTargetState, 'focused');
      expect(d.candidateState, 'focused');
      expect(d.candidateCount, 2);
      expect(d.candidateElapsedMs, 1100);
      expect(d.stableState, 'focused');
      expect(d.matchedRule, 'built-in');
      expect(d.mappingRevision, 12);
      expect(d.manualOverride, isNull);
      expect(d.lastTransitionResult, 'committed');
      expect(d.transitionResultZh, contains('已提交'));
      expect(d.categoryDetail, 'exact:com.android.chrome');
      expect(d.platformAppCategory, -1);
      expect(d.candidateSince, isNotNull);
      expect(d.mappingReceivedAt, isNotNull);
      expect(d.lastCommittedAt, isNotNull);
    });

    test('缺字段时安全默认（stableState 退回 stateId，时间字段为 null）', () {
      final OverlayStateDiagnostics d =
          OverlayStateDiagnostics.fromMap(<String, Object?>{});
      expect(d.collectorRunning, isFalse);
      expect(d.resolvedTargetState, isNull);
      // 原生没回报 stableState 时，界面口径等同 stateId。
      expect(d.stableState, isNull);
      expect(d.stableStateId, 'default');
      expect(d.candidateSince, isNull);
      expect(d.candidateElapsedMs, 0);
      expect(d.mappingReceivedAt, isNull);
      expect(d.lastTransitionResult, isNull);
      expect(d.lastTransitionReason, isNull);
      expect(d.lastCommittedAt, isNull);
      expect(d.categoryDetail, isNull);
      expect(d.platformAppCategory, isNull);
    });

    test('时间戳为 0 / 负数时不显示 1970 年', () {
      final OverlayStateDiagnostics d =
          OverlayStateDiagnostics.fromMap(<String, Object?>{
        'candidateSince': 0,
        'mappingReceivedAt': 0,
        'lastCommittedAt': 0,
      });
      expect(d.candidateSince, isNull);
      expect(d.mappingReceivedAt, isNull);
      expect(d.lastCommittedAt, isNull);
    });

    test('每种提交结果都有可读中文说明，未知值原样显示', () {
      const Map<String, String> expected = <String, String>{
        'committed': '已提交（stableState 已更新）',
        'candidate': '候选中（还在等稳定）',
        'suppressed': '已稳定，但在快速切换抑制窗口内',
        'unchanged': '目标与当前状态相同',
        'hold': '系统界面：保持上一个稳定状态',
        'manual': '手动覆盖生效',
        'disabled': '自动联动已关闭',
        'unavailable': '权限或前台数据不可用',
      };
      expected.forEach((String raw, String label) {
        expect(
          OverlayStateDiagnostics.fromMap(
            <String, Object?>{'lastTransitionResult': raw},
          ).transitionResultZh,
          label,
        );
      });
      expect(
        OverlayStateDiagnostics.fromMap(
          <String, Object?>{'lastTransitionResult': 'something-new'},
        ).transitionResultZh,
        'something-new',
      );
    });

    test('非 Android 平台的安全默认也带齐新字段（不抛错）', () async {
      const UnsupportedOverlayPet overlay = UnsupportedOverlayPet();
      final OverlayStateDiagnostics d = await overlay.stateDiagnostics();
      expect(d.resolvedTargetState, isNull);
      expect(d.stableStateId, 'default');
      expect(d.collectorRunning, isFalse);
    });
  });

  group('轮盘与按钮大小范围（4C-6B-1.2 A3）', () {
    test('范围 50%~250%、步进 10%、默认值固定', () {
      const OverlayWheelLayoutSettings s = OverlayWheelLayoutSettings.unsupported;
      expect(s.minScale, 0.50);
      expect(s.maxScale, 2.50);
      expect(s.step, 0.10);
      expect(s.defaultScale, 1.00);
      expect(s.minButtonScale, 0.50);
      expect(s.maxButtonScale, 2.50);
      expect(s.defaultButtonScale, 1.30);
    });

    test('缺字段时取默认值（轮盘 100% / 按钮 130%）', () {
      final OverlayWheelLayoutSettings s =
          OverlayWheelLayoutSettings.fromMap(<String, Object?>{});
      expect(s.preferredScale, 1.00);
      expect(s.buttonVisualScale, 1.30);
      expect(s.minScale, 0.50);
      expect(s.maxScale, 2.50);
      expect(s.minButtonScale, 0.50);
      expect(s.maxButtonScale, 2.50);
      expect(s.step, 0.10);
      expect(s.defaultScale, 1.00);
      expect(s.defaultButtonScale, 1.30);
    });

    test('越界值被夹到 50%~250%', () {
      final OverlayWheelLayoutSettings low =
          OverlayWheelLayoutSettings.fromMap(<String, Object?>{
        'preferredScale': 0.01,
        'buttonVisualScale': 0.01,
      });
      expect(low.preferredScale, 0.50);
      expect(low.buttonVisualScale, 0.50);

      final OverlayWheelLayoutSettings high =
          OverlayWheelLayoutSettings.fromMap(<String, Object?>{
        'preferredScale': 9.0,
        'buttonVisualScale': 9.0,
      });
      expect(high.preferredScale, 2.50);
      expect(high.buttonVisualScale, 2.50);
    });

    test('百分比文案覆盖 50%~250% 两端', () {
      expect(
        OverlayWheelLayoutSettings.fromMap(
          <String, Object?>{'preferredScale': 0.5},
        ).scalePercent,
        50,
      );
      expect(
        OverlayWheelLayoutSettings.fromMap(
          <String, Object?>{'preferredScale': 1.3},
        ).scalePercent,
        130,
      );
      expect(
        OverlayWheelLayoutSettings.fromMap(
          <String, Object?>{'preferredScale': 2.5},
        ).scalePercent,
        250,
      );
    });
  });
}

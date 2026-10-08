import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:petlife/asset_decoder/asset_decoder.dart';
import 'package:petlife/asset_decoder/decoded_animation.dart';
import 'package:petlife/character/models/emotion_asset.dart';
import 'package:petlife/character/models/enums.dart';
import 'package:petlife/character/pet_renderer.dart';
import 'package:petlife/core/result.dart';
import 'package:petlife/state_engine/state_debouncer.dart';
import 'package:petlife/state_engine/system_state.dart';
import 'package:petlife/ui/pages/state_debugger_page.dart';
import 'package:petlife/ui/pet/pet_frame_controller.dart';
import 'package:petlife/ui/pet/pet_view.dart';

import 'filename_parser_test.dart' show locateAceAttorneyFolder;

/// 1×1 红色 PNG（base64），作为测试用的静态图片。
const String kTinyPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

/// 轮询等待条件成立，超时则失败。用于等待真实帧定时器推进，避免依赖具体帧时长。
Future<void> waitUntil(
  bool Function() cond, {
  Duration timeout = const Duration(seconds: 10),
  String? reason,
}) async {
  final Stopwatch sw = Stopwatch()..start();
  while (!cond()) {
    if (sw.elapsed > timeout) {
      fail('等待超时（>${timeout.inMilliseconds}ms）：${reason ?? '条件未满足'}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 40));
  }
}

/// 可控解码器：直接返回测试预先创建的 [DecodedAnimation]，便于持有对象引用断言资源释放。
class _FakeDecoder implements AssetDecoder {
  _FakeDecoder(this.animations);

  final Map<String, DecodedAnimation> animations;

  @override
  Future<Result<DecodedAnimation>> load({
    required String assetId,
    required File file,
    int containerDurationMs = 0,
  }) async {
    final DecodedAnimation? a = animations[assetId];
    if (a == null) {
      return Err<DecodedAnimation>(Failure(FailureKind.undecodable, 'fake: 未知素材 $assetId'));
    }
    return Ok<DecodedAnimation>(a);
  }

  @override
  Future<Result<DecodeVerification>> verifyDecodable(File file) async =>
      const Ok<DecodeVerification>(
          DecodeVerification(decoderFrameCount: 1, width: 1, height: 1, firstFrameDurationMs: 0));

  @override
  Future<Result<ui.Image>> loadStaticImage({
    required String assetId,
    required File file,
  }) async =>
      Err<ui.Image>(Failure(FailureKind.undecodable, 'fake: 本测试走 load 路径'));

  @override
  Future<void> evict(String assetId) async {}

  @override
  Future<void> clear() async {}

  @override
  int get cachedFileBytes => 0;

  @override
  int get cachedFileEntries => 0;

  @override
  int get cachedImageBytes => 0;

  @override
  int get cachedImageEntries => 0;
}

EmotionAsset asset({
  required String id,
  required String path,
  int frames = 1,
  bool animated = false,
}) =>
    EmotionAsset(
      id: id,
      characterId: 'c1',
      emotionName: id,
      variantName: 'default',
      filePath: path,
      originalFilePath: path,
      fileHash: 'hash-$id',
      mimeType: animated ? 'image/webp' : 'image/png',
      fileSize: 100,
      width: 256,
      height: 192,
      frameCount: frames,
      isAnimated: animated,
      hasAlpha: true,
      enabled: true,
      validationStatus: ValidationStatus.valid,
      createdAt: DateTime(2026, 1, 1),
      animationDurationMs: animated ? 5000 : 0,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('动态 WebP 渲染与重绘（缺陷：动态素材显示但不动）', () {
    final Directory? folder = locateAceAttorneyFolder();

    File animatedFile(String name) => File(p.join(folder!.path, name));

    test('动态素材加载后 frameIndex 随时间变化', () async {
      if (folder == null) {
        markTestSkipped('未找到 Ace Attorney 素材目录');
        return;
      }
      final File file = animatedFile('Maya_Angry_1.webp');
      final DecodedAnimation anim = await DecodedAnimation.create(
        assetId: 'angry',
        bytes: await file.readAsBytes(),
      );
      expect(anim.isAnimated, isTrue, reason: '真实 WebP 应为多帧动画');

      final PetFrameController controller =
          PetFrameController(decoder: _FakeDecoder(<String, DecodedAnimation>{'angry': anim}));
      addTearDown(controller.dispose);

      await controller.display(asset(
        id: 'angry',
        path: file.path,
        frames: anim.frameCount,
        animated: true,
      ));

      expect(anim.frameIndex, 0);
      // 帧定时器推进到非零帧。
      await waitUntil(() => anim.frameIndex > 0, reason: 'frameIndex 应从 0 开始推进');
      final int first = anim.frameIndex;
      // 再推进至少一次，确认真实定时器在持续运转而不是碰巧一帧。
      await waitUntil(() => anim.frameIndex != first, reason: 'frameIndex 应继续变化');
      expect(controller.currentFrameIndex, anim.frameIndex,
          reason: '渲染器应暴露当前帧序号供诊断页展示');
      expect(controller.isAnimated, isTrue);
    });

    test('每次帧推进都会触发 Renderer 通知', () async {
      if (folder == null) {
        markTestSkipped('未找到 Ace Attorney 素材目录');
        return;
      }
      final File file = animatedFile('Maya_Angry_1.webp');
      final DecodedAnimation anim = await DecodedAnimation.create(
        assetId: 'angry',
        bytes: await file.readAsBytes(),
      );
      final PetFrameController controller =
          PetFrameController(decoder: _FakeDecoder(<String, DecodedAnimation>{'angry': anim}));
      addTearDown(controller.dispose);

      int notifications = 0;
      controller.addListener(() => notifications++);

      await controller.display(asset(
        id: 'angry',
        path: file.path,
        frames: anim.frameCount,
        animated: true,
      ));
      await waitUntil(() => anim.frameIndex >= 3, reason: '帧应至少推进 3 次');

      // 初始 display 通知 1 次 + 每次成功 advance 各 1 次。
      expect(notifications, greaterThanOrEqualTo(3),
          reason: '每次帧推进都必须通知监听者，否则 Widget 不会重建、Painter 不会重绘');
    });

    test('动画状态下 Painter 必须重绘（即使新旧 Painter 持有同一个图层对象）', () async {
      if (folder == null) {
        markTestSkipped('未找到 Ace Attorney 素材目录');
        return;
      }
      final File file = animatedFile('Maya_Angry_1.webp');
      final DecodedAnimation anim = await DecodedAnimation.create(
        assetId: 'angry',
        bytes: await file.readAsBytes(),
      );
      // 复刻缺陷现场：新旧 Painter 持有的是同一个可变 AnimationRenderLayer。
      final AnimationRenderLayer layer = AnimationRenderLayer(animation: anim, opacity: 1.0);
      final PetLayerPainter oldPainter =
          PetLayerPainter(layers: <PetRenderLayer>[layer], smooth: false);
      final PetLayerPainter newPainter =
          PetLayerPainter(layers: <PetRenderLayer>[layer], smooth: false);
      expect(newPainter.shouldRepaint(oldPainter), isTrue,
          reason: '动画图层存在时必须重绘——identical(image) 永远为真，无法感知帧变化');
    });

    test('静态图片不会启动帧定时器', () async {
      final Directory tmp = Directory.systemTemp.createTempSync('petlife_static_test');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final File png = File(p.join(tmp.path, 'static.png'));
      png.writeAsBytesSync(base64Decode(kTinyPngBase64));

      final DecodedAnimation staticAnim = await DecodedAnimation.create(
        assetId: 'static',
        bytes: await png.readAsBytes(),
      );
      expect(staticAnim.isAnimated, isFalse, reason: 'PNG 应为静态图');

      final PetFrameController controller =
          PetFrameController(decoder: _FakeDecoder(<String, DecodedAnimation>{'static': staticAnim}));
      addTearDown(controller.dispose);

      int notifications = 0;
      controller.addListener(() => notifications++);

      await controller.display(asset(id: 'static', path: png.path));
      await Future<void>.delayed(const Duration(milliseconds: 350));

      expect(notifications, 1,
          reason: '静态图只有 display 的一次通知，不应启动帧定时器造成持续重绘');
      expect(staticAnim.frameIndex, 0);
      expect(controller.currentFrameIndex, 0);
    });

    test('loopAnimation=false 后帧停止推进', () async {
      if (folder == null) {
        markTestSkipped('未找到 Ace Attorney 素材目录');
        return;
      }
      final File file = animatedFile('Maya_Angry_1.webp');
      final DecodedAnimation anim = await DecodedAnimation.create(
        assetId: 'angry',
        bytes: await file.readAsBytes(),
      );
      final PetFrameController controller =
          PetFrameController(decoder: _FakeDecoder(<String, DecodedAnimation>{'angry': anim}));
      addTearDown(controller.dispose);

      await controller.display(asset(
        id: 'angry',
        path: file.path,
        frames: anim.frameCount,
        animated: true,
      ));
      await waitUntil(() => anim.frameIndex > 0, reason: '动画应先开始播放');

      controller.setLoop(false);
      // 让可能正在飞行中的一次 advance 落定，再冻结帧号。
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final int frozen = anim.frameIndex;

      // 至少等待一个完整帧周期 + 余量。
      final int period = anim.frameDuration.inMilliseconds < 0 ? 100 : anim.frameDuration.inMilliseconds;
      await Future<void>.delayed(Duration(milliseconds: period + 250));

      expect(anim.frameIndex, frozen, reason: '禁用循环后帧不应继续推进');
    });

    test('切换素材后旧动画定时器和旧 ui.Image 被释放', () async {
      if (folder == null) {
        markTestSkipped('未找到 Ace Attorney 素材目录');
        return;
      }
      final File fileA = animatedFile('Maya_Angry_1.webp');
      final File fileB = animatedFile('Maya_Thinking_1.webp');
      final DecodedAnimation animA = await DecodedAnimation.create(
        assetId: 'a',
        bytes: await fileA.readAsBytes(),
      );
      final DecodedAnimation animB = await DecodedAnimation.create(
        assetId: 'b',
        bytes: await fileB.readAsBytes(),
      );
      final PetFrameController controller = PetFrameController(
        decoder: _FakeDecoder(<String, DecodedAnimation>{'a': animA, 'b': animB}),
      );
      addTearDown(controller.dispose);

      await controller.display(asset(
        id: 'a',
        path: fileA.path,
        frames: animA.frameCount,
        animated: true,
      ));
      await waitUntil(() => animA.frameIndex > 0, reason: '素材 A 应先开始播放');

      await controller.display(asset(
        id: 'b',
        path: fileB.path,
        frames: animB.frameCount,
        animated: true,
      ));

      // 交叉淡入淡出（默认 220ms）结束后旧动画必须被 dispose。
      await waitUntil(
        () => animA.isDisposed,
        timeout: const Duration(seconds: 5),
        reason: '旧动画应在淡出结束后释放（dispose ui.Codec 与 ui.Image）',
      );
      expect(controller.currentAssetId, 'b');

      final int frozen = animA.frameIndex;
      final int periodB = animB.frameDuration.inMilliseconds < 0 ? 100 : animB.frameDuration.inMilliseconds;
      await Future<void>.delayed(Duration(milliseconds: periodB + 250));
      expect(animA.frameIndex, frozen,
          reason: '旧动画释放后不得再推进帧（其定时器已被取消）');
    });
  });

  group('状态调试器与自动切换的即时性', () {
    final DateTime base = DateTime(2026, 9, 27, 12, 0, 0);

    test('状态调试器请求携带 force=true 和 immediate=true', () {
      for (final SystemState state in SystemState.values) {
        final StateChangeRequest r = debuggerStateRequest(state);
        expect(r.state, state);
        expect(r.trigger, StateTrigger.debugger, reason: state.wireName);
        expect(r.force, isTrue, reason: '${state.wireName}: 调试器必须强制触发（覆盖全部状态）');
        expect(r.immediate, isTrue,
            reason: '${state.wireName}: 调试器必须立即生效（不等当前动画播完一轮）');
        expect(r.manualAssetId, isNull, reason: '${state.wireName}: 非 manual 不携带锁定图');
      }
    });

    test('manual 状态请求携带 manualAssetId', () {
      final StateChangeRequest r =
          debuggerStateRequest(SystemState.manual, manualAssetId: 'a1');
      expect(r.immediate, isTrue);
      expect(r.force, isTrue);
      expect(r.manualAssetId, 'a1');
    });

    test('普通自动状态仍然 waitForAnimationCycle=true', () {
      final DebounceDecision d = const StateDebouncer().decide(
        currentState: SystemState.focused,
        currentStateStartedAt: base.subtract(const Duration(seconds: 60)),
        lastAppliedChangeAt: base.subtract(const Duration(seconds: 60)),
        request: const StateChangeRequest(
          state: SystemState.happy,
          trigger: StateTrigger.foregroundApp,
        ),
        now: base,
        appStateStableFor: const Duration(seconds: 60),
      );
      expect(d, isA<ApplyNow>());
      expect((d as ApplyNow).waitForAnimationCycle, isTrue,
          reason: '真实运行下的自动切换仍应等当前动画播完一轮');
    });

    test('调试器 immediate=true 的请求跳过「等动画一轮」', () {
      final DebounceDecision d = const StateDebouncer().decide(
        currentState: SystemState.focused,
        currentStateStartedAt: base.subtract(const Duration(seconds: 60)),
        lastAppliedChangeAt: base.subtract(const Duration(seconds: 60)),
        request: debuggerStateRequest(SystemState.happy),
        now: base,
        appStateStableFor: const Duration(seconds: 60),
      );
      expect(d, isA<ApplyNow>());
      expect((d as ApplyNow).waitForAnimationCycle, isFalse,
          reason: '调试器手动触发必须立即开始切换');
    });
  });
}

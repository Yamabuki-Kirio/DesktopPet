import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import '../../asset_decoder/asset_decoder.dart';
import '../../asset_decoder/decoded_animation.dart';
import '../../character/models/emotion_asset.dart';
import '../../character/pet_renderer.dart';
import '../../character/pet_visual_bounds.dart';
import '../../core/logger.dart';
import '../../core/result.dart';

/// 动画图层（公开，供 Widget 直接绘制）。
class AnimationRenderLayer extends PetRenderLayer {
  const AnimationRenderLayer({required this.animation, required super.opacity})
      : super(assetId: null);

  final DecodedAnimation animation;

  @override
  String? get assetId => animation.assetId;

  @override
  bool get isPlaceholder => false;

  ui.Image get image => animation.image;

  @override
  String toString() => 'AnimationLayer(${animation.assetId}, opacity=${opacity.toStringAsFixed(2)})';
}

/// 内置占位图图层（公开，供 Widget 直接绘制）。
class PlaceholderRenderLayer extends PetRenderLayer {
  const PlaceholderRenderLayer({required super.opacity}) : super(assetId: null);

  @override
  bool get isPlaceholder => true;

  @override
  String toString() => 'PlaceholderLayer(opacity=${opacity.toStringAsFixed(2)})';
}

/// 基于 Flutter `dart:ui` 的桌宠渲染器。
///
/// 设计要点：
/// 1. **图层化**：切换素材时新旧素材各占一个图层，用 150~300ms 交叉淡入淡出
///    （需求「图片切换使用约 150～300ms 淡入淡出」）。
///    注意淡化的是**素材之间**，不是动画帧之间——帧是原地替换的。
/// 2. **不重复解码**：同一 assetId 重复 display 会被直接忽略，
///    动画不会被打断重播（需求「同一张图片不得反复重新加载和重新开始动画」）。
/// 3. **逐帧拉取**：每帧按需从 codec 取出，取到新帧后立即释放旧帧，
///    长时间运行不会累积内存（验收第 21 项）。
/// 4. **占位图零依赖**：素材为空时挂占位图层，由 Widget 用 Canvas 直接画。
class PetFrameController extends PetRenderer {
  PetFrameController({required AssetDecoder decoder}) : _decoder = decoder;

  final AssetDecoder _decoder;

  List<PetRenderLayer> _layers = <PetRenderLayer>[];

  Timer? _fadeTimer;
  Timer? _frameTimer;

  int _crossFadeMs = 220;
  bool _loop = true;
  bool _disposed = false;

  double _fadeProgress = 1.0;
  AnimationRenderLayer? _outgoing;

  @override
  List<PetRenderLayer> get layers => List<PetRenderLayer>.unmodifiable(_layers);

  @override
  String? get currentAssetId {
    for (int i = _layers.length - 1; i >= 0; i--) {
      final PetRenderLayer l = _layers[i];
      if (l is AnimationRenderLayer) return l.animation.assetId;
    }
    return null;
  }

  AnimationRenderLayer? get _topAnimation {
    for (int i = _layers.length - 1; i >= 0; i--) {
      final PetRenderLayer l = _layers[i];
      if (l is AnimationRenderLayer) return l;
    }
    return null;
  }

  @override
  bool get isAnimated => _topAnimation?.animation.isAnimated ?? false;

  @override
  int? get currentFrameIndex => _topAnimation?.animation.frameIndex;

  @override
  int get remainingMsInCycle => _topAnimation?.animation.remainingMsInCycle ?? 0;

  @override
  ui.Size? get contentSize {
    final AnimationRenderLayer? top = _topAnimation;
    if (top != null) return top.animation.size;
    if (_layers.any((PetRenderLayer l) => l.isPlaceholder)) return BuiltinPlaceholder.size;
    return null;
  }

  // ---------------------------------------------------------------------------
  // 人物视觉边界（alpha 包围盒）—— C1.1 需求 §二
  // ---------------------------------------------------------------------------

  /// 逐帧测量的缓存（按 `assetId + frameIndex` 去重，绝不对同一帧重复扫像素）。
  final PetVisualBoundsCache _visualBoundsCache = PetVisualBoundsCache();

  /// 进行中的测量（保证 [ensureVisualBounds] 不会漏掉"刚好在飞的那一次"）。
  Future<void>? _pendingMeasure;

  /// 已经上报过视觉边界的素材（用于判断"是否需要让固几何失效"）。
  String? _reportedBoundsAssetId;

  /// 测量缓存（诊断 / 测试用）。
  PetVisualBoundsCache get visualBoundsCache => _visualBoundsCache;

  @override
  PetVisualBounds? get visualBounds {
    final String? id = currentAssetId;
    if (id == null) return null;
    return _visualBoundsCache.boundsOf(id);
  }

  @override
  Future<PetVisualBounds> ensureVisualBounds() async {
    // 先等一次在飞的测量（它可能正好就是当前素材的首帧）。
    for (int i = 0; i < 2; i++) {
      final Future<void>? pending = _pendingMeasure;
      if (pending != null) {
        await pending;
      } else {
        break;
      }
      final PetVisualBounds? got = visualBounds;
      if (got != null) return got;
    }
    // 还没量到 → 立刻主动量一次当前帧（不等下一帧，避免"打开菜单时缺口还是整张图"）。
    await _measureCurrentFrame();
    return visualBounds ?? PetVisualBounds.full;
  }

  /// 量当前顶层动画的**当前帧**（幂等：同一帧只扫一次像素）。
  Future<void> _measureCurrentFrame() async {
    if (_disposed) return;
    final AnimationRenderLayer? top = _topAnimation;
    if (top == null) return; // 占位图无需测量（它是自绘的矢量形状）。
    final String assetId = top.animation.assetId;
    final int frameIndex = top.animation.frameIndex;
    if (_visualBoundsCache.hasMeasuredFrame(assetId, frameIndex)) return;

    final ui.Image image = top.animation.image;
    final Future<void> task = () async {
      final PetVisualBounds? before = _visualBoundsCache.boundsOf(assetId);
      final PetVisualBounds bounds = await PetAlphaBoundsScanner.measureImage(image);
      if (_disposed) return;
      _visualBoundsCache.record(assetId, frameIndex, bounds);
      if (_reportedBoundsAssetId != assetId) {
        _reportedBoundsAssetId = assetId;
        Loggers.decode.info(
          '视觉边界测量: asset=$assetId frame=$frameIndex '
          'bounds=${bounds.describe()} '
          'frames=${_visualBoundsCache.measuredFrames(assetId)}',
        );
      }
      // 只在**并集变大**时通知（新帧把边界撑开 → 以人物尺寸为输入的几何需要失效）。
      //
      // ⚠️ 首帧测量**不**通知：静态素材若为此多发一次通知，会变成"静态图持续重绘"
      // 那类缺陷（并且规划侧本来就 `await ensureVisualBounds()`，不依赖通知）。
      final PetVisualBounds? after = _visualBoundsCache.boundsOf(assetId);
      final bool grew = before != null &&
          after != null &&
          (after.left < before.left - 1e-6 ||
              after.top < before.top - 1e-6 ||
              after.right > before.right + 1e-6 ||
              after.bottom > before.bottom + 1e-6);
      if (grew) notifyListeners();
    }();
    _pendingMeasure = task;
    try {
      await task;
    } finally {
      if (identical(_pendingMeasure, task)) _pendingMeasure = null;
    }
  }

  /// 当前是否处于淡入淡出过程中（诊断用）。
  double get fadeProgress => _fadeProgress;

  bool get isFading => _fadeTimer != null;

  @override
  void setLoop(bool loop) {
    if (_loop == loop) return;
    _loop = loop;
    Loggers.decode.info('动画循环播放设置为 $loop');
    if (_loop) {
      _scheduleFrame();
    } else {
      _frameTimer?.cancel();
      _frameTimer = null;
    }
  }

  @override
  void setCrossFadeMs(int ms) {
    if (ms == _crossFadeMs) return;
    _crossFadeMs = ms;
    Loggers.settings.fine('淡入淡出时长设置为 ${ms}ms');
  }

  @override
  Future<void> display(EmotionAsset? asset, {bool immediate = false}) async {
    if (_disposed) return;

    // 完全没有素材 → 占位图。
    if (asset == null) {
      if (_layers.length == 1 && _layers.first.isPlaceholder) return;
      await _switchTo(const PlaceholderRenderLayer(opacity: 0), immediate: immediate);
      return;
    }

    // 同一素材重复请求：什么都不做，动画继续跑，绝不重启。
    if (currentAssetId == asset.id) return;

    // 素材不可用（被禁用 / 校验失败）→ 占位图，避免渲染空白。
    if (!asset.isRenderable) {
      Loggers.decode.warning(
        '素材不可渲染（enabled=${asset.enabled} '
        'status=${asset.validationStatus.wireName}），显示占位图: ${asset.id}',
      );
      await _switchTo(const PlaceholderRenderLayer(opacity: 0), immediate: immediate);
      return;
    }

    final Result<DecodedAnimation> result = await _decoder.load(
      assetId: asset.id,
      file: File(asset.filePath),
      containerDurationMs: asset.animationDurationMs,
    );
    if (_disposed) return;

    if (result is Err<DecodedAnimation>) {
      // 解码失败 → 占位图，而不是崩溃或空白（验收第 16 项）。
      Loggers.decode.warning('素材加载失败，回退占位图: ${asset.id} -> ${result.failure}');
      await _switchTo(const PlaceholderRenderLayer(opacity: 0), immediate: true);
      return;
    }

    final DecodedAnimation animation = (result as Ok<DecodedAnimation>).value;
    Loggers.decode.info(
      '开始渲染 ${asset.emotionName}/${asset.variantName} '
      '(${animation.size.width.toInt()}x${animation.size.height.toInt()}, '
      '${animation.frameCount} 帧, 动画=${animation.isAnimated}, '
      '一轮=${animation.effectiveTotalDurationMs}ms)',
    );
    await _switchTo(AnimationRenderLayer(animation: animation, opacity: 0), immediate: immediate);
  }

  /// 用新图层替换当前图层，并启动淡入淡出。
  Future<void> _switchTo(PetRenderLayer incoming, {required bool immediate}) async {
    _fadeTimer?.cancel();
    _frameTimer?.cancel();

    final AnimationRenderLayer? previous =
        _layers.isNotEmpty && _layers.last is AnimationRenderLayer
            ? _layers.last as AnimationRenderLayer
            : null;
    _outgoing = previous;

    if (previous == null || immediate || _crossFadeMs <= 0) {
      if (previous != null) previous.animation.dispose();
      _outgoing = null;
      _fadeProgress = 1.0;
      _layers = <PetRenderLayer>[incoming.withOpacity(1.0)];
      _scheduleFrame();
      // 换素材后立刻量一次首帧：缺口不能等到下一帧才对齐。
      unawaited(_measureCurrentFrame());
      notifyListeners();
      return;
    }

    _fadeProgress = 0.0;
    _layers = <PetRenderLayer>[
      previous.withOpacity(1.0),
      incoming.withOpacity(0.0),
    ];

    const int stepMs = 16;
    _fadeTimer = Timer.periodic(const Duration(milliseconds: stepMs), (Timer timer) {
      if (_disposed) {
        timer.cancel();
        return;
      }
      _fadeProgress += stepMs / _crossFadeMs;
      if (_fadeProgress >= 1.0) {
        _finishFade();
        timer.cancel();
      } else {
        _layers = <PetRenderLayer>[
          previous.withOpacity(1.0 - _fadeProgress),
          incoming.withOpacity(_fadeProgress),
        ];
      }
      notifyListeners();
    });
  }

  void _finishFade() {
    final AnimationRenderLayer? outgoing = _outgoing;
    final PetRenderLayer incoming = _layers.last;

    // 释放退场图层占用的原生资源。
    outgoing?.animation.dispose();

    _outgoing = null;
    _fadeTimer = null;
    _fadeProgress = 1.0;
    _layers = <PetRenderLayer>[incoming.withOpacity(1.0)];
    _scheduleFrame();
    unawaited(_measureCurrentFrame());
    notifyListeners();
  }

  /// 按当前帧时长安排下一次取帧。
  void _scheduleFrame() {
    _frameTimer?.cancel();
    if (_disposed || !_loop) return;
    final AnimationRenderLayer? top = _topAnimation;
    if (top == null || !top.animation.isAnimated) return;

    int ms = top.animation.frameDuration.inMilliseconds;
    if (ms <= 0) ms = 100;

    _frameTimer = Timer(Duration(milliseconds: ms), () async {
      if (_disposed) return;
      final bool advanced = await top.animation.advance();
      if (_disposed) return;
      if (advanced) {
        // 视觉边界：**逐帧**测量（同一帧只扫一次像素），并累加成稳定并集。
        unawaited(_measureCurrentFrame());
        notifyListeners();
      }
      _scheduleFrame();
    });
  }

  @override
  Future<void> clear() async {
    _fadeTimer?.cancel();
    _frameTimer?.cancel();
    _fadeTimer = null;
    _frameTimer = null;
    for (final PetRenderLayer l in _layers) {
      if (l is AnimationRenderLayer) l.animation.dispose();
    }
    _outgoing = null;
    _layers = <PetRenderLayer>[];
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _fadeTimer?.cancel();
    _frameTimer?.cancel();
    for (final PetRenderLayer l in _layers) {
      if (l is AnimationRenderLayer) l.animation.dispose();
    }
    _layers = <PetRenderLayer>[];
    super.dispose();
    Loggers.decode.info('渲染器已释放');
  }
}

/// 复制一个图层并换掉不透明度，避免 Widget 依赖可变对象。
extension PetRenderLayerOps on PetRenderLayer {
  PetRenderLayer withOpacity(double value) {
    final PetRenderLayer self = this;
    if (self is AnimationRenderLayer) {
      return AnimationRenderLayer(animation: self.animation, opacity: value);
    }
    return PlaceholderRenderLayer(opacity: value);
  }
}

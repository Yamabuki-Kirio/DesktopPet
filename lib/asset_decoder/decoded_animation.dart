import 'dart:typed_data';
import 'dart:ui' as ui;

import '../core/logger.dart';

/// 一个已解码、可逐帧播放的素材。
///
/// 由 [ui.Codec] 驱动。Skia 的 WebP 解码器（libwebp 的动画解码器）会**返回合成后的整幅画布帧**，
/// 因此 Ace Attorney 这类「帧矩形小于画布」的素材可以正确显示，无需在上层手工合成。
/// 这一点会在阶段 0 验收第 6/7/8 项中实测确认。
class DecodedAnimation {
  DecodedAnimation._({
    required this.assetId,
    required ui.Codec codec,
    required ui.Image firstFrame,
    required this.frameCount,
    required this.frameDuration,
    required this.totalDurationMs,
    required this.size,
  })  : _codec = codec,
        _current = firstFrame;

  final String assetId;
  final int frameCount;

  /// 当前帧应有的展示时长。
  Duration frameDuration;

  /// 一轮动画总时长（毫秒）。静态图为 0。
  final int totalDurationMs;

  final ui.Size size;

  final ui.Codec _codec;
  ui.Image _current;
  int _frameIndex = 0;
  int _playedMs = 0;
  bool _disposed = false;

  /// 解码一个素材。
  ///
  /// 只解码一次，得到 codec 与首帧；后续帧由 [advance] 按需拉取，
  /// 避免一次性把所有帧解进内存。
  static Future<DecodedAnimation> create({
    required String assetId,
    required Uint8List bytes,
  }) async {
    final ui.Codec codec = await ui.instantiateImageCodec(bytes);
    final ui.FrameInfo first = await codec.getNextFrame();
    final int frameCount = codec.frameCount <= 0 ? 1 : codec.frameCount;

    int total = 0;
    if (frameCount > 1) {
      // 用首帧 duration 做初值；精确总时长由 WebP 容器解析给出并覆盖。
      total = first.duration.inMilliseconds * frameCount;
    }

    return DecodedAnimation._(
      assetId: assetId,
      codec: codec,
      firstFrame: first.image,
      frameCount: frameCount,
      frameDuration: first.duration,
      totalDurationMs: total,
      size: ui.Size(first.image.width.toDouble(), first.image.height.toDouble()),
    );
  }

  bool get isAnimated => frameCount > 1;

  bool get isDisposed => _disposed;

  ui.Image get image => _current;

  int get frameIndex => _frameIndex;

  /// 覆盖容器解析得到的总时长与单帧时长（比 codec 推断更准确）。
  void overrideTiming({required int totalDurationMsFromContainer}) {
    if (totalDurationMsFromContainer <= 0) return;
    _totalOverride = totalDurationMsFromContainer;
  }

  int? _totalOverride;

  int get effectiveTotalDurationMs => _totalOverride ?? totalDurationMs;

  /// 距离当前这一轮动画结束还有多少毫秒。
  ///
  /// 需求「五、素材显示」要求普通状态切换时尽量等当前动画播完一轮，
  /// 该值就是渲染层的等待依据。静态图返回 0（无需等待）。
  int get remainingMsInCycle {
    if (!isAnimated) return 0;
    final int total = effectiveTotalDurationMs;
    if (total <= 0) return 0;
    final int remaining = total - _playedMs;
    return remaining < 0 ? 0 : remaining;
  }

  /// 推进到下一帧。
  ///
  /// 返回 true 表示成功取到新帧（动画）；静态图始终返回 false。
  Future<bool> advance() async {
    if (_disposed || !isAnimated) return false;
    try {
      final ui.FrameInfo next = await _codec.getNextFrame();
      if (_disposed) {
        next.image.dispose();
        return false;
      }
      final ui.Image old = _current;
      _current = next.image;
      _playedMs += frameDuration.inMilliseconds;
      frameDuration = next.duration;
      _frameIndex = (_frameIndex + 1) % frameCount;
      if (_frameIndex == 0) {
        // 一轮结束，重置计数，供“等一轮播完”逻辑使用。
        _playedMs = 0;
      }
      // 及时释放上一帧，避免动画长时间运行造成内存增长（验收第 21 项）。
      old.dispose();
      return true;
    } catch (e, st) {
      Loggers.decode.warning('动画推进失败: asset=$assetId frame=$_frameIndex', e, st);
      return false;
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    try {
      _current.dispose();
    } catch (_) {
      // ignore
    }
    try {
      _codec.dispose();
    } catch (_) {
      // ignore
    }
  }
}

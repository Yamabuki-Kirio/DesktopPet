import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../core/constants.dart';
import '../core/logger.dart';
import '../core/result.dart';
import 'asset_decoder.dart';
import 'decoded_animation.dart';
import 'lru_cache.dart';

/// 基于 Flutter `dart:ui` 解码器的实现。
///
/// 缓存策略（需求：有限缓存 + 避免重复解码）：
/// - **字节缓存**：LRU，最近用过的文件原始字节，避免反复读盘。
/// - **静态图缓存**：LRU，缓存已解码的 [ui.Image]，按实际像素字节计费。
/// - **动画不缓存 codec**：`ui.Codec` 是有状态的游标，多个播放器共享会互相干扰。
///   同时只保留一个活动动画（桌宠窗口只有一个），切换时立刻 dispose 旧的。
class FlutterAssetDecoder implements AssetDecoder {
  FlutterAssetDecoder();

  final LruCache<String, Uint8List> _bytesCache = LruCache<String, Uint8List>(
    maxEntries: 32,
    maxBytes: 96 * 1024 * 1024,
    sizeOf: (String _, Uint8List v) => v.lengthInBytes,
  );

  final LruCache<String, ui.Image> _imageCache = LruCache<String, ui.Image>(
    maxEntries: AssetLimits.decodedCacheEntries,
    maxBytes: AssetLimits.decodedCacheBytes,
    sizeOf: (String _, ui.Image v) => v.width * v.height * 4,
    onEvict: (String _, ui.Image v) {
      // ui.Image 持有原生内存，必须显式释放。
      try {
        v.dispose();
      } catch (_) {
        // 可能已被释放，忽略。
      }
    },
  );

  @override
  int get cachedImageEntries => _imageCache.length;

  @override
  int get cachedImageBytes => _imageCache.bytes;

  @override
  int get cachedFileEntries => _bytesCache.length;

  @override
  int get cachedFileBytes => _bytesCache.bytes;

  @override
  Future<Result<DecodeVerification>> verifyDecodable(File file) async {
    try {
      final Uint8List bytes = await _readBytes(file);
      final ui.Codec codec = await ui.instantiateImageCodec(bytes);
      try {
        final ui.FrameInfo frame = await codec.getNextFrame();
        final DecodeVerification verification = DecodeVerification(
          decoderFrameCount: codec.frameCount <= 0 ? 1 : codec.frameCount,
          width: frame.image.width,
          height: frame.image.height,
          firstFrameDurationMs: frame.duration.inMilliseconds,
        );
        frame.image.dispose();
        return Ok<DecodeVerification>(verification);
      } finally {
        codec.dispose();
      }
    } catch (e, st) {
      Loggers.decode.warning('解码验证失败: ${file.path}', e, st);
      return Err<DecodeVerification>(Failure(
        FailureKind.undecodable,
        '解码器无法解码该文件',
        detail: e.toString(),
      ));
    }
  }

  @override
  Future<Result<DecodedAnimation>> load({
    required String assetId,
    required File file,
    int containerDurationMs = 0,
  }) async {
    try {
      final Uint8List bytes = await _readBytes(file);
      final DecodedAnimation animation = await DecodedAnimation.create(
        assetId: assetId,
        bytes: bytes,
      );
      if (containerDurationMs > 0) {
        animation.overrideTiming(totalDurationMsFromContainer: containerDurationMs);
      }
      return Ok<DecodedAnimation>(animation);
    } catch (e, st) {
      Loggers.decode.warning('素材解码失败: asset=$assetId path=${file.path}', e, st);
      return Err<DecodedAnimation>(Failure(
        FailureKind.undecodable,
        '素材解码失败',
        detail: e.toString(),
      ));
    }
  }

  @override
  Future<Result<ui.Image>> loadStaticImage({
    required String assetId,
    required File file,
  }) async {
    final ui.Image? cached = _imageCache.get(assetId);
    if (cached != null) {
      Loggers.decode.fine('静态图缓存命中: $assetId');
      return Ok<ui.Image>(cached);
    }
    try {
      final Uint8List bytes = await _readBytes(file);
      final ui.Codec codec = await ui.instantiateImageCodec(bytes);
      final ui.FrameInfo frame = await codec.getNextFrame();
      codec.dispose();
      _imageCache.put(assetId, frame.image);
      return Ok<ui.Image>(frame.image);
    } catch (e, st) {
      Loggers.decode.warning('静态图解码失败: asset=$assetId path=${file.path}', e, st);
      return Err<ui.Image>(Failure(FailureKind.undecodable, '静态图解码失败', detail: e.toString()));
    }
  }

  @override
  Future<void> evict(String assetId) async {
    _imageCache.remove(assetId);
    _bytesCache.remove(assetId);
  }

  @override
  Future<void> clear() async {
    _imageCache.clear();
    _bytesCache.clear();
    Loggers.decode.info('解码缓存已清空');
  }

  /// 读文件，带字节缓存。
  Future<Uint8List> _readBytes(File file) async {
    final String key = file.path;
    final Uint8List? cached = _bytesCache.get(key);
    if (cached != null) return cached;
    // 大文件不进字节缓存，避免把内存都花在极少复用的资源上。
    final int size = await file.length();
    final Uint8List bytes = await file.readAsBytes();
    if (size <= 4 * 1024 * 1024) {
      _bytesCache.put(key, bytes);
    }
    return bytes;
  }
}

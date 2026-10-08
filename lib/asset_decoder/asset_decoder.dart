import 'dart:io';
import 'dart:ui' as ui;

import '../core/result.dart';
import 'decoded_animation.dart';

/// 解码层抽象。
///
/// 抽象出来是为了后续阶段能换实现而不动业务逻辑：
/// 例如 Android 用不同的解码后端、或引入带预乘 alpha 校正的解码器。
abstract interface class AssetDecoder {
  /// 验证文件**真的能被解码**（不只是头合法）。
  ///
  /// 需求 4.5 要求校验「文件能否解码」，容器头解析做不到这一点。
  /// 返回的 [DecodeVerification] 会带上解码器报告的帧数，
  /// 用于交叉验证容器解析结果（若两者不一致，说明后端不支持该动画）。
  Future<Result<DecodeVerification>> verifyDecodable(File file);

  /// 加载为一个可逐帧播放的动画句柄（静态图也可用，此时 frameCount = 1）。
  Future<Result<DecodedAnimation>> load({
    required String assetId,
    required File file,
    int containerDurationMs = 0,
  });

  /// 加载静态图并进入有限缓存；同一 assetId 重复调用直接命中缓存。
  Future<Result<ui.Image>> loadStaticImage({
    required String assetId,
    required File file,
  });

  /// 从缓存中移除（含释放原生资源）。
  Future<void> evict(String assetId);

  /// 清空缓存。
  Future<void> clear();

  /// 缓存统计（诊断用）。
  int get cachedImageEntries;

  int get cachedImageBytes;

  int get cachedFileEntries;

  int get cachedFileBytes;
}

/// 解码验证结果。
class DecodeVerification {
  const DecodeVerification({
    required this.decoderFrameCount,
    required this.width,
    required this.height,
    required this.firstFrameDurationMs,
  });

  /// 解码器报告的帧数。若为 1 而容器显示为动画，说明后端未启用动画解码。
  final int decoderFrameCount;

  final int width;
  final int height;
  final int firstFrameDurationMs;
}

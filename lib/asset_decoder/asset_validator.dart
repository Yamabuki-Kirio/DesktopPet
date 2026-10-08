import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../core/constants.dart';
import '../core/logger.dart';
import '../core/result.dart';
import 'image_format.dart';
import 'image_header.dart';
import 'webp_container.dart';

/// 素材结构探测结果（不包含像素解码）。
class AssetProbe {
  const AssetProbe({
    required this.path,
    required this.format,
    required this.width,
    required this.height,
    required this.hasAlpha,
    required this.frameCount,
    required this.isAnimated,
    required this.fileSize,
    required this.fileHash,
    required this.animationDurationMs,
    this.detail,
    this.webp,
  });

  final String path;
  final ImageFormat format;
  final int width;
  final int height;
  final bool hasAlpha;
  final int frameCount;
  final bool isAnimated;
  final int fileSize;

  /// SHA-256 十六进制摘要，用于去重与「文件是否变化」判断。
  final String fileHash;

  /// 一轮动画时长（毫秒）；静态图为 0。
  final int animationDurationMs;

  final String? detail;

  /// WebP 专属细节（帧矩形、循环次数等）。
  final WebpInfo? webp;

  String get mimeType => format.mimeType;

  int get pixels => width * height;
}

/// 素材校验器。
abstract interface class AssetValidator {
  /// 校验单个文件。
  ///
  /// - **绝不抛出异常**：任何异常都会被转成 [Err]。
  /// - [declaredExtension] 为文件名上的扩展名，用于识别伪造扩展名。
  Future<Result<AssetProbe>> probe(File file, {required String declaredExtension});

  /// 校验一段已在内存中的字节（ZIP 导入用，因为条目没有真实文件路径）。
  Future<Result<AssetProbe>> probeBytes(
    Uint8List bytes, {
    required String virtualPath,
    required String declaredExtension,
  });
}

/// 默认实现：magic bytes + 容器头解析 + 资源上限检查。
class DefaultAssetValidator implements AssetValidator {
  const DefaultAssetValidator();

  @override
  Future<Result<AssetProbe>> probe(
    File file, {
    required String declaredExtension,
  }) async {
    try {
      if (!await file.exists()) {
        return Err<AssetProbe>(Failure(FailureKind.unreadable, '文件不存在'));
      }
      final int size = await file.length();
      if (size == 0) {
        return Err<AssetProbe>(Failure(FailureKind.emptyContent, '文件为空'));
      }
      if (size > AssetLimits.maxFileBytes) {
        return Err<AssetProbe>(Failure(
          FailureKind.fileTooLarge,
          '文件超过单文件上限',
          detail: '$size > ${AssetLimits.maxFileBytes} 字节',
        ));
      }
      final Uint8List bytes = await file.readAsBytes();
      return _probeBytes(bytes, path: file.path, declaredExtension: declaredExtension);
    } catch (e, st) {
      // 读盘失败（权限、占用、坏道）不能影响同文件夹中其他素材。
      Loggers.scan.warning('读取素材失败: ${file.path}', e, st);
      return Err<AssetProbe>(Failure(FailureKind.unreadable, '读取失败', detail: e.toString()));
    }
  }

  @override
  Future<Result<AssetProbe>> probeBytes(
    Uint8List bytes, {
    required String virtualPath,
    required String declaredExtension,
  }) async {
    try {
      return _probeBytes(bytes, path: virtualPath, declaredExtension: declaredExtension);
    } catch (e, st) {
      Loggers.scan.warning('校验字节流失败: $virtualPath', e, st);
      return Err<AssetProbe>(Failure(FailureKind.unknown, '校验失败', detail: e.toString()));
    }
  }

  Result<AssetProbe> _probeBytes(
    Uint8List bytes, {
    required String path,
    required String declaredExtension,
  }) {
    final ImageFormat format = ImageFormatSniffer.sniff(bytes);

    if (format == ImageFormat.unknown) {
      return Err<AssetProbe>(Failure(
        FailureKind.undecodable,
        '无法识别的图片格式（文件头不匹配任何支持的格式）',
        detail: '前 12 字节: ${_hexPreview(bytes)}',
      ));
    }

    if (!format.isSupported) {
      return Err<AssetProbe>(Failure(FailureKind.unsupportedExtension, '不支持的格式 $format'));
    }

    if (!ImageFormatSniffer.extensionMatches(declaredExtension, format)) {
      return Err<AssetProbe>(Failure(
        FailureKind.formatMismatch,
        '扩展名与实际格式不符（疑似伪造扩展名）',
        detail: '.$declaredExtension 实际为 ${format.mimeType}',
      ));
    }

    final String hash = sha256.convert(bytes).toString();

    try {
      if (format == ImageFormat.webp) {
        final WebpInfo info = WebpContainerParser.parse(bytes);
        final Failure? limitFailure = _checkLimits(
          width: info.width,
          height: info.height,
          frames: info.frameCount,
          size: bytes.length,
        );
        if (limitFailure != null) return Err<AssetProbe>(limitFailure);

        return Ok<AssetProbe>(AssetProbe(
          path: path,
          format: format,
          width: info.width,
          height: info.height,
          hasAlpha: info.hasAlpha,
          frameCount: info.frameCount,
          isAnimated: info.isAnimated,
          fileSize: bytes.length,
          fileHash: hash,
          animationDurationMs: info.totalDurationMs,
          detail: '${info.encoding}, loop=${info.loopCount}, '
              '${info.hasSubRectFrames ? '帧矩形小于画布（需正确帧合成）' : '帧矩形等于画布'}',
          webp: info,
        ));
      }

      final ImageHeaderInfo header = ImageHeaderParser.parse(bytes, format);
      final Failure? limitFailure = _checkLimits(
        width: header.width,
        height: header.height,
        frames: header.frameCount,
        size: bytes.length,
      );
      if (limitFailure != null) return Err<AssetProbe>(limitFailure);

      return Ok<AssetProbe>(AssetProbe(
        path: path,
        format: format,
        width: header.width,
        height: header.height,
        hasAlpha: header.hasAlpha,
        frameCount: header.frameCount,
        isAnimated: header.isAnimated,
        fileSize: bytes.length,
        fileHash: hash,
        animationDurationMs: 0,
        detail: header.detail,
      ));
    } catch (e) {
      // 解析失败 = 文件损坏。标记不可用，但绝不抛出。
      return Err<AssetProbe>(Failure(
        FailureKind.undecodable,
        '图片解析失败，文件可能已损坏',
        detail: e.toString(),
      ));
    }
  }

  /// 资源上限检查（防止解压炸弹与超大解码内存）。
  Failure? _checkLimits({
    required int width,
    required int height,
    required int frames,
    required int size,
  }) {
    if (width <= 0 || height <= 0) {
      return Failure(FailureKind.undecodable, '图片尺寸非法', detail: '${width}x$height');
    }
    if (width > AssetLimits.maxEdge || height > AssetLimits.maxEdge) {
      return Failure(
        FailureKind.dimensionTooLarge,
        '图片单边超过上限',
        detail: '${width}x$height > ${AssetLimits.maxEdge}',
      );
    }
    if (width * height > AssetLimits.maxPixels) {
      return Failure(
        FailureKind.tooManyPixels,
        '图片像素总量超过上限',
        detail: '${width * height} > ${AssetLimits.maxPixels}',
      );
    }
    if (frames > AssetLimits.maxFrames) {
      return Failure(
        FailureKind.tooManyFrames,
        '帧数超过上限',
        detail: '$frames > ${AssetLimits.maxFrames}',
      );
    }
    return null;
  }

  String _hexPreview(Uint8List bytes) {
    final int n = bytes.length < 12 ? bytes.length : 12;
    return bytes
        .sublist(0, n)
        .map((int b) => b.toRadixString(16).padLeft(2, '0'))
        .join(' ');
  }
}

/// 便于日志：把探测结果序列化成短描述。
String describeProbe(AssetProbe p) => jsonEncode(<String, Object?>{
      'path': p.path,
      'format': p.format.name,
      'size': '${p.width}x${p.height}',
      'frames': p.frameCount,
      'animated': p.isAnimated,
      'alpha': p.hasAlpha,
      'duration_ms': p.animationDurationMs,
      'bytes': p.fileSize,
    });

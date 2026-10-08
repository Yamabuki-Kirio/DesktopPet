import 'dart:typed_data';

import 'image_format.dart';

/// 图片头信息（不解码像素）。
class ImageHeaderInfo {
  const ImageHeaderInfo({
    required this.format,
    required this.width,
    required this.height,
    required this.hasAlpha,
    required this.frameCount,
    required this.isAnimated,
    this.detail,
  });

  final ImageFormat format;
  final int width;
  final int height;
  final bool hasAlpha;
  final int frameCount;
  final bool isAnimated;

  /// 附加说明（例如 PNG 的色彩类型），用于日志与诊断。
  final String? detail;

  int get pixels => width * height;
}

/// PNG / JPEG / GIF 的纯 Dart 头解析。
///
/// WebP 由 [WebpContainerParser] 处理（需要拿帧矩形等更细的信息）。
class ImageHeaderParser {
  ImageHeaderParser._();

  /// 按真实格式分派解析。
  static ImageHeaderInfo parse(Uint8List data, ImageFormat format) {
    switch (format) {
      case ImageFormat.png:
        return parsePng(data);
      case ImageFormat.jpeg:
        return parseJpeg(data);
      case ImageFormat.gif:
        return parseGif(data);
      case ImageFormat.webp:
      case ImageFormat.unknown:
        throw FormatException('ImageHeaderParser 不处理 $format，请使用 WebpContainerParser');
    }
  }

  // ---------------------------------------------------------------------------
  // PNG
  // ---------------------------------------------------------------------------

  static ImageHeaderInfo parsePng(Uint8List d) {
    if (d.length < 33) throw const FormatException('PNG 文件过短');
    // 8 字节签名 + 4 字节长度 + 4 字节类型 = IHDR 数据从 16 开始
    final int width = _u32be(d, 16);
    final int height = _u32be(d, 20);
    final int bitDepth = d[24];
    final int colorType = d[25];

    // colorType 4/6 自带 alpha；调色板图可能通过 tRNS 提供透明色。
    bool hasAlpha = colorType == 4 || colorType == 6;
    bool hasTrns = false;

    // 扫描块寻找 tRNS
    int pos = 8;
    while (pos + 8 <= d.length) {
      final int length = _u32be(d, pos);
      final String type = String.fromCharCodes(d.sublist(pos + 4, pos + 8));
      if (type == 'tRNS') {
        hasTrns = true;
        break;
      }
      if (type == 'IDAT' || type == 'IEND') break;
      pos += 12 + length;
      if (length < 0) break;
    }
    hasAlpha = hasAlpha || hasTrns;

    return ImageHeaderInfo(
      format: ImageFormat.png,
      width: width,
      height: height,
      hasAlpha: hasAlpha,
      frameCount: 1,
      isAnimated: false,
      detail: 'colorType=$colorType bitDepth=$bitDepth'
          '${hasTrns ? ' tRNS' : ''}'
          // 带 acTL 的 APNG 属于动画，阶段 0 按静态处理，仅记录。
          '${_hasApng(d) ? ' (APNG)' : ''}',
    );
  }

  static bool _hasApng(Uint8List d) {
    int pos = 8;
    while (pos + 8 <= d.length) {
      final int length = _u32be(d, pos);
      final String type = String.fromCharCodes(d.sublist(pos + 4, pos + 8));
      if (type == 'acTL') return true;
      if (type == 'IDAT' || type == 'IEND' || length < 0) return false;
      pos += 12 + length;
    }
    return false;
  }

  // ---------------------------------------------------------------------------
  // JPEG
  // ---------------------------------------------------------------------------

  static ImageHeaderInfo parseJpeg(Uint8List d) {
    int pos = 2; // 跳过 SOI
    while (pos + 3 < d.length) {
      if (d[pos] != 0xFF) {
        pos++;
        continue;
      }
      int marker = d[pos + 1];
      // 跳过填充的 0xFF
      while (marker == 0xFF && pos + 2 < d.length) {
        pos++;
        marker = d[pos + 1];
      }
      pos += 2;

      // 无长度字段的独立标记
      if (marker >= 0xD0 && marker <= 0xD9) continue;
      if (marker == 0x01) continue;

      if (pos + 1 >= d.length) break;
      final int segmentLength = _u16be(d, pos);
      if (segmentLength < 2) break;

      final bool isSof = (marker >= 0xC0 && marker <= 0xCF) &&
          marker != 0xC4 && // DHT
          marker != 0xC8 && // JPG
          marker != 0xCC; // DAC
      if (isSof) {
        final int precision = d[pos + 2];
        final int height = _u16be(d, pos + 3);
        final int width = _u16be(d, pos + 5);
        final int components = d[pos + 7];
        return ImageHeaderInfo(
          format: ImageFormat.jpeg,
          width: width,
          height: height,
          hasAlpha: false, // 基线 JPEG 无 alpha
          frameCount: 1,
          isAnimated: false,
          detail: 'SOF${marker - 0xC0} precision=$precision components=$components',
        );
      }

      if (marker == 0xDA) break; // 到达扫描数据
      pos += segmentLength;
    }
    throw const FormatException('未找到 JPEG SOF 段，文件可能损坏');
  }

  // ---------------------------------------------------------------------------
  // GIF
  // ---------------------------------------------------------------------------

  /// 完整遍历 GIF 块，得到精确帧数与透明标记。
  static ImageHeaderInfo parseGif(Uint8List d) {
    if (d.length < 13) throw const FormatException('GIF 文件过短');
    final int width = _u16le(d, 6);
    final int height = _u16le(d, 8);
    final int packed = d[10];

    bool hasAlpha = (packed & 0x80) != 0; // 全局调色板存在则可能用到透明索引
    int pos = 13;

    if ((packed & 0x80) != 0) {
      final int gctSize = 3 * (1 << ((packed & 0x07) + 1));
      pos += gctSize;
    }

    int frameCount = 0;
    while (pos < d.length) {
      final int block = d[pos];
      if (block == 0x3B) break; // trailer
      if (block == 0x21) {
        // 扩展块：label + 子块序列
        if (pos + 1 >= d.length) break;
        final int label = d[pos + 1];
        if (label == 0xF9 && pos + 3 < d.length) {
          final int gcePacked = d[pos + 3];
          if ((gcePacked & 0x01) != 0) hasAlpha = true; // 透明色标志
        }
        pos += 2;
        pos = _skipSubBlocks(d, pos);
      } else if (block == 0x2C) {
        frameCount++;
        if (pos + 10 > d.length) break;
        final int lct = d[pos + 9];
        pos += 10;
        if ((lct & 0x80) != 0) {
          pos += 3 * (1 << ((lct & 0x07) + 1));
        }
        if (pos >= d.length) break;
        pos += 1; // LZW 最小码长
        pos = _skipSubBlocks(d, pos);
      } else {
        break; // 未知块，停止解析，保留已统计到的信息。
      }
    }

    if (frameCount == 0) frameCount = 1;

    return ImageHeaderInfo(
      format: ImageFormat.gif,
      width: width,
      height: height,
      hasAlpha: hasAlpha,
      frameCount: frameCount,
      isAnimated: frameCount > 1,
      detail: 'frames=$frameCount',
    );
  }

  static int _skipSubBlocks(Uint8List d, int pos) {
    while (pos < d.length) {
      final int size = d[pos];
      pos += 1;
      if (size == 0) break;
      pos += size;
    }
    return pos;
  }

  static int _u16be(Uint8List d, int o) => (d[o] << 8) | d[o + 1];

  static int _u16le(Uint8List d, int o) => d[o] | (d[o + 1] << 8);

  static int _u32be(Uint8List d, int o) =>
      (d[o] << 24) | (d[o + 1] << 16) | (d[o + 2] << 8) | d[o + 3];
}

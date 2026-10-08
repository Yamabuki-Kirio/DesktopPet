import 'dart:typed_data';

/// 单个 ANMF 帧头信息。
///
/// 之所以保留每帧的矩形与时长：Ace Attorney 素材的画布是 256×192，
/// 但单帧矩形只有 66×168 ~ 138×164 不等，是**带偏移的子矩形**。
/// 这是排查「动画错位 / 缺块」类显示问题的第一手数据。
class WebpFrameHeader {
  const WebpFrameHeader({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.durationMs,
    required this.blend,
    required this.dispose,
  });

  final int x;
  final int y;
  final int width;
  final int height;
  final int durationMs;

  /// true 表示该帧需要与前一帧做 alpha 混合（ANMF 的 B 位为 0）。
  final bool blend;

  /// true 表示该帧渲染后需要清空其矩形区域（ANMF 的 D 位为 1）。
  final bool dispose;

  @override
  String toString() =>
      'Frame(${width}x$height @ $x,$y, ${durationMs}ms, blend=$blend, dispose=$dispose)';
}

/// RIFF 块。
class WebpChunk {
  const WebpChunk(this.type, this.size);

  final String type;
  final int size;

  @override
  String toString() => '$type($size)';
}

/// WebP 容器解析结果。
///
/// 只解析容器结构，不做像素解码，因此开销极低（Ace Attorney 的 13 个文件合计不到 60 KB）。
/// 这些字段正是 `emotion_assets` 表需要落库的内容。
class WebpInfo {
  const WebpInfo({
    required this.width,
    required this.height,
    required this.frameCount,
    required this.isAnimated,
    required this.hasAlpha,
    required this.loopCount,
    required this.totalDurationMs,
    required this.encoding,
    required this.chunks,
    required this.frames,
  });

  /// 画布宽度。
  final int width;

  /// 画布高度。
  final int height;

  /// 帧数，单帧图为 1。
  final int frameCount;

  final bool isAnimated;

  /// 是否存在透明通道。
  final bool hasAlpha;

  /// 循环次数，0 表示无限循环。
  final int loopCount;

  /// 一轮动画的总时长（毫秒）。
  final int totalDurationMs;

  /// 编码方式：VP8 (lossy) / VP8L (lossless) / VP8+VP8L。
  final String encoding;

  /// 出现的块类型及大小（诊断用）。
  final List<WebpChunk> chunks;

  /// 各帧头部（诊断用）。
  final List<WebpFrameHeader> frames;

  bool get isLoopingInfinitely => loopCount == 0;

  /// 是否存在「帧矩形小于画布」的帧。
  bool get hasSubRectFrames => frames.any(
        (WebpFrameHeader f) => f.width < width || f.height < height,
      );

  @override
  String toString() => 'WebpInfo(${width}x$height, frames=$frameCount, animated=$isAnimated, '
      'alpha=$hasAlpha, loop=$loopCount, duration=${totalDurationMs}ms, enc=$encoding)';
}

/// 解析异常。
class WebpParseException implements Exception {
  WebpParseException(this.message);

  final String message;

  @override
  String toString() => 'Webp 解析失败: $message';
}

/// 纯 Dart 的 WebP 容器解析器。
///
/// 为什么自己写：容器头解析只需一百多行，而且我们需要第三方库通常不暴露的信息
/// （每帧矩形、混合/处置标志、循环次数）。这也避免为了统计帧数而把整图解进内存。
class WebpContainerParser {
  WebpContainerParser._();

  /// 解析完整 WebP 字节流。失败时抛出 [WebpParseException]。
  static WebpInfo parse(Uint8List data) {
    if (data.length < 12) {
      throw WebpParseException('文件过短（${data.length} 字节），不是合法 WebP');
    }
    if (_ascii(data, 0, 4) != 'RIFF') {
      throw WebpParseException('缺少 RIFF 标识');
    }
    if (_ascii(data, 8, 4) != 'WEBP') {
      throw WebpParseException('缺少 WEBP 标识');
    }

    final int riffSize = _u32(data, 4);
    if (riffSize + 8 > data.length) {
      throw WebpParseException(
        'RIFF 声明大小 ${riffSize + 8} 大于实际文件大小 ${data.length}，文件可能被截断',
      );
    }

    int pos = 12;
    int width = 0;
    int height = 0;
    int frameCount = 0;
    bool animated = false;
    bool hasAlpha = false;
    int loopCount = 0;
    int totalDuration = 0;
    bool seenVp8 = false;
    bool seenVp8L = false;
    // 顶层 VP8X/ANIM/ANMF 之外还可能是简单 WebP（直接 VP8/VP8L）。
    // 注意：动画 WebP 的编码块嵌套在 ANMF 内部，见下方 ANMF 分支的探测逻辑。
    String encoding = 'unknown';
    final List<WebpChunk> chunks = <WebpChunk>[];
    final List<WebpFrameHeader> frames = <WebpFrameHeader>[];

    while (pos + 8 <= data.length) {
      final String type = _ascii(data, pos, 4);
      final int size = _u32(data, pos + 4);
      final int payloadStart = pos + 8;

      if (size < 0 || payloadStart + size > data.length) {
        throw WebpParseException('块 $type 声明大小 $size 超出文件边界，文件已损坏');
      }

      chunks.add(WebpChunk(type, size));

      switch (type) {
        case 'VP8X':
          if (size >= 10) {
            final int flags = data[payloadStart];
            hasAlpha = hasAlpha || (flags & 0x10) != 0;
            animated = animated || (flags & 0x02) != 0;
            width = 1 + _u24(data, payloadStart + 4);
            height = 1 + _u24(data, payloadStart + 7);
          }
          break;

        case 'ANIM':
          if (size >= 6) {
            loopCount = _u16(data, payloadStart + 4);
            animated = true;
          }
          break;

        case 'ANMF':
          frameCount++;
          if (size >= 16) {
            final int fx = 2 * _u24(data, payloadStart);
            final int fy = 2 * _u24(data, payloadStart + 3);
            final int fw = 1 + _u24(data, payloadStart + 6);
            final int fh = 1 + _u24(data, payloadStart + 9);
            final int duration = _u24(data, payloadStart + 12);
            final int flags = data[payloadStart + 15];
            totalDuration += duration;
            frames.add(WebpFrameHeader(
              x: fx,
              y: fy,
              width: fw,
              height: fh,
              durationMs: duration,
              blend: (flags & 0x02) == 0,
              dispose: (flags & 0x01) != 0,
            ));

            // 动画 WebP 的 VP8/VP8L 块嵌套在 ANMF 内部（16 字节帧头之后），
            // 顶层遍历看不到，需要在这里识别一次编码方式。
            if (size >= 20) {
              final String frameCodec = _ascii(data, payloadStart + 16, 4);
              if (frameCodec == 'VP8 ') seenVp8 = true;
              if (frameCodec == 'VP8L') seenVp8L = true;
            }
          }
          break;

        case 'ALPH':
          hasAlpha = true;
          break;

        case 'VP8 ':
          seenVp8 = true;
          if (width == 0 && size >= 10) {
            // 关键帧：3 字节 frame tag + 3 字节起始码 0x9D 0x01 0x2A + 2+2 字节尺寸
            width = _u16(data, payloadStart + 6) & 0x3FFF;
            height = _u16(data, payloadStart + 8) & 0x3FFF;
          }
          break;

        case 'VP8L':
          seenVp8L = true;
          if (size >= 5) {
            final int bits = data[payloadStart + 1] |
                (data[payloadStart + 2] << 8) |
                (data[payloadStart + 3] << 16) |
                (data[payloadStart + 4] << 24);
            if (width == 0) {
              width = (bits & 0x3FFF) + 1;
              height = ((bits >> 14) & 0x3FFF) + 1;
            }
            hasAlpha = hasAlpha || ((bits >> 28) & 0x01) != 0;
          }
          break;

        default:
          break;
      }

      // RIFF 规定块大小为奇数时补一个填充字节。
      pos = payloadStart + size + (size.isOdd ? 1 : 0);
    }

    if (seenVp8 && seenVp8L) {
      encoding = 'VP8+VP8L';
    } else if (seenVp8) {
      encoding = 'VP8 (lossy)';
    } else if (seenVp8L) {
      encoding = 'VP8L (lossless)';
    }

    if (frameCount == 0) frameCount = 1;
    if (frameCount > 1) animated = true;
    if (width <= 0 || height <= 0) {
      throw WebpParseException('无法确定画布尺寸，文件可能已损坏');
    }

    return WebpInfo(
      width: width,
      height: height,
      frameCount: frameCount,
      isAnimated: animated,
      hasAlpha: hasAlpha,
      loopCount: loopCount,
      totalDurationMs: totalDuration,
      encoding: encoding,
      chunks: chunks,
      frames: frames,
    );
  }

  static int _u16(Uint8List d, int o) => d[o] | (d[o + 1] << 8);

  static int _u24(Uint8List d, int o) => d[o] | (d[o + 1] << 8) | (d[o + 2] << 16);

  static int _u32(Uint8List d, int o) =>
      d[o] | (d[o + 1] << 8) | (d[o + 2] << 16) | (d[o + 3] << 24);

  static String _ascii(Uint8List d, int o, int len) {
    if (o + len > d.length) return '';
    return String.fromCharCodes(d.sublist(o, o + len));
  }
}

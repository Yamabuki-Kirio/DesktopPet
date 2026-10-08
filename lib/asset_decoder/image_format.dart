import 'dart:typed_data';

/// 真实图片格式。
///
/// 需求 4.5 明确要求「不能只信任文件扩展名」，因此一切判断都基于 magic bytes。
enum ImageFormat {
  png('image/png', 'png'),
  webp('image/webp', 'webp'),
  jpeg('image/jpeg', 'jpg'),
  gif('image/gif', 'gif'),
  unknown('application/octet-stream', '');

  const ImageFormat(this.mimeType, this.canonicalExtension);

  final String mimeType;
  final String canonicalExtension;

  bool get isSupported =>
      this == ImageFormat.png ||
      this == ImageFormat.webp ||
      this == ImageFormat.jpeg ||
      this == ImageFormat.gif;

  /// 该格式是否可能包含动画。
  bool get canBeAnimated => this == ImageFormat.webp || this == ImageFormat.gif;
}

/// 基于 magic bytes 的格式嗅探。
class ImageFormatSniffer {
  ImageFormatSniffer._();

  static const List<int> _pngSignature = <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

  /// 从文件头字节判断真实格式。
  static ImageFormat sniff(Uint8List head) {
    if (head.length >= 8 && _startsWith(head, _pngSignature)) {
      return ImageFormat.png;
    }
    if (head.length >= 12 &&
        _ascii(head, 0, 4) == 'RIFF' &&
        _ascii(head, 8, 4) == 'WEBP') {
      return ImageFormat.webp;
    }
    if (head.length >= 3 && head[0] == 0xFF && head[1] == 0xD8 && head[2] == 0xFF) {
      return ImageFormat.jpeg;
    }
    if (head.length >= 6) {
      final String sig = _ascii(head, 0, 6);
      if (sig == 'GIF87a' || sig == 'GIF89a') {
        return ImageFormat.gif;
      }
    }
    return ImageFormat.unknown;
  }

  /// 扩展名与真实格式是否一致（允许 jpg/jpeg、webp 等别名）。
  static bool extensionMatches(String extension, ImageFormat format) {
    final String ext = extension.toLowerCase();
    switch (format) {
      case ImageFormat.png:
        return ext == 'png';
      case ImageFormat.webp:
        return ext == 'webp';
      case ImageFormat.jpeg:
        return ext == 'jpg' || ext == 'jpeg';
      case ImageFormat.gif:
        return ext == 'gif';
      case ImageFormat.unknown:
        return false;
    }
  }

  static bool _startsWith(Uint8List data, List<int> prefix) {
    for (int i = 0; i < prefix.length; i++) {
      if (data[i] != prefix[i]) return false;
    }
    return true;
  }

  static String _ascii(Uint8List data, int offset, int length) {
    if (offset + length > data.length) return '';
    return String.fromCharCodes(data.sublist(offset, offset + length));
  }
}

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

/// APK 图标与启动页资源完整性检查（需求 §5）。
///
/// 这一层是**资源契约**，不是像素艺术评审。它要挡住的是
/// "改完界面忘了换图标 / 换了图标但没接上 adaptive icon / 启动页又变回旧的"
/// 这类回归，以及旧版本遗留的蓝色头像。
void main() {
  final String root = Directory.current.path;
  final String res = p.join(root, 'android', 'app', 'src', 'main', 'res');

  File resFile(String relative) => File(p.join(res, relative));

  String readRes(String relative) => resFile(relative).readAsStringSync();

  /// PNG 尺寸（直接读 IHDR，不依赖解码库）。
  ({int width, int height}) pngSize(File file) {
    expect(file.existsSync(), isTrue, reason: '缺少资源：${file.path}');
    final List<int> bytes = file.readAsBytesSync();
    expect(bytes.length, greaterThan(24));
    int read32(int at) =>
        (bytes[at] << 24) | (bytes[at + 1] << 16) | (bytes[at + 2] << 8) | bytes[at + 3];
    return (width: read32(16), height: read32(20));
  }

  const Map<String, double> densities = <String, double>{
    'mdpi': 1.0,
    'hdpi': 1.5,
    'xhdpi': 2.0,
    'xxhdpi': 3.0,
    'xxxhdpi': 4.0,
  };

  /// 强调色（P3P 粉）。与 `PetLifeColors.accentDefault` 一致。
  const int accentR = 0xF2;
  const int accentG = 0x4D;
  const int accentB = 0x96;

  /// 旧版临时图标的蓝色（必须已被替换）。
  const int oldBlueR = 0x4A;
  const int oldBlueG = 0x7E;
  const int oldBlueB = 0xBB;

  group('adaptive icon 资源完整性', () {
    test('存在 adaptive icon 定义（前景 / 背景分层）', () {
      for (final String name in <String>['ic_launcher', 'ic_launcher_round']) {
        final File file = resFile('mipmap-anydpi-v26/$name.xml');
        expect(file.existsSync(), isTrue, reason: '缺少 $name 的 adaptive icon 定义');
        final String xml = file.readAsStringSync();
        expect(xml, contains('<adaptive-icon'));
        expect(xml, contains('@color/ic_launcher_background'), reason: '背景层必须独立');
        expect(xml, contains('@mipmap/ic_launcher_foreground'), reason: '前景层必须独立');
      }
    });

    test('背景层是白色（主色）', () {
      final String colors = readRes('values/colors.xml');
      expect(
        RegExp(r'<color name="ic_launcher_background">#FFFFFF</color>')
            .hasMatch(colors),
        isTrue,
        reason: '图标底必须是白色圆角方形（需求：白色圆角方形底）',
      );
    });

    test('传统图标 PNG 覆盖 5 档密度，尺寸为 48dp 基准', () {
      for (final MapEntry<String, double> e in densities.entries) {
        final int expected = (48 * e.value).round();
        for (final String name in <String>['ic_launcher', 'ic_launcher_round']) {
          final ({int width, int height}) size =
              pngSize(resFile('mipmap-${e.key}/$name.png'));
          expect(size.width, expected, reason: '${e.key}/$name 宽度不对');
          expect(size.height, expected, reason: '${e.key}/$name 高度不对');
        }
      }
    });

    test('前景层 PNG 覆盖 5 档密度，尺寸为 108dp 画布', () {
      for (final MapEntry<String, double> e in densities.entries) {
        final int expected = (108 * e.value).round();
        final ({int width, int height}) size =
            pngSize(resFile('mipmap-${e.key}/ic_launcher_foreground.png'));
        expect(size.width, expected, reason: '${e.key} 前景层宽度不对');
        expect(size.height, expected, reason: '${e.key} 前景层高度不对');
      }
    });
  });

  group('图标内容（原创图形：粉色放射环 + 中央爪印）', () {
    /// 统计一张图里"接近给定颜色"的像素数。
    int countNear(img.Image image, int r, int g, int b, {int tolerance = 24}) {
      int count = 0;
      for (int y = 0; y < image.height; y += 2) {
        for (int x = 0; x < image.width; x += 2) {
          final img.Pixel pixel = image.getPixel(x, y);
          if (pixel.a < 128) continue;
          if ((pixel.r - r).abs() <= tolerance &&
              (pixel.g - g).abs() <= tolerance &&
              (pixel.b - b).abs() <= tolerance) {
            count++;
          }
        }
      }
      return count;
    }

    test('图标使用强调色粉，且不含旧版临时图标的蓝色', () {
      final img.Image icon =
          img.decodePng(resFile('mipmap-xxxhdpi/ic_launcher.png').readAsBytesSync())!;
      final int pink = countNear(icon, accentR, accentG, accentB);
      final int oldBlue = countNear(icon, oldBlueR, oldBlueG, oldBlueB);
      expect(pink, greaterThan(icon.width), reason: '图标里几乎没有强调色粉色');
      expect(oldBlue, 0, reason: '仍然残留旧版蓝色头像的蓝色');
    });

    test('前景层是分层的透明底（四角必须透明）', () {
      final img.Image fg = img.decodePng(
        resFile('mipmap-xxxhdpi/ic_launcher_foreground.png').readAsBytesSync(),
      )!;
      for (final (int x, int y) in <(int, int)>[
        (0, 0),
        (fg.width - 1, 0),
        (0, fg.height - 1),
        (fg.width - 1, fg.height - 1),
      ]) {
        expect(fg.getPixel(x, y).a, 0,
            reason: '前景层四角必须透明，否则圆形/水滴形启动器会看到方块');
      }
    });

    test('前景层内容落在安全圆内（不同启动器遮罩都不会裁掉爪印）', () {
      final img.Image fg = img.decodePng(
        resFile('mipmap-xxxhdpi/ic_launcher_foreground.png').readAsBytesSync(),
      )!;
      final double cx = fg.width / 2;
      final double cy = fg.height / 2;
      // adaptive icon 的安全区：以 108dp 画布中心为圆心、直径 66dp 的圆。
      final double safeRadius = (66.0 / 108.0) * fg.width / 2;
      double maxRadius = 0;
      for (int y = 0; y < fg.height; y++) {
        for (int x = 0; x < fg.width; x++) {
          if (fg.getPixel(x, y).a < 16) continue;
          final double r = math.sqrt(
            math.pow(x - cx, 2) + math.pow(y - cy, 2),
          );
          if (r > maxRadius) maxRadius = r;
        }
      }
      expect(maxRadius, lessThanOrEqualTo(safeRadius + 1),
          reason: '前景内容超出了 66dp 安全圆，会被启动器裁掉');
    });
  });

  group('启动页', () {
    test('传统路径：白色背景 + 居中图标 + PetLife + 粉色加载线', () {
      for (final String path in <String>[
        'drawable/launch_background.xml',
        'drawable-v21/launch_background.xml',
      ]) {
        final String xml = readRes(path);
        expect(xml, contains('@color/splash_background'), reason: '$path 背景不是暖白');
        expect(xml, contains('@drawable/splash_petlife'), reason: '$path 没有放启动页位图');
        expect(xml.contains('?android:colorBackground'), isFalse,
            reason: '$path 在深色系统下会变黑，违反"白色启动页"');
      }
      for (final MapEntry<String, double> e in densities.entries) {
        final ({int width, int height}) size =
            pngSize(resFile('drawable-${e.key}/splash_petlife.png'));
        expect(size.height, greaterThan(size.width),
            reason: '启动页位图应为竖向构图（图标在上、文字与加载线在下）');
      }
    });

    test('Android 12+：系统启动页使用新图标 + 品牌图 + 200ms 动画', () {
      for (final String path in <String>[
        'values-v31/styles.xml',
        'values-night-v31/styles.xml',
      ]) {
        final String xml = readRes(path);
        expect(xml, contains('android:windowSplashScreenBackground'), reason: path);
        expect(xml, contains('@color/splash_background'), reason: path);
        expect(xml, contains('android:windowSplashScreenAnimatedIcon'), reason: path);
        expect(xml, contains('@drawable/splash_icon'), reason: path);
        expect(xml, contains('android:windowSplashScreenBrandingImage'), reason: path);
        expect(xml, contains('@drawable/splash_branding'), reason: path);
        // 不播放长时间动画。
        expect(
          RegExp(r'windowSplashScreenAnimationDuration">(\d+)<').firstMatch(xml),
          isNotNull,
        );
        final int duration = int.parse(
          RegExp(r'windowSplashScreenAnimationDuration">(\d+)<').firstMatch(xml)!.group(1)!,
        );
        expect(duration, lessThanOrEqualTo(300));
      }
    });

    test('启动页图标与品牌图覆盖 5 档密度，尺寸分别为 288dp / 200×80dp', () {
      for (final MapEntry<String, double> e in densities.entries) {
        final ({int width, int height}) icon =
            pngSize(resFile('drawable-${e.key}/splash_icon.png'));
        expect(icon.width, (288 * e.value).round());
        expect(icon.height, (288 * e.value).round());

        final ({int width, int height}) branding =
            pngSize(resFile('drawable-${e.key}/splash_branding.png'));
        expect(branding.width, (200 * e.value).round());
        expect(branding.height, (80 * e.value).round());
      }
    });

    test('启动页图标的内容同样落在安全圆内（圆形遮罩不会被裁）', () {
      final img.Image icon = img.decodePng(
        resFile('drawable-xxxhdpi/splash_icon.png').readAsBytesSync(),
      )!;
      final double cx = icon.width / 2;
      final double cy = icon.height / 2;
      // 系统只显示 288dp 画布的中央 2/3（192dp）。
      final double visibleRadius = (192.0 / 288.0) * icon.width / 2;
      for (int y = 0; y < icon.height; y += 2) {
        for (int x = 0; x < icon.width; x += 2) {
          if (icon.getPixel(x, y).a < 16) continue;
          final double r = math.sqrt(math.pow(x - cx, 2) + math.pow(y - cy, 2));
          expect(r, lessThanOrEqualTo(visibleRadius + 1),
              reason: '启动页图标内容超出系统可见区域，会被裁掉');
        }
      }
    });
  });

  group('清单与可复现性', () {
    test('AndroidManifest 同时声明 icon 与 roundIcon', () {
      final String manifest = File(
        p.join(root, 'android', 'app', 'src', 'main', 'AndroidManifest.xml'),
      ).readAsStringSync();
      expect(manifest, contains('android:icon="@mipmap/ic_launcher"'));
      expect(manifest, contains('android:roundIcon="@mipmap/ic_launcher_round"'));
    });

    test('图标生成脚本可复现（提交在 tools/ 下）', () {
      final File script = File(p.join(root, 'tools', 'make_app_icon.py'));
      expect(script.existsSync(), isTrue, reason: '图标必须可复现，脚本要一起提交');
      final String source = script.readAsStringSync();
      expect(source, contains('ic_launcher_foreground'));
      expect(source, contains('splash_petlife'));
      expect(source, contains('splash_icon'));
      expect(source, contains('splash_branding'));
    });
  });
}

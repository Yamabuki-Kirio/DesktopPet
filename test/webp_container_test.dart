import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:petlife/asset_decoder/asset_validator.dart';
import 'package:petlife/asset_decoder/image_format.dart';
import 'package:petlife/asset_decoder/webp_container.dart';
import 'package:petlife/core/result.dart';

import 'filename_parser_test.dart' show locateAceAttorneyFolder;

/// 预期帧数（由独立的纯 Python 容器解析脚本交叉验证得到）。
const Map<String, int> kExpectedFrameCounts = <String, int>{
  'Maya_Angry_1.webp': 9,
  'Maya_Bench_Exasperated_1.webp': 5,
  'Maya_Bench_Thinking_1.webp': 15,
  'Maya_Cheerful_1.webp': 9,
  'Maya_Confident_1.webp': 9,
  'Maya_Crying_1.webp': 5,
  'Maya_Disheartened_1.webp': 5,
  'Maya_Excited_1.webp': 9,
  'Maya_Nod.webp': 7,
  'Maya_Shocked.webp': 12,
  'Maya_Surprised_1.webp': 13,
  'Maya_Thinking_1.webp': 9,
  'Maya_Worried_1.webp': 9,
};

void main() {
  group('WebP 容器解析', () {
    final Directory? folder = locateAceAttorneyFolder();

    test('全部 13 个文件都被识别为 256x192 的多帧动画且带透明通道', () {
      if (folder == null) {
        markTestSkipped('未找到 Ace Attorney 素材目录');
        return;
      }
      final List<File> files = folder
          .listSync()
          .whereType<File>()
          .where((File f) => f.path.toLowerCase().endsWith('.webp'))
          .toList()
        ..sort((File a, File b) => a.path.compareTo(b.path));

      expect(files.length, 13);

      for (final File f in files) {
        final String name = p.basename(f.path);
        final Uint8List bytes = f.readAsBytesSync();

        // 真实格式必须由 magic bytes 判定
        expect(ImageFormatSniffer.sniff(bytes), ImageFormat.webp, reason: name);

        final WebpInfo info = WebpContainerParser.parse(bytes);

        expect(info.width, 256, reason: '$name 画布宽度');
        expect(info.height, 192, reason: '$name 画布高度');
        expect(info.isAnimated, isTrue, reason: '$name 应被识别为动态图，而不是静态图');
        expect(info.frameCount, greaterThan(1), reason: name);
        expect(info.frameCount, kExpectedFrameCounts[name], reason: '$name 帧数');
        expect(info.hasAlpha, isTrue, reason: '$name 应带透明通道');
        expect(info.loopCount, 0, reason: '$name 应为无限循环');
        expect(info.totalDurationMs, greaterThan(0), reason: '$name 动画总时长');
        expect(info.frames.length, info.frameCount, reason: '$name 帧头数量');

        // 这正是 Ace Attorney 素材的关键特征：帧矩形小于画布，需要正确的帧合成。
        expect(info.hasSubRectFrames, isTrue,
            reason: '$name 的帧矩形应小于画布（需要解码器做帧合成）');

        // 帧数应落在需求描述的 5~15 区间内
        expect(info.frameCount, inInclusiveRange(5, 15), reason: name);
      }
    });

    test('损坏文件不会抛异常，而是返回失败结果', () async {
      const DefaultAssetValidator validator = DefaultAssetValidator();
      final Directory tmp = Directory.systemTemp.createTempSync('petlife_test');
      addTearDown(() => tmp.deleteSync(recursive: true));

      // 1) 扩展名伪造：内容是 PNG，名字是 webp
      final File fake = File(p.join(tmp.path, 'fake.webp'));
      // 最小合法 PNG 头（这里只关心 magic bytes 判定，因此不需要完整 PNG）
      fake.writeAsBytesSync(<int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0]);
      final Result<AssetProbe> r1 = await validator.probe(fake, declaredExtension: 'webp');
      expect(r1.isErr, isTrue);
      expect(r1.failureOrNull!.kind, FailureKind.formatMismatch);

      // 2) 随机字节
      final File junk = File(p.join(tmp.path, 'junk.png'));
      junk.writeAsBytesSync(List<int>.generate(64, (int i) => i * 7 % 256));
      final Result<AssetProbe> r2 = await validator.probe(junk, declaredExtension: 'png');
      expect(r2.isErr, isTrue);
      expect(r2.failureOrNull!.kind, FailureKind.undecodable);

      // 3) 空文件
      final File empty = File(p.join(tmp.path, 'empty.png'));
      empty.writeAsBytesSync(<int>[]);
      final Result<AssetProbe> r3 = await validator.probe(empty, declaredExtension: 'png');
      expect(r3.isErr, isTrue);
      expect(r3.failureOrNull!.kind, FailureKind.emptyContent);

      // 4) 截断的 WebP：RIFF 头声明的大小远大于实际
      final File truncated = File(p.join(tmp.path, 'truncated.webp'));
      final List<int> header = <int>[
        0x52, 0x49, 0x46, 0x46, // RIFF
        0xFF, 0xFF, 0x00, 0x00, // 声明的尺寸（故意过大）
        0x57, 0x45, 0x42, 0x50, // WEBP
      ];
      truncated.writeAsBytesSync(header);
      final Result<AssetProbe> r4 = await validator.probe(truncated, declaredExtension: 'webp');
      expect(r4.isErr, isTrue);
    });
  });
}

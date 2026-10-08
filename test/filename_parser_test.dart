import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:petlife/asset_import/filename_parser.dart';

/// 定位工作区里的 Ace Attorney 素材目录（存在则跑「真实素材」用例）。
Directory? locateAceAttorneyFolder() {
  Directory dir = Directory.current;
  for (int i = 0; i < 4; i++) {
    final Directory candidate = Directory(p.join(dir.path, 'Ace Attorney'));
    if (candidate.existsSync()) return candidate;
    dir = dir.parent;
  }
  return null;
}

void main() {
  const AssetFilenameParser parser = AssetFilenameParser();

  group('文件名解析规则（需求 4.2）', () {
    test('带序号：角色_情绪_序号', () {
      final ParsedAssetName r = parser.parse('Maya_Angry_1.webp', packName: 'Ace Attorney');
      expect(r.packName, 'Ace Attorney');
      expect(r.characterName, 'Maya');
      expect(r.emotionName, 'Angry');
      expect(r.variantName, '1');
      expect(r.extension, 'webp');
      expect(r.isDefaultVariant, isFalse);
    });

    test('情绪名包含下划线', () {
      final ParsedAssetName r =
          parser.parse('Maya_Bench_Thinking_1.webp', packName: 'Ace Attorney');
      expect(r.characterName, 'Maya');
      expect(r.emotionName, 'Bench_Thinking');
      expect(r.variantName, '1');
    });

    test('无序号时变体为 default', () {
      final ParsedAssetName r = parser.parse('Maya_Nod.webp', packName: 'Ace Attorney');
      expect(r.characterName, 'Maya');
      expect(r.emotionName, 'Nod');
      expect(r.variantName, defaultVariantName);
      expect(r.isDefaultVariant, isTrue);
    });

    test('作品包名取自文件夹名', () {
      final ParsedAssetName r = parser.parsePath(
        p.join('D:', 'assets', 'Ace Attorney', 'Maya_Shocked.webp'),
      );
      expect(r.packName, 'Ace Attorney');
      expect(r.characterName, 'Maya');
      expect(r.emotionName, 'Shocked');
    });

    test('完全没有下划线时，整名视作角色名', () {
      final ParsedAssetName r = parser.parse('Maya.png', packName: 'Pack');
      expect(r.characterName, 'Maya');
      expect(r.emotionName, fallbackEmotionName);
      expect(r.variantName, defaultVariantName);
    });

    test('只有序号没有情绪时，情绪回退为 default', () {
      final ParsedAssetName r = parser.parse('Maya_2.webp', packName: 'Pack');
      expect(r.characterName, 'Maya');
      expect(r.emotionName, fallbackEmotionName);
      expect(r.variantName, '2');
    });

    test('只把最后一段纯数字当作变体', () {
      final ParsedAssetName r = parser.parse('Maya_Angry_2_3.webp', packName: 'Pack');
      expect(r.emotionName, 'Angry_2');
      expect(r.variantName, '3');
    });

    test('支持前导零序号', () {
      final ParsedAssetName r = parser.parse('Maya_Angry_01.webp', packName: 'Pack');
      expect(r.variantName, '01');
      expect(r.emotionName, 'Angry');
    });

    test('多余下划线不会产生空情绪名', () {
      final ParsedAssetName r = parser.parse('Maya__Angry_1.webp', packName: 'Pack');
      expect(r.emotionName, 'Angry');
      expect(r.variantName, '1');
    });

    test('扩展名统一转小写', () {
      final ParsedAssetName r = parser.parse('Maya_Angry_1.WEBP', packName: 'Pack');
      expect(r.extension, 'webp');
    });

    test('规范化文件名可反向构造且无序号文件保持无序号', () {
      expect(
        parser.parse('Maya_Nod.webp', packName: 'P').canonicalFileName(),
        'Maya_Nod.webp',
      );
      expect(
        parser.parse('Maya_Bench_Thinking_1.webp', packName: 'P').canonicalFileName(),
        'Maya_Bench_Thinking_1.webp',
      );
    });
  });

  group('真实素材文件夹（Ace Attorney）', () {
    final Directory? folder = locateAceAttorneyFolder();

    test('目录存在（不存在则跳过）', () {
      if (folder == null) {
        markTestSkipped('未找到 Ace Attorney 素材目录，跳过真实素材用例');
        return;
      }
      expect(folder.existsSync(), isTrue);
    });

    test('13 个文件全部解析为同一作品包、同一角色，情绪不重复且变体正确', () {
      if (folder == null) {
        markTestSkipped('未找到 Ace Attorney 素材目录');
        return;
      }
      final List<String> files = folder
          .listSync()
          .whereType<File>()
          .map((File f) => p.basename(f.path))
          .where((String n) => n.toLowerCase().endsWith('.webp'))
          .toList()
        ..sort();

      expect(files.length, 13, reason: '素材目录应包含 13 个 WebP 文件');

      final List<ParsedAssetName> parsed =
          files.map((String f) => parser.parse(f, packName: 'Ace Attorney')).toList();

      // 作品包统一
      expect(parsed.every((ParsedAssetName r) => r.packName == 'Ace Attorney'), isTrue);
      // 角色统一为 Maya
      expect(parsed.every((ParsedAssetName r) => r.characterName == 'Maya'), isTrue);
      // 情绪名互不重复
      final Set<String> emotions = parsed.map((ParsedAssetName r) => r.emotionName).toSet();
      expect(emotions.length, 13);
      // 只有 Maya_Nod 与 Maya_Shocked 没有序号
      final List<String> noVariant = parsed
          .where((ParsedAssetName r) => r.isDefaultVariant)
          .map((ParsedAssetName r) => r.sourceFileName)
          .toList()
        ..sort();
      expect(noVariant, <String>['Maya_Nod.webp', 'Maya_Shocked.webp']);
    });
  });
}

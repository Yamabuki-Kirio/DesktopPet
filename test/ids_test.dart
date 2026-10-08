import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:petlife/asset_import/filename_parser.dart';
import 'package:petlife/core/ids.dart';
import 'package:uuid/uuid.dart';

import 'filename_parser_test.dart' show locateAceAttorneyFolder;

/// UUID v5 的严格形态：
/// - 第 3 段首字符固定为 `5`（version）；
/// - 第 4 段首字符落在 `8/9/a/b`（variant）。
final RegExp _uuidV5Pattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

/// 断言 [value] 是合法 UUID v5。
///
/// 两层校验缺一不可：
/// - 自有正则锁定 version=5 / variant 位（`Uuid.isValidUUID` 只要求 version ∈ 0-8，不够严）；
/// - `Uuid.isValidUUID` 用包自身的严格模式交叉验证（避免正则写错）。
void expectUuidV5(String value, {String? reason}) {
  expect(value.length, 36, reason: reason);
  expect(
    _uuidV5Pattern.hasMatch(value),
    isTrue,
    reason: '${reason ?? ''} 不是合法 UUID v5: $value',
  );
  expect(
    Uuid.isValidUUID(fromString: value),
    isTrue,
    reason: '${reason ?? ''} 未通过 uuid 包的严格校验: $value',
  );
}

void main() {
  // 各生成器的固定输入，供「确定性 / 唯一性」两组用例共用。
  const String owner = 'local.default';
  const String packName = 'Ace Attorney';
  const String otherPack = 'Another Pack';
  const String character = 'Maya';
  const String emotion = 'Angry';
  const String systemState = 'focused';

  group('命名空间（缺陷 D-01 回归护栏）', () {
    test('Ids.namespace 本身必须是合法 UUID', () {
      // D-01 的根因就是这里非法的 version 位（第三段首字符为 `d`）。
      // 这条断言是防止它再次被写成非法值的唯一自动化防线。
      expect(
        Ids.isNamespaceValid,
        isTrue,
        reason: 'Ids.namespace 非法会让 uuid v5 抛 FormatException，导致全部导入失败：'
            '${Ids.namespace}',
      );
      expect(Uuid.isValidUUID(fromString: Ids.namespace), isTrue);
    });

    test('assertNamespaceValid 在当前常量下不抛异常', () {
      expect(Ids.assertNamespaceValid, returnsNormally);
    });
  });

  group('四个 ID 生成器都不抛异常', () {
    test('Ids.packId()', () {
      expect(() => Ids.packId(owner, packName), returnsNormally);
    });

    test('Ids.characterId()', () {
      expect(() => Ids.characterId(Ids.packId(owner, packName), character), returnsNormally);
    });

    test('Ids.assetId()', () {
      final String characterId = Ids.characterId(Ids.packId(owner, packName), character);
      expect(() => Ids.assetId(characterId, emotion, '1'), returnsNormally);
    });

    test('Ids.stateMappingId()', () {
      final String characterId = Ids.characterId(Ids.packId(owner, packName), character);
      expect(() => Ids.stateMappingId(characterId, systemState, 0), returnsNormally);
    });

    test('整条 ID 链可以串联生成（导入路径实际调用顺序）', () {
      expect(() {
        final String packId = Ids.packId(owner, packName);
        final String characterId = Ids.characterId(packId, character);
        final String assetId = Ids.assetId(characterId, emotion, '1');
        final String mappingId = Ids.stateMappingId(characterId, systemState, 0);
        expect(<String>{packId, characterId, assetId, mappingId}.length, 4);
      }, returnsNormally);
    });
  });

  group('确定性：相同输入始终生成相同 ID', () {
    test('packId', () {
      expect(Ids.packId(owner, packName), Ids.packId(owner, packName));
    });

    test('characterId', () {
      final String packId = Ids.packId(owner, packName);
      expect(Ids.characterId(packId, character), Ids.characterId(packId, character));
    });

    test('assetId', () {
      final String characterId = Ids.characterId(Ids.packId(owner, packName), character);
      expect(
        Ids.assetId(characterId, emotion, '1'),
        Ids.assetId(characterId, emotion, '1'),
      );
    });

    test('stateMappingId', () {
      final String characterId = Ids.characterId(Ids.packId(owner, packName), character);
      expect(
        Ids.stateMappingId(characterId, systemState, 2),
        Ids.stateMappingId(characterId, systemState, 2),
      );
    });

    test('大小写不敏感：重复扫描同名文件夹不会产生新 ID', () {
      // 这是「重复导入幂等」的前提：Windows 文件系统大小写不敏感，
      // 同一个包/角色/情绪不该因为大小写差异拿到两个 ID。
      expect(Ids.packId(owner, 'Ace Attorney'), Ids.packId(owner, 'ace attorney'));
      final String upperPack = Ids.packId(owner, packName);
      expect(Ids.characterId(upperPack, 'MAYA'), Ids.characterId(upperPack, 'maya'));
      final String characterId = Ids.characterId(upperPack, character);
      expect(
        Ids.assetId(characterId, 'ANGRY', '1'),
        Ids.assetId(characterId, 'angry', '1'),
      );
    });

    test('确定性 ID 与随机会话 ID 不同（random 不参与持久化标识）', () {
      final String deterministicId = Ids.packId(owner, packName);
      expect(Ids.random(), isNot(deterministicId));
    });
  });

  group('唯一性：不同输入生成不同 ID', () {
    test('packId 对 ownerId 与 packName 都敏感', () {
      expect(
        Ids.packId(owner, packName),
        isNot(Ids.packId('another.owner', packName)),
      );
      expect(
        Ids.packId(owner, packName),
        isNot(Ids.packId(owner, otherPack)),
      );
    });

    test('characterId 对 packId 与角色名都敏感', () {
      final String packId = Ids.packId(owner, packName);
      final String otherPackId = Ids.packId(owner, otherPack);
      expect(
        Ids.characterId(packId, character),
        isNot(Ids.characterId(otherPackId, character)),
      );
      expect(
        Ids.characterId(packId, character),
        isNot(Ids.characterId(packId, 'Phoenix')),
      );
    });

    test('assetId 对角色、情绪、变体三个维度都敏感', () {
      final String characterId = Ids.characterId(Ids.packId(owner, packName), character);
      final String other = Ids.characterId(Ids.packId(owner, packName), 'Phoenix');
      expect(Ids.assetId(characterId, emotion, '1'), isNot(Ids.assetId(other, emotion, '1')));
      expect(Ids.assetId(characterId, emotion, '1'), isNot(Ids.assetId(characterId, 'Sad', '1')));
      expect(Ids.assetId(characterId, emotion, '1'), isNot(Ids.assetId(characterId, emotion, '2')));
    });

    test('stateMappingId 对系统状态与序号都敏感', () {
      final String characterId = Ids.characterId(Ids.packId(owner, packName), character);
      expect(
        Ids.stateMappingId(characterId, systemState, 0),
        isNot(Ids.stateMappingId(characterId, 'idle', 0)),
      );
      expect(
        Ids.stateMappingId(characterId, systemState, 0),
        isNot(Ids.stateMappingId(characterId, systemState, 1)),
      );
    });

    test('不同 ID 类型之间不会碰撞（前缀隔离）', () {
      // 四类 ID 都走同一个命名空间，靠 parts[0] 的 'pack'/'character'/'asset'/'mapping'
      // 做域隔离。这里用「同一组字符串」去撞，确认前缀确实起作用。
      const String a = 'same';
      const String b = 'same';
      final Set<String> ids = <String>{
        Ids.packId(a, b),
        Ids.characterId(a, b),
        Ids.assetId(a, b, b),
        Ids.stateMappingId(a, b, 0),
      };
      expect(ids.length, 4, reason: '四类 ID 出现碰撞，前缀隔离失效');
    });

    test('parts 之间用 NUL 连接，不会因为拼接产生歧义碰撞', () {
      // 若用普通字符串拼接，['ab','c'] 与 ['a','bc'] 会得到同一个 ID。
      expect(
        Ids.deterministic(<String>['ab', 'c']),
        isNot(Ids.deterministic(<String>['a', 'bc'])),
      );
    });
  });

  group('输出形态：全部是合法 UUID v5', () {
    test('四个生成器的输出都通过 v5 校验', () {
      final String packId = Ids.packId(owner, packName);
      expectUuidV5(packId, reason: 'packId');
      final String characterId = Ids.characterId(packId, character);
      expectUuidV5(characterId, reason: 'characterId');
      expectUuidV5(Ids.assetId(characterId, emotion, '1'), reason: 'assetId');
      expectUuidV5(Ids.stateMappingId(characterId, systemState, 0), reason: 'stateMappingId');
    });

    test('deterministic() 的输出也是合法 UUID v5', () {
      expectUuidV5(Ids.deterministic(<String>['anything', 'at', 'all']));
    });

    test('空 parts 也能生成合法 v5（不抛异常）', () {
      expect(() => Ids.deterministic(const <String>[]), returnsNormally);
      expectUuidV5(Ids.deterministic(const <String>[]));
    });
  });

  group('真实素材：Ace Attorney 的 13 个文件名', () {
    const AssetFilenameParser parser = AssetFilenameParser();
    final Directory? folder = locateAceAttorneyFolder();

    test('13 个文件全部生成唯一且合法的 assetId', () {
      if (folder == null) {
        markTestSkipped('未找到 Ace Attorney 素材目录，跳过真实素材用例');
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

      // 复刻导入器的 ID 生成顺序：pack -> character -> asset。
      final String packId = Ids.packId(owner, 'Ace Attorney');
      final String characterId = Ids.characterId(packId, 'Maya');

      final List<String> assetIds = <String>[];
      for (final String file in files) {
        final ParsedAssetName parsed = parser.parse(file, packName: 'Ace Attorney');
        final String id = Ids.assetId(characterId, parsed.emotionName, parsed.variantName);
        expectUuidV5(id, reason: file);
        assetIds.add(id);
      }

      // 13 个素材必须是 13 个不同 ID，否则会在库里互相覆盖。
      expect(assetIds.toSet().length, 13, reason: '存在重复 assetId，素材会互相覆盖');
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:petlife/activity_tracking/activity_state_mapper.dart';
import 'package:petlife/platform/overlay_state_mapping.dart';
import 'package:petlife/state_engine/system_state.dart';

/// Phase 4C-6A：状态配置快照（自动开关 + 规则表）的序列化与去重语义。
///
/// 这些字段决定了"原生在 Flutter 被划掉后能不能继续正确联动"，
/// 因此必须逐条钉住：字段名、默认值、以及**去重签名是否覆盖它们**。
///
/// `buildOverlayStateMapping` 的入参透传由 `overlay_pet_controller_test.dart`
/// 的端到端用例覆盖，这里只钉"契约本身"。
void main() {
  OverlayStateMapping build({
    bool automatic = true,
    Map<String, String> categoryRules = const <String, String>{},
    Map<String, String> appOverrides = const <String, String>{},
    int revision = 1,
    String? defaultStateKey = 'default',
  }) =>
      OverlayStateMapping(
        revision: revision,
        characterId: 'char-1',
        automaticStateEnabled: automatic,
        defaultStateKey: defaultStateKey,
        categoryStateRules: categoryRules,
        appStateOverrides: appOverrides,
      );

  group('快照新字段', () {
    test('默认值：自动开启、无规则表、不传默认状态', () {
      const OverlayStateMapping mapping =
          OverlayStateMapping(revision: 1, characterId: 'char-1');
      expect(mapping.schemaVersion, OverlayStateMapping.schemaVersionValue);
      expect(mapping.automaticStateEnabled, isTrue);
      expect(mapping.categoryStateRules, isEmpty);
      expect(mapping.appStateOverrides, isEmpty);
      expect(mapping.defaultStateKey, isNull);
    });

    test('三个字段都进 JSON，字段名与原生解析一致', () {
      final Map<String, Object?> json = build(
        automatic: false,
        categoryRules: <String, String>{'browser': 'focused'},
        appOverrides: <String, String>{'org.telegram.messenger': 'happy'},
      ).toJson();
      expect(json['automaticEnabled'], isFalse);
      expect(json['defaultStateKey'], 'default');
      expect(json['categoryRules'], <String, Object?>{'browser': 'focused'});
      expect(json['appOverrides'], <String, Object?>{'org.telegram.messenger': 'happy'});
    });

    test('withRevision 保留全部配置（只换版本号）', () {
      final OverlayStateMapping mapping = build(
        automatic: false,
        categoryRules: <String, String>{'browser': 'focused'},
      );
      final OverlayStateMapping bumped = mapping.withRevision(9);
      expect(bumped.revision, 9);
      expect(bumped.automaticStateEnabled, isFalse);
      expect(bumped.categoryStateRules, mapping.categoryStateRules);
      expect(bumped.defaultStateKey, mapping.defaultStateKey);
    });
  });

  group('去重签名', () {
    test('只关掉自动开关也必须改变签名（否则原生永远收不到）', () {
      expect(build().signature, isNot(build(automatic: false).signature));
    });

    test('规则表 / 默认状态变化同样改变签名', () {
      expect(
        build().signature,
        isNot(build(categoryRules: <String, String>{'browser': 'focused'}).signature),
      );
      expect(
        build().signature,
        isNot(build(appOverrides: <String, String>{'a.b': 'happy'}).signature),
      );
      expect(build().signature, isNot(build(defaultStateKey: 'away').signature));
    });

    test('内容完全相同时签名稳定（不会每次推送都换 revision）', () {
      final OverlayStateMapping a =
          build(categoryRules: <String, String>{'b': 'focused', 'a': 'gaming'});
      final OverlayStateMapping b =
          build(categoryRules: <String, String>{'a': 'gaming', 'b': 'focused'});
      expect(a.signature, b.signature, reason: '规则表顺序不应影响签名');
    });
  });

  group('规则表契约', () {
    test('下发的分类规则值全部是既有状态 wire 值', () {
      final Set<String> known =
          SystemState.values.map((SystemState s) => s.wireName).toSet();
      for (final String value in ActivityStateMapper.categoryStateRules.values) {
        expect(known, contains(value));
      }
    });

    test('分类规则的键全部是既有分类 wire 值', () {
      const Set<String> known = <String>{
        'development',
        'productivity',
        'gaming',
        'social',
        'entertainment',
        'browser',
        'system',
        'other',
      };
      for (final String key in ActivityStateMapper.categoryStateRules.keys) {
        expect(known, contains(key));
      }
    });

    test('说明文案覆盖规则表里的每一个分类', () {
      for (final String key in ActivityStateMapper.categoryStateRules.keys) {
        expect(ActivityStateMapper.categoryStateNotes[key], isNotNull,
            reason: '分类 $key 缺少中文说明');
      }
    });
  });
}

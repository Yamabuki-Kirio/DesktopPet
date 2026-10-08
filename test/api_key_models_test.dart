import 'package:flutter_test/flutter_test.dart';
import 'package:petlife/sync/models/api_key_models.dart';

/// AI 数据访问密钥模型解析（纯逻辑，无网络无数据库）。
void main() {
  group('ApiKeySummary', () {
    test('解析服务端字段', () {
      final ApiKeySummary key = ApiKeySummary.fromJson(<String, Object?>{
        'id': 'key-1',
        'name': 'AstrBot',
        'key_prefix': 'plk_abcd1234',
        'scopes': <Object?>['stats:read'],
        'created_at': '2026-09-28T08:00:00Z',
        'last_used_at': null,
        'revoked_at': null,
        'is_active': true,
      });

      expect(key.id, 'key-1');
      expect(key.name, 'AstrBot');
      expect(key.keyPrefix, 'plk_abcd1234');
      expect(key.scopes, <String>['stats:read']);
      expect(key.createdAt, DateTime.utc(2026, 9, 28, 8));
      expect(key.lastUsedAt, isNull);
      expect(key.revokedAt, isNull);
      expect(key.isActive, isTrue);
      expect(key.scopesLabel, '只读统计');
    });

    test('已撤销的密钥 isActive 为 false', () {
      final ApiKeySummary key = ApiKeySummary.fromJson(<String, Object?>{
        'id': 'key-2',
        'name': '旧密钥',
        'key_prefix': 'plk_00001111',
        'scopes': <Object?>['stats:read'],
        'created_at': '2026-09-28T08:00:00Z',
        'revoked_at': '2026-09-28T09:00:00Z',
      });
      expect(key.isActive, isFalse);
      expect(key.revokedAt, DateTime.utc(2026, 9, 28, 9));
    });

    test('缺少 scopes / 字段时给安全默认值', () {
      final ApiKeySummary key = ApiKeySummary.fromJson(<String, Object?>{});
      expect(key.scopes, isEmpty);
      expect(key.scopesLabel, '无权限');
      expect(key.createdAt, isNull);
      expect(key.isActive, isTrue, reason: '没有撤销时间即视为有效');
    });

    test('从 items 信封解析列表，忽略脏数据', () {
      final List<ApiKeySummary> list = ApiKeySummary.listFromEnvelope(
        <String, Object?>{
          'items': <Object?>[
            <String, Object?>{'id': 'a', 'name': 'A'},
            <String, Object?>{'id': 'b', 'name': 'B'},
          ],
          'total': 2,
        },
      );
      expect(list.map((ApiKeySummary k) => k.id), <String>['a', 'b']);
    });

    test('缺少 items 时返回空列表（不抛异常）', () {
      expect(ApiKeySummary.listFromEnvelope(<String, Object?>{}), isEmpty);
      expect(
        ApiKeySummary.listFromEnvelope(<String, Object?>{'items': 'nonsense'}),
        isEmpty,
      );
    });

    test('toString 只出现前缀，不出现完整密钥', () {
      const ApiKeySummary key = ApiKeySummary(
        id: 'key-1',
        name: 'AstrBot',
        keyPrefix: 'plk_abcd1234',
        scopes: <String>['stats:read'],
      );
      expect(key.toString(), contains('plk_abcd1234'));
      expect(key.toString(), contains('active=true'));
    });
  });

  group('ApiKeyCreated', () {
    test('解析明文密钥与随附字段', () {
      final ApiKeyCreated created = ApiKeyCreated.fromJson(<String, Object?>{
        'id': 'key-1',
        'name': 'AstrBot',
        'key_prefix': 'plk_abcd1234',
        'scopes': <Object?>['stats:read'],
        'created_at': '2026-09-28T08:00:00Z',
        'key': 'plk_abcd1234SECRET',
      });

      expect(created.key, 'plk_abcd1234SECRET');
      expect(created.summary.id, 'key-1');
      expect(created.summary.keyPrefix, 'plk_abcd1234');
    });

    test('toString 不泄露明文密钥（日志安全）', () {
      const ApiKeyCreated created = ApiKeyCreated(
        summary: ApiKeySummary(
          id: 'key-1',
          name: 'AstrBot',
          keyPrefix: 'plk_abcd1234',
          scopes: <String>['stats:read'],
        ),
        key: 'plk_abcd1234SECRET',
      );
      expect(created.toString(), isNot(contains('SECRET')));
      expect(created.toString(), contains('redacted'));
    });
  });
}

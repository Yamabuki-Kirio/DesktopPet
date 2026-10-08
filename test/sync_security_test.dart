import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:petlife/core/logger.dart';
import 'package:petlife/database/app_database.dart';
import 'package:petlife/database/dao/account_session_dao.dart';
import 'package:petlife/database/dao/sync_outbox_dao.dart';
import 'package:petlife/database/dao/sync_state_dao.dart';
import 'package:petlife/database/schema.dart';
import 'package:petlife/sync/credential_store.dart';
import 'package:petlife/sync/models/sync_models.dart';
import 'package:petlife/sync/sync_preferences.dart';
import 'package:petlife/sync/device_identity.dart';

import 'support/sqlite_test_bootstrap.dart';

/// Phase 2 安全相关：日志脱敏、凭据存储、令牌不落库。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SqliteTestBootstrap.ensureLoaded();

  group('日志脱敏', () {
    test('Authorization 头被抹掉（Bearer 与 Basic 都要覆盖）', () {
      expect(
        AppLog.redact('Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.abcdef.ghijkl'),
        isNot(contains('eyJhbGciOiJIUzI1NiJ9')),
      );
      expect(AppLog.redact('authorization=Basic dXNlcjpwYXNzd29yZA=='),
          isNot(contains('dXNlcjpwYXNzd29yZA')));
      expect(AppLog.redact('Authorization: Bearer abc123XYZ'), contains('<redacted>'));
    });

    test('access_token / refresh_token / password 的值被抹掉', () {
      for (final String raw in <String>[
        'access_token=abcdef123456',
        '"access_token": "abcdef123456"',
        "'refresh_token':'abcdef123456'",
        'refresh_token: abcdef123456',
        'password=hunter2',
        '"password":"hunter2"',
        '{"refresh_token":"abcdef123456"}',
      ]) {
        final String cleaned = AppLog.redact(raw);
        expect(cleaned, isNot(contains('abcdef123456')), reason: raw);
        expect(cleaned, isNot(contains('hunter2')), reason: raw);
      }
    });

    test('裸 JWT 被抹掉', () {
      const String jwt =
          'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c';
      final String cleaned = AppLog.redact('token $jwt end');
      expect(cleaned, isNot(contains(jwt)));
      expect(cleaned, contains('<redacted>'));
    });

    test('普通文本不受影响', () {
      const String text = '同步完成：待同步 0 条，状态 同步成功';
      expect(AppLog.redact(text), text);
    });

    test('AppLog.format 一定会脱敏（文件与界面共用这一处）', () {
      final LogRecord record = LogRecord(
        Level.INFO,
        'leaking access_token=abcdef123456 and Authorization: Bearer zzzz.yyyy.xxxx',
        'petlife.sync',
      );
      final String line = AppLog.format(record);
      expect(line, isNot(contains('abcdef123456')));
      expect(line, isNot(contains('zzzz.yyyy.xxxx')));
      expect(line, contains('<redacted>'));
    });
  });

  group('令牌表示', () {
    test('TokenPair 可往返编码解码', () {
      final TokenPair pair = TokenPair(
        accessToken: 'access-123',
        refreshToken: 'refresh-456',
        accessTokenExpiresAt: DateTime.fromMillisecondsSinceEpoch(1800000000000),
      );
      final TokenPair? decoded = TokenPair.decode(pair.encode());
      expect(decoded, isNotNull);
      expect(decoded!.accessToken, 'access-123');
      expect(decoded.refreshToken, 'refresh-456');
      expect(decoded.accessTokenExpiresAt, isNotNull);
    });

    test('toString() 不泄露令牌（异常与调试输出都会用它）', () {
      final TokenPair pair = TokenPair(accessToken: 'secret-access', refreshToken: 'secret-refresh');
      expect(pair.toString(), isNot(contains('secret-access')));
      expect(pair.toString(), isNot(contains('secret-refresh')));
      expect(pair.toString(), contains('redacted'));
    });

    test('非法内容解码返回 null 而不是抛异常', () {
      expect(TokenPair.decode('not json'), isNull);
      expect(TokenPair.decode('{"a":1}'), isNull);
      expect(TokenPair.decode(null), isNull);
      expect(TokenPair.decode(''), isNull);
    });
  });

  group('凭据存储（内存实现，不触碰真实系统凭据）', () {
    test('写入 / 读取 / 删除', () async {
      final InMemoryCredentialStore store = InMemoryCredentialStore();
      expect(store.isAvailable, isTrue);
      expect(await store.read('PetLife:account'), isNull);

      await store.write('PetLife:account', 'payload-1');
      expect(await store.read('PetLife:account'), 'payload-1');

      await store.write('PetLife:account', 'payload-2');
      expect(await store.read('PetLife:account'), 'payload-2');

      await store.delete('PetLife:account');
      expect(await store.read('PetLife:account'), isNull);
      expect(store.keys, isEmpty);
    });

    test('删除不存在的条目是幂等的', () async {
      final InMemoryCredentialStore store = InMemoryCredentialStore();
      await store.delete('nope');
      await store.delete('nope');
      expect(store.keys, isEmpty);
    });

    test('异常信息里不含凭据内容（异常也会进日志）', () {
      const CredentialStoreException exception =
          CredentialStoreException('写入 Windows 凭据失败（key=PetLife:account）');
      expect(exception.toString(), contains('PetLife:account'));
      expect(exception.toString(), isNot(contains('access_token')));
    });
  });

  group('本地库不保存令牌', () {
    late Directory tmp;

    setUpAll(() {
      tmp = Directory.systemTemp.createTempSync('petlife_sync_security');
    });

    tearDownAll(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('account_session 表结构里没有令牌列', () async {
      await AppDatabase.close();
      final AppDatabase db = await AppDatabase.open(
        path: p.join(tmp.path, 'security_${DateTime.now().microsecondsSinceEpoch}.db'),
      );
      final List<Map<String, Object?>> columns =
          await db.raw.rawQuery('PRAGMA table_info(${DbSchema.tableAccountSession})');
      final Set<String> names = columns
          .map((Map<String, Object?> c) => (c['name']! as String).toLowerCase())
          .toSet();

      expect(names, contains('credential_reference'));
      expect(names, contains('access_token_expires_at'));
      for (final String banned in <String>[
        'access_token',
        'refresh_token',
        'token',
        'password',
        'secret',
      ]) {
        expect(names, isNot(contains(banned)));
      }
      await AppDatabase.close();
    });

    test('AccountSession 落库后整库文本里搜不到令牌内容', () async {
      await AppDatabase.close();
      final String path =
          p.join(tmp.path, 'nosecret_${DateTime.now().microsecondsSinceEpoch}.db');
      final AppDatabase db = await AppDatabase.open(path: path);
      final AccountSessionDao dao = AccountSessionDao(db.raw);

      await dao.save(AccountSession(
        serverBaseUrl: 'http://127.0.0.1:8000',
        userId: 'user-1',
        email: 'a@example.com',
        displayName: 'A',
        deviceServerId: 'device-1',
        credentialReference: 'PetLife:account',
        accessTokenExpiresAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ));
      await AppDatabase.close();

      // 直接扫描数据库文件：令牌内容绝不能出现在任何地方
      final List<int> bytes = await File(path).readAsBytes();
      final String raw = String.fromCharCodes(bytes);
      expect(raw, isNot(contains('access-token-value')));
      expect(raw, isNot(contains('refresh-token-value')));
      expect(raw, contains('PetLife:account'));
    });
  });

  group('设备身份与偏好', () {
    late Directory tmp;

    setUpAll(() {
      tmp = Directory.systemTemp.createTempSync('petlife_sync_device');
    });

    tearDownAll(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('device_local_id 首次生成、重启后不变', () async {
      final String path =
          p.join(tmp.path, 'device_${DateTime.now().microsecondsSinceEpoch}.db');

      await AppDatabase.close();
      AppDatabase db = await AppDatabase.open(path: path);
      final DeviceIdentity identity = DeviceIdentity(db);
      final String first = await identity.ensureDeviceLocalId();
      expect(first, isNotEmpty);
      // 同一个实例重复调用必须一致
      expect(await identity.ensureDeviceLocalId(), first);
      await AppDatabase.close();

      // 模拟"重启"：关闭再打开同一个库文件
      db = await AppDatabase.open(path: path);
      final String afterRestart = await DeviceIdentity(db).ensureDeviceLocalId();
      expect(afterRestart, first, reason: 'device_local_id 必须跨重启保持不变');
      await AppDatabase.close();
    });

    test('服务端地址默认值可读、可改、可持久化', () async {
      final String path =
          p.join(tmp.path, 'prefs_${DateTime.now().microsecondsSinceEpoch}.db');
      await AppDatabase.close();
      AppDatabase db = await AppDatabase.open(path: path);
      final SyncPreferences prefs = SyncPreferences(db);

      expect(await prefs.serverBaseUrl(), 'http://127.0.0.1:8000');

      await prefs.setServerBaseUrl('https://api.example.com/');
      await AppDatabase.close();

      db = await AppDatabase.open(path: path);
      expect(await SyncPreferences(db).serverBaseUrl(), 'https://api.example.com/');
      await AppDatabase.close();
    });

    test('历史回填标记按账户区分', () async {
      final String path =
          p.join(tmp.path, 'backfill_${DateTime.now().microsecondsSinceEpoch}.db');
      await AppDatabase.close();
      final AppDatabase db = await AppDatabase.open(path: path);
      final SyncPreferences prefs = SyncPreferences(db);

      expect(await prefs.historyBackfillMarker(), isNull);
      await prefs.setHistoryBackfillMarker('user-1');
      expect(await prefs.historyBackfillMarker(), 'user-1');
      await prefs.setHistoryBackfillMarker('user-2');
      expect(await prefs.historyBackfillMarker(), 'user-2');
      await AppDatabase.close();
    });
  });

  group('DAO 可实例化（编译期契约）', () {
    test('三个 v3 DAO 都能正常构造', () async {
      await AppDatabase.close();
      final Directory tmp = Directory.systemTemp.createTempSync('petlife_sync_dao');
      final AppDatabase db = await AppDatabase.open(
        path: p.join(tmp.path, 'dao_${DateTime.now().microsecondsSinceEpoch}.db'),
      );
      expect(AccountSessionDao(db.raw).hashCode, isNotNull);
      expect(SyncStateDao(db.raw).hashCode, isNotNull);
      expect(SyncOutboxDao(db.raw).hashCode, isNotNull);
      await AppDatabase.close();
      tmp.deleteSync(recursive: true);
    });
  });
}

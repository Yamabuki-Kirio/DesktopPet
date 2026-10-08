import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:petlife/core/logger.dart';
import 'package:petlife/core/paths.dart';
import 'package:petlife/database/app_database.dart';
import 'package:petlife/settings/app_settings.dart';
import 'package:petlife/settings/sqlite_settings_repository.dart';
import 'package:petlife/ui/overlay_menu_actions.dart';

import 'support/sqlite_test_bootstrap.dart';

/// 菜单请求台账的持久化（幂等性的**唯一**依据）。
///
/// 这一组用例存在的理由：`Activity 重建 / 冷启动` 之后内存集合必然为空，
/// 若台账只存在内存里，"同一个 requestId 至多执行一次"就是假的。
/// 因此这里真的**关库再重开**，验证记录仍在。
///
/// 同时验证它复用既有 `local_settings` 表、**不干扰** `AppSettings`。
void main() {
  Directory? root;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SqliteTestBootstrap.ensureLoaded();

    final Directory dir = Directory.systemTemp.createTempSync('petlife_menu_ledger');
    root = dir;
    AppPaths.resetForTest();
    await AppPaths.initialize(overrideRoot: dir);
    await AppLog.initialize(logFile: AppPaths.instance.logFile);
  });

  tearDownAll(() async {
    await AppDatabase.close();
    await AppLog.dispose();
    AppPaths.resetForTest();
    if (root != null && root!.existsSync()) root!.deleteSync(recursive: true);
  });

  Future<AppDatabase> openDatabase() =>
      AppDatabase.open(path: AppPaths.instance.databaseFile.path);

  test('默认空台账（首次安装时不会误判为"已处理过"）', () async {
    final SqliteMenuRequestLedger ledger =
        SqliteMenuRequestLedger(database: await openDatabase(), ownerId: 'ledger.empty');

    expect(await ledger.loadSeen(), isEmpty);
  });

  test('remember → 关库重开 → 仍然记得（冷启动幂等的依据）', () async {
    const String owner = 'ledger.roundtrip';
    final SqliteMenuRequestLedger ledger =
        SqliteMenuRequestLedger(database: await openDatabase(), ownerId: owner);

    await ledger.remember('req-1');
    await ledger.remember('req-2');
    expect(await ledger.loadSeen(), <String>{'req-1', 'req-2'});

    // 模拟"退出应用 / Activity 被系统回收"：关掉连接再从磁盘重开。
    await AppDatabase.close();
    final SqliteMenuRequestLedger reopened =
        SqliteMenuRequestLedger(database: await openDatabase(), ownerId: owner);

    expect(await reopened.loadSeen(), <String>{'req-1', 'req-2'});
  });

  test('重复 remember 同一条不会出现两条（幂等写入）', () async {
    const String owner = 'ledger.idempotent';
    final SqliteMenuRequestLedger ledger =
        SqliteMenuRequestLedger(database: await openDatabase(), ownerId: owner);

    await ledger.remember('req-x');
    await ledger.remember('req-x');

    expect(await ledger.loadSeen(), <String>{'req-x'});
  });

  test('只保留最近 N 条（无需无限增长）', () async {
    const String owner = 'ledger.cap';
    final SqliteMenuRequestLedger ledger =
        SqliteMenuRequestLedger(database: await openDatabase(), ownerId: owner);

    for (int i = 0; i < SqliteMenuRequestLedger.maxRemembered + 5; i++) {
      await ledger.remember('req-$i');
    }

    final Set<String> seen = await ledger.loadSeen();
    expect(seen, hasLength(SqliteMenuRequestLedger.maxRemembered));
    expect(seen, contains('req-${SqliteMenuRequestLedger.maxRemembered + 4}'));
    expect(seen, isNot(contains('req-0')), reason: '最旧的应被裁掉');
  });

  test('台账写在既有 local_settings 里，不影响 AppSettings 的读写', () async {
    const String owner = 'ledger.isolation';
    final AppDatabase db = await openDatabase();
    final SqliteSettingsRepository settings = SqliteSettingsRepository.fromDatabase(db);
    await settings.save(owner, const AppSettings(scale: 3.0));

    await SqliteMenuRequestLedger(database: db, ownerId: owner).remember('req-iso');

    final AppSettings loaded = await settings.load(owner);
    expect(loaded.scale, 3.0);
    // 台账多出来的键不会被 AppSettings 读进来（也不会被它写没）。
    expect((await settings.load(owner)).toKeyValues(), loaded.toKeyValues());
    expect(
      await SqliteMenuRequestLedger(database: db, ownerId: owner).loadSeen(),
      <String>{'req-iso'},
    );
  });
}

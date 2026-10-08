import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:petlife/core/logger.dart';
import 'package:petlife/core/paths.dart';
import 'package:petlife/database/app_database.dart';
import 'package:petlife/settings/app_settings.dart';
import 'package:petlife/settings/settings_controller.dart';
import 'package:petlife/settings/sqlite_settings_repository.dart';
import 'package:petlife/state_engine/system_state.dart';

import 'support/sqlite_test_bootstrap.dart';

/// 设置持久化往返测试 —— 验收第 18 项「重启后恢复角色、图片、位置、缩放、透明度」。
///
/// 这一层此前**零测试覆盖**：`local_settings` 的读写完全没有被任何用例触碰过，
/// 而它恰好是「重启恢复」唯一的数据来源。缺陷 D-01 的教训是
/// 「零覆盖的模块坏掉会让整条链路失效」，所以这里把往返链路补齐。
///
/// 关键用例是 [save 后关库重开仍能完整读回]：它不是在同一进程里读内存缓存，
/// 而是**真的关掉数据库连接再从磁盘重开**，与用户「退出应用再启动」的路径一致。
void main() {
  // 用可空 + null 判断而不是 late：setUpAll 若在引导阶段失败，
  // tearDownAll 仍会被调用，late 变量会再抛一次 LateInitializationError 掩盖真实错误。
  Directory? root;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SqliteTestBootstrap.ensureLoaded();

    final Directory dir = Directory.systemTemp.createTempSync('petlife_settings_test');
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

  /// 打开（或复用）数据库并返回设置仓储。
  Future<SqliteSettingsRepository> openRepository() async {
    final AppDatabase db = await AppDatabase.open(
      path: AppPaths.instance.databaseFile.path,
    );
    return SqliteSettingsRepository.fromDatabase(db);
  }

  test('空库读取返回默认值（不抛异常，缺字段用默认值补齐）', () async {
    final SqliteSettingsRepository repo = await openRepository();
    final AppSettings s = await repo.load('settings.empty');

    expect(s.alwaysOnTop, isTrue);
    expect(s.ignoreMouseEvents, isFalse);
    expect(s.lockPosition, isFalse);
    expect(s.scale, 2.0);
    expect(s.smoothScaling, isFalse);
    expect(s.opacity, 1.0);
    expect(s.loopAnimation, isTrue);
    expect(s.windowX, isNull);
    expect(s.windowY, isNull);
    expect(s.lastState, SystemState.defaultState);
    expect(s.lastCharacterId, isNull);
    expect(s.lastAssetId, isNull);
  });

  test('save → 关库 → 重开 → load：全部字段逐项一致（重启往返）', () async {
    const String owner = 'settings.roundtrip';

    // 刻意全部取非默认值，任何一项没落盘都会让相等断言失败。
    const AppSettings written = AppSettings(
      alwaysOnTop: false,
      ignoreMouseEvents: true,
      lockPosition: true,
      scale: 3.0,
      smoothScaling: true,
      opacity: 0.6,
      crossFadeMs: 280,
      loopAnimation: false,
      defaultCharacterId: 'char-0001',
      defaultAssetId: 'asset-0001',
      hideOnFullscreen: true,
      launchAtStartup: true,
      windowX: 1352.0,
      windowY: 611.0,
      lastCharacterId: 'char-0001',
      lastState: SystemState.tired,
      lastAssetId: 'asset-0007',
      manualAssetId: 'asset-0009',
    );

    final SqliteSettingsRepository repo = await openRepository();
    await repo.save(owner, written);

    // 模拟「退出应用」：关闭连接（WAL 落盘），再从同一个文件重开。
    await AppDatabase.close();
    final SqliteSettingsRepository reopened = await openRepository();
    final AppSettings loaded = await reopened.load(owner);

    expect(loaded.alwaysOnTop, false);
    expect(loaded.ignoreMouseEvents, true);
    expect(loaded.lockPosition, true);
    expect(loaded.scale, 3.0);
    expect(loaded.smoothScaling, true);
    expect(loaded.opacity, 0.6);
    expect(loaded.crossFadeMs, 280);
    expect(loaded.loopAnimation, false);
    expect(loaded.defaultCharacterId, 'char-0001');
    expect(loaded.defaultAssetId, 'asset-0001');
    expect(loaded.hideOnFullscreen, true);
    expect(loaded.launchAtStartup, true);
    expect(loaded.windowX, 1352.0);
    expect(loaded.windowY, 611.0);
    expect(loaded.lastCharacterId, 'char-0001');
    expect(loaded.lastState, SystemState.tired);
    expect(loaded.lastAssetId, 'asset-0007');
    expect(loaded.manualAssetId, 'asset-0009');

    // 整表往返：写入与读回的键值对必须完全相等（防止某字段只写不读）。
    expect(loaded.toKeyValues(), written.toKeyValues());
  });

  test('SettingsController.load 的日志带出窗口位置 —— 与验收读到的同一行', () async {
    const String owner = 'settings.logline';
    final SqliteSettingsRepository repo = await openRepository();
    await repo.save(
      owner,
      const AppSettings(scale: 4.0, windowX: 1352.0, windowY: 611.0),
    );

    await AppDatabase.close();
    final SettingsController controller = SettingsController(
      repository: await openRepository(),
      ownerId: owner,
    );
    await controller.load();

    expect(controller.isLoaded, isTrue);
    expect(controller.settings.windowX, 1352.0);
    expect(controller.settings.scale, 4.0);

    // 应用启动日志就是靠这一行读出「位置=(x, y) 缩放=Nx」来确认恢复成败的，
    // 所以这里断言的就是验收时实际会去读的那行文本。
    final String logText = AppLog.exportRecentLogText();
    expect(logText, contains('petlife.settings: 设置加载完成'));
    expect(logText, contains('位置=(1352.0, 611.0)'));
    expect(logText, contains('缩放=4.0x'));
  });

  test('SettingsController.update 的改动会落盘（UI 改设置走的就是这条路）', () async {
    const String owner = 'settings.controller';
    final SettingsController controller = SettingsController(
      repository: await openRepository(),
      ownerId: owner,
    );
    await controller.load();

    await controller.setScale(3.0);
    await controller.setIgnoreMouseEvents(true);
    await controller.setOpacity(0.5);
    await controller.rememberWindowPosition(880.0, 420.0);

    // 模拟退出应用再启动。
    await AppDatabase.close();
    final SettingsController restarted = SettingsController(
      repository: await openRepository(),
      ownerId: owner,
    );
    await restarted.load();

    expect(restarted.settings.scale, 3.0);
    expect(restarted.settings.ignoreMouseEvents, isTrue);
    expect(restarted.settings.opacity, 0.5);
    expect(restarted.settings.windowX, 880.0);
    expect(restarted.settings.windowY, 420.0);
  });

  test('patch 局部更新不影响未涉及的键', () async {
    const String owner = 'settings.patch';
    final SqliteSettingsRepository repo = await openRepository();
    await repo.save(owner, const AppSettings(scale: 3.0, opacity: 0.5));

    await repo.patch(owner, <String, String?>{'window.scale': '4.0'});
    final AppSettings after = await repo.load(owner);

    expect(after.scale, 4.0);
    expect(after.opacity, 0.5, reason: '局部更新把未涉及的键覆盖掉了');
  });

  test('越界值被归一化后才落盘（手改数据库也不会渲染出异常值）', () async {
    const String owner = 'settings.normalize';
    final SqliteSettingsRepository repo = await openRepository();
    await repo.save(
      owner,
      const AppSettings(scale: 3.7, opacity: 0.05, crossFadeMs: 9999),
    );

    final AppSettings s = await repo.load(owner);
    expect(s.scale, 4.0, reason: '缩放必须取整到 1~4 的整数档');
    expect(s.opacity, 0.2, reason: '透明度下限 0.2');
    expect(s.crossFadeMs, 300, reason: '淡入淡出上限 300ms');
  });

  test('reset 后回到默认值', () async {
    const String owner = 'settings.reset';
    final SqliteSettingsRepository repo = await openRepository();
    await repo.save(owner, const AppSettings(scale: 4.0, loopAnimation: false));
    expect((await repo.load(owner)).scale, 4.0);

    await repo.reset(owner);
    final AppSettings s = await repo.load(owner);
    expect(s.scale, 2.0);
    expect(s.loopAnimation, isTrue);
  });

  test('不同 owner 的设置互不干扰', () async {
    final SqliteSettingsRepository repo = await openRepository();
    await repo.save('settings.ownerA', const AppSettings(scale: 3.0));
    await repo.save('settings.ownerB', const AppSettings(scale: 4.0));

    expect((await repo.load('settings.ownerA')).scale, 3.0);
    expect((await repo.load('settings.ownerB')).scale, 4.0);
  });

  // ---------------------------------------------------------------------------
  // Phase 4B：使用统计页新增的「本机 | 云端」子页记忆
  //
  // 这一组同时承担「本机统计页面回归」的证据：新增的子页只多了一个 UI 记忆键，
  // 既不能污染其它设置，也不能在取值异常时把页面卡在空白状态
  // （本机采集 / 暂停 / 恢复等原有能力由 usage_analytics_test、
  // activity_segment_service_test 等既有用例继续覆盖）。
  // ---------------------------------------------------------------------------

  test('使用统计子页记忆：默认本机，保存云端后重启仍停在云端', () async {
    const String owner = 'settings.usageTab';

    final SqliteSettingsRepository fresh = await openRepository();
    expect(
      (await fresh.load(owner)).usageStatsTab,
      AppSettings.usageStatsTabLocal,
      reason: '没选过时必须默认停在本机页',
    );

    await fresh.save(
      owner,
      const AppSettings(usageStatsTab: AppSettings.usageStatsTabCloud),
    );

    // 模拟退出应用再启动。
    await AppDatabase.close();
    final AppSettings reopened = await (await openRepository()).load(owner);
    expect(reopened.usageStatsTab, AppSettings.usageStatsTabCloud);
  });

  test('切换子页与其它设置互不影响（切到云端不会改动本机相关配置）', () async {
    const String owner = 'settings.usageTabIsolated';
    final SettingsController controller = SettingsController(
      repository: await openRepository(),
      ownerId: owner,
    );
    await controller.load();
    await controller.setScale(3.0);
    await controller.setIgnoreMouseEvents(true);

    await controller.setUsageStatsTab(AppSettings.usageStatsTabCloud);
    expect(controller.settings.scale, 3.0);
    expect(controller.settings.ignoreMouseEvents, isTrue);

    await AppDatabase.close();
    final SettingsController restarted = SettingsController(
      repository: await openRepository(),
      ownerId: owner,
    );
    await restarted.load();

    expect(restarted.settings.usageStatsTab, AppSettings.usageStatsTabCloud);
    expect(restarted.settings.scale, 3.0);
    expect(restarted.settings.ignoreMouseEvents, isTrue);
    expect(restarted.settings.opacity, 1.0, reason: '未涉及的字段必须保持默认值');
  });

  test('非法的子页取值回落本机，不会把统计页卡在空白状态', () async {
    const String owner = 'settings.usageTabInvalid';
    final SqliteSettingsRepository repo = await openRepository();

    // 模拟手工改库 / 旧版本残留的脏值。
    await repo.patch(owner, <String, String?>{'ui.usageStatsTab': 'banana'});
    expect((await repo.load(owner)).usageStatsTab, AppSettings.usageStatsTabLocal);

    // 直接构造非法值也要被归一化后才落盘。
    await repo.save(owner, const AppSettings(usageStatsTab: 'banana'));
    expect((await repo.load(owner)).usageStatsTab, AppSettings.usageStatsTabLocal);
  });
}

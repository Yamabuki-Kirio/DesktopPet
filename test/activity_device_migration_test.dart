import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:petlife/activity_tracking/models/tracking_settings.dart';
import 'package:petlife/core/constants.dart';
import 'package:petlife/database/app_database.dart';
import 'package:petlife/database/dao/activity_dao.dart';
import 'package:petlife/database/dao/daily_usage_dao.dart';

import 'support/sqlite_test_bootstrap.dart';

/// Phase 4C-5.1A：本地统计的**设备标识迁移**。
///
/// 背景：4C-5.1A 之前本地采集表统一写常量 `desktop.local`；
/// Android 改用稳定安装 UUID 后，旧行若不迁移就会被新查询漏掉，
/// 若直接合并又会重复累计。这里验证迁移只改标识、且**绝不重复累计**。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SqliteTestBootstrap.ensureLoaded();

  late Directory tmp;
  late AppDatabase db;
  late ActivityDao activityDao;
  late DailyUsageDao dailyUsageDao;

  const String legacy = 'desktop.local';
  const String device = '11111111-2222-3333-4444-555555555555';

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('petlife_device_migration');
    db = await AppDatabase.open(path: p.join(tmp.path, 'test.db'));
    activityDao = ActivityDao(db.raw);
    dailyUsageDao = DailyUsageDao(db.raw);
  });

  tearDown(() async {
    if (AppDatabase.isOpen) await AppDatabase.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  DailyUsage usage({
    required String deviceId,
    required String day,
    required int seconds,
  }) =>
      DailyUsage(
        ownerId: AppConstants.localOwnerId,
        deviceLocalId: deviceId,
        dayKey: day,
        sessionSeconds: seconds,
        activeSeconds: seconds,
        idleSeconds: 0,
        firstActiveAt: DateTime(2026, 9, 30, 9),
        lastActiveAt: DateTime(2026, 9, 30, 10),
        updatedAt: DateTime(2026, 9, 30, 10),
      );

  test('activity_segments：旧标识的行被迁到新标识，时间与秒数不变', () async {
    await activityDao.insert(
      ActivitySegment(
        id: 'seg-1',
        ownerId: AppConstants.localOwnerId,
        deviceLocalId: legacy,
        appKey: 'chrome',
        appName: 'Chrome',
        startedAt: DateTime(2026, 9, 30, 9),
        endedAt: DateTime(2026, 9, 30, 9, 5),
        activeSeconds: 300,
        endReason: 'foreground_changed',
        createdAt: DateTime(2026, 9, 30, 9),
      ),
    );

    final int moved = await activityDao.migrateDeviceLocalId(legacy, device);

    expect(moved, 1);
    final List<ActivitySegment> rows = await activityDao.listOverlapping(
      AppConstants.localOwnerId,
      DateTime(2026, 9, 30),
      DateTime(2026, 10, 1),
      deviceLocalId: device,
    );
    expect(rows, hasLength(1));
    expect(rows.single.activeSeconds, 300, reason: '迁移不得改动时长');
    expect(rows.single.startedAt, DateTime(2026, 9, 30, 9), reason: '迁移不得改动时间');
    // 旧标识下不再有行（不会既算旧的又算新的）。
    expect(
      await activityDao.listOverlapping(
        AppConstants.localOwnerId,
        DateTime(2026, 9, 30),
        DateTime(2026, 10, 1),
        deviceLocalId: legacy,
      ),
      isEmpty,
    );
  });

  test('daily_usage：目标标识当天已有行时跳过，绝不把两行相加', () async {
    // 旧标识：09-29 与 09-30 各一行。
    await dailyUsageDao.upsert(
      usage(deviceId: legacy, day: '2026-09-29', seconds: 600),
    );
    await dailyUsageDao.upsert(
      usage(deviceId: legacy, day: '2026-09-30', seconds: 500),
    );
    // 新标识：09-30 已经有自己的行（例如升级后已开始采集）。
    await dailyUsageDao.upsert(
      usage(deviceId: device, day: '2026-09-30', seconds: 120),
    );

    final int moved = await dailyUsageDao.migrateDeviceLocalId(legacy, device);

    expect(moved, 1, reason: '只应迁移 09-29 那一行');
    expect(
      (await dailyUsageDao.find(AppConstants.localOwnerId, device, '2026-09-29'))
          ?.activeSeconds,
      600,
    );
    expect(
      (await dailyUsageDao.find(AppConstants.localOwnerId, device, '2026-09-30'))
          ?.activeSeconds,
      120,
      reason: '冲突的那天必须保留目标行，不能相加（否则就是重复累计）',
    );
    expect(
      await dailyUsageDao.find(AppConstants.localOwnerId, legacy, '2026-09-30'),
      isNotNull,
      reason: '被跳过的那行仍留在旧标识下，绝不会凭空消失',
    );
  });

  test('旧新标识相同时是空操作（幂等，可重复执行）', () async {
    expect(await activityDao.migrateDeviceLocalId(legacy, legacy), 0);
    expect(await dailyUsageDao.migrateDeviceLocalId(legacy, legacy), 0);
    // 再次迁移同一批数据不改变任何东西（第二次已经没有旧行）。
    await dailyUsageDao.upsert(
      usage(deviceId: legacy, day: '2026-09-28', seconds: 60),
    );
    expect(await dailyUsageDao.migrateDeviceLocalId(legacy, device), 1);
    expect(await dailyUsageDao.migrateDeviceLocalId(legacy, device), 0);
  });
}

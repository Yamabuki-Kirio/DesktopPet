import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:petlife/activity_tracking/activity_segment_service.dart';
import 'package:petlife/activity_tracking/application_repository.dart';
import 'package:petlife/activity_tracking/local_change_sink.dart';
import 'package:petlife/activity_tracking/models/activity_enums.dart';
import 'package:petlife/activity_tracking/models/activity_sample.dart';
import 'package:petlife/activity_tracking/models/tracking_settings.dart';
import 'package:petlife/activity_tracking/tracking_clock.dart';
import 'package:petlife/core/constants.dart';
import 'package:petlife/database/app_database.dart';
import 'package:petlife/database/dao/activity_checkpoint_dao.dart';
import 'package:petlife/database/dao/activity_dao.dart';
import 'package:petlife/database/dao/application_dao.dart';
import 'package:petlife/database/dao/daily_usage_dao.dart';

import 'support/sqlite_test_bootstrap.dart';

const String kOwner = 'local.default';
const String kDevice = 'desktop.local';
const int kTick = ActivityTracking.sampleIntervalMs;

/// 测试用的活动段状态机宿主：真实 SQLite + 可控时钟。
///
/// 用真实数据库（临时文件）而不是 Mock，是为了让「活动段合并 / 落库 / 检查点 /
/// 崩溃恢复」这些核心行为得到真实验证，而不是只验证 Mock 返回值。
class Harness {
  Harness(this.db, this.activityDao, this.applicationDao, this.apps);

  final AppDatabase db;
  final ActivityDao activityDao;
  final ApplicationDao applicationDao;
  final ApplicationRepository apps;

  /// 由 [setUp] 用本 Harness 自己的时钟创建，保证时钟实例唯一。
  late ActivitySegmentService service;

  static DateTime base = DateTime.utc(2026, 9, 27, 12, 0, 0);

  final FakeMonotonicClock mono = FakeMonotonicClock(0);
  final FakeWallClock wall = FakeWallClock(base);

  /// 记录 outbox 通知，用于验证「插入成功之前不得创建 outbox」。
  final RecordingChangeSink sink = RecordingChangeSink();

  /// 用本 Harness 的时钟装配状态机。
  ActivitySegmentService buildService() => ActivitySegmentService(
    activityDao: activityDao,
    checkpointDao: ActivityCheckpointDao(db.raw),
    dailyUsageDao: DailyUsageDao(db.raw),
    applications: apps,
    ownerId: kOwner,
    deviceLocalId: kDevice,
    monotonicClock: mono,
    wallClock: wall,
    changeSink: sink,
  );

  int get nowMono => mono.nowMs();
  DateTime get nowWall => wall.now();

  /// 推进时钟并投递一次采样。
  Future<void> tick({
    int? advanceMs,
    String? appPath = r'C:\apps\Code.exe',
    Duration idle = Duration.zero,
    bool locked = false,
    bool paused = false,
  }) async {
    final int step = advanceMs ?? kTick;
    mono.advance(step);
    wall.advance(Duration(milliseconds: step));
    await service.tick(
      build(appPath: appPath, idle: idle, locked: locked, paused: paused),
    );
  }

  ActivitySample build({
    String? appPath = r'C:\apps\Code.exe',
    Duration idle = Duration.zero,
    bool locked = false,
    bool paused = false,
  }) => ActivitySample(
    wallNow: nowWall,
    monotonicMs: nowMono,
    foreground: appPath == null
        ? null
        : ForegroundAppInfo(
            windowHandle: 42,
            processId: 4242,
            processName: p.basename(appPath),
            executablePath: appPath,
          ),
    idle: idle,
    sessionLocked: locked,
    paused: paused,
  );

  /// 直接读库，避免被上层裁剪逻辑掩盖真实写入结果。
  Future<List<Map<String, Object?>>> rows() async =>
      db.raw.query('activity_segments', orderBy: 'started_at ASC');

  Future<List<Map<String, Object?>>> checkpoints() async =>
      db.raw.query('activity_checkpoints');

  Future<int> todayActiveSeconds() async {
    final List<Map<String, Object?>> r = await db.raw.query('daily_usage');
    return r.fold<int>(
      0,
      (int s, Map<String, Object?> e) => s + (e['active_seconds']! as int),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SqliteTestBootstrap.ensureLoaded();

  late Directory tmp;
  late AppDatabase db;
  late Harness h;

  setUpAll(() {
    tmp = Directory.systemTemp.createTempSync('petlife_activity_test');
  });

  tearDownAll(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  setUp(() async {
    final String dbPath = p.join(
      tmp.path,
      'petlife_${DateTime.now().microsecondsSinceEpoch}.db',
    );
    // 每次用例一个独立库文件，避免用例之间互相污染（AppDatabase 是单例，必须关闭再开）。
    await AppDatabase.close();
    db = await AppDatabase.open(path: dbPath);
    await db.raw.execute('PRAGMA foreign_keys = ON');

    final ActivityDao activityDao = ActivityDao(db.raw);
    final ApplicationDao applicationDao = ApplicationDao(db.raw);
    final ApplicationRepository apps = ApplicationRepository(
      dao: applicationDao,
    );
    await apps.load();

    // 时钟实例必须与 service 共用同一份，否则测试推进的时钟对服务不可见。
    final Harness harness = Harness(db, activityDao, applicationDao, apps);
    harness.service = harness.buildService();
    h = harness;
    await h.service.initialize();
  });

  tearDown(() async {
    await AppDatabase.close();
  });

  group('活动段合并（需求 三/四）', () {
    test('1. 相同应用连续采样合并为一个时间段', () async {
      for (int i = 0; i < 5; i++) {
        await h.tick();
      }

      final List<Map<String, Object?>> rows = await h.rows();
      expect(rows.length, 1, reason: '5 次采样是同一个应用的连续使用，必须合并为 1 段而不是 5 条记录');
      expect(rows.first['app_key'], 'code');
      expect(rows.first['ended_at'], isNull, reason: '该段仍在进行中');
      // 首次采样即开段（此时没有已存在的段可产生碎片），之后 4 个间隔各计入 2 秒。
      // 注意：进行中的段只在检查点（每 30 秒）或关闭时才回写数据库，
      // 因此这里断言内存中的实时累计值——数据库里那一行仍是插入时的初值。
      expect(h.service.currentSegmentSeconds, 8);
      expect(rows.first['active_seconds'], 0, reason: '进行中的段尚未到检查点');
    });

    test('2. 应用切换会结束旧段并创建新段', () async {
      for (int i = 0; i < 3; i++) {
        await h.tick(); // Code.exe
      }
      // 切换确认需要 switchConfirmMs(1500ms)，采样间隔 2s，因此新应用第 2 次出现才确认。
      await h.tick(appPath: r'C:\apps\chrome.exe');
      await h.tick(appPath: r'C:\apps\chrome.exe');

      final List<Map<String, Object?>> rows = await h.rows();
      expect(rows.length, 2, reason: '应产生两段：Code 一段 + Chrome 一段');
      expect(rows[0]['app_key'], 'code');
      expect(
        rows[0]['end_reason'],
        SegmentEndReason.foregroundChanged.wireName,
      );
      expect(rows[1]['app_key'], 'chrome');
      expect(rows[1]['ended_at'], isNull);
    });

    test('3/4. 用户空闲结束当前段，恢复后创建新段', () async {
      await h.tick();
      await h.tick();
      final int threshold = h.service.settings.idleThresholdMs;

      // 空闲超过阈值 → 结束当前段。
      await h.tick(idle: Duration(milliseconds: threshold + 1000));

      List<Map<String, Object?>> rows = await h.rows();
      expect(rows.length, 1);
      expect(rows.first['end_reason'], SegmentEndReason.userIdle.wireName);
      expect(rows.first['ended_at'], isNotNull);

      // 恢复使用 → 创建新段（同样需要一次确认）。
      await h.tick(idle: Duration(milliseconds: threshold + 1000));
      await h.tick();
      await h.tick();

      rows = await h.rows();
      expect(rows.length, 2, reason: '恢复活动后必须创建新时间段，不能继续扩展旧段');
      expect(rows.last['ended_at'], isNull);
    });

    test('5/6. 锁屏结束当前段，解锁后恢复采集', () async {
      await h.tick();
      await h.tick();
      await h.tick(locked: true);

      List<Map<String, Object?>> rows = await h.rows();
      expect(rows.length, 1);
      expect(rows.first['end_reason'], SegmentEndReason.sessionLocked.wireName);

      // 锁屏期间继续采样：不应该产生新段。
      await h.tick(locked: true);
      await h.tick(locked: true);
      rows = await h.rows();
      expect(rows.length, 1, reason: '锁屏期间不得累计任何活动段');

      // 解锁 → 恢复采集。
      await h.tick();
      await h.tick();
      rows = await h.rows();
      expect(rows.length, 2);
      expect(rows.last['ended_at'], isNull);
    });

    test('7. 休眠（采样中断）结束当前段且不计入这段时间', () async {
      await h.tick();
      await h.tick();

      // 模拟休眠 1 小时：墙上时钟前进，单调时钟不动。
      h.wall.advance(const Duration(hours: 1));
      await h.service.tick(h.build());

      final List<Map<String, Object?>> rows = await h.rows();
      expect(rows.length, 1);
      expect(rows.first['end_reason'], SegmentEndReason.systemSuspend.wireName);
      // 关键：休眠的一小时绝不能被计入活跃时间。
      expect(rows.first['active_seconds'], lessThanOrEqualTo(4));
    });

    test('8. 暂停记录立即结束当前段', () async {
      await h.tick();
      await h.tick();
      expect(await h.rows(), hasLength(1));

      // 注意：这里不推进时钟，验证「立即生效」而不是等下一个采样周期。
      await h.service.updateSettings(const TrackingSettings(paused: true));

      final List<Map<String, Object?>> rows = await h.rows();
      expect(
        rows.first['end_reason'],
        SegmentEndReason.trackingPaused.wireName,
      );
      expect(rows.first['ended_at'], isNotNull);

      // 暂停期间继续采样：不产生新段、不累计设备用量。
      final int before = await h.todayActiveSeconds();
      await h.tick(paused: true);
      await h.tick(paused: true);
      expect(await h.rows(), hasLength(1));
      expect(await h.todayActiveSeconds(), before);
    });

    test('9/10. 排除应用与 PetLife 自身都不计时', () async {
      // PetLife 自身：内置排除名单。
      await h.tick(appPath: r'C:\apps\PetLife.exe');
      await h.tick(appPath: r'C:\apps\PetLife.exe');
      expect(await h.rows(), isEmpty, reason: 'PetLife 自身的进程不得计入统计');

      // 用户手动排除的应用。
      await h.tick(appPath: r'C:\apps\Secret.exe');
      await h.tick(appPath: r'C:\apps\Secret.exe');
      await h.apps.setExcluded('secret', true);
      await h.tick(appPath: r'C:\apps\Secret.exe');
      await h.tick(appPath: r'C:\apps\Secret.exe');

      final List<Map<String, Object?>> rows = await h.rows();
      expect(rows, hasLength(1), reason: '被排除的应用不应再开启新段');
      expect(rows.first['end_reason'], SegmentEndReason.appExcluded.wireName);
      // 但应用库里仍然要有这条记录，否则用户无法在列表里恢复它。
      expect(h.apps.find('secret'), isNotNull);
    });

    test('11. 快速切换不会产生大量短碎片', () async {
      // 每 2 秒在 Code 与 Chrome 之间来回切换 10 次。
      for (int i = 0; i < 10; i++) {
        await h.tick(
          appPath: i.isEven ? r'C:\apps\Code.exe' : r'C:\apps\chrome.exe',
        );
      }

      final List<Map<String, Object?>> rows = await h.rows();
      expect(rows.length, 1, reason: '闪切未达到切换确认时长，应被归入同一段而不是产生 10 个碎片段');
      expect(rows.first['app_key'], 'code');
    });

    test('12. 系统时间大幅变化不产生负数或超长记录', () async {
      await h.tick();
      await h.tick();

      // 系统时间向后跳 1 小时（同时单调时钟正常前进一个采样周期）。
      h.mono.advance(kTick);
      h.wall.set(h.wall.now().subtract(const Duration(hours: 1)));
      await h.service.tick(h.build());

      await h.tick();

      final List<Map<String, Object?>> rows = await h.rows();
      for (final Map<String, Object?> row in rows) {
        final int? active = row['active_seconds'] as int?;
        if (active != null) {
          expect(active, greaterThanOrEqualTo(0), reason: '活跃秒数不得为负');
          expect(active, lessThan(3600), reason: '不得出现超长记录');
        }
        final int? started = row['started_at'] as int?;
        final int? ended = row['ended_at'] as int?;
        if (started != null && ended != null) {
          expect(ended, greaterThanOrEqualTo(started), reason: '结束时间不得早于开始时间');
        }
      }
      expect(
        rows.any(
          (Map<String, Object?> r) =>
              r['end_reason'] == SegmentEndReason.clockChanged.wireName,
        ),
        isTrue,
        reason: '系统时间大幅变化应显式结束当前段并标记 clock_changed',
      );
    });
  });

  group('检查点与崩溃恢复（需求 五）', () {
    test('13a. 异常退出后按最后检查点关闭活动段', () async {
      // 累计到超过一个检查点周期，确保检查点已写入。
      for (int i = 0; i < 20; i++) {
        await h.tick();
      }
      final List<Map<String, Object?>> cps = await h.checkpoints();
      expect(cps, isNotEmpty, reason: '每 30 秒必须写入一次检查点');

      final int activeAtCheckpoint = cps.first['active_seconds']! as int;
      expect(activeAtCheckpoint, greaterThan(0));

      // 模拟异常退出：不调用 shutdown()，直接新开一个 service 做恢复。
      final ActivitySegmentService recovered = ActivitySegmentService(
        activityDao: h.activityDao,
        checkpointDao: ActivityCheckpointDao(db.raw),
        dailyUsageDao: DailyUsageDao(db.raw),
        applications: h.apps,
        ownerId: kOwner,
        deviceLocalId: kDevice,
        monotonicClock: h.mono,
        wallClock: h.wall,
      );
      await recovered.recoverInterruptedSegments();

      final List<Map<String, Object?>> rows = await h.rows();
      expect(rows, hasLength(1));
      expect(rows.first['ended_at'], isNotNull, reason: '遗留段必须被关闭');
      expect(rows.first['end_reason'], SegmentEndReason.crashRecovery.wireName);
      expect(rows.first['active_seconds'], activeAtCheckpoint);
      expect(await h.checkpoints(), isEmpty, reason: '恢复后检查点应被清理');
    });

    test('13b. 没有检查点时按起点关闭，活跃 0 秒', () async {
      await h.tick();
      await h.tick();
      final List<Map<String, Object?>> rows = await h.rows();
      expect(rows, hasLength(1));
      final int startedAt = rows.first['started_at']! as int;

      // 人为清掉检查点，模拟「开段后 30 秒内就崩溃」。
      await db.raw.delete('activity_checkpoints');

      final ActivitySegmentService recovered = ActivitySegmentService(
        activityDao: h.activityDao,
        checkpointDao: ActivityCheckpointDao(db.raw),
        dailyUsageDao: DailyUsageDao(db.raw),
        applications: h.apps,
        ownerId: kOwner,
        deviceLocalId: kDevice,
        monotonicClock: h.mono,
        wallClock: h.wall,
      );
      await recovered.recoverInterruptedSegments();

      final List<Map<String, Object?>> after = await h.rows();
      expect(
        after.first['ended_at'],
        startedAt,
        reason: '没有检查点时必须用起点关闭，绝不能虚报一段长记录',
      );
      expect(after.first['active_seconds'], 0);
    });

    test('13c. 正常退出写入 client_shutdown 并落盘', () async {
      await h.tick();
      await h.tick();
      await h.service.shutdown();

      final List<Map<String, Object?>> rows = await h.rows();
      expect(
        rows.first['end_reason'],
        SegmentEndReason.clientShutdown.wireName,
      );
      expect(rows.first['ended_at'], isNotNull);
      expect(await h.checkpoints(), isEmpty);
    });
  });

  group('数据库短暂失败后的恢复', () {
    test('20. 首次插入失败，下一次 flush 幂等补写且最终只有一条段', () async {
      await db.raw.execute(
        "CREATE TRIGGER fail_segment_insert BEFORE INSERT ON activity_segments "
        "BEGIN SELECT RAISE(ABORT, 'injected insert failure'); END",
      );

      await h.tick(); // 开段插入失败，但内存里继续计时
      expect(await h.rows(), isEmpty);
      expect(h.sink.segments, isEmpty, reason: '插入成功前不得创建 outbox');

      await db.raw.execute('DROP TRIGGER fail_segment_insert');
      await h.tick(); // 第二个采样周期累计 2 秒
      await h.service.flushNow(); // 检查点触发的补写

      final List<Map<String, Object?>> rows = await h.rows();
      expect(rows, hasLength(1), reason: '重试插入不能产生第二条活动段');
      expect(rows.first['ended_at'], isNull);
      expect(rows.first['active_seconds'], 2);
      expect(h.sink.segments, isNotEmpty);

      // 再 flush 一次仍然只有一条，且不会重复插入。
      await h.service.flushNow();
      expect(await h.rows(), hasLength(1));
    });

    test('21. 关闭失败后保留待关闭状态，下一次 flush 正确关闭', () async {
      await h.tick();
      await h.tick();
      final int threshold = h.service.settings.idleThresholdMs;

      await db.raw.execute(
        "CREATE TRIGGER fail_segment_close BEFORE UPDATE ON activity_segments "
        "WHEN NEW.ended_at IS NOT NULL "
        "BEGIN SELECT RAISE(ABORT, 'injected close failure'); END",
      );

      await h.tick(
        advanceMs: 2000,
        idle: Duration(milliseconds: threshold + 1000),
      );

      List<Map<String, Object?>> rows = await h.rows();
      expect(rows, hasLength(1));
      expect(rows.first['ended_at'], isNull, reason: '关闭失败时必须保留未关闭行');
      expect(h.service.hasOpenSegment, isTrue, reason: '关闭成功前不得清空内存状态');

      await db.raw.execute('DROP TRIGGER fail_segment_close');
      await h.service.flushNow();

      rows = await h.rows();
      expect(rows, hasLength(1), reason: '补写关闭必须幂等，不能产生第二条段');
      expect(rows.first['end_reason'], SegmentEndReason.userIdle.wireName);
      expect(rows.first['active_seconds'], 3);
      expect(rows.first['ended_at'], isNotNull);
      expect(h.service.hasOpenSegment, isFalse);
      expect(await h.checkpoints(), isEmpty, reason: '成功关闭后才删除检查点');
    });
  });

  group('设备级用量（需求 九）', () {
    test('14. 活跃 / 空闲 / 屏幕会话分别累计且口径不同', () async {
      final int threshold = h.service.settings.idleThresholdMs;

      // 活跃 4 个周期。
      for (int i = 0; i < 5; i++) {
        await h.tick();
      }
      final int activeAfterBusy = h.service.todayActiveSeconds;

      // 进入空闲（超过阈值）后继续采样 2 个周期。
      for (int i = 0; i < 3; i++) {
        await h.tick(idle: Duration(milliseconds: threshold + 60000));
      }

      expect(
        h.service.todayIdleSeconds,
        greaterThan(0),
        reason: '超过阈值的空闲应单独计入空闲时间',
      );
      expect(
        h.service.todayActiveSeconds,
        activeAfterBusy,
        reason: '进入空闲后活跃时间不应继续增长',
      );
      expect(
        h.service.todaySessionSeconds,
        h.service.todayActiveSeconds + h.service.todayIdleSeconds,
        reason: '屏幕会话时间 = 活跃 + 空闲',
      );
    });

    test('15. 未应用任何时间的采样延迟不会被全部算成活跃时间', () async {
      await h.tick();
      // 一次 10 秒的采样延迟（小于中断阈值 30 秒，但大于单次计入上限 6 秒）。
      await h.tick(advanceMs: 10000);

      final List<Map<String, Object?>> rows = await h.rows();
      final int active = rows.first['active_seconds']! as int;
      expect(
        active,
        lessThanOrEqualTo(6),
        reason: '单次采样延迟最多只计入 maxCreditPerTickMs',
      );
    });

    test('16. 毫秒余数跨采样累计：1999ms + 2001ms = 4 秒（不逐 tick 丢弃）', () async {
      await h.tick(); // 建立基线并开段
      await h.tick(advanceMs: 1999);
      // 1999ms 不足 2 秒，先记 1 秒 + 999ms 余数。
      expect(h.service.todayActiveSeconds, 1);
      await h.tick(advanceMs: 2001);

      expect(h.service.todayActiveSeconds, 4);
      expect(h.service.todaySessionSeconds, 4);
      expect(h.service.todayIdleSeconds, 0);
      expect(h.service.currentSegmentSeconds, 4);
    });

    test('17. 活跃与空闲混合采样后 session = active + idle', () async {
      final int threshold = h.service.settings.idleThresholdMs;
      await h.tick();
      await h.tick(advanceMs: 1500); // 活跃 1.5s
      await h.tick(
        advanceMs: 1500,
        idle: Duration(milliseconds: threshold + 1500),
      ); // 本 tick 全部空闲 1.5s
      await h.tick(advanceMs: 2501); // 活跃 2.501s

      expect(
        h.service.todaySessionSeconds,
        h.service.todayActiveSeconds + h.service.todayIdleSeconds,
      );
      expect(h.service.todayIdleSeconds, 1);
      expect(h.service.todayActiveSeconds, 4);
      expect(h.service.todaySessionSeconds, 5);
    });

    test('18. 跨午夜按最大余数拆到两天，禁止旧日余数整体转入新日', () async {
      // 2026-09-27 23:59:59.200 → 2026-09-28 00:00:01.200
      // 旧日 800ms / 新日 1200ms：整数秒必须分成旧日 1 秒、新日 1 秒，
      // 不能因为把旧日余数带进新日而变成旧日 0 秒、新日 2 秒。
      h.wall.set(DateTime.utc(2026, 9, 27, 23, 59, 59, 200));
      h.mono.set(1000);
      await h.service.tick(h.build()); // 建立基线并开段

      h.mono.advance(2000);
      h.wall.advance(const Duration(seconds: 2));
      await h.service.tick(h.build());
      await h.service.flushNow();

      final List<Map<String, Object?>> days = await db.raw.query(
        'daily_usage',
        orderBy: 'day_key ASC',
      );
      expect(days, hasLength(2), reason: '跨午夜必须同时留下前后两天的行');
      expect(days[0]['day_key'], '2026-09-27');
      expect(days[1]['day_key'], '2026-09-28');
      expect(days[0]['session_seconds'], 1, reason: '旧日 800ms 按最大余数分配 1 秒');
      expect(days[1]['session_seconds'], 1, reason: '新日 1200ms 分配 1 秒');
      expect(days[0]['active_seconds'], 1);
      expect(days[1]['active_seconds'], 1);
      expect(
        (days[0]['session_seconds']! as int) +
            (days[1]['session_seconds']! as int),
        2,
        reason: '总秒数不增不减',
      );
    });

    test('18b. 新日拿最大余数后，后续毫秒先偿还 1 秒欠账，不重复累计', () async {
      // 旧日 400ms / 新日 900ms：最大余数归新日 → 旧日 0 秒、新日 1 秒。
      h.wall.set(DateTime.utc(2026, 9, 27, 23, 59, 59, 600));
      h.mono.set(1000);
      await h.service.tick(h.build());

      h.mono.advance(1300);
      h.wall.advance(const Duration(milliseconds: 1300));
      await h.service.tick(h.build());
      await h.service.flushNow();

      List<Map<String, Object?>> days = await db.raw.query(
        'daily_usage',
        orderBy: 'day_key ASC',
      );
      expect(days[0]['session_seconds'], 0);
      expect(days[1]['session_seconds'], 1);

      // 新日再走 200ms：前 100ms 偿还新日提前拿到的 1 秒，剩余 100ms 还不够进位。
      h.mono.advance(200);
      h.wall.advance(const Duration(milliseconds: 200));
      await h.service.tick(h.build());
      await h.service.flushNow();

      days = await db.raw.query('daily_usage', orderBy: 'day_key ASC');
      expect(days[1]['session_seconds'], 1, reason: '不得把偿还期内的毫秒再累计成第 2 秒');
    });

    test('19. 空闲发生后 lastActiveAt 停在活跃区间末端，不落在空闲末端', () async {
      final int threshold = h.service.settings.idleThresholdMs;
      await h.tick();
      await h.tick();
      await h.tick(
        advanceMs: 2000,
        idle: Duration(milliseconds: threshold + 1000),
      );

      final DateTime wallNow = h.nowWall;
      expect(h.service.todayLastActiveAt, isNotNull);
      expect(
        h.service.todayLastActiveAt,
        wallNow.subtract(const Duration(milliseconds: 1000)),
        reason: 'lastActiveAt 必须减去 idleOverMs，不能写成采样结束时刻',
      );
    });
  });
}

/// 记录本地变更通知的测试替身。
class RecordingChangeSink implements LocalChangeSink {
  final List<String> segments = <String>[];

  @override
  Future<void> onSegmentChanged(String segmentId) async {
    segments.add(segmentId);
  }

  @override
  Future<void> onDailyUsageChanged({
    required String deviceLocalId,
    required String dayKey,
  }) async {}

  @override
  Future<void> onApplicationChanged(String appKey) async {}
}

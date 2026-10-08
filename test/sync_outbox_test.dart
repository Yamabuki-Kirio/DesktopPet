import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:petlife/core/constants.dart';
import 'package:petlife/database/app_database.dart';
import 'package:petlife/database/dao/sync_outbox_dao.dart';
import 'package:petlife/database/schema.dart';
import 'package:petlife/sync/models/sync_models.dart';
import 'package:petlife/sync/outbox_producer.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/sqlite_test_bootstrap.dart';

/// Outbox（待同步队列）：写入、确认、失败保留、幂等、历史回填、快照语义。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SqliteTestBootstrap.ensureLoaded();

  const String owner = AppConstants.localOwnerId;
  const String device = AppConstants.localDeviceId;
  const String serverDevice = '11111111-1111-4111-8111-111111111111';
  const int t0 = 1767225600000;

  late Directory tmp;
  late AppDatabase db;
  late SyncOutboxDao outbox;
  late OutboxProducer producer;

  setUpAll(() {
    tmp = Directory.systemTemp.createTempSync('petlife_outbox_test');
  });

  tearDownAll(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  setUp(() async {
    await AppDatabase.close();
    db = await AppDatabase.open(
      path: p.join(tmp.path, 'outbox_${DateTime.now().microsecondsSinceEpoch}.db'),
    );
    outbox = SyncOutboxDao(db.raw);
    producer = OutboxProducer(db: db, outbox: outbox, ownerId: owner);
  });

  tearDown(() async {
    await AppDatabase.close();
  });

  // --- 测试数据 ---

  Future<void> seedSegment({
    String id = 'segment-1',
    String appKey = 'code',
    int activeSeconds = 60,
    String? endReason = 'foreground_changed',
  }) async {
    await db.raw.insert(
      DbSchema.tableActivitySegments,
      <String, Object?>{
        'id': id,
        'owner_id': owner,
        'device_local_id': device,
        'app_key': appKey,
        'app_name': appKey,
        'process_name': '$appKey.exe',
        'started_at': t0,
        'ended_at': t0 + activeSeconds * 1000,
        'active_seconds': activeSeconds,
        'end_reason': endReason,
        'sync_status': 'pending',
        'created_at': t0,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> seedDaily({
    String dayKey = '2026-01-01',
    int active = 3000,
    int idle = 600,
  }) async {
    await db.raw.insert(
      DbSchema.tableDailyUsage,
      <String, Object?>{
        'owner_id': owner,
        'device_local_id': device,
        'day_key': dayKey,
        'session_seconds': active + idle,
        'active_seconds': active,
        'idle_seconds': idle,
        'first_active_at': t0,
        'last_active_at': t0 + 3600000,
        'updated_at': t0,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> seedApplication({String appKey = 'code', String category = 'development'}) async {
    await db.raw.insert(
      DbSchema.tableApplications,
      <String, Object?>{
        'app_key': appKey,
        'display_name': 'Visual Studio Code',
        'process_name': 'Code.exe',
        'executable_path': r'C:\Program Files\Microsoft VS Code\Code.exe',
        'category': category,
        'user_overridden': 0,
        'excluded': 0,
        'first_seen_at': t0,
        'last_seen_at': t0,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // --- 用例 ---

  test('活动段入队后出现在待同步队列里', () async {
    await seedSegment();
    expect(await outbox.pendingCount(), 0);

    await producer.enqueueSegment('segment-1');
    expect(await outbox.pendingCount(), 1);

    final List<OutboxEntry> batch =
        await outbox.takeBatch(limit: 10, now: DateTime.now().add(const Duration(days: 1)));
    expect(batch, hasLength(1));
    expect(batch.first.entityType, SyncEntityType.activitySegment);
    expect(batch.first.entityKey, 'segment-1');
    expect(batch.first.isPending, isTrue);
  });

  test('同一记录重复入队只保留一条，且快照被刷新（幂等排队）', () async {
    await seedSegment(activeSeconds: 60);
    await producer.enqueueSegment('segment-1');
    final String payload1 = (await _only(outbox)).payloadJson;

    // 本地数据变化后再次入队
    await seedSegment(activeSeconds: 120);
    await producer.enqueueSegment('segment-1');
    await producer.enqueueSegment('segment-1');

    expect(await outbox.pendingCount(), 1, reason: '同一记录不得重复排队');
    final OutboxEntry entry = await _only(outbox);
    expect(entry.payloadJson, isNot(payload1), reason: '快照应被刷新为最新');
    expect(entry.payloadJson, contains('120'));
  });

  test('每日用量入队使用 <device>:<day> 作为业务键', () async {
    await seedDaily();
    await producer.enqueueDailyUsage(deviceLocalId: device, dayKey: '2026-01-01');
    final OutboxEntry entry = await _only(outbox);
    expect(entry.entityType, SyncEntityType.dailyUsage);
    expect(entry.entityKey, 'desktop.local:2026-01-01');

    // 换一天 → 新记录
    await seedDaily(dayKey: '2026-01-02');
    await producer.enqueueDailyUsage(deviceLocalId: device, dayKey: '2026-01-02');
    expect(await outbox.pendingCount(), 2);
  });

  test('推送时重建的每日用量是完整快照，不是增量累加', () async {
    await seedDaily(active: 3000, idle: 600);
    await producer.enqueueDailyUsage(deviceLocalId: device, dayKey: '2026-01-01');
    final OutboxEntry entry = await _only(outbox);

    // 本地累计继续增长（模拟又过了一个检查点）
    await seedDaily(active: 3600, idle: 900);

    final Map<String, Object?>? payload =
        await producer.buildPayload(entry, serverDeviceId: serverDevice);
    expect(payload, isNotNull);
    expect(payload!['device_id'], serverDevice);
    expect(payload['local_day'], '2026-01-01');
    // 快照语义：直接反映本地当前值，而不是 3000+3600
    expect(payload['active_seconds'], 3600);
    expect(payload['idle_seconds'], 900);
    expect(payload['session_seconds'], 4500);
    expect(payload['timezone_offset_minutes'], isA<int>());
  });

  test('上传体只包含允许的字段（不含本地路径等隐私内容）', () async {
    await seedApplication();
    await producer.enqueueApplication('code');
    final OutboxEntry entry = await _only(outbox);

    final Map<String, Object?> payload =
        (await producer.buildPayload(entry, serverDeviceId: serverDevice))!;
    expect(payload.keys.toSet(), <String>{
      'app_key',
      'display_name',
      'category',
      'user_overridden',
      'updated_at',
    }, reason: '应用记录只允许上传这四个数据字段');

    await seedSegment();
    await producer.enqueueSegment('segment-1');
    final OutboxEntry segmentEntry =
        (await outbox.takeBatch(limit: 10, now: DateTime.now().add(const Duration(days: 1))))
            .firstWhere((OutboxEntry e) => e.entityType == SyncEntityType.activitySegment);
    final Map<String, Object?> segmentPayload =
        (await producer.buildPayload(segmentEntry, serverDeviceId: serverDevice))!;

    expect(segmentPayload['app_key'], 'code');
    expect(segmentPayload['category'], 'development');
    for (final String banned in <String>[
      'window_title',
      'url',
      'document_name',
      'file_path',
      'executable_path',
      'process_name',
      'screenshot',
    ]) {
      expect(segmentPayload.containsKey(banned), isFalse, reason: '不得上传 $banned');
    }
    expect('${segmentPayload['started_at']}', endsWith('Z'));
  });

  test('服务端确认后才标记完成，重复确认是幂等的', () async {
    await seedSegment();
    await producer.enqueueSegment('segment-1');
    final OutboxEntry entry = await _only(outbox);

    final int first =
        await outbox.acknowledge(<String>[entry.id], at: DateTime.now());
    expect(first, 1);
    expect(await outbox.pendingCount(), 0);

    // 重复确认不再影响任何行
    final int second =
        await outbox.acknowledge(<String>[entry.id], at: DateTime.now());
    expect(second, 0);
    expect(await outbox.countAcknowledged(), 1);
  });

  test('失败记录必须保留，只更新重试时间与次数', () async {
    await seedSegment();
    await producer.enqueueSegment('segment-1');
    final OutboxEntry entry = await _only(outbox);

    final DateTime now = DateTime.now();
    await outbox.markFailed(
      <String>[entry.id],
      error: '连不上服务端',
      nextAttemptAt: now.add(const Duration(seconds: 15)),
    );

    expect(await outbox.pendingCount(), 1, reason: '失败绝不能丢数据');
    final OutboxEntry after = await _only(outbox);
    expect(after.attemptCount, 1);
    expect(after.lastError, '连不上服务端');
    expect(after.nextAttemptAt!.isAfter(now), isTrue);

    // 还没到重试时间 → 取不到
    expect(await outbox.takeBatch(limit: 10, now: now), isEmpty);
    // 到了重试时间 → 可以取到
    expect(
      await outbox.takeBatch(limit: 10, now: now.add(const Duration(seconds: 16))),
      hasLength(1),
    );
  });

  test('本地记录已不存在时 buildPayload 返回 null（引擎据此直接确认）', () async {
    await seedSegment();
    await producer.enqueueSegment('segment-1');
    final OutboxEntry entry = await _only(outbox);

    await db.raw.delete(
      DbSchema.tableActivitySegments,
      where: 'id = ?',
      whereArgs: <Object?>['segment-1'],
    );

    expect(await producer.buildPayload(entry, serverDeviceId: serverDevice), isNull);
  });

  test('历史数据首次登录后全量入队，且重复回填是幂等的', () async {
    await seedSegment(id: 'segment-1');
    await seedSegment(id: 'segment-2', appKey: 'chrome');
    await seedDaily(dayKey: '2026-01-01');
    await seedDaily(dayKey: '2026-01-02');
    await seedApplication(appKey: 'code');
    await seedApplication(appKey: 'chrome', category: 'browser');

    final int first = await producer.enqueueHistory();
    expect(first, 6, reason: '2 段 + 2 天 + 2 个应用');
    expect(await outbox.pendingCount(), 6);

    // 再次回填不应产生重复
    final int second = await producer.enqueueHistory();
    expect(second, 6);
    expect(await outbox.pendingCount(), 6, reason: '重复回填必须幂等');
  });

  test('按类型统计待同步数量', () async {
    await seedSegment();
    await seedDaily();
    await seedApplication();
    await producer.enqueueSegment('segment-1');
    await producer.enqueueDailyUsage(deviceLocalId: device, dayKey: '2026-01-01');
    await producer.enqueueApplication('code');
    await producer.enqueueApplication('code'); // 重复

    final Map<SyncEntityType, int> counts = await outbox.pendingCountByType();
    expect(counts[SyncEntityType.activitySegment], 1);
    expect(counts[SyncEntityType.dailyUsage], 1);
    expect(counts[SyncEntityType.application], 1);
    expect(await outbox.pendingCount(), 3);
  });

  test('清理已确认的历史记录，未确认的绝不被删', () async {
    await seedSegment(id: 'segment-1');
    await seedSegment(id: 'segment-2');
    await producer.enqueueSegment('segment-1');
    await producer.enqueueSegment('segment-2');

    final List<OutboxEntry> batch =
        await outbox.takeBatch(limit: 10, now: DateTime.now().add(const Duration(days: 1)));
    await outbox.acknowledge(
      <String>[batch.first.id],
      at: DateTime.now().subtract(const Duration(days: 2)),
    );

    final int removed = await outbox.deleteAcknowledgedBefore(
      DateTime.now().subtract(const Duration(days: 1)),
    );
    expect(removed, 1);
    expect(await outbox.pendingCount(), 1);
  });
}

Future<OutboxEntry> _only(SyncOutboxDao dao) async {
  final List<OutboxEntry> rows =
      await dao.takeBatch(limit: 10, now: DateTime.now().add(const Duration(days: 30)));
  expect(rows, hasLength(1));
  return rows.first;
}

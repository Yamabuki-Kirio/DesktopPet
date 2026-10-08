import 'dart:async';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../core/ids.dart';
import '../core/logger.dart';
import '../database/app_database.dart';
import '../database/dao/sync_outbox_dao.dart';
import '../database/schema.dart';
import '../platform/overlay_pet.dart';
import '../sync/models/sync_models.dart';
import '../sync/outbox_producer.dart';
import 'android_usage_session.dart';
import 'application_repository.dart';
import 'models/activity_enums.dart';

/// 一次导入的结果（供界面与日志展示）。
class AndroidUsageImportResult {
  const AndroidUsageImportResult({
    this.read = 0,
    this.inserted = 0,
    this.alreadyImported = 0,
    this.acknowledged = 0,
    this.skipped = 0,
    this.failed = false,
    this.error,
  });

  /// 从 journal 读到的条数。
  final int read;

  /// 本次**真正新增**的活动段条数。
  final int inserted;

  /// 已存在（上次导入过、只是没来得及确认）的条数 —— 视为已导入，不覆盖、不累加。
  final int alreadyImported;

  /// 事务成功后被原生确认（从 journal 删除）的条数。
  final int acknowledged;

  /// 解析失败被跳过的条数。
  final int skipped;

  final bool failed;
  final String? error;

  bool get isEmpty => read == 0;

  /// 日志/诊断用的一行摘要。
  String get summaryZh =>
      '读取 $read，新增 $inserted，已存在 $alreadyImported，确认 $acknowledged，跳过 $skipped';
}

/// Android 原生使用会话的**幂等导入器**（Phase 4C-5.1B，需求 §6 / §7）。
///
/// 单向链路（不回头）：
/// ```
/// 原生 journal（已结束会话）
///   → 本服务读取并校验
///   → activity_segments（确定性 ID + INSERT OR IGNORE）
///   → sync_outbox（与业务行**同事务**提交）
///   → 事务成功后才原生确认（删除 journal 记录）
/// ```
///
/// 四条硬性保证：
/// 1. **单任务互斥**：所有触发点（冷启动 / 页面打开 / 同步前 / 生命周期恢复）
///    都进同一个导入器，同一时刻只有一个导入在跑（需求 §7）；
/// 2. **不重复累计**：段 ID = `uuidv5(device_local_id + session_id)`，
///    并且使用 `INSERT OR IGNORE`（**绝不**用会删旧行的 `INSERT OR REPLACE`）；
/// 3. **先提交后确认**：事务提交成功之前绝不调用 `acknowledgeUsageSessions`；
/// 4. **失败不阻塞**：任何异常只记日志并保留 journal，下次触发继续重试。
class AndroidUsageImportService {
  AndroidUsageImportService({
    required AndroidOverlayPet overlay,
    required AppDatabase database,
    required SyncOutboxDao outboxDao,
    required OutboxProducer outboxProducer,
    required ApplicationRepository applications,
    required this.ownerId,
    required this.deviceLocalId,
    this.batchLimit = 200,
  })  : _overlay = overlay,
        _database = database,
        _outboxDao = outboxDao,
        _outboxProducer = outboxProducer,
        _applications = applications;

  final AndroidOverlayPet _overlay;
  final AppDatabase _database;
  final SyncOutboxDao _outboxDao;
  final OutboxProducer _outboxProducer;
  final ApplicationRepository _applications;

  /// 本地数据所有者（与采集层一致）。
  final String ownerId;

  /// 本机稳定设备标识（Android = 安装 UUID）；导入时写进 `device_local_id`。
  final String deviceLocalId;

  /// 单次导入最多处理多少条（避免一次传输过大）。
  final int batchLimit;

  Future<AndroidUsageImportResult>? _inFlight;

  DateTime? _lastImportAt;
  String? _lastError;
  int _lastInserted = 0;
  int _importRunCount = 0;

  /// 是否有导入正在进行（界面据此避免重复触发）。
  bool get isImporting => _inFlight != null;

  /// 最近一次导入完成时间。
  DateTime? get lastImportAt => _lastImportAt;

  /// 最近一次导入的错误（成功后清空）。
  String? get lastError => _lastError;

  /// 最近一次导入新增的条数。
  int get lastInsertedCount => _lastInserted;

  /// 导入被触发的次数（诊断）。
  int get importRunCount => _importRunCount;

  // ---------------------------------------------------------------------------
  // 与原生对齐（设备标识 + 暂停状态）
  // ---------------------------------------------------------------------------

  /// 启动时把"本机设备标识"与"是否暂停采集"同步给原生。
  ///
  /// 原生即使在没有 Flutter 的情况下继续运行，也必须知道这两件事：
  /// 前者决定 journal 记录的归属，后者决定要不要新建会话。
  Future<void> initialize({required bool paused}) async {
    try {
      await _overlay.updateUsageIdentity(deviceLocalId);
      await _overlay.setUsageCollectionPaused(paused);
      Loggers.activity.info(
        '已向原生同步使用采集身份与暂停状态（paused=$paused，device=$deviceLocalId）',
      );
    } catch (e, st) {
      // 同步失败不影响本地采集与桌宠；下一次保存设置或重启会再试。
      Loggers.activity.warning('向原生同步采集身份失败（不影响桌宠）', e, st);
    }
  }

  /// 记录采集暂停开关变化（需求 §9：界面、原生采集状态、本地设置三者一致）。
  Future<void> syncCollectionPaused(bool paused) async {
    try {
      await _overlay.setUsageCollectionPaused(paused);
    } catch (e, st) {
      Loggers.activity.warning('同步采集暂停状态失败', e, st);
    }
  }

  /// 读取原生采集器状态（设置页诊断区）。
  Future<UsageCollectorState> collectorState() async {
    try {
      return await _overlay.usageCollectorState();
    } catch (e, st) {
      Loggers.activity.warning('读取原生采集器状态失败', e, st);
      return UsageCollectorState.unsupported;
    }
  }

  // ---------------------------------------------------------------------------
  // 导入
  // ---------------------------------------------------------------------------

  /// 导入一批待处理会话。**单任务互斥**：并发调用复用同一次导入。
  Future<AndroidUsageImportResult> importPending() async {
    final Future<AndroidUsageImportResult>? existing = _inFlight;
    if (existing != null) {
      Loggers.activity.fine('已有导入任务在进行中，复用当前任务');
      return existing;
    }
    final Future<AndroidUsageImportResult> task = _runOnce();
    _inFlight = task;
    try {
      return await task;
    } finally {
      if (identical(_inFlight, task)) _inFlight = null;
    }
  }

  Future<AndroidUsageImportResult> _runOnce() async {
    _importRunCount++;
    try {
      final List<AndroidUsageSession> pending =
          await _overlay.readPendingUsageSessions(limit: batchLimit);
      if (pending.isEmpty) {
        _lastImportAt = DateTime.now();
        _lastError = null;
        _lastInserted = 0;
        return const AndroidUsageImportResult();
      }
      Loggers.activity.info('usage.journal_import_started count=${pending.length}');

      // 0) 归属过滤：**别的设备标识**的记录不属于本机统计，导入进来会污染本设备的数据，
      //    而且它永远无法被正确导入 → 确认掉，避免永久堵在 FIFO 队头。
      //    （设备标识为空的记录是"下发前产生的"，按本机处理，由本端补齐归属。）
      final List<AndroidUsageSession> sessions = <AndroidUsageSession>[];
      final List<String> foreignSessionIds = <String>[];
      for (final AndroidUsageSession session in pending) {
        if (session.deviceLocalId.isNotEmpty && session.deviceLocalId != deviceLocalId) {
          foreignSessionIds.add(session.sessionId);
          continue;
        }
        sessions.add(session);
      }
      if (foreignSessionIds.isNotEmpty) {
        Loggers.activity.warning(
          '跳过 ${foreignSessionIds.length} 条非本机设备标识的使用记录'
          '（不属于 $deviceLocalId，已从暂存队列移除）',
        );
        await _overlay.acknowledgeUsageSessions(foreignSessionIds);
      }
      if (sessions.isEmpty) {
        _lastImportAt = DateTime.now();
        _lastError = null;
        _lastInserted = 0;
        return AndroidUsageImportResult(read: pending.length, skipped: foreignSessionIds.length);
      }

      // 1) 先登记应用（显示名 / 分类）—— 上传体的 category 来自应用库，
      //    因此必须在构建 payload 之前完成。
      for (final AndroidUsageSession session in sessions) {
        await _applications.ensureSeenFromPlatform(
          appKey: session.packageName,
          displayName: session.appName,
          category: _categoryOf(session.category),
          at: session.startedAt,
        );
      }

      // 2) 构建业务行与待同步条目（**确定性 ID** → 重复导入必然撞主键）。
      final List<Map<String, Object?>> rows = <Map<String, Object?>>[];
      final List<String> nativeSessionIds = <String>[];
      final List<OutboxEntry> entries = <OutboxEntry>[];
      for (final AndroidUsageSession session in sessions) {
        final String segmentId = Ids.usageSession(deviceLocalId, session.sessionId);
        final Map<String, Object?> row = <String, Object?>{
          'id': segmentId,
          'owner_id': ownerId,
          'device_local_id': deviceLocalId,
          'app_key': session.packageName,
          'app_name': session.appName ?? session.packageName,
          'process_name': session.packageName,
          'started_at': session.startedAt.millisecondsSinceEpoch,
          'ended_at': session.endedAt.millisecondsSinceEpoch,
          'active_seconds': session.activeSeconds,
          'end_reason': session.endReason,
          'sync_status': 'pending',
          'created_at': session.createdAt.millisecondsSinceEpoch,
        };
        rows.add(row);
        nativeSessionIds.add(session.sessionId);
        entries.add(OutboxEntry(
          id: Ids.random(),
          entityType: SyncEntityType.activitySegment,
          entityKey: segmentId,
          entityLocalId: segmentId,
          payload: (await _outboxProducer.buildPayloadFromRow(
                SyncEntityType.activitySegment,
                row,
              )) ??
              const <String, Object?>{},
          createdAt: DateTime.now(),
        ));
      }

      // 3) 一个事务里提交"业务行 + outbox"：
      //    要么都成功、要么都不写，绝不留"段落库了但没排队"的中间态。
      int inserted = 0;
      await _database.raw.transaction((Transaction txn) async {
        for (final Map<String, Object?> row in rows) {
          final int rowId = await txn.insert(
            DbSchema.tableActivitySegments,
            row,
            // 关键：`INSERT OR IGNORE`，**绝不用** `ConflictAlgorithm.replace`
            // （那会删掉同 ID 的旧行，等于"重复导入时覆盖"）。
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
          if (rowId != 0) inserted++;
        }
        await _outboxDao.enqueueAllWith(txn, entries);
      });
      Loggers.activity.info(
        'usage.outbox_enqueued count=${entries.length}（其中新增段 $inserted）',
      );

      // 4) 事务成功之后才确认原生记录（顺序反了会丢数据）。
      final int acknowledged = await _overlay.acknowledgeUsageSessions(nativeSessionIds);

      _lastImportAt = DateTime.now();
      _lastError = null;
      _lastInserted = inserted;
      final AndroidUsageImportResult result = AndroidUsageImportResult(
        read: pending.length,
        inserted: inserted,
        alreadyImported: sessions.length - inserted,
        acknowledged: acknowledged + foreignSessionIds.length,
        skipped: foreignSessionIds.length,
      );
      Loggers.activity.info('usage.journal_import_completed ${result.summaryZh}');
      return result;
    } catch (e, st) {
      // 失败**保留 journal**（不确认），不阻塞启动，下次触发继续重试。
      _lastError = '$e';
      Loggers.activity.warning('usage.journal_import_failed（记录保留，稍后重试）', e, st);
      return AndroidUsageImportResult(failed: true, error: '$e');
    }
  }

  /// `AppCategory.wireName` → 枚举；未知或缺失一律归入 `other`（与既有口径一致）。
  static AppCategory? _categoryOf(String? wireName) {
    if (wireName == null || wireName.isEmpty) return null;
    for (final AppCategory category in AppCategory.values) {
      if (category.wireName == wireName) return category;
    }
    return null;
  }
}

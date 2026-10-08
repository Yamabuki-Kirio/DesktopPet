import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/constants.dart';
import '../core/logger.dart';
import '../database/dao/sync_outbox_dao.dart';
import '../database/dao/sync_state_dao.dart';
import 'api_client.dart';
import 'authenticated_api.dart';
import 'models/sync_models.dart';
import 'outbox_producer.dart';
import 'sync_preferences.dart';

/// 同步引擎（需求「六、同步引擎」）。
///
/// 设计要点
/// --------
/// * **单任务互斥（同一会话内）**：同一时刻只允许一个同步在跑。计时器重入、
///   手动点击、启动触发同时发生时，后到的调用会复用正在进行的那个 future，
///   而不会启动第二个任务。**跨会话不复用**：重新登录时必须能立刻开始
///   新会话的首次同步，且旧任务不得再改写新会话的状态。
/// * **退避不丢数据**：失败只更新 `next_attempt_at` 与 `attempt_count`，
///   记录仍在 outbox 里，网络恢复后继续传。
/// * **不阻塞**：所有网络调用都在后台；本地采集与桌宠渲染完全不受影响。
///   退出前的快速同步有严格超时，宁可少传一批也不卡住退出。
/// * **认证失效只有一个责任方**：`AuthenticatedApi`（见
///   [SyncEngine._handleFailure] 的说明），引擎从不自己清令牌。
/// * **暴露给 UI 的状态**：`signedOut / idle / syncing / success /
///   waitingForNetwork / needsReauthentication / failed`。
class SyncEngine extends ChangeNotifier {
  SyncEngine({
    required AuthenticatedApi api,
    required SyncOutboxDao outboxDao,
    required SyncStateDao stateDao,
    required OutboxProducer producer,
    required SyncPreferences preferences,
    Future<void> Function()? beforePush,
    DateTime Function()? clock,
    List<Duration>? backoffSteps,
    Duration? periodicInterval,
  })  : _api = api,
        _outbox = outboxDao,
        _stateDao = stateDao,
        _producer = producer,
        _preferences = preferences,
        _beforePush = beforePush,
        _clock = clock ?? DateTime.now,
        _backoffSteps = backoffSteps ?? defaultBackoffSteps,
        _periodicInterval = periodicInterval ?? SyncConfig.periodicInterval;

  final AuthenticatedApi _api;
  final SyncOutboxDao _outbox;
  final SyncStateDao _stateDao;
  final OutboxProducer _producer;
  final SyncPreferences _preferences;

  /// 推送**之前**执行一次的钩子（Phase 4C-5.1B）。
  ///
  /// 用来把"还没落库的本地数据"先补进库与 outbox —— Android 原生 journal 里的
  /// 使用会话就是通过它进入同步链路的（需求 §7："开始同步之前"也要尝试导入）。
  /// 钩子失败**不影响同步**：由实现方自己吞掉异常并记日志。
  final Future<void> Function()? _beforePush;

  final DateTime Function() _clock;
  final List<Duration> _backoffSteps;
  final Duration _periodicInterval;

  /// 默认退避阶梯：5s → 15s → 1min → 5min → 15min（与需求一致）。
  static final List<Duration> defaultBackoffSteps = SyncConfig.backoffSeconds
      .map((int s) => Duration(seconds: s))
      .toList(growable: false);

  // --- 对外状态 ---

  SyncStatus _status = SyncStatus.signedOut;
  DateTime? _lastSuccessAt;
  String? _lastError;
  int _pendingCount = 0;
  int _consecutiveFailures = 0;
  DateTime? _nextRetryAt;
  String? _lastRejectedNote;

  /// 最近一次同步的**上行 / 下行条数**（增量 C2，需求 §8.1 摘要）。
  ///
  /// 只用于给用户看"上传 N 条、下载 M 条"；**不参与任何业务判定**，
  /// 因此即使数值缺失也不影响同步语义。
  int _lastUploadedCount = 0;
  int _lastDownloadedCount = 0;

  SyncStatus get status => _status;
  DateTime? get lastSuccessAt => _lastSuccessAt;
  String? get lastError => _lastError;
  int get pendingCount => _pendingCount;
  int get consecutiveFailures => _consecutiveFailures;
  DateTime? get nextRetryAt => _nextRetryAt;

  /// 最近一次同步中被服务端拒收的记录说明（最多展示一条）。
  String? get lastRejectedNote => _lastRejectedNote;

  bool get isSyncing => _status == SyncStatus.syncing;

  /// 最近一次同步上传成功的记录条数（需求 §8.1）。
  int get lastUploadedCount => _lastUploadedCount;

  /// 最近一次同步拉取到的记录条数（需求 §8.1）。
  int get lastDownloadedCount => _lastDownloadedCount;

  /// 最近一次同步的一句话摘要（需求 §8.1 的文案来源）。
  ///
  /// 形如 `上传 12 条，下载 4 条`；两边都为 0 时返回 `没有需要同步的数据`。
  String get lastRunSummary {
    final int up = _lastUploadedCount;
    final int down = _lastDownloadedCount;
    if (up == 0 && down == 0) return '没有需要同步的数据';
    return '上传 $up 条，下载 $down 条';
  }

  // --- 内部 ---

  Timer? _periodicTimer;
  Timer? _retryTimer;
  Future<void>? _inFlight;

  /// 上面那次同步所属的会话代次（[SyncEngine] 侧的 epoch）。
  int? _inFlightEpoch;

  /// 会话代次：每次登录成功（[onSignedIn]）与退出登录（[onSignedOut]）都 +1。
  ///
  /// 它解决两件事：
  /// * 登录时若还有**上一个会话**的同步任务在飞，新会话必须能立刻开始自己的
  ///   首次同步，而不是被旧任务挡住（复用旧 future 会让首次同步永远不发生）；
  /// * 旧任务随后无论成功还是失败，都不该再改写新会话的界面状态。
  int _sessionEpoch = 0;

  bool _disposed = false;
  bool _needsHistoryBackfill = false;

  /// 该代次是否已经被替换（登录 / 退出登录发生在其之后）。
  bool _isStaleEpoch(int epoch) => epoch != _sessionEpoch;

  /// 可测试的退避计算：第 `failures` 次失败后应等待多久。
  static Duration computeBackoff(int failures, {List<Duration>? steps}) {
    final List<Duration> ladder = steps ?? defaultBackoffSteps;
    if (ladder.isEmpty) return const Duration(seconds: 5);
    final int index = (failures <= 0 ? 1 : failures) - 1;
    final Duration value = index >= ladder.length ? ladder.last : ladder[index];
    final Duration cap = ladder.last;
    return value > cap ? cap : value;
  }

  // ---------------------------------------------------------------------------
  // 生命周期
  // ---------------------------------------------------------------------------

  /// 启动：恢复状态、注册定时器，并按当前登录状态决定是否立即同步。
  Future<void> start() async {
    await refreshPendingCount();
    await _restoreStateFromDb();
    _periodicTimer?.cancel();
    _periodicTimer = Timer.periodic(_periodicInterval, (_) {
      // 定时器重入不会启动第二个任务：syncNow 内部有互斥。
      unawaited(syncNow(trigger: 'periodic'));
    });
    if (_api.isSignedIn) {
      await _onSignedInInternal();
    } else {
      _setStatus(SyncStatus.signedOut);
    }
  }

  Future<void> stop() async {
    _periodicTimer?.cancel();
    _periodicTimer = null;
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  @override
  void dispose() {
    _disposed = true;
    _periodicTimer?.cancel();
    _retryTimer?.cancel();
    _periodicTimer = null;
    _retryTimer = null;
    super.dispose();
  }

  Future<void> _restoreStateFromDb() async {
    final List<SyncStateRow> rows = await _stateDao.loadAll();
    if (rows.isEmpty) return;
    final SyncStateRow newest = rows.reduce((SyncStateRow a, SyncStateRow b) =>
        a.updatedAt.isAfter(b.updatedAt) ? a : b);
    _lastSuccessAt = newest.lastSuccessAt;
    _lastError = newest.lastError;
    _consecutiveFailures = newest.consecutiveFailures;
    _nextRetryAt = newest.nextRetryAt;
  }

  // ---------------------------------------------------------------------------
  // 触发时机
  // ---------------------------------------------------------------------------

  /// 登录成功后调用：切换会话代次，首次做历史回填，然后立刻同步一次。
  Future<void> onSignedIn() async {
    // 新会话：推进代次。旧会话仍在飞的任务从此既不会阻塞这次同步，
    // 也不会再改写新会话的界面状态。
    _sessionEpoch += 1;
    _retryTimer?.cancel();
    _retryTimer = null;
    await _onSignedInInternal();
  }

  Future<void> _onSignedInInternal() async {
    try {
      final String? userId = _api.lastAccount?.userId;
      if (userId != null) {
        final String? marker = await _preferences.historyBackfillMarker();
        if (marker != userId) {
          _needsHistoryBackfill = true;
        }
      }
      await refreshPendingCount();
    } catch (e, st) {
      Loggers.sync.warning('准备首次同步失败', e, st);
    }
    await syncNow(trigger: 'signIn');
  }

  /// 手动点击「立即同步」。
  ///
  /// 手动触发会**解除退避**：用户明确要求现在同步，不该被上次失败的等待时间挡住。
  Future<void> syncNow({String trigger = 'manual', bool manual = false}) async {
    if (manual) {
      await _clearBackoff();
    }
    await _syncOnce(trigger: trigger);
  }

  /// 网络恢复：解除退避并立刻尝试。
  Future<void> onNetworkRestored() async {
    if (!_api.isSignedIn) return;
    await _clearBackoff();
    await _syncOnce(trigger: 'networkRestored');
  }

  /// 退出前的快速同步：**严格超时**，超时就放弃，绝不卡住退出流程。
  Future<void> syncOnShutdown() async {
    if (!_api.isSignedIn) return;
    final Future<void> task = _syncOnce(trigger: 'shutdown');
    try {
      await task.timeout(SyncConfig.shutdownTimeout);
    } on TimeoutException {
      // 超时后那个请求可能仍在飞，之后才失败。这里挂一个吞异常的回调，
      // 否则会变成"未处理的异步异常"，在退出路径上很难排查。
      unawaited(task.then<void>((_) {}, onError: (Object _) {}));
      Loggers.sync.info('退出前同步超时（${SyncConfig.shutdownTimeout.inSeconds}s），已放弃，数据留在本地');
    } catch (e, st) {
      Loggers.sync.fine('退出前同步失败（忽略）', e, st);
    }
  }

  /// 退出登录时调用：清空内存状态。
  Future<void> onSignedOut() async {
    // 推进代次：在途的旧任务从此不再影响任何状态
    _sessionEpoch += 1;
    _retryTimer?.cancel();
    _retryTimer = null;
    await refreshPendingCount();
    _setStatus(SyncStatus.signedOut);
  }

  // ---------------------------------------------------------------------------
  // 核心
  // ---------------------------------------------------------------------------

  /// 单任务互斥：**同一会话代次内**已在跑就直接复用，不启动第二个。
  ///
  /// 跨代次不复用：登录时若旧会话的任务还卡在网络上，复用它等于让新会话
  /// 永远等不到自己的首次同步（而且那次同步用的还是旧令牌）。
  Future<void> _syncOnce({required String trigger}) async {
    final int epoch = _sessionEpoch;
    final Future<void>? existing = _inFlight;
    if (existing != null) {
      if (_inFlightEpoch == epoch) {
        // 手动/启动触发的调用等待当前任务即可（不会叠加请求）
        Loggers.sync.fine('已有同步任务在进行中，复用当前任务（trigger=$trigger）');
        return existing;
      }
      Loggers.sync.info(
        '存在上一个会话遗留的同步任务，为其启动新的同步（trigger=$trigger）',
      );
    }
    final Future<void> task = _run(trigger: trigger, epoch: epoch);
    _inFlight = task;
    _inFlightEpoch = epoch;
    try {
      await task;
    } finally {
      // 只清自己登记的：后来者可能已经登记了新的任务
      if (identical(_inFlight, task)) {
        _inFlight = null;
        _inFlightEpoch = null;
      }
    }
  }

  Future<void> _run({required String trigger, required int epoch}) async {
    if (_disposed) return;
    if (!_api.isSignedIn) {
      _setStatus(SyncStatus.signedOut);
      return;
    }

    _retryTimer?.cancel();
    _retryTimer = null;
    _setStatus(SyncStatus.syncing);
    // 每次真正开始一轮同步都重置摘要素数（需求 §8.1：摘要必须对应当前这一轮）。
    _lastUploadedCount = 0;
    _lastDownloadedCount = 0;
    Loggers.sync.fine('开始同步（trigger=$trigger，会话=$epoch，待同步=$_pendingCount）');

    try {
      if (_needsHistoryBackfill) {
        await _producer.enqueueHistory();
        final String? userId = _api.lastAccount?.userId;
        if (userId != null) {
          await _preferences.setHistoryBackfillMarker(userId);
        }
        _needsHistoryBackfill = false;
        await refreshPendingCount();
      }

      // Phase 4C-5.1B：把"还没落库的本地采集"补进来（Android 原生 journal）。
      // 钩子内部自己吞异常，这里不再包 try —— 它不该让同步失败。
      final Future<void> Function()? beforePush = _beforePush;
      if (beforePush != null) {
        await beforePush();
        await refreshPendingCount();
      }

      await _pushAll();
      await _pull();

      final DateTime now = _clock();
      for (final SyncEntityType type in SyncEntityType.values) {
        await _stateDao.recordSuccess(type, cursor: await _pullCursor(), at: now);
      }
      if (_isStaleEpoch(epoch)) {
        // 这次任务属于已被替换的会话：数据工作照做，但**不覆盖**新会话的界面状态
        Loggers.sync.fine('会话已更换，本次同步不更新界面状态（trigger=$trigger）');
        return;
      }
      _consecutiveFailures = 0;
      _nextRetryAt = null;
      _lastError = null;
      _lastSuccessAt = now;
      await refreshPendingCount();
      _setStatus(SyncStatus.success);
      Loggers.sync.info('同步完成（trigger=$trigger，剩余待同步=$_pendingCount）');
    } on ApiException catch (e) {
      await _safeHandleFailure(e, epoch: epoch);
    } catch (e, st) {
      Loggers.sync.warning('同步出现未预期错误', e, st);
      await _safeHandleFailure(
        ApiException(
          kind: SyncFailureKind.unknown,
          message: '同步失败：$e',
        ),
        epoch: epoch,
      );
    }
  }

  /// 失败处理本身也可能出错（例如数据库正在关闭）。
  /// 这里兜住，保证同步引擎永远不向调用方抛异常。
  Future<void> _safeHandleFailure(ApiException e, {required int epoch}) async {
    try {
      await _handleFailure(e, epoch: epoch);
    } catch (inner, st) {
      Loggers.sync.fine('记录同步失败信息时出错（已忽略）', inner, st);
    }
  }

  /// 分批推送，直到队列清空或达到单次上限。
  Future<void> _pushAll() async {
    final String deviceId = await _api.ensureDeviceId();

    for (int round = 0; round < SyncConfig.maxBatchesPerRun; round++) {
      final List<OutboxEntry> batch = await _outbox.takeBatch(
        limit: SyncConfig.maxBatchSize,
        now: _clock(),
      );
      if (batch.isEmpty) return;

      // 推送时重建 payload：每日用量永远是"当前完整快照"，不是增量。
      final Map<SyncEntityType, List<Map<String, Object?>>> records =
          <SyncEntityType, List<Map<String, Object?>>>{};
      final List<String> vanished = <String>[];

      for (final OutboxEntry entry in batch) {
        final Map<String, Object?>? payload =
            await _producer.buildPayload(entry, serverDeviceId: deviceId);
        if (payload == null) {
          // 本地记录已不存在（例如活动段被清理）：直接确认，不做无意义重试。
          vanished.add(entry.id);
          continue;
        }
        records.putIfAbsent(entry.entityType, () => <Map<String, Object?>>[]).add(payload);
      }

      if (vanished.isNotEmpty) {
        await _outbox.acknowledge(vanished, at: _clock());
        Loggers.sync.fine('已确认 ${vanished.length} 条本地已不存在的记录');
      }
      if (records.isEmpty) continue;

      final PushOutcome outcome = await _api.send(
        (String token, String _) =>
            _api.push(accessToken: token, deviceId: deviceId, records: records),
      );

      await _applyPushOutcome(batch, outcome);
    }

    Loggers.sync.warning('单次同步达到批次上限（${SyncConfig.maxBatchesPerRun}），剩余留待下次');
  }

  /// 根据 push 结果确认或标记失败。
  Future<void> _applyPushOutcome(List<OutboxEntry> batch, PushOutcome outcome) async {
    final Map<String, RejectedRecord> rejectedByKey = <String, RejectedRecord>{
      for (final RejectedRecord r in outcome.rejected) '${r.kind}:${r.key}': r,
    };

    final DateTime now = _clock();
    final List<String> toAcknowledge = <String>[];
    final List<String> retryable = <String>[];
    final StringBuffer notes = StringBuffer();

    for (final OutboxEntry entry in batch) {
      final RejectedRecord? rejected =
          rejectedByKey['${entry.entityType.wireName}:${entry.entityKey}'];
      if (rejected == null) {
        toAcknowledge.add(entry.id);
        continue;
      }
      if (rejected.code == 'conflict' || rejected.code == 'internal_error') {
        // 可重试：保留记录并退避
        retryable.add(entry.id);
      } else {
        // 不可重试（例如时间范围非法）：丢弃该条但记录原因，避免永远堵住队列
        toAcknowledge.add(entry.id);
      }
      if (notes.isEmpty) {
        notes.write('${rejected.kind}/${rejected.key}: ${rejected.message}');
      }
    }

    final int acked = await _outbox.acknowledge(toAcknowledge, at: now);
    // 需求 §8.1：累计本轮真正被服务端接收的条数（摘要用）。
    _lastUploadedCount += acked;
    if (retryable.isNotEmpty) {
      await _outbox.markFailed(
        retryable,
        error: '服务端暂时拒绝（conflict），稍后重试',
        nextAttemptAt: now.add(computeBackoff(_consecutiveFailures + 1, steps: _backoffSteps)),
      );
    }
    _lastRejectedNote = notes.isEmpty ? null : notes.toString();

    // 服务端返回的游标可以直接作为下次 pull 的起点
    if (outcome.cursor > 0) {
      await _writePullCursor(outcome.cursor, at: now);
    }
    if (acked > 0) {
      Loggers.sync.fine('已确认 $acked 条记录（batch=${batch.length}）');
    }
    await refreshPendingCount();
  }

  /// 增量拉取：推进游标（本地库是这台设备的事实来源，本阶段不回写远端数据）。
  Future<void> _pull() async {
    final int cursor = await _pullCursor();
    final PullOutcome outcome = await _api.send(
      (String token, String deviceId) =>
          _api.pullRaw(accessToken: token, deviceId: deviceId, cursor: cursor),
    );
    if (outcome.cursor > cursor) {
      await _writePullCursor(outcome.cursor, at: _clock());
      // 需求 §8.1：累计本轮拉取到的条数（摘要用）。
      _lastDownloadedCount += outcome.totalRecords;
      Loggers.sync.fine('拉取游标推进：$cursor -> ${outcome.cursor}（${outcome.totalRecords} 条）');
    }
  }

  // ---------------------------------------------------------------------------
  // 失败处理与退避
  // ---------------------------------------------------------------------------

  /// 失败处理。
  ///
  /// 认证失效的**唯一责任边界是 `AuthenticatedApi`**
  /// ---------------------------------------------------
  /// 只有 `AuthenticatedApi` 能清令牌、只有它能置 `needsReauthentication`，
  /// 而且它只在"这个错误确实属于当前会话"时才这么做。
  ///
  /// 因此这里**绝不再自己清一次**：
  /// * 如果传入的错误来自已被替换的旧会话（登录 / 退出登录已经换了代次），
  ///   或 `AuthenticatedApi` 判定当前会话仍然有效，那就说明它**没有**置位 ——
  ///   此时若引擎再清一次，就会把刚登录得到的新令牌删掉，
  ///   界面立刻回到「需要重新登录」（这就是本次修复的竞态）；
  /// * 只有当 `AuthenticatedApi` 确实置位（真的失效了）时，引擎才把界面状态
  ///   迁移到 [SyncStatus.needsReauthentication]。
  Future<void> _handleFailure(ApiException e, {required int epoch}) async {
    if (_isStaleEpoch(epoch)) {
      // 旧会话遗留任务的失败：与当前会话无关，不记失败、不改状态
      Loggers.sync.info('忽略已失效会话的同步失败（不改变当前状态）：${e.message}');
      return;
    }

    if (e.kind.needsReauth && !_api.needsReauthentication) {
      Loggers.sync.info(
        '忽略不属于当前会话的认证错误（令牌保持不动）：${e.message}',
      );
      return;
    }

    _consecutiveFailures += 1;
    _lastError = e.message;

    if (e.kind.needsReauth) {
      // 设备被撤销 / Refresh Token 失效：**令牌已由 AuthenticatedApi 清理**，
      // 这里只负责界面状态与退避。本地采集继续运行（采集完全在本地）。
      _nextRetryAt = null;
      await _recordFailure(e.message, SyncStatus.needsReauthentication);
      Loggers.sync.warning('同步进入「需要重新登录」：${e.message}');
      return;
    }

    if (e.kind.retryable) {
      final Duration delay = computeBackoff(_consecutiveFailures, steps: _backoffSteps);
      final DateTime next = _clock().add(delay);
      _nextRetryAt = next;
      // 区分「网络问题」与「服务端问题」：前者用户只需等待网络，
      // 后者说明服务端出了状况 —— UI 上的措辞与处置建议不同。
      final SyncStatus nextStatus = e.kind.isNetworkIssue
          ? SyncStatus.waitingForNetwork
          : SyncStatus.failed;
      await _recordFailure(e.message, nextStatus);
      _scheduleRetry(delay);
      Loggers.sync.info(
        '同步失败将重试（第 $_consecutiveFailures 次，${delay.inSeconds}s 后）：${e.message}',
      );
      return;
    }

    _nextRetryAt = null;
    await _recordFailure(e.message, SyncStatus.failed);
    Loggers.sync.warning('同步失败（不重试）：${e.message}');
  }

  Future<void> _recordFailure(String error, SyncStatus status) async {
    final DateTime now = _clock();
    for (final SyncEntityType type in SyncEntityType.values) {
      await _stateDao.recordFailure(
        type,
        error: error,
        consecutiveFailures: _consecutiveFailures,
        nextRetryAt: _nextRetryAt ?? now,
        at: now,
      );
    }
    // 失败路径同样要刷新「待同步数量」：界面上必须能看到还有多少条在等，
    // 否则同步失败时用户会误以为数据已经传完。
    await refreshPendingCount();
    _setStatus(status);
  }

  void _scheduleRetry(Duration delay) {
    _retryTimer?.cancel();
    _retryTimer = Timer(delay, () => unawaited(_syncOnce(trigger: 'retry')));
  }

  Future<void> _clearBackoff() async {
    final DateTime now = _clock();
    for (final SyncEntityType type in SyncEntityType.values) {
      await _stateDao.clearBackoff(type, at: now);
    }
    _consecutiveFailures = 0;
    _nextRetryAt = null;
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  // ---------------------------------------------------------------------------
  // 游标
  // ---------------------------------------------------------------------------

  /// 拉取游标：三类实体共用同一个服务端游标，取其中最小值作为统一起点。
  Future<int> _pullCursor() async {
    final List<SyncStateRow> rows = await _stateDao.loadAll();
    if (rows.isEmpty) return 0;
    return rows.map((SyncStateRow r) => r.cursor).reduce((int a, int b) => a < b ? a : b);
  }

  Future<void> _writePullCursor(int cursor, {required DateTime at}) async {
    for (final SyncEntityType type in SyncEntityType.values) {
      final SyncStateRow? existing = await _stateDao.load(type);
      if (existing != null && existing.cursor >= cursor) continue;
      await _stateDao.save(SyncStateRow(
        entityType: type,
        cursor: cursor,
        lastSuccessAt: existing?.lastSuccessAt,
        lastError: existing?.lastError,
        consecutiveFailures: existing?.consecutiveFailures ?? 0,
        nextRetryAt: existing?.nextRetryAt,
        updatedAt: at,
      ));
    }
  }

  // ---------------------------------------------------------------------------
  // UI 辅助
  // ---------------------------------------------------------------------------

  Future<void> refreshPendingCount() async {
    try {
      _pendingCount = await _outbox.pendingCount();
    } catch (e, st) {
      Loggers.sync.fine('统计待同步数量失败', e, st);
    }
    _notify();
  }

  /// 只通知、不改状态（用于入队后刷新 UI 的待同步数量）。
  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  void _setStatus(SyncStatus value) {
    if (_status == value) {
      _notify();
      return;
    }
    _status = value;
    _notify();
  }
}

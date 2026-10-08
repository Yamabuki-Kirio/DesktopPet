package asia.akechi.petlife.overlay

/**
 * 原生侧的应用使用会话（Phase 4C-5.1B）。
 *
 * 为什么必须有这一层：
 * 4C-5 的前台识别只驱动**桌宠状态**（切换素材），一条记录都不写；
 * 而 Flutter 退出后 Dart 侧的 SQLite 写入全部不可用（`AppDatabase.close()`），
 * 所以"Flutter 没在跑的时候"仍然必须有人把使用时长记下来 —— 那就是这里。
 *
 * 数据流（单向，不回头）：
 * ```
 * ForegroundAppRegistry（4C-5.1A 的共享快照，唯一检测入口）
 *   └─ AndroidUsageSessionTracker（本文件：纯逻辑状态机）
 *        └─ UsageSessionJournal（filesDir 下的暂存队列，先落盘再算成功）
 *             └─ Flutter 幂等导入 → activity_segments → sync_outbox → 服务端
 * ```
 *
 * 三条硬性约束：
 * 1. **不再查 `UsageStatsManager`** —— 只读共享快照，绝不新增第二个轮询器；
 * 2. 时间一律 UTC epoch 毫秒；`activeSeconds` 不允许为负；
 * 3. journal 里**不含**任何账户 / 令牌 / 服务端设备 ID（只含本地设备标识）。
 */

/** journal 记录的结构版本；Flutter 侧遇到不认识的版本会跳过该条并记日志。 */
internal const val USAGE_SESSION_SCHEMA_VERSION = 1

/**
 * 会话结束原因。
 *
 * 取值即 Flutter 侧 `activity_segments.end_reason` 的 wire 值（**同一套命名，禁止另起一套**）。
 *
 * 关于需求里建议的 `device_locked`：Android 上 `ACTION_SCREEN_OFF` 是熄屏与锁屏
 * **共用的唯一广播**，系统不会告诉应用"只是息屏"还是"还锁上了"，
 * 因此这里统一记 `screen_off`，不伪造一个区分不出来的原因（需求 §3.3 是"建议"取值）。
 */
internal enum class UsageSessionEndReason(val wire: String) {
    /** 切到了另一个应用（正常的 A → B）。 */
    appSwitch("app_switch"),

    /** 熄屏 / 锁屏（同一广播）。 */
    screenOff("screen_off"),

    /** 悬浮服务被停止。 */
    serviceStopped("service_stopped"),

    /** 用户暂停了采集。 */
    collectionPaused("collection_paused"),

    /** 使用情况访问权限被撤销。 */
    permissionRevoked("permission_revoked"),

    /** 前台结果持续不可用，超过容错窗口。 */
    collectorUnavailable("collector_unavailable"),

    /** 进程异常终止后重新启动，按最后一次可靠时间补齐关闭。 */
    processRecovery("process_recovery"),
}

/** 一条**已结束**的会话（journal 的存储单位）。 */
internal data class UsageSessionRecord(
    /** 原生生成、在同一次会话的所有重放里保持不变 → Flutter 侧据此做幂等导入。 */
    val sessionId: String,
    /** 本机稳定设备标识（由 Flutter 下发并持久化；未下发时为空串）。 */
    val deviceLocalId: String,
    /** 包名（Flutter 侧映射为 `app_key`）。 */
    val packageName: String,
    /** 应用标签（可为空 —— 拿不到就如实为空，不编）。 */
    val appName: String?,
    /** 分类（`AppCategoryId.wireName`）。 */
    val category: String?,
    /** 开始时间（UTC epoch 毫秒）。 */
    val startedAt: Long,
    /** 结束时间（UTC epoch 毫秒，恒 ≥ [startedAt]）。 */
    val endedAt: Long,
    /** 有效秒数（恒 ≥ 0）。 */
    val activeSeconds: Int,
    /** 结束原因（[UsageSessionEndReason.wire]）。 */
    val endReason: String,
    /** 记录创建时间（UTC epoch 毫秒）。 */
    val createdAt: Long,
    val schemaVersion: Int = USAGE_SESSION_SCHEMA_VERSION,
)

/** 进行中的会话（内存态；同时是"开放会话检查点"的落盘内容）。 */
internal data class OpenUsageSession(
    val sessionId: String,
    val packageName: String,
    val appName: String?,
    val category: String?,
    val startedAt: Long,
    /**
     * 已经计入到哪个时刻（毫秒）。
     *
     * 与 `activeMillis` 一起构成"不重复计入同一段时间"的不变式：
     * 每次计入都是 `now - creditUpToMs`，随后把 `creditUpToMs` 前移。
     */
    var creditUpToMs: Long,
    /** 已累计的有效毫秒数。 */
    var activeMillis: Long,
    val createdAt: Long,
) {
    /** 转成待落盘的结束记录（`endedAt` 不得早于开始时间）。 */
    fun toRecord(endReason: UsageSessionEndReason, endedAtMs: Long, deviceLocalId: String): UsageSessionRecord {
        val safeEnd = endedAtMs.coerceAtLeast(startedAt)
        val seconds = (activeMillis / 1000L).coerceAtLeast(0L).coerceAtMost(Int.MAX_VALUE.toLong())
        return UsageSessionRecord(
            sessionId = sessionId,
            deviceLocalId = deviceLocalId,
            packageName = packageName,
            appName = appName,
            category = category,
            startedAt = startedAt,
            endedAt = safeEnd,
            activeSeconds = seconds.toInt(),
            endReason = endReason.wire,
            createdAt = createdAt,
        )
    }
}

/** 一次观察（由服务从共享快照转换而来）。 */
internal data class UsageObservation(
    /** 当前前台外部应用包名；null = 这一轮没有可用的外部应用（无权限 / 无事件 / 缓存过期）。 */
    val packageName: String?,
    val appName: String?,
    val category: String?,
    /**
     * 是否**计入普通应用时长**。
     *
     * 桌面（launcher）与系统界面按需求 §3.3 不计入，但它们出现在前台时
     * **仍然要结束上一个普通应用会话** —— 因此这里是独立的布尔量，
     * 而不是把包名置空。
     */
    val countable: Boolean,
    val observedAt: Long,
)

/** 会话状态机的时间参数（集中配置，不散落硬编码）。 */
internal data class UsageSessionConfig(
    /** 同一应用被连续观察到时，单次最多计入多少毫秒（防止卡顿被算成使用时间）。 */
    val maxCreditPerObservationMs: Long = 3 * 1_500L,

    /** 切换确认窗口：新应用要稳定出现这么久才真正切段（抑制快速切换碎片）。 */
    val switchConfirmMs: Long = 1_500L,

    /** 前台结果不可用时的容错窗口；超过才结束会话。 */
    val unavailableToleranceMs: Long = 6_000L,

    /** 小于该秒数的会话直接丢弃（避免大量 1~2 秒碎片），记 `usage.session.discard`。 */
    val minSessionSeconds: Int = 2,
)

/**
 * 应用会话状态机（**纯逻辑**，不依赖任何 Android API）。
 *
 * 真机行为由 `PetOverlayService` 驱动，全部用例可在 JVM 单测里用虚拟时间打靶 ——
 * 与 4C-5 的 `ForegroundAppResolver` 是同一套可测试性策略。
 */
internal class AndroidUsageSessionTracker(
    private val config: UsageSessionConfig = UsageSessionConfig(),
    /** 会话 ID 工厂（注入以便单测断言确定性）。 */
    private val idFactory: () -> String,
    /** 本机稳定设备标识（Flutter 下发；未下发时为空串）。 */
    private val deviceLocalId: () -> String,
    /** 记录创建时间来源。 */
    private val clock: () -> Long,
) {

    /** 当前进行中的会话。 */
    var open: OpenUsageSession? = null
        private set

    /** 采集是否已暂停（暂停期间不新建会话、不累计）。 */
    var paused: Boolean = false
        private set

    /** 已结束但还没写进 journal 的会话（由宿主在每次调用后取走）。 */
    private val completed = ArrayList<UsageSessionRecord>(4)

    /** 待确认的新应用候选。 */
    private var candidatePackage: String? = null
    private var candidateSince: Long = 0

    /** 前台不可用窗口的起点（0 = 不在窗口内）。 */
    private var unavailableSince: Long = 0

    // -----------------------------------------------------------------------
    // 对外查询
    // -----------------------------------------------------------------------

    /** 当前会话已持续的秒数（按 `now` 实时计算，用于界面「使用中」）。 */
    fun currentElapsedSeconds(now: Long): Int {
        val session = open ?: return 0
        val total = session.activeMillis + (now - session.creditUpToMs).coerceAtLeast(0L)
        return (total / 1000L).coerceAtLeast(0L).coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
    }

    // -----------------------------------------------------------------------
    // 观察
    // -----------------------------------------------------------------------

    /**
     * 处理一次前台观察，返回**本次新完成**（已结束）的会话。
     *
     * 调用方负责：把返回值写进 journal、以及按需写开放会话检查点。
     */
    fun observe(observation: UsageObservation): List<UsageSessionRecord> {
        completed.clear()
        val now = observation.observedAt
        if (paused) return emptyList()

        val target = observation.packageName?.trim().orEmpty()
        if (target.isEmpty()) {
            handleUnavailable(now)
            return drain()
        }

        // 前台不可用窗口结束：拿回结果就重置容错计时。
        unavailableSince = 0L

        // 与当前会话是同一个应用 → 直接延长（不产生任何切换候选）。
        val session = open
        if (session != null && session.packageName == target) {
            clearCandidate()
            credit(session, now)
            return drain()
        }

        // 目前没有任何会话在计时：没有碎片可抑制，**直接开段**。
        // 延迟开段只会白丢这段时间（与 Windows 采集器的既有结论一致）。
        if (session == null) {
            clearCandidate()
            if (observation.countable) {
                open = begin(
                    packageName = target,
                    appName = observation.appName,
                    category = observation.category,
                    startedAt = now,
                )
            }
            return drain()
        }

        // 已有会话在计时、且前台换成了别的应用：必须经过"切换确认"，
        // 避免系统过渡页 / 快速切换切出碎片。
        if (candidatePackage != target) {
            candidatePackage = target
            candidateSince = now
            // 新应用第一次被看到的时刻之前，前台仍是旧应用 → 先把它记到位。
            credit(session, now)
            return drain()
        }

        // 候选已存在：还没稳定够 → **不再给旧会话计入**。
        //
        // 这一步很关键：新应用从"候选首次出现"那一刻起算，因此确认切换时
        // 旧会话必须恰好结束在同一时刻，否则会出现 1 秒左右的重叠计数。
        // 候选最终被证伪（又变回旧应用）时，`credit()` 会从 creditUpTo 一次性补齐，
        // 因此这段时间不会白丢。
        if (now - candidateSince < config.switchConfirmMs) {
            return drain()
        }

        // 确认切换：旧会话结束于"候选首次出现"的时刻（与已计入的时间一致）。
        val switchAt = candidateSince
        closeOpen(session, UsageSessionEndReason.appSwitch, switchAt)?.let { completed += it }
        clearCandidate()

        // 新应用是桌面 / 系统界面 → 只结束不新开（需求 §3.3）。
        if (observation.countable) {
            open = begin(
                packageName = target,
                appName = observation.appName,
                category = observation.category,
                startedAt = switchAt,
            )
        }
        return drain()
    }

    // -----------------------------------------------------------------------
    // 显式结束（这些信号不需要切换确认，立即生效）
    // -----------------------------------------------------------------------

    /** 熄屏 / 锁屏。 */
    fun onScreenOff(now: Long): List<UsageSessionRecord> = endNow(UsageSessionEndReason.screenOff, now)

    /** 服务被停止 / 服务销毁。 */
    fun onServiceStopped(now: Long): List<UsageSessionRecord> = endNow(UsageSessionEndReason.serviceStopped, now)

    /** 使用情况访问权限被撤销。 */
    fun onPermissionRevoked(now: Long): List<UsageSessionRecord> =
        endNow(UsageSessionEndReason.permissionRevoked, now)

    /** 暂停采集：立即结束当前会话，之后不再新建。 */
    fun onPaused(now: Long): List<UsageSessionRecord> {
        val records = endNow(UsageSessionEndReason.collectionPaused, now)
        paused = true
        return records
    }

    /** 恢复采集：从**下一个**稳定前台应用开始新会话，不补算暂停期间。 */
    fun onResumed() {
        paused = false
        clearCandidate()
        unavailableSince = 0L
    }

    /**
     * 进程重启后的恢复：把上次遗留的开放会话按 [UsageSessionEndReason.processRecovery] 关闭。
     *
     * 结束时间取**检查点里的最后一次可靠时间**，绝不把进程离线期间算成使用时长（需求 §4.2）。
     * 返回 null 表示这是一段不足 [UsageSessionConfig.minSessionSeconds] 的碎片（已丢弃）。
     */
    fun recover(recovered: OpenUsageSession): UsageSessionRecord? {
        open = null
        clearCandidate()
        unavailableSince = 0L
        val record = recovered.toRecord(
            endReason = UsageSessionEndReason.processRecovery,
            endedAtMs = recovered.creditUpToMs,
            deviceLocalId = deviceLocalId(),
        )
        if (record.activeSeconds < config.minSessionSeconds) {
            Log.log(
                "usage.session.discard id=${record.sessionId} pkg=${record.packageName} " +
                    "seconds=${record.activeSeconds} reason=${record.endReason}",
            )
            return null
        }
        Log.record("usage.session.recovered", record)
        return record
    }

    // -----------------------------------------------------------------------
    // 内部
    // -----------------------------------------------------------------------

    private fun handleUnavailable(now: Long) {
        clearCandidate()
        val session = open ?: return
        if (unavailableSince == 0L) {
            unavailableSince = now
            return
        }
        if (now - unavailableSince < config.unavailableToleranceMs) return
        // 超过容错窗口：以**最后一次可靠检测时间**结束，不含无法确认的那段时间。
        closeOpen(session, UsageSessionEndReason.collectorUnavailable, session.creditUpToMs)
            ?.let { completed += it }
        unavailableSince = 0L
    }

    private fun endNow(reason: UsageSessionEndReason, now: Long): List<UsageSessionRecord> {
        completed.clear()
        clearCandidate()
        unavailableSince = 0L
        val session = open
        if (session != null) {
            credit(session, now)
            closeOpen(session, reason, now)?.let { completed += it }
        }
        return drain()
    }

    /** 计入 `[creditUpToMs, now]`（夹在 [UsageSessionConfig.maxCreditPerObservationMs] 内）。 */
    private fun credit(session: OpenUsageSession, now: Long) {
        val delta = now - session.creditUpToMs
        if (delta <= 0L) return
        val credited = delta.coerceAtMost(config.maxCreditPerObservationMs)
        session.activeMillis += credited
        session.creditUpToMs = now
    }

    private fun begin(
        packageName: String,
        appName: String?,
        category: String?,
        startedAt: Long,
    ): OpenUsageSession {
        val created = clock()
        val session = OpenUsageSession(
            sessionId = idFactory(),
            packageName = packageName,
            appName = appName,
            category = category,
            startedAt = startedAt,
            creditUpToMs = startedAt,
            activeMillis = 0L,
            createdAt = created,
        )
        Log.log(
            "usage.session.started id=${session.sessionId} pkg=$packageName " +
                "at=$startedAt category=${category ?: "-"}",
        )
        return session
    }

    /**
     * 结束当前会话；返回 null 表示这是一段**碎片**（短于 [UsageSessionConfig.minSessionSeconds]），
     * 已按需求 §3.4 丢弃并记日志。
     */
    private fun closeOpen(
        session: OpenUsageSession,
        reason: UsageSessionEndReason,
        endedAtMs: Long,
    ): UsageSessionRecord? {
        open = null
        val record = session.toRecord(reason, endedAtMs, deviceLocalId())
        if (record.activeSeconds < config.minSessionSeconds) {
            // 碎片丢弃：不写 journal，但要在日志里能看见（需求 §3.4）。
            Log.log(
                "usage.session.discard id=${record.sessionId} pkg=${record.packageName} " +
                    "seconds=${record.activeSeconds} reason=${record.endReason}",
            )
            return null
        }
        Log.record("usage.session.ended", record)
        return record
    }

    /** 取出本次产生的记录。 */
    private fun drain(): List<UsageSessionRecord> {
        if (completed.isEmpty()) return emptyList()
        val out = completed.toList()
        completed.clear()
        return out
    }

    private fun clearCandidate() {
        candidatePackage = null
        candidateSince = 0
    }

    /** 结构化日志（需求 §12：只记 ID / 包名 / 时间 / 时长，不记任何隐私内容）。 */
    internal object Log {
        fun log(message: String) = OverlayLog.log(message)

        fun record(event: String, record: UsageSessionRecord) {
            OverlayLog.log(
                "$event id=${record.sessionId} pkg=${record.packageName} " +
                    "from=${record.startedAt} to=${record.endedAt} " +
                    "seconds=${record.activeSeconds} reason=${record.endReason}",
            )
        }
    }
}

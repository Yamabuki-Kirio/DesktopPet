package asia.akechi.petlife.overlay

import android.app.AppOpsManager
import android.app.usage.UsageEvents
import android.app.usage.UsageStats
import android.app.usage.UsageStatsManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Process
import android.provider.Settings
import java.util.concurrent.TimeUnit

/**
 * 前台应用快照（只读）。
 *
 * **只包含包名与应用标签** —— 需求 §5 明确禁止读取屏幕内容 / 输入内容 /
 * 通知内容 / 聊天内容 / 文件内容 / 浏览器页面标题 / 无障碍节点。
 */
internal data class ForegroundAppSnapshot(
    val packageName: String,
    val appLabel: String?,
    val observedAt: Long,
    /**
     * 分类（Phase 4C-6A）。
     *
     * 由**检测侧**算一次并随快照传播：状态判定（[PetStateMonitor]）、
     * 使用会话采集与界面（设置页 / 统计页）读到的因此是**同一份分类**。
     * 之前"状态判定自己再算一遍"会让诊断显示的分类与实际生效的分类可能不一致。
     */
    val category: String? = null,
    /** 分类来源（`AppCategorySource.wire`）。 */
    val categorySource: String? = null,
    /** 系统声明的分类值（`ApplicationInfo.category`，API 26+）；诊断用，拿不到为 null。 */
    val platformCategory: Int? = null,
)

/**
 * 一条前台事件（只保留判定需要的三个字段）。
 *
 * 与 `UsageEvents.Event` 分开建模的原因：这样"筛选与排序"就是**纯函数**，
 * 可以在 JVM 单测里逐条打靶（真机 4C-5 复验缺陷 C 的全部 15 条用例都是这么测的）。
 */
internal data class ForegroundEventRecord(
    val packageName: String,
    val eventType: Int,
    val timestampMs: Long,
)

/** 一条候选（来自事件流或使用统计兜底）。 */
internal data class ForegroundCandidate(
    val packageName: String,
    val timestampMs: Long,
    val label: String?,
    val eventType: Int?,
)

/** 前台应用的**判定来源**（诊断用；兜底结果绝不伪装成精确事件）。 */
internal enum class ForegroundDetectionSource(val wire: String) {
    /** 来自 `queryEvents` 的 ACTIVITY_RESUMED / MOVE_TO_FOREGROUND 事件。 */
    activityEvents("activity-events"),

    /** 事件流无可用项，退回到 `queryUsageStats`（按 `lastTimeUsed`）。 */
    usageStatsFallback("usage-stats-fallback"),

    /** 本轮没有任何新信息，沿用最近一次有效外部应用（分屏/返回设置页场景）。 */
    cache("cache"),

    unavailable("unavailable"),
}

/** 一次检测的完整诊断（需求 §6）。 */
internal data class ForegroundDiagnostics(
    val usageAccessGranted: Boolean,
    val appOpsAllowed: Boolean,
    val queryStart: Long,
    val queryEnd: Long,
    val eventCount: Int,
    val resumedEventCount: Int,
    val usableEventCount: Int,
    val statsCount: Int,
    val lastRawPackage: String?,
    val lastExternalPackage: String?,
    val lastExternalEventType: Int?,
    val lastExternalEventTime: Long,
    val detectionSource: String,
    val detectionFailureReason: String?,
)

/** 一次检测的结果。 */
internal data class ForegroundAppReading(
    val snapshot: ForegroundAppSnapshot?,
    val source: ForegroundDetectionSource,
    /** 使用情况访问是否可用（false → 上层按需求 §6 回退默认状态）。 */
    val usageAccessAvailable: Boolean,
    /** 判定原因 / 失败原因（诊断与日志）。 */
    val reason: String?,
    val diagnostics: ForegroundDiagnostics,
)

/**
 * 前台应用来源（需求 §5）。
 *
 * 抽成接口的目的：真机走 [AndroidForegroundAppSource]，单测注入固定脚本，
 * 状态判定逻辑因此完全不依赖 Android。
 */
internal interface ForegroundAppSource {

    /**
     * 读取当前前台应用。
     *
     * @param now 当前时间（毫秒）；由调用方传入，便于用虚拟时间测试缓存过期。
     */
    fun read(now: Long): ForegroundAppReading
}

/** 构造一份"读不到"的结果（诊断字段保持自洽，避免界面显示错乱）。 */
internal fun unavailableReading(now: Long, reason: String): ForegroundAppReading =
    ForegroundAppReading(
        snapshot = null,
        source = ForegroundDetectionSource.unavailable,
        usageAccessAvailable = false,
        reason = reason,
        diagnostics = ForegroundDiagnostics(
            usageAccessGranted = false,
            appOpsAllowed = false,
            queryStart = now,
            queryEnd = now,
            eventCount = 0,
            resumedEventCount = 0,
            usableEventCount = 0,
            statsCount = 0,
            lastRawPackage = null,
            lastExternalPackage = null,
            lastExternalEventType = null,
            lastExternalEventTime = 0L,
            detectionSource = ForegroundDetectionSource.unavailable.wire,
            detectionFailureReason = reason,
        ),
    )

/**
 * 使用情况访问权限（Usage Access）。
 *
 * 与悬浮窗权限（`SYSTEM_ALERT_WINDOW`）**是两项独立权限**：
 * 缺使用情况访问只影响"状态联动"，桌宠仍能正常显示、播放动画、用默认状态。
 */
internal object UsageAccess {

    /** 读取前台应用所需的 AppOps 名称。 */
    private const val OPSTR_GET_USAGE_STATS = "android:get_usage_stats"

    /**
     * AppOps 是否明确返回 `MODE_ALLOWED`（**只用于诊断**）。
     *
     * 真机 4C-5 复验教训：不能只靠这一条判定"有没有权限" ——
     * 个别 ROM 在用户已在系统设置里授权的情况下仍返回 `MODE_DEFAULT`。
     * 因此权限判定走 [isGranted]（含"确实能读到数据"的兜底验证）。
     */
    @Suppress("DEPRECATION")
    fun appOpsAllowed(context: Context): Boolean {
        return try {
            val appOps = context.getSystemService(Context.APP_OPS_SERVICE) as? AppOpsManager
                ?: return false
            val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                // Q 起 `checkOpNoThrow` 被 `unsafeCheckOpNoThrow` 取代（后者不做权限前置检查）。
                appOps.unsafeCheckOpNoThrow(
                    OPSTR_GET_USAGE_STATS,
                    Process.myUid(),
                    context.packageName,
                )
            } else {
                appOps.checkOpNoThrow(
                    OPSTR_GET_USAGE_STATS,
                    Process.myUid(),
                    context.packageName,
                )
            }
            mode == AppOpsManager.MODE_ALLOWED
        } catch (t: Throwable) {
            false
        }
    }

    /**
     * 使用情况访问是否**真的可用**：AppOps 允许，或 AppOps 口径不准但确实能读到使用数据。
     *
     * 任何异常一律按"未授权"处理（绝不崩）。
     */
    fun isGranted(context: Context): Boolean {
        if (appOpsAllowed(context)) return true
        return hasUsageStats(context)
    }

    /** 兜底：直接问系统能否取到使用数据（覆盖个别 ROM 的 AppOps 口径差异）。 */
    fun hasUsageStats(context: Context): Boolean {
        return try {
            val manager = context.getSystemService(Context.USAGE_STATS_SERVICE) as? UsageStatsManager
                ?: return false
            val now = System.currentTimeMillis()
            val stats = manager.queryUsageStats(
                UsageStatsManager.INTERVAL_DAILY,
                now - TimeUnit.HOURS.toMillis(6),
                now,
            )
            !stats.isNullOrEmpty()
        } catch (t: Throwable) {
            false
        }
    }

    /**
     * 跳到系统"使用情况访问"设置页。
     *
     * 只能在用户**主动点击**时调用 —— 需求 §6 明确要求"不反复弹系统授权页"。
     */
    fun openSettings(context: Context) {
        val intent = Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val opened = runCatching { context.startActivity(intent) }.isSuccess
        if (opened) return
        // 少数设备没有该页面：退回到本应用的详情页，绝不因此崩溃。
        val fallback = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
            .setData(android.net.Uri.fromParts("package", context.packageName, null))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        runCatching { context.startActivity(fallback) }
    }
}

/**
 * 前台事件的**筛选与选择**（纯逻辑，可 JVM 单测）。
 *
 * 真机 4C-5 复验缺陷 C 的核心教训：
 * **必须"先过滤、再取最新"，而不是"取最新、再看是不是 PetLife"。**
 * 后者在"返回 PetLife 设置页"或"分屏里 PetLife 也在前台"时，最后一条事件
 * 往往是 PetLife 自己 → 直接返回 null → 设置页显示"当前应用：-"、状态永远是 default。
 */
internal object ForegroundCandidateSelector {

    /**
     * 事件类型是否代表"应用来到前台"。
     *
     * `MOVE_TO_FOREGROUND`（API 1 起，API 29 起被取代）与 `ACTIVITY_RESUMED`（API 29 起）
     * **数值相同（1）**，但语义不同、且部分 ROM 只回报其中一个 ——
     * 因此两个常量都显式比较，绝不"只处理旧事件"。
     */
    @Suppress("DEPRECATION")
    fun isForegroundEventType(type: Int): Boolean =
        type == UsageEvents.Event.MOVE_TO_FOREGROUND ||
            type == UsageEvents.Event.ACTIVITY_RESUMED

    /**
     * 不应参与状态联动的包（需求 §2.5）。
     *
     * * **SystemUI**：下拉通知栏、最近任务、音量条都会产生 RESUMED，不代表用户换应用；
     * * **输入法**：弹出键盘会让输入法进入前台；
     * * **权限控制器 / android 自身**：系统弹窗。
     *
     * 刻意**不包含**桌面（launcher）与系统设置：
     * 验收要求里"切到桌面 / 系统设置"要能判定为系统类状态（→ `default`），
     * 把它们过滤掉会让状态卡在上一个应用上，反而不符合验收预期。
     */
    private val exactNoise: Set<String> = setOf(
        "com.android.systemui",
        "com.android.permissioncontroller",
        "android",
        "com.google.android.packageinstaller",
        "com.android.packageinstaller",
        "com.google.android.inputmethod.latin",
        "com.baidu.input",
        "com.sohu.inputmethod.sogou",
        "com.tencent.qqpinyin",
        "com.iflytek.inputmethod",
    )

    /** 包名关键字启发（覆盖各厂商输入法的包名差异）。 */
    private val noiseKeywords: List<String> = listOf(
        "inputmethod",
        "systemui",
        ".ime",
    )

    /** 是否属于"不应参与状态联动"的包。 */
    fun isNoise(packageName: String): Boolean {
        val key = packageName.trim().lowercase()
        if (key.isEmpty()) return true
        if (exactNoise.contains(key)) return true
        return noiseKeywords.any { key.contains(it) }
    }

    /** 是否是一个**有效**的外部候选（非空、非自己、非系统噪声）。 */
    fun isUsable(packageName: String?, selfPackage: String): Boolean {
        val key = packageName?.trim().orEmpty()
        if (key.isEmpty()) return false
        if (key.equals(selfPackage, ignoreCase = true)) return false
        return !isNoise(key)
    }

    /**
     * 在事件流里挑出**最后一个有效的外部应用事件**。
     *
     * 顺序很重要：先按事件类型筛出前台候选 → 再逐个过滤（自己 / 空包名 / 系统噪声）
     * → 最后取时间戳最大的那一条。
     */
    fun selectLatest(
        events: List<ForegroundEventRecord>,
        selfPackage: String,
    ): ForegroundCandidate? = events
        .asSequence()
        .filter { isForegroundEventType(it.eventType) }
        .filter { isUsable(it.packageName, selfPackage) }
        .maxByOrNull { it.timestampMs }
        ?.let {
            ForegroundCandidate(
                packageName = it.packageName.trim(),
                timestampMs = it.timestampMs,
                label = null,
                eventType = it.eventType,
            )
        }

    /** `queryUsageStats` 兜底：按 `lastTimeUsed` 取最近的有效外部应用。 */
    fun selectLatestFromStats(
        stats: List<ForegroundCandidate>,
        selfPackage: String,
    ): ForegroundCandidate? = stats
        .asSequence()
        .filter { isUsable(it.packageName, selfPackage) }
        .maxByOrNull { it.timestampMs }

    /** 窗口内最后一条前台事件（**未过滤**，用于诊断"最后一条到底是谁"）。 */
    fun lastForegroundEvent(events: List<ForegroundEventRecord>): ForegroundEventRecord? =
        events.asSequence()
            .filter { isForegroundEventType(it.eventType) }
            .maxByOrNull { it.timestampMs }
}

/** 检测的时间参数（集中成常量，便于调整与测试）。 */
internal object ForegroundWindow {

    /** 事件查询窗口：覆盖"刚刚切过来"的应用；更长的时间由使用统计兜底负责。 */
    const val QUERY_WINDOW_MS = 45_000L

    /** 使用统计兜底窗口（`lastTimeUsed` 视角）。 */
    const val STATS_WINDOW_MS = 10 * 60_000L

    /** 最近有效外部应用的缓存有效期；过期后才回退 default。 */
    const val CACHE_TTL_MS = 10 * 60_000L
}

/**
 * 原生查询能力的**抽象**（真机走 [AndroidForegroundAppQuery]，单测注入脚本）。
 *
 * 把"系统怎么给数据"与"怎么筛/怎么兜底"分开，是这一轮修复能被单测覆盖的关键。
 */
internal interface ForegroundAppQuery {

    /** 使用情况访问是否可用（含"确实能读到数据"的兜底验证）。 */
    fun usageAccessAvailable(): Boolean

    /** AppOps 是否明确允许（仅诊断）。 */
    fun appOpsAllowed(): Boolean

    /** 查询窗口内的事件流。 */
    fun queryEvents(begin: Long, end: Long): List<ForegroundEventRecord>

    /** 使用统计兜底（`lastTimeUsed`）。 */
    fun queryUsageStats(begin: Long, end: Long): List<ForegroundCandidate>
}

/**
 * 前台应用的**判定器**（纯逻辑，除 [query] 外不依赖任何 Android API）。
 *
 * 判定顺序（需求 §三 / §四 / §五）：
 * ```
 * 1. 权限不可用            → unavailable + usage-access-missing
 * 2. 事件流里最后一个有效外部应用 → activity-events
 * 3. 没有事件则退到使用统计兜底   → usage-stats-fallback
 * 4. 两者都没有则沿用缓存（有效期内）→ cache（split-screen-last-external）
 * 5. 缓存也过期            → unavailable
 * ```
 *
 * 关键不变式：**只返回"有效外部应用"，绝不因为最后一条是 PetLife / SystemUI
 * 就把结果清空** —— 这是真机缺陷 C 的根因。
 */
internal class ForegroundAppResolver(
    private val query: ForegroundAppQuery,
    private val selfPackage: String,
) : ForegroundAppSource {

    private var cached: ForegroundCandidate? = null

    /** 诊断：最近一次使用的缓存内容。 */
    var cachedCandidate: ForegroundCandidate? = null
        private set

    override fun read(now: Long): ForegroundAppReading {
        val begin = now - ForegroundWindow.QUERY_WINDOW_MS

        // 1. 权限：不可用时**不查询**（避免无意义查询），并给出明确原因。
        val appOps = runCatching { query.appOpsAllowed() }.getOrDefault(false)
        val granted = runCatching { query.usageAccessAvailable() }.getOrDefault(false)
        if (!granted) {
            return reading(
                snapshot = null,
                source = ForegroundDetectionSource.unavailable,
                usageAccessAvailable = false,
                reason = PetStateError.USAGE_ACCESS_MISSING,
                appOps = appOps,
                begin = begin,
                end = now,
                events = emptyList(),
                stats = emptyList(),
                lastRaw = null,
                selected = null,
            )
        }

        // 2. 事件流。
        val events = runCatching { query.queryEvents(begin, now) }.getOrElse { emptyList() }
        val lastRaw = ForegroundCandidateSelector.lastForegroundEvent(events)?.packageName
        val fromEvents = ForegroundCandidateSelector.selectLatest(events, selfPackage)
        if (fromEvents != null) {
            cached = fromEvents
            cachedCandidate = fromEvents
            return reading(
                snapshot = snapshotOf(fromEvents, now),
                source = ForegroundDetectionSource.activityEvents,
                usageAccessAvailable = true,
                reason = null,
                appOps = appOps,
                begin = begin,
                end = now,
                events = events,
                stats = emptyList(),
                lastRaw = lastRaw,
                selected = fromEvents,
            )
        }

        // 3. 使用统计兜底（事件流为空或全是自己/噪声时）。
        val stats = runCatching {
            query.queryUsageStats(now - ForegroundWindow.STATS_WINDOW_MS, now)
        }.getOrElse { emptyList() }
        val fromStats = ForegroundCandidateSelector.selectLatestFromStats(stats, selfPackage)
        if (fromStats != null) {
            val candidate = fromStats.copy(eventType = null)
            cached = candidate
            cachedCandidate = candidate
            return reading(
                snapshot = snapshotOf(candidate, now),
                source = ForegroundDetectionSource.usageStatsFallback,
                usageAccessAvailable = true,
                reason = "usage-stats-fallback",
                appOps = appOps,
                begin = begin,
                end = now,
                events = events,
                stats = stats,
                lastRaw = lastRaw,
                selected = candidate,
            )
        }

        // 4. 缓存（分屏 / 返回设置页 / 桌面停留等"没有新外部事件"的场景）。
        val failure = describeFailure(lastRaw, selfPackage)
        val kept = cached?.takeIf { now - it.timestampMs <= ForegroundWindow.CACHE_TTL_MS }
        if (kept != null) {
            return reading(
                snapshot = snapshotOf(kept, now),
                source = ForegroundDetectionSource.cache,
                usageAccessAvailable = true,
                reason = if (lastRaw == null) "no-event-in-window" else failure,
                appOps = appOps,
                begin = begin,
                end = now,
                events = events,
                stats = stats,
                lastRaw = lastRaw,
                selected = kept,
            )
        }

        // 5. 实在没有可用的外部应用。
        return reading(
            snapshot = null,
            source = ForegroundDetectionSource.unavailable,
            usageAccessAvailable = true,
            reason = if (cached != null) "cache-expired" else failure,
            appOps = appOps,
            begin = begin,
            end = now,
            events = events,
            stats = stats,
            lastRaw = lastRaw,
            selected = null,
        )
    }

    /** 说明"为什么这一轮没拿到外部应用"（诊断用）。 */
    private fun describeFailure(lastRaw: String?, selfPackage: String): String = when {
        lastRaw == null -> "no-event-in-window"
        lastRaw.equals(selfPackage, ignoreCase = true) -> "last-event-is-self"
        ForegroundCandidateSelector.isNoise(lastRaw) -> "last-event-is-system-noise"
        else -> "no-usable-external-event"
    }

    private fun snapshotOf(candidate: ForegroundCandidate, now: Long) = ForegroundAppSnapshot(
        packageName = candidate.packageName,
        appLabel = candidate.label,
        observedAt = if (candidate.timestampMs > 0L) candidate.timestampMs else now,
    )

    private fun reading(
        snapshot: ForegroundAppSnapshot?,
        source: ForegroundDetectionSource,
        usageAccessAvailable: Boolean,
        reason: String?,
        appOps: Boolean,
        begin: Long,
        end: Long,
        events: List<ForegroundEventRecord>,
        stats: List<ForegroundCandidate>,
        lastRaw: String?,
        selected: ForegroundCandidate?,
    ): ForegroundAppReading = ForegroundAppReading(
        snapshot = snapshot,
        source = source,
        usageAccessAvailable = usageAccessAvailable,
        reason = reason,
        diagnostics = ForegroundDiagnostics(
            usageAccessGranted = usageAccessAvailable,
            appOpsAllowed = appOps,
            queryStart = begin,
            queryEnd = end,
            eventCount = events.size,
            resumedEventCount = events.count {
                ForegroundCandidateSelector.isForegroundEventType(it.eventType)
            },
            usableEventCount = events.count {
                ForegroundCandidateSelector.isForegroundEventType(it.eventType) &&
                    ForegroundCandidateSelector.isUsable(it.packageName, selfPackage)
            },
            statsCount = stats.size,
            lastRawPackage = lastRaw,
            lastExternalPackage = selected?.packageName,
            lastExternalEventType = selected?.eventType,
            lastExternalEventTime = selected?.timestampMs ?: 0L,
            detectionSource = source.wire,
            detectionFailureReason = reason,
        ),
    )
}

/**
 * `UsageStatsManager` 的原生实现（Phase 4C-5）。
 *
 * * 只读事件类型与包名，不写任何使用记录（需求 §5："状态联动只订阅结果，不重新统计时长"）；
 * * 不使用轮询器 —— 采样节奏完全由 [PetStateMonitor] / `PetStatePoller` 决定；
 * * 任何异常（权限被撤销、厂商裁剪 API）都返回空列表 / false，绝不抛。
 */
internal class AndroidForegroundAppQuery(private val context: Context) : ForegroundAppQuery {

    private val labelCache = HashMap<String, String?>(16)

    override fun usageAccessAvailable(): Boolean = UsageAccess.isGranted(context)

    override fun appOpsAllowed(): Boolean = UsageAccess.appOpsAllowed(context)

    override fun queryEvents(begin: Long, end: Long): List<ForegroundEventRecord> {
        val manager = context.getSystemService(Context.USAGE_STATS_SERVICE) as? UsageStatsManager
            ?: return emptyList()
        val events = manager.queryEvents(begin, end) ?: return emptyList()
        val out = ArrayList<ForegroundEventRecord>(32)
        while (events.hasNextEvent()) {
            // 每个事件都用**新实例**：个别 ROM 的 getNextEvent 不会覆盖对象的全部字段，
            // 复用同一个实例可能残留上一条的包名/类型（真机 4C-5 复验缺陷 C 的可疑点之一）。
            val event = UsageEvents.Event()
            events.getNextEvent(event)
            val record = ForegroundEventRecord(
                packageName = event.packageName.orEmpty(),
                eventType = event.eventType,
                timestampMs = event.timeStamp,
            )
            out.add(record)
            // 逐条事件只在诊断模式输出（需求 §6：正常模式不要输出每条事件）。
            OverlayLog.debug(
                "state.foreground.event type=${record.eventType} " +
                    "pkg=${record.packageName.ifEmpty { "<empty>" }} at=${record.timestampMs}",
            )
        }
        OverlayLog.debug("state.foreground.event count=${out.size}（窗口 $begin..$end）")
        return out
    }

    override fun queryUsageStats(begin: Long, end: Long): List<ForegroundCandidate> {
        val manager = context.getSystemService(Context.USAGE_STATS_SERVICE) as? UsageStatsManager
            ?: return emptyList()
        val stats: List<UsageStats> = manager.queryUsageStats(
            UsageStatsManager.INTERVAL_DAILY,
            begin,
            end,
        ) ?: return emptyList()
        return stats.mapNotNull { stat ->
            val packageName = stat.packageName?.trim().orEmpty()
            if (packageName.isEmpty()) return@mapNotNull null
            ForegroundCandidate(
                packageName = packageName,
                timestampMs = stat.lastTimeUsed,
                label = labelOf(packageName),
                eventType = null,
            )
        }
    }

    /** 应用标签（失败返回 null，诊断页会自动退回显示包名）。 */
    private fun labelOf(packageName: String): String? {
        labelCache[packageName]?.let { return it }
        val label = try {
            val info = context.packageManager.getApplicationInfo(packageName, 0)
            context.packageManager.getApplicationLabel(info).toString()
        } catch (t: PackageManager.NameNotFoundException) {
            null
        } catch (t: Throwable) {
            null
        }
        labelCache[packageName] = label
        return label
    }
}

/**
 * 悬浮服务用的前台应用来源：`UsageStatsManager` 查询 + 纯判定器。
 *
 * 应用标签在事件路径上由本类补齐（`queryEvents` 不返回标签），
 * 统计路径的标签由 `queryUsageStats` 一并给出。
 *
 * **每次读取都会把结果发布到 [ForegroundAppRegistry]** —— 这样桌宠状态、
 * 使用统计采集（4C-5.1B）与界面（设置页 / 统计页）共用同一份前台应用快照，
 * 不会出现"两个页面显示不同应用"（真机缺陷 D）。
 */
internal class AndroidForegroundAppSource(context: Context) : ForegroundAppSource {

    private val appContext = context.applicationContext
    private val labelCache = HashMap<String, String?>(16)

    /** `ApplicationInfo.category` 缓存（分类是静态属性，查一次就够）。 */
    private val platformCategoryCache = HashMap<String, Int?>(16)

    private val resolver = ForegroundAppResolver(
        query = AndroidForegroundAppQuery(appContext),
        selfPackage = appContext.packageName,
    )

    override fun read(now: Long): ForegroundAppReading {
        val reading = resolver.read(now)
        // 标签 + 分类在这里一次补齐，随后**随快照传播**给所有消费者。
        val enriched = reading.snapshot?.let { snapshot ->
            val platformCategory = platformCategoryOf(snapshot.packageName)
            val classification = AndroidAppCategoryRules.classify(
                packageName = snapshot.packageName,
                platformCategory = platformCategory,
            )
            reading.copy(
                snapshot = snapshot.copy(
                    appLabel = snapshot.appLabel ?: labelOf(snapshot.packageName),
                    category = classification.category,
                    categorySource = classification.source.wire,
                    platformCategory = platformCategory,
                ),
            )
        } ?: reading
        // 单一检测入口 = 单一发布点：所有消费者都读 registry，不各自查询。
        ForegroundAppRegistry.publish(enriched, now)
        return enriched
    }

    /**
     * 系统声明的分类（`ApplicationInfo.category`）。
     *
     * * API 26 才有该字段 —— 低版本直接返回 null（继续走包名规则），不做任何伪装；
     * * 查询失败（应用已卸载 / 无权限）同样返回 null，**绝不因此影响前台识别**。
     */
    private fun platformCategoryOf(packageName: String): Int? {
        if (platformCategoryCache.containsKey(packageName)) {
            return platformCategoryCache[packageName]
        }
        val value = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            runCatching {
                appContext.packageManager.getApplicationInfo(packageName, 0).category
            }.getOrNull()
        } else {
            null
        }
        platformCategoryCache[packageName] = value
        return value
    }

    private fun labelOf(packageName: String): String? {
        labelCache[packageName]?.let { return it }
        val label = try {
            val info = appContext.packageManager.getApplicationInfo(packageName, 0)
            appContext.packageManager.getApplicationLabel(info).toString()
        } catch (t: Throwable) {
            null
        }
        labelCache[packageName] = label
        return label
    }
}

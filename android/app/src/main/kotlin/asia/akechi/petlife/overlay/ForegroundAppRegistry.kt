package asia.akechi.petlife.overlay

/**
 * 前台应用的**进程内共享快照**（Phase 4C-5.1A）。
 *
 * 为什么需要它（真机缺陷 D）：
 * 悬浮桌宠设置页能显示「当前前台应用」，但**使用统计（本机）页显示为空** ——
 * 因为统计页走的是 Dart 侧的 Windows 专用链路（Android 上是"不可用"实现），
 * 与原生检测**没有共用同一份数据**。
 *
 * 本阶段的约定（需求 §3.1 / §3.2 / §4）：
 * ```
 * AndroidForegroundAppSource.read()      ← 唯一检测入口（不新增第二个轮询器）
 *   └─ ForegroundAppRegistry             ← 进程内只读快照
 *        ├─ PetStateMonitor              只负责桌宠状态与素材
 *        ├─ AndroidUsageSessionTracker   只负责使用会话（4C-5.1B）
 *        └─ PetOverlayBridge             只负责给界面读（设置页 / 统计页共用）
 * ```
 *
 * 快照由检测侧写入，界面侧**只读**；界面刷新不会再调用 `UsageStatsManager`
 * （只有"快照过期"时才会触发一次真正的检测，见 `PetOverlayService.refreshForegroundSnapshotIfStale`）。
 */
internal data class SharedForegroundApp(
    /** 有效外部应用包名；拿不到时为 null。 */
    val packageName: String?,
    val appLabel: String?,
    /** 分类（`AppCategoryId.wireName`）。 */
    val category: String?,
    /** 分类来源（`AppCategorySource.wire`）。 */
    val categorySource: String?,
    /** 判定依据的事件时间戳（毫秒）；无事件时为 0。 */
    val eventTime: Long,
    /** 本次检测时刻（毫秒）。 */
    val detectedAt: Long,
    /** 检测来源（`ForegroundDetectionSource.wire`）。 */
    val source: String,
    /** 失败/降级原因（如 `last-event-is-self`、`usage_access_missing`）。 */
    val reason: String?,
    /** 使用情况访问是否可用（AppOps + 数据双验证的结论）。 */
    val usageAccessAvailable: Boolean,
    /** AppOps 是否明确允许（仅诊断；与上一项不一致说明 ROM 口径有差异）。 */
    val appOpsAllowed: Boolean,
    /** 检测这一轮窗口内的事件数（诊断）。 */
    val eventCount: Int,
    /** 其中"应用来到前台"的事件数（诊断）。 */
    val resumedEventCount: Int,
    /** 过滤后剩下的有效外部应用事件数（诊断）。 */
    val usableEventCount: Int,
    /** 窗口内未过滤的最后一条前台事件包名（诊断"最后一条到底是谁"）。 */
    val lastRawPackage: String?,
) {
    /** 是否是一个"可用的外部应用"。 */
    val hasApp: Boolean get() = !packageName.isNullOrEmpty()
}

/**
 * 快照的持有者（进程级）。
 *
 * @Volatile 单字段写入：读侧永远拿到一个完整对象，不会读到"半更新"状态。
 */
internal object ForegroundAppRegistry {

    @Volatile
    private var snapshot: SharedForegroundApp? = null

    /** 采集器（= 悬浮服务里的状态轮询任务）是否在运行。 */
    @Volatile
    var collectorRunning: Boolean = false
        private set

    val current: SharedForegroundApp? get() = snapshot

    /** 由检测侧调用：把一次读取结果发布为共享快照。 */
    fun publish(reading: ForegroundAppReading, now: Long) {
        val snapshot = reading.snapshot
        // 分类优先用**检测侧算好的那一份**（[AndroidForegroundAppSource] 会把
        // 系统声明分类一起考虑进去）；快照没带分类时才在这里兜底算一次。
        val classification = if (snapshot?.category == null) {
            snapshot?.let { AndroidAppCategoryRules.classify(it.packageName) }
        } else {
            null
        }
        val d = reading.diagnostics
        this.snapshot = SharedForegroundApp(
            packageName = snapshot?.packageName,
            appLabel = snapshot?.appLabel,
            category = snapshot?.category ?: classification?.category,
            categorySource = snapshot?.categorySource ?: classification?.source?.wire,
            eventTime = d.lastExternalEventTime,
            detectedAt = now,
            source = reading.source.wire,
            reason = reading.reason,
            usageAccessAvailable = reading.usageAccessAvailable,
            appOpsAllowed = d.appOpsAllowed,
            eventCount = d.eventCount,
            resumedEventCount = d.resumedEventCount,
            usableEventCount = d.usableEventCount,
            lastRawPackage = d.lastRawPackage,
        )
    }

    /** 由服务在监听任务启停时调用（界面据此区分"没有应用"与"采集没在跑"）。 */
    fun setCollectorRunning(running: Boolean) {
        collectorRunning = running
    }

    /** 服务销毁时清空：宁可显示"不可用"，也不要让界面读到一个进程级的陈旧快照。 */
    fun clear() {
        snapshot = null
        collectorRunning = false
    }
}

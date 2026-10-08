package asia.akechi.petlife.overlay

/**
 * 状态监听与判定（Phase 4C-5）。
 *
 * 拆成两半，原因是"能测的部分"和"必须真机的部分"完全不同：
 *
 * * [PetStateMonitor]：**纯逻辑**，不引用任何 Android 类。输入是
 *   "前台应用读取结果 + 当前时间 + 当前状态"，输出是"要不要换状态"。可以用虚拟时间穷举测试。
 * * [PetStatePoller]：只管"什么时候再跑一次"。它把投递/取消定时器的能力通过
 *   两个函数注入进来，因此 JVM 单测里也能用假实现验证"同一个任务不会被叠加"。
 *
 * 需求 §11 明确禁止"多个 Timer / Handler 互相叠加"，这两条约定在 [PetStatePoller]
 * 里被结构性保证：内部只有一个 `Runnable`，`start()` 幂等。
 */
internal class PetStateMonitor(
    private val foregroundSource: ForegroundAppSource,
    private val debouncer: PetStateDebouncer = PetStateDebouncer(),
    /**
     * 判断某个包名是不是当前设备的**桌面（launcher）**（Phase 4C-6A）。
     *
     * 桌面也落在 `system` 分类里，但语义是"回到桌面 ≈ 空闲"，与系统设置页
     * 完全不同（需求 §4.2 要求两者区别对待）。由服务用 `PackageManager`
     * 解析出的 home 包名集合注入，因此本类仍然**不引用任何 Android API**、可单测。
     */
    private val isLauncher: (String) -> Boolean = { false },
    /**
     * 系统声明的应用分类（`ApplicationInfo.category`，Phase 4C-6A）。
     *
     * 由服务注入（需要 `PackageManager`），因此本类仍不引用任何 Android API。
     * 只有"包名覆盖表没有命中"时才会被用到，见 [AndroidAppCategoryRules.classify]。
     */
    private val platformCategoryOf: (String) -> Int? = { null },
) {

    // --- 诊断字段（设置页只读展示）---

    /** 最近一次读到的前台包名（**经筛选后的有效外部应用**）。 */
    var lastForegroundPackage: String? = null
        private set

    /** 最近一次读到的应用标签（拿不到时为 null，诊断页退回显示包名）。 */
    var lastForegroundLabel: String? = null
        private set

    /** 最近一次分类结果（`AppCategoryId`）。 */
    var lastCategory: String? = null
        private set

    /** 最近一次分类来源（`AppCategorySource.wire`）。 */
    var lastCategorySource: String? = null
        private set

    /** 最近一次分类命中的**具体依据**（包名 / 前缀 / 关键字 / 系统声明值）。 */
    var lastCategoryDetail: String? = null
        private set

    /** 最近一次读到的系统声明分类值（`ApplicationInfo.category`；拿不到为 null）。 */
    var lastPlatformCategory: Int? = null
        private set

    /** 最近一次判定的原因（人可读）。 */
    var lastReason: String? = null
        private set

    /**
     * 最近一次命中的规则（Phase 4C-6A 诊断）。
     *
     * 取值：`user-app`（具体应用规则）/ `user-category`（用户分类规则）/
     * `built-in`（内置分类规则）/ `launcher`（桌面）/ `hold`（保持上一个状态）/
     * `manual`（手动覆盖）/ `disabled`（自动联动已关闭）/ `none`（无法判定）。
     */
    var lastMatchedRule: String? = null
        private set

    /**
     * 最近一次**解析出来的目标状态**（Phase 4C-6A 诊断）。
     *
     * 这是排查"为什么状态不变"的关键字段：
     * * 它与 [candidateState] 都为空 → 根本没走到规则解析（权限 / 快照不可用）；
     * * 它有值但 `candidateState` 为空 → 目标与当前状态相同，或命中"保持"；
     * * 两者相同但状态未提交 → 问题在**防抖提交**那一步。
     */
    var lastResolvedTargetState: String? = null
        private set

    /**
     * 最近一次**提交结果**（诊断"卡在哪一步"）。
     *
     * 取值：`committed`（状态已提交）/ `candidate`（候选未稳定）/ `suppressed`
     * （快速切换抑制窗内）/ `unchanged`（与当前状态相同）/ `hold`（系统界面保持）/
     * `manual`（手动覆盖）/ `disabled`（自动联动已关闭）/ `unavailable`（权限或数据缺失）。
     */
    var lastTransitionResult: String? = null
        private set

    /** 最近一次提交结果的人可读说明（诊断页直接显示）。 */
    var lastTransitionReason: String? = null
        private set

    /**
     * 候选状态首次出现的时间（**墙钟毫秒**）。
     *
     * 由"单调时钟差值"折算而来（[candidateElapsedMs] 才是判定用的时间），
     * 因此系统时间被 NTP 调整时**不会**让候选看起来"突然重置"。
     */
    var candidateSinceWall: Long = 0L
        private set

    /** 候选状态已持续的毫秒数（单调时钟；诊断"候选是不是被反复重置"）。 */
    var candidateElapsedMs: Long = 0L
        private set

    /** 最近一次状态真正提交的时间（墙钟毫秒；0 = 从未提交）。 */
    var lastCommittedAt: Long = 0L
        private set

    /** 最近一次不允许/忽略的原因码（诊断）。 */
    var lastErrorCode: String? = null
        private set

    /** 最近一次的检测来源（`ForegroundDetectionSource.wire`）。 */
    var lastDetectionSource: String? = null
        private set

    /** 最近一次的检测原因 / 失败原因（诊断）。 */
    var lastDetectionReason: String? = null
        private set

    /** 最近一次检测的完整诊断（需求 §6）。 */
    var lastDiagnostics: ForegroundDiagnostics? = null
        private set

    /** 当前候选状态（尚未稳定生效）。 */
    val candidateState: String? get() = debouncer.candidate

    /** 候选已连续出现的次数。 */
    val candidateCount: Int get() = debouncer.consecutive

    /** 上一条已打过的检测日志（避免稳定状态下每秒刷屏，需求 §6）。 */
    private var lastLoggedDetectionKey: String? = null

    /**
     * 检测一次并给出决策。
     *
     * **时间有两个来源，绝不能混用**（Phase 4C-6A 诊断要求"时间计算使用单调时钟"）：
     * * [now]：**单调时钟**（`SystemClock.elapsedRealtime()`），只用于防抖的时间比较 ——
     *   它不受用户改时间 / NTP 校时影响，"稳定 1 秒"这件事才不会被系统校时打断；
     * * [wallNow]：**墙钟**（`System.currentTimeMillis()`），只用于给界面展示时间戳
     *   （"候选从几点开始""状态最近一次变化"）。
     *
     * @param now 单调时钟毫秒
     * @param currentStateId 当前已生效状态
     * @param manualOverride 状态调试器的手动覆盖（null = 未覆盖）
     * @param fastPath 跳过候选稳定性门槛（显示/解锁后的首次检测用，见 [PetStateDebouncer.offer]）
     * @param wallNow 墙钟毫秒（默认与 [now] 相同，便于单测只给一个时间）
     * @return 需要切换时返回决策；null 表示"保持当前状态"
     */
    fun tick(
        now: Long,
        currentStateId: String,
        manualOverride: String?,
        fastPath: Boolean = false,
        rules: PetStateRules = PetStateRules.DEFAULT,
        wallNow: Long = now,
    ): PetStateDecision? {
        val decision = decide(now, wallNow, currentStateId, manualOverride, fastPath, rules)
        // 诊断快照在此**统一**更新一次：无论上面走哪条分支都不会漏（此前散落各处易漏更新）。
        // 候选时长用单调时钟算，再折算成墙钟起点 —— 系统校时不会让候选"看起来重置"。
        if (debouncer.candidate != null) {
            candidateElapsedMs = (now - debouncer.candidateSince).coerceAtLeast(0L)
            candidateSinceWall = wallNow - candidateElapsedMs
        } else {
            candidateElapsedMs = 0L
            candidateSinceWall = 0L
        }
        return decision
    }

    private fun decide(
        now: Long,
        wallNow: Long,
        currentStateId: String,
        manualOverride: String?,
        fastPath: Boolean,
        rules: PetStateRules,
    ): PetStateDecision? {
        // 1. 手动覆盖优先级最高，且**不等防抖**（需求 §12 / §16）。
        if (PetStateId.isKnown(manualOverride)) {
            debouncer.reset()
            lastReason = "状态调试器手动覆盖状态 ${manualOverride}"
            lastMatchedRule = "manual"
            lastResolvedTargetState = manualOverride
            lastTransitionResult = "manual"
            lastTransitionReason = "手动覆盖生效（不响应自动切换）"
            lastErrorCode = null
            return PetStateDecision(
                stateId = manualOverride!!,
                source = PetStateSource.manualDebug,
                reason = lastReason!!,
                foregroundPackage = lastForegroundPackage,
                decidedAt = wallNow,
            )
        }

        // 1b. 用户关闭了"自动状态联动"：不再提交任何自动状态，
        //     但**不影响**前台识别与使用时长采集（需求 §9 / 验收第 19 条）。
        if (!rules.automaticEnabled) {
            debouncer.reset()
            lastReason = "自动状态联动已关闭（保持当前素材）"
            lastMatchedRule = "disabled"
            lastResolvedTargetState = null
            lastTransitionResult = "disabled"
            lastTransitionReason = "自动状态联动已关闭"
            lastErrorCode = null
            return null
        }

        // 2. 读前台应用（筛选、兜底、缓存都在 ForegroundAppResolver 里完成）。
        val reading = foregroundSource.read(now)
        lastDiagnostics = reading.diagnostics
        lastDetectionSource = reading.source.wire
        lastDetectionReason = reading.reason
        logDetection(reading)

        // 3. 使用情况访问不可用：明确回退默认状态（需求 §6），不阻塞、不弹窗。
        if (!reading.usageAccessAvailable) {
            debouncer.reset()
            lastForegroundPackage = null
            lastForegroundLabel = null
            lastReason = "未授予使用情况访问权限，桌宠保持默认状态"
            lastMatchedRule = "none"
            lastResolvedTargetState = null
            lastTransitionResult = "unavailable"
            lastTransitionReason = "未授予使用情况访问权限"
            lastErrorCode = PetStateError.USAGE_ACCESS_MISSING
            return PetStateDecision(
                stateId = PetStateId.DEFAULT,
                source = PetStateSource.unsupported,
                reason = lastReason!!,
                foregroundPackage = null,
                decidedAt = wallNow,
            )
        }

        // 4. 权限没问题但这一轮拿不到**有效外部应用**：保持当前状态，不清空。
        //    这是"分屏里 PetLife 自己在前台 / 最后一条事件是 SystemUI"的正确行为。
        val snapshot = reading.snapshot
        if (snapshot == null) {
            debouncer.reset()
            lastMatchedRule = "none"
            lastResolvedTargetState = null
            lastTransitionResult = "unavailable"
            lastTransitionReason = "无法确定当前前台应用（${reading.reason ?: "unknown"}）"
            lastErrorCode = PetStateError.FOREGROUND_APP_UNAVAILABLE
            lastReason = "无法确定当前前台应用（${reading.reason ?: "unknown"}），保持当前状态"
            return null
        }
        lastForegroundPackage = snapshot.packageName
        lastForegroundLabel = snapshot.appLabel

        // 5. 规则优先级（需求 §4.1）：具体应用规则 → 分类规则（用户下发）→ 内置分类规则 → default。
        //
        // 分类**优先用检测侧算好的那一份**（`snapshot.category`）：它已经考虑了
        // 系统声明分类（`ApplicationInfo.category`），而且与统计页/设置页读到的
        // 是同一份 —— 不会出现"界面显示 browser、判定却按 other 走"的分叉。
        val classification = if (snapshot.category != null) {
            AppCategoryResult(
                category = snapshot.category!!,
                source = AppCategorySource.values().firstOrNull { it.wire == snapshot.categorySource }
                    ?: AppCategorySource.builtInRule,
                detail = null,
            )
        } else {
            AndroidAppCategoryRules.classify(
                packageName = snapshot.packageName,
                platformCategory = snapshot.platformCategory
                    ?: runCatching { platformCategoryOf(snapshot.packageName) }.getOrNull(),
            )
        }
        lastCategory = classification.category
        lastCategorySource = classification.source.wire
        lastCategoryDetail = classification.detail
        lastPlatformCategory = snapshot.platformCategory
        val launcher = runCatching { isLauncher(snapshot.packageName) }.getOrDefault(false)
        val reasonBase = "前台应用「${snapshot.appLabel ?: snapshot.packageName}」" +
            "分类为「${AppCategoryId.labelZh(classification.category)}」" +
            AppCategoryStateMapper.noteForCategory(classification.category, launcher)

        val overrideState = rules.appOverrides[snapshot.packageName]
        val categoryState = rules.categoryRules[classification.category]
        val targetState: String
        when {
            // ① 用户为这个具体应用指定的状态。
            PetStateId.isKnown(overrideState) -> {
                targetState = overrideState!!
                lastMatchedRule = "user-app"
            }
            // ② 用户为这个分类指定的状态（由 Flutter 下发；不含"保持"语义的分类）。
            PetStateId.isKnown(categoryState) -> {
                targetState = categoryState!!
                lastMatchedRule = "user-category"
            }
            else -> when (val outcome = AppCategoryStateMapper.outcomeFor(classification.category, launcher)) {
                is CategoryStateOutcome.Mapped -> {
                    targetState = outcome.stateId
                    lastMatchedRule = if (launcher) "launcher" else "built-in"
                }
                // ③ 系统设置页 / 权限弹窗 / 最近任务这类"无法判断用户意图"的场景：
                //    **保持上一个稳定状态**，只清掉候选（需求 §4.2：不能在系统界面之间乱跳）。
                CategoryStateOutcome.Hold -> {
                    debouncer.reset()
                    lastReason = "$reasonBase：保持当前状态"
                    lastMatchedRule = "hold"
                    // "保持"也是**解析出了目标**：这里如实记为"保持"，而不是装作没解析。
                    lastResolvedTargetState = currentStateId
                    lastTransitionResult = "hold"
                    lastTransitionReason = "系统界面（${AppCategoryId.labelZh(classification.category)}）保持上一个稳定状态"
                    lastErrorCode = null
                    return null
                }
            }
        }
        val reason = reasonBase
        lastResolvedTargetState = targetState
        OverlayLog.log(
            "state.resolve pkg=${snapshot.packageName} category=${classification.category}" +
                "/${classification.source.wire} target=$targetState rule=${lastMatchedRule}" +
                " current=$currentStateId",
        )

        // 6. 防抖（时间用**单调时钟**，见 [tick] 的说明）。
        return when (
            val outcome = debouncer.offer(
                candidateStateId = targetState,
                currentStateId = currentStateId,
                now = now,
                fastPath = fastPath,
            )
        ) {
            is PetDebounceOutcome.Accepted -> {
                lastReason = reason
                lastErrorCode = null
                lastTransitionResult = "committed"
                lastTransitionReason = "候选稳定 ${outcome.stableForMs}ms，" +
                    "状态从 $currentStateId 提交为 ${outcome.stateId}"
                lastCommittedAt = wallNow
                // 结构化日志：提交是"状态真的变了"的唯一证据，必须有一条。
                OverlayLog.log(
                    "state.transition.committed from=$currentStateId to=${outcome.stateId} " +
                        "rule=${lastMatchedRule} stableMs=${outcome.stableForMs} " +
                        "pkg=${snapshot.packageName}",
                )
                PetStateDecision(
                    stateId = outcome.stateId,
                    source = PetStateSource.foregroundApp,
                    reason = reason,
                    foregroundPackage = snapshot.packageName,
                    decidedAt = wallNow,
                )
            }

            is PetDebounceOutcome.Waiting -> {
                lastReason = outcome.reason
                lastErrorCode = PetStateError.STALE_STATE_RESULT
                lastTransitionResult = if (outcome.suppressed) "suppressed" else "candidate"
                lastTransitionReason = outcome.reason
                logCandidate(outcome, snapshot.packageName)
                null
            }

            is PetDebounceOutcome.Ignored -> {
                lastReason = outcome.reason
                lastErrorCode = null
                lastTransitionResult = outcome.code
                lastTransitionReason = outcome.reason
                null
            }
        }
    }

    /**
     * 检测结果发生变化时的日志（需求 §6）。
     *
     * **只在结果真的变化时打** —— 稳定状态下每 1.5 秒重复打印同一行会把验收日志刷满。
     * 完整事件列表由查询层在诊断模式下输出（`state.foreground.event`）。
     */
    private fun logDetection(reading: ForegroundAppReading) {
        val key = listOf(
            reading.source.wire,
            reading.snapshot?.packageName ?: "-",
            reading.reason ?: "-",
            reading.diagnostics.lastRawPackage ?: "-",
        ).joinToString("|")
        if (key == lastLoggedDetectionKey) return
        lastLoggedDetectionKey = key

        val d = reading.diagnostics
        when (reading.source) {
            ForegroundDetectionSource.activityEvents -> OverlayLog.log(
                "state.foreground.detected pkg=${reading.snapshot?.packageName} " +
                    "label=${reading.snapshot?.appLabel ?: "<none>"} " +
                    "type=${d.lastExternalEventType} at=${d.lastExternalEventTime} " +
                    "source=${reading.source.wire}",
            )

            ForegroundDetectionSource.usageStatsFallback -> OverlayLog.log(
                "state.foreground.fallback reason=usage-stats-fallback " +
                    "pkg=${reading.snapshot?.packageName} at=${d.lastExternalEventTime} " +
                    "stats=${d.statsCount}（尚未伪装成精确 Activity 事件）",
            )

            ForegroundDetectionSource.cache -> OverlayLog.log(
                "state.foreground.filtered reason=${reading.reason} " +
                    "keeping=${reading.snapshot?.packageName} lastRaw=${d.lastRawPackage ?: "<none>"} " +
                    "（分屏或返回设置页，保留最近有效外部应用）",
            )

            ForegroundDetectionSource.unavailable -> OverlayLog.warn(
                "state.foreground.unavailable reason=${reading.reason} " +
                    "lastRaw=${d.lastRawPackage ?: "<none>"} events=${d.eventCount}",
            )
        }
        // 查询摘要：与上面同一组变化一起打，因此不会刷屏。
        OverlayLog.log(
            "state.foreground.query start=${d.queryStart} end=${d.queryEnd} " +
                "events=${d.eventCount} resumed=${d.resumedEventCount} usable=${d.usableEventCount} " +
                "stats=${d.statsCount} appOps=${d.appOpsAllowed} granted=${d.usageAccessGranted} " +
                "lastRaw=${d.lastRawPackage ?: "<none>"} source=${d.detectionSource}",
        )
    }

    /**
     * 候选未生效时的日志。
     *
     * 只在新候选**第一次出现**时打一条 —— 稳定状态下每秒重复打印相同状态
     * 会把验收日志刷满（需求 §6 / 4C-4 §20 明令禁止）。
     */
    private fun logCandidate(outcome: PetDebounceOutcome.Waiting, packageName: String) {
        if (outcome.consecutiveCount > 1) return
        OverlayLog.log(
            "state.candidate state=${outcome.stateId} count=${outcome.consecutiveCount} " +
                "remaining=${outcome.remainingMs}ms pkg=$packageName",
        )
    }

    /** 停止监听时清空候选（需求 §22 第 20 条）。 */
    fun reset() {
        debouncer.reset()
        lastErrorCode = null
    }
}

/**
 * 唯一的轮询任务（需求 §11）。
 *
 * 结构性保证：
 * * 内部**只有一个** `Runnable`，`start()` 幂等 —— 重复 show 不会创建第二个监听；
 * * 间隔由 [intervalMs] 动态给出（服务运行 1500ms / 隐藏 5000ms）；
 * * `stop()` 会 `removeCallbacks` 并把 `running` 置假，之后**回调不再执行**；
 * * 投递与取消通过 [post]/[remove] 注入，因此 JVM 单测可用假实现验证。
 */
internal class PetStatePoller(
    private val post: (Runnable, Long) -> Unit,
    private val remove: (Runnable) -> Unit,
    private val intervalMs: () -> Long,
    private val onTick: () -> Unit,
) {

    private var running = false

    private val task = object : Runnable {
        override fun run() {
            if (!running) return
            onTick()
            if (running) schedule()
        }
    }

    val isRunning: Boolean get() = running

    /** 启动（幂等）。[immediate] = true 时立刻先检测一次。 */
    fun start(immediate: Boolean) {
        if (running) return
        running = true
        if (immediate) post(task, 0L) else schedule()
    }

    /** 立即检测一次（解锁 / 重新显示时用）。任务未启动时是空操作。 */
    fun pollNow() {
        if (!running) return
        remove(task)
        post(task, 0L)
    }

    /** 停止并取消回调（幂等）。 */
    fun stop() {
        running = false
        remove(task)
    }

    private fun schedule() {
        post(task, intervalMs().coerceAtLeast(MIN_INTERVAL_MS))
    }

    companion object {
        /** 轮询间隔下限：任何情况下不得高于 2 次/秒。 */
        const val MIN_INTERVAL_MS = 500L
    }
}

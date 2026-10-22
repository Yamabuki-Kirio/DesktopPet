package asia.akechi.petlife.overlay

/**
 * 会话采集的**记录器**：把纯逻辑状态机与 journal 串起来（Phase 4C-5.1B）。
 *
 * 为什么单独一层：状态机不该知道文件、服务也不该关心"什么时候落盘"。
 * 这一层只做三件事，每一件都必须是可判定的：
 * 1. **先落盘再算成功** —— 每次结束会话立刻写 journal，写失败就记日志（时间不丢在内存里）；
 * 2. **开放会话检查点** —— 按固定间隔把进行中的会话写到 `open.jsonl`，
 *    进程异常终止后由 [onServiceStarted] 按 `process_recovery` 补齐关闭；
 * 3. **启动恢复** —— 服务起来时先把上次遗留的开放会话收尾，再接受新观察。
 *
 * 隐私：journal 里只有包名、应用标签、分类、时间与时长，
 * **没有**屏幕内容 / 输入内容 / 通知 / 文件路径 / 账户 / 令牌（需求 §1）。
 */
internal class UsageSessionRecorder(
    private val tracker: AndroidUsageSessionTracker,
    private val journal: UsageSessionJournal,
    /** 开放会话检查点的最小写入间隔（避免每 1.5 秒写一次盘）。 */
    private val checkpointIntervalMs: Long = 10_000L,
    private val now: () -> Long = { System.currentTimeMillis() },
) {

    /** 最近一次检查点写入时刻。 */
    private var lastCheckpointAtMs: Long = 0L

    /**
     * 仅存在于内存的待重试队列。
     *
     * journal 是唯一持久化介质；这里只是"已经结束、但这次没写进 journal"的会话。
     * 顺序即完成顺序，重试成功一个才移除一个；进程在成功前被系统杀死时，
     * 仍按现有检查点精度边界处理，不引入第二套持久化文件。
     */
    private val pendingPersist = ArrayList<UsageSessionRecord>(4)
    private val pendingPersistIds = HashSet<String>()

    // -----------------------------------------------------------------------
    // 生命周期
    // -----------------------------------------------------------------------

    /**
     * 服务启动：先收尾上次遗留的开放会话，再把暂停状态对齐。
     *
     * **必须最先调用**（在任何 `observe` 之前），否则遗留会话会一直挂到下次崩溃。
     */
    fun onServiceStarted(paused: Boolean) {
        val leftover = journal.readOpen()
        if (leftover != null) {
            val record = tracker.recover(leftover)
            if (record != null) {
                // 恢复记录同样必须"先落盘再算成功"：写失败就留在待重试队列。
                flushCompleted(listOf(record))
            }
            OverlayLog.log(
                "usage.journal.recovered-checkpoint id=${leftover.sessionId} " +
                    "pkg=${leftover.packageName} lastSeen=${leftover.creditUpToMs}",
            )
        }
        journal.writeOpen(null)
        if (paused) {
            tracker.onPaused(now())
        } else {
            tracker.onResumed()
        }
        OverlayLog.log(
            "usage.collector.started paused=$paused pending=${journal.pendingCount()}",
        )
    }

    /** 服务停止 / 销毁：结束当前会话并清掉开放检查点。 */
    fun onServiceStopped() {
        flushCompleted(tracker.onServiceStopped(now()))
        journal.writeOpen(null)
        OverlayLog.log("usage.collector.stopped pending=${journal.pendingCount()}")
    }

    /** 熄屏 / 锁屏：立刻结束当前会话（不该把息屏时间算成使用时长）。 */
    fun onScreenOff() {
        flushCompleted(tracker.onScreenOff(now()))
        journal.writeOpen(null)
    }

    /** 使用情况访问权限被撤销。 */
    fun onPermissionRevoked() {
        flushCompleted(tracker.onPermissionRevoked(now()))
        journal.writeOpen(null)
    }

    /** 切换暂停状态（由 Flutter 下发；原生也持久化，重启后仍生效）。 */
    fun setPaused(paused: Boolean) {
        if (paused == tracker.paused) return
        if (paused) {
            flushCompleted(tracker.onPaused(now()))
            journal.writeOpen(null)
            OverlayLog.log("usage.collection.paused")
        } else {
            tracker.onResumed()
            OverlayLog.log("usage.collection.resumed（不补算暂停期间）")
        }
    }

    // -----------------------------------------------------------------------
    // 观察
    // -----------------------------------------------------------------------

    /**
     * 处理一次前台观察。
     *
     * @param packageName 共享快照里的前台应用；null = 这一轮没有可用的外部应用
     * @param countable 是否计入普通应用时长（桌面 / 系统界面为 false）
     */
    fun observe(
        packageName: String?,
        appName: String?,
        category: String?,
        countable: Boolean,
    ) {
        val at = now()
        val completed = tracker.observe(
            UsageObservation(
                packageName = packageName,
                appName = appName,
                category = category,
                countable = countable,
                observedAt = at,
            ),
        )
        flushCompleted(completed)
        checkpointOpen(at)
    }

    /** 当前会话（供桥接 `getCurrentUsageSession` 读取）。 */
    fun currentSession(): OpenUsageSession? = tracker.open

    /** 当前会话已持续秒数。 */
    fun currentElapsedSeconds(): Int = tracker.currentElapsedSeconds(now())

    /** journal 摘要（诊断）。 */
    fun journalSummary(): Map<String, Any?> = journal.summary()

    // -----------------------------------------------------------------------
    // 内部
    // -----------------------------------------------------------------------

    /** 写入已结束的会话：**先落盘再算成功**；写失败只记日志，绝不影响桌宠。 */
    private fun flushCompleted(records: List<UsageSessionRecord>) {
        // 先重试旧记录，再写本次新记录：保证 journal 里的顺序与完成顺序一致。
        retryPendingPersist()
        for (record in records) {
            persist(record)
        }
    }

    /** 尝试把一条已结束会话写入 journal；失败则保留在内存队列。 */
    private fun persist(record: UsageSessionRecord) {
        if (!pendingPersistIds.add(record.sessionId)) {
            // 同一 sessionId 已经排队：只更新内容，绝不重复追加。
            val index = pendingPersist.indexOfFirst { it.sessionId == record.sessionId }
            if (index >= 0) pendingPersist[index] = record
            return
        }
        if (journal.append(record)) {
            pendingPersistIds.remove(record.sessionId)
            OverlayLog.log("usage.outbox.enqueued id=${record.sessionId}（等待 Flutter 导入）")
            return
        }
        pendingPersist.add(record)
        OverlayLog.warn(
            "usage.session.persist-failed id=${record.sessionId} pkg=${record.packageName} " +
                "（已保留在内存待重试，当前 ${pendingPersist.size} 条）",
        )
    }

    /** 按完成顺序重试内存队列；写成功一个才移除一个。 */
    private fun retryPendingPersist() {
        if (pendingPersist.isEmpty()) return
        val iterator = pendingPersist.iterator()
        while (iterator.hasNext()) {
            val record = iterator.next()
            if (!journal.append(record)) {
                // 存储仍不可用：保留剩余记录与顺序，下一次触发继续。
                OverlayLog.warn(
                    "usage.session.persist-retry-failed id=${record.sessionId} " +
                        "（保留 ${pendingPersist.size} 条待重试）",
                )
                return
            }
            iterator.remove()
            pendingPersistIds.remove(record.sessionId)
            OverlayLog.log(
                "usage.session.persist-retried id=${record.sessionId}（等待 Flutter 导入）",
            )
        }
    }

    /**
     * 定期写开放会话检查点。
     *
     * 间隔内不写盘：会话每 1.5 秒被延长一次，每次都写盘会造成无谓 I/O。
     * 代价是异常终止时最多丢失一个检查点间隔的时长 —— 但结束时间取的是
     * 检查点里的 `creditUpToMs`，因此**只会少算，绝不会虚报**。
     */
    private fun checkpointOpen(at: Long) {
        val open = tracker.open
        if (open == null) {
            if (lastCheckpointAtMs != 0L) {
                journal.writeOpen(null)
                lastCheckpointAtMs = 0L
            }
            return
        }
        if (at - lastCheckpointAtMs < checkpointIntervalMs) return
        lastCheckpointAtMs = at
        journal.writeOpen(open)
    }
}

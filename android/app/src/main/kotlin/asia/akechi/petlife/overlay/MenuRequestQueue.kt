package asia.akechi.petlife.overlay

/**
 * 菜单请求协议（Phase 4C-6B-3，需求 §17 菜单动作接线）。
 *
 * 为什么需要这条"请求队列"：
 * 轮盘里有一部分动作**必须由 Dart 执行**（自动状态、素材切换、记录、设置页……），
 * 但它们是在**原生悬浮窗**里被点下来的 —— 而原生服务可能在 Flutter 引擎
 * 已经被回收（或 Activity 刚被重建）的时候仍然存活。
 * 因此原生侧把"要 Dart 做的事"落成一条**待交付请求**：
 * 能推就推（`menuRequest`），推不动就先留在队列里，等 Dart 回来 `pullPendingMenuRequests`。
 *
 * 本文件的类是**纯 Kotlin**（不含任何 `android.*` / `org.json` 依赖），
 * 因此 enqueue / 去重 / 过期 / 上限 / 只消费一次 这些规则都能在 JVM 单测里逐条打靶。
 * 真正的落盘在 [MenuRequestStore]（薄薄一层 SharedPreferences + org.json）。
 */
internal enum class MenuRequestStatus(val wire: String) {
    /** 还没交给 Dart。 */
    pending("pending"),

    /** 已经交给 Dart（推送成功或已被 pull 走），等它回结果。 */
    delivered("delivered"),

    /** 终态：Dart 已完成。 */
    completed("completed"),

    /** 终态：Dart 执行失败。 */
    failed("failed"),

    /** 终态：超过 TTL 被丢弃。 */
    expired("expired"),
    ;

    /** 终态：不会再被推送、也不会再被 pull。 */
    val isTerminal: Boolean get() = this != pending && this != delivered

    companion object {
        /** 与 Dart 侧共用的稳定 wire 值（**不得随意改名**）。 */
        fun fromWire(raw: String?): MenuRequestStatus =
            entries.firstOrNull { it.wire == raw } ?: pending
    }
}

/**
 * 一条待交付的菜单请求。
 *
 * [requestId] 是**幂等键**：同一 id 只会被入队一次、只会被消费一次。
 */
internal data class PendingMenuRequest(
    val requestId: String,
    val actionId: String,
    val args: Map<String, Any?> = emptyMap(),
    val createdAt: Long = 0L,
    val status: MenuRequestStatus = MenuRequestStatus.pending,
) {

    /**
     * 与 Dart 侧**冻结契约**完全一致的载荷。
     *
     * 刻意**只有**这四个键（`requestId` / `actionId` / `args` / `createdAt`）：
     * 内部状态（[status]）是原生自己的事，绝不混进协议里。
     */
    fun toPayload(): Map<String, Any?> = linkedMapOf(
        "requestId" to requestId,
        "actionId" to actionId,
        "args" to args,
        "createdAt" to createdAt,
    )

    fun withStatus(next: MenuRequestStatus): PendingMenuRequest = copy(status = next)

    companion object {
        /** 从载荷还原（字段不全 / 类型不符一律返回 null，不猜）。 */
        fun fromPayload(raw: Map<*, *>): PendingMenuRequest? {
            val requestId = (raw["requestId"] as? String)?.trim().orEmpty()
            val actionId = (raw["actionId"] as? String)?.trim().orEmpty()
            if (requestId.isEmpty() || actionId.isEmpty()) return null
            val createdAt = (raw["createdAt"] as? Number)?.toLong() ?: 0L
            val args = (raw["args"] as? Map<*, *>)?.let { source ->
                val out = LinkedHashMap<String, Any?>()
                source.forEach { (key, value) -> if (key is String) out[key] = value }
                out
            } ?: emptyMap()
            return PendingMenuRequest(
                requestId = requestId,
                actionId = actionId,
                args = args,
                createdAt = createdAt,
            )
        }
    }
}

/**
 * 待交付请求的**唯一**队列实现。
 *
 * 规则（需求 §17，全部由单测钉住）：
 * * 按 [PendingMenuRequest.requestId] 去重：同 id 重复入队被忽略；
 * * 超过 [TTL_MS] 的条目视为 `expired` 并被丢弃；
 * * 最多 [MAX_ENTRIES] 条，超出时丢**最旧**的；
 * * 已终结（completed / failed / expired）的 id 进 [COMPLETED_LRU]（LRU，最多 64 条），
 *   因此"已完成的请求"绝不会被重新入队或重新推送（Activity 重建同理）。
 *
 * 时钟由构造参数注入 —— 过期与 TTL 因此是**可测的纯行为**。
 */
internal class MenuRequestQueue(
    initial: List<PendingMenuRequest> = emptyList(),
    completedIds: List<String> = emptyList(),
    private val now: () -> Long = { System.currentTimeMillis() },
) {

    private val entries = ArrayList<PendingMenuRequest>()

    /** 已完成/已终结 id 的 LRU：index 0 = 最新。 */
    private val completed = ArrayList<String>()

    /** 因 TTL 被丢弃的条数（诊断）。 */
    var expiredCount: Int = 0
        private set

    /** 因超过容量被丢弃的条数（诊断）。 */
    var droppedForCapacity: Int = 0
        private set

    /** 真正完成（Dart 回报 completed）的条数（诊断）。 */
    var completedCount: Int = 0
        private set

    init {
        completedIds.forEach { rememberTerminal(it) }
        // 恢复时一律按 pending 处理：是否真的送达过只有 Dart 知道，
        // 而重复推送是幂等的（Dart 按 requestId 去重），漏推送却是用户看得见的丢失。
        initial.forEach { request ->
            if (request.status.isTerminal) {
                rememberTerminal(request.requestId)
            } else {
                entries.add(request.withStatus(MenuRequestStatus.pending))
            }
        }
        trimToCapacity()
    }

    /** 当前非终态条目数。 */
    val size: Int get() = entries.size

    /** 非终态条目（按入队顺序，最旧在前）。 */
    fun all(): List<PendingMenuRequest> = entries.toList()

    /** 还没交给 Dart 的条目（只读快照，**不消费**）。 */
    fun pendingSnapshot(): List<PendingMenuRequest> {
        expireStale()
        return entries.filter { it.status == MenuRequestStatus.pending }
    }

    /**
     * 取出并**消费**（标记 delivered）全部 pending 条目。
     *
     * 幂等键的意义就在这里：同一条请求只会被交给 Dart 一次 ——
     * 第二次调用拿到的是空列表（"consumed at most once"）。
     */
    fun takePending(): List<PendingMenuRequest> {
        expireStale()
        val taken = ArrayList<PendingMenuRequest>()
        for (index in entries.indices) {
            val entry = entries[index]
            if (entry.status != MenuRequestStatus.pending) continue
            taken.add(entry)
            entries[index] = entry.withStatus(MenuRequestStatus.delivered)
        }
        return taken
    }

    /**
     * 入队一条新请求。
     *
     * @return true = 真的入队了；false = 被忽略（空 id / 重复 / 已终结）。
     */
    fun enqueue(request: PendingMenuRequest): Boolean {
        expireStale()
        val id = request.requestId.trim()
        if (id.isEmpty()) return false
        if (isTerminalId(id)) return false
        if (entries.any { it.requestId == id }) return false
        entries.add(
            request.copy(
                requestId = id,
                createdAt = if (request.createdAt > 0L) request.createdAt else now(),
                status = MenuRequestStatus.pending,
            ),
        )
        trimToCapacity()
        return true
    }

    /** 标记为已交给 Dart（推送成功 / 已被 pull）。 */
    fun markDelivered(requestId: String): Boolean {
        val index = entries.indexOfFirst { it.requestId == requestId }
        if (index < 0) return false
        val entry = entries[index]
        if (entry.status.isTerminal) return false
        entries[index] = entry.withStatus(MenuRequestStatus.delivered)
        return true
    }

    /** Dart 回报 completed：条目出队，id 进 LRU。 */
    fun markCompleted(requestId: String): Boolean = terminate(requestId, completed = true)

    /** Dart 回报 failed：条目出队，id 进 LRU。 */
    fun markFailed(requestId: String): Boolean = terminate(requestId, completed = false)

    /** 该 id 是否已经终结（绝不再入队 / 再推送）。 */
    fun isTerminalId(requestId: String): Boolean = completed.contains(requestId)

    /** 已完成（终结）id 的 LRU 快照（最新在前）。 */
    fun completedIds(): List<String> = completed.toList()

    /** 丢弃超过 TTL 的条目；返回本次丢弃条数。 */
    fun expireStale(): Int {
        val deadline = now() - TTL_MS
        var removed = 0
        val iterator = entries.iterator()
        while (iterator.hasNext()) {
            val entry = iterator.next()
            if (entry.createdAt in 1..deadline) {
                iterator.remove()
                rememberTerminal(entry.requestId)
                expiredCount += 1
                removed += 1
            }
        }
        return removed
    }

    private fun terminate(requestId: String, completed: Boolean): Boolean {
        val index = entries.indexOfFirst { it.requestId == requestId }
        if (index < 0) return isTerminalId(requestId)
        entries.removeAt(index)
        rememberTerminal(requestId)
        if (completed) completedCount += 1
        return true
    }

    /** id 进 LRU（去重 + 封顶），保证"已结束的请求不会再跑第二遍"。 */
    private fun rememberTerminal(requestId: String) {
        if (requestId.isEmpty()) return
        completed.remove(requestId)
        completed.add(0, requestId)
        while (completed.size > COMPLETED_LRU) {
            completed.removeAt(completed.size - 1)
        }
    }

    private fun trimToCapacity() {
        while (entries.size > MAX_ENTRIES) {
            entries.removeAt(0)
            droppedForCapacity += 1
        }
    }

    companion object {
        /** 请求存活上限：超过即过期丢弃（需求 §17）。 */
        const val TTL_MS = 10 * 60 * 1000L

        /** 队列容量上限：超出时丢最旧的（需求 §17）。 */
        const val MAX_ENTRIES = 32

        /** 已终结 id 的 LRU 容量（需求 §17：64）。 */
        const val COMPLETED_LRU = 64
    }
}

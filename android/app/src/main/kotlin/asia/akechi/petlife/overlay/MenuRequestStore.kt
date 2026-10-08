package asia.akechi.petlife.overlay

import android.content.Context
import android.content.SharedPreferences
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/**
 * 菜单请求的**落盘层**（Phase 4C-6B-3）。
 *
 * 为什么用 SharedPreferences 而不是 Flutter 的 SQLite：悬浮服务可能在 Flutter 进程
 * 已被回收时继续运行，而"用户刚点了一个要 Dart 执行的动作"这件事必须**立刻**落盘 ——
 * 否则 Activity/引擎一旦重建，这条请求就永远丢了。
 *
 * 设计要点：
 * * 本类**不持有任何内存状态**：每次调用都从 SharedPreferences 读、改、写。
 *   因此服务侧与桥侧各持一份实例也不会出现两份互相矛盾的队列；
 * * 所有调用都发生在**主线程**（菜单手势 / MethodChannel 回调 / 服务回调），
 *   天然串行，不需要额外加锁；
 * * 队列规则（去重 / TTL / 上限 / LRU）全在纯逻辑的 [MenuRequestQueue] 里。
 */
internal class MenuRequestStore(context: Context) {

    private val prefs: SharedPreferences =
        context.applicationContext.getSharedPreferences(PetOverlayStore.PREFS_NAME, Context.MODE_PRIVATE)

    /**
     * 生成一条新请求并入队。
     *
     * @return 入队成功的请求；被去重命中（同 id 已存在/已终结）时返回 null。
     */
    fun enqueue(actionId: String, args: Map<String, Any?>): PendingMenuRequest? {
        if (actionId.isBlank()) return null
        val queue = load()
        val request = PendingMenuRequest(
            requestId = UUID.randomUUID().toString(),
            actionId = actionId,
            args = args,
            createdAt = System.currentTimeMillis(),
            status = MenuRequestStatus.pending,
        )
        if (!queue.enqueue(request)) return null
        save(queue)
        return request
    }

    /** 还没交给 Dart 的请求（只读，不消费）。 */
    fun pending(): List<PendingMenuRequest> = load().pendingSnapshot()

    /**
     * 按 requestId 查 canonical 动作 id（供完成日志使用；查不到返回 null，不猜）。
     *
     * 必须在 `markCompleted` / `markFailed` **之前**调用 —— 终态会让条目出队。
     */
    fun actionIdOf(requestId: String): String? =
        load().all().firstOrNull { it.requestId == requestId }?.actionId

    /** 取出并消费（标记 delivered）全部 pending 请求。 */
    fun takePending(): List<PendingMenuRequest> {
        val queue = load()
        val taken = queue.takePending()
        if (taken.isNotEmpty()) save(queue)
        return taken
    }

    fun markDelivered(requestId: String): Boolean {
        val queue = load()
        val changed = queue.markDelivered(requestId)
        if (changed) save(queue)
        return changed
    }

    fun markCompleted(requestId: String): Boolean {
        val queue = load()
        val changed = queue.markCompleted(requestId)
        if (changed) save(queue)
        return changed
    }

    fun markFailed(requestId: String): Boolean {
        val queue = load()
        val changed = queue.markFailed(requestId)
        if (changed) save(queue)
        return changed
    }

    private fun load(): MenuRequestQueue {
        val entries = ArrayList<PendingMenuRequest>()
        val raw = prefs.getString(KEY_PENDING_REQUESTS, null)
        if (!raw.isNullOrEmpty()) {
            runCatching {
                val array = JSONArray(raw)
                for (index in 0 until array.length()) {
                    val obj = array.optJSONObject(index) ?: continue
                    PendingMenuRequest.fromPayload(obj.toKotlinMap())?.let { entries.add(it) }
                }
            }.onFailure { OverlayLog.warn("菜单请求队列解析失败（按空队列处理）", it) }
        }
        val completed = readIds(KEY_COMPLETED_REQUESTS)
        val delivered = readIds(KEY_DELIVERED_REQUESTS)
        val queue = MenuRequestQueue(initial = entries, completedIds = completed)
        // 载荷本身**不含** status（它是原生内部状态），因此"已交付"用一份原生 id 列表还原 ——
        // 这样"一条请求只交给 Dart 一次"在多次 load/save 之间依然成立。
        delivered.forEach { queue.markDelivered(it) }
        return queue
    }

    private fun save(queue: MenuRequestQueue) {
        val entries = JSONArray()
        queue.all().forEach { request -> entries.put(JSONObject(request.toPayload())) }
        val delivered = JSONArray()
        queue.all()
            .filter { it.status == MenuRequestStatus.delivered }
            .forEach { delivered.put(it.requestId) }
        val completed = JSONArray()
        queue.completedIds().forEach { id -> completed.put(id) }
        prefs.edit()
            .putString(KEY_PENDING_REQUESTS, entries.toString())
            .putString(KEY_DELIVERED_REQUESTS, delivered.toString())
            .putString(KEY_COMPLETED_REQUESTS, completed.toString())
            .apply()
    }

    private fun readIds(key: String): List<String> {
        val raw = prefs.getString(key, null) ?: return emptyList()
        return runCatching {
            val array = JSONArray(raw)
            List(array.length()) { index -> array.optString(index, "") }.filter { it.isNotEmpty() }
        }.getOrElse {
            OverlayLog.warn("菜单请求 id 列表解析失败（按空处理） key=$key")
            emptyList()
        }
    }

    /** `org.json` → Kotlin（JSONObject.NULL 折成 null，嵌套 map/list 递归展开）。 */
    private fun JSONObject.toKotlinMap(): Map<String, Any?> {
        val out = LinkedHashMap<String, Any?>()
        val names = keys()
        while (names.hasNext()) {
            val key = names.next()
            out[key] = unwrap(opt(key))
        }
        return out
    }

    private fun unwrap(value: Any?): Any? = when (value) {
        null, JSONObject.NULL -> null
        is JSONObject -> value.toKotlinMap()
        is JSONArray -> List(value.length()) { index -> unwrap(value.opt(index)) }
        else -> value
    }

    companion object {
        /** 待交付请求（与 Dart 侧契约钉死的键名）。 */
        internal const val KEY_PENDING_REQUESTS = "overlay.menu.pending_requests"

        /** 已交付请求 id（原生内部状态；载荷里刻意不含 status）。 */
        internal const val KEY_DELIVERED_REQUESTS = "overlay.menu.delivered_requests"

        /** 已终结请求 id 的 LRU（原生内部，不参与协议）。 */
        internal const val KEY_COMPLETED_REQUESTS = "overlay.menu.completed_requests"
    }
}

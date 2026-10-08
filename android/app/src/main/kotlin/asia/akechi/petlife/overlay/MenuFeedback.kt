package asia.akechi.petlife.overlay

/**
 * 窗口内反馈条的**类型**（Phase 4C-6B-3，需求 §17）。
 *
 * 四种语义与菜单动作的三种走向一一对应：
 * 请求已发出（`running`）、原生动作完成（`success`）、需要提醒（`warning`）、失败（`error`）。
 */
internal enum class FeedbackKind(val wire: String) {
    running("running"),
    success("success"),
    warning("warning"),
    error("error"),
    ;

    companion object {
        fun fromWire(raw: String?): FeedbackKind =
            entries.firstOrNull { it.wire == raw } ?: running
    }
}

/**
 * 反馈条的**纯逻辑**：位置计算 + 陈旧结果判定。
 *
 * 两条硬约束（需求 §17）都在这里被钉住：
 * 1. 反馈条只画在**窗口矩形内部**（本对象只接收窗口尺寸、只返回内部矩形，
 *    没有任何"改窗口尺寸"的能力）—— 因此显示反馈**不可能**改变窗口几何；
 * 2. **旧异步结果不得覆盖新反馈**：新请求会把上一条 requestId 记入 `superseded`，
 *    之后迟到的旧结果一律被丢弃。
 */
internal object MenuFeedbackPolicy {

    /** 自动消失时间：几秒，够读一句话，也不会长期占着画面。 */
    const val DURATION_MS = 2_800L

    /** 被取代的 requestId 保留上限（有界，避免无限增长）。 */
    const val MAX_SUPERSEDED = 16

    /** 反馈条高度（dp）。 */
    const val BAR_HEIGHT_DP = 26f

    /** 反馈条与窗口底边 / 左右边的间距（dp）。 */
    const val MARGIN_DP = 8f

    /** `completeMenuRequest` 的终态 wire → 反馈类型（原生不猜，只映射）。 */
    fun kindOfStatus(status: String?): FeedbackKind = when (status) {
        MenuRequestBridge.STATUS_COMPLETED -> FeedbackKind.success
        MenuRequestBridge.STATUS_FAILED -> FeedbackKind.error
        MenuRequestBridge.STATUS_EXPIRED -> FeedbackKind.warning
        else -> FeedbackKind.running
    }

    /**
     * 这条反馈是不是**陈旧结果**（必须丢弃）。
     *
     * @param incoming  本次要显示的 requestId（null = 本地即时反馈，永远显示）
     * @param active    当前正在显示的 requestId
     * @param superseded 已被更新的反馈取代掉的 requestId 集合
     */
    fun isStale(incoming: String?, active: String?, superseded: Set<String>): Boolean {
        if (incoming == null) return false
        if (incoming == active) return false
        return superseded.contains(incoming)
    }

    /**
     * 反馈条在**窗口内**的矩形（容器坐标）。
     *
     * 只依赖传入的窗口尺寸 ⇒ 纯函数、可单测，且**永远不会反过来影响窗口几何**。
     * 位置固定在窗口底部（轮盘下方），不覆盖人物头部与主按钮所在的环带中心区域。
     */
    fun rectInWindow(
        windowWidth: Int,
        windowHeight: Int,
        barHeightPx: Int,
        marginPx: Int,
    ): OverlayRect {
        if (windowWidth <= 0 || windowHeight <= 0) return OverlayRect(0, 0, 0, 0)
        val height = barHeightPx.coerceIn(1, windowHeight)
        val safeMargin = marginPx.coerceAtLeast(0)
        val bottom = (windowHeight - safeMargin).coerceAtLeast(height)
        val top = (bottom - height).coerceAtLeast(0)
        val sideInset = safeMargin.coerceAtMost((windowWidth - 1) / 2)
        val left = sideInset.coerceAtMost(windowWidth - 1)
        val right = (windowWidth - sideInset).coerceAtLeast(left + 1)
        return OverlayRect(left, top, right, bottom.coerceAtMost(windowHeight))
    }
}

/**
 * 反馈条的**运行时状态**（哪条在显示、什么时候该消失、哪些已被取代）。
 *
 * 抽成与 View 无关的纯类，是为了让"旧结果不得覆盖新反馈"这条规则能在 JVM 单测里打靶。
 */
internal class MenuFeedbackState(private val now: () -> Long = { System.currentTimeMillis() }) {

    var text: String? = null
        private set

    var kind: FeedbackKind = FeedbackKind.running
        private set

    var requestId: String? = null
        private set

    var expiresAt: Long = 0L
        private set

    private val superseded = ArrayList<String>()

    val isShowing: Boolean get() = text != null

    /**
     * 请求显示一条反馈。
     *
     * @return false = 这是**陈旧结果**，调用方必须原样忽略（不改文字、不重置倒计时）。
     */
    fun show(text: String, kind: FeedbackKind, requestId: String? = null): Boolean {
        if (text.isBlank()) return false
        if (MenuFeedbackPolicy.isStale(requestId, this.requestId, superseded.toSet())) {
            OverlayLog.log("menu.feedback 忽略陈旧结果 requestId=$requestId（当前=${this.requestId}）")
            return false
        }
        // 新的 requestId 取代旧的：旧 id 进"已被取代"集合，之后迟到的结果会被丢弃。
        val previous = this.requestId
        if (requestId != null && previous != null && previous != requestId) {
            superseded.remove(previous)
            superseded.add(0, previous)
            while (superseded.size > MenuFeedbackPolicy.MAX_SUPERSEDED) {
                superseded.removeAt(superseded.size - 1)
            }
        }
        this.text = text
        this.kind = kind
        this.requestId = requestId
        this.expiresAt = now() + MenuFeedbackPolicy.DURATION_MS
        return true
    }

    /** 反馈条是否已到期（到点即隐藏）。 */
    fun isExpired(): Boolean {
        if (text == null) return false
        return now() >= expiresAt
    }

    /** 立即隐藏（手动关闭 / 到期）。 */
    fun hide() {
        text = null
        requestId = null
        expiresAt = 0L
    }
}

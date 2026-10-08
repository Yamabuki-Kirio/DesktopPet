package asia.akechi.petlife.overlay

import android.content.Context
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.TextView
import kotlin.math.roundToInt

/**
 * 双窗口模式下的**菜单窗宿主**（Phase 4C-6B-4）。
 *
 * 生命周期（**复用探测器真机验证过的行为**）：
 * * [addOnce]：服务 attach 时**最先**加窗，且整个窗口纪元**只加一次**；
 * * [prepareOpen]：阶段 1 —— 把窗口摆到目标矩形，**仍** `FLAG_NOT_TOUCHABLE` +
 *   内容 `INVISIBLE`（参与测量/布局，因此轮盘会被量到目标尺寸；但**不绘制**、不吃输入）；
 * * [presentOpen]：阶段 2 —— 布局达标后**第二次** `updateViewLayout`：去 `FLAG_NOT_TOUCHABLE` + 内容 `VISIBLE`；
 * * [follow]：菜单开着时跟随桌宠移动，只 `updateViewLayout`；
 * * [close]：一次 `updateViewLayout` —— 加 `FLAG_NOT_TOUCHABLE` + 缩到 1×1 + 移到安全角落 + 内容 `GONE`。
 *
 * 打开拆成两阶段的原因：菜单的**第一帧**必须发生在"轮盘已真实布局到目标尺寸"之后，
 * 否则动画会从错误坐标起跑（真机表现为"菜单先出现在上方再滑下来"）。
 *
 * 准备阶段**必须**用 `INVISIBLE` 而**不是** `GONE`：`GONE` 子树不参与 measure/layout，
 * 于是宿主窗尺寸达标并不能证明轮盘被量到目标矩形（这正是本次修复的缺口）。
 *
 * **绝不**在开/关时 `removeView` / `addView`（那会让菜单被重新抬到桌宠窗之上）。
 *
 * 内容层结构（[MenuWindowHostView]）：
 * ```
 * FrameLayout（菜单窗根）
 *   ├── FrameLayout menuHost     轮盘层（惰性挂一个 [WheelMenuView]，跨开合复用）
 *   └── FrameLayout feedbackHost 反馈层（窗口内反馈；关闭态整块 GONE）
 * ```
 */
internal class DualWindowMenuWindow(
    private val context: Context,
    private val windowManager: WindowManager,
) {

    /** 加/减/更新账本（`menuAddCount` 恒为 1 的可判定形式）。 */
    val ledger: DualWindowWindowLedger = DualWindowWindowLedger()

    private var host: MenuWindowHostView? = null
    private var params: WindowManager.LayoutParams? = null
    private var wheel: WheelMenuView? = null
    private var menuOpen: Boolean = false

    /**
     * 布局代次：每次"准备打开 / 关闭 / 移除"都 +1。
     *
     * 打开序列用它判定"布局回调是不是本次打开产生的" —— 旧代次的回调绝不参与新一次打开
     * （与 [MenuOpenSequencer.sessionId] 一起构成双保险）。
     */
    private var layoutGeneration: Long = 0L

    /** 本次**准备打开**的会话号与目标矩形（null = 没有在准备）。 */
    private var pendingSessionId: Long = 0L
    private var pendingRect: OverlayRect? = null

    val isAttached: Boolean get() = host != null

    /** 菜单是否处于打开态（窗口可触摸且内容可见）。 */
    val isOpen: Boolean get() = menuOpen

    val menuAddCount: Int get() = ledger.menuAddCount

    val currentLayoutGeneration: Long get() = layoutGeneration

    /** 正在准备的目标矩形（诊断：`targetMenuRect`）。 */
    val pendingTargetRect: OverlayRect? get() = pendingRect

    val pendingOpenSession: Long get() = pendingSessionId

    /** 菜单窗根 View（测量 / 挂一次性布局回调用；未挂载时 null）。 */
    fun hostView(): View? = host

    /** 当前内容层的三态可见性名（诊断：`GONE` / `INVISIBLE` / `VISIBLE`）。 */
    fun contentVisibilityName(): String = host?.contentVisibility?.wire ?: "none"

    /** 当前菜单窗 LayoutParams 的一行式文本（诊断：`menuWindow` 的 x/y/宽/高）。 */
    fun layoutParamsText(): String {
        val lp = params ?: return "none"
        return "(${lp.x},${lp.y} ${lp.width}x${lp.height})"
    }

    private fun density(): Float = context.resources.displayMetrics.density

    /**
     * 加窗（**恰好一次**，幂等）。任何异常都向上抛，由调用方决定回退单窗口 ——
     * 本类不吞掉"没加成功"这一事实。
     */
    fun addOnce() {
        if (host != null) return
        val created = MenuWindowHostView(context)
        val closed = DualWindowSceneSpec.closedMenuWindow(density())
        val lp = WindowManager.LayoutParams(
            closed.width,
            closed.height,
            OverlayWindowSpec.windowType(Build.VERSION.SDK_INT),
            // 关闭态即"输入释放"：含 FLAG_NOT_TOUCHABLE，绝不用 alpha=0。
            OverlayWindowSpec.windowFlags(touchThrough = true),
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = closed.left
            y = closed.top
            alpha = 1f
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                layoutInDisplayCutoutMode =
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
            }
        }
        created.setContentVisible(false)
        windowManager.addView(created, lp)
        host = created
        params = lp
        val seq = ledger.recordAdd(OverlayWindowKind.MENU)
        OverlayLog.log(
            "dual.menu add seq=$seq menuAddCount=${ledger.menuAddCount} type=${lp.type} " +
                "rect=(${closed.left},${closed.top} ${closed.width}x${closed.height}) " +
                "flags=+NOT_TOUCHABLE content=GONE",
        )
    }

    /**
     * 取（惰性创建）轮盘 View：整个菜单窗生命周期内**只创建一个实例**，跨开合复用
     * （每次打开通过 `prepareContent()` + `beginOpenAnimation()` 重置内部状态机）。
     */
    fun wheelView(): WheelMenuView? {
        val current = host ?: return null
        wheel?.let { return it }
        val created = WheelMenuView(context)
        current.attachMenuView(created)
        wheel = created
        return created
    }

    /**
     * 打开菜单**阶段 1 / 准备布局**：把菜单窗摆到目标矩形，但
     * **仍保持** `FLAG_NOT_TOUCHABLE`、内容 `INVISIBLE`（参与测量/布局但**不绘制**）。
     *
     * 这里用 `INVISIBLE` 而**不是** `GONE` 是本阶段的关键：`GONE` 子树不参与 measure/layout，
     * 于是宿主窗的测量尺寸无法证明 [WheelMenuView] 已被量到目标矩形；`INVISIBLE` 让轮盘
     * 真实参与布局（因此闸门可以只信轮盘自己的 `measuredWidth/Height`），同时**不绘制**、
     * 不吃输入。**不用** alpha=0 代替（那只是不绘制，语义上仍是"可见"）。
     *
     * 调用方应已先 `wheel.prepareContent(...)` 配置好本次打开的层级/几何。
     * 这是"先摆位、后动画"的第一步：这一帧**绝不会**显示菜单、也**绝不会**吃输入，
     * 因此不可能出现"菜单先出现在错误位置"的第一帧。真正的显示 + 起动画由调用方
     * 在 [MenuOpenSequencer] 判定**轮盘**布局达标后调用 [presentOpen] 完成（第二次 `updateViewLayout`）。
     *
     * **不** remove/add，只 `updateViewLayout`。
     */
    fun prepareOpen(rect: OverlayRect, session: Long): Boolean {
        val current = host ?: return false
        val lp = params ?: return false
        val width = rect.width.coerceAtLeast(1)
        val height = rect.height.coerceAtLeast(1)
        val left = rect.left
        val top = rect.top
        layoutGeneration += 1
        pendingSessionId = session
        pendingRect = OverlayRect(left, top, left + width, top + height)
        // 内容 INVISIBLE：参与测量/布局（轮盘会被量到目标尺寸），但绝不绘制、绝不吃输入。
        current.setContentPreparing()
        // 仍不可触摸：准备布局期间绝不吃输入。
        lp.flags = OverlayWindowSpec.windowFlags(touchThrough = true)
        lp.width = width
        lp.height = height
        lp.x = left
        lp.y = top
        val ok = runCatching { windowManager.updateViewLayout(current, lp) }.isSuccess
        ledger.recordUpdate(OverlayWindowKind.MENU)
        OverlayLog.log(
            "dual.menu.prepare session=$session gen=$layoutGeneration " +
                "rect=($left,$top ${width}x$height) flags=+NOT_TOUCHABLE content=INVISIBLE",
        )
        return ok
    }

    /**
     * 打开菜单**阶段 2 / 显示并放行输入**：内容 `VISIBLE` + 去 `FLAG_NOT_TOUCHABLE`
     * （**第二次** `updateViewLayout`；矩形已在 [prepareOpen] 摆好）。
     *
     * 陈旧会话（已被关闭 / 被新一次打开取代）一律**惰性**：不显示、不清标志、不动窗口。
     */
    fun presentOpen(session: Long): Boolean {
        val current = host ?: return false
        val lp = params ?: return false
        if (pendingRect == null || session != pendingSessionId) {
            OverlayLog.warn(
                "dual.menu.present 被忽略：陈旧会话 session=$session pending=$pendingSessionId",
            )
            return false
        }
        current.setContentVisible(true)
        lp.flags = OverlayWindowSpec.windowFlags(touchThrough = false)
        val ok = runCatching { windowManager.updateViewLayout(current, lp) }.isSuccess
        menuOpen = ok
        ledger.recordUpdate(OverlayWindowKind.MENU)
        OverlayLog.log(
            "dual.menu.present session=$session gen=$layoutGeneration " +
                "rect=$pendingRect touchable=true content=VISIBLE menuOpen=$menuOpen",
        )
        return ok
    }

    /** 菜单开着时跟随桌宠：一次 `updateViewLayout`（**不动** flags / 内容可见性）。 */
    fun follow(rect: OverlayRect): Boolean {
        if (!menuOpen) return false
        val current = host ?: return false
        val lp = params ?: return false
        lp.width = rect.width.coerceAtLeast(1)
        lp.height = rect.height.coerceAtLeast(1)
        lp.x = rect.left
        lp.y = rect.top
        val ok = runCatching { windowManager.updateViewLayout(current, lp) }.isSuccess
        ledger.recordUpdate(OverlayWindowKind.MENU)
        if (!ok) OverlayLog.warn("dual.menu follow updateViewLayout 失败 rect=$rect")
        return ok
    }

    /** 关闭菜单：一次 `updateViewLayout`（加 NOT_TOUCHABLE + 1×1 + 角落 + 内容 GONE）。 */
    fun close(): Boolean {
        val current = host ?: return false
        val lp = params ?: return false
        val state = DualWindowSceneSpec.closedMenuWindow(density())
        // 关闭使本次打开的任何待处理布局回调失效（旧代次 / 旧会话一律惰性）。
        layoutGeneration += 1
        pendingSessionId = 0
        pendingRect = null
        current.setContentVisible(false)
        lp.flags = OverlayWindowSpec.windowFlags(touchThrough = true)
        lp.width = state.width
        lp.height = state.height
        lp.x = state.left
        lp.y = state.top
        val ok = runCatching { windowManager.updateViewLayout(current, lp) }.isSuccess
        menuOpen = false
        val seq = ledger.recordUpdate(OverlayWindowKind.MENU)
        OverlayLog.log(
            "dual.menu close seq=$seq flags=+NOT_TOUCHABLE size=1x1 " +
                "pos=(${state.left},${state.top}) content=GONE",
        )
        return ok
    }

    /** 窗口内反馈（关闭态时调用方应改用 Toast 兜底）。 */
    fun showFeedback(text: String, kind: FeedbackKind, requestId: String? = null): Boolean {
        if (!menuOpen) return false
        return host?.showFeedback(text, kind, requestId) ?: false
    }

    fun hideFeedback() {
        host?.hideFeedback()
    }

    /** 反馈层当前是否真的可见（关闭态恒 false ⇒ 调用方回退 Toast）。 */
    val isFeedbackVisible: Boolean get() = menuOpen && host?.isFeedbackVisible == true

    /** 移除窗口（幂等；仅在整个窗口纪元结束 / 服务停止时调用）。 */
    fun remove() {
        val current = host ?: return
        host = null
        params = null
        wheel = null
        menuOpen = false
        layoutGeneration += 1
        pendingSessionId = 0
        pendingRect = null
        ledger.recordRemove(OverlayWindowKind.MENU)
        runCatching { windowManager.removeView(current) }
            .onFailure { OverlayLog.warn("dual.menu removeView 失败", it) }
        OverlayLog.log("dual.menu remove menuRemoveCount=${ledger.menuRemoveCount}")
    }

    /**
     * 菜单窗根 View：轮盘层 + 反馈层。
     *
     * 反馈层与单窗口版 [PetOverlayView] 的反馈层同源（[MenuFeedbackState] + [MenuFeedbackPolicy]），
     * 只是宿主换成了菜单窗。
     */
    internal class MenuWindowHostView(context: Context) : FrameLayout(context) {

        private val menuHost: FrameLayout = FrameLayout(context).apply {
            visibility = View.GONE
            isClickable = false
            layoutParams = LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT)
        }

        private val feedbackHost: FrameLayout = FrameLayout(context).apply {
            visibility = View.GONE
            isClickable = false
            layoutParams = LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT)
        }

        private val feedbackBar: TextView = TextView(context).apply {
            gravity = Gravity.CENTER
            maxLines = 1
            ellipsize = android.text.TextUtils.TruncateAt.END
            setTextColor(android.graphics.Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
            setPadding(dp(10f), dp(3f), dp(10f), dp(3f))
            layoutParams = LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT)
        }

        private val feedbackState = MenuFeedbackState()
        private val feedbackDismiss = Runnable { hideFeedback() }

        private val density: Float get() = resources.displayMetrics.density

        init {
            feedbackHost.addView(feedbackBar)
            addView(menuHost)
            addView(feedbackHost)
        }

        fun attachMenuView(view: View) {
            menuHost.removeAllViews()
            menuHost.addView(view, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
            requestLayout()
        }

        /**
         * 内容可见性三态开关（缺陷修复：准备布局阶段必须让轮盘**参与测量**）：
         *
         * * [MenuContentVisibility.gone]（关闭态）：整块 `GONE`，不参与测量/布局、不绘制、不吃触摸；
         * * [MenuContentVisibility.invisible]（准备布局态）：整块 `INVISIBLE`，**参与测量/布局**
         *   （因此 [WheelMenuView] 会被量到菜单窗的目标尺寸），但**不绘制**、不吃触摸；
         * * [MenuContentVisibility.visible]（打开态）：整块 `VISIBLE`，绘制且可交互。
         *
         * **不触碰窗口 LayoutParams** —— 窗口尺寸/位置由 [DualWindowMenuWindow] 在同一次
         * `updateViewLayout` 里改，内容可见性只是子 View 属性。
         */
        fun setContentVisibility(visibility: MenuContentVisibility) {
            menuHost.visibility = when (visibility) {
                MenuContentVisibility.gone -> View.GONE
                MenuContentVisibility.invisible -> View.INVISIBLE
                MenuContentVisibility.visible -> View.VISIBLE
            }
            if (!visibility.draws) {
                feedbackBar.removeCallbacks(feedbackDismiss)
                feedbackHost.visibility = View.GONE
                feedbackState.hide()
            }
            requestLayout()
            invalidate()
        }

        /** 关闭态 / 打开态二值入口（GONE / VISIBLE）。 */
        fun setContentVisible(visible: Boolean) {
            setContentVisibility(
                if (visible) MenuContentVisibility.visible else MenuContentVisibility.gone,
            )
        }

        /** 准备布局态：参与测量/布局但**不绘制**（INVISIBLE）。 */
        fun setContentPreparing() {
            setContentVisibility(MenuContentVisibility.invisible)
        }

        /** 当前内容层的三态可见性（诊断）。 */
        val contentVisibility: MenuContentVisibility
            get() = when (menuHost.visibility) {
                View.VISIBLE -> MenuContentVisibility.visible
                View.INVISIBLE -> MenuContentVisibility.invisible
                else -> MenuContentVisibility.gone
            }

        fun showFeedback(text: String, kind: FeedbackKind, requestId: String? = null): Boolean {
            if (!feedbackState.show(text, kind, requestId)) return false
            feedbackBar.text = text
            feedbackBar.background = GradientDrawable().apply {
                cornerRadius = dpF(8f)
                setColor(feedbackColor(kind))
            }
            feedbackHost.visibility = View.VISIBLE
            placeFeedback()
            feedbackBar.removeCallbacks(feedbackDismiss)
            feedbackBar.postDelayed(feedbackDismiss, MenuFeedbackPolicy.DURATION_MS)
            invalidate()
            OverlayLog.log(
                "dual.menu.feedback show kind=${kind.wire} requestId=${requestId ?: "<local>"} text=$text",
            )
            return true
        }

        fun hideFeedback() {
            feedbackBar.removeCallbacks(feedbackDismiss)
            if (feedbackHost.visibility != View.GONE) {
                feedbackHost.visibility = View.GONE
                invalidate()
            }
            feedbackState.hide()
        }

        val isFeedbackVisible: Boolean get() = feedbackHost.visibility == View.VISIBLE

        val feedbackText: String? get() = feedbackState.text

        override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
            super.onSizeChanged(w, h, oldw, oldh)
            if (feedbackHost.visibility == View.VISIBLE) placeFeedback()
        }

        override fun onDetachedFromWindow() {
            feedbackBar.removeCallbacks(feedbackDismiss)
            super.onDetachedFromWindow()
        }

        private fun placeFeedback() {
            if (width <= 0 || height <= 0) return
            val lp = feedbackBar.layoutParams as? LayoutParams ?: return
            val rect = MenuFeedbackPolicy.rectInWindow(
                windowWidth = width,
                windowHeight = height,
                barHeightPx = dp(MenuFeedbackPolicy.BAR_HEIGHT_DP),
                marginPx = dp(MenuFeedbackPolicy.MARGIN_DP),
            )
            if (rect.width <= 0 || rect.height <= 0) return
            lp.width = rect.width
            lp.height = rect.height
            lp.leftMargin = rect.left
            lp.topMargin = rect.top
            lp.gravity = Gravity.TOP or Gravity.START
            feedbackBar.layoutParams = lp
        }

        private fun feedbackColor(kind: FeedbackKind): Int = when (kind) {
            FeedbackKind.running -> android.graphics.Color.parseColor("#E61F2933")
            FeedbackKind.success -> android.graphics.Color.parseColor("#E6205B34")
            FeedbackKind.warning -> android.graphics.Color.parseColor("#E6A06300")
            FeedbackKind.error -> android.graphics.Color.parseColor("#E69B1C1C")
        }

        private fun dp(value: Float): Int = (value * density).roundToInt()

        private fun dpF(value: Float): Float = value * density
    }
}

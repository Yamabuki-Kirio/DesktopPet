package asia.akechi.petlife.overlay

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.drawable.Animatable
import android.graphics.drawable.Drawable
import android.graphics.drawable.GradientDrawable
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.TextView
import kotlin.math.roundToInt

/**
 * 悬浮窗的可见状态。
 *
 * 单独建模的原因（4C-2 真机缺陷复盘）：只用一个 `Bitmap?` 无法区分
 * "还没加载 / 加载失败 / 根本没有素材 / 诊断模式"，而它们的界面处理完全不同。
 */
internal enum class OverlayVisual {
    /** 有素材并已显示。 */
    asset,

    /** 正在加载（此时必须显示可见占位，不能是空窗口）。 */
    loading,

    /** 加载/校验失败（必须显示**可见的**错误占位）。 */
    failure,

    /** 还没有任何素材。 */
    empty,

    /**
     * 诊断模式：完全不依赖素材的固定洋红方块。
     *
     * 用于二分定位"问题在窗口/命令时序"还是"在素材解析与绘制"（4C-2 真机排障第二步）。
     */
    debug,
}

/**
 * 可见状态的**纯决策**（可 JVM 单测）。
 *
 * 核心不变式：**只要不是"有图可显示"以外的任何情况，都必须落到一个可见的占位状态** ——
 * 绝不返回"什么都不显示"，也绝不允许把窗口整体做成全透明。
 */
internal object OverlayVisualPolicy {

    fun resolve(
        hasImage: Boolean,
        loading: Boolean,
        lastError: String?,
        debugMode: Boolean = false,
    ): OverlayVisual = when {
        debugMode -> OverlayVisual.debug
        hasImage -> OverlayVisual.asset
        loading -> OverlayVisual.loading
        !lastError.isNullOrEmpty() -> OverlayVisual.failure
        else -> OverlayVisual.empty
    }

    /** 占位/诊断文案（asset 状态不显示占位，返回空串）。 */
    fun placeholderText(visual: OverlayVisual): String = when (visual) {
        OverlayVisual.asset -> ""
        OverlayVisual.loading -> "加载中…"
        OverlayVisual.failure -> "素材加载失败"
        OverlayVisual.empty -> "等待素材"
        OverlayVisual.debug -> "PetLife Overlay"
    }

    /**
     * 是否需要画可见底（不透明边框 + 填充）。
     *
     * 只要不是 [OverlayVisual.asset] 就必须画 —— 这是"窗口永远能被看见"的兜底：
     * 用户至少能看到"这里有一个窗口"，而不是"什么都没发生"。
     */
    fun showsPlaceholderChrome(visual: OverlayVisual): Boolean =
        visual != OverlayVisual.asset
}

/**
 * 悬浮桌宠的**原生 View**（Phase 4C-2）。
 *
 * 结构（Phase 4C-6B-3：单窗口分层 + 窗口内反馈）：
 * ```
 * FrameLayout（根容器 = 当前"场景"窗口：菜单关闭 == 人物矩形，菜单打开 == 人物 ∪ 菜单信封）
 *   ├── FrameLayout menuHost     菜单层（index 0，**在下方**；无菜单时 GONE）
 *   │     └── WheelMenuView      轮盘菜单（菜单打开时挂载）
 *   ├── FrameLayout feedbackHost 反馈层（index 1；无反馈时 GONE，**不改窗口几何**）
 *   │     └── TextView           一条短反馈（窗口底部，自动消失）
 *   └── FrameLayout petContent   人物层（index 2，**在上方**）
 *         ├── ImageView         当前素材（MATCH_PARENT，FIT_CENTER，保持宽高比）
 *         ├── TextView          占位/诊断文案
 *         └── TextView          "动态·第一帧" 角标（4C-4 之前必须显式标注）
 * ```
 *
 * 层级即绘制顺序：人物层永远画在菜单层与反馈层**之上**，菜单背景自然从人物背后穿过，
 * 人物盖住它 —— 因此**不需要在菜单上挖人形洞**（挖洞会错误地露出下层应用）。
 *
 * 三个关键不变式（都是 4C-2 真机两次失败的教训）：
 * 1. **根 View 永远有非零尺寸**：`prepareSceneGeometry` 写 `minimumWidth/Height`，
 *    且 `onMeasure` 先按 EXACTLY 调 `super`（让 FrameLayout 正常测量子 View）再钉死自身尺寸；
 * 2. **非 asset 状态一定有可见底**，绝不出现"全透明窗口"；
 * 3. **alpha / scale / visibility 在每次刷新时显式归位**，避免被历史状态或复用的 View 带成不可见。
 */
internal class PetOverlayView(context: Context) : FrameLayout(context) {

    /**
     * 菜单层容器（Phase 4C-6B-2）。
     *
     * 与 [petContent] 同处**一个窗口**：本层在 index 0（下方），人物层在 index 1（上方），
     * 因此人物永远画在菜单之上。菜单关闭时本层 `GONE`（不参与绘制、也不吃触摸）。
     * 本层自身不消费触摸（`isClickable = false`），触摸由被挂进来的菜单 View 处理。
     */
    private val menuHost: FrameLayout = FrameLayout(context).apply {
        visibility = View.GONE
        isClickable = false
        // 铺满整个窗口：菜单子 View 用 leftMargin/topMargin 定位到容器内偏移。
        layoutParams = LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT)
    }

    /**
     * 桌宠内容容器（Phase 4C-3B）。
     *
     * 存在意义：可见性/透明度/背景这些"桌宠本体"的样式统一作用在内层，
     * 根 View 专心做"场景画布"（尺寸 = 人物 ∪ 菜单 的并集）。菜单层在**同一个窗口**里
     * 位于本层之下，因此这里通过 `leftMargin/topMargin` 表达"人物在容器内的偏移"。
     */
    private val petContent: FrameLayout = FrameLayout(context).apply {
        layoutParams = LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT)
    }

    /**
     * 反馈层容器（Phase 4C-6B-3）。
     *
     * **不是新窗口**：它只是同一个根容器里的一个子 View（index 1），
     * 夹在菜单层（index 0）与人物层（index 2）之间。
     * 因此显示/隐藏反馈**永远不会**触发 `updateViewLayout` —— 窗口几何一个像素都不动。
     */
    private val feedbackHost: FrameLayout = FrameLayout(context).apply {
        visibility = View.GONE
        isClickable = false
        layoutParams = LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT)
    }

    /** 反馈条本体（短文案 + 圆角底）；位置由 [placeFeedback] 按窗口尺寸算到窗口内部。 */
    private val feedbackBar: TextView = TextView(context).apply {
        gravity = Gravity.CENTER
        maxLines = 1
        ellipsize = android.text.TextUtils.TruncateAt.END
        setTextColor(Color.WHITE)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
        setPadding(dp(10f), dp(3f), dp(10f), dp(3f))
        layoutParams = LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT)
    }

    /** 反馈条的**纯逻辑状态**（陈旧结果判定 / 自动消失计时）。 */
    private val feedbackState = MenuFeedbackState()

    private val feedbackDismiss = Runnable { hideFeedback() }

    private val imageView: ImageView = ImageView(context).apply {
        scaleType = ImageView.ScaleType.FIT_CENTER
        adjustViewBounds = false
        layoutParams = LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT)
        visibility = View.GONE
    }

    private val placeholder: TextView = TextView(context).apply {
        gravity = Gravity.CENTER
        setTextColor(Color.WHITE)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
        text = OverlayVisualPolicy.placeholderText(OverlayVisual.empty)
        setPadding(dp(6f), dp(4f), dp(6f), dp(4f))
        layoutParams = LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT)
    }

    /** 动态素材在 4C-2 只显示第一帧，必须让用户看得见这件事。 */
    private val badge: TextView = TextView(context).apply {
        setTextColor(Color.WHITE)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 8f)
        text = "动态·第一帧"
        visibility = View.GONE
        setPadding(dp(4f), dp(1f), dp(4f), dp(1f))
        background = GradientDrawable().apply {
            cornerRadius = dpF(4f)
            setColor(Color.parseColor("#CC1F2933"))
        }
        layoutParams = LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT).apply {
            gravity = Gravity.BOTTOM or Gravity.START
            bottomMargin = dp(2f)
            leftMargin = dp(2f)
        }
    }

    /** 动画是否暂停（息屏时暂停；真正接动画是 4C-4 的事）。 */
    var animationPaused: Boolean = false
        private set

    /** 当前可见状态（诊断用）。 */
    var visual: OverlayVisual = OverlayVisual.empty
        private set

    /** 是否已经成功挂上一张图。 */
    var hasImage: Boolean = false
        private set

    private var debugMode: Boolean = false
    private var desiredWidthPx: Int = 0
    private var desiredHeightPx: Int = 0

    /** 当前视觉是否是**可播放动画**（动态 WebP 且系统支持完整播放）。 */
    private var animateVisual: Boolean = false

    /**
     * 触摸事件转发（Phase 4C-3A）。
     *
     * 由 [PetOverlayManager] 安装：手势判定（touchSlop / 点击 / 拖动）全部在
     * 状态机里，View 只负责把 [android.view.MotionEvent] 递出去，
     * **不在这里做任何 WindowManager 操作**。
     */
    var touchHandler: ((android.view.MotionEvent) -> Boolean)? = null

    /**
     * 整段触摸手势是否已由本 View 接管（**只在 DOWN 判定一次**）。
     *
     * 缺陷 2-3 修复：旧实现在**每一个**事件上都重跑「是否落在人物层内」的命中判定，
     * 手指一旦快速移出人物层（或移出窗口），onTouchEvent 返回 false，拖动**当场被丢**。
     * 现在只在 DOWN 时判定，接管后整段手势（MOVE/UP/CANCEL）都继续转给手势处理器。
     */
    private var gestureClaimed: Boolean = false

    init {
        // 自身也钉住最小尺寸，双保险（根 View 尺寸由 onMeasure 决定）。
        petContent.addView(imageView)
        petContent.addView(placeholder)
        petContent.addView(badge)
        feedbackHost.addView(feedbackBar)
        // 加入顺序即层级：菜单层（index 0，下方）→ 反馈层（index 1）→ 人物层（index 2，上方）。
        addView(menuHost)
        addView(feedbackHost)
        addView(petContent)
        refreshVisual(loading = false, lastError = null)
    }

    /** 挂上一张**静态**素材（PNG / JPG / 静态 WebP / 低版本的第一帧回退）。 */
    fun showStatic(drawable: Drawable) {
        applyDrawable(drawable, animatable = false)
    }

    /**
     * 挂上一个**动态**素材（动态 WebP）。
     *
     * 播放/停止统一走 [Animatable]（API 1 就有），因此不需要在 24~27 上引用
     * `AnimatedImageDrawable` 这个 API 28 的类。
     */
    fun showAnimated(drawable: Drawable) {
        applyDrawable(drawable, animatable = true)
    }

    /**
     * 解码失败：**清除旧视觉**并显示**可见的**错误占位。
     *
     * 为什么不像 4C-2 那样保留旧图：切换素材失败时留着旧素材，用户会误以为切换成功。
     * 4C-4 按需求建议统一改为"显示明确错误占位"（窗口绝不消失）。
     */
    fun showErrorPlaceholder(message: String?) {
        stopAnimation()
        animateVisual = false
        hasImage = false
        imageView.setImageDrawable(null)
        applyVisual(OverlayVisual.failure)
        placeholder.text = message?.takeIf { it.isNotBlank() }
            ?: OverlayVisualPolicy.placeholderText(OverlayVisual.failure)
        OverlayLog.log("visual.apply.placeholder reason=${message ?: "<none>"}")
    }

    /** 清空视觉（隐藏/停止时用）：停动画 → 摘掉 Drawable → 回到空占位。 */
    fun clearVisual() {
        stopAnimation()
        animateVisual = false
        hasImage = false
        imageView.setImageDrawable(null)
        applyVisual(OverlayVisual.empty)
        OverlayLog.log("visual.clear ${dump()}")
    }

    /** 开始播放（已在下述条件里判过；这里只保证幂等）。 */
    fun startAnimationIfAllowed() {
        if (!animateVisual) return
        val animatable = imageView.drawable as? Animatable ?: run {
            OverlayLog.warn("animation.start 忽略：当前 Drawable 不是 Animatable")
            return
        }
        if (animatable.isRunning) return
        try {
            animatable.start()
        } catch (t: Throwable) {
            OverlayLog.error("animation.error 启动失败", t)
        }
    }

    /** 停止播放（幂等；不会把 Drawable 摘掉 —— 重新显示时可直接恢复）。 */
    fun stopAnimation() {
        val animatable = imageView.drawable as? Animatable ?: return
        if (!animatable.isRunning) return
        try {
            animatable.stop()
        } catch (t: Throwable) {
            OverlayLog.warn("animation.stop 失败（忽略）", t)
        }
    }

    /** 当前动画是否真的在跑（诊断 + 幂等判据）。 */
    val isAnimationRunning: Boolean
        get() = (imageView.drawable as? Animatable)?.isRunning == true

    /** 当前视觉是否是动态素材（与是否在播放无关）。 */
    val isAnimatableVisual: Boolean get() = animateVisual

    /** 当前视觉的宽高比（无图时 1:1；静态与动态走同一条路径）。 */
    val drawableAspectRatio: Float
        get() {
            val drawable = imageView.drawable ?: return 1f
            val w = drawable.intrinsicWidth
            val h = drawable.intrinsicHeight
            return if (w > 0 && h > 0) w.toFloat() / h.toFloat() else 1f
        }

    private fun applyDrawable(drawable: Drawable, animatable: Boolean) {
        // 需求第 12 节：先从 ImageView 移除/替换，再释放旧引用；替换前先停旧动画。
        stopAnimation()
        OverlayLog.log(
            "visual.replace animatable=$animatable " +
                "size=${drawable.intrinsicWidth}x${drawable.intrinsicHeight} " +
                "type=${drawable.javaClass.simpleName}",
        )
        animateVisual = animatable
        hasImage = true
        imageView.setImageDrawable(drawable)
        applyVisual(OverlayVisual.asset)
        OverlayLog.log(
            "visual.apply.${if (animatable) "animated" else "static"} " +
                "running=$isAnimationRunning ${dump()}",
        )
    }

    /** 打开/关闭诊断模式（洋红方块，不依赖素材）。 */
    fun setDebugMode(enabled: Boolean) {
        if (debugMode == enabled) return
        debugMode = enabled
        refreshVisual(loading = false, lastError = null)
    }

    /** 按"有没有图 / 是否在加载 / 最近一次错误 / 诊断模式"刷新可见状态。 */
    fun refreshVisual(loading: Boolean, lastError: String?) {
        applyVisual(
            OverlayVisualPolicy.resolve(
                hasImage = hasImage,
                loading = loading,
                lastError = lastError,
                debugMode = debugMode,
            ),
        )
    }

    private fun applyVisual(next: OverlayVisual) {
        visual = next
        val showChrome = OverlayVisualPolicy.showsPlaceholderChrome(next)
        placeholder.text = OverlayVisualPolicy.placeholderText(next)
        placeholder.visibility = if (showChrome) View.VISIBLE else View.GONE
        when (next) {
            OverlayVisual.asset -> {
                // 真实素材：撤掉占位底，透明通道才不会被挡住。
                petContent.background = null
            }
            OverlayVisual.debug -> {
                // 诊断模式：**不透明**洋红 —— 只要能看见它就说明窗口链路是通的。
                petContent.background = GradientDrawable().apply {
                    setColor(Color.parseColor("#FFFF00FF"))
                }
                placeholder.setTextColor(Color.WHITE)
                placeholder.setBackgroundColor(Color.TRANSPARENT)
            }
            else -> {
                // 可见占位底：半透明填充 + 不透明边框，用户一眼能看出"窗口在这里"。
                petContent.background = GradientDrawable().apply {
                    cornerRadius = dpF(14f)
                    setColor(Color.parseColor("#E6232F3E"))
                    setStroke(dp(2f), Color.parseColor("#FF7FB3D5"))
                }
                placeholder.setTextColor(Color.WHITE)
            }
        }
        imageView.visibility = if (hasImage && next == OverlayVisual.asset) {
            View.VISIBLE
        } else {
            View.GONE
        }
        // 显式归位：绝不让历史/复用状态把整个窗口带成不可见。
        // 4C-3B：可见性/透明度归位作用在**桌宠内容层**上 —— 根 View 从此是
        // "菜单画布"，它必须始终可见（否则整扇菜单会被一起隐藏）；
        // 而桌宠本身的可见性仍然由这里显式钉死（4C-2 的教训不变）。
        petContent.alpha = 1f
        petContent.scaleX = 1f
        petContent.scaleY = 1f
        petContent.visibility = View.VISIBLE
        alpha = 1f
        scaleX = 1f
        scaleY = 1f
        visibility = View.VISIBLE
        requestLayout()
        invalidate()
    }

    // -----------------------------------------------------------------------
    // 窗口几何（Phase 4C-3A / 4C-3B）
    // -----------------------------------------------------------------------

    /**
     * 只准备窗口尺寸参数，**不触发可见的半完成状态**。
     *
     * 为什么不让调用方分别调"设尺寸 + requestLayout + updateViewLayout"：
     * 那会让根 View 期望尺寸与 WindowManager 窗口矩形分两次生效，
     * Android 可能在两次之间绘制一帧。这里把参数**一次改完**，
     * 由调用方随后用**唯一一次** `updateViewLayout` 触发遍历。
     *
     * 注意：刻意**不调用** `setLayoutParams`（它内部会 requestLayout），
     * 而是原地修改已有的 LayoutParams 对象 —— 准备阶段一次遍历都不触发。
     *
     * Phase 4C-6B-2：等价于"窗口 = 人物、人物偏移 = (0,0)"的场景几何。
     */
    fun prepareWindowGeometry(size: OverlaySize) {
        prepareSceneGeometry(size, OverlayRect(0, 0, size.width, size.height))
    }

    /**
     * 准备**场景**几何（Phase 4C-6B-2）：根容器尺寸 = 整个场景窗口，
     * 人物层放在容器内的 [petRectInWindow]（尺寸仍 = 人物尺寸）。
     *
     * 与 [prepareWindowGeometry] 一样：只写参数、不触发遍历，由调用方用**唯一一次**
     * `updateViewLayout` 提交 —— 因此菜单开关不会产生中间帧（不闪、不抽动）。
     */
    fun prepareSceneGeometry(windowSize: OverlaySize, petRectInWindow: OverlayRect) {
        val safeWidth = OverlayGeometry.safeViewSize(windowSize.width)
        val safeHeight = OverlayGeometry.safeViewSize(windowSize.height)
        minimumWidth = safeWidth
        minimumHeight = safeHeight
        desiredWidthPx = safeWidth
        desiredHeightPx = safeHeight

        val lp = petContent.layoutParams as LayoutParams
        lp.width = OverlayGeometry.safeViewSize(petRectInWindow.width)
        lp.height = OverlayGeometry.safeViewSize(petRectInWindow.height)
        lp.leftMargin = petRectInWindow.left
        lp.topMargin = petRectInWindow.top
    }

    // -----------------------------------------------------------------------
    // 菜单层（Phase 4C-6B-2：单窗口分层）
    // -----------------------------------------------------------------------

    /**
     * 把菜单层挂进**同一个窗口**（index 0，位于人物层**之下**）。
     *
     * 幂等：先清掉可能残留的旧菜单层（最多一层）。菜单子 View 用显式
     * `FrameLayout.LayoutParams`（宽高 = 菜单矩形、左边距/上边距 = 容器内偏移），
     * 因此它的画布原点就是菜单窗口原点，轮盘内部坐标无需任何换算。
     */
    fun attachMenuLayer(layer: View, rectInWindow: OverlayRect) {
        menuHost.removeAllViews()
        val lp = LayoutParams(rectInWindow.width, rectInWindow.height).apply {
            leftMargin = rectInWindow.left
            topMargin = rectInWindow.top
            gravity = Gravity.TOP or Gravity.START
        }
        menuHost.addView(layer, lp)
        menuHost.visibility = View.VISIBLE
        requestLayout()
        invalidate()
    }

    /** 移除菜单层（幂等）。人物层不受影响 —— 同一个 View 实例、同一个父容器。 */
    fun detachMenuLayer() {
        if (menuHost.childCount == 0 && menuHost.visibility == View.GONE) return
        menuHost.removeAllViews()
        menuHost.visibility = View.GONE
        requestLayout()
        invalidate()
    }

    /** 菜单层是否已挂载（诊断用）。 */
    val isMenuLayerAttached: Boolean get() = menuHost.childCount > 0

    // -----------------------------------------------------------------------
    // 反馈层（Phase 4C-6B-3：单窗口内的轻量反馈，不新开窗口、不改几何）
    // -----------------------------------------------------------------------

    /**
     * 在**同一个窗口内**显示一条反馈。
     *
     * 三条约束（需求 §17）：
     * 1. 只动本 View 的子 View 属性 —— **绝不** 调用 `updateViewLayout` / 几何提交，
     *    窗口矩形一个像素都不变（[MenuFeedbackPolicy.rectInWindow] 只接收窗口尺寸、只返回内部矩形）；
     * 2. 位置固定在窗口底部中央（轮盘下方），不覆盖人物头部与按钮环带；
     * 3. 陈旧结果被丢弃（见 [MenuFeedbackState.show]）：旧 requestId 的异步结果
     *    不会覆盖更新的反馈。
     *
     * @param requestId 关联的请求 id（本地即时反馈传 null）
     * @return true = 本条已被显示
     */
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
        OverlayLog.log("menu.feedback show kind=${kind.wire} requestId=${requestId ?: "<local>"} text=$text")
        return true
    }

    /** 立即收起反馈条（幂等）。 */
    fun hideFeedback() {
        feedbackBar.removeCallbacks(feedbackDismiss)
        if (feedbackHost.visibility != View.GONE) {
            feedbackHost.visibility = View.GONE
            invalidate()
        }
        feedbackState.hide()
    }

    /** 当前反馈文案（诊断 / 单测口径）。 */
    val feedbackText: String? get() = feedbackState.text

    /**
     * 把反馈条放到窗口**内部**的底部（容器坐标），随窗口尺寸变化重新计算。
     *
     * 只写子 View 的 margin/尺寸，**不触碰** 窗口 LayoutParams —— 这是"反馈不影响几何"的结构性保证。
     */
    private fun placeFeedback() {
        val width = desiredWidthPx
        val height = desiredHeightPx
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
        FeedbackKind.running -> Color.parseColor("#E61F2933")
        FeedbackKind.success -> Color.parseColor("#E6205B34")
        FeedbackKind.warning -> Color.parseColor("#E6A06300")
        FeedbackKind.error -> Color.parseColor("#E69B1C1C")
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        if (feedbackHost.visibility == View.VISIBLE) placeFeedback()
    }

    override fun onDetachedFromWindow() {
        // 窗口被摘掉时必须停掉计时回调，避免"已 detached 的 View 仍在跑 Runnable"。
        feedbackBar.removeCallbacks(feedbackDismiss)
        super.onDetachedFromWindow()
    }

    /** 菜单层当前矩形（容器内坐标；诊断用）。 */
    val menuLayerRect: OverlayRect?
        get() {
            val child = menuHost.getChildAt(0) ?: return null
            val lp = child.layoutParams as? LayoutParams ?: return null
            return OverlayRect(
                left = lp.leftMargin,
                top = lp.topMargin,
                right = lp.leftMargin + lp.width,
                bottom = lp.topMargin + lp.height,
            )
        }

    /**
     * 幂等地保证桌宠内容**始终可见**（Phase 4C-6B-1.2 A3）。
     *
     * 隐藏机制已**彻底删除**：本类不再提供任何能把 `imageAlpha` 置 0 的入口，
     * 也不存在"菜单窗口接管人物"的开关。这里只兜住"万一被外部改成非 255"的情况。
     *
     * @return true 表示本次**真的做了纠正**（此前不是 255）；正常路径恒返回 false。
     */
    fun ensureSourceVisible(): Boolean {
        if (imageView.imageAlpha == 255) return false
        imageView.imageAlpha = 255
        return true
    }

    /** 下一帧诊断：桌宠内容层在**屏幕**上的绝对位置。 */
    fun petContentLocationOnScreen(): IntArray {
        val location = IntArray(2)
        petContent.getLocationOnScreen(location)
        return location
    }

    /** 下一帧诊断：桌宠内容层的真实尺寸。 */
    fun petContentSize(): IntArray = intArrayOf(petContent.width, petContent.height)

    /** 下一帧诊断：人物层在**根容器内**的矩形（`menu.trace` 逐帧核对用）。 */
    fun petLayerBoundsInWindow(): OverlayRect =
        OverlayRect(petContent.left, petContent.top, petContent.right, petContent.bottom)

    /**
     * 下一帧诊断：一行式报告人物层的容器内矩形 + 平移/缩放 + 屏幕位置。
     *
     * 用于 `menu.trace`：配合窗口 LP 与根 View 的 translation，逐帧核对
     * "开/关菜单期间人物**绘制**位置有没有动"。
     */
    fun petLayerTraceSegment(): String {
        val bounds = petLayerBoundsInWindow()
        val location = petContentLocationOnScreen()
        return "petContent=(l=${bounds.left} t=${bounds.top} ${bounds.width}x${bounds.height})" +
            " petTrans=(${petContent.translationX},${petContent.translationY})" +
            " petScale=(${petContent.scaleX},${petContent.scaleY})" +
            " rootTrans=(${translationX},${translationY})" +
            " rootScale=(${scaleX},${scaleY})" +
            " petScreen=(${location[0]},${location[1]})"
    }

    fun setPlaceholderText(text: String) {
        placeholder.text = text
    }

    /** true = 显示"动态素材当前只有第一帧"角标。 */
    fun setAnimatedBadgeVisible(visible: Boolean) {
        badge.visibility = if (visible) View.VISIBLE else View.GONE
    }

    fun setAnimationPaused(paused: Boolean) {
        animationPaused = paused
    }

    fun imageViewSize(): IntArray = intArrayOf(imageView.width, imageView.height)

    /** 一行式诊断（日志与 `getState` 共用），**不省略任何关键字段**。 */
    fun dump(): String = buildString {
        append("visual=").append(visual)
        append(" size=").append(width).append('x').append(height)
        append(" measured=").append(measuredWidth).append('x').append(measuredHeight)
        append(" min=").append(minimumWidth).append('x').append(minimumHeight)
        append(" desired=").append(desiredWidthPx).append('x').append(desiredHeightPx)
        append(" visibility=").append(visibility)
        append(" alpha=").append(alpha)
        append(" scale=").append(scaleX).append('x').append(scaleY)
        append(" attached=").append(isAttachedToWindow)
        append(" shader=").append(if (petContent.background == null) "none" else "set")
        append(" image=").append(imageView.width).append('x').append(imageView.height)
        append(" imageVisibility=").append(imageView.visibility)
        append(" hasImage=").append(hasImage)
        append(" debug=").append(debugMode)
        append(" petContent=").append(petContent.width).append('x').append(petContent.height)
        append(" menuLayer=").append(menuLayerRect ?: "none")
        append(" feedback=").append(feedbackState.text ?: "none")
        append(" feedbackVisible=").append(feedbackHost.visibility == View.VISIBLE)
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val w = desiredWidthPx.coerceAtLeast(1)
        val h = desiredHeightPx.coerceAtLeast(1)
        // 关键：必须先按"确定尺寸"调用 super，让 FrameLayout 正常测量子 View。
        // 只调 setMeasuredDimension 会让 ImageView / TextView 的 measuredWidth
        // 恒为 0，onLayout 把它们摆成 0×0 —— 窗口在，但什么都看不见。
        super.onMeasure(
            MeasureSpec.makeMeasureSpec(w, MeasureSpec.EXACTLY),
            MeasureSpec.makeMeasureSpec(h, MeasureSpec.EXACTLY),
        )
        setMeasuredDimension(w, h)
    }

    /**
     * 把触摸事件交给手势状态机（Phase 4C-3A）。
     *
     * 规则：**只在 DOWN 判定一次命中**（缺陷 2-3 修复）—— 落在人物层内（或菜单层已挂载）才接管
     * 整段手势；接管后 MOVE/UP/CANCEL **不再重跑**命中判定，否则手指快速移出人物层/窗口时
     * onTouchEvent 会返回 false，正在进行的拖动被当场丢掉（"脱手"的成因之一）。
     *
     * 注意（**不要再写错平台行为**）：这里返回 `false` 只表示"本 View 不吃这一串事件"，
     * **不会**把事件重新派发给下层的其他应用窗口；`FLAG_NOT_TOUCH_MODAL` 只让事件**落在窗口
     * 之外**时才交给下层。因此"人物之外的区域能否穿透"**不能**靠 return false 来实现 ——
     * 那要靠**窗口本身收缩回人物矩形**（见 [OverlaySceneSolver] 与 `PetOverlayManager.closeMenuScene`）。
     */
    override fun onTouchEvent(event: android.view.MotionEvent): Boolean {
        val handler = touchHandler ?: return super.onTouchEvent(event)
        when (event.actionMasked) {
            android.view.MotionEvent.ACTION_DOWN -> {
                gestureClaimed = petLayerContains(event.x, event.y) || isMenuLayerAttached
                return if (gestureClaimed) handler.invoke(event) else super.onTouchEvent(event)
            }
            android.view.MotionEvent.ACTION_UP,
            android.view.MotionEvent.ACTION_CANCEL,
            -> {
                val claimed = gestureClaimed
                gestureClaimed = false
                return if (claimed) handler.invoke(event) else super.onTouchEvent(event)
            }
            else ->
                return if (gestureClaimed) handler.invoke(event) else super.onTouchEvent(event)
        }
    }

    // -----------------------------------------------------------------------
    // 关于"菜单关闭后不遮挡下层应用"
    // -----------------------------------------------------------------------
    //
    // 【为什么删掉了"反射声明可触摸区域"】声明窗口可触摸区域必须用到
    // ViewTreeObserver.OnComputeInternalInsetsListener / InternalInsetsInfo，
    // 它们在 AOSP 里是 @hide 成员，**本项目的 android.jar（compileSdk 35/36/37）里根本不存在**，
    // 只能靠反射灰名单 API 访问 —— 而项目规则是"不用隐藏 API、不用反射、
    // 不用无障碍/注入作为通用方案"，所以这套实现**不能上线**，已整体删除。
    //
    // 【因此窗口必须按状态收缩】
    // 平台没有公开 API 能声明"窗口内只有某一块子区域可触摸"，而且**大窗口内的透明 padding
    // 仍会消费触摸**：本类 [onTouchEvent] 返回 false **不会**把事件重新派发给下层应用
    // （`FLAG_NOT_TOUCH_MODAL` 只放开窗口**之外**的触摸）。所以唯一可行的做法是：
    // * 菜单关闭 → 窗口收缩为**人物矩形**（零 padding，见 `OverlaySceneSolver.petOnly/closed`）；
    // * 菜单打开 → 窗口扩展为 人物 ∪ 菜单信封（见 `OverlaySceneSolver.open`）。
    // 关菜单缩窗由 `PetOverlayManager.closeMenuScene` 在唯一提交点完成。

    /** 点（根容器坐标）是否落在人物层范围内。 */
    private fun petLayerContains(x: Float, y: Float): Boolean =
        x >= petContent.left && x < petContent.right &&
            y >= petContent.top && y < petContent.bottom

    private val density: Float
        get() = resources.displayMetrics.density

    /** dp → 整数像素（padding / margin / 描边宽度）。 */
    private fun dp(value: Float): Int = (value * density).roundToInt()

    /** dp → 浮点像素（`cornerRadius` 需要 Float）。 */
    private fun dpF(value: Float): Float = value * density
}

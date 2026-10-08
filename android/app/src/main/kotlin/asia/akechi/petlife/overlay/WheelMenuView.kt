package asia.akechi.petlife.overlay

import android.content.Context
import android.graphics.Canvas
import android.os.SystemClock
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.View
import java.util.Locale

/** 每帧耗时统计（需求 §15 的调试指标）。 */
internal data class WheelFrameStats(
    var frames: Long = 0L,
    var totalMs: Double = 0.0,
    var maxMs: Double = 0.0,
    var dropped: Long = 0L,
) {
    val averageMs: Double get() = if (frames == 0L) 0.0 else totalMs / frames

    fun reset() {
        frames = 0
        totalMs = 0.0
        maxMs = 0.0
        dropped = 0
    }
}

/**
 * 轮盘菜单窗口的根 View（Phase 4C-6B-1）。
 *
 * 它同时承担三件事，且**只有这三件**：
 * 1. 持有交互状态机 [WheelMenuStateMachine]（层级 / 选中 / 阶段 / 方向）；
 * 2. 用 [WheelMenuGestureController] 解释触摸（点击 / 圆弧滑选 / 取消 / 空白关闭）；
 * 3. 用 [WheelMenuRenderer] 逐帧重绘（**窗口尺寸在整个打开期间不变**）。
 *
 * 与人物层的关系（Phase 4C-6B-2：**单窗口分层**）：
 * 本 View 现在是 `PetOverlayView` 根容器里的**菜单层**（index 0，在下方），
 * 人物层（`petContent`）在同容器 index 1（在上方）。因此：
 * * 人物永远画在菜单之上，菜单背景从人物背后穿过，人物透明处自然透出菜单；
 * * 打开/关闭菜单只改根窗口的矩形与两层偏移（**一次** `updateViewLayout`），
 *   人物 View 实例与其父容器在整个窗口生命周期内**不变** —— "人物不抽动"是结构性保证。
 *
 * 手势互斥（需求 §12）：按在人物区域上的触摸虽由本 View 先收到，
 * 但 GestureController 把它判为 `center`（人物区域）并交给 `petDragListener` 转发或
 * 由上层人物 View 处理；轮盘自身只在环带 / 空白区响应。
 */
internal class WheelMenuView(context: Context) : View(context) {

    /** 某个条目被确认（点击或滑选松手）—— 由 manager 决定"进入子菜单 / 执行 / 只高亮"。 */
    var entryListener: ((WheelMenuEntry, Int) -> Unit)? = null

    /** 空白处松手 → 关闭整个菜单（需求 §5）。 */
    var closeListener: (() -> Unit)? = null

    /**
     * 中央桌宠区域的拖动转发（需求 §3）。
     *
     * 参数是**菜单窗口内**的原始坐标；菜单窗口现在在上层，
     * 因此"按在人物身上拖动"必须由这里转发给 manager 去移动桌宠窗口，
     * 而不是依赖窗口触摸穿透。
     */
    var petDragListener: ((x: Float, y: Float, phase: WheelPetDragPhase) -> Unit)? = null

    /** 一次动画播完（manager 据此同步窗口级状态机与诊断）。 */
    var animationListener: ((WheelAnimationKind) -> Unit)? = null

    /** 选中项实时信息（只读快照；由 manager 在选中变化时提供，**不在 onDraw 里算**）。 */
    var infoProvider: ((WheelMenuEntry) -> String?)? = null

    /** 触觉反馈开关（需求 §16 持久化，缺省开启）。 */
    var hapticsEnabled: Boolean = true

    /** 诊断模式：画出窗口与环带边界。 */
    var debugBounds: Boolean = false

    /**
     * 架构验证（Phase 4C-6B-2）：是否画出"粉色大扇区"。
     *
     * 由 manager 在本阶段默认开启；用来在真机上肉眼确认
     * "人物层盖在菜单层之上"（粉色扇区应从人物背后穿过）。
     */
    var debugVerifyFan: Boolean = false

    val state = WheelMenuStateMachine()

    private val renderer = WheelMenuRenderer()
    private val gesture = WheelMenuGestureController.fromDensity(resources.displayMetrics.density)

    private var theme: WheelMenuTheme = WheelMenuThemes.default()
    private var envelope: WheelMenuEnvelope? = null
    private var layout: WheelMenuLayout? = null
    /** 打开时的尺寸参数快照：换层时用它复算几何（**窗口不变**）。 */
    private var spec: WheelMenuSpec? = null
    private var run: WheelAnimationRun? = null
    private var pressRun: WheelAnimationRun? = null

    private var frame = hiddenFrame()
    private var liveSelection: Float? = null
    private var infoText: String? = null
    private var infoKey: String? = null

    private var tickerRunning = false
    private var lastTickUptime = 0L

    /** 拖动桌宠期间抑制绘制（View 仍 VISIBLE，触摸流不断）。 */
    private var suppressed = false

    /**
     * 是否允许菜单交互（缺陷 1 的**唯一门控**）。
     *
     * 由 manager 按会话号统一下发：关闭请求被接受的那一刻置 false。false 时本 View
     * 只吞事件防穿透，绝不产生任何菜单动作（但会继续收敛已经在转发的桌宠拖动，见 [petDragForwarding]）。
     */
    private var interactive: Boolean = false

    /**
     * 是否正在把"中央桌宠拖动"转发给 manager（缺陷 1）。
     *
     * 它的存在是为了保证转发拖动**恰好补一次结束**：不管手势是正常抬手、被 CANCEL、
     * 多指介入，还是菜单被外力关闭，都必须在同一处调用一次 [endPetDragForwarding]，
     * 否则 manager 的"延迟摘层"闸门会永远挂起（= 菜单看不见却继续吞触摸）。
     */
    private var petDragForwarding: Boolean = false

    /** 最近一次触摸的原始坐标（转发拖动要用）。 */
    private var lastTouchRawX = 0f
    private var lastTouchRawY = 0f
    private val frameStats = WheelFrameStats()

    private val ticker = object : Runnable {
        override fun run() {
            if (!tickerRunning) return
            tick()
            if (tickerRunning) postOnAnimation(this)
        }
    }

    // ------------------------------------------------------------------
    // 对外只读诊断
    // ------------------------------------------------------------------

    val phaseName: String get() = state.phase.name

    val levelIdName: String get() = state.levelId ?: "none"

    val activeIndexNow: Int get() = state.activeIndex

    val directionName: String get() = state.direction.name

    val gestureOwnerName: String get() = gesture.ownerName

    val animationName: String get() = run?.kind?.name ?: "idle"

    val windowRectNow: OverlayRect? get() = envelope?.windowRect

    val isAnimating: Boolean get() = run != null

    /** 当前是否允许菜单交互（诊断；权威值在 manager 的会话里）。 */
    val interactiveNow: Boolean get() = interactive

    /** 展开动画进度（0 = 完全收起，1 = 完全展开；打开序列诊断用）。 */
    val openProgressNow: Float get() = frame.openProgress

    /**
     * 动画枢轴（**菜单窗口局部坐标**；诊断用）。
     *
     * 渲染层的 canvas 缩放 / 旋转围绕 `layout.centerX/centerY` 进行 —— 这两个值已经是
     * 窗口内相对坐标。把它们同时写进 View 的 `pivotX/pivotY`，是为了让"整段动画只有一个
     * 坐标系"这条不变式成为可读、可断言的属性（绝不是屏幕原始坐标）。
     */
    var animationPivotX: Float = 0f
        private set

    var animationPivotY: Float = 0f
        private set

    /** 当前是否正在转发桌宠拖动（诊断；用于证明延迟摘层闸门是否会卡住）。 */
    val petDragForwardingNow: Boolean get() = petDragForwarding

    fun frameStatsSnapshot(): WheelFrameStats = frameStats

    fun currentLayout(): WheelMenuLayout? = layout

    fun currentTheme(): WheelMenuTheme = theme

    fun levelTitleZh(): String = state.currentLevel?.titleZh ?: ""

    // ------------------------------------------------------------------
    // 生命周期 / 配置
    // ------------------------------------------------------------------

    override fun onDetachedFromWindow() {
        // 需求 §15：菜单收起或窗口移除后**必须**停止动画时钟，不留 Timer/Animator。
        stopTicker()
        super.onDetachedFromWindow()
    }

    /**
     * 打开序列**准备内容**（从原 `present()` 拆出，无任何动画、不可交互）：
     * 信封（窗口 + 中心 + 环带半径）在此**一次性**确定，之后不再变化。
     *
     * 它只做两件事：配置本次打开的层级 / 几何 / 主题，并把帧置为"完全收起"。
     * **绝不起动画、绝不置交互打开** —— 真正的第一帧动画必须等布局闸门达标后由
     * [beginOpenAnimation] 触发（这正是"菜单第一帧错位"缺陷的修复点）。
     *
     * 之所以要在"准备布局"阶段就调用它：本 View 只有在**已配置 layout** 时才会在
     * `onMeasure`/`onLayout` 里被量到父容器的目标尺寸；而闸门判据正是
     * "本 View 的 `measuredWidth/Height` == 目标矩形"。
     */
    fun prepareContent(
        envelope: WheelMenuEnvelope,
        level: WheelMenuLevel,
        layout: WheelMenuLayout,
        theme: WheelMenuTheme,
        direction: WheelExpandDirection,
        spec: WheelMenuSpec,
    ) {
        this.envelope = envelope
        this.theme = theme
        this.layout = layout
        this.spec = spec
        state.open(direction)
        bindLayout(layout)
        liveSelection = null
        pressRun = null
        suppressed = false
        petDragForwarding = false
        frame = hiddenFrame().copy(
            mirrorProgress = mirrorOf(direction),
            buttonProgress = List(layout.itemCount) { 0f },
        )
        refreshInfo(force = true)
        contentDescription = "轮盘菜单：${level.titleZh}"
        frameStats.reset()
        invalidate()
    }

    /**
     * 设置动画枢轴：入参必须是**菜单窗口局部坐标**（[WheelMenuLayout.centerX]/[centerY]），
     * 绝不是屏幕原始坐标。渲染层的 canvas 变换围绕它进行 ⇒ 整段动画只有一个坐标系。
     */
    fun setAnimationPivot(x: Float, y: Float) {
        animationPivotX = x
        animationPivotY = y
        pivotX = x
        pivotY = y
    }

    /**
     * 布局超时**降级**：立即以"完全展开"帧呈现（显示在最终位置，**不播**展开动画）。
     *
     * 与 [prepareContent] 的唯一区别：这里直接把帧置为完全展开、不启动动画时钟 ——
     * 因此菜单不会从任何错误坐标"掉落"，只是出现在最终位置且完全可用（STEP 5）。
     */
    fun presentOpened(
        envelope: WheelMenuEnvelope,
        level: WheelMenuLevel,
        layout: WheelMenuLayout,
        theme: WheelMenuTheme,
        direction: WheelExpandDirection,
        spec: WheelMenuSpec,
    ) {
        prepareContent(envelope, level, layout, theme, direction, spec)
        stopTicker()
        run = null
        pressRun = null
        frame = hiddenFrame().copy(
            openProgress = 1f,
            selectionPosition = frame.selectionPosition,
            mirrorProgress = mirrorOf(direction),
            buttonProgress = List(layout.itemCount) { 1f },
        )
        state.markOpened()
        bindLayout(layout)
        invalidate()
    }

    /** 主题即时预览（需求 §13.3：修改后立即生效，不重开菜单）。 */
    fun applyTheme(theme: WheelMenuTheme) {
        this.theme = theme
        invalidate()
    }

    fun updateInfoProvider(provider: ((WheelMenuEntry) -> String?)?) {
        infoProvider = provider
        refreshInfo(force = true)
        invalidate()
    }

    // ------------------------------------------------------------------
    // 动画驱动
    // ------------------------------------------------------------------

    /**
     * 打开序列**布局达标后**的唯一动画入口：起一次展开动画（**恰好一次**）。
     *
     * 只允许在 [MenuOpenSequencer] 判定"本 View 已量到目标尺寸"之后调用 ——
     * 早于这一帧起动画正是"菜单第一帧用错坐标"的根因。
     */
    fun beginOpenAnimation() {
        val current = layout ?: return
        startRun(WheelAnimationKind.open, from = 0f, to = 0f, count = current.itemCount)
    }

    fun startCloseAnimation() {
        val current = layout ?: return
        state.beginClosing()
        startRun(
            WheelAnimationKind.close,
            from = frame.selectionPosition,
            to = frame.selectionPosition,
            count = current.itemCount,
        )
    }

    /**
     * 进入子菜单：层级**立即**切换，动画只做过渡。
     *
     * **窗口不动**：新层级只是在既有信封里重新算一遍内部几何（需求 §14）。
     */
    fun enterLayer(level: WheelMenuLevel): Boolean {
        // 先算几何再动栈：算不出来就**完全不改变状态**（绝不会留下"栈进了、画不出来"）。
        val next = computeLayout(level) ?: return false
        if (!state.enterLayer(level.id)) return false
        layout = next
        bindLayout(next)
        clearPress()
        refreshInfo(force = true)
        startRun(WheelAnimationKind.enterLayer, from = 0f, to = 0f, count = next.itemCount)
        return true
    }

    /** 返回上一层：同样只做过渡动画，窗口不动。 */
    fun exitLayer(): Boolean {
        val path = state.path()
        if (path.size < 2) return false
        val target = WheelMenuCatalog.level(path[path.size - 2]) ?: return false
        val next = computeLayout(target) ?: return false
        if (!state.exitLayer()) return false
        layout = next
        bindLayout(next)
        clearPress()
        refreshInfo(force = true)
        startRun(WheelAnimationKind.exitLayer, from = 0f, to = 0f, count = next.itemCount)
        return true
    }

    private fun computeLayout(level: WheelMenuLevel): WheelMenuLayout? {
        val env = envelope ?: return null
        val sizes = spec ?: return null
        return WheelMenuGeometry.layoutFor(env, level, sizes)
    }

    /**
     * 根选项切换（沿弧线滑动，需求 §10.2）。
     *
     * 用于"点了条目但不导航"的情况（业务占位项）：高亮、扇区与标题都要**连续平移**过去。
     */
    fun animateSelectionTo(index: Int) {
        val current = layout ?: return
        if (index !in 0 until current.itemCount) return
        val from = liveSelection ?: frame.selectionPosition
        liveSelection = null
        state.setPreview(null)
        state.beginSwitch(index)
        startRun(
            WheelAnimationKind.selectionSwitch,
            from = from,
            to = index.toFloat(),
            count = current.itemCount,
        )
        state.finishSwitch(index)
        refreshInfo(force = true)
    }

    /**
     * 门控菜单交互（缺陷 1）。由 manager 按会话号统一下发，是本 View "允不允许交互"的**唯一**来源。
     *
     * 置 false 时（关闭请求被接受的同一帧）立即：停菜单动画时钟、清按压 / 高亮 / 待确认。
     * **刻意不动**正在转发的桌宠拖动（[petDragForwarding]）—— 它的终止事件还要用来释放
     * manager 的延迟摘层闸门；这里只清掉菜单自身的交互意图。
     */
    fun setInteractive(value: Boolean, reason: String) {
        if (interactive == value) return
        interactive = value
        if (value) {
            OverlayLog.log("wheel.interactive=true reason=$reason")
            return
        }
        clearPress()
        run = null
        pressRun = null
        stopTicker()
        state.setPreview(null)
        liveSelection = null
        if (!petDragForwarding) gesture.reset()
        invalidate()
        OverlayLog.log("wheel.interactive=false reason=$reason forwarding=$petDragForwarding")
    }

    /**
     * 拖动桌宠期间**不显示轮盘**（需求 §13）。
     *
     * View 仍保持 `VISIBLE` —— 这是关键：一旦不可见/被摘掉，这一轮触摸事件就断了，
     * 转发也就没法继续。因此这里只停止时钟与绘制。
     *
     * ⚠️ **绝不能调用 [freeze]**：freeze 会 `gesture.reset()`，把"正在转发"的所有权
     * （`Owner.petDrag`）清掉，后续 MOVE/UP 再也发不出 petDragMove/petDragEnd ——
     * 这正是真机缺陷 1 的根因之一（延迟摘层闸门永不释放，菜单看不见却继续吞触摸）。
     */
    fun hideForPetDrag() {
        run = null
        pressRun = null
        stopTicker()
        liveSelection = null
        suppressed = true
        invalidate()
    }

    /** 立即停止一切动画并把当前帧定格（隐藏 / 停止 / 几何变化等外力打断）。 */
    fun freeze() {
        run?.let { active ->
            frame = WheelAnimationClock.frame(active, SystemClock.uptimeMillis())
        }
        run = null
        pressRun = null
        stopTicker()
        gesture.reset()
        liveSelection = null
        state.settleAfterInterruption()
    }

    private fun startRun(kind: WheelAnimationKind, from: Float, to: Float, count: Int) {
        val mirror = mirrorOf(state.direction)
        // 新动画**接管**旧动画：先按旧动画当前帧收敛，避免位置误差累积（需求 §18.4）。
        run?.let { previous ->
            frame = WheelAnimationClock.frame(previous, SystemClock.uptimeMillis()).copy(
                mirrorProgress = mirror,
            )
        }
        run = WheelAnimationRun(
            kind = kind,
            startedAtMs = SystemClock.uptimeMillis(),
            fromSelection = from,
            toSelection = to,
            itemCount = count,
            mirrorProgress = mirror,
        )
        startTicker()
        invalidate()
    }

    private fun startTicker() {
        if (tickerRunning) return
        tickerRunning = true
        lastTickUptime = SystemClock.uptimeMillis()
        postOnAnimation(ticker)
    }

    private fun stopTicker() {
        if (!tickerRunning) return
        tickerRunning = false
        removeCallbacks(ticker)
    }

    private fun tick() {
        val now = SystemClock.uptimeMillis()
        recordFrame((now - lastTickUptime).coerceAtLeast(0L))
        lastTickUptime = now

        var next = run?.let { if (WheelAnimationClock.isFinished(it, now)) frame else WheelAnimationClock.frame(it, now) }
            ?: frame
        pressRun?.let { press ->
            val pressFrame = WheelAnimationClock.frame(press, now)
            next = next.copy(pressIndex = press.pressIndex, pressProgress = pressFrame.pressProgress)
            if (WheelAnimationClock.isFinished(press, now)) pressRun = null
        }
        liveSelection?.let { next = next.copy(selectionPosition = it) }
        frame = next

        run?.let { active ->
            if (WheelAnimationClock.isFinished(active, now)) {
                run = null
                finishRun(active)
            }
        }
        if (run == null && pressRun == null) stopTicker()
        invalidate()
    }

    private fun finishRun(active: WheelAnimationRun) {
        when (active.kind) {
            WheelAnimationKind.open -> state.markOpened()
            WheelAnimationKind.close -> state.markClosed()
            WheelAnimationKind.selectionSwitch -> state.finishSwitch(active.toSelection.toInt())
            WheelAnimationKind.enterLayer,
            WheelAnimationKind.exitLayer,
            -> state.finishLayerTransition()
            WheelAnimationKind.press -> Unit
        }
        animationListener?.invoke(active.kind)
    }

    private fun recordFrame(elapsedMs: Long) {
        if (elapsedMs <= 0L) return
        frameStats.frames += 1
        frameStats.totalMs += elapsedMs
        frameStats.maxMs = maxOf(frameStats.maxMs, elapsedMs.toDouble())
        // 超过两个 60Hz 帧视为掉帧（需求 §15 的调试指标之一）。
        if (elapsedMs > 33L) frameStats.dropped += 1
    }

    // ------------------------------------------------------------------
    // 触摸
    // ------------------------------------------------------------------

    override fun onTouchEvent(event: MotionEvent): Boolean {
        val current = layout ?: return false
        // 0) **正在转发桌宠拖动**：先无条件收敛终止事件（缺陷 1）。
        //    这一步必须排在最前，且不依赖 interactive / phase —— 因为菜单可能已被外力关闭
        //    （此时 interactive=false），但 manager 的"延迟摘层"闸门仍挂着，正是靠这里释放。
        if (petDragForwarding) {
            lastTouchRawX = event.rawX
            lastTouchRawY = event.rawY
            when (event.actionMasked) {
                MotionEvent.ACTION_MOVE ->
                    if (interactive) {
                        petDragListener?.invoke(lastTouchRawX, lastTouchRawY, WheelPetDragPhase.move)
                    }
                MotionEvent.ACTION_UP,
                MotionEvent.ACTION_CANCEL,
                MotionEvent.ACTION_POINTER_DOWN,
                MotionEvent.ACTION_POINTER_UP,
                -> endPetDragForwarding("touch-${event.actionMasked}")
                else -> Unit
            }
            return true
        }
        // 1) 菜单不可交互（关闭请求已被接受）：只吞掉事件防穿透，绝不产生任何菜单动作。
        if (!interactive) {
            gesture.reset()
            return true
        }
        // 2) 展开 / 收起动画期间不接受输入：避免"还没张开就被点掉"（需求 §18.2 快速重复开关）。
        if (state.phase == WheelMenuPhase.opening || state.phase == WheelMenuPhase.closing) {
            return true
        }
        val time = event.eventTime
        // 转发给桌宠窗口的坐标必须是**屏幕坐标**：菜单窗口/桌宠窗口会在拖动过程中一起移动，
        // 用 View 局部的 event.x/y 会在窗口移动后失去基准（真机"脱手"的直接原因）。
        lastTouchRawX = event.rawX
        lastTouchRawY = event.rawY
        val outcome = when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> gesture.onDown(event.x, event.y, time, event.pointerCount)
            MotionEvent.ACTION_MOVE -> gesture.onMove(event.x, event.y, time, event.pointerCount)
            MotionEvent.ACTION_POINTER_DOWN -> gesture.onDown(event.x, event.y, time, 2)
            MotionEvent.ACTION_POINTER_UP -> gesture.onUp(event.x, event.y, time, 2)
            MotionEvent.ACTION_UP -> gesture.onUp(event.x, event.y, time, event.pointerCount)
            MotionEvent.ACTION_CANCEL -> gesture.onCancel()
            else -> WheelGestureOutcome(WheelGestureEffect.none)
        }
        handleOutcome(current, outcome)
        return true
    }

    /**
     * 结束"转发桌宠拖动"，**恰好一次**通知 manager（缺陷 1）。
     *
     * 所有终止路径（抬手 / CANCEL / 多指 / 外力关闭后的终止事件）都汇聚到这里，
     * 保证 manager 的 `detachDeferral.endForwardedDrag()` + 摘层缩窗一定被触发一次。
     */
    private fun endPetDragForwarding(reason: String) {
        if (!petDragForwarding) return
        petDragForwarding = false
        gesture.reset()
        OverlayLog.log("wheel.pet_drag.forward.end reason=$reason")
        petDragListener?.invoke(lastTouchRawX, lastTouchRawY, WheelPetDragPhase.end)
    }

    private fun handleOutcome(current: WheelMenuLayout, outcome: WheelGestureOutcome) {
        when (outcome.effect) {
            WheelGestureEffect.none -> Unit

            WheelGestureEffect.press -> {
                val index = outcome.index ?: return
                pressRun = WheelAnimationRun(
                    kind = WheelAnimationKind.press,
                    startedAtMs = SystemClock.uptimeMillis(),
                    fromSelection = frame.selectionPosition,
                    toSelection = frame.selectionPosition,
                    itemCount = current.itemCount,
                    pressIndex = index,
                    mirrorProgress = mirrorOf(current.direction),
                )
                startTicker()
                invalidate()
            }

            WheelGestureEffect.swipeStart,
            WheelGestureEffect.highlight,
            -> {
                val index = outcome.index ?: return
                state.setPreview(index)
                liveSelection = index.toFloat()
                frame = frame.copy(
                    selectionPosition = index.toFloat(),
                    mirrorProgress = mirrorOf(current.direction),
                )
                if (outcome.haptic) performHaptic()
                refreshInfo(force = false)
                invalidate()
            }

            WheelGestureEffect.confirm -> {
                val index = outcome.index ?: return
                state.setPreview(index)
                val entry = state.confirmSelection() ?: return
                liveSelection = null
                clearPress()
                refreshInfo(force = true)
                invalidate()
                entryListener?.invoke(entry, index)
            }

            WheelGestureEffect.cancel -> {
                // 取消：高亮弹回已确认项，不执行任何动作（需求 §11.2 / §11.4）。
                state.setPreview(null)
                liveSelection = null
                clearPress()
                refreshInfo(force = true)
                startRun(
                    WheelAnimationKind.selectionSwitch,
                    from = frame.selectionPosition,
                    to = state.selectedIndex.toFloat(),
                    count = current.itemCount,
                )
            }

            WheelGestureEffect.outsideTap -> closeListener?.invoke()

            WheelGestureEffect.petDragStart -> {
                // 中央桌宠区域开始拖动：先隐藏轮盘，再把后续位移转发给桌宠窗口（需求 §3 / §13）。
                // 记下"正在转发"：后续 MOVE/终止事件会走 [onTouchEvent] 的第 0 分支（同一处收尾）。
                petDragForwarding = true
                hideForPetDrag()
                petDragListener?.invoke(lastTouchRawX, lastTouchRawY, WheelPetDragPhase.start)
            }

            WheelGestureEffect.petDragMove ->
                petDragListener?.invoke(lastTouchRawX, lastTouchRawY, WheelPetDragPhase.move)

            WheelGestureEffect.petDragEnd -> {
                petDragForwarding = false
                petDragListener?.invoke(lastTouchRawX, lastTouchRawY, WheelPetDragPhase.end)
            }
        }
    }

    private fun clearPress() {
        pressRun = null
        if (frame.pressIndex >= 0) {
            frame = frame.copy(pressIndex = -1, pressProgress = 0f)
        }
    }

    private fun performHaptic() {
        if (!hapticsEnabled) return
        // 轻触觉（"每跨一个槽位一次"，需求 §11.2）；失败不影响手势。
        runCatching { performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK) }
    }

    private fun bindLayout(layout: WheelMenuLayout) {
        gesture.layout = layout
        gesture.selectedIndex = state.selectedIndex
    }

    private fun refreshInfo(force: Boolean) {
        val provider = infoProvider
        val entry = state.activeEntry
        if (provider == null || entry == null) {
            infoText = null
            infoKey = null
            return
        }
        val key = "${entry.id}#${state.activeIndex}"
        if (!force && key == infoKey) return
        infoKey = key
        infoText = runCatching { provider(entry) }.getOrNull()
    }

    // ------------------------------------------------------------------
    // 绘制
    // ------------------------------------------------------------------

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        // 拖动桌宠期间不画轮盘（View 仍是 VISIBLE，触摸流不断）。
        if (suppressed) return
        val current = layout ?: return
        val level = state.currentLevel ?: return
        renderer.draw(
            canvas,
            WheelRenderParams(
                layout = current,
                level = level,
                frame = frame,
                activeIndex = state.activeIndex,
                theme = theme,
                infoText = infoText,
                debugBounds = debugBounds,
                density = resources.displayMetrics.density,
                // 按钮中文标签只画在**根菜单**（需求 §10.3）。
                showButtonLabels = state.levelId == WheelMenuCatalog.ROOT_ID,
                // ARCH-VERIFY：架构验证扇区（证明人物层在菜单层之上）。
                verifyFan = debugVerifyFan,
            ),
        )
    }

    private fun mirrorOf(direction: WheelExpandDirection): Float =
        if (direction == WheelExpandDirection.right) 1f else 0f

    private fun hiddenFrame(): WheelAnimationFrame = WheelAnimationFrame(
        openProgress = 0f,
        selectionPosition = 0f,
        layerProgress = 1f,
        titleProgress = 1f,
        mirrorProgress = 1f,
        buttonProgress = emptyList(),
        pressIndex = -1,
        pressProgress = 0f,
        rotationDeg = 0f,
        scale = 1f,
    )

    /** 一行式诊断（日志用）。 */
    fun dump(): String = String.format(
        Locale.US,
        "wheel phase=%s level=%s dir=%s active=%d anim=%s gesture=%s window=%s " +
            "avgFrame=%.1fms maxFrame=%.1fms dropped=%d",
        state.phase.name,
        state.levelId,
        state.direction.name,
        state.activeIndex,
        run?.kind?.name ?: "idle",
        gesture.ownerName,
        layout?.windowRect?.toString() ?: "none",
        frameStats.averageMs,
        frameStats.maxMs,
        frameStats.dropped,
    )
}

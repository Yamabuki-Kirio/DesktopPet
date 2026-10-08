package asia.akechi.petlife.overlay

import kotlin.math.hypot
import kotlin.math.roundToInt

/**
 * 悬浮桌宠的手势状态（Phase 4C-3A）。
 *
 * 为什么要有明确状态而不是几个布尔值：拖动、点击、双指缩放三者互斥，
 * 用 `isDragging`/`isPressed`/`isScaling` 互相覆盖必然出现
 * "拖动结束误触发菜单""缩放中途把窗口拖走"这类竞态。
 *
 * 状态迁移（4C-3A 实现的部分）：
 * ```
 * IDLE --DOWN--> PRESSING --移动>touchSlop--> DRAGGING --UP--> IDLE
 *                    |                                        ↑
 *                    +---UP(未超 slop 且未超时)--> 点击 --> IDLE
 *                    +---UP(超时/超 slop)------> 取消 --> IDLE
 *                    +---CANCEL--------------------------> IDLE
 * ```
 * [SCALING] 属于 4C-3A 的可选双指缩放（第一版不实现，只在机器里预留转移），
 * [MENU_OPEN] 属于 4C-3B 的圆盘菜单，[HIDDEN] / [STOPPED] 由服务生命周期驱动。
 */
internal enum class OverlayGestureState {
    IDLE,
    PRESSING,
    DRAGGING,
    SCALING,
    MENU_OPEN,
    HIDDEN,
    STOPPED,
}

/** 一次触摸事件的**判定结果**（调用方据此操作窗口，机器本身不碰 WindowManager）。 */
internal enum class OverlayGestureEffect {
    /** 什么都不做。 */
    none,

    /** 手指按下（可以开始累积拖动）。 */
    press,

    /** 越过 touchSlop，正式开始拖动。 */
    dragStart,

    /** 拖动中（每次 MOVE 一次）。 */
    drag,

    /** 拖动结束（此时才允许持久化位置）。 */
    dragEnd,

    /** 判定为单击（移动未超 slop 且按下时间未超阈值）。 */
    click,

    /** 手势被取消（ACTION_CANCEL、超时、或多指介入）。 */
    cancel,
}

/**
 * 手势状态机（**纯逻辑**，可 JVM 单测）。
 *
 * 硬规则（对应需求"三、4C-3A 手势状态机"）：
 * 1. `DOWN` 后先进 [OverlayGestureState.PRESSING]；
 * 2. 移动超过 touchSlop 才进 [OverlayGestureState.DRAGGING]；
 * 3. [OverlayGestureState.DRAGGING] 状态下松手**一定不**产生 [OverlayGestureEffect.click]；
 * 4. [OverlayGestureState.SCALING] 状态下不拖动、不点击；
 * 5. `ACTION_CANCEL` 必须回到干净状态。
 *
 * touchSlop 由调用方传入 `ViewConfiguration.getScaledTouchSlop()`，
 * **不写死像素阈值**。
 */
internal class OverlayGestureMachine(
    private val touchSlopPx: Int,
    private val tapTimeoutMs: Long = OverlayGeometry.TAP_TIMEOUT_MS,
) {

    var state: OverlayGestureState = OverlayGestureState.IDLE
        private set

    /**
     * 窗口当前是否可以更新（已挂载且 `isAttachedToWindow == true`）。
     *
     * 为 false 时**不允许进入拖动**：否则会出现"View 已经被摘掉，
     * 还在对它调 updateViewLayout"（需求"三、第 7/8 条"）。
     */
    var windowUpdatable: Boolean = true

    private var downX: Float = 0f
    private var downY: Float = 0f
    private var downAtMs: Long = 0L
    private var dragging: Boolean = false

    /** touchSlop 至少为 1，避免"任何移动都算拖动"。 */
    private val slop: Int get() = touchSlopPx.coerceAtLeast(1)

    fun onDown(x: Float, y: Float, timeMs: Long, pointerCount: Int = 1): OverlayGestureEffect {
        if (state == OverlayGestureState.HIDDEN || state == OverlayGestureState.STOPPED) {
            return OverlayGestureEffect.none
        }
        // 第二根手指落下：进入缩放（4C-3A 第一版不实现缩放，直接取消手势，
        // 保证"双指时既不会拖动也不会打开菜单"）。
        if (pointerCount > 1) {
            return beginScaling()
        }
        state = OverlayGestureState.PRESSING
        downX = x
        downY = y
        downAtMs = timeMs
        dragging = false
        return OverlayGestureEffect.press
    }

    fun onMove(x: Float, y: Float, timeMs: Long, pointerCount: Int = 1): OverlayGestureEffect {
        if (pointerCount > 1) {
            // 拖动中突然多指：立即结束拖动（不持久化——交给 cancel 语义），进入缩放态。
            if (state == OverlayGestureState.DRAGGING || state == OverlayGestureState.PRESSING) {
                return beginScaling()
            }
            return OverlayGestureEffect.none
        }
        return when (state) {
            OverlayGestureState.PRESSING,
            // 菜单打开时按下桌宠：依然允许"移动超过 slop → 开始拖动"
            // （需求 3.3：菜单打开时开始拖动要先关菜单，再进入 DRAGGING）。
            OverlayGestureState.MENU_OPEN,
            ->
                if (!windowUpdatable) {
                    // 窗口不可更新（未附着）：不进入拖动，位置一动不动。
                    OverlayGestureEffect.none
                } else if (movedBeyondSlop(x, y)) {
                    state = OverlayGestureState.DRAGGING
                    dragging = true
                    OverlayGestureEffect.dragStart
                } else {
                    OverlayGestureEffect.none
                }
            OverlayGestureState.DRAGGING -> OverlayGestureEffect.drag
            else -> OverlayGestureEffect.none
        }
    }

    fun onUp(x: Float, y: Float, timeMs: Long, pointerCount: Int = 1): OverlayGestureEffect {
        if (pointerCount > 1) return beginScaling()
        val previous = state
        val beyondSlop = movedBeyondSlop(x, y)
        val withinTapTime = timeMs - downAtMs in 0..tapTimeoutMs
        clearGesture()

        return when (previous) {
            // 拖动过就绝不再判点击（需求 3 / 7.5 的硬规则）。
            OverlayGestureState.DRAGGING -> OverlayGestureEffect.dragEnd
            OverlayGestureState.PRESSING ->
                if (!beyondSlop && withinTapTime) {
                    OverlayGestureEffect.click
                } else {
                    OverlayGestureEffect.cancel
                }
            else -> OverlayGestureEffect.none
        }
    }

    fun onCancel(): OverlayGestureEffect {
        val previous = state
        clearGesture()
        return when (previous) {
            OverlayGestureState.PRESSING,
            OverlayGestureState.DRAGGING,
            OverlayGestureState.SCALING,
            -> OverlayGestureEffect.cancel
            else -> OverlayGestureEffect.none
        }
    }

    /** 窗口隐藏 / 服务停止：取消一切进行中的手势（需求 5）。 */
    fun suspend(target: OverlayGestureState) {
        require(target == OverlayGestureState.HIDDEN || target == OverlayGestureState.STOPPED) {
            "suspend 只接受 HIDDEN / STOPPED"
        }
        clearGesture()
        state = target
    }

    /** 菜单已打开：进入 [OverlayGestureState.MENU_OPEN]（幂等）。 */
    fun onMenuOpened() {
        if (state == OverlayGestureState.HIDDEN || state == OverlayGestureState.STOPPED) return
        clearGesture()
        state = OverlayGestureState.MENU_OPEN
    }

    /** 菜单已关闭：回到 [OverlayGestureState.IDLE]（幂等；HIDDEN/STOPPED 不被覆盖）。 */
    fun onMenuClosed() {
        if (state == OverlayGestureState.HIDDEN || state == OverlayGestureState.STOPPED) return
        clearGesture()
        state = OverlayGestureState.IDLE
    }

    /** 菜单当前是否处于打开态（诊断 / 命中判定用）。 */
    fun isMenuOpen(): Boolean = state == OverlayGestureState.MENU_OPEN

    /** 是否正处于"拖动中"（调用方据此决定要不要写窗口坐标）。 */
    fun isDragging(): Boolean = dragging

    /** 缩放态（4C-3A 第一版只用于"取消手势"，不产生窗口变化）。 */
    private fun beginScaling(): OverlayGestureEffect {
        val previous = state
        dragging = false
        state = OverlayGestureState.SCALING
        return if (previous == OverlayGestureState.DRAGGING ||
            previous == OverlayGestureState.PRESSING
        ) {
            OverlayGestureEffect.cancel
        } else {
            OverlayGestureEffect.none
        }
    }

    private fun clearGesture() {
        dragging = false
        downX = 0f
        downY = 0f
        downAtMs = 0L
        if (state != OverlayGestureState.HIDDEN && state != OverlayGestureState.STOPPED) {
            state = OverlayGestureState.IDLE
        }
    }

    private fun movedBeyondSlop(x: Float, y: Float): Boolean =
        hypot((x - downX).toDouble(), (y - downY).toDouble()) > slop
}

/**
 * **拖动跟踪器**（纯逻辑，可 JVM 单测；真机缺陷 2「快速拖动像脱手」的结构性修复）。
 *
 * 旧实现用「按下点 + 局部坐标位移增量」算窗口新位置
 * （`dragOrigin + (event.x - pressRawX)`）。一旦窗口跟着手指移动，`event.x/y`
 * 所属的坐标系（View 局部）**基准也一起变了**，每帧再拿它当增量必然漂移 ——
 * 真机上表现为「快速/大幅拖动时桌宠越拖越跟不上、像从手里滑出去」。
 *
 * 本类改用**屏幕绝对坐标 + 一次性抓取偏移**，只依赖两个量：
 * ```
 * grabOffset      = 手指屏幕坐标(DOWN) − 桌宠屏幕左上角(DOWN)   // 只在 DOWN 记一次
 * petTargetOrigin = 手指屏幕坐标(当前) − grabOffset            // 每帧重算，绝不累加
 * ```
 * 因为 `grabOffset` 在整个手势里是常量，`petTargetOrigin` 与「窗口/桌宠当前在哪」
 * **完全无关** —— 手指怎么动，桌宠就怎么跟，从结构上不可能「脱手」。
 *
 * 另外三条硬规则（对应需求 2-2 / 2-3 / 2-4 / 2-6 / 2-7）：
 * 1. **锁定 DOWN 指针**：MOVE/UP 只有同一个 [activePointerId] 才生效，第二根手指
 *    不抢手势；锁定指针抬起即干净结束，**绝不悄悄换到别的指针**；
 * 2. **越界不丢手势**：目标点被夹进可用区域，但 [isActive] 保持为 true；
 *    手指回到范围内桌宠立刻继续跟随；
 * 3. **UP 用最后手指位置结算**：[end] 以最后一次已知手指位置重算目标，
 *    不用按下点、也不用中途任何一个旧值。
 */
internal class OverlayDragTracker {

    /** 按下时锁定的指针 id；无手势时为 -1。 */
    var activePointerId: Int = -1
        private set

    /** 抓取偏移（屏幕坐标）：手指按住点 − 桌宠屏幕左上角。 */
    var grabOffsetX: Float = 0f
        private set
    var grabOffsetY: Float = 0f
        private set

    private var lastFingerX: Float = 0f
    private var lastFingerY: Float = 0f
    private var lastTargetX: Int = 0
    private var lastTargetY: Int = 0
    private var haveTarget: Boolean = false
    private var active: Boolean = false

    /** 手势是否仍在进行（越界不改变它）。 */
    val isActive: Boolean get() = active

    /** 是否已经算出过至少一个有效目标（UP 落盘用）。 */
    val hasTarget: Boolean get() = haveTarget

    /** 最近一次算出的桌宠**屏幕**左上角；从未移动过则为 null。 */
    fun lastTarget(): IntArray? = if (haveTarget) intArrayOf(lastTargetX, lastTargetY) else null

    /** 强制回到"没有手势"状态（窗口重建 / 卸载时调用；不影响已有 lastTarget）。 */
    fun reset() {
        active = false
        activePointerId = -1
    }

    /**
     * 记录抓取：一次性算出 `grabOffset = 手指屏幕坐标 − 桌宠屏幕左上角`。
     *
     * @param pointerId 按下指针 id
     * @param petOriginX / [petOriginY] 桌宠**屏幕**左上角（窗口原点 + 人物层偏移）
     */
    fun begin(pointerId: Int, fingerX: Float, fingerY: Float, petOriginX: Int, petOriginY: Int) {
        activePointerId = pointerId
        grabOffsetX = fingerX - petOriginX
        grabOffsetY = fingerY - petOriginY
        lastFingerX = fingerX
        lastFingerY = fingerY
        active = true
        haveTarget = false
    }

    /** 该指针是否就是按下时锁定的那一个（第二根手指恒为 false）。 */
    fun owns(pointerId: Int): Boolean = active && pointerId == activePointerId

    /**
     * 记录一次手指屏幕位置并返回**夹取后**的桌宠目标左上角。
     * 非锁定指针返回 null（忽略：不抢手势、不改状态）。
     */
    fun update(
        pointerId: Int,
        fingerX: Float,
        fingerY: Float,
        bounds: OverlayBounds,
        petWidth: Int,
        petHeight: Int,
    ): IntArray? {
        if (!owns(pointerId)) return null
        lastFingerX = fingerX
        lastFingerY = fingerY
        return resolveTarget(bounds, petWidth, petHeight)
    }

    /**
     * 抬手：以**最后已知手指位置**结算一次并结束手势。
     * 非锁定指针返回 null（不改状态，避免第二根手指的 UP 误结束拖动）。
     */
    fun end(
        pointerId: Int,
        bounds: OverlayBounds,
        petWidth: Int,
        petHeight: Int,
    ): IntArray? {
        if (!owns(pointerId)) return null
        val target = resolveTarget(bounds, petWidth, petHeight)
        active = false
        activePointerId = -1
        return target
    }

    /**
     * 取消：结束手势，**保留**最后有效目标（供「保留最后位置」用），不清空。
     * 从未移动过则返回 null。
     */
    fun cancel(): IntArray? {
        if (!active) return null
        active = false
        activePointerId = -1
        return lastTarget()
    }

    private fun resolveTarget(bounds: OverlayBounds, petWidth: Int, petHeight: Int): IntArray {
        val rawX = (lastFingerX - grabOffsetX).roundToInt()
        val rawY = (lastFingerY - grabOffsetY).roundToInt()
        val clamped = OverlayPositionCalculator.clampTopLeft(rawX, rawY, bounds, petWidth, petHeight)
        lastTargetX = clamped[0]
        lastTargetY = clamped[1]
        haveTarget = true
        return clamped
    }
}

/**
 * **转发拖动期间的菜单摘除延迟器**（纯逻辑，可 JVM 单测；真机缺陷 2-5）。
 *
 * 背景：菜单打开时，桌宠拖动由 `WheelMenuView` **转发**（事件流的持有者是菜单层）。
 * 如果在拖动进行中把菜单层摘掉，菜单 View 会从窗口树消失，系统立刻给这条手势补一个
 * `ACTION_CANCEL` —— 拖动被「腰斩」，用户看到桌宠突然停住。
 *
 * 规则：转发拖动进行中收到的摘除请求**挂起**（只记第一个原因），手势结束后由调用方
 * `consumePendingDetach()` 取走并**恰好执行一次**。
 */
internal class OverlayDetachDeferral {

    private var forwardedDragActive: Boolean = false
    private var pendingReason: String? = null

    val isForwardedDragActive: Boolean get() = forwardedDragActive

    val hasPending: Boolean get() = pendingReason != null

    fun reset() {
        forwardedDragActive = false
        pendingReason = null
    }

    /** 转发拖动开始（幂等）。 */
    fun beginForwardedDrag() {
        forwardedDragActive = true
    }

    /** 转发拖动结束（幂等；不自动消费挂起项，由调用方显式消费）。 */
    fun endForwardedDrag() {
        forwardedDragActive = false
    }

    /**
     * 请求摘除菜单层。
     * @return true = 现在就可以摘；false = 已挂起（转发拖动进行中），稍后消费。
     */
    fun requestDetach(reason: String): Boolean {
        if (!forwardedDragActive) return true
        if (pendingReason == null) pendingReason = reason
        return false
    }

    /** 手势结束后消费挂起的摘除请求（**最多一次**）。返回被挂起的原因或 null。 */
    fun consumePendingDetach(): String? {
        val reason = pendingReason
        pendingReason = null
        return reason
    }

    /**
     * **强制释放**（缺陷 1 最终兜底）：无条件清掉"转发拖动进行中"的挂起闸门，
     * 并把被挂起的原因返回（供调用方立刻完成摘层 + 缩窗）。
     *
     * 为什么需要它：只靠"手势终止事件"释放闸门的前提是**终止事件一定会到**。
     * 真机上存在终止事件缺失的路径（转发拖动转发链被外力打断、触摸流被系统吞掉等），
     * 一旦缺失，闸门永远挂起 —— 表现就是"菜单看着没了，可它那块区域继续吞触摸、
     * 隐藏按钮还能被点亮"。有界超时后必须能无条件收敛，因此这里不依赖任何手势状态。
     *
     * @return 被挂起的原因；没有挂起项时返回 null（此时若仍在转发拖动，也一并清掉标志）。
     */
    fun forceRelease(): String? {
        val reason = pendingReason
        forwardedDragActive = false
        pendingReason = null
        return reason
    }
}

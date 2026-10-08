package asia.akechi.petlife.overlay

import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.hypot
import kotlin.math.roundToInt

/** 手指相对轮盘的位置分区（需求 §11.4）。 */
internal enum class WheelZone {
    /** 中央缺口：取消区。 */
    center,

    /** 滑选环带：可选择。 */
    ring,

    /** 环带之外：取消区，且**短暂离开有容差**。 */
    outside,
}

/** 手势判定结果（调用方据此改状态、给触觉、执行动作）。 */
internal enum class WheelGestureEffect {
    none,

    /** 按在按钮/环带上（可以进入点击或滑选）。 */
    press,

    /** 开始沿弧线滑选。 */
    swipeStart,

    /** 高亮项发生变化。 */
    highlight,

    /** 松手确认（[WheelGestureOutcome.index] 为被选中槽位）。 */
    confirm,

    /** 取消（滑出环带 / 回中心 / 多指介入）。 */
    cancel,

    /** 落在空白处并松手 —— 关闭整个菜单。 */
    outsideTap,

    /** 中央桌宠区域开始拖动（**由菜单 View 转发给桌宠窗口**，需求 §3）。 */
    petDragStart,

    /** 中央桌宠区域拖动中。 */
    petDragMove,

    /** 中央桌宠区域拖动结束（先关菜单，再贴边与落盘）。 */
    petDragEnd,
}

/** 中央桌宠区域拖动的三个相位（转发给桌宠窗口用）。 */
internal enum class WheelPetDragPhase { start, move, end }

internal data class WheelGestureOutcome(
    val effect: WheelGestureEffect,
    val index: Int? = null,
    /** 本次是否应给一次轻触觉（跨槽位各一次，需求 §11.2）。 */
    val haptic: Boolean = false,
)

/**
 * 轮盘手势控制器（**纯逻辑**，可 JVM 单测）。
 *
 * 三条硬规则（需求 §11 / §12）：
 * 1. **角度判定**，不是水平位移：`slot = nearestSlot(atan2(dy, dx))`
 *    —— 只用水平位移在轮盘下半圈会判反；
 * 2. **槽位滞回**：跨槽需要越过"边界 + 6~10°"，否则手指停在两槽之间时高亮会来回闪；
 * 3. **松手确认**：划过即执行会让"隐藏""停止服务"被误触发，所以一律抬手才生效。
 *
 * 另外：**第一版不做惯性旋转**（需求 §11.5）—— 甩动最多按手指最后的落点确认一项，
 * 绝不"额外多滚几项"。
 */
internal class WheelMenuGestureController(
    private val touchSlopPx: Float,
    private val swipeSlopPx: Float,
    private val hysteresisDeg: Float = HYSTERESIS_DEG,
    private val leaveToleranceMs: Long = LEAVE_TOLERANCE_MS,
) {

    var layout: WheelMenuLayout? = null

    /** 当前已确认的选中项（滑选从它开始算滞回）。 */
    var selectedIndex: Int = 0

    private var owner: Owner = Owner.none
    private var downX = 0f
    private var downY = 0f
    private var highlightIndex: Int? = null
    private var leaveSinceMs: Long? = null

    /** 中央桌宠区域的拖动是否已经开始（决定发 petDragStart 还是 petDragMove）。 */
    private var petDragging: Boolean = false

    /** 诊断用：当前手势归属。 */
    val ownerName: String get() = owner.name

    val isSwiping: Boolean get() = owner == Owner.swiping

    val highlightedIndex: Int? get() = highlightIndex

    fun reset() {
        owner = Owner.none
        highlightIndex = null
        leaveSinceMs = null
        petDragging = false
    }

    fun onDown(x: Float, y: Float, timeMs: Long, pointerCount: Int = 1): WheelGestureOutcome {
        val current = layout ?: return WheelGestureOutcome(WheelGestureEffect.none)
        reset()
        downX = x
        downY = y
        if (pointerCount > 1) {
            // 多指：所有权不明确 → 本轮一律不产生动作（宁可什么都不做）。
            owner = Owner.cancelled
            return WheelGestureOutcome(WheelGestureEffect.cancel)
        }
        val zone = zoneAt(current, x, y)
        return when (zone) {
            WheelZone.ring -> {
                owner = Owner.pressing
                highlightIndex = indexAt(current, x, y, selectedIndex)
                WheelGestureOutcome(WheelGestureEffect.press, highlightIndex)
            }
            WheelZone.center, WheelZone.outside -> {
                // 中央缺口 = 桌宠区域：拖动由菜单 View **转发**给桌宠窗口
                // （菜单窗口在上层，不依赖窗口触摸穿透，需求 §3）。
                // 落在环带之外（轮盘外）才是"空白处"。
                owner = if (zone == WheelZone.center) Owner.petDrag else Owner.pendingOutside
                WheelGestureOutcome(WheelGestureEffect.none)
            }
        }
    }

    fun onMove(x: Float, y: Float, timeMs: Long, pointerCount: Int = 1): WheelGestureOutcome {
        val current = layout ?: return WheelGestureOutcome(WheelGestureEffect.none)
        if (pointerCount > 1) {
            if (owner == Owner.pressing || owner == Owner.swiping || owner == Owner.pendingOutside ||
                owner == Owner.petDrag
            ) {
                owner = Owner.cancelled
                highlightIndex = null
                petDragging = false
                return WheelGestureOutcome(WheelGestureEffect.cancel)
            }
            return WheelGestureOutcome(WheelGestureEffect.none)
        }
        val moved = distance(downX, downY, x, y)
        when (owner) {
            Owner.pendingOutside -> {
                if (moved > swipeSlopPx && zoneAt(current, x, y) == WheelZone.ring) {
                    owner = Owner.swiping
                    return startHighlight(current, x, y)
                }
                return WheelGestureOutcome(WheelGestureEffect.none)
            }
            Owner.pressing -> {
                if (moved <= swipeSlopPx) return WheelGestureOutcome(WheelGestureEffect.none)
                owner = Owner.swiping
                return startHighlight(current, x, y)
            }
            Owner.swiping -> {
                val zone = zoneAt(current, x, y)
                if (zone != WheelZone.ring) {
                    val since = leaveSinceMs ?: timeMs.also { leaveSinceMs = it }
                    if (timeMs - since <= leaveToleranceMs) {
                        // 短暂离开环带：保持当前高亮（需求 §11.4）。
                        return WheelGestureOutcome(WheelGestureEffect.none)
                    }
                    highlightIndex = null
                    return WheelGestureOutcome(WheelGestureEffect.cancel)
                }
                leaveSinceMs = null
                val next = indexAt(current, x, y, highlightIndex)
                if (next == highlightIndex) return WheelGestureOutcome(WheelGestureEffect.none)
                val changed = next != highlightIndex
                highlightIndex = next
                return WheelGestureOutcome(
                    WheelGestureEffect.highlight,
                    next,
                    // 跨槽位各一次轻触觉（需求 §11.2 / §18.3）。
                    haptic = changed,
                )
            }
            Owner.petDrag -> {
                // 中央桌宠区域：超过滑选阈值即视为拖动桌宠（需求 §3 / §4）。
                if (moved > swipeSlopPx) {
                    if (!petDragging) {
                        petDragging = true
                        return WheelGestureOutcome(WheelGestureEffect.petDragStart)
                    }
                    return WheelGestureOutcome(WheelGestureEffect.petDragMove)
                }
                return WheelGestureOutcome(WheelGestureEffect.none)
            }
            Owner.cancelled, Owner.none -> return WheelGestureOutcome(WheelGestureEffect.none)
        }
    }

    fun onUp(x: Float, y: Float, timeMs: Long, pointerCount: Int = 1): WheelGestureOutcome {
        val current = layout ?: return WheelGestureOutcome(WheelGestureEffect.none)
        val previous = owner
        val moved = distance(downX, downY, x, y)
        val index = highlightIndex
        // reset() 会清掉 petDragging，因此在它之前先把"是否真的拖过"记下来。
        val wasPetDragging = petDragging
        reset()
        if (pointerCount > 1) return WheelGestureOutcome(WheelGestureEffect.cancel)
        return when (previous) {
            Owner.swiping -> {
                if (index != null && zoneAt(current, x, y) == WheelZone.ring) {
                    WheelGestureOutcome(WheelGestureEffect.confirm, index)
                } else {
                    WheelGestureOutcome(WheelGestureEffect.cancel)
                }
            }
            Owner.pressing -> {
                if (index != null && moved <= touchSlopPx) {
                    // 点击阈值内抬手 = 点击该按钮（需求 §11.1 / §12）。
                    WheelGestureOutcome(WheelGestureEffect.confirm, index)
                } else {
                    WheelGestureOutcome(WheelGestureEffect.cancel)
                }
            }
            Owner.pendingOutside ->
                if (moved <= touchSlopPx) {
                    WheelGestureOutcome(WheelGestureEffect.outsideTap)
                } else {
                    WheelGestureOutcome(WheelGestureEffect.none)
                }
            Owner.petDrag ->
                if (wasPetDragging) {
                    WheelGestureOutcome(WheelGestureEffect.petDragEnd)
                } else {
                    // 在桌宠区域点一下（没有拖动）＝ 关闭菜单（需求 §4：空白处/桌宠处点击关闭）。
                    WheelGestureOutcome(WheelGestureEffect.outsideTap)
                }
            Owner.cancelled, Owner.none -> WheelGestureOutcome(WheelGestureEffect.none)
        }
    }

    fun onCancel(): WheelGestureOutcome {
        val previous = owner
        reset()
        return if (previous == Owner.none) {
            WheelGestureOutcome(WheelGestureEffect.none)
        } else {
            WheelGestureOutcome(WheelGestureEffect.cancel)
        }
    }

    /** 位置分区。 */
    fun zoneAt(layout: WheelMenuLayout, x: Float, y: Float): WheelZone {
        if (insideNotch(layout, x, y)) return WheelZone.center
        val distance = distance(layout.centerX, layout.centerY, x, y)
        return if (distance <= layout.rimOuterPx) WheelZone.ring else WheelZone.outside
    }

    /**
     * 是否落在**中央缺口**里。
     *
     * 4C-6B-1.1 起缺口是**椭圆**（跟着桌宠的宽高比），且中心压在桌宠锚点上 ——
     * 因此"按在桌宠身上"会稳定判成取消区，与上层桌宠窗口的拖动互不干扰。
     */
    fun insideNotch(layout: WheelMenuLayout, x: Float, y: Float): Boolean {
        val rx = layout.notchRx.coerceAtLeast(1f)
        val ry = layout.notchRy.coerceAtLeast(1f)
        val nx = (x - layout.notchCenterX) / rx
        val ny = (y - layout.notchCenterY) / ry
        return nx * nx + ny * ny <= 1f
    }

    /**
     * 由**角度**推出最近的槽位；[previous] 非空时应用槽位滞回。
     */
    fun indexAt(
        layout: WheelMenuLayout,
        x: Float,
        y: Float,
        previous: Int?,
    ): Int? {
        if (layout.itemCount <= 0) return null
        if (layout.itemCount == 1) return 0
        val step = layout.stepDeg
        if (step <= 0f) return null
        val angle = Math.toDegrees(
            atan2((y - layout.centerY).toDouble(), (x - layout.centerX).toDouble()),
        ).toFloat()
        val raw = WheelMenuGeometry.rawIndexAt(layout, angle)
        if (previous != null && previous in 0 until layout.itemCount) {
            val hysteresisUnits = (hysteresisDeg / step).coerceAtMost(0.45f)
            if (abs(raw - previous) < 0.5f + hysteresisUnits) return previous
        }
        return raw.roundToInt().coerceIn(0, layout.itemCount - 1)
    }

    private fun startHighlight(
        layout: WheelMenuLayout,
        x: Float,
        y: Float,
    ): WheelGestureOutcome {
        if (zoneAt(layout, x, y) != WheelZone.ring) {
            return WheelGestureOutcome(WheelGestureEffect.swipeStart)
        }
        val before = highlightIndex
        val next = indexAt(layout, x, y, highlightIndex)
        highlightIndex = next
        return WheelGestureOutcome(
            WheelGestureEffect.swipeStart,
            next,
            // 进入滑选时如果直接落到另一个槽位，同样要补一次触觉（跨槽一次）。
            haptic = next != before,
        )
    }

    private fun distance(x0: Float, y0: Float, x1: Float, y1: Float): Float =
        hypot((x1 - x0).toDouble(), (y1 - y0).toDouble()).toFloat()

    private enum class Owner {
        none,
        pressing,
        swiping,
        pendingOutside,
        /** 中央桌宠区域（缺口）：拖动转发给桌宠窗口。 */
        petDrag,
        cancelled,
    }

    companion object {
        /** 每个槽位额外增加的滞回角度（需求 §11.3：6~10°）。 */
        const val HYSTERESIS_DEG = 7f

        /** 短暂离开环带的容差（需求 §11.4：100~150ms）。 */
        const val LEAVE_TOLERANCE_MS = 130L

        /** 点击判定阈值（需求 §12 建议 ~8dp）。 */
        const val TAP_SLOP_DP = 8f

        /** 滑选启动阈值（需求 §12 建议 10~12dp）。 */
        const val SWIPE_SLOP_DP = 12f

        fun fromDensity(density: Float): WheelMenuGestureController {
            val d = OverlayGeometry.safeDensity(density)
            return WheelMenuGestureController(
                touchSlopPx = TAP_SLOP_DP * d,
                swipeSlopPx = SWIPE_SLOP_DP * d,
            )
        }
    }
}

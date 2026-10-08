package asia.akechi.petlife.overlay

import kotlin.math.pow

/**
 * 三次贝塞尔缓动（**纯 Kotlin**）。
 *
 * 为什么不直接用 `android.view.animation.PathInterpolator`：
 * 动画时序是需求 §10 里最需要"逐毫秒打靶"的部分（错峰间隔、拖尾、接管），
 * 而这些测试必须能在 JVM 单测里跑，不能依赖 android 框架桩。
 */
internal class CubicBezierEasing(
    private val x1: Float,
    private val y1: Float,
    private val x2: Float,
    private val y2: Float,
) {
    /** 给定时间比例 `t ∈ [0,1]`，返回缓动后的进度。 */
    fun value(t: Float): Float {
        val x = t.coerceIn(0f, 1f)
        if (x <= 0f) return 0f
        if (x >= 1f) return 1f
        return sampleCurveY(solveCurveX(x))
    }

    private fun sampleCurveX(t: Float): Float = cubic(t, 0f, x1, x2, 1f)

    private fun sampleCurveY(t: Float): Float = cubic(t, 0f, y1, y2, 1f)

    private fun sampleDerivativeX(t: Float): Float =
        3f * (1f - t).pow(2) * x1 + 6f * (1f - t) * t * (x2 - x1) + 3f * t.pow(2) * (1f - x2)

    /** 牛顿迭代 + 二分兜底（与 Android 的实现同口径，保证真机与单测一致）。 */
    private fun solveCurveX(x: Float): Float {
        var t = x
        repeat(NEWTON_ITERATIONS) {
            val error = sampleCurveX(t) - x
            if (kotlin.math.abs(error) < NEWTON_EPSILON) return t
            val derivative = sampleDerivativeX(t)
            if (kotlin.math.abs(derivative) < 1e-6f) return@repeat
            t -= error / derivative
        }
        var lower = 0f
        var upper = 1f
        t = x
        repeat(BISECTION_ITERATIONS) {
            val current = sampleCurveX(t)
            when {
                current > x -> upper = t
                current < x -> lower = t
                else -> return t
            }
            t = (lower + upper) / 2f
        }
        return t
    }

    private fun cubic(t: Float, p0: Float, p1: Float, p2: Float, p3: Float): Float {
        val mt = 1f - t
        return mt.pow(3) * p0 + 3f * mt.pow(2) * t * p1 + 3f * mt * t.pow(2) * p2 + t.pow(3) * p3
    }

    companion object {
        private const val NEWTON_ITERATIONS = 8
        private const val BISECTION_ITERATIONS = 18
        private const val NEWTON_EPSILON = 1e-4f

        /** 展开：`PathInterpolator(0.16, 1.0, 0.30, 1.0)`（需求 §10.6）。 */
        val OPEN = CubicBezierEasing(0.16f, 1.0f, 0.30f, 1.0f)

        /** 切换 / 换层：`PathInterpolator(0.22, 0.85, 0.30, 1.0)`。 */
        val SWITCH = CubicBezierEasing(0.22f, 0.85f, 0.30f, 1.0f)

        /** 关闭：`PathInterpolator(0.55, 0.0, 0.85, 0.35)`。 */
        val CLOSE = CubicBezierEasing(0.55f, 0.0f, 0.85f, 0.35f)

        /** 按钮弹出的轻微回弹（不是无限 Spring，避免"弹跳过度"）。 */
        val POP = CubicBezierEasing(0.18f, 1.36f, 0.36f, 1.0f)
    }
}

/**
 * 一次动画的参数（**纯数据**）。
 *
 * [kind] 决定时序曲线；[fromSelection] / [toSelection] 是连续浮点选中位
 * （需求 §10："0.0 = 桌宠、1.0 = 形象、2.0 = 记录"，切换时**连续插值**而不是瞬间换索引）。
 */
internal data class WheelAnimationRun(
    val kind: WheelAnimationKind,
    val startedAtMs: Long,
    val fromSelection: Float,
    val toSelection: Float,
    val itemCount: Int,
    /** 换层动画的目标层级条目数（旧层级条目数用 [previousItemCount]）。 */
    val previousItemCount: Int = itemCount,
    /** 按下反馈的目标槽位（-1 = 无）。 */
    val pressIndex: Int = -1,
    /**
     * 镜像进度（0 = 向左展开，1 = 向右展开；需求 §10 的 `mirrorProgress`）。
     *
     * 菜单打开期间方向是**锁定**的（需求 §9），所以它是一个常量透传 ——
     * 放在这里是为了让"渲染层只读一个结构"这条不变式成立。
     */
    val mirrorProgress: Float = 1f,
) {
    val durationMs: Long get() = WheelAnimationTimeline.durationOf(kind)
}

internal enum class WheelAnimationKind {
    open,
    close,
    selectionSwitch,
    enterLayer,
    exitLayer,
    press,
}

/**
 * 每帧的动画状态（需求 §10 的 `WheelAnimationState`）。
 *
 * 渲染层**只读这一个结构**，不再自己去算时间 ——
 * 这样"展开、切换、换层、返回、关闭"共享同一个时钟，
 * 不会出现"两套动画同时改同一个属性"的抖动。
 */
internal data class WheelAnimationFrame(
    /** 0 = 完全收起，1 = 完全展开。 */
    val openProgress: Float,
    /** 连续选中位（0.0 = 第一项）。 */
    val selectionPosition: Float,
    /** 0 = 还是旧层级，1 = 已完全换成新层级。 */
    val layerProgress: Float,
    /** 标题切换进度（旧标题滑出 → 新标题进入）。 */
    val titleProgress: Float,
    /** 每帧的镜像进度（0 = 左展开，1 = 右展开）。 */
    val mirrorProgress: Float,
    /** 每个槽位的弹出进度（错峰）。 */
    val buttonProgress: List<Float>,
    val pressIndex: Int,
    val pressProgress: Float,
    /** 轮盘主体的旋转偏角（`-6° → 1° → 0°`）。 */
    val rotationDeg: Float,
    /** 轮盘主体的缩放（`0.75 → 1.03 → 1.0`）。 */
    val scale: Float,
)

/** 动画时序表（需求 §10 的逐段毫秒数，集中一处便于单测与文档引用）。 */
internal object WheelAnimationTimeline {

    const val OPEN_MS = 300L
    const val CLOSE_MS = 180L
    const val SELECT_MS = 220L
    const val ENTER_LAYER_MS = 300L
    const val EXIT_LAYER_MS = 230L
    const val PRESS_MS = 70L

    /** 展开时按钮错峰间隔。 */
    const val BUTTON_STAGGER_MS = 25L

    /** 展开阶段各段的起止（相对展开开始）。 */
    const val OPEN_BODY_START_MS = 0L
    const val OPEN_BODY_END_MS = 120L
    const val OPEN_BUTTON_START_MS = 50L
    const val OPEN_BUTTON_END_MS = 230L
    const val OPEN_TITLE_START_MS = 100L
    const val OPEN_TITLE_END_MS = 300L

    /** 关闭时不允许"反向错峰"造成尾巴拖长：整体一起收。 */
    const val CLOSE_BUTTON_TAIL_MS = 40L

    fun durationOf(kind: WheelAnimationKind): Long = when (kind) {
        WheelAnimationKind.open -> OPEN_MS
        WheelAnimationKind.close -> CLOSE_MS
        WheelAnimationKind.selectionSwitch -> SELECT_MS
        WheelAnimationKind.enterLayer -> ENTER_LAYER_MS
        WheelAnimationKind.exitLayer -> EXIT_LAYER_MS
        WheelAnimationKind.press -> PRESS_MS
    }

    /** 某个槽位在展开动画里的弹出进度（错峰：第 i 个比第 i-1 个晚 [BUTTON_STAGGER_MS]）。 */
    fun buttonProgress(elapsedMs: Long, index: Int, count: Int): Float {
        val startDelay = OPEN_BUTTON_START_MS
        val span = (OPEN_BUTTON_END_MS - OPEN_BUTTON_START_MS).toFloat()
        // 错峰后总时长会超过 180ms —— 按总数压缩间隔，保证最后一个仍在 OPEN_BUTTON_END 内弹出。
        val stagger = if (count <= 1) {
            0f
        } else {
            kotlin.math.min(BUTTON_STAGGER_MS.toFloat(), (span * 0.5f) / (count - 1))
        }
        val start = startDelay + stagger * index
        if (elapsedMs <= start) return 0f
        // 注意：必须走 Float 除法 —— Long/Long 会把进度整段截成 0。
        val local = ((elapsedMs - start).toFloat() / span).coerceIn(0f, 1f)
        return CubicBezierEasing.POP.value(local)
    }
}

/**
 * 由 [WheelAnimationRun] 与当前时间推出 [WheelAnimationFrame]（**纯函数**）。
 */
internal object WheelAnimationClock {

    fun frame(run: WheelAnimationRun, nowMs: Long): WheelAnimationFrame {
        val elapsed = (nowMs - run.startedAtMs).coerceAtLeast(0L)
        val total = run.durationMs.toFloat()
        val raw = if (total <= 0f) 1f else (elapsed / total).coerceIn(0f, 1f)
        val eased = when (run.kind) {
            WheelAnimationKind.open -> CubicBezierEasing.OPEN.value(raw)
            WheelAnimationKind.close -> CubicBezierEasing.CLOSE.value(raw)
            else -> CubicBezierEasing.SWITCH.value(raw)
        }
        val count = run.itemCount.coerceAtLeast(1)
        val buttons = List(count) { index ->
            when (run.kind) {
                WheelAnimationKind.open -> WheelAnimationTimeline.buttonProgress(elapsed, index, count)
                WheelAnimationKind.close ->
                    (1f - CubicBezierEasing.CLOSE.value(
                        ((elapsed + index * 0L) / total).coerceIn(0f, 1f),
                    ))
                WheelAnimationKind.enterLayer ->
                    // 子菜单按钮在后半段重新弹出，返回键最后出现（需求 §10.3）。
                    staggeredPop(elapsed, index, count, 80L, WheelAnimationTimeline.ENTER_LAYER_MS)
                WheelAnimationKind.exitLayer ->
                    staggeredPop(elapsed, index, count, 60L, WheelAnimationTimeline.EXIT_LAYER_MS)
                WheelAnimationKind.selectionSwitch,
                WheelAnimationKind.press,
                -> 1f
            }
        }
        val pressProgress = if (run.pressIndex >= 0) {
            when (run.kind) {
                WheelAnimationKind.press ->
                    // 压缩 → 回弹：前半段压扁，后半段回到 1。
                    if (raw < 0.5f) {
                        CubicBezierEasing.SWITCH.value(raw / 0.5f)
                    } else {
                        1f - CubicBezierEasing.OPEN.value((raw - 0.5f) / 0.5f)
                    }
                else -> 0f
            }
        } else {
            0f
        }
        val selection = when (run.kind) {
            WheelAnimationKind.open,
            WheelAnimationKind.close,
            WheelAnimationKind.enterLayer,
            WheelAnimationKind.exitLayer,
            -> run.toSelection
            else -> run.fromSelection + (run.toSelection - run.fromSelection) * eased
        }
        val mirror = run.mirrorProgress
        return WheelAnimationFrame(
            openProgress = when (run.kind) {
                WheelAnimationKind.open -> CubicBezierEasing.OPEN.value(raw)
                WheelAnimationKind.close -> 1f - CubicBezierEasing.CLOSE.value(raw)
                else -> 1f
            },
            selectionPosition = selection,
            layerProgress = when (run.kind) {
                WheelAnimationKind.enterLayer -> eased
                WheelAnimationKind.exitLayer -> 1f - eased
                else -> 1f
            },
            titleProgress = when (run.kind) {
                WheelAnimationKind.selectionSwitch -> eased
                WheelAnimationKind.enterLayer -> eased
                WheelAnimationKind.exitLayer -> 1f - eased
                else -> 1f
            },
            mirrorProgress = mirror,
            buttonProgress = buttons,
            pressIndex = run.pressIndex,
            pressProgress = pressProgress,
            rotationDeg = openRotation(run.kind, raw),
            scale = openScale(run.kind, raw),
        )
    }

    fun isFinished(run: WheelAnimationRun, nowMs: Long): Boolean =
        nowMs - run.startedAtMs >= run.durationMs

    /** 展开时的 `-6° → 1° → 0°`；关闭时反向。 */
    private fun openRotation(kind: WheelAnimationKind, raw: Float): Float = when (kind) {
        WheelAnimationKind.open -> when {
            raw < 0.5f -> -6f + (1f - -6f) * (raw / 0.5f)
            else -> 1f - 1f * ((raw - 0.5f) / 0.5f)
        }
        WheelAnimationKind.close -> 6f * raw
        else -> 0f
    }

    /** 展开时的 `0.75 → 1.03 → 1.0`；关闭时反向收缩。 */
    private fun openScale(kind: WheelAnimationKind, raw: Float): Float = when (kind) {
        WheelAnimationKind.open -> when {
            raw < 0.55f -> 0.75f + (1.03f - 0.75f) * (raw / 0.55f)
            else -> 1.03f - 0.03f * ((raw - 0.55f) / 0.45f)
        }
        WheelAnimationKind.close -> 1f - 0.25f * raw
        else -> 1f
    }

    /** 换层动画里第 [index] 个按钮的弹出（[delay] 之后开始，错峰 [WheelAnimationTimeline.BUTTON_STAGGER_MS]）。 */
    private fun staggeredPop(
        elapsedMs: Long,
        index: Int,
        count: Int,
        delayMs: Long,
        totalMs: Long,
    ): Float {
        val stagger = if (count <= 1) 0L else {
            kotlin.math.min(WheelAnimationTimeline.BUTTON_STAGGER_MS, 120L / (count - 1))
        }
        val start = delayMs + stagger * index
        val span = (totalMs - start).coerceAtLeast(1L)
        val local = ((elapsedMs - start).toFloat() / span).coerceIn(0f, 1f)
        return CubicBezierEasing.POP.value(local)
    }
}

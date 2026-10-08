package asia.akechi.petlife.overlay

import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * 悬浮桌宠的**可用区域**（像素，相对屏幕左上角）。
 *
 * 为什么不是"屏幕宽高"：状态栏、导航栏、刘海/挖孔都会吃掉可见区域，
 * 直接用 `displayMetrics.widthPixels` 会让桌宠被状态栏或导航栏压住/推到屏幕外。
 * 因此边界计算统一以本类型为准。
 *
 * [isUsable] 为 false 表示"拿不到可信的窗口指标"（例如早期 API 的上报异常），
 * 此时坐标计算必须退化为"不做限制"，绝不能把桌宠夹到 0×0 的角落里。
 */
internal data class OverlayBounds(
    val left: Int,
    val top: Int,
    val right: Int,
    val bottom: Int,
) {
    val width: Int get() = (right - left).coerceAtLeast(0)

    val height: Int get() = (bottom - top).coerceAtLeast(0)

    val isUsable: Boolean get() = width > 0 && height > 0

    companion object {
        val unknown = OverlayBounds(0, 0, 0, 0)

        /** 兜底：只有屏幕宽高、没有 inset 信息时用它（仍优于"不做任何限制"）。 */
        fun ofScreen(screenWidth: Int, screenHeight: Int): OverlayBounds =
            if (screenWidth > 0 && screenHeight > 0) {
                OverlayBounds(0, 0, screenWidth, screenHeight)
            } else {
                unknown
            }
    }
}

/** 桌宠窗口的像素尺寸（不是正方形：素材宽高比不同，窗口就不同）。 */
internal data class OverlaySize(val width: Int, val height: Int) {

    /** 长边：解码采样率以它为"目标尺寸"。 */
    val longEdge: Int get() = max(width, height)

    val isValid: Boolean get() = width > 0 && height > 0

    companion object {
        val fallback = OverlaySize(OverlayGeometry.MIN_VIEW_PX, OverlayGeometry.MIN_VIEW_PX)
    }
}

/**
 * 吸附边。`none` = 用户关掉了自动吸附，或还没拖动过。
 *
 * 刻意是 **public** 而不是 internal：它是持久化契约（`overlay.snap_edge`）
 * 与"服务 ↔ 窗口层"回调的共同词汇，出现在 public 的
 * [PetOverlayService] 的 override 签名里。
 */
enum class OverlaySnapEdge {
    left,
    right,
    none;

    /** 显示名（日志/设置页用）。 */
    val labelZh: String
        get() = when (this) {
            left -> "左"
            right -> "右"
            none -> "无"
        }

    companion object {
        fun fromWire(raw: String?): OverlaySnapEdge = when (raw?.lowercase()) {
            "left" -> left
            "right" -> right
            else -> none
        }
    }
}

/**
 * 悬浮桌宠的**纯几何计算**（Phase 4C-2 建立，Phase 4C-3A 扩展）。
 *
 * 全部是 Kotlin 原生类型（不碰任何 android.* 类），因此能在 JVM 单元测试里
 * 直接验证"尺寸下界""宽高比""边界夹取""相对位置换算""吸附"这些容易出错的规则。
 */
internal object OverlayGeometry {

    /** 悬浮窗**长边**基准（dp，100% 缩放时）。 */
    const val BASE_SIZE_DP = 96f

    /** 窗口长边的**硬下限**（dp）。需求要求"dp 转 px 后强制 width/height >= 48dp"。 */
    const val MIN_WINDOW_DP = 48f

    /** 绝对像素下限（防止 density 异常时算出 0）。 */
    const val MIN_VIEW_PX = 32

    /** 短边下限（dp）：长条素材也不能缩成一条线。 */
    const val MIN_SHORT_EDGE_DP = 32f

    /** 长边上限（dp）：缩放 200% 时的安全网，防止极端宽高比把窗口撑满屏幕。 */
    const val MAX_LONG_EDGE_DP = 320f

    /**
     * 允许的素材宽高比区间。
     *
     * 超出区间一律夹回来：否则一张 1×4000 的怪图会算出 0 宽窗口（4C-2 的教训之一
     * 就是"任何路径都不能产生 0 尺寸"）。
     */
    const val MIN_ASPECT = 0.2f
    const val MAX_ASPECT = 5f

    /** 诊断窗口：固定 200dp × 200dp。 */
    const val DEBUG_SIZE_DP = 200f

    /** 诊断窗口：固定位置（80dp, 160dp），**不恢复历史坐标**。 */
    const val DEBUG_X_DP = 80f
    const val DEBUG_Y_DP = 160f

    /** 贴边吸附动画时长（需求建议 150~250ms）。 */
    const val SNAP_ANIMATION_MS = 180L

    /** 判定"单击"的最长按下时间（与 touchSlop 一起决定是点击还是拖动）。 */
    const val TAP_TIMEOUT_MS = 300L

    /** 把任意"希望的边长"收敛成**一定可用**的像素值。 */
    fun safeViewSize(candidate: Int): Int = candidate.coerceAtLeast(MIN_VIEW_PX)

    /** 48dp 对应的像素（density 异常时退回 1.0）。 */
    fun minWindowPx(density: Float): Int {
        val safeDensity = safeDensity(density)
        return maxOf(MIN_VIEW_PX, (MIN_WINDOW_DP * safeDensity).roundToInt())
    }

    /** 短边下限对应的像素。 */
    fun minShortEdgePx(density: Float): Int {
        val safeDensity = safeDensity(density)
        return maxOf(MIN_VIEW_PX, (MIN_SHORT_EDGE_DP * safeDensity).roundToInt())
    }

    /** 长边上限对应的像素。 */
    fun maxLongEdgePx(density: Float): Int {
        val safeDensity = safeDensity(density)
        return maxOf(minWindowPx(density), (MAX_LONG_EDGE_DP * safeDensity).roundToInt())
    }

    /** 宽高比安全化：非有限值/非正值 → 1.0；超出区间 → 夹回。 */
    fun clampAspect(aspectRatio: Float): Float {
        if (!aspectRatio.isFinite() || aspectRatio <= 0f) return 1f
        return aspectRatio.coerceIn(MIN_ASPECT, MAX_ASPECT)
    }

    /** 缩放限制到设置页允许的区间。 */
    fun clampScale(scale: Float): Float =
        scale.coerceIn(PetOverlayStore.MIN_SCALE, PetOverlayStore.MAX_SCALE)

    /**
     * 窗口**长边**的像素值。
     *
     * 三条硬约束：
     * * **绝不为 0 或负数**（下限 = `max(48dp, 32px)`）—— 否则窗口"创建成功但不可见"；
     * * 不超过屏幕短边（窄屏 + 200% 缩放时窗口不能比屏幕还大）；
     * * 屏幕指标未知（0）时不设上限，交给下限兜底。
     *
     * 注意：4C-3A 起，窗口不再是正方形 —— 本函数只负责**长边**，
     * 真正的宽高由 [OverlayPetSize.resolve] 按素材宽高比分配。
     */
    fun viewSizePx(
        scale: Float,
        density: Float,
        screenWidth: Int,
        screenHeight: Int,
    ): Int {
        val safeDensityValue = safeDensity(density)
        val raw = (BASE_SIZE_DP * safeDensityValue * clampScale(scale)).roundToInt()
        val floor = minWindowPx(density)
        val screenCap = min(screenWidth, screenHeight)
        val upper = if (screenCap > 0) maxOf(screenCap, floor) else Int.MAX_VALUE
        return raw.coerceIn(floor, upper)
    }

    /** 诊断窗口边长（像素）：固定 200dp，同样不超过屏幕短边。 */
    fun debugSizePx(density: Float, screenWidth: Int, screenHeight: Int): Int {
        val safeDensityValue = safeDensity(density)
        val raw = (DEBUG_SIZE_DP * safeDensityValue).roundToInt()
        val floor = minWindowPx(density)
        val screenCap = min(screenWidth, screenHeight)
        val upper = if (screenCap > 0) maxOf(screenCap, floor) else Int.MAX_VALUE
        return raw.coerceIn(floor, upper)
    }

    /** 诊断窗口位置（像素）：固定 (80dp, 160dp)，再夹进可用区域。 */
    fun debugTopLeftPx(
        density: Float,
        bounds: OverlayBounds,
        viewSize: Int,
    ): IntArray {
        val safeDensityValue = safeDensity(density)
        val x = (DEBUG_X_DP * safeDensityValue).roundToInt()
        val y = (DEBUG_Y_DP * safeDensityValue).roundToInt()
        // 诊断窗口是正方形，宽高都用 viewSize。
        return OverlayPositionCalculator.clampTopLeft(
            x = x,
            y = y,
            bounds = bounds,
            petWidth = viewSize,
            petHeight = viewSize,
        )
    }

    /** density 异常（0 / NaN / 负数）时按 1.0 处理，绝不让它把尺寸算成 0。 */
    fun safeDensity(density: Float): Float =
        if (density.isFinite() && density > 0f) density else 1f
}

/**
 * 按**素材宽高比**把长边分配成窗口宽高（Phase 4C-3A）。
 *
 * 规则（每一条都对应需求"2.5 调整桌宠大小"）：
 * 1. 长边 = `96dp × density × scale`，夹进 `[48dp, 320dp]`；
 * 2. 短边 = 长边 ÷ 宽高比（宽高比 > 1 时按宽算，< 1 时按高算）→ **保持宽高比、不拉伸**；
 * 3. 短边不得小于 `max(32dp, 32px)`；必要时**等比放大长边**（仍然不变形）；
 * 4. 最后整体夹进可用区域（窗口比可用区域还大时等比缩小）；
 * 5. 最终宽高一定 > 0。
 */
internal object OverlayPetSize {

    fun resolve(
        scale: Float,
        density: Float,
        aspectRatio: Float,
        bounds: OverlayBounds,
    ): OverlaySize {
        val aspect = OverlayGeometry.clampAspect(aspectRatio)
        val longEdge = OverlayGeometry.viewSizePx(
            scale = scale,
            density = density,
            screenWidth = bounds.width,
            screenHeight = bounds.height,
        )
        return fromLongEdge(longEdge, aspect, density, bounds)
    }

    /** 由"长边像素 + 宽高比"推出宽高（便于单测直接打靶）。 */
    fun fromLongEdge(
        longEdgePx: Int,
        aspectRatio: Float,
        density: Float,
        bounds: OverlayBounds,
    ): OverlaySize {
        val aspect = OverlayGeometry.clampAspect(aspectRatio)
        val shortFloor = OverlayGeometry.minShortEdgePx(density)
        val longFloor = OverlayGeometry.minWindowPx(density)

        var long = max(OverlayGeometry.safeViewSize(longEdgePx), longFloor)
        var short = if (aspect >= 1f) {
            (long / aspect).roundToInt()
        } else {
            (long * aspect).roundToInt()
        }
        // 短边太小 → 等比放大长边（保持宽高比，而不是拉长短边）。
        if (short < shortFloor) {
            val factor = shortFloor.toFloat() / short.coerceAtLeast(1).toFloat()
            long = (long * factor).roundToInt()
            short = shortFloor
        }
        long = long.coerceAtLeast(1)
        short = short.coerceAtLeast(1)

        var width = if (aspect >= 1f) long else short
        var height = if (aspect >= 1f) short else long
        // 大尺寸安全网（极端宽高比 + 高分屏）。
        val maxLong = OverlayGeometry.maxLongEdgePx(density)
        if (max(width, height) > maxLong) {
            val factor = maxLong.toFloat() / max(width, height).toFloat()
            width = (width * factor).roundToInt().coerceAtLeast(1)
            height = (height * factor).roundToInt().coerceAtLeast(1)
        }
        // 夹进可用区域（窗口比可用区域还大时等比缩小，仍然不变形）。
        if (bounds.isUsable) {
            val factor = min(
                if (width > bounds.width) bounds.width.toFloat() / width else 1f,
                if (height > bounds.height) bounds.height.toFloat() / height else 1f,
            )
            if (factor < 1f) {
                width = (width * factor).roundToInt().coerceAtLeast(1)
                height = (height * factor).roundToInt().coerceAtLeast(1)
            }
        }
        return OverlaySize(width.coerceAtLeast(1), height.coerceAtLeast(1))
    }
}

/**
 * 位置计算（纯函数，Phase 4C-3A）。
 *
 * 位置策略：**把桌宠完全限制在可用区域内**（比"至少保留 25% 在屏内"更严格，
 * 用户不会出现"半个桌宠挂在状态栏/屏幕外"的观感）；只有桌宠比可用区域还大
 * （退化场景）时才贴到区域左上角，保证"尽可能可见"而不是崩掉或算出 0。
 */
internal object OverlayPositionCalculator {

    /**
     * 把左上角坐标夹进"桌宠完全位于可用区域"的范围。
     *
     * 可用区域不可信时**不做限制**（返回原值）；桌宠比区域还大时贴 `left/top`。
     */
    fun clampTopLeft(
        x: Int,
        y: Int,
        bounds: OverlayBounds,
        petWidth: Int,
        petHeight: Int,
    ): IntArray {
        if (!bounds.isUsable) return intArrayOf(x, y)
        val maxOffsetX = (bounds.width - petWidth).coerceAtLeast(0)
        val maxOffsetY = (bounds.height - petHeight).coerceAtLeast(0)
        return intArrayOf(
            x.coerceIn(bounds.left, bounds.left + maxOffsetX),
            y.coerceIn(bounds.top, bounds.top + maxOffsetY),
        )
    }

    /** 相对位置 → 左上角像素。分母是"可用区域 - 桌宠尺寸"，因此 ratio=1 正好贴右边/下边。 */
    fun topLeftFromRatio(
        xRatio: Float,
        yRatio: Float,
        bounds: OverlayBounds,
        petWidth: Int,
        petHeight: Int,
    ): IntArray {
        if (!bounds.isUsable) return intArrayOf(bounds.left, bounds.top)
        val availableX = (bounds.width - petWidth).coerceAtLeast(0)
        val availableY = (bounds.height - petHeight).coerceAtLeast(0)
        val x = bounds.left + (xRatio.coerceIn(0f, 1f) * availableX).roundToInt()
        val y = bounds.top + (yRatio.coerceIn(0f, 1f) * availableY).roundToInt()
        return clampTopLeft(x, y, bounds, petWidth, petHeight)
    }

    /** 左上角像素 → 相对位置（需求 2.4 的公式，分母保证不为 0）。 */
    fun ratioFromTopLeft(
        x: Int,
        y: Int,
        bounds: OverlayBounds,
        petWidth: Int,
        petHeight: Int,
    ): FloatArray {
        if (!bounds.isUsable) return floatArrayOf(0f, 0f)
        val availableX = max(1, bounds.width - petWidth)
        val availableY = max(1, bounds.height - petHeight)
        val rx = (x - bounds.left).toFloat() / availableX
        val ry = (y - bounds.top).toFloat() / availableY
        return floatArrayOf(rx.coerceIn(0f, 1f), ry.coerceIn(0f, 1f))
    }

    /** 按桌宠**中心点**落在左半还是右半决定吸附边（需求 2.3）。 */
    fun snapEdgeFor(centerX: Int, bounds: OverlayBounds): OverlaySnapEdge {
        if (!bounds.isUsable) return OverlaySnapEdge.none
        return if (centerX < bounds.left + bounds.width / 2) {
            OverlaySnapEdge.left
        } else {
            OverlaySnapEdge.right
        }
    }

    /** 吸附目标左上角 X。 */
    fun snapTargetX(edge: OverlaySnapEdge, bounds: OverlayBounds, petWidth: Int): Int {
        if (!bounds.isUsable) return bounds.left
        return when (edge) {
            OverlaySnapEdge.left -> bounds.left
            OverlaySnapEdge.right ->
                bounds.left + (bounds.width - petWidth).coerceAtLeast(0)
            OverlaySnapEdge.none -> bounds.left
        }
    }

    /** 桌宠中心点 X（吸附判定与日志用）。 */
    fun centerX(x: Int, petWidth: Int): Int = x + petWidth / 2
}

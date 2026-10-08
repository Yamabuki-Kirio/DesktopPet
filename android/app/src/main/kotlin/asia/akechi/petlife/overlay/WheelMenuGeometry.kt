package asia.akechi.petlife.overlay

import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sin

/** 轮盘展开方向（需求 §4）。 */
internal enum class WheelExpandDirection(val sign: Int) {
    right(1),
    left(-1);

    val labelZh: String get() = if (this == right) "右" else "左"

    fun opposite(): WheelExpandDirection = if (this == right) left else right
}

/** 靠边时扇形的额外偏转（正 = 向视觉下方偏）。 */
private const val EDGE_FAN_BIAS_DEG = 26f

/**
 * 垂直布局模式（Phase 4C-6B-1.1，需求 §8）。
 *
 * 关键约束：**不允许为了让轮盘塞进屏幕而直接平移轮盘中心** ——
 * 那会让中央缺口与桌宠错位（真机反馈问题 6 的根因）。
 * 正确的做法是改变**扇形朝向**（`fanBiasDeg`）并降低实际缩放。
 */
internal enum class WheelVerticalMode(val biasDeg: Float) {
    center(0f),
    topEdge(EDGE_FAN_BIAS_DEG),
    bottomEdge(-EDGE_FAN_BIAS_DEG);

    val labelZh: String get() = when (this) {
        center -> "居中"
        topEdge -> "靠上"
        bottomEdge -> "靠下"
    }
}

/**
 * 轮盘布局设置（Phase 4C-6B-1.1，需求 §5）。
 *
 * **与主题分开**：主题管颜色，这里管几何 —— 两者的演进线与 revision 互不干扰。
 */
internal data class WheelMenuLayoutSettings(
    /** 用户期望的轮盘大小（0.60 ~ 1.20）。 */
    val preferredScale: Float = DEFAULT_SCALE,
    /** 菜单偏离桌宠可见宽度的比例（仅用于让脸部与标题错开）。 */
    val menuDistance: Float = DEFAULT_DISTANCE,
    /** 按钮视觉缩放的额外倍率（1.0 = 跟随轮盘缩放）。 */
    val buttonVisualScale: Float = 1f,
    /** 紧凑模式：由布局求解器在空间不足时置位，也可由用户强制开启。 */
    val compactMode: Boolean = false,
    val revision: Long = 0L,
) {
    fun normalized(): WheelMenuLayoutSettings = copy(
        preferredScale = clampScale(preferredScale),
        menuDistance = clampDistance(menuDistance),
        buttonVisualScale = buttonVisualScale.coerceIn(MIN_BUTTON_SCALE, MAX_BUTTON_SCALE),
    )

    companion object {
        /** 轮盘大小：50%~250%，步进 10%，默认 100%（需求 §4）。 */
        const val MIN_SCALE = 0.50f
        const val MAX_SCALE = 2.50f
        const val STEP = 0.10f
        const val DEFAULT_SCALE = 1.00f

        const val MIN_DISTANCE = 0.05f
        const val MAX_DISTANCE = 0.30f
        const val DEFAULT_DISTANCE = 0.16f

        /** 按钮大小：50%~250%，步进 10%，默认 130%（需求 §5）。 */
        const val MIN_BUTTON_SCALE = 0.50f
        const val MAX_BUTTON_SCALE = 2.50f
        const val BUTTON_STEP = 0.10f
        const val DEFAULT_BUTTON_SCALE = 1.30f

        /** 按钮触摸直径下界（需求 §5：无论视觉多小，触摸范围不低于 48dp）。 */
        const val BUTTON_TOUCH_MIN_DP = 48f

        fun clampScale(value: Float): Float =
            if (!value.isFinite()) DEFAULT_SCALE else value.coerceIn(MIN_SCALE, MAX_SCALE)

        fun clampButtonScale(value: Float): Float =
            if (!value.isFinite()) DEFAULT_BUTTON_SCALE
            else value.coerceIn(MIN_BUTTON_SCALE, MAX_BUTTON_SCALE)

        fun clampDistance(value: Float): Float =
            if (!value.isFinite()) DEFAULT_DISTANCE else value.coerceIn(MIN_DISTANCE, MAX_DISTANCE)

        /** 把任意比例吸附到 10% 的步进（滑块的取值口径）。 */
        fun quantizeScale(value: Float): Float {
            val steps = (clampScale(value) / STEP).roundToInt()
            return clampScale(steps * STEP)
        }

        /** 按钮大小同样吸附到 10% 步进（需求 §5：步长 0.1）。 */
        fun quantizeButtonScale(value: Float): Float {
            val steps = (clampButtonScale(value) / BUTTON_STEP).roundToInt()
            return clampButtonScale(steps * BUTTON_STEP)
        }

        val DEFAULT = WheelMenuLayoutSettings()
    }
}

/** 密度换算后的轮盘尺寸参数（集中一处，避免魔法数字散落）。 */
internal data class WheelMenuSpec(
    val buttonDiameterPx: Float,
    val compactButtonDiameterPx: Float,
    val buttonGapPx: Float,
    val bandPaddingPx: Float,
    val rimLobePx: Float,
    val outlinePx: Float,
    val density: Float,
    /** 缺少用户设置时的默认菜单偏移比例。 */
    val offsetRatio: Float,
) {
    /**
     * 按钮可见直径（随**实际缩放**变化）。
     *
     * ⚠️ **按钮大小设置不在这里**：唯一来源是 `WheelMenuLayoutSettings.buttonVisualScale`，
     * 由 [intrinsicLayout] 乘进去。曾经这里也存一份，结果设置改了却不生效（两份来源打架）。
     */
    fun buttonDiameterFor(itemCount: Int, scale: Float = 1f): Float {
        val base = if (itemCount >= 7) compactButtonDiameterPx else buttonDiameterPx
        // 缩放上限放宽到 4.0：轮盘(≤2.5) × 按钮(≤2.5) 的乘积最大 6.25，但两者同时拉满时
        // 由"相邻按钮不重叠"的环带半径兜底，这里只防止算出荒谬值。
        return base * scale.coerceIn(0.20f, 4.0f)
    }

    fun dp(value: Float): Float = value * density

    /** 描边宽度：随缩放变化，但有上下限（需求 §6）。 */
    fun outlineWidthFor(basePx: Float, scaled: Float): Float =
        (basePx * max(scaled, MIN_OUTLINE_SCALE))
            .coerceIn(MIN_OUTLINE_DP * density, MAX_OUTLINE_DP * density)

    companion object {
        const val BUTTON_DIAMETER_DP = 44f
        const val BUTTON_DIAMETER_COMPACT_DP = 40f
        const val BUTTON_GAP_DP = 6f
        const val BAND_PADDING_DP = 8f
        const val RIM_LOBE_DP = 7f
        /** 描边基准宽度（需求 §10.2：**收细**，避免黑圈糊住字）。 */
        const val OUTLINE_DP = 2.2f
        const val DEFAULT_OFFSET_RATIO = WheelMenuLayoutSettings.DEFAULT_DISTANCE

        const val MIN_OUTLINE_DP = 1.2f
        const val MAX_OUTLINE_DP = 4.5f
        const val MIN_OUTLINE_SCALE = 0.72f

        fun fromDensity(density: Float): WheelMenuSpec {
            val d = OverlayGeometry.safeDensity(density)
            return WheelMenuSpec(
                buttonDiameterPx = BUTTON_DIAMETER_DP * d,
                compactButtonDiameterPx = BUTTON_DIAMETER_COMPACT_DP * d,
                buttonGapPx = BUTTON_GAP_DP * d,
                bandPaddingPx = BAND_PADDING_DP * d,
                rimLobePx = RIM_LOBE_DP * d,
                outlinePx = OUTLINE_DP * d,
                density = d,
                offsetRatio = DEFAULT_OFFSET_RATIO,
            )
        }
    }
}

/** 一个按钮槽位的落位结果（坐标统一为**菜单窗口内相对坐标**）。 */
internal data class WheelSlotPlacement(
    val index: Int,
    val entry: WheelMenuEntry,
    val offsetAngleDeg: Float,
    val absoluteAngleDeg: Float,
    val centerX: Float,
    val centerY: Float,
)

/**
 * 菜单窗口的"信封"（Phase 4C-6B-1.1）。
 *
 * 三条不变量（需求 §1）：
 * 1. **[petAnchorX] / [petAnchorY] 是桌宠视觉锚点，轮盘缺口永远绑在它上面**；
 * 2. `distance(轮盘中心, 桌宠锚点) = |off| ≤ allowedVisualOffset`（只用于错开脸部与标题）；
 * 3. [windowRect] **一次性**算出，打开期间不变（需求 §14 沿用）。
 *
 * 与 4C-6B-1 的关键差异：**不再要求窗口避开桌宠抓取区**。
 * 现在允许菜单窗口与桌宠窗口重叠，重叠区由**层级更高**的桌宠窗口负责显示与拖动，
 * 中央缺口因此天然"透出桌宠"（需求 §2）。
 */
internal data class WheelMenuEnvelope(
    val direction: WheelExpandDirection,
    val verticalMode: WheelVerticalMode,
    val windowRect: OverlayRect,
    /** 轮盘中心（屏幕绝对坐标）。 */
    val centerX: Int,
    val centerY: Int,
    /** 桌宠**视觉**锚点（屏幕绝对坐标）——中央缺口必须绑在它上面。 */
    val petAnchorX: Int,
    val petAnchorY: Int,
    /** 中央缺口椭圆半径（相对**桌宠锚点**）。 */
    val holeRx: Float,
    val holeRy: Float,
    /** 允许的视觉偏移上限（缺口与桌宠锚点的最大允许偏心）。 */
    val allowedOffsetPx: Float,
    val maxRingRadiusPx: Float,
    val buttonDiameterPx: Float,
    /** 触摸直径：视觉可能很小，但触摸范围不低于 48dp（需求 §5）。 */
    val buttonTouchDiameterPx: Float,
    /** 扇形偏转角（正 = 向视觉下方偏）。 */
    val fanBiasDeg: Float,
    /** 用户期望的缩放与最终生效的缩放。 */
    val preferredScale: Float,
    val actualScale: Float,
    val compact: Boolean,
    val degraded: Boolean,
    val fallbackReason: String?,
) {
    val widthPx: Int get() = windowRect.width
    val heightPx: Int get() = windowRect.height

    /** 缺口锚点与桌宠锚点的实际距离（诊断用；恒应 ≤ [allowedOffsetPx]）。 */
    val anchorDistancePx: Float
        get() = hypot((centerX - petAnchorX).toDouble(), (centerY - petAnchorY).toDouble()).toFloat()
}

/**
 * 轮盘几何结果（需求 §3 / §4）。
 *
 * [windowRect] 是菜单窗口的**屏幕绝对矩形**；其余坐标都是窗口内相对坐标。
 */
internal data class WheelMenuLayout(
    val direction: WheelExpandDirection,
    val verticalMode: WheelVerticalMode,
    val itemCount: Int,
    val windowRect: OverlayRect,
    val centerX: Float,
    val centerY: Float,
    val ringRadiusPx: Float,
    val bandOuterPx: Float,
    /**
     * 中央缺口椭圆：中心（窗口内坐标，**恒等于桌宠锚点**）与两个半径。
     *
     * 它是"轮盘围绕桌宠"这条不变量的落点：轮盘中心可以比桌宠锚点偏一点，
     * 缺口却**永远**压在桌宠锚点上。
     */
    val notchCenterX: Float,
    val notchCenterY: Float,
    val notchRx: Float,
    val notchRy: Float,
    val bladeLengthPx: Float,
    val bladeHalfSweepDeg: Float,
    val stepDeg: Float,
    val fanHalfSpanDeg: Float,
    val fanBiasDeg: Float,
    val buttonDiameterPx: Float,
    /**
     * 按钮的**触摸直径**（需求 §5）：视觉可能缩到很小，但触摸范围不低于 48dp。
     *
     * 实际命中走"角度 + 整条环带"，比这个直径更宽松；它在这里是为了让"最小可点尺寸"
     * 成为可断言的几何量，而不是一句口头承诺。
     */
    val buttonTouchDiameterPx: Float,
    val outlineWidthPx: Float,
    val rimLobePx: Float,
    val slots: List<WheelSlotPlacement>,
    val actualScale: Float,
    val compact: Boolean,
    val degraded: Boolean,
) {
    val rimOuterPx: Float get() = bandOuterPx + rimLobePx

    fun absoluteAngleFor(index: Int): Float =
        slots.firstOrNull { it.index == index }?.absoluteAngleDeg ?: baseAngle()

    private fun baseAngle(): Float =
        if (direction == WheelExpandDirection.right) 0f else 180f
}

/**
 * 参数化几何（**纯函数**，不碰 WindowManager / View）。
 *
 * 两段式 API：
 * * [computeEnvelope] —— 打开时按**最大条目数**与当前设置算一次信封（窗口 + 锚点 + 缺口）；
 * * [layoutFor] —— 每次层级 / 选中变化时在同一个信封里重算内部几何（**不碰窗口**）。
 *
 * 求解顺序（需求 §9）：
 * 1. 由素材视觉边界算桌宠锚点；2. 绑定缺口；3. 判左右；4. 判垂直模式；
 * 5. 用 preferredScale 试布局；6. 算水平/垂直可用空间；7. 降到 actualScale；
 * 8. 低于下限则紧凑模式；9. 收窄弧线；10. 减少装饰；11. 最后才允许小范围整体偏移。
 */
internal object WheelMenuGeometry {

    /** 角度间隔的下界（紧凑模式更窄）。 */
    const val MIN_STEP_DEG = 16f

    /** 角度间隔的上界。 */
    const val MAX_STEP_DEG = 30f

    /** 扇形半张角的上界（普通 / 紧凑）。 */
    const val MAX_HALF_SPAN_DEG = 68f
    const val COMPACT_HALF_SPAN_DEG = 50f

    /** 紧凑模式下扇形半张角的下限（再窄就要靠紧凑模式承担了）。 */
    const val MIN_HALF_SPAN_DEG = 38f

    /** 高亮扇区的半张角。 */
    const val BLADE_HALF_SWEEP_DEG = 30f

    private const val BLADE_EXTENT_RATIO = 0.42f
    const val BLADE_EXTENT_MIN_DP = 40f
    const val BLADE_EXTENT_MAX_DP = 88f

    /** 半径的绝对下界。 */
    const val MIN_RADIUS_DP = 62f

    /** 缺口相对桌宠可见尺寸的比例（需求 §3）。 */
    const val HOLE_WIDTH_RATIO = 1.05f
    const val HOLE_HEIGHT_RATIO = 1.05f

    /** 缺口相对桌宠可见尺寸的额外边距（dp，需求 §4 建议 8~16dp）。 */
    const val NOTCH_PADDING_DP = 10f

    /**
     * 缺口相对"按钮轨道内径"的上限比例（需求 §4）。
     *
     * 这是**防止异常素材把轮盘撑坏**的兜底：缺口绝不能接近按钮内缘，
     * 否则轮盘会退化成一个粗甜甜圈（4C-6B-1.2 首版的真机回归）。
     */
    const val NOTCH_MAX_INNER_DIAMETER_RATIO = 0.88f

    /** 缺口与按钮之间必须保留的净空。 */
    private const val HOLE_MARGIN_DP = 4f

    /** 窗口相对绘制内容的额外安全边距（描边 / 阴影 / 抗锯齿 overshoot，需求 §5.1）。 */
    const val SAFETY_PADDING_DP = 10f

    /** 实际缩放的下限（需求 §9：低于它不得继续缩小，改用紧凑几何）。 */
    const val MIN_ACTUAL_SCALE = 0.60f

    /** 垂直模式滞回（相对安全区域高度的比例）。 */
    private const val VERTICAL_HYSTERESIS = 0.06f

    /** 方向滞回。 */
    private const val DIRECTION_HYSTERESIS = 0.08f

    /** 窗口相对安全区域的建议上限（超出即触发紧凑模式，需求 §7）。 */
    private const val MAX_WINDOW_WIDTH_RATIO = 0.65f
    private const val MAX_WINDOW_HEIGHT_RATIO = 0.70f
    private const val MAX_WINDOW_WIDTH_RATIO_COMPACT = 0.55f
    private const val MAX_WINDOW_HEIGHT_RATIO_COMPACT = 0.60f

    /** 桌宠可见边界不可信时的兜底比例（按窗口尺寸折算）。 */
    private const val FALLBACK_VISIBLE_RATIO = 0.86f

    // ------------------------------------------------------------------
    // 方向与垂直模式
    // ------------------------------------------------------------------

    fun decideDirection(
        petRect: OverlayRect,
        bounds: OverlayBounds,
        previousDirection: WheelExpandDirection?,
        locked: Boolean,
    ): WheelExpandDirection {
        if (locked && previousDirection != null) return previousDirection
        if (!bounds.isUsable || !petRect.isUsable) return WheelExpandDirection.right
        val leftSpace = petRect.centerX - bounds.left
        val rightSpace = bounds.right - petRect.centerX
        val natural =
            if (rightSpace >= leftSpace) WheelExpandDirection.right else WheelExpandDirection.left
        val previous = previousDirection ?: return natural
        val deadZone = (bounds.width * DIRECTION_HYSTERESIS).roundToInt()
        val mid = bounds.left + bounds.width / 2
        return when (previous) {
            WheelExpandDirection.right ->
                if (petRect.centerX <= mid + deadZone) previous else WheelExpandDirection.left
            WheelExpandDirection.left ->
                if (petRect.centerX >= mid - deadZone) previous else WheelExpandDirection.right
        }
    }

    /**
     * 垂直模式（需求 §8）：比较桌宠上下可用空间，并带**滞回区**避免阈值附近反复切换。
     */
    fun decideVerticalMode(
        petVisible: OverlayRect,
        bounds: OverlayBounds,
        previous: WheelVerticalMode?,
        locked: Boolean,
    ): WheelVerticalMode {
        if (locked && previous != null) return previous
        if (!bounds.isUsable || !petVisible.isUsable) return WheelVerticalMode.center
        val above = petVisible.centerY - bounds.top
        val below = bounds.bottom - petVisible.centerY
        val natural = when {
            above < below * 0.55f -> WheelVerticalMode.topEdge
            below < above * 0.55f -> WheelVerticalMode.bottomEdge
            else -> WheelVerticalMode.center
        }
        val prev = previous ?: return natural
        val deadZone = (bounds.height * VERTICAL_HYSTERESIS).roundToInt()
        // 滞回：只有真的越过阈值才允许切换，否则保持上一次模式。
        return when (prev) {
            WheelVerticalMode.center ->
                if (natural == WheelVerticalMode.center) prev
                else if (abs(above - below) > deadZone) natural else prev
            WheelVerticalMode.topEdge ->
                if (above > deadZone * 2) natural else prev
            WheelVerticalMode.bottomEdge ->
                if (below > deadZone * 2) natural else prev
        }
    }

    // ------------------------------------------------------------------
    // 桌宠可见边界
    // ------------------------------------------------------------------

    /**
     * 桌宠的**视觉**矩形（屏幕绝对坐标）。
     *
     * 素材带透明留白时按比例裁掉，避免缺口被撑得远大于人物（需求 §3）。
     */
    fun petVisibleRect(
        petWindowRect: OverlayRect,
        content: PetContentBounds?,
    ): OverlayRect {
        if (!petWindowRect.isUsable) return petWindowRect
        val bounds = content ?: PetContentBounds.FULL
        val rect = PetContentBounds.toScreenRect(petWindowRect, bounds)
        if (!rect.isUsable) return petWindowRect
        // 视觉边界异常小（素材几乎全透明）时回退到窗口的固定比例，避免缺口退化。
        val fallbackWidth = (petWindowRect.width * FALLBACK_VISIBLE_RATIO).roundToInt()
        val fallbackHeight = (petWindowRect.height * FALLBACK_VISIBLE_RATIO).roundToInt()
        val safeWidth = max(rect.width, min(fallbackWidth, petWindowRect.width))
        val safeHeight = max(rect.height, min(fallbackHeight, petWindowRect.height))
        if (safeWidth == rect.width && safeHeight == rect.height) return rect
        val cx = rect.centerX
        val cy = rect.centerY
        val left = (cx - safeWidth / 2f).roundToInt().coerceIn(petWindowRect.left, petWindowRect.right)
        val top = (cy - safeHeight / 2f).roundToInt().coerceIn(petWindowRect.top, petWindowRect.bottom)
        return OverlayRect(left, top, left + safeWidth, top + safeHeight)
    }

    /**
     * 桌宠的**抓取区**（中心正方形）—— 仍然用于"拖动桌宠"的命中判定，
     * 但**不再是菜单窗口的硬约束**（4C-6B-1.1 起允许两窗口重叠）。
     */
    fun petGrabRect(petRect: OverlayRect): OverlayRect {
        val side = max(48, (min(petRect.width, petRect.height) * 0.5f).roundToInt())
        return OverlayRect.centered(petRect.centerX, petRect.centerY, side)
    }

    // ------------------------------------------------------------------
    // 信封
    // ------------------------------------------------------------------

    fun computeEnvelope(
        bounds: OverlayBounds,
        petWindowRect: OverlayRect,
        content: PetContentBounds?,
        maxItemCount: Int,
        spec: WheelMenuSpec,
        settings: WheelMenuLayoutSettings,
        previousDirection: WheelExpandDirection? = null,
        previousVerticalMode: WheelVerticalMode? = null,
        lockMode: Boolean = false,
    ): WheelMenuEnvelope {
        val normalized = settings.normalized()
        val visible = petVisibleRect(petWindowRect, content)
        val count = max(1, maxItemCount)
        val direction = decideDirection(visible, bounds, previousDirection, lockMode)
        val vertical = decideVerticalMode(visible, bounds, previousVerticalMode, lockMode)
        val anchorX = visible.centerX
        val anchorY = visible.centerY
        val allowedOffset = (visible.width * normalized.menuDistance)
            .coerceAtLeast(spec.dp(HOLE_MARGIN_DP))
        val offset = allowedOffset

        if (!bounds.isUsable || !visible.isUsable) {
            return degenerateEnvelope(
                bounds, visible, direction, vertical, 0f, 0f, allowedOffset, normalized, spec,
            )
        }

        // 1) **固有几何**：只看设置与桌宠尺寸，与位置/剩余空间无关（需求 §3.1）。
        val intrinsic = intrinsicLayout(
            itemCount = count,
            spec = spec,
            settings = normalized,
            petVisibleWidth = visible.width.toFloat(),
            petVisibleHeight = visible.height.toFloat(),
        )
        // 2) **设备级应急缩放**：只由"屏幕 + 固有尺寸"决定，同一屏幕方向下是常量，
        //    **不随桌宠位置变化**（需求 §3.2）。只有整屏都放不下时才会 < 1。
        //    注意：用户把轮盘调**大**时**一律不缩回**（需求 §4）——
        //    放不下就裁外围装饰（degraded），绝不偷偷改用户选的大小。
        val deviceScale = if (normalized.preferredScale > WheelMenuLayoutSettings.DEFAULT_SCALE) {
            1f
        } else {
            deviceEmergencyScale(bounds, intrinsic)
        }
        // 3) **放置**：只选方向、平移窗口、必要时裁装饰 —— 不改任何尺寸（需求 §3.1）。
        val plan = plan(
            bounds = bounds,
            direction = direction,
            vertical = vertical,
            anchorX = anchorX,
            anchorY = anchorY,
            intrinsic = intrinsic,
            offset = offset,
            scale = deviceScale,
            spec = spec,
        ) ?: forcedPlan(
            bounds = bounds,
            intrinsic = intrinsic,
            direction = direction,
            vertical = vertical,
            anchorX = anchorX,
            anchorY = anchorY,
            offset = offset,
            spec = spec,
        )
        val degraded = !plan.fits
        return plan.toEnvelope(
            normalized,
            degraded = degraded,
            reason = if (degraded) "window-clamped" else null,
        )
    }

    /**
     * 轮盘**固有几何**（需求 §3.1）。
     *
     * 输入里**没有**桌宠坐标、没有左右剩余空间、没有离边缘距离 ——
     * 只有设置、条目数与桌宠的**可见尺寸**（尺寸随位置不变，因此轮盘大小恒定）。
     */
    fun intrinsicLayout(
        itemCount: Int,
        spec: WheelMenuSpec,
        settings: WheelMenuLayoutSettings,
        petVisibleWidth: Float,
        petVisibleHeight: Float,
    ): WheelIntrinsicLayout {
        val normalized = settings.normalized()
        val count = max(1, itemCount)
        val compact = normalized.compactMode
        val halfSpan = halfSpanFor(count, compact)
        val step = stepDegFor(count, halfSpan)
        val effectiveScale = normalized.preferredScale *
            if (compact) COMPACT_BUTTON_SHRINK else 1f
        // 按钮大小设置的**唯一落点**（需求 §4.3）。
        val buttonDiameter = spec.buttonDiameterFor(
            count,
            effectiveScale * normalized.buttonVisualScale,
        )
        val buttonRadius = buttonDiameter / 2f
        val padding = spec.dp(NOTCH_PADDING_DP)
        // 【需求 §4】缺口由**桌宠可见尺寸**决定（含边距），不再"贴按钮轨道"。
        // 这里保留**未夹取**的原始值：缺口必须始终盖住桌宠，绝不因为缩放而变小。
        val notchRxRaw = petVisibleWidth * HOLE_WIDTH_RATIO / 2f + padding
        val notchRyRaw = petVisibleHeight * HOLE_HEIGHT_RATIO / 2f + padding
        // 缺口必须放得下：按钮轨道内径要够 —— 不够时**扩大轮盘**，
        // 而不是把缺口撑到按钮边缘（那会把轮盘变成粗甜甜圈，4C-6B-1.2 首版的真机回归）。
        val minRadiusForNotch = max(notchRxRaw, notchRyRaw) / NOTCH_MAX_INNER_DIAMETER_RATIO +
            buttonRadius
        val spacing = spacingRadiusPx(count, step, buttonDiameter, spec)
        val margin = spec.dp(HOLE_MARGIN_DP)
        val clearance = hypot(petVisibleWidth / 2.0, petVisibleHeight / 2.0).toFloat() +
            petVisibleWidth * normalized.menuDistance + buttonRadius + margin
        val ringRadius = max(max(spacing, minRadiusForNotch), max(clearance, spec.dp(MIN_RADIUS_DP)))
        val bandOuter = ringRadius + buttonRadius + spec.bandPaddingPx
        val rimOuter = bandOuter + spec.rimLobePx
        val bladeExtent = (BLADE_EXTENT_RATIO * ringRadius)
            .coerceIn(spec.dp(BLADE_EXTENT_MIN_DP), spec.dp(BLADE_EXTENT_MAX_DP))
        // 刀刃伸长跟随用户设置的轮盘比例 —— 口径必须与设置在**同一区间**（0.50~2.50），
        // 否则 1.20 以上/0.60 以下的设置会被静默夹回旧范围，看起来"调大了没反应"。
        val bladeLength = rimOuter + bladeExtent * normalized.preferredScale.coerceIn(
            WheelMenuLayoutSettings.MIN_SCALE,
            WheelMenuLayoutSettings.MAX_SCALE,
        )

        // 绘制包围盒的半宽/半高（**相对轮盘中心**，用于设备级应急缩放）。
        // 必须是"扇形 + 刀刃"的真实包络，而不是正方形 ——
        // 用正方形会把正常手机误判成"放不下"，进而把整个轮盘（含缺口）缩小。
        // 取垂直模式偏转的**最坏情况**，保证与桌宠位置/上下边缘无关。
        val reachDeg = halfSpan + BLADE_HALF_SWEEP_DEG + kotlin.math.abs(EDGE_FAN_BIAS_DEG)
        val outward = max(bladeLength, rimOuter)
        val inwardFactor = if (reachDeg > 90f) {
            (-cos(Math.toRadians(min(180f, reachDeg).toDouble()))).toFloat()
        } else {
            0f
        }
        val safety = spec.dp(SAFETY_PADDING_DP)
        val halfW = (outward + outward * inwardFactor) / 2f + safety
        val halfH = outward * (sin(Math.toRadians(min(90f, reachDeg).toDouble()))).toFloat() + safety
        return WheelIntrinsicLayout(
            itemCount = count,
            ringRadiusPx = ringRadius,
            buttonDiameterPx = buttonDiameter,
            bandOuterPx = bandOuter,
            rimOuterPx = rimOuter,
            bladeLengthPx = bladeLength,
            bladeHalfSweepDeg = BLADE_HALF_SWEEP_DEG,
            stepDeg = step,
            fanHalfSpanDeg = halfSpan,
            outlineWidthPx = spec.outlineWidthFor(spec.outlinePx, normalized.preferredScale),
            rimLobePx = spec.rimLobePx,
            compact = compact,
            notchRx = notchRxRaw,
            notchRy = notchRyRaw,
            halfWidthPx = halfW,
            halfHeightPx = halfH,
        )
    }

    /**
     * 设备级应急缩放（需求 §3.2）。
     *
     * 只在"整块屏幕在任何方向都放不下这个固定尺寸的轮盘"时才 < 1；
     * 输入只有安全区域与固有尺寸，**与桌宠位置无关**，因此同一屏幕方向下是常量。
     */
    fun deviceEmergencyScale(bounds: OverlayBounds, intrinsic: WheelIntrinsicLayout): Float {
        if (!bounds.isUsable) return MIN_ACTUAL_SCALE
        val needW = intrinsic.halfWidthPx * 2f
        val needH = intrinsic.halfHeightPx * 2f
        if (needW <= 0f || needH <= 0f) return 1f
        val byWidth = bounds.width / needW
        val byHeight = bounds.height / needH
        return min(1f, min(byWidth, byHeight)).coerceAtLeast(MIN_ACTUAL_SCALE)
    }

    /**
     * 某一层级在既定信封内的实际几何（**只读信封，绝不改窗口**）。
     */
    fun layoutFor(
        envelope: WheelMenuEnvelope,
        level: WheelMenuLevel,
        spec: WheelMenuSpec,
    ): WheelMenuLayout {
        val count = max(1, level.itemCount)
        val compact = envelope.compact
        val halfSpan = halfSpanFor(count, compact)
        val step = stepDegFor(count, halfSpan)
        val radius = envelope.maxRingRadiusPx
        val button = envelope.buttonDiameterPx
        val bandOuter = radius + button / 2f + spec.bandPaddingPx
        val rimOuter = bandOuter + spec.rimLobePx
        val bladeExtent = (BLADE_EXTENT_RATIO * radius)
            .coerceIn(spec.dp(BLADE_EXTENT_MIN_DP), spec.dp(BLADE_EXTENT_MAX_DP))
        val bladeLength = rimOuter + bladeExtent * envelope.actualScale.coerceIn(0.6f, 1.2f)

        val window = envelope.windowRect
        val cx = envelope.centerX - window.left.toFloat()
        val cy = envelope.centerY - window.top.toFloat()
        // 缺口中心 = 桌宠视觉锚点（窗口坐标系）—— 这条是"轮盘围绕桌宠"的核心不变量。
        val notchCx = envelope.petAnchorX - window.left.toFloat()
        val notchCy = envelope.petAnchorY - window.top.toFloat()
        val half = (count - 1) / 2f
        val slots = level.entries.mapIndexed { index, entry ->
            val offsetAngle = (index - half) * step
            val absolute = absoluteAngle(envelope.direction, offsetAngle + envelope.fanBiasDeg)
            val rad = Math.toRadians(absolute.toDouble())
            WheelSlotPlacement(
                index = index,
                entry = entry,
                offsetAngleDeg = offsetAngle,
                absoluteAngleDeg = normalizeAngle(absolute),
                centerX = cx + (radius * cos(rad)).toFloat(),
                centerY = cy + (radius * sin(rad)).toFloat(),
            )
        }
        return WheelMenuLayout(
            direction = envelope.direction,
            verticalMode = envelope.verticalMode,
            itemCount = count,
            windowRect = window,
            centerX = cx,
            centerY = cy,
            ringRadiusPx = radius,
            bandOuterPx = bandOuter,
            notchCenterX = notchCx,
            notchCenterY = notchCy,
            notchRx = envelope.holeRx,
            notchRy = envelope.holeRy,
            bladeLengthPx = bladeLength,
            bladeHalfSweepDeg = BLADE_HALF_SWEEP_DEG,
            stepDeg = step,
            fanHalfSpanDeg = halfSpan,
            fanBiasDeg = envelope.fanBiasDeg,
            buttonDiameterPx = button,
            buttonTouchDiameterPx = max(button, spec.dp(WheelMenuLayoutSettings.BUTTON_TOUCH_MIN_DP)),
            outlineWidthPx = spec.outlineWidthFor(spec.outlinePx, envelope.actualScale),
            rimLobePx = spec.rimLobePx,
            slots = slots,
            actualScale = envelope.actualScale,
            compact = compact,
            degraded = envelope.degraded,
        )
    }

    /** 相邻按钮的角度间隔。 */
    fun stepDegFor(itemCount: Int, halfSpanDeg: Float = MAX_HALF_SPAN_DEG): Float {
        if (itemCount <= 1) return 0f
        val raw = halfSpanDeg * 2f / (itemCount - 1)
        return raw.coerceIn(MIN_STEP_DEG, MAX_STEP_DEG)
    }

    /** 扇形半张角（紧凑模式更窄）。 */
    fun halfSpanFor(itemCount: Int, compact: Boolean): Float {
        val base = if (compact) COMPACT_HALF_SPAN_DEG else MAX_HALF_SPAN_DEG
        if (itemCount <= 1) return 0f
        val needed = MIN_STEP_DEG * (itemCount - 1) / 2f
        return max(base, min(needed, MAX_HALF_SPAN_DEG))
    }

    /** "相邻按钮不重叠"推出的半径下界。 */
    fun spacingRadiusPx(itemCount: Int, stepDeg: Float, buttonDiameter: Float, spec: WheelMenuSpec): Float {
        if (itemCount <= 1 || stepDeg <= 0f) return 0f
        val chordUnit = 2.0 * sin(Math.toRadians(stepDeg / 2.0))
        if (chordUnit <= 0.0) return 0f
        return ((buttonDiameter + spec.buttonGapPx) / chordUnit).toFloat()
    }

    /**
     * 桌宠可见矩形到轮盘中心的**最近允许半径**。
     *
     * 按钮圆必须完全不压住桌宠（按钮被桌宠窗口盖住就点不到了），
     * 因此按"桌宠可见矩形四角到轮盘中心的最大距离 + 按钮半径 + 净空"计算。
     */
    fun petClearanceRadius(
        visible: OverlayRect,
        offset: Float,
        buttonRadius: Float,
        margin: Float,
    ): Float {
        if (!visible.isUsable) return 0f
        val cx = visible.centerX.toFloat()
        val cy = visible.centerY.toFloat()
        val corners = listOf(
            Pair(visible.left.toFloat(), visible.top.toFloat()),
            Pair(visible.right.toFloat(), visible.top.toFloat()),
            Pair(visible.left.toFloat(), visible.bottom.toFloat()),
            Pair(visible.right.toFloat(), visible.bottom.toFloat()),
        )
        val farthest = corners.maxOf { (x, y) ->
            hypot((x - cx).toDouble(), (y - cy).toDouble())
        }.toFloat()
        return farthest + offset + buttonRadius + margin
    }

    // ------------------------------------------------------------------
    // 求解器
    // ------------------------------------------------------------------

    /** 一次求解的完整结果（全部字段显式给出，避免任何"先建对象再回填"的隐患）。 */
    private data class WheelPlan(
        val direction: WheelExpandDirection,
        val verticalMode: WheelVerticalMode,
        val windowRect: OverlayRect,
        val centerX: Int,
        val centerY: Int,
        val petAnchorX: Int,
        val petAnchorY: Int,
        val holeRx: Float,
        val holeRy: Float,
        val allowedOffset: Float,
        val ringRadiusPx: Float,
        val buttonDiameterPx: Float,
        /** 触摸直径（视觉可能更小，但触摸不低于 48dp，需求 §5）。 */
        val buttonTouchDiameterPx: Float,
        val fanBiasDeg: Float,
        val scale: Float,
        val compact: Boolean,
        /** 是否能同时满足"落在安全区内"与"不超过建议占比"。 */
        val fits: Boolean,
        /** 窗口是否完整包住中央缺口（包不住就意味着缺口被裁，必须避免）。 */
        val notchInside: Boolean,
    ) {
        fun toEnvelope(
            settings: WheelMenuLayoutSettings,
            degraded: Boolean,
            reason: String?,
        ) = WheelMenuEnvelope(
            direction = direction,
            verticalMode = verticalMode,
            windowRect = windowRect,
            centerX = centerX,
            centerY = centerY,
            petAnchorX = petAnchorX,
            petAnchorY = petAnchorY,
            holeRx = holeRx,
            holeRy = holeRy,
            allowedOffsetPx = allowedOffset,
            maxRingRadiusPx = ringRadiusPx,
            buttonDiameterPx = buttonDiameterPx,
            buttonTouchDiameterPx = buttonTouchDiameterPx,
            fanBiasDeg = fanBiasDeg,
            preferredScale = settings.preferredScale,
            actualScale = scale,
            compact = compact,
            degraded = degraded,
            fallbackReason = reason,
        )
    }

    private fun plan(
        bounds: OverlayBounds,
        direction: WheelExpandDirection,
        vertical: WheelVerticalMode,
        anchorX: Int,
        anchorY: Int,
        intrinsic: WheelIntrinsicLayout,
        offset: Float,
        scale: Float,
        spec: WheelMenuSpec,
    ): WheelPlan? {
        val compact = intrinsic.compact
        val halfSpan = intrinsic.fanHalfSpanDeg
        val step = intrinsic.stepDeg
        // 尺寸全部来自**固有几何**（只乘设备级应急缩放）——放置阶段不得改尺寸。
        val buttonDiameter = intrinsic.buttonDiameterPx * scale
        val buttonRadius = buttonDiameter / 2f
        // 【需求 §4】缺口由桌宠**可见尺寸**决定，绝不"贴按钮轨道"；
        // 也**不乘应急缩放** —— 桌宠不会因为屏幕小就变小，缺口必须始终盖住它。
        val notchRx = intrinsic.notchRx
        val notchRy = intrinsic.notchRy
        // 反过来：环带必须始终"容得下"这个缺口（否则按钮会被放进洞里）。
        // 极端素材（桌宠比屏幕还大）时宁可让窗口溢出并标记 degraded，
        // 也不能让缺口吃掉按钮轨道。
        val notchHost = max(notchRx, notchRy) / NOTCH_MAX_INNER_DIAMETER_RATIO + buttonRadius
        val ringRadius = max(intrinsic.ringRadiusPx * scale, notchHost)
        val bandOuter = ringRadius + buttonRadius + spec.bandPaddingPx * scale
        val rimOuter = bandOuter + intrinsic.rimLobePx * scale
        val bladeLength = rimOuter + (intrinsic.bladeLengthPx - intrinsic.rimOuterPx) * scale
        val margin = spec.dp(HOLE_MARGIN_DP)
        val bias = vertical.biasDeg

        val centerX = when (direction) {
            WheelExpandDirection.right -> anchorX + offset
            WheelExpandDirection.left -> anchorX - offset
        }.roundToInt()
        val centerY = anchorY

        val sign = direction.sign
        val base = baseAngle(direction)
        var left = Float.MAX_VALUE
        var right = -Float.MAX_VALUE
        var top = Float.MAX_VALUE
        var bottom = -Float.MAX_VALUE

        fun include(x: Float, y: Float) {
            if (x < left) left = x
            if (x > right) right = x
            if (y < top) top = y
            if (y > bottom) bottom = y
        }

        // 环带外圈：沿扇形从一端采样到另一端（含偏转，采样步长 4° 足够覆盖包围盒）。
        var t = -halfSpan + bias
        val upper = halfSpan + bias
        while (t <= upper + 0.001f) {
            val rad = Math.toRadians((base + sign * t).toDouble())
            include(
                centerX + (rimOuter * cos(rad)).toFloat(),
                centerY + (rimOuter * sin(rad)).toFloat(),
            )
            t += 4f
        }
        // 刀刃（跟随选中槽位，端点槽位最极端）
        for (slotOffset in floatArrayOf(-halfSpan + bias, halfSpan + bias)) {
            for (delta in floatArrayOf(-BLADE_HALF_SWEEP_DEG, 0f, BLADE_HALF_SWEEP_DEG)) {
                val rad = Math.toRadians((base + sign * (slotOffset + delta)).toDouble())
                include(
                    centerX + (bladeLength * cos(rad)).toFloat(),
                    centerY + (bladeLength * sin(rad)).toFloat(),
                )
            }
        }
        // 环带 + 刀刃的包围盒：**"放不放得下"只看它**（缺口在屏幕边缘被裁是正常的、无害的）。
        val ringBladeBox = OverlayRect.of(left, top, right, bottom)

        // 中央缺口（绑在桌宠锚点上）—— 用来扩大窗口，保证缺口边界可见。
        include(anchorX - notchRx - margin, anchorY - notchRy - margin)
        include(anchorX + notchRx + margin, anchorY + notchRy + margin)
        val holeBox = OverlayRect.of(
            anchorX - notchRx - margin, anchorY - notchRy - margin,
            anchorX + notchRx + margin, anchorY + notchRy + margin,
        )

        // 【需求 §5】把**旋转后的文字 AABB** 也算进窗口包围盒 ——
        // 真机反馈"桌宠/形象/…被窗口矩形裁切"就是因为只算了环带与刀刃。
        // 文字 chip 挂在刀刃中心线上，取"最长的中文标签"作为上界，
        // 半径方向按倾斜 8° 放大（旋转只会让径向包络变大，不会变小）。
        run {
            val bandStart = ringRadius + buttonRadius + spec.dp(WheelTextLayout.TEXT_BAND_GAP_DP)
            val bandEnd = max(bladeLength, bandStart + 1f)
            val chipRadius = bandStart + (bandEnd - bandStart) * WheelTextLayout.CHIP_RADIUS_RATIO
            val chipSize = max(buttonDiameter * 0.42f, WheelTextLayout.MIN_CHIP_SP * spec.density)
            val maxChars = WheelMenuCatalog.maxLabelChars
            val chipHalfW = (maxChars * chipSize) / 2f + chipSize * 0.55f
            // 倾斜 8° 时径向包络最多膨胀到 halfW·sin8 + halfH·cos8，这里取 1.7 倍的保守系数。
            val chipHalfH = chipSize * 0.86f * 1.7f
            for (slotOffset in floatArrayOf(-halfSpan + bias, halfSpan + bias)) {
                for (delta in floatArrayOf(-BLADE_HALF_SWEEP_DEG, BLADE_HALF_SWEEP_DEG)) {
                    val rad = Math.toRadians((base + sign * (slotOffset + delta)).toDouble())
                    val cx = centerX + (chipRadius * cos(rad)).toFloat()
                    val cy = centerY + (chipRadius * sin(rad)).toFloat()
                    // 切向 = 半径法线的垂直方向
                    val tx = -sin(rad).toFloat()
                    val ty = cos(rad).toFloat()
                    val nx = cos(rad).toFloat()
                    val ny = sin(rad).toFloat()
                    for (sw in floatArrayOf(-1f, 1f)) {
                        for (sh in floatArrayOf(-1f, 1f)) {
                            include(
                                cx + tx * chipHalfW * sw + nx * chipHalfH * sh,
                                cy + ty * chipHalfW * sw + ny * chipHalfH * sh,
                            )
                        }
                    }
                }
            }
        }

        // 【需求 §5.1】再留一圈安全边距（描边、阴影、抗锯齿 overshoot）。
        val safety = spec.dp(SAFETY_PADDING_DP)
        val rawWindow = OverlayRect.of(left - safety, top - safety, right + safety, bottom + safety)
        if (!rawWindow.isUsable || !ringBladeBox.isUsable) return null
        val window = clampIntoBounds(rawWindow, bounds)
        val notchInside = window.left <= holeBox.left && window.right >= holeBox.right &&
            window.top <= holeBox.top && window.bottom >= holeBox.bottom
        val widthLimit = bounds.width * if (compact) MAX_WINDOW_WIDTH_RATIO_COMPACT else MAX_WINDOW_WIDTH_RATIO
        val heightLimit = bounds.height * if (compact) MAX_WINDOW_HEIGHT_RATIO_COMPACT else MAX_WINDOW_HEIGHT_RATIO
        val fits = ringBladeBox.isInside(bounds) &&
            ringBladeBox.width <= widthLimit && ringBladeBox.height <= heightLimit

        return WheelPlan(
            direction = direction,
            verticalMode = vertical,
            windowRect = window,
            centerX = centerX,
            centerY = centerY,
            petAnchorX = anchorX,
            petAnchorY = anchorY,
            holeRx = notchRx,
            holeRy = notchRy,
            allowedOffset = offset,
            ringRadiusPx = ringRadius,
            buttonDiameterPx = buttonDiameter,
            buttonTouchDiameterPx = max(
                buttonDiameter,
                spec.dp(WheelMenuLayoutSettings.BUTTON_TOUCH_MIN_DP),
            ),
            fanBiasDeg = bias,
            scale = scale,
            compact = compact,
            fits = fits,
            notchInside = notchInside,
        )
    }

    /**
     * 兜底方案（安全区极端狭窄）：**优先保住"缺口仍绑在桌宠上"**，
     * 外圈装饰允许被窗口裁掉，并如实标记 degraded。
     */
    /**
     * 兜底放置（安全区极端狭窄）：**尺寸仍然不变**，只是把窗口夹进安全区
     * （允许裁掉外圈装饰），并如实标记 degraded。
     */
    private fun forcedPlan(
        bounds: OverlayBounds,
        intrinsic: WheelIntrinsicLayout,
        direction: WheelExpandDirection,
        vertical: WheelVerticalMode,
        anchorX: Int,
        anchorY: Int,
        offset: Float,
        spec: WheelMenuSpec,
    ): WheelPlan {
        val centerX = when (direction) {
            WheelExpandDirection.right -> anchorX + offset
            WheelExpandDirection.left -> anchorX - offset
        }.roundToInt()
        val raw = OverlayRect.of(
            anchorX - intrinsic.notchRx, anchorY - intrinsic.halfHeightPx,
            centerX + intrinsic.halfWidthPx, anchorY + intrinsic.halfHeightPx,
        )
        return WheelPlan(
            direction = direction,
            verticalMode = vertical,
            windowRect = clampIntoBounds(raw, bounds),
            centerX = centerX,
            centerY = anchorY,
            petAnchorX = anchorX,
            petAnchorY = anchorY,
            holeRx = intrinsic.notchRx,
            holeRy = intrinsic.notchRy,
            allowedOffset = offset,
            ringRadiusPx = intrinsic.ringRadiusPx,
            buttonDiameterPx = intrinsic.buttonDiameterPx,
            buttonTouchDiameterPx = max(
                intrinsic.buttonDiameterPx,
                spec.dp(WheelMenuLayoutSettings.BUTTON_TOUCH_MIN_DP),
            ),
            fanBiasDeg = vertical.biasDeg,
            scale = 1f,
            compact = intrinsic.compact,
            fits = false,
            notchInside = true,
        )
    }

    private fun degenerateEnvelope(
        bounds: OverlayBounds,
        visible: OverlayRect,
        direction: WheelExpandDirection,
        vertical: WheelVerticalMode,
        holeRx: Float,
        holeRy: Float,
        offset: Float,
        settings: WheelMenuLayoutSettings,
        spec: WheelMenuSpec,
    ): WheelMenuEnvelope {
        val rect = if (visible.isUsable) visible else OverlayRect(0, 0, 1, 1)
        return WheelMenuEnvelope(
            direction = direction,
            verticalMode = vertical,
            windowRect = rect,
            centerX = rect.centerX,
            centerY = rect.centerY,
            petAnchorX = rect.centerX,
            petAnchorY = rect.centerY,
            holeRx = max(holeRx, 1f),
            holeRy = max(holeRy, 1f),
            allowedOffsetPx = offset,
            maxRingRadiusPx = spec.dp(MIN_RADIUS_DP),
            buttonDiameterPx = spec.buttonDiameterFor(2, MIN_ACTUAL_SCALE),
            buttonTouchDiameterPx = max(
                spec.buttonDiameterFor(2, MIN_ACTUAL_SCALE),
                spec.dp(WheelMenuLayoutSettings.BUTTON_TOUCH_MIN_DP),
            ),
            fanBiasDeg = vertical.biasDeg,
            preferredScale = settings.preferredScale,
            actualScale = MIN_ACTUAL_SCALE,
            compact = true,
            degraded = true,
            fallbackReason = "no-usable-bounds",
        )
    }

    private fun clampIntoBounds(rect: OverlayRect, bounds: OverlayBounds): OverlayRect {
        if (!bounds.isUsable) return rect
        val width = min(rect.width, bounds.width)
        val height = min(rect.height, bounds.height)
        val left = rect.left.coerceIn(bounds.left, max(bounds.left, bounds.right - width))
        val top = rect.top.coerceIn(bounds.top, max(bounds.top, bounds.bottom - height))
        return OverlayRect(left, top, left + width, top + height)
    }

    private fun baseAngle(direction: WheelExpandDirection): Float =
        if (direction == WheelExpandDirection.right) 0f else 180f

    /**
     * 把**相对展开轴**的角度换算成屏幕绝对角度。
     *
     * 镜像时角度要**取反**（`180° − offset` 而不是 `180° + offset`）：
     * 否则左展开时"槽位下标越大越靠下"会变成"越靠上"，
     * 固定返回键就会跑到视觉最上方（需求 §11 明确禁止）。
     */
    fun absoluteAngle(direction: WheelExpandDirection, offsetAngleDeg: Float): Float =
        normalizeAngle(baseAngle(direction) + direction.sign * offsetAngleDeg)

    /**
     * 绝对角度 → **连续的槽位下标**（0.0 = 第一项）。
     *
     * 手势命中与渲染（刀刃跟随选中项）都走这一个换算，保证两边永远一致。
     */
    fun rawIndexAt(layout: WheelMenuLayout, absoluteAngleDeg: Float): Float {
        if (layout.itemCount <= 1 || layout.stepDeg <= 0f) return 0f
        val offset = normalizeAngle(absoluteAngleDeg - baseAngle(layout.direction)) * layout.direction.sign
        return (offset - layout.fanBiasDeg) / layout.stepDeg + (layout.itemCount - 1) / 2f
    }

    /** 归一到 `(-180, 180]`。 */
    fun normalizeAngle(deg: Float): Float {
        var value = deg % 360f
        if (value > 180f) value -= 360f
        if (value <= -180f) value += 360f
        return value
    }

    /** 紧凑模式下按钮视觉直径的收缩比例。 */
    private const val COMPACT_BUTTON_SHRINK = 0.92f
}

/**
 * 轮盘的**固有几何**（Phase 4C-6B-1.2 修复，需求 §3.1）。
 *
 * 只由 `wheel_scale` / `button_scale` / 条目数 / 桌宠**尺寸**决定，
 * **绝不**接收桌宠位置、剩余空间、离边缘距离 —— 这是"同一设置下轮盘大小恒定"的结构性保证。
 */
internal data class WheelIntrinsicLayout(
    val itemCount: Int,
    val ringRadiusPx: Float,
    val buttonDiameterPx: Float,
    val bandOuterPx: Float,
    val rimOuterPx: Float,
    val bladeLengthPx: Float,
    val bladeHalfSweepDeg: Float,
    val stepDeg: Float,
    val fanHalfSpanDeg: Float,
    val outlineWidthPx: Float,
    val rimLobePx: Float,
    val compact: Boolean,
    /** 缺口半轴（由桌宠可见尺寸决定；已按内径上限夹过）。 */
    val notchRx: Float,
    val notchRy: Float,
    /** 绘制包围盒的半宽/半高（含文字 AABB 与安全边距，用于设备级应急缩放）。 */
    val halfWidthPx: Float,
    val halfHeightPx: Float,
)

/**
 * 主扇区里三层文字的**纯布局**（Phase 4C-6B-1.1，需求 §10.1 / §10.2）。
 *
 * 抽成纯函数的原因：真机上"英文标题与中文名重叠""标题越过按钮边界"都是
 * **几何问题**而不是绘制问题，只有把半径与字号先算清楚，才能用单测钉住；
 * 渲染层只负责按这套数字画。
 */
internal data class WheelTextSlots(
    /** 文字安全带：[bandStart, bandEnd]（径向上不会撞到按钮与缺口）。 */
    val bandStart: Float,
    val bandEnd: Float,
    val titleRadius: Float,
    val chipRadius: Float,
    val infoRadius: Float,
    val titleSizePx: Float,
    val chipSizePx: Float,
    val infoSizePx: Float,
    /** 每条文字在该半径处的最大可用宽度（扇形张角内的弦长）。 */
    val titleMaxWidth: Float,
    val chipMaxWidth: Float,
    val infoMaxWidth: Float,
)

internal object WheelTextLayout {

    /** 文字安全带相对刀刃的占比（标题 / 中文名 / 说明）。 */
    const val TITLE_RADIUS_RATIO = 0.30f
    const val CHIP_RADIUS_RATIO = 0.72f
    const val INFO_RADIUS_RATIO = 0.93f

    /** 标题字号相对安全带高度的比例。 */
    const val TITLE_SIZE_RATIO = 0.30f

    /** 可用弦长只取扇形张角的一部分，避免文字顶到扇区尖角。 */
    const val CHORD_SAFETY = 0.78f

    /** 文字安全带与按钮圆之间的净空（dp）。 */
    const val TEXT_BAND_GAP_DP = 4f

    /** 中文名的基准字号（sp）—— 与渲染层的 `MIN_SUBTITLE_SP` 保持一致口径。 */
    const val MIN_CHIP_SP = 16f

    /**
     * @param density 屏幕密度（最小字号按 sp 换算）
     * @param minTitleSp / [minChipSp] / [minInfoSp] 最小字号（sp）
     */
    fun compute(
        layout: WheelMenuLayout,
        density: Float,
        minTitleSp: Float,
        minChipSp: Float,
        minInfoSp: Float,
    ): WheelTextSlots {
        val d = OverlayGeometry.safeDensity(density)
        // 安全带起点 = **按钮圆的外侧切点 + 净空**：
        // 高亮按钮就在刀刃根部，文字若从环带内缘起排会直接压住它（真机反馈问题之一）。
        val bandStart = layout.ringRadiusPx + layout.buttonDiameterPx * 0.5f + d * TEXT_BAND_GAP_DP
        val bandEnd = max(layout.bladeLengthPx, bandStart + 1f)
        val band = bandEnd - bandStart
        val titleRadius = bandStart + band * TITLE_RADIUS_RATIO
        val chipRadius = bandStart + band * CHIP_RADIUS_RATIO
        val infoRadius = bandStart + band * INFO_RADIUS_RATIO
        val titleSize = max(band * TITLE_SIZE_RATIO, minTitleSp * d)
        val chipSize = max(layout.buttonDiameterPx * 0.42f, minChipSp * d)
        val infoSize = max(layout.buttonDiameterPx * 0.27f, minInfoSp * d)
        return WheelTextSlots(
            bandStart = bandStart,
            bandEnd = bandEnd,
            titleRadius = titleRadius,
            chipRadius = chipRadius,
            infoRadius = infoRadius,
            titleSizePx = titleSize,
            chipSizePx = chipSize,
            infoSizePx = infoSize,
            titleMaxWidth = chordAt(layout, titleRadius),
            chipMaxWidth = chordAt(layout, chipRadius),
            infoMaxWidth = chordAt(layout, infoRadius),
        )
    }

    /** 半径 [radius] 处、扇形张角内的可用宽度。 */
    fun chordAt(layout: WheelMenuLayout, radius: Float): Float =
        (2.0 * radius *
            kotlin.math.sin(Math.toRadians(layout.bladeHalfSweepDeg * CHORD_SAFETY.toDouble())))
            .toFloat()
}

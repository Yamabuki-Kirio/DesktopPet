package asia.akechi.petlife.overlay

import android.content.Context
import android.content.res.Configuration
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PixelFormat
import android.graphics.RectF
import android.os.Build
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.WindowManager
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

// =============================================================================================
// 双窗口层级探测（**仅诊断模式**）——完全自包含，不参与任何生产菜单开合路径。
//
// 真机复验（v2，修正版）目标：
//   1) menuProbeWindow **只 add 一次**、全程**绝不 remove / 绝不重加**（menuAddCount 恒为 1）；
//   2) petProbeWindow 后加一次（故桌宠应始终在菜单之上，menuWasReaddedAfterPet 恒为 false）；
//   3) 关菜单 = **一次 updateViewLayout**：加 `FLAG_NOT_TOUCHABLE` + 缩到 1×1 + 移到安全角落 + 内容 GONE；
//   4) 开菜单 = **一次 updateViewLayout**：按桌宠**当前**屏幕矩形重算菜单矩形（镜像 + 垂直偏置）+ 清
//      `FLAG_NOT_TOUCHABLE` + 恢复内容（**绝不 addView**）；
//   5) 菜单始终跟随桌宠**当前**屏幕矩形（拖拽 / 贴边 / 旋转 / 分屏），锚点不变式
//      `anchorMatchesCurrentPet` 一旦为 false 立刻把 `probeValid=false` 并记原因码；
//   6) 蓝块**只**显示 `PET` / top 判断 / `lastTouchReceiver`，并提供一枚按钮循环记录
//      `actualVisualTop`（操作者**看到的**谁在最上层）；
//   7) 完整状态通过既有 MethodChannel 的 `getDualWindowProbeStatus` 暴露给 Flutter。
//
// 硬约束（见任务书）：
//   * 只在 `PetOverlayStore.debugOverlayMode` 打开时存活（默认关闭 ⇒ 探测默认关闭）；
//   * 退出/关闭诊断 ⇒ 移除**本探测创建的每一个窗口**，绝不留透明可触摸窗口；
//   * 不使用 TYPE_SYSTEM_ALERT / TYPE_PHONE / 隐藏 API / 反射 / 无障碍 / 输入注入；
//   * 探测的任何失败都不得影响生产悬浮窗（服务侧统一 try/catch）；
//   * 绝不用 `alpha=0` 作为"释放输入"的手段（输入释放只靠 `FLAG_NOT_TOUCHABLE`）。
//
// 纯逻辑部分（[ProbeLayerLedger] / [DualWindowProbePlanner] / [DualWindowProbeContract]）不依赖任何
// `android.*` 类型，因此可在 JVM 单测里逐条打靶。
// =============================================================================================

/** 探测窗口种类（加/减序与计数都按它记账）。 */
internal enum class ProbeWindowKind(val wire: String) {
    MENU("menu"),
    PET("pet"),
}

/** 屏上/日志里统一描述的窗口矩形文本：`left,top w×h`；null ⇒ `none`。 */
internal fun OverlayRect?.probeText(): String =
    this?.let { "${it.left},${it.top} ${it.width}×${it.height}" } ?: "none"

/**
 * 加/减/更新序与计数账本（**纯逻辑，可 JVM 单测**）。
 *
 * * `addSequence`：**每一次** add / remove / updateViewLayout 都 +1 的全局单调操作序；
 * * `petLastAddSequence` / `menuLastAddSequence`：各窗口**最后一次 add** 时的操作序。
 *   菜单只 add 一次 ⇒ `menuLastAddSequence` 恒为 1，`currentExpectedTopWindow` 恒为 `pet`。
 * * `menuWasReaddedAfterPet`：菜单是否在桌宠出现之后被**重加**过（正常恒为 false）。
 */
internal class ProbeLayerLedger {

    private val adds = ArrayList<ProbeWindowKind>(4)

    var petAddCount: Int = 0
        private set

    var menuAddCount: Int = 0
        private set

    var petRemoveCount: Int = 0
        private set

    var menuRemoveCount: Int = 0
        private set

    /** 菜单窗口当前是否已挂载（add 后 true、remove 后 false）。 */
    var menuAttached: Boolean = false
        private set

    /** 桌宠窗口当前是否已挂载（add 后 true、remove 后 false）。 */
    var petAttached: Boolean = false
        private set

    /** 全局单调操作序（每次 add/remove/updateViewLayout 都 +1）。 */
    var addSequence: Int = 0
        private set

    /** 桌宠窗口**最后一次 add** 时的全局操作序。 */
    var petLastAddSequence: Int = 0
        private set

    /** 菜单窗口**最后一次 add** 时的全局操作序。 */
    var menuLastAddSequence: Int = 0
        private set

    /** 菜单是否在桌宠出现之后被重加（正常恒为 false）。 */
    var menuWasReaddedAfterPet: Boolean = false
        private set

    /** 完整加序（按时间顺序）。 */
    fun history(): List<ProbeWindowKind> = adds.toList()

    /** **前两次**加窗序——这就是"固定加序 menu→pet"的可判定形式。 */
    fun initialOrder(): List<ProbeWindowKind> = adds.take(2)

    fun initialOrderLabel(): String = initialOrder().joinToString("→") { it.wire }

    fun addOrderLabel(): String = adds.joinToString("→") { it.wire }

    /**
     * 期望的顶层窗口：**后 add 者在上**。用"最后一次 add 的操作序"比较，
     * 于是"菜单被 update（关闭/移动）"**不会**把它错误地抬到桌宠之上。
     */
    fun currentExpectedTopWindow(): ProbeWindowKind =
        if (petLastAddSequence > menuLastAddSequence) ProbeWindowKind.PET else ProbeWindowKind.MENU

    /** 记录一次 addView，返回本次操作的全局序。 */
    fun recordAdd(kind: ProbeWindowKind): Int {
        addSequence += 1
        adds.add(kind)
        when (kind) {
            ProbeWindowKind.PET -> {
                petAddCount += 1
                petAttached = true
                petLastAddSequence = addSequence
            }
            ProbeWindowKind.MENU -> {
                menuAddCount += 1
                menuAttached = true
                menuLastAddSequence = addSequence
                if (petAddCount > 0) menuWasReaddedAfterPet = true
            }
        }
        return addSequence
    }

    /** 记录一次 removeView，返回本次操作的全局序。 */
    fun recordRemove(kind: ProbeWindowKind): Int {
        addSequence += 1
        when (kind) {
            ProbeWindowKind.PET -> {
                petRemoveCount += 1
                petAttached = false
            }
            ProbeWindowKind.MENU -> {
                menuRemoveCount += 1
                menuAttached = false
            }
        }
        return addSequence
    }

    /** 记录一次 updateViewLayout（不改动加/减计数，只推进全局序），返回本次操作序。 */
    fun recordUpdate(kind: ProbeWindowKind): Int {
        addSequence += 1
        // kind 仅用于将来按窗口统计；此处保持纯计数语义。
        when (kind) {
            ProbeWindowKind.MENU, ProbeWindowKind.PET -> Unit
        }
        return addSequence
    }

    /** 加减配对自检：任何窗口的移除次数都不得超过其添加次数。 */
    fun isPaired(): Boolean =
        petRemoveCount <= petAddCount && menuRemoveCount <= menuAddCount
}

/**
 * 探测几何（屏幕绝对坐标；纯数据 + 纯判定）。
 *
 * 不变式（单测直接打靶）：
 * * `outsideButton` **严格位于** `petRect` 之外（含 1px 以上间隙，绝不贴边）；
 * * `overlapButton` **严格与** `petRect` 相交（面积 > 0），且重叠比例约 50%。
 */
internal data class DualWindowProbeLayout(
    /** 桌宠探测窗口矩形（尺寸 >= 最小可读尺寸）。 */
    val petRect: OverlayRect,
    /** 菜单探测窗口矩形（透明色块 + 三个按钮的宿主）。 */
    val menuRect: OverlayRect,
    val outsideButton: OverlayRect,
    val overlapButton: OverlayRect,
    val closeButton: OverlayRect,
    /** 水平镜像：桌宠在屏幕左半 ⇒ 菜单向右铺开（`right`）；右半 ⇒ `left`；拿不到屏幕宽 ⇒ `center`。 */
    val menuDirection: String = "center",
    /** 垂直偏置：桌宠贴近下边界 ⇒ 菜单改到桌宠上方（`above`）；否则 `below`。 */
    val verticalMode: String = "below",
    /** 菜单矩形是否被屏幕边界夹取过。 */
    val clampedByScreen: Boolean = false,
) {

    /** OVERLAP 按钮与桌宠矩形的相交面积 / 按钮面积（0~1）。 */
    val overlapRatio: Float
        get() {
            val area = overlapButton.width.toLong() * overlapButton.height.toLong()
            if (area <= 0L) return 0f
            val w = min(overlapButton.right, petRect.right) - max(overlapButton.left, petRect.left)
            val h = min(overlapButton.bottom, petRect.bottom) - max(overlapButton.top, petRect.top)
            if (w <= 0 || h <= 0) return 0f
            return (w.toLong() * h.toLong()).toFloat() / area.toFloat()
        }

    /** OUTSIDE 按钮是否**严格**在桌宠矩形之外（四个方向任一方向留出 >=1px 间隙）。 */
    fun outsideIsStrictlyOutsidePet(): Boolean =
        outsideButton.bottom < petRect.top ||
            outsideButton.top > petRect.bottom ||
            outsideButton.right < petRect.left ||
            outsideButton.left > petRect.right

    /** OVERLAP 按钮是否**严格**与桌宠矩形相交（半开区间下 overlaps 为 true 即为真实相交）。 */
    fun overlapStrictlyIntersectsPet(): Boolean = petRect.overlaps(overlapButton)

    /** 三个按钮是否都完整落在菜单矩形内。 */
    fun buttonsInsideMenu(): Boolean =
        inside(outsideButton) && inside(overlapButton) && inside(closeButton)

    private fun inside(rect: OverlayRect): Boolean =
        rect.left >= menuRect.left && rect.top >= menuRect.top &&
            rect.right <= menuRect.right && rect.bottom <= menuRect.bottom
}

/**
 * 探测布局求解（**纯函数**，可 JVM 单测）。
 *
 * 设计：菜单块以桌宠为锚点铺开，顶部**故意压住桌宠下半部分**（证明"后加的桌宠在菜单之上"）。
 * 保留两件"边缘自适应"：
 * * **左右镜像**：桌宠在屏幕左半 → 菜单向右；右半 → 向左；拿不到屏幕宽 → 居中；
 * * **垂直偏置**：桌宠贴近下边界 → 菜单改到桌宠上方；否则在下方。
 * 两者都保证菜单与桌宠仍有重叠（否则"桌宠盖住菜单"就无从证明）。
 */
internal object DualWindowProbePlanner {

    /** 兜底桌宠探测尺寸（取不到真实桌宠尺寸时用）。 */
    const val FALLBACK_PET_SIZE_DP = 180f

    /**
     * 桌宠探测窗口**最小可读尺寸**（可配置常量）。
     *
     * 取 `max(真实桌宠尺寸, 本值)`：既"从真实桌宠尺寸派生"，又保证读out 文本放得下。
     */
    const val MIN_PET_PROBE_DP = 160f

    /** 菜单探测窗口最小宽度（保证按钮排得下）。 */
    const val MENU_MIN_WIDTH_DP = 260f

    /** 菜单块在桌宠下方额外延伸的高度。 */
    const val MENU_BAND_DP = 130f

    const val BUTTON_HEIGHT_DP = 44f
    const val BUTTON_MARGIN_DP = 10f

    /** OVERLAP 按钮最大宽度（居中压在桌宠边界上，宽度不超过桌宠宽度）。 */
    const val OVERLAP_MAX_WIDTH_DP = 220f

    /** 关闭态菜单窗口缩到 1×1 后，摆到屏幕角落的内缩量（dp）。 */
    const val CLOSED_MENU_INSET_DP = 2f

    fun dp(density: Float, value: Float): Int =
        (value * density).roundToInt().coerceAtLeast(1)

    /**
     * 关闭态菜单窗口的 1×1 角落矩形（内缩几px，绝不放 (0,0) 正中以免与系统手势区打架）。
     *
     * 与 `FLAG_NOT_TOUCHABLE` 一起构成"输入释放"机制：**绝不**用 `alpha=0`。
     */
    fun closedMenuRect(density: Float): OverlayRect {
        val inset = dp(density, CLOSED_MENU_INSET_DP)
        return OverlayRect(inset, inset, inset + 1, inset + 1)
    }

    /**
     * 解析桌宠探测矩形：优先用真实桌宠屏幕矩形；拿不到时用固定 dp 兜底。
     *
     * 只取左上角，尺寸统一收敛到 >= [MIN_PET_PROBE_DP]，并夹回屏幕内。
     */
    fun resolvePetRect(
        provided: OverlayRect?,
        density: Float,
        screenWidth: Int,
        screenHeight: Int,
    ): OverlayRect {
        val minSize = dp(density, MIN_PET_PROBE_DP)
        val fallback = dp(density, FALLBACK_PET_SIZE_DP)
        val base = if (provided != null && provided.isUsable) provided else {
            val left = ((screenWidth - fallback) / 2).coerceAtLeast(0)
            val top = ((screenHeight - fallback) / 3).coerceAtLeast(0)
            OverlayRect(left, top, left + fallback, top + fallback)
        }
        val width = max(base.width, minSize)
        val height = max(base.height, minSize)
        var left = base.left
        var top = base.top
        if (screenWidth > 0) left = left.coerceIn(0, max(0, screenWidth - width))
        if (screenHeight > 0) top = top.coerceIn(0, max(0, screenHeight - height))
        return OverlayRect(left, top, left + width, top + height)
    }

    /**
     * 由桌宠探测矩形求解双窗口 + 三按钮布局。
     *
     * [screenWidth]/[screenHeight] 为 0 表示"拿不到屏幕尺寸"⇒ 关闭镜像/偏置/夹取（退化为居中 + 下方）。
     */
    fun plan(
        petRect: OverlayRect,
        density: Float,
        screenWidth: Int = 0,
        screenHeight: Int = 0,
    ): DualWindowProbeLayout {
        val pet = petRect
        val margin = dp(density, BUTTON_MARGIN_DP)
        val buttonHeight = dp(density, BUTTON_HEIGHT_DP)
        val band = dp(density, MENU_BAND_DP)

        val menuWidth = max(pet.width, dp(density, MENU_MIN_WIDTH_DP))
        // 菜单顶部压住桌宠一半：重叠高度 = 桌宠高度的一半（证明"后加的桌宠在菜单之上"）。
        val overlapY = (pet.height / 2).coerceAtLeast(1)
        val menuHeight = overlapY + band

        // 水平镜像：桌宠在屏幕左半 → 菜单向右铺开；右半 → 向左；拿不到屏幕宽 → 居中。
        val menuDirection = when {
            screenWidth <= 0 -> "center"
            pet.centerX <= screenWidth / 2 -> "right"
            else -> "left"
        }
        val rawMenuLeft = when (menuDirection) {
            "right" -> pet.left
            "left" -> pet.right - menuWidth
            else -> pet.centerX - menuWidth / 2
        }

        // 垂直偏置：桌宠贴近下边界 → 菜单改到桌宠上方；否则在下方。
        val verticalMode =
            if (screenHeight > 0 && pet.bottom + band > screenHeight) "above" else "below"
        val rawMenuTop = when (verticalMode) {
            "above" -> pet.top - band
            else -> pet.bottom - overlapY
        }

        // 夹回屏幕（拿不到屏幕尺寸 / 屏幕比菜单还小 ⇒ 不做夹取）。
        var menuLeft = rawMenuLeft
        var menuTop = rawMenuTop
        var clamped = false
        if (screenWidth > 0 && screenWidth >= menuWidth) {
            val c = menuLeft.coerceIn(0, screenWidth - menuWidth)
            if (c != menuLeft) {
                menuLeft = c
                clamped = true
            }
        }
        if (screenHeight > 0 && screenHeight >= menuHeight) {
            val c = menuTop.coerceIn(0, screenHeight - menuHeight)
            if (c != menuTop) {
                menuTop = c
                clamped = true
            }
        }
        val menu = OverlayRect(menuLeft, menuTop, menuLeft + menuWidth, menuTop + menuHeight)

        // OVERLAP：水平居中于桌宠、骑在"菜单与桌宠共享的那条边界"上。
        val overlapWidth = min(pet.width - 2 * margin, dp(density, OVERLAP_MAX_WIDTH_DP))
            .coerceAtLeast(1)
        val overlapLeft = pet.centerX - overlapWidth / 2
        val overlapTop = when (verticalMode) {
            "above" -> pet.top - buttonHeight / 2
            else -> pet.bottom - buttonHeight / 2
        }
        val overlapButton = OverlayRect(
            left = overlapLeft,
            top = overlapTop,
            right = overlapLeft + overlapWidth,
            bottom = overlapTop + buttonHeight,
        )

        // OUTSIDE / CLOSE MENU：整行落在菜单的"外侧"（下方模式在桌宠下方；上方模式在桌宠上方）。
        val rowTop = when (verticalMode) {
            "above" -> pet.top - buttonHeight / 2 - margin - buttonHeight
            else -> pet.bottom + buttonHeight / 2 + margin
        }
        val half = menuLeft + menuWidth / 2
        val outsideButton = OverlayRect(
            left = menuLeft + margin,
            top = rowTop,
            right = half - margin,
            bottom = rowTop + buttonHeight,
        )
        val closeButton = OverlayRect(
            left = half + margin,
            top = rowTop,
            right = menuLeft + menuWidth - margin,
            bottom = rowTop + buttonHeight,
        )

        return DualWindowProbeLayout(
            petRect = pet,
            menuRect = menu,
            outsideButton = outsideButton,
            overlapButton = overlapButton,
            closeButton = closeButton,
            menuDirection = menuDirection,
            verticalMode = verticalMode,
            clampedByScreen = clamped,
        )
    }
}

/**
 * 探测结论有效性契约（**纯逻辑，可 JVM 单测**）。
 *
 * 为什么要有它：真机上生产悬浮窗若与探测窗口同时存在，探测就**无法**证明"双窗口层级"结论。
 * 因此把"有效性判定 / 读out 字段 / 启动与停止日志块 / 冻结状态 key 集"收敛到这里唯一一处，
 * 既能被单测逐条打靶，又保证真机日志与读out 说的是同一件事。
 */
internal object DualWindowProbeContract {

    /** 探测自知应该存在的窗口数：menu + pet（生产窗口已被摘除）。 */
    const val EXPECTED_PROBE_WINDOW_COUNT = 2

    /** 生产悬浮窗仍在挂载 ⇒ 探测结论无效的原因码。 */
    const val REASON_PRODUCTION_WINDOW_ATTACHED = "PROBE_INVALID_PRODUCTION_WINDOW_ATTACHED"

    /** 任一探测窗口添加失败 ⇒ 探测结论无效的原因码。 */
    const val REASON_PROBE_WINDOW_ADD_FAILED = "PROBE_INVALID_PROBE_WINDOW_ADD_FAILED"

    /** 菜单锚点与桌宠当前矩形不一致 ⇒ 探测结论无效的原因码。 */
    const val REASON_ANCHOR_MISMATCH = "PROBE_INVALID_ANCHOR_MISMATCH"

    /** 统一日志前缀（任务要求 tag = `probe.dual`）。 */
    const val LOG_PREFIX = "probe.dual "

    /** 空值文本（未运行 / 不存在时统一用）。 */
    const val NONE = "none"

    /**
     * 启动硬门：**只有**"生产窗口已不在 + 两个探测窗口都加成功"才算有效。
     */
    fun computeProbeValid(
        productionWindowAttached: Boolean,
        allProbeWindowsAdded: Boolean,
    ): Boolean = !productionWindowAttached && allProbeWindowsAdded

    /**
     * "已有结论"与"此刻真值"的复合：生产窗口一旦出现，任何"通过"都必须作废。
     */
    fun effectiveProbeValid(
        storedProbeValid: Boolean,
        productionWindowAttached: Boolean,
    ): Boolean = storedProbeValid && !productionWindowAttached

    /**
     * 锚点不变式：菜单锚点（其矩形是据以计算菜单矩形的那份桌宠矩形）必须与桌宠**当前**屏幕矩形一致。
     * 一旦为 false（例如误用了缓存的 `initialPetRect`），探测必须判为无效。
     */
    fun anchorMatches(menuAnchorPetRect: OverlayRect?, currentPetScreenRect: OverlayRect?): Boolean =
        menuAnchorPetRect != null && menuAnchorPetRect == currentPetScreenRect

    /** 锚点不变式的复合：`anchorMatches=false` ⇒ 结论一律无效。 */
    fun applyAnchorInvariant(storedProbeValid: Boolean, anchorMatches: Boolean): Boolean =
        storedProbeValid && anchorMatches

    /** 当前真正挂载的探测窗口数（menu + pet）。 */
    fun probeWindowCount(menuAttached: Boolean, petAttached: Boolean): Int =
        (if (menuAttached) 1 else 0) + (if (petAttached) 1 else 0)

    /** 探测自知的总悬浮窗数 = 生产窗口（0/1） + 探测窗口。 */
    fun totalKnownOverlayWindowCount(
        productionWindowAttached: Boolean,
        probeWindowCount: Int,
    ): Int = (if (productionWindowAttached) 1 else 0) + probeWindowCount

    /**
     * 恢复生产桌宠窗口时的重建计数：`attach` **真正新建**才为 1；
     * 已挂载时 `attach` 幂等返回 false ⇒ 0（证明没有重复建窗）。
     */
    fun petWindowRecreateCount(attachCreated: Boolean): Int = if (attachCreated) 1 else 0

    // ------------------------------------------------------------------
    // Flutter 侧冻结的状态 key 集（`getDualWindowProbeStatus` 返回值）
    //
    // **顺序即契约**：Dart 侧并行开发对着这份列表写，故 key 名与顺序都不得随意改动。
    // ------------------------------------------------------------------
    val STATUS_KEYS: List<String> = listOf(
        "probeValid",
        "productionWindowAttached",
        "probeWindowCount",
        "expectedProbeWindowCount",
        "totalKnownOverlayWindowCount",
        "petAddCount",
        "menuAddCount",
        "petLastAddSequence",
        "menuLastAddSequence",
        "addSequence",
        "currentExpectedTopWindow",
        "actualVisualTop",
        "menuWasReaddedAfterPet",
        "menuAttached",
        "menuTouchable",
        "menuAnchorPetRect",
        "currentPetScreenRect",
        "currentMenuWindowRect",
        "anchorMatchesCurrentPet",
        "menuDirection",
        "verticalMode",
        "clampedByScreen",
        "lastWindowOperation",
        "lastTouchReceiver",
        "orientation",
        "deviceModel",
        "sdkInt",
    )

    /** 冻结状态集的强类型取值容器（纯数据，便于单测构造与逐字段打靶）。 */
    data class ProbeStatus(
        val probeValid: Boolean,
        val productionWindowAttached: Boolean,
        val probeWindowCount: Int,
        val expectedProbeWindowCount: Int,
        val totalKnownOverlayWindowCount: Int,
        val petAddCount: Int,
        val menuAddCount: Int,
        val petLastAddSequence: Int,
        val menuLastAddSequence: Int,
        val addSequence: Int,
        val currentExpectedTopWindow: String,
        val actualVisualTop: String,
        val menuWasReaddedAfterPet: Boolean,
        val menuAttached: Boolean,
        val menuTouchable: Boolean,
        val menuAnchorPetRect: String,
        val currentPetScreenRect: String,
        val currentMenuWindowRect: String,
        val anchorMatchesCurrentPet: Boolean,
        val menuDirection: String,
        val verticalMode: String,
        val clampedByScreen: Boolean,
        val lastWindowOperation: String,
        val lastTouchReceiver: String,
        val orientation: String,
        val deviceModel: String,
        val sdkInt: Int,
    )

    /** 按冻结顺序把取值容器摊平成 Map（**恰好** [STATUS_KEYS] 这些 key）。 */
    fun statusMap(v: ProbeStatus): Map<String, Any?> = linkedMapOf(
        "probeValid" to v.probeValid,
        "productionWindowAttached" to v.productionWindowAttached,
        "probeWindowCount" to v.probeWindowCount,
        "expectedProbeWindowCount" to v.expectedProbeWindowCount,
        "totalKnownOverlayWindowCount" to v.totalKnownOverlayWindowCount,
        "petAddCount" to v.petAddCount,
        "menuAddCount" to v.menuAddCount,
        "petLastAddSequence" to v.petLastAddSequence,
        "menuLastAddSequence" to v.menuLastAddSequence,
        "addSequence" to v.addSequence,
        "currentExpectedTopWindow" to v.currentExpectedTopWindow,
        "actualVisualTop" to v.actualVisualTop,
        "menuWasReaddedAfterPet" to v.menuWasReaddedAfterPet,
        "menuAttached" to v.menuAttached,
        "menuTouchable" to v.menuTouchable,
        "menuAnchorPetRect" to v.menuAnchorPetRect,
        "currentPetScreenRect" to v.currentPetScreenRect,
        "currentMenuWindowRect" to v.currentMenuWindowRect,
        "anchorMatchesCurrentPet" to v.anchorMatchesCurrentPet,
        "menuDirection" to v.menuDirection,
        "verticalMode" to v.verticalMode,
        "clampedByScreen" to v.clampedByScreen,
        "lastWindowOperation" to v.lastWindowOperation,
        "lastTouchReceiver" to v.lastTouchReceiver,
        "orientation" to v.orientation,
        "deviceModel" to v.deviceModel,
        "sdkInt" to v.sdkInt,
    )

    /**
     * 探测**未运行**时的安全状态：`probeValid=false`，其余 `none` / 0 / false。
     * 让 Flutter 卡片在任意时刻都能安全渲染。
     */
    fun emptyStatus(): Map<String, Any?> = statusMap(
        ProbeStatus(
            probeValid = false,
            productionWindowAttached = false,
            probeWindowCount = 0,
            expectedProbeWindowCount = EXPECTED_PROBE_WINDOW_COUNT,
            totalKnownOverlayWindowCount = 0,
            petAddCount = 0,
            menuAddCount = 0,
            petLastAddSequence = 0,
            menuLastAddSequence = 0,
            addSequence = 0,
            currentExpectedTopWindow = NONE,
            actualVisualTop = NONE,
            menuWasReaddedAfterPet = false,
            menuAttached = false,
            menuTouchable = false,
            menuAnchorPetRect = NONE,
            currentPetScreenRect = NONE,
            currentMenuWindowRect = NONE,
            anchorMatchesCurrentPet = false,
            menuDirection = NONE,
            verticalMode = NONE,
            clampedByScreen = false,
            lastWindowOperation = NONE,
            lastTouchReceiver = NONE,
            orientation = NONE,
            deviceModel = NONE,
            sdkInt = 0,
        ),
    )

    /** 新增的 5 个读out 字段（顺序固定，便于真机逐条比对）。 */
    fun readoutLines(
        productionWindowAttached: Boolean,
        probeWindowCount: Int,
        probeValid: Boolean,
    ): List<String> = listOf(
        "productionWindowAttached=$productionWindowAttached",
        "probeWindowCount=$probeWindowCount",
        "expectedProbeWindowCount=$EXPECTED_PROBE_WINDOW_COUNT",
        "totalKnownOverlayWindowCount=" +
            totalKnownOverlayWindowCount(productionWindowAttached, probeWindowCount),
        "probeValid=$probeValid",
    )

    /** 启动日志契约块（**带 `probe.dual ` 前缀的完整行**，真机可直接 grep）。 */
    fun startContractLines(
        knownWindows: Int,
        productionWindowAttached: Boolean,
        probeValid: Boolean,
        reason: String? = null,
    ): List<String> {
        val lines = mutableListOf(
            LOG_PREFIX + "knownWindows=$knownWindows",
            LOG_PREFIX + "productionAttached=$productionWindowAttached",
            LOG_PREFIX + "add order=1 menu",
            LOG_PREFIX + "add order=2 pet",
            LOG_PREFIX + "probeValid=$probeValid",
        )
        if (reason != null) lines.add(LOG_PREFIX + "probeInvalidReason=$reason")
        return lines
    }

    /** 停止日志契约块（**带 `probe.dual ` 前缀的完整行**）。 */
    fun stopSummaryLines(
        menuRemoveCount: Int,
        petRemoveCount: Int,
        probeWindowCountAfterStop: Int,
        productionVisibleBefore: Boolean,
        productionRestored: Boolean,
        petWindowRecreateCount: Int,
        productionWindowAttached: Boolean,
    ): List<String> {
        val bothRemoved =
            menuRemoveCount == 1 && petRemoveCount == 1 && probeWindowCountAfterStop == 0
        return listOf(
            LOG_PREFIX + "probeRemove menu=$menuRemoveCount pet=$petRemoveCount " +
                "probeWindowCount=$probeWindowCountAfterStop bothRemoved=$bothRemoved",
            LOG_PREFIX + "productionVisibleBefore=$productionVisibleBefore",
            LOG_PREFIX + "productionRestored=$productionRestored",
            LOG_PREFIX + "petWindowRecreateCount=$petWindowRecreateCount",
            LOG_PREFIX + "productionWindowAttached=$productionWindowAttached",
        )
    }
}

/**
 * 一次 [DualWindowLayerProbe.stop] 的结果（**本次实际移除**的窗口数，不是累计）。
 */
internal data class ProbeStopResult(
    val menuRemoveCount: Int,
    val petRemoveCount: Int,
    val probeWindowCount: Int,
) {
    companion object {
        val Empty = ProbeStopResult(menuRemoveCount = 0, petRemoveCount = 0, probeWindowCount = 0)
    }
}

/**
 * 双窗口层级探测（Android 侧实现）。
 *
 * 生命周期由 [PetOverlayService] 按 `debugOverlayMode` 驱动：
 * * 诊断开 → [start]（幂等）；诊断关 / 服务停 → [stop]（移除本探测创建的全部窗口）。
 *
 * 加序**固定**：先 [ProbeWindowKind.MENU]，后 [ProbeWindowKind.PET]；且菜单**只 add 一次**，
 * 之后的开/关都只是 `updateViewLayout`（故菜单**不可能**再被抬到桌宠之上）。
 */
internal class DualWindowLayerProbe(
    private val context: Context,
    /** 取当前真实桌宠屏幕矩形；拿不到时返回 null（改用兜底尺寸）。 */
    private val petRectProvider: () -> OverlayRect?,
    /** 读"生产悬浮窗是否仍在挂载"的真值（服务注入 `manager.isAttached`）。 */
    private val productionWindowAttachedProvider: () -> Boolean = { false },
) {

    private val windowManager: WindowManager =
        context.getSystemService(Context.WINDOW_SERVICE) as WindowManager

    private val ledger = ProbeLayerLedger()
    private val touchSlopPx = ViewConfiguration.get(context).scaledTouchSlop

    private var layout: DualWindowProbeLayout? = null

    // 视图引用（null = 该窗口当前未挂载）。
    private var menuView: MenuProbeView? = null
    private var petView: PetProbeView? = null

    // LayoutParams（作为窗口配置快照，供读out 显示 type/flags/rect）。
    private var menuParams: WindowManager.LayoutParams? = null
    private var petParams: WindowManager.LayoutParams? = null

    private var running = false

    /**
     * 探测结论是否有效（**硬门**）：
     * * 启动时生产悬浮窗仍在挂载 ⇒ false（[DualWindowProbeContract.REASON_PRODUCTION_WINDOW_ATTACHED]）；
     * * 任一探测窗口添加失败 ⇒ false（[DualWindowProbeContract.REASON_PROBE_WINDOW_ADD_FAILED]）；
     * * 运行中生产悬浮窗一旦出现 ⇒ 立刻作废（**绝不报告假通过**）；
     * * 菜单锚点与桌宠当前矩形不一致 ⇒ 立刻作废（[DualWindowProbeContract.REASON_ANCHOR_MISMATCH]）。
     */
    var probeValid: Boolean = false
        private set

    /** 结论无效的原因码（有效时为 null）。 */
    var invalidReason: String? = null
        private set

    /** 当前**真正挂载**的探测窗口数（menu + pet）。 */
    val probeWindowCount: Int
        get() = (if (menuView != null) 1 else 0) + (if (petView != null) 1 else 0)

    // --- 菜单开关状态（窗口**始终挂载**，开关只切 flags/尺寸/位置/内容） ---
    private var menuOpen: Boolean = false
    private var menuTouchable: Boolean = false

    /** 菜单矩形据以计算的桌宠矩形（用于锚点不变式）。 */
    private var menuAnchorPetRect: OverlayRect? = null

    /** 操作者**看到**的顶层窗口（蓝块上的按钮循环记录，初始 `pet`）。 */
    private var actualVisualTop: String = ProbeWindowKind.PET.wire

    /** 最近一次窗口操作（`add menu seq=1` / `updateViewLayout menu seq=7` …）。 */
    private var lastWindowOperation: String = DualWindowProbeContract.NONE

    // --- 触摸观测状态 ---
    private var lastEvent: String = "NONE"
    private var lastReceiver: String = "UNDERLYING(unknown)"
    private var petTouchCount: Int = 0
    private var menuTouchCount: Int = 0

    // 桌宠拖拽（屏幕坐标 + 一次性抓取偏移）。
    private var dragging = false
    private var grabDx = 0f
    private var grabDy = 0f
    private var downRawX = 0f
    private var downRawY = 0f

    val isRunning: Boolean get() = running

    private fun density(): Float = context.resources.displayMetrics.density

    /**
     * 启动探测（幂等：已在运行则直接返回，绝不重加桌宠窗口）。
     *
     * [providedPetRect] 由服务在**摘除生产窗口之前**捕获的真实桌宠矩形；
     * 传 null 时才回退到 [petRectProvider]（几何始终从真实桌宠派生，绝不为避让重叠而挪位）。
     */
    fun start(providedPetRect: OverlayRect? = null) {
        if (running) return
        // 硬门：生产悬浮窗仍在 ⇒ 三窗并存，探测结论不可能有效，直接拒绝启动。
        if (productionWindowAttachedProvider()) {
            probeValid = false
            invalidReason = DualWindowProbeContract.REASON_PRODUCTION_WINDOW_ATTACHED
            logStartContract(productionWindowAttached = true, reason = invalidReason)
            logStatus()
            log(
                "${DualWindowProbeContract.REASON_PRODUCTION_WINDOW_ATTACHED} " +
                    "productionAttached=true —— 探测拒绝启动",
            )
            return
        }
        val dm = context.resources.displayMetrics
        val density = dm.density
        val petRect = DualWindowProbePlanner.resolvePetRect(
            provided = providedPetRect ?: petRectProvider(),
            density = density,
            screenWidth = dm.widthPixels,
            screenHeight = dm.heightPixels,
        )
        val plan = DualWindowProbePlanner.plan(
            petRect = petRect,
            density = density,
            screenWidth = dm.widthPixels,
            screenHeight = dm.heightPixels,
        )
        layout = plan
        try {
            // ---- 加序 #1：菜单（**只此一次 addView**）----
            val mv = MenuProbeView(context)
            val mp = paramsFor(plan.menuRect)
            windowManager.addView(mv, mp)
            menuView = mv
            menuParams = mp
            val menuSeq = ledger.recordAdd(ProbeWindowKind.MENU)
            logWindowOp("add", ProbeWindowKind.MENU, menuSeq, "type=${mp.type} rect=${plan.menuRect}")
            menuOpen = true
            menuTouchable = true
            mv.visibility = View.VISIBLE

            // ---- 加序 #2：桌宠（后加 ⇒ 在上层）----
            val pv = PetProbeView(context)
            val pp = paramsFor(plan.petRect)
            windowManager.addView(pv, pp)
            petView = pv
            petParams = pp
            val petSeq = ledger.recordAdd(ProbeWindowKind.PET)
            logWindowOp("add", ProbeWindowKind.PET, petSeq, "type=${pp.type} rect=${plan.petRect}")

            running = true
            menuAnchorPetRect = currentPetRect()
            probeValid = true
            invalidReason = null
            log(
                "start order=${ledger.initialOrderLabel()} sequence=${ledger.addOrderLabel()} " +
                    "petAddCount=${ledger.petAddCount} menuAddCount=${ledger.menuAddCount} " +
                    "expectedTop=${ledger.currentExpectedTopWindow().wire} " +
                    "anchorMatches=${anchorMatchesNow()} " +
                    "menuDir=${plan.menuDirection} vMode=${plan.verticalMode} " +
                    "clamped=${plan.clampedByScreen} " +
                    "overlapRatio=${(plan.overlapRatio * 100).roundToInt()}% " +
                    "outsideStrict=${plan.outsideIsStrictlyOutsidePet()} " +
                    "overlapIntersects=${plan.overlapStrictlyIntersectsPet()}",
            )
            logStartContract(
                productionWindowAttached = productionWindowAttachedProvider(),
                reason = null,
            )
            logStatus()
            refreshReadout()
        } catch (t: Throwable) {
            // 任一步失败：结论一定无效；把已加窗口全部摘掉，绝不留半残状态。
            probeValid = false
            invalidReason = DualWindowProbeContract.REASON_PROBE_WINDOW_ADD_FAILED
            log("start failed: ${t.message}")
            logStartContract(
                productionWindowAttached = productionWindowAttachedProvider(),
                reason = invalidReason,
            )
            stop()
            throw t
        }
    }

    /**
     * 停止探测：**先**移除**本探测创建的每一个窗口**（幂等）。
     *
     * 返回计数按"本次调用真正摘掉几个窗口"计（不是累计），供服务侧打印可核对的停止摘要。
     */
    fun stop(): ProbeStopResult {
        val pv = petView
        val mv = menuView
        petView = null
        menuView = null
        var petRemoved = 0
        var menuRemoved = 0
        if (pv != null) {
            val seq = ledger.recordRemove(ProbeWindowKind.PET)
            runCatching { windowManager.removeView(pv) }
                .onFailure { log("pet removeView failed: ${it.message}") }
            logWindowOp("remove", ProbeWindowKind.PET, seq)
            petRemoved = 1
        }
        if (mv != null) {
            val seq = ledger.recordRemove(ProbeWindowKind.MENU)
            runCatching { windowManager.removeView(mv) }
                .onFailure { log("menu removeView failed: ${it.message}") }
            logWindowOp("remove", ProbeWindowKind.MENU, seq)
            menuRemoved = 1
        }
        menuParams = null
        petParams = null
        layout = null
        menuOpen = false
        menuTouchable = false
        menuAnchorPetRect = null
        dragging = false
        running = false
        // 已停止 ⇒ 不再持有任何"有效结论"。
        probeValid = false
        log(
            "stop petRemoveCount=${ledger.petRemoveCount} menuRemoveCount=${ledger.menuRemoveCount} " +
                "petAddCount=${ledger.petAddCount} menuAddCount=${ledger.menuAddCount}",
        )
        logStatus()
        return ProbeStopResult(
            menuRemoveCount = menuRemoved,
            petRemoveCount = petRemoved,
            probeWindowCount = probeWindowCount,
        )
    }

    /**
     * 配置变化（旋转 / 分屏 / 尺寸变化）：按桌宠**当前**屏幕矩形重算菜单并（若菜单开着）跟随，
     * **绝不**重加/缩放任何窗口。
     */
    fun onConfigurationChanged() {
        if (running) {
            syncMenuToCurrentPet(applyToWindow = menuOpen)
        }
        refreshReadout()
        log(
            "configuration changed ori=${orientationName()} screen=${screenSizeText()} " +
                "menuDir=${layout?.menuDirection ?: "none"} " +
                "anchorMatches=${anchorMatchesNow()}",
        )
    }

    // ------------------------------------------------------------------
    // 菜单开关（**只 updateViewLayout，绝不 add / remove**）
    // ------------------------------------------------------------------

    private fun toggleMenuProbe() {
        if (menuOpen) closeMenuProbe() else openMenuProbe()
    }

    /**
     * 打开菜单：**一次** `updateViewLayout` —— 按桌宠**当前**屏幕矩形重算菜单矩形（含镜像/偏置/夹取），
     * 清除 `FLAG_NOT_TOUCHABLE`，恢复内容（VISIBLE）。**绝不** addView。
     */
    private fun openMenuProbe() {
        if (!running || menuOpen || menuView == null) return
        val mv = menuView ?: return
        val mp = menuParams ?: return
        val plan = syncMenuToCurrentPet(applyToWindow = false)
        mp.width = plan.menuRect.width
        mp.height = plan.menuRect.height
        mp.x = plan.menuRect.left
        mp.y = plan.menuRect.top
        // 复用生产同款 flags 语义：touchThrough=false ⇒ 不含 FLAG_NOT_TOUCHABLE。
        mp.flags = OverlayWindowSpec.windowFlags(touchThrough = false)
        mv.visibility = View.VISIBLE
        runCatching { windowManager.updateViewLayout(mv, mp) }
            .onFailure { log("menu open updateViewLayout failed: ${it.message}") }
        menuOpen = true
        menuTouchable = true
        val seq = ledger.recordUpdate(ProbeWindowKind.MENU)
        logWindowOp(
            "updateViewLayout",
            ProbeWindowKind.MENU,
            seq,
            "open flags=-NOT_TOUCHABLE rect=${plan.menuRect}",
        )
        refreshReadout()
    }

    /**
     * 关闭菜单：**一次** `updateViewLayout` ——
     * 1) 加 `FLAG_NOT_TOUCHABLE`（输入释放，**绝不** alpha=0）；
     * 2) 缩到 1×1；
     * 3) 移到安全角落（内缩几px）；
     * 4) 内容置 GONE。
     * **不触碰 petProbeWindow**。
     */
    private fun closeMenuProbe() {
        if (!running || !menuOpen || menuView == null) return
        val mv = menuView ?: return
        val mp = menuParams ?: return
        val corner = DualWindowProbePlanner.closedMenuRect(density())
        mp.flags = OverlayWindowSpec.windowFlags(touchThrough = true) // 含 FLAG_NOT_TOUCHABLE
        mp.width = 1
        mp.height = 1
        mp.x = corner.left
        mp.y = corner.top
        mv.visibility = View.GONE
        runCatching { windowManager.updateViewLayout(mv, mp) }
            .onFailure { log("menu close updateViewLayout failed: ${it.message}") }
        menuOpen = false
        menuTouchable = false
        val seq = ledger.recordUpdate(ProbeWindowKind.MENU)
        logWindowOp(
            "updateViewLayout",
            ProbeWindowKind.MENU,
            seq,
            "close flags=+NOT_TOUCHABLE size=1x1 pos=(${corner.left},${corner.top})",
        )
        // 与任务示例对齐，额外打一行 flags 记录（序列号不变，便于真机 grep）。
        log(
            "flags menu +NOT_TOUCHABLE seq=$seq device=${Build.MODEL} " +
                "(若 1×1 角落窗口在本机型异常，请记录机型与现象)",
        )
        lastEvent = "CLOSE_MENU_UPDATED"
        lastReceiver = "MENU"
        refreshReadout()
    }

    /**
     * 按桌宠**当前**屏幕矩形重算菜单矩形（镜像 + 垂直偏置 + 夹取），并更新锚点。
     *
     * 复用于：开菜单、拖拽、贴边、旋转/分屏。**绝不**使用缓存的 `initialPetRect`。
     * [applyToWindow]=true 时对菜单窗口发一次 `updateViewLayout`（若菜单开着）。
     */
    private fun syncMenuToCurrentPet(applyToWindow: Boolean): DualWindowProbeLayout {
        val dm = context.resources.displayMetrics
        val pet = currentPetRect()
        val plan = DualWindowProbePlanner.plan(
            petRect = pet,
            density = dm.density,
            screenWidth = dm.widthPixels,
            screenHeight = dm.heightPixels,
        )
        layout = plan
        menuAnchorPetRect = pet
        if (applyToWindow && menuOpen) {
            val mv = menuView
            val mp = menuParams
            if (mv != null && mp != null) {
                mp.width = plan.menuRect.width
                mp.height = plan.menuRect.height
                mp.x = plan.menuRect.left
                mp.y = plan.menuRect.top
                runCatching { windowManager.updateViewLayout(mv, mp) }
                    .onFailure { log("menu follow updateViewLayout failed: ${it.message}") }
                val seq = ledger.recordUpdate(ProbeWindowKind.MENU)
                logWindowOp(
                    "updateViewLayout",
                    ProbeWindowKind.MENU,
                    seq,
                    "follow rect=${plan.menuRect}",
                )
            }
        }
        return plan
    }

    // ------------------------------------------------------------------
    // 触摸处理
    // ------------------------------------------------------------------

    /** 桌宠窗口触摸：屏幕坐标拖拽 + 记录接收方（轻点=开关菜单；点实际顶层按钮=循环 actualVisualTop）。 */
    private fun handlePetTouch(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                val p = petParams ?: return false
                grabDx = event.rawX - p.x
                grabDy = event.rawY - p.y
                downRawX = event.rawX
                downRawY = event.rawY
                dragging = true
                petTouchCount += 1
                lastReceiver = "PET"
                lastEvent = "PET_TOUCH_RECEIVED"
                log(
                    "touch receiver=PET action=DOWN raw=(${event.rawX.toInt()},${event.rawY.toInt()}) " +
                        "petRect=${currentPetRect().probeText()} petAddCount=${ledger.petAddCount}",
                )
                refreshReadout()
                return true
            }

            MotionEvent.ACTION_MOVE -> {
                if (!dragging) return true
                val p = petParams ?: return true
                val nx = (event.rawX - grabDx).roundToInt()
                val ny = (event.rawY - grabDy).roundToInt()
                if (nx != p.x || ny != p.y) {
                    p.x = nx
                    p.y = ny
                    // 拖动只移动**本窗口 LayoutParams**（单次 updateViewLayout），绝不重加/改尺寸。
                    runCatching { windowManager.updateViewLayout(petView, p) }
                        .onFailure { log("pet updateViewLayout failed: ${it.message}") }
                    val seq = ledger.recordUpdate(ProbeWindowKind.PET)
                    logWindowOp(
                        "updateViewLayout",
                        ProbeWindowKind.PET,
                        seq,
                        "drag pos=(${p.x},${p.y})",
                    )
                    // 菜单跟随桌宠**当前**屏幕矩形（仅菜单开着时真正下发）。
                    syncMenuToCurrentPet(applyToWindow = menuOpen)
                    refreshReadout()
                }
                return true
            }

            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                val moved = abs(event.rawX - downRawX) > touchSlopPx ||
                    abs(event.rawY - downRawY) > touchSlopPx
                dragging = false
                // 拖拽结束（含贴边/落位）：再按当前桌宠矩形同步一次菜单并复核锚点。
                if (moved && event.actionMasked == MotionEvent.ACTION_UP) {
                    syncMenuToCurrentPet(applyToWindow = menuOpen)
                }
                if (event.actionMasked == MotionEvent.ACTION_UP && !moved) {
                    if (actualToggleHit(event.y)) {
                        cycleActualVisualTop()
                    } else {
                        // 轻点 = 开关菜单（桌宠窗口本身位置不变）。
                        log("pet.tap toggle menu (petAddCount=${ledger.petAddCount})")
                        toggleMenuProbe()
                    }
                }
                return true
            }
        }
        return true
    }

    /** 菜单窗口触摸：命中按钮则该按钮动作生效，否则记为菜单背景触摸。 */
    private fun handleMenuTouch(event: MotionEvent): Boolean {
        val plan = layout ?: return false
        // 视图局部坐标下的 1px 点：与按钮矩形做半开区间相交判定，等价于"点是否落在按钮内"。
        val point = OverlayRect(
            event.x.toInt(),
            event.y.toInt(),
            event.x.toInt() + 1,
            event.y.toInt() + 1,
        )
        if (event.actionMasked != MotionEvent.ACTION_UP) {
            // 只要菜单窗口收到触摸就说明它没被桌宠挡住 —— DOWN 即记录一次接收方。
            if (event.actionMasked == MotionEvent.ACTION_DOWN) {
                menuTouchCount += 1
                lastReceiver = "MENU"
                log("touch receiver=MENU action=DOWN x=${event.x.toInt()} y=${event.y.toInt()}")
                refreshReadout()
            }
            return true
        }
        when {
            point.overlaps(localRect(plan.outsideButton)) ->
                recordMenuButton("OUTSIDE_BUTTON_RECEIVED")
            point.overlaps(localRect(plan.overlapButton)) ->
                recordMenuButton("OVERLAP_BUTTON_RECEIVED")
            point.overlaps(localRect(plan.closeButton)) -> {
                lastReceiver = "MENU"
                lastEvent = "CLOSE_BUTTON_RECEIVED"
                log("touch receiver=MENU action=CLOSE_BUTTON")
                closeMenuProbe()
            }
            else -> {
                lastReceiver = "MENU"
                lastEvent = "MENU_TOUCH_RECEIVED"
                log("touch receiver=MENU action=BACKGROUND")
                refreshReadout()
            }
        }
        return true
    }

    private fun recordMenuButton(event: String) {
        lastReceiver = "MENU"
        lastEvent = event
        log("touch receiver=MENU action=$event menuTouchCount=$menuTouchCount")
        refreshReadout()
    }

    /** 屏幕坐标按钮矩形 → 视图局部坐标（菜单视图原点 = menuRect 左上角）。 */
    private fun localRect(screen: OverlayRect): OverlayRect {
        val plan = layout ?: return screen
        return screen.translate(-plan.menuRect.left, -plan.menuRect.top)
    }

    /** 操作者循环记录"实际看到的顶层窗口"。 */
    private fun cycleActualVisualTop() {
        actualVisualTop =
            if (actualVisualTop == ProbeWindowKind.PET.wire) ProbeWindowKind.MENU.wire
            else ProbeWindowKind.PET.wire
        lastReceiver = "PET"
        lastEvent = "ACTUAL_TOP_TOGGLED"
        log("actualVisualTop=$actualVisualTop (operator)")
        refreshReadout()
    }

    /** 轻点落在蓝块底部"实际顶层"按钮区域内。 */
    private fun actualToggleHit(viewY: Float): Boolean {
        val v = petView ?: return false
        val inset = DualWindowProbePlanner.dp(density(), 8f)
        val h = DualWindowProbePlanner.dp(density(), 30f)
        return viewY >= (v.height - h - inset)
    }

    // ------------------------------------------------------------------
    // 读out / 日志 / 配置
    // ------------------------------------------------------------------

    private fun refreshReadout() {
        // 生产窗口一旦出现，任何"通过"结论都必须立刻作废（绝不报告假通过）。
        probeValid = DualWindowProbeContract.effectiveProbeValid(
            storedProbeValid = probeValid,
            productionWindowAttached = productionWindowAttachedProvider(),
        )
        // 锚点不变式：菜单矩形必须据"桌宠当前矩形"计算；一旦不一致立刻作废。
        if (running && !anchorMatchesNow()) {
            if (probeValid) {
                log(
                    "${DualWindowProbeContract.REASON_ANCHOR_MISMATCH} " +
                        "anchor=${menuAnchorPetRect.probeText()} " +
                        "currentPet=${currentPetRect().probeText()}",
                )
            }
            invalidReason = DualWindowProbeContract.REASON_ANCHOR_MISMATCH
            probeValid = DualWindowProbeContract.applyAnchorInvariant(probeValid, false)
        }
        petView?.invalidate()
    }

    private fun anchorMatchesNow(): Boolean =
        DualWindowProbeContract.anchorMatches(menuAnchorPetRect, currentPetRect())

    private fun currentPetRect(): OverlayRect {
        val p = petParams ?: return layout?.petRect ?: OverlayRect(0, 0, 0, 0)
        return OverlayRect(p.x, p.y, p.x + p.width, p.y + p.height)
    }

    /** 菜单窗口**当前**实际矩形（关闭态即 1×1 角落）；未挂载 ⇒ null。 */
    private fun currentMenuWindowRect(): OverlayRect? {
        val p = menuParams ?: return null
        if (menuView == null) return null
        return OverlayRect(p.x, p.y, p.x + p.width, p.y + p.height)
    }

    /** 冻结状态的强类型取值（供 [statusMap] 与日志用）。 */
    private fun statusValues(): DualWindowProbeContract.ProbeStatus {
        val currentPet = currentPetRect()
        val anchor = menuAnchorPetRect
        val plan = layout
        val productionAttached = productionWindowAttachedProvider()
        return DualWindowProbeContract.ProbeStatus(
            probeValid = probeValid,
            productionWindowAttached = productionAttached,
            probeWindowCount = probeWindowCount,
            expectedProbeWindowCount = DualWindowProbeContract.EXPECTED_PROBE_WINDOW_COUNT,
            totalKnownOverlayWindowCount = DualWindowProbeContract.totalKnownOverlayWindowCount(
                productionWindowAttached = productionAttached,
                probeWindowCount = probeWindowCount,
            ),
            petAddCount = ledger.petAddCount,
            menuAddCount = ledger.menuAddCount,
            petLastAddSequence = ledger.petLastAddSequence,
            menuLastAddSequence = ledger.menuLastAddSequence,
            addSequence = ledger.addSequence,
            currentExpectedTopWindow = ledger.currentExpectedTopWindow().wire,
            actualVisualTop = actualVisualTop,
            menuWasReaddedAfterPet = ledger.menuWasReaddedAfterPet,
            menuAttached = menuView != null,
            menuTouchable = menuTouchable,
            menuAnchorPetRect = anchor.probeText(),
            currentPetScreenRect = currentPet.probeText(),
            currentMenuWindowRect = currentMenuWindowRect().probeText(),
            anchorMatchesCurrentPet = DualWindowProbeContract.anchorMatches(anchor, currentPet),
            menuDirection = plan?.menuDirection ?: DualWindowProbeContract.NONE,
            verticalMode = plan?.verticalMode ?: DualWindowProbeContract.NONE,
            clampedByScreen = plan?.clampedByScreen ?: false,
            lastWindowOperation = lastWindowOperation,
            lastTouchReceiver = lastReceiver,
            orientation = orientationName(),
            deviceModel = Build.MODEL,
            sdkInt = Build.VERSION.SDK_INT,
        )
    }

    /** Flutter 侧 `getDualWindowProbeStatus` 的返回值（恰好冻结 key 集）。 */
    fun statusMap(): Map<String, Any?> =
        DualWindowProbeContract.statusMap(statusValues())

    /** 蓝块**只**显示这三件事：`PET` / top 判断（期望 vs 实际）/ 最近触摸接收方。 */
    private fun blockLines(): List<String> = listOf(
        "PET",
        "top exp=${ledger.currentExpectedTopWindow().wire} act=$actualVisualTop",
        "touch=$lastReceiver",
    )

    private fun orientationName(): String =
        if (context.resources.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE) {
            "landscape"
        } else {
            "portrait"
        }

    private fun screenSizeText(): String {
        val dm = context.resources.displayMetrics
        return "${dm.widthPixels}x${dm.heightPixels}"
    }

    /** 统一日志前缀（任务要求 tag = `probe.dual`）。 */
    private fun log(message: String) = OverlayLog.log("probe.dual $message")

    /**
     * 记录**每一次** add / remove / updateViewLayout（带序列号与窗口），
     * 同时更新 [lastWindowOperation]。
     */
    private fun logWindowOp(op: String, window: ProbeWindowKind, seq: Int, detail: String = "") {
        lastWindowOperation = "$op ${window.wire} seq=$seq"
        val suffix = if (detail.isEmpty()) "" else " $detail"
        log("op=$op window=${window.wire} seq=$seq$suffix")
    }

    /** 启动日志契约块：逐行输出**完整** `probe.dual ...`（便于真机直接 grep 比对）。 */
    private fun logStartContract(productionWindowAttached: Boolean, reason: String?) {
        DualWindowProbeContract.startContractLines(
            knownWindows = DualWindowProbeContract.EXPECTED_PROBE_WINDOW_COUNT,
            productionWindowAttached = productionWindowAttached,
            probeValid = probeValid,
            reason = reason,
        ).forEach { OverlayLog.log(it) }
    }

    /** 把冻结状态逐条写进日志（保证"屏上/通道看到 = 日志可核对"）。 */
    private fun logStatus() {
        DualWindowProbeContract.statusMap(statusValues()).forEach { (key, value) ->
            log("status $key=$value")
        }
    }

    /**
     * 窗口配置（两个窗口完全一致，唯一区别是尺寸、位置与 flags）。
     *
     * * 类型：`TYPE_APPLICATION_OVERLAY`（API>=26；低版本沿用生产同款 [OverlayWindowSpec.windowType]）；
     * * 标志：复用 [OverlayWindowSpec.windowFlags] 的 `touchThrough=false` 语义
     *   （`FLAG_NOT_FOCUSABLE | FLAG_NOT_TOUCH_MODAL | FLAG_LAYOUT_NO_LIMITS`），**绝不**加
     *   `FLAG_NOT_TOUCHABLE`（否则触摸收不到，探测无意义）；
     * * 格式：`PixelFormat.TRANSLUCENT`；gravity：`TOP or START`；alpha=1；
     * * API>=28 设 `LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES`（与生产窗口一致）。
     */
    private fun paramsFor(rect: OverlayRect): WindowManager.LayoutParams =
        WindowManager.LayoutParams(
            rect.width.coerceAtLeast(1),
            rect.height.coerceAtLeast(1),
            OverlayWindowSpec.windowType(Build.VERSION.SDK_INT),
            OverlayWindowSpec.windowFlags(touchThrough = false),
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = rect.left
            y = rect.top
            alpha = 1f
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                layoutInDisplayCutoutMode =
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
            }
        }

    // ------------------------------------------------------------------
    // 自绘 View
    // ------------------------------------------------------------------

    /** 桌宠探测块：实心蓝色圆角矩形 + `PET` / top 判断 / 触摸接收方 + 一枚实际顶层切换按钮；可拖拽。 */
    private inner class PetProbeView(context: Context) : View(context) {

        private val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.rgb(0x1E, 0x6F, 0xD6) }
        private val text = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.WHITE
            textSize = sp(11f)
            isFakeBoldText = true
        }
        private val toggleFill = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = 0xCC111111.toInt() }
        private val toggleStroke = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = dp(2f).toFloat()
            color = Color.WHITE
        }
        private val corner = dp(14f)

        init {
            isClickable = true
            isFocusable = false
        }

        override fun onDraw(canvas: Canvas) {
            super.onDraw(canvas)
            val r = corner.toFloat()
            canvas.drawRoundRect(RectF(0f, 0f, width.toFloat(), height.toFloat()), r, r, fill)

            val lines = blockLines()
            // 顶部大字 PET
            text.textSize = sp(20f)
            text.textAlign = Paint.Align.CENTER
            canvas.drawText(lines[0], width / 2f, sp(24f), text)

            // 下方两行：top 判断 / 触摸接收方。
            text.textAlign = Paint.Align.LEFT
            text.textSize = sp(11f)
            val lineHeight = text.textSize * 1.3f
            var y = sp(24f) + lineHeight
            for (i in 1 until lines.size) {
                canvas.drawText(lines[i], dp(8f).toFloat(), y, text)
                y += lineHeight
            }

            // 底部"实际顶层"切换按钮。
            val inset = dp(8f)
            val buttonTop = height - dp(30f) - inset
            val rect = RectF(
                dp(8f).toFloat(),
                buttonTop.toFloat(),
                width - dp(8f).toFloat(),
                height - inset.toFloat(),
            )
            canvas.drawRoundRect(rect, r, r, toggleFill)
            canvas.drawRoundRect(rect, r, r, toggleStroke)
            text.textAlign = Paint.Align.CENTER
            text.textSize = sp(11f)
            val baseline = rect.centerY() - (text.descent() + text.ascent()) / 2f
            canvas.drawText("ACTUAL: $actualVisualTop", rect.centerX(), baseline, text)
        }

        override fun onTouchEvent(event: MotionEvent): Boolean = handlePetTouch(event)

        private fun sp(value: Float): Float =
            TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, value, resources.displayMetrics)

        private fun dp(value: Float): Int = DualWindowProbePlanner.dp(resources.displayMetrics.density, value)
    }

    /** 菜单探测块：半透明色块 + `OUTSIDE(xx%)` / `CLOSE MENU` 三个按钮。 */
    private inner class MenuProbeView(context: Context) : View(context) {

        private val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = 0x8822AA55.toInt() }
        private val buttonFill = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = 0xCC111111.toInt() }
        private val buttonStroke = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = dp(2f).toFloat()
            color = Color.WHITE
        }
        private val text = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.WHITE
            textAlign = Paint.Align.CENTER
            textSize = sp(11f)
            isFakeBoldText = true
        }
        private val corner = dp(10f).toFloat()

        init {
            isClickable = true
            isFocusable = false
        }

        override fun onDraw(canvas: Canvas) {
            super.onDraw(canvas)
            canvas.drawRect(0f, 0f, width.toFloat(), height.toFloat(), fill)
            val plan = layout ?: return
            val pct = (plan.overlapRatio * 100f).roundToInt()
            drawButton(canvas, plan.outsideButton, "OUTSIDE")
            drawButton(canvas, plan.overlapButton, "OVERLAP($pct%)")
            drawButton(canvas, plan.closeButton, "CLOSE MENU")
        }

        private fun drawButton(canvas: Canvas, screen: OverlayRect, label: String) {
            val plan = layout ?: return
            val local = screen.translate(-plan.menuRect.left, -plan.menuRect.top)
            val rect = RectF(
                local.left.toFloat(),
                local.top.toFloat(),
                local.right.toFloat(),
                local.bottom.toFloat(),
            )
            canvas.drawRoundRect(rect, corner, corner, buttonFill)
            canvas.drawRoundRect(rect, corner, corner, buttonStroke)
            val baseline = rect.centerY() - (text.descent() + text.ascent()) / 2f
            canvas.drawText(label, rect.centerX(), baseline, text)
        }

        override fun onTouchEvent(event: MotionEvent): Boolean = handleMenuTouch(event)

        private fun sp(value: Float): Float =
            TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, value, resources.displayMetrics)

        private fun dp(value: Float): Int = DualWindowProbePlanner.dp(resources.displayMetrics.density, value)
    }
}

package asia.akechi.petlife.overlay

import kotlin.math.roundToInt

// =============================================================================================
// 双悬浮窗（桌宠窗 + 菜单窗）的**纯逻辑**部分。
//
// 背景（真机探测已验证，见 DualWindowLayerProbe 的类注释）：
//   * 同类型 `TYPE_APPLICATION_OVERLAY` 窗口：先加菜单窗、后加桌宠窗 ⇒ 桌宠稳定压在菜单之上；
//   * 菜单窗**只加一次**，之后开/关都只是 `updateViewLayout`（不改 z-order、不漂移）；
//   * 关菜单 = 一次 `updateViewLayout`：加 `FLAG_NOT_TOUCHABLE` + 缩到 1×1 + 移到安全角落 + 内容 GONE；
//   * 开菜单 = 一次 `updateViewLayout`：按桌宠**当前**屏幕矩形重算菜单矩形（镜像 + 垂直偏置 + 夹取）；
//   * 桌宠窗的几何**永不**因菜单开合而改变 ⇒ 桌宠不可能漂移。
//
// 本文件只放**不依赖任何 `android.*` 类型**的部分，因此可以在 JVM 单测里逐条打靶；
// 真正的 addView / updateViewLayout 在 [DualWindowMenuWindow] 与 [PetOverlayManager] 里。
//
// 抽取自探测器的 production 版（**不 import 探测器本身**）：加序账本 + 关闭态矩形/窗口状态 +
// 「菜单矩形据桌宠当前矩形重算」的规划器 + 单/双窗口运行模式决策。
// =============================================================================================

/** 双窗口模式下的两类窗口（加/减/更新都按它记账）。 */
internal enum class OverlayWindowKind(val wire: String) {
    MENU("menu"),
    PET("pet"),
}

/**
 * 加/减/更新账本（**纯逻辑，可 JVM 单测**）。
 *
 * 与探测器里的 `ProbeLayerLedger` 同源，但语义收敛为**生产契约**：
 * * 菜单窗**恰好 add 一次**；反复开/关只记 [recordUpdate]（⇒ `menuAddCount` 恒为 1）；
 * * 桌宠窗**恰好 add 一次**，且**永不**因菜单开合被 remove / 重加；
 * * `currentExpectedTopWindow` 只由「最后一次 add 的操作序」推出 ——
 *   菜单的 `updateViewLayout` **不会**把它错误地抬到桌宠之上。
 */
internal class DualWindowWindowLedger {

    private val adds = ArrayList<OverlayWindowKind>(4)

    var petAddCount: Int = 0
        private set

    var menuAddCount: Int = 0
        private set

    var petRemoveCount: Int = 0
        private set

    var menuRemoveCount: Int = 0
        private set

    /** 菜单窗当前是否已挂载。 */
    var menuAttached: Boolean = false
        private set

    /** 桌宠窗当前是否已挂载。 */
    var petAttached: Boolean = false
        private set

    /** 全局单调操作序（每次 add / remove / updateViewLayout 都 +1）。 */
    var operationSequence: Int = 0
        private set

    var petLastAddSequence: Int = 0
        private set

    var menuLastAddSequence: Int = 0
        private set

    /** 菜单是否在桌宠出现之后被**重加**过（正常恒为 false）。 */
    var menuWasReaddedAfterPet: Boolean = false
        private set

    fun history(): List<OverlayWindowKind> = adds.toList()

    /** 前两次加窗序 —— 「固定加序 menu→pet」的可判定形式。 */
    fun initialOrder(): List<OverlayWindowKind> = adds.take(2)

    fun initialOrderLabel(): String = initialOrder().joinToString("→") { it.wire }

    fun addOrderLabel(): String = adds.joinToString("→") { it.wire }

    /** 期望的顶层窗口：**后 add 者在上**（update 不算 add）。 */
    fun currentExpectedTopWindow(): OverlayWindowKind =
        if (petLastAddSequence > menuLastAddSequence) OverlayWindowKind.PET else OverlayWindowKind.MENU

    fun recordAdd(kind: OverlayWindowKind): Int {
        operationSequence += 1
        adds.add(kind)
        when (kind) {
            OverlayWindowKind.PET -> {
                petAddCount += 1
                petAttached = true
                petLastAddSequence = operationSequence
            }
            OverlayWindowKind.MENU -> {
                menuAddCount += 1
                menuAttached = true
                menuLastAddSequence = operationSequence
                if (petAddCount > 0) menuWasReaddedAfterPet = true
            }
        }
        return operationSequence
    }

    fun recordRemove(kind: OverlayWindowKind): Int {
        operationSequence += 1
        when (kind) {
            OverlayWindowKind.PET -> {
                petRemoveCount += 1
                petAttached = false
            }
            OverlayWindowKind.MENU -> {
                menuRemoveCount += 1
                menuAttached = false
            }
        }
        return operationSequence
    }

    /** 记一次 `updateViewLayout`（**不改**加/减计数，只推进全局操作序）。 */
    fun recordUpdate(@Suppress("UNUSED_PARAMETER") kind: OverlayWindowKind): Int {
        operationSequence += 1
        return operationSequence
    }

    /** 加减配对自检：任何窗口的移除次数都不得超过其添加次数。 */
    fun isPaired(): Boolean =
        petRemoveCount <= petAddCount && menuRemoveCount <= menuAddCount

    /** 窗口纪元重置（新服务/新窗口会话）。 */
    fun reset() {
        adds.clear()
        petAddCount = 0
        menuAddCount = 0
        petRemoveCount = 0
        menuRemoveCount = 0
        menuAttached = false
        petAttached = false
        operationSequence = 0
        petLastAddSequence = 0
        menuLastAddSequence = 0
        menuWasReaddedAfterPet = false
    }
}

/**
 * 菜单窗的**纯状态快照**（打开/关闭态的窗口几何 + 是否可触摸 + 内容是否可见）。
 *
 * 之所以把它做成纯数据：单测要能直接断言「关闭态 = 不可触摸 + 1×1 + 角落 + 内容 GONE」，
 * 而不必真的去碰 `WindowManager`。
 */
internal data class DualWindowMenuWindowState(
    val touchable: Boolean,
    val width: Int,
    val height: Int,
    val left: Int,
    val top: Int,
    val contentVisible: Boolean,
) {
    /** 关闭态：不可触摸 + 1×1 + 内容 GONE（与"角落"一起构成输入释放机制）。 */
    val isClosedCorner: Boolean
        get() = !touchable && width == 1 && height == 1 && !contentVisible
}

/**
 * 双窗口的**纯规格**（dp 换算 / 关闭态角落矩形 / 开与关的窗口状态）。
 *
 * 关闭态用「[OverlayWindowSpec.windowFlags] 的 `touchThrough = true`」表达 `FLAG_NOT_TOUCHABLE`，
 * 因此这里只记布尔量，不引用任何 `android.*` 常量。
 */
internal object DualWindowSceneSpec {

    /** 关闭态菜单窗缩到 1×1 后，摆到屏幕角落的内缩量（dp）。 */
    const val CLOSED_MENU_INSET_DP = 2f

    fun dp(density: Float, value: Float): Int =
        (value * density).roundToInt().coerceAtLeast(1)

    /**
     * 关闭态菜单窗的 1×1 角落矩形（内缩几 px，绝不放 (0,0) 正中以免与系统手势区打架）。
     */
    fun closedMenuRect(density: Float): OverlayRect {
        val inset = dp(density, CLOSED_MENU_INSET_DP)
        return OverlayRect(inset, inset, inset + 1, inset + 1)
    }

    /** 关闭态菜单窗状态：**不可触摸** + 1×1 + 角落 + 内容 GONE（输入释放的唯一手段）。 */
    fun closedMenuWindow(density: Float): DualWindowMenuWindowState {
        val corner = closedMenuRect(density)
        return DualWindowMenuWindowState(
            touchable = false,
            width = 1,
            height = 1,
            left = corner.left,
            top = corner.top,
            contentVisible = false,
        )
    }

    /** 打开态菜单窗状态：可触摸 + 恰好等于重算出的菜单矩形 + 内容 VISIBLE。 */
    fun openMenuWindow(rect: OverlayRect): DualWindowMenuWindowState =
        DualWindowMenuWindowState(
            touchable = true,
            width = rect.width.coerceAtLeast(1),
            height = rect.height.coerceAtLeast(1),
            left = rect.left,
            top = rect.top,
            contentVisible = true,
        )
}

/**
 * 菜单矩形规划器（**纯函数**）。
 *
 * 复用轮盘既有的 [WheelMenuGeometry.computeEnvelope]：它已经包含
 * **左右镜像**（桌宠在屏幕左半 → 菜单向右，右半 → 向左）、**垂直偏置**（贴近下边界 → 菜单移到上方）
 * 与**屏幕夹取**。这里只做一件事：把「桌宠**当前**屏幕矩形」喂进去并取出菜单窗口矩形。
 *
 * 「当前」是要点：**绝不**使用缓存的首次桌宠矩形 —— 每次开菜单、拖拽、贴边、旋转/分屏都重新调用。
 */
internal object DualWindowMenuPlanner {

    fun envelopeFromPet(
        petScreenRect: OverlayRect,
        bounds: OverlayBounds,
        content: PetContentBounds?,
        maxItemCount: Int,
        spec: WheelMenuSpec,
        settings: WheelMenuLayoutSettings,
        previousDirection: WheelExpandDirection? = null,
        previousVerticalMode: WheelVerticalMode? = null,
    ): WheelMenuEnvelope? {
        if (!petScreenRect.isUsable) return null
        return runCatching {
            WheelMenuGeometry.computeEnvelope(
                bounds = bounds,
                petWindowRect = petScreenRect,
                content = content,
                maxItemCount = maxItemCount,
                spec = spec,
                settings = settings,
                previousDirection = previousDirection,
                previousVerticalMode = previousVerticalMode,
                lockMode = false,
            )
        }.getOrNull()
    }

    /** 只取菜单窗口矩形（屏幕绝对坐标）；拿不到时返回 null。 */
    fun menuRectFromPet(
        petScreenRect: OverlayRect,
        bounds: OverlayBounds,
        content: PetContentBounds?,
        maxItemCount: Int,
        spec: WheelMenuSpec,
        settings: WheelMenuLayoutSettings,
        previousDirection: WheelExpandDirection? = null,
        previousVerticalMode: WheelVerticalMode? = null,
    ): OverlayRect? = envelopeFromPet(
        petScreenRect = petScreenRect,
        bounds = bounds,
        content = content,
        maxItemCount = maxItemCount,
        spec = spec,
        settings = settings,
        previousDirection = previousDirection,
        previousVerticalMode = previousVerticalMode,
    )?.windowRect
}

/**
 * 双窗口**场景模型**（纯数据）：桌宠窗矩形 + 菜单窗矩形 + 菜单开合。
 *
 * 硬不变式：**菜单开合 / 菜单窗移动都绝不改变桌宠窗矩形** —— [petGeometryEquals] 直接打靶它。
 */
internal data class DualWindowScene(
    val petWindowRect: OverlayRect,
    val menuWindowRect: OverlayRect?,
    val menuOpen: Boolean,
) {
    fun petGeometryEquals(other: DualWindowScene): Boolean =
        petWindowRect == other.petWindowRect

    /** 打开菜单：只改菜单窗矩形与开合标志，**桌宠窗矩形原样保留**。 */
    fun withMenuOpened(menuWindowRect: OverlayRect): DualWindowScene =
        copy(menuWindowRect = menuWindowRect, menuOpen = true)

    /** 关闭菜单：菜单窗矩形回到 null，**桌宠窗矩形原样保留**。 */
    fun withMenuClosed(): DualWindowScene =
        copy(menuWindowRect = null, menuOpen = false)

    /** 拖拽桌宠：桌宠窗矩形移动，菜单窗矩形跟随重算（若菜单开着）。 */
    fun withPetMoved(petWindowRect: OverlayRect, menuWindowRect: OverlayRect?): DualWindowScene =
        copy(
            petWindowRect = petWindowRect,
            menuWindowRect = if (menuOpen) menuWindowRect else null,
        )

    companion object {
        fun closed(petWindowRect: OverlayRect): DualWindowScene =
            DualWindowScene(petWindowRect = petWindowRect, menuWindowRect = null, menuOpen = false)

        fun open(petWindowRect: OverlayRect, menuWindowRect: OverlayRect): DualWindowScene =
            DualWindowScene(
                petWindowRect = petWindowRect,
                menuWindowRect = menuWindowRect,
                menuOpen = true,
            )
    }
}

/** 悬浮窗运行模式（可运行时切换；默认双窗口）。 */
internal enum class OverlayMode(val wire: String) {
    /** 单窗口（相册式分层）：菜单作为同一窗口内的一层。 */
    SINGLE_WINDOW("single"),

    /** 双窗口：桌宠窗 + 固定菜单窗（菜单只加一次）。 */
    DUAL_WINDOW("dual"),
}

/**
 * 运行模式决策（**纯函数**）。
 *
 * 规则：请求双窗口 **且** 双窗口建窗成功 ⇒ 双窗口；否则一律回退单窗口
 * （「绝不让用户失去桌宠窗」是硬约束 —— 建窗失败必须回退，且由调用方记日志）。
 */
internal object DualWindowModeResolver {

    fun resolve(requestedDual: Boolean, dualSetupSucceeded: Boolean): OverlayMode =
        if (requestedDual && dualSetupSucceeded) OverlayMode.DUAL_WINDOW else OverlayMode.SINGLE_WINDOW

    /** 回退原因码（null = 无需回退）。 */
    fun fallbackReason(requestedDual: Boolean, dualSetupSucceeded: Boolean): String? =
        if (requestedDual && !dualSetupSucceeded) REASON_DUAL_SETUP_FAILED else null

    const val REASON_DUAL_SETUP_FAILED = "dual-window-setup-failed"
}

// =============================================================================================
// 打开序列的**纯逻辑**（Phase 4C-6B-4 缺陷修复：菜单打开的"第一帧"）
//
// 真机症状：菜单打开时，视觉先出现在**最终位置之上**，再滑到正确位置。
// 根因是"同一次打开里把三件事揉在一起"：改窗口矩形 + 显示内容 + 起动画，
// 而动画可能早于窗口真实布局到目标尺寸那一帧就开始了。
//
// 这里把"准备布局"与"起动画"拆成两个可判定的阶段，且**全部是纯逻辑**（不引用任何 android.*）：
//   * [MenuOpenSequencer]：会话号 + 有界帧计数 + "布局达标才允许第一次动画 / 才允许变成可交互"；
//   * [MenuOpenCoordinates]：锚点 / 枢轴一律换算到**菜单窗口局部坐标**（绝不用屏幕原始坐标）。
//
// 帧时序（真机 addView / updateViewLayout / onPreDraw）无法在 JVM 里假装通过，
// 但那部分必须能通过"决策函数"逐条打靶 —— 这正是本文件的意义。
// =============================================================================================

/**
 * 菜单内容层在打开序列中的**三态可见性**（纯逻辑，可 JVM 单测）。
 *
 * 这是"准备布局"与"关闭"能并存的关键：
 * * [gone]（关闭态）：不参与测量/布局、不绘制、不吃触摸；
 * * [invisible]（准备布局态）：**参与测量/布局**（因此 [WheelMenuView] 会被量到菜单窗的目标尺寸），
 *   但**不绘制**、**不吃触摸**；
 * * [visible]（打开态）：参与测量/布局、绘制、且允许交互。
 *
 * 缺陷根因：准备阶段若用 `GONE`，[WheelMenuView] 根本不参与测量 ⇒ 宿主窗的测量尺寸
 * 无法证明"轮盘已被量到目标矩形"，动画仍可能早于真实布局起跑。因此准备态必须是
 * [invisible]（**不是** alpha=0 —— 那只是不绘制，语义上仍是"可见/参与布局"，且会让
 * 宿主测到 0×0 之外的假象无处可查）。
 */
internal enum class MenuContentVisibility(val wire: String) {
    gone("GONE"),
    invisible("INVISIBLE"),
    visible("VISIBLE"),
    ;

    /** 是否参与测量/布局（只有 [gone] 不参与 —— View 层映射为 `GONE`）。 */
    val participatesInLayout: Boolean get() = this != gone

    /** 是否会绘制菜单内容（只有 [visible] 会 —— 映射为 `View.VISIBLE`）。 */
    val draws: Boolean get() = this == visible

    /** 是否允许菜单交互（只有 [visible]）。 */
    val interactive: Boolean get() = this == visible
}

/** 打开序列的阶段（纯逻辑，可 JVM 单测）。 */
internal enum class MenuOpenPhase {
    /** 还没有开始本次打开。 */
    idle,

    /** 已把菜单窗摆到目标矩形，正在等"真实布局到目标尺寸"的那一帧。 */
    awaitingLayout,

    /** 布局达标：已允许起动画 / 变成可交互（恰好一次）。 */
    ready,

    /** 布局超时：直接显示在最终位置，不播动画（菜单仍完全可用）。 */
    degraded,

    /** 本次打开被关闭 / 新会话取代：此后一切回调都必须惰性。 */
    cancelled,
}

/**
 * 一次布局回调的**决策**（纯数据）。
 *
 * [isInert] 为 true 表示"这一帧什么都不做" —— 陈旧会话 / 未达标都返回它，
 * 从而保证"旧会话的回调绝不启动新菜单的动画、绝不显示内容、绝不清 FLAG_NOT_TOUCHABLE"。
 */
internal data class MenuOpenDecision(
    val startAnimation: Boolean = false,
    val showContent: Boolean = false,
    val clearNotTouchable: Boolean = false,
    val degrade: Boolean = false,
    val reason: String? = null,
) {
    val isInert: Boolean
        get() = !startAnimation && !showContent && !clearNotTouchable && !degrade
}

/**
 * 菜单打开的**布局闸门**（纯逻辑）。
 *
 * 硬规则：
 * 1. 关闭态 1×1 / 未测量（`<= 1`）时**绝不**启动动画；
 * 2. 达标判据只看 **`WheelMenuView` 的测量尺寸**（`contentMeasured == target`），
 *    **绝不**看宿主窗 `hostView` 的测量尺寸 —— `GONE` 子树不参与 measure/layout，
 *    因此宿主尺寸达标并不能证明轮盘已被量到目标矩形（这正是本次修复的缺口）；
 * 3. 只有内容达标且会话匹配时，才第一次允许"显示内容 + 去 NOT_TOUCHABLE + 起动画"；
 * 4. 动画**恰好启动一次**（`animationStarts` 是它的可断言形式）；
 * 5. 超过 [maxLayoutFrames] 帧仍未达标 ⇒ 降级：显示在最终位置、不播动画、菜单仍可用；
 * 6. 已取消 / 被新会话取代后，任何回调都惰性。
 *
 * 准备布局阶段的隐藏帧（内容 `INVISIBLE`、`contentMeasured` 可能为 0/1×1）**只是"还没到"**，
 * 绝不算视觉失败：它们只累计 [framesWaited]，不产生任何可观测动作。
 */
internal class MenuOpenSequencer(
    private val maxLayoutFrames: Int = DEFAULT_MAX_LAYOUT_FRAMES,
) {

    var sessionId: Long = 0L
        private set

    var phase: MenuOpenPhase = MenuOpenPhase.idle
        private set

    var targetWidth: Int = 0
        private set

    var targetHeight: Int = 0
        private set

    /** 本次打开锁定的方向（动画中途绝不再切换）。 */
    var direction: WheelExpandDirection? = null
        private set

    var framesWaited: Int = 0
        private set

    /** 动画实际启动次数（健康路径恒为 1，降级路径为 0）。 */
    var animationStarts: Int = 0
        private set

    var interactive: Boolean = false
        private set

    var layoutReady: Boolean = false
        private set

    /** 最近一次闸门回调里宿主窗的测量尺寸（**只用诊断**，不参与判定）。 */
    var lastHostWidth: Int = 0
        private set

    var lastHostHeight: Int = 0
        private set

    /** 最近一次闸门回调里 [WheelMenuView] 的测量尺寸（**判定依据**）。 */
    var lastContentWidth: Int = 0
        private set

    var lastContentHeight: Int = 0
        private set

    /** 最近一次回调里内容是否已量到目标尺寸（"第一帧可见"的通过判据）。 */
    val contentAtTarget: Boolean
        get() = lastContentWidth > 1 && lastContentHeight > 1 &&
            lastContentWidth == targetWidth && lastContentHeight == targetHeight

    /**
     * 开始等待布局。目标必须是**真实展开尺寸**（宽高都 > 1）；否则返回 false，
     * 由调用方直接走降级路径（绝不用 1×1 起动画）。
     */
    fun beginLayout(
        session: Long,
        width: Int,
        height: Int,
        direction: WheelExpandDirection,
    ): Boolean {
        if (width <= 1 || height <= 1) return false
        sessionId = session
        targetWidth = width
        targetHeight = height
        this.direction = direction
        phase = MenuOpenPhase.awaitingLayout
        framesWaited = 0
        animationStarts = 0
        interactive = false
        layoutReady = false
        lastHostWidth = 0
        lastHostHeight = 0
        lastContentWidth = 0
        lastContentHeight = 0
        return true
    }

    /**
     * 一次 pre-draw 布局回调（携带会话号）。
     *
     * [hostWidth]/[hostHeight] 仅记录用于诊断；[contentWidth]/[contentHeight] 是
     * [WheelMenuView] 的测量尺寸，才是达标判据。
     */
    fun onPreDraw(
        hostWidth: Int,
        hostHeight: Int,
        contentWidth: Int,
        contentHeight: Int,
        session: Long,
    ): MenuOpenDecision {
        if (!isAwaiting(session)) return MenuOpenDecision()
        recordMeasurements(hostWidth, hostHeight, contentWidth, contentHeight)
        // 只有 WheelMenuView 量到目标尺寸才算达标；宿主尺寸不参与判定。
        if (!contentAtTarget) return MenuOpenDecision()
        return beginPresentation()
    }

    /** 一次有界帧计数（postOnAnimation 链）；达标同样可以在这里第一次起动画。 */
    fun onFrame(
        hostWidth: Int,
        hostHeight: Int,
        contentWidth: Int,
        contentHeight: Int,
        session: Long,
    ): MenuOpenDecision {
        if (!isAwaiting(session)) return MenuOpenDecision()
        recordMeasurements(hostWidth, hostHeight, contentWidth, contentHeight)
        if (contentAtTarget) return beginPresentation()
        framesWaited += 1
        if (framesWaited >= maxLayoutFrames) {
            phase = MenuOpenPhase.degraded
            interactive = true
            return MenuOpenDecision(
                showContent = true,
                clearNotTouchable = true,
                degrade = true,
                reason = REASON_LAYOUT_TIMEOUT,
            )
        }
        return MenuOpenDecision()
    }

    /** 取消本次打开（关闭 / 几何变化）：携带旧会话号的回调从此惰性。 */
    fun cancel(session: Long): Boolean {
        if (session != sessionId) return false
        phase = MenuOpenPhase.cancelled
        interactive = false
        return true
    }

    /** 无条件作废（detach / 服务停止）：连阶段一起收敛，避免任何残留等待。 */
    fun invalidate() {
        phase = MenuOpenPhase.cancelled
        interactive = false
    }

    fun isCurrent(session: Long): Boolean = session != 0L && session == sessionId

    /** 方向锁定：本次打开一旦决定方向，后续候选值一律被忽略。 */
    fun lockedDirection(candidate: WheelExpandDirection): WheelExpandDirection = direction ?: candidate

    private fun isAwaiting(session: Long): Boolean =
        session == sessionId && phase == MenuOpenPhase.awaitingLayout

    private fun recordMeasurements(
        hostWidth: Int,
        hostHeight: Int,
        contentWidth: Int,
        contentHeight: Int,
    ) {
        lastHostWidth = hostWidth
        lastHostHeight = hostHeight
        lastContentWidth = contentWidth
        lastContentHeight = contentHeight
    }

    private fun beginPresentation(): MenuOpenDecision {
        phase = MenuOpenPhase.ready
        layoutReady = true
        interactive = true
        animationStarts += 1
        return MenuOpenDecision(
            startAnimation = true,
            showContent = true,
            clearNotTouchable = true,
        )
    }

    companion object {
        /** 布局等待的帧数上限（大约是 200ms@60Hz，足够覆盖一次真实 relayout）。 */
        const val DEFAULT_MAX_LAYOUT_FRAMES = 12

        /** 降级日志码（STEP 5 要求的关键字）。 */
        const val REASON_LAYOUT_TIMEOUT = "menu.open.layout_timeout"
    }
}

/**
 * 菜单窗口**局部**坐标换算（锚点 / 枢轴都必须走它）。
 *
 * 动画的坐标系只能是"菜单窗口局部"：窗口原点 + 局部坐标 = 屏幕坐标。
 * 把桌宠锚点 / 轮盘中心直接当屏幕坐标喂给动画，就是"第一帧位置对不上"的一类根因。
 */
internal object MenuOpenCoordinates {

    /** 屏幕坐标 → 菜单窗口局部坐标（相对 [windowRect] 原点）。 */
    fun toWindowLocal(screenX: Int, screenY: Int, windowRect: OverlayRect): FloatArray =
        floatArrayOf(
            (screenX - windowRect.left).toFloat(),
            (screenY - windowRect.top).toFloat(),
        )

    /** 该局部点是否落在窗口绘制范围内（用于断言"枢轴确实在窗口局部坐标系里"）。 */
    fun isWithinWindow(x: Float, y: Float, windowRect: OverlayRect): Boolean =
        x >= 0f && y >= 0f && x <= windowRect.width.toFloat() && y <= windowRect.height.toFloat()
}

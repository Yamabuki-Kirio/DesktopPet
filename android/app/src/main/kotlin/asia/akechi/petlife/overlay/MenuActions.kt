package asia.akechi.petlife.overlay

import kotlin.math.roundToInt

/**
 * 轮盘里的**原生动作**（Phase 4C-6B-3）。
 *
 * 这些动作**完全在 Kotlin 侧执行**，绝不绕一圈去问 Dart —— 否则"缩小一点"
 * 这种即时操作会变成一次跨引擎往返（用户看到的是没反应）。
 * 每个动作都复用**既有**的原生路径（命令通道 / 几何提交 / 通知启动），不复制第二套。
 */
internal enum class MenuNativeOp(val wire: String) {
    /** 隐藏桌宠：窗口收起，**服务与通知继续运行**。 */
    hide("hide"),

    /** 恢复默认位置：写回默认比例后走既有几何提交。 */
    resetPosition("reset-position"),

    /** 缩小一档。 */
    sizeDown("size-down"),

    /** 放大一档。 */
    sizeUp("size-up"),

    /** 恢复默认大小。 */
    sizeReset("size-reset"),

    /** 打开 PetLife 主界面。 */
    openApp("open-app"),
    ;

    /**
     * 该动作需要走哪条**既有命令**（null = 不需要命令通道）。
     *
     * 「隐藏」必须映射到 [OverlayCommand.HIDE]（摘窗口、保服务），
     * 而**绝不是** [OverlayCommand.STOP] —— 这条由单测钉死。
     */
    val command: OverlayCommand?
        get() = if (this == hide) OverlayCommand.HIDE else null
}

internal object MenuNativeOps {

    /** 动作 wire → 原生操作（与 [WheelMenuAction] 的 wire 一一对应，没有第二套命名）。 */
    fun fromWire(raw: String?): MenuNativeOp? = when (raw) {
        WheelMenuAction.hideOverlay.wire -> MenuNativeOp.hide
        WheelMenuAction.resetPetPosition.wire -> MenuNativeOp.resetPosition
        WheelMenuAction.changePetSizeDown.wire -> MenuNativeOp.sizeDown
        WheelMenuAction.changePetSizeUp.wire -> MenuNativeOp.sizeUp
        WheelMenuAction.resetPetSize.wire -> MenuNativeOp.sizeReset
        WheelMenuAction.openPetLife.wire -> MenuNativeOp.openApp
        else -> null
    }

    /** 动作 wire → 既有命令（供诊断与单测：隐藏 = HIDE，绝不是 STOP）。 */
    fun commandOf(raw: String?): OverlayCommand? = fromWire(raw)?.command
}

/**
 * 桌宠大小的**纯步进**（需求 §17：区间 50%~200%，步进 10%，默认 100%）。
 *
 * 与设置页滑块共用 [PetOverlayStore.MIN_SCALE] / [PetOverlayStore.MAX_SCALE]，
 * 因此"轮盘里改到 210%"这种事在物理上不可能发生。
 */
internal object MenuPetSize {

    /** 步进 10%。 */
    const val STEP = 0.1f

    fun down(current: Float): Float = PetOverlayStore.safeScale(quantize(current) - STEP)

    fun up(current: Float): Float = PetOverlayStore.safeScale(quantize(current) + STEP)

    /** 恢复默认大小（与设置页"默认值"一致）。 */
    fun reset(@Suppress("UNUSED_PARAMETER") current: Float): Float = PetOverlayStore.DEFAULT_SCALE

    /** 展示用百分比文案（例：`130%`）。 */
    fun percent(scale: Float): String =
        "${(PetOverlayStore.safeScale(scale) * 100f).roundToInt()}%"

    /** 先吸附到 10% 网格，避免连续点击累积浮点误差（1.0000001 → 1.0）。 */
    private fun quantize(value: Float): Float {
        if (!value.isFinite()) return PetOverlayStore.DEFAULT_SCALE
        return (value / STEP).roundToInt() * STEP
    }
}

/**
 * 导航目的地的**稳定 wire 值**（与 Dart 侧冻结契约一致）。
 *
 * 原生不解释这些字符串，只是把它们放进请求 `args.destination`；
 * 真正的页面切换在 Dart 侧完成。
 */
internal object MenuDartDestinations {
    const val ASSET_LIBRARY = "assetLibrary"
    const val STATE_ASSET_MAPPING = "stateAssetMapping"
    const val LOCAL_STATISTICS = "localStatistics"
    const val CLOUD_STATISTICS = "cloudStatistics"
    const val ACCOUNT_SYNC = "accountSync"
    const val OVERLAY_SETTINGS = "overlaySettings"
}

/**
 * 菜单动作的**执行口径**（纯查表，可单测）。
 *
 * 存在的意义：把"哪些动作要先把菜单收起来""哪些动作会走几何提交"
 * 这类口径集中到一处，界面、服务与测试读的是同一份答案。
 */
internal object MenuActionPlan {

    /**
     * dartRequest 里需要"收起菜单后生效"的动作（用户已确认的口径）。
     *
     * 尺寸/自动状态这类会**改变桌宠或轮盘外观**的动作，菜单继续开着会让人以为没生效；
     * 只读类的（今日时长、同步状态…）则保持菜单在屏幕上，反馈直接显示在窗口内。
     */
    private val CLOSE_MENU_FIRST: Set<WheelMenuAction> = setOf(
        WheelMenuAction.toggleAutomaticState,
        WheelMenuAction.changeMenuScale,
        WheelMenuAction.changeButtonScale,
    )

    /** 会走 [PetOverlayManager] 既有几何提交路径的动作。 */
    private val COMMITS_GEOMETRY: Set<WheelMenuAction> = setOf(
        WheelMenuAction.resetPetPosition,
        WheelMenuAction.changePetSizeDown,
        WheelMenuAction.changePetSizeUp,
        WheelMenuAction.resetPetSize,
    )

    fun closesMenuFirst(action: WheelMenuAction): Boolean = action in CLOSE_MENU_FIRST

    /**
     * 该动作是否会走几何提交。
     *
     * 反馈层（[MenuFeedbackPolicy]）**永远**不在这个集合里 ——
     * 显示一条反馈绝不允许改变窗口几何。
     */
    fun commitsGeometry(action: WheelMenuAction): Boolean = action in COMMITS_GEOMETRY
}

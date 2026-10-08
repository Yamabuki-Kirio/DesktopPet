package asia.akechi.petlife.overlay

/**
 * 动作路由（需求 §17）。
 *
 * 四条通道**互斥且完备**：任何一个菜单动作都能且只能落到其中一条。
 */
internal enum class WheelActionRoute {
    /** 导航：打开子菜单 / 返回 / 关闭菜单 —— 原生即时生效。 */
    navigation,

    /** 原生动作：完全在 Kotlin 里执行（隐藏 / 重置位置 / 改大小 / 打开 PetLife）。 */
    native,

    /** Dart 请求：必须由 Dart 执行（自动状态、素材、记录、设置…），走请求通道。 */
    dartRequest,

    /** 只读信息项：显示一条短提示，不改任何状态。 */
    info,
}

/** 分发结果（供日志与诊断使用）。 */
internal data class WheelActionOutcome(
    val route: WheelActionRoute,
    val action: WheelMenuAction,
    val entryId: String,
    /** 宿主是否真的处理了（导航 / 原生动作可能返回 true；入队类返回 true 表示已提交）。 */
    val handled: Boolean,
)

/**
 * 轮盘宿主（由 `PetOverlayManager` 实现）。
 *
 * 刻意只有四条通道：**导航**、**原生动作**、**Dart 请求**、**只读信息**。
 * 交互层永远只调用 [WheelMenuActionDispatcher.dispatch]，不允许任何一处直接去调业务方法 ——
 * 否则"哪个动作走哪条通道"会散落在渲染代码里，接线时必然漏掉几处。
 */
internal interface WheelMenuActionHost {

    /** 导航类。返回 `true` 表示已处理（用于日志与诊断）。 */
    fun onNavigateAction(action: WheelMenuAction, entryId: String): Boolean

    /** 原生动作（必须在 Kotlin 里即刻执行，绝不绕道 Dart）。 */
    fun onNativeAction(action: WheelMenuAction, entryId: String): Boolean

    /** Dart 请求（入队 + 尝试推送）。 */
    fun onDartRequestAction(action: WheelMenuAction, entryId: String, entry: WheelMenuEntry?): Boolean

    /** 只读信息项（"当前状态""当前应用"等）。 */
    fun onInfoAction(entryId: String, entry: WheelMenuEntry)
}

/**
 * 动作 → 通道的**唯一**映射表（纯逻辑，可 JVM 单测）。
 *
 * 以前"占位 / 真实"的二元判断散在分发器里；现在改成四通道后，
 * 服务、界面与测试读的都是这一份答案。
 */
internal object WheelMenuActionRoutes {

    private val NAVIGATION: Set<WheelMenuAction> = setOf(
        WheelMenuAction.openPetMenu,
        WheelMenuAction.openAppearanceMenu,
        WheelMenuAction.openRecordsMenu,
        WheelMenuAction.openToolsMenu,
        WheelMenuAction.openSettingsMenu,
        WheelMenuAction.back,
        WheelMenuAction.closeMenu,
    )

    private val NATIVE: Set<WheelMenuAction> = setOf(
        WheelMenuAction.hideOverlay,
        WheelMenuAction.resetPetPosition,
        WheelMenuAction.changePetSizeDown,
        WheelMenuAction.changePetSizeUp,
        WheelMenuAction.resetPetSize,
        WheelMenuAction.openPetLife,
    )

    private val INFO: Set<WheelMenuAction> = setOf(WheelMenuAction.showInfo)

    fun routeOf(action: WheelMenuAction): WheelActionRoute = when (action) {
        in NAVIGATION -> WheelActionRoute.navigation
        in NATIVE -> WheelActionRoute.native
        in INFO -> WheelActionRoute.info
        else -> WheelActionRoute.dartRequest
    }

    fun nativeActions(): Set<WheelMenuAction> = NATIVE

    fun navigationActions(): Set<WheelMenuAction> = NAVIGATION

    fun infoActions(): Set<WheelMenuAction> = INFO

    /** Dart 请求动作＝除上述三类以外的全部（**必须**与冻结的路由表逐条一致）。 */
    fun dartRequestActions(): Set<WheelMenuAction> =
        WheelMenuAction.entries.toSet() - NAVIGATION - NATIVE - INFO
}

/**
 * 统一动作分发（需求 §17）。
 *
 * "轮盘只是命令的发射器"这句话就落在这里：**交互层永远只调用 [dispatch]**。
 */
internal class WheelMenuActionDispatcher(private val host: WheelMenuActionHost) {

    /** 最近一次分发的动作（诊断字段 `lastMenuAction` 的数据源）。 */
    var lastActionWire: String? = null
        private set

    var lastRoute: WheelActionRoute? = null
        private set

    fun routeOf(action: WheelMenuAction): WheelActionRoute = WheelMenuActionRoutes.routeOf(action)

    fun dispatch(action: WheelMenuAction, entryId: String, entry: WheelMenuEntry?): WheelActionOutcome {
        val route = routeOf(action)
        lastActionWire = action.wire
        lastRoute = route
        val handled = when (route) {
            WheelActionRoute.navigation -> host.onNavigateAction(action, entryId)
            WheelActionRoute.native -> host.onNativeAction(action, entryId)
            WheelActionRoute.dartRequest -> host.onDartRequestAction(action, entryId, entry)
            WheelActionRoute.info -> {
                if (entry != null) host.onInfoAction(entryId, entry)
                false
            }
        }
        return WheelActionOutcome(route, action, entryId, handled)
    }

    /**
     * 导航类动作对应的目标子菜单（`null` = 不是"进入子菜单"这条路径）。
     *
     * 单独抽出来是为了让"根条目 → 子菜单"的映射**只有一份**，
     * 界面、状态机与测试都读它。
     */
    fun targetLevelOf(action: WheelMenuAction): String? = when (action) {
        WheelMenuAction.openPetMenu -> WheelMenuCatalog.LEVEL_PET
        WheelMenuAction.openAppearanceMenu -> WheelMenuCatalog.LEVEL_APPEARANCE
        WheelMenuAction.openRecordsMenu -> WheelMenuCatalog.LEVEL_RECORDS
        WheelMenuAction.openToolsMenu -> WheelMenuCatalog.LEVEL_TOOLS
        WheelMenuAction.openSettingsMenu -> WheelMenuCatalog.LEVEL_SETTINGS
        else -> null
    }
}

package asia.akechi.petlife.overlay

/**
 * 跨端菜单动作 id 契约（Phase 4C-6B-3 契约修复）。
 *
 * 历史缺陷：原生把 [WheelMenuAction.wire]（camelCase，如 `toggleAutomaticState`）
 * 直接发给 Dart，而 Dart 执行器只认 canonical snake_case id（如 `pet_auto`），
 * 于是**每一个** Dart 请求都以 `不支持的菜单动作` 失败。
 *
 * 现在全项目只有这一份 canonical id 集合（下面 17 个常量）：
 * * [WheelMenuAction] 的 `dartRequest` 动作把 [wire] 直接设成这些常量 ⇒
 *   入队 / 日志 / `menuRequest` / `pullPendingMenuRequests` / Dart 执行器
 *   全程是**同一个字符串**；
 * * 分发器与单测都读这一份，杜绝"第二套命名"再次出现。
 *
 * 注意：**enum 常量名与界面文案都不是协议 id**，永远不要拿它们做跨端判断；
 * `navigation` / `native` / `info` 三类动作不参与本契约，也绝不发给 Dart。
 */
internal object MenuActionIds {
    const val PET_AUTO = "pet_auto"
    const val APPEARANCE_PREV = "appearance_prev"
    const val APPEARANCE_NEXT = "appearance_next"
    const val APPEARANCE_AUTO = "appearance_auto"
    const val APPEARANCE_FAV = "appearance_fav"
    const val APPEARANCE_MAPPING = "appearance_mapping"
    const val APPEARANCE_LIBRARY = "appearance_library"
    const val RECORDS_TODAY = "records_today"
    const val RECORDS_STATS = "records_stats"
    const val RECORDS_CLOUD = "records_cloud"
    const val RECORDS_TRACK = "records_track"
    const val RECORDS_SYNC = "records_sync"
    const val RECORDS_SYNC_STATE = "records_sync_state"
    const val SETTINGS_THEME = "settings_theme"
    const val SETTINGS_WHEEL_SIZE = "settings_wheel_size"
    const val SETTINGS_BUTTON_SIZE = "settings_button_size"
    const val SETTINGS_OPEN = "settings_open"

    /** 全部 canonical dart 动作 id（**唯一来源**，共 17 个）。 */
    val CANONICAL_DART_IDS: Set<String> = linkedSetOf(
        PET_AUTO,
        APPEARANCE_PREV,
        APPEARANCE_NEXT,
        APPEARANCE_AUTO,
        APPEARANCE_FAV,
        APPEARANCE_MAPPING,
        APPEARANCE_LIBRARY,
        RECORDS_TODAY,
        RECORDS_STATS,
        RECORDS_CLOUD,
        RECORDS_TRACK,
        RECORDS_SYNC,
        RECORDS_SYNC_STATE,
        SETTINGS_THEME,
        SETTINGS_WHEEL_SIZE,
        SETTINGS_BUTTON_SIZE,
        SETTINGS_OPEN,
    )

    /** 会被发往 Dart 的动作（route == dartRequest）。 */
    fun dartRequestActions(): Set<WheelMenuAction> = WheelMenuActionRoutes.dartRequestActions()

    /** 发往 Dart 的动作 id 集合（每个动作的 [WheelMenuAction.wire]）。 */
    fun dartRequestIds(): Set<String> = dartRequestActions().map { it.wire }.toSet()

    /** 该字符串是否是 canonical dart 动作 id。 */
    fun isCanonicalDartId(raw: String?): Boolean = raw != null && raw in CANONICAL_DART_IDS
}

/**
 * 轮盘菜单的**统一命令**（Phase 4C-6B-1 建立，4C-6B-3 接上真实业务）。
 *
 * 菜单只是这些命令的"发射器"：交互层永远只调用 [WheelMenuActionDispatcher.dispatch]，
 * 由它按 [WheelActionRoute] 分派到四条通道之一：
 * * `navigation` —— 打开子菜单 / 返回（原生即时执行）；
 * * `native`     —— 完全在 Kotlin 里执行（隐藏 / 重置位置 / 改大小 / 打开 PetLife）；
 * * `dartRequest`—— 必须由 Dart 执行（自动状态、素材、记录、设置…），走请求通道；
 * * `info`       —— 只读信息项，点击不产生副作用。
 *
 * [wire] 是与 Flutter / 日志 / 事件共用的稳定字符串（**不得随意改名**）：
 * `dartRequest` 动作的 wire 一律取自 [MenuActionIds] 的 canonical id，绝不是 enum 名或文案。
 */
internal enum class WheelMenuAction(val wire: String) {
    // --- 导航（原生即时执行）---
    openPetMenu("openPetMenu"),
    openAppearanceMenu("openAppearanceMenu"),
    openRecordsMenu("openRecordsMenu"),
    openToolsMenu("openToolsMenu"),
    openSettingsMenu("openSettingsMenu"),
    back("back"),
    closeMenu("closeMenu"),

    // --- native：完全在 Kotlin 里执行，绝不绕一圈问 Dart ---
    /** `root_hide`：隐藏桌宠（摘窗口），**服务与通知继续运行**。 */
    hideOverlay("hideOverlay"),
    /** `pet_home`：重置位置回默认比例。 */
    resetPetPosition("resetPetPosition"),
    changePetSizeDown("changePetSizeDown"),
    changePetSizeUp("changePetSizeUp"),
    resetPetSize("resetPetSize"),
    /** `tools_open_app`：打开 PetLife 主界面。 */
    openPetLife("openPetLife"),

    // --- dartRequest：必须由 Dart 执行（wire 一律是 canonical snake_case id）---
    toggleAutomaticState(MenuActionIds.PET_AUTO),
    previousAsset(MenuActionIds.APPEARANCE_PREV),
    nextAsset(MenuActionIds.APPEARANCE_NEXT),
    /** 自动形象（开关交给 Dart 判定与持久化）。 */
    toggleAutomaticAsset(MenuActionIds.APPEARANCE_AUTO),
    toggleFavorite(MenuActionIds.APPEARANCE_FAV),
    openStateMapping(MenuActionIds.APPEARANCE_MAPPING),
    openAssetLibrary(MenuActionIds.APPEARANCE_LIBRARY),
    showTodayUsage(MenuActionIds.RECORDS_TODAY),
    openUsageStatistics(MenuActionIds.RECORDS_STATS),
    /** 云端记录。 */
    openCloudRecords(MenuActionIds.RECORDS_CLOUD),
    toggleTracking(MenuActionIds.RECORDS_TRACK),
    syncNow(MenuActionIds.RECORDS_SYNC),
    showSyncState(MenuActionIds.RECORDS_SYNC_STATE),
    selectTheme(MenuActionIds.SETTINGS_THEME),
    /** 轮盘大小（收起菜单后在 Dart 设置页里调整）。 */
    changeMenuScale(MenuActionIds.SETTINGS_WHEEL_SIZE),
    /** 按钮大小。 */
    changeButtonScale(MenuActionIds.SETTINGS_BUTTON_SIZE),
    /** 打开完整设置。 */
    openSettings(MenuActionIds.SETTINGS_OPEN),

    /** 只读信息项（"当前状态""当前应用"），点击不产生副作用。 */
    showInfo("showInfo"),
}

/** 轮盘图标 key（**原创几何**，见 `WheelMenuIcons`；不使用任何游戏美术资源）。 */
internal enum class WheelMenuIcon {
    pet,
    appearance,
    record,
    tools,
    gear,
    hide,
    cycle,
    state,
    hand,
    refresh,
    pin,
    resize,
    home,
    back,
    prev,
    next,
    shuffle,
    heart,
    character,
    mapping,
    library,
    clock,
    app,
    pause,
    sync,
    cloud,
    chart,
    timer,
    bolt,
    star,
    edit,
    palette,
    opacity,
    ruler,
    vibrate,
    sound,
    info,
    restart,
    power,
}

/**
 * 一个轮盘条目。
 *
 * [titleEn] / [titleZh] / [description] 三者是需求 §3 的"大号倾斜英文标题 +
 * 中文名称 + 一句简短说明"三层信息；根菜单条目三者齐全，子菜单条目通常
 * 只有中文名（`titleEn` 为空时渲染层只画中文）。
 */
internal data class WheelMenuEntry(
    val id: String,
    val action: WheelMenuAction,
    val icon: WheelMenuIcon,
    val labelZh: String,
    val titleEn: String? = null,
    val description: String? = null,
    val enabled: Boolean = true,
    /** `true` = 固定槽位的"返回"（永远排在视觉最下方，不参与重排）。 */
    val isBack: Boolean = false,
)

/** 一个菜单层级。 */
internal data class WheelMenuLevel(
    val id: String,
    val titleEn: String,
    val titleZh: String,
    val entries: List<WheelMenuEntry>,
) {
    val itemCount: Int get() = entries.size
}

/**
 * 菜单目录（需求 §4 / §17）：根菜单固定六项，五个子菜单 + 一个直接动作（隐藏）。
 *
 * 每个条目的 [WheelMenuEntry.id] 是**稳定契约**（日志、请求 `args`、诊断与单测都读它），
 * [WheelMenuEntry.labelZh] 只用于显示 —— **任何业务判断都不得依赖文案**。
 * 动态状态（自动状态开/关、暂停采集、轮盘大小 130%……）通过既有的
 * `infoProvider`（选中项实时信息）机制展示，绝不改写 id。
 */
internal object WheelMenuCatalog {

    const val ROOT_ID = "root"
    const val LEVEL_PET = "pet"
    const val LEVEL_APPEARANCE = "appearance"
    const val LEVEL_RECORDS = "records"
    const val LEVEL_TOOLS = "tools"
    const val LEVEL_SETTINGS = "settings"

    /** 固定返回键（需求 §5）。 */
    private val BACK = WheelMenuEntry(
        id = "back",
        action = WheelMenuAction.back,
        icon = WheelMenuIcon.back,
        labelZh = "返回",
        description = "回到上一层",
        isBack = true,
    )

    /** 根菜单：桌宠 / 形象 / 记录 / 工具 / 设置 / 隐藏。 */
    val ROOT: WheelMenuLevel = WheelMenuLevel(
        id = ROOT_ID,
        titleEn = "PETLIFE",
        titleZh = "桌宠",
        entries = listOf(
            WheelMenuEntry(
                id = "root_pet",
                action = WheelMenuAction.openPetMenu,
                icon = WheelMenuIcon.pet,
                labelZh = "桌宠",
                titleEn = "PET",
                description = "AUTO MODE",
            ),
            WheelMenuEntry(
                id = "root_appearance",
                action = WheelMenuAction.openAppearanceMenu,
                icon = WheelMenuIcon.appearance,
                labelZh = "形象",
                titleEn = "APPEARANCE",
                description = "角色与素材",
            ),
            WheelMenuEntry(
                id = "root_records",
                action = WheelMenuAction.openRecordsMenu,
                icon = WheelMenuIcon.record,
                labelZh = "记录",
                titleEn = "RECORD",
                description = "今日使用时长",
            ),
            WheelMenuEntry(
                id = "root_tools",
                action = WheelMenuAction.openToolsMenu,
                icon = WheelMenuIcon.tools,
                labelZh = "工具",
                titleEn = "TOOLS",
                description = "专注与快捷入口",
            ),
            WheelMenuEntry(
                id = "root_settings",
                action = WheelMenuAction.openSettingsMenu,
                icon = WheelMenuIcon.gear,
                labelZh = "设置",
                titleEn = "SYSTEM",
                description = "主题与服务",
            ),
            WheelMenuEntry(
                id = "root_hide",
                action = WheelMenuAction.hideOverlay,
                icon = WheelMenuIcon.hide,
                labelZh = "隐藏",
                titleEn = "HIDE",
                description = "隐藏桌宠（服务继续运行）",
            ),
        ),
    )

    /**
     * 桌宠子菜单。
     *
     * 顺序（需求 §17 冻结）：缩小 / 放大 / 恢复默认 / 自动状态 / 当前状态 / 重置位置 / 返回。
     * `pet_current` 是**只读信息项**（原有原生读取，保持原样）。
     */
    val PET: WheelMenuLevel = WheelMenuLevel(
        id = LEVEL_PET,
        titleEn = "PET",
        titleZh = "桌宠",
        entries = listOf(
            WheelMenuEntry("pet_size_down", WheelMenuAction.changePetSizeDown, WheelMenuIcon.resize, "缩小"),
            WheelMenuEntry("pet_size_up", WheelMenuAction.changePetSizeUp, WheelMenuIcon.resize, "放大"),
            WheelMenuEntry("pet_size_reset", WheelMenuAction.resetPetSize, WheelMenuIcon.refresh, "恢复默认"),
            WheelMenuEntry("pet_auto", WheelMenuAction.toggleAutomaticState, WheelMenuIcon.cycle, "自动状态"),
            WheelMenuEntry("pet_current", WheelMenuAction.showInfo, WheelMenuIcon.state, "当前状态"),
            WheelMenuEntry("pet_home", WheelMenuAction.resetPetPosition, WheelMenuIcon.home, "重置位置"),
            BACK,
        ),
    )

    /**
     * 形象子菜单。
     *
     * 顺序（需求 §17 冻结）：上一张 / 下一张 / 自动形象 / 收藏(取消收藏) /
     * 编辑状态素材 / 打开素材库 / 返回。
     */
    val APPEARANCE: WheelMenuLevel = WheelMenuLevel(
        id = LEVEL_APPEARANCE,
        titleEn = "APPEARANCE",
        titleZh = "形象",
        entries = listOf(
            WheelMenuEntry("appearance_prev", WheelMenuAction.previousAsset, WheelMenuIcon.prev, "上一张"),
            WheelMenuEntry("appearance_next", WheelMenuAction.nextAsset, WheelMenuIcon.next, "下一张"),
            WheelMenuEntry(
                "appearance_auto",
                WheelMenuAction.toggleAutomaticAsset,
                WheelMenuIcon.shuffle,
                "自动形象",
            ),
            WheelMenuEntry("appearance_fav", WheelMenuAction.toggleFavorite, WheelMenuIcon.heart, "收藏"),
            WheelMenuEntry(
                "appearance_mapping",
                WheelMenuAction.openStateMapping,
                WheelMenuIcon.mapping,
                "编辑状态素材",
            ),
            WheelMenuEntry(
                "appearance_library",
                WheelMenuAction.openAssetLibrary,
                WheelMenuIcon.library,
                "打开素材库",
            ),
            BACK,
        ),
    )

    /**
     * 记录子菜单。
     *
     * 顺序（需求 §17 冻结）：今日时长 / 当前应用 / 本机统计 / 云端记录 / 返回。
     * "当前应用"是原有的**只读信息项**（保持原样）。
     */
    val RECORDS: WheelMenuLevel = WheelMenuLevel(
        id = LEVEL_RECORDS,
        titleEn = "RECORD",
        titleZh = "记录",
        entries = listOf(
            WheelMenuEntry("records_today", WheelMenuAction.showTodayUsage, WheelMenuIcon.clock, "今日时长"),
            WheelMenuEntry("records_app", WheelMenuAction.showInfo, WheelMenuIcon.app, "当前应用"),
            WheelMenuEntry(
                "records_stats",
                WheelMenuAction.openUsageStatistics,
                WheelMenuIcon.chart,
                "本机统计",
            ),
            WheelMenuEntry(
                "records_cloud",
                WheelMenuAction.openCloudRecords,
                WheelMenuIcon.cloud,
                "云端记录",
            ),
            BACK,
        ),
    )

    /**
     * 工具子菜单。
     *
     * 顺序（需求 §17 冻结）：暂停(恢复)采集 / 立即同步 / 同步状态 / 打开 PetLife / 返回。
     * 采集与同步三项的条目 id 沿用原有的 `records_*`（**id 是稳定契约，不随层级位置改名**）。
     */
    val TOOLS: WheelMenuLevel = WheelMenuLevel(
        id = LEVEL_TOOLS,
        titleEn = "TOOLS",
        titleZh = "工具",
        entries = listOf(
            WheelMenuEntry("records_track", WheelMenuAction.toggleTracking, WheelMenuIcon.pause, "暂停采集"),
            WheelMenuEntry("records_sync", WheelMenuAction.syncNow, WheelMenuIcon.sync, "立即同步"),
            WheelMenuEntry(
                "records_sync_state",
                WheelMenuAction.showSyncState,
                WheelMenuIcon.cloud,
                "同步状态",
            ),
            WheelMenuEntry(
                "tools_open_app",
                WheelMenuAction.openPetLife,
                WheelMenuIcon.star,
                "打开 PetLife",
            ),
            BACK,
        ),
    )

    /**
     * 设置子菜单。
     *
     * 顺序（需求 §17 冻结）：轮盘主题 / 轮盘大小 / 按钮大小 / 完整设置 / 返回。
     */
    val SETTINGS: WheelMenuLevel = WheelMenuLevel(
        id = LEVEL_SETTINGS,
        titleEn = "SYSTEM",
        titleZh = "设置",
        entries = listOf(
            WheelMenuEntry("settings_theme", WheelMenuAction.selectTheme, WheelMenuIcon.palette, "轮盘主题"),
            WheelMenuEntry(
                "settings_wheel_size",
                WheelMenuAction.changeMenuScale,
                WheelMenuIcon.ruler,
                "轮盘大小",
            ),
            WheelMenuEntry(
                "settings_button_size",
                WheelMenuAction.changeButtonScale,
                WheelMenuIcon.resize,
                "按钮大小",
            ),
            WheelMenuEntry("settings_open", WheelMenuAction.openSettings, WheelMenuIcon.gear, "完整设置"),
            BACK,
        ),
    )

    private val LEVELS: Map<String, WheelMenuLevel> = listOf(
        ROOT, PET, APPEARANCE, RECORDS, TOOLS, SETTINGS,
    ).associateBy { it.id }

    fun level(id: String): WheelMenuLevel? = LEVELS[id]

    /** 子菜单 ID → 其父级永远是根菜单（层级只有两级 + 固定返回）。 */
    fun isRoot(id: String): Boolean = id == ROOT_ID

    /**
     * 一个层级最多多少项 —— 几何层据此决定按钮尺寸与环带半径。
     *
     * 4C-6B-3 起最大的一层是"形象"（6 项 + 返回 = 7）。
     */
    val maxItems: Int = LEVELS.values.maxOf { it.itemCount }

    /** 全部层级（诊断 / 单测遍历用；顺序固定）。 */
    val allLevels: List<WheelMenuLevel> get() = LEVELS.values.toList()

    /** 全部条目（诊断 / 单测遍历用）。 */
    val allEntries: List<WheelMenuEntry> get() = LEVELS.values.flatMap { it.entries }

    /** 按条目 id 查条目（**只有这一处**按 id 找文案，业务判断仍只看 id）。 */
    fun entryOf(entryId: String): WheelMenuEntry? =
        LEVELS.values.firstNotNullOfOrNull { level ->
            level.entries.firstOrNull { it.id == entryId }
        }

    /**
     * 所有条目里最长的中文标签字数。
     *
     * 用来估算"文字 chip 可能伸出刀刃多远"，好把它算进菜单窗口包围盒 ——
     * 真机反馈的"桌宠/形象/记录/工具/设置/隐藏 被窗口矩形裁切"就是漏了这一步。
     */
    val maxLabelChars: Int = LEVELS.values
        .flatMap { it.entries }
        .maxOfOrNull { it.labelZh.length }
        ?: 1

    /** 命中"直接动作"的根条目（"隐藏"不进子菜单，需求 §4.6）。 */
    fun directActionOf(levelId: String, index: Int): WheelMenuAction? {
        val level = level(levelId) ?: return null
        return level.entries.getOrNull(index)?.action
    }
}

/**
 * 菜单栈（需求 §5）。
 *
 * **只有这一处维护层级**：进入子菜单 = `push`，返回 = `pop`，
 * 关闭 = `clear`。绝不为每个子菜单写独立的返回逻辑 ——
 * 那正是"多级返回错乱"的根源。
 */
internal class WheelMenuStack {

    private val ids = ArrayList<String>()

    val depth: Int get() = ids.size

    val isEmpty: Boolean get() = ids.isEmpty()

    /** 栈顶（当前层级）；空栈返回 `null`。 */
    val currentId: String?
        get() = ids.lastOrNull()

    val current: WheelMenuLevel?
        get() = currentId?.let { WheelMenuCatalog.level(it) }

    fun path(): List<String> = ids.toList()

    /** 打开根菜单（幂等：已打开时不清空子层级）。 */
    fun open() {
        if (ids.isEmpty()) ids.add(WheelMenuCatalog.ROOT_ID)
    }

    /** 进入子菜单；非法层级**拒绝**（保持原层级，绝不产生非法路径）。 */
    fun push(levelId: String): Boolean {
        if (WheelMenuCatalog.level(levelId) == null) return false
        if (WheelMenuCatalog.isRoot(levelId)) return false
        if (ids.isEmpty()) return false
        if (ids.last() == levelId) return false
        ids.add(levelId)
        return true
    }

    /** 返回一级；在根菜单时返回 `false`（**不关闭菜单**，关闭是另一个动作）。 */
    fun pop(): Boolean {
        if (ids.size <= 1) return false
        ids.removeAt(ids.size - 1)
        return true
    }

    /** 一路回根（长按返回 / 需求 §5 的可选能力）。 */
    fun popToRoot(): Boolean {
        if (ids.size <= 1) return false
        while (ids.size > 1) ids.removeAt(ids.size - 1)
        return true
    }

    fun clear() {
        ids.clear()
    }
}

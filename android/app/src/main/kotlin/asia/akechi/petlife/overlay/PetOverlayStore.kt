package asia.akechi.petlife.overlay

import android.content.Context
import android.content.SharedPreferences
import android.view.WindowManager

/**
 * 悬浮窗 WindowManager 参数的**纯计算**部分。
 *
 * 抽出来的原因：这部分逻辑最容易写错（类型/标志/API 差异），
 * 而它又完全不需要 Context —— 因此可以在 JVM 单元测试里逐条验证，
 * 不必等到真机才发现"低版本用了不存在的窗口类型"。
 */
internal object OverlayWindowSpec {

    /**
     * 窗口类型（**两种窗口用同一个类型**）。
     *
     * 4C-6B-1.1 首版曾用"菜单用更低类型"来固定层级（`TYPE_SYSTEM_ALERT` / `TYPE_PHONE`），
     * **真机回归直接失败：点击桌宠后菜单完全没有出现**。
     * 这些遗留类型在 Android 8+ 属废弃类型，各 ROM 行为不一致（多数情况下会被直接拒绝或静默不显示），
     * 因此**不能作为正式层级方案**。
     *
     * 现行方案（需求 §2 / §3）：
     * * Android 8+ 两种窗口都用 `TYPE_APPLICATION_OVERLAY`；
     * * 层级靠 **addView 先后**（菜单后加 → 在上层）；
     * * 菜单中央缺口完全透明，桌宠透过缺口显示；
     * * 缺口区域的**拖动由菜单 View 主动转发**给 manager（不依赖窗口触摸穿透）。
     */
    fun windowType(sdkInt: Int): Int =
        if (sdkInt >= 26) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            // API 24~25 没有 TYPE_APPLICATION_OVERLAY，沿用 4C-2 起就在用、且已通过真机验收的 TYPE_PHONE。
            @Suppress("DEPRECATION")
            WindowManager.LayoutParams.TYPE_PHONE
        }

    /** 桌宠窗口类型（= [windowType]，保留独立函数只为诊断可读）。 */
    fun petWindowType(sdkInt: Int): Int = windowType(sdkInt)

    /** 轮盘菜单窗口类型（= [windowType]，同类型 + 后 addView ⇒ 天然在上层）。 */
    fun menuWindowType(sdkInt: Int): Int = windowType(sdkInt)

    /**
     * 基础标志。
     *
     * * `FLAG_NOT_FOCUSABLE`：不抢输入焦点，否则会挡住其他应用的输入法；
     * * `FLAG_NOT_TOUCH_MODAL`：窗口之外的触摸继续交给下层应用；
     * * `FLAG_LAYOUT_NO_LIMITS`：允许贴边到刘海/圆角之外（位置随后由安全区域再限制）。
     *
     * `FLAG_NOT_TOUCHABLE`（触摸穿透）**只有**用户显式开启时才加 ——
     * 默认加上会让用户无法拖动桌宠。开启后必须能从通知栏或设置页恢复。
     */
    fun windowFlags(touchThrough: Boolean): Int {
        @Suppress("DEPRECATION")
        var flags = WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
            WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
            WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS
        if (touchThrough) {
            flags = flags or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
        }
        return flags
    }
}

/**
 * 悬浮窗配置的持久化（Phase 4C）。
 *
 * **刻意不写 Flutter 的 SQLite**：前台服务可能在 Flutter 进程已被回收的情况下
 * 独立存活，那时初始化整个 Flutter 数据库既慢又可能失败。位置、缩放、
 * 当前素材这些"原生自己要用"的东西一律放 SharedPreferences。
 *
 * 键名与含义在 Phase 4C 内保持稳定；[SCHEMA_VERSION] 变化时由
 * [PetOverlayStore] 自行把无法识别的旧配置重置为默认值（不做增量迁移）。
 */
class PetOverlayStore(context: Context) {

    private val prefs: SharedPreferences =
        context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    // --- 服务与窗口状态 ---

    var enabled: Boolean
        get() = prefs.getBoolean(KEY_ENABLED, false)
        set(value) = prefs.edit().putBoolean(KEY_ENABLED, value).apply()

    var hidden: Boolean
        get() = prefs.getBoolean(KEY_HIDDEN, false)
        set(value) = prefs.edit().putBoolean(KEY_HIDDEN, value).apply()

    // ---------------------------------------------------------------------------
    // 开机自启（Phase 4D）
    //
    // 为什么放在原生 SharedPreferences 而不是 Flutter 的 SQLite：
    // 开机广播到达时 Flutter 引擎**还没有**启动，`BOOT_COMPLETED` 接收器必须能
    // 直接读到"用户是否开启了开机自启"，因此这份标志只能是原生可读的。
    // Flutter 设置页通过 `PetOverlayBridge.setAutostart` 写穿到这里（写透）。
    //
    // 与 [hidden] / [enabled] **完全分开**：`enabled`/`hidden` 是"显示桌宠"的运行态，
    // `autostartEnabled` 只决定"重启后要不要把服务拉起来"，两者互不覆盖。
    // ---------------------------------------------------------------------------

    /** 开机自动启动开关（默认关闭；只有用户显式打开才会在重启后启动服务）。 */
    var autostartEnabled: Boolean
        get() = prefs.getBoolean(KEY_AUTOSTART_ENABLED, false)
        set(value) = prefs.edit().putBoolean(KEY_AUTOSTART_ENABLED, value).apply()

    /** 最近一次开机自启的结果码（null = 从未有过开机记录）。 */
    val bootResultCode: String?
        get() = prefs.getString(KEY_BOOT_RESULT, null)?.takeIf { it.isNotEmpty() }

    /** 最近一次开机自启结果的记录时间（毫秒；0 = 从未记录）。 */
    val bootResultAt: Long
        get() = prefs.getLong(KEY_BOOT_RESULT_AT, 0L)

    /** 最近一次开机自启的补充说明（诊断用，可为 null）。 */
    val bootResultDetail: String?
        get() = prefs.getString(KEY_BOOT_RESULT_DETAIL, null)?.takeIf { it.isNotEmpty() }

    /** 最近一次尝试启动服务的时间（毫秒；去重守卫用）。 */
    var bootLastAttemptAt: Long
        get() = prefs.getLong(KEY_BOOT_LAST_ATTEMPT_AT, 0L)
        set(value) = prefs.edit().putLong(KEY_BOOT_LAST_ATTEMPT_AT, value).apply()

    /**
     * 记录一次开机自启结果（**单次原子提交**）。
     *
     * 由 `BootAutostart` 在决策后调用；服务真正起来后会用 `started` 覆盖它，
     * 因此设置页的"最近一次开机结果"最终反映的是**真实的启动结果**而非猜测。
     */
    fun recordBootResult(code: String, detail: String?, atMs: Long) {
        prefs.edit()
            .putString(KEY_BOOT_RESULT, code)
            .putLong(KEY_BOOT_RESULT_AT, atMs)
            .putString(KEY_BOOT_RESULT_DETAIL, detail)
            .apply()
    }

    /** 相对位置（0.0~1.0）。分辨率/尺寸变化后仍能落在可见范围内。 */
    var xRatio: Float
        get() = prefs.getFloat(KEY_X_RATIO, DEFAULT_X_RATIO).coerceIn(0f, 1f)
        set(value) = prefs.edit().putFloat(KEY_X_RATIO, safeRatio(value, DEFAULT_X_RATIO)).apply()

    var yRatio: Float
        get() = prefs.getFloat(KEY_Y_RATIO, DEFAULT_Y_RATIO).coerceIn(0f, 1f)
        set(value) = prefs.edit().putFloat(KEY_Y_RATIO, safeRatio(value, DEFAULT_Y_RATIO)).apply()

    var scale: Float
        get() = safeScale(prefs.getFloat(KEY_SCALE, DEFAULT_SCALE))
        set(value) = prefs.edit().putFloat(KEY_SCALE, safeScale(value)).apply()

    /** 自动贴边开关（需求 `overlay_snap_enabled`，默认开启）。 */
    var snapEnabled: Boolean
        get() = prefs.getBoolean(KEY_SNAP_ENABLED, true)
        set(value) = prefs.edit().putBoolean(KEY_SNAP_ENABLED, value).apply()

    /** 最近一次吸附到的边（需求 `overlay_snap_edge`）。 */
    var snapEdge: OverlaySnapEdge
        get() = OverlaySnapEdge.fromWire(prefs.getString(KEY_SNAP_EDGE, null))
        set(value) = prefs.edit().putString(KEY_SNAP_EDGE, value.name).apply()

    /**
     * 保存位置时的屏幕方向（需求"保存时屏幕方向"）。
     *
     * 只用于诊断与"是否需要在恢复时额外修正"的判断 —— 坐标本身**永远**按
     * 当前可用区域重算，不依赖它。
     */
    var snapOrientation: String
        get() = prefs.getString(KEY_SNAP_ORIENTATION, null) ?: ORIENTATION_UNKNOWN
        set(value) = prefs.edit().putString(KEY_SNAP_ORIENTATION, value).apply()

    var touchThrough: Boolean
        get() = prefs.getBoolean(KEY_TOUCH_THROUGH, false)
        set(value) = prefs.edit().putBoolean(KEY_TOUCH_THROUGH, value).apply()

    var hideOnLockScreen: Boolean
        get() = prefs.getBoolean(KEY_HIDE_ON_LOCK, true)
        set(value) = prefs.edit().putBoolean(KEY_HIDE_ON_LOCK, value).apply()

    // --- 当前素材（原生独立运行时的回退依据）---

    var characterId: String?
        get() = prefs.getString(KEY_CHARACTER_ID, null)
        set(value) = prefs.edit().putString(KEY_CHARACTER_ID, value).apply()

    var assetId: String?
        get() = prefs.getString(KEY_ASSET_ID, null)
        set(value) = prefs.edit().putString(KEY_ASSET_ID, value).apply()

    var filePath: String?
        get() = prefs.getString(KEY_FILE_PATH, null)
        set(value) = prefs.edit().putString(KEY_FILE_PATH, value).apply()

    var mimeType: String?
        get() = prefs.getString(KEY_MIME_TYPE, null)
        set(value) = prefs.edit().putString(KEY_MIME_TYPE, value).apply()

    var isAnimated: Boolean
        get() = prefs.getBoolean(KEY_IS_ANIMATED, false)
        set(value) = prefs.edit().putBoolean(KEY_IS_ANIMATED, value).apply()

    var frameCount: Int
        get() = prefs.getInt(KEY_FRAME_COUNT, 0)
        set(value) = prefs.edit().putInt(KEY_FRAME_COUNT, value).apply()

    var animationDurationMs: Int
        get() = prefs.getInt(KEY_ANIMATION_DURATION_MS, 0)
        set(value) = prefs.edit().putInt(KEY_ANIMATION_DURATION_MS, value).apply()

    var fixedAssetMode: Boolean
        get() = prefs.getBoolean(KEY_FIXED_ASSET_MODE, false)
        set(value) = prefs.edit().putBoolean(KEY_FIXED_ASSET_MODE, value).apply()

    /**
     * 诊断模式（Phase 4C-2 真机排障）。
     *
     * 打开后悬浮窗**完全不依赖素材**：固定 200dp 洋红方块 + 白字 + 固定位置，
     * 不读数据库、不读 Flutter 状态、不加载图片、不做动画、不恢复历史坐标。
     * 用途是二分定位"问题在窗口/命令时序"还是"在素材解析/绘制"。
     */
    var debugOverlayMode: Boolean
        get() = prefs.getBoolean(KEY_DEBUG_OVERLAY, false)
        set(value) = prefs.edit().putBoolean(KEY_DEBUG_OVERLAY, value).apply()

    /**
     * **双窗口悬浮层**开关（Phase 4C-6B-4；默认**开启**）。
     *
     * 打开 = 桌宠窗 + 固定菜单窗两个 `TYPE_APPLICATION_OVERLAY` 窗口（探测器真机已验证的加序/关态/同步行为）；
     * 关闭 = 沿用旧的**单窗口**分层实现（相册式：菜单作为同一窗口内的一层）。
     *
     * 运行时切换会走服务的"拆一种模式 → 建另一种"重建流程，不会留下重复窗口或可触摸残留。
     */
    var dualWindowMode: Boolean
        get() = prefs.getBoolean(KEY_DUAL_WINDOW, true)
        set(value) = prefs.edit().putBoolean(KEY_DUAL_WINDOW, value).apply()

    /** 清空为一个"未启用"的干净状态（停止服务时调用，位置与素材保留）。 */
    fun clearRuntime() {
        prefs.edit()
            .putBoolean(KEY_ENABLED, false)
            .putBoolean(KEY_HIDDEN, false)
            .apply()
    }

    // ---------------------------------------------------------------------------
    // Phase 4C-5.1B：使用会话采集
    //
    // 为什么放在原生 SharedPreferences 而不是 Flutter 的 SQLite：
    // 悬浮前台服务可能在 Flutter 进程已被回收时继续运行，那时读不到 Flutter 的库，
    // 但"是否暂停采集"与"本机稳定设备标识"必须立刻可用（否则会记错归属）。
    // Flutter 仍然是这两项事实的**权威来源**，只是通过桥接把它们同步到这里。
    // ---------------------------------------------------------------------------

    /**
     * 是否暂停使用会话采集（与 Flutter 的 `tracking.paused` 保持一致）。
     *
     * 暂停期间**不新建会话、不累计时长**；桌宠状态联动不受影响（两者解耦）。
     */
    var usageCollectionPaused: Boolean
        get() = prefs.getBoolean(KEY_USAGE_PAUSED, false)
        set(value) = prefs.edit().putBoolean(KEY_USAGE_PAUSED, value).apply()

    /**
     * 本机稳定设备标识（Flutter 侧 `DeviceIdentity` 生成的安装 UUID）。
     *
     * 只用于**本地**数据归属与幂等（写进 journal，导入时再用于生成确定性段 ID）；
     * 与服务端注册设备 ID（`X-Device-Id`）**不是同一个东西**，绝不混用。
     */
    var usageDeviceLocalId: String
        get() = prefs.getString(KEY_USAGE_DEVICE_LOCAL_ID, null).orEmpty()
        set(value) = prefs.edit().putString(KEY_USAGE_DEVICE_LOCAL_ID, value).apply()

    // ---------------------------------------------------------------------------
    // Phase 4C-5：状态映射快照与手动覆盖
    //
    // 为什么不存一份大 JSON：状态 ID 是**固定的 11 个**（与 Flutter SystemState
    // 逐字一致），因此按状态拆成独立键既能被严格解析，又天然满足"有 schemaVersion /
    // 有大小上限 / 解析失败回退默认 / 不保存素材二进制"这几条需求约束。
    // ---------------------------------------------------------------------------

    /** 映射快照的 schemaVersion（与 Flutter 侧协议同版本；不符时整份忽略）。 */
    val mappingSchemaVersion: Int get() = prefs.getInt(KEY_MAPPING_SCHEMA, 0)

    /** 最近一次被接受的映射版本号（单调递增）。 */
    val mappingRevision: Long get() = prefs.getLong(KEY_MAPPING_REVISION, 0L)

    /** 映射对应的角色 ID。 */
    val mappingCharacterId: String? get() = prefs.getString(KEY_MAPPING_CHARACTER_ID, null)

    /**
     * 状态调试器的手动覆盖（某个状态 ID；null = 未覆盖）。
     *
     * 只保存状态 ID，**不复制素材**（需求 §16）。
     */
    var manualStateOverride: String?
        get() = prefs.getString(KEY_MANUAL_STATE, null)?.takeIf { it.isNotEmpty() }
        set(value) = prefs.edit()
            .putString(KEY_MANUAL_STATE, value?.takeIf { it.isNotEmpty() })
            .apply()

    /**
     * 读取映射快照。
     *
     * 严格解析：schemaVersion 不符、角色 ID 缺失、单个素材字段不全 → 该条忽略；
     * 全部无效时返回 [NativePetStateMapping.EMPTY]（**绝不抛异常**，
     * 否则服务重建时会因为一份坏数据起不来）。
     */
    internal fun readStateMapping(): NativePetStateMapping {
        if (mappingSchemaVersion != MAPPING_SCHEMA_VERSION) return NativePetStateMapping.EMPTY
        val characterId = mappingCharacterId ?: return NativePetStateMapping.EMPTY
        val defaultAsset = readAsset(KEY_DEFAULT_ASSET_PREFIX)
        val states = LinkedHashMap<String, NativePetAsset>()
        for (stateId in PetStateId.ALL) {
            readAsset(assetKeyPrefix(stateId))?.let { states[stateId] = it }
        }
        return NativePetStateMapping(
            characterId = characterId,
            defaultAsset = defaultAsset,
            stateAssets = states,
            revision = mappingRevision,
            // Phase 4C-6A：自动开关与规则表一并持久化，
            // 这样 Flutter 被划掉 / 服务重启后仍能按同一套规则联动。
            automaticEnabled = prefs.getBoolean(KEY_MAPPING_AUTOMATIC, true),
            categoryRules = readRuleMap(KEY_MAPPING_CATEGORY_RULES),
            appOverrides = readRuleMap(KEY_MAPPING_APP_OVERRIDES),
        )
    }

    /**
     * 写入映射快照（**单次原子提交**）。
     *
     * 先清掉全部状态键再写入，保证"上一次映射里有、这一次没有"的状态不会残留。
     */
    internal fun writeStateMapping(mapping: NativePetStateMapping) {
        val editor = prefs.edit()
        editor.putInt(KEY_MAPPING_SCHEMA, MAPPING_SCHEMA_VERSION)
        editor.putLong(KEY_MAPPING_REVISION, mapping.revision)
        editor.putString(KEY_MAPPING_CHARACTER_ID, mapping.characterId)
        editor.putBoolean(KEY_MAPPING_AUTOMATIC, mapping.automaticEnabled)
        editor.putString(KEY_MAPPING_CATEGORY_RULES, encodeRuleMap(mapping.categoryRules))
        editor.putString(KEY_MAPPING_APP_OVERRIDES, encodeRuleMap(mapping.appOverrides))
        putAsset(editor, KEY_DEFAULT_ASSET_PREFIX, mapping.defaultAsset)
        for (stateId in PetStateId.ALL) {
            putAsset(editor, assetKeyPrefix(stateId), mapping.stateAssets[stateId])
        }
        editor.apply()
    }

    /** 角色或素材被删除后清理映射（需求 §8 / §22 第 32 条）。 */
    internal fun clearStateMapping() {
        val editor = prefs.edit()
        editor.putInt(KEY_MAPPING_SCHEMA, 0)
        editor.putLong(KEY_MAPPING_REVISION, 0L)
        editor.remove(KEY_MAPPING_CHARACTER_ID)
        editor.remove(KEY_MANUAL_STATE)
        editor.remove(KEY_MAPPING_CATEGORY_RULES)
        editor.remove(KEY_MAPPING_APP_OVERRIDES)
        putAsset(editor, KEY_DEFAULT_ASSET_PREFIX, null)
        for (stateId in PetStateId.ALL) {
            putAsset(editor, assetKeyPrefix(stateId), null)
        }
        editor.apply()
    }

    /**
     * 规则表的紧凑编码：`键=值` 用换行分隔。
     *
     * 编解码实现放在 [PetStateRulesCodec]（纯逻辑、可 JVM 单测），
     * 这样"服务重启后规则仍在"这条验收不必依赖真机。
     */
    private fun encodeRuleMap(map: Map<String, String>): String =
        PetStateRulesCodec.encode(map)

    private fun readRuleMap(key: String): Map<String, String> =
        PetStateRulesCodec.decode(prefs.getString(key, null))

    private fun assetKeyPrefix(slot: String): String = "overlay.state.$slot"

    private fun putAsset(
        editor: SharedPreferences.Editor,
        prefix: String,
        asset: NativePetAsset?,
    ) {
        if (asset == null) {
            editor.remove("$prefix.asset_id")
            editor.remove("$prefix.path")
            editor.remove("$prefix.is_animated")
            return
        }
        editor.putString("$prefix.asset_id", asset.assetId)
        editor.putString("$prefix.path", asset.path)
        editor.putBoolean("$prefix.is_animated", asset.isAnimated)
    }

    private fun readAsset(prefix: String): NativePetAsset? {
        val assetId = prefs.getString("$prefix.asset_id", null)?.trim().orEmpty()
        val path = prefs.getString("$prefix.path", null)?.trim().orEmpty()
        if (assetId.isEmpty() || path.isEmpty()) return null
        return NativePetAsset(
            assetId = assetId,
            path = path,
            isAnimated = prefs.getBoolean("$prefix.is_animated", false),
        )
    }

    // ---------------------------------------------------------------------------
    // Phase 4C-6B-1：轮盘主题与外观
    //
    // 为什么存在原生 SharedPreferences：悬浮服务可能在 Flutter 进程被回收后
    // 继续运行，那时轮盘照样要画对颜色。默认值就是需求 §13.1 的 P3P 粉色。
    // ---------------------------------------------------------------------------

    /** 读取当前轮盘主题（缺省 = P3P 粉色）。 */
    internal fun menuTheme(): WheelMenuTheme = WheelMenuTheme.fromWire(
        themeId = prefs.getString(KEY_MENU_THEME_ID, null),
        customPrimary = prefs.getInt(KEY_MENU_THEME_CUSTOM_PRIMARY, DEFAULT_MENU_CUSTOM_PRIMARY),
        revision = menuThemeRevision,
    )

    /** 用户自选的主色（仅 `themeId = custom` 时生效）。 */
    var menuCustomPrimary: Int
        get() = prefs.getInt(KEY_MENU_THEME_CUSTOM_PRIMARY, DEFAULT_MENU_CUSTOM_PRIMARY)
        set(value) = prefs.edit().putInt(KEY_MENU_THEME_CUSTOM_PRIMARY, value).apply()

    /**
     * 主题配置版本号（单调递增）。
     *
     * Flutter 侧首次同步必须**从这里续接计数器**（与状态映射 revision 同一套约定），
     * 否则应用重启后新主题会被"旧 revision"挡住（需求 §13.3）。
     */
    val menuThemeRevision: Long get() = prefs.getLong(KEY_MENU_THEME_REVISION, 0L)

    /**
     * 写入主题。**比当前更旧的 revision 一律拒绝**（防止旧配置覆盖新配置）。
     *
     * @return 是否被接受
     */
    internal fun writeMenuTheme(theme: WheelMenuTheme, revision: Long): Boolean {
        if (revision < menuThemeRevision) return false
        prefs.edit()
            .putString(KEY_MENU_THEME_ID, theme.themeId)
            .putInt(KEY_MENU_THEME_CUSTOM_PRIMARY, theme.primary)
            .putLong(KEY_MENU_THEME_REVISION, revision)
            .apply()
        return true
    }

    /** 触觉反馈开关（需求 §16；默认开启）。 */
    var menuHapticsEnabled: Boolean
        get() = prefs.getBoolean(KEY_MENU_HAPTICS, true)
        set(value) = prefs.edit().putBoolean(KEY_MENU_HAPTICS, value).apply()

    /** 音效开关（需求 §16；4C-6B-1 只持久化，不产生音效）。 */
    var menuSoundEnabled: Boolean
        get() = prefs.getBoolean(KEY_MENU_SOUND, false)
        set(value) = prefs.edit().putBoolean(KEY_MENU_SOUND, value).apply()

    /** 圆弧滑选开关（需求 §16；默认开启）。 */
    var menuSwipeEnabled: Boolean
        get() = prefs.getBoolean(KEY_MENU_SWIPE, true)
        set(value) = prefs.edit().putBoolean(KEY_MENU_SWIPE, value).apply()

    /** 滑选灵敏度：0 = 低、1 = 标准、2 = 高（需求 §16）。 */
    var menuSwipeSensitivity: Int
        get() = prefs.getInt(KEY_MENU_SWIPE_SENSITIVITY, 1).coerceIn(0, 2)
        set(value) = prefs.edit().putInt(KEY_MENU_SWIPE_SENSITIVITY, value.coerceIn(0, 2)).apply()

    /**
     * 读取轮盘**布局**设置（Phase 4C-6B-1.1：尺寸 / 距离 / 紧凑）。
     *
     * 与主题分开两条键线：主题管颜色，布局管几何，两者的 revision 互不干扰。
     */
    internal fun menuLayoutSettings(): WheelMenuLayoutSettings = WheelMenuLayoutSettings(
        preferredScale = prefs.getFloat(
            KEY_MENU_SCALE,
            WheelMenuLayoutSettings.DEFAULT_SCALE,
        ),
        menuDistance = prefs.getFloat(
            KEY_MENU_DISTANCE,
            WheelMenuLayoutSettings.DEFAULT_DISTANCE,
        ),
        buttonVisualScale = prefs.getFloat(
            KEY_MENU_BUTTON_SCALE,
            WheelMenuLayoutSettings.DEFAULT_BUTTON_SCALE,
        ),
        compactMode = prefs.getBoolean(KEY_MENU_COMPACT, false),
        revision = menuLayoutRevision,
    ).normalized()

    /** 布局配置版本号（单调递增；与主题 revision 同一套守卫口径）。 */
    val menuLayoutRevision: Long get() = prefs.getLong(KEY_MENU_LAYOUT_REVISION, 0L)

    /** 写入轮盘布局设置；比当前更旧的 revision 一律拒绝。 */
    internal fun writeMenuLayoutSettings(
        settings: WheelMenuLayoutSettings,
        revision: Long,
    ): Boolean {
        if (revision < menuLayoutRevision) return false
        val normalized = settings.normalized()
        prefs.edit()
            .putFloat(KEY_MENU_SCALE, normalized.preferredScale)
            .putFloat(KEY_MENU_DISTANCE, normalized.menuDistance)
            .putFloat(KEY_MENU_BUTTON_SCALE, normalized.buttonVisualScale)
            .putBoolean(KEY_MENU_COMPACT, normalized.compactMode)
            .putLong(KEY_MENU_LAYOUT_REVISION, revision)
            .apply()
        return true
    }

    /** 菜单与桌宠的距离比例（需求 §4：仅用于错开脸部与标题）。 */
    var menuDistanceRatio: Float
        get() = prefs.getFloat(KEY_MENU_DISTANCE, WheelMenuLayoutSettings.DEFAULT_DISTANCE)
        set(value) = prefs.edit()
            .putFloat(KEY_MENU_DISTANCE, WheelMenuLayoutSettings.clampDistance(value))
            .apply()

    /** 上一次展开方向（`right` / `left`；null = 还没开过）。 */
    var menuLastDirection: String?
        get() = prefs.getString(KEY_MENU_LAST_DIRECTION, null)?.takeIf { it.isNotEmpty() }
        set(value) = prefs.edit()
            .putString(KEY_MENU_LAST_DIRECTION, value?.takeIf { it.isNotEmpty() })
            .apply()

    /**
     * 用**已持久化的字段**重建配置（Phase 4C-2）。
     *
     * 这里的字段之所以可信，是因为它们只在
     * [OverlayConfigValidator] 校验通过之后才被写入 —— 因此服务重建
     * （START_STICKY）时可以直接按它恢复最后一个有效素材。
     * 关键字段缺失时返回 null（表示"还没有素材"）。
     */
    internal fun toConfig(): PetOverlayConfig? {
        val character = characterId ?: return null
        val asset = assetId ?: return null
        val path = filePath ?: return null
        val mime = mimeType ?: return null
        return PetOverlayConfig(
            schemaVersion = PetOverlayConfig.SCHEMA_VERSION,
            characterId = character,
            assetId = asset,
            filePath = path,
            mimeType = mime,
            isAnimated = isAnimated,
            frameCount = frameCount,
            animationDurationMs = animationDurationMs,
            scale = scale,
            snapEnabled = snapEnabled,
            fixedAssetMode = fixedAssetMode,
        )
    }

    companion object {
        const val PREFS_NAME = "petlife_overlay"
        const val SCHEMA_VERSION = 1

        /**
         * 状态映射快照的协议版本（Phase 4C-5）。
         *
         * 与 [SCHEMA_VERSION] 分开：悬浮窗配置的版本号和"状态映射协议"的版本号
         * 是两条独立演进线，混在一起会导致一边升级就把另一边的数据清掉。
         */
        const val MAPPING_SCHEMA_VERSION = 1

        const val DEFAULT_X_RATIO = 0.85f
        const val DEFAULT_Y_RATIO = 0.30f
        const val DEFAULT_SCALE = 1.0f

        /** 缩放区间：与设置页滑块一致（50% ~ 200%）。 */
        const val MIN_SCALE = 0.5f
        const val MAX_SCALE = 2.0f

        /** 方向标记（需求要求"保存时屏幕方向"）。 */
        const val ORIENTATION_PORTRAIT = "portrait"
        const val ORIENTATION_LANDSCAPE = "landscape"
        const val ORIENTATION_UNKNOWN = "unknown"

        internal const val KEY_ENABLED = "overlay.enabled"
        internal const val KEY_HIDDEN = "overlay.hidden"
        // Phase 4D：开机自启（原生可读，BOOT_COMPLETED 接收器直接用）
        internal const val KEY_AUTOSTART_ENABLED = "overlay.autostart_enabled"
        internal const val KEY_BOOT_RESULT = "overlay.boot_result"
        internal const val KEY_BOOT_RESULT_AT = "overlay.boot_result_at"
        internal const val KEY_BOOT_RESULT_DETAIL = "overlay.boot_result_detail"
        internal const val KEY_BOOT_LAST_ATTEMPT_AT = "overlay.boot_last_attempt_at"
        internal const val KEY_X_RATIO = "overlay.x_ratio"
        internal const val KEY_Y_RATIO = "overlay.y_ratio"
        internal const val KEY_SCALE = "overlay.scale"
        internal const val KEY_SNAP_ENABLED = "overlay.snap_enabled"
        internal const val KEY_SNAP_EDGE = "overlay.snap_edge"
        internal const val KEY_SNAP_ORIENTATION = "overlay.snap_orientation"
        internal const val KEY_TOUCH_THROUGH = "overlay.touch_through"
        internal const val KEY_HIDE_ON_LOCK = "overlay.hide_on_lock_screen"
        internal const val KEY_CHARACTER_ID = "overlay.character_id"
        internal const val KEY_ASSET_ID = "overlay.asset_id"
        internal const val KEY_FILE_PATH = "overlay.file_path"
        internal const val KEY_MIME_TYPE = "overlay.mime_type"
        internal const val KEY_IS_ANIMATED = "overlay.is_animated"
        internal const val KEY_FRAME_COUNT = "overlay.frame_count"
        internal const val KEY_ANIMATION_DURATION_MS = "overlay.animation_duration_ms"
        internal const val KEY_FIXED_ASSET_MODE = "overlay.fixed_asset_mode"
        internal const val KEY_DEBUG_OVERLAY = "overlay.debug_mode"
        // Phase 4C-6B-4：双窗口悬浮层（默认开启）
        internal const val KEY_DUAL_WINDOW = "overlay.dual_window"
        // Phase 4C-5.1B：使用会话采集
        internal const val KEY_USAGE_PAUSED = "usage.paused"
        internal const val KEY_USAGE_DEVICE_LOCAL_ID = "usage.device_local_id"
        // Phase 4C-5：状态映射快照与手动覆盖
        internal const val KEY_MAPPING_SCHEMA = "overlay.state.schema_version"
        internal const val KEY_MAPPING_REVISION = "overlay.state.revision"
        internal const val KEY_MAPPING_CHARACTER_ID = "overlay.state.character_id"
        // Phase 4C-6B-1：轮盘主题与外观
        internal const val KEY_MENU_THEME_ID = "overlay.menu.theme_id"
        internal const val KEY_MENU_THEME_CUSTOM_PRIMARY = "overlay.menu.theme_custom_primary"
        internal const val KEY_MENU_THEME_REVISION = "overlay.menu.theme_revision"
        internal const val KEY_MENU_HAPTICS = "overlay.menu.haptics"
        internal const val KEY_MENU_SOUND = "overlay.menu.sound"
        internal const val KEY_MENU_SWIPE = "overlay.menu.swipe"
        internal const val KEY_MENU_SWIPE_SENSITIVITY = "overlay.menu.swipe_sensitivity"
        internal const val KEY_MENU_DISTANCE = "overlay.menu.distance"
        internal const val KEY_MENU_LAST_DIRECTION = "overlay.menu.last_direction"
        // Phase 4C-6B-1.1：轮盘布局（尺寸 / 紧凑 / 按钮缩放）
        internal const val KEY_MENU_SCALE = "overlay.menu.scale"
        internal const val KEY_MENU_BUTTON_SCALE = "overlay.menu.button_scale"
        internal const val KEY_MENU_COMPACT = "overlay.menu.compact"
        internal const val KEY_MENU_LAYOUT_REVISION = "overlay.menu.layout_revision"

        /** 自定义主题色的出厂默认（与 P3P 主色一致，保证"没选过"时也是粉色）。 */
        internal const val DEFAULT_MENU_CUSTOM_PRIMARY = 0xFFF24D96.toInt()
        // Phase 4C-6A：自动联动总开关 + 规则表（Flutter 下发并持久化）
        internal const val KEY_MAPPING_AUTOMATIC = "overlay.state.automatic_enabled"
        internal const val KEY_MAPPING_CATEGORY_RULES = "overlay.state.category_rules"
        internal const val KEY_MAPPING_APP_OVERRIDES = "overlay.state.app_overrides"
        internal const val KEY_MANUAL_STATE = "overlay.state.manual_override"

        /** 角色默认素材的键前缀（与各状态共用同一套 `putAsset` / `readAsset`）。 */
        internal const val KEY_DEFAULT_ASSET_PREFIX = "overlay.state.default_asset"

        /**
         * 缩放值安全化（需求"非法、NaN、Infinity 或旧版本数据自动恢复安全默认值"）。
         *
         * 单测直接打靶这一个函数，因此它必须是纯函数。
         */
        internal fun safeScale(value: Float): Float {
            if (!value.isFinite()) return DEFAULT_SCALE
            return value.coerceIn(MIN_SCALE, MAX_SCALE)
        }

        /** 相对位置安全化：NaN / Infinity / 越界一律回到默认值。 */
        internal fun safeRatio(value: Float, fallback: Float): Float {
            if (!value.isFinite()) return fallback
            return value.coerceIn(0f, 1f)
        }
    }
}

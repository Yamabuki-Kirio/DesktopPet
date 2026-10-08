package asia.akechi.petlife.overlay

/**
 * 状态联动的**全部纯逻辑**（Phase 4C-5）。
 *
 * 为什么要单独一个文件、且**不引用任何 Android 类**：
 * 状态 ID、分类规则、防抖、映射快照这些是"最容易写错、又最容易验证"的部分。
 * 它们不需要 Context / UsageStatsManager，因此可以在 JVM 单测里逐条打靶，
 * 不必等真机才发现"把浏览器判成了专注"这种错误。
 *
 * **最重要的约束**：这里的 [PetStateId] 必须与 Flutter 侧
 * `lib/state_engine/system_state.dart` 的 `SystemState.wireName`
 * **逐字一致**。Android 不允许出现第二套状态命名（否则跨平台维护会立刻失控）。
 */

/**
 * 项目现有的 11 个标准状态 ID（= Dart `SystemState.wireName`）。
 *
 * 括号内为 Dart 侧 `priority`，用于判断"谁更优先"。
 */
internal object PetStateId {

    const val ERROR = "error" // 100
    const val MANUAL = "manual" // 95
    const val CONCERNED = "concerned" // 90
    const val TIRED = "tired" // 80
    const val HAPPY = "happy" // 70
    const val GAMING = "gaming" // 60
    const val FOCUSED = "focused" // 50
    const val SOCIAL = "social" // 40
    const val ENTERTAINED = "entertained" // 30
    const val AWAY = "away" // 20
    const val DEFAULT = "default" // 0

    /** 全部状态（顺序与 Dart 的 `SystemState.values` 一致）。 */
    val ALL: List<String> = listOf(
        ERROR, MANUAL, CONCERNED, TIRED, HAPPY,
        GAMING, FOCUSED, SOCIAL, ENTERTAINED, AWAY, DEFAULT,
    )

    fun isKnown(id: String?): Boolean = id != null && ALL.contains(id)

    /**
     * 与 Dart `SystemState.descriptionZh` 保持一致（设置页只读诊断用）。
     */
    fun descriptionZh(id: String): String = when (id) {
        DEFAULT -> "默认"
        FOCUSED -> "专注"
        GAMING -> "游戏"
        SOCIAL -> "社交"
        ENTERTAINED -> "娱乐"
        TIRED -> "疲惫"
        AWAY -> "离开"
        HAPPY -> "开心"
        CONCERNED -> "担忧"
        ERROR -> "错误"
        MANUAL -> "手动锁定"
        else -> id
    }
}

/**
 * 状态来源（需求 §4）。
 *
 * 命名与需求示例一致；`unsupported` 表示"缺权限或读不到前台应用"。
 */
internal enum class PetStateSource(val wire: String) {
    manualDebug("manual-debug"),
    foregroundApp("foreground-app"),
    idle("idle"),
    default("default"),
    screenOff("screen-off"),
    unsupported("unsupported"),
}

/**
 * 一次状态判定结果（需求 §4 建议的统一对象）。
 *
 * 所有来源都产生它，避免"多个来源同时争抢当前状态"。
 */
internal data class PetStateDecision(
    val stateId: String,
    val source: PetStateSource,
    val reason: String,
    val foregroundPackage: String?,
    val decidedAt: Long,
)

/**
 * 项目现有 8 类应用分类 ID（= Dart `AppCategory.wireName`）。
 *
 * 同样不允许出现第二套命名。
 */
internal object AppCategoryId {
    const val DEVELOPMENT = "development"
    const val PRODUCTIVITY = "productivity"
    const val GAMING = "gaming"
    const val SOCIAL = "social"
    const val ENTERTAINMENT = "entertainment"
    const val BROWSER = "browser"
    const val SYSTEM = "system"
    const val OTHER = "other"

    fun isKnown(id: String?): Boolean = id != null && when (id) {
        DEVELOPMENT, PRODUCTIVITY, GAMING, SOCIAL,
        ENTERTAINMENT, BROWSER, SYSTEM, OTHER,
        -> true
        else -> false
    }

    fun labelZh(id: String): String = when (id) {
        DEVELOPMENT -> "开发"
        PRODUCTIVITY -> "生产力"
        GAMING -> "游戏"
        SOCIAL -> "社交"
        ENTERTAINMENT -> "娱乐"
        BROWSER -> "浏览器"
        SYSTEM -> "系统"
        else -> "其他"
    }
}

/**
 * 自动状态联动的**运行时规则**（Phase 4C-6A）。
 *
 * 全部来自 Flutter 下发的快照（[NativePetStateMapping]），因此：
 * * 规则只有一份（Flutter 侧构建，与 Windows 用同一张表）；
 * * 原生在 Flutter 被划掉后仍能用**持久化的快照**继续联动；
 * * 快照里没有规则表时退回内置表 [AppCategoryStateMapper]。
 */
internal data class PetStateRules(
    val automaticEnabled: Boolean = true,
    val categoryRules: Map<String, String> = emptyMap(),
    val appOverrides: Map<String, String> = emptyMap(),
) {
    companion object {
        /** 默认规则：自动开启 + 无自定义规则（走内置表）。 */
        val DEFAULT = PetStateRules()
    }
}

/**
 * 规则表的**紧凑编解码**（`键=值` 换行分隔）。
 *
 * 为什么不用 JSON：`org.json` 在 JVM 单测里是未实现的桩，引它会让
 * "服务重启后规则仍在"这条验收只能靠真机验证。改成纯字符串编解码后，
 * 持久化的往返语义可以直接在 JVM 单测里打靶。
 *
 * 键值都是"包名 / 分类 ID / 状态 ID"这类**不含换行与等号**的字符串，
 * 因此不需要转义；损坏的行逐条丢弃，不影响其它规则。
 */
internal object PetStateRulesCodec {

    fun encode(map: Map<String, String>): String =
        map.entries.joinToString("\n") { "${it.key}=${it.value}" }

    fun decode(raw: String?): Map<String, String> {
        val text = raw?.trim().orEmpty()
        if (text.isEmpty()) return emptyMap()
        val out = LinkedHashMap<String, String>()
        for (line in text.split('\n')) {
            val idx = line.indexOf('=')
            if (idx <= 0) continue
            val key = line.substring(0, idx).trim()
            val value = line.substring(idx + 1).trim()
            if (key.isEmpty() || value.isEmpty()) continue
            out[key] = value
        }
        return out
    }
}

/** 分类来源（对齐 Dart `ClassificationSource`，用于诊断可解释性）。 */
internal enum class AppCategorySource(val wire: String, val labelZh: String) {
    userOverride("user-override", "用户设定"),
    builtInRule("built-in-rule", "内置规则"),

    /**
     * 系统声明的分类（Phase 4C-6A 新增）。
     *
     * 来自 `ApplicationInfo.category` —— 它由应用自己声明，可靠但**常常缺失**
     * （大量应用是 `CATEGORY_UNDEFINED`）。因此它排在"具体包名表"之后、
     * "内置包名规则"之前：有声明就信声明，没声明再退回包名规则。
     */
    platformCategory("platform-category", "系统声明分类"),
    fallback("fallback", "默认归类"),
}

/**
 * 一次分类结果。
 *
 * [detail] 是"为什么归到这一类"的可解释细节（命中的包名 / 前缀 / 关键字 /
 * 系统声明值），只用于诊断，不参与任何判定。
 */
internal data class AppCategoryResult(
    val category: String,
    val source: AppCategorySource,
    val detail: String? = null,
)

/**
 * Android `ApplicationInfo.category` 的取值。
 *
 * 刻意**只使用整数值**（不 `import android.content.pm.ApplicationInfo`）：
 * 这样 [AndroidAppCategoryRules] 保持"零 Android 依赖"，可以在 JVM 单测里
 * 逐条打靶。数值与框架常量一一对应，改动框架值的情况不存在。
 */
internal object AndroidAppInfoCategory {
    const val GAME = 0
    const val AUDIO = 1
    const val VIDEO = 2
    const val IMAGE = 3
    const val SOCIAL = 4
    const val NEWS = 5
    const val MAPS = 6
    const val PRODUCTIVITY = 7
    const val ACCESSIBILITY = 8
    const val UNDEFINED = -1

    /**
     * 系统声明的分类 → 项目既有 8 类。
     *
     * 无法确定时返回 null，**由调用方继续走下一级规则**（绝不硬塞一个分类）。
     * * `NEWS` → `browser`：读资讯与"浏览"是同一类行为，映射到既有语义
     *   （browser → focused），不新增任何分类/状态命名；
     * * `MAPS` → `other`：导航不属于既有 8 类里的任何一类，如实归到未归类。
     */
    fun toAppCategoryId(category: Int?): String? = when (category) {
        GAME -> AppCategoryId.GAMING
        AUDIO, VIDEO, IMAGE -> AppCategoryId.ENTERTAINMENT
        SOCIAL -> AppCategoryId.SOCIAL
        PRODUCTIVITY -> AppCategoryId.PRODUCTIVITY
        NEWS -> AppCategoryId.BROWSER
        ACCESSIBILITY -> AppCategoryId.SYSTEM
        MAPS -> AppCategoryId.OTHER
        else -> null
    }
}

/**
 * **Android 包名 → 分类**规则（Phase 4C-5）。
 *
 * 为什么不直接复用 Windows 的 `kBuiltInCategoryRules`：那张表用的是
 * **可执行文件名**（`chrome` / `telegram`），而 Android 的稳定标识是
 * **包名**（`com.android.chrome` / `org.telegram.messenger`）。
 * 需求 §7 明确要求"不要强行把包名伪装成 Windows 进程名"，
 * 因此这里新开一张包名规则表，但**输出的分类 ID 完全沿用项目既有的 8 类**。
 *
 * 优先级（Phase 4C-6A 修正后的**四级**，与真机诊断要求一致）：
 * ```
 * ① 用户为具体应用设定的分类（userCategory）
 * ② 精确包名覆盖表（exact）
 * ③ 系统声明分类 ApplicationInfo.category（platformCategory）
 * ④ 内置包名前缀 / 关键字规则（prefixes / keywords / launchers）
 * ⑤ other（绝不猜测）
 * ```
 *
 * 为什么把"系统声明分类"放在包名表之后：包名表是我们能给出的**最确定**的结论；
 * 系统声明虽然权威但**大量应用是 UNDEFINED**，只在包名表覆盖不到时才用它，
 * 既补上长尾应用，又不会把已知应用判错。
 *
 * **绝不使用应用显示名做判定**（显示名会随系统语言变化、也会被用户改名）。
 */
internal object AndroidAppCategoryRules {

    /** 精确包名规则（优先级最高；**未归一化**的原始表，见下面 `exact` 的说明）。 */
    private val exactRaw: Map<String, String> = buildMap {
        // --- 开发 ---
        put("com.termux", AppCategoryId.DEVELOPMENT)
        put("com.termux.api", AppCategoryId.DEVELOPMENT)
        put("org.codehaus.mojo", AppCategoryId.DEVELOPMENT)
        put("com.aide.ui", AppCategoryId.DEVELOPMENT)
        put("com.simplemobiletools.code.editor", AppCategoryId.DEVELOPMENT)

        // --- 生产力 ---
        put("com.microsoft.office.word", AppCategoryId.PRODUCTIVITY)
        put("com.microsoft.office.excel", AppCategoryId.PRODUCTIVITY)
        put("com.microsoft.office.powerpoint", AppCategoryId.PRODUCTIVITY)
        put("com.microsoft.office.outlook", AppCategoryId.PRODUCTIVITY)
        put("com.microsoft.office.onenote", AppCategoryId.PRODUCTIVITY)
        put("com.google.android.apps.docs", AppCategoryId.PRODUCTIVITY)
        put("com.google.android.apps.docs.editors.docs", AppCategoryId.PRODUCTIVITY)
        put("com.google.android.apps.docs.editors.sheets", AppCategoryId.PRODUCTIVITY)
        put("com.google.android.apps.docs.editors.slides", AppCategoryId.PRODUCTIVITY)
        put("com.google.android.keep", AppCategoryId.PRODUCTIVITY)
        put("com.google.android.calendar", AppCategoryId.PRODUCTIVITY)
        put("com.notion.id", AppCategoryId.PRODUCTIVITY)
        put("md.obsidian", AppCategoryId.PRODUCTIVITY)
        put("com.evernote", AppCategoryId.PRODUCTIVITY)
        put("com.adobe.reader", AppCategoryId.PRODUCTIVITY)
        put("com.wps.office", AppCategoryId.PRODUCTIVITY)
        put("cn.wps.moffice_eng", AppCategoryId.PRODUCTIVITY)

        // --- 社交 / 通信 ---
        put("org.telegram.messenger", AppCategoryId.SOCIAL)
        put("org.telegram.plus", AppCategoryId.SOCIAL)
        put("com.whatsapp", AppCategoryId.SOCIAL)
        put("com.tencent.mm", AppCategoryId.SOCIAL)
        put("com.tencent.mobileqq", AppCategoryId.SOCIAL)
        put("com.facebook.orca", AppCategoryId.SOCIAL)
        put("com.facebook.katana", AppCategoryId.SOCIAL)
        put("com.instagram.android", AppCategoryId.SOCIAL)
        put("com.twitter.android", AppCategoryId.SOCIAL)
        put("com.discord", AppCategoryId.SOCIAL)
        put("com.skype.raider", AppCategoryId.SOCIAL)
        put("us.zoom.videomeetings", AppCategoryId.SOCIAL)
        put("com.microsoft.teams", AppCategoryId.SOCIAL)
        put("jp.naver.line.android", AppCategoryId.SOCIAL)
        put("com.linkedin.android", AppCategoryId.SOCIAL)
        put("com.snapchat.android", AppCategoryId.SOCIAL)
        put("com.zhiliaoapp.musically", AppCategoryId.SOCIAL)
        put("com.ss.android.ugc.trill", AppCategoryId.SOCIAL)
        put("com.alibaba.android.rimet", AppCategoryId.SOCIAL)

        // --- 浏览器 ---
        put("com.android.chrome", AppCategoryId.BROWSER)
        put("com.chrome.beta", AppCategoryId.BROWSER)
        put("com.chrome.dev", AppCategoryId.BROWSER)
        put("org.mozilla.firefox", AppCategoryId.BROWSER)
        put("org.mozilla.focus", AppCategoryId.BROWSER)
        put("com.microsoft.emmx", AppCategoryId.BROWSER)
        put("com.brave.browser", AppCategoryId.BROWSER)
        put("com.opera.browser", AppCategoryId.BROWSER)
        put("com.opera.mini.native", AppCategoryId.BROWSER)
        put("com.sec.android.app.sbrowser", AppCategoryId.BROWSER)
        put("com.vivaldi.browser", AppCategoryId.BROWSER)
        put("com.qc.web.browsers", AppCategoryId.BROWSER)
        put("com.quark.browser", AppCategoryId.BROWSER)
        put("com.UCMobile", AppCategoryId.BROWSER)
        put("com.tencent.mtt", AppCategoryId.BROWSER)
        put("com.heytap.browser", AppCategoryId.BROWSER)
        put("com.miui.browser", AppCategoryId.BROWSER)

        // --- 娱乐 ---
        put("com.google.android.youtube", AppCategoryId.ENTERTAINMENT)
        put("com.netflix.mediaclient", AppCategoryId.ENTERTAINMENT)
        put("tv.twitch.android.app", AppCategoryId.ENTERTAINMENT)
        put("com.spotify.music", AppCategoryId.ENTERTAINMENT)
        put("com.netease.cloudmusic", AppCategoryId.ENTERTAINMENT)
        put("com.tencent.qqmusic", AppCategoryId.ENTERTAINMENT)
        put("com.kugou.android", AppCategoryId.ENTERTAINMENT)
        put("com.ximalaya.ting.android", AppCategoryId.ENTERTAINMENT)
        put("tv.danmaku.bili", AppCategoryId.ENTERTAINMENT)
        put("com.tencent.qqlive", AppCategoryId.ENTERTAINMENT)
        put("com.qiyi.video", AppCategoryId.ENTERTAINMENT)
        put("com.youku.phone", AppCategoryId.ENTERTAINMENT)
        put("com.ss.android.ugc.aweme", AppCategoryId.ENTERTAINMENT)

        // --- 系统 / 桌面 / 输入法 ---
        put("com.android.systemui", AppCategoryId.SYSTEM)
        put("com.android.settings", AppCategoryId.SYSTEM)
        put("com.android.launcher", AppCategoryId.SYSTEM)
        put("com.android.launcher3", AppCategoryId.SYSTEM)
        put("com.google.android.apps.nexuslauncher", AppCategoryId.SYSTEM)
        put("com.miui.home", AppCategoryId.SYSTEM)
        put("com.huawei.android.launcher", AppCategoryId.SYSTEM)
        put("com.sec.android.app.launcher", AppCategoryId.SYSTEM)
        put("com.android.vending", AppCategoryId.SYSTEM)
        put("com.google.android.packageinstaller", AppCategoryId.SYSTEM)
        put("com.android.permissioncontroller", AppCategoryId.SYSTEM)
        put("com.google.android.inputmethod.latin", AppCategoryId.SYSTEM)
        put("com.baidu.input", AppCategoryId.SYSTEM)
        put("com.sohu.inputmethod.sogou", AppCategoryId.SYSTEM)
        put("com.tencent.qqpinyin", AppCategoryId.SYSTEM)
        // 其余厂商桌面（4C-6A 补充；真机验收必须能识别"回到桌面"）。
        put("com.oppo.launcher", AppCategoryId.SYSTEM)
        put("com.coloros.launcher", AppCategoryId.SYSTEM)
        put("com.oplus.launcher", AppCategoryId.SYSTEM)
        put("com.vivo.launcher", AppCategoryId.SYSTEM)
        put("com.bbk.launcher2", AppCategoryId.SYSTEM)
        put("com.oneplus.launcher", AppCategoryId.SYSTEM)
        put("com.hihonor.android.launcher", AppCategoryId.SYSTEM)

        // --- 补：终端 / IDE / 办公（真机"开发与办公应用"验收用例）---
        put("com.rhmsoft.code", AppCategoryId.DEVELOPMENT)
        put("com.tom.rv2ide", AppCategoryId.DEVELOPMENT)
        put("com.microsoft.office.mobile", AppCategoryId.PRODUCTIVITY)

        // --- PetLife 自身：归 system，避免"自己在前台导致状态无限切换" ---
        put("asia.akechi.petlife", AppCategoryId.SYSTEM)
    }

    /**
     * 查表用的精确规则（**键统一小写**）。
     *
     * 真机 4C-6A 实测缺陷：包名在查表前会经 [normalizePackageName] 归一化成小写，
     * 而表里存在 `com.UCMobile` / `com.transsion.XOSLauncher` 这类**含大写字母**
     * 的真实包名 —— 不统一大小写就会"表里有、却永远命中不到"，
     * 表现为"某个浏览器始终判成 other → 状态始终 default"。
     */
    private val exact: Map<String, String> =
        exactRaw.entries.associate { it.key.lowercase() to it.value }

    /**
     * 包名**关键字**规则（最后一级启发式，仅用于包名表与前缀表都没覆盖的应用）。
     *
     * 只匹配**包名**，绝不匹配应用显示名 —— 显示名会随系统语言变化、
     * 也会被用户改名，据此判定会得出"换个系统语言就换状态"的荒谬结论。
     *
     * 顺序敏感：先匹配到的先返回，因此把更具体的词放前面。
     */
    private val keywords: List<Pair<String, String>> = listOf(
        // 浏览器
        "browser" to AppCategoryId.BROWSER,
        "chrome" to AppCategoryId.BROWSER,
        "firefox" to AppCategoryId.BROWSER,
        "webkit" to AppCategoryId.BROWSER,
        // 开发 / 终端
        "termux" to AppCategoryId.DEVELOPMENT,
        "terminal" to AppCategoryId.DEVELOPMENT,
        "androidide" to AppCategoryId.DEVELOPMENT,
        "codeeditor" to AppCategoryId.DEVELOPMENT,
        "githubbrowser" to AppCategoryId.DEVELOPMENT,
        "stackexchange" to AppCategoryId.DEVELOPMENT,
        // 社交 / 通信
        "messenger" to AppCategoryId.SOCIAL,
        "whatsapp" to AppCategoryId.SOCIAL,
        "discord" to AppCategoryId.SOCIAL,
        "telegram" to AppCategoryId.SOCIAL,
        // 游戏
        "tmgp" to AppCategoryId.GAMING,
        "game" to AppCategoryId.GAMING,
        "games" to AppCategoryId.GAMING,
        // 视频 / 音乐
        "music" to AppCategoryId.ENTERTAINMENT,
        "video" to AppCategoryId.ENTERTAINMENT,
        "player" to AppCategoryId.ENTERTAINMENT,
        "media" to AppCategoryId.ENTERTAINMENT,
        // 办公 / 生产力
        "office" to AppCategoryId.PRODUCTIVITY,
        "wps" to AppCategoryId.PRODUCTIVITY,
        "notion" to AppCategoryId.PRODUCTIVITY,
        "obsidian" to AppCategoryId.PRODUCTIVITY,
        "onedrive" to AppCategoryId.PRODUCTIVITY,
        // 系统 / 桌面 / 输入法
        "launcher" to AppCategoryId.SYSTEM,
        "inputmethod" to AppCategoryId.SYSTEM,
        "systemui" to AppCategoryId.SYSTEM,
        "settings" to AppCategoryId.SYSTEM,
    )

    /** 包名前缀规则（用于厂商/子包结构不固定的应用，如游戏）。 */
    private val prefixes: List<Pair<String, String>> = listOf(
        "com.miHoYo." to AppCategoryId.GAMING,
        "com.miHoYo" to AppCategoryId.GAMING,
        "com.tencent.tmgp." to AppCategoryId.GAMING,
        "com.supercell." to AppCategoryId.GAMING,
        "com.epicgames." to AppCategoryId.GAMING,
        "com.ea.game" to AppCategoryId.GAMING,
        "com.gameloft." to AppCategoryId.GAMING,
        "com.activision." to AppCategoryId.GAMING,
        "com.riotgames." to AppCategoryId.GAMING,
        "com.netease.g" to AppCategoryId.GAMING,
        "com.pubg." to AppCategoryId.GAMING,
        "com.garena." to AppCategoryId.GAMING,
        "com.roblox." to AppCategoryId.GAMING,
        "com.mojang." to AppCategoryId.GAMING,
        "com.dts.freefire" to AppCategoryId.GAMING,
        "com.microsoft.office." to AppCategoryId.PRODUCTIVITY,
        "com.google.android.apps.docs" to AppCategoryId.PRODUCTIVITY,
    )

    /**
     * 归类。
     *
     * @param packageName 前台应用包名（会做小写 + 去空白归一化）
     * @param userCategory 用户自定义分类（`AppCategoryId` 之一；非法值忽略）
     */
    fun classify(
        packageName: String?,
        userCategory: String? = null,
        platformCategory: Int? = null,
    ): AppCategoryResult {
        // ① 用户为这个应用设定的分类（最高优先级，永远压过一切内置判断）。
        if (AppCategoryId.isKnown(userCategory)) {
            return AppCategoryResult(
                userCategory!!,
                AppCategorySource.userOverride,
                "user:$userCategory",
            )
        }
        val key = normalizePackageName(packageName)
            ?: return AppCategoryResult(
                AppCategoryId.OTHER,
                AppCategorySource.fallback,
                "empty-package",
            )

        // ② 精确包名覆盖表：最确定、最稳定，优先于系统声明。
        exact[key]?.let {
            return AppCategoryResult(it, AppCategorySource.builtInRule, "exact:$key")
        }

        // ③ 系统声明的分类（ApplicationInfo.category；缺失时是 null / UNDEFINED）。
        AndroidAppInfoCategory.toAppCategoryId(platformCategory)?.let {
            return AppCategoryResult(
                it,
                AppCategorySource.platformCategory,
                "platform:$platformCategory",
            )
        }

        // ④ 内置包名前缀规则（厂商 / 子包结构固定的应用，如游戏）。
        for ((prefix, category) in prefixes) {
            if (key.startsWith(prefix.lowercase())) {
                return AppCategoryResult(category, AppCategorySource.builtInRule, "prefix:$prefix")
            }
        }

        // ⑤ 内置包名关键字规则（长尾应用的启发式；只匹配包名，绝不匹配显示名）。
        for ((keyword, category) in keywords) {
            if (key.contains(keyword)) {
                return AppCategoryResult(category, AppCategorySource.builtInRule, "keyword:$keyword")
            }
        }

        // ⑥ 如实归到未归类 —— 不为了"看起来有结果"而猜一个分类。
        return AppCategoryResult(AppCategoryId.OTHER, AppCategorySource.fallback, "unmatched:$key")
    }

    /**
     * 包名归一化：去首尾空白 + 小写。
     *
     * 刻意**不做**"去掉最后一段"之类的猜测 —— 包名与进程名不同，
     * 截断会让 `com.tencent.mm` 与 `com.tencent.mobileqq` 混为一谈。
     */
    internal fun normalizePackageName(packageName: String?): String? {
        if (packageName == null) return null
        val trimmed = packageName.trim()
        if (trimmed.isEmpty()) return null
        return trimmed.lowercase()
    }
}

/**
 * 分类 → 状态的**解析结果**（Phase 4C-6A）。
 *
 * 为什么不是直接返回状态 ID：系统界面（设置页、权限弹窗…）这类"仅凭包名
 * 无法判断用户意图"的场景，正确行为是**保持上一个稳定状态**而不是硬给一个状态 ——
 * 否则桌宠会在系统界面之间反复切图（需求 §4.2）。
 */
internal sealed class CategoryStateOutcome {

    /** 明确映射到某个状态。 */
    data class Mapped(val stateId: String) : CategoryStateOutcome()

    /** 保持上一个稳定状态（只清候选、不换素材）。 */
    data object Hold : CategoryStateOutcome()
}

/**
 * 分类 → 状态。
 *
 * Phase 4C-6A 修正了"日常应用根本不会触发切换"的问题：
 * * **桌面（launcher）→ `away`**：项目既有语义里 idle 就是 `away`
 *   （Dart `ActivityStateMapper`：用户空闲 → away），因此不新增状态；
 * * **浏览器 → `focused`**：既有 11 个状态里没有 reading/curious，
 *   而"看网页"在语义上最接近"专注"。此前 browser→default 会让
 *   "打开浏览器桌宠毫无反应"（这正是 4C-6A 要修的核心缺陷）；
 * * **其他系统界面 → 保持上一个稳定状态**（[CategoryStateOutcome.Hold]）；
 * * 开发 / 办公 / 游戏 / 通信 / 娱乐的映射**保持不变**（原来是正确的）。
 *
 * 仍然**只使用项目既有的 11 个状态 wire 值**，不新增任何状态命名。
 */
internal object AppCategoryStateMapper {

    /**
     * 解析分类对应的状态。
     *
     * @param isLauncher 该包名是否为当前设备的桌面（launcher）。桌面也属于
     *   `system` 分类，但语义完全不同（回到桌面 ≈ 空闲），因此单独先判。
     */
    fun outcomeFor(category: String, isLauncher: Boolean = false): CategoryStateOutcome {
        if (isLauncher) return CategoryStateOutcome.Mapped(PetStateId.AWAY)
        return when (category) {
            AppCategoryId.DEVELOPMENT,
            AppCategoryId.PRODUCTIVITY,
            AppCategoryId.BROWSER,
            -> CategoryStateOutcome.Mapped(PetStateId.FOCUSED)

            AppCategoryId.GAMING -> CategoryStateOutcome.Mapped(PetStateId.GAMING)
            AppCategoryId.SOCIAL -> CategoryStateOutcome.Mapped(PetStateId.SOCIAL)
            AppCategoryId.ENTERTAINMENT -> CategoryStateOutcome.Mapped(PetStateId.ENTERTAINED)
            AppCategoryId.SYSTEM -> CategoryStateOutcome.Hold
            else -> CategoryStateOutcome.Mapped(PetStateId.DEFAULT)
        }
    }

    /** 分类说明（写入判定原因，与 Dart 的 note 对齐）。 */
    fun noteForCategory(category: String, isLauncher: Boolean = false): String {
        if (isLauncher) return "（桌面 / 空闲）"
        return when (category) {
            AppCategoryId.DEVELOPMENT -> "（开发工具）"
            AppCategoryId.PRODUCTIVITY -> "（办公软件）"
            AppCategoryId.BROWSER -> "（浏览器 / 阅读）"
            AppCategoryId.GAMING -> "（游戏）"
            AppCategoryId.SOCIAL -> "（通信软件）"
            AppCategoryId.ENTERTAINMENT -> "（娱乐）"
            AppCategoryId.SYSTEM -> "（系统界面，保持上一个状态）"
            else -> "（未归类）"
        }
    }
}

/**
 * 防抖决策。
 *
 * 每个分支都带上"为什么"的结构化字段 —— 设置页诊断区据此显示
 * `lastTransitionResult` / `lastTransitionReason`，不必去正则匹配中文说明。
 */
internal sealed class PetDebounceOutcome {

    /** 状态正式生效。[stableForMs] = 候选从首次出现到提交所经历的毫秒数。 */
    data class Accepted(
        val stateId: String,
        val reason: String,
        val stableForMs: Long = 0L,
    ) : PetDebounceOutcome()

    /**
     * 候选尚未稳定，继续等待（诊断用）。
     *
     * [suppressed] = true 表示"其实已经稳定，只是落在快速切换抑制窗口内"——
     * 与"还需要再等一会儿"是两件不同的事，诊断必须能分开看。
     */
    data class Waiting(
        val stateId: String,
        val consecutiveCount: Int,
        val remainingMs: Long,
        val reason: String,
        val suppressed: Boolean = false,
    ) : PetDebounceOutcome()

    /**
     * 本轮不改变状态。
     *
     * [code] 是给诊断用的稳定枚举值：`unchanged`（与当前状态相同）/
     * `manual`（manual 状态锁定）。
     */
    data class Ignored(
        val reason: String,
        val code: String = "unchanged",
    ) : PetDebounceOutcome()
}

/**
 * 状态防抖（需求 §12）。
 *
 * 与 Dart `StateDebouncer` 的语义保持一致（同一套参数），但**只保留原生需要的那部分**：
 * 候选必须"连续出现 N 次且持续够久"才生效，并且受快速切换抑制窗口约束。
 *
 * 纯逻辑：不持有 Handler / 计时器，`now` 由调用方传入 —— 因此可以用虚拟时间穷举测试。
 */
internal class PetStateDebouncer(
    private val requiredConsecutive: Int = DEFAULT_REQUIRED_CONSECUTIVE,
    private val stableMs: Long = DEFAULT_STABLE_MS,
    private val rapidSwitchSuppressMs: Long = DEFAULT_RAPID_SUPPRESS_MS,
) {

    private var candidateId: String? = null
    private var firstSeenAt: Long = 0L
    private var consecutiveCount: Int = 0
    private var lastAppliedAt: Long = 0L

    /** 诊断：当前候选状态（没有则 null）。 */
    val candidate: String? get() = candidateId

    /** 诊断：候选已连续出现多少次。 */
    val consecutive: Int get() = consecutiveCount

    /** 诊断：候选首次出现的时间。 */
    val candidateSince: Long get() = firstSeenAt

    /** 停止监听 / 停止服务时清空候选（需求 §22 第 20 条）。 */
    fun reset() {
        candidateId = null
        firstSeenAt = 0L
        consecutiveCount = 0
    }

    /**
     * 提交一次候选状态。
     *
     * **刻意不做"最短展示时长"**（Dart `StateDebouncer` 有这一条）：
     * 需求 §25-B 的验收方式是"每个应用停留 3~5 秒，确认状态随之变化"，
     * 而 Dart 侧的最短展示时长是 15 秒 —— 直接搬过来会让验收永远等不到切换。
     * 这里的"不连跳"由**候选稳定性 + 快速切换抑制**两条共同保证，语义不打折。
     *
     * @param candidateStateId 本次检测出的目标状态
     * @param currentStateId   当前已生效状态
     * @param now              当前时间（毫秒，由调用方提供，便于测试）
     * @param fastPath         true = 跳过"候选稳定性"门槛（显示桌宠后的首次检测、
     *   解锁后的首次检测用）。需求 §12/§17.5 允许这类"第一次检测"不等防抖，
     *   否则用户解锁后要盯着旧素材看一秒多才恢复。
     */
    fun offer(
        candidateStateId: String,
        currentStateId: String,
        now: Long,
        fastPath: Boolean = false,
    ): PetDebounceOutcome {
        // 1. manual 锁定：自动状态不得顶掉它（与 Dart StateDebouncer 第 1 条一致）。
        if (currentStateId == PetStateId.MANUAL && candidateStateId != PetStateId.MANUAL) {
            reset()
            return PetDebounceOutcome.Ignored("manual 状态已锁定，需用户先解除", code = "manual")
        }

        // 2. 与当前状态相同：不重新加载素材、不重启动画。
        if (candidateStateId == currentStateId) {
            reset()
            return PetDebounceOutcome.Ignored("状态未发生变化", code = "unchanged")
        }

        // 3. 候选记账。
        if (candidateId != candidateStateId) {
            candidateId = candidateStateId
            firstSeenAt = now
            consecutiveCount = 1
        } else {
            consecutiveCount += 1
        }

        val stableFor = now - firstSeenAt
        val neededMs = maxOf(0L, stableMs - stableFor)
        val stableEnough = fastPath ||
            (consecutiveCount >= requiredConsecutive && stableFor >= stableMs)
        if (!stableEnough) {
            return PetDebounceOutcome.Waiting(
                stateId = candidateStateId,
                consecutiveCount = consecutiveCount,
                remainingMs = neededMs,
                reason = "候选状态需连续 $requiredConsecutive 次且稳定 ${stableMs}ms" +
                    "（当前 $consecutiveCount 次 / ${stableFor}ms）",
            )
        }

        // 4. 快速切换抑制（"快速切换应用时不得连跳"的落点，需求 §25-C）。
        if (lastAppliedAt > 0L && now - lastAppliedAt < rapidSwitchSuppressMs) {
            return PetDebounceOutcome.Waiting(
                stateId = candidateStateId,
                consecutiveCount = consecutiveCount,
                remainingMs = rapidSwitchSuppressMs - (now - lastAppliedAt),
                reason = "处于快速切换抑制窗口（${rapidSwitchSuppressMs}ms）",
                suppressed = true,
            )
        }

        lastAppliedAt = now
        // 提交前把"候选稳定了多久"记下来（reset 之后就拿不到了）。
        val stableForMs = stableFor
        reset()
        return PetDebounceOutcome.Accepted(
            stateId = candidateStateId,
            reason = "候选状态已稳定并通过防抖",
            stableForMs = stableForMs,
        )
    }

    companion object {
        /** 需要连续出现的次数（需求 §12：连续稳定 2 次）。 */
        const val DEFAULT_REQUIRED_CONSECUTIVE = 2

        /** 需要持续的时间（需求 §12：800~1500ms 区间，取 1000ms）。 */
        const val DEFAULT_STABLE_MS = 1000L

        /** 快速切换抑制窗口，与 Dart `StateDebounce.rapidSwitchSuppressMs` 一致。 */
        const val DEFAULT_RAPID_SUPPRESS_MS = 400L
    }
}

/**
 * 临时预览窗口（Phase 4C-6A.1，需求 §11）。
 *
 * 为什么单独一个类而不是在 [PetOverlayService] 里散着两个字段：
 * * 预览的"开始 / 替换 / 到期 / 结束"是可以**纯逻辑打靶**的（本类不引用 Android）；
 * * 服务里只剩"什么时候调用它"，可读性与可测性都更好。
 *
 * **绝不持久化**：需求 §11.2 明确"服务重启后不恢复临时预览"，
 * 因此本类没有任何写盘接口 —— 新实例永远是"没有预览"。
 */
internal class PreviewWindow(val durationMs: Long = DEFAULT_DURATION_MS) {

    /** 正在预览的状态 ID；null = 没有预览。 */
    var stateId: String? = null
        private set

    /** 到期时间（墙钟毫秒）；0 = 没有预览。 */
    var expiresAt: Long = 0L
        private set

    val isActive: Boolean get() = stateId != null

    /**
     * 开始（或**替换**）预览。
     *
     * 需求 §11.1："预览另一个状态时替换上一个" —— 因此这里直接覆盖，
     * 不需要先 clear（服务侧也不用做特判）。
     */
    fun start(stateId: String, now: Long) {
        this.stateId = stateId
        this.expiresAt = now + durationMs
    }

    /** 结束预览（幂等）。 */
    fun clear() {
        stateId = null
        expiresAt = 0L
    }

    /** 是否已到期（没有预览时返回 false —— "没预览"不等于"到期"）。 */
    fun isExpired(now: Long): Boolean {
        if (stateId == null) return false
        return now >= expiresAt
    }

    /** 剩余毫秒（没有预览或已到期时为 0）。 */
    fun remainingMs(now: Long): Long {
        if (stateId == null) return 0L
        val left = expiresAt - now
        return if (left < 0L) 0L else left
    }

    companion object {
        /** 需求 §11.1："约 10 秒后恢复自动状态"。 */
        const val DEFAULT_DURATION_MS = 10_000L
    }
}

/** 一次素材选择的结果（回退链的落点）。 */
internal data class NativeAssetSelection(
    val asset: NativePetAsset,
    val level: Int,
    val reason: String,
)

/**
 * 状态 → 素材的回退链（需求 §14）。
 *
 * 语义与 Flutter `FallbackChain` 一致，只是**窄化**到原生手里有的信息：
 * ```
 * 1. 当前状态对应素材
 * 2. 当前角色默认素材
 * 3. 当前角色任一有效素材
 * 4. 可见占位（由返回 null 表示）
 * ```
 *
 * `characterId` 由快照自带，因此"不跨角色回退"是结构性保证：
 * 这里只能看到当前角色那一份映射。
 */
internal object NativeAssetSelector {

    const val LEVEL_STATE_ASSET = 1
    const val LEVEL_CHARACTER_DEFAULT = 2
    const val LEVEL_FIRST_VALID = 3
    const val LEVEL_PLACEHOLDER = 4

    fun select(mapping: NativePetStateMapping, stateId: String): NativeAssetSelection? {
        mapping.assetFor(stateId)?.let {
            return NativeAssetSelection(it, LEVEL_STATE_ASSET, "命中状态 $stateId 的指定素材")
        }
        mapping.defaultAsset?.let {
            return NativeAssetSelection(
                it,
                LEVEL_CHARACTER_DEFAULT,
                "状态 $stateId 无映射，回退到角色默认素材",
            )
        }
        val any = mapping.allAssets().firstOrNull()
            ?: return null
        return NativeAssetSelection(
            any,
            LEVEL_FIRST_VALID,
            "状态 $stateId 无映射且无默认素材，回退到角色任一有效素材",
        )
    }
}

/**
 * 路径 → MIME。
 *
 * 只用于日志与 `PetOverlayConfig` 的必填字段：**真正的格式判定在解码器里**
 * （magic bytes / `ImageDecoder` 返回类型），因此这里按扩展名给一个合理值即可，
 * 不必也不应该据此拒绝素材。
 */
internal object PetMime {
    fun forPath(path: String): String =
        when (path.substringAfterLast('.', "").lowercase()) {
            "png" -> "image/png"
            "jpg", "jpeg" -> "image/jpeg"
            "gif" -> "image/gif"
            else -> "image/webp"
        }
}

/** 映射里的一个素材（需求 §8）。 */
internal data class NativePetAsset(
    val assetId: String,
    val path: String,
    val isAnimated: Boolean,
)

/**
 * 状态 → 素材的只读快照 + **自动联动配置**（需求 §8 / Phase 4C-6A）。
 *
 * * `stateAssets` 的键必须是 [PetStateId.ALL] 里的合法 ID；未知键在解析时被忽略。
 * * Phase 4C-6A 新增的三个字段都是**可选的**（老快照没有它们照样能解析）：
 *   缺失时 `automaticEnabled = true`、规则表为空 → 原生退回内置规则，
 *   因此**不需要提升 schemaVersion**（提升反而会让升级瞬间"没有映射可用"）。
 */
internal data class NativePetStateMapping(
    val characterId: String,
    val defaultAsset: NativePetAsset?,
    val stateAssets: Map<String, NativePetAsset>,
    val revision: Long,
    /** 自动状态联动总开关（用户可在设置页关闭；关闭后只保留手动覆盖）。 */
    val automaticEnabled: Boolean = true,
    /**
     * 分类 → 状态规则（[AppCategoryId] → [PetStateId]）。
     *
     * 由 Flutter 下发，保证"规则只有一份"；为空时用原生内置表
     * [AppCategoryStateMapper] 兜底（两者语义一致）。
     */
    val categoryRules: Map<String, String> = emptyMap(),
    /** 具体应用覆盖规则（包名 → [PetStateId]），优先级高于分类规则。 */
    val appOverrides: Map<String, String> = emptyMap(),
) {

    /** 该状态对应的素材（没有则 null）。 */
    fun assetFor(stateId: String): NativePetAsset? = stateAssets[stateId]

    /** 角色下全部有效素材（回退链用；按 assetId 去重且顺序稳定）。 */
    fun allAssets(): List<NativePetAsset> {
        val seen = LinkedHashMap<String, NativePetAsset>()
        defaultAsset?.let { seen[it.assetId] = it }
        for (id in PetStateId.ALL) {
            stateAssets[id]?.let { seen[it.assetId] = it }
        }
        return seen.values.toList()
    }

    /** 提取运行时规则（供 [PetStateMonitor] 使用）。 */
    fun rules(): PetStateRules = PetStateRules(
        automaticEnabled = automaticEnabled,
        categoryRules = categoryRules,
        appOverrides = appOverrides,
    )

    companion object {
        /** 空映射（尚未收到 Flutter 推送时使用）。 */
        val EMPTY = NativePetStateMapping(
            characterId = "",
            defaultAsset = null,
            stateAssets = emptyMap(),
            revision = 0L,
        )
    }
}

/**
 * 映射快照的**严格解析**（需求 §9）。
 *
 * 传输格式就是 MethodChannel 给过来的嵌套 Map（Flutter 侧 `toJson()` 的结果），
 * 这里做逐字段校验：类型不符 / 缺关键字段 / 未知状态 ID 都有明确处置，
 * 绝不"猜一个默认值"。
 *
 * @param previous 上一次有效映射：整体解析失败时返回它，避免服务因一次坏数据失控。
 */
internal object NativePetStateMappingParser {

    data class Result(
        val mapping: NativePetStateMapping?,
        val code: String?,
        val message: String?,
    )

    fun parse(raw: Any?, previous: NativePetStateMapping?): Result {
        if (raw !is Map<*, *>) {
            return Result(previous, PetStateError.MAPPING_PARSE_FAILED, "映射不是对象")
        }
        val revision = (raw["revision"] as? Number)?.toLong()
            ?: return Result(previous, PetStateError.MAPPING_PARSE_FAILED, "revision 缺失或类型不符")
        if (revision < 0) {
            return Result(previous, PetStateError.MAPPING_PARSE_FAILED, "revision 非法")
        }
        if (previous != null && revision < previous.revision) {
            return Result(
                previous,
                PetStateError.MAPPING_REVISION_STALE,
                "旧 revision（$revision < ${previous.revision}）被拒绝",
            )
        }
        val characterId = raw["characterId"] as? String
        if (characterId.isNullOrBlank()) {
            return Result(previous, PetStateError.MAPPING_PARSE_FAILED, "characterId 缺失")
        }

        val defaultAsset = parseAsset(raw["defaultAsset"])

        val statesRaw = raw["states"]
        val states = LinkedHashMap<String, NativePetAsset>()
        var ignoredUnknown = 0
        if (statesRaw is Map<*, *>) {
            for ((key, value) in statesRaw) {
                val stateId = key as? String ?: continue
                if (!PetStateId.isKnown(stateId)) {
                    // 未知状态 ID：忽略并记录，不影响其它条目（需求 §9）。
                    ignoredUnknown += 1
                    continue
                }
                val asset = parseAsset(value) ?: continue
                states[stateId] = asset
            }
        }

        return Result(
            mapping = NativePetStateMapping(
                characterId = characterId,
                defaultAsset = defaultAsset,
                stateAssets = states,
                revision = revision,
                // 三个 4C-6A 字段都可选：缺失时沿用上一次的值（首次则用默认），
                // 因此老版本 Flutter 推来的快照不会把配置"清零"。
                automaticEnabled = raw["automaticEnabled"] as? Boolean
                    ?: previous?.automaticEnabled
                    ?: true,
                categoryRules = parseRules(
                    raw = raw["categoryRules"],
                    previous = previous?.categoryRules,
                    keyValidator = { AppCategoryId.isKnown(it) },
                ),
                appOverrides = parseRules(
                    raw = raw["appOverrides"],
                    previous = previous?.appOverrides,
                    keyValidator = { it.isNotBlank() },
                ),
            ),
            code = if (ignoredUnknown > 0) PetStateError.UNKNOWN_STATE else null,
            message = if (ignoredUnknown > 0) "忽略了 $ignoredUnknown 个未知状态 ID" else null,
        )
    }

    /**
     * 解析 `分类/应用 → 状态` 规则表。
     *
     * 规则：键必须通过 [keyValidator]，**值必须是既有的状态 ID**（否则整条丢弃）——
     * 这样即使 Flutter 侧写错，原生也不会进入一个不存在的状态。
     */
    private fun parseRules(
        raw: Any?,
        previous: Map<String, String>?,
        keyValidator: (String) -> Boolean,
    ): Map<String, String> {
        if (raw !is Map<*, *>) return previous ?: emptyMap()
        val out = LinkedHashMap<String, String>()
        for ((key, value) in raw) {
            val k = (key as? String)?.trim().orEmpty()
            val v = (value as? String)?.trim().orEmpty()
            if (!keyValidator(k)) continue
            if (!PetStateId.isKnown(v)) continue
            out[k] = v
        }
        return out
    }

    /** 单个素材：三个字段都必须合法，否则整条丢弃（回退链自动顶上）。 */
    private fun parseAsset(raw: Any?): NativePetAsset? {
        if (raw !is Map<*, *>) return null
        val assetId = (raw["assetId"] as? String)?.trim().orEmpty()
        val path = (raw["path"] as? String)?.trim().orEmpty()
        if (assetId.isEmpty() || path.isEmpty()) return null
        return NativePetAsset(
            assetId = assetId,
            path = path,
            isAnimated = raw["isAnimated"] == true,
        )
    }
}

/** 状态联动错误码（需求 §21）。 */
internal object PetStateError {
    const val USAGE_ACCESS_MISSING = "usage_access_missing"
    const val FOREGROUND_APP_UNAVAILABLE = "foreground_app_unavailable"
    const val UNKNOWN_PACKAGE = "unknown_package"
    const val UNKNOWN_STATE = "unknown_state"
    const val MAPPING_MISSING = "mapping_missing"
    const val MAPPING_REVISION_STALE = "mapping_revision_stale"
    const val MAPPING_PARSE_FAILED = "mapping_parse_failed"
    const val STATE_ASSET_MISSING = "state_asset_missing"
    const val STATE_ASSET_INVALID = "state_asset_invalid"
    const val STATE_DECODE_FAILED = "state_decode_failed"
    const val MONITOR_DISPOSED = "monitor_disposed"
    const val STALE_STATE_RESULT = "stale_state_result"
}

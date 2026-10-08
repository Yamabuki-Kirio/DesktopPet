package asia.akechi.petlife.overlay

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Phase 4C-5：状态联动的**纯逻辑**测试。
 *
 * 覆盖需求 §22 里可以在 JVM 上真实验证的部分：状态 ID 契约、权限与前台应用、
 * 包名分类、防抖、映射解析、回退链、监听任务。
 *
 * 需要真实 `UsageStatsManager` / `SharedPreferences` / `WindowManager` 的条目
 * （授权与撤销权限、真机前台应用切换、映射落盘与重启恢复、素材上屏与动画、
 * 菜单兼容、位置与大小不受影响）属于**仪器测试与真机验收**，见 docs §11，
 * **不在 JVM 测试里假装通过**。
 */
class PetStateIdTest {

    @Test
    fun `状态 ID 与 Flutter SystemState 逐字一致且共 11 个`() {
        assertEquals(
            listOf(
                "error", "manual", "concerned", "tired", "happy",
                "gaming", "focused", "social", "entertained", "away", "default",
            ),
            PetStateId.ALL,
        )
        assertEquals(11, PetStateId.ALL.size)
        assertTrue(PetStateId.isKnown("focused"))
        assertFalse(PetStateId.isKnown("sleeping"))
        assertFalse(PetStateId.isKnown(null))
    }

    @Test
    fun `中文说明齐全（设置页只读诊断用）`() {
        assertEquals("默认", PetStateId.descriptionZh(PetStateId.DEFAULT))
        assertEquals("社交", PetStateId.descriptionZh(PetStateId.SOCIAL))
        assertEquals("手动锁定", PetStateId.descriptionZh(PetStateId.MANUAL))
    }

    @Test
    fun `未知状态 ID 的中文说明退回原样，不编造标签`() {
        assertEquals("hibernating", PetStateId.descriptionZh("hibernating"))
    }
}

class AndroidAppCategoryRulesTest {

    @Test
    fun `已知包名映射到已有分类`() {
        assertEquals(
            AppCategoryId.SOCIAL,
            AndroidAppCategoryRules.classify("org.telegram.messenger").category,
        )
        assertEquals(
            AppCategoryId.BROWSER,
            AndroidAppCategoryRules.classify("com.android.chrome").category,
        )
        assertEquals(
            AppCategoryId.GAMING,
            AndroidAppCategoryRules.classify("com.miHoYo.GenshinImpact").category,
        )
        assertEquals(
            AppCategoryId.PRODUCTIVITY,
            AndroidAppCategoryRules.classify("com.microsoft.office.word").category,
        )
    }

    @Test
    fun `未知包名归入 other 而不是猜一个特殊状态`() {
        val result = AndroidAppCategoryRules.classify("com.example.unknown.app")
        assertEquals(AppCategoryId.OTHER, result.category)
        assertEquals(AppCategorySource.fallback, result.source)
    }

    @Test
    fun `包名归一化：大小写与首尾空白`() {
        assertEquals(
            AppCategoryId.SOCIAL,
            AndroidAppCategoryRules.classify("  ORG.Telegram.Messenger  ").category,
        )
        assertNull(AndroidAppCategoryRules.normalizePackageName("   "))
        assertNull(AndroidAppCategoryRules.normalizePackageName(null))
        assertEquals(
            "com.tencent.mm",
            AndroidAppCategoryRules.normalizePackageName(" COM.Tencent.MM "),
        )
    }

    @Test
    fun `用户自定义分类优先于内置规则`() {
        val result = AndroidAppCategoryRules.classify(
            packageName = "org.telegram.messenger",
            userCategory = AppCategoryId.PRODUCTIVITY,
        )
        assertEquals(AppCategoryId.PRODUCTIVITY, result.category)
        assertEquals(AppCategorySource.userOverride, result.source)
        // 非法的用户分类被忽略，退回内置规则。
        val ignored = AndroidAppCategoryRules.classify(
            packageName = "org.telegram.messenger",
            userCategory = "not-a-category",
        )
        assertEquals(AppCategoryId.SOCIAL, ignored.category)
        assertEquals(AppCategorySource.builtInRule, ignored.source)
    }

    @Test
    fun `PetLife 自身与系统桌面归 system，避免自己在前台导致无限切换`() {
        assertEquals(
            AppCategoryId.SYSTEM,
            AndroidAppCategoryRules.classify("asia.akechi.petlife").category,
        )
        assertEquals(
            AppCategoryId.SYSTEM,
            AndroidAppCategoryRules.classify("com.android.launcher3").category,
        )
        assertEquals(
            AppCategoryId.SYSTEM,
            AndroidAppCategoryRules.classify("com.google.android.inputmethod.latin").category,
        )
    }

    @Test
    fun `分类异常输入不崩溃`() {
        assertEquals(AppCategoryId.OTHER, AndroidAppCategoryRules.classify(null).category)
        assertEquals(AppCategoryId.OTHER, AndroidAppCategoryRules.classify("").category)
        assertEquals(AppCategoryId.OTHER, AndroidAppCategoryRules.classify("   ").category)
    }

    // --- Phase 4C-6A 真机修复：真实包名回归 ---
    // 真机缺陷是"切换浏览器 / Telegram 后状态仍是 default"，因此这一组
    // **刻意使用真机上真实存在的包名**逐条打靶（不是"看起来像"的假包名）。

    @Test
    fun `真实浏览器包名归 browser`() {
        val browsers = listOf(
            "com.android.chrome",
            "org.mozilla.firefox",
            "com.microsoft.emmx",
            "com.brave.browser",
            "com.tencent.mtt",
            "com.quark.browser",
            "com.UCMobile",
            "com.heytap.browser",
            "com.miui.browser",
        )
        for (pkg in browsers) {
            val result = AndroidAppCategoryRules.classify(pkg)
            assertEquals("浏览器包名 $pkg", AppCategoryId.BROWSER, result.category)
        }
    }

    @Test
    fun `Telegram 与微信 QQ 归 social`() {
        for (pkg in listOf(
            "org.telegram.messenger",
            "org.telegram.plus",
            "com.tencent.mm",
            "com.tencent.mobileqq",
            "com.alibaba.android.rimet",
        )) {
            assertEquals("通信包名 $pkg", AppCategoryId.SOCIAL, AndroidAppCategoryRules.classify(pkg).category)
        }
    }

    @Test
    fun `常见游戏包名（含包名关键字）归 gaming`() {
        for (pkg in listOf(
            "com.miHoYo.GenshinImpact",
            "com.tencent.tmgp.sgame",
            "com.miHoYo.hkrpg",
            "com.supercell.clashofclans",
            "com.dts.freefireth",
        )) {
            assertEquals("游戏包名 $pkg", AppCategoryId.GAMING, AndroidAppCategoryRules.classify(pkg).category)
        }
    }

    @Test
    fun `视频音乐与终端办公也能归类（真机验收用例）`() {
        assertEquals(
            AppCategoryId.ENTERTAINMENT,
            AndroidAppCategoryRules.classify("com.netease.cloudmusic").category,
        )
        assertEquals(
            AppCategoryId.ENTERTAINMENT,
            AndroidAppCategoryRules.classify("tv.danmaku.bili").category,
        )
        assertEquals(
            AppCategoryId.DEVELOPMENT,
            AndroidAppCategoryRules.classify("com.termux").category,
        )
        assertEquals(
            AppCategoryId.PRODUCTIVITY,
            AndroidAppCategoryRules.classify("com.microsoft.office.word").category,
        )
    }

    @Test
    fun `系统声明分类在包名表未命中时生效`() {
        val result = AndroidAppCategoryRules.classify(
            packageName = "com.studio.some.unknown.app",
            platformCategory = AndroidAppInfoCategory.GAME,
        )
        assertEquals(AppCategoryId.GAMING, result.category)
        assertEquals(AppCategorySource.platformCategory, result.source)
    }

    @Test
    fun `具体包名表优先于系统声明分类（包名表更确定）`() {
        val result = AndroidAppCategoryRules.classify(
            packageName = "com.android.chrome",
            platformCategory = AndroidAppInfoCategory.GAME,
        )
        assertEquals(AppCategoryId.BROWSER, result.category)
        assertEquals(AppCategorySource.builtInRule, result.source)
    }

    @Test
    fun `UNDEFINED 与未知声明值不猜测，继续走包名规则`() {
        val undefined = AndroidAppCategoryRules.classify(
            packageName = "com.studio.some.unknown.app",
            platformCategory = AndroidAppInfoCategory.UNDEFINED,
        )
        assertEquals(AppCategoryId.OTHER, undefined.category)
        assertEquals(AppCategorySource.fallback, undefined.source)

        val bogus = AndroidAppCategoryRules.classify(
            packageName = "com.studio.some.unknown.app",
            platformCategory = 999,
        )
        assertEquals(AppCategoryId.OTHER, bogus.category)
    }

    @Test
    fun `系统声明分类的映射只用既有 8 类`() {
        for (raw in listOf(
            AndroidAppInfoCategory.GAME,
            AndroidAppInfoCategory.AUDIO,
            AndroidAppInfoCategory.VIDEO,
            AndroidAppInfoCategory.IMAGE,
            AndroidAppInfoCategory.SOCIAL,
            AndroidAppInfoCategory.NEWS,
            AndroidAppInfoCategory.MAPS,
            AndroidAppInfoCategory.PRODUCTIVITY,
            AndroidAppInfoCategory.ACCESSIBILITY,
            AndroidAppInfoCategory.UNDEFINED,
        )) {
            val mapped = AndroidAppInfoCategory.toAppCategoryId(raw)
            if (mapped != null) assertTrue("未知分类 $mapped", AppCategoryId.isKnown(mapped))
        }
    }

    @Test
    fun `分类依据可解释（说明命中了什么）`() {
        assertEquals(
            "exact:com.android.chrome",
            AndroidAppCategoryRules.classify("com.android.chrome").detail,
        )
        assertEquals(
            "keyword:game",
            AndroidAppCategoryRules.classify("com.studio.mygame.arcade").detail,
        )
        assertEquals(
            "prefix:com.supercell.",
            AndroidAppCategoryRules.classify("com.supercell.clashofclans").detail,
        )
        assertEquals(
            "platform:0",
            AndroidAppCategoryRules.classify("com.studio.unknown.app", platformCategory = 0).detail,
        )
    }
}

/**
 * Phase 4C-6A.1：临时预览窗口的纯逻辑（需求 §11.1 / §11.2 / §16.4）。
 *
 * "服务重启后不恢复预览"由 [PreviewWindow] **没有任何持久化接口**结构性保证，
 * 这里同时钉住"新实例就是没有预览"。
 */
class PreviewWindowTest {

    @Test
    fun `开始预览后处于激活状态，到期时间等于开始时间 + 时长`() {
        val window = PreviewWindow()
        window.start(PetStateId.FOCUSED, now = 1_000L)

        assertTrue(window.isActive)
        assertEquals(PetStateId.FOCUSED, window.stateId)
        assertEquals(1_000L + PreviewWindow.DEFAULT_DURATION_MS, window.expiresAt)
        assertEquals(PreviewWindow.DEFAULT_DURATION_MS, window.remainingMs(1_000L))
    }

    @Test
    fun `预览时长是 10 秒（需求「约 10 秒后恢复自动状态」）`() {
        assertEquals(10_000L, PreviewWindow.DEFAULT_DURATION_MS)
        // 服务侧常量必须与它一致，否则文档与行为会分叉。
        assertEquals(PreviewWindow.DEFAULT_DURATION_MS, PetOverlayService.PREVIEW_DURATION_MS)
    }

    @Test
    fun `预览另一个状态会替换上一个，并重新计时`() {
        val window = PreviewWindow()
        window.start(PetStateId.FOCUSED, now = 1_000L)
        window.start(PetStateId.SOCIAL, now = 5_000L)

        assertEquals(PetStateId.SOCIAL, window.stateId)
        assertEquals(5_000L + PreviewWindow.DEFAULT_DURATION_MS, window.expiresAt)
    }

    @Test
    fun `未到期不算到期，到点才算（边界：恰好在到期时刻算到期）`() {
        val window = PreviewWindow(durationMs = 10_000L)
        window.start(PetStateId.GAMING, now = 0L)

        assertFalse(window.isExpired(9_999L))
        assertTrue(window.isExpired(10_000L))
        assertTrue(window.isExpired(20_000L))
    }

    @Test
    fun `没有预览时 isExpired 为 false（没预览不等于到期）`() {
        val window = PreviewWindow()
        assertFalse(window.isActive)
        assertFalse(window.isExpired(999_999L))
        assertEquals(0L, window.remainingMs(999_999L))
    }

    @Test
    fun `手动结束后立刻失效，且清掉到期时间`() {
        val window = PreviewWindow()
        window.start(PetStateId.AWAY, now = 100L)
        window.clear()

        assertFalse(window.isActive)
        assertNull(window.stateId)
        assertEquals(0L, window.expiresAt)
        // 幂等：重复结束不抛错。
        window.clear()
        assertFalse(window.isActive)
    }

    @Test
    fun `新实例永远是没有预览（服务重启后不得恢复）`() {
        val first = PreviewWindow()
        first.start(PetStateId.HAPPY, now = 1L)
        first.clear()

        val restarted = PreviewWindow()
        assertFalse(restarted.isActive)
        assertNull(restarted.stateId)
    }

    @Test
    fun `到期时间用墙钟（到期本身就是「到几点」的语义）`() {
        val window = PreviewWindow(durationMs = 300L)
        val now = 1_700_000_000_000L
        window.start(PetStateId.SOCIAL, now)
        assertEquals(now + 300L, window.expiresAt)
        assertEquals(300L, window.remainingMs(now))
        assertEquals(100L, window.remainingMs(now + 200L))
    }
}

class PetStateRulesCodecTest {

    @Test
    fun `规则表编码后再解码得到同一份（服务重启后规则仍存在）`() {
        val rules = mapOf(
            AppCategoryId.BROWSER to PetStateId.FOCUSED,
            AppCategoryId.SOCIAL to PetStateId.SOCIAL,
            AppCategoryId.GAMING to PetStateId.GAMING,
            "com.tencent.mm" to PetStateId.SOCIAL,
        )
        val restored = PetStateRulesCodec.decode(PetStateRulesCodec.encode(rules))
        assertEquals(rules, restored)
    }

    @Test
    fun `损坏的行被逐条丢弃，不影响其它规则`() {
        val restored = PetStateRulesCodec.decode(
            "browser=focused\n" +
                "没有等号的一行\n" +
                "=没有键\n" +
                "social=\n" +
                "gaming=gaming\n",
        )
        assertEquals(
            mapOf(AppCategoryId.BROWSER to PetStateId.FOCUSED, AppCategoryId.GAMING to PetStateId.GAMING),
            restored,
        )
    }

    @Test
    fun `空字符串与 null 解出空规则表`() {
        assertTrue(PetStateRulesCodec.decode(null).isEmpty())
        assertTrue(PetStateRulesCodec.decode("").isEmpty())
        assertTrue(PetStateRulesCodec.decode("   ").isEmpty())
    }
}

class AppCategoryStateMapperTest {

    private fun mapped(category: String, isLauncher: Boolean = false): String? =
        when (val outcome = AppCategoryStateMapper.outcomeFor(category, isLauncher)) {
            is CategoryStateOutcome.Mapped -> outcome.stateId
            CategoryStateOutcome.Hold -> null
        }

    @Test
    fun `开发-办公-游戏-通信-娱乐的分类动作保持不变`() {
        assertEquals(PetStateId.FOCUSED, mapped(AppCategoryId.DEVELOPMENT))
        assertEquals(PetStateId.FOCUSED, mapped(AppCategoryId.PRODUCTIVITY))
        assertEquals(PetStateId.GAMING, mapped(AppCategoryId.GAMING))
        assertEquals(PetStateId.SOCIAL, mapped(AppCategoryId.SOCIAL))
        assertEquals(PetStateId.ENTERTAINED, mapped(AppCategoryId.ENTERTAINMENT))
    }

    @Test
    fun `浏览器映射为 focused 而不是 default（4C-6A：否则打开浏览器毫无反应）`() {
        assertEquals(PetStateId.FOCUSED, mapped(AppCategoryId.BROWSER))
    }

    @Test
    fun `桌面映射为 away（项目既有语义里的 idle）`() {
        assertEquals(PetStateId.AWAY, mapped(AppCategoryId.SYSTEM, isLauncher = true))
        // 桌面判定优先于分类：即使分类给成别的，launcher 仍然按"回到桌面"处理
        assertEquals(PetStateId.AWAY, mapped(AppCategoryId.OTHER, isLauncher = true))
    }

    @Test
    fun `系统界面保持上一个稳定状态而不是硬切 default`() {
        assertNull(mapped(AppCategoryId.SYSTEM))
    }

    @Test
    fun `未归类与未知分类回退 default`() {
        assertEquals(PetStateId.DEFAULT, mapped(AppCategoryId.OTHER))
        assertEquals(PetStateId.DEFAULT, mapped("bogus"))
    }

    @Test
    fun `分类说明覆盖全部 8 类并区分桌面`() {
        for (category in listOf(
            AppCategoryId.DEVELOPMENT,
            AppCategoryId.PRODUCTIVITY,
            AppCategoryId.GAMING,
            AppCategoryId.SOCIAL,
            AppCategoryId.ENTERTAINMENT,
            AppCategoryId.BROWSER,
            AppCategoryId.SYSTEM,
            AppCategoryId.OTHER,
        )) {
            assertTrue(AppCategoryStateMapper.noteForCategory(category).isNotEmpty())
        }
        assertEquals("（桌面 / 空闲）", AppCategoryStateMapper.noteForCategory(AppCategoryId.SYSTEM, true))
    }

    @Test
    fun `所有映射结果都必须是既有状态 ID（不新增状态命名）`() {
        for (category in listOf(
            AppCategoryId.DEVELOPMENT,
            AppCategoryId.PRODUCTIVITY,
            AppCategoryId.GAMING,
            AppCategoryId.SOCIAL,
            AppCategoryId.ENTERTAINMENT,
            AppCategoryId.BROWSER,
            AppCategoryId.SYSTEM,
            AppCategoryId.OTHER,
            "bogus",
        )) {
            for (launcher in listOf(false, true)) {
                val state = mapped(category, launcher)
                if (state != null) assertTrue("未知状态 $state", PetStateId.isKnown(state))
            }
        }
    }
}

class PetStateDebouncerTest {

    private fun debouncer() = PetStateDebouncer()

    @Test
    fun `候选出现一次不立即切换`() {
        val debouncer = debouncer()
        val outcome = debouncer.offer(
            candidateStateId = PetStateId.SOCIAL,
            currentStateId = PetStateId.DEFAULT,
            now = 10_000L,
        )
        assertTrue(outcome is PetDebounceOutcome.Waiting)
        assertEquals(1, debouncer.consecutive)
    }

    @Test
    fun `连续出现达到阈值且稳定足够久后才切换`() {
        val debouncer = debouncer()
        debouncer.offer(PetStateId.SOCIAL, PetStateId.DEFAULT, 10_000L)
        // 第二次但时间还不够 → 继续等待。
        assertTrue(
            debouncer.offer(PetStateId.SOCIAL, PetStateId.DEFAULT, 10_500L)
                is PetDebounceOutcome.Waiting,
        )
        // 第三次且已稳定 1000ms → 生效。
        val accepted = debouncer.offer(PetStateId.SOCIAL, PetStateId.DEFAULT, 11_000L)
        assertTrue(accepted is PetDebounceOutcome.Accepted)
        assertEquals(PetStateId.SOCIAL, (accepted as PetDebounceOutcome.Accepted).stateId)
    }

    @Test
    fun `候选中途变化会重新计数`() {
        val debouncer = debouncer()
        debouncer.offer(PetStateId.SOCIAL, PetStateId.DEFAULT, 10_000L)
        debouncer.offer(PetStateId.SOCIAL, PetStateId.DEFAULT, 11_000L)
        // 换成游戏：计数归 1。
        val changed = debouncer.offer(PetStateId.GAMING, PetStateId.DEFAULT, 11_500L)
        assertTrue(changed is PetDebounceOutcome.Waiting)
        assertEquals(1, debouncer.consecutive)
        assertEquals(PetStateId.GAMING, debouncer.candidate)
    }

    @Test
    fun `当前状态重复出现不重新应用`() {
        val debouncer = debouncer()
        val outcome = debouncer.offer(
            candidateStateId = PetStateId.DEFAULT,
            currentStateId = PetStateId.DEFAULT,
            now = 10_000L,
        )
        assertTrue(outcome is PetDebounceOutcome.Ignored)
        assertNull(debouncer.candidate)
    }

    @Test
    fun `短暂经过桌面被过滤：只出现一次的候选永不生效`() {
        val debouncer = debouncer()
        // 一次桌面（default），随即回到游戏。
        debouncer.offer(PetStateId.DEFAULT, PetStateId.GAMING, 10_000L)
        val back = debouncer.offer(PetStateId.GAMING, PetStateId.GAMING, 11_500L)
        assertTrue(back is PetDebounceOutcome.Ignored)
    }

    @Test
    fun `manual 锁定时自动状态不得顶掉它`() {
        val debouncer = debouncer()
        val outcome = debouncer.offer(
            candidateStateId = PetStateId.GAMING,
            currentStateId = PetStateId.MANUAL,
            now = 10_000L,
            fastPath = true,
        )
        assertTrue(outcome is PetDebounceOutcome.Ignored)
    }

    @Test
    fun `快速路径跳过稳定性门槛，但快速切换抑制仍然生效`() {
        val debouncer = debouncer()
        val first = debouncer.offer(
            PetStateId.SOCIAL, PetStateId.DEFAULT, 10_000L, fastPath = true,
        )
        assertTrue(first is PetDebounceOutcome.Accepted)
        // 立刻再来一次（距上次生效 < 400ms）→ 被抑制。
        val suppressed = debouncer.offer(
            PetStateId.GAMING, PetStateId.SOCIAL, 10_100L, fastPath = true,
        )
        assertTrue(suppressed is PetDebounceOutcome.Waiting)
        // 过了抑制窗口就能生效。
        val later = debouncer.offer(
            PetStateId.GAMING, PetStateId.SOCIAL, 10_500L, fastPath = true,
        )
        assertTrue(later is PetDebounceOutcome.Accepted)
    }

    @Test
    fun `停止服务后候选被清空`() {
        val debouncer = debouncer()
        debouncer.offer(PetStateId.SOCIAL, PetStateId.DEFAULT, 10_000L)
        assertNotNull(debouncer.candidate)
        debouncer.reset()
        assertNull(debouncer.candidate)
        assertEquals(0, debouncer.consecutive)
    }
}

/**
 * 前台事件类型的字面量。
 *
 * `UsageEvents.Event.MOVE_TO_FOREGROUND`（API 1 起，API 29 起被取代）与
 * `UsageEvents.Event.ACTIVITY_RESUMED`（API 29 起）**数值都是 1** ——
 * 这里刻意写成两个常量，让"两个都要认"这件事在测试里看得见。
 */
private const val MOVE_TO_FOREGROUND = 1
private const val ACTIVITY_RESUMED = 1

/** 其它事件类型（`MOVE_TO_BACKGROUND`），用于验证"不会把后台事件当前台"。 */
private const val MOVE_TO_BACKGROUND = 2

/** 脚本式前台应用来源（不触碰任何 Android API）。 */
private class FakeForegroundAppSource(
    var reading: ForegroundAppReading,
) : ForegroundAppSource {
    var calls = 0
        private set

    override fun read(now: Long): ForegroundAppReading {
        calls += 1
        return reading
    }
}

/** 构造一份"读到某个外部应用"的结果。 */
private fun detectedReading(
    packageName: String,
    label: String? = null,
    now: Long = 1_000L,
    source: ForegroundDetectionSource = ForegroundDetectionSource.activityEvents,
    eventType: Int? = MOVE_TO_FOREGROUND,
) = ForegroundAppReading(
    snapshot = ForegroundAppSnapshot(packageName, label, now),
    source = source,
    usageAccessAvailable = true,
    reason = null,
    diagnostics = ForegroundDiagnostics(
        usageAccessGranted = true,
        appOpsAllowed = true,
        queryStart = now - ForegroundWindow.QUERY_WINDOW_MS,
        queryEnd = now,
        eventCount = 1,
        resumedEventCount = 1,
        usableEventCount = 1,
        statsCount = 0,
        lastRawPackage = packageName,
        lastExternalPackage = packageName,
        lastExternalEventType = eventType,
        lastExternalEventTime = now,
        detectionSource = source.wire,
        detectionFailureReason = null,
    ),
)

/** 构造一份"有权限但这一轮拿不到有效外部应用"的结果。 */
private fun emptyReading(now: Long, reason: String) = ForegroundAppReading(
    snapshot = null,
    source = ForegroundDetectionSource.unavailable,
    usageAccessAvailable = true,
    reason = reason,
    diagnostics = ForegroundDiagnostics(
        usageAccessGranted = true,
        appOpsAllowed = true,
        queryStart = now - ForegroundWindow.QUERY_WINDOW_MS,
        queryEnd = now,
        eventCount = 0,
        resumedEventCount = 0,
        usableEventCount = 0,
        statsCount = 0,
        lastRawPackage = null,
        lastExternalPackage = null,
        lastExternalEventType = null,
        lastExternalEventTime = 0L,
        detectionSource = ForegroundDetectionSource.unavailable.wire,
        detectionFailureReason = reason,
    ),
)

class PetStateMonitorTest {

    private fun monitor(
        source: FakeForegroundAppSource,
        isLauncher: (String) -> Boolean = { false },
    ) = PetStateMonitor(foregroundSource = source, isLauncher = isLauncher)

    @Test
    fun `未授权时回退默认状态并给出明确原因码`() {
        val monitor = monitor(
            FakeForegroundAppSource(unavailableReading(1_000L, PetStateError.USAGE_ACCESS_MISSING)),
        )
        val decision = monitor.tick(
            now = 10_000L,
            currentStateId = PetStateId.FOCUSED,
            manualOverride = null,
        )
        assertNotNull(decision)
        assertEquals(PetStateId.DEFAULT, decision!!.stateId)
        assertEquals(PetStateSource.unsupported, decision.source)
        assertEquals(PetStateError.USAGE_ACCESS_MISSING, monitor.lastErrorCode)
    }

    @Test
    fun `有权限但读不到有效外部应用时不干预（保持当前状态）`() {
        val monitor = monitor(
            FakeForegroundAppSource(emptyReading(1_000L, "last-event-is-self")),
        )
        val decision = monitor.tick(
            now = 10_000L,
            currentStateId = PetStateId.GAMING,
            manualOverride = null,
        )
        assertNull(decision)
        assertEquals(PetStateError.FOREGROUND_APP_UNAVAILABLE, monitor.lastErrorCode)
        assertEquals("last-event-is-self", monitor.lastDetectionReason)
    }

    @Test
    fun `读到前台应用时按分类判定，且要等防抖`() {
        val source = FakeForegroundAppSource(
            detectedReading("org.telegram.messenger", "Telegram"),
        )
        val monitor = monitor(source)
        // 第一次：候选，未生效。
        assertNull(monitor.tick(10_000L, PetStateId.DEFAULT, null))
        assertEquals(PetStateId.SOCIAL, monitor.candidateState)
        assertEquals(AppCategoryId.SOCIAL, monitor.lastCategory)
        // 第二次且稳定足够久：生效。
        val decision = monitor.tick(11_100L, PetStateId.DEFAULT, null)
        assertNotNull(decision)
        assertEquals(PetStateId.SOCIAL, decision!!.stateId)
        assertEquals(PetStateSource.foregroundApp, decision.source)
        assertEquals("org.telegram.messenger", decision.foregroundPackage)
        assertEquals("Telegram", monitor.lastForegroundLabel)
    }

    @Test
    fun `首次检测走快速路径立即生效（显示桌宠、解锁后恢复）`() {
        val monitor = monitor(FakeForegroundAppSource(detectedReading("com.miHoYo.GenshinImpact")))
        val decision = monitor.tick(10_000L, PetStateId.DEFAULT, null, fastPath = true)
        assertNotNull(decision)
        assertEquals(PetStateId.GAMING, decision!!.stateId)
    }

    @Test
    fun `检测来源与诊断被如实暴露给上层`() {
        val monitor = monitor(
            FakeForegroundAppSource(
                detectedReading(
                    "org.telegram.messenger",
                    source = ForegroundDetectionSource.usageStatsFallback,
                    eventType = null,
                ),
            ),
        )
        monitor.tick(10_000L, PetStateId.DEFAULT, null, fastPath = true)
        assertEquals("usage-stats-fallback", monitor.lastDetectionSource)
        assertEquals("usage-stats-fallback", monitor.lastDiagnostics?.detectionSource)
        assertEquals(1, monitor.lastDiagnostics?.resumedEventCount)
    }

    @Test
    fun `拿不到候选时不清空已识别的外部应用（分屏、返回设置页都不清空）`() {
        val source = FakeForegroundAppSource(
            detectedReading("org.telegram.messenger", "Telegram"),
        )
        val monitor = monitor(source)
        monitor.tick(10_000L, PetStateId.DEFAULT, null, fastPath = true)
        assertEquals("org.telegram.messenger", monitor.lastForegroundPackage)

        // 分屏里 PetLife 自己在前台 / 最后一条事件是 SystemUI → 本轮没有外部候选。
        source.reading = emptyReading(11_000L, "last-event-is-self")
        val decision = monitor.tick(11_000L, PetStateId.SOCIAL, null, fastPath = true)

        assertNull(decision)
        assertEquals(
            "不允许把当前应用从 Telegram 直接变成「-」（真机缺陷 C）",
            "org.telegram.messenger",
            monitor.lastForegroundPackage,
        )
        assertEquals("Telegram", monitor.lastForegroundLabel)
    }

    @Test
    fun `未知应用归入默认状态`() {
        val monitor = monitor(FakeForegroundAppSource(detectedReading("com.example.unknown")))
        val decision = monitor.tick(10_000L, PetStateId.SOCIAL, null, fastPath = true)
        assertNotNull(decision)
        assertEquals(PetStateId.DEFAULT, decision!!.stateId)
        assertEquals(AppCategoryId.OTHER, monitor.lastCategory)
    }

    @Test
    fun `手动覆盖立即生效且不等防抖`() {
        val monitor = monitor(FakeForegroundAppSource(detectedReading("com.android.chrome")))
        val decision = monitor.tick(
            now = 10_000L,
            currentStateId = PetStateId.DEFAULT,
            manualOverride = PetStateId.CONCERNED,
        )
        assertNotNull(decision)
        assertEquals(PetStateId.CONCERNED, decision!!.stateId)
        assertEquals(PetStateSource.manualDebug, decision.source)
    }

    @Test
    fun `清除手动覆盖后按快速路径立即恢复检测`() {
        val monitor = monitor(FakeForegroundAppSource(detectedReading("org.telegram.messenger")))
        monitor.tick(10_000L, PetStateId.DEFAULT, PetStateId.CONCERNED)
        val restored = monitor.tick(10_100L, PetStateId.CONCERNED, null, fastPath = true)
        assertNotNull(restored)
        assertEquals(PetStateId.SOCIAL, restored!!.stateId)
        assertEquals(PetStateSource.foregroundApp, restored.source)
    }

    @Test
    fun `非法的手动覆盖 ID 被忽略，走正常自动判定`() {
        val monitor = monitor(FakeForegroundAppSource(detectedReading("org.telegram.messenger")))
        val decision = monitor.tick(10_000L, PetStateId.DEFAULT, "not-a-state", fastPath = true)
        assertNotNull(decision)
        assertEquals(PetStateId.SOCIAL, decision!!.stateId)
    }

    @Test
    fun `相同状态不重复上报（避免重复解码同一素材）`() {
        val monitor = monitor(FakeForegroundAppSource(detectedReading("org.telegram.messenger")))
        assertNull(monitor.tick(10_000L, PetStateId.SOCIAL, null))
    }

    @Test
    fun `reset 清空候选与错误码`() {
        val monitor = monitor(FakeForegroundAppSource(detectedReading("org.telegram.messenger")))
        monitor.tick(10_000L, PetStateId.DEFAULT, null)
        assertNotNull(monitor.candidateState)
        monitor.reset()
        assertNull(monitor.candidateState)
        assertEquals(0, monitor.candidateCount)
    }

    // --- Phase 4C-6A：让"日常应用"真的能触发切换 ---

    @Test
    fun `浏览器从 default 切到 focused（4C-6A 核心修复）`() {
        val monitor = monitor(FakeForegroundAppSource(detectedReading("com.android.chrome", "Chrome")))
        assertNull(monitor.tick(10_000L, PetStateId.DEFAULT, null))
        val decision = monitor.tick(11_100L, PetStateId.DEFAULT, null)
        assertNotNull(decision)
        assertEquals(PetStateId.FOCUSED, decision!!.stateId)
        assertEquals("built-in", monitor.lastMatchedRule)
    }

    @Test
    fun `回到桌面切到 away（idle 的既有表达）`() {
        val monitor = monitor(
            FakeForegroundAppSource(detectedReading("com.android.launcher3", "桌面")),
            isLauncher = { it == "com.android.launcher3" },
        )
        assertNull(monitor.tick(10_000L, PetStateId.FOCUSED, null))
        val decision = monitor.tick(11_100L, PetStateId.FOCUSED, null)
        assertNotNull(decision)
        assertEquals(PetStateId.AWAY, decision!!.stateId)
        assertEquals("launcher", monitor.lastMatchedRule)
    }

    @Test
    fun `系统设置页保持上一个稳定状态（不切图、也不乱跳）`() {
        val monitor = monitor(FakeForegroundAppSource(detectedReading("com.android.settings", "设置")))
        // 连续多轮都必须是 null（保持当前状态），而不是切到 default
        repeat(5) {
            assertNull(monitor.tick(10_000L + it * 2_000L, PetStateId.SOCIAL, null))
        }
        assertEquals("hold", monitor.lastMatchedRule)
        assertEquals(AppCategoryId.SYSTEM, monitor.lastCategory)
        assertNull(monitor.candidateState)
    }

    @Test
    fun `系统页之后回到原应用不会重复切图`() {
        val source = FakeForegroundAppSource(detectedReading("org.telegram.messenger", "Telegram"))
        val monitor = monitor(source)
        // Telegram 已是当前稳定状态 → 同状态不上报
        assertNull(monitor.tick(10_000L, PetStateId.SOCIAL, null))
        // 切到系统设置页：保持
        source.reading = detectedReading("com.android.settings", "设置", now = 12_000L)
        assertNull(monitor.tick(12_000L, PetStateId.SOCIAL, null))
        // 回到 Telegram：仍是同一状态 → 依旧不上报
        source.reading = detectedReading("org.telegram.messenger", "Telegram", now = 14_000L)
        assertNull(monitor.tick(14_000L, PetStateId.SOCIAL, null))
    }

    @Test
    fun `同一分类的两个不同应用不会重复切素材`() {
        val source = FakeForegroundAppSource(detectedReading("org.telegram.messenger", "Telegram"))
        val monitor = monitor(source)
        assertNull(monitor.tick(10_000L, PetStateId.DEFAULT, null))
        assertEquals(PetStateId.SOCIAL, monitor.tick(11_100L, PetStateId.DEFAULT, null)?.stateId)

        // 换到另一个同为 social 的应用（微信）：目标状态相同 → 不上报
        source.reading = detectedReading("com.tencent.mm", "微信", now = 20_000L)
        assertNull(monitor.tick(20_000L, PetStateId.SOCIAL, null))
        assertNull(monitor.tick(21_500L, PetStateId.SOCIAL, null))
    }

    @Test
    fun `A 到 B 到 A 的快速来回不会提交中间状态`() {
        val source = FakeForegroundAppSource(detectedReading("org.telegram.messenger", "Telegram"))
        val monitor = monitor(source)
        // 当前是 social；切到 Chrome（候选 focused）但只停 0.5 秒
        source.reading = detectedReading("com.android.chrome", "Chrome", now = 10_000L)
        assertNull(monitor.tick(10_000L, PetStateId.SOCIAL, null))
        assertEquals(PetStateId.FOCUSED, monitor.candidateState)
        // 立刻切回 Telegram → 候选被取消
        source.reading = detectedReading("org.telegram.messenger", "Telegram", now = 10_500L)
        assertNull(monitor.tick(10_500L, PetStateId.SOCIAL, null))
        assertNull(monitor.candidateState)
    }

    @Test
    fun `桌面判定函数抛异常时安全降级为普通分类`() {
        val monitor = monitor(
            FakeForegroundAppSource(detectedReading("com.android.launcher3", "桌面")),
            isLauncher = { throw IllegalStateException("boom") },
        )
        assertNull(monitor.tick(10_000L, PetStateId.FOCUSED, null))
        val decision = monitor.tick(11_100L, PetStateId.FOCUSED, null)
        // system 分类 + 桌面判定失败 → 按"保持上一个状态"处理，绝不崩
        assertNull(decision)
        assertEquals("hold", monitor.lastMatchedRule)
    }

    // --- Phase 4C-6A：自动开关与规则优先级 ---

    private val allAutoOff = PetStateRules(automaticEnabled = false)

    @Test
    fun `关闭自动状态后不提交任何自动切换`() {
        val monitor = monitor(FakeForegroundAppSource(detectedReading("org.telegram.messenger")))
        repeat(3) {
            assertNull(
                monitor.tick(10_000L + it * 2_000L, PetStateId.DEFAULT, null, rules = allAutoOff),
            )
        }
        assertEquals("disabled", monitor.lastMatchedRule)
        assertNull(monitor.candidateState)
    }

    @Test
    fun `关闭自动状态时手动覆盖仍然生效`() {
        val monitor = monitor(FakeForegroundAppSource(detectedReading("org.telegram.messenger")))
        val decision = monitor.tick(
            now = 10_000L,
            currentStateId = PetStateId.DEFAULT,
            manualOverride = PetStateId.HAPPY,
            rules = allAutoOff,
        )
        assertEquals(PetStateId.HAPPY, decision?.stateId)
        assertEquals("manual", monitor.lastMatchedRule)
    }

    @Test
    fun `具体应用规则优先于分类规则`() {
        val rules = PetStateRules(
            categoryRules = mapOf(AppCategoryId.SOCIAL to PetStateId.HAPPY),
            appOverrides = mapOf("org.telegram.messenger" to PetStateId.CONCERNED),
        )
        val monitor = monitor(FakeForegroundAppSource(detectedReading("org.telegram.messenger")))
        assertNull(monitor.tick(10_000L, PetStateId.DEFAULT, null, rules = rules))
        val decision = monitor.tick(11_100L, PetStateId.DEFAULT, null, rules = rules)
        assertEquals(PetStateId.CONCERNED, decision?.stateId)
        assertEquals("user-app", monitor.lastMatchedRule)
    }

    @Test
    fun `用户分类规则优先于内置分类规则`() {
        val rules = PetStateRules(categoryRules = mapOf(AppCategoryId.BROWSER to PetStateId.TIRED))
        val monitor = monitor(FakeForegroundAppSource(detectedReading("com.android.chrome")))
        assertNull(monitor.tick(10_000L, PetStateId.DEFAULT, null, rules = rules))
        val decision = monitor.tick(11_100L, PetStateId.DEFAULT, null, rules = rules)
        assertEquals(PetStateId.TIRED, decision?.stateId)
        assertEquals("user-category", monitor.lastMatchedRule)
    }

    @Test
    fun `分类规则里没有该分类时退回内置表`() {
        val rules = PetStateRules(categoryRules = mapOf(AppCategoryId.GAMING to PetStateId.HAPPY))
        val monitor = monitor(FakeForegroundAppSource(detectedReading("com.android.chrome")))
        assertNull(monitor.tick(10_000L, PetStateId.DEFAULT, null, rules = rules))
        val decision = monitor.tick(11_100L, PetStateId.DEFAULT, null, rules = rules)
        assertEquals(PetStateId.FOCUSED, decision?.stateId)
        assertEquals("built-in", monitor.lastMatchedRule)
    }

    // --- Phase 4C-6A 真机诊断：状态提交链路的可判定性 ---

    @Test
    fun `桌面包名经注入的 isLauncher 判定后切到 away`() {
        val monitor = monitor(
            FakeForegroundAppSource(detectedReading("com.miui.home", "系统桌面")),
            isLauncher = { it == "com.miui.home" },
        )
        val decision = monitor.tick(10_000L, PetStateId.FOCUSED, null, fastPath = true)
        assertNotNull(decision)
        assertEquals(PetStateId.AWAY, decision!!.stateId)
        assertEquals("launcher", monitor.lastMatchedRule)
        assertEquals(PetStateId.AWAY, monitor.lastResolvedTargetState)
    }

    @Test
    fun `连续相同目标不会重置候选起点（每轮 reading 都是新对象）`() {
        val source = FakeForegroundAppSource(detectedReading("com.android.chrome", "Chrome"))
        val monitor = monitor(source)
        // 第 1 轮：候选起步。墙钟起点 = 1000ms - 0 = 1000。
        assertNull(monitor.tick(10_000L, PetStateId.DEFAULT, null, wallNow = 1_700_000_001_000L))
        val since = monitor.candidateSinceWall
        assertEquals(1_700_000_001_000L, since)
        // 第 2 轮：即便 reading 是另一个对象、时间前进 600ms，候选起点也必须不动。
        source.reading = detectedReading("com.android.chrome", "Chrome")
        assertNull(monitor.tick(10_600L, PetStateId.DEFAULT, null, wallNow = 1_700_000_001_600L))
        assertEquals("候选起点不得被重置", since, monitor.candidateSinceWall)
        assertEquals(600L, monitor.candidateElapsedMs)
        assertEquals(2, monitor.candidateCount)
    }

    @Test
    fun `候选稳定超过阈值后 stableState 才改变，并给出提交诊断`() {
        val monitor = monitor(FakeForegroundAppSource(detectedReading("com.android.chrome", "Chrome")))
        var stable = PetStateId.DEFAULT

        assertNull(monitor.tick(10_000L, stable, null, wallNow = 1_700_000_001_000L))
        assertEquals("candidate", monitor.lastTransitionResult)
        assertEquals(PetStateId.FOCUSED, monitor.lastResolvedTargetState)
        assertEquals("stableState 不得提前变化", PetStateId.DEFAULT, stable)

        val decision = monitor.tick(11_100L, stable, null, wallNow = 1_700_000_002_100L)
        assertNotNull(decision)
        stable = decision!!.stateId
        assertEquals(PetStateId.FOCUSED, stable)
        assertEquals("committed", monitor.lastTransitionResult)
        assertEquals(1_700_000_002_100L, monitor.lastCommittedAt)
        assertTrue(
            "提交说明应包含实际稳定时长：${monitor.lastTransitionReason}",
            monitor.lastTransitionReason!!.contains("1100ms"),
        )
    }

    @Test
    fun `快照规则下发后立即生效（不必等下一次推送）`() {
        val rules = PetStateRules(
            automaticEnabled = true,
            categoryRules = mapOf(AppCategoryId.BROWSER to PetStateId.ENTERTAINED),
        )
        val monitor = monitor(FakeForegroundAppSource(detectedReading("com.android.chrome")))
        val decision = monitor.tick(10_000L, PetStateId.DEFAULT, null, fastPath = true, rules = rules)
        assertEquals(PetStateId.ENTERTAINED, decision?.stateId)
        assertEquals("user-category", monitor.lastMatchedRule)
    }

    @Test
    fun `自动联动关闭时诊断如实报告 disabled`() {
        val monitor = monitor(FakeForegroundAppSource(detectedReading("com.android.chrome")))
        assertNull(
            monitor.tick(
                10_000L,
                PetStateId.DEFAULT,
                null,
                fastPath = true,
                rules = PetStateRules(automaticEnabled = false),
            ),
        )
        assertEquals("disabled", monitor.lastTransitionResult)
        assertEquals("disabled", monitor.lastMatchedRule)
        assertNull(monitor.lastResolvedTargetState)
    }

    @Test
    fun `系统界面保持时诊断说明为保持而不是装作没解析`() {
        val monitor = monitor(FakeForegroundAppSource(detectedReading("com.android.settings")))
        assertNull(monitor.tick(10_000L, PetStateId.FOCUSED, null, fastPath = true))
        assertEquals("hold", monitor.lastTransitionResult)
        assertEquals("hold", monitor.lastMatchedRule)
        assertEquals(PetStateId.FOCUSED, monitor.lastResolvedTargetState)
    }

    @Test
    fun `检测侧算好的分类被直接采用（不会两处各算一遍）`() {
        val reading = detectedReading("com.example.unknown").let { base ->
            base.copy(
                snapshot = base.snapshot!!.copy(
                    category = AppCategoryId.BROWSER,
                    categorySource = AppCategorySource.platformCategory.wire,
                ),
            )
        }
        val monitor = monitor(FakeForegroundAppSource(reading))
        val decision = monitor.tick(10_000L, PetStateId.DEFAULT, null, fastPath = true)
        assertEquals(PetStateId.FOCUSED, decision?.stateId)
        assertEquals(AppCategoryId.BROWSER, monitor.lastCategory)
        assertEquals(AppCategorySource.platformCategory.wire, monitor.lastCategorySource)
    }

    @Test
    fun `检测侧没给分类时用注入的系统声明分类兜底`() {
        val monitor = PetStateMonitor(
            foregroundSource = FakeForegroundAppSource(
                detectedReading("com.studio.unknown.arcade", "某游戏"),
            ),
            platformCategoryOf = { AndroidAppInfoCategory.GAME },
        )
        val decision = monitor.tick(10_000L, PetStateId.DEFAULT, null, fastPath = true)
        assertEquals(PetStateId.GAMING, decision?.stateId)
        assertEquals(AppCategorySource.platformCategory.wire, monitor.lastCategorySource)
    }

    @Test
    fun `未授权时状态链路诊断给出 unavailable`() {
        val monitor = monitor(
            FakeForegroundAppSource(unavailableReading(1_000L, PetStateError.USAGE_ACCESS_MISSING)),
        )
        monitor.tick(10_000L, PetStateId.DEFAULT, null)
        assertEquals("unavailable", monitor.lastTransitionResult)
        assertNull(monitor.lastResolvedTargetState)
    }
}

/** Phase 4C-6A：快照新增字段的解析与持久化语义。 */
class NativePetStateMappingRulesTest {

    private fun raw(
        revision: Long = 1,
        automatic: Any? = null,
        categoryRules: Any? = null,
        appOverrides: Any? = null,
    ): Map<String, Any?> = buildMap {
        put("revision", revision)
        put("characterId", "char-1")
        put("defaultAsset", null)
        put("states", emptyMap<String, Any?>())
        automatic?.let { put("automaticEnabled", it) }
        categoryRules?.let { put("categoryRules", it) }
        appOverrides?.let { put("appOverrides", it) }
    }

    @Test
    fun `三个新字段都可选，缺失时用默认值（老快照照样能解析）`() {
        val result = NativePetStateMappingParser.parse(raw(), null)
        val mapping = result.mapping
        assertNotNull(mapping)
        assertTrue(mapping!!.automaticEnabled)
        assertTrue(mapping.categoryRules.isEmpty())
        assertTrue(mapping.appOverrides.isEmpty())
    }

    @Test
    fun `解析自动开关与两张规则表`() {
        val result = NativePetStateMappingParser.parse(
            raw(
                automatic = false,
                categoryRules = mapOf(AppCategoryId.BROWSER to PetStateId.TIRED),
                appOverrides = mapOf("org.telegram.messenger" to PetStateId.HAPPY),
            ),
            null,
        )
        val mapping = result.mapping!!
        assertFalse(mapping.automaticEnabled)
        assertEquals(PetStateId.TIRED, mapping.categoryRules[AppCategoryId.BROWSER])
        assertEquals(PetStateId.HAPPY, mapping.appOverrides["org.telegram.messenger"])
    }

    @Test
    fun `规则表里的非法条目被逐条丢弃（未知状态、未知分类、空值）`() {
        val result = NativePetStateMappingParser.parse(
            raw(
                categoryRules = mapOf(
                    AppCategoryId.BROWSER to "not-a-state",
                    "not-a-category" to PetStateId.HAPPY,
                    AppCategoryId.SOCIAL to PetStateId.SOCIAL,
                ),
                appOverrides = mapOf(
                    "com.example.app" to PetStateId.FOCUSED,
                    "" to PetStateId.HAPPY,
                    "com.example.bad" to "",
                ),
            ),
            null,
        )
        val mapping = result.mapping!!
        assertEquals(1, mapping.categoryRules.size)
        assertEquals(PetStateId.SOCIAL, mapping.categoryRules[AppCategoryId.SOCIAL])
        assertEquals(1, mapping.appOverrides.size)
        assertEquals(PetStateId.FOCUSED, mapping.appOverrides["com.example.app"])
    }

    @Test
    fun `字段缺失时沿用上一次的规则，不会被老 Flutter 清空`() {
        val previous = NativePetStateMappingParser
            .parse(raw(automatic = false, appOverrides = mapOf("a.b" to PetStateId.HAPPY)), null)
            .mapping!!
        val merged = NativePetStateMappingParser.parse(raw(revision = 2), previous).mapping!!
        assertFalse(merged.automaticEnabled)
        assertEquals(PetStateId.HAPPY, merged.appOverrides["a.b"])
    }

    @Test
    fun `旧 revision 被拒绝，不能覆盖新配置`() {
        val previous = NativePetStateMappingParser.parse(raw(revision = 9), null).mapping!!
        val result = NativePetStateMappingParser.parse(raw(revision = 3, automatic = false), previous)
        assertEquals(PetStateError.MAPPING_REVISION_STALE, result.code)
        assertEquals(9L, result.mapping?.revision)
        assertTrue("旧快照不得改写已有配置", result.mapping!!.automaticEnabled)
    }
}

/** 脚本式查询能力：把"系统给什么"完全固定下来，从而只验证筛选与兜底逻辑。 */
private class FakeForegroundQuery(
    var granted: Boolean = true,
    var appOps: Boolean = true,
    var events: List<ForegroundEventRecord> = emptyList(),
    var stats: List<ForegroundCandidate> = emptyList(),
) : ForegroundAppQuery {

    var eventQueries = 0
        private set
    var statQueries = 0
        private set

    override fun usageAccessAvailable(): Boolean = granted

    override fun appOpsAllowed(): Boolean = appOps

    override fun queryEvents(begin: Long, end: Long): List<ForegroundEventRecord> {
        eventQueries += 1
        return events
    }

    override fun queryUsageStats(begin: Long, end: Long): List<ForegroundCandidate> {
        statQueries += 1
        return stats
    }
}

private const val SELF_PACKAGE = "asia.akechi.petlife"

private fun resumed(pkg: String, at: Long, type: Int = MOVE_TO_FOREGROUND) =
    ForegroundEventRecord(pkg, type, at)

private fun background(pkg: String, at: Long) =
    ForegroundEventRecord(pkg, MOVE_TO_BACKGROUND, at)

private fun stat(pkg: String, at: Long) = ForegroundCandidate(pkg, at, null, null)

/**
 * 真机 4C-5 复验缺陷 C：前台应用识别。
 *
 * 15 条用例逐条对应修复要求 §七 —— 全部是**纯逻辑**，不需要设备。
 */
class ForegroundAppResolverTest {

    private fun resolver(query: FakeForegroundQuery) =
        ForegroundAppResolver(query = query, selfPackage = SELF_PACKAGE)

    @Test
    fun `1-两种前台事件常量都算前台事件`() {
        assertTrue(ForegroundCandidateSelector.isForegroundEventType(ACTIVITY_RESUMED))
        assertTrue(ForegroundCandidateSelector.isForegroundEventType(MOVE_TO_FOREGROUND))
        assertFalse(ForegroundCandidateSelector.isForegroundEventType(MOVE_TO_BACKGROUND))
    }

    @Test
    fun `2-只有 ACTIVITY_RESUMED 事件时也能识别`() {
        val query = FakeForegroundQuery(
            events = listOf(resumed("org.telegram.messenger", 900L, ACTIVITY_RESUMED)),
        )
        val reading = resolver(query).read(1_000L)
        assertEquals("org.telegram.messenger", reading.snapshot?.packageName)
        assertEquals(ForegroundDetectionSource.activityEvents, reading.source)
    }

    @Test
    fun `3-只有 MOVE_TO_FOREGROUND 事件时也能识别`() {
        val query = FakeForegroundQuery(
            events = listOf(resumed("org.telegram.messenger", 900L, MOVE_TO_FOREGROUND)),
        )
        val reading = resolver(query).read(1_000L)
        assertEquals("org.telegram.messenger", reading.snapshot?.packageName)
    }

    @Test
    fun `4-两种事件混合时按时间戳取最新的一条`() {
        val query = FakeForegroundQuery(
            events = listOf(
                resumed("com.android.chrome", 500L, MOVE_TO_FOREGROUND),
                resumed("org.telegram.messenger", 950L, ACTIVITY_RESUMED),
                resumed("com.miHoYo.GenshinImpact", 700L, ACTIVITY_RESUMED),
            ),
        )
        val reading = resolver(query).read(1_000L)
        assertEquals("org.telegram.messenger", reading.snapshot?.packageName)
        assertNotNull(reading.diagnostics.lastExternalEventType)
        assertEquals(ACTIVITY_RESUMED, reading.diagnostics.lastExternalEventType!!)
    }

    @Test
    fun `5-最后一条是 PetLife 时继续向前找外部应用`() {
        val query = FakeForegroundQuery(
            events = listOf(
                resumed("org.telegram.messenger", 500L),
                resumed(SELF_PACKAGE, 990L),
            ),
        )
        val reading = resolver(query).read(1_000L)
        assertEquals(
            "不能因为最后一条是 PetLife 就把结果清空（真机缺陷 C 的根因）",
            "org.telegram.messenger",
            reading.snapshot?.packageName,
        )
        assertEquals(SELF_PACKAGE, reading.diagnostics.lastRawPackage)
    }

    @Test
    fun `6-分屏中 PetLife 与 Telegram 同时 RESUMED 时返回 Telegram`() {
        val query = FakeForegroundQuery(
            events = listOf(
                resumed(SELF_PACKAGE, 700L),
                resumed("org.telegram.messenger", 800L),
                resumed(SELF_PACKAGE, 900L),
            ),
        )
        val reading = resolver(query).read(1_000L)
        assertEquals("org.telegram.messenger", reading.snapshot?.packageName)
    }

    @Test
    fun `7-System UI 是最后事件时继续向前查找`() {
        val query = FakeForegroundQuery(
            events = listOf(
                resumed("org.telegram.messenger", 500L),
                resumed("com.android.systemui", 990L),
            ),
        )
        val reading = resolver(query).read(1_000L)
        assertEquals("org.telegram.messenger", reading.snapshot?.packageName)
    }

    @Test
    fun `8-输入法是最后事件时继续向前查找`() {
        val query = FakeForegroundQuery(
            events = listOf(
                resumed("org.telegram.messenger", 500L),
                resumed("com.google.android.inputmethod.latin", 990L),
            ),
        )
        val reading = resolver(query).read(1_000L)
        assertEquals("org.telegram.messenger", reading.snapshot?.packageName)
        assertTrue(ForegroundCandidateSelector.isNoise("com.baidu.input"))
        assertTrue(ForegroundCandidateSelector.isNoise("com.sogou.inputmethod.pinyin"))
    }

    @Test
    fun `9-查询窗口内无新事件时使用最近有效缓存`() {
        val query = FakeForegroundQuery(events = listOf(resumed("org.telegram.messenger", 1_000L)))
        val target = resolver(query)
        assertEquals("org.telegram.messenger", target.read(1_000L).snapshot?.packageName)

        // 之后的窗口里什么也没有（统计兜底也空）：应沿用缓存。
        query.events = emptyList()
        query.stats = emptyList()
        val reading = target.read(2_000L)
        assertEquals("org.telegram.messenger", reading.snapshot?.packageName)
        assertEquals(ForegroundDetectionSource.cache, reading.source)
        assertTrue(reading.usageAccessAvailable)
    }

    @Test
    fun `10-缓存过期后回退 default（不再返回快照）`() {
        val query = FakeForegroundQuery(events = listOf(resumed("org.telegram.messenger", 1_000L)))
        val target = resolver(query)
        target.read(1_000L)

        query.events = emptyList()
        query.stats = emptyList()
        val reading = target.read(1_000L + ForegroundWindow.CACHE_TTL_MS + 1L)

        assertNull(reading.snapshot)
        assertEquals(ForegroundDetectionSource.unavailable, reading.source)
        assertEquals("cache-expired", reading.reason)
        assertTrue("权限本身没问题", reading.usageAccessAvailable)
    }

    @Test
    fun `11-queryEvents 为空时使用 queryUsageStats 兜底并如实标注来源`() {
        val query = FakeForegroundQuery(
            events = emptyList(),
            stats = listOf(
                stat("com.android.systemui", 1_900L),
                stat("org.telegram.messenger", 1_800L),
                stat(SELF_PACKAGE, 1_950L),
            ),
        )
        val reading = resolver(query).read(2_000L)
        assertEquals("org.telegram.messenger", reading.snapshot?.packageName)
        assertEquals(ForegroundDetectionSource.usageStatsFallback, reading.source)
        assertNull(
            "兜底结果不得伪装成精确 Activity 事件",
            reading.diagnostics.lastExternalEventType,
        )
        assertEquals(3, reading.diagnostics.statsCount)
    }

    @Test
    fun `12-未授权时不查询并返回明确原因`() {
        val query = FakeForegroundQuery(granted = false, appOps = false)
        val reading = resolver(query).read(1_000L)

        assertNull(reading.snapshot)
        assertFalse(reading.usageAccessAvailable)
        assertEquals(PetStateError.USAGE_ACCESS_MISSING, reading.reason)
        assertEquals(0, query.eventQueries)
        assertEquals("不得做无意义查询", 0, query.statQueries)
    }

    @Test
    fun `13-包名为空的事件被安全跳过`() {
        val query = FakeForegroundQuery(
            events = listOf(
                resumed("", 990L),
                resumed("   ", 995L),
                resumed("org.telegram.messenger", 900L),
            ),
        )
        val reading = resolver(query).read(1_000L)
        assertEquals("org.telegram.messenger", reading.snapshot?.packageName)
        assertEquals(1, reading.diagnostics.usableEventCount)
    }

    @Test
    fun `14-不同时间戳的事件排序正确（乱序事件流也能取到最新）`() {
        val query = FakeForegroundQuery(
            events = listOf(
                resumed("a.app", 900L),
                resumed("b.app", 300L),
                resumed("c.app", 700L),
            ),
        )
        val reading = resolver(query).read(1_000L)
        assertEquals("a.app", reading.snapshot?.packageName)
        assertEquals(900L, reading.diagnostics.lastExternalEventTime)
    }

    @Test
    fun `15-分屏下不因 PetLife 活跃而清空外部应用（缓存保留）`() {
        val query = FakeForegroundQuery(events = listOf(resumed("org.telegram.messenger", 1_000L)))
        val target = resolver(query)
        assertEquals("org.telegram.messenger", target.read(1_000L).snapshot?.packageName)

        // 用户回到 PetLife 设置页：窗口内只剩 PetLife 自己（分屏下 Telegram 仍是 RESUMED，
        // 但这里用最坏情况验证 —— 只剩自己也不能把结果清空）。
        query.events = listOf(resumed(SELF_PACKAGE, 2_000L))
        query.stats = emptyList()
        val reading = target.read(2_000L)

        assertEquals("org.telegram.messenger", reading.snapshot?.packageName)
        assertEquals(ForegroundDetectionSource.cache, reading.source)
        assertEquals("last-event-is-self", reading.reason)
    }

    @Test
    fun `诊断字段完整：事件计数、最后原始包名、窗口与来源`() {
        val query = FakeForegroundQuery(
            events = listOf(
                background("com.example.bg", 100L),
                resumed("org.telegram.messenger", 200L),
                resumed(SELF_PACKAGE, 300L),
            ),
        )
        val reading = resolver(query).read(1_000L)
        val d = reading.diagnostics
        assertEquals(3, d.eventCount)
        assertEquals(2, d.resumedEventCount)
        assertEquals(1, d.usableEventCount)
        assertEquals(SELF_PACKAGE, d.lastRawPackage)
        assertEquals("org.telegram.messenger", d.lastExternalPackage)
        assertEquals("activity-events", d.detectionSource)
        assertNull(d.detectionFailureReason)
        assertTrue(d.usageAccessGranted)
        assertTrue(d.appOpsAllowed)
        assertEquals(1_000L, d.queryEnd)
        assertEquals(
            "查询窗口必须是扩大的窗口，而不是最近 1~2 秒",
            1_000L - ForegroundWindow.QUERY_WINDOW_MS,
            d.queryStart,
        )
        assertTrue(ForegroundWindow.QUERY_WINDOW_MS >= 30_000L)
    }

    @Test
    fun `窗口内只有自己与噪声时，原因码指明最后一条到底是谁`() {
        val selfOnly = FakeForegroundQuery(events = listOf(resumed(SELF_PACKAGE, 900L)))
        assertEquals("last-event-is-self", resolver(selfOnly).read(1_000L).reason)

        val noiseOnly = FakeForegroundQuery(
            events = listOf(resumed("com.android.systemui", 900L)),
        )
        assertEquals("last-event-is-system-noise", resolver(noiseOnly).read(1_000L).reason)

        val none = FakeForegroundQuery()
        assertEquals("no-event-in-window", resolver(none).read(1_000L).reason)

        val backgroundOnly = FakeForegroundQuery(
            events = listOf(background("com.example.bg", 900L)),
        )
        assertEquals("no-event-in-window", resolver(backgroundOnly).read(1_000L).reason)
    }

    @Test
    fun `AppOps 口径不准但确实能读到数据时仍可用（并如实报告 appOps=false）`() {
        val query = FakeForegroundQuery(
            granted = true,
            appOps = false,
            events = listOf(resumed("org.telegram.messenger", 900L)),
        )
        val reading = resolver(query).read(1_000L)
        assertEquals("org.telegram.messenger", reading.snapshot?.packageName)
        assertTrue(reading.usageAccessAvailable)
        assertFalse("appOps 与真实可用性不一致时必须看得出来", reading.diagnostics.appOpsAllowed)
    }
}

/**
 * Phase 4C-5.1A：前台应用**共享快照**。
 *
 * 这是"两个页面显示同一个应用"的结构性保证：设置页与使用统计页都只读这一份快照。
 */
class ForegroundAppRegistryTest {

    @After
    fun tearDown() {
        ForegroundAppRegistry.clear()
    }

    @Test
    fun `发布后快照反映包名-标签-分类与检测来源`() {
        ForegroundAppRegistry.publish(
            detectedReading("org.telegram.messenger", "Telegram", now = 5_000L),
            now = 5_000L,
        )
        val snapshot = ForegroundAppRegistry.current
        assertNotNull(snapshot)
        assertEquals("org.telegram.messenger", snapshot!!.packageName)
        assertEquals("Telegram", snapshot.appLabel)
        assertEquals(AppCategoryId.SOCIAL, snapshot.category)
        assertEquals(AppCategorySource.builtInRule.wire, snapshot.categorySource)
        assertEquals("activity-events", snapshot.source)
        assertEquals(5_000L, snapshot.detectedAt)
        assertTrue(snapshot.hasApp)
        assertNull(snapshot.reason)
    }

    @Test
    fun `拿不到应用时快照仍然存在但 hasApp 为 false 且带失败原因`() {
        ForegroundAppRegistry.publish(
            emptyReading(6_000L, "last-event-is-self"),
            now = 6_000L,
        )
        val snapshot = ForegroundAppRegistry.current!!
        assertFalse(snapshot.hasApp)
        assertNull(snapshot.packageName)
        assertEquals("last-event-is-self", snapshot.reason)
    }

    @Test
    fun `未授权时快照如实报告 usage_access_missing`() {
        ForegroundAppRegistry.publish(
            unavailableReading(7_000L, PetStateError.USAGE_ACCESS_MISSING),
            now = 7_000L,
        )
        val snapshot = ForegroundAppRegistry.current!!
        assertFalse(snapshot.usageAccessAvailable)
        assertEquals(PetStateError.USAGE_ACCESS_MISSING, snapshot.reason)
    }

    @Test
    fun `采集器运行状态可独立于快照设置`() {
        assertFalse(ForegroundAppRegistry.collectorRunning)
        ForegroundAppRegistry.setCollectorRunning(true)
        assertTrue(ForegroundAppRegistry.collectorRunning)
        ForegroundAppRegistry.setCollectorRunning(false)
        assertFalse(ForegroundAppRegistry.collectorRunning)
    }

    @Test
    fun `clear 同时清空快照与采集器状态（服务销毁后界面必须显示不可用）`() {
        ForegroundAppRegistry.publish(detectedReading("org.telegram.messenger"), now = 1_000L)
        ForegroundAppRegistry.setCollectorRunning(true)

        ForegroundAppRegistry.clear()

        assertNull(ForegroundAppRegistry.current)
        assertFalse(ForegroundAppRegistry.collectorRunning)
    }

    @Test
    fun `统计兜底来源如实标注，不会伪装成精确事件`() {
        ForegroundAppRegistry.publish(
            detectedReading(
                "org.telegram.messenger",
                source = ForegroundDetectionSource.usageStatsFallback,
                eventType = null,
            ),
            now = 8_000L,
        )
        val snapshot = ForegroundAppRegistry.current!!
        // 快照本身不带"事件类型"字段，界面/诊断只能看到来源，
        // 因此兜底结果在结构上就不可能被显示成精确的 ACTIVITY_RESUMED 事件。
        assertEquals("usage-stats-fallback", snapshot.source)
        assertTrue(snapshot.hasApp)
    }
}

class PetStatePollerTest {

    /** 虚拟调度器：让"定时任务"在 JVM 上可精确验证。 */
    private class FakeScheduler {
        private val queue = ArrayList<Triple<Long, Long, Runnable>>()
        private var clock = 0L
        private var seq = 0L

        val pendingCount: Int get() = queue.size

        fun post(runnable: Runnable, delayMs: Long) {
            queue.add(Triple(clock + delayMs, seq++, runnable))
        }

        fun remove(runnable: Runnable) {
            queue.removeAll { it.third === runnable }
        }

        /** 推进到 [t] 并执行到期任务（按到期时间逐个前进，任务里再投递的也会被执行）。 */
        fun advanceTo(t: Long) {
            while (true) {
                val due = queue.filter { it.first <= t }.minByOrNull { it.second } ?: break
                queue.remove(due)
                // 时钟走到该任务的到期时刻，这样它再投递的任务时间才是正确的。
                clock = maxOf(clock, due.first)
                due.third.run()
            }
            clock = maxOf(clock, t)
        }
    }

    @Test
    fun `重复 start 不会创建第二个监听任务`() {
        val scheduler = FakeScheduler()
        var ticks = 0
        val poller = PetStatePoller(
            post = scheduler::post,
            remove = scheduler::remove,
            intervalMs = { 1_000L },
            onTick = { ticks += 1 },
        )
        poller.start(immediate = true)
        poller.start(immediate = true)
        poller.start(immediate = true)
        assertEquals("同一时刻最多一个任务", 1, scheduler.pendingCount)
        scheduler.advanceTo(0L)
        assertEquals(1, ticks)
    }

    @Test
    fun `任务按间隔重复触发`() {
        val scheduler = FakeScheduler()
        var ticks = 0
        val poller = PetStatePoller(
            post = scheduler::post,
            remove = scheduler::remove,
            intervalMs = { 1_000L },
            onTick = { ticks += 1 },
        )
        poller.start(immediate = false)
        scheduler.advanceTo(3_000L)
        assertEquals(3, ticks)
    }

    @Test
    fun `stop 之后回调不再执行`() {
        val scheduler = FakeScheduler()
        var ticks = 0
        val poller = PetStatePoller(
            post = scheduler::post,
            remove = scheduler::remove,
            intervalMs = { 1_000L },
            onTick = { ticks += 1 },
        )
        poller.start(immediate = true)
        scheduler.advanceTo(0L)
        assertEquals(1, ticks)
        poller.stop()
        assertFalse(poller.isRunning)
        assertEquals(0, scheduler.pendingCount)
        scheduler.advanceTo(100_000L)
        assertEquals("停止后不得再有任何回调", 1, ticks)
    }

    @Test
    fun `pollNow 立即触发一次`() {
        val scheduler = FakeScheduler()
        var ticks = 0
        val poller = PetStatePoller(
            post = scheduler::post,
            remove = scheduler::remove,
            intervalMs = { 10_000L },
            onTick = { ticks += 1 },
        )
        poller.start(immediate = false)
        assertEquals(0, ticks)
        poller.pollNow()
        scheduler.advanceTo(1L)
        assertEquals(1, ticks)
    }

    @Test
    fun `未启动时 pollNow 是空操作`() {
        val scheduler = FakeScheduler()
        var ticks = 0
        val poller = PetStatePoller(
            post = scheduler::post,
            remove = scheduler::remove,
            intervalMs = { 1_000L },
            onTick = { ticks += 1 },
        )
        poller.pollNow()
        scheduler.advanceTo(10_000L)
        assertEquals(0, ticks)
        assertEquals(0, scheduler.pendingCount)
    }

    @Test
    fun `间隔低于下限时被夹到 500ms（不允许高于 2 次每秒）`() {
        val scheduler = FakeScheduler()
        var ticks = 0
        val poller = PetStatePoller(
            post = scheduler::post,
            remove = scheduler::remove,
            intervalMs = { 10L },
            onTick = { ticks += 1 },
        )
        poller.start(immediate = false)
        scheduler.advanceTo(499L)
        assertEquals(0, ticks)
        scheduler.advanceTo(500L)
        assertEquals(1, ticks)
    }
}

class NativePetStateMappingParserTest {

    private fun raw(
        revision: Long = 1L,
        characterId: String = "char-1",
        defaultAsset: Map<String, Any?>? = mapOf(
            "assetId" to "asset-default",
            "path" to "/data/assets/default.png",
            "isAnimated" to false,
        ),
        states: Map<String, Any?> = mapOf(
            "focused" to mapOf(
                "assetId" to "asset-focus",
                "path" to "/data/assets/focus.png",
                "isAnimated" to false,
            ),
            "gaming" to mapOf(
                "assetId" to "asset-game",
                "path" to "/data/assets/game.webp",
                "isAnimated" to true,
            ),
        ),
    ): Map<String, Any?> = mapOf(
        "revision" to revision,
        "characterId" to characterId,
        "defaultAsset" to defaultAsset,
        "states" to states,
    )

    @Test
    fun `新 revision 被接受并正确解析每个字段`() {
        val result = NativePetStateMappingParser.parse(raw(revision = 12L), previous = null)
        val mapping = result.mapping
        assertNotNull(mapping)
        assertEquals(12L, mapping!!.revision)
        assertEquals("char-1", mapping.characterId)
        assertEquals("asset-default", mapping.defaultAsset?.assetId)
        assertEquals("asset-focus", mapping.assetFor(PetStateId.FOCUSED)?.assetId)
        assertTrue(mapping.assetFor(PetStateId.GAMING)?.isAnimated == true)
        assertNull(result.code)
    }

    @Test
    fun `相同 revision 幂等（不报错，由服务层决定跳过写盘）`() {
        val first = NativePetStateMappingParser.parse(raw(revision = 5L), null).mapping!!
        val again = NativePetStateMappingParser.parse(raw(revision = 5L), first)
        assertNotNull(again.mapping)
        assertEquals(5L, again.mapping!!.revision)
        assertNull(again.code)
    }

    @Test
    fun `旧 revision 被拒绝并保留上一次有效映射`() {
        val previous = NativePetStateMappingParser.parse(raw(revision = 9L), null).mapping!!
        val result = NativePetStateMappingParser.parse(raw(revision = 8L), previous)
        assertEquals(PetStateError.MAPPING_REVISION_STALE, result.code)
        assertSame(previous, result.mapping)
    }

    @Test
    fun `未知状态 ID 被安全忽略且不影响其它条目`() {
        val states = mapOf<String, Any?>(
            "focused" to mapOf("assetId" to "a", "path" to "/p/a.png", "isAnimated" to false),
            "hibernating" to mapOf("assetId" to "x", "path" to "/p/x.png", "isAnimated" to false),
        )
        val result = NativePetStateMappingParser.parse(raw(states = states), null)
        val mapping = result.mapping!!
        assertEquals(setOf(PetStateId.FOCUSED), mapping.stateAssets.keys)
        assertEquals(PetStateError.UNKNOWN_STATE, result.code)
    }

    @Test
    fun `单个素材字段不全时只丢弃该条，不丢弃整份映射`() {
        val states = mapOf<String, Any?>(
            "focused" to mapOf("assetId" to "", "path" to "/p/a.png"),
            "gaming" to mapOf("assetId" to "ok", "path" to "/p/g.png", "isAnimated" to true),
        )
        val result = NativePetStateMappingParser.parse(raw(states = states), null)
        val mapping = result.mapping!!
        assertNull(mapping.assetFor(PetStateId.FOCUSED))
        assertNotNull(mapping.assetFor(PetStateId.GAMING))
    }

    @Test
    fun `解析失败时回退到上一次有效版本，绝不抛异常`() {
        val previous = NativePetStateMappingParser.parse(raw(revision = 3L), null).mapping!!
        for (bad in listOf(null, "not-a-map", 42, emptyMap<String, Any?>())) {
            val result = NativePetStateMappingParser.parse(bad, previous)
            assertEquals(PetStateError.MAPPING_PARSE_FAILED, result.code)
            assertSame(previous, result.mapping)
        }
        // revision 类型不符 / characterId 缺失
        val badRevision = NativePetStateMappingParser.parse(
            mapOf("revision" to "abc", "characterId" to "c"), previous,
        )
        assertEquals(PetStateError.MAPPING_PARSE_FAILED, badRevision.code)
        val noCharacter = NativePetStateMappingParser.parse(
            mapOf("revision" to 4L, "characterId" to "  "), previous,
        )
        assertEquals(PetStateError.MAPPING_PARSE_FAILED, noCharacter.code)
    }

    @Test
    fun `空映射（没有 states）是合法的，全部走默认素材`() {
        val result = NativePetStateMappingParser.parse(raw(states = emptyMap()), null)
        val mapping = result.mapping!!
        assertTrue(mapping.stateAssets.isEmpty())
        assertNotNull(mapping.defaultAsset)
    }
}

class NativeAssetSelectorTest {

    private val stateAsset = NativePetAsset("a-state", "/p/state.png", false)
    private val defaultAsset = NativePetAsset("a-default", "/p/default.png", false)
    private val otherAsset = NativePetAsset("a-other", "/p/other.webp", true)

    @Test
    fun `状态素材存在时优先使用它`() {
        val mapping = NativePetStateMapping(
            characterId = "c1",
            defaultAsset = defaultAsset,
            stateAssets = mapOf(PetStateId.SOCIAL to stateAsset),
            revision = 1L,
        )
        val selection = NativeAssetSelector.select(mapping, PetStateId.SOCIAL)!!
        assertEquals("a-state", selection.asset.assetId)
        assertEquals(NativeAssetSelector.LEVEL_STATE_ASSET, selection.level)
    }

    @Test
    fun `缺少状态素材时回退角色默认素材`() {
        val mapping = NativePetStateMapping(
            characterId = "c1",
            defaultAsset = defaultAsset,
            stateAssets = mapOf(PetStateId.SOCIAL to stateAsset),
            revision = 1L,
        )
        val selection = NativeAssetSelector.select(mapping, PetStateId.GAMING)!!
        assertEquals("a-default", selection.asset.assetId)
        assertEquals(NativeAssetSelector.LEVEL_CHARACTER_DEFAULT, selection.level)
    }

    @Test
    fun `默认素材也失效时回退到角色任一有效素材`() {
        val mapping = NativePetStateMapping(
            characterId = "c1",
            defaultAsset = null,
            stateAssets = mapOf(PetStateId.SOCIAL to stateAsset, PetStateId.GAMING to otherAsset),
            revision = 1L,
        )
        val selection = NativeAssetSelector.select(mapping, PetStateId.FOCUSED)!!
        assertEquals(NativeAssetSelector.LEVEL_FIRST_VALID, selection.level)
        assertTrue(selection.asset.assetId in setOf("a-state", "a-other"))
    }

    @Test
    fun `全部失效时返回 null（由服务层显示可见占位）`() {
        val mapping = NativePetStateMapping("c1", null, emptyMap(), 1L)
        assertNull(NativeAssetSelector.select(mapping, PetStateId.FOCUSED))
    }

    @Test
    fun `不跨角色回退：另一个角色的素材不会出现在本次选择里`() {
        val roleA = NativePetStateMapping(
            characterId = "cA",
            defaultAsset = NativePetAsset("aA", "/p/aA.png", false),
            stateAssets = emptyMap(),
            revision = 1L,
        )
        val selected = NativeAssetSelector.select(roleA, PetStateId.GAMING)!!
        assertTrue(selected.asset.assetId.startsWith("aA"))
        // 角色 B 的映射只可能选出 B 的素材。
        val roleB = NativePetStateMapping(
            characterId = "cB",
            defaultAsset = NativePetAsset("aB", "/p/aB.png", false),
            stateAssets = emptyMap(),
            revision = 1L,
        )
        assertEquals("aB", NativeAssetSelector.select(roleB, PetStateId.GAMING)!!.asset.assetId)
    }

    @Test
    fun `allAssets 去重且顺序稳定`() {
        val mapping = NativePetStateMapping(
            characterId = "c1",
            defaultAsset = defaultAsset,
            stateAssets = mapOf(
                PetStateId.SOCIAL to stateAsset,
                PetStateId.GAMING to defaultAsset,
            ),
            revision = 1L,
        )
        assertEquals(listOf("a-default", "a-state"), mapping.allAssets().map { it.assetId })
    }
}

class PetMimeTest {

    @Test
    fun `按扩展名给出合理 MIME，未知扩展名按 webp`() {
        assertEquals("image/png", PetMime.forPath("/p/a.png"))
        assertEquals("image/jpeg", PetMime.forPath("/p/a.JPG"))
        assertEquals("image/jpeg", PetMime.forPath("/p/a.jpeg"))
        assertEquals("image/gif", PetMime.forPath("/p/a.gif"))
        assertEquals("image/webp", PetMime.forPath("/p/a.webp"))
        assertEquals("image/webp", PetMime.forPath("/p/a"))
    }
}

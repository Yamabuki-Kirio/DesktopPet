package asia.akechi.petlife.overlay

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Phase 4C-6B-3 契约修复：**跨端动作 id 只有一套 canonical 值**。
 *
 * 背景：原生过去把 `WheelMenuAction.wire`（camelCase，如 `toggleAutomaticState`）
 * 发给 Dart，而 Dart 执行器只认 canonical snake_case id（如 `pet_auto`），
 * 导致每个 Dart 请求都以 `不支持的菜单动作` 失败。
 *
 * 本测试钉死三件事，防止再次出现"两套命名"：
 * 1. 会被发往 Dart 的条目，其 actionId 必须落在 [MenuActionIds.CANONICAL_DART_IDS]（恰好 17 个）；
 * 2. canonical 集合无重复、无空白、不是界面文案；
 * 3. `navigation` / `native` 动作绝不路由到 Dart 通道。
 */
class MenuActionContractTest {

    /** 测试用的"唯一契约"（与 [MenuActionIds] 同源，这里按需求逐字冻结）。 */
    private val requiredCanonicalIds: Set<String> = linkedSetOf(
        "pet_auto",
        "appearance_prev",
        "appearance_next",
        "appearance_auto",
        "appearance_fav",
        "appearance_mapping",
        "appearance_library",
        "records_today",
        "records_stats",
        "records_cloud",
        "records_track",
        "records_sync",
        "records_sync_state",
        "settings_theme",
        "settings_wheel_size",
        "settings_button_size",
        "settings_open",
    )

    /** 只会被发往 Dart 的条目（`entry.action` 走 dartRequest 通道）。 */
    private val dartEntries: List<WheelMenuEntry> = WheelMenuCatalog.allEntries.filter {
        WheelMenuActionRoutes.routeOf(it.action) == WheelActionRoute.dartRequest
    }

    @Test
    fun `每个 dartRequest 条目的 actionId 都在 canonical 集合里`() {
        assertTrue("必须存在 dart 条目", dartEntries.isNotEmpty())
        dartEntries.forEach { entry ->
            val actionId = entry.action.wire
            assertTrue(
                "条目 ${entry.id} 会发出 $actionId，必须落在 canonical 集合里",
                MenuActionIds.isCanonicalDartId(actionId),
            )
            // 条目 id 本身即稳定契约；这里顺带钉住"条目 id 也是 canonical"，
            // 让日志 / 请求 / 诊断在任何一处看到的都是同一串字符串。
            assertEquals("条目 id 必须等于 canonical actionId", entry.id, actionId)
        }
    }

    @Test
    fun `canonical 集合无重复、无空白，且绝不是显示文案`() {
        val ids = MenuActionIds.CANONICAL_DART_IDS
        assertEquals("canonical 集合不允许重复", ids.size, ids.toList().distinct().size)
        ids.forEach { id ->
            assertTrue("canonical id 不能为空或全空白：'$id'", id.isNotBlank())
            assertFalse("canonical id 不能有前后空白：'$id'", id != id.trim())
        }

        // 界面文案（中文名 / 英文标题）绝不允许被当成协议 id。
        val displayTexts = HashSet<String>()
        WheelMenuCatalog.allEntries.forEach { entry ->
            displayTexts.add(entry.labelZh)
            entry.titleEn?.let { displayTexts.add(it) }
            WheelMenuCatalog.allLevels.forEach { level ->
                displayTexts.add(level.titleEn)
                displayTexts.add(level.titleZh)
            }
        }
        ids.forEach { id ->
            assertFalse(
                "canonical id '$id' 不得与任何显示文案相同",
                displayTexts.contains(id),
            )
        }
    }

    @Test
    fun `canonical 集合恰好是这 17 个（双向一致）`() {
        assertEquals("canonical 集合必须恰好 17 个", 17, MenuActionIds.CANONICAL_DART_IDS.size)
        assertEquals("冻结契约逐字一致", requiredCanonicalIds, MenuActionIds.CANONICAL_DART_IDS)

        // 方向一：每个必需 id 恰好由一个 dart 条目产生（不多不少）。
        val producedByEntry = dartEntries.groupBy { it.action.wire }
        requiredCanonicalIds.forEach { id ->
            assertEquals(
                "必需 id '$id' 必须恰好由一个条目产生",
                1,
                producedByEntry[id]?.size ?: 0,
            )
        }

        // 方向二：不存在任何"额外的" dart 请求 id（多于 17 个就是又开了一套命名）。
        assertEquals(
            "不得存在 canonical 集合之外的 dart 请求 id",
            requiredCanonicalIds,
            MenuActionIds.dartRequestIds(),
        )
        assertEquals(
            "dartRequestActions 与条目发出的 id 必须一致",
            requiredCanonicalIds,
            dartEntries.map { it.action.wire }.toSet(),
        )
    }

    @Test
    fun `native 与 navigation 动作绝不发往 Dart`() {
        val nativeActions = WheelMenuActionRoutes.nativeActions()
        val navigationActions = WheelMenuActionRoutes.navigationActions()

        (nativeActions + navigationActions).forEach { action ->
            assertFalse(
                "$action 不得落在 dartRequest 通道",
                WheelMenuActionRoutes.routeOf(action) == WheelActionRoute.dartRequest,
            )
            assertFalse(
                "$action 的 wire 不得是 canonical dart id",
                MenuActionIds.isCanonicalDartId(action.wire),
            )
        }

        // 逐条打靶：分发器确实把 native / navigation 路由到各自通道，且从不进 Dart。
        val host = RecordingHost()
        val dispatcher = WheelMenuActionDispatcher(host)
        nativeActions.forEach { dispatcher.dispatch(it, "test", null) }
        navigationActions.forEach { dispatcher.dispatch(it, "test", null) }

        assertEquals("native 动作必须全部进 native 通道", nativeActions, host.native.toSet())
        assertEquals("navigation 动作必须全部进 navigation 通道", navigationActions, host.navigated.toSet())
        assertTrue("native / navigation 一条都不得进 Dart 通道", host.dartRequests.isEmpty())
    }

    /** 只记录"每个动作走了哪条通道"的宿主。 */
    private class RecordingHost : WheelMenuActionHost {
        val navigated = ArrayList<WheelMenuAction>()
        val native = ArrayList<WheelMenuAction>()
        val dartRequests = ArrayList<WheelMenuAction>()
        val info = ArrayList<String>()

        override fun onNavigateAction(action: WheelMenuAction, entryId: String): Boolean {
            navigated.add(action)
            return true
        }

        override fun onNativeAction(action: WheelMenuAction, entryId: String): Boolean {
            native.add(action)
            return true
        }

        override fun onDartRequestAction(
            action: WheelMenuAction,
            entryId: String,
            entry: WheelMenuEntry?,
        ): Boolean {
            dartRequests.add(action)
            return true
        }

        override fun onInfoAction(entryId: String, entry: WheelMenuEntry) {
            info.add(entryId)
        }
    }

    @Test
    fun `契约辅助函数的边界行为`() {
        assertTrue(MenuActionIds.isCanonicalDartId("pet_auto"))
        // 旧的 camelCase 值在原生侧已不再是 canonical —— 只由 Dart 接收侧做兼容归一化。
        assertFalse(MenuActionIds.isCanonicalDartId("toggleAutomaticState"))
        assertFalse(MenuActionIds.isCanonicalDartId(null))
        assertFalse(MenuActionIds.isCanonicalDartId(""))
    }
}

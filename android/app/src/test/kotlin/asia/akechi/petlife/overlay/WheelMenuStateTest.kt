package asia.akechi.petlife.overlay

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Phase 4C-6B-1：轮盘交互状态机与动作分发 —— 覆盖需求 §18.2 与 §17。
 */
class WheelMenuStateTest {

    // --- 菜单栈与层级 -------------------------------------------------------

    @Test
    fun `打开菜单进入根菜单，关闭后栈被清空`() {
        val machine = WheelMenuStateMachine()
        assertTrue(machine.open(WheelExpandDirection.right))
        assertEquals(WheelMenuPhase.opening, machine.phase)
        assertEquals(WheelMenuCatalog.ROOT_ID, machine.levelId)
        assertEquals(0, machine.selectedIndex)
        assertFalse("根菜单不能返回", machine.canGoBack)

        machine.markOpened()
        assertEquals(WheelMenuPhase.open, machine.phase)

        assertTrue(machine.close())
        assertEquals(WheelMenuPhase.closed, machine.phase)
        assertNull(machine.levelId)
    }

    @Test
    fun `重复打开是幂等的（不会产生第二套菜单）`() {
        val machine = WheelMenuStateMachine()
        assertTrue(machine.open(WheelExpandDirection.right))
        assertFalse("已打开时再次 open 必须被拒绝", machine.open(WheelExpandDirection.left))
        assertEquals(WheelExpandDirection.right, machine.direction)
    }

    @Test
    fun `进入子菜单与返回：栈深度正确，返回键只退一级`() {
        val machine = WheelMenuStateMachine()
        machine.open(WheelExpandDirection.right)
        machine.markOpened()

        assertTrue(machine.enterLayer(WheelMenuCatalog.LEVEL_PET))
        assertEquals(WheelMenuCatalog.LEVEL_PET, machine.levelId)
        assertEquals(2, machine.depth)
        assertTrue(machine.canGoBack)
        machine.finishLayerTransition()
        assertEquals(WheelMenuPhase.open, machine.phase)

        assertTrue(machine.exitLayer())
        assertEquals(WheelMenuCatalog.ROOT_ID, machine.levelId)
        assertEquals(1, machine.depth)
        machine.finishLayerTransition()

        assertFalse("根菜单再返回必须失败（不能顺手关掉菜单）", machine.exitLayer())
        assertEquals(WheelMenuCatalog.ROOT_ID, machine.levelId)
        assertEquals(WheelMenuPhase.open, machine.phase)
    }

    @Test
    fun `非法层级路径被拒绝，不产生非法状态`() {
        val machine = WheelMenuStateMachine()
        machine.open(WheelExpandDirection.right)
        machine.markOpened()
        assertFalse("不存在的层级必须被拒绝", machine.enterLayer("no-such-level"))
        assertFalse("根菜单不能作为子菜单进入", machine.enterLayer(WheelMenuCatalog.ROOT_ID))
        assertFalse("重复进入同一层级必须被拒绝", run {
            machine.enterLayer(WheelMenuCatalog.LEVEL_PET) &&
                machine.enterLayer(WheelMenuCatalog.LEVEL_PET)
        })
        assertEquals(WheelMenuCatalog.LEVEL_PET, machine.levelId)
        assertEquals(2, machine.depth)
    }

    @Test
    fun `菜单关闭时不能进入子菜单`() {
        val machine = WheelMenuStateMachine()
        assertFalse(machine.enterLayer(WheelMenuCatalog.LEVEL_PET))
        assertFalse(machine.exitLayer())
        assertNull(machine.levelId)
    }

    @Test
    fun `换层后选中项回到第一项`() {
        val machine = WheelMenuStateMachine()
        machine.open(WheelExpandDirection.right)
        machine.markOpened()
        machine.setPreview(4)
        machine.confirmSelection()
        assertEquals(4, machine.selectedIndex)

        machine.enterLayer(WheelMenuCatalog.LEVEL_SETTINGS)
        assertEquals(0, machine.selectedIndex)
        assertNull(machine.previewIndex)
    }

    // --- 选中与取消 ---------------------------------------------------------

    @Test
    fun `滑选中的临时高亮优先于已确认项，且越界会被夹回`() {
        val machine = WheelMenuStateMachine()
        machine.open(WheelExpandDirection.right)
        machine.markOpened()
        assertEquals(0, machine.activeIndex)

        machine.setPreview(3)
        assertEquals(3, machine.activeIndex)
        assertEquals("确认项还没变", 0, machine.selectedIndex)

        machine.setPreview(null)
        assertEquals("取消后回到已确认项", 0, machine.activeIndex)

        machine.setPreview(999)
        assertEquals("越界必须夹回合法范围", machine.currentLevel!!.itemCount - 1, machine.activeIndex)
    }

    @Test
    fun `松手确认把临时高亮变成已确认项并返回被选中的条目`() {
        val machine = WheelMenuStateMachine()
        machine.open(WheelExpandDirection.right)
        machine.markOpened()
        machine.setPreview(2)
        val entry = machine.confirmSelection()
        assertEquals(WheelMenuCatalog.ROOT.entries[2].id, entry?.id)
        assertEquals(2, machine.selectedIndex)
        assertNull(machine.previewIndex)
    }

    @Test
    fun `动画被打断后收敛到确定状态，绝不卡在中间态`() {
        for (phase in WheelMenuPhase.entries) {
            val machine = WheelMenuStateMachine()
            machine.open(WheelExpandDirection.right)
            machine.markOpened()
            when (phase) {
                WheelMenuPhase.switching -> machine.beginSwitch(1)
                WheelMenuPhase.enteringLayer -> machine.enterLayer(WheelMenuCatalog.LEVEL_PET)
                WheelMenuPhase.exitingLayer -> {
                    machine.enterLayer(WheelMenuCatalog.LEVEL_PET)
                    machine.finishLayerTransition()
                    machine.exitLayer()
                }
                WheelMenuPhase.closing -> machine.beginClosing()
                WheelMenuPhase.opening -> {
                    // 重新构造一个"正在展开"的实例
                    val fresh = WheelMenuStateMachine()
                    fresh.open(WheelExpandDirection.right)
                    fresh.settleAfterInterruption()
                    assertEquals(WheelMenuPhase.open, fresh.phase)
                    continue
                }
                WheelMenuPhase.closed, WheelMenuPhase.open -> continue
            }
            machine.settleAfterInterruption()
            assertTrue(
                "phase=$phase 打断后必须落在确定状态，实际 ${machine.phase}",
                machine.phase == WheelMenuPhase.open || machine.phase == WheelMenuPhase.closed,
            )
        }
    }

    @Test
    fun `长按返回可以一路回到根菜单`() {
        val stack = WheelMenuStack()
        stack.open()
        stack.push(WheelMenuCatalog.LEVEL_PET)
        stack.push(WheelMenuCatalog.LEVEL_SETTINGS)
        assertTrue(stack.popToRoot())
        assertEquals(WheelMenuCatalog.ROOT_ID, stack.currentId)
        assertFalse(stack.popToRoot())
    }

    // --- 动作分发（需求 §17）---------------------------------------------

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
    fun `四条通道与冻结契约逐条一致（navigation、native、dartRequest、info）`() {
        val dispatcher = WheelMenuActionDispatcher(RecordingHost())

        // --- navigation：五个子菜单 + 返回 + 关闭 ---
        for (action in listOf(
            WheelMenuAction.openPetMenu,
            WheelMenuAction.openAppearanceMenu,
            WheelMenuAction.openRecordsMenu,
            WheelMenuAction.openToolsMenu,
            WheelMenuAction.openSettingsMenu,
            WheelMenuAction.back,
            WheelMenuAction.closeMenu,
        )) {
            assertEquals("$action 必须是 navigation", WheelActionRoute.navigation, dispatcher.routeOf(action))
        }

        // --- native：完全在 Kotlin 里执行（绝不回 Dart 一趟）---
        for (action in listOf(
            WheelMenuAction.hideOverlay,
            WheelMenuAction.resetPetPosition,
            WheelMenuAction.changePetSizeDown,
            WheelMenuAction.changePetSizeUp,
            WheelMenuAction.resetPetSize,
            WheelMenuAction.openPetLife,
        )) {
            assertEquals("$action 必须是 native", WheelActionRoute.native, dispatcher.routeOf(action))
        }

        // --- info：只读信息项 ---
        assertEquals(WheelActionRoute.info, dispatcher.routeOf(WheelMenuAction.showInfo))

        // --- dartRequest：必须由 Dart 执行 ---
        for (action in listOf(
            WheelMenuAction.toggleAutomaticState,
            WheelMenuAction.previousAsset,
            WheelMenuAction.nextAsset,
            WheelMenuAction.toggleAutomaticAsset,
            WheelMenuAction.toggleFavorite,
            WheelMenuAction.openStateMapping,
            WheelMenuAction.openAssetLibrary,
            WheelMenuAction.showTodayUsage,
            WheelMenuAction.openUsageStatistics,
            WheelMenuAction.openCloudRecords,
            WheelMenuAction.toggleTracking,
            WheelMenuAction.syncNow,
            WheelMenuAction.showSyncState,
            WheelMenuAction.selectTheme,
            WheelMenuAction.changeMenuScale,
            WheelMenuAction.changeButtonScale,
            WheelMenuAction.openSettings,
        )) {
            assertEquals(
                "$action 必须是 dartRequest",
                WheelActionRoute.dartRequest,
                dispatcher.routeOf(action),
            )
        }
    }

    @Test
    fun `每个动作都有且只有一条通道（路由完备且互斥）`() {
        val routes = WheelMenuAction.entries.map { WheelMenuActionRoutes.routeOf(it) }
        assertEquals(WheelMenuAction.entries.size, routes.size)
        // 四类集合的并集必须覆盖全部动作，交集必须为空
        val nav = WheelMenuActionRoutes.navigationActions()
        val native = WheelMenuActionRoutes.nativeActions()
        val info = WheelMenuActionRoutes.infoActions()
        val dart = WheelMenuActionRoutes.dartRequestActions()
        assertTrue(
            "四类通道必须覆盖全部动作",
            (nav + native + info + dart).size == WheelMenuAction.entries.size,
        )
        assertTrue("通道之间不得重叠：nav∩native", (nav intersect native).isEmpty())
        assertTrue("通道之间不得重叠：nav∩info", (nav intersect info).isEmpty())
        assertTrue("通道之间不得重叠：native∩info", (native intersect info).isEmpty())
        assertTrue("通道之间不得重叠：nav∩dart", (nav intersect dart).isEmpty())
        assertTrue("通道之间不得重叠：native∩dart", (native intersect dart).isEmpty())
    }

    @Test
    fun `分发只调用对应的一条通道`() {
        val host = RecordingHost()
        val dispatcher = WheelMenuActionDispatcher(host)

        dispatcher.dispatch(WheelMenuAction.openSettingsMenu, "root_settings", null)
        assertEquals(listOf(WheelMenuAction.openSettingsMenu), host.navigated)
        assertTrue(host.native.isEmpty())
        assertTrue(host.dartRequests.isEmpty())

        dispatcher.dispatch(WheelMenuAction.resetPetSize, "pet_size_reset", null)
        assertEquals(listOf(WheelMenuAction.resetPetSize), host.native)

        dispatcher.dispatch(WheelMenuAction.syncNow, "records_sync", null)
        assertEquals(listOf(WheelMenuAction.syncNow), host.dartRequests)

        dispatcher.dispatch(
            WheelMenuAction.showInfo,
            "records_app",
            WheelMenuCatalog.RECORDS.entries.first { it.id == "records_app" },
        )
        assertEquals(listOf("records_app"), host.info)
    }

    @Test
    fun `隐藏动作命令路径是 HIDE（不是 STOP：服务与通知必须继续运行）`() {
        assertEquals(
            OverlayCommand.HIDE,
            MenuNativeOps.commandOf(WheelMenuAction.hideOverlay.wire),
        )
        assertTrue(
            "隐藏绝不能映射成停止",
            MenuNativeOps.commandOf(WheelMenuAction.hideOverlay.wire) != OverlayCommand.STOP,
        )
        // 其余原生动作不占命令通道（它们只改 store + 走既有 UPDATE / 启动入口）
        assertNull(MenuNativeOps.commandOf(WheelMenuAction.changePetSizeDown.wire))
        assertNull(MenuNativeOps.commandOf(WheelMenuAction.resetPetPosition.wire))
        assertNull(MenuNativeOps.commandOf(WheelMenuAction.openPetLife.wire))
    }

    @Test
    fun `根条目到子菜单的映射只有一份，且来回一致`() {
        val dispatcher = WheelMenuActionDispatcher(RecordingHost())
        val expected = mapOf(
            WheelMenuAction.openPetMenu to WheelMenuCatalog.LEVEL_PET,
            WheelMenuAction.openAppearanceMenu to WheelMenuCatalog.LEVEL_APPEARANCE,
            WheelMenuAction.openRecordsMenu to WheelMenuCatalog.LEVEL_RECORDS,
            WheelMenuAction.openToolsMenu to WheelMenuCatalog.LEVEL_TOOLS,
            WheelMenuAction.openSettingsMenu to WheelMenuCatalog.LEVEL_SETTINGS,
        )
        // 根菜单里每个"打开子菜单"的动作都能映射到真实存在的层级
        WheelMenuCatalog.ROOT.entries.forEach { entry ->
            val target = dispatcher.targetLevelOf(entry.action)
            if (target != null) {
                assertEquals(expected[entry.action], target)
                assertTrue("映射到的层级必须真实存在", WheelMenuCatalog.level(target) != null)
            }
        }
        assertNull(dispatcher.targetLevelOf(WheelMenuAction.hideOverlay))
        assertNull(dispatcher.targetLevelOf(WheelMenuAction.back))
    }

    @Test
    fun `每个条目的动作都在统一命令表里（没有第二套命名）`() {
        val all = WheelMenuCatalog.allEntries
        assertTrue(all.isNotEmpty())
        all.forEach { entry ->
            assertTrue("条目 ${entry.id} 的 id 不能为空", entry.id.isNotEmpty())
            assertTrue("条目 ${entry.id} 的中文名不能为空", entry.labelZh.isNotEmpty())
            assertTrue(
                "条目 ${entry.id} 的动作必须在命令表里",
                WheelMenuAction.entries.contains(entry.action),
            )
        }
        // id 在同一层级内唯一（返回键在所有子菜单里共用同一个 id，这是刻意的）
        WheelMenuCatalog.allLevels.forEach { level ->
            assertEquals(
                "${level.id} 内 id 必须唯一",
                level.entries.size,
                level.entries.map { it.id }.distinct().size,
            )
        }
        // 除共用的 `back` 之外，条目 id 全局唯一（id 是稳定契约：日志 / 请求 / 诊断都读它）
        val shared = all.filter { it.id == "back" }.map { it.id }.distinct()
        val globalIds = all.filter { it.id != "back" }.map { it.id }
        assertEquals("除 back 外条目 id 必须全局唯一", globalIds.size, globalIds.distinct().size)
        assertEquals(listOf("back"), shared)
    }

    @Test
    fun `每条条目的动作都能查到唯一的通道，且 id 能反查回条目`() {
        WheelMenuCatalog.allEntries.forEach { entry ->
            val route = WheelMenuActionRoutes.routeOf(entry.action)
            assertTrue(
                "条目 ${entry.id}（${entry.action}）必须有通道",
                route in WheelActionRoute.entries,
            )
            assertTrue("id 必须能反查回条目：${entry.id}", WheelMenuCatalog.entryOf(entry.id) != null)
        }
    }

    // --- 菜单请求队列（需求 §17：幂等 / 过期 / 上限 / 只消费一次）----------

    private fun request(id: String, createdAt: Long, action: String = "nextAsset") =
        PendingMenuRequest(requestId = id, actionId = action, createdAt = createdAt)

    @Test
    fun `入队按 requestId 去重，同 id 第二次入队被忽略`() {
        val queue = MenuRequestQueue(now = { 1_000L })
        assertTrue(queue.enqueue(request("r1", 1_000L)))
        assertFalse("同 id 重复入队必须被忽略", queue.enqueue(request("r1", 1_000L)))
        assertEquals(1, queue.size)
        // 载荷形状与 Dart 契约一致：只有四个键
        val payload = queue.all().first().toPayload()
        assertEquals(listOf("requestId", "actionId", "args", "createdAt"), payload.keys.toList())
    }

    @Test
    fun `pending 请求只会被消费一次`() {
        val queue = MenuRequestQueue(now = { 1_000L })
        assertTrue(queue.enqueue(request("r1", 1_000L)))
        assertTrue(queue.enqueue(request("r2", 1_001L)))

        val first = queue.takePending()
        assertEquals(listOf("r1", "r2"), first.map { it.requestId })
        assertTrue("同一条请求不得被交付第二次", queue.takePending().isEmpty())
        assertTrue("消费后不应还在 pending 快照里", queue.pendingSnapshot().isEmpty())
    }

    @Test
    fun `超过 TTL 的请求被丢弃并计入 expired`() {
        var now = 1_000L
        val queue = MenuRequestQueue(now = { now })
        queue.enqueue(request("old", 1_000L))
        now = 1_000L + MenuRequestQueue.TTL_MS + 1
        queue.enqueue(request("fresh", now))
        assertEquals("过期条目必须被丢弃", 1, queue.size)
        assertEquals(listOf("fresh"), queue.all().map { it.requestId })
        assertEquals(1, queue.expiredCount)
        // 过期 id 进 LRU：不会因为"再来一条同 id"而复活
        assertTrue(queue.isTerminalId("old"))
    }

    @Test
    fun `队列上限 32 条，超出时丢最旧的`() {
        val queue = MenuRequestQueue(now = { 1_000L })
        for (index in 1..(MenuRequestQueue.MAX_ENTRIES + 5)) {
            assertTrue(queue.enqueue(request("r$index", 1_000L + index)))
        }
        assertEquals(MenuRequestQueue.MAX_ENTRIES, queue.size)
        assertEquals(5, queue.droppedForCapacity)
        // 最旧的 5 条被丢弃，最旧的现存条目是 r6
        assertEquals("r6", queue.all().first().requestId)
        assertEquals("r37", queue.all().last().requestId)
    }

    @Test
    fun `已完成的请求不会被重新入队或重新推送（Activity 重建同理）`() {
        val queue = MenuRequestQueue(now = { 1_000L })
        queue.enqueue(request("r1", 1_000L))
        assertEquals(listOf("r1"), queue.takePending().map { it.requestId })
        assertTrue(queue.markCompleted("r1"))
        assertEquals(0, queue.size)
        assertFalse("已完成 id 不得再次入队", queue.enqueue(request("r1", 2_000L)))
        assertTrue(queue.takePending().isEmpty())
        assertTrue(queue.isTerminalId("r1"))

        // 重建队列（等价于 Activity / 进程重建：从落盘的 id 列表恢复）
        val rebuilt = MenuRequestQueue(completedIds = queue.completedIds(), now = { 3_000L })
        assertFalse("重建后同样不得再次执行", rebuilt.enqueue(request("r1", 3_000L)))
        assertTrue(rebuilt.takePending().isEmpty())
    }

    @Test
    fun `completed 的 LRU 容量为 64，最旧的被挤出`() {
        val ids = (1..(MenuRequestQueue.COMPLETED_LRU + 3)).map { "c$it" }
        val queue = MenuRequestQueue(completedIds = ids, now = { 1_000L })
        assertEquals(MenuRequestQueue.COMPLETED_LRU, queue.completedIds().size)
        assertFalse("被挤出的 id 不再是终态", queue.isTerminalId("c1"))
        assertTrue("最新的 id 仍是终态", queue.isTerminalId("c${MenuRequestQueue.COMPLETED_LRU + 3}"))
    }

    @Test
    fun `marked failed 也是终态，且状态 wire 与 Dart 侧一致`() {
        assertEquals("completed", MenuRequestStatus.completed.wire)
        assertEquals("failed", MenuRequestStatus.failed.wire)
        assertEquals("expired", MenuRequestStatus.expired.wire)
        assertEquals(MenuRequestStatus.failed, MenuRequestStatus.fromWire("failed"))

        val queue = MenuRequestQueue(now = { 1_000L })
        queue.enqueue(request("r1", 1_000L))
        queue.takePending()
        assertTrue(queue.markFailed("r1"))
        assertFalse(queue.enqueue(request("r1", 1_000L)))
        assertTrue(queue.isTerminalId("r1"))
    }

    // --- 尺寸动作（需求 §17：50%~200%，步进 10%，默认 100%）----------------

    @Test
    fun `缩小放大按 10% 步进并在 50%-200% 处夹紧`() {
        assertEquals(0.9f, MenuPetSize.down(1.0f), 0.0001f)
        assertEquals(1.1f, MenuPetSize.up(1.0f), 0.0001f)
        assertEquals(0.5f, MenuPetSize.down(0.5f), 0.0001f)
        assertEquals(0.5f, MenuPetSize.down(0.1f), 0.0001f)
        assertEquals(2.0f, MenuPetSize.up(2.0f), 0.0001f)
        assertEquals(2.0f, MenuPetSize.up(2.4f), 0.0001f)
        // 浮点累积误差必须被吸附掉（连续点 10 次回到 1.0）
        var scale = 1.0f
        repeat(10) { scale = MenuPetSize.down(scale) }
        assertEquals("10 次缩小后必须落在 50%", 0.5f, scale, 0.0001f)
        var up = 0.5f
        repeat(5) { up = MenuPetSize.up(up) }
        assertEquals("5 次放大后必须正好回到 100%", 1.0f, up, 0.0001f)
    }

    @Test
    fun `恢复默认大小回到 100%`() {
        assertEquals(PetOverlayStore.DEFAULT_SCALE, MenuPetSize.reset(1.7f), 0.0001f)
        assertEquals(PetOverlayStore.DEFAULT_SCALE, MenuPetSize.reset(0.5f), 0.0001f)
        assertEquals("130%", MenuPetSize.percent(1.3f))
        assertEquals("200%", MenuPetSize.percent(2.0f))
    }

    // --- 窗口内反馈（需求 §17：不覆盖新结果、不改窗口几何）------------------

    @Test
    fun `旧异步结果不得覆盖更新的反馈`() {
        var now = 1_000L
        val state = MenuFeedbackState(now = { now })
        assertTrue(state.show("处理中…", FeedbackKind.running, "req-1"))
        assertTrue("新请求必须能取代旧的", state.show("处理中…", FeedbackKind.running, "req-2"))
        assertEquals("req-2", state.requestId)
        now += 100L
        assertFalse(
            "旧 requestId 的迟到结果必须被丢弃",
            state.show("失败", FeedbackKind.error, "req-1"),
        )
        assertEquals("req-2", state.requestId)
        assertEquals(FeedbackKind.running, state.kind)
        // 同一个 requestId 的后续结果（running → success）必须能更新
        assertTrue(state.show("已完成", FeedbackKind.success, "req-2"))
        assertEquals("已完成", state.text)
    }

    @Test
    fun `反馈到点自动消失`() {
        var now = 1_000L
        val state = MenuFeedbackState(now = { now })
        state.show("已缩小", FeedbackKind.success, null)
        assertFalse(state.isExpired())
        now += MenuFeedbackPolicy.DURATION_MS
        assertTrue("超过展示时长必须到期", state.isExpired())
        state.hide()
        assertFalse(state.isShowing)
    }

    @Test
    fun `反馈层只画在窗口内部，绝不改变窗口几何`() {
        val window = OverlayBounds(0, 0, 1080, 1920)
        for (height in intArrayOf(200, 640, 1920)) {
            val rect = MenuFeedbackPolicy.rectInWindow(
                windowWidth = window.width,
                windowHeight = height,
                barHeightPx = 88,
                marginPx = 24,
            )
            assertTrue("反馈条必须完全落在窗口内：$rect", rect.isInside(OverlayBounds(0, 0, window.width, height)))
            assertTrue("反馈条必须靠近底部：$rect", rect.bottom > height / 2)
            assertTrue("反馈条必须有非零尺寸", rect.isUsable)
        }
        // 反馈只读窗口尺寸、只返回窗口内矩形 ⇒ 任何"反馈动作"都不在该集合里
        for (action in WheelMenuAction.entries) {
            if (WheelMenuActionRoutes.routeOf(action) == WheelActionRoute.dartRequest) {
                assertFalse(
                    "$action 只是请求/反馈，不得提交几何",
                    MenuActionPlan.commitsGeometry(action),
                )
            }
        }
        assertTrue("重置位置确实会走几何提交", MenuActionPlan.commitsGeometry(WheelMenuAction.resetPetPosition))
        assertTrue("改大小确实会走几何提交", MenuActionPlan.commitsGeometry(WheelMenuAction.changePetSizeUp))
        assertFalse(MenuActionPlan.commitsGeometry(WheelMenuAction.showInfo))
    }

    @Test
    fun `尺寸与自动状态类请求先收起菜单，只读类保持菜单打开`() {
        // 用户已确认的口径：会改变外观的动作"收起菜单后生效"
        assertTrue(MenuActionPlan.closesMenuFirst(WheelMenuAction.changeMenuScale))
        assertTrue(MenuActionPlan.closesMenuFirst(WheelMenuAction.changeButtonScale))
        assertTrue(MenuActionPlan.closesMenuFirst(WheelMenuAction.toggleAutomaticState))
        // 只读类保持菜单在屏幕上，反馈直接显示在窗口内
        assertFalse(MenuActionPlan.closesMenuFirst(WheelMenuAction.showTodayUsage))
        assertFalse(MenuActionPlan.closesMenuFirst(WheelMenuAction.showSyncState))
    }

    @Test
    fun `请求状态的 wire 值与 Dart 侧冻结契约一致`() {
        assertEquals(FeedbackKind.running, MenuFeedbackPolicy.kindOfStatus("running"))
        assertEquals(FeedbackKind.success, MenuFeedbackPolicy.kindOfStatus(MenuRequestBridge.STATUS_COMPLETED))
        assertEquals(FeedbackKind.error, MenuFeedbackPolicy.kindOfStatus(MenuRequestBridge.STATUS_FAILED))
        assertEquals(FeedbackKind.warning, MenuFeedbackPolicy.kindOfStatus(MenuRequestBridge.STATUS_EXPIRED))
        assertEquals("menuRequest", MenuRequestBridge.METHOD_MENU_REQUEST)
        assertEquals("pullPendingMenuRequests", MenuRequestBridge.METHOD_PULL_PENDING)
        assertEquals("completeMenuRequest", MenuRequestBridge.METHOD_COMPLETE_REQUEST)
        assertNull(MenuRequestBridge.parseCompletion(mapOf("status" to "completed")))
        assertEquals(
            Triple("r1", "completed", "ok"),
            MenuRequestBridge.parseCompletion(
                mapOf("requestId" to "r1", "status" to "completed", "message" to "ok"),
            ),
        )
    }
}

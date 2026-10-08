package asia.akechi.petlife.overlay

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 真机缺陷 1 的**纯逻辑**回归测试：菜单交互会话 + 回调策略 + 延迟摘层闸门的终结。
 *
 * 对应任务要求：
 * 1. 关闭后陈旧的抬手不会执行动作（[MenuInteractionSession.canDispatchAction]）；
 * 2. 关闭后陈旧的动画结束回调不会恢复交互或几何（[MenuCallbackPolicy]）；
 * 3. 关闭后立刻重开：旧回调不扰动新会话（会话号）；
 * 4. 转发拖动挂起的摘层请求在手势结束后**恰好消费一次**，终止事件缺失时也能强制释放；
 * 5. 关闭终结后**窗口缩回人物矩形**（零 padding），人物屏幕矩形不变 —— 这是唯一能让
 *    下层应用重新可点的做法（平台没有公开的"局部可触摸区域"API，返回 false 不会穿透）。
 */
class MenuInteractionSessionTest {

    // --- 1. 打开 / 关闭的交互门控 -------------------------------------------

    @Test
    fun `打开菜单后允许派发动作，关闭被接受后同一帧即拒绝`() {
        val session = MenuInteractionSession()
        val id = session.beginOpen()
        assertTrue("打开后应允许交互", session.touchAllowed())
        assertTrue("打开后应允许派发", session.canDispatchAction(id, menuOpen = true))

        assertTrue("关闭应真的改变交互开关", session.acceptClose())
        assertFalse("关闭被接受后不得再允许交互", session.touchAllowed())
        assertFalse(
            "关闭被接受后同一帧就必须拒绝派发（陈旧抬手不得执行动作）",
            session.canDispatchAction(id, menuOpen = true),
        )
    }

    @Test
    fun `派发动作同时要求会话未过期与菜单处于打开态`() {
        val session = MenuInteractionSession()
        val id = session.beginOpen()

        assertFalse("会话正确但菜单不在打开态 → 拒绝", session.canDispatchAction(id, menuOpen = false))
        assertFalse("菜单打开但会话过期 → 拒绝", session.canDispatchAction(id + 1, menuOpen = true))
        assertTrue(session.canDispatchAction(id, menuOpen = true))
    }

    // --- 2. 关闭后立刻重开（会话号隔离） -------------------------------------

    @Test
    fun `关闭后立刻重开：旧会话的回调全部失效，新会话不受影响`() {
        val session = MenuInteractionSession()
        val old = session.beginOpen()
        session.acceptClose()
        val new = session.beginOpen()

        assertNotEquals("重开必须进入新会话", old, new)
        assertFalse("旧会话必须失效", session.isCurrent(old))
        assertTrue("新会话必须是当前会话", session.isCurrent(new))
        assertFalse("旧会话的陈旧抬手不得执行动作", session.canDispatchAction(old, menuOpen = true))
        assertTrue("新会话正常派发", session.canDispatchAction(new, menuOpen = true))
    }

    @Test
    fun `invalidate（detach 场景）推进会话号并关闭交互`() {
        val session = MenuInteractionSession()
        val id = session.beginOpen()
        session.invalidate()
        assertFalse(session.isCurrent(id))
        assertFalse(session.touchAllowed())
    }

    // --- 3. 陈旧的动画结束回调 -----------------------------------------------

    @Test
    fun `关闭后陈旧的动画结束回调不得被应用（不恢复交互或几何）`() {
        val session = MenuInteractionSession()
        val id = session.beginOpen()

        // 关闭被接受前：closing 状态下的收起动画结束回调应当被应用。
        assertTrue(
            MenuCallbackPolicy.shouldApplyAnimationFinished(id, session.sessionId, OverlayMenuState.closing),
        )

        // 关闭已经终结（closed）：任何动画结束回调都必须被忽略。
        assertFalse(
            "菜单已 closed 时旧回调必须被忽略",
            MenuCallbackPolicy.shouldApplyAnimationFinished(id, session.sessionId, OverlayMenuState.closed),
        )

        // 会话过期（关掉又重开）：旧回调同样被忽略。
        session.acceptClose()
        val new = session.beginOpen()
        assertFalse(
            "陈旧会话的回调必须被忽略",
            MenuCallbackPolicy.shouldApplyAnimationFinished(id, session.sessionId, OverlayMenuState.open),
        )
        assertTrue(MenuCallbackPolicy.shouldApplyAnimationFinished(new, session.sessionId, OverlayMenuState.opening))
    }

    // --- 4. 延迟摘层闸门：正常消费一次 / 异常强制释放 -------------------------

    @Test
    fun `转发拖动进行中关闭请求被挂起，手势结束后恰好消费一次`() {
        val gate = OverlayDetachDeferral()
        gate.beginForwardedDrag()
        assertFalse("转发拖动进行中不得立即摘层", gate.requestDetach("function-key-close"))
        assertTrue(gate.hasPending)

        gate.endForwardedDrag()
        assertEquals("function-key-close", gate.consumePendingDetach())
        assertNull("只能消费一次", gate.consumePendingDetach())
        assertFalse(gate.hasPending)
    }

    @Test
    fun `终止事件缺失时 forceRelease 无条件清掉闸门（缺陷 1 兜底）`() {
        val gate = OverlayDetachDeferral()
        gate.beginForwardedDrag()
        assertFalse(gate.requestDetach("function-key-close"))
        assertTrue("还没释放时仍在转发拖动", gate.isForwardedDragActive)

        // 模拟"终止事件永远没到"：兜底强制释放。
        assertEquals("function-key-close", gate.forceRelease())
        assertFalse(gate.isForwardedDragActive)
        assertFalse(gate.hasPending)
        // 释放后新的摘层请求立即生效。
        assertTrue(gate.requestDetach("after-force-release"))
    }

    // --- 5. 关闭终结：窗口缩回人物矩形，人物屏幕矩形不变 ----------------------

    @Test
    fun `关闭终结后窗口缩回人物矩形，且人物屏幕矩形不变`() {
        val pet = OverlayRect(300, 500, 462, 662)
        val menu = OverlayRect(600, 300, 1100, 800)

        // 打开：窗口 = 人物 ∪ 菜单。
        val opened = OverlaySceneSolver.open(pet, menu)
        assertTrue(opened.windowRect.width > pet.width)
        assertEquals("打开不改变人物屏幕矩形", pet, opened.petScreenRect)

        // 转发拖动挂起期间收到关闭请求。
        val gate = OverlayDetachDeferral()
        gate.beginForwardedDrag()
        assertFalse(gate.requestDetach("close"))
        // 终止事件缺失 → 强制释放 → 用释放后的**关态**布局收尾。
        gate.forceRelease()

        // 关态必须把窗口**缩回人物矩形**（零 padding），否则会留下永久触摸遮挡。
        val closed = OverlaySceneSolver.closed(pet)
        assertEquals("关态窗口必须缩回人物矩形", pet, closed.windowRect)
        assertEquals(
            "关态人物层偏移归零",
            OverlayRect(0, 0, pet.width, pet.height),
            closed.petRectInWindow,
        )
        assertEquals(
            "窗口原点 + 人物层偏移 == 人物屏幕矩形",
            pet,
            closed.petRectInWindow.translate(closed.windowRect.left, closed.windowRect.top),
        )
        assertEquals("开关两次的人物屏幕矩形必须完全相同", opened.petScreenRect, closed.petScreenRect)
        assertTrue(closed.assertConsistent())
    }

    // --- 6. 每条关闭路径：菜单层恰好摘一次 + 立即不可交互 + 缩窗恰好一次 -------

    /**
     * 三条关闭路径（正常 close / 转发拖动挂起后消费 / 终止事件缺失强制释放）都必须：
     * * 菜单层**恰好摘下一次**（重复摘除返回 false）；
     * * 关闭被接受的同一帧 `interactive=false`，陈旧抬手不得派发动作；
     * * **恰好产生一次**窗口几何提交（窗口缩回人物矩形，零 padding）。
     */
    @Test
    fun `三条关闭路径：菜单层恰好摘一次、interactive=false、且窗口缩回人物矩形一次`() {
        val pet = OverlayRect(300, 500, 462, 662)
        val menu = OverlayRect(600, 300, 1100, 800)

        listOf("normal", "deferred", "force-release").forEach { path ->
            val epoch = OverlaySceneEpoch()
            epoch.commit(pet, menu)
            epoch.markMenuLayerAttached()
            val session = MenuInteractionSession()
            val id = session.beginOpen()
            assertTrue(session.canDispatchAction(id, menuOpen = true))
            val gate = OverlayDetachDeferral()

            val detachApplied = when (path) {
                "normal" -> {
                    session.acceptClose()
                    gate.requestDetach(path)
                    epoch.markMenuLayerDetached()
                }
                "deferred" -> {
                    gate.beginForwardedDrag()
                    session.acceptClose()
                    assertFalse("转发拖动进行中必须挂起", gate.requestDetach(path))
                    gate.endForwardedDrag()
                    gate.consumePendingDetach()
                    epoch.markMenuLayerDetached()
                }
                else -> {
                    gate.beginForwardedDrag()
                    session.acceptClose()
                    assertFalse(gate.requestDetach(path))
                    gate.forceRelease()
                    epoch.markMenuLayerDetached()
                }
            }

            assertTrue("$path：必须真的摘下菜单层", detachApplied)
            assertFalse("$path：关闭后不得再允许交互", session.interactive)
            assertFalse("$path：关闭后陈旧抬手不得派发动作", session.canDispatchAction(id, menuOpen = true))
            assertFalse("$path：摘层后 epoch 必须认为未挂载", epoch.menuLayerAttached)
            assertFalse("$path：重复摘除必须被拒绝（恰好一次）", epoch.markMenuLayerDetached())

            // 关菜单 = 一次"窗口缩回人物矩形"的几何提交（manager 唯一提交点）。
            val commitsBeforeClose = epoch.commitCount
            val closedLayout = epoch.closedLayout()!!
            epoch.noteWindowCommitted()
            assertEquals("$path：关闭路径恰好产生一次窗口提交", commitsBeforeClose + 1, epoch.commitCount)
            assertEquals("$path：关态窗口必须缩回人物矩形（零 padding）", pet, closedLayout.windowRect)
            assertTrue(closedLayout.assertConsistent())
        }
    }
}

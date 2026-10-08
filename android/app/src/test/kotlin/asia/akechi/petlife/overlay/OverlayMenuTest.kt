package asia.akechi.petlife.overlay

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 菜单**窗口级**状态机（纯函数）—— 覆盖需求 §18.2 中"状态层面"的部分。
 *
 * 轮盘内部的分层 / 滑选 / 动画由 `WheelMenuTest` 系列覆盖；
 * 这里只钉住"窗口几何：展开一次、关闭一次"这条不变式。
 */
class OverlayMenuStateMachineTest {

    @Test
    fun `单击打开菜单：closed 变成 opening`() {
        assertEquals(
            OverlayMenuState.opening,
            OverlayMenuStateMachine.next(OverlayMenuState.closed, OverlayMenuEvent.requestToggle),
        )
    }

    @Test
    fun `再次单击关闭菜单：open 变成 closing`() {
        assertEquals(
            OverlayMenuState.closing,
            OverlayMenuStateMachine.next(OverlayMenuState.open, OverlayMenuEvent.requestToggle),
        )
    }

    @Test
    fun `快速连续单击不会产生第二套菜单（已打开时重复 open 是幂等）`() {
        var state = OverlayMenuState.closed
        repeat(20) {
            state = OverlayMenuStateMachine.next(state, OverlayMenuEvent.requestToggle)
        }
        assertTrue(state == OverlayMenuState.closed || state == OverlayMenuState.closing)
        assertEquals(
            OverlayMenuState.open,
            OverlayMenuStateMachine.next(OverlayMenuState.open, OverlayMenuEvent.requestOpen),
        )
        assertEquals(
            OverlayMenuState.opening,
            OverlayMenuStateMachine.next(OverlayMenuState.opening, OverlayMenuEvent.requestOpen),
        )
    }

    @Test
    fun `打开动画结束进入 open，关闭动画结束进入 closed`() {
        assertEquals(
            OverlayMenuState.open,
            OverlayMenuStateMachine.next(OverlayMenuState.opening, OverlayMenuEvent.animationFinished),
        )
        assertEquals(
            OverlayMenuState.closed,
            OverlayMenuStateMachine.next(OverlayMenuState.closing, OverlayMenuEvent.animationFinished),
        )
    }

    @Test
    fun `打开过程中请求关闭会反向，关闭过程中请求打开会收敛`() {
        assertEquals(
            OverlayMenuState.closing,
            OverlayMenuStateMachine.next(OverlayMenuState.opening, OverlayMenuEvent.requestClose),
        )
        assertEquals(
            OverlayMenuState.opening,
            OverlayMenuStateMachine.next(OverlayMenuState.closing, OverlayMenuEvent.requestOpen),
        )
    }

    @Test
    fun `动画被取消后状态确定：opening 收敛到 open，closing 收敛到 closed`() {
        assertEquals(
            OverlayMenuState.open,
            OverlayMenuStateMachine.next(
                OverlayMenuState.opening,
                OverlayMenuEvent.animationCancelled,
            ),
        )
        assertEquals(
            OverlayMenuState.closed,
            OverlayMenuStateMachine.next(
                OverlayMenuState.closing,
                OverlayMenuEvent.animationCancelled,
            ),
        )
    }

    @Test
    fun `隐藏、停止、配置变化、素材变化、大小变化都立即关闭菜单`() {
        for (from in OverlayMenuState.entries) {
            assertEquals(
                "从 $from 触发 forceClose 必须到 closed",
                OverlayMenuState.closed,
                OverlayMenuStateMachine.next(from, OverlayMenuEvent.forceClose),
            )
        }
        assertTrue(OverlayMenuStateMachine.isImmediate(OverlayMenuEvent.forceClose))
        assertFalse(OverlayMenuStateMachine.isImmediate(OverlayMenuEvent.requestClose))
    }

    @Test
    fun `重复关闭是幂等的，不报错也不改变状态`() {
        assertEquals(
            OverlayMenuState.closed,
            OverlayMenuStateMachine.next(OverlayMenuState.closed, OverlayMenuEvent.requestClose),
        )
        assertEquals(
            OverlayMenuState.closed,
            OverlayMenuStateMachine.next(OverlayMenuState.closed, OverlayMenuEvent.forceClose),
        )
    }

    @Test
    fun `只有 closed 之外的三个状态占用扩展窗口`() {
        assertFalse(OverlayMenuState.closed.occupiesWindow)
        assertTrue(OverlayMenuState.opening.occupiesWindow)
        assertTrue(OverlayMenuState.open.occupiesWindow)
        assertTrue(OverlayMenuState.closing.occupiesWindow)
    }

    @Test
    fun `两套状态机互不影响（旧实例关闭不会动新实例的菜单）`() {
        val oldState = OverlayMenuStateMachine.next(OverlayMenuState.open, OverlayMenuEvent.forceClose)
        assertEquals(OverlayMenuState.closed, oldState)
        val newState = OverlayMenuStateMachine.next(OverlayMenuState.open, OverlayMenuEvent.animationFinished)
        assertEquals(OverlayMenuState.open, newState)
        assertEquals(
            newState,
            OverlayMenuStateMachine.next(OverlayMenuState.open, OverlayMenuEvent.animationFinished),
        )
    }

    @Test
    fun `窗口更新前置条件：未附着或实例已失效都拒绝更新`() {
        assertTrue(canUpdateMenuWindow(disposed = false, attachedToWindow = true))
        assertFalse("View 脱离后不得再动 WindowManager", canUpdateMenuWindow(false, false))
        assertFalse("实例已失效后不得再动 WindowManager", canUpdateMenuWindow(true, true))
        assertFalse(canUpdateMenuWindow(true, false))
    }
}

/**
 * 桌宠窗口自己的手势（**与轮盘窗口互斥**的另一条链）。
 *
 * 需求 §12 的"手势所有权一旦确定就不再改变"在这里固化：
 * 拖动与点击互斥、多指一律取消、菜单打开时拖动要先关菜单。
 */
class OverlayMenuGestureTest {

    private fun machine() = OverlayGestureMachine(touchSlopPx = 24, tapTimeoutMs = 300)

    @Test
    fun `单击桌宠产生 click（界面据此开关菜单）`() {
        val m = machine()
        m.onDown(100f, 100f, 0L)
        assertEquals(OverlayGestureEffect.click, m.onUp(102f, 100f, 60L))
    }

    @Test
    fun `拖动不打开菜单（只产生 dragStart-drag-dragEnd）`() {
        val m = machine()
        m.onDown(100f, 100f, 0L)
        assertEquals(OverlayGestureEffect.dragStart, m.onMove(300f, 300f, 20L))
        assertEquals(OverlayGestureEffect.drag, m.onMove(320f, 320f, 30L))
        assertEquals("松手必须是 dragEnd，绝不能是 click", OverlayGestureEffect.dragEnd, m.onUp(340f, 340f, 40L))
    }

    @Test
    fun `多指不打开菜单也不会补触发单击`() {
        val m = machine()
        m.onDown(100f, 100f, 0L)
        assertEquals(
            OverlayGestureEffect.cancel,
            m.onDown(120f, 120f, 10L, pointerCount = 2),
        )
        assertEquals(OverlayGestureState.SCALING, m.state)
        assertEquals(
            OverlayGestureEffect.none,
            m.onUp(120f, 120f, 20L, pointerCount = 2),
        )
    }

    @Test
    fun `ACTION_CANCEL 收敛到 IDLE，不会留下半开的菜单请求`() {
        val m = machine()
        m.onDown(100f, 100f, 0L)
        assertEquals(OverlayGestureEffect.cancel, m.onCancel())
        assertEquals(OverlayGestureState.IDLE, m.state)
        assertFalse(m.isMenuOpen())
    }

    @Test
    fun `菜单打开时按下桌宠并移动超过 slop 会进入拖动（实现里先关菜单再拖）`() {
        val m = machine()
        m.onMenuOpened()
        assertEquals(OverlayGestureState.MENU_OPEN, m.state)
        assertTrue(m.isMenuOpen())

        m.onDown(100f, 100f, 0L)
        assertEquals(
            "菜单打开时也必须能拖动（先关菜单，再拖动）",
            OverlayGestureEffect.dragStart,
            m.onMove(300f, 300f, 20L),
        )
        assertEquals(OverlayGestureState.DRAGGING, m.state)
        assertFalse("一旦进入拖动就不再是 MENU_OPEN", m.isMenuOpen())
    }

    @Test
    fun `菜单打开时单击桌宠仍然是 click（用来关闭菜单）`() {
        val m = machine()
        m.onMenuOpened()
        m.onDown(100f, 100f, 0L)
        assertEquals(OverlayGestureEffect.click, m.onUp(100f, 100f, 50L))
    }

    @Test
    fun `菜单开关是幂等的：重复 onMenuOpened-onMenuClosed 不产生额外状态`() {
        val m = machine()
        repeat(5) { m.onMenuOpened() }
        assertEquals(OverlayGestureState.MENU_OPEN, m.state)
        repeat(5) { m.onMenuClosed() }
        assertEquals(OverlayGestureState.IDLE, m.state)
    }

    @Test
    fun `隐藏或停止后菜单开关不会再进入 MENU_OPEN`() {
        val hidden = machine()
        hidden.suspend(OverlayGestureState.HIDDEN)
        hidden.onMenuOpened()
        assertEquals(OverlayGestureState.HIDDEN, hidden.state)

        val stopped = machine()
        stopped.suspend(OverlayGestureState.STOPPED)
        stopped.onMenuOpened()
        assertEquals(OverlayGestureState.STOPPED, stopped.state)
    }

    @Test
    fun `窗口未附着时拒绝进入拖动（也就不会去扩展菜单窗口）`() {
        val m = machine()
        m.windowUpdatable = false
        m.onMenuOpened()
        m.onDown(100f, 100f, 0L)
        assertEquals(OverlayGestureEffect.none, m.onMove(500f, 500f, 20L))
        assertEquals(OverlayGestureState.PRESSING, m.state)
    }
}

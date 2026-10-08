package asia.akechi.petlife.overlay

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Phase 4C-3A：手势状态机的**纯逻辑**测试。
 *
 * 覆盖需求"五、Phase 4C-3A 测试"的第 9~12 条：
 * touchSlop 以内是点击、超过是拖动、拖动后松手不触发点击、窗口未附着时不拖动；
 * 另外覆盖 `ACTION_CANCEL` 与多指介入的清理（需求"三、第 4~6 条"）。
 *
 * 这里用**注入的 touchSlop**（而不是真机 `getScaledTouchSlop()`），
 * 正好证明"阈值没有写死"。
 */
class OverlayGestureTest {

    private val slop = 24
    private fun machine() = OverlayGestureMachine(touchSlopPx = slop, tapTimeoutMs = 300)

    // --- 9：touchSlop 以内判定为点击 -----------------------------------------

    @Test
    fun `移动未超过 touchSlop 且时间够短 → 判定为单击`() {
        val m = machine()
        assertEquals(OverlayGestureEffect.press, m.onDown(100f, 100f, 0L))
        assertEquals(OverlayGestureState.PRESSING, m.state)

        // 14.1px < 24px
        assertEquals(OverlayGestureEffect.none, m.onMove(110f, 110f, 10L))
        assertEquals(OverlayGestureState.PRESSING, m.state)

        assertEquals(OverlayGestureEffect.click, m.onUp(110f, 110f, 50L))
        assertEquals(OverlayGestureState.IDLE, m.state)
    }

    @Test
    fun `原地按下再抬起也是单击`() {
        val m = machine()
        m.onDown(500f, 900f, 0L)
        assertEquals(OverlayGestureEffect.click, m.onUp(500f, 900f, 120L))
    }

    @Test
    fun `按下时间过长不算单击（长按本阶段不定义功能）`() {
        val m = machine()
        m.onDown(100f, 100f, 0L)
        assertEquals(OverlayGestureEffect.cancel, m.onUp(100f, 100f, 5_000L))
    }

    // --- 10：超过 touchSlop 判定为拖动 ---------------------------------------

    @Test
    fun `移动超过 touchSlop 进入拖动，并持续给出 drag 事件`() {
        val m = machine()
        assertEquals(OverlayGestureEffect.press, m.onDown(100f, 100f, 0L))

        // 位移 141px > 24px
        assertEquals(OverlayGestureEffect.dragStart, m.onMove(200f, 200f, 20L))
        assertEquals(OverlayGestureState.DRAGGING, m.state)
        assertTrue(m.isDragging())

        assertEquals(OverlayGestureEffect.drag, m.onMove(210f, 210f, 30L))
        assertEquals(OverlayGestureEffect.drag, m.onMove(220f, 220f, 40L))
    }

    @Test
    fun `touchSlop 边界：正好等于阈值不算拖动，超过才拖动`() {
        val m = machine()
        m.onDown(0f, 0f, 0L)
        // 正好 24px：不算超过
        assertEquals(OverlayGestureEffect.none, m.onMove(slop.toFloat(), 0f, 10L))
        assertEquals(OverlayGestureState.PRESSING, m.state)
        // 25px：超过
        assertEquals(OverlayGestureEffect.dragStart, m.onMove(slop + 1f, 0f, 20L))
        assertEquals(OverlayGestureState.DRAGGING, m.state)
    }

    // --- 11：拖动后松手不触发点击 --------------------------------------------

    @Test
    fun `拖动之后松开只结束拖动，绝不触发单击`() {
        val m = machine()
        m.onDown(100f, 100f, 0L)
        m.onMove(300f, 300f, 20L)
        // 松手位置又回到按下点附近，但**曾经**拖过 → 依然不能算单击
        val effect = m.onUp(105f, 105f, 60L)
        assertEquals(OverlayGestureEffect.dragEnd, effect)
        assertEquals(OverlayGestureState.IDLE, m.state)
        assertFalse(m.isDragging())
    }

    // --- 12：窗口未附着时不拖动 ----------------------------------------------

    @Test
    fun `窗口未附着时不允许进入拖动（也就不会去调 updateViewLayout）`() {
        val m = machine()
        m.windowUpdatable = false
        assertEquals(OverlayGestureEffect.press, m.onDown(100f, 100f, 0L))
        assertEquals(OverlayGestureEffect.none, m.onMove(500f, 500f, 20L))
        assertEquals("必须停在 PRESSING，不得进入 DRAGGING", OverlayGestureState.PRESSING, m.state)
        assertFalse(m.isDragging())
        // 松手时因为已经"移动超过 slop"，既不是拖动也不是单击 → 取消
        assertEquals(OverlayGestureEffect.cancel, m.onUp(500f, 500f, 40L))
    }

    // --- ACTION_CANCEL ------------------------------------------------------

    @Test
    fun `ACTION_CANCEL 从按下态和拖动态都能干净回到 IDLE`() {
        val pressed = machine()
        pressed.onDown(10f, 10f, 0L)
        assertEquals(OverlayGestureEffect.cancel, pressed.onCancel())
        assertEquals(OverlayGestureState.IDLE, pressed.state)

        val dragged = machine()
        dragged.onDown(10f, 10f, 0L)
        dragged.onMove(200f, 200f, 10L)
        assertEquals(OverlayGestureEffect.cancel, dragged.onCancel())
        assertEquals(OverlayGestureState.IDLE, dragged.state)
        assertFalse(dragged.isDragging())

        // 已经空闲时再取消：什么也不做
        assertEquals(OverlayGestureEffect.none, dragged.onCancel())
    }

    // --- 多指介入 -----------------------------------------------------------

    @Test
    fun `第二根手指落下会取消拖动，且不产生点击`() {
        val m = machine()
        m.onDown(100f, 100f, 0L)
        m.onMove(300f, 300f, 10L)
        assertEquals(OverlayGestureEffect.cancel, m.onDown(300f, 300f, 20L, pointerCount = 2))
        assertEquals(OverlayGestureState.SCALING, m.state)
        // 缩放态下移动不拖动
        assertEquals(OverlayGestureEffect.none, m.onMove(320f, 320f, 30L, pointerCount = 2))
    }

    @Test
    fun `缩放态下抬起不会触发单击`() {
        val m = machine()
        m.onDown(100f, 100f, 0L)
        m.onDown(120f, 120f, 10L, pointerCount = 2)
        assertEquals(OverlayGestureState.SCALING, m.state)
        assertEquals(
            OverlayGestureEffect.none,
            m.onUp(120f, 120f, 20L, pointerCount = 2),
        )
    }

    // --- 生命周期：隐藏 / 停止 ----------------------------------------------

    @Test
    fun `窗口隐藏或服务停止后不再接受任何手势`() {
        val hidden = machine()
        hidden.onDown(10f, 10f, 0L)
        hidden.suspend(OverlayGestureState.HIDDEN)
        assertEquals(OverlayGestureState.HIDDEN, hidden.state)
        assertEquals(OverlayGestureEffect.none, hidden.onDown(10f, 10f, 20L))
        assertEquals(OverlayGestureState.HIDDEN, hidden.state)

        val stopped = machine()
        stopped.suspend(OverlayGestureState.STOPPED)
        assertEquals(OverlayGestureState.STOPPED, stopped.state)
        assertEquals(OverlayGestureEffect.none, stopped.onMove(500f, 500f, 10L))
        assertEquals(OverlayGestureState.STOPPED, stopped.state)
    }

    @Test
    fun `suspend 只接受 HIDDEN 或 STOPPED`() {
        val m = machine()
        var threw = false
        try {
            m.suspend(OverlayGestureState.IDLE)
        } catch (e: IllegalArgumentException) {
            threw = true
        }
        assertTrue("suspend(IDLE) 必须被拒绝，避免误用", threw)
    }

    @Test
    fun `touchSlop 非法（0 或负数）时退化为 1，任何移动都算拖动而不是崩溃`() {
        val m = OverlayGestureMachine(touchSlopPx = 0, tapTimeoutMs = 300)
        m.onDown(100f, 100f, 0L)
        // 位移 2px > 1px（退化后的阈值）
        assertEquals(OverlayGestureEffect.dragStart, m.onMove(102f, 100f, 10L))
        assertEquals(OverlayGestureState.DRAGGING, m.state)
    }

    // =======================================================================
    // 缺陷 2：拖动跟踪器（屏幕坐标 + 抓取偏移 + 指针锁定 + 越界不丢）
    // =======================================================================

    private fun tracker() = OverlayDragTracker()

    private val wideBounds = OverlayBounds(0, 0, 2_000, 2_000)

    @Test
    fun `改变窗口原点不改变抓取偏移：桌宠目标只跟手指走`() {
        val t = tracker()
        // DOWN：桌宠屏幕左上角 (100,100)，手指屏幕 (150,150) ⇒ grabOffset = (50,50)
        t.begin(pointerId = 0, fingerX = 150f, fingerY = 150f, petOriginX = 100, petOriginY = 100)
        assertEquals(50f, t.grabOffsetX, 0.001f)
        assertEquals(50f, t.grabOffsetY, 0.001f)

        // 手指移到 (250,250) ⇒ 目标 (200,200)（与窗口此刻在哪无关）
        assertArrayEquals(intArrayOf(200, 200), t.update(0, 250f, 250f, wideBounds, 200, 200))
        // 窗口已经跟着移到 (200,200) 了；手指再移到 (350,450) ⇒ 目标仍是 finger - grabOffset
        assertArrayEquals(intArrayOf(300, 400), t.update(0, 350f, 450f, wideBounds, 200, 200))
        // 换个"窗口原点"重放同样的手指轨迹，目标完全一致（证明不依赖窗口原点）
        val t2 = tracker()
        t2.begin(pointerId = 0, fingerX = 150f, fingerY = 150f, petOriginX = 100, petOriginY = 100)
        assertArrayEquals(intArrayOf(300, 400), t2.update(0, 350f, 450f, wideBounds, 200, 200))
    }

    @Test
    fun `快速大幅移动与越界都保持拖动存活，手指回到范围内立刻继续跟随`() {
        val t = tracker()
        t.begin(0, fingerX = 100f, fingerY = 100f, petOriginX = 50, petOriginY = 50)
        val bounds = OverlayBounds(0, 0, 1_000, 1_000)
        // 手指飞出屏幕右下角 ⇒ 目标被夹到 (1000-200, 1000-200) = (800,800)
        assertArrayEquals(intArrayOf(800, 800), t.update(0, 5_000f, 5_000f, bounds, 200, 200))
        assertTrue("越界不得结束拖动", t.isActive)
        // 手指回到 (400,400) ⇒ 目标 (350,350)，立刻继续跟随
        assertArrayEquals(intArrayOf(350, 350), t.update(0, 400f, 400f, bounds, 200, 200))
        assertTrue(t.isActive)
    }

    @Test
    fun `最新目标获胜，UP 用最后手指位置结算`() {
        val t = tracker()
        // 手指按住桌宠左上角 ⇒ grabOffset = (0,0)，目标 == 手指位置，便于断言
        t.begin(0, fingerX = 0f, fingerY = 0f, petOriginX = 0, petOriginY = 0)
        t.update(0, 200f, 200f, wideBounds, 200, 200)
        // 最后一次记录的手指位置是 (260,300)
        t.update(0, 260f, 300f, wideBounds, 200, 200)
        // UP 必须按"最后已知手指位置"结算，而不是按下点 / 中途旧值
        assertArrayEquals(intArrayOf(260, 300), t.end(0, wideBounds, 200, 200))
        assertFalse(t.isActive)
        // 手势结束后再喂 MOVE 一律无效
        assertNull(t.update(0, 900f, 900f, wideBounds, 200, 200))
    }

    @Test
    fun `CANCEL 收敛：手势结束、保留最后有效位置、不再响应任何输入`() {
        val t = tracker()
        t.begin(0, fingerX = 0f, fingerY = 0f, petOriginX = 0, petOriginY = 0)
        t.update(0, 200f, 200f, wideBounds, 200, 200)
        assertArrayEquals(intArrayOf(200, 200), t.cancel())
        assertFalse(t.isActive)
        // 最后有效位置被保留（供"保留最后位置"落盘用）
        assertArrayEquals(intArrayOf(200, 200), t.lastTarget())
        assertNull(t.update(0, 900f, 900f, wideBounds, 200, 200))
    }

    @Test
    fun `CANCEL 一个从未移动过的手势返回 null`() {
        val t = tracker()
        t.begin(0, fingerX = 10f, fingerY = 10f, petOriginX = 0, petOriginY = 0)
        assertNull(t.cancel())
        assertNull(t.lastTarget())
    }

    @Test
    fun `多指：第二根手指不抢占拖动（非锁定指针被一律忽略）`() {
        val t = tracker()
        t.begin(pointerId = 7, fingerX = 0f, fingerY = 0f, petOriginX = 0, petOriginY = 0)
        // 第二根手指的 MOVE 必须被忽略，且不改变锁定指针
        assertNull(t.update(9, 500f, 500f, wideBounds, 200, 200))
        assertTrue(t.isActive)
        assertEquals(7, t.activePointerId)
        // 锁定指针自己的 MOVE 仍生效
        assertArrayEquals(intArrayOf(120, 120), t.update(7, 120f, 120f, wideBounds, 200, 200))
        // 非锁定指针抬手不结束手势
        assertNull(t.end(9, wideBounds, 200, 200))
        assertTrue("第二根手指抬起不得结束拖动", t.isActive)
        // 锁定指针抬手才干净结束
        assertArrayEquals(intArrayOf(120, 120), t.end(7, wideBounds, 200, 200))
        assertFalse(t.isActive)
    }

    // =======================================================================
    // 缺陷 2-5：转发拖动期间的菜单摘除延迟
    // =======================================================================

    @Test
    fun `转发拖动进行中不摘菜单层，手势结束后恰好摘一次`() {
        val g = OverlayDetachDeferral()
        g.beginForwardedDrag()
        // 拖动进行中的摘除请求被挂起（返回 false）
        assertFalse("转发拖动进行中不得立即摘除菜单层", g.requestDetach("a"))
        assertTrue(g.hasPending)
        // 后续请求不覆盖第一个原因
        assertFalse(g.requestDetach("b"))
        // 手势结束前一直挂起
        g.endForwardedDrag()
        assertEquals("a", g.consumePendingDetach())
        assertNull("只能消费一次", g.consumePendingDetach())
        assertFalse(g.hasPending)
    }

    @Test
    fun `非拖动状态下的摘除请求立即执行，reset 清空挂起项`() {
        val g = OverlayDetachDeferral()
        assertTrue(g.requestDetach("idle"))
        g.beginForwardedDrag()
        assertFalse(g.requestDetach("hold"))
        g.reset()
        assertFalse(g.isForwardedDragActive)
        assertFalse(g.hasPending)
        assertTrue(g.requestDetach("after-reset"))
    }
}

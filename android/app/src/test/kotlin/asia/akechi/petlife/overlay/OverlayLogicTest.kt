package asia.akechi.petlife.overlay

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 悬浮桌宠的**纯逻辑**单元测试（Phase 4C-1）。
 *
 * 这里刻意只测不依赖 Context / WindowManager 实例的部分：
 * 状态机幂等、窗口类型与标志、坐标与缩放换算。
 * 需要真机能力的东西（addView、拖动、动画）**不在这里假装通过** ——
 * 它们属于仪器测试与人工验收（见 docs/35）。
 */
class OverlayStateMachineTest {

    private val stopped = OverlayState.stopped

    @Test
    fun `start 幂等：连续两次结果相同`() {
        val once = OverlayStateMachine.next(stopped, OverlayCommand.START)
        val twice = OverlayStateMachine.next(once, OverlayCommand.START)
        assertEquals(once, twice)
        assertTrue(once.running)
        assertFalse(once.hidden)
        assertTrue(once.windowVisible)
    }

    @Test
    fun `show 与 start 等价，重复调用不会产生第二种状态`() {
        val start = OverlayStateMachine.next(stopped, OverlayCommand.START)
        val show = OverlayStateMachine.next(start, OverlayCommand.SHOW)
        assertEquals(start, show)
    }

    @Test
    fun `hide 不停止服务：running 仍为 true 但窗口不可见`() {
        val running = OverlayStateMachine.next(stopped, OverlayCommand.START)
        val hidden = OverlayStateMachine.next(running, OverlayCommand.HIDE)
        assertTrue(hidden.running)
        assertTrue(hidden.hidden)
        assertFalse(hidden.windowVisible)
        // 隐藏后再隐藏仍然稳定
        assertEquals(hidden, OverlayStateMachine.next(hidden, OverlayCommand.HIDE))
    }

    @Test
    fun `hide 在服务未运行时不会把服务凭空拉起来`() {
        assertEquals(stopped, OverlayStateMachine.next(stopped, OverlayCommand.HIDE))
    }

    @Test
    fun `show 能把隐藏状态的窗口恢复出来`() {
        val running = OverlayStateMachine.next(stopped, OverlayCommand.START)
        val hidden = OverlayStateMachine.next(running, OverlayCommand.HIDE)
        val restored = OverlayStateMachine.next(hidden, OverlayCommand.SHOW)
        assertEquals(running, restored)
        assertTrue(restored.windowVisible)
    }

    @Test
    fun `toggle 在运行中来回切换且不改变 running`() {
        val running = OverlayStateMachine.next(stopped, OverlayCommand.START)
        val hidden = OverlayStateMachine.next(running, OverlayCommand.TOGGLE)
        assertTrue(hidden.running)
        assertTrue(hidden.hidden)
        assertEquals(running, OverlayStateMachine.next(hidden, OverlayCommand.TOGGLE))
    }

    @Test
    fun `toggle 在未运行时等价于显示`() {
        val shown = OverlayStateMachine.next(stopped, OverlayCommand.TOGGLE)
        assertTrue(shown.running)
        assertFalse(shown.hidden)
    }

    @Test
    fun `stop 幂等：连续两次都是停止且窗口不可见`() {
        val running = OverlayStateMachine.next(stopped, OverlayCommand.START)
        val once = OverlayStateMachine.next(running, OverlayCommand.STOP)
        val twice = OverlayStateMachine.next(once, OverlayCommand.STOP)
        assertEquals(OverlayState.stopped, once)
        assertEquals(once, twice)
        assertFalse(once.windowVisible)
    }

    @Test
    fun `update 不改变运行与隐藏状态`() {
        assertEquals(stopped, OverlayStateMachine.next(stopped, OverlayCommand.UPDATE))
        val hidden = OverlayState(running = true, hidden = true)
        assertEquals(hidden, OverlayStateMachine.next(hidden, OverlayCommand.UPDATE))
        val running = OverlayState(running = true, hidden = false)
        assertEquals(running, OverlayStateMachine.next(running, OverlayCommand.UPDATE))
    }

    @Test
    fun `未知指令不改变状态`() {
        val running = OverlayState(running = true, hidden = false)
        assertEquals(running, OverlayStateMachine.next(running, OverlayCommand.UNKNOWN))
    }

    @Test
    fun `指令解析：空值视为 start，未知字符串视为 unknown`() {
        assertEquals(OverlayCommand.START, OverlayCommand.fromWire(null))
        assertEquals(OverlayCommand.START, OverlayCommand.fromWire(""))
        assertEquals(OverlayCommand.HIDE, OverlayCommand.fromWire("hide"))
        assertEquals(OverlayCommand.UPDATE, OverlayCommand.fromWire("update"))
        assertEquals(OverlayCommand.UNKNOWN, OverlayCommand.fromWire("drop-table"))
    }
}

class OverlayWindowSpecTest {

    @Test
    fun `API 26 及以上两种窗口都用 TYPE_APPLICATION_OVERLAY`() {
        assertEquals(2038, OverlayWindowSpec.petWindowType(26))
        assertEquals(2038, OverlayWindowSpec.petWindowType(36))
        // 4C-6B-1.1 真机回归：菜单用低层级类型会直接不显示，因此必须同类型
        assertEquals(2038, OverlayWindowSpec.menuWindowType(26))
        assertEquals(2038, OverlayWindowSpec.menuWindowType(36))
    }

    @Test
    fun `API 24-25 沿用已验收的 TYPE_PHONE`() {
        assertEquals(2002, OverlayWindowSpec.petWindowType(24))
        assertEquals(2002, OverlayWindowSpec.petWindowType(25))
        assertEquals(2002, OverlayWindowSpec.menuWindowType(24))
        assertEquals(2002, OverlayWindowSpec.menuWindowType(25))
    }

    /**
     * 层级方案：**同类型 + 菜单后 addView**（不靠遗留窗口类型）。
     *
     * 真机回归教训：用 `TYPE_SYSTEM_ALERT` 造层级会导致菜单完全不显示。
     */
    @Test
    fun `两种窗口类型必须完全相同`() {
        for (sdk in intArrayOf(24, 25, 26, 30, 36)) {
            assertEquals(
                "sdk=$sdk 时菜单与桌宠必须是同一窗口类型",
                OverlayWindowSpec.petWindowType(sdk),
                OverlayWindowSpec.menuWindowType(sdk),
            )
        }
    }

    @Test
    fun `基础标志包含不抢焦点与不吃掉窗口外触摸`() {
        val flags = OverlayWindowSpec.windowFlags(touchThrough = false)
        assertTrue("必须不抢焦点", (flags and 8) != 0)          // FLAG_NOT_FOCUSABLE
        assertTrue("窗口外触摸要传给下层", (flags and 32) != 0)   // FLAG_NOT_TOUCH_MODAL
        assertTrue("允许贴边", (flags and 512) != 0)             // FLAG_LAYOUT_NO_LIMITS
    }

    @Test
    fun `默认不启用触摸穿透，只有显式开启才加 FLAG_NOT_TOUCHABLE`() {
        val interactive = OverlayWindowSpec.windowFlags(touchThrough = false)
        val through = OverlayWindowSpec.windowFlags(touchThrough = true)
        assertEquals(0, interactive and 16)                    // 未开启时没有 NOT_TOUCHABLE
        assertNotEquals(0, through and 16)
    }
}

class OverlayGeometryTest {

    @Test
    fun `缩放被限制在 50%-200%`() {
        assertEquals(0.5f, OverlayGeometry.clampScale(0.1f))
        assertEquals(1.0f, OverlayGeometry.clampScale(1.0f))
        assertEquals(2.0f, OverlayGeometry.clampScale(9.0f))
    }

    @Test
    fun `窗口长边不超过屏幕短边（窄屏 200% 也不会比屏幕还大）`() {
        val tiny = OverlayGeometry.viewSizePx(
            scale = 2.0f, density = 3.0f, screenWidth = 320, screenHeight = 480,
        )
        assertTrue("实际是 $tiny", tiny <= 320)

        val normal = OverlayGeometry.viewSizePx(
            scale = 1.0f, density = 2.0f, screenWidth = 1080, screenHeight = 2400,
        )
        assertEquals((96f * 2.0f).toInt(), normal)
    }

    // --- Phase 4C-3A：窗口不再是正方形，按素材宽高比分配 ---------------------

    @Test
    fun `宽高比 1 比 1 时长边就是窗口边长（与 4C-2 行为一致）`() {
        val bounds = OverlayBounds(0, 0, 1080, 2400)
        val size = OverlayPetSize.resolve(scale = 1f, density = 2f, aspectRatio = 1f, bounds = bounds)
        val longEdge = OverlayGeometry.viewSizePx(1f, 2f, 1080, 2400)
        assertEquals(longEdge, size.width)
        assertEquals(longEdge, size.height)
    }

    @Test
    fun `横长素材按宽高比分配，长边保持、短边等比缩小`() {
        val bounds = OverlayBounds(0, 0, 1080, 2400)
        val longEdge = OverlayGeometry.viewSizePx(1f, 2f, 1080, 2400)
        val size = OverlayPetSize.resolve(scale = 1f, density = 2f, aspectRatio = 2f, bounds = bounds)
        assertEquals(longEdge, size.width)
        assertEquals((longEdge / 2.0).toInt(), size.height)
        assertTrue("不得拉伸变形", size.width > size.height)
    }

    @Test
    fun `竖长素材反过来：长边在高度方向`() {
        val bounds = OverlayBounds(0, 0, 1080, 2400)
        val longEdge = OverlayGeometry.viewSizePx(1f, 2f, 1080, 2400)
        val size = OverlayPetSize.resolve(scale = 1f, density = 2f, aspectRatio = 0.5f, bounds = bounds)
        assertEquals(longEdge, size.height)
        assertEquals((longEdge * 0.5).toInt(), size.width)
    }

    @Test
    fun `极端宽高比被夹进区间，且宽高永远大于 0`() {
        val bounds = OverlayBounds(0, 0, 1080, 2400)
        val ultraWide = OverlayPetSize.resolve(1f, 2f, aspectRatio = 1000f, bounds = bounds)
        assertTrue(ultraWide.isValid)
        assertTrue(
            "长宽比必须被夹回来，实际 ${ultraWide.width}x${ultraWide.height}",
            ultraWide.width.toDouble() / ultraWide.height <= OverlayGeometry.MAX_ASPECT + 0.1,
        )

        val ultraTall = OverlayPetSize.resolve(1f, 2f, aspectRatio = 0.001f, bounds = bounds)
        assertTrue(ultraTall.isValid)
        assertTrue(
            "高宽比必须被夹回来，实际 ${ultraTall.width}x${ultraTall.height}",
            ultraTall.height.toDouble() / ultraTall.width <= 1.0 / OverlayGeometry.MIN_ASPECT + 0.1,
        )

        // NaN / 0 / 负数 / Infinity 一律退回 1:1
        for (bad in listOf(Float.NaN, 0f, -3f, Float.POSITIVE_INFINITY)) {
            val size = OverlayPetSize.resolve(1f, 2f, aspectRatio = bad, bounds = bounds)
            assertEquals(size.width, size.height)
            assertTrue(size.isValid)
        }
    }

    @Test
    fun `短边不小于下限：细长素材也会被等比放大而不是压成一条线`() {
        val bounds = OverlayBounds(0, 0, 1080, 2400)
        val density = 3f
        val size = OverlayPetSize.resolve(
            scale = 0.5f, density = density, aspectRatio = 5f, bounds = bounds,
        )
        assertTrue(
            "短边 ${size.height} 必须 >= ${OverlayGeometry.minShortEdgePx(density)}",
            size.height >= OverlayGeometry.minShortEdgePx(density),
        )
        // 仍然保持宽高比（允许取整误差）
        val aspect = size.width.toFloat() / size.height.toFloat()
        assertEquals(5.0, aspect.toDouble(), 0.1)
    }

    @Test
    fun `窗口比可用区域还大时等比缩小到能装下`() {
        // 可用区域只有 200x300，而窗口想涨到 200% × 96dp × density=3 → 576px
        val bounds = OverlayBounds(0, 0, 200, 300)
        val size = OverlayPetSize.resolve(2f, 3f, aspectRatio = 1f, bounds = bounds)
        assertTrue("宽度 ${size.width} 必须 <= 200", size.width <= 200)
        assertTrue("高度 ${size.height} 必须 <= 300", size.height <= 300)
        assertTrue(size.isValid)
    }

    @Test
    fun `可用区域不可信时退化为不做尺寸上限，但仍然大于 0`() {
        val size = OverlayPetSize.resolve(1f, 2f, aspectRatio = 1f, bounds = OverlayBounds.unknown)
        assertTrue(size.isValid)
        assertEquals(OverlayGeometry.viewSizePx(1f, 2f, 0, 0), size.longEdge)
    }
}

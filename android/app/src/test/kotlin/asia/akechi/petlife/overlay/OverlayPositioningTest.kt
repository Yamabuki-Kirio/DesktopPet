package asia.akechi.petlife.overlay

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Phase 4C-3A：位置计算与持久化的**纯逻辑**测试。
 *
 * 覆盖需求"五、Phase 4C-3A 测试"的第 1~8 条：
 * 左右/上下边界限制、桌宠大于可用区域、xRatio/yRatio 往返、
 * 竖屏转横屏恢复、改变大小后的坐标修正、左右侧吸附、非法缩放值。
 *
 * 需要真实 WindowManager / View 的部分（跟手拖动、动画帧）**不在这里假装通过**，
 * 属于真机人工验收（见 docs/35 §9）。
 */
class OverlayPositioningTest {

    /** 典型竖屏：状态栏 60，导航栏 90。 */
    private val portrait = OverlayBounds(left = 0, top = 60, right = 1080, bottom = 2310)

    /** 同设备的横屏：状态栏 60，导航栏在右侧 90。 */
    private val landscape = OverlayBounds(left = 0, top = 60, right = 2310, bottom = 1080)

    private val petW = 200
    private val petH = 200

    // --- 1 / 2：左右、上下边界限制 -------------------------------------------

    @Test
    fun `左右边界限制：拖出左边和右边都会被夹回可用区域`() {
        val farLeft = OverlayPositionCalculator.clampTopLeft(-9999, 500, portrait, petW, petH)
        assertEquals(portrait.left, farLeft[0])

        val farRight = OverlayPositionCalculator.clampTopLeft(99999, 500, portrait, petW, petH)
        assertEquals("右边缘必须正好贴住可用区域右边", portrait.right - petW, farRight[0])
        assertTrue("窗口必须完全在可用区域内", farRight[0] + petW <= portrait.right)
    }

    @Test
    fun `上下边界限制：不会被状态栏压住，也不会被导航栏挡住`() {
        val tooHigh = OverlayPositionCalculator.clampTopLeft(500, -9999, portrait, petW, petH)
        assertEquals("上边界是可用区域的 top（已含状态栏）", portrait.top, tooHigh[1])

        val tooLow = OverlayPositionCalculator.clampTopLeft(500, 99999, portrait, petW, petH)
        assertEquals(portrait.bottom - petH, tooLow[1])
        assertTrue(tooLow[1] + petH <= portrait.bottom)
    }

    // --- 3：桌宠大于可用区域时的降级处理 -------------------------------------

    @Test
    fun `桌宠比可用区域还大时贴左上角降级，不崩也不算出负数`() {
        val tiny = OverlayBounds(left = 0, top = 40, right = 120, bottom = 140)
        val huge = OverlayPositionCalculator.clampTopLeft(
            x = 500, y = 500, bounds = tiny, petWidth = 400, petHeight = 400,
        )
        assertEquals(tiny.left, huge[0])
        assertEquals(tiny.top, huge[1])
        // 退化场景下不再强求"完全可见"，但绝不能是负数（那会让窗口跑到屏幕外）
        assertTrue(huge[0] >= 0)
        assertTrue(huge[1] >= 0)
    }

    @Test
    fun `可用区域不可信时不做限制（绝不把窗口夹到 0 号角落）`() {
        val unknown = OverlayPositionCalculator.clampTopLeft(123, 456, OverlayBounds.unknown, petW, petH)
        assertEquals(123, unknown[0])
        assertEquals(456, unknown[1])
        assertFalse(OverlayBounds.unknown.isUsable)
    }

    // --- 4：相对位置保存与恢复 -----------------------------------------------

    @Test
    fun `xRatio-yRatio 往返可逆（拖动保存的就是它，而不是绝对像素）`() {
        for (xRatio in listOf(0f, 0.25f, 0.5f, 0.75f, 1f)) {
            val topLeft = OverlayPositionCalculator.topLeftFromRatio(
                xRatio = xRatio, yRatio = xRatio,
                bounds = portrait, petWidth = petW, petHeight = petH,
            )
            val back = OverlayPositionCalculator.ratioFromTopLeft(
                x = topLeft[0], y = topLeft[1],
                bounds = portrait, petWidth = petW, petHeight = petH,
            )
            assertEquals(xRatio.toDouble(), back[0].toDouble(), 0.002)
            assertEquals(xRatio.toDouble(), back[1].toDouble(), 0.002)
        }
    }

    @Test
    fun `ratio 为 1 时正好贴住右下边缘（不会有一半挂在屏幕外）`() {
        val topLeft = OverlayPositionCalculator.topLeftFromRatio(
            xRatio = 1f, yRatio = 1f,
            bounds = portrait, petWidth = petW, petHeight = petH,
        )
        assertEquals(portrait.right - petW, topLeft[0])
        assertEquals(portrait.bottom - petH, topLeft[1])
    }

    @Test
    fun `分母用 max-1 保护：桌宠恰好等于可用区域时不会除零`() {
        val exact = OverlayBounds(left = 0, top = 0, right = petW, bottom = petH)
        val ratios = OverlayPositionCalculator.ratioFromTopLeft(0, 0, exact, petW, petH)
        assertFalse("绝不能是 NaN", ratios[0].isNaN())
        assertFalse(ratios[1].isNaN())
        assertEquals(0f, ratios[0])
        assertEquals(0f, ratios[1])
    }

    // --- 5：竖屏转横屏 -------------------------------------------------------

    @Test
    fun `竖屏转横屏后按比例恢复，仍落在可见区域内`() {
        // 竖屏右下角
        val portraitTopLeft = OverlayPositionCalculator.topLeftFromRatio(
            xRatio = 1f, yRatio = 1f,
            bounds = portrait, petWidth = petW, petHeight = petH,
        )
        val ratios = OverlayPositionCalculator.ratioFromTopLeft(
            x = portraitTopLeft[0], y = portraitTopLeft[1],
            bounds = portrait, petWidth = petW, petHeight = petH,
        )
        // 换成横屏的可用区域重算
        val landscapeTopLeft = OverlayPositionCalculator.topLeftFromRatio(
            xRatio = ratios[0], yRatio = ratios[1],
            bounds = landscape, petWidth = petW, petHeight = petH,
        )
        assertTrue(landscapeTopLeft[0] in landscape.left..(landscape.right - petW))
        assertTrue(landscapeTopLeft[1] in landscape.top..(landscape.bottom - petH))
        assertEquals("横屏下仍然贴右边缘", landscape.right - petW, landscapeTopLeft[0])
    }

    // --- 6：改变大小后的坐标修正 ---------------------------------------------

    @Test
    fun `改大之后坐标被修正：贴右边的桌宠不会向屏幕外扩张`() {
        val biggerW = 320
        val biggerH = 320
        // 先算"改大小前"贴右边缘的位置
        val before = OverlayPositionCalculator.topLeftFromRatio(
            xRatio = 1f, yRatio = 0.5f,
            bounds = portrait, petWidth = petW, petHeight = petH,
        )
        assertEquals(portrait.right - petW, before[0])

        // 改大后如果直接沿用旧 x，就会超出右边缘 —— 因此必须重新按边/比例算
        val afterSnap = OverlayPositionCalculator.snapTargetX(
            OverlaySnapEdge.right, portrait, biggerW,
        )
        assertEquals(portrait.right - biggerW, afterSnap)
        assertTrue(afterSnap + biggerW <= portrait.right)

        // 即便走比例路径，也会被 clamp 回可用区域
        val afterRatio = OverlayPositionCalculator.topLeftFromRatio(
            xRatio = 1f, yRatio = 0.5f,
            bounds = portrait, petWidth = biggerW, petHeight = biggerH,
        )
        assertTrue(afterRatio[0] + biggerW <= portrait.right)
    }

    // --- 7：左右侧吸附 -------------------------------------------------------

    @Test
    fun `吸附按中心点分左右：左半吸左、右半吸右`() {
        val availableW = portrait.width
        val centerOfLeftHalf = portrait.left + availableW / 4
        val centerOfRightHalf = portrait.left + availableW * 3 / 4

        assertEquals(OverlaySnapEdge.left, OverlayPositionCalculator.snapEdgeFor(centerOfLeftHalf, portrait))
        assertEquals(OverlaySnapEdge.right, OverlayPositionCalculator.snapEdgeFor(centerOfRightHalf, portrait))

        assertEquals(portrait.left, OverlayPositionCalculator.snapTargetX(OverlaySnapEdge.left, portrait, petW))
        assertEquals(
            portrait.right - petW,
            OverlayPositionCalculator.snapTargetX(OverlaySnapEdge.right, portrait, petW),
        )
    }

    @Test
    fun `可用区域不可信时不做吸附（避免吸到 0 号边缘）`() {
        assertEquals(OverlaySnapEdge.none, OverlayPositionCalculator.snapEdgeFor(10, OverlayBounds.unknown))
    }

    @Test
    fun `centerX 用的是窗口宽度的一半`() {
        assertEquals(100 + 50, OverlayPositionCalculator.centerX(100, 100))
    }

    // --- 8：非法缩放值 -------------------------------------------------------

    @Test
    fun `非法缩放值恢复默认：NaN-Infinity-越界都不会污染配置`() {
        assertEquals(PetOverlayStore.DEFAULT_SCALE, PetOverlayStore.safeScale(Float.NaN))
        assertEquals(PetOverlayStore.DEFAULT_SCALE, PetOverlayStore.safeScale(Float.POSITIVE_INFINITY))
        assertEquals(PetOverlayStore.DEFAULT_SCALE, PetOverlayStore.safeScale(Float.NEGATIVE_INFINITY))
        assertEquals(PetOverlayStore.MIN_SCALE, PetOverlayStore.safeScale(0.01f))
        assertEquals(PetOverlayStore.MAX_SCALE, PetOverlayStore.safeScale(99f))
        assertEquals(1.4f, PetOverlayStore.safeScale(1.4f))
    }

    @Test
    fun `非法相对位置恢复默认值（含 NaN）`() {
        assertEquals(0.85f, PetOverlayStore.safeRatio(Float.NaN, 0.85f))
        assertEquals(0.85f, PetOverlayStore.safeRatio(Float.POSITIVE_INFINITY, 0.85f))
        assertEquals(0f, PetOverlayStore.safeRatio(-5f, 0.85f))
        assertEquals(1f, PetOverlayStore.safeRatio(5f, 0.85f))
        assertEquals(0.3f, PetOverlayStore.safeRatio(0.3f, 0.85f))
    }

    // --- 吸附边的序列化 -----------------------------------------------------

    @Test
    fun `吸附边序列化往返且未知值退化为 none`() {
        for (edge in OverlaySnapEdge.entries) {
            assertEquals(edge, OverlaySnapEdge.fromWire(edge.name))
        }
        assertEquals(OverlaySnapEdge.left, OverlaySnapEdge.fromWire("LEFT"))
        assertEquals(OverlaySnapEdge.none, OverlaySnapEdge.fromWire(null))
        assertEquals(OverlaySnapEdge.none, OverlaySnapEdge.fromWire("bogus"))
    }
}

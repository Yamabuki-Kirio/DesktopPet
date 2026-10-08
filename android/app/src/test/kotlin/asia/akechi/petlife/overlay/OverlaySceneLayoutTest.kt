package asia.akechi.petlife.overlay

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 单窗口场景求解的回归测试。
 *
 * 核心不变式：**菜单开关不改变人物的屏幕矩形**（`windowOrigin + petLocal == petScreen`）。
 * 这条一旦不成立，真机上就表现为"点击桌宠后人物抽动/消失"。
 *
 * 本轮修正（覆盖此前"恒定大窗口"的错误结论）：
 * * 菜单**关闭** → 窗口 == 人物矩形（**零透明 padding**），人物层偏移 (0,0)；
 * * 菜单**打开** → 窗口 == 人物 ∪ 菜单信封，人物层偏移 = 人物屏幕矩形 − 窗口原点。
 *
 * 为什么关态必须缩回人物矩形：平台没有公开 API 能声明"窗口内只有某块区域可触摸"
 * （`ViewTreeObserver.*InternalInsets*` 属 `@hide`，本项目 android.jar 里不存在；反射被禁止），
 * 且 `onTouchEvent` 返回 `false` **不会**把事件派发给下层窗口 —— 大窗口的透明 padding 会永久遮挡。
 * 因此开/关菜单**确实会改变窗口几何**（本轮测试明确断言这一点）。
 */
class OverlaySceneLayoutTest {

    /** 人物屏幕矩形：162×162（非正方形尺寸也必须原样保留）。 */
    private val pet = OverlayRect(left = 300, top = 500, right = 462, bottom = 662)

    // --- (a) 关态 = 人物矩形（零 padding） ---------------------------------

    @Test
    fun `closed：窗口 == 人物矩形（零 padding），人物层偏移为 (0,0)`() {
        val closed = OverlaySceneSolver.closed(pet)

        assertEquals("关态窗口必须严格等于人物屏幕矩形（不再有多余 padding）", pet, closed.windowRect)
        assertEquals(
            "人物层容器内矩形必须为 (0,0)–(人物宽高)",
            OverlayRect(0, 0, pet.width, pet.height),
            closed.petRectInWindow,
        )
        assertNull("菜单关闭时没有菜单层", closed.menuRectInWindow)
        assertEquals(pet, closed.petScreenRect)
        assertFalse(closed.menuOpen)
        assertTrue(closed.assertConsistent())
    }

    // --- (b) 打开态：人物屏幕矩形完全不变 ------------------------------------

    @Test
    fun `open：人物屏幕矩形与输入完全相等`() {
        val menu = OverlayRect(left = 600, top = 300, right = 1100, bottom = 800)
        val scene = OverlaySceneSolver.open(pet, menu)

        assertEquals("人物屏幕矩形必须一个像素都不变", pet, scene.petScreenRect)
        assertEquals("开态窗口必须严格等于 人物 ∪ 菜单（无额外 padding）", pet.union(menu), scene.windowRect)
        assertTrue(scene.menuOpen)
        assertTrue(scene.assertConsistent())
    }

    // --- (c) 开-关-开往返：人物屏幕矩形全程不变，窗口矩形来回切换 -------------

    @Test
    fun `开-关-开往返：窗口矩形在(人物)与(并集)之间切换，人物屏幕矩形始终不变`() {
        val menu = OverlayRect(left = 600, top = 300, right = 1100, bottom = 800)
        val opened1 = OverlaySceneSolver.open(pet, menu)
        val closed = OverlaySceneSolver.closed(pet)
        val opened2 = OverlaySceneSolver.open(pet, menu)

        assertNotEquals("关态窗口必须小于开态窗口（这是有意为之）", closed.windowRect, opened1.windowRect)
        assertEquals("关态窗口 == 人物矩形", pet, closed.windowRect)
        assertEquals("打开①的窗口帧 = 人物 ∪ 菜单", pet.union(menu), opened1.windowRect)
        assertEquals("重新打开的窗口帧与之前完全相同", opened1.windowRect, opened2.windowRect)
        assertEquals("人物层放置必须随窗口状态各自自洽（关态）",
            OverlayRect(0, 0, pet.width, pet.height), closed.petRectInWindow)
        assertEquals("人物屏幕矩形恒定（开①）", pet, opened1.petScreenRect)
        assertEquals("人物屏幕矩形恒定（关）", pet, closed.petScreenRect)
        assertEquals("人物屏幕矩形恒定（开②）", pet, opened2.petScreenRect)
        assertTrue(opened1.assertConsistent())
        assertTrue(closed.assertConsistent())
        assertTrue(opened2.assertConsistent())
    }

    // --- (d) 人物层在容器内的位置 -------------------------------------------

    @Test
    fun `人物层在容器内的位置 = 人物屏幕矩形减窗口原点，且尺寸不变`() {
        val menu = OverlayRect(left = 0, top = 0, right = 1000, bottom = 400)
        val scene = OverlaySceneSolver.open(pet, menu)
        val origin = scene.windowRect

        assertEquals(
            OverlayRect(
                left = pet.left - origin.left,
                top = pet.top - origin.top,
                right = pet.right - origin.left,
                bottom = pet.bottom - origin.top,
            ),
            scene.petRectInWindow,
        )
        assertEquals(pet.width, scene.petRectInWindow.width)
        assertEquals(pet.height, scene.petRectInWindow.height)
    }

    // --- (e) 菜单层在容器内的位置 -------------------------------------------

    @Test
    fun `菜单层在容器内的位置 = 菜单屏幕矩形减窗口原点`() {
        val menu = OverlayRect(left = 0, top = 0, right = 1000, bottom = 400)
        val scene = OverlaySceneSolver.open(pet, menu)
        val origin = scene.windowRect
        val rect = scene.menuRectInWindow!!

        assertEquals(
            OverlayRect(
                left = menu.left - origin.left,
                top = menu.top - origin.top,
                right = menu.right - origin.left,
                bottom = menu.bottom - origin.top,
            ),
            rect,
        )
        assertEquals(menu.width, rect.width)
        assertEquals(menu.height, rect.height)
    }

    // --- (f) 并集：菜单在人物的右/下/左/上四个方向 ---------------------------

    @Test
    fun `并集正确：菜单在人物右侧`() {
        val menu = OverlayRect(left = 500, top = 400, right = 1000, bottom = 900)
        val scene = OverlaySceneSolver.open(pet, menu)

        assertEquals(OverlayRect(300, 400, 1000, 900), scene.windowRect)
        // 窗口左/上边界还是人物的左/上边界 → 人物偏移只可能在 (0,0)
        assertEquals(0, scene.petRectInWindow.left)
        assertEquals(100, scene.petRectInWindow.top)
    }

    @Test
    fun `并集正确：菜单在人物左侧`() {
        val menu = OverlayRect(left = 0, top = 600, right = 200, bottom = 1000)
        val scene = OverlaySceneSolver.open(pet, menu)

        assertEquals(OverlayRect(0, 500, 462, 1000), scene.windowRect)
        assertEquals(300, scene.petRectInWindow.left)
        assertEquals(0, scene.petRectInWindow.top)
    }

    @Test
    fun `并集正确：菜单在人物上方`() {
        val menu = OverlayRect(left = 350, top = 100, right = 700, bottom = 400)
        val scene = OverlaySceneSolver.open(pet, menu)

        assertEquals(OverlayRect(300, 100, 700, 662), scene.windowRect)
        assertEquals(0, scene.petRectInWindow.left)
        assertEquals(400, scene.petRectInWindow.top)
    }

    @Test
    fun `并集正确：菜单在人物下方`() {
        val menu = OverlayRect(left = 350, top = 700, right = 700, bottom = 1100)
        val scene = OverlaySceneSolver.open(pet, menu)

        assertEquals(OverlayRect(300, 500, 700, 1100), scene.windowRect)
        assertEquals(0, scene.petRectInWindow.left)
        assertEquals(0, scene.petRectInWindow.top)
    }

    @Test
    fun `并集正确：菜单完全包住人物（人物在容器正中）`() {
        val menu = OverlayRect(left = 100, top = 200, right = 900, bottom = 1000)
        val scene = OverlaySceneSolver.open(pet, menu)

        assertEquals(menu, scene.windowRect)
        assertEquals(200, scene.petRectInWindow.left)
        assertEquals(300, scene.petRectInWindow.top)
        assertEquals(pet, scene.petScreenRect)
    }

    // --- (g) 往返：窗口原点 + 人物层偏移 == 人物屏幕矩形 ----------------------

    @Test
    fun `往返：窗口原点加人物层偏移仍等于人物屏幕矩形`() {
        val menus = listOf(
            OverlayRect(600, 300, 1100, 800),
            OverlayRect(0, 0, 200, 200),
            OverlayRect(100, 200, 900, 1000),
            OverlayRect(350, 700, 700, 1100),
        )
        menus.forEach { menu ->
            val scene = OverlaySceneSolver.open(pet, menu)
            val origin = scene.windowRect
            val back = scene.petRectInWindow.translate(origin.left, origin.top)
            assertEquals("菜单=$menu 时往返必须还原人物屏幕矩形", pet, back)
            assertTrue(scene.assertConsistent())
        }
    }

    // --- 自检函数本身 -------------------------------------------------------

    @Test
    fun `自检：人为写错的偏移会被判为不一致`() {
        val consistent = OverlaySceneSolver.open(pet, OverlayRect(600, 300, 1100, 800))
        assertTrue(consistent.assertConsistent())

        val broken = consistent.copy(
            petRectInWindow = consistent.petRectInWindow.translate(1, 0),
        )
        assertFalse("人物层偏移被改 1px 必须自检失败", broken.assertConsistent())
    }

    // -----------------------------------------------------------------------
    // 几何纪元（OverlaySceneEpoch，纯 JVM）
    // -----------------------------------------------------------------------

    private val density = 2.75f
    private val spec = WheelMenuSpec.fromDensity(density)
    private val bounds = OverlayBounds(left = 0, top = 60, right = 1080, bottom = 2310)

    private fun petAt(x: Int, y: Int, size: Int = 264): OverlayRect =
        OverlayRect(x, y, x + size, y + size)

    /** 用**锁定模式**算出"就是这个方向 / 这个垂直模式"的信封（参数与 manager 一致）。 */
    private fun envelopeFor(
        pet: OverlayRect,
        direction: WheelExpandDirection,
        vertical: WheelVerticalMode,
        scale: Float = WheelMenuLayoutSettings.DEFAULT_SCALE,
    ): WheelMenuEnvelope = WheelMenuGeometry.computeEnvelope(
        bounds = bounds,
        petWindowRect = pet,
        content = null,
        maxItemCount = WheelMenuCatalog.maxItems,
        spec = spec,
        settings = WheelMenuLayoutSettings.DEFAULT.copy(preferredScale = scale),
        previousDirection = direction,
        previousVerticalMode = vertical,
        lockMode = true,
    )

    @Test
    fun `纪元：关态窗口 == 人物矩形，开态窗口 == 并集（两者不同）`() {
        val pet = petAt(300, 1000)
        val env = envelopeFor(pet, WheelExpandDirection.right, WheelVerticalMode.center)
        val epoch = OverlaySceneEpoch()
        epoch.commit(pet, env.windowRect)

        val closed = epoch.closedLayout()!!
        val open = epoch.openLayout()!!

        assertEquals("关态窗口 == 人物矩形（零 padding）", pet, closed.windowRect)
        assertEquals(
            "关态人物层偏移 (0,0)",
            OverlayRect(0, 0, pet.width, pet.height),
            closed.petRectInWindow,
        )
        assertNull("关闭时没有菜单层", closed.menuRectInWindow)
        assertEquals("开态窗口 == 人物 ∪ 信封", pet.union(env.windowRect), open.windowRect)
        assertNotEquals("开菜单必须改变窗口矩形（有意为之）", closed.windowRect, open.windowRect)
        assertNotNull("开态必须有菜单层矩形", open.menuRectInWindow)
        assertEquals("开态人物屏幕矩形不变", pet, open.petScreenRect)
        assertTrue(closed.assertConsistent())
        assertTrue(open.assertConsistent())
    }

    /**
     * 本轮有意改变的行为：**开菜单与关菜单各自产生一次窗口几何提交**（`commitCount` +1）。
     *
     * 这正是"不再留有永久触摸遮挡"的代价与前提：窗口状态必须真的在"人物矩形 ↔ 并集"之间切换。
     */
    @Test
    fun `纪元：开菜单与关菜单都改变窗口矩形，并各自记一次几何提交`() {
        val pet = petAt(300, 1000)
        val env = envelopeFor(pet, WheelExpandDirection.right, WheelVerticalMode.center)
        val epoch = OverlaySceneEpoch()
        epoch.commit(pet, env.windowRect)
        val before = epoch.commitCount

        // 开菜单：窗口扩成并集 → 记一次提交。
        val open = epoch.openLayout()!!
        epoch.noteWindowCommitted()
        assertEquals("开菜单产生一次窗口提交", before + 1, epoch.commitCount)
        assertEquals(pet.union(env.windowRect), open.windowRect)

        // 关菜单：窗口缩回人物矩形 → 再记一次提交。
        val closed = epoch.closedLayout()!!
        epoch.noteWindowCommitted()
        assertEquals("关菜单再产生一次窗口提交", before + 2, epoch.commitCount)
        assertEquals(pet, closed.windowRect)
    }

    @Test
    fun `纪元：菜单层挂载与摘除恰好一次（幂等）`() {
        val pet = petAt(300, 1000)
        val env = envelopeFor(pet, WheelExpandDirection.right, WheelVerticalMode.center)
        val epoch = OverlaySceneEpoch()
        epoch.commit(pet, env.windowRect)

        assertTrue("第一次挂载必须生效", epoch.markMenuLayerAttached())
        assertFalse("重复挂载必须被拒绝（最多一层）", epoch.markMenuLayerAttached())
        assertEquals(1, epoch.menuLayerAttachCount)
        assertTrue("第一次摘除必须生效", epoch.markMenuLayerDetached())
        assertFalse("重复摘除必须返回 false（绝不可能摘两次）", epoch.markMenuLayerDetached())
        assertFalse(epoch.menuLayerAttached)
    }

    @Test
    fun `纪元：无可用信封时退化为窗口 == 人物，且不能打开菜单`() {
        val pet = petAt(300, 1000)
        val epoch = OverlaySceneEpoch()
        val scene = epoch.commit(pet, null)

        assertEquals("无信封时窗口 == 人物（无 padding）", pet, scene.windowRect)
        assertEquals(OverlayRect(0, 0, pet.width, pet.height), scene.petRectInWindow)
        assertFalse(epoch.hasMenuEnvelope)
        assertNull("没有信封 → 不允许打开菜单", epoch.openLayout())
        assertEquals("关态场景同样 == 人物矩形", pet, epoch.closedLayout()!!.windowRect)
        assertTrue(scene.assertConsistent())
    }

    /** 两个方向 × 三种垂直模式 × 三个位置：菜单矩形都完整落在**打开态窗口**内。 */
    @Test
    fun `菜单矩形在两种方向与三种垂直模式下都完整落在打开态窗口内`() {
        val directions = listOf(WheelExpandDirection.right, WheelExpandDirection.left)
        val verticals = listOf(
            WheelVerticalMode.center,
            WheelVerticalMode.topEdge,
            WheelVerticalMode.bottomEdge,
        )
        val pets = listOf(
            petAt(300, 1000),
            petAt(0, bounds.top),
            petAt(bounds.right - 264, bounds.bottom - 264),
        )
        var cases = 0
        directions.forEach { direction ->
            verticals.forEach { vertical ->
                pets.forEach { pet ->
                    val env = envelopeFor(pet, direction, vertical)
                    val scene = OverlaySceneSolver.open(pet, env.windowRect)
                    val menu = scene.menuRectInWindow!!
                    val inside = menu.left >= 0 && menu.top >= 0 &&
                        menu.left + menu.width <= scene.windowRect.width &&
                        menu.top + menu.height <= scene.windowRect.height
                    assertTrue(
                        "dir=$direction v=$vertical pet=$pet 菜单层级矩形必须落在窗口内：menu=$menu window=${scene.windowRect}",
                        inside,
                    )
                    assertEquals(pet, scene.petScreenRect)
                    assertTrue(scene.assertConsistent())
                    cases += 1
                }
            }
        }
        assertEquals("共 2×3×3 组", 18, cases)
    }

    // -----------------------------------------------------------------------
    // moved：拖动每一帧只平移窗口原点（窗口尺寸 / 人物层偏移 / 菜单层矩形都不变）
    // -----------------------------------------------------------------------

    @Test
    fun `moved 只平移窗口原点，人物层偏移与窗口尺寸保持不变`() {
        val pet = petAt(300, 1000)
        // 关态：人物层偏移 (0,0)，窗口尺寸 = 人物尺寸。
        val local = OverlayRect(0, 0, pet.width, pet.height)
        val windowSize = OverlaySize(pet.width, pet.height)
        val target = pet.translate(120, -80)

        val moved = OverlaySceneSolver.moved(
            petScreenRect = target,
            petRectInWindow = local,
            windowSize = windowSize,
            menuRectInWindow = null,
            menuOpen = false,
        )

        assertEquals("人物层偏移不变", local, moved.petRectInWindow)
        assertEquals("窗口尺寸不变", windowSize.width, moved.windowRect.width)
        assertEquals("窗口尺寸不变", windowSize.height, moved.windowRect.height)
        assertEquals("窗口原点 = 目标人物位置 − 人物层偏移", target.left, moved.windowRect.left)
        assertEquals("窗口原点 = 目标人物位置 − 人物层偏移", target.top, moved.windowRect.top)
        assertEquals("人物屏幕矩形 == 目标", target, moved.petScreenRect)
        assertTrue(moved.assertConsistent())
    }

    @Test
    fun `moved 在菜单打开（窗口更大）时也保持人物层偏移与菜单层矩形不变`() {
        val pet = petAt(300, 1000)
        val menu = OverlayRect(0, 0, 200, 200)
        val open = OverlaySceneSolver.open(pet, menu)
        val local = open.petRectInWindow
        val newPet = pet.translate(50, 80)

        val moved = OverlaySceneSolver.moved(
            petScreenRect = newPet,
            petRectInWindow = local,
            windowSize = OverlaySize(open.windowRect.width, open.windowRect.height),
            menuRectInWindow = open.menuRectInWindow,
            menuOpen = true,
        )

        assertEquals("人物层偏移不变", local, moved.petRectInWindow)
        assertEquals("菜单层矩形不变", open.menuRectInWindow, moved.menuRectInWindow)
        assertEquals("窗口尺寸不变", open.windowRect.width, moved.windowRect.width)
        assertEquals(
            "窗口原点 + 人物层偏移 == 新的人物屏幕矩形",
            newPet,
            moved.petRectInWindow.translate(moved.windowRect.left, moved.windowRect.top),
        )
        assertTrue(moved.assertConsistent())
    }
}

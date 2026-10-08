package asia.akechi.petlife.overlay

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 双窗口悬浮层（Phase 4C-6B-4）的**纯逻辑**回归测试。
 *
 * 只打靶不依赖任何 `android.*` 类型的部分：
 * * [DualWindowWindowLedger]：加序固定、菜单/桌宠各只 add 一次、反复开合只 update；
 * * [DualWindowSceneSpec]：关闭态 = 不可触摸 + 1×1 + 角落 + 内容 GONE；打开态 = 传入矩形；
 * * [DualWindowMenuPlanner]：菜单矩形据桌宠**当前**矩形重算（镜像 + 垂直偏置保留）；
 * * [DualWindowScene]：菜单开合/跟随**绝不**改变桌宠窗几何；
 * * [DualWindowModeResolver]：失败回退单窗口。
 *
 * 真机窗口层（addView / updateViewLayout、z-order、触摸归属）**不在这里假装通过** ——
 * 那必须由操作者在真机上按报告里的步骤验证。
 */
class DualWindowMenuSceneTest {

    private val density = 2.75f
    private val bounds = OverlayBounds(0, 0, 1080, 2340)
    private val spec = WheelMenuSpec.fromDensity(density)
    private val settings = WheelMenuLayoutSettings.DEFAULT

    private fun envelopeFrom(pet: OverlayRect): WheelMenuEnvelope? =
        DualWindowMenuPlanner.envelopeFromPet(
            petScreenRect = pet,
            bounds = bounds,
            content = PetContentBounds.FULL,
            maxItemCount = WheelMenuCatalog.maxItems,
            spec = spec,
            settings = settings,
        )

    private fun menuRectFrom(pet: OverlayRect): OverlayRect? =
        DualWindowMenuPlanner.menuRectFromPet(
            petScreenRect = pet,
            bounds = bounds,
            content = PetContentBounds.FULL,
            maxItemCount = WheelMenuCatalog.maxItems,
            spec = spec,
            settings = settings,
        )

    private fun petAt(left: Int, top: Int, w: Int = 300, h: Int = 300): OverlayRect =
        OverlayRect(left, top, left + w, top + h)

    // -----------------------------------------------------------------------
    // 加/减/更新账本
    // -----------------------------------------------------------------------

    @Test
    fun `加序固定为 menu 先、pet 后`() {
        val ledger = DualWindowWindowLedger()
        ledger.recordAdd(OverlayWindowKind.MENU)
        ledger.recordAdd(OverlayWindowKind.PET)

        assertEquals(
            listOf(OverlayWindowKind.MENU, OverlayWindowKind.PET),
            ledger.initialOrder(),
        )
        assertEquals("menu→pet", ledger.initialOrderLabel())
        assertEquals(OverlayWindowKind.PET, ledger.currentExpectedTopWindow())
    }

    @Test
    fun `反复开合 200 轮：菜单与桌宠各只 add 一次，开合只记 update`() {
        val ledger = DualWindowWindowLedger()
        ledger.recordAdd(OverlayWindowKind.MENU) // seq=1
        ledger.recordAdd(OverlayWindowKind.PET) // seq=2

        repeat(200) {
            // 【已更新】旧实现断言"开菜单 = 一次 updateViewLayout"；修复"第一帧"缺陷后，
            // 双窗口打开拆成两阶段：prepare（仍 NOT_TOUCHABLE）+ present（去标志）——
            // 因此每次打开是**两次** updateViewLayout。但**依旧只是 update**（不是 add/remove），
            // 下面 ledger 仍逐次记录下来，`menuAddCount` 恒为 1 的不变式不受影响。
            // 关菜单 = 一次 updateViewLayout；开菜单 = 两次 updateViewLayout。
            ledger.recordUpdate(OverlayWindowKind.MENU)
            ledger.recordUpdate(OverlayWindowKind.MENU)
            ledger.recordUpdate(OverlayWindowKind.MENU)
        }

        assertEquals("菜单全程只 add 一次", 1, ledger.menuAddCount)
        assertEquals("菜单全程从未 removeView", 0, ledger.menuRemoveCount)
        assertEquals("桌宠全程只 add 一次", 1, ledger.petAddCount)
        assertEquals("桌宠全程从未 removeView", 0, ledger.petRemoveCount)
        assertFalse("菜单绝不能在桌宠之后被重加", ledger.menuWasReaddedAfterPet)
        assertTrue("菜单窗口始终挂载", ledger.menuAttached)
        assertEquals("全局操作序随每次操作单调递增", 2 + 200 * 3, ledger.operationSequence)
        assertTrue(ledger.isPaired())
    }

    @Test
    fun `双窗口开菜单是两次 updateViewLayout（prepare+present），仍不 add remove`() {
        val ledger = DualWindowWindowLedger()
        ledger.recordAdd(OverlayWindowKind.MENU)
        ledger.recordAdd(OverlayWindowKind.PET)
        val before = ledger.operationSequence

        // 旧实现 = 一次 update；现在 = prepare（仍 NOT_TOUCHABLE）+ present（去标志），都只是 update。
        ledger.recordUpdate(OverlayWindowKind.MENU)
        ledger.recordUpdate(OverlayWindowKind.MENU)

        assertEquals(before + 2, ledger.operationSequence)
        assertEquals(1, ledger.menuAddCount)
        assertEquals(0, ledger.menuRemoveCount)
        assertEquals(1, ledger.petAddCount)
        assertEquals(0, ledger.petRemoveCount)
        assertFalse(ledger.menuWasReaddedAfterPet)
        assertTrue(ledger.isPaired())
    }

    @Test
    fun `期望顶层窗口恒为 pet（菜单的 update 不会把它抬高）`() {
        val ledger = DualWindowWindowLedger()
        ledger.recordAdd(OverlayWindowKind.MENU)
        ledger.recordAdd(OverlayWindowKind.PET)

        assertEquals(1, ledger.menuLastAddSequence)
        assertEquals(2, ledger.petLastAddSequence)

        repeat(20) { ledger.recordUpdate(OverlayWindowKind.MENU) }
        assertEquals("菜单 update 不改变其最后 add 序", 1, ledger.menuLastAddSequence)
        assertEquals(OverlayWindowKind.PET, ledger.currentExpectedTopWindow())
    }

    @Test
    fun `重复移除同一窗口被判为不配平`() {
        val ledger = DualWindowWindowLedger()
        ledger.recordAdd(OverlayWindowKind.MENU)
        ledger.recordRemove(OverlayWindowKind.MENU)
        ledger.recordRemove(OverlayWindowKind.MENU)

        assertEquals(2, ledger.menuRemoveCount)
        assertFalse("移除次数超过添加次数必须判为不配平", ledger.isPaired())
    }

    // -----------------------------------------------------------------------
    // 关闭态 / 打开态的窗口状态
    // -----------------------------------------------------------------------

    @Test
    fun `关闭态菜单窗是 1×1 + 不可触摸 + 角落 + 内容 GONE`() {
        val closed = DualWindowSceneSpec.closedMenuWindow(density)
        val corner = DualWindowSceneSpec.closedMenuRect(density)
        val inset = DualWindowSceneSpec.dp(density, DualWindowSceneSpec.CLOSED_MENU_INSET_DP)

        assertFalse("关闭态必须不可触摸（FLAG_NOT_TOUCHABLE）", closed.touchable)
        assertEquals(1, closed.width)
        assertEquals(1, closed.height)
        assertEquals(inset, closed.left)
        assertEquals(inset, closed.top)
        assertFalse("关闭态内容必须 GONE", closed.contentVisible)
        assertTrue(closed.isClosedCorner)
        assertEquals(corner.left, closed.left)
        assertEquals(corner.top, closed.top)
        assertTrue("角落必须内缩，不能正好落在 (0,0)", inset >= 1)
    }

    @Test
    fun `打开态菜单窗等于传入矩形且可触摸 + 内容 VISIBLE`() {
        val rect = OverlayRect(120, 300, 120 + 480, 300 + 620)
        val open = DualWindowSceneSpec.openMenuWindow(rect)

        assertTrue(open.touchable)
        assertEquals(rect.left, open.left)
        assertEquals(rect.top, open.top)
        assertEquals(rect.width, open.width)
        assertEquals(rect.height, open.height)
        assertTrue(open.contentVisible)
        assertFalse(open.isClosedCorner)
    }

    // -----------------------------------------------------------------------
    // 菜单矩形据桌宠“当前”矩形重算
    // -----------------------------------------------------------------------

    @Test
    fun `菜单矩形由桌宠当前矩形重算，而非缓存首次矩形`() {
        val first = petAt(100, 200)
        val moved = petAt(100, 1500)

        val rectFirst = menuRectFrom(first)
        val rectMoved = menuRectFrom(moved)

        assertTrue("两张桌宠矩形都必须能解出菜单矩形", rectFirst != null && rectMoved != null)
        assertNotEquals("桌宠移动后菜单矩形必须随之改变", rectFirst, rectMoved)
    }

    @Test
    fun `左右镜像保留：桌宠在左半菜单向右、右半菜单向左`() {
        val leftPet = petAt(50, 400) // centerX=200 < 540
        val rightPet = petAt(700, 400) // centerX=850 > 540

        assertEquals(WheelExpandDirection.right, envelopeFrom(leftPet)?.direction)
        assertEquals(WheelExpandDirection.left, envelopeFrom(rightPet)?.direction)
    }

    @Test
    fun `垂直偏置保留：桌宠贴近下边界时靠下`() {
        val nearBottom = OverlayRect(100, 2200, 400, 2340)
        val env = envelopeFrom(nearBottom)
        assertEquals(WheelVerticalMode.bottomEdge, env?.verticalMode)
    }

    @Test
    fun `拿不到可用桌宠矩形时不产出菜单矩形`() {
        assertNull(menuRectFrom(OverlayRect(0, 0, 0, 0)))
    }

    // -----------------------------------------------------------------------
    // 桌宠窗几何在菜单开合下恒定
    // -----------------------------------------------------------------------

    @Test
    fun `菜单开合与跟随都不改变桌宠窗几何`() {
        val pet = petAt(100, 900)
        val closed = DualWindowScene.closed(pet)

        val opened = closed.withMenuOpened(OverlayRect(100, 1200, 700, 1800))
        assertTrue("打开菜单后桌宠窗矩形必须逐字节不变", opened.petGeometryEquals(closed))
        assertTrue(opened.menuOpen)
        assertEquals(OverlayRect(100, 1200, 700, 1800), opened.menuWindowRect)

        val followed = opened.withPetMoved(pet, OverlayRect(120, 1220, 720, 1820))
        assertTrue("菜单跟随重算后桌宠窗矩形仍不变", followed.petGeometryEquals(closed))
        assertEquals(OverlayRect(120, 1220, 720, 1820), followed.menuWindowRect)

        val reclosed = followed.withMenuClosed()
        assertTrue("关闭菜单后桌宠窗矩形仍不变", reclosed.petGeometryEquals(closed))
        assertNull(reclosed.menuWindowRect)
        assertFalse(reclosed.menuOpen)
    }

    @Test
    fun `桌宠被拖动时菜单窗矩形跟随新位置而桌宠窗随新位置（两者解耦）`() {
        val petA = petAt(100, 900)
        val petB = petAt(300, 900)
        val sceneA = DualWindowScene.open(petA, OverlayRect(100, 1200, 700, 1800))
        val sceneB = sceneA.withPetMoved(petB, OverlayRect(300, 1200, 900, 1800))

        assertFalse("桌宠移动后桌宠窗几何必须变", sceneB.petGeometryEquals(sceneA))
        assertEquals(petB, sceneB.petWindowRect)
        assertNotEquals(sceneA.menuWindowRect, sceneB.menuWindowRect)
    }

    // -----------------------------------------------------------------------
    // 模式切换 / 回退
    // -----------------------------------------------------------------------

    @Test
    fun `请求双窗口且建窗成功 ⇒ 双窗口`() {
        assertEquals(
            OverlayMode.DUAL_WINDOW,
            DualWindowModeResolver.resolve(requestedDual = true, dualSetupSucceeded = true),
        )
        assertNull(DualWindowModeResolver.fallbackReason(requestedDual = true, dualSetupSucceeded = true))
    }

    @Test
    fun `请求双窗口但建窗失败 ⇒ 回退单窗口并给出原因码`() {
        assertEquals(
            OverlayMode.SINGLE_WINDOW,
            DualWindowModeResolver.resolve(requestedDual = true, dualSetupSucceeded = false),
        )
        assertEquals(
            DualWindowModeResolver.REASON_DUAL_SETUP_FAILED,
            DualWindowModeResolver.fallbackReason(requestedDual = true, dualSetupSucceeded = false),
        )
    }

    @Test
    fun `请求单窗口 ⇒ 单窗口（即使建窗本可成功）`() {
        assertEquals(
            OverlayMode.SINGLE_WINDOW,
            DualWindowModeResolver.resolve(requestedDual = false, dualSetupSucceeded = true),
        )
        assertNull(DualWindowModeResolver.fallbackReason(requestedDual = false, dualSetupSucceeded = true))
    }

    @Test
    fun `模式切换重建：重置纪元后重新加一次菜单与桌宠，绝不重复挂载`() {
        val ledger = DualWindowWindowLedger()
        // 第一段：双窗口。
        ledger.recordAdd(OverlayWindowKind.MENU)
        ledger.recordAdd(OverlayWindowKind.PET)
        // 切换模式：先把两窗都摘掉。
        ledger.recordRemove(OverlayWindowKind.PET)
        ledger.recordRemove(OverlayWindowKind.MENU)
        assertFalse(ledger.petAttached)
        assertFalse(ledger.menuAttached)
        assertTrue(ledger.isPaired())
        // 重置纪元后建新模式：重新恰好各加一次。
        ledger.reset()
        ledger.recordAdd(OverlayWindowKind.MENU)
        ledger.recordAdd(OverlayWindowKind.PET)
        assertEquals(1, ledger.menuAddCount)
        assertEquals(1, ledger.petAddCount)
        assertTrue(ledger.isPaired())
    }

    // -----------------------------------------------------------------------
    // 打开序列（修复"菜单打开第一帧"缺陷）：布局闸门 MenuOpenSequencer
    // -----------------------------------------------------------------------

    private fun envAt(pet: OverlayRect): WheelMenuEnvelope =
        requireNotNull(envelopeFrom(pet)) { "信封必须可解" }

    @Test
    fun `关闭 1×1 状态绝不启动展开动画`() {
        val seq = MenuOpenSequencer()
        // 还没开始打开：任何回调都惰性。
        assertTrue(seq.onPreDraw(1, 1, 1, 1, 0).isInert)
        // 目标不是真实展开尺寸：拒绝进入等待（调用方走降级，绝不用 1×1 起动画）。
        assertFalse(seq.beginLayout(7, 1, 1, WheelExpandDirection.right))
        assertEquals(0, seq.animationStarts)

        // 进入等待后，仍是关闭态 1×1 的那一帧不达标。
        assertTrue(seq.beginLayout(7, 480, 620, WheelExpandDirection.right))
        assertTrue(seq.onPreDraw(1, 1, 1, 1, 7).isInert)
        assertEquals(0, seq.animationStarts)
        assertFalse(seq.interactive)
    }

    @Test
    fun `布局尺寸未达标前不得变成可交互`() {
        val seq = MenuOpenSequencer()
        seq.beginLayout(1, 480, 620, WheelExpandDirection.right)

        assertFalse("未达标帧不得显示内容", seq.onPreDraw(480, 620, 480, 619, 1).showContent)
        assertFalse("未达标帧不得清 NOT_TOUCHABLE", seq.onPreDraw(480, 620, 479, 620, 1).clearNotTouchable)
        assertFalse(seq.interactive)

        val ready = seq.onPreDraw(480, 620, 480, 620, 1)
        assertTrue(ready.startAnimation)
        assertTrue(ready.showContent)
        assertTrue(ready.clearNotTouchable)
        assertTrue(seq.interactive)
        assertTrue(seq.layoutReady)
    }

    @Test
    fun `布局达标后动画恰好启动一次`() {
        val seq = MenuOpenSequencer()
        seq.beginLayout(3, 480, 620, WheelExpandDirection.right)

        assertTrue(seq.onPreDraw(480, 620, 480, 620, 3).startAnimation)
        assertEquals(1, seq.animationStarts)
        // 下一帧再来一次同样的 pre-draw 必须惰性，绝不重复起动画。
        assertTrue(seq.onPreDraw(480, 620, 480, 620, 3).isInert)
        assertEquals(1, seq.animationStarts)
    }

    @Test
    fun `旧会话的 pre-draw 回调不能启动新会话的动画`() {
        val seq = MenuOpenSequencer()
        seq.beginLayout(1, 480, 620, WheelExpandDirection.right)
        seq.beginLayout(2, 480, 620, WheelExpandDirection.left) // 新一次打开

        assertTrue("旧会话回调必须惰性", seq.onPreDraw(480, 620, 480, 620, 1).isInert)
        assertTrue(seq.onPreDraw(480, 620, 480, 620, 2).startAnimation)
        assertEquals(1, seq.animationStarts)
    }

    @Test
    fun `快速 开→关：延迟回调不得重新显示菜单`() {
        val seq = MenuOpenSequencer()
        seq.beginLayout(5, 480, 620, WheelExpandDirection.right)
        assertTrue(seq.cancel(5))

        assertTrue(seq.onPreDraw(480, 620, 480, 620, 5).isInert)
        assertTrue(seq.onFrame(480, 620, 480, 620, 5).isInert)
        assertEquals(0, seq.animationStarts)
        assertFalse(seq.interactive)
        assertEquals(MenuOpenPhase.cancelled, seq.phase)
    }

    @Test
    fun `快速 开→关→开：只有最后一个会话能起动画`() {
        val seq = MenuOpenSequencer()
        seq.beginLayout(1, 480, 620, WheelExpandDirection.right)
        seq.cancel(1)
        seq.beginLayout(2, 480, 620, WheelExpandDirection.left)

        assertTrue("第一个会话的回调必须惰性", seq.onPreDraw(480, 620, 480, 620, 1).isInert)
        assertTrue("最后一个会话才允许起动画", seq.onPreDraw(480, 620, 480, 620, 2).startAnimation)
        assertEquals(1, seq.animationStarts)
    }

    @Test
    fun `锚点与枢轴使用菜单窗口局部坐标而非屏幕坐标`() {
        val pet = petAt(120, 900)
        val env = envAt(pet)
        val layout = WheelMenuGeometry.layoutFor(env, WheelMenuCatalog.ROOT, spec)
        val win = env.windowRect

        // 锚点：屏幕坐标 → 窗口局部坐标，必须等于布局算出的缺口中心（恒等于桌宠锚点）。
        val anchorLocal = MenuOpenCoordinates.toWindowLocal(env.petAnchorX, env.petAnchorY, win)
        assertEquals("局部锚点 X = 缺口中心 X", layout.notchCenterX, anchorLocal[0], 0.01f)
        assertEquals("局部锚点 Y = 缺口中心 Y", layout.notchCenterY, anchorLocal[1], 0.01f)
        assertTrue(MenuOpenCoordinates.isWithinWindow(anchorLocal[0], anchorLocal[1], win))

        // 枢轴 = 布局中心（窗口局部坐标）：局部 + 窗口原点 == 屏幕中心。
        assertEquals(env.centerX.toFloat(), win.left + layout.centerX, 0.01f)
        assertEquals(env.centerY.toFloat(), win.top + layout.centerY, 0.01f)
        assertTrue(MenuOpenCoordinates.isWithinWindow(layout.centerX, layout.centerY, win))

        // 关键：把屏幕原始中心当枢轴会落在窗口之外 ⇒ 局部坐标才是唯一正确的坐标系。
        if (win.left > 0) {
            assertFalse(
                MenuOpenCoordinates.isWithinWindow(env.centerX.toFloat(), env.centerY.toFloat(), win),
            )
        }
    }

    @Test
    fun `左右镜像与垂直偏置下打开方向在动画期间不二次切换`() {
        val seq = MenuOpenSequencer()
        val leftPet = petAt(50, 400) // 中心在左半 → 向右展开
        val env = envAt(leftPet)
        assertEquals(WheelExpandDirection.right, env.direction)
        assertTrue(seq.beginLayout(9, env.windowRect.width, env.windowRect.height, env.direction))

        // 锁定后即便后续候选是"向左"，也仍返回本次打开锁定的方向。
        assertEquals(WheelExpandDirection.right, seq.lockedDirection(WheelExpandDirection.left))
        assertEquals(WheelExpandDirection.right, seq.direction)

        // 垂直偏置（贴近下边界）下同样不二次切换方向。
        val nearBottom = envAt(OverlayRect(50, 2200, 350, 2340))
        assertTrue(
            seq.beginLayout(10, nearBottom.windowRect.width, nearBottom.windowRect.height, nearBottom.direction),
        )
        assertEquals(nearBottom.direction, seq.lockedDirection(nearBottom.direction.opposite()))
    }

    @Test
    fun `布局超时降级：显示在最终位置而不是从上方掉落`() {
        val seq = MenuOpenSequencer(maxLayoutFrames = 3)
        seq.beginLayout(4, 480, 620, WheelExpandDirection.right)

        // 连续 3 帧都还是 1×1（布局迟迟没到）⇒ 降级。
        assertTrue(seq.onFrame(1, 1, 1, 1, 4).isInert)
        assertTrue(seq.onFrame(1, 1, 1, 1, 4).isInert)
        val degrade = seq.onFrame(1, 1, 1, 1, 4)

        assertTrue(degrade.degrade)
        assertFalse("降级绝不播动画（否则会从错误坐标掉落）", degrade.startAnimation)
        assertTrue(degrade.showContent)
        assertTrue(degrade.clearNotTouchable)
        assertEquals(MenuOpenSequencer.REASON_LAYOUT_TIMEOUT, degrade.reason)
        assertEquals(0, seq.animationStarts)
        assertTrue("降级后菜单仍完全可用", seq.interactive)
        assertEquals(MenuOpenPhase.degraded, seq.phase)
    }

    @Test
    fun `开菜单全程桌宠窗几何与 addCount 不变`() {
        val pet = petAt(150, 1000)
        val env = envAt(pet)
        val ledger = DualWindowWindowLedger()
        ledger.recordAdd(OverlayWindowKind.MENU) // 菜单窗最先加，一次
        ledger.recordAdd(OverlayWindowKind.PET) // 桌宠窗后加（在上层），一次

        val seq = MenuOpenSequencer()
        // 阶段 1：prepare（一次 update，仍 NOT_TOUCHABLE）。
        ledger.recordUpdate(OverlayWindowKind.MENU)
        assertTrue(seq.beginLayout(11, env.windowRect.width, env.windowRect.height, env.direction))
        val ready = seq.onPreDraw(env.windowRect.width, env.windowRect.height, env.windowRect.width, env.windowRect.height, 11)
        assertTrue(ready.startAnimation)
        assertEquals(1, seq.animationStarts)
        // 阶段 2：present（第二次 update，去标志）。
        ledger.recordUpdate(OverlayWindowKind.MENU)

        val closed = DualWindowScene.closed(pet)
        val opened = closed.withMenuOpened(env.windowRect)
        assertTrue("桌宠窗几何必须逐字节不变", opened.petGeometryEquals(closed))
        assertEquals("桌宠窗只 add 一次", 1, ledger.petAddCount)
        assertEquals("菜单窗只 add 一次", 1, ledger.menuAddCount)
        assertEquals(0, ledger.petRemoveCount)
        assertEquals(0, ledger.menuRemoveCount)
        assertTrue(ledger.isPaired())
    }

    // -----------------------------------------------------------------------
    // 布局闸门只看**轮盘（WheelMenuView）**的测量尺寸
    // （修复缺口：准备阶段旧实现用 GONE，轮盘不参与测量，宿主尺寸达标被误判为通过）
    // -----------------------------------------------------------------------

    @Test
    fun `宿主窗达标但轮盘 0×0 或 1×1 时绝不启动动画`() {
        val seq = MenuOpenSequencer()
        seq.beginLayout(21, 480, 620, WheelExpandDirection.right)

        // 宿主窗（菜单窗根）已量到目标尺寸 —— 但轮盘仍是 0×0：这一帧不达标。
        assertTrue(seq.onPreDraw(480, 620, 0, 0, 21).isInert)
        assertEquals(0, seq.animationStarts)
        assertFalse(seq.interactive)
        // 1×1（关闭态残留）同样不达标。
        assertTrue(seq.onPreDraw(480, 620, 1, 1, 21).isInert)
        assertEquals(0, seq.animationStarts)
        assertFalse(seq.layoutReady)
    }

    @Test
    fun `可见与可交互只在轮盘量到目标尺寸之后`() {
        val seq = MenuOpenSequencer()
        seq.beginLayout(22, 480, 620, WheelExpandDirection.right)

        // 准备阶段的多帧：轮盘尚未量到目标尺寸 ⇒ 既不可见也不可交互。
        repeat(3) {
            val hidden = seq.onPreDraw(480, 620, 300, 400, 22)
            assertFalse(hidden.showContent)
            assertFalse(hidden.clearNotTouchable)
            assertFalse(hidden.startAnimation)
            assertFalse(seq.interactive)
        }
        // 轮盘量到目标尺寸的那一帧：才允许可见 + 可交互 + 起动画。
        val ready = seq.onPreDraw(480, 620, 480, 620, 22)
        assertTrue(ready.showContent)
        assertTrue(ready.clearNotTouchable)
        assertTrue(ready.startAnimation)
        assertTrue(seq.interactive)
    }

    @Test
    fun `闸门只读轮盘测量尺寸而不读宿主尺寸`() {
        val seq = MenuOpenSequencer()
        seq.beginLayout(23, 480, 620, WheelExpandDirection.right)

        // 宿主尺寸达标、轮盘不达标 ⇒ 绝不通过（旧实现会误判通过，正是本次修复的缺口）。
        assertTrue(seq.onPreDraw(480, 620, 200, 200, 23).isInert)
        assertEquals(200, seq.lastContentWidth)
        assertFalse(seq.contentAtTarget)

        // 宿主尺寸"不达标"、轮盘达标 ⇒ 通过（证明判定用的是轮盘尺寸）。
        val ready = seq.onPreDraw(999, 999, 480, 620, 23)
        assertTrue(ready.startAnimation)
        assertTrue(seq.contentAtTarget)
        assertEquals(999, seq.lastHostWidth) // 宿主尺寸只是被记录用于诊断
    }

    @Test
    fun `第一个可见帧的轮盘测量尺寸必须等于 target`() {
        val seq = MenuOpenSequencer()
        seq.beginLayout(24, 480, 620, WheelExpandDirection.right)

        val ready = seq.onFrame(480, 620, 480, 620, 24)
        assertTrue(ready.showContent)
        assertTrue(seq.layoutReady)
        assertEquals(seq.targetWidth, seq.lastContentWidth)
        assertEquals(seq.targetHeight, seq.lastContentHeight)
    }

    @Test
    fun `隐藏准备帧 contentMeasured 为 0 不计为视觉失败`() {
        val seq = MenuOpenSequencer(maxLayoutFrames = 12)
        seq.beginLayout(25, 480, 620, WheelExpandDirection.right)

        // 若干"隐藏准备帧"：宿主达标但轮盘 0×0（INVISIBLE 阶段尚无量）—— 每帧都惰性、无降级。
        repeat(5) {
            val hidden = seq.onFrame(480, 620, 0, 0, 25)
            assertTrue("隐藏准备帧必须惰性，绝不触发降级/失败", hidden.isInert)
            assertFalse(hidden.degrade)
        }
        assertEquals(0, seq.animationStarts)
        assertEquals(MenuOpenPhase.awaitingLayout, seq.phase)
        // 随后轮盘量到目标尺寸 ⇒ 正常放行（没有因隐藏帧被误判为失败）。
        val ready = seq.onPreDraw(480, 620, 480, 620, 25)
        assertTrue(ready.startAnimation)
        assertEquals(1, seq.animationStarts)
    }

    @Test
    fun `准备布局态参与测量但不绘制且不可交互`() {
        assertTrue(
            "INVISIBLE 必须参与测量/布局（否则轮盘量不到目标尺寸）",
            MenuContentVisibility.invisible.participatesInLayout,
        )
        assertFalse("INVISIBLE 绝不绘制", MenuContentVisibility.invisible.draws)
        assertFalse("INVISIBLE 绝不可交互", MenuContentVisibility.invisible.interactive)

        assertFalse("GONE 不参与测量/布局", MenuContentVisibility.gone.participatesInLayout)
        assertFalse(MenuContentVisibility.gone.draws)

        assertTrue(MenuContentVisibility.visible.participatesInLayout)
        assertTrue(MenuContentVisibility.visible.draws)
        assertTrue(MenuContentVisibility.visible.interactive)
    }
}

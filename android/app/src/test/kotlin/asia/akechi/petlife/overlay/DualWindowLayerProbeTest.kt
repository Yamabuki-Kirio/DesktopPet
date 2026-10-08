package asia.akechi.petlife.overlay

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 双窗口层级探测的**纯逻辑**回归测试。
 *
 * 只打靶不依赖任何 `android.*` 类型的部分：
 * * [ProbeLayerLedger]：加序记录、加/减计数配对、`petAddCount` 在菜单开关下恒定；
 * * [DualWindowProbePlanner]：菜单/按钮布局（OUTSIDE 严格在桌宠矩形外、OVERLAP 严格相交）。
 *
 * 真机窗口层（addView/removeView、触摸归属、层级）**不在这里假装通过** —— 那必须由操作者在真机上按
 * 报告里的步骤验证。
 */
class DualWindowLayerProbeTest {

    private val density = 2.75f

    // -----------------------------------------------------------------------
    // 账本：加序 / 计数配对 / petAddCount 不变
    // -----------------------------------------------------------------------

    @Test
    fun `加序固定为 menu 先、pet 后`() {
        val ledger = ProbeLayerLedger()
        ledger.recordAdd(ProbeWindowKind.MENU)
        ledger.recordAdd(ProbeWindowKind.PET)

        assertEquals(
            listOf(ProbeWindowKind.MENU, ProbeWindowKind.PET),
            ledger.initialOrder(),
        )
        assertEquals("menu→pet", ledger.initialOrderLabel())
        assertEquals("menu→pet", ledger.addOrderLabel())
    }

    @Test
    fun `加与减计数成对：正常加一次再移除一次后完全配平`() {
        val ledger = ProbeLayerLedger()
        ledger.recordAdd(ProbeWindowKind.MENU)
        ledger.recordAdd(ProbeWindowKind.PET)
        ledger.recordRemove(ProbeWindowKind.PET)
        ledger.recordRemove(ProbeWindowKind.MENU)

        assertEquals(1, ledger.petAddCount)
        assertEquals(1, ledger.menuAddCount)
        assertEquals(1, ledger.petRemoveCount)
        assertEquals(1, ledger.menuRemoveCount)
        assertTrue("每个窗口最多移除其被添加的次数", ledger.isPaired())
        assertFalse("两个窗口都已摘除", ledger.menuAttached)
    }

    @Test
    fun `重复移除同一窗口会被配对自检判为不配平`() {
        val ledger = ProbeLayerLedger()
        ledger.recordAdd(ProbeWindowKind.PET)
        ledger.recordRemove(ProbeWindowKind.PET)
        ledger.recordRemove(ProbeWindowKind.PET)

        assertEquals(2, ledger.petRemoveCount)
        assertFalse("移除次数超过添加次数必须判为不配平", ledger.isPaired())
    }

    @Test
    fun `开关菜单多次：petAddCount 恒为 1（桌宠窗口从不重加也不移除）`() {
        val ledger = ProbeLayerLedger()
        // 固定加序：先菜单、后桌宠。
        ledger.recordAdd(ProbeWindowKind.MENU)
        ledger.recordAdd(ProbeWindowKind.PET)

        repeat(10) {
            // 关菜单（removeView）→ 再开菜单（重新 addView）——只有菜单在动。
            ledger.recordRemove(ProbeWindowKind.MENU)
            ledger.recordAdd(ProbeWindowKind.MENU)
        }

        assertEquals("开关菜单 10 轮，桌宠窗口绝不能被重加", 1, ledger.petAddCount)
        assertEquals("桌宠窗口也绝不能被移除", 0, ledger.petRemoveCount)
        assertEquals("菜单累计加 11 次", 11, ledger.menuAddCount)
        assertEquals("菜单累计移除 10 次", 10, ledger.menuRemoveCount)
        assertTrue(ledger.menuAttached)
        assertTrue(ledger.isPaired())
    }

    @Test
    fun `初始加序标签只取前两次（开关菜单不会污染 menu→pet 这一事实）`() {
        val ledger = ProbeLayerLedger()
        ledger.recordAdd(ProbeWindowKind.MENU)
        ledger.recordAdd(ProbeWindowKind.PET)
        ledger.recordRemove(ProbeWindowKind.MENU)
        ledger.recordAdd(ProbeWindowKind.MENU)

        assertEquals("menu→pet", ledger.initialOrderLabel())
        assertEquals("menu→pet→menu", ledger.addOrderLabel())
    }

    // -----------------------------------------------------------------------
    // 布局：OUTSIDE 严格在桌宠之外 / OVERLAP 严格相交
    // -----------------------------------------------------------------------

    private fun petRectAt(left: Int = 400, top: Int = 800): OverlayRect =
        DualWindowProbePlanner.plan(
            petRect = OverlayRect(left, top, left + 300, top + 300),
            density = density,
        ).petRect

    @Test
    fun `OUTSIDE 按钮严格位于桌宠探测矩形之外（含间隙）`() {
        val plan = DualWindowProbePlanner.plan(petRectAt(), density)

        assertTrue("OUTSIDE 必须严格在桌宠矩形外", plan.outsideIsStrictlyOutsidePet())
        assertFalse("OUTSIDE 不得与桌宠矩形相交", plan.petRect.overlaps(plan.outsideButton))
    }

    @Test
    fun `OVERLAP 按钮严格与桌宠探测矩形相交`() {
        val plan = DualWindowProbePlanner.plan(petRectAt(), density)

        assertTrue("OVERLAP 必须与桌宠矩形严格相交", plan.overlapStrictlyIntersectsPet())
        assertTrue("相交面积必须大于 0", plan.overlapRatio > 0f)
        assertTrue("重叠比例不能是全覆盖", plan.overlapRatio < 1f)
    }

    @Test
    fun `OVERLAP 重叠比例约为一半（允许布局取整误差）`() {
        val plan = DualWindowProbePlanner.plan(petRectAt(), density)
        assertTrue(
            "实际重叠比例=${plan.overlapRatio} 应接近 0.5",
            plan.overlapRatio in 0.4f..0.6f,
        )
    }

    @Test
    fun `三个按钮都完整落在菜单探测矩形内且互不相同`() {
        val plan = DualWindowProbePlanner.plan(petRectAt(), density)

        assertTrue(plan.buttonsInsideMenu())
        assertFalse(plan.outsideButton.overlaps(plan.overlapButton))
        assertFalse(plan.outsideButton.overlaps(plan.closeButton))
        assertFalse(plan.overlapButton.overlaps(plan.closeButton))
    }

    @Test
    fun `菜单块与桌宠矩形故意部分重叠（证明桌宠在上层）`() {
        val plan = DualWindowProbePlanner.plan(petRectAt(), density)
        assertTrue("菜单块必须与桌宠矩形相交", plan.menuRect.overlaps(plan.petRect))
    }

    // -----------------------------------------------------------------------
    // 尺寸派生：有真实桌宠矩形就用它；没有就用固定 dp 兜底
    // -----------------------------------------------------------------------

    @Test
    fun `拿不到真实桌宠矩形时用兜底尺寸，且不小于最小可读尺寸`() {
        val rect = DualWindowProbePlanner.resolvePetRect(
            provided = null,
            density = density,
            screenWidth = 1080,
            screenHeight = 2340,
        )
        val minSize = DualWindowProbePlanner.dp(density, DualWindowProbePlanner.MIN_PET_PROBE_DP)

        assertTrue(rect.isUsable)
        assertTrue("宽不得小于最小可读尺寸", rect.width >= minSize)
        assertTrue("高不得小于最小可读尺寸", rect.height >= minSize)
    }

    @Test
    fun `极小的真实桌宠尺寸会被放大到最小可读尺寸`() {
        val tiny = OverlayRect(100, 100, 100 + 40, 100 + 40)
        val resolved = DualWindowProbePlanner.resolvePetRect(
            provided = tiny,
            density = density,
            screenWidth = 1080,
            screenHeight = 2340,
        )
        val minSize = DualWindowProbePlanner.dp(density, DualWindowProbePlanner.MIN_PET_PROBE_DP)

        assertTrue(resolved.width >= minSize)
        assertTrue(resolved.height >= minSize)
        assertEquals("左上角沿用真实桌宠位置", tiny.left, resolved.left)
        assertEquals("左上角沿用真实桌宠位置", tiny.top, resolved.top)
    }

    @Test
    fun `真实桌宠矩形已足够大时原样沿用其尺寸`() {
        val big = OverlayRect(50, 60, 50 + 500, 60 + 520)
        val resolved = DualWindowProbePlanner.resolvePetRect(
            provided = big,
            density = density,
            screenWidth = 1080,
            screenHeight = 2340,
        )
        assertEquals(big.width, resolved.width)
        assertEquals(big.height, resolved.height)
        assertEquals(big.left, resolved.left)
        assertEquals(big.top, resolved.top)
    }

    @Test
    fun `越界的兜底位置会被夹回屏幕内`() {
        val resolved = DualWindowProbePlanner.resolvePetRect(
            provided = OverlayRect(1000, 2300, 1000 + 400, 2300 + 400),
            density = density,
            screenWidth = 1080,
            screenHeight = 2340,
        )
        assertTrue("左边必须 >= 0", resolved.left >= 0)
        assertTrue("上边必须 >= 0", resolved.top >= 0)
        assertTrue("右边不得越界", resolved.right <= 1080)
        assertTrue("下边不得越界", resolved.bottom <= 2340)
    }

    // -----------------------------------------------------------------------
    // 结论有效性契约：硬门 / 读out 5 字段 / 启动日志块 / 停止摘要
    // -----------------------------------------------------------------------

    @Test
    fun `probeValid 在生产窗口仍挂载时为 false（摘除未生效）`() {
        // 生产窗口仍在 ⇒ 无论探测窗口是否加成功，结论一律无效。
        assertFalse(
            "生产窗口存在时绝不能判定为有效",
            DualWindowProbeContract.computeProbeValid(
                productionWindowAttached = true,
                allProbeWindowsAdded = true,
            ),
        )
        assertFalse(
            DualWindowProbeContract.computeProbeValid(
                productionWindowAttached = true,
                allProbeWindowsAdded = false,
            ),
        )
    }

    @Test
    fun `probeValid 只有摘除成功且两个探测窗口都加成功才为 true`() {
        assertTrue(
            "生产窗口已摘除 + 两窗都加成功 ⇒ 有效",
            DualWindowProbeContract.computeProbeValid(
                productionWindowAttached = false,
                allProbeWindowsAdded = true,
            ),
        )
        assertFalse(
            "任一探测窗口添加失败 ⇒ 无效",
            DualWindowProbeContract.computeProbeValid(
                productionWindowAttached = false,
                allProbeWindowsAdded = false,
            ),
        )
    }

    @Test
    fun `运行中生产窗口一旦出现，已有通过结论立即作废`() {
        assertTrue(
            DualWindowProbeContract.effectiveProbeValid(
                storedProbeValid = true,
                productionWindowAttached = false,
            ),
        )
        assertFalse(
            "生产窗口出现后绝不报告通过",
            DualWindowProbeContract.effectiveProbeValid(
                storedProbeValid = true,
                productionWindowAttached = true,
            ),
        )
    }

    @Test
    fun `读out 含新增的 5 个字段且总数按 生产+探测 计`() {
        val lines = DualWindowProbeContract.readoutLines(
            productionWindowAttached = false,
            probeWindowCount = 2,
            probeValid = true,
        )

        assertEquals(5, lines.size)
        assertTrue(lines.contains("productionWindowAttached=false"))
        assertTrue(lines.contains("probeWindowCount=2"))
        assertTrue(lines.contains("expectedProbeWindowCount=2"))
        assertTrue(lines.contains("totalKnownOverlayWindowCount=2"))
        assertTrue(lines.contains("probeValid=true"))
    }

    @Test
    fun `读out 生产窗口仍挂载时总数为 3 且 probeValid=false`() {
        val lines = DualWindowProbeContract.readoutLines(
            productionWindowAttached = true,
            probeWindowCount = 2,
            probeValid = false,
        )
        assertTrue(lines.contains("totalKnownOverlayWindowCount=3"))
        assertTrue(lines.contains("probeValid=false"))
    }

    @Test
    fun `探测窗口计数按当前实际挂载数（开关菜单会变）`() {
        assertEquals(2, DualWindowProbeContract.probeWindowCount(menuAttached = true, petAttached = true))
        assertEquals(1, DualWindowProbeContract.probeWindowCount(menuAttached = false, petAttached = true))
        assertEquals(0, DualWindowProbeContract.probeWindowCount(menuAttached = false, petAttached = false))
    }

    @Test
    fun `启动日志契约块在有效时逐行完全匹配`() {
        val lines = DualWindowProbeContract.startContractLines(
            knownWindows = DualWindowProbeContract.EXPECTED_PROBE_WINDOW_COUNT,
            productionWindowAttached = false,
            probeValid = true,
        )
        assertEquals(
            listOf(
                "probe.dual knownWindows=2",
                "probe.dual productionAttached=false",
                "probe.dual add order=1 menu",
                "probe.dual add order=2 pet",
                "probe.dual probeValid=true",
            ),
            lines,
        )
    }

    @Test
    fun `启动日志契约块在无效时写出真值与原因码`() {
        val lines = DualWindowProbeContract.startContractLines(
            knownWindows = DualWindowProbeContract.EXPECTED_PROBE_WINDOW_COUNT,
            productionWindowAttached = true,
            probeValid = false,
            reason = DualWindowProbeContract.REASON_PRODUCTION_WINDOW_ATTACHED,
        )
        assertTrue(lines.contains("probe.dual productionAttached=true"))
        assertTrue(lines.contains("probe.dual probeValid=false"))
        assertTrue(
            lines.contains(
                "probe.dual probeInvalidReason=PROBE_INVALID_PRODUCTION_WINDOW_ATTACHED",
            ),
        )
    }

    @Test
    fun `停止摘要：两窗各移除一次、无重复桌宠窗口`() {
        val lines = DualWindowProbeContract.stopSummaryLines(
            menuRemoveCount = 1,
            petRemoveCount = 1,
            probeWindowCountAfterStop = 0,
            productionVisibleBefore = true,
            productionRestored = true,
            petWindowRecreateCount = 1,
            productionWindowAttached = true,
        )
        assertTrue(lines.contains("probe.dual productionVisibleBefore=true"))
        assertTrue(lines.contains("probe.dual productionRestored=true"))
        assertTrue(lines.contains("probe.dual petWindowRecreateCount=1"))
        assertTrue(lines.contains("probe.dual productionWindowAttached=true"))
        assertTrue(
            lines.any {
                it == "probe.dual probeRemove menu=1 pet=1 probeWindowCount=0 bothRemoved=true"
            },
        )
    }

    @Test
    fun `停止摘要：探测前隐藏则保持隐藏且不重建生产窗口`() {
        val lines = DualWindowProbeContract.stopSummaryLines(
            menuRemoveCount = 1,
            petRemoveCount = 1,
            probeWindowCountAfterStop = 0,
            productionVisibleBefore = false,
            productionRestored = true,
            petWindowRecreateCount = 0,
            productionWindowAttached = false,
        )
        assertTrue(lines.contains("probe.dual productionVisibleBefore=false"))
        assertTrue(lines.contains("probe.dual petWindowRecreateCount=0"))
        assertTrue(lines.contains("probe.dual productionWindowAttached=false"))
    }

    @Test
    fun `桌宠重建计数：只有 attach 真正新建才为 1（已挂载幂等返回 false 即 0）`() {
        assertEquals(
            "已挂载时 attach 幂等返回 false ⇒ 绝不重复建窗",
            0,
            DualWindowProbeContract.petWindowRecreateCount(attachCreated = false),
        )
        assertEquals(1, DualWindowProbeContract.petWindowRecreateCount(attachCreated = true))
    }

    // -----------------------------------------------------------------------
    // v2 修正：菜单只 add 一次 / 开关只是 updateViewLayout
    // -----------------------------------------------------------------------

    @Test
    fun `菜单从不重加：反复开关 50 轮 menuAddCount 恒为 1 且 menuWasReaddedAfterPet 恒为 false`() {
        val ledger = ProbeLayerLedger()
        ledger.recordAdd(ProbeWindowKind.MENU) // seq=1
        ledger.recordAdd(ProbeWindowKind.PET) // seq=2

        repeat(50) {
            // 关菜单 = updateViewLayout；开菜单 = updateViewLayout（**都不是** add/remove）。
            ledger.recordUpdate(ProbeWindowKind.MENU)
            ledger.recordUpdate(ProbeWindowKind.MENU)
        }

        assertEquals("菜单全程只 add 一次", 1, ledger.menuAddCount)
        assertEquals("菜单全程从未 removeView", 0, ledger.menuRemoveCount)
        assertEquals("桌宠全程只 add 一次", 1, ledger.petAddCount)
        assertEquals("桌宠全程从未 removeView", 0, ledger.petRemoveCount)
        assertFalse("菜单绝不能在桌宠之后被重加", ledger.menuWasReaddedAfterPet)
        assertTrue("菜单窗口始终挂载", ledger.menuAttached)
        assertEquals("全局操作序随每次操作单调递增", 102, ledger.addSequence)
    }

    @Test
    fun `期望顶层窗口由序列号推出：pet 后加即恒为 pet，菜单的 update 不会把它抬高`() {
        val ledger = ProbeLayerLedger()
        ledger.recordAdd(ProbeWindowKind.MENU) // seq=1
        ledger.recordAdd(ProbeWindowKind.PET) // seq=2

        assertEquals(1, ledger.menuLastAddSequence)
        assertEquals(2, ledger.petLastAddSequence)
        assertEquals(ProbeWindowKind.PET, ledger.currentExpectedTopWindow())

        // 菜单被反复 update（关闭/移动）：其"最后 add 序"必须保持为 1。
        repeat(20) { ledger.recordUpdate(ProbeWindowKind.MENU) }
        assertEquals("菜单 update 不改变其最后 add 序", 1, ledger.menuLastAddSequence)
        assertEquals(ProbeWindowKind.PET, ledger.currentExpectedTopWindow())
    }

    @Test
    fun `关闭态菜单窗口是 1×1 且贴在屏幕角落（内缩几px）`() {
        val corner = DualWindowProbePlanner.closedMenuRect(density)
        val inset = DualWindowProbePlanner.dp(density, DualWindowProbePlanner.CLOSED_MENU_INSET_DP)
        assertEquals(1, corner.width)
        assertEquals(1, corner.height)
        assertEquals(inset, corner.left)
        assertEquals(inset, corner.top)
        assertTrue("角落必须内缩，不能正好落在 (0,0)", inset >= 1)
    }

    // -----------------------------------------------------------------------
    // 锚点不变式：菜单矩形必须据桌宠"当前"矩形计算
    // -----------------------------------------------------------------------

    @Test
    fun `锚点不一致 ⇒ 结论立刻作废`() {
        val petA = OverlayRect(100, 100, 400, 400)
        val petB = OverlayRect(100, 900, 400, 1200)

        assertTrue(DualWindowProbeContract.anchorMatches(petA, petA))
        assertFalse("锚点与当前桌宠矩形不同必须判为不一致", DualWindowProbeContract.anchorMatches(petA, petB))
        assertFalse("锚点缺失也必须判为不一致", DualWindowProbeContract.anchorMatches(null, petA))

        assertTrue(DualWindowProbeContract.applyAnchorInvariant(storedProbeValid = true, anchorMatches = true))
        assertFalse(
            "anchorMatches=false ⇒ probeValid 必须为 false",
            DualWindowProbeContract.applyAnchorInvariant(storedProbeValid = true, anchorMatches = false),
        )
    }

    @Test
    fun `菜单矩形由桌宠当前矩形重算，而非缓存首次矩形`() {
        val first = OverlayRect(100, 100, 100 + 300, 100 + 300)
        val moved = OverlayRect(100, 1500, 100 + 300, 1500 + 300)

        val planFirst = DualWindowProbePlanner.plan(first, density, 1080, 2340)
        val planMoved = DualWindowProbePlanner.plan(moved, density, 1080, 2340)

        assertNotEquals("桌宠移动后菜单矩形必须随之改变", planFirst.menuRect, planMoved.menuRect)
        assertEquals("布局锚点即传入的当前桌宠矩形", moved, planMoved.petRect)
        assertTrue("菜单仍与桌宠重叠（层级可证明）", planMoved.menuRect.overlaps(moved))
        assertTrue(planMoved.buttonsInsideMenu())
    }

    @Test
    fun `左右镜像：桌宠在左半菜单向右、右半菜单向左`() {
        val leftPet = OverlayRect(50, 400, 350, 700) // centerX=200 < 540
        val rightPet = OverlayRect(700, 400, 1000, 700) // centerX=850 > 540

        assertEquals("right", DualWindowProbePlanner.plan(leftPet, density, 1080, 2340).menuDirection)
        assertEquals("left", DualWindowProbePlanner.plan(rightPet, density, 1080, 2340).menuDirection)
    }

    @Test
    fun `垂直偏置：桌宠贴近下边界时菜单改到其上方`() {
        val nearBottom = OverlayRect(100, 2200, 400, 2340)
        val plan = DualWindowProbePlanner.plan(nearBottom, density, 1080, 2340)

        assertEquals("above", plan.verticalMode)
        assertTrue("菜单仍与桌宠重叠", plan.menuRect.overlaps(nearBottom))
        assertTrue(plan.buttonsInsideMenu())
    }

    // -----------------------------------------------------------------------
    // 冻结状态 key 集（Flutter `getDualWindowProbeStatus` 契约）
    // -----------------------------------------------------------------------

    @Test
    fun `冻结状态 key 集恰好与契约完全一致（顺序即契约）`() {
        val expected = listOf(
            "probeValid", "productionWindowAttached", "probeWindowCount",
            "expectedProbeWindowCount", "totalKnownOverlayWindowCount", "petAddCount",
            "menuAddCount", "petLastAddSequence", "menuLastAddSequence", "addSequence",
            "currentExpectedTopWindow", "actualVisualTop", "menuWasReaddedAfterPet",
            "menuAttached", "menuTouchable", "menuAnchorPetRect", "currentPetScreenRect",
            "currentMenuWindowRect", "anchorMatchesCurrentPet", "menuDirection",
            "verticalMode", "clampedByScreen", "lastWindowOperation", "lastTouchReceiver",
            "orientation", "deviceModel", "sdkInt",
        )
        assertEquals(expected, DualWindowProbeContract.STATUS_KEYS)
        assertEquals(27, DualWindowProbeContract.STATUS_KEYS.size)
        assertEquals(
            "未运行时返回的 map 必须恰好是冻结 key 集",
            expected.toSet(),
            DualWindowProbeContract.emptyStatus().keys,
        )
    }

    @Test
    fun `未运行时的状态安全值：probeValid=false，其余 none 或 0 或 false`() {
        val status = DualWindowProbeContract.emptyStatus()

        assertEquals(false, status["probeValid"])
        assertEquals(0, status["probeWindowCount"])
        assertEquals(2, status["expectedProbeWindowCount"])
        assertEquals("none", status["menuAnchorPetRect"])
        assertEquals("none", status["currentMenuWindowRect"])
        assertEquals("none", status["lastWindowOperation"])
        assertEquals(false, status["menuWasReaddedAfterPet"])
        assertEquals(false, status["anchorMatchesCurrentPet"])
        assertEquals(0, status["sdkInt"])
    }

    @Test
    fun `矩形文本格式为 left,top w×h，缺失为 none`() {
        assertEquals("1,2 3×4", OverlayRect(1, 2, 4, 6).probeText())
        assertEquals("none", (null as OverlayRect?).probeText())
    }
}

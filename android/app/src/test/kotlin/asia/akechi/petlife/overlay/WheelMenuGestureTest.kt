package asia.akechi.petlife.overlay

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Phase 4C-6B-1：轮盘手势（**纯逻辑**）—— 覆盖需求 §18.3。
 *
 * 手势的核心是"角度判定 + 滞回 + 松手确认"三件事，全部与 Android 无关，
 * 因此可以在这里逐条打靶；真机上只需要确认"确实收到了这些事件"。
 */
class WheelMenuGestureTest {

    private val density = 2.75f
    private val spec = WheelMenuSpec.fromDensity(density)
    private val bounds = OverlayBounds(0, 60, 1080, 2310)
    private val petRect = OverlayRect(0, 1000, 264, 1264)

    private val gesture = WheelMenuGestureController(
        touchSlopPx = 8f * density,
        swipeSlopPx = 12f * density,
    )

    private lateinit var layout: WheelMenuLayout

    private fun prepare(level: WheelMenuLevel = WheelMenuCatalog.ROOT) {
        val env = WheelMenuGeometry.computeEnvelope(
            bounds = bounds,
            petWindowRect = petRect,
            content = null,
            maxItemCount = WheelMenuCatalog.maxItems,
            spec = spec,
            settings = WheelMenuLayoutSettings.DEFAULT,
        )
        layout = WheelMenuGeometry.layoutFor(env, level, spec)
        gesture.layout = layout
        gesture.selectedIndex = 0
        gesture.reset()
    }

    /** 某个槽位中心附近的点（用于"按在按钮上"）。 */
    private fun slotPoint(index: Int, radialOffset: Float = 0f): Pair<Float, Float> {
        val slot = layout.slots[index]
        val dx = slot.centerX - layout.centerX
        val dy = slot.centerY - layout.centerY
        val len = kotlin.math.hypot(dx.toDouble(), dy.toDouble()).toFloat().coerceAtLeast(1f)
        return Pair(
            slot.centerX + dx / len * radialOffset,
            slot.centerY + dy / len * radialOffset,
        )
    }

    /** 环带上某个角度（绝对角度）上的点。 */
    private fun ringPoint(absoluteAngleDeg: Float, radius: Float = 0f): Pair<Float, Float> {
        val r = if (radius > 0f) radius else layout.ringRadiusPx
        val rad = Math.toRadians(absoluteAngleDeg.toDouble())
        return Pair(
            layout.centerX + (r * kotlin.math.cos(rad)).toFloat(),
            layout.centerY + (r * kotlin.math.sin(rad)).toFloat(),
        )
    }

    private fun absoluteAngleOf(index: Int): Float = layout.slots[index].absoluteAngleDeg

    // --- 点击 --------------------------------------------------------------

    @Test
    fun `按在按钮上原地抬手就是点击该按钮`() {
        prepare()
        val (x, y) = slotPoint(2)
        gesture.onDown(x, y, 0L)
        val up = gesture.onUp(x + 2f, y + 2f, 60L)
        assertEquals(WheelGestureEffect.confirm, up.effect)
        assertEquals(2, up.index)
    }

    @Test
    fun `按在环带空白处（不在按钮上）也能进入选择`() {
        prepare()
        val (x, y) = ringPoint(absoluteAngleOf(1))
        gesture.onDown(x, y, 0L)
        val up = gesture.onUp(x, y, 50L)
        assertEquals(WheelGestureEffect.confirm, up.effect)
        assertNotNull(up.index)
    }

    // --- 圆弧滑选 ----------------------------------------------------------

    @Test
    fun `沿圆弧滑动时高亮跟随手指，并且每跨一个槽位只给一次轻触觉`() {
        prepare()
        val (x0, y0) = ringPoint(absoluteAngleOf(0))
        assertEquals(WheelGestureEffect.press, gesture.onDown(x0, y0, 0L).effect)

        var haptics = 0
        var lastIndex = gesture.highlightedIndex
        for (index in 1 until layout.itemCount) {
            val (x, y) = ringPoint(absoluteAngleOf(index))
            // 分两步移动，模拟手指真实轨迹
            val first = gesture.onMove(x, y, index * 16L)
            if (first.haptic) haptics += 1
            if (first.index != null) {
                assertTrue(
                    "一次最多前进一个槽位",
                    kotlin.math.abs(first.index!! - (lastIndex ?: 0)) <= 1,
                )
            }
            val outcome = gesture.onMove(x, y, index * 16L + 1)
            if (outcome.haptic) {
                assertTrue("跨槽必须给一次轻触觉", outcome.haptic)
                assertTrue(
                    "一次最多前进一个槽位",
                    kotlin.math.abs((outcome.index ?: 0) - (lastIndex ?: 0)) <= 1,
                )
                haptics += 1
            }
            lastIndex = gesture.highlightedIndex
        }
        assertTrue("至少跨过几个槽位（实际 $haptics）", haptics >= layout.itemCount - 2)
        assertEquals("最后一个槽位应当被高亮到", layout.itemCount - 1, gesture.highlightedIndex)
    }

    @Test
    fun `松手确认当前高亮项`() {
        prepare()
        val (x0, y0) = ringPoint(absoluteAngleOf(0))
        gesture.onDown(x0, y0, 0L)
        val (x3, y3) = ringPoint(absoluteAngleOf(3))
        gesture.onMove(x3, y3, 20L)
        gesture.onMove(x3, y3, 40L)
        val up = gesture.onUp(x3, y3, 60L)
        assertEquals(WheelGestureEffect.confirm, up.effect)
        assertEquals(3, up.index)
    }

    @Test
    fun `槽位滞回：手指停在边界附近时高亮不来回闪`() {
        prepare()
        val (x0, y0) = ringPoint(absoluteAngleOf(1))
        gesture.onDown(x0, y0, 0L)
        gesture.onMove(x0, y0, 10L)
        assertEquals(1, gesture.highlightedIndex)

        // 恰好越过 0.5 个槽位（边界）但未越过滞回带 → 必须保持
        val boundary = absoluteAngleOf(1) + layout.stepDeg * 0.5f
        val (xb, yb) = ringPoint(boundary + layout.stepDeg * 0.1f)
        val outcome = gesture.onMove(xb, yb, 20L)
        assertEquals("滞回带内不得切换", 1, gesture.highlightedIndex)
        assertFalse(outcome.haptic)
    }

    // --- 取消 --------------------------------------------------------------

    @Test
    fun `滑出环带太远则取消，不执行任何动作`() {
        prepare()
        val (x0, y0) = ringPoint(absoluteAngleOf(0))
        gesture.onDown(x0, y0, 0L)
        val (x1, y1) = ringPoint(absoluteAngleOf(1))
        gesture.onMove(x1, y1, 20L)

        // 移出环带外侧很远
        val far = layout.rimOuterPx + 400f
        val (xf, yf) = ringPoint(absoluteAngleOf(1), far)
        gesture.onMove(xf, yf, 30L)
        assertEquals("短暂离开先保持", WheelGestureEffect.none, gesture.onMove(xf, yf, 40L).effect)
        // 超过容差时间
        val late = gesture.onMove(xf, yf, 400L)
        assertEquals(WheelGestureEffect.cancel, late.effect)
        assertNull(gesture.highlightedIndex)

        val up = gesture.onUp(xf, yf, 420L)
        assertEquals("松手时已取消，不得确认", WheelGestureEffect.cancel, up.effect)
    }

    @Test
    fun `回到中心取消区松手不执行`() {
        prepare()
        val (x0, y0) = ringPoint(absoluteAngleOf(2))
        gesture.onDown(x0, y0, 0L)
        gesture.onMove(x0, y0, 10L)
        // 回到轮盘中心（缺口区）
        val center = Pair(layout.centerX, layout.centerY)
        gesture.onMove(center.first, center.second, 30L)
        val up = gesture.onUp(center.first, center.second, 60L)
        assertEquals(WheelGestureEffect.cancel, up.effect)
    }

    @Test
    fun `直接按在轮盘外并松手 = 关闭菜单`() {
        prepare()
        val outside = Pair(layout.centerX, layout.centerY - layout.rimOuterPx - 300f)
        assertEquals(WheelGestureEffect.none, gesture.onDown(outside.first, outside.second, 0L).effect)
        assertEquals(
            WheelGestureEffect.outsideTap,
            gesture.onUp(outside.first, outside.second, 40L).effect,
        )
    }

    @Test
    fun `中心缺口区按下松手也视为外部点击`() {
        prepare()
        val center = Pair(layout.centerX, layout.centerY)
        gesture.onDown(center.first, center.second, 0L)
        assertEquals(
            WheelGestureEffect.outsideTap,
            gesture.onUp(center.first, center.second, 40L).effect,
        )
    }

    @Test
    fun `多指介入一律取消，不产生动作`() {
        prepare()
        val (x, y) = slotPoint(1)
        gesture.onDown(x, y, 0L)
        assertEquals(WheelGestureEffect.cancel, gesture.onDown(x, y, 10L, pointerCount = 2).effect)
        assertEquals(WheelGestureEffect.cancel, gesture.onUp(x, y, 20L, pointerCount = 2).effect)
        assertNull(gesture.highlightedIndex)
    }

    @Test
    fun `按下后小范围抖动仍然算点击而不是滑选`() {
        prepare()
        val (x, y) = slotPoint(1)
        gesture.onDown(x, y, 0L)
        // 小于滑选阈值（12dp）
        gesture.onMove(x + 1f, y + 1f, 10L)
        assertFalse("还没超过滑选阈值就不该进入滑选", gesture.isSwiping)
        val up = gesture.onUp(x + 2f, y + 2f, 30L)
        assertEquals(WheelGestureEffect.confirm, up.effect)
    }

    @Test
    fun `快速甩动最多前进一个槽位`() {
        prepare()
        val (x0, y0) = ringPoint(absoluteAngleOf(0))
        gesture.onDown(x0, y0, 0L)
        val (x1, y1) = ringPoint(absoluteAngleOf(1))
        val outcome = gesture.onMove(x1, y1, 5L)
        if (outcome.effect == WheelGestureEffect.highlight) {
            assertTrue(
                "第一版不做惯性旋转，一次 MOVE 最多前进一项",
                (outcome.index ?: 0) - 0 <= 1,
            )
        }
        val up = gesture.onUp(x1, y1, 10L)
        assertEquals(WheelGestureEffect.confirm, up.effect)
        assertTrue((up.index ?: 0) <= 1)
    }

    @Test
    fun `相位区间：中心是取消区、环带是可选区、外圈是取消区`() {
        prepare()
        assertEquals(WheelZone.center, gesture.zoneAt(layout, layout.centerX, layout.centerY))
        val (rx, ry) = ringPoint(absoluteAngleOf(0))
        assertEquals(WheelZone.ring, gesture.zoneAt(layout, rx, ry))
        val (ox, oy) = ringPoint(absoluteAngleOf(0), layout.rimOuterPx + 50f)
        assertEquals(WheelZone.outside, gesture.zoneAt(layout, ox, oy))
    }

    // --- Phase 4C-6B-1.1：菜单在上层时，中央区域必须能转发拖动桌宠（需求 §3 / §7）---

    @Test
    fun `按在中央桌宠区域获得 petDrag 所有权并转发拖动`() {
        prepare()
        val (cx, cy) = Pair(layout.notchCenterX, layout.notchCenterY)
        assertEquals(WheelGestureEffect.none, gesture.onDown(cx, cy, 0L).effect)
        assertEquals("中央区域的手势归属必须是 petDrag", "petDrag", gesture.ownerName)

        // 超过滑选阈值 → 先 start，再 move
        val first = gesture.onMove(cx + 80f, cy + 80f, 20L)
        assertEquals(WheelGestureEffect.petDragStart, first.effect)
        assertEquals(WheelGestureEffect.petDragMove, gesture.onMove(cx + 120f, cy + 120f, 30L).effect)
        assertEquals(WheelGestureEffect.petDragEnd, gesture.onUp(cx + 140f, cy + 140f, 60L).effect)
    }

    @Test
    fun `在中央桌宠区域点一下（未拖动）视为关闭菜单`() {
        prepare()
        val (cx, cy) = Pair(layout.notchCenterX, layout.notchCenterY)
        gesture.onDown(cx, cy, 0L)
        assertEquals(
            WheelGestureEffect.outsideTap,
            gesture.onUp(cx + 1f, cy + 1f, 40L).effect,
        )
    }

    @Test
    fun `按钮区域的手势不会变成拖动桌宠`() {
        prepare()
        val (x, y) = slotPoint(2)
        gesture.onDown(x, y, 0L)
        assertEquals("pressing", gesture.ownerName)
        val outcome = gesture.onMove(x + 4f, y + 4f, 10L)
        assertTrue(
            "按钮区域绝不能触发拖动桌宠：${outcome.effect}",
            outcome.effect != WheelGestureEffect.petDragStart &&
                outcome.effect != WheelGestureEffect.petDragMove,
        )
    }

    @Test
    fun `视觉 alpha bounds 只影响缺口大小，不影响按钮命中`() {
        // 用两份不同的视觉边界各自建一次布局，比较同一个环带角度点的命中结果。
        val bounds = OverlayBounds(0, 60, 1080, 2310)
        val pet = OverlayRect(0, 1000, 264, 1264)
        fun layoutWith(content: PetContentBounds): WheelMenuLayout {
            val env = WheelMenuGeometry.computeEnvelope(
                bounds = bounds,
                petWindowRect = pet,
                content = content,
                maxItemCount = WheelMenuCatalog.maxItems,
                spec = spec,
                settings = WheelMenuLayoutSettings.DEFAULT,
            )
            return WheelMenuGeometry.layoutFor(env, WheelMenuCatalog.ROOT, spec)
        }
        val full = layoutWith(PetContentBounds.FULL)
        val trimmed = layoutWith(PetContentBounds(0.2f, 0.2f, 0.8f, 0.8f))
        // 缺口永远盖住桌宠可见矩形（alpha bounds 生效的体现）
        val visible = WheelMenuGeometry.petVisibleRect(pet, PetContentBounds(0.2f, 0.2f, 0.8f, 0.8f))
        assertTrue(
            "缺口必须盖住桌宠可见宽度：notch=${trimmed.notchRx} visible=${visible.width}",
            trimmed.notchRx * 2f >= visible.width - 0.01f,
        )
        // 按钮命中（角度判定）与 alpha bounds 无关：同一个槽位的绝对角度仍命中同一个下标
        assertEquals(3, gestureIndexIn(full, full.slots[3].absoluteAngleDeg))
        assertEquals(3, gestureIndexIn(trimmed, trimmed.slots[3].absoluteAngleDeg))
    }

    private fun gestureIndexIn(target: WheelMenuLayout, angleDeg: Float): Int? {
        gesture.layout = target
        gesture.reset()
        val rad = Math.toRadians(angleDeg.toDouble())
        val x = target.centerX + (target.ringRadiusPx * kotlin.math.cos(rad)).toFloat()
        val y = target.centerY + (target.ringRadiusPx * kotlin.math.sin(rad)).toFloat()
        return gesture.indexAt(target, x, y, null)
    }
}

/**
 * Phase 4C-6B-1：动画时钟与缓动 —— 覆盖需求 §18.4 中"时序"的部分。
 */
class WheelMenuAnimationTest {

    @Test
    fun `各段动画的时长与需求 §10 一致`() {
        assertEquals(300L, WheelAnimationTimeline.durationOf(WheelAnimationKind.open))
        assertEquals(220L, WheelAnimationTimeline.durationOf(WheelAnimationKind.selectionSwitch))
        assertEquals(300L, WheelAnimationTimeline.durationOf(WheelAnimationKind.enterLayer))
        assertEquals(230L, WheelAnimationTimeline.durationOf(WheelAnimationKind.exitLayer))
        assertEquals(180L, WheelAnimationTimeline.durationOf(WheelAnimationKind.close))
        assertEquals(70L, WheelAnimationTimeline.durationOf(WheelAnimationKind.press))
    }

    @Test
    fun `关闭比展开更快`() {
        assertTrue(
            WheelAnimationTimeline.CLOSE_MS < WheelAnimationTimeline.OPEN_MS,
        )
    }

    @Test
    fun `缓动函数端点正确且单调不减`() {
        for (easing in listOf(
            CubicBezierEasing.OPEN,
            CubicBezierEasing.SWITCH,
            CubicBezierEasing.CLOSE,
        )) {
            assertEquals(0f, easing.value(0f), 1e-3f)
            assertEquals(1f, easing.value(1f), 1e-3f)
            var previous = -1f
            for (step in 0..20) {
                val value = easing.value(step / 20f)
                assertTrue("缓动必须单调不减", value >= previous - 1e-3f)
                previous = value
            }
        }
    }

    @Test
    fun `展开动画从 0 到 1，关闭动画从 1 到 0`() {
        val open = WheelAnimationRun(
            kind = WheelAnimationKind.open,
            startedAtMs = 1_000L,
            fromSelection = 0f,
            toSelection = 0f,
            itemCount = 6,
        )
        assertEquals(0f, WheelAnimationClock.frame(open, 1_000L).openProgress, 1e-3f)
        assertEquals(1f, WheelAnimationClock.frame(open, 1_300L).openProgress, 1e-3f)
        assertFalse(WheelAnimationClock.isFinished(open, 1_299L))
        assertTrue(WheelAnimationClock.isFinished(open, 1_300L))

        val close = open.copy(kind = WheelAnimationKind.close, startedAtMs = 2_000L)
        assertEquals(1f, WheelAnimationClock.frame(close, 2_000L).openProgress, 1e-3f)
        assertEquals(0f, WheelAnimationClock.frame(close, 2_180L).openProgress, 1e-3f)
    }

    @Test
    fun `根选项切换是连续插值而不是瞬间换索引`() {
        val run = WheelAnimationRun(
            kind = WheelAnimationKind.selectionSwitch,
            startedAtMs = 0L,
            fromSelection = 0f,
            toSelection = 3f,
            itemCount = 6,
        )
        val start = WheelAnimationClock.frame(run, 0L).selectionPosition
        val mid = WheelAnimationClock.frame(run, 110L).selectionPosition
        val end = WheelAnimationClock.frame(run, 220L).selectionPosition
        assertEquals(0f, start, 1e-3f)
        assertTrue("中途必须处于两者之间，不能瞬间跳到 3", mid > 0.05f && mid < 2.95f)
        assertEquals(3f, end, 1e-3f)
    }

    @Test
    fun `展开时按钮错峰弹出，第一个早于最后一个`() {
        val run = WheelAnimationRun(
            kind = WheelAnimationKind.open,
            startedAtMs = 0L,
            fromSelection = 0f,
            toSelection = 0f,
            itemCount = 6,
        )
        val early = WheelAnimationClock.frame(run, 90L).buttonProgress
        assertTrue("第一个按钮应当已经动起来", early.first() > 0f)
        assertTrue("最后一个按钮应当还没动起来", early.last() < early.first())
        val done = WheelAnimationClock.frame(run, 300L).buttonProgress
        done.forEach { assertEquals(1f, it, 0.05f) }
    }

    @Test
    fun `动画结束帧不产生最终位置误差`() {
        val run = WheelAnimationRun(
            kind = WheelAnimationKind.selectionSwitch,
            startedAtMs = 100L,
            fromSelection = 2f,
            toSelection = 5f,
            itemCount = 6,
        )
        // 超过时长之后再取帧，仍然稳定落在目标位（不会继续漂）
        assertEquals(5f, WheelAnimationClock.frame(run, 10_000L).selectionPosition, 1e-4f)
    }

    @Test
    fun `换层动画的按钮进度不超过 1 且最终全部弹出`() {
        for (kind in listOf(WheelAnimationKind.enterLayer, WheelAnimationKind.exitLayer)) {
            val run = WheelAnimationRun(
                kind = kind,
                startedAtMs = 0L,
                fromSelection = 0f,
                toSelection = 0f,
                itemCount = 9,
            )
            val last = WheelAnimationClock.frame(run, WheelAnimationTimeline.durationOf(kind)).buttonProgress
            last.forEach {
                // 轻量回弹会略微过冲 —— 这是有意的（"弹起"），只要不失控即可。
                assertTrue("按钮进度必须在合理范围内：$it", it in -0.01f..1.2f)
            }
            assertTrue("最后一个按钮最终必须出现", last.last() > 0.9f)
        }
    }
}

/**
 * Phase 4C-6B-1：主题与配色（**纯函数**）—— 覆盖需求 §18.5 的算法部分。
 */
class WheelMenuThemeTest {

    @Test
    fun `默认主题就是需求 §13_1 给定的 P3P 粉色`() {
        val theme = WheelMenuThemes.default()
        assertEquals(WheelMenuThemes.ID_P3P, theme.themeId)
        assertEquals(0xFFF24D96.toInt(), theme.primary)
        assertEquals(0xFFFF8ABA.toInt(), theme.secondary)
        assertEquals(0xFFFFD8E9.toInt(), theme.background)
        assertEquals(0xFFFFD42A.toInt(), theme.highlight)
        assertEquals(0xFF111111.toInt(), theme.outline)
        assertEquals(0xFFFFFFFF.toInt(), theme.text)
        assertEquals(0xFF8E7180.toInt(), theme.disabled)
    }

    @Test
    fun `底色扇面由主题派生：每个预设都是半透明的同色系玫瑰`() {
        WheelMenuThemes.presets.forEach { preset ->
            val fan = WheelMenuThemes.baseFanColor(preset)
            val alpha = (fan ushr 24) and 0xFF
            assertTrue("${preset.themeId} 底色扇面必须约 40% 透明", alpha in 90..130)
            // 轨道带要比底色扇面**更亮**，否则两层会糊成一块。
            assertTrue(
                "${preset.themeId} 按钮轨道带必须比底色扇面更亮",
                WheelMenuThemes.relativeLuminance(preset.background) >
                    WheelMenuThemes.relativeLuminance(fan),
            )
        }
    }

    @Test
    fun `P3P 底色扇面是玫瑰粉：落在次色与背景色的连线上`() {
        val theme = WheelMenuThemes.default()
        val fan = WheelMenuThemes.baseFanColor(theme)
        assertEquals(WheelMenuThemes.BASE_FAN_ALPHA, (fan ushr 24) and 0xFF)
        val expectedRgb = WheelMenuThemes.mix(
            theme.secondary,
            theme.background,
            WheelMenuThemes.BASE_FAN_BLEND_TO_BACKGROUND,
        )
        assertEquals(expectedRgb and 0x00FFFFFF, fan and 0x00FFFFFF)
    }

    @Test
    fun `内置预设齐全（P3P 粉色-蓝色-红色-紫色-绿色）`() {
        val ids = WheelMenuThemes.presets.map { it.themeId }
        assertEquals(
            listOf("p3p-pink", "blue", "red", "purple", "green"),
            ids,
        )
        WheelMenuThemes.presets.forEach { preset ->
            assertTrue("${preset.themeId} 的文字要能看清", WheelMenuThemes.isLegible(preset))
            assertTrue(preset.displayName.isNotEmpty())
        }
    }

    @Test
    fun `P3P 主题的文字色自动选为白色且对比度达标`() {
        val theme = WheelMenuThemes.default()
        assertEquals(theme.text, WheelMenuThemes.autoTextColor(theme.primary))
        assertTrue(
            "主色上的文字对比度必须达标",
            WheelMenuThemes.contrastRatio(theme.text, theme.primary) >=
                WheelMenuThemes.MIN_TEXT_CONTRAST,
        )
    }

    @Test
    fun `对比度计算符合 WCAG 的已知取值`() {
        // 黑底白字 = 21:1，同色 = 1:1
        assertEquals(21.0, WheelMenuThemes.contrastRatio(0xFF000000.toInt(), 0xFFFFFFFF.toInt()), 0.1)
        assertEquals(1.0, WheelMenuThemes.contrastRatio(0xFF3366CC.toInt(), 0xFF3366CC.toInt()), 1e-6)
        // 顺序无关
        assertEquals(
            WheelMenuThemes.contrastRatio(0xFF000000.toInt(), 0xFFFFFFFF.toInt()),
            WheelMenuThemes.contrastRatio(0xFFFFFFFF.toInt(), 0xFF000000.toInt()),
            1e-9,
        )
    }

    @Test
    fun `自定义主色派生出完整色板，且是确定的`() {
        val a = WheelMenuThemes.custom(0xFF2F7CF6.toInt())
        val b = WheelMenuThemes.custom(0xFF2F7CF6.toInt())
        assertEquals(a, b)
        assertEquals(WheelMenuTheme.ID_CUSTOM, a.themeId)
        assertEquals(0xFF2F7CF6.toInt(), a.primary)
        assertEquals("描边固定为粗黑", WheelMenuThemes.OUTLINE_BLACK, a.outline)
        assertEquals("强调色固定为 P3P 黄", WheelMenuThemes.ACCENT_HIGHLIGHT, a.highlight)
        assertTrue("派生出的背景必须比主色亮", WheelMenuThemes.relativeLuminance(a.background) >
            WheelMenuThemes.relativeLuminance(a.primary))
        assertTrue("派生出的高光必须比主色亮", WheelMenuThemes.relativeLuminance(a.secondary) >
            WheelMenuThemes.relativeLuminance(a.primary))
    }

    @Test
    fun `浅色主色会自动选黑字`() {
        val light = WheelMenuThemes.custom(0xFFEFEFEF.toInt())
        assertEquals(0xFF000000.toInt(), light.text)
    }

    @Test
    fun `十六进制解析与格式化可以往返，非法输入返回 null`() {
        assertEquals(0xFFF24D96.toInt(), WheelMenuThemes.parseHex("#F24D96"))
        assertEquals(0xFFF24D96.toInt(), WheelMenuThemes.parseHex("F24D96"))
        assertEquals(0xFFF24D96.toInt(), WheelMenuThemes.parseHex("#FFF24D96"))
        assertNull(WheelMenuThemes.parseHex("#12345"))
        assertNull(WheelMenuThemes.parseHex("not-a-color"))
        assertNull(WheelMenuThemes.parseHex(null))
        assertEquals("#F24D96", WheelMenuThemes.toHex(0xFFF24D96.toInt()))
    }

    @Test
    fun `透明色被判定为不可用`() {
        assertFalse(WheelMenuThemes.isUsableColor(0x00F24D96))
        assertTrue(WheelMenuThemes.isUsableColor(0xFFF24D96.toInt()))
    }

    @Test
    fun `fromWire 对未知或缺失的主题回落到 P3P 粉色`() {
        assertEquals(WheelMenuThemes.ID_P3P, WheelMenuTheme.fromWire(null, 0).themeId)
        assertEquals(WheelMenuThemes.ID_P3P, WheelMenuTheme.fromWire("no-such", 0).themeId)
        assertEquals(
            WheelMenuTheme.ID_CUSTOM,
            WheelMenuTheme.fromWire(WheelMenuTheme.ID_CUSTOM, 0xFF123456.toInt()).themeId,
        )
        assertEquals(
            "P3P 粉色",
            WheelMenuTheme.fromWire(WheelMenuThemes.ID_P3P, 0, revision = 7L).displayName,
        )
        assertEquals(7L, WheelMenuTheme.fromWire(WheelMenuThemes.ID_P3P, 0, revision = 7L).revision)
    }

    @Test
    fun `颜色混合在两端返回原色`() {
        assertEquals(0xFF112233.toInt(), WheelMenuThemes.mix(0xFF112233.toInt(), 0xFFFFFFFF.toInt(), 0.0))
        assertEquals(0xFFFFFFFF.toInt(), WheelMenuThemes.mix(0xFF112233.toInt(), 0xFFFFFFFF.toInt(), 1.0))
    }
}

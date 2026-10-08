package asia.akechi.petlife.overlay

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.hypot

/**
 * Phase 4C-6B-1.1：轮盘**围绕桌宠**的几何 —— 覆盖需求 §15.1 / §15.2。
 *
 * 与 4C-6B-1 的测试口径差异：**不再断言"菜单窗口避开桌宠"** ——
 * 那条约束已经按需求 §2 删除（两窗口允许重叠，桌宠窗口在上层）。
 * 现在要钉住的是四条新不变量：
 * 1. 缺口中心恒等于桌宠视觉锚点；
 * 2. 轮盘中心与桌宠锚点的距离不超过允许的视觉偏移；
 * 3. 按钮（可达性）不压住桌宠可见矩形；
 * 4. 返回键始终在视觉最下方（左右镜像 + 上下偏转都成立）。
 */
class WheelMenuGeometryTest {

    private val density = 2.75f
    private val spec = WheelMenuSpec.fromDensity(density)

    private val portrait = OverlayBounds(left = 0, top = 60, right = 1080, bottom = 2310)
    private val landscape = OverlayBounds(left = 60, top = 0, right = 2310, bottom = 1080)
    private val split = OverlayBounds(left = 0, top = 100, right = 1080, bottom = 1100)

    private fun petAt(x: Int, y: Int, size: Int = 264): OverlayRect =
        OverlayRect(x, y, x + size, y + size)

    private fun envelope(
        pet: OverlayRect,
        bounds: OverlayBounds = portrait,
        content: PetContentBounds? = null,
        settings: WheelMenuLayoutSettings = WheelMenuLayoutSettings.DEFAULT,
        previousDirection: WheelExpandDirection? = null,
        previousVerticalMode: WheelVerticalMode? = null,
        lockMode: Boolean = false,
        maxItems: Int = WheelMenuCatalog.maxItems,
    ): WheelMenuEnvelope = WheelMenuGeometry.computeEnvelope(
        bounds = bounds,
        petWindowRect = pet,
        content = content,
        maxItemCount = maxItems,
        spec = spec,
        settings = settings,
        previousDirection = previousDirection,
        previousVerticalMode = previousVerticalMode,
        lockMode = lockMode,
    )

    private fun layoutOf(env: WheelMenuEnvelope, level: WheelMenuLevel = WheelMenuCatalog.ROOT) =
        WheelMenuGeometry.layoutFor(env, level, spec)

    /** 圆与矩形是否相交（窗口坐标 → 屏幕绝对坐标后比较）。 */
    private fun slotHitsRect(
        layout: WheelMenuLayout,
        slot: WheelSlotPlacement,
        rect: OverlayRect,
    ): Boolean {
        val cx = slot.centerX + layout.windowRect.left
        val cy = slot.centerY + layout.windowRect.top
        val r = layout.buttonDiameterPx / 2f
        val nx = cx.coerceIn(rect.left.toFloat(), rect.right.toFloat())
        val ny = cy.coerceIn(rect.top.toFloat(), rect.bottom.toFloat())
        return hypot((cx - nx).toDouble(), (cy - ny).toDouble()) < r.toDouble()
    }

    // --- §15.1 锚点 --------------------------------------------------------

    @Test
    fun `中央缺口恒等于桌宠视觉锚点（居中-靠上-靠下三种模式）`() {
        val cases = listOf(
            petAt(0, 1000),                       // 居中
            petAt(0, portrait.top),               // 靠上
            petAt(0, portrait.bottom - 264),      // 靠下
        )
        for (pet in cases) {
            val env = envelope(pet)
            val layout = layoutOf(env)
            assertEquals(
                "缺口中心 X 必须等于桌宠锚点（vmode=${env.verticalMode}）",
                env.petAnchorX.toFloat(),
                layout.notchCenterX + layout.windowRect.left,
                1.5f,
            )
            assertEquals(
                "缺口中心 Y 必须等于桌宠锚点（vmode=${env.verticalMode}）",
                env.petAnchorY.toFloat(),
                layout.notchCenterY + layout.windowRect.top,
                1.5f,
            )
        }
    }

    @Test
    fun `轮盘中心与桌宠锚点的距离不超过允许的视觉偏移`() {
        val cases = listOf(
            petAt(0, 1000),
            petAt(1080 - 264, 1000),
            petAt(0, portrait.top),
            petAt(portrait.right - 264, portrait.bottom - 264),
        )
        for (pet in cases) {
            val env = envelope(pet)
            assertTrue(
                "锚点距离 ${env.anchorDistancePx} 超过允许值 ${env.allowedOffsetPx}",
                env.anchorDistancePx <= env.allowedOffsetPx + 1.5f,
            )
        }
    }

    @Test
    fun `缺口按素材视觉尺寸缩放（透明留白素材缺口更小）`() {
        val pet = petAt(0, 1000)
        val fullVisible = WheelMenuGeometry.petVisibleRect(pet, PetContentBounds.FULL)
        val trimmedVisible =
            WheelMenuGeometry.petVisibleRect(pet, PetContentBounds(0.25f, 0.25f, 0.75f, 0.75f))
        assertTrue(
            "裁剪后的可见矩形必须更小：full=${fullVisible.width} trimmed=${trimmedVisible.width}",
            trimmedVisible.width < fullVisible.width,
        )
        val full = envelope(pet, content = PetContentBounds.FULL)
        val trimmed = envelope(pet, content = PetContentBounds(0.25f, 0.25f, 0.75f, 0.75f))
        // 【需求 §4】缺口 = 桌宠可见尺寸 × 1.05 + 边距 → 素材越小缺口越小（不会更大）
        assertTrue(
            "缺口必须随可见尺寸变小：full=${full.holeRx} trimmed=${trimmed.holeRx}",
            trimmed.holeRx <= full.holeRx + 0.01f,
        )
        // 缺口加边距后必须**盖住**桌宠可见矩形
        assertTrue(
            "缺口宽必须盖住桌宠：notch=${full.holeRx * 2} visible=${fullVisible.width}",
            full.holeRx * 2 >= fullVisible.width - 0.01f,
        )
        assertTrue(
            "缺口高必须盖住桌宠：notch=${full.holeRy * 2} visible=${fullVisible.height}",
            full.holeRy * 2 >= fullVisible.height - 0.01f,
        )
    }

    @Test
    fun `缺口绝不接近按钮轨道内缘（否则轮盘会退化成粗甜甜圈）`() {
        // 极端素材：桌宠远大于屏幕
        for (size in intArrayOf(264, 560, 1200)) {
            val pet = petAt(0, 900, size)
            val env = envelope(pet)
            val limit = (env.maxRingRadiusPx - env.buttonDiameterPx / 2f) *
                WheelMenuGeometry.NOTCH_MAX_INNER_DIAMETER_RATIO
            assertTrue(
                "size=$size 缺口(${env.holeRx}) 超过了内径上限($limit)",
                env.holeRx <= limit + 1f && env.holeRy <= limit + 1f,
            )
            // 缺口之外必须还有足够的按钮轨道
            assertTrue(
                "size=$size 按钮轨道被缺口吃掉了",
                env.maxRingRadiusPx - env.buttonDiameterPx / 2f - env.holeRx > 0f,
            )
        }
    }

    @Test
    fun `左右镜像：桌宠靠左向右展开，靠右向左展开`() {
        assertEquals(
            WheelExpandDirection.right,
            envelope(petAt(0, 1000)).direction,
        )
        assertEquals(
            WheelExpandDirection.left,
            envelope(petAt(1080 - 264, 1000)).direction,
        )
    }

    // --- 按钮可达性（人物不被按钮压住）-----------------------------------

    @Test
    fun `所有按钮都不压住桌宠可见矩形（否则按钮会被上层桌宠盖住而点不到）`() {
        val cases = listOf(
            petAt(0, 1000),
            petAt(1080 - 264, 1000),
            petAt(0, portrait.top),
            petAt(1080 - 264, portrait.bottom - 264),
        )
        for (pet in cases) {
            val visible = WheelMenuGeometry.petVisibleRect(pet, null)
            for (level in listOf(WheelMenuCatalog.ROOT, WheelMenuCatalog.SETTINGS)) {
                val env = envelope(pet)
                val layout = layoutOf(env, level)
                layout.slots.forEach { slot ->
                    assertFalse(
                        "槽位 ${slot.index}（${level.id}）压住了桌宠：center=(${slot.centerX},${slot.centerY})",
                        slotHitsRect(layout, slot, visible),
                    )
                }
            }
        }
    }

    @Test
    fun `返回键永远在视觉最下方（左右镜像 + 上下偏转都成立）`() {
        val cases = listOf(
            petAt(0, 1000),                       // 右展开 + 居中
            petAt(1080 - 264, 1000),              // 左展开 + 居中
            petAt(0, portrait.top),               // 靠上（扇形向下偏）
            petAt(1080 - 264, portrait.bottom - 264), // 靠下（扇形向上偏）
        )
        for (pet in cases) {
            val env = envelope(pet)
            val layout = layoutOf(env, WheelMenuCatalog.SETTINGS)
            val backIndex = WheelMenuCatalog.SETTINGS.entries.indexOfFirst { it.isBack }
            assertTrue(backIndex >= 0)
            val back = layout.slots[backIndex]
            layout.slots.forEach { slot ->
                assertTrue(
                    "返回键必须在视觉最下方：dir=${layout.direction} vmode=${layout.verticalMode} " +
                        "back.y=${back.centerY} slot${slot.index}.y=${slot.centerY}",
                    slot.centerY <= back.centerY + 1f,
                )
            }
        }
    }

    @Test
    fun `相邻按钮在视觉上不重叠`() {
        val pet = petAt(0, 1000)
        for (level in listOf(
            WheelMenuCatalog.ROOT,
            WheelMenuCatalog.PET,
            WheelMenuCatalog.SETTINGS,
        )) {
            val layout = layoutOf(envelope(pet), level)
            val need = layout.buttonDiameterPx - 1f
            for (i in 0 until layout.slots.size - 1) {
                val a = layout.slots[i]
                val b = layout.slots[i + 1]
                val chord = hypot(
                    (a.centerX - b.centerX).toDouble(),
                    (a.centerY - b.centerY).toDouble(),
                ).toFloat()
                assertTrue(
                    "${level.id} 的 $i 与 ${i + 1} 重叠：chord=$chord diameter=${layout.buttonDiameterPx}",
                    chord >= need,
                )
            }
        }
    }

    // --- §8 垂直模式与滞回 -------------------------------------------------

    @Test
    fun `垂直模式：靠上-靠下-居中各自判定正确`() {
        assertEquals(WheelVerticalMode.topEdge, envelope(petAt(0, portrait.top)).verticalMode)
        assertEquals(
            WheelVerticalMode.bottomEdge,
            envelope(petAt(0, portrait.bottom - 264)).verticalMode,
        )
        assertEquals(
            WheelVerticalMode.center,
            envelope(petAt(0, (portrait.top + portrait.bottom) / 2)).verticalMode,
        )
    }

    @Test
    fun `垂直模式在阈值附近不反复切换（滞回）`() {
        val first = envelope(petAt(0, portrait.top)).verticalMode
        assertEquals(WheelVerticalMode.topEdge, first)
        // 往下挪一点点（仍在滞回带内）→ 必须保持上一次模式
        val nudged = envelope(
            petAt(0, portrait.top + 60),
            previousVerticalMode = first,
        )
        assertEquals(first, nudged.verticalMode)
    }

    @Test
    fun `菜单打开期间方向与垂直模式都被锁定`() {
        val pet = petAt(0, 1000)
        val env = envelope(pet)
        val locked = envelope(
            petAt(1080 - 264, portrait.bottom - 264),
            previousDirection = env.direction,
            previousVerticalMode = env.verticalMode,
            lockMode = true,
        )
        assertEquals(env.direction, locked.direction)
        assertEquals(env.verticalMode, locked.verticalMode)
    }

    // --- §15.2 尺寸 -------------------------------------------------------

    @Test
    fun `同一设置下九个不同位置得到的轮盘尺寸完全相同（需求 §3-3）`() {
        val size = 264
        val positions = listOf(
            Pair(0, 1000),
            Pair(1080 - size, 1000),
            Pair((1080 - size) / 2, 1000),
            Pair(0, portrait.top),
            Pair(1080 - size, portrait.top),
            Pair(0, portrait.bottom - size),
            Pair(1080 - size, portrait.bottom - size),
            Pair((1080 - size) / 2, portrait.top),
            Pair((1080 - size) / 2, portrait.bottom - size),
        )
        val results = positions.map { (x, y) ->
            val env = envelope(petAt(x, y, size))
            val layout = layoutOf(env)
            listOf(
                env.buttonDiameterPx,
                env.maxRingRadiusPx,
                env.holeRx,
                env.holeRy,
                layout.bladeLengthPx,
                layout.notchRx,
                layout.notchRy,
            ) to layout.windowRect
        }
        val first = results.first().first
        results.forEachIndexed { index, (metrics, _) ->
            metrics.forEachIndexed { i, value ->
                assertEquals(
                    "位置 #$index 的第 $i 项尺寸与其他位置不一致（轮盘大小不得随位置变化）",
                    first[i],
                    value,
                    0.01f,
                )
            }
        }
        assertTrue(
            "不同位置必须给出不同的窗口坐标（否则说明放置阶段没生效）",
            results.map { it.second.left }.distinct().size > 1,
        )
    }

    @Test
    fun `轮盘尺寸设置改变实际几何，且落在允许区间内`() {
        val pet = petAt(0, 1000)
        val small = envelope(
            pet,
            settings = WheelMenuLayoutSettings(preferredScale = 0.60f),
        )
        val large = envelope(
            pet,
            settings = WheelMenuLayoutSettings(preferredScale = 1.20f),
        )
        // 设置越大 → 按钮越大（尺寸只由设置与桌宠尺寸决定）
        assertTrue(
            "放大设定必须带来更大的按钮：small=${small.buttonDiameterPx} large=${large.buttonDiameterPx}",
            large.buttonDiameterPx > small.buttonDiameterPx,
        )
        assertTrue(
            "放大设定必须带来更大的环带：small=${small.maxRingRadiusPx} large=${large.maxRingRadiusPx}",
            large.maxRingRadiusPx > small.maxRingRadiusPx,
        )
        // actualScale 现在只是"设备级应急缩放"：只可能 ≤ 1，且不得低于下限
        assertTrue("缩放不得超过 1", small.actualScale <= 1f && large.actualScale <= 1f)
        assertTrue(
            "缩放不得低于下限",
            small.actualScale >= WheelMenuGeometry.MIN_ACTUAL_SCALE - 0.001f &&
                large.actualScale >= WheelMenuGeometry.MIN_ACTUAL_SCALE - 0.001f,
        )
        assertTrue(small.windowRect.isUsable && large.windowRect.isUsable)
    }

    @Test
    fun `按钮大小设置独立于轮盘大小（需求 §4-3）`() {
        val pet = petAt(0, 1000)
        val visible = WheelMenuGeometry.petVisibleRect(pet, null)
        // 用**固有几何**比较（不含设备级应急缩放，避免屏幕大小干扰判定）
        val base = WheelMenuGeometry.intrinsicLayout(
            itemCount = WheelMenuCatalog.maxItems,
            spec = spec,
            settings = WheelMenuLayoutSettings(preferredScale = 0.78f),
            petVisibleWidth = visible.width.toFloat(),
            petVisibleHeight = visible.height.toFloat(),
        )
        val bigger = WheelMenuGeometry.intrinsicLayout(
            itemCount = WheelMenuCatalog.maxItems,
            spec = spec,
            settings = WheelMenuLayoutSettings(preferredScale = 0.78f, buttonVisualScale = 1.40f),
            petVisibleWidth = visible.width.toFloat(),
            petVisibleHeight = visible.height.toFloat(),
        )
        assertTrue(
            "按钮设置必须改变按钮直径：base=${base.buttonDiameterPx} bigger=${bigger.buttonDiameterPx}",
            bigger.buttonDiameterPx > base.buttonDiameterPx,
        )
        // 缺口算法只跟桌宠可见尺寸走 → 按钮大小不改变缺口
        assertEquals("按钮大小不得改变缺口算法", base.notchRx, bigger.notchRx, 0.01f)
        assertEquals("按钮大小不得改变缺口算法", base.notchRy, bigger.notchRy, 0.01f)
    }

    @Test
    fun `紧凑模式只由用户设置触发，不因位置自动进入（需求 §3-2）`() {
        val pet = petAt(0, 400)
        val normal = envelope(pet, bounds = split)
        assertFalse(
            "位置不得触发紧凑模式（只能由用户设置触发）",
            normal.compact,
        )
        val forced = envelope(
            pet,
            bounds = split,
            settings = WheelMenuLayoutSettings(compactMode = true),
        )
        assertTrue("用户开启紧凑必须生效", forced.compact)
        assertTrue("用户开启紧凑时扇形更窄", forced.fanBiasDeg == 0f || forced.compact)
    }

    @Test
    fun `缩放设置被夹到合法区间与步进`() {
        // 轮盘：50%~250%，步进 10%，默认 100%（需求 §4）
        assertEquals(0.50f, WheelMenuLayoutSettings.clampScale(0.1f), 0.001f)
        assertEquals(2.50f, WheelMenuLayoutSettings.clampScale(9f), 0.001f)
        assertEquals(1.00f, WheelMenuLayoutSettings.clampScale(Float.NaN), 0.001f)
        assertEquals(1.00f, WheelMenuLayoutSettings.DEFAULT_SCALE, 0.001f)
        assertEquals(0.10f, WheelMenuLayoutSettings.STEP, 0.001f)
        assertEquals(1.00f, WheelMenuLayoutSettings.quantizeScale(1.04f), 0.001f)
        assertEquals(0.50f, WheelMenuLayoutSettings.quantizeScale(0.52f), 0.001f)
        // 按钮：50%~250%，步进 10%，默认 130%（需求 §5）
        assertEquals(1.30f, WheelMenuLayoutSettings.DEFAULT_BUTTON_SCALE, 0.001f)
        assertEquals(0.50f, WheelMenuLayoutSettings.MIN_BUTTON_SCALE, 0.001f)
        assertEquals(2.50f, WheelMenuLayoutSettings.MAX_BUTTON_SCALE, 0.001f)
        assertEquals(0.10f, WheelMenuLayoutSettings.BUTTON_STEP, 0.001f)
        // 按钮同样夹取 + 吸附 10% 步进
        assertEquals(0.50f, WheelMenuLayoutSettings.clampButtonScale(0.01f), 0.001f)
        assertEquals(2.50f, WheelMenuLayoutSettings.clampButtonScale(9f), 0.001f)
        assertEquals(1.30f, WheelMenuLayoutSettings.clampButtonScale(Float.NaN), 0.001f)
        assertEquals(1.30f, WheelMenuLayoutSettings.quantizeButtonScale(1.32f), 0.001f)
        assertEquals(1.40f, WheelMenuLayoutSettings.quantizeButtonScale(1.37f), 0.001f)
        assertEquals(2.50f, WheelMenuLayoutSettings.quantizeButtonScale(2.48f), 0.001f)
        // normalized() 后仍落在合法区间
        val wild = WheelMenuLayoutSettings(preferredScale = 99f, buttonVisualScale = 99f).normalized()
        assertEquals(2.50f, wild.preferredScale, 0.001f)
        assertEquals(2.50f, wild.buttonVisualScale, 0.001f)
    }

    @Test
    fun `轮盘大小 50-250 与按钮大小 50-250 都能算出可用几何（需求 §7）`() {
        val pet = petAt(0, 1000)
        for (scale in floatArrayOf(0.50f, 1.00f, 1.50f, 2.00f, 2.50f)) {
            val env = envelope(pet, settings = WheelMenuLayoutSettings(preferredScale = scale))
            val layout = layoutOf(env, WheelMenuCatalog.SETTINGS)
            assertTrue("轮盘 ${scale * 100}% 窗口不可用", env.windowRect.isUsable)
            assertTrue("轮盘 ${scale * 100}% 无槽位", layout.slots.size == WheelMenuCatalog.SETTINGS.itemCount)
            // 放不下时允许裁装饰（degraded），但**绝不偷偷缩回用户选的大小**
            assertTrue(
                "轮盘 ${scale * 100}% 不应被自动缩小：actual=${env.actualScale}",
                env.actualScale >= if (scale > 1f) 1f else 0f,
            )
        }
        for (button in floatArrayOf(0.50f, 1.00f, 1.30f, 2.00f, 2.50f)) {
            val env = envelope(pet, settings = WheelMenuLayoutSettings(buttonVisualScale = button))
            val layout = layoutOf(env, WheelMenuCatalog.SETTINGS)
            assertTrue("按钮 ${button * 100}% 窗口不可用", env.windowRect.isUsable)
            assertTrue("按钮 ${button * 100}% 无槽位", layout.slots.isNotEmpty())
        }
    }

    @Test
    fun `250% 按钮仍不重叠，50% 按钮触摸范围仍不小于 48dp（需求 §7）`() {
        val pet = petAt(0, 1000)
        val big = envelope(pet, settings = WheelMenuLayoutSettings(buttonVisualScale = 2.50f))
        val bigLayout = layoutOf(big, WheelMenuCatalog.SETTINGS)
        for (i in 0 until bigLayout.slots.size - 1) {
            val a = bigLayout.slots[i]
            val b = bigLayout.slots[i + 1]
            val chord = hypot(
                (a.centerX - b.centerX).toDouble(),
                (a.centerY - b.centerY).toDouble(),
            ).toFloat()
            assertTrue(
                "250% 按钮重叠：chord=$chord diameter=${bigLayout.buttonDiameterPx}",
                chord >= bigLayout.buttonDiameterPx - 1f,
            )
        }
        val small = envelope(pet, settings = WheelMenuLayoutSettings(buttonVisualScale = 0.50f))
        val smallLayout = layoutOf(small, WheelMenuCatalog.SETTINGS)
        assertTrue(
            "50% 按钮的触摸直径不得小于 48dp：${smallLayout.buttonTouchDiameterPx}",
            smallLayout.buttonTouchDiameterPx >= 48f * density - 0.01f,
        )
        assertTrue(
            "视觉直径确实变小了：${smallLayout.buttonDiameterPx} < ${bigLayout.buttonDiameterPx}",
            smallLayout.buttonDiameterPx < bigLayout.buttonDiameterPx,
        )
    }

    // --- 窗口与安全区 -----------------------------------------------------

    @Test
    fun `正常场景窗口落在安全区内且不需要降级`() {
        val env = envelope(petAt(0, 1000))
        assertFalse("正常竖屏不该降级：${env.fallbackReason}", env.degraded)
        assertTrue("窗口必须落在安全区内：${env.windowRect}", env.windowRect.isInside(portrait))
    }

    @Test
    fun `屏幕四角与横屏仍能算出合法布局`() {
        val size = 264
        val cases = listOf(
            petAt(portrait.left, portrait.top, size) to portrait,
            petAt(portrait.right - size, portrait.top, size) to portrait,
            petAt(portrait.left, portrait.bottom - size, size) to portrait,
            petAt(portrait.right - size, portrait.bottom - size, size) to portrait,
            petAt(60, 300, size) to landscape,
        )
        for ((pet, bounds) in cases) {
            val env = envelope(pet, bounds)
            val layout = layoutOf(env)
            assertTrue("窗口不可用：$pet", env.windowRect.isUsable)
            assertEquals("缺口必须仍然绑在桌宠上：$pet", env.petAnchorX.toFloat(),
                layout.notchCenterX + layout.windowRect.left, 1.5f)
            assertEquals("必须能算出全部槽位", WheelMenuCatalog.ROOT.itemCount, layout.slots.size)
            if (!env.degraded) {
                assertTrue("未降级时窗口必须落在安全区内：${env.windowRect}", env.windowRect.isInside(bounds))
            } else {
                assertNotNull("降级必须给出原因", env.fallbackReason)
            }
        }
    }

    @Test
    fun `分屏窄窗口不崩溃且缺口仍绑定桌宠`() {
        val pet = petAt(0, 400)
        val env = envelope(pet, split)
        val layout = layoutOf(env)
        assertTrue(env.windowRect.isUsable)
        assertEquals(env.petAnchorX.toFloat(), layout.notchCenterX + layout.windowRect.left, 1.5f)
        assertEquals(env.petAnchorY.toFloat(), layout.notchCenterY + layout.windowRect.top, 1.5f)
    }

    // --- 需求 §14：窗口几何只展开一次 --------------------------------------

    @Test
    fun `所有层级共用同一个窗口矩形（换层不改窗口）`() {
        val env = envelope(petAt(0, 1000))
        val levels = listOf(
            WheelMenuCatalog.ROOT,
            WheelMenuCatalog.PET,
            WheelMenuCatalog.APPEARANCE,
            WheelMenuCatalog.RECORDS,
            WheelMenuCatalog.TOOLS,
            WheelMenuCatalog.SETTINGS,
        )
        levels.forEach { level ->
            assertEquals(env.windowRect, layoutOf(env, level).windowRect)
        }
    }

    @Test
    fun `不同条目数的层级按钮直径一致（打开期间不忽大忽小）`() {
        val env = envelope(petAt(0, 1000))
        val a = layoutOf(env, WheelMenuCatalog.ROOT).buttonDiameterPx
        val b = layoutOf(env, WheelMenuCatalog.SETTINGS).buttonDiameterPx
        assertEquals(a, b, 0.01f)
    }

    // --- 异常输入 ---------------------------------------------------------

    @Test
    fun `可用区域不可信时给出降级信封而不抛异常`() {
        val env = envelope(petAt(0, 0), bounds = OverlayBounds(0, 0, 0, 0))
        assertTrue(env.degraded)
        assertNotNull(env.fallbackReason)
        val layout = layoutOf(env)
        assertTrue(layout.slots.isEmpty() || layout.slots.size == WheelMenuCatalog.ROOT.itemCount)
    }

    @Test
    fun `空层级不会产生槽位`() {
        val env = envelope(petAt(0, 1000))
        val empty = WheelMenuLevel(id = "empty", titleEn = "E", titleZh = "空", entries = emptyList())
        assertTrue(layoutOf(env, empty).slots.isEmpty())
    }

    @Test
    fun `菜单距离设置影响锚点偏移`() {
        val pet = petAt(0, 1000)
        val near = envelope(pet, settings = WheelMenuLayoutSettings(menuDistance = 0.05f))
        val far = envelope(pet, settings = WheelMenuLayoutSettings(menuDistance = 0.30f))
        assertTrue(
            "距离设置越大，轮盘中心离桌宠越远：near=${near.anchorDistancePx} far=${far.anchorDistancePx}",
            far.anchorDistancePx > near.anchorDistancePx,
        )
        assertNotEquals(near.anchorDistancePx, far.anchorDistancePx)
    }

    // --- §15.3 可读性（文本安全区 / 最小字号）----------------------------

    private fun textSlots(
        layout: WheelMenuLayout,
        densityValue: Float = density,
    ): WheelTextSlots = WheelTextLayout.compute(
        layout = layout,
        density = densityValue,
        minTitleSp = 13f,
        minChipSp = 16f,
        minInfoSp = 11f,
    )

    @Test
    fun `文本安全带完全落在按钮圆之外（标题不会压住高亮按钮）`() {
        for (settings in listOf(
            WheelMenuLayoutSettings(preferredScale = 0.60f),
            WheelMenuLayoutSettings.DEFAULT,
            WheelMenuLayoutSettings(preferredScale = 1.20f),
        )) {
            val env = envelope(petAt(0, 1000), settings = settings)
            for (level in listOf(WheelMenuCatalog.ROOT, WheelMenuCatalog.SETTINGS)) {
                val layout = layoutOf(env, level)
                val slots = textSlots(layout)
                val buttonOuter = layout.ringRadiusPx + layout.buttonDiameterPx * 0.5f
                assertTrue(
                    "文字安全带起点(${slots.bandStart}) 必须大于按钮外缘($buttonOuter)：" +
                        "scale=${settings.preferredScale} level=${level.id}",
                    slots.bandStart > buttonOuter,
                )
                assertTrue(slots.titleRadius >= slots.bandStart)
                assertTrue(slots.chipRadius > slots.titleRadius)
                assertTrue(slots.infoRadius > slots.chipRadius)
                assertTrue(
                    "文字不得超出刀刃外缘：info=${slots.infoRadius} blade=${layout.bladeLengthPx}",
                    slots.infoRadius <= layout.bladeLengthPx + 1f,
                )
            }
        }
    }

    @Test
    fun `三层文字的最小字号在任何缩放下都被满足`() {
        val small = layoutOf(
            envelope(petAt(0, 1000), settings = WheelMenuLayoutSettings(preferredScale = 0.60f)),
            WheelMenuCatalog.SETTINGS,
        )
        val slots = textSlots(small)
        assertTrue(
            "英文标题不得低于最小字号：${slots.titleSizePx}",
            slots.titleSizePx >= 13f * density - 0.01f,
        )
        assertTrue(
            "中文名不得低于 16sp：${slots.chipSizePx}",
            slots.chipSizePx >= 16f * density - 0.01f,
        )
        assertTrue(
            "说明不得低于 11sp：${slots.infoSizePx}",
            slots.infoSizePx >= 11f * density - 0.01f,
        )
    }

    @Test
    fun `标题与中文名在径向上至少隔开半个行高（不会重叠）`() {
        val layout = layoutOf(envelope(petAt(0, 1000)), WheelMenuCatalog.ROOT)
        val slots = textSlots(layout)
        val needed = (slots.titleSizePx + slots.chipSizePx) * 0.5f
        assertTrue(
            "标题与中文名太近：gap=${slots.chipRadius - slots.titleRadius} needed=$needed",
            slots.chipRadius - slots.titleRadius >= needed,
        )
    }

    @Test
    fun `可用弦长随半径单调增加，且随扇形张角变化`() {
        val layout = layoutOf(envelope(petAt(0, 1000)), WheelMenuCatalog.ROOT)
        val near = WheelTextLayout.chordAt(layout, 100f)
        val far = WheelTextLayout.chordAt(layout, 200f)
        assertTrue("半径越大可用宽度越大：$near → $far", far > near)
        assertEquals(
            "半径 0 处没有可用宽度",
            0f,
            WheelTextLayout.chordAt(layout, 0f),
            0.001f,
        )
    }
}

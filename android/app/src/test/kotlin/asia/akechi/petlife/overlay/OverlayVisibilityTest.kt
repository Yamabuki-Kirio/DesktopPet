package asia.akechi.petlife.overlay

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

/**
 * Phase 4C-2 真机缺陷后的**可见性回归测试**（纯逻辑，可 JVM 单测）。
 *
 * 复盘的缺陷链：
 * ```
 * onMeasure 只调 setMeasuredDimension（没调 super）
 *   → ImageView 的 measuredWidth 恒为 0
 *   → onLayout 把它摆成 0×0
 *   → 成功贴图后 background = null，唯一的可见元素消失
 *   → 服务在跑、通知在，但窗口完全看不见
 * ```
 * 这里把"永远有尺寸、永远可见"的不变式固化成断言。
 *
 * 需要真机 Bitmap / View 测量的部分（真实解码、requestLayout 后的实测尺寸）
 * **不在这里冒充通过**，见 docs/35 §5 的阻塞说明。
 */
class OverlayVisibilityTest {

    // --- 1 / 8：尺寸永不为 0 -------------------------------------------------

    @Test
    fun `无 Drawable 时请求的边长也会被抬到最小可见尺寸`() {
        assertEquals(OverlayGeometry.MIN_VIEW_PX, OverlayGeometry.safeViewSize(0))
        assertEquals(OverlayGeometry.MIN_VIEW_PX, OverlayGeometry.safeViewSize(-100))
        assertEquals(240, OverlayGeometry.safeViewSize(240))
        assertTrue(OverlayGeometry.safeViewSize(0) > 0)
    }

    @Test
    fun `屏幕指标或密度异常时窗口边长仍不为 0`() {
        assertTrue(OverlayGeometry.viewSizePx(1f, 3f, 0, 0) > 0)
        assertTrue(OverlayGeometry.viewSizePx(0f, 0f, 0, 0) >= OverlayGeometry.MIN_VIEW_PX)
        assertTrue(OverlayGeometry.viewSizePx(0.5f, 0f, 0, 0) >= OverlayGeometry.MIN_VIEW_PX)
        assertTrue(OverlayGeometry.viewSizePx(9f, 2f, 320, 0) >= OverlayGeometry.MIN_VIEW_PX)
    }

    // --- 2 / 3 / 4 / 9 / 10：可见状态决策 ------------------------------------

    @Test
    fun `加载中仍未显示完整占位，窗口保持可见`() {
        val visual = OverlayVisualPolicy.resolve(
            hasImage = false,
            loading = true,
            lastError = null,
        )
        assertEquals(OverlayVisual.loading, visual)
        assertTrue("加载中必须有可见占位底", OverlayVisualPolicy.showsPlaceholderChrome(visual))
        assertEquals("加载中…", OverlayVisualPolicy.placeholderText(visual))
    }

    @Test
    fun `解码失败显示错误占位而不是全透明窗口`() {
        val visual = OverlayVisualPolicy.resolve(
            hasImage = false,
            loading = false,
            lastError = "decode_failed: 图片解码失败",
        )
        assertEquals(OverlayVisual.failure, visual)
        assertTrue(OverlayVisualPolicy.showsPlaceholderChrome(visual))
        assertEquals("素材加载失败", OverlayVisualPolicy.placeholderText(visual))
    }

    @Test
    fun `路径校验失败同样落到可见的错误占位`() {
        val visual = OverlayVisualPolicy.resolve(
            hasImage = false,
            loading = false,
            lastError = "outside_private_root: 素材必须位于 PetLife 应用私有素材目录内",
        )
        assertEquals(OverlayVisual.failure, visual)
        assertTrue(OverlayVisualPolicy.showsPlaceholderChrome(visual))
    }

    @Test
    fun `解码成功后才撤掉占位底`() {
        val visual = OverlayVisualPolicy.resolve(
            hasImage = true,
            loading = false,
            lastError = null,
        )
        assertEquals(OverlayVisual.asset, visual)
        assertFalse("有图时才能撤掉占位底", OverlayVisualPolicy.showsPlaceholderChrome(visual))
        assertEquals("", OverlayVisualPolicy.placeholderText(visual))
    }

    @Test
    fun `路径错误不清除旧图（有图时永远是 asset）`() {
        val visual = OverlayVisualPolicy.resolve(
            hasImage = true,
            loading = false,
            lastError = "path_traversal: 素材路径不允许包含 ..",
        )
        assertEquals(OverlayVisual.asset, visual)
        assertFalse(OverlayVisualPolicy.showsPlaceholderChrome(visual))
    }

    @Test
    fun `Bitmap 为空时不清除旧图，新请求加载中也不闪掉旧图`() {
        assertEquals(
            OverlayVisual.asset,
            OverlayVisualPolicy.resolve(hasImage = true, loading = true, lastError = null),
        )
        assertEquals(
            OverlayVisual.asset,
            OverlayVisualPolicy.resolve(
                hasImage = true,
                loading = false,
                lastError = "decode_failed: 图片解码失败",
            ),
        )
    }

    @Test
    fun `没有任何素材时是空占位，同样可见`() {
        val visual = OverlayVisualPolicy.resolve(
            hasImage = false,
            loading = false,
            lastError = null,
        )
        assertEquals(OverlayVisual.empty, visual)
        assertTrue(OverlayVisualPolicy.showsPlaceholderChrome(visual))
        assertEquals("等待素材", OverlayVisualPolicy.placeholderText(visual))
    }

    // --- 5 / 6：hidden 持久化状态 --------------------------------------------

    @Test
    fun `hidden=true 时点击显示必须恢复可见`() {
        val hidden = OverlayState(running = true, hidden = true)
        assertFalse(hidden.windowVisible)

        val shown = OverlayStateMachine.next(hidden, OverlayCommand.SHOW)
        assertTrue("show 之后窗口必须可见", shown.windowVisible)
        assertFalse(shown.hidden)
        assertTrue(shown.running)
    }

    @Test
    fun `start 必须把 hidden 重置为 false`() {
        val hidden = OverlayState(running = true, hidden = true)
        val started = OverlayStateMachine.next(hidden, OverlayCommand.START)
        assertFalse("start 之后不得继承 hidden=true", started.hidden)
        assertTrue(started.windowVisible)

        // 即使服务已经停了，start 也是"显示"。
        val stopped = OverlayStateMachine.next(OverlayState.stopped, OverlayCommand.START)
        assertTrue(stopped.windowVisible)
    }

    @Test
    fun `toggle 也能从隐藏回到可见`() {
        val hidden = OverlayState(running = true, hidden = true)
        assertTrue(OverlayStateMachine.next(hidden, OverlayCommand.TOGGLE).windowVisible)
    }

    // --- 12：快速切换最终显示最后一张 ----------------------------------------

    @Test
    fun `快速切换素材时只有最后一次请求会被采纳`() {
        val guard = OverlayRequestGuard()
        val a = guard.begin()
        val b = guard.begin()
        val c = guard.begin()

        assertFalse(guard.isLatest(a))
        assertFalse(guard.isLatest(b))
        assertTrue("最后一张必须胜出", guard.isLatest(c))
    }
}

/**
 * 真机第二轮失败后的加固：
 * 诊断模式（不依赖素材的洋红方块）、48dp 尺寸下限、固定诊断几何、坐标夹取。
 */
class OverlayDebugModeTest {

    @Test
    fun `诊断模式优先级最高：即使没有素材也是可见状态`() {
        val visual = OverlayVisualPolicy.resolve(
            hasImage = false,
            loading = false,
            lastError = "decode_failed: 图片解码失败",
            debugMode = true,
        )
        assertEquals(OverlayVisual.debug, visual)
        assertTrue(OverlayVisualPolicy.showsPlaceholderChrome(visual))
        assertEquals("PetLife Overlay", OverlayVisualPolicy.placeholderText(visual))
    }

    @Test
    fun `诊断模式不参与"有图优先"的降级链`() {
        // 诊断模式下即使已经有图，也仍然显示诊断方块（就为了看清窗口本身）。
        assertEquals(
            OverlayVisual.debug,
            OverlayVisualPolicy.resolve(
                hasImage = true,
                loading = false,
                lastError = null,
                debugMode = true,
            ),
        )
    }

    @Test
    fun `窗口边长下限是 48dp 对应的像素，且永不为 0`() {
        assertEquals(144, OverlayGeometry.minWindowPx(3.0f))
        // density 异常（0/NaN）时按 1.0 处理，下限是 48dp = 48px，而不是 0
        assertEquals(48, OverlayGeometry.minWindowPx(0f))
        assertTrue(OverlayGeometry.minWindowPx(0f) > 0)
        // 50% 缩放正好是 48dp
        assertEquals(144, OverlayGeometry.viewSizePx(0.5f, 3.0f, 1080, 2400))
        // 任何异常输入都不能得到 0
        assertTrue(OverlayGeometry.viewSizePx(0f, 0f, 0, 0) >= OverlayGeometry.MIN_VIEW_PX)
        assertTrue(OverlayGeometry.viewSizePx(0.5f, 0f, 0, 0) >= OverlayGeometry.MIN_VIEW_PX)
    }

    @Test
    fun `诊断窗口固定 200dp 且位置固定在 80dp-160dp`() {
        // density=2 → 200dp = 400px；(80dp,160dp) = (160,320)
        assertEquals(400, OverlayGeometry.debugSizePx(2f, 1080, 2400))
        val topLeft = OverlayGeometry.debugTopLeftPx(2f, OverlayBounds(0, 0, 1080, 2400), 400)
        assertEquals(160, topLeft[0])
        assertEquals(320, topLeft[1])
    }

    @Test
    fun `诊断窗口在小屏上会被夹进屏幕`() {
        // 屏幕只有 300x400，窗口想要 400px → 尺寸被压到短边 300
        val size = OverlayGeometry.debugSizePx(2f, 300, 400)
        assertEquals(300, size)
        // x 想要 160 但窗口宽 300、屏宽 300 → 只能 0；
        // y 想要 320 但最大可用 400-300=100 → 夹到 100（窗口仍然完全可见）
        val topLeft = OverlayGeometry.debugTopLeftPx(2f, OverlayBounds(0, 0, 300, 400), size)
        assertEquals(0, topLeft[0])
        assertEquals(100, topLeft[1])
    }
}

/**
 * 私有根目录白名单必须是**一组**候选根。
 *
 * 真机不可见的头号嫌疑之一就是"Flutter 侧的 ApplicationSupport 映射成了
 * `<dataDir>/PetLife/assets`，而原生只认 `<filesDir>/PetLife/assets`"，
 * 于是所有素材都被判为越界、窗口永远没有内容。
 */
class OverlayPrivateRootsTest {

    @get:Rule
    val folder = TemporaryFolder()

    private fun asset(relative: String, bytes: ByteArray = byteArrayOf(0x89.toByte(), 0x50.toByte())): File {
        val file = File(folder.root, relative)
        file.parentFile!!.mkdirs()
        file.writeBytes(bytes)
        return file
    }

    private fun payload(filePath: String): Map<String, Any?> = mapOf(
        "schemaVersion" to 1,
        "characterId" to "char-1",
        "assetId" to "asset-1",
        "filePath" to filePath,
        "mimeType" to "image/png",
        "isAnimated" to false,
    )

    @Test
    fun `命中第二个候选根也算通过（filesDir 之外但仍属应用私有目录）`() {
        val rootA = folder.newFolder("filesDir", "PetLife", "assets")
        val rootB = folder.newFolder("dataDir", "PetLife", "assets")
        val file = asset("dataDir/PetLife/assets/packA/Maya/idle.png")

        val result = OverlayConfigValidator.validate(
            payload(file.path),
            listOf(rootA, rootB),
        )

        assertTrue("第二个根必须被接受，否则真机上素材永远加载不了", result is ConfigResult.Accepted)
        val accepted = result as ConfigResult.Accepted
        assertNotNull(accepted.matchedRoot)
        assertTrue(
            "matchedRoot 应该是 dataDir 那个根",
            accepted.matchedRoot!!.contains("dataDir"),
        )
    }

    @Test
    fun `不在任何候选根内的路径仍被拒绝`() {
        val rootA = folder.newFolder("filesDir", "PetLife", "assets")
        val rootB = folder.newFolder("dataDir", "PetLife", "assets")
        val outside = folder.newFile("outside.png")

        val result = OverlayConfigValidator.validate(
            payload(outside.path),
            listOf(rootA, rootB),
        )

        assertTrue(result is ConfigResult.Rejected)
        assertEquals("outside_private_root", (result as ConfigResult.Rejected).code)
    }

    @Test
    fun `多个候选根时仍拒绝路径穿越`() {
        val rootA = folder.newFolder("filesDir", "PetLife", "assets")
        val rootB = folder.newFolder("dataDir", "PetLife", "assets")
        val traversal = "${rootB.path}${File.separator}..${File.separator}..${File.separator}secret.png"

        val result = OverlayConfigValidator.validate(payload(traversal), listOf(rootA, rootB))
        assertEquals("path_traversal", (result as ConfigResult.Rejected).code)
    }
}

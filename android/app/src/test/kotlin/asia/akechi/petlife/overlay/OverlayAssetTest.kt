package asia.akechi.petlife.overlay

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

/**
 * Phase 4C-2：素材配置校验、路径白名单、尺寸上限与采样（**纯逻辑**）。
 *
 * 这一组测试是"能不能把一张图交给原生解码"的闸门，全部不依赖 Android 框架：
 * * [PetOverlayConfig] 的校验只用 `java.io.File`；
 * * [ImageSampling] / [OverlayImageLimits] 是纯算术；
 * * [OverlayRequestGuard] 是纯序号逻辑。
 *
 * **真实解码（PNG/JPG/WebP、透明通道、Bitmap 生命周期）不在这里冒充通过** ——
 * 那需要 `BitmapFactory`，属于仪器测试（见 docs/35 §4 的阻塞说明）。
 */
class OverlayPathPolicyTest {

    @Test
    fun `含两个点段的路径一律判为逃逸`() {
        assertTrue(OverlayPathPolicy.hasTraversal("../../etc/passwd"))
        assertTrue(OverlayPathPolicy.hasTraversal("/data/user/0/p/files/PetLife/assets/../../x.png"))
        assertTrue(OverlayPathPolicy.hasTraversal("assets\\..\\secret.png"))
        assertFalse(OverlayPathPolicy.hasTraversal("/data/user/0/p/files/PetLife/assets/a/b.png"))
    }

    @Test
    fun `扩展名解析：大小写无关，无扩展名返回空串`() {
        assertEquals("png", OverlayPathPolicy.extensionOf("/a/b/idle.PNG"))
        assertEquals("webp", OverlayPathPolicy.extensionOf("/a/b/idle.webp"))
        assertEquals("jpeg", OverlayPathPolicy.extensionOf("/a/b/idle.jpeg"))
        assertEquals("", OverlayPathPolicy.extensionOf("/a/b/noext"))
        assertEquals("", OverlayPathPolicy.extensionOf("/a/b/.hidden"))
    }
}

class OverlayPathInsideTest {

    @get:Rule
    val folder = TemporaryFolder()

    @Test
    fun `私有根内的文件通过，根外的文件与根自身都不通过`() {
        val root = folder.newFolder("PetLife", "assets")
        val inside = File(root, "packA/Maya/idle.png").apply {
            parentFile!!.mkdirs()
            writeBytes(byteArrayOf(1.toByte(), 2.toByte(), 3.toByte()))
        }
        val outside = folder.newFile("outside.png")

        assertTrue(OverlayPathPolicy.isInside(root, inside))
        assertFalse("根目录本身不是素材文件", OverlayPathPolicy.isInside(root, root))
        assertFalse("根外文件必须被拒绝", OverlayPathPolicy.isInside(root, outside))
    }

    @Test
    fun `用相对回退拼出来的路径在规范化后被正确判定`() {
        val root = folder.newFolder("PetLife", "assets")
        val real = File(root, "packA/Maya/idle.png").apply {
            parentFile!!.mkdirs()
            writeBytes(byteArrayOf(1.toByte()))
        }
        val disguised = File(File(root, "packA"), "../packA/Maya/idle.png")
        assertTrue(OverlayPathPolicy.isInside(root, disguised))
        assertTrue(File(disguised.canonicalPath) == File(real.canonicalPath))
    }
}

class OverlayImageLimitsTest {

    @Test
    fun `合法尺寸通过`() {
        assertNull(OverlayImageLimits.validateSize(1024, 1024))
        assertNull(OverlayImageLimits.validateSize(1, 1))
        assertNull(OverlayImageLimits.validateSize(16384, 1))
    }

    @Test
    fun `非法尺寸被拒绝`() {
        assertNotNull(OverlayImageLimits.validateSize(0, 100))
        assertNotNull(OverlayImageLimits.validateSize(-1, 100))
        assertNotNull("单边超上限", OverlayImageLimits.validateSize(16385, 10))
        assertNotNull("像素总量超上限", OverlayImageLimits.validateSize(16384, 16384))
    }
}

class ImageSamplingTest {

    @Test
    fun `小于目标的图不降采样`() {
        assertEquals(1, ImageSampling.inSampleSize(64, 64, 240))
        assertEquals(1, ImageSampling.inSampleSize(240, 240, 240))
    }

    @Test
    fun `大图按 2 的幂降采样`() {
        assertEquals(2, ImageSampling.inSampleSize(480, 480, 240))
        assertEquals(4, ImageSampling.inSampleSize(960, 960, 240))
        // 4000 → 2000 → 1000 → 500 → 250，250 仍不小于目标 240，再折半就成了 125（小于目标）
        // 因此取 16（解码结果 250x250），策略是"绝不缩到小于目标尺寸"。
        assertEquals(16, ImageSampling.inSampleSize(4000, 4000, 240))
    }

    @Test
    fun `采样率一定是 2 的幂（BitmapFactory 的硬要求）`() {
        for (edge in intArrayOf(1, 100, 641, 1920, 4096, 16384)) {
            val sample = ImageSampling.inSampleSize(edge, edge, 250)
            assertTrue("edge=$edge sample=$sample", sample > 0 && (sample and (sample - 1)) == 0)
        }
    }

    @Test
    fun `非法输入退回不采样，而不是崩掉`() {
        assertEquals(1, ImageSampling.inSampleSize(0, 100, 240))
        assertEquals(1, ImageSampling.inSampleSize(100, 100, 0))
    }
}

class PetOverlayConfigValidationTest {

    @get:Rule
    val folder = TemporaryFolder()

    private lateinit var assetsRoot: File

    private fun setupRoot(): File {
        assetsRoot = folder.newFolder("PetLife", "assets")
        return assetsRoot
    }

    private fun asset(relative: String, bytes: ByteArray = byteArrayOf(0x89.toByte(), 0x50.toByte())): File {
        val file = File(assetsRoot, relative)
        file.parentFile!!.mkdirs()
        file.writeBytes(bytes)
        return file
    }

    private fun payload(
        characterId: String? = "char-1",
        assetId: String? = "asset-1",
        filePath: String?,
        mimeType: String? = "image/png",
        schemaVersion: Int? = 1,
        isAnimated: Boolean = false,
        frameCount: Int = 0,
    ): Map<String, Any?> = buildMap {
        if (schemaVersion != null) put("schemaVersion", schemaVersion)
        if (characterId != null) put("characterId", characterId)
        if (assetId != null) put("assetId", assetId)
        if (filePath != null) put("filePath", filePath)
        if (mimeType != null) put("mimeType", mimeType)
        put("isAnimated", isAnimated)
        put("frameCount", frameCount)
    }

    private fun codeOf(result: ConfigResult): String =
        (result as ConfigResult.Rejected).code

    @Test
    fun `合法私有路径通过并解析出完整配置`() {
        val root = setupRoot()
        val file = asset("packA/Maya/idle.png")

        val result = OverlayConfigValidator.validate(
            payload(filePath = file.path, isAnimated = false),
            root,
        )

        assertTrue(result is ConfigResult.Accepted)
        val config = (result as ConfigResult.Accepted).config
        assertEquals("char-1", config.characterId)
        assertEquals("asset-1", config.assetId)
        assertEquals(file.path, config.filePath)
        assertEquals("image/png", config.mimeType)
        assertFalse(config.animatedFirstFrameOnly)
    }

    @Test
    fun `没有携带配置时返回 Absent（用现有配置继续）`() {
        val root = setupRoot()
        assertTrue(OverlayConfigValidator.validate(null, root) is ConfigResult.Absent)
        assertTrue(OverlayConfigValidator.validate("not-a-map", root) is ConfigResult.Absent)
    }

    @Test
    fun `协议版本不支持被拒绝`() {
        val root = setupRoot()
        val file = asset("a.png")
        assertEquals(
            "unsupported_schema",
            codeOf(OverlayConfigValidator.validate(payload(filePath = file.path, schemaVersion = 2), root)),
        )
    }

    @Test
    fun `空角色 ID 素材 ID 文件路径被拒绝`() {
        val root = setupRoot()
        val file = asset("a.png")
        assertEquals(
            "empty_character_id",
            codeOf(OverlayConfigValidator.validate(payload(characterId = "  ", filePath = file.path), root)),
        )
        assertEquals(
            "empty_asset_id",
            codeOf(OverlayConfigValidator.validate(payload(assetId = null, filePath = file.path), root)),
        )
        assertEquals(
            "empty_file_path",
            codeOf(OverlayConfigValidator.validate(payload(filePath = ""), root)),
        )
    }

    @Test
    fun `含两个点段的路径被拒绝`() {
        val root = setupRoot()
        val outside = folder.newFile("outside.png")
        val traversal = "${root.path}${File.separator}..${File.separator}outside.png"
        assertEquals(
            "path_traversal",
            codeOf(OverlayConfigValidator.validate(payload(filePath = traversal), root)),
        )
        assertTrue(outside.exists())
    }

    @Test
    fun `应用私有目录之外的路径被拒绝`() {
        val root = setupRoot()
        val outside = folder.newFile("outside.png")
        assertEquals(
            "outside_private_root",
            codeOf(OverlayConfigValidator.validate(payload(filePath = outside.path), root)),
        )
    }

    @Test
    fun `不存在的文件被拒绝`() {
        val root = setupRoot()
        val missing = File(root, "packA/Maya/missing.png")
        assertEquals(
            "file_missing",
            codeOf(OverlayConfigValidator.validate(payload(filePath = missing.path), root)),
        )
    }

    @Test
    fun `目录而不是普通文件被拒绝`() {
        val root = setupRoot()
        val dir = File(root, "packA/Maya").apply { mkdirs() }
        assertEquals(
            "not_a_regular_file",
            codeOf(OverlayConfigValidator.validate(payload(filePath = dir.path), root)),
        )
    }

    @Test
    fun `不支持的 MIME 被拒绝（GIF 也算不支持）`() {
        val root = setupRoot()
        val file = asset("a.png")
        assertEquals(
            "unsupported_mime",
            codeOf(OverlayConfigValidator.validate(payload(filePath = file.path, mimeType = "image/gif"), root)),
        )
        assertEquals(
            "unsupported_mime",
            codeOf(OverlayConfigValidator.validate(payload(filePath = file.path, mimeType = "image/svg+xml"), root)),
        )
    }

    @Test
    fun `扩展名与 MIME 不匹配被拒绝`() {
        val root = setupRoot()
        val file = asset("a.png")
        assertEquals(
            "mime_extension_mismatch",
            codeOf(OverlayConfigValidator.validate(payload(filePath = file.path, mimeType = "image/webp"), root)),
        )
    }

    @Test
    fun `jpeg 同时接受 jpg 与 jpeg 两种扩展名`() {
        val root = setupRoot()
        val jpg = asset("a.jpg")
        val jpeg = asset("b.jpeg")
        assertTrue(
            OverlayConfigValidator.validate(payload(filePath = jpg.path, mimeType = "image/jpeg"), root)
                is ConfigResult.Accepted,
        )
        assertTrue(
            OverlayConfigValidator.validate(payload(filePath = jpeg.path, mimeType = "image/jpeg"), root)
                is ConfigResult.Accepted,
        )
    }

    @Test
    fun `动态素材在配置层保留动画声明（4C-4 起由视觉策略决定是否真播放）`() {
        val root = setupRoot()
        val file = asset("packA/Maya/idle.webp")
        val result = OverlayConfigValidator.validate(
            payload(
                filePath = file.path,
                mimeType = "image/webp",
                isAnimated = true,
                frameCount = 12,
            ),
            root,
        )
        val config = (result as ConfigResult.Accepted).config
        assertTrue(config.isAnimated)
        assertTrue("配置层必须保留动画声明（4C-4 由此推导静态/动态）", config.animatedFirstFrameOnly)
        // §18：旧提示（"完整动画将在 4C-4 实现"）必须退役，只保留低版本回退文案。
        assertTrue(PetOverlayService.ANIMATED_FIRST_FRAME_FALLBACK_NOTICE.contains("第一帧"))
    }
}

class OverlayRequestGuardTest {

    @Test
    fun `旧请求的结果不得覆盖新请求（A 开始 B 开始 B 完成 A 随后完成）`() {
        val guard = OverlayRequestGuard()

        val a = guard.begin()
        val b = guard.begin()

        assertTrue("A 先发出但不是最新的", !guard.isLatest(a))
        assertTrue("B 是最新请求", guard.isLatest(b))
        // B 完成后 A 才回来：仍然必须被丢弃。
        assertFalse(guard.isLatest(a))
    }

    @Test
    fun `作废后在途请求全部失效`() {
        val guard = OverlayRequestGuard()
        val a = guard.begin()
        assertTrue(guard.isLatest(a))
        guard.invalidate()
        assertFalse("作废后 A 不得再被采纳", guard.isLatest(a))
    }

    @Test
    fun `序号单调递增，不会与历史请求碰撞`() {
        val guard = OverlayRequestGuard()
        val first = guard.begin()
        val second = guard.begin()
        val third = guard.begin()
        assertEquals(listOf(1L, 2L, 3L), listOf(first, second, third))
        assertTrue(guard.isLatest(third))
    }
}

package asia.akechi.petlife.overlay

import android.graphics.Canvas
import android.graphics.ColorFilter
import android.graphics.PixelFormat
import android.graphics.drawable.Animatable
import android.graphics.drawable.Drawable
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.Executor

/**
 * Phase 4C-4：动态 WebP 的**纯逻辑**测试。
 *
 * 覆盖需求第 21 节列出的 32 条里**可以在 JVM 上真实验证**的部分：
 * 类型判定 / API 分级 / 播放门控 / 解码器与加载器的 requestId 防过期 / 视觉替换与释放顺序 /
 * 错误码口径。
 *
 * 需要真实 `ImageDecoder`、`AnimatedImageDrawable`、`ImageView` 与 `WindowManager` 的条目
 * （真实解码出多帧、hide/show 后 `isRunning` 变化、View 销毁后无回调泄漏、拖动/菜单不重启动画）
 * 属于**仪器测试与真机验收**，见 docs §10.9，**不在 JVM 测试里假装通过**。
 */
class PetVisualTypePolicyTest {

    @Test
    fun `静态素材无论什么版本都是 Static`() {
        for (api in listOf(24, 27, 28, 34)) {
            assertEquals(PetVisualKind.static, PetVisualTypePolicy.resolve(false, api))
        }
    }

    @Test
    fun `API 28 及以上的动态素材才是完整动画`() {
        assertEquals(PetVisualKind.animated, PetVisualTypePolicy.resolve(true, 28))
        assertEquals(PetVisualKind.animated, PetVisualTypePolicy.resolve(true, 34))
        assertTrue(PetVisualTypePolicy.supportsFullAnimation(28))
        assertTrue(PetVisualTypePolicy.supportsFullAnimation(34))
    }

    @Test
    fun `API 24 到 27 的动态素材进入第一帧回退，绝不假装支持动画`() {
        for (api in listOf(24, 25, 26, 27)) {
            assertEquals(
                PetVisualKind.animatedFirstFrameFallback,
                PetVisualTypePolicy.resolve(true, api),
            )
            assertFalse(PetVisualTypePolicy.supportsFullAnimation(api))
        }
        // 回退态对外仍然如实报告"这是动态素材"，只是帧模式不同
        assertEquals("animated", PetVisualKind.animatedFirstFrameFallback.wire)
        assertEquals("first-frame-fallback", PetVisualKind.animatedFirstFrameFallback.frameMode)
        assertEquals("full-animation", PetVisualKind.animated.frameMode)
        assertEquals("not-applicable", PetVisualKind.static.frameMode)
        assertEquals("not-applicable", PetVisualKind.placeholder.frameMode)
        assertEquals("placeholder", PetVisualKind.placeholder.wire)
    }
}

class AnimatedWebpHeaderTest {

    private fun bytes(vararg ascii: String): ByteArray {
        val text = ascii.joinToString("")
        return text.toByteArray(Charsets.US_ASCII)
    }

    @Test
    fun `带 ANIM 块的 RIFF-WEBP 被识别为动态素材`() {
        val header = bytes("RIFF", "0000", "WEBP", "VP8X", "0000", "ANIM", "0000")
        assertTrue(AnimatedWebpHeader.looksAnimated(header))
    }

    @Test
    fun `静态 WebP（没有 ANIM 块）不被误判为动态`() {
        val header = bytes("RIFF", "0000", "WEBP", "VP8 ", "0000", "0000")
        assertFalse(AnimatedWebpHeader.looksAnimated(header))
    }

    @Test
    fun `非 WebP 文件与截断文件都安全返回 false`() {
        assertFalse(AnimatedWebpHeader.looksAnimated(bytes("PNGxxxxx", "yyyy")))
        assertFalse(AnimatedWebpHeader.looksAnimated(ByteArray(0)))
        assertFalse(AnimatedWebpHeader.looksAnimated(bytes("RIFF")))
        assertFalse(AnimatedWebpHeader.looksAnimated(bytes("RIFF0000", "WEBP")))
    }

    @Test
    fun `RIFF 头前面出现 ANIM 字节不会被误判（必须同时满足两个魔术字）`() {
        val header = bytes("ANIM", "RIFF", "0000", "0000")
        assertFalse(AnimatedWebpHeader.looksAnimated(header))
    }
}

class AnimationGateTest {

    private val allowed = AnimationGate(
        serviceRunning = true,
        viewAttached = true,
        petVisible = true,
        screenInteractive = true,
        visualIsAnimated = true,
        stopping = false,
        instanceActive = true,
    )

    @Test
    fun `七条条件全部满足才允许播放`() {
        assertTrue(allowed.shouldAnimate())
        assertNull(allowed.blockedReason())
    }

    @Test
    fun `任一条不满足都不允许播放，且给出明确原因`() {
        assertFalse(allowed.copy(viewAttached = false).shouldAnimate())
        assertEquals("view-detached", allowed.copy(viewAttached = false).blockedReason())
        assertFalse(allowed.copy(petVisible = false).shouldAnimate())
        assertEquals("pet-hidden", allowed.copy(petVisible = false).blockedReason())
        assertFalse(allowed.copy(screenInteractive = false).shouldAnimate())
        assertEquals("screen-off", allowed.copy(screenInteractive = false).blockedReason())
        assertFalse(allowed.copy(visualIsAnimated = false).shouldAnimate())
        assertEquals("visual-not-animated", allowed.copy(visualIsAnimated = false).blockedReason())
        assertFalse(allowed.copy(stopping = true).shouldAnimate())
        assertEquals("stopping", allowed.copy(stopping = true).blockedReason())
        assertFalse(allowed.copy(serviceRunning = false).shouldAnimate())
        assertFalse(allowed.copy(instanceActive = false).shouldAnimate())
        assertEquals("service-instance-replaced", allowed.copy(instanceActive = false).blockedReason())
    }

    @Test
    fun `隐藏状态与未附着状态都不启动动画`() {
        assertFalse("未 attached 不得启动", allowed.copy(viewAttached = false).shouldAnimate())
        assertFalse("hidden 不得启动", allowed.copy(petVisible = false).shouldAnimate())
    }
}

class PetVisualErrorTest {

    @Test
    fun `每个错误码都有用户可读中文，未知码退回通用文案`() {
        val codes = listOf(
            PetVisualError.PATH_NOT_ALLOWED,
            PetVisualError.FILE_MISSING,
            PetVisualError.FILE_NOT_REGULAR,
            PetVisualError.FILE_TOO_LARGE,
            PetVisualError.INVALID_DIMENSIONS,
            PetVisualError.PIXEL_LIMIT_EXCEEDED,
            PetVisualError.DECODE_FAILED,
            PetVisualError.UNSUPPORTED_ANIMATED_WEBP,
            PetVisualError.OUT_OF_MEMORY,
            PetVisualError.STALE_REQUEST,
            PetVisualError.SERVICE_DISPOSED,
            PetVisualError.VIEW_DETACHED,
        )
        assertEquals(codes.size, codes.toSet().size)
        codes.forEach { code ->
            val message = PetVisualError.userMessage(code)
            assertTrue("$code 必须有中文说明", message.isNotBlank())
            assertTrue("$code 的说明不能是堆栈", !message.contains("Exception"))
        }
        assertEquals("素材解码失败", PetVisualError.userMessage("something_else"))
    }
}

/** 可统计 start/stop 的假动画 Drawable（模拟 AnimatedImageDrawable 的 Animatable 合约）。 */
private class FakeAnimatedDrawable : Drawable(), Animatable {
    var startCount = 0
        private set
    var stopCount = 0
        private set
    private var running = false

    override fun start() {
        startCount += 1
        running = true
    }

    override fun stop() {
        stopCount += 1
        running = false
    }

    override fun isRunning(): Boolean = running

    override fun draw(canvas: Canvas) = Unit

    override fun setAlpha(alpha: Int) = Unit

    override fun setColorFilter(colorFilter: ColorFilter?) = Unit

    @Deprecated("Drawable 的旧 API，测试里无害")
    override fun getOpacity(): Int = PixelFormat.OPAQUE
}

private class FakeStaticDrawable : Drawable() {
    var recycledHint = false
    override fun draw(canvas: Canvas) = Unit
    override fun setAlpha(alpha: Int) = Unit
    override fun setColorFilter(colorFilter: ColorFilter?) = Unit
    @Deprecated("Drawable 的旧 API，测试里无害")
    override fun getOpacity(): Int = PixelFormat.TRANSLUCENT
}

private class FakeVisualDecoder(
    private val produce: (path: String, targetSizePx: Int, apiLevel: Int) -> DecodedPetVisual,
) : PetVisualDecoder {
    var calls = 0
        private set
    val requestedPaths = ArrayList<String>()

    override fun decode(path: String, targetSizePx: Int, apiLevel: Int): DecodedPetVisual {
        calls += 1
        requestedPaths.add(path)
        return produce(path, targetSizePx, apiLevel)
    }
}

private fun config(
    assetId: String,
    path: String = "/tmp/$assetId.webp",
    animated: Boolean = false,
): PetOverlayConfig = PetOverlayConfig(
    schemaVersion = PetOverlayConfig.SCHEMA_VERSION,
    characterId = "char",
    assetId = assetId,
    filePath = path,
    mimeType = "image/webp",
    isAnimated = animated,
    frameCount = 0,
    animationDurationMs = 0,
    scale = 1f,
    snapEnabled = true,
    fixedAssetMode = false,
)

private fun animatedVisual(path: String, apiLevel: Int, drawable: FakeAnimatedDrawable): DecodedPetVisual =
    DecodedPetVisual(
        kind = PetVisualTypePolicy.resolve(true, apiLevel),
        visual = if (apiLevel >= 28) {
            PetVisual.Animated(drawable, 64, 64, path)
        } else {
            PetVisual.Static(drawable, 64, 64, path)
        },
        width = 64,
        height = 64,
        sourceIsAnimated = true,
        decoderName = "Fake",
    )

private fun staticVisual(path: String): DecodedPetVisual {
    val drawable = FakeStaticDrawable()
    return DecodedPetVisual(
        kind = PetVisualKind.static,
        visual = PetVisual.Static(drawable, 32, 32, path),
        width = 32,
        height = 32,
        sourceIsAnimated = false,
        decoderName = "Fake",
    )
}

/**
 * 加载器行为：requestId 防过期、视觉替换、释放顺序、快速切换只认最后一次。
 */
class PetVisualLoaderTest {

    private fun loader(
        decoder: PetVisualDecoder,
        apiLevel: Int = 34,
    ): PetImageLoader = PetImageLoader(
        decoder = decoder,
        apiLevel = apiLevel,
        worker = Executor { it.run() },
        postToMain = { it.run() },
    )

    private class Recorder {
        val loaded = ArrayList<String>()
        val failed = ArrayList<String>()
        val stale = ArrayList<Long>()
        val listener = object : PetImageLoader.Listener {
            override fun onLoaded(
                requestSeq: Long,
                decoded: DecodedPetVisual,
                config: PetOverlayConfig,
            ) {
                loaded.add("${config.assetId}:${decoded.kind.name}")
            }

            override fun onFailed(
                requestSeq: Long,
                code: String,
                message: String,
                config: PetOverlayConfig,
            ) {
                failed.add("${config.assetId}:$code")
            }

            override fun onStale(requestSeq: Long) {
                stale.add(requestSeq)
            }
        }
    }

    @Test
    fun `静态素材识别为 Static，动态素材识别为 Animated`() {
        val decoder = FakeVisualDecoder { path, _, api ->
            if (path.endsWith("animated.webp")) {
                animatedVisual(path, api, FakeAnimatedDrawable())
            } else {
                staticVisual(path)
            }
        }
        val loader = loader(decoder)
        val recorder = Recorder()

        loader.load(config("static-1", "/tmp/static.webp"), 128, recorder.listener)
        loader.load(config("anim-1", "/tmp/animated.webp", animated = true), 128, recorder.listener)

        assertEquals(listOf("static-1:static", "anim-1:animated"), recorder.loaded)
        assertEquals("anim-1", loader.displayedAssetId)
        assertFalse(loader.isPlaceholder)
    }

    @Test
    fun `API 24 到 27 上动态素材被标记为第一帧回退`() {
        val decoder = FakeVisualDecoder { path, _, api -> animatedVisual(path, api, FakeAnimatedDrawable()) }
        val loader = loader(decoder, apiLevel = 24)
        val recorder = Recorder()

        loader.load(config("anim-old", animated = true), 128, recorder.listener)

        assertEquals(listOf("anim-old:animatedFirstFrameFallback"), recorder.loaded)
    }

    @Test
    fun `解码失败回报明确错误码，且不破坏当前记账`() {
        val decoder = FakeVisualDecoder { path, _, _ ->
            throw PetImageLoadException(PetVisualError.FILE_MISSING, "文件不存在")
        }
        val loader = loader(decoder)
        val recorder = Recorder()

        loader.load(config("missing"), 128, recorder.listener)

        assertEquals(listOf("missing:${PetVisualError.FILE_MISSING}"), recorder.failed)
        assertTrue("没有成功加载时仍是占位状态", loader.isPlaceholder)
        assertNull(loader.displayedAssetId)
        assertNull(loader.currentVisualOrNull())
    }

    @Test
    fun `路径越界-超大文件-异常尺寸分别得到对应错误码`() {
        val cases = listOf(
            PetVisualError.PATH_NOT_ALLOWED,
            PetVisualError.FILE_TOO_LARGE,
            PetVisualError.INVALID_DIMENSIONS,
            PetVisualError.PIXEL_LIMIT_EXCEEDED,
            PetVisualError.OUT_OF_MEMORY,
        )
        cases.forEach { code ->
            val decoder = FakeVisualDecoder { _, _, _ ->
                throw PetImageLoadException(code, "fake")
            }
            val recorder = Recorder()
            loader(decoder).load(config("x-$code"), 128, recorder.listener)
            assertEquals(listOf("x-$code:$code"), recorder.failed)
        }
    }

    @Test
    fun `连续快速切换素材只采纳最后一次请求`() {
        val queued = ArrayList<Runnable>()
        val decoder = FakeVisualDecoder { path, _, _ -> staticVisual(path) }
        val recorder = Recorder()
        // 同步 worker + 排队的主线程回调：三个请求的**结果**依次到达时，
        // 只有序号最大的那个才允许上屏（需求第 31 条）。
        val loader = PetImageLoader(
            decoder = decoder,
            apiLevel = 34,
            worker = Executor { it.run() },
            postToMain = { queued.add(it) },
        )

        loader.load(config("a-1", "/tmp/a.webp"), 128, recorder.listener)
        loader.load(config("b-2", "/tmp/b.webp"), 128, recorder.listener)
        loader.load(config("c-3", "/tmp/c.webp"), 128, recorder.listener)
        queued.forEach { it.run() }

        assertEquals(listOf("c-3:static"), recorder.loaded)
        assertEquals("前两次必须被判为过期", listOf(1L, 2L), recorder.stale)
        assertEquals("只有最后一次上屏", "c-3", loader.displayedAssetId)
    }

    @Test
    fun `旧请求的结果晚到时不覆盖新素材（过期结果不会上屏）`() {
        val queued = ArrayList<Runnable>()
        val decoder = FakeVisualDecoder { path, _, _ -> staticVisual(path) }
        val recorder = Recorder()
        // 同步 worker + **可手动放行**的主线程回调：精确复现
        // "A 开始 → B 开始 → B 完成 → A 才完成" 的乱序。
        val loader = PetImageLoader(
            decoder = decoder,
            apiLevel = 34,
            worker = Executor { it.run() },
            postToMain = { queued.add(it) },
        )

        loader.load(config("a-1", "/tmp/a.webp"), 128, recorder.listener)
        loader.load(config("b-2", "/tmp/b.webp"), 128, recorder.listener)
        assertEquals(2, queued.size)

        // A 的结果先到，但序号已经过期 → 丢弃并回调 onStale
        queued[0].run()
        assertEquals(listOf(1L), recorder.stale)
        assertTrue("过期结果不得上屏", recorder.loaded.isEmpty())

        // B 的结果到达 → 上屏
        queued[1].run()
        assertEquals(listOf("b-2:static"), recorder.loaded)
        assertEquals("b-2", loader.displayedAssetId)
    }

    @Test
    fun `过期的动态结果被丢弃，不会成为当前视觉`() {
        val queued = ArrayList<Runnable>()
        val staleDrawable = FakeAnimatedDrawable()
        var calls = 0
        val decoder = FakeVisualDecoder { path, _, api ->
            calls += 1
            animatedVisual(path, api, if (calls == 1) staleDrawable else FakeAnimatedDrawable())
        }
        val recorder = Recorder()
        val loader = PetImageLoader(
            decoder = decoder,
            apiLevel = 34,
            worker = Executor { it.run() },
            postToMain = { queued.add(it) },
        )

        loader.load(config("a-1", animated = true), 128, recorder.listener)
        loader.load(config("b-2", animated = true), 128, recorder.listener)

        // A 过期
        queued[0].run()
        assertEquals(listOf(1L), recorder.stale)
        assertTrue(recorder.loaded.isEmpty())
        assertNull("过期结果不得成为当前视觉", loader.displayedAssetId)
        assertEquals("过期素材的动画绝不允许被启动", 0, staleDrawable.startCount)

        // B 上屏
        queued[1].run()
        assertEquals(listOf("b-2:animated"), recorder.loaded)
        assertEquals("b-2", loader.displayedAssetId)
    }

    @Test
    fun `替换视觉时旧动画先被停止（释放顺序）`() {
        val firstDrawable = FakeAnimatedDrawable()
        val secondDrawable = FakeAnimatedDrawable()
        var calls = 0
        val decoder = FakeVisualDecoder { path, _, api ->
            calls += 1
            if (calls == 1) animatedVisual(path, api, firstDrawable) else animatedVisual(path, api, secondDrawable)
        }
        val loader = loader(decoder)
        val recorder = Recorder()

        loader.load(config("anim-1", animated = true), 128, recorder.listener)
        firstDrawable.start()
        assertTrue(firstDrawable.isRunning)

        loader.load(config("anim-2", animated = true), 128, recorder.listener)

        assertEquals("旧动画必须被 stop()", 1, firstDrawable.stopCount)
        assertFalse(firstDrawable.isRunning)
        assertEquals(0, secondDrawable.stopCount)
        assertEquals("anim-2", loader.displayedAssetId)
    }

    @Test
    fun `dispose 会停掉在跑的动画并作废后续加载`() {
        val drawable = FakeAnimatedDrawable()
        val decoder = FakeVisualDecoder { path, _, api -> animatedVisual(path, api, drawable) }
        val loader = loader(decoder)
        val recorder = Recorder()

        loader.load(config("anim-1", animated = true), 128, recorder.listener)
        drawable.start()

        loader.dispose()
        loader.dispose()  // 幂等

        assertEquals("动画被停一次", 1, drawable.stopCount)
        assertNull(loader.currentVisualOrNull())
        assertTrue(loader.isPlaceholder)

        // dispose 之后的加载请求必须被忽略（不会产生第二次解码）
        val before = decoder.calls
        loader.load(config("anim-2", animated = true), 128, recorder.listener)
        assertEquals(before, decoder.calls)
    }

    @Test
    fun `clearCurrent 丢掉视觉并停掉动画（素材被删除时）`() {
        val drawable = FakeAnimatedDrawable()
        val decoder = FakeVisualDecoder { path, _, api -> animatedVisual(path, api, drawable) }
        val loader = loader(decoder)
        val recorder = Recorder()

        loader.load(config("anim-1", animated = true), 128, recorder.listener)
        drawable.start()
        loader.clearCurrent()

        assertEquals(1, drawable.stopCount)
        assertNull(loader.displayedAssetId)
        assertTrue(loader.isPlaceholder)
    }

    @Test
    fun `同一素材不同目标尺寸都会重新解码（尺寸变化必须重新采样）`() {
        val decoder = FakeVisualDecoder { path, _, _ -> staticVisual(path) }
        val loader = loader(decoder)
        val recorder = Recorder()

        loader.load(config("same", "/tmp/same.webp"), 128, recorder.listener)
        loader.load(config("same", "/tmp/same.webp"), 256, recorder.listener)

        assertEquals("尺寸不同 → 解码两次（去重判据在服务层，见 loadAssetIfNeeded）", 2, decoder.calls)
        assertEquals(2, recorder.loaded.size)
    }

    @Test
    fun `解码器收到的 apiLevel 与系统一致（分级策略的唯一入口）`() {
        var seenApi = -1
        val decoder = FakeVisualDecoder { path, _, api ->
            seenApi = api
            staticVisual(path)
        }
        loader(decoder, apiLevel = 26).load(config("x"), 64, Recorder().listener)
        assertEquals(26, seenApi)
    }
}

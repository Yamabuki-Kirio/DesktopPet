package asia.akechi.petlife.overlay

import android.content.res.Resources
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.graphics.drawable.AnimatedImageDrawable
import android.graphics.drawable.Animatable
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.annotation.RequiresApi
import java.io.File
import java.io.RandomAccessFile
import java.util.concurrent.Executor
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * 请求序号守卫（**纯逻辑**，可 JVM 单测）。
 *
 * 解决需求里那条竞态：
 * ```
 * 请求 A 开始 → 请求 B 开始 → B 完成并显示 → A 随后完成 → A 不得覆盖 B
 * ```
 * 做法是"只有最新序号的结果才允许被采纳"，且失败/过期结果一律丢弃。
 */
internal class OverlayRequestGuard {
    private var sequence: Long = 0L

    val latest: Long get() = sequence

    fun begin(): Long {
        sequence += 1
        return sequence
    }

    fun isLatest(candidate: Long): Boolean = candidate == sequence

    /** 作废所有在途请求（停止服务 / 释放资源时用）。 */
    fun invalidate() {
        sequence += 1
    }
}

/** 解码失败（带可回传给 Flutter 的错误码）。 */
internal class PetImageLoadException(val code: String, message: String) :
    Exception(message)

/**
 * Android 原生视觉解码（Phase 4C-4：静态 PNG/JPG/静态 WebP + **动态 WebP**）。
 *
 * 分级策略（需求第 3 节）：
 * * **API 28+**：`ImageDecoder.decodeDrawable` —— 动态 WebP 直接得到
 *   `AnimatedImageDrawable`，可完整播放、可循环；
 * * **API 24~27**：没有 `ImageDecoder`，用 `BitmapFactory` **安全显示第一帧**，
 *   并用 [AnimatedWebpHeader] 读文件头判断"这其实是动态素材"，
 *   从而给出准确口径（而不是假装支持动画）。
 *
 * 安全边界沿用 4C-2 已验收的实现：路径必须在应用私有素材根目录内、
 * 文件存在且是普通文件、大小/单边/像素数都在项目既有上限之内。
 * 扩展名只用于日志与初步提示，**不作为类型判定依据**。
 */
internal class AndroidPetVisualDecoder(
    private val roots: List<File>,
    private val resources: Resources,
) : PetVisualDecoder {

    override fun decode(path: String, targetSizePx: Int, apiLevel: Int): DecodedPetVisual {
        val file = validate(path)
        return try {
            if (apiLevel >= PetVisualTypePolicy.MIN_API_FULL_ANIMATION) {
                decodeWithImageDecoder(file, path, targetSizePx, apiLevel)
            } else {
                decodeFirstFrame(file, path, targetSizePx, apiLevel)
            }
        } catch (e: PetImageLoadException) {
            throw e
        } catch (e: OutOfMemoryError) {
            throw PetImageLoadException(
                PetVisualError.OUT_OF_MEMORY,
                PetVisualError.userMessage(PetVisualError.OUT_OF_MEMORY),
            )
        } catch (t: Throwable) {
            throw PetImageLoadException(
                PetVisualError.DECODE_FAILED,
                t.message ?: PetVisualError.userMessage(PetVisualError.DECODE_FAILED),
            )
        }
    }

    /** 路径 → 存在 → 普通文件 → 大小上限。任何一项不过都不进入解码。 */
    private fun validate(path: String): File {
        val file = File(path)
        val inside = roots.any { root -> OverlayPathPolicy.isInside(root, file) }
        if (!inside) {
            throw PetImageLoadException(
                PetVisualError.PATH_NOT_ALLOWED,
                PetVisualError.userMessage(PetVisualError.PATH_NOT_ALLOWED),
            )
        }
        if (!file.exists()) {
            throw PetImageLoadException(
                PetVisualError.FILE_MISSING,
                PetVisualError.userMessage(PetVisualError.FILE_MISSING),
            )
        }
        if (!file.isFile) {
            throw PetImageLoadException(
                PetVisualError.FILE_NOT_REGULAR,
                PetVisualError.userMessage(PetVisualError.FILE_NOT_REGULAR),
            )
        }
        if (file.length() > PetOverlayConfig.MAX_FILE_BYTES) {
            throw PetImageLoadException(
                PetVisualError.FILE_TOO_LARGE,
                PetVisualError.userMessage(PetVisualError.FILE_TOO_LARGE),
            )
        }
        return file
    }

    /**
     * API 28+：全量解码（动态 WebP → `AnimatedImageDrawable`）。
     *
     * 解码前先按目标长边缩放，避免把整张原图拉进内存。
     */
    @RequiresApi(PetVisualTypePolicy.MIN_API_FULL_ANIMATION)
    private fun decodeWithImageDecoder(
        file: File,
        path: String,
        targetSizePx: Int,
        apiLevel: Int,
    ): DecodedPetVisual {
        val source = ImageDecoder.createSource(file)
        val drawable: Drawable = ImageDecoder.decodeDrawable(source) { decoder, info, _ ->
            val width = info.size.width
            val height = info.size.height
            if (width <= 0 || height <= 0) {
                throw PetImageLoadException(
                    PetVisualError.INVALID_DIMENSIONS,
                    PetVisualError.userMessage(PetVisualError.INVALID_DIMENSIONS),
                )
            }
            OverlayImageLimits.validateSize(width, height)?.let {
                throw PetImageLoadException(PetVisualError.PIXEL_LIMIT_EXCEEDED, it)
            }
            val scale = targetScale(width, height, targetSizePx)
            if (scale < 1f) {
                val targetWidth = (width * scale).toInt().coerceAtLeast(1)
                val targetHeight = (height * scale).toInt().coerceAtLeast(1)
                decoder.setTargetSize(targetWidth, targetHeight)
            }
        }

        val animated = drawable is AnimatedImageDrawable
        if (animated) {
            // 第一版默认无限循环（需求第 9 节）。
            (drawable as AnimatedImageDrawable).repeatCount = AnimatedImageDrawable.REPEAT_INFINITE
        }
        val width = drawable.intrinsicWidth.coerceAtLeast(1)
        val height = drawable.intrinsicHeight.coerceAtLeast(1)
        OverlayImageLimits.validateSize(width, height)?.let {
            throw PetImageLoadException(PetVisualError.PIXEL_LIMIT_EXCEEDED, it)
        }
        val kind = PetVisualTypePolicy.resolve(sourceIsAnimated = animated, apiLevel = apiLevel)
        return DecodedPetVisual(
            kind = kind,
            visual = if (kind == PetVisualKind.animated) {
                PetVisual.Animated(drawable, width, height, path)
            } else {
                PetVisual.Static(drawable, width, height, path)
            },
            width = width,
            height = height,
            sourceIsAnimated = animated,
            decoderName = "ImageDecoder",
        )
    }

    /** API 24~27：`BitmapFactory` 取第一帧；动态素材用文件头识别并标记为回退。 */
    private fun decodeFirstFrame(
        file: File,
        path: String,
        targetSizePx: Int,
        apiLevel: Int,
    ): DecodedPetVisual {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, bounds)
        val width = bounds.outWidth
        val height = bounds.outHeight
        if (width <= 0 || height <= 0) {
            throw PetImageLoadException(
                PetVisualError.INVALID_DIMENSIONS,
                PetVisualError.userMessage(PetVisualError.INVALID_DIMENSIONS),
            )
        }
        OverlayImageLimits.validateSize(width, height)?.let {
            throw PetImageLoadException(PetVisualError.PIXEL_LIMIT_EXCEEDED, it)
        }

        val sampleSize = ImageSampling.inSampleSize(width, height, targetSizePx)
        val options = BitmapFactory.Options().apply {
            inSampleSize = sampleSize
            // ARGB_8888：PNG / WebP 的透明通道必须保留（JPG 无 alpha，不影响）
            inPreferredConfig = Bitmap.Config.ARGB_8888
        }
        val bitmap = BitmapFactory.decodeFile(path, options)
            ?: throw PetImageLoadException(
                PetVisualError.DECODE_FAILED,
                PetVisualError.userMessage(PetVisualError.DECODE_FAILED),
            )
        val drawable = BitmapDrawable(resources, bitmap)
        val sourceIsAnimated = AnimatedWebpHeader.looksAnimated(readHeader(file))
        val kind = PetVisualTypePolicy.resolve(sourceIsAnimated = sourceIsAnimated, apiLevel = apiLevel)
        return DecodedPetVisual(
            kind = kind,
            // 低版本只能显示第一帧：视觉上就是一张静态图（[kind] 已如实标记为回退）。
            visual = PetVisual.Static(drawable, bitmap.width, bitmap.height, path),
            width = bitmap.width,
            height = bitmap.height,
            sourceIsAnimated = sourceIsAnimated,
            decoderName = "BitmapFactory",
        )
    }

    private fun targetScale(width: Int, height: Int, targetSizePx: Int): Float {
        if (targetSizePx <= 0) return 1f
        val longEdge = maxOf(width, height)
        if (longEdge <= targetSizePx) return 1f
        return targetSizePx.toFloat() / longEdge.toFloat()
    }

    /** 只读文件头（用于 API 24~27 的动态 WebP 识别；最多 64 字节）。 */
    private fun readHeader(file: File): ByteArray {
        return try {
            RandomAccessFile(file, "r").use { raf ->
                val buffer = ByteArray(AnimatedWebpHeader.HEADER_BYTES)
                val read = raf.read(buffer)
                if (read <= 0) ByteArray(0) else buffer.copyOf(read)
            }
        } catch (t: Throwable) {
            ByteArray(0)
        }
    }
}

/**
 * 悬浮窗素材加载器（Phase 4C-4 起以 [PetVisual] 为单位）。
 *
 * 硬性要求：
 * * 解码在**后台线程**，回调回**主线程**；
 * * **新视觉成功后才释放旧视觉**（失败时不动当前视觉）；
 * * 旧请求的结果**不得覆盖**新素材（由 [OverlayRequestGuard] 保证）；
 * * 释放前先 `stop()` 掉还在跑的动画（需求第 12 节：先从 ImageView 移除，再释放引用）；
 * * 不对 `AnimatedImageDrawable` 调用 `Bitmap.recycle()`；
 * * 全程不逐帧读文件、不在主线程解码。
 */
internal class PetImageLoader(
    private val decoder: PetVisualDecoder,
    private val apiLevel: Int = Build.VERSION.SDK_INT,
    private val worker: Executor = defaultWorker(),
    postToMain: ((Runnable) -> Unit)? = null,
) {

    /** 加载结果回调（都在主线程）。 */
    interface Listener {
        fun onLoaded(requestSeq: Long, decoded: DecodedPetVisual, config: PetOverlayConfig)

        fun onFailed(
            requestSeq: Long,
            code: String,
            message: String,
            config: PetOverlayConfig,
        )

        /** 结果已过期（有更新的请求），调用方应忽略。 */
        fun onStale(requestSeq: Long)
    }

    private val poster: (Runnable) -> Unit = postToMain ?: defaultPoster()
    private val guard = OverlayRequestGuard()

    private var currentVisual: DecodedPetVisual? = null
    private var disposed = false

    /** 当前**真正显示中**的素材 ID（null = 仍是占位内容）。 */
    var displayedAssetId: String? = null
        private set

    /** true = 没有任何素材成功显示（悬浮窗显示的是占位内容）。 */
    var isPlaceholder: Boolean = true
        private set

    /** 当前视觉；仅用于测试与诊断。 */
    fun currentVisualOrNull(): DecodedPetVisual? = currentVisual

    fun load(config: PetOverlayConfig, targetSizePx: Int, listener: Listener) {
        if (disposed) return
        val seq = guard.begin()
        OverlayLog.log(
            "visual.decode.start seq=$seq asset=${config.assetId} " +
                "mime=${config.mimeType} animatedHint=${config.isAnimated} " +
                "targetSize=$targetSizePx apiLevel=$apiLevel",
        )
        worker.execute {
            val outcome: Result<DecodedPetVisual> = runCatching {
                decoder.decode(config.filePath, targetSizePx, apiLevel)
            }
            poster {
                handleOutcome(seq, outcome, config, listener)
            }
        }
    }

    private fun handleOutcome(
        seq: Long,
        outcome: Result<DecodedPetVisual>,
        config: PetOverlayConfig,
        listener: Listener,
    ) {
        if (disposed) {
            outcome.getOrNull()?.detachDrawable()
            OverlayLog.log("visual.decode.stale seq=$seq reason=service_disposed")
            return
        }
        // 过期结果：直接丢弃，绝不动当前显示的素材。
        if (!guard.isLatest(seq)) {
            outcome.getOrNull()?.detachDrawable()
            OverlayLog.log("visual.decode.stale seq=$seq reason=${PetVisualError.STALE_REQUEST}")
            listener.onStale(seq)
            return
        }

        outcome.fold(
            onSuccess = { decoded ->
                OverlayLog.log(
                    "visual.decode.success seq=$seq asset=${config.assetId} " +
                        "decoder=${decoded.decoderName} kind=${decoded.kind.name} " +
                        "size=${decoded.width}x${decoded.height} " +
                        "sourceAnimated=${decoded.sourceIsAnimated}",
                )
                val previous = currentVisual
                currentVisual = decoded
                displayedAssetId = config.assetId
                isPlaceholder = false
                listener.onLoaded(seq, decoded, config)
                // 新视觉已经上屏了，这时才释放旧视觉。
                if (previous !== decoded) previous?.detachDrawable()
            },
            onFailure = { error ->
                // 保留旧视觉引用（由 View 层决定"显示错误占位还是保留旧图"），只回报原因。
                val code = (error as? PetImageLoadException)?.code ?: PetVisualError.DECODE_FAILED
                val message = error.message ?: PetVisualError.userMessage(code)
                OverlayLog.warn(
                    "visual.decode.failed seq=$seq asset=${config.assetId} code=$code msg=$message",
                )
                listener.onFailed(seq, code, message, config)
            },
        )
    }

    /** 丢掉当前视觉（例如当前素材已被删除），回到占位状态。 */
    fun clearCurrent() {
        guard.invalidate()
        val previous = currentVisual
        currentVisual = null
        displayedAssetId = null
        isPlaceholder = true
        previous?.detachDrawable()
        OverlayLog.log("visual.clear reason=clearCurrent")
    }

    /**
     * 停止服务时释放资源：作废在途请求 + 停掉动画 + 丢掉引用。
     *
     * 调用方必须**先**把 Drawable 从 ImageView 上摘掉（`PetOverlayView.clearVisual()`），
     * 否则会出现"Drawable 已释放但仍被 View 持有"的窗口期。
     */
    fun dispose() {
        if (disposed) return
        disposed = true
        guard.invalidate()
        val previous = currentVisual
        currentVisual = null
        displayedAssetId = null
        isPlaceholder = true
        previous?.detachDrawable()
        (worker as? ExecutorService)?.shutdownNow()
        OverlayLog.log("visual.clear reason=dispose")
    }

    companion object {

        private fun defaultWorker(): Executor = Executors.newSingleThreadExecutor()

        private fun defaultPoster(): (Runnable) -> Unit {
            val handler = Handler(Looper.getMainLooper())
            return { runnable -> handler.post(runnable) }
        }
    }
}

/**
 * 释放一个视觉对象：**先停动画，再丢掉引用**。
 *
 * 刻意不调用 `Bitmap.recycle()`：动态 WebP 的 Drawable 内部按帧管理解码结果，
 * 手动回收会造成"还在渲染的帧被回收"崩溃；静态图交给 GC 回收即可
 * （Bitmap 在 ARGB_8888 下本来就是堆内存，由 GC 统一管理）。
 */
private fun DecodedPetVisual.detachDrawable() {
    when (val target = visual) {
        is PetVisual.Animated -> (target.drawable as? Animatable)?.let { animatable ->
            if (animatable.isRunning) {
                runCatching { animatable.stop() }
            }
        }
        is PetVisual.Static -> Unit
        is PetVisual.Placeholder -> Unit
    }
}

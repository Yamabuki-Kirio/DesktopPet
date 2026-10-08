package asia.akechi.petlife.overlay

import android.graphics.drawable.Drawable

/**
 * 悬浮桌宠的**统一视觉模型**（Phase 4C-4）。
 *
 * 为什么不再用"多个 Bitmap 字段 + 若干布尔量"：4C-2 只有静态图还能凑合，
 * 一旦引入动态 WebP，就必须同时表达"静态 / 动态 / 占位"三种互斥状态，
 * 松散字段必然出现"既有图又在播放动画又在报错"的矛盾组合。
 *
 * 注意一处**刻意偏离需求建议**：需求建议 `Animated(drawable: AnimatedImageDrawable)`，
 * 这里用 [Drawable] 保存。原因是 `AnimatedImageDrawable` 是 API 28 才有的类，
 * 项目 minSdk 24 —— 把它写进字段类型会让 24~27 设备在加载本类时就要解析该类型。
 * 播放/停止统一走 API 1 就有的 [android.graphics.drawable.Animatable] 接口，
 * "是不是动态"由 [PetVisualKind] 显式表达（而不是靠类型转换猜）。
 */
internal sealed class PetVisual {

    /** 静态素材（PNG / JPG / 静态 WebP）。 */
    data class Static(
        val drawable: Drawable,
        val width: Int,
        val height: Int,
        val source: String,
    ) : PetVisual()

    /** 动态素材（动态 WebP）。[drawable] 实现 [android.graphics.drawable.Animatable]。 */
    data class Animated(
        val drawable: Drawable,
        val width: Int,
        val height: Int,
        val source: String,
    ) : PetVisual()

    /** 占位（加载中 / 失败 / 空 / 诊断）。 */
    data class Placeholder(val reason: String?) : PetVisual()
}

/**
 * 视觉类型（对外诊断口径）。
 *
 * * [static]：普通静态素材；
 * * [animated]：动态素材且**完整播放**（API 28+）；
 * * [animatedFirstFrameFallback]：动态素材但当前系统只能显示第一帧（API 24~27）；
 * * [placeholder]：没有可用素材（占位）。
 */
internal enum class PetVisualKind {
    static,
    animated,
    animatedFirstFrameFallback,
    placeholder;

    /** 传给 Flutter 的 `visualType`。 */
    val wire: String
        get() = when (this) {
            static -> "static"
            animated -> "animated"
            animatedFirstFrameFallback -> "animated"
            placeholder -> "placeholder"
        }

    /** 传给 Flutter 的 `animationFrameMode`。 */
    val frameMode: String
        get() = when (this) {
            static -> "not-applicable"
            animated -> "full-animation"
            animatedFirstFrameFallback -> "first-frame-fallback"
            placeholder -> "not-applicable"
        }
}

/** 视觉类型判定（**纯逻辑**，可 JVM 单测）。 */
internal object PetVisualTypePolicy {

    /** 完整动画需要的最低 API（ImageDecoder + AnimatedImageDrawable）。 */
    const val MIN_API_FULL_ANIMATION = 28

    /**
     * @param sourceIsAnimated 解码器报告的"素材本身是动态的"（API 28+ 靠 Drawable 类型；
     *   24~27 靠文件头）
     */
    fun resolve(sourceIsAnimated: Boolean, apiLevel: Int): PetVisualKind = when {
        !sourceIsAnimated -> PetVisualKind.static
        apiLevel >= MIN_API_FULL_ANIMATION -> PetVisualKind.animated
        else -> PetVisualKind.animatedFirstFrameFallback
    }

    /** 当前系统是否支持完整动画（用于设置页文案与日志）。 */
    fun supportsFullAnimation(apiLevel: Int): Boolean = apiLevel >= MIN_API_FULL_ANIMATION
}

/**
 * 动画播放条件（**纯逻辑**，可 JVM 单测）。
 *
 * 需求第 10 节把条件列成七条，这里集中成一个不可绕过的判定，
 * 避免 `start()/stop()` 散落在多个分支里各判一半。
 */
internal data class AnimationGate(
    val serviceRunning: Boolean,
    val viewAttached: Boolean,
    val petVisible: Boolean,
    val screenInteractive: Boolean,
    val visualIsAnimated: Boolean,
    val stopping: Boolean,
    val instanceActive: Boolean,
) {
    fun shouldAnimate(): Boolean =
        serviceRunning && viewAttached && petVisible && screenInteractive &&
            visualIsAnimated && !stopping && instanceActive

    /** 不允许播放时的原因（诊断用；允许播放时返回 null）。 */
    fun blockedReason(): String? = when {
        !instanceActive -> "service-instance-replaced"
        stopping -> "stopping"
        !serviceRunning -> "service-not-running"
        !viewAttached -> "view-detached"
        !petVisible -> "pet-hidden"
        !screenInteractive -> "screen-off"
        !visualIsAnimated -> "visual-not-animated"
        else -> null
    }
}

/**
 * 动态 WebP 的**文件头识别**（纯逻辑，可 JVM 单测）。
 *
 * API 24~27 没有 `ImageDecoder`，只能用 `BitmapFactory` 解出第一帧；
 * 要给出"这是动态素材，当前只显示第一帧"的准确口径，就得自己看文件头：
 * `RIFF....WEBP` 且带 `ANIM` 块即为动态 WebP。
 *
 * 它只用于**低版本回退口径**，不参与 28+ 的类型判定（28+ 一律以 Drawable 类型为准）。
 */
internal object AnimatedWebpHeader {

    /** 需要读入的文件头长度（足够覆盖 WEBP 的扩展块声明）。 */
    const val HEADER_BYTES = 64

    fun looksAnimated(header: ByteArray): Boolean {
        if (header.size < 16) return false
        if (!matches(header, 0, "RIFF")) return false
        if (!matches(header, 8, "WEBP")) return false
        return indexOf(header, "ANIM") >= 12
    }

    private fun matches(bytes: ByteArray, offset: Int, ascii: String): Boolean {
        if (offset + ascii.length > bytes.size) return false
        return ascii.indices.all { bytes[offset + it] == ascii[it].code.toByte() }
    }

    private fun indexOf(bytes: ByteArray, ascii: String): Int {
        if (ascii.isEmpty() || bytes.size < ascii.length) return -1
        val first = ascii[0].code.toByte()
        for (start in 0..(bytes.size - ascii.length)) {
            if (bytes[start] != first) continue
            if (matches(bytes, start, ascii)) return start
        }
        return -1
    }
}

/** 解码结果（统一视觉模型 + 尺寸 + 类型）。 */
internal data class DecodedPetVisual(
    val kind: PetVisualKind,
    val visual: PetVisual,
    val width: Int,
    val height: Int,
    val sourceIsAnimated: Boolean,
    /** 诊断用：解码实现（`ImageDecoder` / `BitmapFactory` / 测试假实现）。 */
    val decoderName: String,
)

/** 可替换的解码器接口（真机用 [AndroidPetVisualDecoder]；测试注入假实现）。 */
internal interface PetVisualDecoder {
    @Throws(PetImageLoadException::class)
    fun decode(path: String, targetSizePx: Int, apiLevel: Int): DecodedPetVisual
}

/** 统一错误码（需求第 20 节）。 */
internal object PetVisualError {
    const val PATH_NOT_ALLOWED = "path_not_allowed"
    const val FILE_MISSING = "file_missing"
    const val FILE_NOT_REGULAR = "file_not_regular"
    const val FILE_TOO_LARGE = "file_too_large"
    const val INVALID_DIMENSIONS = "invalid_dimensions"
    const val PIXEL_LIMIT_EXCEEDED = "pixel_limit_exceeded"
    const val DECODE_FAILED = "decode_failed"
    const val UNSUPPORTED_ANIMATED_WEBP = "unsupported_animated_webp"
    const val OUT_OF_MEMORY = "out_of_memory"
    const val STALE_REQUEST = "stale_request"
    const val SERVICE_DISPOSED = "service_disposed"
    const val VIEW_DETACHED = "view_detached"

    /** 错误码 → 用户可读中文（Flutter 页面只显示中文，不显示堆栈）。 */
    fun userMessage(code: String): String = when (code) {
        PATH_NOT_ALLOWED -> "素材路径不在 PetLife 管理目录内"
        FILE_MISSING -> "素材文件不存在（可能已被删除）"
        FILE_NOT_REGULAR -> "素材不是一个普通文件"
        FILE_TOO_LARGE -> "素材文件过大"
        INVALID_DIMENSIONS -> "素材尺寸异常"
        PIXEL_LIMIT_EXCEEDED -> "素材像素数超过上限"
        UNSUPPORTED_ANIMATED_WEBP -> "当前 Android 版本不支持动态 WebP 播放"
        OUT_OF_MEMORY -> "内存不足，无法解码该素材"
        STALE_REQUEST -> "该请求已被更新的素材取代"
        SERVICE_DISPOSED -> "悬浮服务已停止"
        VIEW_DETACHED -> "悬浮窗已脱离"
        else -> "素材解码失败"
    }
}

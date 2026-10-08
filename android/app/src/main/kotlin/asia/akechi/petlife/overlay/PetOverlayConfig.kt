package asia.akechi.petlife.overlay

import android.content.Context
import java.io.File
import java.util.Locale

/**
 * 悬浮窗素材配置（Phase 4C-2）。
 *
 * 只有**通过 [OverlayConfigValidator] 校验**的配置才会被写进
 * [PetOverlayStore] 并交给 [PetImageLoader] 解码 ——
 * 校验不过的配置一律"保持现状 + 记录原因"，绝不落盘、绝不加载。
 */
internal data class PetOverlayConfig(
    val schemaVersion: Int,
    val characterId: String,
    val assetId: String,
    val filePath: String,
    val mimeType: String,
    val isAnimated: Boolean,
    val frameCount: Int,
    val animationDurationMs: Int,
    val scale: Float,
    val snapEnabled: Boolean,
    val fixedAssetMode: Boolean,
) {

    /**
     * 素材来源声明为"动态"（由导入侧写入的 `isAnimated`）。
     *
     * Phase 4C-4 起这只是**输入声明**，不代表最终是否播放：真正的判定在
     * [PetVisualTypePolicy.resolve]（API 28+ 且解码得到 `AnimatedImageDrawable`
     * 才算 `animated`；否则回退为 `animatedFirstFrameFallback`）。
     */
    val animatedFirstFrameOnly: Boolean get() = isAnimated

    fun applyTo(store: PetOverlayStore) {
        store.characterId = characterId
        store.assetId = assetId
        store.filePath = filePath
        store.mimeType = mimeType
        store.isAnimated = isAnimated
        store.frameCount = frameCount
        store.animationDurationMs = animationDurationMs
        store.scale = scale
        store.snapEnabled = snapEnabled
        store.fixedAssetMode = fixedAssetMode
    }

    companion object {
        const val SCHEMA_VERSION = 1

        /** 与 Flutter 侧 `AppConstants.appDataFolder` / `AppPaths.assetsRoot` 一致。 */
        const val APP_DATA_FOLDER = "PetLife"
        const val ASSETS_SUBDIR = "assets"

        /**
         * 允许加载的**应用私有素材根目录**（可能不止一个）。
         *
         * 为什么是列表而不是单一目录：Flutter 侧 `AppPaths.assetsRoot` 由
         * `path_provider` 的 `getApplicationSupportDirectory()` 决定，而它在 Android 上
         * 可能是 `<filesDir>` 也可能是 `<dataDir>`（不同 path_provider 版本/厂商实现）。
         * 两者都是**应用私有目录**，因此都接受 —— 这样既不会因为一次映射差异
         * 让所有素材都被判为"越界"（4C-2 真机不可见的重大嫌疑之一），
         * 也不会放宽"只能加载应用私有目录"这条安全边界。
         */
        fun privateAssetRoots(context: Context): List<File> {
            val candidates = ArrayList<File>(2)
            candidates.add(File(File(context.filesDir, APP_DATA_FOLDER), ASSETS_SUBDIR))
            @Suppress("NewApi")
            context.dataDir?.let {
                candidates.add(File(File(it, APP_DATA_FOLDER), ASSETS_SUBDIR))
            }
            return candidates.distinctBy { candidate ->
                runCatching { candidate.canonicalPath }.getOrElse { candidate.absolutePath }
            }
        }

        /** 兼容旧调用：默认取第一个候选根。 */
        fun assetsRootOf(context: Context): File = privateAssetRoots(context).first()

        /** 与 Flutter 侧 `AssetLimits` 保持一致的项目现有素材上限。 */
        const val MAX_FILE_BYTES = 64L * 1024 * 1024
        const val MAX_PIXELS = 64 * 1024 * 1024
        const val MAX_EDGE = 16_384

        /**
         * 允许的 MIME。
         *
         * **GIF 不在其中**：本项目 Android 侧没有验证过 GIF 动画解码，
         * 按需求"不要宣称支持尚未验证的格式"，本阶段直接拒绝。
         */
        val ALLOWED_MIME_TYPES: Set<String> = setOf(
            "image/png",
            "image/jpeg",
            "image/webp",
        )

        /** MIME → 允许的扩展名（jpeg 同时接受 jpg 与 jpeg）。 */
        private val MIME_EXTENSIONS: Map<String, Set<String>> = mapOf(
            "image/png" to setOf("png"),
            "image/jpeg" to setOf("jpg", "jpeg"),
            "image/webp" to setOf("webp"),
        )

        fun allowedExtensions(mimeType: String): Set<String> =
            MIME_EXTENSIONS[mimeType.lowercase(Locale.ROOT)] ?: emptySet()
    }
}

/** 校验结果。 */
internal sealed interface ConfigResult {
    /** 通过校验。[matchedRoot] 是命中的私有根目录（诊断用）。 */
    data class Accepted(
        val config: PetOverlayConfig,
        val matchedRoot: String? = null,
    ) : ConfigResult

    /** 被拒绝：保持现有素材，并把原因回传/落日志。 */
    data class Rejected(val code: String, val message: String) : ConfigResult

    /** 本次调用没有携带配置（例如 `start` 只带指令）。 */
    object Absent : ConfigResult
}

/**
 * 路径与格式策略（**纯逻辑**，不依赖任何 Android 框架类）。
 *
 * 单独抽出来的原因：这是本阶段唯一的"安全边界"，而它完全可以用
 * 普通 JVM 单元测试逐条打靶 —— 不需要真机，也不该等真机才发现。
 */
internal object OverlayPathPolicy {

    /** 路径里出现 `..` 段即视为试图逃逸。 */
    fun hasTraversal(rawPath: String): Boolean =
        rawPath.split('/', '\\').any { it == ".." }

    /**
     * 目标路径（规范化后）是否**严格位于**私有根目录之内。
     *
     * 用规范化路径比较，因此 `assets/../assets/x` 这类伪装会被正确判为"在根内"，
     * 而 `assets/../../etc/passwd` 会被 [hasTraversal] 拦下。
     */
    fun isInside(root: File, target: File): Boolean {
        return try {
            val rootPath = root.canonicalPath.trimEnd(File.separatorChar)
            val targetPath = target.canonicalPath
            targetPath != rootPath && targetPath.startsWith(rootPath + File.separator)
        } catch (t: Throwable) {
            false
        }
    }

    fun extensionOf(path: String): String {
        val name = File(path).name
        val dot = name.lastIndexOf('.')
        if (dot <= 0 || dot == name.length - 1) return ""
        return name.substring(dot + 1).lowercase(Locale.ROOT)
    }
}

/** 尺寸上限（纯逻辑；真实尺寸由 [PetImageLoader] 在"只读边界"阶段取得）。 */
internal object OverlayImageLimits {
    fun validateSize(width: Int, height: Int): String? = when {
        width <= 0 || height <= 0 -> "图片尺寸非法：${width}x$height"
        width > PetOverlayConfig.MAX_EDGE || height > PetOverlayConfig.MAX_EDGE ->
            "图片单边超过上限：${width}x$height > ${PetOverlayConfig.MAX_EDGE}"
        width.toLong() * height.toLong() > PetOverlayConfig.MAX_PIXELS ->
            "图片像素总量超过上限：${width * height} > ${PetOverlayConfig.MAX_PIXELS}"
        else -> null
    }
}

/**
 * 采样率计算（纯逻辑）。
 *
 * 取"不小于所需比例的 2 的幂"：`BitmapFactory` 的 `inSampleSize` 只有在
 * 2 的幂时才保证质量与效率（非 2 的幂在旧版本会被向下取整），
 * 因此这里显式对齐到 2 的幂，避免"算出来 3、实际按 2 解码"导致的内存翻倍。
 */
internal object ImageSampling {

    fun inSampleSize(srcWidth: Int, srcHeight: Int, targetSizePx: Int): Int {
        if (srcWidth <= 0 || srcHeight <= 0 || targetSizePx <= 0) return 1
        var sample = 1
        var halfW = srcWidth
        var halfH = srcHeight
        while (halfW / 2 >= targetSizePx && halfH / 2 >= targetSizePx) {
            halfW /= 2
            halfH /= 2
            sample *= 2
        }
        return sample
    }
}

/**
 * 原生侧配置校验（需求"三、原生配置校验"）。
 *
 * 12 条检查逐条对应；其中"图片尺寸上限"必须真正读到图片边界才知道，
 * 因此放在 [PetImageLoader] 的"只读边界"阶段执行（那里同样会拒绝并回传原因）。
 */
internal object OverlayConfigValidator {

    /** 单根重载（测试与简单调用）。 */
    fun validate(arguments: Any?, assetsRoot: File): ConfigResult =
        validate(arguments, listOf(assetsRoot))

    fun validate(arguments: Any?, assetsRoots: List<File>): ConfigResult {
        val map = arguments as? Map<*, *> ?: return ConfigResult.Absent

        // 1) 协议版本
        val schemaVersion = intOf(map["schemaVersion"]) ?: PetOverlayConfig.SCHEMA_VERSION
        if (schemaVersion != PetOverlayConfig.SCHEMA_VERSION) {
            return ConfigResult.Rejected(
                "unsupported_schema",
                "不支持的配置版本：$schemaVersion",
            )
        }

        // 2) 3) 4) 必填标识
        val characterId = stringOf(map["characterId"])
        if (characterId.isNullOrBlank()) {
            return ConfigResult.Rejected("empty_character_id", "缺少角色 ID")
        }
        val assetId = stringOf(map["assetId"])
        if (assetId.isNullOrBlank()) {
            return ConfigResult.Rejected("empty_asset_id", "缺少素材 ID")
        }
        val filePath = stringOf(map["filePath"])
        if (filePath.isNullOrBlank()) {
            return ConfigResult.Rejected("empty_file_path", "缺少素材文件路径")
        }

        // 8) 路径逃逸
        if (OverlayPathPolicy.hasTraversal(filePath)) {
            return ConfigResult.Rejected("path_traversal", "素材路径不允许包含 ..")
        }

        val file = File(filePath)
        // 7) 必须在**某个**应用私有素材目录之内（同时覆盖 12：不允许任意外部路径）
        val matchedRoot = assetsRoots.firstOrNull { OverlayPathPolicy.isInside(it, file) }
        if (matchedRoot == null) {
            val roots = assetsRoots.joinToString(" | ") { root ->
                runCatching { root.canonicalPath }.getOrElse { root.absolutePath }
            }
            return ConfigResult.Rejected(
                "outside_private_root",
                "素材必须位于 PetLife 应用私有素材目录内（允许根：$roots）",
            )
        }
        // 5) 必须真实存在
        if (!file.exists()) {
            return ConfigResult.Rejected("file_missing", "素材文件不存在")
        }
        // 6) 必须是普通文件
        if (!file.isFile) {
            return ConfigResult.Rejected("not_a_regular_file", "素材路径不是普通文件")
        }
        // 10) 文件大小
        if (file.length() > PetOverlayConfig.MAX_FILE_BYTES) {
            return ConfigResult.Rejected(
                "file_too_large",
                "素材文件过大：${file.length()} 字节",
            )
        }

        // 9) MIME 与扩展名（都必须在允许列表内，且互相对应）
        val mimeType = stringOf(map["mimeType"])?.lowercase(Locale.ROOT).orEmpty()
        if (mimeType !in PetOverlayConfig.ALLOWED_MIME_TYPES) {
            return ConfigResult.Rejected("unsupported_mime", "不支持的素材类型：$mimeType")
        }
        val extension = OverlayPathPolicy.extensionOf(filePath)
        if (extension !in PetOverlayConfig.allowedExtensions(mimeType)) {
            return ConfigResult.Rejected(
                "mime_extension_mismatch",
                "扩展名 .$extension 与类型 $mimeType 不匹配",
            )
        }

        val config = PetOverlayConfig(
            schemaVersion = schemaVersion,
            characterId = characterId,
            assetId = assetId,
            filePath = filePath,
            mimeType = mimeType,
            isAnimated = map["isAnimated"] == true,
            frameCount = intOf(map["frameCount"]) ?: 0,
            animationDurationMs = intOf(map["animationDurationMs"]) ?: 0,
            scale = floatOf(map["scale"]) ?: PetOverlayStore.DEFAULT_SCALE,
            snapEnabled = map["snapEnabled"] != false,
            fixedAssetMode = map["fixedAssetMode"] == true,
        )
        return ConfigResult.Accepted(
            config = config,
            matchedRoot = runCatching { matchedRoot.canonicalPath }
                .getOrElse { matchedRoot.absolutePath },
        )
    }

    private fun stringOf(value: Any?): String? = value as? String

    private fun intOf(value: Any?): Int? = (value as? Number)?.toInt()

    private fun floatOf(value: Any?): Float? = (value as? Number)?.toFloat()
}

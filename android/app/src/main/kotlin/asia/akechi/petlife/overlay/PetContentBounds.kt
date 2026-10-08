package asia.akechi.petlife.overlay

import android.graphics.Bitmap
import android.graphics.BitmapFactory

/**
 * 桌宠素材的**视觉边界**（Phase 4C-6B-1.1，需求 §3）。
 *
 * 为什么不能直接用图片文件尺寸：立绘素材普遍带大量透明留白，
 * 按整张图算出来的"中央缺口"会远大于人物，轮盘被撑开、菜单再次与桌宠分离。
 *
 * 因此这里额外做一次**廉价的采样解码**（`inSampleSize`）只为扫描 alpha 包围盒，
 * 结果以**相对比例**（0~1）保存 —— 它只取决于素材本身，
 * 与窗口尺寸、缩放、横竖屏都无关，因此可以长期缓存。
 *
 * 刻意**不改动已验收的 4C-4 解码链路**：这是独立的一次只读测量，
 * 失败一律回退到"整张图"（[FULL]），绝不影响桌宠显示。
 */
internal data class PetContentBounds(
    val left: Float,
    val top: Float,
    val right: Float,
    val bottom: Float,
) {
    val width: Float get() = (right - left).coerceIn(0.01f, 1f)
    val height: Float get() = (bottom - top).coerceIn(0.01f, 1f)

    val isFull: Boolean
        get() = left <= 0.001f && top <= 0.001f && right >= 0.999f && bottom >= 0.999f

    fun describe(): String =
        "%.3f,%.3f,%.3f,%.3f".format(left, top, right, bottom)

    companion object {
        val FULL = PetContentBounds(0f, 0f, 1f, 1f)

        /**
         * 把相对边界换算成**屏幕绝对矩形**。
         *
         * 纯函数，可 JVM 打靶：`petBounds` 是桌宠窗口的绝对矩形。
         */
        fun toScreenRect(petBounds: OverlayRect, bounds: PetContentBounds): OverlayRect {
            val w = petBounds.width.toFloat()
            val h = petBounds.height.toFloat()
            return OverlayRect.of(
                petBounds.left + w * bounds.left,
                petBounds.top + h * bounds.top,
                petBounds.left + w * bounds.right,
                petBounds.top + h * bounds.bottom,
            )
        }
    }
}

/**
 * 从**已解码的位图**里量出视觉边界（alpha 包围盒）。
 *
 * 抽成纯函数是为了可单测（喂一张带透明边的 Bitmap）。
 */
internal object PetAlphaBounds {

    /** alpha 低于该值视为透明（抗锯齿边缘会产生 1~10 的噪声）。 */
    const val ALPHA_THRESHOLD = 12

    fun measure(bitmap: Bitmap): PetContentBounds {
        val width = bitmap.width
        val height = bitmap.height
        if (width <= 0 || height <= 0) return PetContentBounds.FULL
        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        val row = IntArray(width)
        for (y in 0 until height) {
            bitmap.getPixels(row, 0, width, 0, y, width, 1)
            for (x in 0 until width) {
                val alpha = (row[x] ushr 24) and 0xFF
                if (alpha <= ALPHA_THRESHOLD) continue
                if (x < minX) minX = x
                if (x > maxX) maxX = x
                if (y < minY) minY = y
                if (y > maxY) maxY = y
            }
        }
        if (maxX < 0 || maxY < 0) {
            // 全透明素材：按整张图处理（此时缺口大小已无意义，但不能返回 0 面积）。
            return PetContentBounds.FULL
        }
        return PetContentBounds(
            left = minX.toFloat() / width,
            top = minY.toFloat() / height,
            right = (maxX + 1).toFloat() / width,
            bottom = (maxY + 1).toFloat() / height,
        )
    }

    /**
     * 采样解码一张素材只为量边界。
     *
     * 采样上限 [MAX_SAMPLE_PIXELS]：立绘的包围盒精度不需要原图分辨率，
     * 采样到约 256px 足够，且能把大图的解码成本压到可忽略。
     */
    fun measureFile(path: String, maxSamplePixels: Int = MAX_SAMPLE_PIXELS): PetContentBounds {
        val decodeOptions = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, decodeOptions)
        val width = decodeOptions.outWidth
        val height = decodeOptions.outHeight
        if (width <= 0 || height <= 0) return PetContentBounds.FULL
        val options = BitmapFactory.Options().apply {
            inSampleSize = sampleSizeFor(width, height, maxSamplePixels)
            inPreferredConfig = Bitmap.Config.ARGB_8888
        }
        val bitmap = BitmapFactory.decodeFile(path, options) ?: return PetContentBounds.FULL
        return try {
            measure(bitmap)
        } finally {
            // 只为测量而解码，用完立刻释放（绝不交给任何 View 持有）。
            bitmap.recycle()
        }
    }

    /** 让最长边不超过 [maxPixels] 的最小 2 的幂采样率（纯函数）。 */
    fun sampleSizeFor(width: Int, height: Int, maxPixels: Int): Int {
        if (maxPixels <= 0) return 1
        var sample = 1
        var longEdge = maxOf(width, height)
        while (longEdge / 2 >= maxPixels) {
            longEdge /= 2
            sample *= 2
        }
        return sample.coerceAtLeast(1)
    }

    /** 采样测量的最长边上限（像素）。 */
    const val MAX_SAMPLE_PIXELS = 256
}

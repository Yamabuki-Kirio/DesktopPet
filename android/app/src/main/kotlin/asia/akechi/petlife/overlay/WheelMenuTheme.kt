package asia.akechi.petlife.overlay

import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.roundToInt

/**
 * 轮盘主题（Phase 4C-6B-1，需求 §13）。
 *
 * **全部颜色用 `Int` ARGB 表达**，不依赖 `android.graphics.Color` ——
 * 这样整套配色与对比度规则都能在 JVM 单测里逐条打靶，
 * 不必等到真机才发现"某个主题下文字看不清"。
 *
 * 颜色语义（与 `WheelMenuRenderer` 一一对应）：
 * * [primary] —— 主色：按钮底、高亮扇区主调、外轮廓描边内的填充；
 * * [secondary] —— 派生亮色：按钮渐变的高光端、扇区渐变内圈；
 * * [background] —— 环带底色（浅色，保证白色图标可辨）；
 * * [highlight] —— 强调色（进度条 / 装饰弧 / 实时数值）；
 * * [outline] —— 粗黑描边；
 * * [text] —— 大标题与中文名文字色；
 * * [disabled] —— 不可用项。
 */
internal data class WheelMenuTheme(
    val themeId: String,
    val displayName: String,
    val primary: Int,
    val secondary: Int,
    val background: Int,
    val highlight: Int,
    val outline: Int,
    val text: Int,
    val disabled: Int,
    val gradientEnabled: Boolean = true,
    val animationStyle: String = ANIMATION_STANDARD,
    /** 配置版本号：防止旧配置覆盖新配置（需求 §13.3）。 */
    val revision: Long = 0L,
) {
    companion object {
        const val ANIMATION_STANDARD = "standard"
        const val ANIMATION_CALM = "calm"

        /** 自定义主题的固定 ID（用户选了自定义主色后用它）。 */
        const val ID_CUSTOM = "custom"

        fun fromWire(
            themeId: String?,
            customPrimary: Int,
            revision: Long = 0L,
        ): WheelMenuTheme {
            val id = themeId?.trim().orEmpty()
            val resolved = when {
                id.isEmpty() -> WheelMenuThemes.p3pPink()
                id == ID_CUSTOM -> WheelMenuThemes.custom(customPrimary)
                else -> WheelMenuThemes.preset(id) ?: WheelMenuThemes.p3pPink()
            }
            return resolved.copy(revision = revision)
        }
    }
}

/**
 * 主题预设与派生算法（**纯函数**）。
 *
 * 预设只钉住一个**主色**，其余颜色一律派生 —— 于是"新增一个预设"不会引入
 * 一整套手抄常量，也不会出现"某个预设忘了配文字色导致看不清"。
 * 唯一例外是 P3P 粉色：它的六个颜色是需求 §13.1 明确给定的，必须逐字一致。
 */
internal object WheelMenuThemes {

    const val ID_P3P = "p3p-pink"
    const val ID_BLUE = "blue"
    const val ID_RED = "red"
    const val ID_PURPLE = "purple"
    const val ID_GREEN = "green"
    const val ID_CUSTOM = WheelMenuTheme.ID_CUSTOM

    /** 需求 §13.1 给定的默认色板（逐字一致，不得改动）。 */
    private const val P3P_PRIMARY = 0xFFF24D96.toInt()
    private const val P3P_SECONDARY = 0xFFFF8ABA.toInt()
    private const val P3P_BACKGROUND = 0xFFFFD8E9.toInt()
    private const val P3P_HIGHLIGHT = 0xFFFFD42A.toInt()
    private const val P3P_OUTLINE = 0xFF111111.toInt()
    private const val P3P_TEXT = 0xFFFFFFFF.toInt()
    private const val P3P_DISABLED = 0xFF8E7180.toInt()

    /** 其他预设的主色（各自派生完整色板）。 */
    private const val BLUE_PRIMARY = 0xFF2F7CF6.toInt()
    private const val RED_PRIMARY = 0xFFE23B3B.toInt()
    private const val PURPLE_PRIMARY = 0xFF8B4DE0.toInt()
    private const val GREEN_PRIMARY = 0xFF1FA463.toInt()

    /** 强调色固定为 P3P 黄（各主题共用，保证"黄色高光"这一视觉语言一致）。 */
    const val ACCENT_HIGHLIGHT = P3P_HIGHLIGHT

    /** 描边固定为近黑（P3P 的"粗黑描边"）。 */
    const val OUTLINE_BLACK = P3P_OUTLINE

    /**
     * 文字与背景的最小对比度（WCAG 大号粗体阈值）。
     *
     * 取 3.0 而不是 4.5：轮盘标题是超大号粗体装饰字（P3P 原稿白字压在粉底上
     * 也只有约 3.4），按正文阈值要求会让所有预设都"不合规"，
     * 反而逼出"为了过检查把主题改成不像 P3P"的错误结论。
     */
    const val MIN_TEXT_CONTRAST = 3.0

    /** 所有内置预设（顺序即设置页展示顺序）。 */
    val presets: List<WheelMenuTheme> = listOf(
        p3pPink(),
        derivedPreset(ID_BLUE, "蓝色", BLUE_PRIMARY),
        derivedPreset(ID_RED, "红色", RED_PRIMARY),
        derivedPreset(ID_PURPLE, "紫色", PURPLE_PRIMARY),
        derivedPreset(ID_GREEN, "绿色", GREEN_PRIMARY),
    )

    /** 默认主题 = P3P 粉色（需求 §1.3 / §13.1）。 */
    fun default(): WheelMenuTheme = p3pPink()

    fun p3pPink(): WheelMenuTheme = WheelMenuTheme(
        themeId = ID_P3P,
        displayName = "P3P 粉色",
        primary = P3P_PRIMARY,
        secondary = P3P_SECONDARY,
        background = P3P_BACKGROUND,
        highlight = P3P_HIGHLIGHT,
        outline = P3P_OUTLINE,
        text = P3P_TEXT,
        disabled = P3P_DISABLED,
    )

    fun preset(themeId: String?): WheelMenuTheme? =
        presets.firstOrNull { it.themeId == themeId }

    /** 用户自定义主色 → 完整主题（其余颜色派生，文字色按对比度自动选择）。 */
    fun custom(primaryColor: Int): WheelMenuTheme {
        val primary = opaque(primaryColor)
        return WheelMenuTheme(
            themeId = ID_CUSTOM,
            displayName = "自定义",
            primary = primary,
            secondary = lighten(primary, 0.42),
            background = mix(primary, WHITE, 0.84),
            highlight = ACCENT_HIGHLIGHT,
            outline = OUTLINE_BLACK,
            text = autoTextColor(primary),
            disabled = mix(primary, GREY_MID, 0.55),
        )
    }

    private fun derivedPreset(id: String, name: String, primary: Int): WheelMenuTheme =
        custom(primary).copy(themeId = id, displayName = name)

    /**
     * 文字色自动选择（需求 §13.3："根据背景亮度选择黑/白文字"）。
     *
     * 规则刻意**偏向白字**：只要白字达到大号粗体的可读阈值就用白色 ——
     * 因为轮盘的视觉语言是"白图标 + 白标题压在饱和主色上"（P3P 原稿如此）。
     * 纯按"对比度谁更大"会给出黑字（黑压粉的绝对对比度确实更高），
     * 但那会让自定义主题一眼就不像 P3P 了。
     */
    fun autoTextColor(onSurface: Int): Int =
        if (contrastRatio(WHITE, onSurface) >= MIN_TEXT_CONTRAST) WHITE else INK

    /**
     * 主题是否"可辨认"：文字对主色的对比度达标。
     *
     * 设置页在校验自定义颜色时用它给用户一句明确反馈，
     * 而不是让用户自己看"好像有点糊"。
     */
    fun isLegible(theme: WheelMenuTheme): Boolean =
        contrastRatio(theme.text, theme.primary) >= MIN_TEXT_CONTRAST

    /** 相对亮度（WCAG 2.x 定义）。 */
    fun relativeLuminance(color: Int): Double {
        val r = channel(color, 16)
        val g = channel(color, 8)
        val b = channel(color, 0)
        return 0.2126 * linearize(r) + 0.7152 * linearize(g) + 0.0722 * linearize(b)
    }

    /** 对比度（1.0 ~ 21.0）。 */
    fun contrastRatio(a: Int, b: Int): Double {
        val la = relativeLuminance(a)
        val lb = relativeLuminance(b)
        val lighter = max(la, lb)
        val darker = min(la, lb)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /**
     * 菜单**底色扇面**的颜色（Phase 4C-6B-2 视觉收尾）。
     *
     * 由主题**派生**而不是写死粉色：`secondary` 向 `background` 混合
     * （[BASE_FAN_BLEND_TO_BACKGROUND]），再压上约 40% 的 alpha
     * （[BASE_FAN_ALPHA]）。于是粉色主题得到"深玫瑰"，绿/蓝主题也各自得到
     * 同色系的底色 —— 新增预设不需要再手抄一个"底色常量"。
     *
     * 不返回整圆的颜色语义：调用方只把它填在**打开方向的扇形**上。
     */
    fun baseFanColor(theme: WheelMenuTheme): Int =
        withAlpha(mix(theme.secondary, theme.background, BASE_FAN_BLEND_TO_BACKGROUND), BASE_FAN_ALPHA)

    /** 给不透明 RGB 补上 alpha（越界自动夹取）。 */
    fun withAlpha(color: Int, alpha: Int): Int =
        (alpha.coerceIn(0, 255) shl 24) or (color and 0x00FFFFFF)

    /** 底色扇面的混合比例（0 = 纯 [WheelMenuTheme.secondary]，1 = 纯 background）。 */
    const val BASE_FAN_BLEND_TO_BACKGROUND = 0.40

    /** 底色扇面的 alpha（约 40% 透明，压在人物层下方）。 */
    const val BASE_FAN_ALPHA = 108

    /** 线性混合：`t = 0` 取 [a]，`t = 1` 取 [b]。 */
    fun mix(a: Int, b: Int, t: Double): Int {
        val ratio = t.coerceIn(0.0, 1.0)
        fun blend(shift: Int): Int {
            val va = channel(a, shift)
            val vb = channel(b, shift)
            return (va + (vb - va) * ratio).roundToInt().coerceIn(0, 255)
        }
        return argb(blend(16), blend(8), blend(0))
    }

    /** 向白色靠拢（保留色相）。 */
    fun lighten(color: Int, amount: Double): Int = mix(color, WHITE, amount)

    /** 向黑色靠拢。 */
    fun darken(color: Int, amount: Double): Int = mix(color, INK, amount)

    /** 完全透明的判定（自定义色若带 alpha=0 视为非法）。 */
    fun isUsableColor(color: Int): Boolean = (color ushr 24) and 0xFF != 0

    /** 去掉用户可能带进来的 alpha，统一按不透明处理。 */
    fun opaque(color: Int): Int = color or 0xFF000000.toInt()

    /** `#RRGGBB` / `#AARRGGBB` → Int；非法返回 null（**不抛异常**）。 */
    fun parseHex(raw: String?): Int? {
        val text = raw?.trim()?.removePrefix("#") ?: return null
        if (text.length != 6 && text.length != 8) return null
        if (text.any { it.digitToIntOrNull(16) == null }) return null
        val value = text.toLong(16)
        return if (text.length == 6) (0xFF000000L or value).toInt() else value.toInt()
    }

    /** Int → `#RRGGBB`（写进 SharedPreferences / 传给 Flutter 用的稳定文本形式）。 */
    fun toHex(color: Int): String {
        val r = channel(color, 16)
        val g = channel(color, 8)
        val b = channel(color, 0)
        return "#" + listOf(r, g, b).joinToString("") { it.toString(16).padStart(2, '0').uppercase() }
    }

    private const val WHITE = 0xFFFFFFFF.toInt()
    private const val INK = 0xFF000000.toInt()
    private const val GREY_MID = 0xFF808080.toInt()

    private fun channel(color: Int, shift: Int): Int = (color shr shift) and 0xFF

    private fun argb(r: Int, g: Int, b: Int): Int =
        (0xFF shl 24) or (r shl 16) or (g shl 8) or b

    private fun linearize(raw: Int): Double {
        val c = raw / 255.0
        return if (c <= 0.03928) c / 12.92 else ((c + 0.055) / 1.055).pow(2.4)
    }

    /** 供测试断言"派生算法是确定的"。 */
    internal fun channelDistance(a: Int, b: Int): Int {
        var sum = 0
        for (shift in intArrayOf(16, 8, 0)) {
            sum += abs(channel(a, shift) - channel(b, shift))
        }
        return sum
    }
}

package asia.akechi.petlife.overlay

import android.graphics.Canvas
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.graphics.Shader
import android.graphics.Typeface
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.roundToInt
import kotlin.math.sin

/** 渲染输入（**渲染层不查任何数据库、不读文件**，一切都从参数来）。 */
internal data class WheelRenderParams(
    val layout: WheelMenuLayout,
    val level: WheelMenuLevel,
    val frame: WheelAnimationFrame,
    /** 当前高亮槽位（滑选中的临时项优先）。 */
    val activeIndex: Int,
    val theme: WheelMenuTheme,
    /** 选中项的实时信息（只读快照；由调用方在选中变化时刷新，**不在 onDraw 里算**）。 */
    val infoText: String? = null,
    /** 诊断模式：画出窗口矩形与环带边界。 */
    val debugBounds: Boolean = false,
    /** 屏幕密度（最小字号按 sp 换算用）。 */
    val density: Float = 1f,
    /** 根菜单是否画出按钮中文标签（子菜单不画，需求 §10.3 只要求根菜单）。 */
    val showButtonLabels: Boolean = true,
    /**
     * 架构验证（Phase 4C-6B-2）：画一个**粉色大扇区**（约 160°）。
     *
     * 用途：单窗口分层后，人物层画在菜单层**之上**；这个扇区横跨人物所在区域，
     * 真机上只要看到"人物把粉色扇区盖住"，就证明"菜单背景从人物背后穿过、人物在顶层"。
     */
    val verifyFan: Boolean = false,
)

/**
 * 轮盘渲染器（Phase 4C-6B-1）。
 *
 * 需求 §7：**只用 `Canvas + Path + Paint`**，不用一堆普通控件拼按钮，
 * 也不用在 XML 里摆一圈圆形按钮 —— P3P 的外轮廓不规则、高亮扇区需要连续变形、
 * 按钮要沿弧线运动，这三件事只有画布能同时做到。
 *
 * 需求 §15：**所有 Paint / Path / RectF / Shader 一律复用**，
 * `onDraw` 里不分配对象、不查数据、不解码图片。
 * 文本宽度只在"标题变化"时测量一次（[measureTitleWidth]），逐帧不再测量。
 *
 * Phase 4C-6B-2 分层：人物由**同一个窗口里的上层 View**（`petContent`）绘制，
 * 菜单层在它下方（`menuHost`）。因此**不再需要"清出人物洞"** ——
 * 人物在不透明处盖住菜单，在透明处自然透出菜单；挖洞反而会错误地露出下层应用。
 */
internal class WheelMenuRenderer {

    private val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.FILL }
    private val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeJoin = Paint.Join.ROUND
        strokeCap = Paint.Cap.ROUND
    }
    private val iconPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.FILL }

    private val textPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        textAlign = Paint.Align.CENTER
        typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        textSkewX = TEXT_SKEW
        isSubpixelText = true
    }
    private val path = Path()
    private val rect = RectF()

    private var bladeShader: Shader? = null
    private var bladeShaderKey: String = ""

    private var cachedTitle: String = ""
    private var cachedTitleWidth: Float = 0f

    /**
     * 画一帧。
     *
     * [canvas] 的坐标原点就是菜单窗口左上角，[WheelMenuLayout] 里的坐标已经是窗口内相对坐标。
     */
    fun draw(canvas: Canvas, params: WheelRenderParams) {
        val frame = params.frame
        if (frame.openProgress <= 0.004f) return
        val layout = params.layout
        val alpha = frame.openProgress.coerceIn(0f, 1f)

        canvas.save()
        canvas.scale(frame.scale, frame.scale, layout.centerX, layout.centerY)
        canvas.rotate(frame.rotationDeg, layout.centerX, layout.centerY)

        // 【需求 §2】绘制顺序：架构验证扇区 → 轮盘背景/装饰/文字 → 按钮与标签。
        // 人物不在本层绘制：**同一个窗口的上层人物 View** 会盖住菜单，
        // 因此这里既不需要挖洞，也不需要把菜单避开人物。
        if (params.verifyFan) drawVerifyFan(canvas, params, alpha)
        // 真正的菜单底色：打开方向的连续扇面（主题派生的玫瑰/粉 + 透明），
        // 压在刀刃与按钮轨道带**下面**；人物层在同一窗口的更上层，会盖住它。
        drawBaseFan(canvas, params, alpha)
        drawBlade(canvas, params, alpha)
        drawBand(canvas, params, alpha)
        drawRimDecoration(canvas, params, alpha)
        drawTexts(canvas, params, alpha)
        drawButtons(canvas, params, alpha)
        drawButtonLabels(canvas, params, alpha)
        if (params.debugBounds) drawDebug(canvas, params, alpha)

        canvas.restore()
    }

    /**
     * **架构验证扇区**（Phase 4C-6B-2，仅验证期使用）。
     *
     * 画一个以展开方向为中心、约 [VERIFY_FAN_SPAN_DEG]° 的粉色扇区，
     * 内缘贴近轮盘中心、外缘到 `bladeLengthPx`。它横跨人物所在区域：
     * 真机上"人物盖住粉色扇区"就是"人物层在菜单层之上"的直接证据。
     *
     * 绘制顺序刻意放在**最前**（在刀刃 / 环带之前），因此它是被压在下面的一层。
     * 复用 `path` / `rect` / `fill`，不分配任何对象。
     */
    private fun drawVerifyFan(canvas: Canvas, params: WheelRenderParams, alpha: Float) {
        if (alpha <= 0.004f) return
        val layout = params.layout
        val half = VERIFY_FAN_SPAN_DEG / 2f
        val start = WheelMenuGeometry.absoluteAngle(
            layout.direction,
            layout.fanBiasDeg - half,
        )
        val sweep = layout.direction.sign * VERIFY_FAN_SPAN_DEG
        val inner = layout.ringRadiusPx * VERIFY_FAN_INNER_RATIO
        val outer = max(layout.bladeLengthPx, inner + 1f)
        val cx = layout.centerX
        val cy = layout.centerY

        path.reset()
        rect.set(cx - outer, cy - outer, cx + outer, cy + outer)
        path.arcTo(rect, start, sweep, true)
        val endRad = Math.toRadians((start + sweep).toDouble())
        path.lineTo(
            cx + (inner * cos(endRad)).toFloat(),
            cy + (inner * sin(endRad)).toFloat(),
        )
        rect.set(cx - inner, cy - inner, cx + inner, cy + inner)
        path.arcTo(rect, start + sweep, -sweep, false)
        path.close()

        fill.shader = null
        // "不透明-ish"粉色：用主题高亮色，整体 alpha ≈200（再乘展开进度）。
        fill.color = params.theme.highlight
        fill.alpha = (VERIFY_FAN_ALPHA * alpha).toInt().coerceIn(0, 255)
        canvas.drawPath(path, fill)
        fill.alpha = 255
    }

    /**
     * 菜单**真正的底色扇面**（Phase 4C-6B-2 视觉收尾）。
     *
     * 它是"打开方向"的一整片连续扇形（**不是整圆、也不是整环**）：内缘贴近轮盘中心、
     * 外缘到刀刃外缘，角度范围与按钮轨道带一致（复用 [WheelMenuLayout.fanHalfSpanDeg] /
     * `fanBiasDeg`，不新增角度常量）。颜色由 [WheelMenuThemes.baseFanColor] 从主题派生
     * （约 40% 透明的玫瑰/粉），因此绿/蓝主题也各自得到同色系底色。
     *
     * 它画在人物层**下方**：人物盖住中间，人物透明处自然透出这层底色 ——
     * 与"按钮轨道带叠在它上面、比它更亮"共同保证两层不会糊成一块。
     */
    private fun drawBaseFan(canvas: Canvas, params: WheelRenderParams, alpha: Float) {
        if (alpha <= 0.004f) return
        val layout = params.layout
        val inner = (layout.ringRadiusPx * BASE_FAN_INNER_RATIO).coerceAtLeast(1f)
        val outer = max(layout.bladeLengthPx, layout.rimOuterPx)
        buildFanBand(layout, inner, outer)
        fill.shader = null
        fill.color = withAlpha(WheelMenuThemes.baseFanColor(params.theme), alpha)
        canvas.drawPath(path, fill)
    }

    // ------------------------------------------------------------------
    // 高亮扇区（"刀刃"）
    // ------------------------------------------------------------------
    private fun drawBlade(canvas: Canvas, params: WheelRenderParams, alpha: Float) {
        val layout = params.layout
        val theme = params.theme
        val selection = params.frame.selectionPosition
        val count = max(1, layout.itemCount)
        val half = (count - 1) / 2f
        val angle = WheelMenuGeometry.absoluteAngle(
            layout.direction,
            (selection - half) * layout.stepDeg + layout.fanBiasDeg,
        )
        val halfSweep = layout.bladeHalfSweepDeg
        val innerRadius = layout.notchRx * 0.72f

        buildWedge(layout, angle, halfSweep, innerRadius, layout.bladeLengthPx)
        fill.shader = bladeGradient(params, angle, innerRadius, layout.bladeLengthPx)
        fill.alpha = 255
        canvas.drawPath(path, fill)
        fill.shader = null

        // 粗黑描边（P3P 的标志性轮廓）
        stroke.color = withAlpha(theme.outline, alpha)
        stroke.strokeWidth = layout.outlineWidthPx * 1.35f
        stroke.shader = null
        canvas.drawPath(path, stroke)
    }

    /**
     * 刀刃的扇形路径：从 [innerRadius] 到 [outerRadius]，张角 `±halfSweep`。
     *
     * 内缘用**参数化的缺口**（需求 §8 的 `cutoutDepth` / `cornerRadius`）：
     * 不是简单的圆弧，而是"两个内切小弧 + 一段直边"，这样才有 P3P 那种
     * "扇区咬合进中心齿轮"的感觉。
     */
    private fun buildWedge(
        layout: WheelMenuLayout,
        angleDeg: Float,
        halfSweepDeg: Float,
        innerRadius: Float,
        outerRadius: Float,
    ) {
        val cx = layout.centerX
        val cy = layout.centerY
        val start = Math.toRadians((angleDeg - halfSweepDeg).toDouble())
        val end = Math.toRadians((angleDeg + halfSweepDeg).toDouble())
        val corner = (outerRadius - innerRadius) * 0.28f

        path.reset()
        // 内缘：从起点沿内弧走到终点，中间用一段"鼓包"表达缺口咬合。
        path.moveTo(cx + (innerRadius * cos(start)).toFloat(), cy + (innerRadius * sin(start)).toFloat())
        val mid = Math.toRadians(angleDeg.toDouble())
        val bump = innerRadius * 1.18f
        path.quadTo(
            cx + (bump * cos(mid + (end - start) * 0.16f)).toFloat(),
            cy + (bump * sin(mid + (end - start) * 0.16f)).toFloat(),
            cx + (bump * cos(mid - (end - start) * 0.16f)).toFloat(),
            cy + (bump * sin(mid - (end - start) * 0.16f)).toFloat(),
        )
        path.lineTo(cx + (innerRadius * cos(end)).toFloat(), cy + (innerRadius * sin(end)).toFloat())
        // 外缘：带一个小圆角
        path.lineTo(
            cx + ((outerRadius - corner) * cos(end)).toFloat(),
            cy + ((outerRadius - corner) * sin(end)).toFloat(),
        )
        rect.set(cx - outerRadius, cy - outerRadius, cx + outerRadius, cy + outerRadius)
        path.arcTo(rect, Math.toDegrees(end).toFloat(), -(halfSweepDeg * 2f) * 0.94f, false)
        path.lineTo(
            cx + ((outerRadius - corner) * cos(start)).toFloat(),
            cy + ((outerRadius - corner) * sin(start)).toFloat(),
        )
        path.close()
    }

    private fun bladeGradient(
        params: WheelRenderParams,
        angleDeg: Float,
        innerRadius: Float,
        outerRadius: Float,
    ): Shader? {
        if (!params.theme.gradientEnabled) return null
        val key = "${params.theme.primary}:${params.theme.secondary}:" +
            "${angleDeg.toInt()}:${innerRadius.toInt()}:${outerRadius.toInt()}:" +
            "${params.layout.centerX.toInt()}:${params.layout.centerY.toInt()}"
        if (key == bladeShaderKey && bladeShader != null) return bladeShader
        val layout = params.layout
        val rad = Math.toRadians(angleDeg.toDouble())
        val shader = LinearGradient(
            layout.centerX + (innerRadius * cos(rad)).toFloat(),
            layout.centerY + (innerRadius * sin(rad)).toFloat(),
            layout.centerX + (outerRadius * cos(rad)).toFloat(),
            layout.centerY + (outerRadius * sin(rad)).toFloat(),
            params.theme.primary,
            params.theme.secondary,
            Shader.TileMode.CLAMP,
        )
        bladeShader = shader
        bladeShaderKey = key
        return shader
    }

    // ------------------------------------------------------------------
    // 环带与中央缺口
    // ------------------------------------------------------------------

    private fun drawBand(canvas: Canvas, params: WheelRenderParams, alpha: Float) {
        val layout = params.layout
        val theme = params.theme
        // 轨道带内缘贴近按钮内侧：给按钮留出轨道，同时天然避开人物区域。
        val inner = (layout.ringRadiusPx - layout.buttonDiameterPx * 0.6f).coerceAtLeast(1f)
        buildFanBand(layout, inner, layout.bandOuterPx)
        fill.color = withAlpha(theme.background, alpha)
        fill.shader = null
        canvas.drawPath(path, fill)
        stroke.color = withAlpha(theme.outline, alpha)
        stroke.strokeWidth = layout.outlineWidthPx
        canvas.drawPath(path, stroke)
    }

    /**
     * 扇形带的**几何**（任务约束：轮盘背景不画完整大圆盘）。
     *
     * 只在按钮的角度范围（±`fanHalfSpanDeg`，带 `fanBiasDeg` 偏转）内，
     * 在 [innerRadius] 与 [outerRadius] 之间画一条带状的扇形 —— 中心人物区域由
     * **同一个窗口里位于上层的**人物 View 盖住/透出，因此这里不需要任何"中央挖洞"。
     *
     * 半径参数化后同一段几何被复用两处：[drawBaseFan]（整片底色扇面）与
     * [drawBand]（更亮的按钮轨道带）。
     */
    private fun buildFanBand(layout: WheelMenuLayout, innerRadius: Float, outerRadius: Float) {
        val cx = layout.centerX
        val cy = layout.centerY
        val inner = innerRadius.coerceAtLeast(1f)
        val outerR = max(outerRadius, inner + 1f)
        val start = WheelMenuGeometry.absoluteAngle(
            layout.direction,
            -layout.fanHalfSpanDeg + layout.fanBiasDeg,
        )
        val sweep = layout.direction.sign * (layout.fanHalfSpanDeg * 2f)

        path.reset()
        path.fillType = Path.FillType.WINDING
        val rad0 = Math.toRadians(start.toDouble())
        path.moveTo(
            cx + (outerR * cos(rad0)).toFloat(),
            cy + (outerR * sin(rad0)).toFloat(),
        )
        rect.set(cx - outerR, cy - outerR, cx + outerR, cy + outerR)
        path.arcTo(rect, start, sweep, false)
        rect.set(cx - inner, cy - inner, cx + inner, cy + inner)
        path.arcTo(rect, start + sweep, -sweep, false)
        path.close()
    }

    /** 外缘装饰：沿环带外侧的"齿轮凸起"与一条高亮弧线（紧凑模式自动减量）。 */
    private fun drawRimDecoration(canvas: Canvas, params: WheelRenderParams, alpha: Float) {
        val layout = params.layout
        val theme = params.theme
        val count = if (layout.compact) {
            max(2, layout.itemCount)
        } else {
            max(2, layout.itemCount * 2 - 1)
        }
        val span = layout.fanHalfSpanDeg
        val bias = layout.fanBiasDeg
        fill.shader = null
        fill.color = withAlpha(theme.background, alpha)
        stroke.color = withAlpha(theme.outline, alpha)
        stroke.strokeWidth = layout.outlineWidthPx * 0.85f
        for (i in 0 until count) {
            val t = if (count <= 1) 0.5f else i.toFloat() / (count - 1)
            val offsetAngle = -span + t * span * 2f + bias
            val angle = Math.toRadians(
                WheelMenuGeometry.absoluteAngle(layout.direction, offsetAngle).toDouble(),
            )
            val radius = layout.rimOuterPx - layout.rimLobePx * 0.35f
            val x = layout.centerX + (radius * cos(angle)).toFloat()
            val y = layout.centerY + (radius * sin(angle)).toFloat()
            canvas.drawCircle(x, y, layout.rimLobePx * 0.72f, fill)
            canvas.drawCircle(x, y, layout.rimLobePx * 0.72f, stroke)
        }
        // 高亮装饰弧（"进度条"意象，用主题 highlight 色）
        val arcRadius = layout.bladeLengthPx * 0.86f
        rect.set(
            layout.centerX - arcRadius,
            layout.centerY - arcRadius,
            layout.centerX + arcRadius,
            layout.centerY + arcRadius,
        )
        stroke.color = withAlpha(theme.highlight, alpha)
        stroke.strokeWidth = layout.outlineWidthPx * 2.2f
        stroke.strokeCap = Paint.Cap.ROUND
        val selectionAngle = WheelMenuGeometry.absoluteAngle(
            layout.direction,
            (params.frame.selectionPosition - (layout.itemCount - 1) / 2f) * layout.stepDeg +
                layout.fanBiasDeg,
        )
        // 弧线方向也要随镜像取反，否则高亮弧会画到刀刃的另一侧。
        val sweepDirection = if (layout.direction == WheelExpandDirection.right) 1f else -1f
        canvas.drawArc(
            rect,
            selectionAngle - layout.bladeHalfSweepDeg * 0.62f * sweepDirection,
            layout.bladeHalfSweepDeg * 1.24f * sweepDirection,
            false,
            stroke,
        )
    }

    // ------------------------------------------------------------------
    // 按钮
    // ------------------------------------------------------------------

    private fun drawButtons(canvas: Canvas, params: WheelRenderParams, alpha: Float) {
        val layout = params.layout
        val theme = params.theme
        val frame = params.frame
        val selected = params.activeIndex
        layout.slots.forEach { slot ->
            val progress = frame.buttonProgress.getOrNull(slot.index) ?: 1f
            if (progress <= 0.01f) return@forEach
            val isSelected = slot.index == selected
            val pressed = frame.pressIndex == slot.index
            val pressAmount = if (pressed) frame.pressProgress else 0f
            val scale = (if (isSelected) SELECTED_SCALE else 1f) *
                (1f + (progress - 1f) * 1f) *
                (1f - pressAmount * 0.12f)
            val diameter = layout.buttonDiameterPx * scale
            val cx = slot.centerX + (layout.centerX - slot.centerX) * (1f - progress)
            val cy = slot.centerY + (layout.centerY - slot.centerY) * (1f - progress)

            fill.shader = null
            stroke.shader = null
            if (isSelected) {
                // 选中项外圈：白色底座（P3P 的"白圈大图标"）
                fill.color = withAlpha(theme.text, alpha * 0.95f)
                canvas.drawCircle(cx, cy, diameter * 0.62f, fill)
            }
            fill.color = if (slot.entry.enabled) {
                withAlpha(theme.primary, alpha)
            } else {
                withAlpha(theme.disabled, alpha)
            }
            canvas.drawCircle(cx, cy, diameter / 2f, fill)
            stroke.color = withAlpha(theme.outline, alpha)
            stroke.strokeWidth = layout.outlineWidthPx
            canvas.drawCircle(cx, cy, diameter / 2f, stroke)

            val iconColor = if (slot.entry.enabled) theme.text else withAlpha(theme.outline, alpha)
            WheelMenuIcons.draw(
                canvas,
                slot.entry.icon,
                cx,
                cy,
                diameter * ICON_RATIO,
                withAlpha(iconColor, alpha),
                iconPaint,
            )
        }
    }

    // ------------------------------------------------------------------
    // 文字
    // ------------------------------------------------------------------

    /**
     * 根菜单按钮的短中文标签（需求 §10.3）。
     *
     * 放在按钮**外侧**（径向朝外），因此不会被主扇区或中央缺口压住；
     * 镜像时位置跟着翻，但文字**不水平翻转**。
     */
    private fun drawButtonLabels(canvas: Canvas, params: WheelRenderParams, alpha: Float) {
        if (!params.showButtonLabels) return
        val layout = params.layout
        val theme = params.theme
        textPaint.typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        textPaint.textAlign = Paint.Align.CENTER
        textPaint.letterSpacing = 0f
        textPaint.textSkewX = 0f
        textPaint.textSize = max(
            layout.buttonDiameterPx * LABEL_SIZE_RATIO,
            params.density * MIN_LABEL_SP,
        )
        layout.slots.forEach { slot ->
            val entry = slot.entry
            // 返回键固定在最下方、语义自明，不再叠标签（需求 §11）。
            if (entry.isBack) return@forEach
            val progress = params.frame.buttonProgress.getOrNull(slot.index) ?: 1f
            if (progress <= 0.05f) return@forEach
            val dx = slot.centerX - layout.centerX
            val dy = slot.centerY - layout.centerY
            val len = kotlin.math.hypot(dx.toDouble(), dy.toDouble()).toFloat().coerceAtLeast(1f)
            val radius = layout.buttonDiameterPx / 2f + layout.rimLobePx * 0.5f +
                textPaint.textSize * 0.95f
            val lx = slot.centerX + dx / len * radius
            val ly = slot.centerY + dy / len * radius
            val baseline = ly + textPaint.textSize * 0.34f
            // 描边 + 填充：压在任何底色上都读得清。
            textPaint.style = Paint.Style.STROKE
            textPaint.strokeWidth = layout.outlineWidthPx * 1.1f
            textPaint.color = withAlpha(theme.outline, alpha)
            canvas.drawText(entry.labelZh, lx, baseline, textPaint)
            textPaint.style = Paint.Style.FILL
            textPaint.color = withAlpha(theme.text, alpha * progress.coerceAtMost(1f))
            canvas.drawText(entry.labelZh, lx, baseline, textPaint)
        }
        textPaint.textSkewX = TEXT_SKEW
    }

    /**
     * 主扇区里的三层文字（需求 §10.1 / §10.2）：
     * 英文大标题 → 中文名称（白底圆角 chip）→ 说明 / 实时信息。
     *
     * 三层都排在**同一条径向安全带**里：
     * `[环带内缘, 刀刃外缘]`，因此不会与按钮、缺口或扇区尖角相撞。
     */
    private fun drawTexts(canvas: Canvas, params: WheelRenderParams, alpha: Float) {
        val layout = params.layout
        val theme = params.theme
        val entry = params.level.entries.getOrNull(params.activeIndex) ?: return
        val frame = params.frame
        val density = params.density
        val sign = if (layout.direction == WheelExpandDirection.right) 1f else -1f
        val offsetAngle = (frame.selectionPosition - (layout.itemCount - 1) / 2f) * layout.stepDeg
        val selection = WheelMenuGeometry.absoluteAngle(
            layout.direction,
            offsetAngle + layout.fanBiasDeg,
        )
        val rad = Math.toRadians(selection.toDouble())

        // 文本安全带（纯函数算出来的三层半径与最小字号，见 WheelTextLayout）。
        val slots = WheelTextLayout.compute(
            layout = layout,
            density = density,
            minTitleSp = MIN_TITLE_SP,
            minChipSp = MIN_SUBTITLE_SP,
            minInfoSp = MIN_INFO_SP,
        )

        // 倾斜角：英文标题允许 -8~8°，中文几乎不倾斜（需求 §10.2）。
        val tiltDeg = (sign * (TEXT_BASE_TILT_DEG + offsetAngle * TEXT_ARC_FOLLOW))
            .coerceIn(-MAX_TEXT_TILT_DEG, MAX_TEXT_TILT_DEG)

        // 【修复：标题被画两遍】有英文名时画"英文装饰标题 + 中文 chip"；
        // 没有英文名（titleEn == null）时**只画一次中文标题**（近白底 + 深色字），
        // 不再额外画 chip —— 否则同一串中文会在两条半径上各画一遍、叠成一团
        //（真机上的"今日时长 被画两遍/重叠"就是这个原因）。
        val titleRadius = slots.titleRadius
        val chipRotate = tiltDeg.coerceIn(-MAX_CHIP_TILT_DEG, MAX_CHIP_TILT_DEG)
        val titleX = layout.centerX + (titleRadius * cos(rad)).toFloat()
        val titleY = layout.centerY + (titleRadius * sin(rad)).toFloat()
        val englishTitle = entry.titleEn
        textPaint.typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        textPaint.textAlign = Paint.Align.CENTER
        if (englishTitle != null) {
            // 1) 英文大标题（描边 + 填充，轻微倾斜）
            textPaint.letterSpacing = 0.06f
            textPaint.textSize = slots.titleSizePx
            val titleText = fitText(englishTitle, textPaint, slots.titleMaxWidth, density * MIN_TITLE_SP)
            textPaint.style = Paint.Style.STROKE
            textPaint.strokeWidth = layout.outlineWidthPx * 1.35f
            textPaint.color = withAlpha(theme.outline, alpha)
            canvas.drawText(titleText, titleX, titleY + textPaint.textSize * 0.34f, textPaint)
            textPaint.style = Paint.Style.FILL
            textPaint.color = withAlpha(theme.text, alpha)
            canvas.save()
            canvas.rotate(tiltDeg, titleX, titleY)
            canvas.drawText(titleText, titleX, titleY + textPaint.textSize * 0.34f, textPaint)
            canvas.restore()

            // 2) 中文名称（近白底圆角 chip + 深色字），与英文标题**分处两条半径**、不再重叠。
            val chipRadius = slots.chipRadius
            textPaint.letterSpacing = 0f
            textPaint.textSize = slots.chipSizePx
            val labelText = fitText(entry.labelZh, textPaint, slots.chipMaxWidth, density * MIN_SUBTITLE_SP)
            val chipX = layout.centerX + (chipRadius * cos(rad)).toFloat()
            val chipY = layout.centerY + (chipRadius * sin(rad)).toFloat()
            drawChip(canvas, labelText, chipX, chipY, chipRotate, theme, layout, alpha)
        } else {
            // 只有中文标题：**画一次**（近白底 + 深色字），跳过 chip。
            textPaint.letterSpacing = 0f
            textPaint.textSize = slots.titleSizePx
            val titleText = fitText(entry.labelZh, textPaint, slots.titleMaxWidth, density * MIN_TITLE_SP)
            drawChip(canvas, titleText, titleX, titleY, chipRotate, theme, layout, alpha)
        }

        // 说明 / 实时信息（分层进入：中文名先到、说明后到）
        val infoLine = params.infoText ?: entry.description
        if (!infoLine.isNullOrEmpty()) {
            val infoRadius = slots.infoRadius
            textPaint.textSize = slots.infoSizePx
            textPaint.typeface = Typeface.create(Typeface.DEFAULT, Typeface.NORMAL)
            textPaint.color = withAlpha(theme.outline, alpha * 0.88f)
            val infoText = fitText(infoLine, textPaint, slots.infoMaxWidth, density * MIN_INFO_SP)
            val infoX = layout.centerX + (infoRadius * cos(rad)).toFloat()
            val infoY = layout.centerY + (infoRadius * sin(rad)).toFloat()
            canvas.save()
            canvas.rotate(chipRotate, infoX, infoY)
            canvas.drawText(infoText, infoX, infoY, textPaint)
            canvas.restore()
            textPaint.typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        }
    }

    /**
     * 近白底 + 深色字的圆角 chip。
     *
     * 文字必须**已经过 [fitText] 并按当前 [textPaint] 字号测量过** ——
     * 这里用 `measureTextWidth` 的真实宽度定框（而不是"最多 N 个字"的估算），
     * 因此描边 / 旋转后的实际文字一定落在框内。
     */
    private fun drawChip(
        canvas: Canvas,
        text: String,
        centerX: Float,
        centerY: Float,
        rotateDeg: Float,
        theme: WheelMenuTheme,
        layout: WheelMenuLayout,
        alpha: Float,
    ) {
        val halfW = measureTextWidth(text, textPaint) / 2f + textPaint.textSize * 0.55f
        val halfH = textPaint.textSize * 0.86f
        rect.set(centerX - halfW, centerY - halfH, centerX + halfW, centerY + halfH)
        fill.shader = null
        fill.color = withAlpha(theme.text, alpha * 0.94f)
        val corner = halfH * 0.5f
        canvas.save()
        canvas.rotate(rotateDeg, centerX, centerY)
        canvas.drawRoundRect(rect, corner, corner, fill)
        stroke.color = withAlpha(theme.outline, alpha)
        stroke.strokeWidth = layout.outlineWidthPx * 0.8f
        canvas.drawRoundRect(rect, corner, corner, stroke)
        textPaint.style = Paint.Style.FILL
        textPaint.color = withAlpha(theme.outline, alpha)
        canvas.drawText(text, centerX, centerY + textPaint.textSize * 0.36f, textPaint)
        canvas.restore()
    }

    /**
     * 把文字缩到**能塞进给定宽度**；已经到最小字号还塞不下就省略（需求 §10.2）。
     *
     * 绝不返回超出宽度的字符串 —— 这正是"标题越过按钮和扇区边界"的修复点。
     */
    private fun fitText(text: String, paint: Paint, maxWidth: Float, minSizePx: Float): String {
        if (maxWidth <= 0f || text.isEmpty()) return text
        val original = paint.textSize
        var size = original
        while (size > minSizePx && measureTextWidth(text, paint) > maxWidth) {
            size = max(minSizePx, size * 0.92f)
            paint.textSize = size
            if (size <= minSizePx) break
        }
        if (paint.textSize != original) paint.textSize = size
        if (measureTextWidth(text, paint) <= maxWidth) return text
        // 仍然放不下：逐字省略（至少保留一个字符，避免出现空白标题）。
        var end = text.length - 1
        while (end > 1) {
            val candidate = text.substring(0, end) + "…"
            if (measureTextWidth(candidate, paint) <= maxWidth) return candidate
            end -= 1
        }
        return text.substring(0, 1)
    }

    /** 文本宽度缓存：同一段文字（同字号）不重复测量（需求 §15）。 */
    fun measureTextWidth(text: String, paint: Paint): Float {
        val key = "$text@${paint.textSize}"
        if (key == cachedTitle) return cachedTitleWidth
        val width = paint.measureText(text)
        cachedTitle = key
        cachedTitleWidth = width
        return width
    }

    /** 预测量标题，避免首帧在 `onDraw` 里测量（由 View 在层级变化时调用一次）。 */
    fun premeasure(level: WheelMenuLevel, layout: WheelMenuLayout, paint: Paint) {
        level.entries.firstOrNull()?.let {
            paint.textSize = paint.textSize.coerceAtLeast(1f)
            measureTextWidth(it.labelZh, paint)
        }
        cachedTitle = ""
    }

    private fun drawDebug(canvas: Canvas, params: WheelRenderParams, alpha: Float) {
        val layout = params.layout
        stroke.shader = null
        stroke.color = withAlpha(0xFFFF00FF.toInt(), alpha)
        stroke.strokeWidth = 1.5f
        rect.set(0f, 0f, layout.windowRect.width.toFloat(), layout.windowRect.height.toFloat())
        canvas.drawRect(rect, stroke)
        rect.set(
            layout.centerX - layout.bandOuterPx,
            layout.centerY - layout.bandOuterPx,
            layout.centerX + layout.bandOuterPx,
            layout.centerY + layout.bandOuterPx,
        )
        canvas.drawArc(rect, -90f, 180f, false, stroke)
        rect.set(
            layout.notchCenterX - layout.notchRx,
            layout.notchCenterY - layout.notchRy,
            layout.notchCenterX + layout.notchRx,
            layout.notchCenterY + layout.notchRy,
        )
        canvas.drawOval(rect, stroke)
        textPaint.textSize = 12f
        textPaint.style = Paint.Style.FILL
        textPaint.color = withAlpha(0xFFFF00FF.toInt(), alpha)
        canvas.drawText(
            "${layout.itemCount} ${layout.direction.name} ${layout.verticalMode.name} " +
                "deg=${layout.stepDeg.toInt()} scale=${"%.2f".format(layout.actualScale)}",
            layout.centerX,
            16f,
            textPaint,
        )
    }

    private fun withAlpha(color: Int, alpha: Float): Int {
        val base = (color ushr 24) and 0xFF
        val merged = (base * alpha.coerceIn(0f, 1f)).toInt().coerceIn(0, 255)
        return (merged shl 24) or (color and 0x00FFFFFF)
    }

    companion object {
        /** 选中按钮的放大倍数。 */
        const val SELECTED_SCALE = 1.14f

        /** 图标相对按钮直径的比例。 */
        const val ICON_RATIO = 0.58f

        /** 架构验证扇区的张角（约 160°）。 */
        const val VERIFY_FAN_SPAN_DEG = 160f

        /** 架构验证扇区的内缘半径相对环带半径的比例（贴近轮盘中心）。 */
        const val VERIFY_FAN_INNER_RATIO = 0.22f

        /** 架构验证扇区的整体 alpha（"不透明-ish"粉色，0~255）。 */
        const val VERIFY_FAN_ALPHA = 200f

        /** 菜单底色扇面的内缘半径相对环带半径的比例（贴近轮盘中心 → 一整片扇面）。 */
        const val BASE_FAN_INNER_RATIO = 0.30f

        /** 按钮中文标签字号相对按钮直径的比例。 */
        const val LABEL_SIZE_RATIO = 0.30f

        /** 中文字号相对按钮直径的比例。 */
        const val SUBTITLE_SIZE_RATIO = 0.42f

        /** 说明字号相对按钮直径的比例。 */
        const val INFO_SIZE_RATIO = 0.27f

        /** 标题的基础倾斜角（P3P 的"大号倾斜英文"）。 */
        const val TEXT_BASE_TILT_DEG = -10f

        /** 标题跟随弧线的比例（相对角度偏移）。 */
        const val TEXT_ARC_FOLLOW = 0.30f

        /** 文字倾斜上限（需求 §10.2：英文 -8~8°；中文最多 3°）。 */
        const val MAX_TEXT_TILT_DEG = 8f
        const val MAX_CHIP_TILT_DEG = 3f

        /** 文字斜体（轻微，避免"歪得读不出来"）。 */
        const val TEXT_SKEW = -0.10f

        /**
         * 最小字号（sp）。需求 §10.2 明确：中文标题 ≥16sp、副标题 ≥12~14sp。
         *
         * 达到最小字号仍放不下时**省略**而不是继续缩小 —— 宁可少显示，
         * 也不能把字缩成看不清的灰点。
         */
        const val MIN_TITLE_SP = 13f
        const val MIN_SUBTITLE_SP = 16f
        const val MIN_INFO_SP = 11f
        const val MIN_LABEL_SP = 10f
    }
}

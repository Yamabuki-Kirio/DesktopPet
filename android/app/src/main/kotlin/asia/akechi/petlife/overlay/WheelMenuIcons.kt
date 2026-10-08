package asia.akechi.petlife.overlay

import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF

/**
 * 轮盘图标（**原创几何**，Phase 4C-6B-1）。
 *
 * 需求 §7 明确：**不直接复制 P3P 游戏图标**，也不打包任何游戏资源。
 * 因此这里全部用 `Path` 现场画 —— 好处有三：
 * 1. 天然支持换色（画的时候传入当前主题的图标色）与高亮；
 * 2. 不引入位图，不需要为每个密度准备多套图；
 * 3. 图标保持**直立**（需求 §10.2：不跟随圆周倒转），旋转由调用方决定，
 *    图标自身永远画在 `[-1,1]²` 的归一化坐标系里。
 *
 * 所有坐标都是归一化单位（1 = 图标半边长），描边宽度也用同一套单位，
 * 因此同一个图标在任意尺寸下比例一致。
 */
internal object WheelMenuIcons {

    /** 归一化描边宽度。 */
    private const val STROKE = 0.16f

    /**
     * 在 `(cx, cy)` 处画一个边长为 `size` 的图标。
     *
     * [paint] 由调用方复用（**不要在绘制循环里 new Paint**）。
     */
    fun draw(
        canvas: Canvas,
        icon: WheelMenuIcon,
        cx: Float,
        cy: Float,
        size: Float,
        color: Int,
        paint: Paint,
    ) {
        if (size <= 0f) return
        val half = size / 2f
        canvas.save()
        canvas.translate(cx, cy)
        canvas.scale(half, half)
        paint.color = color
        paint.strokeWidth = STROKE
        paint.strokeCap = Paint.Cap.ROUND
        paint.strokeJoin = Paint.Join.ROUND
        drawNormalized(canvas, icon, paint)
        canvas.restore()
    }

    private fun drawNormalized(canvas: Canvas, icon: WheelMenuIcon, paint: Paint) {
        when (icon) {
            WheelMenuIcon.pet -> pet(canvas, paint)
            WheelMenuIcon.appearance -> sparkle(canvas, paint)
            WheelMenuIcon.record -> bars(canvas, paint)
            WheelMenuIcon.tools -> wrench(canvas, paint)
            WheelMenuIcon.gear -> gear(canvas, paint)
            WheelMenuIcon.hide -> eyeOff(canvas, paint)
            WheelMenuIcon.cycle -> ringArrow(canvas, paint, gapStartDeg = 20f, gapEndDeg = 300f)
            WheelMenuIcon.state -> stateDot(canvas, paint)
            WheelMenuIcon.hand -> hand(canvas, paint)
            WheelMenuIcon.refresh -> doubleArc(canvas, paint)
            WheelMenuIcon.pin -> lock(canvas, paint)
            WheelMenuIcon.resize -> resize(canvas, paint)
            WheelMenuIcon.home -> home(canvas, paint)
            WheelMenuIcon.back -> back(canvas, paint)
            WheelMenuIcon.prev -> chevron(canvas, paint, pointingRight = false)
            WheelMenuIcon.next -> chevron(canvas, paint, pointingRight = true)
            WheelMenuIcon.shuffle -> shuffle(canvas, paint)
            WheelMenuIcon.heart -> heart(canvas, paint)
            WheelMenuIcon.character -> people(canvas, paint)
            WheelMenuIcon.mapping -> gridArrow(canvas, paint)
            WheelMenuIcon.library -> folder(canvas, paint)
            WheelMenuIcon.clock -> clock(canvas, paint, topButton = false)
            WheelMenuIcon.timer -> clock(canvas, paint, topButton = true)
            WheelMenuIcon.app -> appGrid(canvas, paint)
            WheelMenuIcon.pause -> pause(canvas, paint)
            WheelMenuIcon.sync -> ringArrow(canvas, paint, gapStartDeg = 150f, gapEndDeg = 60f)
            WheelMenuIcon.cloud -> cloud(canvas, paint)
            WheelMenuIcon.chart -> lineChart(canvas, paint)
            WheelMenuIcon.bolt -> bolt(canvas, paint)
            WheelMenuIcon.star -> star(canvas, paint)
            WheelMenuIcon.edit -> pencil(canvas, paint)
            WheelMenuIcon.palette -> palette(canvas, paint)
            WheelMenuIcon.opacity -> opacity(canvas, paint)
            WheelMenuIcon.ruler -> ruler(canvas, paint)
            WheelMenuIcon.vibrate -> vibrate(canvas, paint)
            WheelMenuIcon.sound -> sound(canvas, paint)
            WheelMenuIcon.info -> info(canvas, paint)
            WheelMenuIcon.restart -> ringArrow(canvas, paint, gapStartDeg = 300f, gapEndDeg = 20f)
            WheelMenuIcon.power -> power(canvas, paint)
        }
    }

    // ------------------------------------------------------------------
    // 基础图元
    // ------------------------------------------------------------------

    private fun fill(canvas: Canvas, paint: Paint, block: Path.() -> Unit) {
        paint.style = Paint.Style.FILL
        canvas.drawPath(Path().apply(block), paint)
    }

    private fun stroke(canvas: Canvas, paint: Paint, block: Path.() -> Unit) {
        paint.style = Paint.Style.STROKE
        canvas.drawPath(Path().apply(block), paint)
    }

    private fun circle(canvas: Canvas, paint: Paint, cx: Float, cy: Float, r: Float, filled: Boolean) {
        paint.style = if (filled) Paint.Style.FILL else Paint.Style.STROKE
        canvas.drawCircle(cx, cy, r, paint)
    }

    private fun poly(canvas: Canvas, paint: Paint, vararg points: Float) {
        fill(canvas, paint) {
            moveTo(points[0], points[1])
            var i = 2
            while (i < points.size) {
                lineTo(points[i], points[i + 1])
                i += 2
            }
            close()
        }
    }

    /** 箭头（指向由 [dx]/[dy] 决定，长度 [length]）。 */
    private fun arrowHead(
        canvas: Canvas,
        paint: Paint,
        tipX: Float,
        tipY: Float,
        dx: Float,
        dy: Float,
        length: Float = 0.34f,
    ) {
        val norm = kotlin.math.hypot(dx.toDouble(), dy.toDouble()).toFloat().coerceAtLeast(1e-4f)
        val ux = dx / norm
        val uy = dy / norm
        val px = -uy
        val py = ux
        val back = length
        val spread = length * 0.62f
        poly(
            canvas, paint,
            tipX, tipY,
            tipX - ux * back + px * spread, tipY - uy * back + py * spread,
            tipX - ux * back - px * spread, tipY - uy * back - py * spread,
        )
    }

    // ------------------------------------------------------------------
    // 具体图标
    // ------------------------------------------------------------------

    private fun pet(canvas: Canvas, paint: Paint) {
        // 耳朵
        poly(canvas, paint, -0.72f, -0.34f, -0.34f, -0.92f, -0.2f, -0.4f)
        poly(canvas, paint, 0.72f, -0.34f, 0.34f, -0.92f, 0.2f, -0.4f)
        circle(canvas, paint, 0f, 0.12f, 0.72f, filled = true)
    }

    private fun sparkle(canvas: Canvas, paint: Paint) {
        fill(canvas, paint) {
            moveTo(0f, -0.9f)
            quadTo(0.16f, -0.16f, 0.9f, 0f)
            quadTo(0.16f, 0.16f, 0f, 0.9f)
            quadTo(-0.16f, 0.16f, -0.9f, 0f)
            quadTo(-0.16f, -0.16f, 0f, -0.9f)
            close()
        }
        fill(canvas, paint) {
            moveTo(-0.66f, -0.78f)
            quadTo(-0.56f, -0.44f, -0.26f, -0.34f)
            quadTo(-0.56f, -0.24f, -0.66f, 0.1f)
            quadTo(-0.76f, -0.24f, -1.06f, -0.34f)
            quadTo(-0.76f, -0.44f, -0.66f, -0.78f)
            close()
        }
    }

    private fun bars(canvas: Canvas, paint: Paint) {
        fill(canvas, paint) {
            addRect(-0.82f, 0.16f, -0.42f, 0.86f, Path.Direction.CW)
            addRect(-0.2f, -0.3f, 0.2f, 0.86f, Path.Direction.CW)
            addRect(0.42f, -0.8f, 0.82f, 0.86f, Path.Direction.CW)
        }
    }

    private fun wrench(canvas: Canvas, paint: Paint) {
        stroke(canvas, paint) {
            moveTo(-0.62f, 0.66f)
            lineTo(0.24f, -0.24f)
        }
        circle(canvas, paint, 0.48f, -0.5f, 0.36f, filled = false)
        fill(canvas, paint) {
            addRect(-0.86f, 0.42f, -0.36f, 0.9f, Path.Direction.CW)
        }
    }

    private fun gear(canvas: Canvas, paint: Paint) {
        // 齿：8 个沿圆周的小梯形
        fill(canvas, paint) {
            for (i in 0 until 8) {
                val angle = Math.toRadians((i * 45).toDouble())
                val cosA = kotlin.math.cos(angle).toFloat()
                val sinA = kotlin.math.sin(angle).toFloat()
                val px = -sinA
                val py = cosA
                val inner = 0.58f
                val outer = 0.98f
                val wide = 0.2f
                moveTo(cosA * inner + px * wide, sinA * inner + py * wide)
                lineTo(cosA * outer + px * wide * 0.7f, sinA * outer + py * wide * 0.7f)
                lineTo(cosA * outer - px * wide * 0.7f, sinA * outer - py * wide * 0.7f)
                lineTo(cosA * inner - px * wide, sinA * inner - py * wide)
                close()
            }
        }
        // 环体用描边表达"中心是孔"，不依赖任何主题色。
        circle(canvas, paint, 0f, 0f, 0.64f, filled = false)
    }

    private fun eyeOff(canvas: Canvas, paint: Paint) {
        stroke(canvas, paint) {
            moveTo(-0.92f, 0f)
            quadTo(0f, -0.72f, 0.92f, 0f)
            quadTo(0f, 0.72f, -0.92f, 0f)
            close()
        }
        circle(canvas, paint, 0f, 0f, 0.26f, filled = true)
        stroke(canvas, paint) {
            moveTo(-0.86f, 0.82f)
            lineTo(0.86f, -0.82f)
        }
    }

    private fun ringArrow(canvas: Canvas, paint: Paint, gapStartDeg: Float, gapEndDeg: Float) {
        val rect = RectF(-0.78f, -0.78f, 0.78f, 0.78f)
        stroke(canvas, paint) {
            addArc(rect, gapStartDeg, (gapEndDeg - gapStartDeg + 360f) % 360f)
        }
        val angle = Math.toRadians(gapEndDeg.toDouble())
        val x = (kotlin.math.cos(angle) * 0.78).toFloat()
        val y = (kotlin.math.sin(angle) * 0.78).toFloat()
        val tangent = Math.toRadians(gapEndDeg + 90.0)
        arrowHead(
            canvas, paint, x, y,
            kotlin.math.cos(tangent).toFloat(),
            kotlin.math.sin(tangent).toFloat(),
        )
    }

    private fun stateDot(canvas: Canvas, paint: Paint) {
        circle(canvas, paint, 0f, 0f, 0.86f, filled = false)
        circle(canvas, paint, 0f, 0f, 0.38f, filled = true)
    }

    private fun hand(canvas: Canvas, paint: Paint) {
        fill(canvas, paint) {
            addRoundRect(RectF(-0.56f, -0.1f, 0.56f, 0.9f), 0.22f, 0.22f, Path.Direction.CW)
            addRoundRect(RectF(-0.6f, -0.92f, -0.32f, 0.1f), 0.14f, 0.14f, Path.Direction.CW)
            addRoundRect(RectF(-0.22f, -1.0f, 0.06f, 0.1f), 0.14f, 0.14f, Path.Direction.CW)
            addRoundRect(RectF(0.16f, -0.9f, 0.44f, 0.1f), 0.14f, 0.14f, Path.Direction.CW)
            addRoundRect(RectF(0.5f, -0.5f, 0.9f, 0.1f), 0.14f, 0.14f, Path.Direction.CW)
        }
    }

    private fun doubleArc(canvas: Canvas, paint: Paint) {
        val rect = RectF(-0.82f, -0.82f, 0.82f, 0.82f)
        stroke(canvas, paint) { addArc(rect, 200f, 130f) }
        stroke(canvas, paint) { addArc(rect, 20f, 130f) }
        arrowHead(canvas, paint, -0.74f, -0.36f, -0.5f, -0.86f)
        arrowHead(canvas, paint, 0.74f, 0.36f, 0.5f, 0.86f)
    }

    private fun lock(canvas: Canvas, paint: Paint) {
        stroke(canvas, paint) {
            addArc(RectF(-0.44f, -0.88f, 0.44f, 0.02f), 180f, 180f)
        }
        fill(canvas, paint) {
            addRoundRect(RectF(-0.66f, -0.02f, 0.66f, 0.86f), 0.16f, 0.16f, Path.Direction.CW)
        }
    }

    private fun resize(canvas: Canvas, paint: Paint) {
        stroke(canvas, paint) {
            moveTo(-0.66f, 0.66f)
            lineTo(0.66f, -0.66f)
        }
        arrowHead(canvas, paint, -0.8f, 0.8f, -1f, 1f)
        arrowHead(canvas, paint, 0.8f, -0.8f, 1f, -1f)
        stroke(canvas, paint) {
            moveTo(-0.92f, 0.28f)
            lineTo(-0.92f, 0.92f)
            lineTo(-0.28f, 0.92f)
            moveTo(0.92f, -0.28f)
            lineTo(0.92f, -0.92f)
            lineTo(0.28f, -0.92f)
        }
    }

    private fun home(canvas: Canvas, paint: Paint) {
        poly(canvas, paint, 0f, -0.92f, 0.96f, 0f, -0.96f, 0f)
        fill(canvas, paint) {
            addRect(-0.62f, 0f, 0.62f, 0.86f, Path.Direction.CW)
        }
    }

    private fun back(canvas: Canvas, paint: Paint) {
        stroke(canvas, paint) {
            moveTo(0.72f, 0.34f)
            lineTo(-0.1f, 0.34f)
            quadTo(-0.66f, 0.34f, -0.66f, -0.14f)
            lineTo(-0.66f, -0.62f)
        }
        arrowHead(canvas, paint, -0.66f, -0.86f, 0f, -1f)
    }

    private fun chevron(canvas: Canvas, paint: Paint, pointingRight: Boolean) {
        val dir = if (pointingRight) 1f else -1f
        stroke(canvas, paint) {
            moveTo(-0.36f * dir, -0.86f)
            lineTo(0.36f * dir, 0f)
            lineTo(-0.36f * dir, 0.86f)
        }
    }

    private fun shuffle(canvas: Canvas, paint: Paint) {
        stroke(canvas, paint) {
            moveTo(-0.86f, -0.56f)
            lineTo(-0.1f, -0.56f)
            lineTo(0.72f, 0.56f)
            moveTo(-0.86f, 0.56f)
            lineTo(-0.1f, 0.56f)
            lineTo(0.72f, -0.56f)
        }
        arrowHead(canvas, paint, 0.94f, 0.7f, 1f, 0.4f)
        arrowHead(canvas, paint, 0.94f, -0.7f, 1f, -0.4f)
    }

    private fun heart(canvas: Canvas, paint: Paint) {
        fill(canvas, paint) {
            moveTo(0f, 0.9f)
            cubicTo(-1.2f, 0f, -0.62f, -0.98f, 0f, -0.34f)
            cubicTo(0.62f, -0.98f, 1.2f, 0f, 0f, 0.9f)
            close()
        }
    }

    private fun people(canvas: Canvas, paint: Paint) {
        circle(canvas, paint, -0.36f, -0.36f, 0.34f, filled = true)
        circle(canvas, paint, 0.42f, -0.28f, 0.28f, filled = true)
        fill(canvas, paint) {
            addRoundRect(RectF(-0.96f, 0.06f, 0.24f, 0.88f), 0.26f, 0.26f, Path.Direction.CW)
            addRoundRect(RectF(0.16f, 0.18f, 0.86f, 0.88f), 0.24f, 0.24f, Path.Direction.CW)
        }
    }

    private fun gridArrow(canvas: Canvas, paint: Paint) {
        fill(canvas, paint) {
            addRect(-0.92f, -0.92f, -0.14f, -0.14f, Path.Direction.CW)
            addRect(-0.92f, 0.14f, -0.14f, 0.92f, Path.Direction.CW)
            addRect(0.14f, -0.92f, 0.92f, -0.14f, Path.Direction.CW)
        }
        stroke(canvas, paint) {
            moveTo(0.2f, 0.72f)
            lineTo(0.82f, 0.72f)
        }
        arrowHead(canvas, paint, 0.94f, 0.72f, 1f, 0f)
    }

    private fun folder(canvas: Canvas, paint: Paint) {
        fill(canvas, paint) {
            moveTo(-0.92f, -0.6f)
            lineTo(-0.24f, -0.6f)
            lineTo(-0.04f, -0.36f)
            lineTo(0.92f, -0.36f)
            lineTo(0.92f, 0.78f)
            lineTo(-0.92f, 0.78f)
            close()
        }
    }

    private fun clock(canvas: Canvas, paint: Paint, topButton: Boolean) {
        circle(canvas, paint, 0f, if (topButton) 0.12f else 0f, 0.78f, filled = false)
        stroke(canvas, paint) {
            moveTo(0f, if (topButton) 0.12f else 0f)
            lineTo(0f, if (topButton) -0.34f else -0.46f)
            moveTo(0f, if (topButton) 0.12f else 0f)
            lineTo(0.38f, if (topButton) 0.36f else 0.24f)
        }
        if (topButton) {
            fill(canvas, paint) {
                addRoundRect(RectF(-0.24f, -0.98f, 0.24f, -0.7f), 0.08f, 0.08f, Path.Direction.CW)
            }
        }
    }

    private fun appGrid(canvas: Canvas, paint: Paint) {
        fill(canvas, paint) {
            addRoundRect(RectF(-0.92f, -0.92f, 0.92f, 0.92f), 0.28f, 0.28f, Path.Direction.CW)
        }
    }

    private fun pause(canvas: Canvas, paint: Paint) {
        fill(canvas, paint) {
            addRoundRect(RectF(-0.6f, -0.86f, -0.16f, 0.86f), 0.1f, 0.1f, Path.Direction.CW)
            addRoundRect(RectF(0.16f, -0.86f, 0.6f, 0.86f), 0.1f, 0.1f, Path.Direction.CW)
        }
    }

    private fun cloud(canvas: Canvas, paint: Paint) {
        circle(canvas, paint, -0.36f, 0.06f, 0.42f, filled = true)
        circle(canvas, paint, 0.16f, -0.24f, 0.5f, filled = true)
        circle(canvas, paint, 0.52f, 0.18f, 0.34f, filled = true)
        fill(canvas, paint) {
            addRect(-0.36f, 0.2f, 0.56f, 0.62f, Path.Direction.CW)
        }
    }

    private fun lineChart(canvas: Canvas, paint: Paint) {
        stroke(canvas, paint) {
            moveTo(-0.86f, 0.86f)
            lineTo(-0.86f, -0.86f)
            moveTo(-0.86f, 0.86f)
            lineTo(0.86f, 0.86f)
        }
        stroke(canvas, paint) {
            moveTo(-0.6f, 0.36f)
            lineTo(-0.12f, -0.2f)
            lineTo(0.24f, 0.16f)
            lineTo(0.72f, -0.56f)
        }
    }

    private fun bolt(canvas: Canvas, paint: Paint) {
        poly(
            canvas, paint,
            0.36f, -0.96f,
            -0.62f, 0.1f,
            -0.06f, 0.1f,
            -0.36f, 0.96f,
            0.62f, -0.16f,
            0.06f, -0.16f,
        )
    }

    private fun star(canvas: Canvas, paint: Paint) {
        fill(canvas, paint) {
            val points = 5
            for (i in 0 until points * 2) {
                val radius = if (i % 2 == 0) 0.98f else 0.44f
                val angle = Math.toRadians((-90 + i * 180.0 / points))
                val x = (radius * kotlin.math.cos(angle)).toFloat()
                val y = (radius * kotlin.math.sin(angle)).toFloat()
                if (i == 0) moveTo(x, y) else lineTo(x, y)
            }
            close()
        }
    }

    private fun pencil(canvas: Canvas, paint: Paint) {
        fill(canvas, paint) {
            moveTo(-0.86f, 0.86f)
            lineTo(-0.62f, 0.24f)
            lineTo(0.36f, -0.74f)
            lineTo(0.78f, -0.32f)
            lineTo(-0.24f, 0.66f)
            close()
        }
    }

    private fun palette(canvas: Canvas, paint: Paint) {
        circle(canvas, paint, 0f, 0f, 0.92f, filled = true)
    }

    private fun opacity(canvas: Canvas, paint: Paint) {
        circle(canvas, paint, 0f, 0f, 0.88f, filled = false)
        fill(canvas, paint) {
            moveTo(0f, -0.88f)
            arcTo(RectF(-0.88f, -0.88f, 0.88f, 0.88f), -90f, 180f)
            close()
        }
    }

    private fun ruler(canvas: Canvas, paint: Paint) {
        fill(canvas, paint) {
            addRoundRect(RectF(-0.96f, -0.4f, 0.96f, 0.4f), 0.12f, 0.12f, Path.Direction.CW)
        }
        stroke(canvas, paint) {
            var x = -0.6f
            while (x <= 0.61f) {
                moveTo(x, -0.4f)
                lineTo(x, 0.06f)
                x += 0.4f
            }
        }
    }

    private fun vibrate(canvas: Canvas, paint: Paint) {
        fill(canvas, paint) {
            addRoundRect(RectF(-0.34f, -0.9f, 0.34f, 0.9f), 0.14f, 0.14f, Path.Direction.CW)
        }
        stroke(canvas, paint) {
            moveTo(-0.62f, -0.44f)
            lineTo(-0.62f, 0.44f)
            moveTo(0.62f, -0.44f)
            lineTo(0.62f, 0.44f)
        }
    }

    private fun sound(canvas: Canvas, paint: Paint) {
        poly(
            canvas, paint,
            -0.88f, -0.24f,
            -0.42f, -0.24f,
            -0.04f, -0.72f,
            -0.04f, 0.72f,
            -0.42f, 0.24f,
            -0.88f, 0.24f,
        )
        stroke(canvas, paint) {
            moveTo(0.24f, -0.4f)
            quadTo(0.56f, 0f, 0.24f, 0.4f)
        }
        stroke(canvas, paint) {
            moveTo(0.5f, -0.68f)
            quadTo(1.0f, 0f, 0.5f, 0.68f)
        }
    }

    private fun info(canvas: Canvas, paint: Paint) {
        circle(canvas, paint, 0f, 0f, 0.9f, filled = true)
        fill(canvas, paint) {
            addRect(-0.14f, -0.6f, 0.14f, -0.3f, Path.Direction.CW)
            addRect(-0.14f, -0.12f, 0.14f, 0.6f, Path.Direction.CW)
        }
    }

    private fun power(canvas: Canvas, paint: Paint) {
        stroke(canvas, paint) {
            addArc(RectF(-0.82f, -0.82f, 0.82f, 0.82f), -58f, 296f)
        }
        stroke(canvas, paint) {
            moveTo(0f, -0.92f)
            lineTo(0f, -0.12f)
        }
    }
}

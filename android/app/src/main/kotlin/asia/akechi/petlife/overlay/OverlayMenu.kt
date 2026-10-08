package asia.akechi.petlife.overlay

import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * 整数矩形（**屏幕绝对坐标**或**窗口内相对坐标**）。
 *
 * 为什么不用 `android.graphics.Rect`：几何必须能在 JVM 单测里逐条打靶，
 * 不能依赖任何 `android.*` 类型。
 */
internal data class OverlayRect(
    val left: Int,
    val top: Int,
    val right: Int,
    val bottom: Int,
) {
    val width: Int get() = (right - left).coerceAtLeast(0)

    val height: Int get() = (bottom - top).coerceAtLeast(0)

    val centerX: Int get() = left + width / 2

    val centerY: Int get() = top + height / 2

    val isUsable: Boolean get() = width > 0 && height > 0

    fun contains(x: Int, y: Int): Boolean = x >= left && x < right && y >= top && y < bottom

    fun translate(dx: Int, dy: Int): OverlayRect =
        OverlayRect(left + dx, top + dy, right + dx, bottom + dy)

    fun union(other: OverlayRect): OverlayRect = OverlayRect(
        left = min(left, other.left),
        top = min(top, other.top),
        right = max(right, other.right),
        bottom = max(bottom, other.bottom),
    )

    fun isInside(bounds: OverlayBounds): Boolean =
        bounds.isUsable && left >= bounds.left && top >= bounds.top &&
            right <= bounds.right && bottom <= bounds.bottom

    /** 是否相交（**半开区间**：正好贴边不算相交，这正是"窗口不压住抓取区"的判定口径）。 */
    fun overlaps(other: OverlayRect): Boolean =
        left < other.right && other.left < right && top < other.bottom && other.top < bottom

    companion object {
        /** 以 (cx, cy) 为中心、边长 size 的正方形。 */
        fun centered(cx: Int, cy: Int, size: Int): OverlayRect {
            val half = size / 2
            return OverlayRect(cx - half, cy - half, cx - half + size, cy - half + size)
        }

        /** 由四个浮点边界构造（坐标换算用）。 */
        fun of(left: Float, top: Float, right: Float, bottom: Float): OverlayRect =
            OverlayRect(left.roundToInt(), top.roundToInt(), right.roundToInt(), bottom.roundToInt())
    }
}

/**
 * 菜单**窗口级**状态（Phase 4C-3B 引入，4C-6B-1 沿用）。
 *
 * 与轮盘内部的交互阶段（`WheelMenuPhase`）分工明确：
 * * 这里管的是"**有没有一个额外的菜单窗口存在**"（窗口几何：展开一次、关闭一次）；
 * * 轮盘内部管的是"画什么、动画到哪一帧"（每帧重绘）。
 *
 * ```
 * closed --requestOpen--> opening --animationFinished--> open
 *    ^                       |                             |
 *    |                       +--requestClose--> closing <--+
 *    +--animationFinished <--+
 * forceClose（隐藏/停止/权限撤销/配置变化）：任何状态 → closed（立即，不等动画）
 * ```
 */
internal enum class OverlayMenuState {
    closed,
    opening,
    open,
    closing;

    val occupiesWindow: Boolean get() = this != closed
}

/** 菜单状态机事件。 */
internal enum class OverlayMenuEvent {
    requestOpen,
    requestClose,

    /** 桌宠被单击：开着就关、关着就开。 */
    requestToggle,

    /** 开/关动画正常结束。 */
    animationFinished,

    /** 动画被取消（新手势、新请求等）：必须收敛到确定状态。 */
    animationCancelled,

    /** 立即关闭，不等动画（隐藏 / 停止 / 权限撤销 / 配置变化 / 素材或大小变化）。 */
    forceClose,
}

/**
 * 菜单窗口级状态机（**纯函数**，可 JVM 单测）。
 *
 * 两条硬规则：
 * 1. **幂等**：`closed + requestClose` 仍是 `closed`，重复关闭不报错；
 * 2. **收敛**：动画被取消时一定落到 `open` 或 `closed`，绝不卡在中间态。
 */
internal object OverlayMenuStateMachine {

    /** 该事件是否要求"立即生效、不播动画"。 */
    fun isImmediate(event: OverlayMenuEvent): Boolean = event == OverlayMenuEvent.forceClose

    fun next(current: OverlayMenuState, event: OverlayMenuEvent): OverlayMenuState = when (event) {
        OverlayMenuEvent.forceClose -> OverlayMenuState.closed

        OverlayMenuEvent.requestOpen -> when (current) {
            OverlayMenuState.closed, OverlayMenuState.closing -> OverlayMenuState.opening
            // 已经在打开 / 已经打开：不重复触发（防止多套动画、多个菜单）
            OverlayMenuState.opening, OverlayMenuState.open -> current
        }

        OverlayMenuEvent.requestClose -> when (current) {
            OverlayMenuState.closed -> OverlayMenuState.closed
            OverlayMenuState.opening, OverlayMenuState.open, OverlayMenuState.closing ->
                OverlayMenuState.closing
        }

        OverlayMenuEvent.requestToggle -> when (current) {
            OverlayMenuState.closed -> OverlayMenuState.opening
            OverlayMenuState.opening, OverlayMenuState.open -> OverlayMenuState.closing
            OverlayMenuState.closing -> OverlayMenuState.opening
        }

        OverlayMenuEvent.animationFinished, OverlayMenuEvent.animationCancelled -> when (current) {
            OverlayMenuState.opening -> OverlayMenuState.open
            OverlayMenuState.closing -> OverlayMenuState.closed
            OverlayMenuState.closed, OverlayMenuState.open -> current
        }
    }
}

/**
 * 桌宠视觉**不变式**（Phase 4C-6B-1.2 A3）。
 *
 * 旧架构允许"菜单窗口接管人物 + 隐藏原桌宠 + 前景首帧回调切换所有权"，
 * 两次真机都出现"打开菜单后桌宠消失"。该机制现已**彻底删除**：
 * `PetOverlayView` 不再有任何可隐藏内容的入口，菜单窗口也绝不持有桌宠 Drawable。
 *
 * 把结论收成常量，一是给设置页诊断一个**恒定输出**，二是让"所有菜单生命周期路径下
 * sourceHidden 永远为 false"这条不变式可以被 JVM 单测直接打靶。
 */
internal object PetVisualInvariant {
    /** 视觉拥有者恒为原桌宠窗口。 */
    const val OWNER = "PET_WINDOW"

    /** 桌宠内容永不隐藏（恒 0）。 */
    const val SOURCE_HIDDEN = 0

    /** 菜单窗口永不复制/绘制桌宠（恒 disabled）。 */
    const val FOREGROUND_COPY = "disabled"

    /** 诊断片段：与菜单状态、层级、生命周期路径**无关**的固定值。 */
    fun diagnosticSegment(): String =
        " owner=$OWNER sourceHidden=$SOURCE_HIDDEN foregroundCopy=$FOREGROUND_COPY"
}

/**
 * 菜单窗口更新的**前置条件**。
 *
 * 关键：`disposed`（服务实例/窗口已失效）与 `attachedToWindow`（View 已脱离）任一为假，
 * 都**不允许**再去动 WindowManager —— 否则会出现"旧实例的动画回调改新实例的窗口"。
 * 抽成纯函数是为了让这条不变式可以被单元测试直接打靶。
 */
internal fun canUpdateMenuWindow(disposed: Boolean, attachedToWindow: Boolean): Boolean =
    !disposed && attachedToWindow

/**
 * 菜单**交互会话**（真机缺陷 1 修复）："菜单当前是否允许交互"的**唯一**权威。
 *
 * 缺陷 1 的根因是"没有单一真值"：关闭后仍可能被旧的动画回调 / 旧的触摸流 / 旧的转发拖动
 * 回调重新点亮按钮或改回几何，而窗口（= 输入区）还停在大矩形上。这里把两件事收进一个对象：
 *
 * 1. [sessionId]：**每次打开**都 +1。所有动画回调、触摸处理、延迟任务、挂起的摘层
 *    都带上它；带旧 id 的回调一律忽略 —— 关掉再立刻重开时，旧会话的回调绝不可能扰动新会话。
 * 2. [interactive]：关闭请求**被接受的那一刻**（同一帧）就置 false，不等动画、不等手势结束。
 *
 * 纯逻辑、无 `android.*` 依赖，因此可以被 JVM 单测逐条打靶。
 */
internal class MenuInteractionSession {

    /** 当前会话号；0 表示"还没有开过菜单"。 */
    var sessionId: Long = 0L
        private set

    /** 是否允许菜单交互（触摸 / 确认 / 动作派发）。 */
    var interactive: Boolean = false
        private set

    /** 开始一次新的打开：推进会话号并允许交互。返回本次会话号。 */
    fun beginOpen(): Long {
        sessionId += 1
        interactive = true
        return sessionId
    }

    /** 改变交互开关；返回**是否真的发生变化**（供调用方决定要不要下发到 View / 记日志）。 */
    fun setInteractive(value: Boolean): Boolean {
        if (interactive == value) return false
        interactive = value
        return true
    }

    /** 关闭被接受：同一帧内立即停止交互。返回是否发生变化。 */
    fun acceptClose(): Boolean = setInteractive(false)

    /** 会话整体作废（detach / 几何变化 / 服务停止）：连会话号一起推进，旧回调全部失效。 */
    fun invalidate() {
        sessionId += 1
        interactive = false
    }

    /** 带会话号的回调是否仍属于当前会话。 */
    fun isCurrent(session: Long): Boolean = session == sessionId

    /** 触摸门控：是否允许进入菜单手势（环带滑选 / 按压 / 空白关闭）。 */
    fun touchAllowed(): Boolean = interactive

    /**
     * **动作派发前的第二道校验**：必须同时满足"会话未过期 + 允许交互 + 菜单确实处于打开态"。
     *
     * 第一道在触摸入口（[touchAllowed]），第二道在这里 —— 只有两道都过才允许执行菜单动作，
     * 这样"关闭后手指才抬起"的陈旧 UP 不可能触发任何按钮。
     */
    fun canDispatchAction(session: Long, menuOpen: Boolean): Boolean =
        interactive && menuOpen && session == sessionId
}

/**
 * 菜单回调策略（纯函数，可 JVM 单测）。
 *
 * 缺陷 1 要求："关闭后陈旧的动画结束回调不得恢复交互或几何"。收起动画结束本来就只是
 * 把 `closing` 收敛到 `closed`；一旦菜单**已经**是 `closed`，任何动画结束回调都必须被忽略，
 * 绝不能再走一遍状态迁移（那可能把窗口/交互改回去）。
 */
internal object MenuCallbackPolicy {

    /** 动画结束回调是否仍应生效：会话必须是当前会话，且菜单尚未收敛到 closed。 */
    fun shouldApplyAnimationFinished(
        session: Long,
        currentSession: Long,
        state: OverlayMenuState,
    ): Boolean = session == currentSession && state != OverlayMenuState.closed
}

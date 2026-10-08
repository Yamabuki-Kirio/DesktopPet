package asia.akechi.petlife.overlay

/** 轮盘的交互阶段（**唯一权威**，不用多个松散布尔量表达"正在开/在切换/在返回"）。 */
internal enum class WheelMenuPhase {
    closed,
    opening,
    open,
    /** 根选项切换（沿弧线滑动）。 */
    switching,
    /** 进入子菜单。 */
    enteringLayer,
    /** 返回上一层。 */
    exitingLayer,
    closing;

    val occupiesWindow: Boolean get() = this != closed

    /** 是否正处于"动画进行中"（此时新的进入类请求要被排队或忽略）。 */
    val animating: Boolean
        get() = this == opening || this == switching || this == enteringLayer ||
            this == exitingLayer || this == closing
}

/**
 * 轮盘状态机（**纯逻辑**，可 JVM 单测）。
 *
 * 三件必须由它独占的事：
 * 1. **菜单栈**（需求 §5）—— 进入/返回/关闭都只走这里；
 * 2. **当前层级与选中项** —— 界面与渲染都只读它，不再各自维护一份索引；
 * 3. **展开方向** —— 打开时决定一次，**打开期间锁定**（需求 §9 第一版建议）。
 *
 * 非法请求（重复打开、根菜单返回、不存在的层级）一律**幂等拒绝**，
 * 绝不产生非法路径 —— "快速连续操作跳到错误层级"就是靠这条防住的。
 */
internal class WheelMenuStateMachine {

    private val stack = WheelMenuStack()

    var phase: WheelMenuPhase = WheelMenuPhase.closed
        private set

    var direction: WheelExpandDirection = WheelExpandDirection.right
        private set

    /** 已确认的选中项（根菜单 = 0..5）。 */
    var selectedIndex: Int = 0
        private set

    /** 手指滑选中的临时高亮（null = 没有临时项，用 [selectedIndex]）。 */
    var previewIndex: Int? = null
        private set

    val levelId: String? get() = stack.currentId

    val currentLevel: WheelMenuLevel? get() = stack.current

    val itemCount: Int get() = currentLevel?.itemCount ?: 0

    val isOpen: Boolean get() = phase.occupiesWindow

    /** 当前高亮项 = 滑选中的临时项优先。 */
    val activeIndex: Int get() = (previewIndex ?: selectedIndex).coerceIn(0, maxOf(0, itemCount - 1))

    /** 是否能返回（根菜单不能）。 */
    val canGoBack: Boolean get() = stack.depth > 1

    val depth: Int get() = stack.depth

    fun path(): List<String> = stack.path()

    val activeEntry: WheelMenuEntry? get() = currentLevel?.entries?.getOrNull(activeIndex)

    val selectedEntry: WheelMenuEntry? get() = currentLevel?.entries?.getOrNull(selectedIndex)

    /**
     * 打开菜单：只在 `closed` / `closing` 生效（幂等）。
     *
     * [direction] 由几何层算出并在此**锁定**，打开期间不再改变。
     */
    fun open(direction: WheelExpandDirection): Boolean {
        if (phase != WheelMenuPhase.closed && phase != WheelMenuPhase.closing) return false
        this.direction = direction
        stack.clear()
        stack.open()
        selectedIndex = 0
        previewIndex = null
        phase = WheelMenuPhase.opening
        return true
    }

    /** 关闭：任何阶段都收敛到 `closed`（幂等）。 */
    fun close(): Boolean {
        if (phase == WheelMenuPhase.closed) return false
        stack.clear()
        previewIndex = null
        selectedIndex = 0
        phase = WheelMenuPhase.closed
        return true
    }

    /** 展开动画结束 → `open`。 */
    fun markOpened() {
        if (phase == WheelMenuPhase.opening) phase = WheelMenuPhase.open
    }

    /** 收起动画结束（幂等）。 */
    fun markClosed() {
        phase = WheelMenuPhase.closed
    }

    /** 根选项切换开始；目标索引非法或本来就选中则拒绝。 */
    fun beginSwitch(index: Int): Boolean {
        if (phase != WheelMenuPhase.open) return false
        if (index !in 0 until itemCount) return false
        if (index == selectedIndex) return false
        phase = WheelMenuPhase.switching
        return true
    }

    /** 根选项切换结束：落到确定状态。 */
    fun finishSwitch(index: Int) {
        if (index in 0 until itemCount) selectedIndex = index
        if (phase == WheelMenuPhase.switching) phase = WheelMenuPhase.open
    }

    /** 进入子菜单（层级立即切换，动画只负责过渡）。 */
    fun enterLayer(targetLevelId: String): Boolean {
        if (phase != WheelMenuPhase.open && phase != WheelMenuPhase.switching) return false
        if (!stack.push(targetLevelId)) return false
        selectedIndex = 0
        previewIndex = null
        phase = WheelMenuPhase.enteringLayer
        return true
    }

    /** 返回上一层；在根菜单返回 `false`（**不关闭菜单**）。 */
    fun exitLayer(): Boolean {
        if (phase != WheelMenuPhase.open && phase != WheelMenuPhase.switching) return false
        if (!stack.pop()) return false
        selectedIndex = 0
        previewIndex = null
        phase = WheelMenuPhase.exitingLayer
        return true
    }

    /** 换层动画结束（进入 / 返回共用）。 */
    fun finishLayerTransition() {
        if (phase == WheelMenuPhase.enteringLayer || phase == WheelMenuPhase.exitingLayer) {
            phase = WheelMenuPhase.open
        }
    }

    /** 收起动画开始。 */
    fun beginClosing() {
        if (phase != WheelMenuPhase.closed) phase = WheelMenuPhase.closing
    }

    /** 滑选：设置临时高亮（越界一律夹到合法范围；`null` = 取消区）。 */
    fun setPreview(index: Int?) {
        previewIndex = index?.coerceIn(0, maxOf(0, itemCount - 1))
    }

    /**
     * 松手确认：把临时高亮变成已确认项，返回**被选中的条目**。
     *
     * 没有临时高亮时返回当前已确认项（"点一下按钮"这条路径）。
     */
    fun confirmSelection(): WheelMenuEntry? {
        val index = previewIndex
        if (index != null && index in 0 until itemCount) {
            selectedIndex = index
        }
        previewIndex = null
        return selectedEntry
    }

    /** 动画被外力打断：收敛到确定状态（绝不卡在中间态）。 */
    fun settleAfterInterruption() {
        phase = when (phase) {
            WheelMenuPhase.opening -> WheelMenuPhase.open
            WheelMenuPhase.switching,
            WheelMenuPhase.enteringLayer,
            WheelMenuPhase.exitingLayer,
            -> WheelMenuPhase.open
            WheelMenuPhase.closing -> WheelMenuPhase.closed
            WheelMenuPhase.closed, WheelMenuPhase.open -> phase
        }
        previewIndex = null
    }
}

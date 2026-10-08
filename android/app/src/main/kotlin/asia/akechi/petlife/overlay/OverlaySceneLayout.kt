package asia.akechi.petlife.overlay

/**
 * 单窗口"场景"布局。
 *
 * 背景：桌宠与轮盘菜单合并在**同一个透明窗口**里：根容器 = `PetOverlayView`，
 * 容器内 `index 0 = 菜单层`、`index 1 = 反馈层`、`index 2 = 人物层`，人物天然画在菜单**之上**。
 *
 * 本类只做一件事：给定人物与菜单的**屏幕**矩形与菜单开关态，求解窗口矩形与两层在容器内的位置。
 * 纯 Kotlin、无任何 `android.*` 依赖，因此可以被 JVM 单测逐条打靶。
 */
internal data class OverlaySceneLayout(
    /** 根窗口的屏幕矩形。 */
    val windowRect: OverlayRect,
    /** 人物层在根容器内的位置（尺寸 = 人物尺寸）。 */
    val petRectInWindow: OverlayRect,
    /** 菜单层在根容器内的位置；菜单关闭时为 null。 */
    val menuRectInWindow: OverlayRect?,
    /** 人物屏幕矩形。不变式：菜单开关前后**完全相等**。 */
    val petScreenRect: OverlayRect,
    val menuOpen: Boolean,
) {
    /**
     * 自检：两层都落在窗口内、尺寸与屏幕矩形一致、窗口原点 + 层内偏移 == 屏幕矩形。
     *
     * 这是"菜单开关不改变人物屏幕位置"这条不变式的可执行形式（单测直接打靶）。
     */
    fun assertConsistent(): Boolean {
        if (!windowRect.isUsable) return false
        if (petRectInWindow.width != petScreenRect.width) return false
        if (petRectInWindow.height != petScreenRect.height) return false
        if (windowRect.left + petRectInWindow.left != petScreenRect.left) return false
        if (windowRect.top + petRectInWindow.top != petScreenRect.top) return false
        if (!insideWindow(petRectInWindow)) return false
        val menu = menuRectInWindow
        if (menuOpen != (menu != null)) return false
        return menu == null || insideWindow(menu)
    }

    private fun insideWindow(rect: OverlayRect): Boolean =
        rect.left >= 0 && rect.top >= 0 &&
            rect.left + rect.width <= windowRect.width &&
            rect.top + rect.height <= windowRect.height
}

/**
 * 场景求解器（**纯函数**，唯一权威）。
 *
 * 唯一的硬不变式（菜单开关前后都成立）：
 * ```
 * windowRect.origin + petRectInWindow.origin == petScreenRect.origin
 * ```
 *
 * 两种状态：
 * * **菜单关闭** → 窗口矩形 == 人物屏幕矩形（**零透明 padding**），人物层容器内偏移 = (0,0)；
 * * **菜单打开** → 窗口矩形 == 人物 ∪ 菜单信封，人物层容器内偏移 = 人物屏幕矩形 − 窗口原点。
 *
 * 【为什么关菜单必须把窗口缩回人物矩形】
 * 平台**没有**任何公开 API 能声明"窗口内只有某一块子区域可触摸"：
 * `ViewTreeObserver.OnComputeInternalInsetsListener` / `ViewTreeObserver.InternalInsetsInfo`
 * 属 AOSP `@hide`，已核实本项目 `android.jar`（compileSdk 35 / 36 / 37）中**根本不存在**；
 * 反射 / 隐藏 API 被项目规则明确禁止。因此无法让一个"大窗口"只在人物处可点。
 *
 * 更关键的是：**大窗口内部的透明 padding 仍然会消费触摸**。
 * `FLAG_NOT_TOUCH_MODAL` 只让事件**落在窗口之外**时才交给下层窗口；
 * 而 `PetOverlayView.onTouchEvent` 返回 `false` **不会**把事件重新派发给下层窗口
 * —— 返回 false 只表示"本 View 不消费这一串事件"，窗口依旧把该点拦下。
 * 所以"窗口比人物大"就等于在人物周围留下一圈**永久触摸遮挡**，这是不可接受的。
 *
 * 结论：菜单关闭时**窗口本身**必须收缩回人物矩形（见 [closed] / [petOnly]）；
 * 只有菜单打开时才把窗口扩成并集（见 [open]）。
 */
internal object OverlaySceneSolver {

    /**
     * 打开态：窗口 = 人物 ∪ 菜单信封。
     *
     * 人物层反向平移同样的量，保证 `窗口原点 + 人物层偏移 == 人物屏幕矩形`（人物不抽动）。
     */
    fun open(petScreenRect: OverlayRect, menuScreenRect: OverlayRect): OverlaySceneLayout {
        val windowRect = petScreenRect.union(menuScreenRect)
        return OverlaySceneLayout(
            windowRect = windowRect,
            // 尺寸不变，只平移（`translate` 保宽高）。
            petRectInWindow = petScreenRect.translate(-windowRect.left, -windowRect.top),
            menuRectInWindow = menuScreenRect.translate(-windowRect.left, -windowRect.top),
            petScreenRect = petScreenRect,
            menuOpen = true,
        )
    }

    /**
     * 关闭态：窗口 == 人物屏幕矩形（**零透明 padding**）。
     *
     * 这是唯一被平台允许的做法：无法声明"局部可触摸区域"，因此窗口本身不能比交互区更大。
     * 关菜单改变窗口几何是**故意**的、必需的，不是可选的优化。
     */
    fun closed(petScreenRect: OverlayRect): OverlaySceneLayout = petOnly(petScreenRect)

    /**
     * 兜底 / 关态同构：窗口 == 人物矩形，没有任何透明 padding。
     *
     * 也用于"没有可用菜单信封（可用区域不可信 / 几何求解失败）"时。
     */
    fun petOnly(petScreenRect: OverlayRect): OverlaySceneLayout = OverlaySceneLayout(
        windowRect = petScreenRect,
        petRectInWindow = OverlayRect(0, 0, petScreenRect.width, petScreenRect.height),
        menuRectInWindow = null,
        petScreenRect = petScreenRect,
        menuOpen = false,
    )

    /**
     * 只改变"人物屏幕位置"（窗口尺寸 / 人物层在容器内的偏移 / 菜单层矩形**都保持不变**）。
     *
     * 用于拖动每一帧：窗口原点与人物层偏移**一起**平移同样的量，因此
     * `windowRect.origin + petRectInWindow.origin == petScreenRect.origin` 恒成立，
     * 不会出现"窗口已到新原点、人物偏移还是旧值"的半帧错位。
     *
     * @param petScreenRect 手指解算出的**新**人物屏幕矩形
     * @param petRectInWindow 当前人物层在容器内的偏移（拖动期间不变）
     * @param windowSize 当前窗口尺寸（拖动期间不变）
     */
    fun moved(
        petScreenRect: OverlayRect,
        petRectInWindow: OverlayRect,
        windowSize: OverlaySize,
        menuRectInWindow: OverlayRect?,
        menuOpen: Boolean,
    ): OverlaySceneLayout {
        val originLeft = petScreenRect.left - petRectInWindow.left
        val originTop = petScreenRect.top - petRectInWindow.top
        return OverlaySceneLayout(
            windowRect = OverlayRect(
                left = originLeft,
                top = originTop,
                right = originLeft + windowSize.width,
                bottom = originTop + windowSize.height,
            ),
            petRectInWindow = petRectInWindow,
            menuRectInWindow = menuRectInWindow,
            petScreenRect = petScreenRect,
            menuOpen = menuOpen,
        )
    }
}

/**
 * **几何纪元**数据 + 窗口提交计数（纯 JVM 可单测）。
 *
 * 纪元内保存一对真实几何输入：**人物屏幕矩形** + **菜单信封屏幕矩形**（可能为 null）。
 * * 菜单关闭 → [closedLayout] 派生"窗口 == 人物矩形"（零 padding）；
 * * 菜单打开 → [openLayout] 派生"窗口 == 人物 ∪ 菜单信封"。
 *
 * **开/关菜单确实会改变窗口几何**：这是为了避免留下一圈永久触摸遮挡（平台没有公开的
 * 局部可触摸区域 API，详见 [OverlaySceneSolver] 的说明）。因此 [commitCount] 在开与关时都会 +1
 * —— 由 manager 的唯一提交点（`commitSceneLayout`）经 [noteWindowCommitted] 统一记账。
 *
 * 无论窗口矩形怎么变，不变式恒成立：`windowRect.origin + petRectInWindow.origin == petScreenRect.origin`。
 */
internal class OverlaySceneEpoch {

    /** 本纪元的真实几何输入：人物屏幕矩形（null = 纪元尚未建立）。 */
    var petScreenRect: OverlayRect? = null
        private set

    /** 本纪元的真实几何输入：菜单信封屏幕矩形（null = 本纪元没有可用信封）。 */
    var menuScreenRect: OverlayRect? = null
        private set

    /** 窗口几何提交次数（开/关菜单、拖动、改大小、位置恢复等每次真实变化 +1）。 */
    var commitCount: Int = 0
        private set

    /** 菜单层是否已挂载（本纪元内）。 */
    var menuLayerAttached: Boolean = false
        private set

    /** 菜单层累计挂载次数（诊断 / 断言"最多一层、关闭恰好摘一次"）。 */
    var menuLayerAttachCount: Int = 0
        private set

    /** 本纪元是否有可用菜单信封（决定能不能打开菜单）。 */
    val hasMenuEnvelope: Boolean get() = menuScreenRect != null

    /** 关态场景：窗口 == 人物矩形（零 padding）；纪元没有人物矩形时为 null。 */
    fun closedLayout(): OverlaySceneLayout? = petScreenRect?.let { OverlaySceneSolver.petOnly(it) }

    /** 开态场景：窗口 == 人物 ∪ 菜单信封；缺人物矩形或信封时为 null（= 不允许打开菜单）。 */
    fun openLayout(): OverlaySceneLayout? {
        val pet = petScreenRect ?: return null
        val menu = menuScreenRect ?: return null
        return OverlaySceneSolver.open(pet, menu)
    }

    /**
     * 更新本纪元的真实几何输入（attach / 拖动落定 / applySettings / 位置恢复时调用）。
     *
     * @param menuScreenRect 菜单信封的屏幕矩形；null = 无可用信封（退化为窗口 == 人物）。
     * @return 关态场景（窗口 == 人物矩形）。调用方应交给唯一提交点提交。
     */
    fun commit(petScreenRect: OverlayRect, menuScreenRect: OverlayRect?): OverlaySceneLayout {
        this.petScreenRect = petScreenRect
        this.menuScreenRect = menuScreenRect
        return OverlaySceneSolver.petOnly(petScreenRect)
    }

    /**
     * 只更新人物屏幕矩形（拖动每一帧用）：窗口随之平移，信封保持不变。
     *
     * 用途：转发拖动（菜单仍挂载、窗口仍是并集）期间，人物位置每帧都在变；
     * 关菜单需要按**最新**人物矩形把窗口缩回去，因此这里必须同步。
     */
    fun updatePetScreenRect(petScreenRect: OverlayRect) {
        this.petScreenRect = petScreenRect
    }

    /** 唯一提交点每真正改一次窗口几何就调一次（开/关菜单也计入）。 */
    fun noteWindowCommitted() {
        commitCount += 1
    }

    /** 标记菜单层已挂载；@return true = 本次状态真的变化（幂等）。 */
    fun markMenuLayerAttached(): Boolean {
        if (menuLayerAttached) return false
        menuLayerAttached = true
        menuLayerAttachCount += 1
        return true
    }

    /** 标记菜单层已摘除；@return true = 本次真的摘下了（重复调用返回 false，绝不可能"摘两次"）。 */
    fun markMenuLayerDetached(): Boolean {
        if (!menuLayerAttached) return false
        menuLayerAttached = false
        return true
    }

    /** 丢弃整个纪元（窗口移除 / 新窗口 attach 时调用）。 */
    fun reset() {
        petScreenRect = null
        menuScreenRect = null
        commitCount = 0
        menuLayerAttached = false
        menuLayerAttachCount = 0
    }
}

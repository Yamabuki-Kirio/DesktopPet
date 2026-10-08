package asia.akechi.petlife.overlay

import android.animation.Animator
import android.animation.AnimatorListenerAdapter
import android.animation.ValueAnimator
import android.content.Context
import android.content.res.Configuration
import android.graphics.PixelFormat
import android.graphics.drawable.Drawable
import android.os.Build
import android.os.Looper
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.ViewTreeObserver
import android.view.WindowInsets
import android.view.WindowManager
import android.view.animation.DecelerateInterpolator
import java.util.Locale

/**
 * 服务向窗口层暴露的**持久化回调**。
 *
 * 为什么不让 manager 直接写 `SharedPreferences`：位置的"存"与"取"必须成对
 * 出现在同一个地方（服务），否则容易出现"窗口按 A 规则摆放、存储按 B 规则写入"
 * 这种自相矛盾的组合。manager 只负责算，服务负责存。
 */
internal interface OverlayWindowHost {

    /**
     * 手势结束后持久化位置（**只在松手/动画结束时调用一次**，绝不在 MOVE 里写盘）。
     *
     * @param xRatio 相对可用区域横向比例（0~1）
     * @param yRatio 相对可用区域纵向比例（0~1）
     * @param edge   当前吸附到的边（关闭吸附时为 [OverlaySnapEdge.none]）
     */
    fun onPersistPosition(xRatio: Float, yRatio: Float, edge: OverlaySnapEdge)

    /** 单击桌宠（4C-3A 只记日志；4C-3B 在 manager 里开关圆盘菜单）。 */
    fun onClickPet()

    /**
     * 轮盘条目动作（Phase 4C-6B-1）。
     *
     * 只传**原始值**（命令 wire / 条目 id / 说明），不传轮盘模型：
     * 服务是 public 类，不能把 internal 的菜单模型暴露到它的重写签名里。
     *
     * 4C-6B-3 起只剩**只读信息项**走这里（导航与原生动作由 manager 自己执行，
     * Dart 请求走 [onMenuDartRequest]）。
     */
    fun onMenuAction(actionWire: String, itemId: String, detail: String)

    /**
     * 轮盘选中项的**只读实时信息**（需求 §3 的"可选实时状态"）。
     *
     * 必须只读**已经缓存的**值：绝不查数据库、绝不打新的使用统计查询 ——
     * 它会在选中变化时被调用，不能有 IO。
     */
    fun onMenuInfo(itemId: String): String?

    /**
     * **原生动作**（Phase 4C-6B-3）：完全在 Kotlin 里执行，绝不绕道 Dart。
     *
     * @param actionWire [WheelMenuAction] 的稳定 wire 值（隐藏 / 重置位置 / 改大小 / 打开 PetLife）
     * @return 是否已执行
     */
    fun onMenuNativeAction(actionWire: String, itemId: String): Boolean

    /**
     * **Dart 请求**（Phase 4C-6B-3）：入队并尝试推送，返回 requestId。
     *
     * 推送失败**不报错**：请求留在队列里，等 Dart `pullPendingMenuRequests`。
     * 返回空串表示这次请求连入队都没成功（调用方据此给一句失败反馈）。
     */
    fun onMenuDartRequest(actionWire: String, itemId: String): String

    /**
     * 窗口内反馈层**无法显示**时的兜底短提示（复用既有 Toast）。
     *
     * 只有"菜单已经收起 / 应用刚启动"这类场景才会走到这里。
     */
    fun onMenuHint(text: String)

    /**
     * 原子几何提交后的**下一帧**核对结果（Phase 4C-3B 收尾修复）。
     *
     * manager 读不到服务里的静态诊断字段，因此把结果回调给服务由它发布。
     * [settled] 为 false 说明下一帧桌宠的绝对位置与提交前不一致（>1px）——
     * 那是真机上"抽动"的直接证据。
     */
    fun onGeometrySettled(tag: String, deltaX: Int, deltaY: Int, settled: Boolean)
}

/**
 * 悬浮窗的 WindowManager 生命周期 + 位置/尺寸/手势（Phase 4C-3A）。
 *
 * 单实例由这里保证：任何时刻**最多**持有一个 [PetOverlayView] 与一份
 * [WindowManager.LayoutParams]；[attach] 幂等（已挂载时只更新，不新建第二个窗口）。
 *
 * 四条硬规则（4C-3A）：
 * 1. 所有 `WindowManager` 操作都在**主线程**串行（[requireMainThread] 会告警）；
 * 2. 拖动过程只 `updateViewLayout`，**不写盘、不 removeView/addView**；
 * 3. 位置一律以**相对比例 + 可用区域**重算，绝不把绝对像素当作恢复依据；
 * 4. 窗口未附着（[View.isAttachedToWindow] 为 false）时**不执行** `updateViewLayout`。
 */
internal class PetOverlayManager(
    private val context: Context,
    private val host: OverlayWindowHost,
) : WheelMenuActionHost {

    private val windowManager: WindowManager =
        context.getSystemService(Context.WINDOW_SERVICE) as WindowManager

    private var view: PetOverlayView? = null
    private var params: WindowManager.LayoutParams? = null

    /** 当前可用区域（每次计算都重新解析，横竖屏/分屏后自动生效）。 */
    private var bounds: OverlayBounds = OverlayBounds.unknown

    /** 手势状态机：**每个窗口一个**，因此新窗口一定是干净的 IDLE。 */
    private var gesture: OverlayGestureMachine? = null

    /**
     * 拖动跟踪器（缺陷 2 修复）：**屏幕坐标 + 一次性抓取偏移**，锁定 DOWN 指针。
     *
     * 与旧实现（按下点 + 局部坐标位移增量）的区别见 [OverlayDragTracker] 的类注释。
     */
    private val dragTracker = OverlayDragTracker()

    /**
     * 转发拖动期间的菜单摘除延迟器（缺陷 2-5）：菜单打开时拖动由菜单层转发，
     * 若中途摘掉菜单层会被系统补 ACTION_CANCEL 而打断拖动，故延迟到手势结束。
     */
    private val detachDeferral = OverlayDetachDeferral()

    // --- 缺陷 3：有界拖动诊断（仅 debugOverlayMode 生效） ---
    private var activeGestureId: Int = 0
    private var dragDownX: Float = 0f
    private var dragDownY: Float = 0f
    private var dragTraceActive: Boolean = false
    private var dragTraceLines: Int = 0
    private var dragTraceBuilder: StringBuilder? = null
    private var dragSourceName: String = "none"

    private var snapAnimator: ValueAnimator? = null

    /** 进行中的贴边动画的目标（动画被打断时要按它落定，不能停在中间帧）。 */
    private var snapTargetEdge: OverlaySnapEdge = OverlaySnapEdge.none
    private var snapTargetX: Int = 0
    private var snapTargetY: Int = 0

    // --- Phase 4C-6B-2：单窗口分层（人物层在菜单层之上） ---
    //
    // 桌宠与菜单处于**同一个透明窗口**里：
    //   index 0 = 菜单层（menuHost）、index 1 = 反馈层、index 2 = 人物层（petContent）。
    // 窗口的 LayoutParams 描述的是**当前场景**：菜单关闭时 == 人物矩形（零 padding），
    // 菜单打开时 == 人物 ∪ 菜单信封。人物的屏幕矩形 = 窗口原点 + 人物层在容器内的偏移
    // （见 [petWindowRect]），开关菜单时两者反向抵消 ⇒ 人物位置不变。

    /** 菜单**窗口级**状态（唯一权威；不额外维护 menuOpen/menuOpening 之类的布尔量）。 */
    private var menuState: OverlayMenuState = OverlayMenuState.closed

    /**
     * 菜单**交互会话**（缺陷 1 的单一真值）：会话号 + 是否允许交互。
     *
     * 每个打开动作都进入新会话；所有回调 / 触摸 / 延迟任务都带会话号，旧会话一律忽略。
     * 关闭被接受的**同一帧**就置为不可交互，不等动画、不等手势结束。
     */
    private val menuSession = MenuInteractionSession()

    /**
     * 双窗口下的**菜单打开布局闸门**（缺陷：菜单打开的"第一帧"）。
     *
     * 它把"准备布局"与"起动画"拆开：只有菜单窗真实布局到目标尺寸的那一帧，
     * 才允许 显示内容 + 去 FLAG_NOT_TOUCHABLE + 起动画（且恰好一次）。
     * 纯逻辑，JVM 单测可直接打靶（见 [MenuOpenSequencer]）。
     */
    private val menuOpenSequencer = MenuOpenSequencer()

    /** 待触发的一次性 pre-draw 布局回调（陈旧会话 / 关闭 / 重开时都要摘掉，避免泄漏）。 */
    private var pendingPreDraw: ViewTreeObserver.OnPreDrawListener? = null
    private var pendingPreDrawView: View? = null

    /**
     * "转发拖动未收到终止事件"的**有界兜底**（缺陷 1）。
     *
     * 延迟摘层闸门靠手势终止事件释放；一旦终止事件因外力缺失，闸门会永久挂起
     * → 菜单看不见却继续吞触摸。超时后无条件强制释放，保证关闭一定终结。
     */
    private var deferralFallbackScheduled: Boolean = false

    /** 轮盘菜单 View（挂在**同一个窗口**的菜单层里；null = 当前没有菜单层）。 */
    private var menuView: WheelMenuView? = null

    // -----------------------------------------------------------------------
    // Phase 4C-6B-4：双窗口悬浮层（桌宠窗 + 固定菜单窗）
    //
    // 复用探测器真机验证过的行为：菜单窗**先加且只加一次**，开/关都只是 updateViewLayout；
    // 桌宠窗后加（故稳定压在菜单之上），其几何**永不**因菜单开合而改变（⇒ 不漂移）。
    // 请求双窗口但建窗失败时自动回退单窗口并记日志 —— 绝不让用户失去桌宠窗。
    // -----------------------------------------------------------------------

    /** 用户请求的运行模式（来自 [PetOverlayStore.dualWindowMode]，默认 true）。 */
    private var dualWindowRequested: Boolean = true

    /** 本窗口纪元**实际生效**的运行模式（建窗失败会回退单窗口）。 */
    private var dualWindowActive: Boolean = false

    /** 双窗口模式下的固定菜单窗（null = 单窗口模式 / 尚未建立）。 */
    private var dualMenuWindow: DualWindowMenuWindow? = null

    /** 菜单层在根容器内的矩形（容器坐标；null = 菜单层未挂载）。 */
    private var menuRectInWindow: OverlayRect? = null

    /**
     * 人物层在根容器内的偏移（= [petLocalRect] 的左上角）。
     *
     * 与 [petLocalRect] 恒等，保留它为诊断/兼容字段。菜单关闭时窗口 == 人物矩形，
     * 因此该偏移为 (0,0)；菜单打开时窗口扩成并集，该偏移给出人物在容器内的反算位置。
     */
    private var petLayerOffset: IntArray = intArrayOf(0, 0)

    /** 最近一次提交的人物像素尺寸（窗口比人物大时，反算人物屏幕矩形必须用它）。 */
    private var petSizePx: OverlaySize = OverlaySize.fallback

    /**
     * **当前窗口矩形**（屏幕坐标）——状态相关：菜单关闭时 == 人物矩形，菜单打开时 == 并集。
     *
     * 由 [commitSceneLayout] 与人物层偏移**同一次**写定，因此永远与 [petLocalRect] 一致；
     * 不存在"窗口原点已更新、人物偏移还是旧值"的那一帧（真机抽动的结构性根因）。
     */
    private var sceneFrame: OverlayRect? = null

    /** 人物层在当前窗口内的矩形；不变式：`sceneFrame.origin + petLocalRect == 人物屏幕矩形`。 */
    private var petLocalRect: OverlayRect? = null

    /**
     * **几何纪元**：保存"人物屏幕矩形 + 菜单信封"这对真实几何输入，并派生开/关两种场景。
     *
     * 菜单关闭时窗口必须收缩回**人物矩形**（零 padding），打开时才扩成 人物 ∪ 菜单信封。
     * 开/关菜单因此**确实会改变窗口几何**（平台没有公开的"局部可触摸区域"API，
     * 大窗口内的透明 padding 会永久吞掉下层应用触摸；详见 [OverlaySceneSolver]）。
     * 唯一提交点 [commitSceneLayout] 与人物层放置同一次写定，不变式恒成立：
     * `windowRect.origin + petRectInWindow.origin == petScreenRect.origin`。
     */
    private val epoch = OverlaySceneEpoch()

    /** 本纪元的菜单信封（打开菜单时直接复用，不再二次求解）。 */
    private var epochEnvelope: WheelMenuEnvelope? = null

    /**
     * 本次打开的**信封**：窗口矩形 + 轮盘中心 + 环带半径上限。
     *
     * 打开时算一次，之后根选项切换 / 层级切换都只改内部绘制（需求 §14）。
     */
    private var envelope: WheelMenuEnvelope? = null

    /** 最近一次轮盘布局（诊断用）。 */
    private var activeLayout: WheelMenuLayout? = null

    /** 当前生效的轮盘主题（打开时快照；设置页改动会即时下发）。 */
    private var menuTheme: WheelMenuTheme = WheelMenuThemes.default()

    /** 上一次展开方向（用于中央缓冲区的滞回；null = 本次运行还没开过）。 */
    private var lastDirection: WheelExpandDirection? = null

    /** 上一次垂直模式（用于阈值附近的滞回，需求 §8）。 */
    private var lastVerticalMode: WheelVerticalMode? = null

    /** 轮盘布局设置（尺寸 / 距离 / 紧凑；与主题分开，需求 §5）。 */
    private var menuSettings: WheelMenuLayoutSettings = WheelMenuLayoutSettings.DEFAULT

    /**
     * 当前素材的**视觉边界**（由服务在解码成功后测量；null = 按整张图处理）。
     *
     * 中央缺口必须按视觉边界算，否则透明留白会把缺口撑得远大于人物（需求 §3）。
     */
    private var petContentBounds: PetContentBounds? = null

    /** 服务在素材解码成功后把视觉边界交给窗口层。 */
    fun setPetContentBounds(bounds: PetContentBounds?) {
        petContentBounds = bounds
        // 视觉边界影响信封（可见锚点 / 缺口）→ 纪元帧需要重算（真实几何变化）。
        // 菜单打开时先收敛（关闭只摘菜单层、不改几何），随后统一重算一次。
        if (!isAttached) return
        if (isMenuOpen) closeMenu("pet-content-bounds", animate = false)
        refreshEpoch(petWindowRect(), "pet-content-bounds")
    }

    // --- Phase 4C-6B-1.1 真机回归：菜单打开链路的可判定诊断 ---
    //
    // 真机症状是"点击桌宠完全没有菜单"。为了不用猜，把这条链路拆成 5 个可判定状态：
    // 没收到点击 / 收到点击但没请求打开 / 请求了但 addView 失败 /
    // addView 成功但 View 未附着（被系统拒绝或被压在下面）/ 菜单存在但几何不可见。

    private var petTapReceived: Boolean = false
    private var menuOpenRequested: Boolean = false
    private var menuAddViewAttempted: Boolean = false
    private var menuAddViewSucceeded: Boolean = false
    private var lastMenuOpenError: String? = null

    /** 一行式可判定诊断（写进日志与运行时状态，设置页直接显示）。 */
    fun menuOpenDiagnostics(): String {
        // 发布前先兜底保证桌宠可见（视觉规则已固定为"桌宠窗口自绘"）。
        enforcePetAlwaysVisible("diagnostics")
        // 诊断口径：菜单层报告**屏幕矩形**（窗口原点 + 容器内偏移），与旧双窗口时期可比。
        val bounds = menuScreenRect()?.let { "(${it.left},${it.top} ${it.width}x${it.height})" }
            ?: "none"
        val visibility = menuView?.let {
            when {
                it.visibility == View.VISIBLE -> "VISIBLE"
                it.visibility == View.INVISIBLE -> "INVISIBLE"
                else -> "GONE"
            }
        } ?: "none"
        val intrinsic = activeLayout?.let {
            "${(it.rimOuterPx * 2).toInt()}x${(it.bladeLengthPx * 2).toInt()}"
        } ?: "none"
        return "tap=${if (petTapReceived) 1 else 0}" +
            " req=${if (menuOpenRequested) 1 else 0}" +
            " addAttempt=${if (menuAddViewAttempted) 1 else 0}" +
            " addOk=${if (menuAddViewSucceeded) 1 else 0}" +
            " attached=${if (view?.isMenuLayerAttached == true) 1 else 0}" +
            " vis=$visibility" +
            " bounds=$bounds" +
            // 单窗口：只有一个（桌宠）窗口类型。
            " type=${OverlayWindowSpec.petWindowType(Build.VERSION.SDK_INT)}" +
            " err=${lastMenuOpenError ?: "<none>"}" +
            " | intrinsic=$intrinsic" +
            " placed=${activeLayout?.windowRect ?: "none"}" +
            " wheelScale=${menuSettings.preferredScale}" +
            " buttonScale=${menuSettings.buttonVisualScale}" +
            " dir=${activeLayout?.direction?.name ?: "none"}" +
            // 【A3】三项恒定：隐藏机制已彻底删除，视觉所有权不可切换。
            PetVisualInvariant.diagnosticSegment()
    }

    /** 菜单打开**之前**桌宠窗口的矩形（只用于下一帧核对"桌宠绝对没动"）。 */
    private var petRectBeforeMenu: OverlayRect? = null

    /** 已经 detach：动画回调不得再操作 WindowManager。 */
    private var disposed: Boolean = false

    /** 轮盘尺寸参数（px，按密度换算，attach/applySettings 时刷新）。 */
    private var wheelSpec: WheelMenuSpec = WheelMenuSpec.fromDensity(1f)

    /** 统一动作分发（需求 §17）：导航真实生效，业务项只发结构化占位事件。 */
    private val actions: WheelMenuActionDispatcher by lazy { WheelMenuActionDispatcher(this) }

    /** 缓存的设置（拖动/吸附路径需要，避免每次回读 SharedPreferences）。 */
    private var snapEnabled: Boolean = true
    private var debugMode: Boolean = false

    /** 轮盘触觉反馈开关（同样缓存，避免每次开菜单回读）。 */
    private var menuHapticsEnabled: Boolean = true

    /** 按钮视觉缩放（独立于轮盘缩放，需求 §4.3）。 */
    private var menuButtonScale: Float = WheelMenuLayoutSettings.DEFAULT_BUTTON_SCALE

    /** 触摸穿透开启时窗口收不到事件，这里再兜一层。 */
    private var touchThrough: Boolean = false

    /** 最近一次 addView / updateViewLayout 的失败原因（诊断用）。 */
    var lastWindowError: String? = null
        private set

    /** 最近一次 addView / updateViewLayout 的结果（诊断用，成功也要留痕）。 */
    var lastWindowAction: String = "none"
        private set

    val isAttached: Boolean get() = view != null

    /** 窗口当前是否可见（我们从不主动把根 View 设为 GONE，这里如实反映）。 */
    val isVisible: Boolean get() = view?.visibility == View.VISIBLE

    /** 根 View 是否已附着到窗口（`addView` 真正生效的判据）。 */
    val isAttachedToWindow: Boolean get() = view?.isAttachedToWindow == true

    /** 当前手势状态名（诊断）。 */
    val gestureStateName: String get() = gesture?.state?.name ?: OverlayGestureState.IDLE.name

    /** 当前菜单状态名（诊断）。 */
    val menuStateName: String get() = menuState.name

    /** 菜单是否占着扩展窗口（此时必须接收"外部点击关闭"）。 */
    val isMenuOpen: Boolean get() = menuState.occupiesWindow

    /** 当前菜单条目数量（诊断）。 */
    val menuButtonCount: Int get() = activeLayout?.itemCount ?: 0

    /** 菜单窗口是否已经挂在 WindowManager 上（诊断）。 */
    val isMenuWindowAttached: Boolean get() = menuView != null

    /** 当前菜单交互会话号（诊断 / 单测口径）：每次打开 +1。 */
    val menuSessionId: Long get() = menuSession.sessionId

    /** 菜单当前是否允许交互（缺陷 1 的单一真值，诊断用）。 */
    val isMenuInteractive: Boolean get() = menuSession.interactive

    /**
     * 门控菜单交互（**唯一入口**）：会话对象是权威，View 只是执行者。
     *
     * 关闭被接受的同一帧就调用它置 false —— 之后任何触摸 / 确认 / 动作派发都会被拒。
     */
    private fun setMenuInteractive(interactive: Boolean, reason: String) {
        if (!menuSession.setInteractive(interactive)) return
        // 关闭 / 几何变化 / 失败：本次打开的"待布局回调"必须立即作废（旧会话回调一律惰性）。
        if (!interactive) invalidatePendingMenuOpen()
        menuView?.setInteractive(interactive, reason)
        OverlayLog.log(
            "menu.interactive=$interactive reason=$reason session=${menuSession.sessionId} " +
                "state=${menuState.name}",
        )
    }

    /**
     * 作废"本次打开的待布局回调"：摘掉一次性 pre-draw 监听并让闸门收敛到 cancelled。
     *
     * 调用点：关闭被接受、几何变化、detach、新窗口建立、打开失败 —— 保证旧会话的
     * 布局回调**绝不**再显示内容 / 清 FLAG_NOT_TOUCHABLE / 启动新菜单的动画。
     */
    private fun invalidatePendingMenuOpen() {
        removePendingPreDraw()
        menuOpenSequencer.invalidate()
    }

    private fun removePendingPreDraw() {
        val listener = pendingPreDraw ?: return
        val v = pendingPreDrawView
        pendingPreDraw = null
        pendingPreDrawView = null
        runCatching { v?.viewTreeObserver?.removeOnPreDrawListener(listener) }
    }

    /**
     * 事件型（每次开 / 关各一条）的输入区诊断：**只报告真实、可取得的值**。
     *
     * 口径（本轮修复后）：菜单关闭时窗口 == 人物矩形（零 padding），打开时 == 人物 ∪ 菜单信封。
     * 因此"窗口矩形 == 人物矩形"本身就等价于"本窗口不会遮挡人物之外的区域"。
     * 这里**绝不臆造平台状态**——不写"某区域是否可触摸 / 是否穿透"这类单测与诊断都拿不到的事实，
     * 只并列菜单状态、会话、交互开关、两层挂载、窗口矩形、人物屏幕矩形与窗口提交计数。
     */
    fun menuInputDiagnostics(): String {
        val p = params
        val windowRect = p?.let { OverlayRect(it.x, it.y, it.x + it.width, it.y + it.height) }
        val petRect = if (isAttached) petWindowRect() else null
        val petLayerViewRect = if (isAttached) view?.petLayerBoundsInWindow() else null
        val menuLayerAttached = view?.isMenuLayerAttached == true
        return "menuDiag session=${menuSession.sessionId}" +
            " state=${menuState.name}" +
            " menuOpen=${menuState.occupiesWindow}" +
            " menuInteractive=${menuSession.interactive}" +
            " layerAttached=$menuLayerAttached" +
            " epochLayerAttached=${epoch.menuLayerAttached}" +
            " viewAttached=$isAttachedToWindow" +
            " windowRect=${windowRect ?: "none"}" +
            " petScreenRect=${petRect ?: "none"}" +
            " petLocalRect=${petLayerViewRect ?: "none"}" +
            " commit=${epoch.commitCount}" +
            " forwarding=${menuView?.petDragForwardingNow ?: false}" +
            " deferralActive=${detachDeferral.isForwardedDragActive}" +
            " deferralPending=${detachDeferral.hasPending}"
    }

    /** 轮盘当前层级（诊断）。 */
    val menuLevelName: String get() = menuView?.levelIdName ?: "none"

    /** 轮盘当前选中槽位（诊断）。 */
    val menuActiveIndex: Int get() = menuView?.activeIndexNow ?: 0

    /** 轮盘当前动画（诊断）。 */
    val menuAnimationName: String get() = menuView?.animationName ?: "idle"

    /** 轮盘手势归属（诊断）。 */
    val menuGestureOwnerName: String get() = menuView?.gestureOwnerName ?: "none"

    /** 最近一次动作路由（诊断）。 */
    val lastMenuActionWire: String? get() = actions.lastActionWire

    /** 最近一次动作是否需要 **Dart 参与**（诊断：`lastMenuActionPlaceholder`）。 */
    val lastMenuActionIsPlaceholder: Boolean get() = actions.lastRoute == WheelActionRoute.dartRequest

    /** 性能指标（需求 §15 的调试指标）。 */
    fun menuPerformanceSummary(): String {
        val stats = menuView?.frameStatsSnapshot() ?: return "wheel perf=<none>"
        return String.format(
            Locale.US,
            "wheel perf frames=%d avg=%.1fms max=%.1fms dropped=%d",
            stats.frames,
            stats.averageMs,
            stats.maxMs,
            stats.dropped,
        )
    }

    /** 最近一次轮盘几何的一句话摘要（诊断）。 */
    fun menuSummary(): String {
        val current = activeLayout ?: return "wheel=<none>"
        val env = envelope
        return "wheel dir=${current.direction.labelZh} level=${menuLevelName} " +
            "items=${current.itemCount} active=${menuActiveIndex} " +
            "radius=${current.ringRadiusPx.toInt()} step=${current.stepDeg.toInt()} " +
            "blade=${current.bladeLengthPx.toInt()} degraded=${current.degraded} " +
            "window=${env?.windowRect ?: "none"} anim=$menuAnimationName gesture=$menuGestureOwnerName"
    }

    fun viewSize(): IntArray {
        val v = view ?: return intArrayOf(0, 0)
        return intArrayOf(v.width, v.height)
    }

    fun imageViewSize(): IntArray = view?.imageViewSize() ?: intArrayOf(0, 0)

    /**
     * 桌宠的**绝对**屏幕矩形（拖拽/落盘/吸附、[WheelMenuGeometry.computeEnvelope] 的权威）。
     *
     * 用"窗口原点 + 人物层在窗口内的偏移（[petLocalRect]）"反算，尺寸取 [petLocalRect]
     * （恒等于最近一次提交的人物尺寸）。
     *
     * 不变式：菜单开/关前后本函数返回值**完全相等** —— 因为窗口矩形的变化总是与
     * [petLocalRect] 的反向变化由 [commitSceneLayout] **同一次**写定。
     */
    private fun petWindowRect(): OverlayRect {
        val p = params ?: return OverlayRect(0, 0, 0, 0)
        val local = petLocalRect
        if (local != null) {
            return OverlayRect(
                left = p.x + local.left,
                top = p.y + local.top,
                right = p.x + local.left + local.width,
                bottom = p.y + local.top + local.height,
            )
        }
        // 兜底（理论不可达）：窗口还没建立时按"窗口原点 + 偏移 + 提交尺寸"。
        val offsetX = petLayerOffset[0]
        val offsetY = petLayerOffset[1]
        return OverlayRect(
            left = p.x + offsetX,
            top = p.y + offsetY,
            right = p.x + offsetX + petSizePx.width,
            bottom = p.y + offsetY + petSizePx.height,
        )
    }

    /** 人物层在容器内的偏移 X（= 窗口原点 → 人物屏幕左上角）。 */
    private fun petLocalX(): Int = petLocalRect?.left ?: petLayerOffset[0]

    /** 人物层在容器内的偏移 Y。 */
    private fun petLocalY(): Int = petLocalRect?.top ?: petLayerOffset[1]

    /**
     * **唯一**会改窗口几何的提交点（原子）：人物层在容器内的放置与窗口 LayoutParams
     * 在同一次主线程操作里改完，随后只触发**一次** `requestLayout()` + **一次**
     * `updateViewLayout(...)` —— 中间不存在"窗口原点已变、人物偏移未变"（或反之）的半帧。
     *
     * 顺序：
     * 1. 先应用人物层放置（只写内存参数，不触发遍历）；
     * 2. 再写窗口 LayoutParams；
     * 3. 最后一次性 `requestLayout()` + `updateViewLayout`。
     *
     * attach 的位置恢复 / [applySettings] / 拖动 / **菜单开合**（关态 = 人物矩形、开态 = 并集）
     * **全部**经过这里，[OverlaySceneSolver] 是几何的唯一权威。
     * 每次真正改变几何都经 [OverlaySceneEpoch.noteWindowCommitted] 记账（开/关菜单也计入）。
     */
    private fun commitSceneLayout(layout: OverlaySceneLayout, tag: String) {
        requireMainThread("commitSceneLayout")
        val currentView = view ?: return
        val p = params ?: return
        val window = layout.windowRect
        val safeWidth = window.width.coerceAtLeast(1)
        val safeHeight = window.height.coerceAtLeast(1)
        val changed = p.x != window.left || p.y != window.top ||
            p.width != safeWidth || p.height != safeHeight ||
            petLocalRect != layout.petRectInWindow
        if (!changed) return
        epoch.noteWindowCommitted()
        // 1) 人物层在容器内的放置（只改内存参数，不触发遍历）。
        currentView.prepareSceneGeometry(OverlaySize(safeWidth, safeHeight), layout.petRectInWindow)
        // 2) 窗口 LayoutParams（与人物层放置同一主线程块，随后一次提交）。
        p.x = window.left
        p.y = window.top
        p.width = safeWidth
        p.height = safeHeight
        // 3) 内部状态与不变式：windowRect.origin + petRectInWindow.origin == petScreenRect.origin。
        sceneFrame = window
        petLocalRect = layout.petRectInWindow
        petLayerOffset = intArrayOf(layout.petRectInWindow.left, layout.petRectInWindow.top)
        petSizePx = OverlaySize(layout.petRectInWindow.width, layout.petRectInWindow.height)
        if (!layout.assertConsistent()) {
            // 自检失败只告警、仍提交：绝不让诊断逻辑把可用的桌宠卡死。
            OverlayLog.warn("scene.layout 自检失败（仍提交）：$layout")
        }
        currentView.requestLayout()
        safeUpdateViewLayout(tag)
    }

    /**
     * 求解本纪元的菜单信封（窗口 + 锚点 + 缺口）；参数与 [enterOpening] 完全一致，
     * 因此"纪元提交时解出的信封"就是"打开菜单时使用的信封"，**开菜单不再二次求解**。
     *
     * 返回 null = 没有可用信封（可用区域不可信 / 求解异常）→ 纪元退化为"窗口 == 人物"，
     * 且本次不允许打开菜单。
     */
    private fun computeMenuEnvelope(petScreenRect: OverlayRect): WheelMenuEnvelope? {
        if (!bounds.isUsable || !petScreenRect.isUsable) return null
        return try {
            WheelMenuGeometry.computeEnvelope(
                bounds = bounds,
                petWindowRect = petScreenRect,
                content = petContentBounds,
                // 按**最大条目数**算信封：打开期间窗口恒定（需求 §14）。
                maxItemCount = WheelMenuCatalog.maxItems,
                spec = wheelSpec,
                settings = menuSettings,
                previousDirection = lastDirection,
                previousVerticalMode = lastVerticalMode,
                lockMode = false,
            )
        } catch (t: Throwable) {
            OverlayLog.error("轮盘几何计算异常（纪元信封不可用）", t)
            null
        }
    }

    /**
     * **真实几何变化**时重算几何纪元：更新"人物屏幕矩形 + 菜单信封"，并按**关态**提交窗口几何
     * （窗口 == 人物矩形，零 padding），**一次**原子提交。
     *
     * 调用时机：attach / applySettings / 拖动落定 / 位置恢复 / 换素材 —— 这些路径菜单必然处于关闭态，
     * 因此提交的是关态帧。菜单**开合**不在这里（开由 [enterOpening] 提交并集，关由 [closeMenuScene] 缩回）。
     *
     * @return true = 解出了可用菜单信封（本纪元可打开菜单）。
     */
    private fun refreshEpoch(petScreenRect: OverlayRect, tag: String): Boolean {
        // 纪元帧变化必然改变菜单层的容器内矩形：若菜单层还挂着（异常时序），先按"几何变化"摘掉，
        // 否则 attached 的菜单 View 仍用旧矩形、与新纪元不一致。正常路径（applySettings 等）已提前摘层。
        if (epoch.menuLayerAttached) {
            OverlayLog.warn("scene.epoch tag=$tag 检测到菜单层仍挂载 → 先摘层再重算（几何变化必须先收敛）")
            detachMenuLayerOnly("epoch-refresh:$tag")
        }
        val env = computeMenuEnvelope(petScreenRect)
        // 双窗口：窗口矩形的唯一权威是**桌宠矩形**（菜单在独立窗口里），因此纪元不存"菜单信封"，
        // [OverlaySceneEpoch.openLayout] 恒为 null ⇒ 结构上不可能再把桌宠窗扩成并集。
        val scene = epoch.commit(petScreenRect, if (dualWindowActive) null else env?.windowRect)
        commitSceneLayout(scene, tag)
        epochEnvelope = env
        if (dualWindowActive) syncDualMenuWindow("epoch:$tag")
        if (env == null) {
            OverlayLog.warn(
                "scene.epoch tag=$tag 无可用菜单信封（窗口 == 人物，无 padding）pet=$petScreenRect",
            )
        }
        return env != null
    }

    /** 菜单层的**屏幕**矩形（窗口原点 + 容器内偏移）；菜单未挂载时为 null。 */
    private fun menuScreenRect(): OverlayRect? {
        val rect = menuRectInWindow ?: return null
        val p = params ?: return null
        return rect.translate(p.x, p.y)
    }

    /** 当前**桌宠**尺寸（未挂载时给一个不变量化的兜底值）。 */
    fun petSize(): OverlaySize {
        val rect = petWindowRect()
        if (rect.isUsable) return OverlaySize(rect.width, rect.height)
        return OverlaySize.fallback
    }

    /** 当前**桌宠**左上角像素（诊断 / 位置持久化 / 吸附判定都用它）。 */
    fun currentTopLeft(): IntArray {
        val rect = petWindowRect()
        return intArrayOf(rect.left, rect.top)
    }

    /** 当前可用区域（诊断）。 */
    fun currentBounds(): OverlayBounds = bounds

    /** 当前可见状态名（`asset`/`loading`/`failure`/`empty`/`debug`；未挂载时 `absent`）。 */
    fun currentVisual(): String = view?.visual?.name ?: "absent"

    fun postAfterLayout(block: () -> Unit) {
        view?.post { block() } ?: OverlayLog.warn("postAfterLayout 被忽略：窗口未挂载")
    }

    /** 一行式窗口诊断（日志用）。 */
    fun dump(): String {
        val v = view
        val p = params
        val topLeft = currentTopLeft()
        return buildString {
            append("attached=").append(isAttached)
            append(" attachedToWindow=").append(isAttachedToWindow)
            append(" visible=").append(isVisible)
            append(" lp=")
            if (p == null) {
                append("null")
            } else {
                append(p.width).append('x').append(p.height)
                append(" x=").append(p.x).append(" y=").append(p.y)
                append(" type=").append(p.type)
                append(" flags=").append(p.flags)
                append(" format=").append(p.format)
                append(" gravity=").append(p.gravity)
                append(" alpha=").append(p.alpha)
            }
            append(" bounds=").append(bounds.left).append(',').append(bounds.top)
                .append('-').append(bounds.right).append(',').append(bounds.bottom)
            append(" size=").append(petSize().width).append('x').append(petSize().height)
            append(" topLeft=").append(topLeft[0]).append(',').append(topLeft[1])
            append(" gesture=").append(gestureStateName)
            append(" menu=").append(menuState.name)
            append(" mode=").append(if (dualWindowActive) "dual" else "single")
            append(" menuWindow=")
            // 单窗口：这里报的是**菜单层的屏幕矩形**（窗口原点 + 容器内偏移）。
            append(menuScreenRect()?.let { "(${it.left},${it.top} ${it.width}x${it.height})" } ?: "none")
            append(" menuLevel=").append(menuLevelName)
            append(" menuItems=").append(menuButtonCount)
            append(" menuActive=").append(menuActiveIndex)
            append(" menuAnim=").append(menuAnimationName)
            append(" petRectBeforeMenu=").append(petRectBeforeMenu ?: "none")
            append(" screen=").append(screenSize()[0]).append('x').append(screenSize()[1])
            append(" density=").append(context.resources.displayMetrics.density)
            append(" thread=").append(Thread.currentThread().name)
            append(" mainThread=").append(Looper.myLooper() == Looper.getMainLooper())
            append(" view[").append(v?.dump() ?: "null").append(']')
            append(" lastAction=").append(lastWindowAction)
            append(" lastError=").append(lastWindowError ?: "<none>")
        }
    }

    // -----------------------------------------------------------------------
    // 挂载 / 卸载
    // -----------------------------------------------------------------------

    /**
     * 挂载窗口；**幂等**。返回是否为本次新建。
     *
     * 已挂载时只把新的缩放/标志/占位文字应用上去，绝不 addView 第二次。
     */
    fun attach(store: PetOverlayStore): Boolean {
        val existing = view
        if (existing != null) {
            applySettings(store)
            OverlayLog.log("addView 跳过：已有唯一窗口（幂等）")
            return false
        }

        requireMainThread("addView")
        cancelSnapAnimation(applyTarget = false)

        snapEnabled = store.snapEnabled
        debugMode = store.debugOverlayMode
        touchThrough = store.touchThrough
        menuTheme = store.menuTheme()
        menuHapticsEnabled = store.menuHapticsEnabled
        menuSettings = store.menuLayoutSettings()
        menuButtonScale = menuSettings.buttonVisualScale
        // 运行模式：请求值来自 store；真正生效值由本次建窗结果决定（见下）。
        dualWindowRequested = store.dualWindowMode
        dualWindowActive = false
        // 双窗口：菜单窗**最先加**（且整个窗口纪元只加一次），随后再加桌宠窗 ⇒ 桌宠稳定在上层。
        // 建窗失败 ⇒ 立即回退单窗口并记日志（绝不因为菜单窗问题让用户失去桌宠窗）。
        var dualSetupSucceeded = false
        if (dualWindowRequested) {
            dualSetupSucceeded = runCatching {
                val menuWindow = dualMenuWindow
                    ?: DualWindowMenuWindow(context, windowManager).also { dualMenuWindow = it }
                menuWindow.addOnce()
                menuWindow.isAttached
            }.getOrElse { t ->
                OverlayLog.error("dual-window 菜单窗建立失败 → 回退单窗口", t)
                false
            }
        }
        dualWindowActive = DualWindowModeResolver.resolve(
            requestedDual = dualWindowRequested,
            dualSetupSucceeded = dualSetupSucceeded,
        ) == OverlayMode.DUAL_WINDOW
        OverlayLog.log(
            "overlay.mode requested=${if (dualWindowRequested) "dual" else "single"} " +
                "active=${if (dualWindowActive) "dual" else "single"} " +
                (DualWindowModeResolver
                    .fallbackReason(dualWindowRequested, dualSetupSucceeded)
                    ?.let { "reason=$it " } ?: ""),
        )
        if (!dualWindowActive) {
            // 回退单窗口：清掉可能残留的菜单窗（异常路径），保证"绝不留可触摸残留"。
            dualMenuWindow?.remove()
            dualMenuWindow = null
        }
        // 每次 attach 都重新解析可用区域：旋转/分屏后一定是新的值。
        bounds = resolveBounds()

        val density = context.resources.displayMetrics.density
        val size = computeSize(store, density)
        val topLeft = computeTopLeft(store, size)

        val created = PetOverlayView(context).apply {
            setDebugMode(debugMode)
            // 触摸交给手势状态机（在 manager 里，每个窗口一个）。
            touchHandler = { event -> handleTouch(event) }
        }
        // 每个新窗口都从"菜单关闭 + 干净状态"开始（4C-3A 的手势机同理）。
        disposed = false
        menuState = OverlayMenuState.closed
        // 会话整体作废：新窗口的会话号与旧窗口绝不相同（旧回调/旧延迟任务一律失效）。
        menuSession.invalidate()
        invalidatePendingMenuOpen()
        activeLayout = null
        envelope = null
        petRectBeforeMenu = null
        menuRectInWindow = null
        sceneFrame = null
        petLocalRect = null
        petLayerOffset = intArrayOf(0, 0)
        petSizePx = size
        // 新窗口 = 新几何纪元：丢弃旧纪元、清空提交计数。
        epoch.reset()
        epochEnvelope = null
        // 新窗口：拖动跟踪器与摘除延迟器都必须回到干净状态。
        dragTracker.reset()
        detachDeferral.reset()
        cancelForwardedDragFallback()
        dragTraceActive = false
        dragTraceBuilder = null
        dragTraceLines = 0
        // 防御性：万一有残留的菜单层（异常路径），先清掉 —— 保证"最多一层菜单"。
        detachMenuLayerOnly("attach-reset")
        wheelSpec = WheelMenuSpec.fromDensity(density)
        gesture = OverlayGestureMachine(
            touchSlopPx = ViewConfiguration.get(context).scaledTouchSlop,
        )
        // 初始按**关态**建窗：窗口 == 人物矩形（零 padding）。菜单信封先算好缓存起来，
        // 等点击开菜单时再把窗口扩成"人物 ∪ 信封"（见 [enterOpening]）。
        val petScreenRect = OverlayRect(
            left = topLeft[0],
            top = topLeft[1],
            right = topLeft[0] + size.width,
            bottom = topLeft[1] + size.height,
        )
        val env = computeMenuEnvelope(petScreenRect)
        // 双窗口：纪元窗口矩形的唯一权威是桌宠矩形（菜单在独立窗口），不存菜单信封。
        val scene = epoch.commit(petScreenRect, if (dualWindowActive) null else env?.windowRect)
        epochEnvelope = env
        val window = scene.windowRect
        sceneFrame = window
        petLocalRect = scene.petRectInWindow
        petLayerOffset = intArrayOf(scene.petRectInWindow.left, scene.petRectInWindow.top)
        created.prepareSceneGeometry(OverlaySize(window.width, window.height), scene.petRectInWindow)
        // 显式尺寸，**不依赖 WRAP_CONTENT**：空 ImageView 的 WRAP_CONTENT 会算出 0×0。
        val layoutParams = WindowManager.LayoutParams(
            window.width,
            window.height,
            OverlayWindowSpec.petWindowType(Build.VERSION.SDK_INT),
            OverlayWindowSpec.windowFlags(store.touchThrough),
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = window.left
            y = window.top
            alpha = 1f
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                layoutInDisplayCutoutMode =
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
            }
        }

        lastWindowAction = "addView(start) thread=${Thread.currentThread().name}"
        // addView 可能在极端情况下失败（例如系统在授权撤销的瞬间拒绝），
        // 此时必须保持"未挂载"，让调用方给出明确提示，而不是留下半残状态。
        try {
            windowManager.addView(created, layoutParams)
        } catch (t: Throwable) {
            view = null
            params = null
            gesture = null
            // 桌宠窗没建成：连带清掉菜单窗，绝不留一个孤立的菜单窗。
            dualMenuWindow?.remove()
            dualMenuWindow = null
            dualWindowActive = false
            lastWindowError = "addView 失败：${t.message}"
            lastWindowAction = "addView(failed)"
            OverlayLog.error(lastWindowError ?: "addView 失败", t)
            throw t
        }

        view = created
        params = layoutParams
        lastWindowError = null
        lastWindowAction = "addView(ok)"
        OverlayLog.log(
            "addView ok debug=$debugMode aspect=${created.drawableAspectRatio} " +
                "topLeft(${topLeft[0]},${topLeft[1]}) ${dump()}",
        )
        OverlayLog.log(
            "position.restore xRatio=${store.xRatio} yRatio=${store.yRatio} " +
                "snapEnabled=$snapEnabled edge=${store.snapEdge} " +
                "x=${topLeft[0]} y=${topLeft[1]} bounds=${bounds.width}x${bounds.height} " +
                "size=${size.width}x${size.height}",
        )
        // 布局完成后再把**真实**尺寸/附着状态记一次：这是"看不见"最直接的证据。
        created.post {
            OverlayLog.log("addView settled(post) ${dump()}")
        }
        return true
    }

    /** 移动 / 缩放 / 旋转后**重新套用**全部几何与标志。 */
    fun applySettings(store: PetOverlayStore) {
        val currentView = view ?: return
        val currentParams = params ?: return

        requireMainThread("updateViewLayout")
        // 尺寸/位置即将重算：进行中的贴边动画必须停掉，否则会与新的坐标打架。
        cancelSnapAnimation(applyTarget = false)
        // 先记下"变化前"的桌宠几何（必须在重算场景帧之前取，用于日志对比）。
        val previousSize = petSize()
        val previousTopLeft = currentTopLeft()
        // 几何即将变化（旋转/分屏/改大小/换素材）→ 菜单必须先收敛到 closed，
        // 否则会残留一个按旧桌面几何算出来的扩展窗口。
        resetMenuForGeometryChange("applySettings")

        debugMode = store.debugOverlayMode
        snapEnabled = store.snapEnabled
        touchThrough = store.touchThrough
        bounds = resolveBounds()

        val density = context.resources.displayMetrics.density
        wheelSpec = WheelMenuSpec.fromDensity(density)
        menuTheme = store.menuTheme()
        menuHapticsEnabled = store.menuHapticsEnabled
        menuSettings = store.menuLayoutSettings()
        menuButtonScale = menuSettings.buttonVisualScale
        val size = computeSize(store, density)
        val topLeft = computeTopLeft(store, size)

        currentView.setDebugMode(debugMode)
        currentParams.flags = OverlayWindowSpec.windowFlags(store.touchThrough)
        currentParams.format = PixelFormat.TRANSLUCENT
        currentParams.alpha = 1f

        // **原子**提交桌宠窗口：参数一次准备完，只触发一次 updateViewLayout。
        // 这是"桌宠本来就该移动"的场景（旋转 / 改大小）。
        val committed = applyPetWindowGeometry(
            left = topLeft[0],
            top = topLeft[1],
            size = size,
            tag = "updateViewLayout",
        )
        if (!committed) {
            // 提交被拒绝的原因必须区分清楚，**绝不能**把"刚创建、还没走完
            // onAttachedToWindow 的窗口"当失效窗口清理掉（那会造成
            // "服务在运行但窗口未成功添加"，4C-3B 复验缺陷 A）：
            // * 守卫拒绝（窗口未附着）→ 只是跳过本次几何提交，窗口本身是好的；
            // * addView/updateViewLayout 真抛异常且窗口确实已不在 WindowManager 上 → 才清理引用。
            if (lastWindowError != null && !currentView.isAttachedToWindow) {
                OverlayLog.warn("窗口确实已不在 WindowManager 上（$lastWindowError），清理引用")
                detach("update-failed-detached")
            } else {
                OverlayLog.warn("本次几何提交被跳过（窗口尚未附着），窗口保持不动：${dump()}")
            }
            return
        }
        currentView.invalidate()
        OverlayLog.log("updateViewLayout ok ${dump()}")
        if (previousSize != size) {
            OverlayLog.log(
                "size.update from=${previousSize.width}x${previousSize.height} " +
                    "to=${size.width}x${size.height} scale=${store.scale} " +
                    "aspect=${currentView.drawableAspectRatio}",
            )
        }
        if (previousTopLeft[0] != topLeft[0] || previousTopLeft[1] != topLeft[1]) {
            OverlayLog.log(
                "position.clamp from=(${previousTopLeft[0]},${previousTopLeft[1]}) " +
                    "to=(${topLeft[0]},${topLeft[1]}) edge=${store.snapEdge} " +
                    "bounds=${bounds.width}x${bounds.height}",
            )
        }
    }

    /** 切换诊断模式（保存到 store 后调用）。 */
    fun setDebugMode(enabled: Boolean) {
        val currentView = view ?: return
        debugMode = enabled
        currentView.setDebugMode(enabled)
        currentView.requestLayout()
        currentView.invalidate()
        OverlayLog.log("setDebugMode $enabled ${dump()}")
    }

    /**
     * 挂上**静态**视觉（PNG / JPG / 静态 WebP / 低版本第一帧回退）。
     */
    fun showStatic(drawable: Drawable) {
        view?.showStatic(drawable)
        OverlayLog.log("visual.apply.static ${dump()}")
    }

    /** 挂上**动态**视觉（动态 WebP）。 */
    fun showAnimated(drawable: Drawable) {
        view?.showAnimated(drawable)
        OverlayLog.log("visual.apply.animated ${dump()}")
    }

    /** 解码失败：清旧视觉 + 显示错误占位（窗口绝不消失）。 */
    fun showErrorPlaceholder(message: String?) {
        view?.showErrorPlaceholder(message)
        // 任务约束：素材加载失败 → 人物已不可见，把菜单关掉。
        closeMenuForVisualLoss("placeholder")
        OverlayLog.log("visual.apply.placeholder ${dump()}")
    }

    /**
     * 清空视觉（隐藏 / 停止时用）：停动画 → 摘 Drawable → 空占位。
     *
     * 必须在 `removeView` **之前**调用：先把 Drawable 从 ImageView 上摘掉，
     * 再让加载器释放引用（需求第 12 节）。
     */
    fun clearVisual(reason: String) {
        OverlayLog.log("visual.clear reason=$reason running=$isAnimationRunning")
        view?.clearVisual()
        // 任务约束：人物已不可见 → 把菜单关掉（缺口处不再是人物）。
        closeMenuForVisualLoss(reason)
    }

    /**
     * 人物不再可见（加载失败 / 被清空）时关闭菜单（任务约束）。
     *
     * 菜单是围绕人物的：一旦人物消失，缺口处只剩占位文案/空白，菜单继续开着没有意义
     * —— 因此强制关闭。只动菜单状态，**不碰**窗口生命周期 / 尺寸范围 / 触摸逻辑。
     */
    private fun closeMenuForVisualLoss(reason: String) {
        if (menuState == OverlayMenuState.closed) return
        if (canRenderMenuForeground()) return
        lastMenuOpenError = "pet-not-visible-or-asset-missing"
        OverlayLog.warn("menu.close：人物不再可见（reason=$reason）→ 强制关闭菜单")
        closeMenu("visual-lost:$reason", animate = false)
    }

    /** 当前动画是否在跑（诊断）。 */
    val isAnimationRunning: Boolean get() = view?.isAnimationRunning == true

    /** 当前视觉是否为"可播放动画"。 */
    val isAnimatableVisual: Boolean get() = view?.isAnimatableVisual == true

    /**
     * 统一的动画播放同步（需求第 10/11 节）。
     *
     * 幂等：已经在跑就不再 start，已经停了就不再 stop；播放/暂停都记一条日志。
     */
    fun syncAnimation(shouldPlay: Boolean, reason: String) {
        val currentView = view ?: return
        if (shouldPlay) {
            if (currentView.isAnimationRunning) return
            currentView.startAnimationIfAllowed()
            if (currentView.isAnimationRunning) {
                OverlayLog.log("animation.start reason=$reason ${dump()}")
            }
        } else {
            if (!currentView.isAnimationRunning) return
            currentView.stopAnimation()
            OverlayLog.log("animation.stop reason=$reason ${dump()}")
        }
    }

    /**
     * 按"有没有图 / 是否在加载 / 最近一次错误"刷新可见状态。
     *
     * 关键点：**有图时永远显示图**（失败也不换成占位），
     * 没图时一定显示**可见的**占位底 —— 绝不留下全透明或 0×0 的窗口。
     */
    fun refreshVisual(loading: Boolean, lastError: String?) {
        val currentView = view ?: return
        currentView.refreshVisual(loading = loading, lastError = lastError)
        OverlayLog.log("refreshVisual loading=$loading ${dump()}")
    }

    fun setAnimationPaused(paused: Boolean) {
        view?.setAnimationPaused(paused)
    }

    /** 动态素材"仅第一帧"角标。 */
    fun setAnimatedBadgeVisible(visible: Boolean) {
        view?.setAnimatedBadgeVisible(visible)
    }

    /**
     * 当前**人物**长边像素 —— 解码采样率以它为"目标尺寸"。
     *
     * 用长边而不是宽或高：素材宽高比不同，窗口宽高也不同，
     * 只有长边能保证"既不全尺寸解码、也不糊掉"。
     * 窗口未挂载时返回 0（调用方跳过加载）。
     *
     * 注意：单窗口方案下 `params` 描述的是**场景并集**，因此这里必须用人物尺寸，
     * 而不是窗口的长边。
     */
    fun currentViewSizePx(): Int = if (params == null) 0 else petSizePx.longEdge

    /**
     * 移除窗口；**幂等**（重复调用不抛异常）。
     *
     * [reason] 会进日志，便于追"谁把它摘掉的"。
     * [suspendGesture] 用于把状态机明确推到 HIDDEN/STOPPED（诊断用）。
     */
    fun detach(
        reason: String = "unspecified",
        suspendGesture: OverlayGestureState? = null,
    ) {
        // 先取消动画：窗口都要没了，任何后续动画帧都不允许再 updateWindowLayout。
        cancelSnapAnimation(applyTarget = false)
        // 双窗口：菜单窗随桌宠窗一起摘除（幂等；绝不留一个孤立的、可能仍可触摸的菜单窗）。
        dualMenuWindow?.remove()
        dualMenuWindow = null
        dualWindowActive = false
        // 窗口即将移除：拖动跟踪与"延迟摘菜单"都必须立刻失效，否则菜单层会被挂起不摘。
        dragTracker.reset()
        dragTraceActive = false
        dragTraceBuilder = null
        detachDeferral.reset()
        cancelForwardedDragFallback()
        // 会话作废：detach 之后任何带旧会话号的回调都不允许再操作窗口 / 恢复交互。
        menuSession.invalidate()
        invalidatePendingMenuOpen()
        // 菜单窗口同理：取消动画 + 清按钮 + 移除独立菜单窗口。
        resetMenuForGeometryChange("detach:$reason")
        disposed = true
        val currentView = view ?: run {
            suspendGesture?.let { gesture?.suspend(it) }
            return
        }
        OverlayLog.log("removeView reason=$reason ${dump()}")
        // 先清引用再移除：即使 removeView 抛异常也不会留下悬空引用。
        view = null
        params = null
        // 场景帧属于这个窗口实例：随窗口一起丢弃（下次 attach 会重新计算）。
        sceneFrame = null
        petLocalRect = null
        // 几何纪元同样属于这个窗口实例。
        epoch.reset()
        epochEnvelope = null
        lastWindowAction = "removeView($reason)"
        suspendGesture?.let { gesture?.suspend(it) }
        try {
            windowManager.removeView(currentView)
        } catch (t: Throwable) {
            OverlayLog.warn("removeView 失败（通常表示窗口已被系统移除）", t)
        }
    }

    /** 兼容旧调用（不带原因）。 */
    fun detach() = detach("unspecified")

    // -----------------------------------------------------------------------
    // 手势（Phase 4C-3A）
    // -----------------------------------------------------------------------

    /**
     * 触摸入口（由 [PetOverlayView] 转发）。
     *
     * 全程**不写盘**：只有松手（或贴边动画结束）才通过 [OverlayWindowHost.onPersistPosition] 存一次。
     *
     * 缺陷 2 修复：拖动位置的算法**完全搬到** [OverlayDragTracker]（屏幕坐标 + 抓取偏移），
     * 这里只负责"把哪个指针的屏幕坐标喂进去"。规则：
     * * `DOWN` 记录抓取（一次性算 grabOffset）并锁定该指针 id；
     * * `MOVE` 只处理锁定指针，第二根手指（`POINTER_DOWN`）一律忽略 —— 不抢手势、不换手指；
     * * 锁定指针抬起（`UP` 或它就是 `POINTER_UP` 的那一个）才干净结束；
     * * 中途**绝不**重跑命中判定，也绝不因为手指离开人物层/窗口而结束拖动。
     */
    private fun handleTouch(event: MotionEvent): Boolean {
        val machine = gesture ?: return false
        if (touchThrough) return false

        val x = event.rawX
        val y = event.rawY
        val time = event.eventTime
        lastTouchX = x
        lastTouchY = y
        dragSourceName = "pet-view"
        // 每次触摸都刷新"窗口是否可更新"：未附着时状态机会拒绝进入拖动。
        machine.windowUpdatable = view?.isAttachedToWindow == true

        val action = event.actionMasked

        val effect = when (action) {
            MotionEvent.ACTION_DOWN -> {
                beginDragTracking(event.getPointerId(0), x, y, dragSourceName)
                machine.onDown(x, y, time)
            }

            MotionEvent.ACTION_MOVE -> {
                // 只有"按下时锁定的那个指针"才喂给跟踪器（第二根手指不会改变 grab 关系）。
                if (isActivePointer(event)) recordFinger(x, y)
                machine.onMove(x, y, time)
            }

            MotionEvent.ACTION_POINTER_DOWN -> {
                // 第二根手指落下：忽略（缺陷 2-2）。拖动继续进行，不派发任何事件给状态机。
                dragTrace("MOVE extraPointer down ignored id=${event.getPointerId(event.actionIndex)}")
                OverlayGestureEffect.none
            }

            MotionEvent.ACTION_POINTER_UP -> {
                val upId = event.getPointerId(event.actionIndex)
                if (upId == dragTracker.activePointerId) {
                    // 锁定的指针抬起 → 干净结束（**不**切换到剩下的手指）。
                    recordFinger(x, y)
                    machine.onUp(x, y, time)
                } else {
                    dragTrace("MOVE extraPointer up ignored id=$upId")
                    OverlayGestureEffect.none
                }
            }

            MotionEvent.ACTION_UP -> {
                if (isActivePointer(event)) recordFinger(x, y)
                machine.onUp(x, y, time)
            }

            MotionEvent.ACTION_CANCEL -> machine.onCancel()
            else -> OverlayGestureEffect.none
        }
        applyGestureEffect(effect)
        return effect != OverlayGestureEffect.none || machine.state != OverlayGestureState.IDLE
    }

    /** 事件里的 pointer-0 是否就是按下时锁定的指针（用于"只跟这一个指针"）。 */
    private fun isActivePointer(event: MotionEvent): Boolean =
        dragTracker.isActive && event.pointerCount > 0 &&
            event.getPointerId(0) == dragTracker.activePointerId

    /**
     * 开始一次手势：记录抓取偏移并锁定指针。
     *
     * 注意 grabOffset 用的是**人物**的屏幕左上角（窗口比人物大，不能用 LP 原点），
     * 且只在 DOWN 记一次 —— 之后无论窗口怎么移动都不再重算。
     */
    private fun beginDragTracking(pointerId: Int, x: Float, y: Float, source: String) {
        val pet = petWindowRect()
        dragTracker.begin(pointerId, x, y, pet.left, pet.top)
        activeGestureId += 1
        dragDownX = x
        dragDownY = y
        dragSourceName = source
        dragTraceActive = false
        dragTraceBuilder = null
        dragTraceLines = 0
        OverlayLog.log("gesture.down x=${x.toInt()} y=${y.toInt()} menuState=${menuState.name} slop=${touchSlopPx()}")
    }

    /** 用当前手指屏幕位置刷新跟踪器（只对锁定指针生效）。 */
    private fun recordFinger(x: Float, y: Float) {
        if (!dragTracker.isActive) return
        val size = petSize()
        dragTracker.update(dragTracker.activePointerId, x, y, bounds, size.width, size.height)
        lastTouchX = x
        lastTouchY = y
    }

    /** 以"最后已知手指位置"结算并结束跟踪（UP 用）。 */
    private fun endDragTracking() {
        if (!dragTracker.isActive) return
        val size = petSize()
        dragTracker.end(dragTracker.activePointerId, bounds, size.width, size.height)
    }

    private fun applyGestureEffect(effect: OverlayGestureEffect) {
        when (effect) {
            OverlayGestureEffect.none -> Unit

            OverlayGestureEffect.press -> {
                // 新的手势开始：正在跑的贴边动画立即定格到目标位（确定状态）。
                cancelSnapAnimation(applyTarget = true)
                // 抓取偏移已在 DOWN 一次性记录（屏幕坐标），这里只保证桌宠可见。
                enforcePetAlwaysVisible("gesture-press")
            }

            OverlayGestureEffect.dragStart -> {
                // 需求 3.3：菜单打开时开始拖动 → **先关菜单**（摘掉菜单层，不改窗口几何），再拖动。
                if (isMenuOpen) {
                    OverlayLog.log("gesture.drag.start 检测到菜单打开 → 先关闭菜单再拖动")
                    closeMenu("drag-start", animate = false)
                }
                dragTraceStart(dragSourceName)
                applyDragTarget("drag-start")
            }

            OverlayGestureEffect.drag -> applyDragTarget("drag")

            OverlayGestureEffect.dragEnd -> {
                // 缺陷 2-6：用跟踪器的 end() 以**最后手指位置**结算并结束手势，再落一次窗口位置。
                endDragTracking()
                applyDragTarget("drag-end")
                OverlayLog.log("gesture.drag.end ${positionSummary()}")
                flushDragTrace("up")
                finishDrag()
            }

            OverlayGestureEffect.click -> {
                OverlayLog.log("gesture.click ${positionSummary()}")
                // 4C-3B：单击 = 开关圆盘菜单（开着就关、关着就开）。
                toggleMenu(reason = "gesture-click")
                host.onClickPet()
            }

            OverlayGestureEffect.cancel -> {
                // 缺陷 2-7：结束手势但不丢位置 —— 保留最后有效位置并落一次盘，
                // 且**不触发任何菜单动作**。
                dragTracker.cancel()
                OverlayLog.log("gesture.cancel ${positionSummary()}")
                flushDragTrace("cancel")
                persistCurrentPosition(edge = null)
                // 取消也可能已经移动过窗口：重算纪元帧，保证下次开菜单的信封与位置一致。
                refreshEpoch(petWindowRect(), "gesture-cancel-settle")
            }
        }
    }

    /**
     * 拖动中：把跟踪器算出的**桌宠屏幕左上角**换算成窗口原点并提交（原子，一次 updateViewLayout）。
     *
     * 屏幕坐标 + 抓取偏移 ⇒ 与窗口当前原点无关，手指怎么动桌宠就怎么跟，不会"脱手"。
     * 越界时目标被夹进可用区域，但手势保持存活（跟踪器不结束），手指回到范围内立刻继续跟随。
     *
     * 走 [commitSceneLayout] + [OverlaySceneSolver.moved]：**窗口尺寸/人物层偏移保持不变，
     * 只把窗口原点与人物层一起平移同样的量**。因此转发拖动期间即使菜单被要求关闭，
     * 窗口也不会在这里被缩小（缩窗由 [closeMenuScene] 走延迟闸门统一处理）。
     */
    private fun applyDragTarget(source: String) {
        val p = params ?: return
        val current = view ?: return
        // 需求"三、第 7/8 条"：View 未附着时不得执行 updateViewLayout。
        if (!current.isAttachedToWindow) {
            dragTrace("MOVE src=$source drop=window-not-attached")
            return
        }
        val target = dragTracker.lastTarget() ?: return
        val actual = currentTopLeft()
        dragTrace(
            "MOVE src=$source finger=(${lastTouchX.toInt()},${lastTouchY.toInt()}) " +
                "petTarget=(${target[0]},${target[1]}) petActual=(${actual[0]},${actual[1]}) " +
                "receiver=$dragSourceName menu=${menuState.name} pending=0",
        )
        // 人物层在容器内的偏移保持不变（拖动期间不变），只平移窗口原点。
        val local = petLocalRect
            ?: OverlayRect(0, 0, petSizePx.width, petSizePx.height)
        val targetRect = OverlayRect(
            left = target[0],
            top = target[1],
            right = target[0] + local.width,
            bottom = target[1] + local.height,
        )
        val layout = OverlaySceneSolver.moved(
            petScreenRect = targetRect,
            petRectInWindow = local,
            windowSize = OverlaySize(p.width, p.height),
            menuRectInWindow = menuRectInWindow,
            menuOpen = menuRectInWindow != null,
        )
        commitSceneLayout(layout, "updateViewLayout(drag)")
        // 同步纪元里的人物屏幕矩形：转发拖动（菜单仍挂载）期间，关菜单要按**最新**人物位置把窗口缩回。
        epoch.updatePetScreenRect(targetRect)
        // 双窗口：菜单开着时，菜单窗按桌宠**当前**屏幕矩形跟随（一次 updateViewLayout）。
        if (dualWindowActive) syncDualMenuWindow("drag:$source")
    }

    // -----------------------------------------------------------------------
    // 缺陷 3：有界拖动诊断（每个手势最多 DRAG_TRACE_MAX_LINES 行，只在 debugOverlayMode 下）
    // -----------------------------------------------------------------------

    private fun dragTraceStart(source: String) {
        if (!debugMode) return
        dragTraceActive = true
        dragTraceBuilder = StringBuilder()
        dragTraceLines = 0
        dragTrace(
            "DOWN id=$activeGestureId pointer=${dragTracker.activePointerId} " +
                "screen=(${dragDownX.toInt()},${dragDownY.toInt()}) receiver=$source " +
                "menu=${menuState.name} grab=(${dragTracker.grabOffsetX.toInt()}," +
                "${dragTracker.grabOffsetY.toInt()}) petOrigin=(${currentTopLeft()[0]},${currentTopLeft()[1]})",
        )
        dragTrace("DRAG-START src=$source slop=${touchSlopPx()}")
    }

    private fun dragTrace(line: String) {
        if (!debugMode || !dragTraceActive) return
        if (dragTraceLines >= DRAG_TRACE_MAX_LINES) return
        val sb = dragTraceBuilder ?: StringBuilder().also { dragTraceBuilder = it }
        dragTraceLines += 1
        sb.append('\n').append("  #").append(dragTraceLines).append(' ').append(line)
    }

    private fun flushDragTrace(endReason: String) {
        if (!dragTraceActive) return
        dragTraceActive = false
        val sb = dragTraceBuilder
        dragTraceBuilder = null
        if (!debugMode || sb == null) return
        OverlayLog.log("gesture.trace id=$activeGestureId end=$endReason lines=$dragTraceLines$sb")
    }

    /** 松手：先贴边（可选），再持久化。全部按**人物**坐标计算，最后换算成窗口原点提交。 */
    private fun finishDrag() {
        val p = params ?: return
        val size = petSize()
        val localX = petLocalX()
        val localY = petLocalY()
        val petLeft = p.x + localX
        val petTop = p.y + localY
        val edge = if (snapEnabled) {
            OverlayPositionCalculator.snapEdgeFor(
                centerX = OverlayPositionCalculator.centerX(petLeft, size.width),
                bounds = bounds,
            )
        } else {
            OverlaySnapEdge.none
        }

        if (edge == OverlaySnapEdge.none) {
            val clamped = OverlayPositionCalculator.clampTopLeft(
                petLeft, petTop, bounds, size.width, size.height,
            )
            if (clamped[0] != petLeft || clamped[1] != petTop) {
                OverlayLog.log(
                    "position.clamp 松手修正 pet=($petLeft,$petTop)->(${clamped[0]},${clamped[1]})",
                )
                p.x = clamped[0] - localX
                p.y = clamped[1] - localY
                safeUpdateViewLayout("snap-none-clamp")
            }
            persistCurrentPosition(edge = OverlaySnapEdge.none)
            // 拖动落定 = 真实几何变化：重算几何纪元（关态窗口 == 人物矩形，零 padding）。
            refreshEpoch(petWindowRect(), "drag-settle")
            return
        }

        val targetX = OverlayPositionCalculator.snapTargetX(edge, bounds, size.width)
        val targetY = petTop.coerceIn(
            bounds.top,
            (bounds.top + (bounds.height - size.height).coerceAtLeast(0)),
        )
        if (targetX == petLeft && targetY == petTop) {
            persistCurrentPosition(edge = edge)
            refreshEpoch(petWindowRect(), "drag-settle")
            return
        }
        OverlayLog.log("snap.start edge=${edge.labelZh} pet=($petLeft,$petTop) -> ($targetX,$targetY)")
        startSnapAnimation(targetX, targetY, edge)
    }

    /**
     * 贴边动画（150~250ms）；动画期间**不写盘**，结束后统一持久化。
     *
     * [targetX] / [targetY] 是**人物**的屏幕左上角目标；窗口原点 = 目标 − 人物层偏移，
     * 因此在动画每一帧里人物与窗口都是一起动的（不会出现半帧错位）。
     */
    private fun startSnapAnimation(targetX: Int, targetY: Int, edge: OverlaySnapEdge) {
        val currentParams = params ?: return
        val localX = petLocalX()
        val localY = petLocalY()
        val startPetX = currentParams.x + localX
        val startPetY = currentParams.y + localY
        cancelSnapAnimation(applyTarget = false)
        val animator = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = OverlayGeometry.SNAP_ANIMATION_MS
            interpolator = DecelerateInterpolator()
            addUpdateListener { animation ->
                val fraction = animation.animatedValue as Float
                val p = params ?: return@addUpdateListener
                val v = view ?: return@addUpdateListener
                if (!v.isAttachedToWindow) return@addUpdateListener
                p.x = (startPetX + (targetX - startPetX) * fraction).toInt() - localX
                p.y = (startPetY + (targetY - startPetY) * fraction).toInt() - localY
                try {
                    windowManager.updateViewLayout(v, p)
                    lastWindowAction = "updateViewLayout(snap)"
                } catch (t: Throwable) {
                    OverlayLog.warn("贴边动画 updateViewLayout 失败", t)
                }
            }
            addListener(object : AnimatorListenerAdapter() {
                override fun onAnimationEnd(animation: Animator) {
                    if (snapAnimator !== animation) return
                    snapAnimator = null
                    val p = params ?: return
                    p.x = targetX - localX
                    p.y = targetY - localY
                    safeUpdateViewLayout("snap-end")
                    OverlayLog.log("snap.end edge=${edge.labelZh} pet=($targetX,$targetY)")
                    persistCurrentPosition(edge = edge)
                    // 贴边落定 = 真实几何变化：重算纪元帧（新位置的左右方向/垂直模式）。
                    refreshEpoch(petWindowRect(), "snap-settle")
                }
            })
        }
        snapTargetEdge = edge
        snapTargetX = targetX
        snapTargetY = targetY
        snapAnimator = animator
        animator.start()
    }

    /**
     * 取消贴边动画。
     *
     * [snapTargetX] / [snapTargetY] 是**人物**坐标，提交窗口原点时要减去人物层偏移。
     *
     * @param applyTarget true = 立刻落到目标位（"动画被取消时恢复确定状态"）；
     *   false = 停在当前帧（窗口即将移除 / 即将重算几何，落点无意义）。
     */
    private fun cancelSnapAnimation(applyTarget: Boolean) {
        val animator = snapAnimator ?: return
        snapAnimator = null
        val fraction = animator.animatedFraction
        animator.cancel()
        if (!applyTarget) {
            OverlayLog.log("snap.cancel fraction=$fraction（保持当前帧）")
            return
        }
        // 动画被打断：按"确定状态"处理 —— 立刻落到本次动画的目标位再持久化，
        // 避免"屏幕停在中间帧、存储写在目标位"，也避免把吸附边误写成 none。
        OverlayLog.log("snap.cancel fraction=$fraction（落到确定状态）")
        params?.let {
            it.x = snapTargetX - petLocalX()
            it.y = snapTargetY - petLocalY()
        }
        safeUpdateViewLayout("snap-cancel")
        persistCurrentPosition(edge = snapTargetEdge)
        snapTargetEdge = OverlaySnapEdge.none
        // 动画被打断后落定到确定位置：同样属于真实几何变化，重算纪元帧。
        refreshEpoch(petWindowRect(), "snap-cancel-settle")
    }

    private fun safeUpdateViewLayout(tag: String) {
        val p = params ?: return
        val v = view ?: return
        if (!v.isAttachedToWindow) return
        try {
            windowManager.updateViewLayout(v, p)
            lastWindowAction = "updateViewLayout($tag)"
        } catch (t: Throwable) {
            lastWindowError = "updateViewLayout($tag) 失败：${t.message}"
            OverlayLog.warn(lastWindowError ?: "updateViewLayout 失败", t)
        }
    }

    /**
     * 按**当前可见的 LP 坐标**持久化（相对比例 + 吸附边）。
     *
     * [edge] 为 null 表示"**按当前位置重新推断**吸附边"（不是在清除吸附）。
     * 之所以要区分：动画被打断、手势被取消时位置已经变了，此时若把边写成 `none`，
     * 下一次"改大小"就会按比例外扩而不是继续贴边（需求 2.5 明确禁止）。
     */
    private fun persistCurrentPosition(edge: OverlaySnapEdge?) {
        if (params == null) return
        val size = petSize()
        // 落盘必须以**人物**左上角为基准（窗口矩形是"场景帧"，比人物大）。
        val petLeft = petWindowRect().left
        val petTop = petWindowRect().top
        if (!bounds.isUsable) {
            OverlayLog.warn("position.persist 跳过：可用区域不可信 bounds=${bounds.width}x${bounds.height}")
            return
        }
        val ratios = OverlayPositionCalculator.ratioFromTopLeft(
            x = petLeft,
            y = petTop,
            bounds = bounds,
            petWidth = size.width,
            petHeight = size.height,
        )
        val resolvedEdge = edge ?: if (snapEnabled) {
            OverlayPositionCalculator.snapEdgeFor(
                centerX = OverlayPositionCalculator.centerX(petLeft, size.width),
                bounds = bounds,
            )
        } else {
            OverlaySnapEdge.none
        }
        OverlayLog.log(
            "position.persist xRatio=${ratios[0]} yRatio=${ratios[1]} edge=${resolvedEdge.labelZh} " +
                "pet=($petLeft,$petTop) bounds=${bounds.width}x${bounds.height} " +
                "size=${size.width}x${size.height} orientation=${orientationName()}",
        )
        host.onPersistPosition(ratios[0], ratios[1], resolvedEdge)
    }

    private fun positionSummary(): String {
        val p = params ?: return "position=<none>"
        val size = petSize()
        return "lp=(${p.x},${p.y}) pet=${currentTopLeft()[0]},${currentTopLeft()[1]} " +
            "size=${size.width}x${size.height} " +
            "bounds=${bounds.width}x${bounds.height} edge=${snapEdgeLabel()}"
    }

    private fun snapEdgeLabel(): String =
        OverlayPositionCalculator
            .snapEdgeFor(OverlayPositionCalculator.centerX(currentTopLeft()[0], petSize().width), bounds)
            .labelZh

    private fun touchSlopPx(): Int = ViewConfiguration.get(context).scaledTouchSlop

    /** 最近一次触摸的屏幕坐标（press 记录起点时要用）。 */
    private var lastTouchX: Float = 0f
    private var lastTouchY: Float = 0f

    // -----------------------------------------------------------------------
    // P3P 风格分层轮盘（Phase 4C-6B-1）
    //
    // 窗口几何：**展开一次、关闭一次**（需求 §14）；内部动画每帧只重绘 Canvas。
    // -----------------------------------------------------------------------

    /** 单击桌宠：开着就关、关着就开（唯一入口）。 */
    fun toggleMenu(reason: String) {
        if (reason.startsWith("gesture-click")) {
            petTapReceived = true
        }
        val next = OverlayMenuStateMachine.next(menuState, OverlayMenuEvent.requestToggle)
        OverlayLog.log(
            "menu.request.toggle reason=$reason menuState=${menuState.name} -> ${next.name} " +
                "gesture=$gestureStateName",
        )
        transitionMenu(OverlayMenuEvent.requestToggle, reason)
    }

    /**
     * 关闭菜单。
     *
     * @param animate false = 立即（隐藏/停止/权限撤销/几何变化：这是**清理**，不是交互）
     */
    fun closeMenu(reason: String, animate: Boolean) {
        if (menuState == OverlayMenuState.closed) {
            OverlayLog.log("menu.request.close 幂等（菜单本来就关着）reason=$reason")
            // 缺陷 1：状态已是 closed，但"转发拖动期间被挂起"的摘层请求可能还挂着 ——
            // 关闭必须终结，这里补消费一次（幂等，重复调用无副作用）。
            consumePendingMenuDetach()
            return
        }
        // 关闭被接受的**同一帧**立即停止菜单交互（不等动画、不等手势结束）：这是缺陷 1 的核心。
        setMenuInteractive(false, "close-accepted:$reason")
        if (!animate) {
            OverlayLog.log("menu.request.close reason=$reason immediate=true")
            transitionMenu(OverlayMenuEvent.forceClose, reason)
            return
        }
        OverlayLog.log("menu.request.close reason=$reason immediate=false")
        transitionMenu(OverlayMenuEvent.requestClose, reason)
    }

    /** 设置页改动主题后立即下发（需求 §13.3：立即预览，不重开菜单）。 */
    fun applyMenuTheme(theme: WheelMenuTheme, reason: String) {
        menuTheme = theme
        menuView?.applyTheme(theme)
        OverlayLog.log("menu.theme.apply id=${theme.themeId} reason=$reason")
    }

    /**
     * 设置页改动**轮盘布局**（尺寸 / 紧凑）后立即生效（Phase 4C-6B-1.1，需求 §5 / §12）。
     *
     * 几何变了就**必须**重算窗口（与主题只换颜色不同），而"菜单打开期间窗口不变"
     * 是 4C-6B-1 的硬约束 —— 因此这里的口径是：
     * * 菜单**关着**：直接保存，下次打开用新尺寸；
     * * 菜单**开着**：立即收起菜单（不重开、不闪），下次点击桌宠即用新尺寸。
     *
     * 需求 §12 建议的"打开期间 180~220ms 几何插值"**本阶段未实现**（见文档 §12.14.12）。
     */
    fun applyMenuLayoutSettings(settings: WheelMenuLayoutSettings, reason: String) {
        val previous = menuSettings
        menuSettings = settings.normalized()
        menuButtonScale = menuSettings.buttonVisualScale
        // 按钮大小只通过 menuSettings 生效（spec 里不再存第二份，避免"设置了不生效"）。
        wheelSpec = WheelMenuSpec.fromDensity(context.resources.displayMetrics.density)
        OverlayLog.log(
            "wheel_layout_settings_updated scale=${previous.preferredScale}→" +
                "${menuSettings.preferredScale} button=${previous.buttonVisualScale}→" +
                "${menuSettings.buttonVisualScale} compact=${menuSettings.compactMode} reason=$reason",
        )
        if (isMenuOpen) {
            closeMenu("layout-settings-changed", animate = false)
        }
        // 轮盘尺寸改变 → 信封尺寸改变 → 纪元帧需要重算（真实几何变化；开菜单时上面已先收敛）。
        if (isAttached) refreshEpoch(petWindowRect(), "menu-layout-settings")
    }

    /**
     * 轮盘条目被确认（点击或滑选松手）。
     *
     * **这里是"菜单"与"业务"的唯一交界**：
     * 导航类（进入子菜单 / 返回 / 关闭）与原生动作由原生即刻执行；
     * Dart 请求走请求通道；只读信息项只在窗口内提示。
     */
    private fun onWheelEntryConfirmed(entry: WheelMenuEntry, index: Int, session: Long) {
        // **第二道校验**（缺陷 1）：必须同时满足"会话未过期 + 允许交互 + 菜单确实打开"。
        // 第一道在触摸入口（WheelMenuView.interactive）；只有两道都过才允许执行菜单动作 ——
        // 这样"关闭之后手指才抬起"的陈旧 UP 不可能触发任何按钮。
        if (!menuSession.canDispatchAction(session, menuState == OverlayMenuState.open)) {
            OverlayLog.warn(
                "menu.action 被拒绝：会话失效或菜单不可交互 session=$session " +
                    "current=${menuSession.sessionId} interactive=${menuSession.interactive} " +
                    "state=${menuState.name} id=${entry.id}",
            )
            return
        }
        val outcome = actions.dispatch(entry.action, entry.id, entry)
        OverlayLog.log(
            "menu.action id=${entry.id} wire=${entry.action.wire} route=${outcome.route.name} " +
                "handled=${outcome.handled} level=$menuLevelName index=$index",
        )
        when (actions.targetLevelOf(entry.action)) {
            null -> when (entry.action) {
                WheelMenuAction.closeMenu -> closeMenu("wheel-action", animate = true)
                WheelMenuAction.back -> Unit
                // 其余：只把高亮与扇区平滑移过去（需求 §10.2），不改窗口、不关闭菜单。
                // 原生动作 / "收起菜单后生效"的 Dart 请求已经把自己那份菜单收掉了
                // （menuView == null）—— 这里自然成为空操作，不需要额外分支。
                else -> menuView?.animateSelectionTo(index)
            }
            else -> enterLayer(entry.action, "wheel-entry:${entry.id}")
        }
    }

    /** 进入子菜单（唯一入口）。 */
    private fun enterLayer(action: WheelMenuAction, reason: String) {
        val target = actions.targetLevelOf(action) ?: return
        val level = WheelMenuCatalog.level(target) ?: return
        val view = menuView ?: return
        if (!view.enterLayer(level)) {
            OverlayLog.warn("menu.enterLayer 被拒绝 level=$target reason=$reason")
            return
        }
        activeLayout = view.currentLayout()
        OverlayLog.log(
            "menu.layer.enter level=$target items=${level.itemCount} " +
                "window=${envelope?.windowRect}（窗口未改动）reason=$reason",
        )
    }

    // ------------------------------------------------------------------
    // 轮盘动作宿主（WheelMenuActionHost）
    // ------------------------------------------------------------------

    /**
     * 导航类动作。
     *
     * 只有 [WheelMenuAction.back] 与 [WheelMenuAction.closeMenu] 需要在这里即时处理；
     * "进入子菜单"由 [onWheelEntryConfirmed] 的 `when` 分支完成（它需要知道被点的条目索引）。
     */
    override fun onNavigateAction(action: WheelMenuAction, entryId: String): Boolean = when (action) {
        WheelMenuAction.back -> {
            exitLayer("nav-back:$entryId")
            true
        }
        WheelMenuAction.closeMenu -> {
            closeMenu("nav-close:$entryId", animate = true)
            true
        }
        else -> false
    }

    /**
     * **原生动作**（Phase 4C-6B-3）：先收起菜单（用户确认的口径："收起菜单后生效"），
     * 再把动作交给服务用自己的既有路径执行（命令通道 / 几何提交 / 通知启动）。
     *
     * 为什么 manager 不自己改 store：位置与缩放的"存"与"取"必须成对出现在服务里
     * （见 [OverlayWindowHost] 的说明），manager 只负责"收起菜单 + 转发 + 反馈"。
     */
    override fun onNativeAction(action: WheelMenuAction, entryId: String): Boolean {
        // 隐藏 / 重置位置 / 改大小 / 打开 PetLife 都会让菜单里的这个动作变得没有意义：
        // 先收起（立即、不等动画），窗口几何随服务那边的既有路径统一重算。
        closeMenu("native:$entryId", animate = false)
        val executed = host.onMenuNativeAction(action.wire, entryId)
        if (!executed) {
            OverlayLog.warn("menu.native 未执行 wire=${action.wire} id=$entryId")
            showMenuFeedback("该操作暂不可用", FeedbackKind.warning)
        }
        return executed
    }

    /**
     * **Dart 请求**（Phase 4C-6B-3）。
     *
     * 尺寸 / 自动状态这类动作按用户口径"收起菜单后生效"；
     * 只读类（今日时长、同步状态…）保持菜单在屏幕上，反馈直接显示在窗口内。
     */
    override fun onDartRequestAction(
        action: WheelMenuAction,
        entryId: String,
        entry: WheelMenuEntry?,
    ): Boolean {
        val label = entry?.labelZh ?: action.wire
        if (MenuActionPlan.closesMenuFirst(action)) {
            closeMenu("dart-request:$entryId", animate = false)
        }
        val requestId = host.onMenuDartRequest(action.wire, entryId)
        if (requestId.isEmpty()) {
            showMenuFeedback("$label：请求未能提交", FeedbackKind.error)
            return false
        }
        showMenuFeedback("$label：处理中…", FeedbackKind.running, requestId)
        return true
    }

    /** 只读信息项：把已经缓存的实时信息交给宿主提示，不改任何状态。 */
    override fun onInfoAction(entryId: String, entry: WheelMenuEntry) {
        val info = runCatching { host.onMenuInfo(entryId) }.getOrNull()
        host.onMenuAction(
            actionWire = WheelMenuAction.showInfo.wire,
            itemId = entryId,
            detail = info ?: entry.labelZh,
        )
    }

    /**
     * 显示一条**窗口内反馈**（Phase 4C-6B-3）。
     *
     * 两条路径：
     * * 窗口内反馈层可用（窗口已附着 + 菜单层还在）→ 画在同一个窗口里，**不改窗口几何**；
     * * 反馈层不可用（菜单已经收起 / 应用刚启动）→ 复用既有 Toast（[OverlayWindowHost.onMenuHint]）。
     */
    internal fun showMenuFeedback(text: String, kind: FeedbackKind, requestId: String? = null) {
        if (dualWindowActive) {
            // 反馈层在**菜单窗**里（它属于菜单 UI）。菜单窗关闭态是 1×1/不可触摸 ⇒ 窗口内反馈看不见，
            // 此时回退既有 Toast（[OverlayWindowHost.onMenuHint]）。
            if (dualMenuWindow?.showFeedback(text, kind, requestId) == true) return
            host.onMenuHint(text)
            return
        }
        val currentView = view
        if (currentView != null && currentView.isAttachedToWindow && currentView.isMenuLayerAttached) {
            currentView.showFeedback(text, kind, requestId)
            return
        }
        host.onMenuHint(text)
    }

    /** 返回上一层（唯一入口）。 */
    private fun exitLayer(reason: String) {
        val view = menuView ?: return
        if (!view.state.canGoBack) {
            OverlayLog.log("menu.layer.exit 忽略：已经在根菜单 reason=$reason")
            return
        }
        if (!view.exitLayer()) {
            OverlayLog.warn("menu.layer.exit 被拒绝 reason=$reason")
            return
        }
        activeLayout = view.currentLayout()
        OverlayLog.log(
            "menu.layer.exit level=${view.levelIdName} " +
                "window=${envelope?.windowRect}（窗口未改动）reason=$reason",
        )
    }

    /** 唯一的菜单状态入口：所有转移都经过 [OverlayMenuStateMachine]。 */
    private fun transitionMenu(event: OverlayMenuEvent, reason: String) {
        val next = OverlayMenuStateMachine.next(menuState, event)
        if (next == menuState && event != OverlayMenuEvent.animationFinished) {
            OverlayLog.log("menu.state 幂等：保持 ${menuState.name}（event=${event.name} reason=$reason）")
            return
        }
        OverlayLog.log("menu.state ${menuState.name} -> ${next.name} event=${event.name} reason=$reason")
        when (next) {
            OverlayMenuState.closed -> enterClosed(reason)
            OverlayMenuState.opening -> enterOpening(reason)
            OverlayMenuState.open -> {
                // 只有"展开动画正常结束"会到这里：窗口已经是扩展状态，什么都不用改。
                menuState = OverlayMenuState.open
            }
            OverlayMenuState.closing -> enterClosing(reason)
        }
    }

    /**
     * 打开菜单：算**一次**信封（窗口 + 中心 + 环带半径）+ 根层级布局，
     * 把菜单挂进**同一个窗口的菜单层**，然后交给轮盘自己播展开动画。
     *
     * Phase 4C-6B-2 修复：窗口几何（稳定场景帧）**在这里完全不改** ——
     * 帧在几何纪元里已经算好（且用的是同一个信封），人物的屏幕矩形**一个像素都不变**。
     */
    // --- Phase 4C-6B-1.2 A3 + 4C-6B-2：**桌宠隐藏机制彻底删除** ---
    //
    // 规则固定为：**人物由本窗口的上层 View 自己绘制**，菜单层在它下方（不再跨窗口、不再挖洞）。
    // 曾经的"菜单前景副本 + 隐藏原桌宠 + 前景首帧回调切换视觉所有权"已全部删除 ——
    // 两次真机都出现"打开菜单后桌宠消失"，根因是这条切换链任何一环失败都会导致两个窗口都不画人物。
    // 现在结构上不可能再发生：`PetOverlayView` 已**不存在**任何可隐藏内容的入口，
    // 而且人物与菜单根本不在两个窗口里。

    /** 桌宠当前是否**能真实显示素材**（仅 `asset` 状态）—— 不能则拒绝打开菜单。 */
    private fun canRenderMenuForeground(): Boolean = view?.visual == OverlayVisual.asset

    /**
     * 强制保证原桌宠可见（所有生命周期/异常路径都收敛到这里）。
     *
     * 正常路径**不写日志**（需求 §20：稳定状态禁止重复刷 INFO）；
     * 只有真的发生"内容被外部改暗"这种不应出现的情况才记一条 ERROR。
     */
    private fun enforcePetAlwaysVisible(reason: String) {
        val corrected = view?.ensureSourceVisible() == true
        if (corrected) {
            OverlayLog.error(
                "检测到桌宠内容被改写（不应发生）reason=$reason → 已强制恢复 " +
                    PetVisualInvariant.diagnosticSegment().trim(),
            )
        }
    }

    /**
     * 打开菜单：复用本纪元已解出的信封（一次求解）+ 根层级布局，把菜单挂进同一个窗口的菜单层，
     * 然后把窗口扩成"人物 ∪ 菜单信封"（一次原子提交），最后交给轮盘播展开动画。
     *
     * 人物的屏幕矩形在这里**一个像素都不改**（窗口原点与人物层偏移反向抵消）。
     */
    private fun enterOpening(reason: String) {
        menuOpenRequested = true
        // 任务约束：人物不可见或素材未就绪（在加载/失败/空/诊断）时**拒绝打开菜单**。
        if (!canRenderMenuForeground()) {
            lastMenuOpenError = "pet-not-visible-or-asset-missing"
            OverlayLog.warn(
                "menu.open 被拒绝：人物当前不可见或素材未就绪 visual=${currentVisual()} reason=$reason",
            )
            menuState = OverlayMenuState.closed
            return
        }
        if (!canTouchWindow()) {
            lastMenuOpenError = "pet-window-not-attached"
            OverlayLog.warn("menu.open 被拒绝：桌宠窗口未附着 reason=$reason")
            menuState = OverlayMenuState.closed
            return
        }
        val petRect = petWindowRect()
        val rootLevel = WheelMenuCatalog.ROOT
        // 信封来源：
        //  * 双窗口：**总是**按桌宠**当前**屏幕矩形重算（绝不使用缓存、更不用首次矩形）；
        //  * 单窗口：复用本纪元已解出的信封（避免二次求解导致位置不一致）。
        val env = if (dualWindowActive) {
            computeMenuEnvelope(petRect)
        } else {
            val cachedEnvelope = epochEnvelope
            if (cachedEnvelope != null && epoch.petScreenRect == petRect) {
                cachedEnvelope
            } else {
                // 防御性：人物在纪元提交后被移动过（所有落定路径都应刷新纪元，这里是最后兜底）。
                OverlayLog.warn(
                    "menu.open 检测到纪元过期（epochPet=${epoch.petScreenRect} current=$petRect）" +
                        "→ 先刷新纪元 reason=$reason",
                )
                refreshEpoch(petRect, "menu-open-epoch-refresh")
                epochEnvelope
            }
        }
        if (env == null || (!dualWindowActive && !epoch.hasMenuEnvelope)) {
            lastMenuOpenError = "geometry-unavailable"
            OverlayLog.warn("menu.open 被拒绝：没有可用菜单信封 reason=$reason")
            menuState = OverlayMenuState.closed
            return
        }
        val layout = try {
            WheelMenuGeometry.layoutFor(env, rootLevel, wheelSpec)
        } catch (t: Throwable) {
            OverlayLog.error("轮盘几何计算异常（菜单不打开）", t)
            lastMenuOpenError = "geometry-unavailable"
            menuState = OverlayMenuState.closed
            return
        }
        // 单窗口：打开态场景 = 人物 ∪ 菜单信封（窗口扩为并集）。双窗口不需要（桌宠窗几何恒定）。
        val openScene = if (dualWindowActive) null else epoch.openLayout()
        if (!dualWindowActive && openScene == null) {
            lastMenuOpenError = "geometry-unavailable"
            OverlayLog.warn("menu.open 被拒绝：纪元缺少菜单层矩形 reason=$reason")
            menuState = OverlayMenuState.closed
            return
        }

        // **新会话**（缺陷 1）：本次打开 = 一个新 sessionId；旧的动画回调 / 触摸 / 延迟任务
        // 从此全部失效，绝不可能再扰动这次的菜单。
        val session = menuSession.beginOpen()
        OverlayLog.log("menu.session.open id=$session reason=$reason")

        // 过渡诊断：记录"进入过渡前"的窗口原点与人物层偏移。
        val windowOriginBefore = params?.let { intArrayOf(it.x, it.y) }
        val petLocalBefore = petLocalRect

        petRectBeforeMenu = petRect
        envelope = env
        activeLayout = layout
        lastDirection = env.direction
        lastVerticalMode = env.verticalMode

        val opened = if (dualWindowActive) {
            // 双窗口：轮盘挂进**固定菜单窗**，一次 updateViewLayout 打开；桌宠窗几何不动。
            openDualWindowMenu(env, layout, session)
        } else {
            // 单窗口：把菜单挂进同一窗口的菜单层（index 0，位于人物层之下）。
            attachMenuLayer(env, layout, openScene!!, session)
        }
        if (!opened) {
            envelope = null
            activeLayout = null
            menuState = OverlayMenuState.closed
            // 打开失败：会话立即收敛为"不可交互"，避免留下一个"能点但不存在"的会话。
            setMenuInteractive(false, "open-failed:$reason")
            return
        }
        // 单窗口：菜单层就位后把窗口扩成"人物 ∪ 菜单信封"（唯一提交点，一次 updateViewLayout）。
        // 双窗口：菜单在自己的窗口里，桌宠窗几何**一个像素都不动**（⇒ 不漂移）。
        if (!dualWindowActive) commitSceneLayout(openScene!!, "menu-open")
        // 过渡几何证据：给出 ΔwindowOrigin / ΔpetLocal（是**证据**，不是"证明没有漂移"）。
        logTransitionDeltas("menu.open", windowOriginBefore, petLocalBefore)
        OverlayLog.log(
            "menu.open dir=${env.direction.labelZh} vmode=${env.verticalMode.labelZh} " +
                "items=${layout.itemCount} scale=${env.preferredScale}→${env.actualScale} " +
                "compact=${env.compact} radius=${layout.ringRadiusPx.toInt()} " +
                "blade=${layout.bladeLengthPx.toInt()} degraded=${env.degraded}" +
                "${env.fallbackReason?.let { " reason=$it" } ?: ""} anchorDist=${env.anchorDistancePx.toInt()} reason=$reason",
        )
        OverlayLog.log(
            "wheel_layout_computed bounds=${bounds.width}x${bounds.height} petScreenRect=$petRect " +
                "petAnchor=(${env.petAnchorX},${env.petAnchorY}) hole=(${env.holeRx.toInt()},${env.holeRy.toInt()}) " +
                "menuScreenRect=${env.windowRect} windowRect=${openScene?.windowRect ?: petRect} " +
                "petScreenRectUnchanged=true（" +
                (if (dualWindowActive) {
                    "双窗口：轮盘在独立菜单窗、桌宠窗几何恒定"
                } else {
                    "单窗口：人物层在菜单层之上；窗口已扩为并集"
                }) + "）",
        )
        menuState = OverlayMenuState.opening
        gesture?.onMenuOpened()
        // 【A2 第二次回归 + 4C-6B-2】不再有任何"前景副本 / 隐藏原桌宠"的切换。
        // 人物由本窗口的上层 View 绘制，菜单层在下方 —— 既不打洞，也不跨窗口。
        // 这里只做一件事：确保人物内容是可见的（防御性，正常路径它一直是可见的）。
        enforcePetAlwaysVisible("menu-open")
        OverlayLog.log(
            "menu.open 视觉规则=单窗口分层（owner=PET_WINDOW, 人物层在菜单层之上, 无挖洞）",
        )
        logMenuScene("menu.open")
        if (dualWindowActive) {
            // 双窗口：**绝不**在这里起动画 —— 必须等**轮盘**真实布局到目标尺寸
            // （由 scheduleDualMenuOpen 注册的一次性 pre-draw / 有界帧回调触发）。
            OverlayLog.log(
                "menu.open.animation.deferred session=$session " +
                    "reason=dual-window-layout-gate（等轮盘布局到目标尺寸后再起动画）",
            )
        } else {
            menuView?.beginOpenAnimation()
        }
        schedulePetPositionSettledDiagnostics("menu.open", petRect)
    }

    /**
     * 打开**双窗口**菜单（拆成两阶段，修复"菜单打开第一帧"缺陷）。
     *
     * 阶段 1（本方法内）：配置轮盘回调 + `wheel.prepareContent(...)`（只配置内容、不起动画）
     * + [DualWindowMenuWindow.prepareOpen] 把菜单窗摆到**最终矩形**，但内容 `INVISIBLE`
     * （参与测量/布局但**不绘制**）、仍 `FLAG_NOT_TOUCHABLE`（这一帧绝不显示、绝不吃输入）。
     * 阶段 2（[scheduleDualMenuOpen] 注册的一次性布局回调）：**轮盘**真实布局到目标尺寸的那一帧，
     * 才显示内容 + 去 NOT_TOUCHABLE + 起展开动画。
     *
     * 关键差异（相对旧实现）：
     * * 旧实现把 `present()` + 改窗口 + 起动画揉在同一帧，且闸门只看宿主窗尺寸 ——
     *   `GONE` 子树不参与测量，所以闸门放行时轮盘可能还是 0×0，动画于是从错误坐标起跑
     *   （真机表现为"菜单先出现在上方再滑下来"）；
     * * 现在准备态用 `INVISIBLE`（轮盘真实参与布局），闸门**只信轮盘自己的测量尺寸**，
     *   动画绝不可能早于"轮盘布局到目标尺寸"那一帧（[MenuOpenSequencer] 是唯一闸门）；
     * * 桌宠窗几何**完全不动** ⇒ 菜单开合与桌宠位置解耦（真机已验证的不漂移行为）；
     * * 所有回调仍**带本次会话号**（会话过期一律忽略，缺陷 1 不回归）。
     */
    private fun openDualWindowMenu(
        env: WheelMenuEnvelope,
        layout: WheelMenuLayout,
        session: Long,
    ): Boolean {
        val menuWindow = dualMenuWindow
        if (menuWindow == null || !menuWindow.isAttached) {
            OverlayLog.warn("dual.menu open 被拒绝：菜单窗未挂载")
            lastMenuOpenError = "menu-window-not-attached"
            return false
        }
        val wheel = menuWindow.wheelView()
        if (wheel == null) {
            lastMenuOpenError = "menu-wheel-unavailable"
            return false
        }
        menuAddViewAttempted = true
        // 所有回调都**携带本次会话号**：旧会话的回调在 manager 侧被直接忽略（缺陷 1）。
        wheel.entryListener = { entry, index -> onWheelEntryConfirmed(entry, index, session) }
        wheel.closeListener = {
            if (menuSession.isCurrent(session)) {
                closeMenu("outside-tap", animate = false)
            } else {
                OverlayLog.warn("menu.close 被忽略：陈旧会话 session=$session")
            }
        }
        wheel.animationListener = { kind -> onWheelAnimationFinished(kind, session) }
        // 双窗口下重叠区触摸归上层桌宠窗；此处保留转发，兜住"菜单窗内、桌宠窗之外"的中央拖动。
        wheel.petDragListener = { x, y, phase ->
            if (menuSession.isCurrent(session) || phase == WheelPetDragPhase.end) {
                onWheelPetDrag(x, y, phase)
            } else {
                OverlayLog.warn("wheel.pet_drag 被忽略：陈旧会话 session=$session")
            }
        }
        wheel.infoProvider = { entry -> host.onMenuInfo(entry.id) }
        wheel.hapticsEnabled = menuHapticsEnabled
        wheel.debugBounds = debugMode
        wheel.debugVerifyFan = false
        // 准备阶段：内容不呈现、菜单不可交互（窗口仍是 NOT_TOUCHABLE）。
        wheel.setInteractive(false, "preparing-layout:$session")
        menuView = wheel
        menuRectInWindow = null

        // 阶段 1a：**配置本次打开的内容**（层级 / 几何 / 主题），但**不起动画**、**不置交互**。
        // 提前配置是必须的：轮盘只有已配置 layout 才会在 onMeasure/onLayout 里被量到目标尺寸，
        // 而后续闸门的达标判据正是"轮盘自己的 measuredWidth/Height == 目标矩形"。
        wheel.prepareContent(
            envelope = env,
            level = WheelMenuCatalog.ROOT,
            layout = layout,
            theme = menuTheme,
            direction = env.direction,
            spec = wheelSpec,
        )
        // 阶段 1b：把菜单窗先摆到最终矩形（内容 INVISIBLE + NOT_TOUCHABLE；只 updateViewLayout）。
        // 用 INVISIBLE（不是 GONE）让轮盘参与测量/布局但**不绘制**、不吃输入。
        val prepared = runCatching { menuWindow.prepareOpen(env.windowRect, session) }.getOrElse { t ->
            OverlayLog.error("dual.menu prepare updateViewLayout 失败", t)
            false
        }
        menuAddViewSucceeded = prepared
        if (!prepared) {
            lastMenuOpenError = "menu-window-prepare-failed"
            return false
        }
        lastMenuOpenError = null
        // 阶段 2：等一次真实布局（尺寸达标 + 会话匹配），达标后才 present + 起动画。
        scheduleDualMenuOpen(menuWindow, wheel, env, layout, session)
        OverlayLog.log(
            "menu.layer.open(dual) menuRect=${env.windowRect} items=${layout.itemCount} " +
                "menuAddCount=${menuWindow.menuAddCount} petWindowUnchanged=true phase=preparing",
        )
        OverlayLog.log("menu.input.evidence tag=open session=$session ${menuInputDiagnostics()}")
        return true
    }

    /**
     * 阶段 2：注册一次性 pre-draw 布局回调 + 有界帧兜底，把"准备布局"与"起动画"彻底分开。
     *
     * * 一次性 pre-draw：布局尺寸达标的那一帧立即完成（**无固定延时**）；
     * * 有界帧兜底：若若干帧后仍未达标 ⇒ [MenuOpenSequencer] 降级，直接显示在最终位置、不播动画；
     * * 会话 / 阶段双重校验：关闭或新一次打开后，旧回调一律惰性。
     */
    private fun scheduleDualMenuOpen(
        menuWindow: DualWindowMenuWindow,
        wheel: WheelMenuView,
        env: WheelMenuEnvelope,
        layout: WheelMenuLayout,
        session: Long,
    ) {
        val rect = env.windowRect
        if (!menuOpenSequencer.beginLayout(session, rect.width, rect.height, env.direction)) {
            // 目标不是真实展开尺寸（退化几何）：绝不用错误尺寸起动画，直接退化到"显示最终位置"。
            // 延后一帧执行，保证在 enterOpening 把 menuState 置为 opening 之后再呈现（并受关闭保护）。
            OverlayLog.warn("menu.open.layout_invalid session=$session rect=$rect（目标非真实展开尺寸）")
            val hostView: View = menuWindow.hostView() ?: wheel
            val degrade = MenuOpenDecision(
                showContent = true,
                clearNotTouchable = true,
                degrade = true,
                reason = MenuOpenSequencer.REASON_LAYOUT_TIMEOUT,
            )
            hostView.postOnAnimation {
                if (menuSession.isCurrent(session) && menuState == OverlayMenuState.opening) {
                    completeDualMenuOpen(menuWindow, wheel, env, layout, session, degrade)
                }
            }
            return
        }
        val hostView: View = menuWindow.hostView() ?: wheel
        startMenuOpenFrameDiagnostics(menuWindow, wheel, env, session)

        val listener = object : ViewTreeObserver.OnPreDrawListener {
            override fun onPreDraw(): Boolean {
                if (!isDualMenuOpenPending(session)) {
                    removePendingPreDraw()
                    return true
                }
                // 达标判据 = **轮盘自己**的测量尺寸（host 尺寸仅诊断）。
                // host（菜单窗根）在窗口移到目标矩形后必然先于轮盘达到目标尺寸，
                // 只看 host 会在轮盘仍 0×0 / 1×1 时误判达标 —— 这正是被修复的缺口。
                val decision = menuOpenSequencer.onPreDraw(
                    hostView.measuredWidth,
                    hostView.measuredHeight,
                    wheel.measuredWidth,
                    wheel.measuredHeight,
                    session,
                )
                if (!decision.isInert) {
                    removePendingPreDraw()
                    completeDualMenuOpen(menuWindow, wheel, env, layout, session, decision)
                }
                return true
            }
        }
        pendingPreDraw = listener
        pendingPreDrawView = hostView
        hostView.viewTreeObserver.addOnPreDrawListener(listener)

        waitMenuOpenLayout(hostView, menuWindow, wheel, env, layout, session)
    }

    /** 有界帧兜底：未达标帧数达到上限时降级（显示在最终位置，不播动画）。 */
    private fun waitMenuOpenLayout(
        hostView: View,
        menuWindow: DualWindowMenuWindow,
        wheel: WheelMenuView,
        env: WheelMenuEnvelope,
        layout: WheelMenuLayout,
        session: Long,
    ) {
        val runnable = object : Runnable {
            override fun run() {
                if (!isDualMenuOpenPending(session)) return
                val decision = menuOpenSequencer.onFrame(
                    hostView.measuredWidth,
                    hostView.measuredHeight,
                    wheel.measuredWidth,
                    wheel.measuredHeight,
                    session,
                )
                if (!decision.isInert) {
                    removePendingPreDraw()
                    completeDualMenuOpen(menuWindow, wheel, env, layout, session, decision)
                    return
                }
                hostView.postOnAnimation(this)
            }
        }
        hostView.postOnAnimation(runnable)
    }

    /**
     * 本次打开的布局回调是否仍然有效（会话 + **窗口布局代次** + 闸门阶段 + 窗口级状态 + 存活性）。
     *
     * 这里除了会话号，还要求菜单窗侧 `pendingOpenSession` 仍是本次打开：
     * [DualWindowMenuWindow.prepareOpen] 会写入、[DualWindowMenuWindow.close] / `remove` 会清零，
     * 因此它等价于"这一次打开对应的那个 layoutGeneration 仍然有效" —— 旧代次的回调
     * 即便侥幸逃过 pre-draw 摘除，也无法在这里通过校验。
     */
    private fun isDualMenuOpenPending(session: Long): Boolean =
        !disposed &&
            menuSession.isCurrent(session) &&
            dualMenuWindow?.pendingOpenSession == session &&
            menuOpenSequencer.phase == MenuOpenPhase.awaitingLayout &&
            (menuState == OverlayMenuState.opening || menuState == OverlayMenuState.open)

    /**
     * 完成一次双窗口打开：**轮盘布局达标后**才显示内容 + 放行输入（第二次 updateViewLayout）、
     * 设最终局部枢轴、起展开动画（恰好一次）；降级路径则直接定格在最终位置、不播动画。
     *
     * 内容（层级 / 几何 / 主题）已在 [openDualWindowMenu] 的准备阶段由 `prepareContent(...)` 配好，
     * 这里**不再**重复配置 —— 健康路径只做"显示 + 枢轴 + 动画"三件事。
     */
    private fun completeDualMenuOpen(
        menuWindow: DualWindowMenuWindow,
        wheel: WheelMenuView,
        env: WheelMenuEnvelope,
        layout: WheelMenuLayout,
        session: Long,
        decision: MenuOpenDecision,
    ) {
        if (disposed || !menuSession.isCurrent(session) || !decision.clearNotTouchable) return
        if (menuState == OverlayMenuState.closed) return
        val animate = decision.startAnimation
        if (!animate) {
            // 降级：直接以"完全展开"帧呈现（显示在最终位置，不播动画）。
            wheel.presentOpened(
                envelope = env,
                level = WheelMenuCatalog.ROOT,
                layout = layout,
                theme = menuTheme,
                direction = env.direction,
                spec = wheelSpec,
            )
        }
        // 先让窗口"可触摸 + 内容可见"（第二次 updateViewLayout），再设枢轴、再起动画。
        val shown = runCatching { menuWindow.presentOpen(session) }.getOrElse { t ->
            OverlayLog.error("dual.menu present updateViewLayout 失败", t)
            false
        }
        if (!shown) {
            lastMenuOpenError = "menu-window-present-failed"
            OverlayLog.warn("menu.open.present 失败 session=$session")
            menuOpenSequencer.cancel(session)
            return
        }
        // 证据：闸门放行依据的是**轮盘自己**的最终测量尺寸（不是宿主窗尺寸）——
        // 这就是 `measured == target` 的通过判据；此处的 content 已是 VISIBLE。
        OverlayLog.log(
            "menu.open.layout_ready session=$session gen=${menuWindow.currentLayoutGeneration} " +
                "measured=${wheel.measuredWidth}x${wheel.measuredHeight} " +
                "target=${env.windowRect.width}x${env.windowRect.height} " +
                "content=${menuWindow.contentVisibilityName()} " +
                "pivotLocal=(${layout.centerX},${layout.centerY}) " +
                "anchorLocal=${MenuOpenCoordinates.toWindowLocal(env.petAnchorX, env.petAnchorY, env.windowRect).joinToString(",")} animate=$animate",
        )
        // 枢轴 = 菜单窗口**局部**坐标（layout.centerX/centerY 已是局部坐标，绝不是屏幕坐标）。
        applyMenuPivot(wheel, layout)
        wheel.setInteractive(menuSession.interactive, "layout-ready:$session")
        if (animate) {
            wheel.beginOpenAnimation()
            OverlayLog.log(
                "menu.open.animation.start session=$session gen=${menuWindow.currentLayoutGeneration} " +
                    "openProgress0=${wheel.openProgressNow}",
            )
        } else {
            // 不播动画 ⇒ 手动把窗口级状态机从 opening 收敛到 open（否则会一直停在 opening）。
            menuState = OverlayMenuState.open
            OverlayLog.warn(
                "menu.open.layout_timeout session=$session gen=${menuWindow.currentLayoutGeneration} " +
                    "target=${env.windowRect}（直接显示在最终位置，不播动画）reason=${decision.reason}",
            )
        }
        logMenuScene("menu.open.presented")
    }

    /** 把菜单窗口局部坐标的中心设为动画枢轴。 */
    private fun applyMenuPivot(wheel: WheelMenuView, layout: WheelMenuLayout) {
        wheel.setAnimationPivot(layout.centerX, layout.centerY)
    }

    /**
     * STEP 1 的有界诊断（≤ [MENU_OPEN_DIAG_FRAMES] 帧）：逐帧记录窗口 / 内容 / 枢轴 / 进度 /
     * 锚点 / 目标矩形 / 布局代次，用于真机判读"第一帧错位"属于哪一类（窗口自身位置 / 内容 /
     * 未测量）。**有界**，绝不持续刷日志。
     *
     * 三态可见性（`contentState`）用于区分两类帧：
     * * `contentState=INVISIBLE` 的**隐藏准备帧**：`contentMeasured` 允许是 0 / 1×1 —— 这时轮盘
     *   尚未量到目标尺寸是**正常**的，**不算视觉失败**；
     * * `contentState=VISIBLE` 的**第一个可见帧**：`contentMeasured` **必须**等于 `targetMenuRect`，
     *   这才是通过判据（闸门放行即记 `menu.open.layout_ready`）。
     */
    private fun startMenuOpenFrameDiagnostics(
        menuWindow: DualWindowMenuWindow,
        wheel: WheelMenuView,
        env: WheelMenuEnvelope,
        session: Long,
    ) {
        val hostView: View = menuWindow.hostView() ?: wheel
        var remaining = MENU_OPEN_DIAG_FRAMES
        val probe = object : Runnable {
            override fun run() {
                if (disposed || !menuSession.isCurrent(session)) return
                remaining -= 1
                val loc = IntArray(2)
                hostView.getLocationOnScreen(loc)
                val measured = "${wheel.measuredWidth}x${wheel.measuredHeight}"
                OverlayLog.log(
                    "menu.open.frame session=$session frame=${MENU_OPEN_DIAG_FRAMES - remaining} " +
                        "gen=${menuWindow.currentLayoutGeneration} " +
                        "menuWindow=${menuWindow.layoutParamsText()} " +
                        "windowScreen=(${loc[0]},${loc[1]}) " +
                        "contentState=${menuWindow.contentVisibilityName()} " +
                        "contentMeasured=$measured contentLeftTop=(${wheel.left},${wheel.top}) " +
                        "contentTrans=(${wheel.translationX},${wheel.translationY}) " +
                        "pivot=(${wheel.animationPivotX},${wheel.animationPivotY}) " +
                        "openProgress=${wheel.openProgressNow} " +
                        "menuAnchorPetRect=${petRectBeforeMenu ?: "none"} targetMenuRect=${env.windowRect} " +
                        "contentBounds=(${loc[0]},${loc[1]} $measured) " +
                        "phase=${menuOpenSequencer.phase.name}",
                )
                if (remaining > 0) hostView.postOnAnimation(this)
            }
        }
        hostView.postOnAnimation(probe)
    }

    /**
     * 双窗口：菜单开着时按桌宠**当前**屏幕矩形重算并跟随菜单窗（一次 `updateViewLayout`）。
     *
     * 调用时机：开菜单后桌宠被拖动 / 贴边 / 旋转 / 分屏（即所有"真实几何变化"路径）。
     * **绝不**使用缓存的首次桌宠矩形，也**绝不**因此改变桌宠窗几何。
     */
    private fun syncDualMenuWindow(reason: String) {
        if (!dualWindowActive) return
        val menuWindow = dualMenuWindow ?: return
        if (!menuWindow.isOpen) return
        val petRect = petWindowRect()
        val env = computeMenuEnvelope(petRect)
        if (env == null) {
            OverlayLog.warn("dual.menu follow 跳过：信封不可用 reason=$reason pet=$petRect")
            return
        }
        envelope = env
        lastDirection = env.direction
        lastVerticalMode = env.verticalMode
        menuWindow.follow(env.windowRect)
        OverlayLog.log("dual.menu follow reason=$reason rect=${env.windowRect} pet=$petRect")
    }

    private fun enterClosing(reason: String) {
        menuState = OverlayMenuState.closing
        // 关闭一旦被接受：**同一帧**立即停止菜单交互（幂等，closeMenu 已经置过一次）。
        setMenuInteractive(false, "closing:$reason")
        OverlayLog.log("menu.close.accepted reason=$reason ${menuInputDiagnostics()}")
        // 转发拖动进行中：菜单本就处于"抑制绘制"状态，**不播收起动画**（播了也看不见），
        // 直接等拖动的终止事件完成摘层 + 缩窗（缺陷 1：延迟闸门一定有释放路径）。
        if (detachDeferral.isForwardedDragActive) {
            OverlayLog.log("menu.animation.skip close（转发拖动进行中，等终止事件收尾）reason=$reason")
            return
        }
        menuView?.startCloseAnimation()
        OverlayLog.log("menu.animation.start close reason=$reason")
    }

    /**
     * 关闭菜单（唯一的收敛点，单窗口分层方案）。顺序：
     * 1. 定格轮盘动画（收敛到确定状态，绝不卡在中间帧）；
     * 2. **摘掉菜单层并把窗口缩回人物矩形**（缺陷 1 修复；同一处、原子提交、走同一个延迟闸门）；
     * 3. 状态切到 closed；下一帧核对人物位置完全没动。
     */
    private fun enterClosed(reason: String) {
        val wasOpen = menuState.occupiesWindow
        val beforePet = petRectBeforeMenu
        // 收敛到确定状态：交互立即失效，且菜单层必须在本次调用内被摘掉 / 缩窗（幂等）。
        setMenuInteractive(false, "closed:$reason")
        menuView?.freeze()
        closeMenuScene("closed:$reason")
        envelope = null
        activeLayout = null
        petRectBeforeMenu = null
        menuState = OverlayMenuState.closed
        gesture?.onMenuClosed()
        OverlayLog.log(
            "menu.close reason=$reason wasOpen=$wasOpen menuLayerAttached=${view?.isMenuLayerAttached == true} " +
                "petScreenRectUnchanged=true",
        )
        OverlayLog.log("menu.input.evidence tag=close:$reason ${menuInputDiagnostics()}")
        if (debugMode && wasOpen) {
            OverlayLog.log(menuPerformanceSummary())
        }
        beforePet?.let { schedulePetPositionSettledDiagnostics("menu.close:$reason", it) }
    }

    /**
     * 几何变化（旋转/分屏/改大小/换素材）与 detach：定格动画并**摘掉菜单层**。
     *
     * 只摘菜单层、**不动窗口几何** —— 真正的窗口几何重算随后由
     * [applyPetWindowGeometry] → [commitSceneLayout]（菜单关闭态 = 人物矩形）统一完成，
     * 避免"先缩到旧人物矩形、再改到新人物矩形"的多余一步。
     */
    private fun resetMenuForGeometryChange(reason: String) {
        if (menuState == OverlayMenuState.closed && menuView == null) return
        setMenuInteractive(false, "geometry-change:$reason")
        menuView?.freeze()
        if (dualWindowActive) {
            // 双窗口：几何变化把菜单窗收敛到关闭态（一次 updateViewLayout），不摘层、不改桌宠窗几何。
            dualMenuWindow?.close()
            menuView = null
            menuRectInWindow = null
        } else {
            detachMenuLayerOnly("geometry-change:$reason")
        }
        envelope = null
        activeLayout = null
        petRectBeforeMenu = null
        menuState = OverlayMenuState.closed
        gesture?.onMenuClosed()
        OverlayLog.log("menu.configuration_changed reason=$reason（菜单层已摘掉，窗口几何随后统一重算）")
    }

    /**
     * 轮盘一次动画播完（带会话号，缺陷 1）。
     *
     * 只有**展开**与**收起**需要同步窗口级状态机；选项切换与换层是纯内部动画。
     * 会话过期或菜单已收敛到 closed 时，陈旧回调一律忽略 —— 绝不恢复交互或改回几何。
     */
    private fun onWheelAnimationFinished(kind: WheelAnimationKind, session: Long) {
        if (!MenuCallbackPolicy.shouldApplyAnimationFinished(
                session = session,
                currentSession = menuSession.sessionId,
                state = menuState,
            )
        ) {
            OverlayLog.warn(
                "menu.animation.end 被忽略（陈旧会话或已关闭）kind=${kind.name} " +
                    "session=$session current=${menuSession.sessionId} state=${menuState.name}",
            )
            return
        }
        OverlayLog.log("menu.animation.end kind=${kind.name} ${menuSummary()}")
        when (kind) {
            WheelAnimationKind.open ->
                transitionMenu(OverlayMenuEvent.animationFinished, "open-animation-end")
            WheelAnimationKind.close ->
                transitionMenu(OverlayMenuEvent.animationFinished, "close-animation-end")
            else -> Unit
        }
    }

    /**
     * 中央人物区域的拖动（由 [WheelMenuView] 转发，需求 §3 / §4 / §13）。
     *
     * 为什么仍然转发：单窗口分层后人物层在菜单层**之上**，但人物层（`petContent`）
     * 不可点击 ⇒ 事件在它上面不被消费，会继续下发到菜单层 ——
     * 不转发就"看得见人物却拖不动"。
     *
     * 口径（需求 §13）：拖动期间**不显示轮盘**；拖动结束**关闭菜单**不自动重开；
     * 由既有的贴边 + 落盘链路收尾（复用 4C-3A 已验证的逻辑，不写第二套）。
     */
    private fun onWheelPetDrag(x: Float, y: Float, phase: WheelPetDragPhase) {
        when (phase) {
            WheelPetDragPhase.start -> {
                // 转发拖动开始：锁定一个"转发专用"指针 id（菜单层不转发原生 pointer id），
                // 记录抓取偏移；同时打开"延迟摘菜单层"的闸门（缺陷 2-5）。
                detachDeferral.beginForwardedDrag()
                beginDragTracking(FORWARDED_POINTER_ID, x, y, "menu-layer")
                dragTraceStart("menu-layer")
                // 拖动时人物必须可见（它由原窗口自绘，这里只是兜底保证）。
                enforcePetAlwaysVisible("pet-drag")
                OverlayLog.log(
                    "wheel.pet_drag.start touch=(${x.toInt()},${y.toInt()}) " +
                        "grab=(${dragTracker.grabOffsetX.toInt()},${dragTracker.grabOffsetY.toInt()})" +
                        "（轮盘已隐藏，位移转发给桌宠窗口）",
                )
            }

            WheelPetDragPhase.move -> {
                recordFinger(x, y)
                applyDragTarget("wheel-forward")
            }

            WheelPetDragPhase.end -> {
                recordFinger(x, y)
                // 用最后手指位置落一次，再结束跟踪；随后放行"延迟摘菜单层 + 缩窗"，最后收菜单 + 贴边 + 落盘。
                applyDragTarget("wheel-forward-end")
                endDragTracking()
                OverlayLog.log("wheel.pet_drag.end ${positionSummary()}")
                flushDragTrace("up(forwarded)")
                detachDeferral.endForwardedDrag()
                cancelForwardedDragFallback()
                // 手势已结束：先收菜单（立即、不重开；此刻会**一次性**摘菜单层 + 把窗口缩回人物矩形），
                // 再走既有的贴边 + 落盘。缩窗在贴边之前完成，因此落盘/吸附都基于"窗口 == 人物矩形"。
                closeMenu("wheel-pet-drag-end", animate = false)
                consumePendingMenuDetach()
                finishDrag()
            }
        }
    }

    /**
     * 消费"转发拖动期间被挂起"的菜单摘除请求（最多一次）。
     *
     * 手势结束后一次性完成"摘菜单层 + 窗口缩回人物矩形"（两件事共用一个延迟闸门）。
     * 这是关闭**终结**的正常路径；异常路径由 [scheduleForwardedDragFallback] 兜底。
     */
    private fun consumePendingMenuDetach() {
        cancelForwardedDragFallback()
        if (!detachDeferral.hasPending) return
        val reason = detachDeferral.consumePendingDetach() ?: return
        OverlayLog.log("menu.layer.detach 消费挂起请求 reason=$reason")
        closeMenuScene("deferred:$reason")
    }

    // -----------------------------------------------------------------------
    // 缺陷 1：延迟摘层闸门的**有界兜底**
    // -----------------------------------------------------------------------
    //
    // 正常释放路径是"转发拖动的终止事件"（见 WheelMenuView.endPetDragForwarding）。
    // 但真机上终止事件可能因外力缺失（转发链被打断、触摸流被系统吞掉、服务被冻结等），
    // 一旦缺失，闸门永久挂起 → 菜单看不见却继续吞触摸、隐藏按钮还能点亮。
    // 这里用一个**一次性**延迟任务兜底：超时后无条件释放闸门并把菜单关闭收敛到终结态。
    // 它只在"关闭期间存在挂起摘层"时被排一次，正常路径会被 `cancelForwardedDragFallback` 取消，
    // 因此绝不会持续刷屏。

    /** 排一次兜底（幂等：同一时间只排一个）。 */
    private fun scheduleForwardedDragFallback(reason: String) {
        if (deferralFallbackScheduled) return
        val currentView = view ?: return
        deferralFallbackScheduled = true
        OverlayLog.warn(
            "menu.deferral.fallback 排程 reason=$reason 等待转发拖动终止事件 " +
                "（超时 ${DEFERRAL_FALLBACK_MS}ms 未到则强制释放）",
        )
        currentView.postDelayed(forwardedDragFallback, DEFERRAL_FALLBACK_MS)
    }

    /** 取消兜底（正常释放 / 窗口移除时调用）。 */
    private fun cancelForwardedDragFallback() {
        if (!deferralFallbackScheduled) return
        deferralFallbackScheduled = false
        view?.removeCallbacks(forwardedDragFallback)
    }

    private val forwardedDragFallback = Runnable {
        deferralFallbackScheduled = false
        if (!detachDeferral.isForwardedDragActive && !detachDeferral.hasPending) return@Runnable
        val reason = detachDeferral.forceRelease()
        OverlayLog.warn(
            "menu.deferral.fallback 触发：终止事件缺失 → 强制释放（reason=$reason）" +
                " ${menuInputDiagnostics()}",
        )
        // 关闭必须是终结的：若菜单已不在打开态（close 已被接受），这里把摘层 + 缩窗补完（恰好一次）。
        if (menuState != OverlayMenuState.open) {
            closeMenuScene("fallback-released:${reason ?: "unknown"}")
        }
    }

    /**
     * 提交**人物**的几何（位置 + 尺寸）：按**菜单关闭态**求布局（窗口 == 人物矩形，无 padding），
     * 原子提交（一次 updateViewLayout）。
     *
     * 只用于"人物本来就该移动"的场景（旋转 / 改大小 / 换素材 / 位置恢复），且**只在菜单关闭时**
     * 调用（`applySettings` 会先 `resetMenuForGeometryChange`）。
     */
    private fun applyPetWindowGeometry(
        left: Int,
        top: Int,
        size: OverlaySize,
        tag: String,
    ): Boolean {
        requireMainThread("applyPetWindowGeometry")
        if (view == null || params == null) return false
        if (!canTouchWindow()) {
            OverlayLog.warn("$tag 被拒绝：窗口未附着或实例已失效（窗口保持不动）")
            return false
        }
        // 人物屏幕矩形 → **重算几何纪元**（关态窗口 == 人物矩形），一次原子提交。
        refreshEpoch(
            OverlayRect(left, top, left + size.width, top + size.height),
            tag,
        )
        return true
    }

    /**
     * 下一帧诊断：读取**真实**的人物内容层在屏幕上的位置，核对"人物绝对没动"。
     *
     * 单窗口方案下，窗口矩形会随菜单开/关扩大，因此**不能**再用根 View 的位置当依据，
     * 必须直接用 `petContent.getLocationOnScreen()`（它天然包含"容器内偏移"）。
     * 这条恒应为 `delta=(0,0)`；出现非 0 就是真机上有位移的直接证据。
     */
    private fun schedulePetPositionSettledDiagnostics(tag: String, beforePet: OverlayRect) {
        val currentView = view ?: return
        currentView.postOnAnimation {
            if (disposed) return@postOnAnimation
            val rootLocation = IntArray(2)
            currentView.getLocationOnScreen(rootLocation)
            val petContentLocation = currentView.petContentLocationOnScreen()
            val petContentSize = currentView.petContentSize()
            val p = params
            val dx = petContentLocation[0] - beforePet.left
            val dy = petContentLocation[1] - beforePet.top
            val settled = kotlin.math.abs(dx) <= 1 && kotlin.math.abs(dy) <= 1
            val message =
                "menu.geometry.settled tag=$tag rootLoc=(${rootLocation[0]},${rootLocation[1]}) " +
                    "petContentLoc=(${petContentLocation[0]},${petContentLocation[1]}) " +
                    "root=${currentView.width}x${currentView.height} " +
                    "petContent=${petContentSize[0]}x${petContentSize[1]} " +
                    "sceneWindowLp=(${p?.x},${p?.y} ${p?.width}x${p?.height}) " +
                    "petLayerOffset=(${petLayerOffset[0]},${petLayerOffset[1]}) " +
                    "menuLayer=" +
                    (menuScreenRect()?.let { "(${it.left},${it.top} ${it.width}x${it.height})" }
                        ?: "none") + " " +
                    "beforePetWindow=(${beforePet.left},${beforePet.top}) " +
                    "delta=($dx,$dy) attached=${currentView.isAttachedToWindow}"
            if (settled) {
                OverlayLog.log(message)
            } else {
                OverlayLog.warn("$message —— 下一帧人物绝对位置与提交前不一致（>1px）")
            }
            host.onGeometrySettled(tag, dx, dy, settled)
        }
    }

    // -----------------------------------------------------------------------
    // 菜单层（单窗口分层方案，Phase 4C-6B-2）
    // -----------------------------------------------------------------------

    /**
     * 把菜单 View 挂进**同一个窗口**的菜单层（最多一层）。
     *
     * 本函数只负责"挂菜单层 + 记录状态"：菜单层用打开态布局 [openScene] 里的**容器内矩形**
     * 定位；窗口几何（扩成 人物 ∪ 菜单 的并集）由紧随其后的 [commitSceneLayout] **原子**提交。
     */
    private fun attachMenuLayer(
        envelope: WheelMenuEnvelope,
        layout: WheelMenuLayout,
        openScene: OverlaySceneLayout,
        session: Long,
    ): Boolean {
        val menuRect = envelope.windowRect
        val menuInWindow = openScene.menuRectInWindow
        val currentView = view
        if (!menuRect.isUsable || menuInWindow == null) {
            OverlayLog.warn("menu.layer.open 跳过：没有可用的轮盘窗口矩形")
            return false
        }
        if (currentView == null || params == null || !canTouchWindow()) {
            OverlayLog.warn("menu.layer.open 被拒绝：窗口未附着或实例已失效")
            return false
        }
        // 保证"最多一层菜单"：把可能残留的旧菜单层从容器里摘掉。
        currentView.detachMenuLayer()
        menuView = null
        menuRectInWindow = null

        val created = WheelMenuView(context).apply {
            // 所有回调都**携带本次会话号**：旧会话的回调在 manager 侧被直接忽略（缺陷 1）。
            entryListener = { entry, index -> onWheelEntryConfirmed(entry, index, session) }
            // 落在环带之外的按下 + 松手 = 外部点击 → 关闭菜单（需求 §5）。
            closeListener = {
                if (menuSession.isCurrent(session)) {
                    closeMenu("outside-tap", animate = false)
                } else {
                    OverlayLog.warn("menu.close 被忽略：陈旧会话 session=$session current=${menuSession.sessionId}")
                }
            }
            animationListener = { kind -> onWheelAnimationFinished(kind, session) }
            // 单窗口分层后人物层在菜单层**之上**，但触摸仍会被本层先收到
            // （人物层 `petContent` 不可点击 ⇒ 事件在该层不被消费，会继续下发给菜单层），
            // 因此"按在人物上拖动人物"仍由这里**主动转发**（保留既有行为，不产生回归）。
            petDragListener = { x, y, phase ->
                // 拖动终止（end）必须放行：它承担释放"延迟摘层"闸门的职责（缺陷 1）；
                // 起 / 移只有在会话仍是当前会话时才转发。
                if (menuSession.isCurrent(session) || phase == WheelPetDragPhase.end) {
                    onWheelPetDrag(x, y, phase)
                } else {
                    OverlayLog.warn("wheel.pet_drag 被忽略：陈旧会话 session=$session")
                }
            }
            infoProvider = { entry -> host.onMenuInfo(entry.id) }
            hapticsEnabled = menuHapticsEnabled
            debugBounds = debugMode
            // 架构验证扇区**已关闭**（默认 false）：验证阶段结束，交付版本不再画黄色大扇区。
            debugVerifyFan = false
            prepareContent(
                envelope = envelope,
                level = WheelMenuCatalog.ROOT,
                layout = layout,
                theme = menuTheme,
                direction = envelope.direction,
                spec = wheelSpec,
            )
            // 交互门控：以 manager 的会话为权威（本会话刚 beginOpen，interactive=true）。
            setInteractive(menuSession.interactive, "attach-session:$session")
        }

        menuAddViewAttempted = true
        // 只做一件事：挂菜单层（用打开态布局里的**容器内矩形**定位）。
        // **不改窗口、不改人物偏移、不 updateViewLayout** —— 窗口几何在整个纪元内恒定。
        currentView.attachMenuLayer(created, menuInWindow)
        menuRectInWindow = menuInWindow
        menuView = created
        // 纪元记账：菜单层已挂载（**不改 commitCount**，因此"开菜单不改窗口几何"可被单测打靶）。
        epoch.markMenuLayerAttached()

        menuAddViewSucceeded = currentView.isMenuLayerAttached
        lastMenuOpenError = if (menuAddViewSucceeded) null else lastWindowError
        OverlayLog.log(
            "menu.layer.open menuRect=(${menuRect.left},${menuRect.top} " +
                "${menuRect.width}x${menuRect.height}) items=${layout.itemCount} " +
                "windowRect=(${openScene.windowRect.left},${openScene.windowRect.top} " +
                "${openScene.windowRect.width}x${openScene.windowRect.height}) " +
                "menuInWindow=(${menuInWindow.left},${menuInWindow.top} " +
                "${menuInWindow.width}x${menuInWindow.height}) " +
                "petLocalRect=${openScene.petRectInWindow} " +
                "petScreenRect=(${openScene.petScreenRect.left},${openScene.petScreenRect.top} " +
                "${openScene.petScreenRect.width}x${openScene.petScreenRect.height})（窗口几何未变）",
        )
        // 下一帧核对"菜单层真的挂上去了"（不再是 addView，但仍要确认附着状态）。
        created.postOnAnimation {
            if (disposed || menuView !== created || !menuSession.isCurrent(session)) return@postOnAnimation
            if (!created.isAttachedToWindow) {
                lastMenuOpenError = "menu-layer-not-attached"
                OverlayLog.error("menu.layer.attach 后下一帧仍未附着 ${menuOpenDiagnostics()}")
            } else {
                OverlayLog.log("menu.layer.attached ${menuOpenDiagnostics()}")
            }
        }
        // 打开事件型的"输入区证据"（一次，不逐帧）。
        OverlayLog.log("menu.input.evidence tag=open session=$session ${menuInputDiagnostics()}")
        // 有界逐帧探针：真机日志据此证明"人物绘制位置在开菜单期间没有动"。
        traceTransitionFrames("menu.open")
        return true
    }

    /**
     * 只摘掉菜单层（幂等，**不改窗口几何**），并走"转发拖动延迟闸门"。
     *
     * 用于几何纪元（旋转/分屏/改大小/换素材）：窗口几何随后由一次 [refreshEpoch] 统一重算，
     * 这里只把菜单层清掉。
     *
     * @return true = 已摘下（或本来就没有）；false = 被挂起（转发拖动进行中，稍后消费）。
     */
    private fun detachMenuLayerOnly(reason: String): Boolean {
        if (dualWindowActive) {
            // 双窗口没有"同一窗口内的菜单层"：等价操作是把菜单窗收敛到关闭态（一次 updateViewLayout）。
            dualMenuWindow?.close()
            cancelForwardedDragFallback()
            detachDeferral.reset()
            menuView = null
            menuRectInWindow = null
            return true
        }
        if (!detachDeferral.requestDetach(reason)) {
            OverlayLog.log("menu.layer.detach 被挂起 reason=$reason（转发拖动进行中，手势结束后再摘）")
            // 有界兜底：确保即使终止事件缺失，闸门也一定会被释放（缺陷 1）。
            scheduleForwardedDragFallback(reason)
            return false
        }
        cancelForwardedDragFallback()
        val currentView = view
        val hadMenu = menuView != null || menuRectInWindow != null ||
            currentView?.isMenuLayerAttached == true
        if (hadMenu) {
            currentView?.detachMenuLayer()
            menuView = null
            menuRectInWindow = null
            // 纪元记账：摘层**恰好一次**（重复调用返回 false，绝不"摘两次"）。
            OverlayLog.log("menu.layer.detach 完成 reason=$reason applied=${epoch.markMenuLayerDetached()}")
        }
        return true
    }

    /**
     * 关闭菜单层：摘掉菜单层，并把窗口**缩回人物矩形**（零 padding），一次原子提交。
     *
     * 【为什么必须缩窗】平台没有公开的"局部可触摸区域"API（`ViewTreeObserver.*InternalInsets*`
     * 是 AOSP `@hide`，本项目 android.jar（compileSdk 35/36/37）里不存在；反射被规则禁止）。
     * 大窗口内的透明 padding 仍会消费触摸，`onTouchEvent` 返回 `false` 不会把事件派发给下层窗口
     * （`FLAG_NOT_TOUCH_MODAL` 只放开窗口**之外**的触摸）。因此关菜单时窗口**必须**缩回人物矩形，
     * 否则会在人物周围留下一圈永久触摸遮挡。
     *
     * "摘菜单层 + 缩窗"与**转发拖动延迟**共用一个闸门：转发拖动进行中不摘（否则菜单 View 从
     * 窗口树消失会让系统补 ACTION_CANCEL 打断拖动）；手势结束后由 [consumePendingMenuDetach] 执行。
     */
    private fun closeMenuScene(reason: String) {
        if (dualWindowActive) {
            // 双窗口：关闭 = **一次 updateViewLayout**（加 NOT_TOUCHABLE + 1×1 + 安全角落 + 内容 GONE）。
            // 与单窗口不同：这里没有"同一窗口内的菜单层"要摘，因此**不经过延迟闸门** ——
            // 关闭必须立刻终结，绝不允许"挂起的转发拖动"把菜单窗留在可触摸状态（任务硬约束）。
            menuView?.freeze()
            dualMenuWindow?.close()
            cancelForwardedDragFallback()
            detachDeferral.reset()
            menuView = null
            menuRectInWindow = null
            enforcePetAlwaysVisible("close-menu-scene(dual):$reason")
            logMenuScene("menu.close(dual):$reason")
            OverlayLog.log("menu.input.evidence tag=close-scene(dual):$reason ${menuInputDiagnostics()}")
            return
        }
        // 缺陷 2-5：转发拖动进行中**不摘菜单层、不缩窗**（等手势结束统一处理）。
        if (!detachDeferral.requestDetach(reason)) {
            OverlayLog.log("menu.layer.detach 被挂起 reason=$reason（转发拖动进行中，手势结束后再摘）")
            // 有界兜底：终止事件缺失时也要保证关闭终结（缺陷 1）。
            scheduleForwardedDragFallback(reason)
            return
        }
        cancelForwardedDragFallback()
        val currentView = view
        val hadMenu = menuView != null || menuRectInWindow != null ||
            currentView?.isMenuLayerAttached == true
        // 过渡诊断：记录"进入过渡前"的窗口原点与人物层偏移（关菜单**会**改变它们，作为 Δ 证据）。
        val windowOriginBefore = params?.let { intArrayOf(it.x, it.y) }
        val petLocalBefore = petLocalRect
        if (hadMenu) {
            currentView?.detachMenuLayer()
            menuView = null
            menuRectInWindow = null
            // 纪元记账：摘层**恰好一次**（重复调用返回 false，绝不"摘两次"）。
            val detached = epoch.markMenuLayerDetached()
            OverlayLog.log(
                "menu.layer.detach reason=$reason applied=$detached sceneFrame=$sceneFrame " +
                    "petLocalRect=$petLocalRect petScreenRect=${petWindowRect()}",
            )
        }
        // **缩窗**：窗口缩回人物矩形。按**最新**人物屏幕位置算（转发拖动期间人物可能已移动）。
        // 唯一提交点，一次 updateViewLayout；若窗口本就是人物矩形则内部 no-op（幂等）。
        if (isAttached) {
            commitSceneLayout(OverlaySceneSolver.petOnly(petWindowRect()), "menu-close")
        }
        enforcePetAlwaysVisible("close-menu-scene:$reason")
        // 过渡几何证据：给出 ΔwindowOrigin / ΔpetLocal（是**证据**，不是"证明没有漂移"）。
        logTransitionDeltas("menu.close", windowOriginBefore, petLocalBefore)
        logMenuScene("menu.close:$reason")
        OverlayLog.log("menu.input.evidence tag=close-scene:$reason ${menuInputDiagnostics()}")
        // 有界逐帧探针：记录关菜单过渡期间人物**绘制**位置（真机据此判断有无漂移）。
        traceTransitionFrames("menu.close")
    }

    /**
     * 菜单开/关各记**一条**（有界）场景诊断：窗口矩形、人物层容器内矩形、菜单层容器内矩形、
     * 菜单层是否挂载。取代了旧的 `touchableRegion` 日志（那套隐藏 API 已整体删除）。
     */
    private fun logMenuScene(tag: String) {
        val p = params
        val windowRect = p?.let { OverlayRect(it.x, it.y, it.x + it.width, it.y + it.height) }
        OverlayLog.log(
            "menu.scene tag=$tag " +
                "windowRect=" +
                (windowRect?.let { "(${it.left},${it.top} ${it.width}x${it.height})" } ?: "none") +
                " petLocalRect=${petLocalRect ?: "none"} " +
                "menuLocalRect=${menuRectInWindow ?: "none"} " +
                "menuLayerAttached=${view?.isMenuLayerAttached == true}",
        )
    }

    /**
     * 开/关菜单过渡期的**有界**逐帧探针（最多 [TRANSITION_TRACE_FRAMES] 帧，每帧一条 `menu.trace`）。
     *
     * 目的：给真机日志留下"人物**绘制**位置在过渡中是否移动"的**证据**。
     * 每行给出：窗口矩形（`windowRect`）、人物层在容器内的矩形（`petLocalRect`）、
     * `petScreenComputed = 窗口原点 + 人物层偏移`、`petLayerTraceSegment()` 里 `getLocationOnScreen`
     * 的**真实** `petScreen`（含根/人物层的 `translationX/Y` 与 `scaleX/Y`）、几何提交计数（`commit`）、
     * 动画阶段（`anim`）、以及 `mixedFrame`（= 计算位置 != 真实位置）。
     *
     * 注意口径：`mixedFrame` 只是**待真机判读的证据**，**不是**"混合帧已被真机确认"的结论
     * （JVM 单测无法证明平台帧时序）。"有界"意味着最多 12 帧后自动停止，绝不持续刷日志。
     */
    private fun traceTransitionFrames(tag: String) {
        val currentView = view ?: return
        var remaining = TRANSITION_TRACE_FRAMES
        val probe = object : Runnable {
            override fun run() {
                if (disposed) return
                remaining -= 1
                val lp = params
                val lpText = lp?.let { "(${it.x},${it.y} ${it.width}x${it.height})" } ?: "none"
                val local = petLocalRect
                val computed = if (lp != null && local != null) {
                    OverlayRect(
                        left = lp.x + local.left,
                        top = lp.y + local.top,
                        right = lp.x + local.left + local.width,
                        bottom = lp.y + local.top + local.height,
                    )
                } else {
                    null
                }
                val real = currentView.petContentLocationOnScreen()
                // mixedFrame：计算位置与真实位置不一致 —— 即"过渡中人物被画到别的坐标"的直接证据。
                val mixed = computed == null || real[0] != computed.left || real[1] != computed.top
                OverlayLog.log(
                    "menu.trace tag=$tag frame=${TRANSITION_TRACE_FRAMES - remaining} " +
                        "windowRect=$lpText petLocalRect=${local ?: "none"} " +
                        "petScreenComputed=${computed ?: "none"} " +
                        currentView.petLayerTraceSegment() +
                        " commit=${epoch.commitCount} anim=$menuAnimationName" +
                        " mixedFrame=${if (mixed) 1 else 0}" +
                        " menuLayerAttached=${currentView.isMenuLayerAttached}" +
                        " menuState=${menuState.name}",
                )
                if (remaining > 0) currentView.postOnAnimation(this)
            }
        }
        currentView.postOnAnimation(probe)
    }

    /**
     * 过渡几何证据（每次开/关各一条）：`ΔwindowOrigin`、`ΔpetLocal` 与人物屏幕不变式。
     *
     * 口径：`petScreen = windowOrigin + petLocal`。开/关菜单**会**改变窗口原点（并集 ↔ 人物矩形），
     * 只要人物层偏移与之**反向抵消**（`dwx + dlx == 0`），人物屏幕矩形就不变。
     * `dWindowOrigin` / `dPetLocal` 是**留待真机判读的证据**；`petScreenStable` 只表示"提交前后
     * 由公式算出的位置一致"，**不构成**"过渡中没有抽动"的证明（平台帧时序只能真机观测）。
     */
    private fun logTransitionDeltas(tag: String, beforeOrigin: IntArray?, beforeLocal: OverlayRect?) {
        val p = params
        val dwx = if (p != null && beforeOrigin != null) p.x - beforeOrigin[0] else 0
        val dwy = if (p != null && beforeOrigin != null) p.y - beforeOrigin[1] else 0
        val dlx = if (beforeLocal != null && petLocalRect != null) petLocalRect!!.left - beforeLocal.left else 0
        val dly = if (beforeLocal != null && petLocalRect != null) petLocalRect!!.top - beforeLocal.top else 0
        OverlayLog.log(
            "menu.geometry.delta tag=$tag dWindowOrigin=($dwx,$dwy) dPetLocal=($dlx,$dly) " +
                "predictedDrift=(${-dwx},${-dwy}) petScreenStable=${dwx + dlx == 0 && dwy + dly == 0} " +
                "commit=${epoch.commitCount}",
        )
    }

    /** 窗口是否可安全操作（未销毁 + 已附着）。 */
    private fun canTouchWindow(): Boolean = canUpdateMenuWindow(disposed, isAttachedToWindow)

    // -----------------------------------------------------------------------
    // 几何
    // -----------------------------------------------------------------------

    /**
     * 计算窗口尺寸：**按素材宽高比**分配，不拉伸变形。
     *
     * 诊断模式固定正方形（4C-2 的排障入口，必须保持"完全不依赖素材"）。
     */
    private fun computeSize(store: PetOverlayStore, density: Float): OverlaySize {
        if (store.debugOverlayMode) {
            val square = OverlayGeometry.debugSizePx(density, screenSize()[0], screenSize()[1])
            return OverlaySize(square, square)
        }
        return OverlayPetSize.resolve(
            scale = store.scale,
            density = density,
            aspectRatio = view?.drawableAspectRatio ?: 1f,
            bounds = bounds,
        )
    }

    /**
     * 计算左上角坐标。
     *
     * 优先级：
     * 1. 诊断模式 → 固定位置（不恢复历史坐标）；
     * 2. 已吸附到左/右边 → **按边对齐**（这样"贴在右侧时改大小不会向屏幕外扩张"）；
     * 3. 否则 → 用持久化的相对比例换算；
     * 4. 最后统一做边界修正。
     */
    private fun computeTopLeft(store: PetOverlayStore, size: OverlaySize): IntArray {
        val density = context.resources.displayMetrics.density
        if (store.debugOverlayMode) {
            return OverlayGeometry.debugTopLeftPx(density, bounds, size.width)
        }
        val edge = if (store.snapEnabled) store.snapEdge else OverlaySnapEdge.none
        val fromRatio = OverlayPositionCalculator.topLeftFromRatio(
            xRatio = store.xRatio,
            yRatio = store.yRatio,
            bounds = bounds,
            petWidth = size.width,
            petHeight = size.height,
        )
        if (edge == OverlaySnapEdge.none) return fromRatio
        val x = OverlayPositionCalculator.snapTargetX(edge, bounds, size.width)
        return OverlayPositionCalculator.clampTopLeft(x, fromRatio[1], bounds, size.width, size.height)
    }

    /**
     * 解析可用区域（状态栏 / 导航栏 / 刘海 / 分屏）。
     *
     * API 30+ 直接用 `WindowMetrics.windowInsets`（含 `displayCutout`），这是唯一
     * 能同时覆盖"状态栏 + 导航栏 + 挖孔 + 分屏"的可靠来源；
     * API 24~29 没有这套 API，退化为"屏幕尺寸 - 系统栏资源高度"（best effort，见文档"已知限制"）。
     */
    private fun resolveBounds(): OverlayBounds {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val metrics = windowManager.currentWindowMetrics
            val b = metrics.bounds
            val insets = metrics.windowInsets.getInsets(
                WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout(),
            )
            val resolved = OverlayBounds(
                left = b.left + insets.left,
                top = b.top + insets.top,
                right = b.right - insets.right,
                bottom = b.bottom - insets.bottom,
            )
            if (resolved.isUsable) return resolved
            return OverlayBounds.ofScreen(b.width(), b.height())
        }
        val screen = screenSize()
        if (screen[0] <= 0 || screen[1] <= 0) return OverlayBounds.unknown
        val landscape =
            context.resources.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE
        val statusBar = systemBarPx("status_bar_height")
        val navBar = systemBarPx(
            if (landscape) "navigation_bar_height_landscape" else "navigation_bar_height",
        )
        val resolved = if (landscape) {
            OverlayBounds(0, statusBar, screen[0] - navBar, screen[1])
        } else {
            OverlayBounds(0, statusBar, screen[0], screen[1] - navBar)
        }
        return if (resolved.isUsable) resolved else OverlayBounds.ofScreen(screen[0], screen[1])
    }

    private fun systemBarPx(resourceName: String): Int {
        val id = context.resources.getIdentifier(resourceName, "dimen", "android")
        if (id <= 0) return 0
        return context.resources.getDimensionPixelSize(id).coerceAtLeast(0)
    }

    /** 屏幕可用区域（API 30+ 用真实窗口指标，低版本用 displayMetrics）。 */
    fun screenSize(): IntArray {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val bounds = windowManager.currentWindowMetrics.bounds
            return intArrayOf(bounds.width(), bounds.height())
        }
        @Suppress("DEPRECATION")
        val metrics = context.resources.displayMetrics
        return intArrayOf(metrics.widthPixels, metrics.heightPixels)
    }

    /** 当前方向名（持久化"保存时屏幕方向"用）。 */
    fun orientationName(): String =
        when (context.resources.configuration.orientation) {
            Configuration.ORIENTATION_LANDSCAPE -> PetOverlayStore.ORIENTATION_LANDSCAPE
            Configuration.ORIENTATION_PORTRAIT -> PetOverlayStore.ORIENTATION_PORTRAIT
            else -> PetOverlayStore.ORIENTATION_UNKNOWN
        }

    private fun requireMainThread(op: String) {
        if (Looper.myLooper() == Looper.getMainLooper()) return
        // 串行化前提：所有 WindowManager 操作都必须在主线程。
        OverlayLog.warn("$op 不在主线程（thread=${Thread.currentThread().name}）—— WindowManager 操作必须串行")
    }

    private companion object {
        /** 开/关菜单过渡探针的帧数上限（有界，避免持续刷日志）。 */
        const val TRANSITION_TRACE_FRAMES = 12

        /** 菜单打开逐帧诊断的帧数上限（STEP 1 的有界诊断；≤12 帧后自动停止）。 */
        const val MENU_OPEN_DIAG_FRAMES = 12

        /**
         * 转发拖动专用的"指针 id"：菜单层只转发坐标（不转发原生 pointer id），
         * 用一个固定哨兵值交给 [OverlayDragTracker] 做指针锁定即可。
         */
        const val FORWARDED_POINTER_ID = -1

        /** 单次拖动手势的有界诊断行数上限（缺陷 3：绝不允许逐帧无界刷日志）。 */
        const val DRAG_TRACE_MAX_LINES = 20

        /**
         * "延迟摘层闸门"的兜底超时（缺陷 1）。
         *
         * 正常释放靠转发拖动的终止事件（通常 < 1s）；超过这个时间还没到，说明终止事件缺失，
         * 必须无条件强制释放，否则菜单看不见却继续吞触摸。
         */
        const val DEFERRAL_FALLBACK_MS = 1200L
    }
}

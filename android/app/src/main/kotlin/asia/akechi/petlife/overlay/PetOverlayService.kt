package asia.akechi.petlife.overlay

import android.app.Service
import android.content.BroadcastReceiver
import android.content.ComponentCallbacks
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.res.Configuration
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.widget.Toast
import java.io.File
import java.util.UUID
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.roundToInt

/**
 * 悬浮桌宠前台服务（Phase 4C）。
 *
 * 职责边界（严格按需求"六、原生文件结构建议"）：
 * * 前台服务生命周期与通知；
 * * 创建/销毁悬浮窗（真正的窗口操作在 [PetOverlayManager]）；
 * * **素材加载**（Phase 4C-2：校验后的配置交给 [PetImageLoader]）；
 * * 接收通知动作；
 * * 恢复 SharedPreferences 里的持久化配置；
 * * 监听屏幕开关（息屏暂停动画）；
 * * **防止重复实例** —— 单实例由"服务唯一 + [PetOverlayManager] 单窗口 +
 *   [OverlayStateMachine] 幂等"三层共同保证。
 *
 * 可见性约定（4C-2 两次真机失败后加固，见 docs/35 §6）：
 * **只要服务在运行且未隐藏，窗口必须能看见** —— 有素材就显示素材，
 * 没有素材/加载失败就显示**可见的**占位底，诊断模式则显示不透明洋红方块。
 * 绝不允许"服务在跑但全透明/0×0"。
 *
 * 命令时序（需求第三步）：
 * * 所有 WindowManager 操作都在**主线程**串行执行（服务回调本身就是主线程）；
 * * 每条命令分配递增 `commandId`，桥发起的命令还带 `issuedAt`，
 *   比已应用命令更旧的**受守卫**命令一律丢弃（防止异步乱序覆盖新状态）；
 * * 每条命令都成对记录入口/出口日志，`removeView` 必带原因。
 *
 * 不做的事（需求明确排除）：无障碍服务、读取其他应用内容、自动点击、
 * 后台定位、申请电池优化白名单、AlarmManager 高频拉活。
 */
class PetOverlayService : Service(), OverlayWindowHost {

    /** 本实例标识：用于在日志里区分"同一个服务实例"与"服务被重建"。 */
    private val instanceId: String = Integer.toHexString(System.identityHashCode(this))

    private lateinit var store: PetOverlayStore
    private lateinit var manager: PetOverlayManager
    private lateinit var loader: PetImageLoader

    /**
     * 菜单请求队列（Phase 4C-6B-3）。
     *
     * **服务是队列的拥有者**：菜单动作只可能在没有 Activity / Flutter 的时候被点下来
     * （悬浮窗独立存活），入队必须在这里完成。落盘用 SharedPreferences
     * （见 [MenuRequestStore]），因此进程重建后待交付请求仍在。
     */
    private val menuRequests: MenuRequestStore by lazy { MenuRequestStore(this) }

    private var state: OverlayState = OverlayState.stopped
    private var screenReceiver: BroadcastReceiver? = null
    private var screenOff = false

    /** onDestroy 的原因（诊断：区分"用户停止"与"被系统杀死"）。 */
    private var destroyReason: String = "unspecified"

    /** 最近一条 start 的 startId（`stopSelfResult` 的判据，见 [stopEverything]）。 */
    private var lastStartId: Int = 0

    /** 上一次真正发起解码的素材与窗口尺寸 —— 相同就不再重复解码。 */
    private var lastLoadAssetId: String? = null
    private var lastLoadSizePx: Int = 0

    /** Phase 4C-4：当前视觉类型（动画门控与诊断都用它）。 */
    private var currentVisualKind: PetVisualKind = PetVisualKind.placeholder

    /** Phase 4C-4：最近一次解码错误码（诊断）。 */
    private var lastDecodeCode: String? = null

    /** Phase 4C-4：是否已经进入"停止清理流程"（停止中不允许启动动画）。 */
    private var stopping = false

    /** Phase 4C-4：最近一次"不允许播放"的原因（诊断）。 */
    private var lastAnimationPausedReason: String? = null

    // -----------------------------------------------------------------------
    // Phase 4C-5：状态联动
    // -----------------------------------------------------------------------

    /** 前台应用来源（真机走 UsageStatsManager；缺权限时返回 null）。 */
    private lateinit var foregroundSource: ForegroundAppSource

    /** 状态判定（纯逻辑）。 */
    private lateinit var stateMonitor: PetStateMonitor

    /** 唯一的轮询任务（需求 §11：同一时刻只有一个监听任务）。 */
    private lateinit var statePoller: PetStatePoller

    // -----------------------------------------------------------------------
    // Phase 4C-5.1B：使用会话采集
    //
    // 只读 4C-5.1A 的共享快照（[ForegroundAppRegistry]），**不新增第二个轮询器**；
    // 驱动的时机就是状态轮询的同一个 tick（需求 §2 / §3.1）。
    // -----------------------------------------------------------------------

    /** 会话记录器（状态机 + journal + 开放检查点）。 */
    private var usageRecorder: UsageSessionRecorder? = null

    /**
     * 双窗口层级探测（**仅诊断模式**，默认关闭）。
     *
     * 完全自成一体：不参与生产菜单开合路径，也不改写窗口/状态/素材。
     * 由 [syncDualWindowLayerProbe] 按 `store.debugOverlayMode` 启停；
     * 服务销毁 / 停止时由 [stopEverything] / [onDestroy] 兜底移除其创建的窗口。
     */
    private var dualLayerProbe: DualWindowLayerProbe? = null

    /**
     * 桌面（launcher）包名集合。
     *
     * 需求 §3.3：桌面与系统界面**不计入**普通应用累计时长，但切到它们时仍要结束
     * 上一个应用会话 —— 因此这里只用于判断"是否计入"，不用于过滤快照。
     * Phase 4C-6A 起同时用于状态解析（桌面 → idle/away）。
     */
    private val homePackages: Set<String> by lazy { resolveHomePackages() }

    /**
     * 自动状态联动的运行时规则（Phase 4C-6A）。
     *
     * 缓存在这里而不是每次 tick 去读 SharedPreferences：规则只在收到 Flutter 推送
     * 时变化，逐帧读盘没有意义。初值与每次 `updateStateMapping` 成功后同步刷新。
     */
    private var stateRules: PetStateRules = PetStateRules.DEFAULT

    /** 主线程 Handler：轮询与动画/窗口操作在同一个线程串行，避免跨线程竞态。 */
    private val mainHandler = Handler(Looper.getMainLooper())

    /** 当前已生效的状态 ID（默认 `default`）。 */
    private var currentStateId: String = PetStateId.DEFAULT

    /** 当前状态的来源。 */
    private var currentStateSource: PetStateSource = PetStateSource.unsupported

    /** 当前状态的判定原因（人可读）。 */
    private var currentStateReason: String = "尚未检测"

    /**
     * 当前正在**临时预览**的状态（Phase 4C-6A.1，需求 §11）。
     *
     * **只存在内存里**（[PreviewWindow] 没有任何写盘接口）：需求 §11.2 明确
     * "服务重启后不恢复临时预览"。它只影响"显示哪张图"，
     * 不影响 `currentStateId`（= stableState）、也不影响手动覆盖。
     */
    private val preview = PreviewWindow(PREVIEW_DURATION_MS)

    /** 当前状态选中的素材（回退链的结果）。 */
    private var currentStateAssetId: String? = null

    /** 当前素材命中的回退级别（1~4，诊断用）。 */
    private var currentFallbackLevel: Int = 0

    /** 最近一次真正发生状态变化的时间。 */
    private var lastStateChangedAt: Long = 0L

    /** 最近一次判定使用的映射版本。 */
    private var mappingRevisionInUse: Long = 0L

    /**
     * 最近一次**成功应用**映射快照的墙钟时间（毫秒）。
     *
     * 诊断价值：它能回答"'规则没生效'是因为快照压根没到，还是到了但规则不对"。
     */
    private var mappingReceivedAt: Long = 0L

    /** 最近一次状态联动的错误码（诊断）。 */
    private var lastStateErrorCode: String? = null

    /**
     * 使用情况访问权限的**短缓存**。
     *
     * 每次检测刷新一次（[refreshUsageAccess]），诊断发布只读缓存 —— 否则
     * "每 1.5 秒的轮询 + 若干次诊断发布"会做多次 AppOps（跨进程）查询。
     */
    private var usageAccessCache: Boolean = false

    /**
     * 下一次轮询是否走"快速路径"。
     *
     * 由 [pollStateNow] / 显示后的首次检测置位，[PetStatePoller] 的 onTick 读取并清空 ——
     * 这样"解锁立即恢复"和"常规轮询"共用同一个任务，不会出现第二个计时器。
     */
    private var fastPathTick: Boolean = false

    private val imageListener = object : PetImageLoader.Listener {
        override fun onLoaded(
            requestSeq: Long,
            decoded: DecodedPetVisual,
            config: PetOverlayConfig,
        ) {
            OverlayLog.log(
                "visual.decode.success seq=$requestSeq asset=${config.assetId} " +
                    "decoder=${decoded.decoderName} kind=${decoded.kind.name} " +
                    "size=${decoded.width}x${decoded.height} " +
                    "apiLevel=${Build.VERSION.SDK_INT} " +
                    "fullAnimation=${PetVisualTypePolicy.supportsFullAnimation(Build.VERSION.SDK_INT)}",
            )
            // 先挂视觉，再撤占位底（顺序由 PetOverlayView.applyDrawable 保证）。
            val drawable = drawableOf(decoded)
            if (drawable == null) {
                manager.showErrorPlaceholder(PetVisualError.userMessage(PetVisualError.DECODE_FAILED))
            } else {
                when (decoded.kind) {
                    // 只有"系统支持完整播放"的动态素材才交给动画通道。
                    PetVisualKind.animated -> manager.showAnimated(drawable)
                    PetVisualKind.static, PetVisualKind.animatedFirstFrameFallback ->
                        manager.showStatic(drawable)
                    PetVisualKind.placeholder ->
                        manager.showErrorPlaceholder(
                            PetVisualError.userMessage(PetVisualError.DECODE_FAILED),
                        )
                }
            }
            if (decoded.kind == PetVisualKind.animatedFirstFrameFallback) {
                OverlayLog.log(ANIMATED_FIRST_FRAME_FALLBACK_NOTICE)
            }
            // Phase 4C-3A：窗口尺寸由**素材宽高比**决定（静态与动态走同一条路径），
            // 图一到就按新的宽高比重算尺寸与坐标，走 applySettings 而不是重建服务。
            manager.applySettings(store)
            // Phase 4C-6B-1.1：量一次素材的**视觉边界**（缺口按它算，需求 §3）。
            scheduleContentBoundsMeasurement(config.filePath, config.assetId)
            currentVisualKind = decoded.kind
            lastDecodeCode = null
            displayedAssetIdFlag = config.assetId
            isPlaceholderFlag = false
            lastLoadErrorFlag = null
            lastUpdatedAtFlag = System.currentTimeMillis()
            OverlayLog.log("visual.apply ok asset=${config.assetId} ${manager.dump()}")
            // 动画是否播放由统一门控决定（attached / 可见 / 亮屏 / 实例有效 …）。
            syncAnimationPlayback("asset-loaded")
            refreshNotification()
        }

        override fun onFailed(
            requestSeq: Long,
            code: String,
            message: String,
            config: PetOverlayConfig,
        ) {
            // 解码失败：**清掉旧视觉**并显示明确错误占位（窗口绝不消失）。
            // 不保留旧素材，避免用户误以为切换成功（需求第 13 节）。
            lastLoadErrorFlag = "$code: $message"
            lastDecodeCode = code
            currentVisualKind = PetVisualKind.placeholder
            displayedAssetIdFlag = null
            isPlaceholderFlag = true
            manager.showErrorPlaceholder(PetVisualError.userMessage(code))
            syncAnimationPlayback("asset-failed")
            OverlayLog.warn(
                "visual.decode.failed asset=${config.assetId} code=$code " +
                    "msg=${PetVisualError.userMessage(code)} ${manager.dump()}",
            )
            logState("asset-failed")
        }

        override fun onStale(requestSeq: Long) {
            OverlayLog.log("visual.decode.stale seq=$requestSeq（已被更新的请求取代，丢弃）")
        }
    }

    /** 已经量过视觉边界的素材（只在素材变化时重量一次）。 */
    private var measuredBoundsAssetId: String? = null

    /**
     * 视觉边界测量的专用后台线程（只为量 alpha 包围盒）。
     *
     * **不用 `by lazy`**：`newSingleThreadExecutor` 本身是惰性起线程的，
     * 这样 `onDestroy` 里可以无条件关掉它，不会漏线程。
     */
    private val boundsExecutor: java.util.concurrent.ExecutorService =
        java.util.concurrent.Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "PetLifeVisualBounds")
        }

    /**
     * 量一次素材的视觉边界（Phase 4C-6B-1.1，需求 §3）。
     *
     * 只在**素材变化**时量一次：结果只取决于素材本身，与窗口尺寸/旋转/缩放都无关，
     * 因此可以长期缓存。测量跑在独立后台线程，绝不阻塞主线程与触摸。
     */
    private fun scheduleContentBoundsMeasurement(path: String, assetId: String) {
        if (path.isEmpty() || assetId.isEmpty()) return
        if (measuredBoundsAssetId == assetId) return
        boundsExecutor.execute {
            val bounds = runCatching { PetAlphaBounds.measureFile(path) }
                .getOrElse { PetContentBounds.FULL }
            mainHandler.post {
                if (activeInstance !== this@PetOverlayService) return@post
                if (measuredBoundsAssetId == assetId) return@post
                measuredBoundsAssetId = assetId
                manager.setPetContentBounds(bounds)
                OverlayLog.log("wheel_layout_bounds asset=$assetId bounds=${bounds.describe()}")
            }
        }
    }

    /**
     * 把解码结果折算成可挂到 ImageView 上的 Drawable。
     *
     * 动态与静态在这里汇合 —— 视图层只关心"是不是 Animatable"。
     */
    private fun drawableOf(decoded: DecodedPetVisual): android.graphics.drawable.Drawable? =
        when (val visual = decoded.visual) {
            is PetVisual.Static -> visual.drawable
            is PetVisual.Animated -> visual.drawable
            is PetVisual.Placeholder -> null
        }

    /**
     * **统一的动画播放同步**（需求第 10 节：七条条件集中判定，不把 start/stop 散落各处）。
     *
     * 这是唯一允许调用 `manager.syncAnimation` 的地方。
     *
     * @param forceStop 用于"隐藏/停止/息屏"这类**必须立刻停**的路径：
     *   此时窗口还没摘掉（`isAttached` 仍为 true），单靠门控判不出来，必须显式压过。
     */
    private fun syncAnimationPlayback(trigger: String, forceStop: Boolean = false) {
        val gate = AnimationGate(
            serviceRunning = true,
            viewAttached = manager.isAttachedToWindow,
            petVisible = manager.isAttached && manager.isVisible,
            screenInteractive = !screenOff,
            visualIsAnimated = currentVisualKind == PetVisualKind.animated,
            stopping = stopping,
            instanceActive = activeInstance === this,
        )
        val shouldPlay = !forceStop && gate.shouldAnimate()
        lastAnimationPausedReason = if (forceStop) trigger else gate.blockedReason()
        if (currentVisualKind == PetVisualKind.animated ||
            currentVisualKind == PetVisualKind.animatedFirstFrameFallback
        ) {
            OverlayLog.log(
                "animation.gate play=$shouldPlay blocked=${gate.blockedReason() ?: "none"} " +
                    "forceStop=$forceStop trigger=$trigger attached=${manager.isAttachedToWindow} " +
                    "visible=${manager.isVisible} screenOff=$screenOff",
            )
        }
        if (currentVisualKind == PetVisualKind.animatedFirstFrameFallback) {
            OverlayLog.log(
                "animation.unsupported reason=${PetVisualError.UNSUPPORTED_ANIMATED_WEBP} " +
                    "apiLevel=${Build.VERSION.SDK_INT} trigger=$trigger",
            )
        }
        manager.syncAnimation(shouldPlay, trigger)
    }

    override fun onCreate() {
        super.onCreate()
        store = PetOverlayStore(this)
        manager = PetOverlayManager(this, this)
        loader = PetImageLoader(
            AndroidPetVisualDecoder(
                roots = PetOverlayConfig.privateAssetRoots(this),
                resources = resources,
            ),
        )
        // Phase 4C-5：状态联动。监听任务在这里创建，但**只有窗口显示后才会启动**
        // （服务被创建不等于用户看到了桌宠）；创建时同步恢复持久化的状态与映射。
        OverlayLog.diagnosticsEnabled = store.debugOverlayMode
        refreshUsageAccess()
        foregroundSource = AndroidForegroundAppSource(this)
        // Phase 4C-6A：桌面（launcher）也落在 system 分类里，但它代表"回到桌面/空闲"，
        // 与系统设置页语义完全不同 —— 这里把 home 包名集合注入纯逻辑的判定器。
        stateMonitor = PetStateMonitor(
            foregroundSource = foregroundSource,
            isLauncher = { packageName -> homePackages.contains(packageName) },
        )
        // 恢复持久化的自动联动规则（Flutter 被划掉后仍能按同一套规则工作）。
        stateRules = store.readStateMapping().rules()
        statePoller = PetStatePoller(
            post = { runnable, delayMs -> mainHandler.postDelayed(runnable, delayMs) },
            remove = { runnable -> mainHandler.removeCallbacks(runnable) },
            // 隐藏时降频（需求 §17.2：状态监听可以暂停或降频），可见时 1.5 秒一次。
            intervalMs = { if (state.hidden) STATE_HIDDEN_POLL_MS else STATE_POLL_MS },
            onTick = {
                val fast = fastPathTick
                fastPathTick = false
                stateTick("poll", fast)
            },
        )
        // Phase 4C-5.1B：使用会话采集。
        //
        // 复用同一个 tick 驱动（不新增轮询器），数据源是 4C-5.1A 的共享快照；
        // 服务一创建就先做一次"上次遗留开放会话"的收尾（需求 §4.2）。
        val usageRecorder = UsageSessionRecorder(
            tracker = AndroidUsageSessionTracker(
                idFactory = { UUID.randomUUID().toString() },
                deviceLocalId = { store.usageDeviceLocalId },
                clock = { System.currentTimeMillis() },
            ),
            journal = UsageSessionJournal.of(filesDir),
        )
        usageRecorder.onServiceStarted(paused = store.usageCollectionPaused)
        this.usageRecorder = usageRecorder
        // 声明"当前活跃实例"。旧实例如果在之后才收到 onDestroy，
        // 绝不能把新实例的通知与静态诊断状态一起清掉（那会造成
        // "通知消失 / 界面显示服务未运行"的假象）。
        val superseded = activeInstance
        activeInstance = this
        runningFlag = true
        if (superseded != null && superseded !== this) {
            OverlayLog.warn(
                "检测到旧服务实例尚未销毁：old=" +
                    Integer.toHexString(System.identityHashCode(superseded)) +
                    " new=$instanceId（新实例已接管）",
            )
        }

        // 必须在 startForegroundService 之后尽快进入前台，否则系统会抛
        // ForegroundServiceDidNotStartInTimeException（即使这一条指令是 STOP，
        // 也要先 startForeground 再 stopSelf）。
        startForeground(
            OverlayNotification.NOTIFICATION_ID,
            OverlayNotification.build(this, store.hidden, null),
        )
        registerScreenReceiver()
        registerConfigurationListener()
        OverlayLog.log(
            "service.onCreate instance=$instanceId sdk=${Build.VERSION.SDK_INT} " +
                "target=${applicationInfo.targetSdkVersion} " +
                "canDrawOverlays=${Settings.canDrawOverlays(this)} " +
                "persistedHidden=${store.hidden} " +
                "persistedEnabled=${store.enabled} debug=${store.debugOverlayMode} " +
                "thread=${Thread.currentThread().name}",
        )
        logState("service-created")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val command = OverlayCommand.fromWire(intent?.getStringExtra(OverlayActions.EXTRA_COMMAND))
        val issuedAt = intent?.getLongExtra(OverlayActions.EXTRA_ISSUED_AT, 0L) ?: 0L
        val guarded = intent?.getBooleanExtra(OverlayActions.EXTRA_GUARDED, false) ?: false
        // Phase 4D：本次启动是否由开机自启触发（只有开机触发的启动才回填 boot 结果）。
        val trigger = intent?.getStringExtra(OverlayActions.EXTRA_TRIGGER)
        val commandId = commandSeq.incrementAndGet()

        OverlayLog.log(
            "onStartCommand instance=$instanceId commandId=$commandId startId=$startId " +
                "command=$command guarded=$guarded issuedAt=$issuedAt trigger=$trigger " +
                "intentNull=${intent == null} stateBefore=$state hiddenBefore=${store.hidden} " +
                "thread=${Thread.currentThread().name}",
        )

        // 过期命令守卫：桥发起的命令带时间戳；比已应用命令更旧的直接丢弃。
        if (guarded && issuedAt > 0L && issuedAt < lastAppliedIssuedAt) {
            OverlayLog.warn(
                "丢弃过期命令 commandId=$commandId command=$command " +
                    "issuedAt=$issuedAt < lastApplied=$lastAppliedIssuedAt",
            )
            return START_STICKY
        }
        if (guarded && issuedAt > 0L) lastAppliedIssuedAt = issuedAt

        lastStartId = startId
        applyCommand(command, commandId, startId, trigger)
        OverlayLog.log("onStartCommand done commandId=$commandId startId=$startId ${manager.dump()}")
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    /** 用户从最近任务里划掉 PetLife：`stopWithTask=false`，因此这里**不**停止悬浮桌宠。 */
    override fun onTaskRemoved(rootIntent: Intent?) {
        OverlayLog.log("onTaskRemoved instance=$instanceId（悬浮桌宠继续运行）")
        logState("task-removed")
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        destroyReason = if (destroyReason == "unspecified") {
            "system-or-unknown（既不是用户停止也不是权限丢失）"
        } else {
            destroyReason
        }
        // 是否仍是"当前活跃实例"：旧实例的 onDestroy 可能晚于新实例的 onCreate。
        val wasActive = activeInstance === this
        OverlayLog.log(
            "service.onDestroy instance=$instanceId reason=$destroyReason wasActive=$wasActive " +
                "state=$state windowAttached=${manager.isAttached} ${manager.dump()}",
        )
        unregisterScreenReceiver()
        unregisterConfigurationListener()
        // Phase 4C-6B-1.1：视觉边界测量是独立线程，必须显式关掉（不留线程泄漏）。
        runCatching { boundsExecutor.shutdownNow() }
        // 顺序很重要（需求 §11.7）：
        // 1) 幂等停动画；2) 把 Drawable 从 ImageView 上摘掉（此时 View 还活着）；
        // 3) 移除窗口；4) 最后才让 loader 释放引用 ——
        // 反过来会出现"Drawable 已释放但仍被 View 持有"的窗口期。
        // 只清理**本实例**持有的 View（manager 是实例字段，天然满足）。
        stopping = true
        // Phase 4C-5：幂等取消状态监听与所有回调（需求 §17.7）。
        // 旧实例的 onTick 即使在队列里，也会因为 poller.running=false 而直接返回，
        // 不会去操作新实例的状态或素材。
        stopStateMonitor("destroy")
        // 4C-5.1B：服务销毁也必须收尾（用户停止时已经关过一次，这里幂等）。
        usageRecorder?.onServiceStopped()
        // 服务销毁即清空共享快照：宁可让界面显示"不可用/采集未运行"，
        // 也不要让它读到一个进程级残留的旧应用名。
        ForegroundAppRegistry.clear()
        resetRuntimeState()
        syncAnimationPlayback("destroy", forceStop = true)
        manager.clearVisual("onDestroy")
        manager.detach("onDestroy")
        // 服务销毁 ⇒ 移除诊断探测创建的全部窗口，绝不留透明可触摸窗口（诊断默认关闭）。
        // 生产窗口已在上面 detach，此处不恢复（服务正在退出）。
        stopDualWindowLayerProbe(restoreProduction = false, reason = "onDestroy")
        loader.dispose()
        currentVisualKind = PetVisualKind.placeholder
        state = OverlayState.stopped
        lastLoadAssetId = null
        lastLoadSizePx = 0
        if (wasActive) {
            // 只有"当前实例"才允许清掉全局状态与通知；
            // 旧实例若已让位给新实例，这些都不是它的了。
            runningFlag = false
            windowAttachedFlag = false
            displayedAssetIdFlag = null
            isPlaceholderFlag = true
            OverlayNotification.cancel(this)
        } else {
            OverlayLog.warn(
                "旧实例 onDestroy：已被新实例接管，跳过通知取消与全局状态清理 instance=$instanceId",
            )
        }
        logState("service-destroyed")
        // 放在最后：这样本实例在 onDestroy 期间仍是"活跃实例"，
        // [publishDiagnostics] 才会如实写出"服务已停、窗口已摘"的终态。
        if (wasActive) activeInstance = null
        super.onDestroy()
    }

    // -----------------------------------------------------------------------
    // 指令
    // -----------------------------------------------------------------------

    private fun applyCommand(
        command: OverlayCommand,
        commandId: Long,
        startId: Int,
        trigger: String? = null,
    ) {
        // Phase 4D：只有开机自启触发的启动才回填 boot 结果，用户手动"显示"不污染它。
        val fromBoot = trigger == OverlayActions.TRIGGER_BOOT
        // 「重新应用配置」是唯一的例外：它不参与状态推导，也不会把
        // 一个没在运行的悬浮桌宠"顺带启动"（那必须由用户显式点显示）。
        if (command == OverlayCommand.UPDATE) {
            // 诊断模式开关可能刚被改过：同步"逐条细节日志"的开关，
            // 并重新验证一次使用情况访问（用户可能刚从系统设置页回来）。
            OverlayLog.diagnosticsEnabled = store.debugOverlayMode
            refreshUsageAccess()
            // 诊断**关**：先停探针并恢复生产窗口（若有），再走常规 attach（幂等，不会重复建窗）。
            if (!store.debugOverlayMode) {
                syncDualWindowLayerProbe()
            }
            if (state.windowVisible) {
                try {
                    manager.attach(store)
                } catch (t: Throwable) {
                    OverlayLog.error("更新悬浮窗布局失败", t)
                }
                manager.refreshVisual(loading = false, lastError = lastLoadErrorFlag)
                refreshNotification()
                loadAssetIfNeeded(force = false)
            }
            // 诊断**开**：探针必须在生产窗口 attach 之后同步 —— 探针要临时摘除生产窗口，
            // 若先跑探针、后 attach，紧接着的 attach 会把刚摘掉的生产窗口又建回来（三窗并存）。
            if (store.debugOverlayMode) {
                syncDualWindowLayerProbe()
            }
            logState("command=update id=$commandId")
            return
        }

        val next = OverlayStateMachine.next(state, command)

        if (!next.running) {
            stopEverything(reason = "command=${command.name.lowercase()} id=$commandId", startId = startId)
            return
        }

        // 权限在运行中被撤销（或本来就没给）：不创建窗口，也不留下"运行中"的假状态。
        if (next.windowVisible && !Settings.canDrawOverlays(this)) {
            OverlayLog.warn("显示请求被拒绝：缺少悬浮窗权限")
            if (fromBoot) {
                store.recordBootResult(
                    BootAutostart.RESULT_MISSING_OVERLAY,
                    "overlay-permission-missing",
                    System.currentTimeMillis(),
                )
            }
            stopEverything(reason = "overlay-permission-missing id=$commandId", startId = startId)
            return
        }

        val wasHidden = state.hidden
        state = next
        // 显式恢复显示：`show` / `start` 后 hidden 一定是 false，
        // 绝不允许"服务在跑但一直继承上次的 hidden=true"。
        store.enabled = next.running
        store.hidden = next.hidden
        if (next.windowVisible && wasHidden) {
            OverlayLog.log("hidden=false（用户显式显示 / start 带配置恢复显示）")
        }

        if (next.windowVisible) {
            // 恢复前台状态：如果上一次 stop 因为"紧接着又来了新的 start"而被
            // 系统忽略（服务存活但已退出前台），这里必须重新进入前台，
            // 否则 Android 12+ 会把一个"已启动但非前台"的服务回收掉。
            ensureForeground()
            val created = try {
                manager.attach(store)
            } catch (t: Throwable) {
                OverlayLog.error("addView 失败，悬浮窗未创建", t)
                if (fromBoot) {
                    store.recordBootResult(
                        BootAutostart.RESULT_START_FAILED,
                        "add-view-failed",
                        System.currentTimeMillis(),
                    )
                }
                stopEverything(reason = "add-view-failed id=$commandId", startId = startId)
                return
            }
            manager.setAnimationPaused(screenOff)
            if (!created) {
                // **只有"复用已有窗口"时**才重新套用配置。
                //
                // 新建窗口时绝对不能再调 applySettings：attach 已经完整应用了 store
                // （debugMode / scale / size / position / flags / format），
                // 而 `addView` 返回时 View **不保证**已经走完 onAttachedToWindow ——
                // 此刻提交几何会被守卫拒绝（isAttachedToWindow == false），
                // 旧代码进而把这个刚创建的窗口当失效窗口 detach 掉，
                // 真机表现就是"服务在运行、但窗口未成功添加"（4C-3B 复验缺陷 A）。
                manager.applySettings(store)
            }
            // 新窗口是空的（或复用了旧窗口）：把已经**解码好**的视觉贴回去，
            // 避免"隐藏 → 显示"时重复解码同一个文件（需求 §11.3）。
            if (created) {
                val decoded = loader.currentVisualOrNull()
                val drawable = decoded?.let { drawableOf(it) }
                if (drawable != null) {
                    if (decoded.kind == PetVisualKind.animated) {
                        manager.showAnimated(drawable)
                    } else {
                        manager.showStatic(drawable)
                    }
                }
            }
            manager.refreshVisual(loading = false, lastError = lastLoadErrorFlag)
            // 布局完成后再打一次日志：这是"窗口到底多大"最直接的证据；
            // 并在**窗口真正 attached 之后**再同步一次动画（需求 §11.1）。
            manager.postAfterLayout {
                logState("layout-settled id=$commandId")
                syncAnimationPlayback("show-attached")
            }
            // Phase 4C-5：先按当前状态选定素材再加载（避免"先贴上次素材、1.5 秒后再换"的白解码），
            // 随后启动唯一的状态监听任务并立即检测一次（需求 §17.1）。
            stateTick("show", fastPath = true)
            loadAssetIfNeeded(force = false)
            startStateMonitor("show")
        } else {
            // 隐藏 ≠ 停止：只移除窗口，服务、通知与已解码素材继续保留。
            // Phase 4C-4：**先停动画**，再摘窗口（需求 §11.2）。
            syncAnimationPlayback("hide", forceStop = true)
            // 4C-3B：菜单必须先关闭（否则会留下一个扩展过的透明窗口）。
            manager.closeMenu("hide", animate = false)
            manager.detach("hide id=$commandId", suspendGesture = OverlayGestureState.HIDDEN)
            // Phase 4C-5：隐藏时状态监听**降频**（不停止：重新显示时能立刻恢复正确状态）。
            publishStateDiagnostics()
        }

        windowAttachedFlag = manager.isAttached
        refreshNotification()
        // Phase 4D：开机触发的启动真正走到这里 = 服务已起来（隐藏启动也算启动成功）。
        // 接收器先前写的是 start_requested，这里回填真实结果，设置页据此显示"最近一次启动成功"。
        if (fromBoot) {
            store.recordBootResult(
                BootAutostart.RESULT_STARTED,
                if (next.hidden) "started-hidden" else "started",
                System.currentTimeMillis(),
            )
        }
        logState("command=${command.name.lowercase()} id=$commandId")
    }

    // -----------------------------------------------------------------------
    // 双窗口层级探测（仅诊断模式）——与生产菜单管理完全解耦
    // -----------------------------------------------------------------------

    /** 探测前"生产窗口应可见"的现场（= `state.windowVisible`）：**仅内存**，绝不写盘。 */
    private var probePreWindowVisible: Boolean = false

    /** 探测是否临时摘除了生产窗口（决定停止时是否需要恢复）。 */
    private var probeDetachedProduction: Boolean = false

    /** 恢复生产桌宠窗口时的重建计数（`attach` 真正新建才为 1；已挂载幂等返回 false 即 0）。 */
    private var probeRestoreRecreateCount: Int = 0

    /**
     * 按 `debugOverlayMode` 启停双窗口探测。
     *
     * * 诊断关（默认）→ 停止探测、移除它创建的全部窗口，并按需恢复生产窗口；
     * * 诊断开 → 幂等创建并启动（已在运行则什么都不做）。
     *
     * 关键：探针运行时必须让生产悬浮窗**先摘除**（否则三窗并存，探测无法证明双窗口层级）。
     * 摘除/恢复都走既有的 [PetOverlayManager.detach] / [PetOverlayManager.attach]，
     * **绝不**用 `OverlayCommand.HIDE`（那会把 `hidden=true` 落盘）。
     * 全部包在 try/catch 里：探测失败**绝不影响**生产悬浮窗。
     */
    private fun syncDualWindowLayerProbe() {
        if (!store.debugOverlayMode) {
            stopDualWindowLayerProbe(restoreProduction = true, reason = "debug-disabled")
            return
        }
        val probe = dualLayerProbe
            ?: DualWindowLayerProbe(
                context = this,
                petRectProvider = { petProbeRectOrNull() },
                productionWindowAttachedProvider = { manager.isAttached },
            ).also { dualLayerProbe = it }
        if (probe.isRunning) return
        startDualWindowLayerProbe(probe)
    }

    /**
     * 启动探测前的诊断专用"摘窗 → 探测"流程。
     *
     * 顺序不可颠倒：
     * 1) **先**记录现场（`state.windowVisible`）与**真实桌宠矩形**（摘窗前才取得到）；
     * 2) 生产窗口若已挂载，用既有 manager 级 detach 临时摘除（`suspendGesture=HIDDEN`：语义为
     *    "窗口暂时不可见但服务仍在运行"，与 [OverlayCommand.HIDE] 的持久化 `hidden` 无关）；
     * 3) 探测内部硬门会再次校验 `manager.isAttached`：若摘除未生效则拒绝启动并打
     *    `PROBE_INVALID_PRODUCTION_WINDOW_ATTACHED`。
     */
    private fun startDualWindowLayerProbe(probe: DualWindowLayerProbe) {
        try {
            // 1) 现场（仅在内存里，绝不改 store.hidden / state.running / 持久化位置）。
            probePreWindowVisible = state.windowVisible
            probeDetachedProduction = false
            probeRestoreRecreateCount = 0
            val petRectBeforeProbe = petProbeRectOrNull()
            // 2) 生产窗口若已挂载：先关菜单，再按既有路径摘除。
            if (manager.isAttached) {
                manager.closeMenu("probe.detach", animate = false)
                manager.detach(
                    reason = "probe.detach",
                    suspendGesture = OverlayGestureState.HIDDEN,
                )
                probeDetachedProduction = true
                windowAttachedFlag = manager.isAttached
            }
            if (manager.isAttached) {
                OverlayLog.warn(
                    "probe.dual 摘除生产窗口未生效（仍挂载）—— 探测将拒绝启动",
                )
            }
            // 3) 启动探测；几何仍从**真实桌宠矩形**派生（绝不挪位避让重叠）。
            probe.start(providedPetRect = petRectBeforeProbe)
        } catch (t: Throwable) {
            OverlayLog.warn("probe.dual 启动失败（不影响生产悬浮窗）", t)
        }
    }

    /** 停止探测：**先**移除全部探测窗口，再按需恢复生产窗口，并打印可核对的停止摘要。 */
    private fun stopDualWindowLayerProbe(restoreProduction: Boolean, reason: String) {
        val probe = dualLayerProbe ?: return
        val visibleBefore = probePreWindowVisible
        val wasRunning = probe.isRunning
        val result = runCatching { probe.stop() }.getOrElse {
            OverlayLog.warn("probe.dual stop 失败", it)
            ProbeStopResult.Empty
        }
        // 恢复**在移除探测窗口之后**：顺序不能反，否则会短暂三窗并存。
        if (restoreProduction) {
            restoreProductionAfterProbe()
        }
        val productionAttached = manager.isAttached
        if (wasRunning || result.menuRemoveCount > 0 || result.petRemoveCount > 0) {
            DualWindowProbeContract.stopSummaryLines(
                menuRemoveCount = result.menuRemoveCount,
                petRemoveCount = result.petRemoveCount,
                probeWindowCountAfterStop = result.probeWindowCount,
                productionVisibleBefore = visibleBefore,
                productionRestored = productionAttached == visibleBefore,
                petWindowRecreateCount = probeRestoreRecreateCount,
                productionWindowAttached = productionAttached,
            ).forEach { OverlayLog.log(it) }
            logState("probe-stopped reason=$reason")
        }
        probeDetachedProduction = false
        probePreWindowVisible = false
        probeRestoreRecreateCount = 0
    }

    /**
     * 探测停止后恢复生产悬浮窗（仅当"探测曾摘除生产窗口"且"探测前应为可见"）。
     *
     * 复用 SHOW 命令建窗后贴回已解码视觉的同一路径：`attach` **幂等**，
     * 已挂载时返回 false ⇒ 绝不重复 addView（[probeRestoreRecreateCount] 如实记 0）。
     * 若探测前本来就是隐藏态，则**保持隐藏**，什么都不做。
     */
    private fun restoreProductionAfterProbe() {
        if (!probeDetachedProduction || !probePreWindowVisible) return
        if (manager.isAttached) return
        try {
            val created = manager.attach(store)
            probeRestoreRecreateCount = DualWindowProbeContract.petWindowRecreateCount(created)
            if (created) {
                // 新窗口是空的：把已经解码好的视觉贴回去（与 SHOW 路径一致，避免重复解码）。
                val decoded = loader.currentVisualOrNull()
                val drawable = decoded?.let { drawableOf(it) }
                if (drawable != null) {
                    if (decoded.kind == PetVisualKind.animated) {
                        manager.showAnimated(drawable)
                    } else {
                        manager.showStatic(drawable)
                    }
                }
            } else {
                manager.applySettings(store)
            }
            manager.setAnimationPaused(screenOff)
            manager.refreshVisual(loading = false, lastError = lastLoadErrorFlag)
            windowAttachedFlag = manager.isAttached
            syncAnimationPlayback("probe-restore")
            manager.postAfterLayout { logState("probe-restore-settled") }
        } catch (t: Throwable) {
            OverlayLog.error("probe.dual 恢复生产悬浮窗失败", t)
        }
    }

    /**
     * 双窗口探测的**完整状态**（供 Flutter `getDualWindowProbeStatus` 读取）。
     *
     * 探测未创建 / 未运行时返回 [DualWindowProbeContract.emptyStatus]：
     * key 集与运行时完全一致，只是值退化为 `none` / 0 / false，Flutter 卡片可安全渲染。
     */
    internal fun dualLayerProbeStatus(): Map<String, Any?> {
        val probe = dualLayerProbe ?: return DualWindowProbeContract.emptyStatus()
        if (!probe.isRunning) return DualWindowProbeContract.emptyStatus()
        return runCatching { probe.statusMap() }.getOrElse {
            OverlayLog.warn("probe.dual statusMap 失败", it)
            DualWindowProbeContract.emptyStatus()
        }
    }

    /**
     * 运行模式（单 / 双窗口）切换：**拆一种模式、建另一种**，不复用旧窗口。
     *
     * 走既有 attach/detach 流程：
     * 1. 先关菜单（双窗口下 = 一次 updateViewLayout 收敛到关闭态）；
     * 2. `detach`（幂等，双窗口下会把菜单窗与桌宠窗**都**摘干净）→ 绝不留可触摸残留；
     * 3. 若窗口本应可见：`attach` 重新读 store 的模式并只建对应的一 / 两个窗口 → 绝不出现重复窗口。
     */
    private fun rebuildOverlayForModeChange(reason: String) {
        if (!manager.isAttached) {
            OverlayLog.log("overlay.mode.rebuild 跳过：窗口未挂载 reason=$reason")
            return
        }
        try {
            manager.closeMenu("mode-change:$reason", animate = false)
            manager.detach("mode-change:$reason", OverlayGestureState.HIDDEN)
            windowAttachedFlag = manager.isAttached
            if (state.windowVisible && Settings.canDrawOverlays(this)) {
                val created = manager.attach(store)
                if (created) {
                    // 新窗口是空的：把已解码好的视觉贴回去（与 SHOW 路径一致，避免重复解码）。
                    val decoded = loader.currentVisualOrNull()
                    val drawable = decoded?.let { drawableOf(it) }
                    if (drawable != null) {
                        if (decoded.kind == PetVisualKind.animated) {
                            manager.showAnimated(drawable)
                        } else {
                            manager.showStatic(drawable)
                        }
                    }
                } else {
                    manager.applySettings(store)
                }
                manager.setAnimationPaused(screenOff)
                manager.refreshVisual(loading = false, lastError = lastLoadErrorFlag)
                windowAttachedFlag = manager.isAttached
                syncAnimationPlayback("mode-rebuild")
                loadAssetIfNeeded(force = false)
            }
            publishDiagnostics()
            logState("mode-rebuild reason=$reason")
        } catch (t: Throwable) {
            OverlayLog.error("运行模式切换重建失败（保持原状）", t)
        }
    }

    /** 取当前真实桌宠屏幕矩形（探测用来派生尺寸/位置）；窗口未挂载时返回 null 走兜底。 */
    private fun petProbeRectOrNull(): OverlayRect? {
        if (!manager.isAttached) return null
        val size = manager.petSize()
        if (size.width <= 0 || size.height <= 0) return null
        val topLeft = manager.currentTopLeft()
        return OverlayRect(
            left = topLeft[0],
            top = topLeft[1],
            right = topLeft[0] + size.width,
            bottom = topLeft[1] + size.height,
        )
    }

    /**
     * 停止：移除窗口 → 清引用 → 退出前台 → 结束服务（需求第三步第 4 条）。
     *
     * 关键细节是 **`stopSelfResult(startId)` 而不是 `stopSelf()`**：
     * `stopSelfResult` 只在"最近一次 start 就是这一条 startId"时才真正停服务。
     * 于是"停止 → 显示"这种连点场景不会出现
     * "新窗口刚 addView 成功，紧接着旧的停止请求把服务 onDestroy 掉、窗口一闪而过"。
     */
    private fun stopEverything(reason: String, startId: Int) {
        destroyReason = "stop($reason)"
        // 进入停止流程：此后不允许再启动动画（门控里的 stopping 条件）。
        stopping = true
        // 需求 §11.6 的清理顺序：关菜单 → 停动画 → 摘 Drawable → 移除窗口。
        // （loader 的最终释放放在 onDestroy：服务实例可能被紧接着的 start 复用，
        //   在这里 dispose 会让"停止 → 显示"再也加载不出素材。）
        // Phase 4C-5：先停状态监听并取消待处理防抖，再动窗口（需求 §17.6）。
        stopStateMonitor("stop")
        // 4C-5.1B：服务停止 = 使用会话结束（需求 §3.3），先落盘再摘窗口。
        usageRecorder?.onServiceStopped()
        resetRuntimeState()
        manager.closeMenu("stop", animate = false)
        syncAnimationPlayback("stop", forceStop = true)
        manager.clearVisual("stop")
        manager.detach("stop($reason)", suspendGesture = OverlayGestureState.STOPPED)
        // 停止时移除诊断探测创建的全部窗口（诊断模式本身保持，重开后按需重建）。
        // 生产窗口已在上面 detach，此处不恢复（服务正在停止）。
        stopDualWindowLayerProbe(restoreProduction = false, reason = "service-stop")
        // 这里**不**释放 loader，也**不**清空"当前显示的是什么"的记账：
        // * loader 的释放统一交给 onDestroy（否则服务实例被下一次 start 复用时，
        //   loader 会永远处于 disposed 状态而不再加载任何素材）；
        // * 记账留着不动，隐藏/停止后再显示时才能把同一张图直接贴回新窗口。
        windowAttachedFlag = false
        state = OverlayState.stopped
        store.clearRuntime()
        logState("stopped($reason)")
        // 先摘窗口（用户点了停止就该立刻看不见），再决定服务本身要不要结束。
        val stopped = stopSelfResult(startId)
        if (stopped) {
            OverlayNotification.cancel(this)
            stopForeground(STOP_FOREGROUND_REMOVE)
            OverlayLog.log("stopSelfResult 生效：服务即将 onDestroy（startId=$startId）")
        } else {
            // 已经有一条更新的 start 在队列里（典型的"停止 → 显示"）：服务保持存活，
            // 前台状态与通知都保留，等那条命令到达时直接重新显示窗口。
            OverlayLog.warn(
                "stopSelfResult 被忽略：已有更新的 start（startId=$startId " +
                    "lastStartId=$lastStartId）—— 服务保持运行，不取消通知",
            )
        }
    }

    /** 确保服务处于前台（幂等；同 ID 的通知只会被更新）。 */
    private fun ensureForeground() {
        startForeground(
            OverlayNotification.NOTIFICATION_ID,
            OverlayNotification.build(this, state.hidden, characterName()),
        )
    }

    // -----------------------------------------------------------------------
    // 素材加载（Phase 4C-2）
    // -----------------------------------------------------------------------

    /**
     * 按当前持久化配置加载素材。
     *
     * 去重规则：**素材 ID + 窗口尺寸都没变**时直接返回 ——
     * 这正是"相同素材不得重复解码"的落点。
     * 诊断模式下**完全不加载素材**（需求第二步）。
     */
    private fun loadAssetIfNeeded(force: Boolean) {
        if (!manager.isAttached) {
            OverlayLog.warn("load skipped: 窗口未挂载")
            return
        }
        if (store.debugOverlayMode) {
            OverlayLog.log("load skipped: 诊断模式（不读取素材）")
            return
        }

        val config = store.toConfig()
        if (config == null) {
            // 还没有任何素材（或当前素材已被删除）：回到**可见的**空占位，
            // 同时丢掉内存里那份已经不成立的视觉，避免"再显示"时把它贴回来。
            loader.clearCurrent()
            manager.clearVisual("no-asset")
            manager.refreshVisual(loading = false, lastError = null)
            displayedAssetIdFlag = null
            isPlaceholderFlag = true
            currentVisualKind = PetVisualKind.placeholder
            lastDecodeCode = null
            lastLoadAssetId = null
            lastLoadSizePx = 0
            return
        }

        val targetSize = manager.currentViewSizePx()
        if (targetSize <= 0) {
            OverlayLog.warn("load skipped: 窗口尺寸为 0")
            return
        }

        if (!force && config.assetId == lastLoadAssetId && targetSize == lastLoadSizePx) {
            OverlayLog.log("load skipped: 相同素材与相同尺寸 asset=${config.assetId} size=$targetSize")
            return
        }
        lastLoadAssetId = config.assetId
        lastLoadSizePx = targetSize

        // 记录需求第四节点名的全部字段：真机排障时这一行就能定位"路径不对"还是"解码不过"。
        val assetFile = File(config.filePath)
        val roots = PetOverlayConfig.privateAssetRoots(this)
        OverlayLog.log(
            "receive config characterId=${config.characterId} assetId=${config.assetId} " +
                "mime=${config.mimeType} animated=${config.isAnimated} " +
                "fileExists=${assetFile.exists()} fileSize=${assetFile.length()} " +
                "file=${runCatching { assetFile.canonicalPath }.getOrElse { config.filePath }} " +
                "allowedRoots=${roots.joinToString(" | ") { root -> runCatching { root.canonicalPath }.getOrElse { root.absolutePath } }} " +
                "targetSize=$targetSize",
        )

        // 加载前先显示"加载中"占位（只会在还没有图时生效），保证窗口始终可见。
        manager.refreshVisual(loading = true, lastError = null)
        loader.load(config, targetSize, imageListener)
    }

    // -----------------------------------------------------------------------
    // 状态联动（Phase 4C-5）
    // -----------------------------------------------------------------------

    /**
     * 一次状态检测（由 [PetStatePoller] 在主线程调用）。
     *
     * 所有判定都在 [PetStateMonitor] 里完成（纯逻辑、可单测），
     * 这里只负责"把决策落到窗口与素材上"。
     */
    private fun stateTick(trigger: String, fastPath: Boolean = false) {
        // 两个时钟各司其职（Phase 4C-6A 诊断要求）：
        // * `monotonicNow`（elapsedRealtime）只用于**防抖**的时间比较；
        // * `wallNow` 只用于给界面展示时间戳。
        // 混用会让"用户改系统时间 / 自动校时"直接把候选计时打断。
        val monotonicNow = SystemClock.elapsedRealtime()
        val wallNow = System.currentTimeMillis()
        // 临时预览到期就立刻结束并回到真实状态的素材（需求 §11.1）。
        // 复用**同一个 tick**，不额外起计时器。
        expirePreviewIfNeeded(wallNow)
        val attached = manager.isAttached
        // Phase 4C-5.1B：使用统计与"窗口是否可见"**解耦** ——
        // 隐藏桌宠只是把窗口摘掉，服务与轮询都还在跑，前台会话必须继续记录。
        // 因此这里先保证"这一 tick 有一份新鲜的前台快照"，再做素材/状态分支。
        val decision = if (attached) {
            stateMonitor.tick(
                now = monotonicNow,
                currentStateId = currentStateId,
                manualOverride = manualOverrideState(),
                fastPath = fastPath,
                rules = stateRules,
                wallNow = wallNow,
            )
        } else {
            // 状态机不跑时快照不会被刷新；补一次"够新就跳过"的检测。
            // 仍然只有 AndroidForegroundAppSource 这一个检测入口（需求 §2）。
            refreshForegroundSnapshotIfStale(USAGE_SNAPSHOT_MAX_AGE_MS)
            null
        }
        // 检测顺带把"使用情况访问是否真的可用"的结论带回来（AppOps + 数据双验证），
        // 诊断发布直接用它，避免每个发布点重复做跨进程查询。
        stateMonitor.lastDiagnostics?.let { diagnostics ->
            if (diagnostics.usageAccessGranted != usageAccessCache) {
                OverlayLog.log(
                    "state.permission.changed granted=${diagnostics.usageAccessGranted}",
                )
                // 权限被撤销：立刻结束当前使用会话（需求 §3.3），不留下超长段。
                if (!diagnostics.usageAccessGranted) usageRecorder?.onPermissionRevoked()
            }
            usageAccessCache = diagnostics.usageAccessGranted
        }
        // 使用会话采集：无论窗口是否可见都要喂一份观察。
        recordUsageObservation()

        // 窗口不可见时不做素材切换（隐藏期间"改了也看不见"，只会白白解码）。
        if (!attached) return
        if (decision == null) {
            publishStateDiagnostics()
            return
        }
        applyStateDecision(decision, trigger)
    }

    /**
     * 解析当前设备上的桌面（launcher）包名集合。
     *
     * 需求 §3.3 要求"桌面 / 系统界面 / PetLife 自身不计入普通应用累计时长"，
     * 但切换到它们时仍要结束上一个应用会话 —— 因此这里只用于判断"是否计入"。
     * SystemUI / 输入法 / PetLife 自身已经在 [ForegroundCandidateSelector] 里被过滤掉了。
     */
    private fun resolveHomePackages(): Set<String> {
        @Suppress("DEPRECATION")
        return runCatching {
            packageManager.queryIntentActivities(
                Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME),
                0,
            ).mapNotNull { it.activityInfo?.packageName }.toSet()
        }.getOrElse { throwable ->
            // 取不到就当作"没有桌面"：宁可多记一个系统类应用，也不要因此不记录。
            OverlayLog.warn("usage.home-packages.failed", throwable)
            emptySet()
        }
    }

    /** 把当前共享快照喂给会话记录器（唯一检测入口 → 唯一发布点 → 唯一消费点）。 */
    private fun recordUsageObservation() {
        val recorder = usageRecorder ?: return
        val snapshot = ForegroundAppRegistry.current
        val packageName = snapshot?.packageName?.takeIf { it.isNotEmpty() }
        recorder.observe(
            packageName = packageName,
            appName = snapshot?.appLabel,
            category = snapshot?.category,
            countable = packageName != null && !homePackages.contains(packageName),
        )
    }

    /** 把一次决策落到"当前状态 + 素材"上。 */
    private fun applyStateDecision(decision: PetStateDecision, trigger: String) {
        val previous = currentStateId
        val changed = previous != decision.stateId
        if (!changed) {
            // 只有"手动覆盖持续生效"会走到这里（轮询每 1.5 秒给同一个 stateId）。
            // 不做任何切换、也不打日志 —— 需求 §20 禁止稳定状态下重复刷 INFO。
            currentStateSource = decision.source
            publishStateDiagnostics()
            return
        }
        currentStateId = decision.stateId
        currentStateSource = decision.source
        currentStateReason = decision.reason
        lastStateErrorCode = null
        lastStateChangedAt = decision.decidedAt
        // 需求 §18：菜单打开时状态变化 → 先关菜单再换素材，避免菜单指向的桌宠被换掉。
        manager.closeMenu("state-changed", animate = false)
        OverlayLog.log(
            "state.changed from=$previous to=${decision.stateId} " +
                "source=${decision.source.wire} trigger=$trigger reason=${decision.reason}",
        )
        // 预览期间只记账、**不换画面**：预览素材必须稳定显示到期（需求 §11.1
        // 要求"临时显示该状态映射素材"，被自动切换顶掉就等于预览失效）。
        // 预览结束后 `applyAssetForState(currentStateId, ...)` 会把画面补回真实状态。
        if (preview.isActive) {
            OverlayLog.log(
                "state.preview.hold 状态已变为 ${decision.stateId}，预览中暂不切换素材",
            )
            publishStateDiagnostics()
            return
        }
        selectAssetForState(decision)
        publishStateDiagnostics()
    }

    /**
     * 按回退链选择当前状态的素材并加载。
     *
     * 复用 4C-4 的加载链路（requestId 防过期 + 去重 + 动画门控），**不写第二套加载器**：
     * 这里只更新 [PetOverlayStore] 的素材字段，随后照常走 `loadAssetIfNeeded`。
     */
    private fun selectAssetForState(decision: PetStateDecision) {
        applyAssetForState(decision.stateId, "state-changed")
    }

    /**
     * 按某个状态解析素材并加载（**不改状态本身**，Phase 4C-6A.1）。
     *
     * 抽出来的唯一目的：临时预览要"显示某状态的素材但不改 stableState"
     * （需求 §11.1），因此必须有一条**只换图、不换状态**的路径 ——
     * 而且它**复用同一条回退链与同一条加载链路**，不写第二套。
     */
    private fun applyAssetForState(stateId: String, reason: String) {
        val mapping = store.readStateMapping()
        mappingRevisionInUse = mapping.revision
        if (mapping.characterId.isEmpty()) {
            lastStateErrorCode = PetStateError.MAPPING_MISSING
            OverlayLog.warn("state.asset.fallback 缺少状态映射快照（等待 Flutter 推送）")
            publishStateDiagnostics()
            return
        }
        val selection = NativeAssetSelector.select(mapping, stateId)
        if (selection == null) {
            // 全部失效：保持窗口可见的错误占位（需求 §14：绝不让窗口消失）。
            lastStateErrorCode = PetStateError.STATE_ASSET_MISSING
            currentStateAssetId = null
            currentFallbackLevel = NativeAssetSelector.LEVEL_PLACEHOLDER
            OverlayLog.warn("state.asset.fallback level=placeholder reason=角色没有任何有效素材")
            manager.showErrorPlaceholder(PetVisualError.userMessage(PetVisualError.FILE_MISSING))
            return
        }

        currentStateAssetId = selection.asset.assetId
        currentFallbackLevel = selection.level
        if (selection.level != NativeAssetSelector.LEVEL_STATE_ASSET) {
            OverlayLog.log(
                "state_asset_fallback level=${selection.level} state=$stateId " +
                    "asset=${selection.asset.assetId} reason=${selection.reason}",
            )
        } else {
            OverlayLog.log(
                "state_asset_resolved state=$stateId asset=${selection.asset.assetId} " +
                    "level=${selection.level} trigger=$reason",
            )
        }

        // 需求 §15 第 3 步：assetId 与当前相同 → 直接结束（不重新解码）。
        if (selection.asset.assetId == store.assetId) {
            OverlayLog.log(
                "state.asset.selected asset=${selection.asset.assetId} " +
                    "state=$stateId（与当前素材相同，跳过解码）",
            )
            return
        }

        // 更新 store 后走既有加载链路；路径安全校验、requestId 防过期、动画门控全在链路里。
        store.assetId = selection.asset.assetId
        store.filePath = selection.asset.path
        store.isAnimated = selection.asset.isAnimated
        store.mimeType = PetMime.forPath(selection.asset.path)
        OverlayLog.log(
            "state.asset.selected asset=${selection.asset.assetId} state=$stateId " +
                "level=${selection.level} animated=${selection.asset.isAnimated}",
        )
        // force=false：去重逻辑会自行判断"素材 + 尺寸都没变就不解码"（需求 §15 第 3 步）。
        loadAssetIfNeeded(force = false)
    }

    // -----------------------------------------------------------------------
    // 临时预览（Phase 4C-6A.1，需求 §11）
    //
    // 三件事必须在语义上分开，UI 文案也不得混用：
    // * **编辑映射**：改「状态 → 素材」这张表（自动模式照常）；
    // * **手动覆盖**：displayMode=manual，一直忽略自动状态直到解除；
    // * **临时预览**：displayMode=preview，只换画面、不动状态，到期自动恢复。
    // -----------------------------------------------------------------------

    /** 当前显示模式（诊断字段，需求 §11.2 / §15）。 */
    private fun displayMode(): String = when {
        preview.isActive -> "preview"
        manualOverrideState() != null -> "manual"
        else -> "auto"
    }

    /**
     * 开始临时预览某状态（幂等；覆盖上一个预览 —— 需求 §11.1「预览另一个状态时替换上一个」）。
     *
     * 刻意**不持久化**：需求 §11.2 明确"服务重启后不恢复临时预览"。
     */
    internal fun previewState(stateId: String?): Boolean {
        if (stateId == null || !PetStateId.isKnown(stateId)) {
            lastStateErrorCode = PetStateError.UNKNOWN_STATE
            OverlayLog.warn("state.preview.set 被拒绝：未知状态 ID $stateId")
            return false
        }
        val replacing = preview.stateId
        preview.start(stateId, System.currentTimeMillis())
        OverlayLog.log(
            "state_asset_preview_started state=$stateId " +
                "replaces=${replacing ?: "<none>"} durationMs=${preview.durationMs}",
        )
        // 预览**不改** currentStateId / lastStateChangedAt / 手动覆盖（需求 §11.1）。
        if (manager.isAttached) applyAssetForState(stateId, "preview")
        publishStateDiagnostics()
        return true
    }

    /** 结束临时预览并回到真实状态对应的素材（幂等）。 */
    internal fun clearPreview(): Boolean {
        val previous = preview.stateId ?: return true
        preview.clear()
        OverlayLog.log("state_asset_preview_ended state=$previous reason=cleared")
        if (manager.isAttached) applyAssetForState(currentStateId, "preview-ended")
        publishStateDiagnostics()
        return true
    }

    /** 预览到期（由唯一的状态轮询 tick 顺带检查，不额外起计时器）。 */
    private fun expirePreviewIfNeeded(wallNow: Long) {
        if (!preview.isExpired(wallNow)) return
        val previewing = preview.stateId
        preview.clear()
        OverlayLog.log("state_asset_preview_ended state=$previewing reason=expired")
        if (manager.isAttached) applyAssetForState(currentStateId, "preview-expired")
        publishStateDiagnostics()
    }

    /**
     * 用 Flutter 推送的映射快照更新原生映射（需求 §9）。
     *
     * 不重建窗口、不重启服务、不影响菜单。
     */
    internal fun updateStateMapping(raw: Any?): NativePetStateMappingParser.Result {
        val previous = store.readStateMapping().takeIf { it.characterId.isNotEmpty() }
        val result = NativePetStateMappingParser.parse(raw, previous)
        val mapping = result.mapping
        if (mapping == null) {
            // 解析彻底失败：**保留上一次配置**，并把错误显式暴露给界面
            // （需求 §4：绝不能静默地"用空规则继续跑"）。
            lastStateErrorCode = result.code
            OverlayLog.warn("state.mapping.rejected code=${result.code} msg=${result.message}")
            publishStateDiagnostics()
            return result
        }
        // 解析失败但保留旧映射：也必须报错，不能伪装成"幂等跳过"。
        val fatal = result.code == PetStateError.MAPPING_PARSE_FAILED ||
            result.code == PetStateError.MAPPING_REVISION_STALE
        if (fatal) {
            lastStateErrorCode = result.code
            OverlayLog.warn(
                "state.mapping.rejected code=${result.code} msg=${result.message}" +
                    "（保留上一次配置 rev=${previous?.revision ?: 0}）",
            )
            publishStateDiagnostics()
            return result
        }
        if (previous != null && mapping.revision == previous.revision) {
            // 相同 revision 幂等：不重复写盘、不重复切换。
            // **但规则仍要刷新** —— 否则"内容没变、配置变了"会被静默吞掉。
            stateRules = mapping.rules()
            mappingRevisionInUse = mapping.revision
            OverlayLog.log("state.mapping.updated revision=${mapping.revision}（幂等，跳过写盘）")
            return result
        }
        store.writeStateMapping(mapping)
        // Phase 4C-6A：规则表与自动开关一并生效（下一次 tick 就用新规则）。
        stateRules = mapping.rules()
        mappingRevisionInUse = mapping.revision
        mappingReceivedAt = System.currentTimeMillis()
        OverlayLog.log(
            "state.mapping.updated revision=${mapping.revision} character=${mapping.characterId} " +
                "states=${mapping.stateAssets.size} default=${mapping.defaultAsset?.assetId ?: "<none>"}" +
                " automatic=${mapping.automaticEnabled} categoryRules=${mapping.categoryRules.size}" +
                " appOverrides=${mapping.appOverrides.size}" +
                (result.code?.let { " note=$it" } ?: ""),
        )
        // 映射变了：当前状态的素材可能也变了，必须**立刻重算**（需求 §8）。
        //
        // 关键点：只调 `stateTick` 是不够的 —— 状态机发现"目标状态没变"会返回
        // "状态未发生变化"并**跳过素材重算**，于是"给当前状态换了张图"在界面上
        // 毫无反应，要等下一次状态切换才生效。因此这里再**无条件**按当前状态
        // （或正在预览的状态）重解析一次素材；assetId 相同会被去重，不会重复解码。
        if (manager.isAttached) {
            stateTick("mapping-updated")
            val stateForAsset = preview.stateId ?: currentStateId
            applyAssetForState(stateForAsset, "mapping-updated")
        }
        publishStateDiagnostics()
        return result
    }

    /** 手动覆盖（状态调试器，需求 §16）：立即生效、不等防抖。 */
    internal fun setManualState(stateId: String?): Boolean {
        if (stateId == null) {
            store.manualStateOverride = null
            OverlayLog.log("state.manual.clear")
        } else if (!PetStateId.isKnown(stateId)) {
            lastStateErrorCode = PetStateError.UNKNOWN_STATE
            OverlayLog.warn("state.manual.set 被拒绝：未知状态 ID $stateId")
            return false
        } else {
            store.manualStateOverride = stateId
            OverlayLog.log("state.manual.set state=$stateId")
        }
        stateMonitor.reset()
        if (manager.isAttached) stateTick("manual-override")
        publishStateDiagnostics()
        return true
    }

    /**
     * 当前手动覆盖（已校验）。
     *
     * 状态 ID 是**固定集合**，因此"失效的覆盖"只可能来自被改坏的数据 ——
     * 这里在读的时候过滤掉，等价于需求 §16 的"状态 ID 失效时自动清除覆盖"。
     */
    private fun manualOverrideState(): String? =
        store.manualStateOverride?.takeIf { PetStateId.isKnown(it) }

    /** 监听任务是否在跑（`statePoller` 在 onCreate 里初始化，这里做安全兜底）。 */
    private val stateMonitorRunning: Boolean
        get() = if (::statePoller.isInitialized) statePoller.isRunning else false

    /**
     * 当前"使用情况访问"是否真实可用。
     *
     * 结论由状态检测带回来（`ForegroundAppResolver` 同时验证 AppOps 与"确实能读到数据"），
     * 因此不需要在每个诊断发布点重复做 AppOps 查询。仅作为兜底：服务刚起、
     * 还没检测过时保持 [usageAccessCache] 的初值。
     */
    private fun refreshUsageAccess(): Boolean {
        val granted = UsageAccess.isGranted(this)
        if (granted != usageAccessCache) {
            if (granted) {
                OverlayLog.log("state.permission.granted（自动联动开始生效）")
            } else {
                OverlayLog.log("state.permission.missing code=${PetStateError.USAGE_ACCESS_MISSING}")
            }
        }
        usageAccessCache = granted
        return granted
    }

    /** 停止服务时清掉**运行时**状态（需求 §17.6：保留用户映射配置，只清运行时）。 */
    private fun resetRuntimeState() {
        // 临时预览是**运行时**的东西：停止服务就该结束（需求 §11.2）。
        if (preview.isActive) {
            OverlayLog.log(
                "state_asset_preview_ended state=${preview.stateId} reason=service-stopped",
            )
        }
        preview.clear()
        // 映射快照与手动覆盖属于"用户配置"，**不清**（重启后仍能继续联动）。
        currentStateId = PetStateId.DEFAULT
        currentStateSource = PetStateSource.unsupported
        currentStateReason = "服务已停止"
        currentStateAssetId = null
        currentFallbackLevel = 0
        lastStateChangedAt = 0L
        lastStateErrorCode = null
        fastPathTick = false
        OverlayLog.log("state.runtime.reset（保留映射与手动覆盖配置）")
    }

    /**
     * 启动状态监听（幂等；需求 §22 第 41/42 条）。
     */
    private fun startStateMonitor(reason: String) {
        if (screenOff) {
            OverlayLog.log("state.monitor.start 跳过 reason=$reason（屏幕已关闭）")
            return
        }
        val wasRunning = stateMonitorRunning
        statePoller.start(immediate = true)
        if (!wasRunning) OverlayLog.log("state.monitor.start reason=$reason interval=${STATE_POLL_MS}ms")
        // 采集器 = 这个唯一的轮询任务；界面据此区分"没有应用"与"采集没在跑"。
        ForegroundAppRegistry.setCollectorRunning(statePoller.isRunning)
        publishStateDiagnostics()
    }

    /** 停止状态监听（幂等；需求 §22 第 44/46/47 条）。 */
    private fun stopStateMonitor(reason: String) {
        val wasRunning = stateMonitorRunning
        statePoller.stop()
        stateMonitor.reset()
        if (wasRunning) OverlayLog.log("state.monitor.stop reason=$reason")
        ForegroundAppRegistry.setCollectorRunning(false)
        publishStateDiagnostics()
    }

    /**
     * 供桥接调用：快照过期时补一次真正的检测（界面刷新本身**不会**查询 UsageStatsManager）。
     *
     * 只有"共享快照比 [maxAgeMs] 更旧"或"从未检测过"时才真的读一次，
     * 因此统计页的秒级刷新不会造成高频系统查询（需求 §3.3）。
     */
    internal fun refreshForegroundSnapshotIfStale(maxAgeMs: Long) {
        if (!::foregroundSource.isInitialized) return
        val now = System.currentTimeMillis()
        val current = ForegroundAppRegistry.current
        if (current != null && now - current.detectedAt <= maxAgeMs) return
        runCatching { foregroundSource.read(now) }.onFailure {
            OverlayLog.warn("前台应用快照刷新失败（界面显示上一次结果）", it)
        }
    }

    /**
     * 供桥接调用：读取本实例的使用会话记录器（服务未运行时为 null，桥侧会降级）。
     *
     * 桥接只在**主线程**调用（MethodChannel 回调与轮询在同一个线程），
     * 因此这里不需要额外加锁。
     */
    internal fun usageRecorderOrNull(): UsageSessionRecorder? = usageRecorder

    /** 解锁 / 重新显示后立即检测一次，不等下一个轮询周期。 */
    private fun pollStateNow(reason: String) {
        if (!stateMonitorRunning) {
            statePoller.start(immediate = true)
        } else {
            statePoller.pollNow()
        }
        OverlayLog.log("state.monitor.poll-now reason=$reason")
    }

    /** 状态联动的诊断发布（独立于窗口诊断，避免把既有方法签名撑爆）。 */
    private fun publishStateDiagnostics() {
        // 与窗口诊断同一条守卫：已被新实例接管的旧实例不得覆写全局状态。
        if (activeInstance !== this) return
        if (!::stateMonitor.isInitialized) return
        publishStateDiagnostics(
            stateId = currentStateId,
            stateSource = currentStateSource.wire,
            stateReason = currentStateReason,
            foregroundPackage = stateMonitor.lastForegroundPackage,
            foregroundLabel = stateMonitor.lastForegroundLabel,
            category = stateMonitor.lastCategory,
            categorySource = stateMonitor.lastCategorySource,
            candidateState = stateMonitor.candidateState,
            candidateCount = stateMonitor.candidateCount,
            manualOverride = manualOverrideState(),
            usageAccessGranted = usageAccessCache,
            monitorRunning = stateMonitorRunning,
            mappingRevision = mappingRevisionInUse,
            stateAssetId = currentStateAssetId,
            fallbackLevel = currentFallbackLevel,
            lastChangedAt = lastStateChangedAt,
            stateErrorCode = lastStateErrorCode ?: stateMonitor.lastErrorCode,
            diagnostics = stateMonitor.lastDiagnostics,
            automaticStateEnabled = stateRules.automaticEnabled,
            matchedRule = stateMonitor.lastMatchedRule,
            resolvedTargetState = stateMonitor.lastResolvedTargetState,
            candidateSince = stateMonitor.candidateSinceWall,
            candidateElapsedMs = stateMonitor.candidateElapsedMs,
            categoryDetail = stateMonitor.lastCategoryDetail,
            platformCategory = stateMonitor.lastPlatformCategory,
            mappingReceivedAt = mappingReceivedAt,
            transitionResult = stateMonitor.lastTransitionResult,
            transitionReason = stateMonitor.lastTransitionReason,
            lastCommittedAt = stateMonitor.lastCommittedAt,
            displayMode = displayMode(),
            previewState = preview.stateId,
            previewExpiresAt = preview.expiresAt,
        )
    }

    // -----------------------------------------------------------------------
    // 屏幕开关
    // -----------------------------------------------------------------------

    private fun registerScreenReceiver() {
        if (screenReceiver != null) return
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                when (intent?.action) {
                    Intent.ACTION_SCREEN_OFF -> {
                        // 息屏：暂停动画，保留窗口与配置（不做任何后台工作）。
                        screenOff = true
                        manager.setAnimationPaused(true)
                        // 4C-3B：锁屏/息屏必须关掉菜单（不允许留下透明拦截区域）。
                        manager.closeMenu("screen-off", animate = false)
                        // 4C-4：立刻停动画，绝不让它在后台空转逐帧解码（需求 §11.4）。
                        syncAnimationPlayback("screen-off", forceStop = true)
                        // 4C-5：锁屏期间**完全停止**状态监听（需求 §11 / §17.4：无轮询）。
                        stopStateMonitor("screen-off")
                        // 4C-5.1B：息屏 = 使用会话的结束点（需求 §3.3），
                        // 绝不能把熄屏到解锁这段时间算成使用时长。
                        usageRecorder?.onScreenOff()
                        OverlayLog.log("animation.pause reason=screen-off")
                        logState("screen-off")
                    }
                    Intent.ACTION_USER_PRESENT -> {
                        // 解锁后恢复（不创建第二个窗口）。
                        screenOff = false
                        manager.setAnimationPaused(false)
                        // 4C-4：按统一门控恢复播放（attached + 可见 + 亮屏 + 实例有效）。
                        syncAnimationPlayback("user-present")
                        // 4C-5：解锁后立即检测一次并按"快速路径"恢复正确状态与素材（需求 §17.5）。
                        if (manager.isAttached) {
                            fastPathTick = true
                            pollStateNow("user-present")
                        }
                        OverlayLog.log("animation.resume reason=user-present")
                        logState("user-present")
                    }
                }
            }
        }
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_OFF)
            addAction(Intent.ACTION_USER_PRESENT)
        }
        // 这两个动作只能在运行时注册（manifest 注册收不到）。
        registerReceiver(receiver, filter)
        screenReceiver = receiver
    }

    private fun unregisterScreenReceiver() {
        val receiver = screenReceiver ?: return
        screenReceiver = null
        try {
            unregisterReceiver(receiver)
        } catch (t: Throwable) {
            // 已经注销过：忽略。
        }
    }

    // -----------------------------------------------------------------------
    // 屏幕配置变化（Phase 4C-3A：横竖屏 / 分屏 / 系统栏变化）
    // -----------------------------------------------------------------------

    private var configurationCallbacks: ComponentCallbacks? = null

    private fun registerConfigurationListener() {
        if (configurationCallbacks != null) return
        val callbacks = object : ComponentCallbacks {
            override fun onConfigurationChanged(newConfig: Configuration) {
                onWindowConfigurationChanged()
            }

            @Deprecated("ComponentCallbacks 的旧方法，仅为兼容低版本")
            override fun onLowMemory() {
                // 悬浮窗不做任何后台工作，低内存时无需处理。
            }
        }
        registerComponentCallbacks(callbacks)
        configurationCallbacks = callbacks
    }

    private fun unregisterConfigurationListener() {
        val callbacks = configurationCallbacks ?: return
        configurationCallbacks = null
        try {
            unregisterComponentCallbacks(callbacks)
        } catch (t: Throwable) {
            // 已经注销过：忽略。
        }
    }

    /**
     * 横竖屏 / 分屏 / 系统栏尺寸变化：**按当前可用区域重算尺寸与坐标**。
     *
     * 位置不依赖旋转前的绝对像素（只依赖 xRatio/yRatio/snapEdge），
     * 因此这里不需要任何"旋转矩阵"，重算即可（需求 2.4 的"必须重新计算"清单）。
     */
    private fun onWindowConfigurationChanged() {
        // 探测读out 里的 orientation/屏幕尺寸需要跟随旋转刷新（探测窗口本身不重加/不缩放）。
        runCatching { dualLayerProbe?.onConfigurationChanged() }
        if (!manager.isAttached) return
        OverlayLog.log(
            "config.changed orientation=${manager.orientationName()} " +
                "boundsBefore=${manager.currentBounds().width}x${manager.currentBounds().height}",
        )
        try {
            manager.applySettings(store)
        } catch (t: Throwable) {
            OverlayLog.error("配置变化后重算几何失败", t)
        }
        // 尺寸可能变了：让素材按新的长边重新采样（去重逻辑会自行判断要不要真解码）。
        loadAssetIfNeeded(force = false)
        publishDiagnostics()
        logState("configuration-changed")
    }

    // -----------------------------------------------------------------------
    // OverlayWindowHost（Phase 4C-3A）
    // -----------------------------------------------------------------------

    /**
     * 手势结束后的位置持久化（**唯一**的位置写盘点）。
     *
     * 写入失败只记日志，绝不让悬浮窗服务崩溃（需求"四、4C-3A 数据保存"）。
     */
    override fun onPersistPosition(xRatio: Float, yRatio: Float, edge: OverlaySnapEdge) {
        try {
            store.xRatio = xRatio
            store.yRatio = yRatio
            store.snapEdge = edge
            store.snapOrientation = manager.orientationName()
        } catch (t: Throwable) {
            OverlayLog.error("位置持久化失败（悬浮窗继续运行）", t)
            return
        }
        publishDiagnostics()
        logState("position-persisted")
    }

    /** 单击桌宠：4C-3B 起由 manager 开关圆盘菜单，这里只留证据。 */
    override fun onClickPet() {
        OverlayLog.log("gesture.click 已交给菜单状态机（menuState=${manager.menuStateName}）")
        publishDiagnostics()
        logState("pet-clicked")
    }

    /**
     * 轮盘条目动作（Phase 4C-6B-3）。
     *
     * 4C-6B-3 起只有**只读信息项**走这里：只记结构化事件 + 给一句短提示，
     * 不写库、不联网、不切换素材、不改桌宠状态。
     */
    override fun onMenuAction(actionWire: String, itemId: String, detail: String) {
        lastMenuActionFlag = "$actionWire:$itemId → $detail"
        OverlayLog.log("menu.action wire=$actionWire id=$itemId detail=$detail（只读信息项）")
        showMenuHint(detail)
        publishDiagnostics()
        logState("menu-action")
    }

    /**
     * **原生动作**（Phase 4C-6B-3）：完全在 Kotlin 里执行，绝不绕道 Dart。
     *
     * 每个分支都复用**既有**路径：
     * * 隐藏 → [applyCommand] 的 [OverlayCommand.HIDE]（摘窗口，服务 + 通知继续运行）；
     * * 重置位置 / 改大小 → 写 store 后走既有的受守卫 `UPDATE`（内部就是
     *   `manager.attach → applySettings → commitSceneLayout`，不复制几何逻辑）；
     * * 打开 PetLife → 复用通知里那条启动入口（[OverlayNotification.launchOpenApp]）。
     */
    override fun onMenuNativeAction(actionWire: String, itemId: String): Boolean {
        val op = MenuNativeOps.fromWire(actionWire) ?: return false
        lastMenuActionFlag = "native:${op.wire}:$itemId"
        OverlayLog.log("menu.native op=${op.wire} id=$itemId scale=${store.scale}")
        when (op) {
            MenuNativeOp.hide -> {
                if (state.windowVisible) {
                    // 关键口径：**隐藏 ≠ 停止**。走的就是既有命令通道的 HIDE 分支 ——
                    // 采集、通知、前台服务全部保持存活。
                    executeLocalCommand(OverlayCommand.HIDE)
                } else {
                    OverlayLog.warn("menu.native hide 被忽略：窗口当前不可见")
                }
                // 窗口已经摘掉 ⇒ 这里会自然落到既有 Toast 兜底。
                manager.showMenuFeedback("已隐藏（服务继续运行）", FeedbackKind.success)
            }

            MenuNativeOp.resetPosition -> {
                store.xRatio = PetOverlayStore.DEFAULT_X_RATIO
                store.yRatio = PetOverlayStore.DEFAULT_Y_RATIO
                // 吸附到某一边时比例不生效：重置位置必须同时解除吸附，否则"回到默认"看不出变化。
                store.snapEdge = OverlaySnapEdge.none
                store.snapOrientation = manager.orientationName()
                pushSettingsUpdate()
                manager.showMenuFeedback("已恢复默认位置", FeedbackKind.success)
            }

            MenuNativeOp.sizeDown,
            MenuNativeOp.sizeUp,
            MenuNativeOp.sizeReset,
            -> {
                val current = store.scale
                val next = when (op) {
                    MenuNativeOp.sizeDown -> MenuPetSize.down(current)
                    MenuNativeOp.sizeUp -> MenuPetSize.up(current)
                    else -> MenuPetSize.reset(current)
                }
                store.scale = next
                pushSettingsUpdate()
                manager.showMenuFeedback(
                    "桌宠大小：${MenuPetSize.percent(next)}",
                    FeedbackKind.success,
                )
            }

            MenuNativeOp.openApp -> {
                val launched = OverlayNotification.launchOpenApp(
                    context = this,
                    destination = null,
                    requestId = itemId,
                )
                manager.showMenuFeedback(
                    if (launched) "已打开 PetLife" else "无法打开 PetLife",
                    if (launched) FeedbackKind.success else FeedbackKind.warning,
                )
            }
        }
        publishDiagnostics()
        logState("menu-native")
        return true
    }

    /**
     * **Dart 请求**（Phase 4C-6B-3）：入队 + 尝试推送，返回 requestId。
     *
     * 参数在**原生**侧组装（原生才知道当前缩放、当前自动开关、当前轮盘尺寸），
     * Dart 只负责执行并用 `completeMenuRequest` 回报结果。
     */
    override fun onMenuDartRequest(actionWire: String, itemId: String): String {
        val action = WheelMenuAction.entries.firstOrNull { it.wire == actionWire }
        if (action == null) {
            OverlayLog.warn("menu.dart.request 未知动作 wire=$actionWire id=$itemId")
            return ""
        }
        val request = menuRequests.enqueue(actionWire, dartRequestArgs(action)) ?: return ""
        lastMenuActionFlag = "dart:${actionWire}:$itemId"
        // 关键可判定日志：canonicalActionId 就是入队 / 推送 / Dart 执行器用的同一个字符串。
        OverlayLog.log(
            "menu.request requestId=${request.requestId} entryId=$itemId " +
                "canonicalActionId=$actionWire args=${request.args}",
        )
        pushMenuRequest(request)
        publishDiagnostics()
        logState("menu-dart-request")
        return request.requestId
    }

    /** 窗口内反馈层不可用时的兜底短提示（既有 Toast，**只在这一种情况下使用**）。 */
    override fun onMenuHint(text: String) {
        showMenuHint(text)
    }

    /**
     * Dart 回报一条请求的终态（由 [PetOverlayBridge] 调用）：把结果变成一条反馈。
     *
     * 反馈走窗口内层（菜单开着）或既有 Toast（菜单已收起），与请求发出时同一套口径。
     */
    internal fun onMenuRequestResult(status: String, message: String?, requestId: String) {
        val kind = MenuFeedbackPolicy.kindOfStatus(status)
        val text = message?.takeIf { it.isNotBlank() } ?: when (kind) {
            FeedbackKind.running -> "处理中…"
            FeedbackKind.success -> "已完成"
            FeedbackKind.warning -> "请求已过期"
            FeedbackKind.error -> "执行失败"
        }
        OverlayLog.log("menu.request.result id=$requestId status=$status text=$text")
        manager.showMenuFeedback(text, kind, requestId)
    }

    /**
     * 轮盘选中项的只读实时信息（需求 §3 的"可选实时状态"）。
     *
     * **只读已经缓存的字段**，绝不查数据库、绝不打新的使用统计查询 —— 它会在选中变化时同步调用。
     * 动态状态（自动开关 / 采集暂停 / 轮盘与按钮大小）都从这里展示：
     * **文案会变，条目 id 永不变**，因此业务判断永远只看 id。
     */
    override fun onMenuInfo(itemId: String): String? = when (itemId) {
        "root_pet", "pet_current" -> "当前状态：${PetStateId.descriptionZh(PetOverlayService.stateId)}"
        "root_records", "records_app" -> PetOverlayService.foregroundLabel?.let { "当前应用：$it" }
            ?: "当前应用：未知"
        "root_hide" -> if (state.hidden) "当前：已隐藏" else "当前：显示中"
        "root_settings", "settings_theme" -> "主题：${store.menuTheme().displayName}"
        "pet_auto" -> if (store.readStateMapping().automaticEnabled) {
            "自动状态：开启"
        } else {
            "自动状态：关闭"
        }
        "records_track" -> if (store.usageCollectionPaused) "当前：已暂停采集" else "当前：正在采集"
        "records_sync_state" ->
            if (store.usageDeviceLocalId.isEmpty()) "同步：未绑定设备" else "同步：已绑定设备"
        "settings_wheel_size" -> "轮盘大小：${menuPercent(store.menuLayoutSettings().preferredScale)}"
        "settings_button_size" ->
            "按钮大小：${menuPercent(store.menuLayoutSettings().buttonVisualScale)}"
        "pet_size_down", "pet_size_up", "pet_size_reset" ->
            "桌宠大小：${MenuPetSize.percent(store.scale)}"
        else -> null
    }

    private fun menuPercent(value: Float): String =
        "${(value * 100f).roundToInt()}%"

    private fun showMenuHint(text: String) {
        if (text.isEmpty()) return
        try {
            Toast.makeText(this, text, Toast.LENGTH_SHORT).show()
        } catch (t: Throwable) {
            // 少数 ROM 限制后台弹 Toast：只记日志，绝不影响悬浮窗。
            OverlayLog.warn("轮盘提示 Toast 失败（忽略）", t)
        }
    }

    /**
     * 在**本实例**上执行一条既有命令。
     *
     * 菜单动作来自窗口自身（服务一定在运行），因此不需要 Intent 往返：
     * 直接走 [applyCommand] 这条**唯一**的命令入口，行为与桥 / 通知完全一致。
     */
    private fun executeLocalCommand(command: OverlayCommand) {
        val commandId = commandSeq.incrementAndGet()
        OverlayLog.log("menu.command.local command=${command.name} id=$commandId")
        applyCommand(command, commandId, lastStartId)
    }

    /**
     * 让刚写入 store 的设置立刻生效。
     *
     * 走既有的**受守卫 UPDATE** 通道：`applyCommand(UPDATE)` → `manager.attach(store)`
     * → `applySettings` → `commitSceneLayout`。位置/缩放的几何逻辑**一份都不复制**。
     */
    private fun pushSettingsUpdate() {
        if (!isRunning) return
        PetOverlayService.sendGuarded(this, OverlayCommand.UPDATE)
    }

    /** 推送一条请求给 Dart；推送失败**保持 pending**，等 Dart `pullPendingMenuRequests`。 */
    private fun pushMenuRequest(request: PendingMenuRequest) {
        MenuRequestBridge.pushMenuRequest(request.toPayload()) { delivered ->
            if (delivered) {
                menuRequests.markDelivered(request.requestId)
                OverlayLog.log(
                    "menu.request.push ok requestId=${request.requestId} " +
                        "canonicalActionId=${request.actionId}",
                )
            } else {
                OverlayLog.log(
                    "menu.request.push 未送达 requestId=${request.requestId} " +
                        "canonicalActionId=${request.actionId}（保持 pending，等 Dart pull）",
                )
            }
        }
    }

    /** 把队列里所有 pending 请求推给 Dart（Flutter 引擎重建后调用，失败仍保持 pending）。 */
    private fun pushPendingToFlutter() {
        val pending = menuRequests.pending()
        if (pending.isEmpty()) return
        OverlayLog.log("menu.request.pushAll count=${pending.size}")
        pending.forEach { pushMenuRequest(it) }
    }

    /**
     * Dart 请求的参数（**原生**组装：只有原生知道当前缩放、自动开关、轮盘尺寸）。
     *
     * 导航类动作统一带 `destination`（与 Dart 侧冻结的 wire 值一致）；
     * 尺寸类动作带上当前值 + 区间 + 步进，Dart 设置页直接可用。
     */
    private fun dartRequestArgs(action: WheelMenuAction): Map<String, Any?> = when (action) {
        WheelMenuAction.toggleAutomaticState -> linkedMapOf(
            "enabled" to store.readStateMapping().automaticEnabled,
        )

        WheelMenuAction.toggleTracking -> linkedMapOf(
            "paused" to store.usageCollectionPaused,
        )

        WheelMenuAction.openStateMapping -> destinationArgs(MenuDartDestinations.STATE_ASSET_MAPPING)
        WheelMenuAction.openAssetLibrary -> destinationArgs(MenuDartDestinations.ASSET_LIBRARY)
        WheelMenuAction.openUsageStatistics ->
            destinationArgs(MenuDartDestinations.LOCAL_STATISTICS)

        WheelMenuAction.openCloudRecords -> destinationArgs(MenuDartDestinations.CLOUD_STATISTICS)
        WheelMenuAction.syncNow -> destinationArgs(MenuDartDestinations.ACCOUNT_SYNC)
        WheelMenuAction.openSettings -> destinationArgs(MenuDartDestinations.OVERLAY_SETTINGS)

        WheelMenuAction.changeMenuScale -> {
            val settings = store.menuLayoutSettings()
            linkedMapOf(
                "preferredScale" to settings.preferredScale.toDouble(),
                "minScale" to WheelMenuLayoutSettings.MIN_SCALE.toDouble(),
                "maxScale" to WheelMenuLayoutSettings.MAX_SCALE.toDouble(),
                "step" to WheelMenuLayoutSettings.STEP.toDouble(),
                "defaultScale" to WheelMenuLayoutSettings.DEFAULT_SCALE.toDouble(),
            )
        }

        WheelMenuAction.changeButtonScale -> {
            val settings = store.menuLayoutSettings()
            linkedMapOf(
                "buttonVisualScale" to settings.buttonVisualScale.toDouble(),
                "minButtonScale" to WheelMenuLayoutSettings.MIN_BUTTON_SCALE.toDouble(),
                "maxButtonScale" to WheelMenuLayoutSettings.MAX_BUTTON_SCALE.toDouble(),
                "defaultButtonScale" to WheelMenuLayoutSettings.DEFAULT_BUTTON_SCALE.toDouble(),
            )
        }

        else -> emptyMap()
    }

    private fun destinationArgs(destination: String): Map<String, Any?> =
        linkedMapOf("destination" to destination)

    /**
     * 原子几何提交的**下一帧**核对结果（4C-3B 收尾修复）。
     *
     * `delta` 超过 1px 就说明真机上出现了"桌宠抽动"——这是直接证据，必须进日志。
     */
    override fun onGeometrySettled(tag: String, deltaX: Int, deltaY: Int, settled: Boolean) {
        lastGeometryDeltaFlag = "$tag:($deltaX,$deltaY)"
        publishDiagnostics()
        logState(if (settled) "menu-geometry-settled" else "menu-geometry-jitter")
    }

    // -----------------------------------------------------------------------
    // 诊断
    // -----------------------------------------------------------------------

    private fun characterName(): String? = store.characterId

    private fun refreshNotification() {
        windowAttachedFlag = manager.isAttached
        OverlayNotification.update(this, state.hidden, characterName())
    }

    /**
     * 结构化日志（需求"十九、错误处理" + 4C-2 排障要求）。
     *
     * **绝不记录**账户密码、access / refresh token、API key —— 本服务不接触它们，
     * 这里也只写悬浮窗自身的状态。文件路径是应用私有路径，可安全记录。
     */
    private fun logState(event: String) {
        publishDiagnostics()
        publishStateDiagnostics()
        OverlayLog.log(
            "state event=$event instance=$instanceId sdk=${Build.VERSION.SDK_INT} " +
                "canDraw=${Settings.canDrawOverlays(this)} " +
                "serviceRunning=$runningFlag hidden=${state.hidden} enabled=${store.enabled} " +
                "scale=${store.scale} debug=${store.debugOverlayMode} " +
                "snapEnabled=${store.snapEnabled} edge=${store.snapEdge.name} " +
                "xRatio=${store.xRatio} yRatio=${store.yRatio} " +
                "pet=${PetOverlayService.petWidth}x${PetOverlayService.petHeight} " +
                "gesture=${PetOverlayService.gestureState} " +
                "menu=${PetOverlayService.menuState} buttons=${PetOverlayService.menuButtonCount} " +
                "lastMenuAction=${PetOverlayService.lastMenuAction ?: "<none>"} " +
                "geometryDelta=${PetOverlayService.lastGeometryDelta ?: "<none>"} " +
                "characterId=${store.characterId ?: "<none>"} " +
                "assetId=${store.assetId ?: "<none>"} " +
                "displayedAssetId=${displayedAssetIdFlag ?: "<none>"} " +
                "placeholder=$isPlaceholderFlag " +
                "mime=${store.mimeType ?: "<none>"} animated=${store.isAnimated} " +
                "visualType=${PetOverlayService.visualType} " +
                "frameMode=${PetOverlayService.animationFrameMode} " +
                "animSupported=${PetOverlayService.animationSupported} " +
                "animPlaying=${PetOverlayService.animationPlaying} " +
                "animPausedReason=${PetOverlayService.animationPausedReason ?: "<none>"} " +
                "decodeCode=${PetOverlayService.decodeCode ?: "<none>"} " +
                // --- Phase 4C-5：状态联动 ---
                "state=${PetOverlayService.stateId} stateSource=${PetOverlayService.stateSource} " +
                "stateAsset=${PetOverlayService.stateAssetId ?: "<none>"} " +
                "fallbackLevel=${PetOverlayService.stateFallbackLevel} " +
                "fgPkg=${PetOverlayService.foregroundPackage ?: "<none>"} " +
                "category=${PetOverlayService.stateCategory ?: "<none>"} " +
                "candidate=${PetOverlayService.stateCandidate ?: "<none>"}" +
                "/${PetOverlayService.stateCandidateCount} " +
                "usageAccess=${PetOverlayService.usageAccessGranted} " +
                "monitorRunning=${PetOverlayService.stateMonitorRunning} " +
                "mappingRevision=${PetOverlayService.stateMappingRevision} " +
                "manualOverride=${PetOverlayService.stateManualOverride ?: "<none>"} " +
                "stateError=${PetOverlayService.stateErrorCode ?: "<none>"} " +
                "animationPaused=${screenOff} " +
                "lastError=${lastLoadErrorFlag ?: "<none>"} " +
                manager.dump(),
        )
    }

    /**
     * 把 manager 的实况搬运到静态诊断字段（界面进程读不到 manager 实例）。
     *
     * 只要窗口状态可能变了就调一次；[logState] 里也会调，
     * 因此"服务在跑但窗口没挂上"这类问题在 `getState` 里一定能看到。
     */
    private fun publishDiagnostics() {
        // 已被新实例接管的旧实例（onDestroy 晚于新 onCreate）不得覆写全局诊断状态。
        if (activeInstance !== this) return
        val viewSize = manager.viewSize()
        val imageSize = manager.imageViewSize()
        val petSize = manager.petSize()
        publishDiagnostics(
            windowAttached = manager.isAttached,
            windowVisible = manager.isVisible,
            viewWidth = viewSize[0],
            viewHeight = viewSize[1],
            imageWidth = imageSize[0],
            imageHeight = imageSize[1],
            visual = manager.currentVisual(),
            lastWindowError = manager.lastWindowError,
            lastWindowAction = manager.lastWindowAction,
            attachedToWindow = manager.isAttachedToWindow,
            debugMode = store.debugOverlayMode,
            petWidth = petSize.width,
            petHeight = petSize.height,
            gestureState = manager.gestureStateName,
            menuState = manager.menuStateName,
            menuButtonCount = manager.menuButtonCount,
            // --- Phase 4C-4：视觉与动画诊断 ---
            visualType = currentVisualKind.wire,
            animationFrameMode = currentVisualKind.frameMode,
            animationSupported = PetVisualTypePolicy.supportsFullAnimation(Build.VERSION.SDK_INT),
            animationPlaying = manager.isAnimationRunning,
            animationPausedReason = lastAnimationPausedReason,
            decodeCode = lastDecodeCode,
        )
        publishMenuDiagnostics(
            level = manager.menuLevelName,
            activeIndex = manager.menuActiveIndex,
            animation = manager.menuAnimationName,
            gestureOwner = manager.menuGestureOwnerName,
            themeId = store.menuTheme().themeId,
            performance = manager.menuPerformanceSummary(),
            lastActionPlaceholder = manager.lastMenuActionIsPlaceholder,
            openDiagnostics = manager.menuOpenDiagnostics(),
        )
    }

    companion object {
        /**
         * 4C-4 对低版本动态素材的公开口径（设置页与日志统一用它）。
         *
         * 4C-2 的"完整动画将在 4C-4 实现"文案已随本阶段完成而**退役**：
         * 现在只有 API 24~27 才会退化为第一帧，并显示这句如实说明。
         */
        const val ANIMATED_FIRST_FRAME_FALLBACK_NOTICE =
            "当前 Android 版本不支持原生动态 WebP 播放，正在显示第一帧"

        // --- Phase 4C-5：状态联动 ---

        /**
         * 状态检测周期（需求 §11：默认 1~2 秒检测一次）。
         *
         * 集中成常量而不是散落在代码里，便于调整与测试。
         */
        const val STATE_POLL_MS = 1500L

        /** 隐藏期间的降频周期（需求 §17.2：可以暂停或降频）。 */
        const val STATE_HIDDEN_POLL_MS = 5000L

        /**
         * 临时预览的时长（Phase 4C-6A.1，需求 §11.1「约 10 秒后恢复自动状态」）。
         *
         * 到期检查复用状态轮询的**同一个 tick**，不额外起计时器。
         * 取值与 [PreviewWindow.DEFAULT_DURATION_MS] 保持一致（单测钉住）。
         */
        const val PREVIEW_DURATION_MS = PreviewWindow.DEFAULT_DURATION_MS

        /**
         * Phase 4C-5.1B：使用统计用的快照新鲜度阈值。
         *
         * 窗口被隐藏时状态机不跑，快照不会被刷新；这里在**同一个 tick** 里
         * 补一次"比阈值旧才真的查一次"的检测 —— 界面刷新与统计都不会触发高频查询。
         */
        const val USAGE_SNAPSHOT_MAX_AGE_MS = 5_000L

        /** 命令序号（诊断：证明"命令按序到达"或"有乱序"）。 */
        private val commandSeq = AtomicLong(0)

        /**
         * 当前活跃的服务实例。
         *
         * 存在的意义：`stopSelfResult` 被忽略、"停止 → 显示"连点等场景下，
         * 可能出现"新实例已经起来、旧实例的 onDestroy 才到达"。旧实例此时
         * **不允许**去取消通知或清空静态状态，否则会出现
         * "窗口还在但通知没了 / 界面说服务没运行"的假象。
         */
        @Volatile
        private var activeInstance: PetOverlayService? = null

        /** 最近一条**受守卫**命令的发出时间（丢弃更旧的命令）。 */
        @Volatile
        private var lastAppliedIssuedAt: Long = 0L

        /**
         * 服务是否正在运行。
         *
         * 用进程内标志而不是查询 ActivityManager：
         * * `getRunningServices` 从 API 26 起只返回调用者自己的服务且已被标记废弃；
         * * 服务与界面永远在同一进程（同一个 APK，没有 `:remote` 进程），
         *   所以 onCreate/onDestroy 维护的标志就是权威值。
         */
        @Volatile
        private var runningFlag: Boolean = false

        /**
         * 窗口是否当前挂在 WindowManager 上。
         *
         * 由服务在每次变更后写一次 —— 界面进程拿不到服务里的
         * [PetOverlayManager] 实例，而这个值必须精确。
         */
        @Volatile
        private var windowAttachedFlag: Boolean = false

        /** 窗口是否可见（诊断）。 */
        @Volatile
        private var windowVisibleFlag: Boolean = false

        /** 根 View 是否已附着到窗口（诊断）。 */
        @Volatile
        private var attachedToWindowFlag: Boolean = false

        @Volatile
        private var viewWidthFlag: Int = 0
        @Volatile
        private var viewHeightFlag: Int = 0
        @Volatile
        private var imageWidthFlag: Int = 0
        @Volatile
        private var imageHeightFlag: Int = 0

        /** Phase 4C-3A：窗口真实尺寸（按素材宽高比，不再是正方形）。 */
        @Volatile
        private var petWidthFlag: Int = 0
        @Volatile
        private var petHeightFlag: Int = 0

        /** Phase 4C-3A：当前手势状态名（IDLE / PRESSING / DRAGGING / …）。 */
        @Volatile
        private var gestureStateFlag: String = "IDLE"

        /** Phase 4C-3B：菜单状态名（closed / opening / open / closing）。 */
        @Volatile
        private var menuStateFlag: String = "closed"

        /** Phase 4C-3B：菜单按钮数量（诊断）。 */
        @Volatile
        private var menuButtonCountFlag: Int = 0

        /** Phase 4C-3B：最近一次菜单按钮动作（"slot_1 → 功能尚未配置"）。 */
        @Volatile
        private var lastMenuActionFlag: String? = null

        // --- Phase 4C-6B-1：轮盘诊断 ---
        @Volatile
        private var menuLevelFlag: String = "none"

        @Volatile
        private var menuActiveIndexFlag: Int = 0

        @Volatile
        private var menuAnimationFlag: String = "idle"

        @Volatile
        private var menuGestureOwnerFlag: String = "none"

        @Volatile
        private var menuThemeIdFlag: String = WheelMenuThemes.ID_P3P

        @Volatile
        private var menuPerformanceFlag: String = "wheel perf=<none>"

        @Volatile
        private var lastMenuActionPlaceholderFlag: Boolean = false

        /**
         * Phase 4C-6B-1.1 真机回归：菜单打开链路的**可判定**诊断
         * （tap / req / addAttempt / addOk / attached / vis / bounds / types / err）。
         */
        @Volatile
        private var menuOpenDiagnosticsFlag: String = "menuOpen=<none>"

        /** Phase 4C-3B 收尾修复：最近一次原子几何提交的下一帧偏差（应恒为 (0,0)）。 */
        @Volatile
        private var lastGeometryDeltaFlag: String? = null

        /** 最近一次 addView / updateViewLayout 失败原因（诊断）。 */
        @Volatile
        private var lastWindowErrorFlag: String? = null

        /** 最近一次窗口操作（含成功）——"show 之后有没有人 removeView"靠它追。 */
        @Volatile
        private var lastWindowActionFlag: String = "none"

        /** 当前可见状态名（asset / loading / failure / empty / debug）。 */
        @Volatile
        private var visualFlag: String = "empty"

        /** 诊断模式是否开启。 */
        @Volatile
        private var debugModeFlag: Boolean = false

        /** 当前**真正显示中**的素材 ID；null = 仍是占位内容。 */
        @Volatile
        private var displayedAssetIdFlag: String? = null

        /** 当前是否显示占位内容（没有任何素材成功加载）。 */
        @Volatile
        private var isPlaceholderFlag: Boolean = true

        /** Phase 4C-4：视觉类型（static / animated / placeholder）。 */
        @Volatile
        private var visualTypeFlag: String = "placeholder"

        /** Phase 4C-4：帧模式（full-animation / first-frame-fallback / not-applicable）。 */
        @Volatile
        private var animationFrameModeFlag: String = "not-applicable"

        /** Phase 4C-4：当前系统是否支持完整动画（API 28+）。 */
        @Volatile
        private var animationSupportedFlag: Boolean = false

        /** Phase 4C-4：动画当前是否真的在播放。 */
        @Volatile
        private var animationPlayingFlag: Boolean = false

        /** Phase 4C-4：最近一次"不允许播放"的原因（诊断）。 */
        @Volatile
        private var animationPausedReasonFlag: String? = null

        /** Phase 4C-4：最近一次解码错误码（成功后清空）。 */
        @Volatile
        private var decodeCodeFlag: String? = null

        // --- Phase 4C-5：状态联动（只读诊断）---

        /** 当前状态 ID（= Dart `SystemState.wireName`）。 */
        @Volatile
        private var stateIdFlag: String = PetStateId.DEFAULT

        /** 当前状态来源（`PetStateSource.wire`）。 */
        @Volatile
        private var stateSourceFlag: String = PetStateSource.unsupported.wire

        /** 当前状态的判定原因（人可读）。 */
        @Volatile
        private var stateReasonFlag: String = "尚未检测"

        /** 当前前台应用包名（隐私：只到包名这一层）。 */
        @Volatile
        private var foregroundPackageFlag: String? = null

        /** 当前前台应用标签（拿不到时为 null，界面退回显示包名）。 */
        @Volatile
        private var foregroundLabelFlag: String? = null

        /** 最近一次分类结果（`AppCategoryId`）。 */
        @Volatile
        private var stateCategoryFlag: String? = null

        /** 最近一次分类来源（`AppCategorySource.wire`）。 */
        @Volatile
        private var stateCategorySourceFlag: String? = null

        /** 候选状态（尚未通过防抖）。 */
        @Volatile
        private var stateCandidateFlag: String? = null

        /** 候选已连续出现的次数。 */
        @Volatile
        private var stateCandidateCountFlag: Int = 0

        /** 状态调试器的手动覆盖状态 ID。 */
        @Volatile
        private var stateManualOverrideFlag: String? = null

        /** 是否已授予使用情况访问权限。 */
        @Volatile
        private var usageAccessFlag: Boolean = false

        /** 状态监听任务是否在运行。 */
        @Volatile
        private var stateMonitorRunningFlag: Boolean = false

        /** 当前生效的映射版本。 */
        @Volatile
        private var stateMappingRevisionFlag: Long = 0L

        /** 当前状态选中的素材 ID（只给 ID，不给内部绝对路径）。 */
        @Volatile
        private var stateAssetIdFlag: String? = null

        /** 命中回退链的级别（1=状态素材 2=角色默认 3=任一有效 4=占位）。 */
        @Volatile
        private var stateFallbackLevelFlag: Int = 0

        /** 最近一次状态变化时间。 */
        @Volatile
        private var stateLastChangedAtFlag: Long = 0L

        /** 最近一次状态联动错误码。 */
        @Volatile
        private var stateErrorCodeFlag: String? = null

        /** Phase 4C-6A：自动状态联动是否开启（设置页诊断）。 */
        @Volatile
        private var stateAutomaticEnabledFlag: Boolean = true

        /** Phase 4C-6A：最近一次命中的规则（`user-app` / `built-in` / `launcher` / `hold` …）。 */
        @Volatile
        private var stateMatchedRuleFlag: String? = null

        /** Phase 4C-6A：自动状态联动是否开启（供桥接读取）。 */
        val automaticStateEnabled: Boolean get() = stateAutomaticEnabledFlag

        /** Phase 4C-6A：最近一次命中的规则（供桥接读取）。 */
        val stateMatchedRule: String? get() = stateMatchedRuleFlag

        // --- Phase 4C-6A 真机诊断：把"状态提交前的每一步"都暴露出来 ---
        // 这一组字段的目的是**可判定**：真机出现"状态不变"时，看一眼就知道
        // 卡在分类、规则、还是防抖，不需要再猜。

        /** 最近一次解析出来的目标状态（`resolvedTargetState`）。 */
        @Volatile
        private var stateResolvedTargetStateFlag: String? = null

        /** 候选状态首次出现的墙钟时间（毫秒，0 = 当前没有候选）。 */
        @Volatile
        private var stateCandidateSinceFlag: Long = 0L

        /** 候选状态已持续的毫秒数（单调时钟）。 */
        @Volatile
        private var stateCandidateElapsedMsFlag: Long = 0L

        /** 最近一次收到并生效的映射快照时间（毫秒，0 = 从未收到）。 */
        @Volatile
        private var stateMappingReceivedAtFlag: Long = 0L

        /** 最近一次提交结果：`committed` / `candidate` / `suppressed` / `unchanged` / `hold` / `manual` / `disabled` / `unavailable`。 */
        @Volatile
        private var stateTransitionResultFlag: String? = null

        /** 最近一次提交结果的说明。 */
        @Volatile
        private var stateTransitionReasonFlag: String? = null

        /** 分类命中的具体依据（`exact:com.android.chrome` / `keyword:game` / `platform:0` …）。 */
        @Volatile
        private var stateCategoryDetailFlag: String? = null

        /** 系统声明的分类值（`ApplicationInfo.category`，API 26+）。 */
        @Volatile
        private var statePlatformCategoryFlag: Int? = null

        /** 最近一次**真正提交**状态的时间（毫秒；0 = 从未提交）。 */
        @Volatile
        private var stateLastCommittedAtFlag: Long = 0L

        /** Phase 4C-6A.1：显示模式 `preview` / `manual` / `auto`。 */
        @Volatile
        private var stateDisplayModeFlag: String = "auto"

        /** Phase 4C-6A.1：预览中的状态（非预览时 null）。 */
        @Volatile
        private var statePreviewStateFlag: String? = null

        /** Phase 4C-6A.1：预览到期时间（毫秒；0 = 未预览）。 */
        @Volatile
        private var statePreviewExpiresAtFlag: Long = 0L

        val stateDisplayMode: String get() = stateDisplayModeFlag

        val statePreviewState: String? get() = statePreviewStateFlag

        val statePreviewExpiresAt: Long get() = statePreviewExpiresAtFlag

        val stateResolvedTargetState: String? get() = stateResolvedTargetStateFlag

        val stateCandidateSince: Long get() = stateCandidateSinceFlag

        val stateCandidateElapsedMs: Long get() = stateCandidateElapsedMsFlag

        val stateMappingReceivedAt: Long get() = stateMappingReceivedAtFlag

        val stateTransitionResult: String? get() = stateTransitionResultFlag

        val stateTransitionReason: String? get() = stateTransitionReasonFlag

        val stateCategoryDetail: String? get() = stateCategoryDetailFlag

        val statePlatformCategory: Int? get() = statePlatformCategoryFlag

        val stateLastCommittedAt: Long get() = stateLastCommittedAtFlag

        // --- Phase 4C-5 缺陷 C 修复：前台应用识别的诊断（需求 §6）---

        /** 检测来源：`activity-events` / `usage-stats-fallback` / `cache` / `unavailable`。 */
        @Volatile
        private var foregroundDetectionSourceFlag: String = ForegroundDetectionSource.unavailable.wire

        /** 检测原因 / 失败原因（如 `last-event-is-self`、`usage-access-missing`）。 */
        @Volatile
        private var foregroundDetectionReasonFlag: String? = null

        /** 窗口内事件总数。 */
        @Volatile
        private var foregroundEventCountFlag: Int = 0

        /** 其中"应用来到前台"的事件数。 */
        @Volatile
        private var foregroundResumedCountFlag: Int = 0

        /** 其中过滤后剩下的有效外部应用事件数。 */
        @Volatile
        private var foregroundUsableCountFlag: Int = 0

        /** 使用统计兜底返回的条目数。 */
        @Volatile
        private var foregroundStatsCountFlag: Int = 0

        /** 窗口内**未过滤**的最后一条前台事件包名（"最后一条到底是谁"）。 */
        @Volatile
        private var foregroundLastRawPackageFlag: String? = null

        /** AppOps 是否明确允许（与"确实能读到数据"分开报告）。 */
        @Volatile
        private var foregroundAppOpsAllowedFlag: Boolean = false

        /** 最近一次检测的窗口起点 / 终点。 */
        @Volatile
        private var foregroundQueryStartFlag: Long = 0L
        @Volatile
        private var foregroundQueryEndFlag: Long = 0L

        /** 最近一次有效外部应用事件的时间戳（缓存有效性的依据）。 */
        @Volatile
        private var foregroundLastEventTimeFlag: Long = 0L

        /** 最近一次素材加载/校验失败原因（`code: message`），成功后清空。 */
        @Volatile
        private var lastLoadErrorFlag: String? = null

        /** 最近一次素材成功显示的时间（毫秒）。 */
        @Volatile
        private var lastUpdatedAtFlag: Long = 0L

        val isRunning: Boolean get() = runningFlag

        /**
         * 当前活跃的服务实例（可能为 null）。
         *
         * 供 [PetOverlayBridge] 执行**实例级**操作（更新状态映射 / 手动覆盖）。
         * 返回 null 时这些操作会被安全忽略 —— 绝不允许为了"设置一个状态"
         * 而把没在运行的服务拉起来（那会凭空弹出一条通知）。
         */
        internal fun currentInstance(): PetOverlayService? = activeInstance

        /**
         * 双窗口探测的**只读**状态快照（Flutter `getDualWindowProbeStatus`）。
         *
         * 服务没在跑 / 探测没在跑时返回 [DualWindowProbeContract.emptyStatus]：
         * key 集不变，值退化为 `none` / 0 / false，界面卡片始终可安全渲染。
         */
        internal fun dualWindowProbeStatus(): Map<String, Any?> =
            activeInstance?.dualLayerProbeStatus() ?: DualWindowProbeContract.emptyStatus()

        /**
         * Phase 4C-6B-1：把主题即时推给正在运行的悬浮服务（需求 §13.3"改完立即生效"）。
         *
         * 服务没在跑时**什么都不做** —— 主题已经落盘，下次显示时自然生效；
         * 绝不能为了换个颜色把服务拉起来（那会凭空弹一条通知）。
         */
        internal fun applyMenuTheme(theme: WheelMenuTheme) {
            val instance = activeInstance ?: return
            instance.manager.applyMenuTheme(theme, "bridge")
            instance.publishDiagnostics()
        }

        /**
         * Phase 4C-6B-1.1：把轮盘**布局**（尺寸 / 紧凑）推给正在运行的服务。
         *
         * 服务没在跑时什么都不做（设置已落盘，下次显示时自然生效）。
         */
        internal fun applyMenuLayoutSettings(settings: WheelMenuLayoutSettings) {
            val instance = activeInstance ?: return
            instance.manager.applyMenuLayoutSettings(settings, "bridge")
            instance.publishDiagnostics()
        }

        /**
         * Phase 4C-6B-4：运行时切换单 / 双窗口模式后**即时重建**。
         *
         * 服务没在跑时什么都不做（开关已落盘，下次显示时自然生效）。
         * 必须在主线程：重建会做 attach / detach 等 WindowManager 操作（串行前提）。
         */
        internal fun rebuildForDualWindowModeChange() {
            val instance = activeInstance ?: return
            instance.mainHandler.post { instance.rebuildOverlayForModeChange("bridge-dual-window") }
        }

        /**
         * Phase 4C-6B-3：把积压的菜单请求推给 Dart。
         *
         * 由 [PetOverlayBridge] 在 Flutter 引擎（重新）建立后调用：
         * 引擎重建意味着"上一次推送很可能没送到"，这时补推一次最稳妥；
         * 推送失败仍保持 pending，Dart 回来 `pullPendingMenuRequests` 兜底。
         *
         * 服务没在跑时**什么都不做** —— 那时不会有新的菜单动作，
         * 历史积压交给 Dart 主动 pull。
         */
        internal fun pushPendingMenuRequests() {
            activeInstance?.pushPendingToFlutter()
        }

        /**
         * Phase 4C-6B-3：把一条 Dart 回报的终态变成窗口内反馈。
         *
         * @return true = 服务在运行且已展示
         */
        internal fun notifyMenuRequestResult(
            status: String,
            message: String?,
            requestId: String,
        ): Boolean {
            val instance = activeInstance ?: return false
            instance.onMenuRequestResult(status, message, requestId)
            return true
        }

        val isWindowAttached: Boolean get() = windowAttachedFlag

        val isWindowVisible: Boolean get() = windowVisibleFlag

        val isAttachedToWindow: Boolean get() = attachedToWindowFlag

        val viewWidth: Int get() = viewWidthFlag

        val viewHeight: Int get() = viewHeightFlag

        val imageViewWidth: Int get() = imageWidthFlag

        val imageViewHeight: Int get() = imageHeightFlag

        /** 窗口真实尺寸（按素材宽高比）。 */
        val petWidth: Int get() = petWidthFlag

        val petHeight: Int get() = petHeightFlag

        /** 当前手势状态名（诊断）。 */
        val gestureState: String get() = gestureStateFlag

        /** 当前菜单状态名（诊断）。 */
        val menuState: String get() = menuStateFlag

        /** 当前菜单按钮数量（诊断）。 */
        val menuButtonCount: Int get() = menuButtonCountFlag

        /** 最近一次菜单按钮动作（诊断）。 */
        val lastMenuAction: String? get() = lastMenuActionFlag

        /** Phase 4C-6B-1：轮盘当前层级 ID（`root` / `pet` / …）。 */
        val menuLevel: String get() = menuLevelFlag

        /** Phase 4C-6B-1：轮盘当前高亮槽位下标。 */
        val menuActiveIndex: Int get() = menuActiveIndexFlag

        /** Phase 4C-6B-1：轮盘当前动画（`idle` / `open` / `selectionSwitch` / …）。 */
        val menuAnimation: String get() = menuAnimationFlag

        /** Phase 4C-6B-1：轮盘手势归属（`none` / `pressing` / `swiping` / `pendingOutside`）。 */
        val menuGestureOwner: String get() = menuGestureOwnerFlag

        /** Phase 4C-6B-1：当前轮盘主题 ID。 */
        val menuThemeId: String get() = menuThemeIdFlag

        /** Phase 4C-6B-1：每帧耗时统计（需求 §15 的调试指标）。 */
        val menuPerformance: String get() = menuPerformanceFlag

        /** Phase 4C-6B-1.1：菜单打开链路的可判定诊断（真机回归用）。 */
        val menuOpenDiagnostics: String get() = menuOpenDiagnosticsFlag

        /** Phase 4C-6B-1：最近一次动作是否只是占位（业务项为 true，导航为 false）。 */
        val lastMenuActionPlaceholder: Boolean get() = lastMenuActionPlaceholderFlag

        /** 最近一次原子几何提交的下一帧偏差（诊断；正常是 "(0,0)"）。 */
        val lastGeometryDelta: String? get() = lastGeometryDeltaFlag

        val lastWindowError: String? get() = lastWindowErrorFlag

        val lastWindowAction: String get() = lastWindowActionFlag

        val visualName: String get() = visualFlag

        val debugOverlayMode: Boolean get() = debugModeFlag

        val displayedAssetId: String? get() = displayedAssetIdFlag

        val isPlaceholder: Boolean get() = isPlaceholderFlag

        /** Phase 4C-4：视觉类型 / 帧模式 / 是否支持 / 是否在播 / 为何不播 / 错误码。 */
        val visualType: String get() = visualTypeFlag

        val animationFrameMode: String get() = animationFrameModeFlag

        val animationSupported: Boolean get() = animationSupportedFlag

        val animationPlaying: Boolean get() = animationPlayingFlag

        val animationPausedReason: String? get() = animationPausedReasonFlag

        val decodeCode: String? get() = decodeCodeFlag

        /** 低版本"仅显示第一帧"（供日志与设置页口径）。 */
        val animatedFirstFrameOnly: Boolean
            get() = visualTypeFlag == "animated" && animationFrameModeFlag == "first-frame-fallback"

        // --- Phase 4C-5：状态联动（只读诊断）---

        val stateId: String get() = stateIdFlag

        val stateSource: String get() = stateSourceFlag

        val stateReason: String get() = stateReasonFlag

        val foregroundPackage: String? get() = foregroundPackageFlag

        val foregroundLabel: String? get() = foregroundLabelFlag

        val stateCategory: String? get() = stateCategoryFlag

        val stateCategorySource: String? get() = stateCategorySourceFlag

        val stateCandidate: String? get() = stateCandidateFlag

        val stateCandidateCount: Int get() = stateCandidateCountFlag

        val stateManualOverride: String? get() = stateManualOverrideFlag

        val usageAccessGranted: Boolean get() = usageAccessFlag

        val stateMonitorRunning: Boolean get() = stateMonitorRunningFlag

        val stateMappingRevision: Long get() = stateMappingRevisionFlag

        val stateAssetId: String? get() = stateAssetIdFlag

        val stateFallbackLevel: Int get() = stateFallbackLevelFlag

        val stateLastChangedAtMillis: Long get() = stateLastChangedAtFlag

        val stateErrorCode: String? get() = stateErrorCodeFlag

        // --- Phase 4C-5 缺陷 C 修复：前台应用识别诊断 ---

        val foregroundDetectionSource: String get() = foregroundDetectionSourceFlag

        val foregroundDetectionReason: String? get() = foregroundDetectionReasonFlag

        val foregroundEventCount: Int get() = foregroundEventCountFlag

        val foregroundResumedEventCount: Int get() = foregroundResumedCountFlag

        val foregroundUsableEventCount: Int get() = foregroundUsableCountFlag

        val foregroundStatsCount: Int get() = foregroundStatsCountFlag

        val foregroundLastRawPackage: String? get() = foregroundLastRawPackageFlag

        val foregroundAppOpsAllowed: Boolean get() = foregroundAppOpsAllowedFlag

        val foregroundQueryStart: Long get() = foregroundQueryStartFlag

        val foregroundQueryEnd: Long get() = foregroundQueryEndFlag

        val foregroundLastEventTime: Long get() = foregroundLastEventTimeFlag

        val lastLoadError: String? get() = lastLoadErrorFlag

        val lastUpdatedAtMillis: Long get() = lastUpdatedAtFlag

        /**
         * 由服务在每次窗口/素材变化后调用，把 [PetOverlayManager] 的实况快照到静态字段。
         *
         * 界面进程读不到服务里的 manager 实例，因此这里必须显式搬运，
         * 而不是让 `getState` 去猜。
         */
        internal fun publishDiagnostics(
            windowAttached: Boolean,
            windowVisible: Boolean,
            viewWidth: Int,
            viewHeight: Int,
            imageWidth: Int,
            imageHeight: Int,
            visual: String,
            lastWindowError: String?,
            lastWindowAction: String,
            attachedToWindow: Boolean,
            debugMode: Boolean,
            petWidth: Int,
            petHeight: Int,
            gestureState: String,
            menuState: String,
            menuButtonCount: Int,
            visualType: String,
            animationFrameMode: String,
            animationSupported: Boolean,
            animationPlaying: Boolean,
            animationPausedReason: String?,
            decodeCode: String?,
        ) {
            windowAttachedFlag = windowAttached
            windowVisibleFlag = windowVisible
            viewWidthFlag = viewWidth
            viewHeightFlag = viewHeight
            imageWidthFlag = imageWidth
            imageHeightFlag = imageHeight
            visualFlag = visual
            lastWindowErrorFlag = lastWindowError
            lastWindowActionFlag = lastWindowAction
            attachedToWindowFlag = attachedToWindow
            debugModeFlag = debugMode
            petWidthFlag = petWidth
            petHeightFlag = petHeight
            gestureStateFlag = gestureState
            menuStateFlag = menuState
            menuButtonCountFlag = menuButtonCount
            visualTypeFlag = visualType
            animationFrameModeFlag = animationFrameMode
            animationSupportedFlag = animationSupported
            animationPlayingFlag = animationPlaying
            animationPausedReasonFlag = animationPausedReason
            decodeCodeFlag = decodeCode
        }

        /**
         * Phase 4C-6B-1：轮盘的诊断快照。
         *
         * 同样**不并进** `publishDiagnostics`（那个已经有 22 个参数）——
         * 轮盘这一层会随 4C-6B-2 继续长出字段，单独一条演进线更安全。
         */
        internal fun publishMenuDiagnostics(
            level: String,
            activeIndex: Int,
            animation: String,
            gestureOwner: String,
            themeId: String,
            performance: String,
            lastActionPlaceholder: Boolean,
            openDiagnostics: String,
        ) {
            menuLevelFlag = level
            menuActiveIndexFlag = activeIndex
            menuAnimationFlag = animation
            menuGestureOwnerFlag = gestureOwner
            menuThemeIdFlag = themeId
            menuPerformanceFlag = performance
            lastMenuActionPlaceholderFlag = lastActionPlaceholder
            menuOpenDiagnosticsFlag = openDiagnostics
        }

        /**
         * Phase 4C-5：状态联动的诊断快照。
         *
         * 刻意**不**并进上面那个方法：那个方法已经有 22 个参数了，再塞 17 个
         * 会让"窗口诊断"和"状态诊断"两条演进线互相牵制。
         *
         * 隐私（需求 §26）：这里只有包名、应用标签、分类与状态 ID ——
         * 不含任何屏幕内容、输入内容、通知或聊天信息。
         */
        internal fun publishStateDiagnostics(
            stateId: String,
            stateSource: String,
            stateReason: String,
            foregroundPackage: String?,
            foregroundLabel: String?,
            category: String?,
            categorySource: String?,
            candidateState: String?,
            candidateCount: Int,
            manualOverride: String?,
            usageAccessGranted: Boolean,
            monitorRunning: Boolean,
            mappingRevision: Long,
            stateAssetId: String?,
            fallbackLevel: Int,
            lastChangedAt: Long,
            stateErrorCode: String?,
            diagnostics: ForegroundDiagnostics?,
            automaticStateEnabled: Boolean = true,
            matchedRule: String? = null,
            resolvedTargetState: String? = null,
            candidateSince: Long = 0L,
            candidateElapsedMs: Long = 0L,
            categoryDetail: String? = null,
            platformCategory: Int? = null,
            mappingReceivedAt: Long = 0L,
            transitionResult: String? = null,
            transitionReason: String? = null,
            lastCommittedAt: Long = 0L,
            displayMode: String = "auto",
            previewState: String? = null,
            previewExpiresAt: Long = 0L,
        ) {
            stateIdFlag = stateId
            stateSourceFlag = stateSource
            stateReasonFlag = stateReason
            foregroundPackageFlag = foregroundPackage
            foregroundLabelFlag = foregroundLabel
            stateCategoryFlag = category
            stateCategorySourceFlag = categorySource
            stateCandidateFlag = candidateState
            stateCandidateCountFlag = candidateCount
            stateManualOverrideFlag = manualOverride
            usageAccessFlag = usageAccessGranted
            stateMonitorRunningFlag = monitorRunning
            stateMappingRevisionFlag = mappingRevision
            stateAssetIdFlag = stateAssetId
            stateFallbackLevelFlag = fallbackLevel
            stateLastChangedAtFlag = lastChangedAt
            stateErrorCodeFlag = stateErrorCode
            // Phase 4C-6A：自动开关与命中规则（设置页诊断）。
            stateAutomaticEnabledFlag = automaticStateEnabled
            stateMatchedRuleFlag = matchedRule
            // Phase 4C-6A 真机诊断：状态提交链路的每一步。
            stateResolvedTargetStateFlag = resolvedTargetState
            stateCandidateSinceFlag = candidateSince
            stateCandidateElapsedMsFlag = candidateElapsedMs
            stateCategoryDetailFlag = categoryDetail
            statePlatformCategoryFlag = platformCategory
            stateTransitionResultFlag = transitionResult
            stateTransitionReasonFlag = transitionReason
            stateLastCommittedAtFlag = lastCommittedAt
            // Phase 4C-6A.1：显示模式与临时预览。
            stateDisplayModeFlag = displayMode
            statePreviewStateFlag = previewState
            statePreviewExpiresAtFlag = previewExpiresAt
            // 映射接收时间只能由"成功应用快照"的那一次写入 ——
            // 否则每次诊断发布都会把它刷成"刚刚"，等于没有信息量。
            if (mappingReceivedAt > 0L) stateMappingReceivedAtFlag = mappingReceivedAt
            // 前台应用识别诊断（缺陷 C 修复后新增）。
            foregroundDetectionSourceFlag =
                diagnostics?.detectionSource ?: ForegroundDetectionSource.unavailable.wire
            foregroundDetectionReasonFlag = diagnostics?.detectionFailureReason
            foregroundEventCountFlag = diagnostics?.eventCount ?: 0
            foregroundResumedCountFlag = diagnostics?.resumedEventCount ?: 0
            foregroundUsableCountFlag = diagnostics?.usableEventCount ?: 0
            foregroundStatsCountFlag = diagnostics?.statsCount ?: 0
            foregroundLastRawPackageFlag = diagnostics?.lastRawPackage
            foregroundAppOpsAllowedFlag = diagnostics?.appOpsAllowed ?: false
            foregroundQueryStartFlag = diagnostics?.queryStart ?: 0L
            foregroundQueryEndFlag = diagnostics?.queryEnd ?: 0L
            foregroundLastEventTimeFlag = diagnostics?.lastExternalEventTime ?: 0L
        }

        /**
         * 配置校验失败时由 [PetOverlayBridge] 调用。
         *
         * 服务可能压根没在运行，因此这里只写日志与错误字段，
         * 不尝试启动任何东西 —— 校验失败绝不该把服务拉起来。
         */
        internal fun recordConfigRejected(code: String, message: String) {
            lastLoadErrorFlag = "$code: $message"
        }

        /**
         * 开机自启入口（Phase 4D）—— **与界面共用同一个服务入口**。
         *
         * 只在 `BOOT_COMPLETED` / `ACTION_MY_PACKAGE_REPLACED` 接收器里调用：
         * * 这两个动作是 Android 12+ 后台启动前台服务限制的**官方豁免**，
         *   因此这里 `startForegroundService` 是合法的；
         * * `hidden = true` 时用 `START_HIDDEN`，把"用户此前隐藏了桌宠"原样保留，
         *   不把窗口弹出来（隐藏 ≠ 关闭自启）；
         * * 系统若仍然拒绝（部分 ROM 收紧策略），异常会向上抛给接收器，
         *   由它记成 `system_blocked`，**不做重试**。
         */
        internal fun startForBoot(context: Context, hidden: Boolean) {
            val command = if (hidden) OverlayCommand.START_HIDDEN else OverlayCommand.START
            val intent = OverlayActions.intent(
                context,
                command,
                guarded = false,
                trigger = OverlayActions.TRIGGER_BOOT,
            )
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        /**
         * 启动/继续服务（**必须**由可见界面里的用户操作或通知动作触发，
         * 以满足 Android 12+ 的后台启动限制）。
         */
        internal fun start(context: Context, command: OverlayCommand) {
            val intent = OverlayActions.intent(context, command, guarded = true)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        /**
         * **界面发起**的指令（已运行的服务）：带 `issuedAt`，参与过期守卫。
         *
         * 为什么界面指令必须走这条通道而不是 `stopService`：
         * * 会真正经过 [OverlayStateMachine]，`stop` 才能立刻摘窗口、
         *   记下明确的 `onDestroy` 原因；
         * * 与 `show` / `hide` 在**主线程严格串行**，配合
         *   [stopEverything] 里的 `stopSelfResult(startId)`，
         *   彻底避免"停止 → 显示"时新窗口被旧的停止请求摘掉（黑框一闪）。
         */
        internal fun sendGuarded(context: Context, command: OverlayCommand) {
            try {
                context.startService(OverlayActions.intent(context, command, guarded = true))
            } catch (t: Throwable) {
                OverlayLog.warn("发送悬浮窗指令失败（guarded）：${command.name}", t)
            }
        }

        /** 已运行的服务收指令（通知动作走这里，不受后台启动限制）。 */
        internal fun send(context: Context, command: OverlayCommand) {
            try {
                // 通知动作**不参与**过期守卫（见 [OverlayActions.EXTRA_GUARDED]）。
                context.startService(OverlayActions.intent(context, command, guarded = false))
            } catch (t: Throwable) {
                OverlayLog.warn("发送悬浮窗指令失败：${command.name}", t)
            }
        }

        /** 直接停止服务（幂等：没在运行时调用不会报错）。 */
        fun stopNow(context: Context) {
            context.stopService(Intent(context, PetOverlayService::class.java))
        }
    }
}

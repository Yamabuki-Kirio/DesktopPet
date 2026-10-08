package asia.akechi.petlife.overlay

import android.Manifest
import android.app.Activity
import android.app.NotificationManager
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Flutter ↔ 原生悬浮桌宠的 MethodChannel 桥（Phase 4C）。
 *
 * 通道名：`asia.akechi.petlife/overlay`（与 Dart 侧 `androidOverlayChannelName` 一致）。
 *
 * 方法（与需求"六、PetOverlayBridge"逐条对应）：
 * `isSupported / getPermissionStatus / requestOverlayPermission /
 *  requestNotificationPermission / start / show / hide / stop /
 *  updatePet / updateSettings / getState / openBatterySettings / openAppDetails`
 *
 * Phase 4C-6B-3 起**同一个通道**还承载菜单请求的双向通信：
 * * 原生 → Dart：`menuRequest`（由 [MenuRequestBridge] 推送）；
 * * Dart → 原生：`pullPendingMenuRequests` / `completeMenuRequest`（本类的分支）。
 *
 * 安全边界：
 * * 桥只做"转发 + 持久化"，**所有窗口操作都在 [PetOverlayService] 里**，
 *   因此界面被销毁不会留下半残窗口；
 * * 权限一律**现场复查**（`Settings.canDrawOverlays`），
 *   绝不把"打开过系统设置页"当成"已授权"；
 * * 方法必须由可见界面发起（后台启动前台服务受 Android 12+ 限制）。
 */
class PetOverlayBridge(private val activity: Activity) : MethodChannel.MethodCallHandler {

    private val store = PetOverlayStore(activity)

    /**
     * 菜单请求的**落盘句柄**（Phase 4C-6B-3）。
     *
     * 与 [PetOverlayService] 里那份指向同一份 SharedPreferences，且本类**不缓存任何状态**，
     * 因此"服务入队 + 桥拉取"不会出现两份互相矛盾的队列。
     */
    private val menuRequests: MenuRequestStore by lazy { MenuRequestStore(activity) }

    /** 正在等待系统回调的「请求通知权限」结果（同一时刻只允许一个）。 */
    private var pendingNotificationResult: MethodChannel.Result? = null

    /** 本桥注入的通道（原生 → Dart 推送与它共用同一个 MethodChannel）。 */
    private var channel: MethodChannel? = null

    /**
     * 由 `MainActivity` 在 `configureFlutterEngine` 里注入通道（Phase 4C-6B-3）。
     *
     * 注入即意味着"Flutter 引擎刚建立"：顺手把队列里积压的请求补推一次；
     * 推送失败仍保持 pending，Dart 回来 `pullPendingMenuRequests` 兜底。
     */
    internal fun attachChannel(channel: MethodChannel) {
        this.channel = channel
        MenuRequestBridge.attach(channel)
        OverlayLog.log("menu.request.channel 注入完成")
        PetOverlayService.pushPendingMenuRequests()
    }

    /** Activity 销毁时清空通道（Idempotent；只清自己那一份）。 */
    internal fun detachChannel() {
        MenuRequestBridge.detach(channel)
        channel = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        OverlayLog.log("bridge call method=${call.method}")
        try {
            when (call.method) {
                METHOD_IS_SUPPORTED -> result.success(isSupported())

                METHOD_PERMISSION_STATUS -> result.success(permissionStatus())

                METHOD_REQUEST_OVERLAY_PERMISSION -> requestOverlayPermission(result)

                METHOD_REQUEST_NOTIFICATION_PERMISSION -> requestNotificationPermission(result)

                METHOD_START -> {
                    val config = applyConfig(call.arguments)
                    if (config is ConfigResult.Rejected) {
                        // 配置有问题：**不落盘**（沿用上一次有效配置），但下面照样显示 ——
                        // 用户点了「显示桌宠」就必须看到窗口（旧素材或可见占位），
                        // 绝不能因为一张素材不合格而表现成"什么都没发生"。
                        PetOverlayService.recordConfigRejected(config.code, config.message)
                        logState("start-config-rejected code=${config.code}")
                    }
                    OverlayLog.log("showOverlay 入口 method=start accepted=${config is ConfigResult.Accepted}")
                    PetOverlayService.start(activity, OverlayCommand.START)
                    OverlayLog.log("showOverlay 出口 method=start")
                    result.success(runtimeState())
                }

                METHOD_SHOW -> {
                    PetOverlayService.start(activity, OverlayCommand.SHOW)
                    result.success(runtimeState())
                }

                METHOD_HIDE -> {
                    // 隐藏不等于停止：服务没在跑时"隐藏"是无意义的空操作，
                    // 不能因为一次隐藏就悄悄把服务拉起来（那会弹出一条通知）。
                    OverlayLog.log("hideOverlay 入口")
                    if (PetOverlayService.isRunning) {
                        PetOverlayService.sendGuarded(activity, OverlayCommand.HIDE)
                    } else {
                        OverlayLog.log("hideOverlay 跳过：服务未运行")
                    }
                    OverlayLog.log("hideOverlay 出口")
                    result.success(runtimeState())
                }

                METHOD_STOP -> {
                    OverlayLog.log("stopOverlay 入口")
                    store.clearRuntime()
                    if (PetOverlayService.isRunning) {
                        // 走**受守卫的命令通道**，而不是裸的 stopService()：
                        // 这样 stop 会经过状态机（立刻摘窗口 + 记录明确的 onDestroy 原因），
                        // 并与随后可能的 show 在主线程严格串行 ——
                        // 否则会出现"停止请求与新窗口交错、窗口刚出现就被摘掉"的黑框一闪。
                        PetOverlayService.sendGuarded(activity, OverlayCommand.STOP)
                    } else {
                        // 服务根本没在跑：stopService 是幂等空操作，顺手清干净。
                        PetOverlayService.stopNow(activity)
                    }
                    OverlayLog.log("stopOverlay 出口")
                    result.success(runtimeState())
                }

                METHOD_SET_DEBUG_OVERLAY -> {
                    val enabled = call.arguments == true
                    store.debugOverlayMode = enabled
                    OverlayLog.log("setDebugOverlay enabled=$enabled")
                    // 服务在跑就立刻生效；没跑则等下次 start 生效（store 已经写好了）。
                    if (PetOverlayService.isRunning) {
                        PetOverlayService.sendGuarded(activity, OverlayCommand.UPDATE)
                    }
                    result.success(runtimeState())
                }

                METHOD_UPDATE_PET -> {
                    when (val config = applyConfig(call.arguments)) {
                        is ConfigResult.Rejected -> {
                            PetOverlayService.recordConfigRejected(config.code, config.message)
                            logState("update-pet-rejected code=${config.code}")
                        }
                        else -> sendUpdate()
                    }
                    result.success(runtimeState())
                }

                METHOD_UPDATE_SETTINGS -> {
                    applySettings(call.arguments)
                    sendUpdate()
                    result.success(runtimeState())
                }

                METHOD_GET_STATE -> result.success(runtimeState())

                METHOD_OPEN_BATTERY_SETTINGS -> {
                    openBatterySettings()
                    result.success(null)
                }

                METHOD_OPEN_APP_DETAILS -> {
                    openAppDetails()
                    result.success(null)
                }

                // --- Phase 4C-5：状态联动 ---

                METHOD_UPDATE_STATE_MAPPING -> {
                    val outcome = service()?.updateStateMapping(call.arguments)
                    if (outcome != null && outcome.code != null &&
                        outcome.code != PetStateError.UNKNOWN_STATE
                    ) {
                        // 严重错误（revision 过期 / 解析失败）如实回报，但**不影响**服务运行：
                        // 旧映射继续生效，窗口与动画都不受影响（需求 §9 / §21）。
                        OverlayLog.warn(
                            "updateStateMapping 被拒绝 code=${outcome.code} msg=${outcome.message}",
                        )
                    }
                    result.success(runtimeState())
                }

                METHOD_SET_MANUAL_STATE -> {
                    val stateId = call.arguments as? String
                    val accepted = service()?.setManualState(stateId) ?: false
                    if (!accepted) {
                        OverlayLog.warn("setManualState 被拒绝 stateId=$stateId（服务未运行或状态未知）")
                    }
                    result.success(runtimeState())
                }

                METHOD_CLEAR_MANUAL_STATE -> {
                    service()?.setManualState(null)
                    result.success(runtimeState())
                }

                // --- Phase 4C-6A.1：临时预览（只换画面、不动状态、到期恢复）---

                METHOD_PREVIEW_STATE -> {
                    val stateId = call.arguments as? String
                    val accepted = service()?.previewState(stateId) ?: false
                    if (!accepted) {
                        OverlayLog.warn(
                            "previewState 被拒绝 stateId=$stateId（服务未运行或状态未知）",
                        )
                    }
                    result.success(runtimeState())
                }

                METHOD_CLEAR_PREVIEW -> {
                    service()?.clearPreview()
                    result.success(runtimeState())
                }

                METHOD_GET_STATE_DIAGNOSTICS -> result.success(stateDiagnostics())

                // --- 双窗口层级探测（仅诊断模式）：完整状态只读快照 ---
                METHOD_GET_DUAL_WINDOW_PROBE_STATUS ->
                    result.success(
                        runCatching { PetOverlayService.dualWindowProbeStatus() }.getOrElse {
                            OverlayLog.warn("getDualWindowProbeStatus 失败", it)
                            DualWindowProbeContract.emptyStatus()
                        },
                    )

                // --- Phase 4C-5.1A：前台应用共享快照（设置页与统计页共用同一份）---

                METHOD_GET_CURRENT_FOREGROUND_APP -> result.success(currentForegroundApp())

                METHOD_OPEN_USAGE_ACCESS_SETTINGS -> {
                    UsageAccess.openSettings(activity)
                    result.success(null)
                }

                // --- Phase 4C-5.1B：使用会话采集（journal + 当前会话 + 暂停开关）---

                METHOD_GET_CURRENT_USAGE_SESSION -> result.success(currentUsageSession())

                METHOD_READ_PENDING_USAGE_SESSIONS -> {
                    val limit = (call.arguments as? Number)?.toInt() ?: DEFAULT_IMPORT_LIMIT
                    result.success(readPendingUsageSessions(limit))
                }

                METHOD_ACKNOWLEDGE_USAGE_SESSIONS -> {
                    result.success(acknowledgeUsageSessions(extractSessionIds(call.arguments)))
                }

                METHOD_GET_USAGE_COLLECTOR_STATE -> result.success(usageCollectorState())

                METHOD_SET_USAGE_COLLECTION_PAUSED -> {
                    val paused = call.arguments == true
                    result.success(setUsageCollectionPaused(paused))
                }

                METHOD_UPDATE_USAGE_IDENTITY -> {
                    val deviceLocalId = (call.arguments as? String).orEmpty()
                    result.success(updateUsageIdentity(deviceLocalId))
                }

                METHOD_GET_MENU_THEME -> result.success(menuThemeState())

                METHOD_SET_MENU_THEME -> {
                    val outcome = applyMenuTheme(call.arguments)
                    OverlayLog.log("setMenuTheme accepted=${outcome["accepted"]}")
                    logState("set-menu-theme")
                    result.success(outcome)
                }

                METHOD_GET_MENU_LAYOUT -> result.success(menuLayoutState())

                METHOD_SET_MENU_LAYOUT -> {
                    val outcome = applyMenuLayout(call.arguments)
                    OverlayLog.log("setMenuLayout accepted=${outcome["accepted"]}")
                    logState("set-menu-layout")
                    result.success(outcome)
                }

                // --- Phase 4D：开机自启 ---

                METHOD_GET_AUTOSTART_STATUS -> result.success(autostartStatus())

                METHOD_SET_AUTOSTART -> {
                    // 写透到**原生** SharedPreferences：BOOT_COMPLETED 接收器
                    // 只能读到这里，因此 Flutter 的开关必须落到这一份。
                    val enabled = call.arguments == true
                    store.autostartEnabled = enabled
                    OverlayLog.log("setAutostart enabled=$enabled")
                    result.success(autostartStatus())
                }

                // --- Phase 4C-6B-4：双窗口悬浮层开关（单 / 双窗口运行时切换）---

                METHOD_GET_DUAL_WINDOW_MODE -> result.success(dualWindowModeState())

                METHOD_SET_DUAL_WINDOW_MODE -> {
                    val enabled = call.arguments == true
                    store.dualWindowMode = enabled
                    OverlayLog.log("setDualWindowMode enabled=$enabled")
                    // 服务在跑就立刻"拆旧模式建新模式"；没跑则等下次 start 生效（store 已写好）。
                    PetOverlayService.rebuildForDualWindowModeChange()
                    logState("set-dual-window")
                    result.success(dualWindowModeState())
                }

                // --- Phase 4C-6B-3：菜单请求（Dart -> 原生 的两个方法）---

                METHOD_PULL_PENDING_MENU_REQUESTS -> {
                    // 取走即"已交付"：同一条请求只会被交给 Dart 一次（幂等键是 requestId）。
                    val pending = menuRequests.takePending()
                    OverlayLog.log("menu.request.pull count=${pending.size}")
                    result.success(
                        linkedMapOf(
                            MenuRequestBridge.KEY_REQUESTS to MenuRequestBridge.payloadsOf(pending),
                        ),
                    )
                }

                METHOD_COMPLETE_MENU_REQUEST -> {
                    val completion = MenuRequestBridge.parseCompletion(call.arguments)
                    if (completion == null) {
                        OverlayLog.warn("completeMenuRequest 参数不合法（忽略）")
                        result.success(linkedMapOf("ok" to false))
                        return
                    }
                    val (requestId, status, message) = completion
                    // 终态会让条目出队，因此先取 canonical 动作 id 再落终态。
                    val actionId = menuRequests.actionIdOf(requestId)
                    val ok = when (status) {
                        MenuRequestBridge.STATUS_COMPLETED -> menuRequests.markCompleted(requestId)
                        MenuRequestBridge.STATUS_FAILED -> menuRequests.markFailed(requestId)
                        // 非终态（Dart 只回报"处理中"）：不改队列状态，如实回 ok=false。
                        else -> false
                    }
                    OverlayLog.log(
                        "menu.complete requestId=$requestId actionId=${actionId ?: "<unknown>"} " +
                            "status=$status ok=$ok",
                    )
                    if (ok) {
                        // 终态 → 一条窗口内反馈（菜单已收起时自动退化为既有 Toast）。
                        PetOverlayService.notifyMenuRequestResult(status, message, requestId)
                    }
                    result.success(linkedMapOf("ok" to ok))
                }

                else -> result.notImplemented()
            }
        } catch (t: Throwable) {
            OverlayLog.error("悬浮窗通道异常 method=${call.method}", t)
            result.error(CODE_FAILED, t.message ?: "悬浮窗操作失败", null)
        }
    }

    /** 由 MainActivity 转发系统权限回调；返回 true 表示这次回调由本桥消费。 */
    fun onRequestPermissionsResult(requestCode: Int, grantResults: IntArray): Boolean {
        if (requestCode != REQUEST_CODE_NOTIFICATIONS) return false
        val pending = pendingNotificationResult ?: return true
        pendingNotificationResult = null
        // 无论授权与否都返回真实状态，界面据此渲染"未授权"而不是假装成功。
        pending.success(permissionStatus())
        logState("notification-permission-result granted=${notificationsGranted()}")
        return true
    }

    // -----------------------------------------------------------------------
    // 权限
    // -----------------------------------------------------------------------

    private fun isSupported(): Boolean = Build.VERSION.SDK_INT >= MIN_OVERLAY_SDK

    private fun notificationManager(): NotificationManager? =
        activity.getSystemService(NotificationManager::class.java)

    private fun notificationsGranted(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            return activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
                PackageManager.PERMISSION_GRANTED
        }
        // API 24+ 才有 areNotificationsEnabled；被用户关掉通知也算"未授权"。
        return notificationManager()?.areNotificationsEnabled() ?: true
    }

    private fun permissionStatus(): Map<String, Any?> = linkedMapOf(
        "supported" to isSupported(),
        "overlayGranted" to Settings.canDrawOverlays(activity),
        "notificationsGranted" to notificationsGranted(),
        // 只有 Android 13+ 才需要运行时申请通知权限；界面据此决定是否显示"授权通知"按钮。
        "notificationsRequired" to (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU),
    )

    /**
     * 开机自启状态（Phase 4D）。
     *
     * 读的是**原生 SharedPreferences**（`PetOverlayStore`）—— 与服务、
     * 开机接收器用的是同一份事实；`bootResultCode` 由接收器/服务写入，
     * 界面只做展示（中文文案在 Dart 侧统一翻译）。
     */
    private fun autostartStatus(): Map<String, Any?> = linkedMapOf(
        "supported" to isSupported(),
        "enabled" to store.autostartEnabled,
        "bootResultCode" to store.bootResultCode,
        "bootResultAt" to store.bootResultAt,
        "bootResultDetail" to store.bootResultDetail,
        "overlayGranted" to Settings.canDrawOverlays(activity),
    )

    /**
     * 双窗口悬浮层状态（Phase 4C-6B-4；设置页"悬浮层运行模式"分区）。
     *
     * `enabled = true` ⇒ 双窗口（桌宠窗 + 固定菜单窗）；`false` ⇒ 旧单窗口分层实现。
     * `mode` 给界面一个稳定 wire（`dual` / `single`），无需自己拼布尔量。
     */
    private fun dualWindowModeState(): Map<String, Any?> = linkedMapOf(
        "supported" to isSupported(),
        "enabled" to store.dualWindowMode,
        "defaultEnabled" to true,
        "mode" to if (store.dualWindowMode) {
            OverlayMode.DUAL_WINDOW.wire
        } else {
            OverlayMode.SINGLE_WINDOW.wire
        },
    )

    /**
     * 打开系统的"显示在其他应用上层"授权页。
     *
     * 立刻返回**当前**状态（通常是 false）：真正是否授权只能在回到应用后
     * 重新查 `Settings.canDrawOverlays` 才知道 —— 这正是需求强调的那一点。
     */
    private fun requestOverlayPermission(result: MethodChannel.Result) {
        if (Settings.canDrawOverlays(activity)) {
            result.success(permissionStatus())
            return
        }
        val packageUri = Uri.parse("package:${activity.packageName}")
        val launched = try {
            activity.startActivity(
                Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, packageUri),
            )
            true
        } catch (t: Throwable) {
            OverlayLog.warn("无法打开悬浮窗授权页，回退到应用详情页", t)
            false
        }
        if (!launched) {
            // 少数定制系统没有这个 Activity：退到应用详情页，由用户手动开启。
            openAppDetails()
        }
        result.success(permissionStatus())
    }

    /** 请求通知权限（仅 Android 13+ 需要）；结果由 [onRequestPermissionsResult] 回填。 */
    private fun requestNotificationPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU || notificationsGranted()) {
            result.success(permissionStatus())
            return
        }
        // 上一次请求还没回来就再点一次：先把旧的那个用真实状态结掉，避免 Result 泄漏。
        pendingNotificationResult?.let {
            it.success(permissionStatus())
        }
        pendingNotificationResult = result
        activity.requestPermissions(
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            REQUEST_CODE_NOTIFICATIONS,
        )
    }

    private fun openBatterySettings() {
        // 只打开"电池优化"设置列表，让用户自己决定；
        // **不**使用 ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS（那等于自动申请白名单）。
        val candidates = listOf(
            Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS),
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                .setData(Uri.parse("package:${activity.packageName}")),
        )
        for (intent in candidates) {
            try {
                activity.startActivity(intent)
                return
            } catch (t: Throwable) {
                OverlayLog.warn("打开电池设置失败，尝试下一个入口", t)
            }
        }
    }

    private fun openAppDetails() {
        try {
            activity.startActivity(
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                    .setData(Uri.parse("package:${activity.packageName}")),
            )
        } catch (t: Throwable) {
            OverlayLog.warn("打开应用详情页失败", t)
        }
    }

    // -----------------------------------------------------------------------
    // 配置持久化
    // -----------------------------------------------------------------------

    /**
     * 写入"当前素材"相关配置（Phase 4C-2：**先校验再落盘**）。
     *
     * 只有 [ConfigResult.Accepted] 才会写进 [PetOverlayStore] ——
     * 于是"服务重启后恢复最后一个**有效**素材"这件事天然成立：
     * 存里躺着的配置永远是校验过的。
     */
    private fun applyConfig(arguments: Any?): ConfigResult {
        return when (
            val outcome = OverlayConfigValidator.validate(
                arguments = arguments,
                assetsRoots = PetOverlayConfig.privateAssetRoots(activity),
            )
        ) {
            is ConfigResult.Accepted -> {
                outcome.config.applyTo(store)
                OverlayLog.log(
                    "config accepted asset=${outcome.config.assetId} " +
                        "matchedRoot=${outcome.matchedRoot ?: "?"} " +
                        "file=${outcome.config.filePath}",
                )
                outcome
            }
            is ConfigResult.Rejected -> {
                OverlayLog.warn("config-rejected code=${outcome.code} msg=${outcome.message}")
                outcome
            }
            ConfigResult.Absent -> ConfigResult.Absent
        }
    }

    /** 写入"悬浮窗外观/行为"设置。 */
    private fun applySettings(arguments: Any?) {
        val map = arguments as? Map<*, *> ?: return

        (map["scale"] as? Number)?.let { store.scale = it.toFloat() }
        (map["snapEnabled"] as? Boolean)?.let { store.snapEnabled = it }
        (map["touchThrough"] as? Boolean)?.let { store.touchThrough = it }
        (map["hideOnLockScreen"] as? Boolean)?.let { store.hideOnLockScreen = it }
        (map["fixedAssetMode"] as? Boolean)?.let { store.fixedAssetMode = it }
        // 只有界面**显式**带上来时才改位置/吸附边；不传 = 不动用户拖出来的位置。
        (map["xRatio"] as? Number)?.let { store.xRatio = it.toFloat() }
        (map["yRatio"] as? Number)?.let { store.yRatio = it.toFloat() }
        (map["snapEdge"] as? String)?.let { store.snapEdge = OverlaySnapEdge.fromWire(it) }
    }

    private fun sendUpdate() {
        // UPDATE 不会被解释成"启动"：服务没跑时它什么也不做。
        // 用受守卫通道：界面连续调整时，旧设置不会覆盖新设置。
        if (PetOverlayService.isRunning) {
            PetOverlayService.sendGuarded(activity, OverlayCommand.UPDATE)
        }
    }

    /** 当前活跃的服务实例（状态联动是**实例级**行为，必须在实例上执行）。 */
    private fun service(): PetOverlayService? = PetOverlayService.currentInstance()

    /**
     * 状态联动的只读诊断（需求 §19）。
     *
     * 刻意**不**并进 [runtimeState]：那张表已经很长，而状态诊断需要界面按需单独刷新；
     * 分开也便于后续单独演进。
     *
     * 隐私：只有状态 ID / 包名 / 应用标签 / 分类 / 素材 ID —— **没有**任何绝对路径与内容。
     */
    private fun stateDiagnostics(): Map<String, Any?> = linkedMapOf(
        "stateId" to PetOverlayService.stateId,
        "stateLabel" to PetStateId.descriptionZh(PetOverlayService.stateId),
        "stateSource" to PetOverlayService.stateSource,
        "stateReason" to PetOverlayService.stateReason,
        "foregroundPackage" to PetOverlayService.foregroundPackage,
        "foregroundLabel" to PetOverlayService.foregroundLabel,
        "category" to PetOverlayService.stateCategory,
        "categorySource" to PetOverlayService.stateCategorySource,
        "candidateState" to PetOverlayService.stateCandidate,
        "candidateCount" to PetOverlayService.stateCandidateCount,
        "manualOverride" to PetOverlayService.stateManualOverride,
        // 权限判定要同时看"现场复查"与"服务实际检测结论"：
        // 只要有一条成立就不该对用户显示"未授权"（个别 ROM 的 AppOps 口径不准）。
        "usageAccessGranted" to (
            UsageAccess.isGranted(activity) || PetOverlayService.usageAccessGranted
            ),
        "monitorRunning" to PetOverlayService.stateMonitorRunning,
        "mappingRevision" to PetOverlayService.stateMappingRevision,
        // --- Phase 4C-6A：自动状态联动（设置页诊断）---
        "automaticStateEnabled" to PetOverlayService.automaticStateEnabled,
        "matchedRule" to PetOverlayService.stateMatchedRule,
        // --- Phase 4C-6A 真机诊断：状态提交链路的每一步（全部来自原生服务）---
        // 这些字段存在的唯一目的：真机出现"切换应用后状态不变"时，
        // 在设置页就能判断卡在**分类 / 规则 / 防抖提交**哪一步，不需要再猜。
        "resolvedTargetState" to PetOverlayService.stateResolvedTargetState,
        "candidateSince" to PetOverlayService.stateCandidateSince,
        "candidateElapsedMs" to PetOverlayService.stateCandidateElapsedMs,
        "stableState" to PetOverlayService.stateId,
        "categoryDetail" to PetOverlayService.stateCategoryDetail,
        "platformAppCategory" to PetOverlayService.statePlatformCategory,
        "mappingReceivedAt" to PetOverlayService.stateMappingReceivedAt,
        "lastTransitionResult" to PetOverlayService.stateTransitionResult,
        "lastTransitionReason" to PetOverlayService.stateTransitionReason,
        "lastCommittedAt" to PetOverlayService.stateLastCommittedAt,
        // --- Phase 4C-6A.1：显示模式与临时预览（需求 §11.2 / §15）---
        "displayMode" to PetOverlayService.stateDisplayMode,
        "previewState" to PetOverlayService.statePreviewState,
        "previewExpiresAt" to PetOverlayService.statePreviewExpiresAt,
        // 采集器 = 悬浮服务里的**唯一**轮询任务（4C-5.1A 的共享快照由它驱动）。
        "collectorRunning" to PetOverlayService.stateMonitorRunning,
        "stateAssetId" to PetOverlayService.stateAssetId,
        "fallbackLevel" to PetOverlayService.stateFallbackLevel,
        "lastChangedAt" to PetOverlayService.stateLastChangedAtMillis,
        "stateErrorCode" to PetOverlayService.stateErrorCode,
        // --- Phase 4C-5 缺陷 C 修复：前台应用识别诊断（需求 §6）---
        // AppOps 与"确实能读到数据"分开报告：两者不一致时一眼能看出是权限口径问题。
        "foregroundDetectionSource" to PetOverlayService.foregroundDetectionSource,
        "foregroundDetectionReason" to PetOverlayService.foregroundDetectionReason,
        "foregroundEventCount" to PetOverlayService.foregroundEventCount,
        "foregroundResumedEventCount" to PetOverlayService.foregroundResumedEventCount,
        "foregroundUsableEventCount" to PetOverlayService.foregroundUsableEventCount,
        "foregroundStatsCount" to PetOverlayService.foregroundStatsCount,
        "foregroundLastRawPackage" to PetOverlayService.foregroundLastRawPackage,
        "foregroundAppOpsAllowed" to PetOverlayService.foregroundAppOpsAllowed,
        "foregroundQueryStart" to PetOverlayService.foregroundQueryStart,
        "foregroundQueryEnd" to PetOverlayService.foregroundQueryEnd,
        "foregroundLastEventTime" to PetOverlayService.foregroundLastEventTime,
    )

    // -----------------------------------------------------------------------
    // Phase 4C-5.1A：前台应用共享快照
    // -----------------------------------------------------------------------

    /**
     * 当前前台应用的**只读**快照（需求 §3.3）。
     *
     * 界面刷新走这里，**不会**直接查询 `UsageStatsManager`：
     * * 正常由服务里的唯一轮询任务每 1.5 秒更新共享快照，界面只读；
     * * 只有当快照比 [SNAPSHOT_STALE_MS] 更旧（例如服务刚起、或刚被系统唤醒）时，
     *   才补一次真正的检测。
     */
    private fun currentForegroundApp(): Map<String, Any?> {
        val service = PetOverlayService.currentInstance()
        service?.refreshForegroundSnapshotIfStale(SNAPSHOT_STALE_MS)
        val snapshot = ForegroundAppRegistry.current
        val usageAccess = UsageAccess.isGranted(activity)
        val collectorRunning = service != null && ForegroundAppRegistry.collectorRunning
        return linkedMapOf(
            "available" to (snapshot?.hasApp == true),
            "packageName" to snapshot?.packageName,
            "appLabel" to snapshot?.appLabel,
            "category" to snapshot?.category,
            "categorySource" to snapshot?.categorySource,
            "detectionSource" to
                (snapshot?.source ?: ForegroundDetectionSource.unavailable.wire),
            "detectionReason" to snapshot?.reason,
            "eventTime" to (snapshot?.eventTime ?: 0L),
            "detectedAt" to (snapshot?.detectedAt ?: 0L),
            "usageAccessAvailable" to usageAccess,
            "appOpsAllowed" to (snapshot?.appOpsAllowed ?: false),
            "collectorRunning" to collectorRunning,
            "eventCount" to (snapshot?.eventCount ?: 0),
            "resumedEventCount" to (snapshot?.resumedEventCount ?: 0),
            "usableEventCount" to (snapshot?.usableEventCount ?: 0),
            "lastRawPackage" to snapshot?.lastRawPackage,
            "failureReason" to failureReasonOf(
                snapshot = snapshot,
                usageAccessAvailable = usageAccess,
                serviceRunning = service != null,
                collectorRunning = collectorRunning,
            ),
        )
    }

    /**
     * 给界面一个**单一**可读的失败原因（避免界面自己拼状态）。
     *
     * 采集器与会话的独立通道见 `getUsageCollectorState` / `getCurrentUsageSession`
     * （Phase 4C-5.1B）；本方法只描述"前台识别这一件事"为什么没结果。
     */
    private fun failureReasonOf(
        snapshot: SharedForegroundApp?,
        usageAccessAvailable: Boolean,
        serviceRunning: Boolean,
        collectorRunning: Boolean,
    ): String? = when {
        !usageAccessAvailable -> "usage_access_missing"
        !serviceRunning -> "collector_not_running"
        !collectorRunning -> "collector_paused_or_stopped"
        snapshot == null -> "foreground_unavailable"
        !snapshot.hasApp -> snapshot.reason ?: "foreground_unavailable"
        else -> null
    }

    // -----------------------------------------------------------------------
    // Phase 4C-5.1B：使用会话采集
    // -----------------------------------------------------------------------

    /**
     * journal 的**桥侧**句柄。
     *
     * 为什么桥自己持有一份而不是只用服务里的那份：导入与确认必须在
     * **悬浮服务没在运行**时也能工作（冷启动、用户刚打开统计页但还没显示桌宠）。
     * 两次实例指向同一个目录；所有通道回调与服务的轮询都在主线程串行执行，
     * 因此不存在并发写同一文件的问题。
     */
    private val usageJournal: UsageSessionJournal by lazy {
        UsageSessionJournal.of(activity.filesDir)
    }

    /** 读取待导入会话（限制条数，避免一次传输过大；需求 §5）。 */
    private fun readPendingUsageSessions(limit: Int): List<Map<String, Any?>> {
        val safeLimit = limit.coerceIn(1, MAX_IMPORT_LIMIT)
        val records = usageJournal.readPending(safeLimit)
        OverlayLog.log("usage.import.read limit=$safeLimit returned=${records.size}")
        return records.map { it.toBridgeMap() }
    }

    /**
     * 按 `session_id` 确认并删除。
     *
     * **只有 Flutter 本地事务成功之后才会调用**（需求 §5 / §6.2）；
     * 桥接异常绝不删除 journal。
     */
    private fun acknowledgeUsageSessions(sessionIds: List<String>): Int {
        val removed = usageJournal.acknowledge(sessionIds)
        if (removed > 0) OverlayLog.log("usage.import.ack count=$removed")
        return removed
    }

    /** 当前进行中的会话（没有则返回 null；界面据此显示「使用中」）。 */
    private fun currentUsageSession(): Map<String, Any?>? {
        val recorder = service()?.usageRecorderOrNull() ?: return null
        val open = recorder.currentSession() ?: return null
        return linkedMapOf(
            "sessionId" to open.sessionId,
            "packageName" to open.packageName,
            "appName" to open.appName,
            "category" to open.category,
            "startedAt" to open.startedAt,
            "elapsedSeconds" to recorder.currentElapsedSeconds(),
        )
    }

    /** 采集器状态 + journal 摘要（设置页诊断区，需求 §12）。 */
    private fun usageCollectorState(): Map<String, Any?> {
        val running = PetOverlayService.isRunning
        val recorder = service()?.usageRecorderOrNull()
        val summary = usageJournal.summary()
        val usageAccess = UsageAccess.isGranted(activity)
        return linkedMapOf(
            "supported" to isSupported(),
            "running" to running,
            "paused" to store.usageCollectionPaused,
            "usageAccessAvailable" to usageAccess,
            "collectorRunning" to (running && ForegroundAppRegistry.collectorRunning),
            "journalAvailable" to (summary["available"] ?: false),
            "pendingCount" to (summary["pending"] ?: 0),
            "corruptLines" to (summary["corruptLines"] ?: 0),
            "droppedForCapacity" to (summary["droppedForCapacity"] ?: 0),
            "deviceLocalIdSet" to store.usageDeviceLocalId.isNotEmpty(),
            "currentSessionSeconds" to (recorder?.currentElapsedSeconds() ?: 0),
            // 缺权限 / 服务未运行时的**单一**失败原因，界面不自己拼状态。
            "failureReason" to when {
                !usageAccess -> "usage_access_missing"
                !running -> "collector_not_running"
                !ForegroundAppRegistry.collectorRunning -> "collector_paused_or_stopped"
                else -> null
            },
        )
    }

    /**
     * 切换采集暂停。
     *
     * 先写进原生持久化（服务重启后仍生效），再作用到正在运行的采集器上；
     * 暂停时立即结束当前会话（需求 §9）。
     */
    private fun setUsageCollectionPaused(paused: Boolean): Boolean {
        store.usageCollectionPaused = paused
        service()?.usageRecorderOrNull()?.setPaused(paused)
        OverlayLog.log("usage.paused.set paused=$paused")
        return true
    }

    /**
     * 下发本机稳定设备标识（**额外**于需求 §5 的五个方法）。
     *
     * 需求 §3.2 要求 journal 记录里带 `device_local_id`，而它只有 Dart 侧知道
     * （`DeviceIdentity` 生成并持久化）。Flutter 仍然是这一字段的权威来源：
     * 原生只是把它落到 SharedPreferences，由会话状态机在**每次写记录时**读取
     * （`AndroidUsageSessionTracker.deviceLocalId` 直接读 store，不缓存第二份真相）。
     */
    private fun updateUsageIdentity(deviceLocalId: String): Boolean {
        store.usageDeviceLocalId = deviceLocalId
        OverlayLog.log(
            "usage.identity.updated deviceLocalId=${deviceLocalId.ifEmpty { "<empty>" }}",
        )
        return true
    }

    /** 从桥参数里安全提取 `session_id` 列表（类型不符一律忽略，不猜）。 */
    private fun extractSessionIds(arguments: Any?): List<String> {
        if (arguments !is List<*>) return emptyList()
        return arguments.mapNotNull { it as? String }.filter { it.isNotEmpty() }
    }

    /** 一条会话记录的桥接表示（字段名与 Dart 侧模型一一对应）。 */
    private fun UsageSessionRecord.toBridgeMap(): Map<String, Any?> = linkedMapOf(
        "sessionId" to sessionId,
        "deviceLocalId" to deviceLocalId,
        "packageName" to packageName,
        "appName" to appName,
        "category" to category,
        "startedAt" to startedAt,
        "endedAt" to endedAt,
        "activeSeconds" to activeSeconds,
        "endReason" to endReason,
        "createdAt" to createdAt,
        "schemaVersion" to schemaVersion,
    )

    // -----------------------------------------------------------------------
    // 状态
    // -----------------------------------------------------------------------

    private fun runtimeState(): Map<String, Any?> = linkedMapOf(
        "supported" to isSupported(),
        "serviceRunning" to PetOverlayService.isRunning,
        "windowAttached" to PetOverlayService.isWindowAttached,
        "enabled" to store.enabled,
        "hidden" to store.hidden,
        "overlayGranted" to Settings.canDrawOverlays(activity),
        "notificationsGranted" to notificationsGranted(),
        "characterId" to store.characterId,
        "assetId" to store.assetId,
        "mimeType" to store.mimeType,
        "isAnimated" to store.isAnimated,
        "frameCount" to store.frameCount,
        "animationDurationMs" to store.animationDurationMs,
        "scale" to store.scale.toDouble(),
        "snapEnabled" to store.snapEnabled,
        "snapEdge" to store.snapEdge.name,
        "snapOrientation" to store.snapOrientation,
        "touchThrough" to store.touchThrough,
        "hideOnLockScreen" to store.hideOnLockScreen,
        "fixedAssetMode" to store.fixedAssetMode,
        // --- Phase 4C-6B-4：双窗口悬浮层（只读诊断）---
        "dualWindowMode" to store.dualWindowMode,
        "xRatio" to store.xRatio.toDouble(),
        "yRatio" to store.yRatio.toDouble(),
        // --- Phase 4C-2：素材加载状态反馈（需求第七节）---
        "displayedAssetId" to PetOverlayService.displayedAssetId,
        "isPlaceholder" to PetOverlayService.isPlaceholder,
        "lastLoadError" to PetOverlayService.lastLoadError,
        "lastUpdatedAt" to PetOverlayService.lastUpdatedAtMillis,
        "animatedFirstFrameOnly" to PetOverlayService.animatedFirstFrameOnly,
        // --- Phase 4C-2 加固：窗口诊断（"服务在跑但看不见"必须能一眼看出）---
        "windowVisible" to PetOverlayService.isWindowVisible,
        "attachedToWindow" to PetOverlayService.isAttachedToWindow,
        "viewWidth" to PetOverlayService.viewWidth,
        "viewHeight" to PetOverlayService.viewHeight,
        "imageViewWidth" to PetOverlayService.imageViewWidth,
        "imageViewHeight" to PetOverlayService.imageViewHeight,
        "lastWindowError" to PetOverlayService.lastWindowError,
        "lastWindowAction" to PetOverlayService.lastWindowAction,
        "visual" to PetOverlayService.visualName,
        "debugOverlayMode" to PetOverlayService.debugOverlayMode,
        // --- Phase 4C-3A：位置 / 尺寸 / 手势（拖动与缩放的状态反馈）---
        "petWidth" to PetOverlayService.petWidth,
        "petHeight" to PetOverlayService.petHeight,
        "gestureState" to PetOverlayService.gestureState,
        // --- Phase 4C-3B：圆盘菜单（只读诊断；界面不驱动菜单）---
        "menuState" to PetOverlayService.menuState,
        "menuButtonCount" to PetOverlayService.menuButtonCount,
        "lastMenuAction" to PetOverlayService.lastMenuAction,
        // --- Phase 4C-4：视觉与动画（只读诊断；Flutter 绝不逐帧驱动动画）---
        "visualType" to PetOverlayService.visualType,
        "animationFrameMode" to PetOverlayService.animationFrameMode,
        "animationSupported" to PetOverlayService.animationSupported,
        "animationPlaying" to PetOverlayService.animationPlaying,
        "animationPausedReason" to PetOverlayService.animationPausedReason,
        "decodeCode" to PetOverlayService.decodeCode,
        // --- Phase 4C-6B-1：轮盘（只读诊断；界面不驱动菜单动画）---
        "menuLevel" to PetOverlayService.menuLevel,
        "menuActiveIndex" to PetOverlayService.menuActiveIndex,
        "menuAnimation" to PetOverlayService.menuAnimation,
        "menuGestureOwner" to PetOverlayService.menuGestureOwner,
        "menuThemeId" to PetOverlayService.menuThemeId,
        "menuPerformance" to PetOverlayService.menuPerformance,
        "menuOpenDiagnostics" to PetOverlayService.menuOpenDiagnostics,
        "lastMenuActionPlaceholder" to PetOverlayService.lastMenuActionPlaceholder,
    )

    // -----------------------------------------------------------------------
    // 轮盘主题（Phase 4C-6B-1）
    // -----------------------------------------------------------------------

    /**
     * 读取轮盘主题（设置页"轮盘主题"分区用）。
     *
     * 返回 preset 列表 + 当前生效色板 + 持久化开关；
     * `revision` 供 Flutter 侧**续接计数器**（否则重启后新主题会被旧 revision 挡住）。
     */
    private fun menuThemeState(): Map<String, Any?> {
        val theme = store.menuTheme()
        return linkedMapOf(
            "themeId" to theme.themeId,
            "displayName" to theme.displayName,
            "revision" to store.menuThemeRevision,
            "customPrimary" to WheelMenuThemes.toHex(store.menuCustomPrimary),
            "legible" to WheelMenuThemes.isLegible(theme),
            "contrast" to WheelMenuThemes.contrastRatio(theme.text, theme.primary),
            "current" to themeColors(theme),
            "presets" to WheelMenuThemes.presets.map { preset ->
                linkedMapOf(
                    "themeId" to preset.themeId,
                    "displayName" to preset.displayName,
                    "colors" to themeColors(preset),
                )
            },
            "menuDistanceRatio" to store.menuDistanceRatio.toDouble(),
            "hapticsEnabled" to store.menuHapticsEnabled,
            "soundEnabled" to store.menuSoundEnabled,
            "swipeEnabled" to store.menuSwipeEnabled,
            "swipeSensitivity" to store.menuSwipeSensitivity,
        )
    }

    /**
     * 写入轮盘主题并**立即推送**给正在运行的悬浮服务（需求 §13.3）。
     *
     * 校验顺序（任何一条不过都不落盘、不改变现状）：
     * 1. 参数必须是 map，且带单调 `revision`；
     * 2. 预设 ID 必须存在；自定义主色必须是不透明的合法颜色；
     * 3. revision 不能比已存的小（防止旧配置覆盖新配置）。
     */
    private fun applyMenuTheme(arguments: Any?): Map<String, Any?> {
        val map = arguments as? Map<*, *> ?: return rejectedTheme("invalid_arguments")
        val themeId = (map["themeId"] as? String)?.trim().orEmpty()
        val revision = (map["revision"] as? Number)?.toLong() ?: return rejectedTheme("missing_revision")
        val customPrimary = (map["customPrimary"] as? Number)?.toInt()
        if (customPrimary != null && !WheelMenuThemes.isUsableColor(customPrimary)) {
            return rejectedTheme("invalid_color")
        }
        val theme = when {
            themeId.isEmpty() || themeId == WheelMenuTheme.ID_CUSTOM ->
                WheelMenuThemes.custom(customPrimary ?: store.menuCustomPrimary)
            else -> WheelMenuThemes.preset(themeId) ?: return rejectedTheme("unknown_theme")
        }
        if (revision < store.menuThemeRevision) return rejectedTheme("stale_revision")
        if (!store.writeMenuTheme(theme, revision)) return rejectedTheme("stale_revision")
        PetOverlayService.applyMenuTheme(theme)
        return menuThemeState() + ("accepted" to true)
    }

    private fun rejectedTheme(code: String): Map<String, Any?> =
        linkedMapOf<String, Any?>(
            "accepted" to false,
            "errorCode" to code,
        )

    private fun themeColors(theme: WheelMenuTheme): Map<String, Any?> = linkedMapOf(
        "primary" to WheelMenuThemes.toHex(theme.primary),
        "secondary" to WheelMenuThemes.toHex(theme.secondary),
        "background" to WheelMenuThemes.toHex(theme.background),
        "highlight" to WheelMenuThemes.toHex(theme.highlight),
        "outline" to WheelMenuThemes.toHex(theme.outline),
        "text" to WheelMenuThemes.toHex(theme.text),
        "disabled" to WheelMenuThemes.toHex(theme.disabled),
        "gradientEnabled" to theme.gradientEnabled,
    )

    // -----------------------------------------------------------------------
    // 轮盘布局（Phase 4C-6B-1.1：尺寸 / 紧凑）
    // -----------------------------------------------------------------------

    /** 读取轮盘布局设置（设置页「轮盘大小」用）。 */
    private fun menuLayoutState(): Map<String, Any?> {
        val settings = store.menuLayoutSettings()
        return linkedMapOf(
            "preferredScale" to settings.preferredScale.toDouble(),
            "buttonVisualScale" to settings.buttonVisualScale.toDouble(),
            "menuDistance" to settings.menuDistance.toDouble(),
            "compactMode" to settings.compactMode,
            "revision" to settings.revision,
            "minScale" to WheelMenuLayoutSettings.MIN_SCALE.toDouble(),
            "maxScale" to WheelMenuLayoutSettings.MAX_SCALE.toDouble(),
            "step" to WheelMenuLayoutSettings.STEP.toDouble(),
            "defaultScale" to WheelMenuLayoutSettings.DEFAULT_SCALE.toDouble(),
            "minButtonScale" to WheelMenuLayoutSettings.MIN_BUTTON_SCALE.toDouble(),
            "maxButtonScale" to WheelMenuLayoutSettings.MAX_BUTTON_SCALE.toDouble(),
            "defaultButtonScale" to WheelMenuLayoutSettings.DEFAULT_BUTTON_SCALE.toDouble(),
        )
    }

    /**
     * 写入轮盘布局设置并立即生效（需求 §5 / §12）。
     *
     * 校验：参数必须是 map；带单调 `revision`；轮盘比例会被夹到 **0.50~2.50** 并**吸附到 10% 步进**；
     * 按钮比例夹到 **0.50~2.50**（不吸附，保持连续手感）。
     */
    private fun applyMenuLayout(arguments: Any?): Map<String, Any?> {
        val map = arguments as? Map<*, *> ?: return rejectedTheme("invalid_arguments")
        val revision = (map["revision"] as? Number)?.toLong()
            ?: return rejectedTheme("missing_revision")
        val rawScale = (map["preferredScale"] as? Number)?.toFloat()
            ?: store.menuLayoutSettings().preferredScale
        val rawButton = (map["buttonVisualScale"] as? Number)?.toFloat()
            ?: store.menuLayoutSettings().buttonVisualScale
        val compact = map["compactMode"] as? Boolean ?: store.menuLayoutSettings().compactMode
        if (revision < store.menuLayoutRevision) return rejectedTheme("stale_revision")
        val settings = WheelMenuLayoutSettings(
            preferredScale = WheelMenuLayoutSettings.quantizeScale(rawScale),
            menuDistance = store.menuLayoutSettings().menuDistance,
            buttonVisualScale = WheelMenuLayoutSettings.quantizeButtonScale(rawButton),
            compactMode = compact,
            revision = revision,
        )
        if (!store.writeMenuLayoutSettings(settings, revision)) {
            return rejectedTheme("stale_revision")
        }
        PetOverlayService.applyMenuLayoutSettings(settings)
        return menuLayoutState() + ("accepted" to true)
    }

    private fun logState(event: String) {
        OverlayLog.log(
            "bridge event=$event sdk=${Build.VERSION.SDK_INT} " +
                "target=${activity.applicationInfo.targetSdkVersion} " +
                "canDraw=${Settings.canDrawOverlays(activity)} " +
                "notif=${notificationsGranted()} " +
                "serviceRunning=${PetOverlayService.isRunning} " +
                "windowAttached=${PetOverlayService.isWindowAttached} " +
                "windowVisible=${PetOverlayService.isWindowVisible} " +
                "view=${PetOverlayService.viewWidth}x${PetOverlayService.viewHeight} " +
                "visual=${PetOverlayService.visualName} " +
                "hidden=${store.hidden} enabled=${store.enabled} " +
                "scale=${store.scale} snapEnabled=${store.snapEnabled} edge=${store.snapEdge.name} " +
                "xRatio=${store.xRatio} yRatio=${store.yRatio} " +
                "menu=${PetOverlayService.menuState} menuButtons=${PetOverlayService.menuButtonCount} " +
                "gesture=${PetOverlayService.gestureState} " +
                "characterId=${store.characterId ?: "<none>"} " +
                "assetId=${store.assetId ?: "<none>"} " +
                "displayedAssetId=${PetOverlayService.displayedAssetId ?: "<none>"} " +
                "mime=${store.mimeType ?: "<none>"} animated=${store.isAnimated} " +
                "lastError=${PetOverlayService.lastLoadError ?: "<none>"} " +
                "lastWindowError=${PetOverlayService.lastWindowError ?: "<none>"}",
        )
    }

    companion object {

        /** 与 Dart 侧 `androidOverlayChannelName` 必须完全一致。 */
        const val CHANNEL_NAME = "asia.akechi.petlife/overlay"

        /** 悬浮窗能力的最低 API（SYSTEM_ALERT_WINDOW 从 API 23 起）。 */
        const val MIN_OVERLAY_SDK = 23

        const val REQUEST_CODE_NOTIFICATIONS = 4901

        const val CODE_FAILED = "overlay_failed"

        // --- Phase 4C-6B-1：轮盘主题（设置页 → 悬浮桌宠 → 轮盘主题）---
        private const val METHOD_GET_MENU_THEME = "getMenuTheme"
        private const val METHOD_SET_MENU_THEME = "setMenuTheme"
        private const val METHOD_GET_MENU_LAYOUT = "getMenuLayout"
        private const val METHOD_SET_MENU_LAYOUT = "setMenuLayout"

        // --- Phase 4D：开机自启（开关 + 最近一次开机结果）---
        private const val METHOD_GET_AUTOSTART_STATUS = "getAutostartStatus"
        private const val METHOD_SET_AUTOSTART = "setAutostart"

        // --- Phase 4C-6B-4：双窗口悬浮层（单 / 双窗口运行时切换）---
        private const val METHOD_GET_DUAL_WINDOW_MODE = "getDualWindowMode"
        private const val METHOD_SET_DUAL_WINDOW_MODE = "setDualWindowMode"

        // --- Phase 4C-6B-3：菜单请求（与 Dart 侧冻结契约逐字一致）---
        /** Dart → 原生：拉取尚未交付的请求。 */
        private const val METHOD_PULL_PENDING_MENU_REQUESTS = "pullPendingMenuRequests"

        /** Dart → 原生：回报一条请求的终态（`{requestId, status, message}`）。 */
        private const val METHOD_COMPLETE_MENU_REQUEST = "completeMenuRequest"

        private const val METHOD_IS_SUPPORTED = "isSupported"
        private const val METHOD_PERMISSION_STATUS = "getPermissionStatus"
        private const val METHOD_REQUEST_OVERLAY_PERMISSION = "requestOverlayPermission"
        private const val METHOD_REQUEST_NOTIFICATION_PERMISSION = "requestNotificationPermission"
        private const val METHOD_START = "start"
        private const val METHOD_SHOW = "show"
        private const val METHOD_HIDE = "hide"
        private const val METHOD_STOP = "stop"
        private const val METHOD_UPDATE_PET = "updatePet"
        private const val METHOD_UPDATE_SETTINGS = "updateSettings"
        private const val METHOD_GET_STATE = "getState"
        private const val METHOD_SET_DEBUG_OVERLAY = "setDebugOverlay"
        private const val METHOD_OPEN_BATTERY_SETTINGS = "openBatterySettings"
        private const val METHOD_OPEN_APP_DETAILS = "openAppDetails"

        // --- Phase 4C-5：状态联动 ---
        private const val METHOD_UPDATE_STATE_MAPPING = "updateStateMapping"
        private const val METHOD_SET_MANUAL_STATE = "setManualState"
        private const val METHOD_CLEAR_MANUAL_STATE = "clearManualState"

        /** Phase 4C-6A.1：临时预览某状态的素材 / 立刻结束预览。 */
        private const val METHOD_PREVIEW_STATE = "previewState"
        private const val METHOD_CLEAR_PREVIEW = "clearPreview"
        private const val METHOD_GET_STATE_DIAGNOSTICS = "getStateDiagnostics"

        /**
         * 双窗口层级探测（仅诊断模式）的完整状态。
         *
         * 与 Dart 侧并行开发的卡片契约：返回的 key 集**冻结**于
         * [DualWindowProbeContract.STATUS_KEYS]，探测未运行时返回 `none`/0/false 安全值。
         */
        private const val METHOD_GET_DUAL_WINDOW_PROBE_STATUS = "getDualWindowProbeStatus"
        private const val METHOD_OPEN_USAGE_ACCESS_SETTINGS = "openUsageAccessSettings"

        // --- Phase 4C-5.1A：前台应用共享快照 ---
        private const val METHOD_GET_CURRENT_FOREGROUND_APP = "getCurrentForegroundApp"

        // --- Phase 4C-5.1B：使用会话采集 ---
        private const val METHOD_GET_CURRENT_USAGE_SESSION = "getCurrentUsageSession"
        private const val METHOD_READ_PENDING_USAGE_SESSIONS = "readPendingUsageSessions"
        private const val METHOD_ACKNOWLEDGE_USAGE_SESSIONS = "acknowledgeUsageSessions"
        private const val METHOD_GET_USAGE_COLLECTOR_STATE = "getUsageCollectorState"
        private const val METHOD_SET_USAGE_COLLECTION_PAUSED = "setUsageCollectionPaused"

        /**
         * 下发本机稳定设备标识。
         *
         * 不在需求 §5 列出的五个方法里，但 §3.2 要求 journal 记录包含 `device_local_id`，
         * 而它只有 Dart 侧知道 —— 因此必须有一条通道把它同步给原生。
         */
        private const val METHOD_UPDATE_USAGE_IDENTITY = "updateUsageIdentity"

        /** 单次导入的默认与最大条数（需求 §5：限制条数，避免一次传输过大）。 */
        private const val DEFAULT_IMPORT_LIMIT = 200
        private const val MAX_IMPORT_LIMIT = 1_000

        /**
         * 共享快照的"新鲜度"阈值。
         *
         * 界面每秒读一次快照，只有超过这个时间没更新时才补一次真正的检测 ——
         * 因此正常情况下界面刷新**不会**触发任何 `UsageStatsManager` 查询。
         */
        private const val SNAPSHOT_STALE_MS = 5_000L
    }
}

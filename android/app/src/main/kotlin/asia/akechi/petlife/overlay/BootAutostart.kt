package asia.akechi.petlife.overlay

/**
 * 开机自启（Phase 4D）。
 *
 * 为什么把"读标志 → 决策 → 启动"拆成**纯逻辑** + 一层薄薄的副作用：
 * 开机路径几乎无法靠单测在真机上复现（要真重启），因此这里把所有判断
 * 收敛成一个可以在 JVM 单测里逐条打靶的纯函数（[BootAutostart.decide]），
 * 真机只需要验证"重启后确实起来了"这一条。
 *
 * 语义（与需求一致，不许混淆）：
 * * `autostartEnabled` 只决定"重启后要不要把服务拉起来"，是**独立**设置；
 * * 它与"显示桌宠"（[PetOverlayStore.enabled] / [PetOverlayStore.hidden]）分开：
 *   用户此前把桌宠**隐藏**了，就按隐藏方式启动（不把用户藏起来的东西重新弹出来），
 *   这与"关闭开机自启"是**两回事**；
 * * 关闭开机自启后重启，什么都不启动；
 * * 系统拒绝启动（Android 12+ 的 [android.app.ForegroundServiceStartNotAllowedException]
 *   等）时**只记录原因、不做无限重试**，把事实交给设置页展示。
 *
 * Android 版本限制（targetSdk 36，见 AndroidManifest 与 docs/30）：
 * * Android 12+（API 31）后台启动前台服务默认被禁，但**接收 BOOT_COMPLETED /
 *   ACTION_MY_PACKAGE_REPLACED 的接收器**属于官方豁免，可以启动前台服务；
 * * Android 14+（API 34）必须声明前台服务类型（本项目为 `specialUse`）与对应权限；
 * * Android 15+（API 35）`BOOT_COMPLETED` 接收器**不允许**启动 `dataSync` 等特定类型，
 *   本项目用的是 `specialUse`，不在禁止之列。
 */

/**
 * 开机自启所需的**最小持久化面**。
 *
 * 抽成接口只为一件事：让 [BootAutostart] 的逻辑可以在 JVM 单测里跑，
 * 而不必构造 Android 的 `Context` / `SharedPreferences`。
 * 真机侧由 [PetOverlayBootStore] 适配到 [PetOverlayStore]。
 */
internal interface BootStore {
    /** 用户是否开启了开机自启（重启后读它决定要不要启动服务）。 */
    var autostartEnabled: Boolean

    /** 用户此前是否把桌宠隐藏了（隐藏 ≠ 关闭自启，必须保留）。 */
    val petHidden: Boolean

    /** 最近一次开机自启结果码（null = 从未记录）。 */
    val bootResultCode: String?

    /** 最近一次尝试启动的时间（毫秒；0 = 从未尝试）；用于重复信号去重。 */
    var bootLastAttemptAt: Long

    /** 记录一次开机自启结果（原子写）。 */
    fun recordBootResult(code: String, detail: String?, atMs: Long)
}

/** 开机后要做的动作。 */
internal enum class BootAction {
    /** 以"显示"方式启动。 */
    START,

    /** 以"隐藏"方式启动（保留用户的隐藏状态）。 */
    START_HIDDEN,

    /** 什么都不做。 */
    SKIP,
}

/** 一次开机决策的结果（纯数据）。 */
internal data class BootOutcome(
    val action: BootAction,
    val resultCode: String,
    val detail: String? = null,
)

/**
 * 开机自启的核心逻辑（纯函数 + 一层注入式副作用）。
 *
 * 结果码与 Dart 侧 `OverlayAutostartStatus.bootResultLabelZh` **逐字对应**，
 * 新增/改名必须两端一起改。
 */
internal object BootAutostart {

    // --- 结果码（两端协议，勿随意改名）---

    /** 开机自启已关闭 → 不启动。 */
    const val RESULT_DISABLED = "disabled"

    /** 指令已发出、服务已真正挂载窗口（由服务回填）。 */
    const val RESULT_STARTED = "started"

    /** 指令已发出，但服务尚未回报（接收器写下的中间态）。 */
    const val RESULT_START_REQUESTED = "start_requested"

    /** 缺少「显示在其他应用上层」权限 → 不启动。 */
    const val RESULT_MISSING_OVERLAY = "missing_overlay_permission"

    /** 系统限制后台启动（`startForegroundService` 抛异常）→ 不重试，记录原因。 */
    const val RESULT_SYSTEM_BLOCKED = "system_blocked"

    /** 服务已在运行 → 不重复启动。 */
    const val RESULT_ALREADY_RUNNING = "already_running"

    /** 短时间内的第二个开机信号 → 去重忽略。 */
    const val RESULT_DUPLICATE_IGNORED = "duplicate_ignored"

    /** 服务起来了但窗口/素材失败（由服务回填）。 */
    const val RESULT_START_FAILED = "start_failed"

    /** 需要用户打开应用才能恢复（权限被引导、厂商后台限制等）。 */
    const val RESULT_NEEDS_USER = "needs_user"

    /**
     * 同一轮开机内的去重窗口。
     *
     * `BOOT_COMPLETED` 与随后可能的 `ACTION_MY_PACKAGE_REPLACED` 可能相隔数秒，
     * 而服务 `onCreate` 又是异步的，光靠"服务已在运行"不足以挡住并发的第二条信号，
     * 因此再加一层时间窗守卫。
     */
    const val DUPLICATE_WINDOW_MS = 20_000L

    /**
     * 纯决策：给定输入，算出一件**唯一**要做的事。
     *
     * 判断顺序是被单测钉死的：
     * 1. 自启关闭 → 什么都不做；
     * 2. 缺少悬浮窗权限 → 不启动（没权限时服务起来也会被 `applyCommand` 当场停掉）；
     * 3. 服务已在运行 → 不重复启动；
     * 4. 距上次尝试太近 → 判为重复信号；
     * 5. 其余 → 启动（此前隐藏则按隐藏启动）。
     */
    fun decide(
        autostartEnabled: Boolean,
        petHidden: Boolean,
        overlayGranted: Boolean,
        serviceRunning: Boolean,
        nowMs: Long,
        lastAttemptAtMs: Long,
        duplicateWindowMs: Long = DUPLICATE_WINDOW_MS,
    ): BootOutcome {
        if (!autostartEnabled) {
            return BootOutcome(BootAction.SKIP, RESULT_DISABLED)
        }
        if (!overlayGranted) {
            return BootOutcome(BootAction.SKIP, RESULT_MISSING_OVERLAY)
        }
        if (serviceRunning) {
            return BootOutcome(BootAction.SKIP, RESULT_ALREADY_RUNNING)
        }
        if (lastAttemptAtMs > 0L && nowMs - lastAttemptAtMs < duplicateWindowMs) {
            return BootOutcome(BootAction.SKIP, RESULT_DUPLICATE_IGNORED)
        }
        return if (petHidden) {
            BootOutcome(BootAction.START_HIDDEN, RESULT_START_REQUESTED, detail = "pet-hidden")
        } else {
            BootOutcome(BootAction.START, RESULT_START_REQUESTED)
        }
    }

    /**
     * 执行一次开机决策。
     *
     * @param startService 由调用方注入：真机 = `startForegroundService`；测试 = 计数假实现。
     *        只要它抛异常（如 `ForegroundServiceStartNotAllowedException`），
     *        就按 [RESULT_SYSTEM_BLOCKED] 记录，**不做重试**。
     * @return 最终写下的决策（便于接收器打日志）。
     */
    fun run(
        store: BootStore,
        overlayGranted: Boolean,
        serviceRunning: Boolean,
        nowMs: Long,
        startService: (hidden: Boolean) -> Unit,
    ): BootOutcome {
        val outcome = decide(
            autostartEnabled = store.autostartEnabled,
            petHidden = store.petHidden,
            overlayGranted = overlayGranted,
            serviceRunning = serviceRunning,
            nowMs = nowMs,
            lastAttemptAtMs = store.bootLastAttemptAt,
        )
        when (outcome.action) {
            BootAction.SKIP ->
                store.recordBootResult(outcome.resultCode, outcome.detail, nowMs)

            BootAction.START, BootAction.START_HIDDEN -> {
                val hidden = outcome.action == BootAction.START_HIDDEN
                // 先记尝试时间：无论成功与否，都挡住紧接着的第二条开机信号。
                store.bootLastAttemptAt = nowMs
                val blockedReason: String? = try {
                    startService(hidden)
                    null
                } catch (t: Throwable) {
                    // 只记异常类名（不含任何用户数据），供设置页/日志诊断。
                    OverlayLog.warn("开机启动悬浮服务被系统拒绝（不再重试）", t)
                    t::class.java.simpleName
                }
                store.recordBootResult(
                    code = if (blockedReason == null) RESULT_START_REQUESTED else RESULT_SYSTEM_BLOCKED,
                    detail = blockedReason ?: outcome.detail,
                    atMs = nowMs,
                )
            }
        }
        return outcome
    }
}

/**
 * 把 [PetOverlayStore] 适配成 [BootStore]。
 *
 * 之所以需要这一层：`PetOverlayStore` 是 public 类，不适合直接实现 internal 的
 * [BootStore]；这里用组合把它包起来，逻辑仍然只有一份实现。
 */
internal class PetOverlayBootStore(private val store: PetOverlayStore) : BootStore {
    override var autostartEnabled: Boolean
        get() = store.autostartEnabled
        set(value) {
            store.autostartEnabled = value
        }

    override val petHidden: Boolean get() = store.hidden

    override val bootResultCode: String? get() = store.bootResultCode

    override var bootLastAttemptAt: Long
        get() = store.bootLastAttemptAt
        set(value) {
            store.bootLastAttemptAt = value
        }

    override fun recordBootResult(code: String, detail: String?, atMs: Long) =
        store.recordBootResult(code, detail, atMs)
}

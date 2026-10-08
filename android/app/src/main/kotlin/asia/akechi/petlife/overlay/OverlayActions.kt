package asia.akechi.petlife.overlay

import android.content.Intent

/**
 * 悬浮桌宠的统一日志出口（Phase 4C-2 真机排障要求）。
 *
 * 固定标签 `PetLifeOverlay`，真机复验时直接：
 * ```
 * adb logcat -c
 * adb logcat -s PetLifeOverlay:* AndroidRuntime:E
 * ```
 * **绝不打日志**账户密码 / access token / refresh token / API key ——
 * 本模块也从不接触它们。
 */
internal object OverlayLog {
    const val TAG = "PetLifeOverlay"

    /**
     * 诊断模式：打开后才会输出**逐条**细节（例如前台应用的完整事件列表）。
     *
     * 由服务按用户的"诊断模式"开关同步；默认关闭，避免正常运行时刷屏。
     */
    @Volatile
    var diagnosticsEnabled: Boolean = false

    fun log(message: String) {
        android.util.Log.i(TAG, message)
    }

    /** 仅诊断模式输出的细节日志（逐条事件等）。 */
    fun debug(message: String) {
        if (!diagnosticsEnabled) return
        android.util.Log.i(TAG, message)
    }

    fun warn(message: String, throwable: Throwable? = null) {
        android.util.Log.w(TAG, message, throwable)
    }

    fun error(message: String, throwable: Throwable? = null) {
        android.util.Log.e(TAG, message, throwable)
    }
}

/**
 * 悬浮桌宠的**指令**与**状态机**（Phase 4C）。
 *
 * 为什么把这两件事单独抽出来：
 * * 通知栏动作、Flutter MethodChannel、服务重建（START_STICKY）三条入口
 *   必须解释成同一套指令，否则"点通知隐藏"和"点设置页隐藏"会走出两种行为；
 * * 指令到状态的推导是**纯函数**，可以在 JVM 单元测试里直接验证幂等性
 *   （需求："start / show / hide / stop 必须幂等"，"同时最多一个服务、一个窗口"）。
 */
internal enum class OverlayCommand {
    /** 启用并显示（服务未运行时创建）。 */
    START,

    /**
     * 启用但**保持隐藏**（Phase 4D 开机自启专用）。
     *
     * 用户此前把桌宠隐藏了，重启后仍应隐藏 —— 这与"关闭开机自启"是两回事，
     * 不能因为自启就强行把用户藏起来的东西弹出来。
     */
    START_HIDDEN,
    SHOW,
    HIDE,
    /** 通知栏的「显示/隐藏」切换。 */
    TOGGLE,
    /** 重新应用配置（缩放/穿透/素材变化），**不改变**运行与隐藏状态。 */
    UPDATE,
    /** 停止服务并移除窗口。 */
    STOP,
    UNKNOWN;

    companion object {
        fun fromWire(raw: String?): OverlayCommand = when (raw) {
            null, "" -> START
            "start" -> START
            "start_hidden" -> START_HIDDEN
            "show" -> SHOW
            "hide" -> HIDE
            "toggle" -> TOGGLE
            "update" -> UPDATE
            "stop" -> STOP
            else -> UNKNOWN
        }
    }
}

/**
 * 服务的可持久化状态。
 *
 * [windowVisible] 是唯一的"窗口是否应该存在"判据 —— 服务运行 + 未隐藏。
 */
internal data class OverlayState(
    val running: Boolean,
    val hidden: Boolean,
) {
    val windowVisible: Boolean get() = running && !hidden

    companion object {
        val stopped = OverlayState(running = false, hidden = false)
    }
}

/**
 * 指令 → 新状态。**幂等**是这里的硬要求：
 * * 连续两次 START / SHOW 结果完全相同；
 * * 连续两次 STOP 结果完全相同；
 * * HIDE 在服务未运行时不会"凭空把服务拉起来"（隐藏一个不存在的东西没有意义）；
 * * TOGGLE 在服务未运行时等价于 START（用户在通知栏点"显示"）。
 */
internal object OverlayStateMachine {
    fun next(current: OverlayState, command: OverlayCommand): OverlayState = when (command) {
        OverlayCommand.START -> OverlayState(running = true, hidden = false)
        // 开机自启：服务起来但保留"用户此前隐藏"的状态（不把窗口弹出来）。
        OverlayCommand.START_HIDDEN -> OverlayState(running = true, hidden = true)
        OverlayCommand.SHOW -> OverlayState(running = true, hidden = false)
        OverlayCommand.HIDE ->
            if (current.running) OverlayState(running = true, hidden = true) else current
        OverlayCommand.TOGGLE ->
            if (current.running) OverlayState(running = true, hidden = !current.hidden)
            else OverlayState(running = true, hidden = false)
        // 重新应用配置不改变运行/隐藏状态（哪怕当前根本没在运行）。
        OverlayCommand.UPDATE -> current
        OverlayCommand.STOP -> OverlayState.stopped
        OverlayCommand.UNKNOWN -> current
    }
}

/** 服务与通知、Intent 之间共用的常量。 */
internal object OverlayActions {
    private const val PREFIX = "asia.akechi.petlife.overlay.action."

    /** 承载一次指令（服务未运行时也会带上它，默认 START）。 */
    const val ACTION_COMMAND = "${PREFIX}COMMAND"

    const val EXTRA_COMMAND = "overlay_command"

    /** 指令发出时间（毫秒），用于丢弃"过期命令"。 */
    const val EXTRA_ISSUED_AT = "overlay_issued_at"

    /**
     * 是否参与"过期命令"守卫。
     *
     * 只对**桥（Flutter）发起**的指令生效：通知栏的 PendingIntent 是"点击时投递、
     * 内容在构建时确定"，如果也参与守卫，用户稍后点"停止"就会因为时间戳比
     * 最后一次状态变更早而被误丢弃 —— 那会变成"点了停止停不掉"。
     */
    const val EXTRA_GUARDED = "overlay_guarded"

    /**
     * 触发来源（Phase 4D）：`boot` = 开机自启。
     *
     * 服务据此把"这次启动是不是开机触发的"记进 boot 结果 —— 只有开机触发的
     * 启动才允许回填 `started` / `start_failed`，用户手动点"显示"不会污染它。
     */
    const val EXTRA_TRIGGER = "overlay_trigger"

    /** [EXTRA_TRIGGER] 的取值：开机自启。 */
    const val TRIGGER_BOOT = "boot"

    /** PendingIntent 的 requestCode：必须是固定值，否则重复发通知会堆叠出多个入口。 */
    const val REQUEST_TOGGLE = 4811
    const val REQUEST_STOP = 4812
    const val REQUEST_OPEN_APP = 4813

    /**
     * 构造发给服务的 Intent。
     *
     * **不带任何用户数据**：悬浮窗配置存在 SharedPreferences（见 [PetOverlayStore]），
     * Intent 只承载"做什么"。
     */
    fun intent(
        context: android.content.Context,
        command: OverlayCommand,
        guarded: Boolean = false,
        trigger: String? = null,
    ): Intent =
        Intent(context, PetOverlayService::class.java).apply {
            action = ACTION_COMMAND
            putExtra(EXTRA_COMMAND, command.name.lowercase())
            putExtra(EXTRA_ISSUED_AT, System.currentTimeMillis())
            putExtra(EXTRA_GUARDED, guarded)
            if (trigger != null) putExtra(EXTRA_TRIGGER, trigger)
        }
}

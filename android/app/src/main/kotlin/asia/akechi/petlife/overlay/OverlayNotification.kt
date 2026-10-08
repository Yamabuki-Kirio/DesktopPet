package asia.akechi.petlife.overlay

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import asia.akechi.petlife.MainActivity
import asia.akechi.petlife.R

/**
 * 悬浮桌宠的常驻通知（Phase 4C）。
 *
 * 设计取舍：
 * * **全部用平台 API**，不引入 androidx：`NotificationChannel` 只在 API 26+
 *   存在，24/25 走无渠道分支，因此不需要兼容库；
 * * 通知是"悬浮桌宠正在运行"的唯一常驻入口，必须提供
 *   「显示/隐藏」「打开 PetLife」「停止」三个动作；
 * * 所有 PendingIntent 都是**不可变**（FLAG_IMMUTABLE）且 requestCode 固定 ——
 *   否则重复发通知会堆出多个入口，或者在 API 31+ 直接抛异常。
 */
internal object OverlayNotification {

    const val CHANNEL_ID = "petlife_overlay"
    const val NOTIFICATION_ID = 4820

    /** 创建通知渠道；API 26 以下没有渠道概念，直接返回。 */
    fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "悬浮桌宠",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "PetLife 悬浮桌宠的运行状态与控制入口"
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    /**
     * 构造常驻通知。
     *
     * @param hidden 当前是否隐藏 —— 用它决定「显示/隐藏」动作的标题，
     *   保证通知里读到的状态与真实状态一致。
     * @param characterName 当前角色显示名；为 null 时不显示这一行。
     */
    fun build(context: Context, hidden: Boolean, characterName: String?): Notification {
        ensureChannel(context)

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context)
        }

        val content = if (characterName.isNullOrBlank()) {
            if (hidden) "悬浮桌宠已隐藏（服务仍在运行）" else "PetLife 桌宠正在运行"
        } else {
            if (hidden) "当前角色：$characterName（已隐藏）" else "当前角色：$characterName"
        }

        builder
            .setSmallIcon(R.drawable.ic_petlife_overlay)
            .setContentTitle("PetLife 桌宠正在运行")
            .setContentText(content)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setContentIntent(openAppIntent(context))

        @Suppress("DEPRECATION")
        builder.addAction(
            R.drawable.ic_petlife_overlay,
            if (hidden) "显示" else "隐藏",
            commandIntent(context, OverlayCommand.TOGGLE, OverlayActions.REQUEST_TOGGLE),
        )
        @Suppress("DEPRECATION")
        builder.addAction(
            R.drawable.ic_petlife_overlay,
            "打开 PetLife",
            openAppIntent(context),
        )
        @Suppress("DEPRECATION")
        builder.addAction(
            R.drawable.ic_petlife_overlay,
            "停止",
            commandIntent(context, OverlayCommand.STOP, OverlayActions.REQUEST_STOP),
        )

        return builder.build()
    }

    /** 刷新已发出的通知（服务状态变化时调用；重复调用不会产生第二条通知）。 */
    fun update(context: Context, hidden: Boolean, characterName: String?) {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        manager.notify(NOTIFICATION_ID, build(context, hidden, characterName))
    }

    fun cancel(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        manager.cancel(NOTIFICATION_ID)
    }

    /**
     * 交给服务的指令 Intent。
     *
     * 用 `getService`：服务在发出这条通知时**一定已经在运行**，
     * 因此 `startService` 不受 Android 8+ 的后台启动限制
     * （限制只针对"从后台启动一个尚未运行的服务"）。
     */
    private fun commandIntent(
        context: Context,
        command: OverlayCommand,
        requestCode: Int,
    ): PendingIntent {
        val intent = OverlayActions.intent(context, command)
        return PendingIntent.getService(
            context,
            requestCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    /** 「打开 PetLife」：复用启动 Activity，避免新建任务栈。 */
    private fun openAppIntent(context: Context): PendingIntent =
        PendingIntent.getActivity(
            context,
            OverlayActions.REQUEST_OPEN_APP,
            openAppLaunchIntent(context, destination = null, requestId = null),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

    /**
     * 「打开 PetLife」的 Intent —— **唯一**一份构造逻辑（通知与轮盘原生动作共用）。
     *
     * @param destination 目标页 wire 值（如 `overlaySettings`）；null = 只打开主界面
     * @param requestId   触发这次跳转的菜单请求 id（供后续导航/对账使用）
     */
    internal fun openAppLaunchIntent(context: Context, destination: String?, requestId: String?): Intent {
        val intent = Intent(context, MainActivity::class.java).apply {
            action = Intent.ACTION_MAIN
            addCategory(Intent.CATEGORY_LAUNCHER)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        if (!destination.isNullOrBlank()) intent.putExtra(EXTRA_DESTINATION, destination)
        if (!requestId.isNullOrBlank()) intent.putExtra(EXTRA_MENU_REQUEST_ID, requestId)
        return intent
    }

    /**
     * 直接启动 PetLife（轮盘「打开 PetLife」原生动作走这里）。
     *
     * 与通知里的入口**共用同一份 Intent 构造**：不复制、不产生第二种打开方式。
     * 启动失败只记日志并返回 false（悬浮窗本身不受影响）。
     */
    internal fun launchOpenApp(
        context: Context,
        destination: String?,
        requestId: String? = null,
    ): Boolean = try {
        context.startActivity(openAppLaunchIntent(context, destination, requestId))
        true
    } catch (t: Throwable) {
        OverlayLog.warn("打开 PetLife 失败（悬浮窗继续运行）", t)
        false
    }

    /** 跳转目标页的 extra 键（Dart 侧按需读取；不进任何日志）。 */
    internal const val EXTRA_DESTINATION = "overlay.menu.destination"

    /** 触发这次跳转的菜单请求 id。 */
    internal const val EXTRA_MENU_REQUEST_ID = "overlay.menu.request_id"
}

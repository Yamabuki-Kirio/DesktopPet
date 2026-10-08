package asia.akechi.petlife.overlay

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.provider.Settings

/**
 * 开机自启接收器（Phase 4D）。
 *
 * 处理的动作（只这两个，**不**处理 `LOCKED_BOOT_COMPLETED`）：
 * * `ACTION_BOOT_COMPLETED` —— 设备重启完成（对非 direct-boot 应用，系统在
 *   **用户解锁后**才投递，因此此时凭据加密的 SharedPreferences 已经可读，正好满足
 *   "解锁后再动桌宠"的要求）；
 * * `ACTION_MY_PACKAGE_REPLACED` —— 应用被覆盖安装（用户会把它当成"重启一次"）。
 *
 * 为什么不处理 `LOCKED_BOOT_COMPLETED`：
 * 那份开机自启标志存在**凭据加密**存储（`MODE_PRIVATE`）里，设备锁定阶段读不到，
 * 而本项目也**刻意不**申请 direct-boot 存储 —— 因此在未解锁前不做任何事，
 * 自然避免了"在用户解锁前就把悬浮窗/素材准备好"这类越界行为。
 *
 * 关键设计：**完全不依赖 Flutter**。
 * 判断所需的全部信息（开关、隐藏态）都在原生 `SharedPreferences`，
 * 启动走的是与界面**完全相同的** `PetOverlayService` 入口；
 * 素材/状态映射同样是原生已持久化的那份，因此服务起来后即使 Flutter 没启动，
 * 占位图/上次素材也照常显示。需要 Flutter 的菜单请求由既有的
 * `MenuRequestStore` 落盘排队，等界面回来再拉取，不需要在这里起引擎。
 */
class BootCompletedReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action
        if (action != Intent.ACTION_BOOT_COMPLETED &&
            action != Intent.ACTION_MY_PACKAGE_REPLACED
        ) {
            return
        }

        val appContext = context.applicationContext
        val store = PetOverlayBootStore(PetOverlayStore(appContext))
        // 权限现场复查（绝不缓存）：没给悬浮窗权限时起来也会被服务当场停掉，
        // 这里直接记录原因、不浪费一次启动。
        val overlayGranted = Settings.canDrawOverlays(appContext)
        val serviceRunning = PetOverlayService.isRunning

        val outcome = BootAutostart.run(
            store = store,
            overlayGranted = overlayGranted,
            serviceRunning = serviceRunning,
            nowMs = System.currentTimeMillis(),
            startService = { hidden -> PetOverlayService.startForBoot(appContext, hidden) },
        )

        OverlayLog.log(
            "boot.action=$action result=${outcome.resultCode} action=${outcome.action} " +
                "overlayGranted=$overlayGranted serviceRunning=$serviceRunning " +
                "detail=${outcome.detail}",
        )
    }
}

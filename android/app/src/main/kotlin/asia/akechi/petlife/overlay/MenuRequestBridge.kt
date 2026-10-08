package asia.akechi.petlife.overlay

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel

/**
 * 菜单请求的**原生 → Dart 推送端点**（Phase 4C-6B-3）。
 *
 * 复用**同一个** MethodChannel（`asia.akechi.petlife/overlay`，见
 * [PetOverlayBridge.CHANNEL_NAME]）做双向通信，因此：
 * * 不新开 FlutterEngine、不新开 WindowManager 窗口、不需要 EventChannel；
 * * 通道对象由 `MainActivity` 在 `configureFlutterEngine` 时注入（Activity 重建即重新注入，
 *   旧通道自动失效 —— 推送失败时请求**保持 pending**，等 Dart 回来 pull）。
 *
 * 线程约定：`invokeMethod` 必须在主线程调用，因此本对象内部统一 post 到主线程。
 */
internal object MenuRequestBridge {

    /** 原生 → Dart：一条菜单请求。 */
    const val METHOD_MENU_REQUEST = "menuRequest"

    /** Dart → 原生：拉取尚未交付的请求。 */
    const val METHOD_PULL_PENDING = "pullPendingMenuRequests"

    /** Dart → 原生：回报一条请求的终态。 */
    const val METHOD_COMPLETE_REQUEST = "completeMenuRequest"

    /** `pullPendingMenuRequests` 的回包键。 */
    const val KEY_REQUESTS = "requests"

    /** 终态 wire 值（与 Dart 侧冻结契约一致）。 */
    const val STATUS_COMPLETED = "completed"
    const val STATUS_FAILED = "failed"
    const val STATUS_EXPIRED = "expired"

    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile
    private var channel: MethodChannel? = null

    /** Activity 建立引擎后注入通道（重复注入即替换）。 */
    fun attach(attached: MethodChannel) {
        channel = attached
    }

    /** Activity 销毁后清空（只清自己那一份，避免清掉新注入的）。 */
    fun detach(attached: MethodChannel?) {
        if (channel === attached) channel = null
    }

    fun isAttached(): Boolean = channel != null

    /**
     * 推送一条请求给 Dart。
     *
     * **失败一律不抛异常**（引擎未起 / Activity 被销毁 / Dart 尚未注册 handler）：
     * 回调 false，调用方据此让请求留在队列里，等 Dart `pullPendingMenuRequests`。
     */
    fun pushMenuRequest(payload: Map<String, Any?>, onResult: (Boolean) -> Unit) {
        val target = channel
        if (target == null) {
            OverlayLog.log("menu.request.push 跳过：Flutter 通道未注入")
            onResult(false)
            return
        }
        if (Looper.myLooper() != Looper.getMainLooper()) {
            mainHandler.post { pushMenuRequest(payload, onResult) }
            return
        }
        try {
            target.invokeMethod(
                METHOD_MENU_REQUEST,
                payload,
                object : MethodChannel.Result {
                    override fun success(result: Any?) {
                        onResult(true)
                    }

                    override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
                        OverlayLog.warn(
                            "menu.request.push 失败 code=$errorCode msg=$errorMessage（保持 pending）",
                        )
                        onResult(false)
                    }

                    override fun notImplemented() {
                        OverlayLog.warn("menu.request.push 未实现（Dart 尚未注册 handler，保持 pending）")
                        onResult(false)
                    }
                },
            )
        } catch (t: Throwable) {
            OverlayLog.warn("menu.request.push 异常（保持 pending）", t)
            onResult(false)
        }
    }

    /** 从 `completeMenuRequest` 的参数里安全提取三要素（类型不符一律忽略，不猜）。 */
    fun parseCompletion(arguments: Any?): Triple<String, String, String?>? {
        val map = arguments as? Map<*, *> ?: return null
        val requestId = (map["requestId"] as? String)?.trim().orEmpty()
        val status = (map["status"] as? String)?.trim().orEmpty()
        if (requestId.isEmpty() || status.isEmpty()) return null
        val message = (map["message"] as? String)?.takeIf { it.isNotBlank() }
        return Triple(requestId, status, message)
    }

    /** 协议载荷（供 `pullPendingMenuRequests` 与推送共用同一份形状）。 */
    fun payloadsOf(requests: List<PendingMenuRequest>): List<Map<String, Any?>> =
        requests.map { it.toPayload() }
}

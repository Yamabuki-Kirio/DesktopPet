package asia.akechi.petlife

import android.os.Handler
import android.os.Looper
import asia.akechi.petlife.overlay.PetOverlayBridge
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * PetLife Android 入口。
 *
 * 做两件事：
 * 1. 把 Dart 侧的凭据读写请求转发给 [PetLifeCredentialStore]；
 * 2. 把悬浮桌宠的权限/生命周期请求转发给 [PetOverlayBridge]（Phase 4C）。
 *
 * 平台隔离说明（Phase 4A 第 10 条）
 * -------------------------------
 * 这个文件在 `android/app/src/main/kotlin/` 下，**只被 Android 构建编译**；
 * Windows 构建根本不包含它，因此注册 MethodChannel 不会影响 Windows 的链接。
 * Dart 侧也只有 `AndroidCredentialStoreFactory` / `AndroidPlatformServices`
 * 会创建对应的通道对象。
 */
class MainActivity : FlutterActivity() {

    /**
     * Keystore 读写在单线程池上执行：`SharedPreferences` 与 Cipher 都是阻塞调用，
     * 不应放在主线程。结果统一回到主线程回调给 Flutter。
     */
    private val credentialExecutor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    /** 悬浮桌宠桥（Phase 4C）。需要 Activity 才能发起权限请求与打开系统设置页。 */
    private var overlayBridge: PetOverlayBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val store = PetLifeCredentialStore(applicationContext)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CREDENTIAL_STORE_CHANNEL)
            .setMethodCallHandler { call, result -> handleCredentialCall(store, call, result) }

        val bridge = PetOverlayBridge(this)
        overlayBridge = bridge
        // 关键：原生 → Dart 的菜单请求推送**复用同一个通道对象**
        // （不新开 FlutterEngine、不新开 EventChannel），因此这里必须把 channel 交给桥。
        val overlayChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            PetOverlayBridge.CHANNEL_NAME,
        )
        overlayChannel.setMethodCallHandler(bridge)
        bridge.attachChannel(overlayChannel)
    }

    override fun onDestroy() {
        overlayBridge?.detachChannel()
        overlayBridge = null
        credentialExecutor.shutdown()
        super.onDestroy()
    }

    /**
     * 转发 Android 13+ 的 POST_NOTIFICATIONS 授权结果。
     *
     * 必须调用 `super`：Flutter 插件（以及 Flutter 自身的权限流程）
     * 也依赖这个回调。
     */
    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        overlayBridge?.onRequestPermissionsResult(requestCode, grantResults)
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }

    private fun handleCredentialCall(
        store: PetLifeCredentialStore,
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        val key: String? = call.argument<String>("key")
        if (key.isNullOrEmpty()) {
            result.error(CODE_INVALID_ARGUMENTS, "缺少参数 key", null)
            return
        }

        credentialExecutor.execute {
            val outcome: Result<Any?> = runCatching {
                when (call.method) {
                    METHOD_WRITE -> {
                        val secret: String = call.argument<String>("secret")
                            ?: throw CredentialStoreFailure(
                                CODE_INVALID_ARGUMENTS,
                                "缺少参数 secret",
                            )
                        store.write(key, secret)
                        null
                    }
                    METHOD_READ -> store.read(key)
                    METHOD_DELETE -> {
                        store.delete(key)
                        null
                    }
                    else -> throw CredentialStoreFailure(
                        CODE_UNSUPPORTED_METHOD,
                        "不支持的凭据操作：${call.method}",
                    )
                }
            }

            // 回调必须在主线程（Flutter 的 MethodChannel.Result 要求）。
            mainHandler.post {
                outcome.fold(
                    onSuccess = { value -> result.success(value) },
                    onFailure = { error ->
                        val failure = error as? CredentialStoreFailure
                        // 只透传错误码与安全消息（消息里不含令牌明文）。
                        result.error(
                            failure?.code ?: CODE_UNKNOWN,
                            failure?.message ?: "凭据操作失败：$key",
                            null,
                        )
                    },
                )
            }
        }
    }

    companion object {
        /** 与 Dart 侧 `androidCredentialStoreChannelName` 必须完全一致。 */
        const val CREDENTIAL_STORE_CHANNEL = "asia.akechi.petlife/credential_store"

        const val METHOD_WRITE = "write"
        const val METHOD_READ = "read"
        const val METHOD_DELETE = "delete"

        const val CODE_INVALID_ARGUMENTS = "invalid_arguments"
        const val CODE_UNSUPPORTED_METHOD = "unsupported_method"
        const val CODE_UNKNOWN = "unknown"
    }
}

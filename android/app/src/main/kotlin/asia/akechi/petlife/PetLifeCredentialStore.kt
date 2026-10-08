package asia.akechi.petlife

import android.content.Context
import android.content.SharedPreferences
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.GeneralSecurityException
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * 凭据操作失败。
 *
 * [code] 会被原样透传给 Dart（`PlatformException.code`），
 * [message] **只允许包含条目名与失败原因**，绝不能出现令牌明文 ——
 * 否则令牌会顺着异常信息进入日志或 UI。
 */
internal class CredentialStoreFailure(
    val code: String,
    override val message: String,
    cause: Throwable? = null,
) : Exception(message, cause)

/**
 * Android 安全凭据存储（Phase 4A）。
 *
 * 设计要点（对应 Phase 4A 第 2 项要求）
 * ------------------------------------
 * 1. 密钥由 **AndroidKeyStore** 生成（`AES-256`）。AndroidKeyStore 的密钥材料
 *    永远留在系统 keystore 守护进程里，`SecretKey.getEncoded()` 返回 null，
 *    应用进程**无法导出**私钥材料；
 * 2. 加密算法固定为 `AES/GCM/NoPadding`（带认证标签，密文被篡改会被检出）；
 * 3. 每次写入都让 Cipher 自己生成**随机 IV**（配合
 *    `setRandomizedEncryptionRequired(true)`，系统会拒绝由调用方指定 IV），
 *    因此同样的明文两次写入得到的密文不同；
 * 4. `SharedPreferences` 里**只**保存 `版本:IV:密文` 三段式信封，
 *    不保存明文、不保存密钥；
 * 5. 读取失败（密钥被清除 / 密文被篡改 / 信封格式损坏）时抛出
 *    [CredentialStoreFailure]，**绝不回退到明文**，也不返回"猜"出来的值。
 *
 * 与 Windows 的关系
 * -----------------
 * 这个文件只被 Android 构建编译（在 `android/app/src/main/kotlin/` 下），
 * Windows 侧继续使用 Credential Manager / DPAPI，两者互不影响。
 */
internal class PetLifeCredentialStore(context: Context) {

    private val preferences: SharedPreferences =
        context.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)

    /** 写入（覆盖）一条凭据。明文只在本次调用内存在，落盘的只有信封。 */
    @Throws(CredentialStoreFailure::class)
    fun write(key: String, secret: String) {
        val cipher: Cipher = try {
            Cipher.getInstance(TRANSFORMATION).apply {
                init(Cipher.ENCRYPT_MODE, loadOrCreateKey())
            }
        } catch (e: GeneralSecurityException) {
            throw CredentialStoreFailure(CODE_KEY_INVALID, "无法初始化加密密钥：$key", e)
        }

        val ciphertext: ByteArray = try {
            cipher.doFinal(secret.toByteArray(Charsets.UTF_8))
        } catch (e: GeneralSecurityException) {
            throw CredentialStoreFailure(CODE_ENCRYPT_FAILED, "凭据加密失败：$key", e)
        }

        // 每次写入都是新的随机 IV（由系统生成，见 setRandomizedEncryptionRequired）。
        val envelope = buildString {
            append(ENVELOPE_VERSION)
            append(ENVELOPE_SEPARATOR)
            append(Base64.encodeToString(cipher.iv, Base64.NO_WRAP))
            append(ENVELOPE_SEPARATOR)
            append(Base64.encodeToString(ciphertext, Base64.NO_WRAP))
        }

        val committed = preferences.edit()
            .putString(preferenceKey(key), envelope)
            .commit()
        if (!committed) {
            throw CredentialStoreFailure(CODE_WRITE_FAILED, "凭据写入失败：$key")
        }
    }

    /** 读取凭据；条目不存在返回 null；损坏或密钥失效抛明确错误。 */
    @Throws(CredentialStoreFailure::class)
    fun read(key: String): String? {
        val stored: String = preferences.getString(preferenceKey(key), null) ?: return null

        val parts = stored.split(ENVELOPE_SEPARATOR)
        if (parts.size != 3 || parts[0] != ENVELOPE_VERSION) {
            throw CredentialStoreFailure(
                CODE_CIPHER_CORRUPT,
                "凭据数据格式无法识别（不是 $ENVELOPE_VERSION 信封）：$key",
            )
        }

        val iv = decodeBase64(parts[1], key)
        val ciphertext = decodeBase64(parts[2], key)

        val secretKey = loadKey()
            ?: throw CredentialStoreFailure(
                CODE_KEY_INVALID,
                "加密密钥已不存在（可能被系统清除或用户重置了锁屏）：$key",
            )

        val plain: ByteArray = try {
            Cipher.getInstance(TRANSFORMATION).run {
                init(Cipher.DECRYPT_MODE, secretKey, GCMParameterSpec(GCM_TAG_LENGTH_BITS, iv))
                doFinal(ciphertext)
            }
        } catch (e: GeneralSecurityException) {
            // AEADBadTagException 等：密文被篡改，或密钥不匹配。绝不返回明文兜底。
            throw CredentialStoreFailure(
                CODE_CIPHER_CORRUPT,
                "凭据解密失败（密钥不匹配或数据已损坏）：$key",
                e,
            )
        }

        return String(plain, Charsets.UTF_8)
    }

    /** 删除凭据；条目不存在也算成功（幂等）。 */
    fun delete(key: String) {
        preferences.edit().remove(preferenceKey(key)).commit()
    }

    private fun decodeBase64(value: String, key: String): ByteArray = try {
        Base64.decode(value, Base64.NO_WRAP)
    } catch (e: IllegalArgumentException) {
        throw CredentialStoreFailure(
            CODE_CIPHER_CORRUPT,
            "凭据数据无法解码（Base64 损坏）：$key",
            e,
        )
    }

    private fun loadKey(): SecretKey? = try {
        KeyStore.getInstance(KEYSTORE_PROVIDER).run {
            load(null)
            getKey(KEY_ALIAS, null)
        } as? SecretKey
    } catch (e: GeneralSecurityException) {
        null
    }

    @Throws(CredentialStoreFailure::class)
    private fun loadOrCreateKey(): SecretKey {
        loadKey()?.let { return it }

        val generated: SecretKey = try {
            KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE_PROVIDER).run {
                init(
                    KeyGenParameterSpec.Builder(
                        KEY_ALIAS,
                        KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                    )
                        .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                        .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                        .setKeySize(KEY_SIZE_BITS)
                        // 强制要求每次加密使用系统生成的随机 IV（不接受调用方传入 IV）。
                        .setRandomizedEncryptionRequired(true)
                        // 不绑定生物识别：后台同步也要能读取令牌。
                        .setUserAuthenticationRequired(false)
                        .build(),
                )
                generateKey()
            }
        } catch (e: GeneralSecurityException) {
            throw CredentialStoreFailure(CODE_KEY_INVALID, "无法创建 Android Keystore 密钥", e)
        }
        return generated
    }

    /**
     * 条目名转成 SharedPreferences 键。
     *
     * 加前缀是为了让"这个键属于凭据信封"在 prefs 里一眼可辨，
     * 也便于将来清理其它用途的键。
     */
    private fun preferenceKey(key: String): String = PREFERENCE_PREFIX + key

    internal companion object {
        /** AndroidKeyStore provider 名。 */
        const val KEYSTORE_PROVIDER = "AndroidKeyStore"

        /** 密钥别名；带 `.v1` 后缀，便于将来轮换密钥而不影响旧数据。 */
        const val KEY_ALIAS = "asia.akechi.petlife.credentials.v1"

        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val GCM_TAG_LENGTH_BITS = 128
        const val KEY_SIZE_BITS = 256

        /** 与 Dart 侧约定：`v1:<ivBase64>:<cipherBase64>`。 */
        const val ENVELOPE_VERSION = "v1"
        const val ENVELOPE_SEPARATOR = ':'

        const val PREFERENCES_NAME = "asia.akechi.petlife.credentials"
        const val PREFERENCE_PREFIX = "entry:"

        // 错误码（Dart 侧按这些码映射成明确的失败原因，绝不回退明文）。
        const val CODE_KEY_INVALID = "key_invalid"
        const val CODE_CIPHER_CORRUPT = "cipher_corrupt"
        const val CODE_ENCRYPT_FAILED = "encrypt_failed"
        const val CODE_WRITE_FAILED = "write_failed"
    }
}

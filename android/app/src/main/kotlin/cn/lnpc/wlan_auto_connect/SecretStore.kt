package cn.lnpc.wlan_auto_connect

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/// 敏感字段（校园网密码）的静态加密。
///
/// 为什么需要：小组件/磁贴/开机三条后台路径要在没有 Flutter 引擎的情况下读取
/// 配置，因此密码必须放在原生可读的 SharedPreferences 里；若不加密，它会以明文
/// 形式出现在 `HomeWidgetPreferences.xml`（Windows 端对应位置使用的是 DPAPI）。
/// 这里用 AndroidKeyStore 中的 AES-256-GCM 密钥加密，密钥由系统密钥库保管、
/// 不随应用数据导出。
///
/// 存储格式：`enc:v1:<base64(iv || ciphertext)>`。
/// 不带该前缀的值按**历史明文**处理并原样返回，以便从旧版本平滑迁移：
/// 用户下次保存档案时即被加密，无需额外迁移逻辑。
object SecretStore {
    private const val PREFIX = "enc:v1:"
    private const val KEY_ALIAS = "cn_wlan_secret_v1"
    private const val ANDROID_KEYSTORE = "AndroidKeyStore"
    private const val TRANSFORMATION = "AES/GCM/NoPadding"
    private const val IV_LENGTH = 12
    private const val TAG_LENGTH_BITS = 128

    fun isEncrypted(value: String): Boolean = value.startsWith(PREFIX)

    /// 加密明文。空串原样返回（无需加密）。
    /// 失败返回 null，由调用方决定降级策略（见 WlanMethods 的 encryptSecret）。
    fun encrypt(plain: String): String? {
        if (plain.isEmpty()) return ""
        return try {
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.ENCRYPT_MODE, secretKey())
            val iv = cipher.iv
            val cipherText = cipher.doFinal(plain.toByteArray(Charsets.UTF_8))
            PREFIX + Base64.encodeToString(iv + cipherText, Base64.NO_WRAP)
        } catch (e: Throwable) {
            android.util.Log.w("SecretStore", "加密失败", e)
            null
        }
    }

    /// 解密。
    /// - 历史明文（无前缀）→ 原样返回
    /// - 解密失败（密钥丢失 / 数据损坏 / 换了设备）→ null，调用方应视为"需要重新输入"
    fun decrypt(stored: String): String? {
        if (stored.isEmpty()) return ""
        if (!isEncrypted(stored)) return stored
        return try {
            val raw = Base64.decode(stored.removePrefix(PREFIX), Base64.NO_WRAP)
            if (raw.size <= IV_LENGTH) return null
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(
                Cipher.DECRYPT_MODE,
                secretKey(),
                GCMParameterSpec(TAG_LENGTH_BITS, raw, 0, IV_LENGTH),
            )
            String(
                cipher.doFinal(raw, IV_LENGTH, raw.size - IV_LENGTH),
                Charsets.UTF_8,
            )
        } catch (e: Throwable) {
            android.util.Log.w("SecretStore", "解密失败", e)
            null
        }
    }

    /// 取（必要时创建）密钥库中的 AES 密钥。
    private fun secretKey(): SecretKey {
        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        (keyStore.getEntry(KEY_ALIAS, null) as? KeyStore.SecretKeyEntry)
            ?.let { return it.secretKey }

        val generator = KeyGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE
        )
        generator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build()
        )
        return generator.generateKey()
    }
}

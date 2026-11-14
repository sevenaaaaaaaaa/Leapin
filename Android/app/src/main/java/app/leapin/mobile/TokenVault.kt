package app.leapin.mobile

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Encrypts the control token with a key that never leaves the Android Keystore.
 * Stored form is base64(iv || ciphertext) in SharedPreferences.
 */
object TokenVault {
    private const val KEYSTORE = "AndroidKeyStore"
    private const val ALIAS = "leapin.control.token"
    private const val TRANSFORMATION = "AES/GCM/NoPadding"
    private const val IV_BYTES = 12

    private fun secretKey(): SecretKey? {
        val store = KeyStore.getInstance(KEYSTORE).apply { load(null) }
        (store.getEntry(ALIAS, null) as? KeyStore.SecretKeyEntry)?.let { return it.secretKey }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE)
        generator.init(
            KeyGenParameterSpec.Builder(
                ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .build()
        )
        return generator.generateKey()
    }

    fun encrypt(plain: String): String? = runCatching {
        val key = secretKey() ?: return null
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key)
        val iv = cipher.iv
        val sealed = cipher.doFinal(plain.toByteArray())
        Base64.encodeToString(iv + sealed, Base64.NO_WRAP)
    }.getOrNull()

    fun decrypt(stored: String): String? = runCatching {
        val key = secretKey() ?: return null
        val raw = Base64.decode(stored, Base64.NO_WRAP)
        if (raw.size <= IV_BYTES) return null
        val iv = raw.copyOfRange(0, IV_BYTES)
        val body = raw.copyOfRange(IV_BYTES, raw.size)
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, iv))
        String(cipher.doFinal(body))
    }.getOrNull()
}

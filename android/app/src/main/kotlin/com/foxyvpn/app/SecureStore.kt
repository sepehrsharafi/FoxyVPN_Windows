package com.foxyvpn.app

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Log
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Small encrypted key/value store for the sign-in tokens (the Android twin of
 * the Windows DPAPI file). Values are encrypted with AES-256-GCM using a key
 * that lives in the Android Keystore (hardware backed where the device has it
 * and never leaves it), and stored as files in the app's private storage:
 *
 *     files/secure/<key>.bin  =  IV (12 bytes) || ciphertext + GCM tag
 *
 * The key name is bound to the ciphertext as associated data, so a file cannot
 * be swapped for another one. No extra library (and no Flutter plugin) is
 * needed. Anything that cannot be decrypted (a key that Android invalidated, a
 * damaged file) reads as "nothing saved", which the app treats as signed out.
 */
class SecureStore(context: Context) {
    private val dir = File(context.filesDir, "secure")

    @Synchronized
    fun get(key: String): String? {
        val file = fileFor(key)
        return try {
            if (!file.exists()) return null
            val blob = file.readBytes()
            if (blob.size <= IV_BYTES + TAG_BYTES) return null
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(
                Cipher.DECRYPT_MODE,
                secretKey(createIfMissing = false) ?: return null,
                GCMParameterSpec(TAG_BYTES * 8, blob, 0, IV_BYTES),
            )
            cipher.updateAAD(key.toByteArray(Charsets.UTF_8))
            String(cipher.doFinal(blob, IV_BYTES, blob.size - IV_BYTES), Charsets.UTF_8)
        } catch (t: Throwable) {
            Log.w(TAG, "could not read the secure value '$key'")
            null
        }
    }

    @Synchronized
    fun put(key: String, value: String) {
        val file = fileFor(key)
        dir.mkdirs()
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, secretKey(createIfMissing = true)!!)
        cipher.updateAAD(key.toByteArray(Charsets.UTF_8))
        val encrypted = cipher.doFinal(value.toByteArray(Charsets.UTF_8))
        val tmp = File(dir, file.name + ".tmp")
        tmp.writeBytes(cipher.iv + encrypted)
        if (!tmp.renameTo(file)) {
            file.delete()
            if (!tmp.renameTo(file)) throw IllegalStateException("could not save the secure value")
        }
    }

    @Synchronized
    fun delete(key: String) {
        fileFor(key).delete()
    }

    private fun fileFor(key: String): File {
        require(KEY_NAME.matches(key)) { "invalid key name" }
        return File(dir, "$key.bin")
    }

    private fun secretKey(createIfMissing: Boolean): SecretKey? {
        val store = KeyStore.getInstance(PROVIDER).apply { load(null) }
        (store.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        if (!createIfMissing) return null
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, PROVIDER)
        generator.init(
            KeyGenParameterSpec.Builder(
                ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build(),
        )
        return generator.generateKey()
    }

    private companion object {
        const val TAG = "SecureStore"
        const val PROVIDER = "AndroidKeyStore"
        const val ALIAS = "foxyvpn.secure.v1"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val IV_BYTES = 12
        const val TAG_BYTES = 16
        val KEY_NAME = Regex("[A-Za-z0-9._-]{1,64}")
    }
}

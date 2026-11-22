package com.namao.flutter

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.security.KeyStore
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * The user's own Instagram cookies.txt, kept on this phone only.
 *
 * The file is encrypted with AES-GCM under a key that lives in the Android Keystore (it cannot be
 * read out of the device), and stored in the app's private, backup-excluded storage. It is
 * decrypted only for the moment a yt-dlp run needs it, into a private temp file that is wiped
 * right after; nothing here logs, uploads or otherwise copies the contents. Dart has already
 * reduced the file to Instagram's own cookies before it gets here.
 */
class SessionVault(private val app: Context) {
    private val dir: File get() = File(app.noBackupFilesDir, "session")
    private val dataFile: File get() = File(dir, "instagram.enc")
    private val metaFile: File get() = File(dir, "instagram.json")
    private val tempDir: File get() = File(app.cacheDir, "session-tmp")

    fun exists(): Boolean = dataFile.isFile

    /** When it was saved and when its login cookie expires (epoch seconds), or null with no session. */
    fun info(): Map<String, Any?>? {
        if (!exists()) return null
        val meta = try {
            JSONObject(metaFile.readText())
        } catch (e: Exception) {
            JSONObject()
        }
        return mapOf(
            "savedAt" to meta.optLong("savedAt", 0L),
            "expiresAt" to if (meta.has("expiresAt")) meta.optLong("expiresAt") else null,
        )
    }

    @Synchronized
    fun save(text: String, expiresAtSeconds: Long?) {
        dir.mkdirs()
        val cipher = Cipher.getInstance(TRANSFORM)
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val sealed = cipher.iv + cipher.doFinal(text.toByteArray(Charsets.UTF_8))
        val pending = File(dir, "instagram.enc.tmp")
        pending.writeBytes(sealed)
        if (!pending.renameTo(dataFile)) {
            pending.delete()
            throw IOException("could not store the session")
        }
        val meta = JSONObject().put("savedAt", System.currentTimeMillis() / 1000)
        if (expiresAtSeconds != null) meta.put("expiresAt", expiresAtSeconds)
        metaFile.writeText(meta.toString())
    }

    @Synchronized
    fun remove() {
        dataFile.delete()
        metaFile.delete()
        File(dir, "instagram.enc.tmp").delete()
        wipeTemp()
        try {
            KeyStore.getInstance(KEYSTORE).apply { load(null) }.deleteEntry(KEY_ALIAS)
        } catch (e: Exception) {
            // The ciphertext is already gone; a leftover key protects nothing.
        }
    }

    /**
     * Decrypts the session into a private temp file for one run; the caller must pass it to
     * [discard] when the run ends. Null when there is no session, or when it can no longer be read
     * (the key was lost, say): then it is removed instead of failing every later run.
     */
    @Synchronized
    fun materialize(): File? {
        if (!exists()) return null
        val plain = try {
            val sealed = dataFile.readBytes()
            val cipher = Cipher.getInstance(TRANSFORM)
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(TAG_BITS, sealed, 0, IV_BYTES))
            cipher.doFinal(sealed, IV_BYTES, sealed.size - IV_BYTES)
        } catch (e: Exception) {
            remove()
            return null
        }
        tempDir.mkdirs()
        val file = File(tempDir, UUID.randomUUID().toString() + ".txt")
        file.writeBytes(plain)
        plain.fill(0)
        return file
    }

    /** Overwrites then deletes a file made by [materialize]. */
    fun discard(file: File) {
        try {
            if (file.isFile) file.writeBytes(ByteArray(file.length().toInt()))
        } catch (e: Exception) {
            // Deleting is what matters.
        }
        file.delete()
    }

    /** Removes temp copies a crashed run left behind. */
    fun wipeTemp() {
        tempDir.listFiles()?.forEach { discard(it) }
    }

    private fun key(): SecretKey {
        val store = KeyStore.getInstance(KEYSTORE).apply { load(null) }
        (store.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE)
        generator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
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
        const val KEYSTORE = "AndroidKeyStore"
        const val KEY_ALIAS = "namao_instagram_session"
        const val TRANSFORM = "AES/GCM/NoPadding"
        const val IV_BYTES = 12
        const val TAG_BITS = 128
    }
}

package com.namao.flutter

import android.content.Context
import android.util.Log
import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.MessageDigest
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.locks.ReentrantReadWriteLock

/**
 * Keeps the bundled yt-dlp current without a new app release.
 *
 * This is the only updater: the library's own one goes through the GitHub REST API (60 anonymous
 * requests an hour per address), which fails on shared networks, so the release files are fetched
 * directly. Only the stable channel is ever used (`releases/latest` never points at a nightly:
 * those live in a different repository).
 *
 * Like [LocalEngine] this class holds mechanics, not policy: Dart decides when to check and what
 * counts as newer. The guarantees that must hold even if Dart misbehaves live here:
 *  - nothing is swapped while any engine process runs (the [gate]'s read side is held by them);
 *  - the new file is checksum-verified before it replaces the old one and is swapped in atomically;
 *  - the new engine must start and report the expected version, or the previous file is restored;
 *  - an update interrupted by a crash is repaired the next time the engine starts ([recover]).
 */
class EngineUpdates(
    app: Context,
    /** Read-locked by every running engine process; the swap needs the write side. */
    private val gate: ReentrantReadWriteLock,
    /** Starts the installed engine and returns its version, or null when it does not run. */
    private val readVersion: () -> String?,
) {
    private val prefs = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    private val dir = File(app.noBackupFilesDir, "youtubedl-android/yt-dlp")
    private val binary = File(dir, "yt-dlp")
    private val previous = File(dir, "yt-dlp.previous")
    private val partial = File(dir, "yt-dlp.download")
    private val running = AtomicBoolean(false)

    @Volatile
    private var progress = -1

    /** The version last seen running; cached because reading it starts a Python process. */
    @Volatile
    var version: String? = null

    var autoUpdate: Boolean
        get() = prefs.getBoolean(KEY_AUTO, true)
        set(value) = prefs.edit().putBoolean(KEY_AUTO, value).apply()

    /** True on a fresh install: nothing has ever been checked or attempted. */
    val neverChecked: Boolean get() = lastCheck == 0L && prefs.getLong(KEY_LAST_ATTEMPT, 0L) == 0L

    // Installs from before the toggle existed only recorded the last successful update.
    private val lastCheck: Long
        get() = maxOf(prefs.getLong(KEY_LAST_CHECK, 0L), prefs.getLong(KEY_LAST_UPDATE, 0L))

    fun info(): Map<String, Any?> = mapOf(
        "version" to version,
        "previousVersion" to prefs.getString(KEY_PREVIOUS_VERSION, null),
        "autoUpdate" to autoUpdate,
        "lastCheckMs" to lastCheck.takeIf { it > 0 },
        "lastAttemptMs" to prefs.getLong(KEY_LAST_ATTEMPT, 0L).takeIf { it > 0 },
        "lastUpdateMs" to prefs.getLong(KEY_LAST_UPDATE, 0L).takeIf { it > 0 },
        "updating" to running.get(),
        "progress" to progress.takeIf { it >= 0 },
    )

    /** The check found nothing newer; remembered so the next automatic check is a day away. */
    fun markChecked() {
        prefs.edit().putLong(KEY_LAST_CHECK, System.currentTimeMillis()).apply()
    }

    // ------------------------------------------------------------------ startup repair

    /**
     * Runs once per process after the library has unpacked itself: removes a half-downloaded file
     * and, if the installed engine does not start (a crash landed between the swap and its
     * verification), puts the previous one back. Returns the version that is running afterwards.
     */
    fun recover(): String? {
        partial.delete()
        var current = readVersion()
        if (current == null && previous.isFile) {
            Log.w(TAG, "engine does not start; restoring the previous one")
            try {
                putPreviousBack()
                current = readVersion()
            } catch (e: IOException) {
                Log.w(TAG, "could not restore the previous engine", e)
            }
        }
        version = current
        return current
    }

    // ----------------------------------------------------------------------- the update

    /** The newest stable version, found without the GitHub API: the "latest" page redirects to its tag. */
    fun latestVersion(): String {
        prefs.edit().putLong(KEY_LAST_ATTEMPT, System.currentTimeMillis()).apply()
        try {
            val connection = URL(LATEST_URL).openConnection() as HttpURLConnection
            connection.instanceFollowRedirects = false
            connection.connectTimeout = CONNECT_TIMEOUT_MS
            connection.readTimeout = READ_TIMEOUT_MS
            try {
                val location = connection.getHeaderField("Location")
                if (connection.responseCode !in 300..399 || location == null) {
                    throw IOException("HTTP ${connection.responseCode} from the release page")
                }
                val target = URL(URL(LATEST_URL), location)
                val tag = TAG_PATH.matchEntire(target.path)?.groupValues?.get(1)
                if (target.protocol != "https" || target.host != "github.com" || tag == null) {
                    throw EngineException("update_failed", "unexpected release location $target")
                }
                return tag
            } finally {
                connection.disconnect()
            }
        } catch (e: IOException) {
            throw EngineException("network", e.message ?: e.javaClass.simpleName)
        }
    }

    /** First launch after install: take whatever is newest, without comparing, and never throw. */
    fun installLatestQuietly() {
        try {
            install(latestVersion())
        } catch (e: Exception) {
            Log.w(TAG, "first-run engine update did not complete", e)
        }
    }

    /**
     * Replaces the engine with release [wanted] and returns the version that runs afterwards.
     * Throws `busy` (without having changed anything) while an engine process is running, so a
     * download in progress is never disturbed; `network`; `verify_failed` (the previous engine is
     * back in place).
     */
    fun install(wanted: String): Map<String, Any?> {
        require(VERSION_TAG.matches(wanted)) { "bad engine version" }
        if (gate.readLockCount > 0 || !running.compareAndSet(false, true)) {
            throw EngineException("busy", "the engine is in use")
        }
        progress = 0
        try {
            fetchVerified("$RELEASE_ROOT$wanted/")
            return swap(wanted)
        } catch (e: IOException) {
            throw EngineException("network", e.message ?: e.javaClass.simpleName)
        } finally {
            partial.delete()
            progress = -1
            running.set(false)
        }
    }

    /** Downloads the release file next to the installed one and checks it against the published SHA-256. */
    private fun fetchVerified(base: String) {
        val expected = expectedChecksum(base)
        val digest = MessageDigest.getInstance("SHA-256")
        dir.mkdirs()
        val connection = open(base + "yt-dlp")
        try {
            val length = connection.contentLengthLong
            var received = 0L
            connection.inputStream.use { input ->
                partial.outputStream().use { out ->
                    val buffer = ByteArray(64 * 1024)
                    while (true) {
                        val n = input.read(buffer)
                        if (n < 0) break
                        digest.update(buffer, 0, n)
                        out.write(buffer, 0, n)
                        received += n
                        if (length > 0) progress = (received * PROGRESS_BEFORE_SWAP / length).toInt()
                    }
                }
            }
        } finally {
            connection.disconnect()
        }
        val actual = digest.digest().joinToString("") { "%02x".format(it) }
        if (partial.length() < MIN_YTDLP_BYTES || actual != expected) {
            partial.delete()
            throw EngineException("verify_failed", "downloaded engine failed its checksum")
        }
    }

    /** The one step that needs every engine process to be idle; it stays short (one copy, one start). */
    private fun swap(wanted: String): Map<String, Any?> {
        if (!gate.writeLock().tryLock()) throw EngineException("busy", "the engine is in use")
        try {
            val before = readVersion()
            // Keep the working engine as the way back. A broken current one must not replace an older good copy.
            if (before != null && binary.isFile) {
                Files.copy(binary.toPath(), previous.toPath(), StandardCopyOption.REPLACE_EXISTING)
            }
            Files.move(partial.toPath(), binary.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
            val after = readVersion()
            if (after == null || !sameRelease(after, wanted)) {
                restorePrevious()
                version = readVersion()
                throw EngineException("verify_failed", "the new engine reported ${after ?: "nothing"}, expected $wanted")
            }
            version = after
            val now = System.currentTimeMillis()
            prefs.edit()
                .putLong(KEY_LAST_UPDATE, now)
                .putLong(KEY_LAST_CHECK, now)
                .putString(KEY_PREVIOUS_VERSION, before)
                .apply()
            progress = 100
            Log.i(TAG, "engine updated from $before to $after")
            return mapOf("version" to after, "previousVersion" to before)
        } finally {
            gate.writeLock().unlock()
        }
    }

    /** Copies the saved engine beside the installed one, then moves it in: never a half-written file. */
    private fun putPreviousBack() {
        val staging = File(dir, "yt-dlp.restore")
        Files.copy(previous.toPath(), staging.toPath(), StandardCopyOption.REPLACE_EXISTING)
        Files.move(staging.toPath(), binary.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
    }

    private fun restorePrevious() {
        if (!previous.isFile) return
        try {
            putPreviousBack()
        } catch (e: IOException) {
            Log.w(TAG, "could not restore the previous engine", e)
        }
    }

    /** yt-dlp's `--version` equals the release tag for stable builds; tolerate a trailing build suffix. */
    private fun sameRelease(reported: String, wanted: String) =
        reported == wanted || reported.startsWith("$wanted.") || wanted.startsWith("$reported.")

    private fun expectedChecksum(base: String): String {
        val connection = open(base + "SHA2-256SUMS")
        try {
            val sums = connection.inputStream.bufferedReader().use { it.readText() }
            return sums.lineSequence()
                .map { it.trim().split(Regex("\\s+")) }
                .firstOrNull { it.size == 2 && it[1].removePrefix("*") == "yt-dlp" }
                ?.get(0)?.lowercase()
                ?: throw EngineException("verify_failed", "no checksum published for the engine")
        } finally {
            connection.disconnect()
        }
    }

    /** HTTPS only (redirects between HTTPS hosts are followed by the platform; a downgrade is refused). */
    private fun open(url: String): HttpURLConnection {
        require(url.startsWith("https://")) { "refusing a non-HTTPS download" }
        val connection = URL(url).openConnection() as HttpURLConnection
        connection.connectTimeout = CONNECT_TIMEOUT_MS
        connection.readTimeout = READ_TIMEOUT_MS
        if (connection.responseCode != 200) {
            connection.disconnect()
            throw IOException("HTTP ${connection.responseCode} for $url")
        }
        return connection
    }

    private companion object {
        const val TAG = "NamaoEngine"
        const val PREFS = "namao_engine"
        const val KEY_AUTO = "auto_update"
        const val KEY_LAST_CHECK = "last_check_ms"
        const val KEY_LAST_ATTEMPT = "last_update_attempt_ms"
        const val KEY_LAST_UPDATE = "last_update_ms"
        const val KEY_PREVIOUS_VERSION = "previous_version"
        const val LATEST_URL = "https://github.com/yt-dlp/yt-dlp/releases/latest"
        const val RELEASE_ROOT = "https://github.com/yt-dlp/yt-dlp/releases/download/"
        const val MIN_YTDLP_BYTES = 1_000_000L
        const val CONNECT_TIMEOUT_MS = 15_000
        const val READ_TIMEOUT_MS = 30_000

        /** The download is most of the work; the swap and the version check take the rest of the bar. */
        const val PROGRESS_BEFORE_SWAP = 90
        const val VERSION_PATTERN = "\\d{4}\\.\\d{2}\\.\\d{2}(?:\\.\\d+)?"
        val VERSION_TAG = Regex(VERSION_PATTERN)
        val TAG_PATH = Regex("/yt-dlp/yt-dlp/releases/tag/($VERSION_PATTERN)")
    }
}

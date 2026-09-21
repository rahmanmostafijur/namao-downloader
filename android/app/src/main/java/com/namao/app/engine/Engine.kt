package com.namao.app.engine

import androidx.documentfile.provider.DocumentFile
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import java.net.URI
import java.io.File

/**
 * URL -> supported-platform detection and light normalization. Mirrors
 * PLATFORM_PATTERNS in the desktop main.py so both surfaces agree on what
 * counts as a supported link.
 */
object PlatformDetector {

    private val PATTERNS = linkedMapOf(
        "youtube" to Regex("(youtube\\.com|youtu\\.be)", RegexOption.IGNORE_CASE),
        "facebook" to Regex("(facebook\\.com|fb\\.watch|fb\\.com)", RegexOption.IGNORE_CASE),
        "tiktok" to Regex("([a-z]{2}\\.)?tiktok\\.com", RegexOption.IGNORE_CASE),
        "twitter" to Regex("(twitter\\.com|x\\.com)", RegexOption.IGNORE_CASE),
        "instagram" to Regex("instagram\\.com", RegexOption.IGNORE_CASE),
    )

    // Tracking params known to be safe to drop — never touches anything that
    // could change *which* video a platform resolves (e.g. leaves youtube's
    // "v", "list", tiktok's item id, instagram's shortcode path untouched).
    private val TRACKING_PARAMS = setOf(
        "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content",
        "si", "igshid", "igsh", "fbclid", "gclid", "spm", "_r", "is_from_webapp",
        "sender_device", "referrer_video_id",
    )

    fun detect(url: String): String? =
        PATTERNS.entries.firstOrNull { it.value.containsMatchIn(url) }?.key

    /** Best-effort tracking-parameter strip. Falls back to the original string
     * unchanged for anything that doesn't parse as a URL, rather than risk
     * mangling a link the app can't fully understand. */
    fun normalize(rawUrl: String): String {
        val trimmed = rawUrl.trim()
        return try {
            val uri = URI(trimmed)
            val query = uri.rawQuery ?: return trimmed
            val kept = query.split("&")
                .filter { it.isNotBlank() }
                .filter { pair ->
                    val key = pair.substringBefore("=").lowercase()
                    key !in TRACKING_PARAMS
                }
            val newQuery = kept.joinToString("&").ifEmpty { null }
            URI(uri.scheme, uri.authority, uri.path, newQuery, uri.fragment).toString()
        } catch (e: Exception) {
            trimmed
        }
    }
}

/**
 * Filesystem-safe filenames, ported from main.py's ".120B" outtmpl truncation
 * plus the "never silently overwrite" requirement the desktop version didn't
 * need (it always downloads into a fresh temp dir).
 */
object FilenameSanitizer {

    private val INVALID_CHARS = Regex("[\\\\/:*?\"<>|\\x00-\\x1F]")
    private const val MAX_NAME_BYTES = 120

    fun sanitizeBaseName(rawTitle: String): String {
        val cleaned = INVALID_CHARS.replace(rawTitle, "").replace(Regex("\\s+"), " ").trim()
        val safe = cleaned.ifBlank { "video" }
        return truncateUtf8(safe, MAX_NAME_BYTES)
    }

    /** Truncates to at most [maxBytes] UTF-8 bytes without splitting a
     * multi-byte character, so non-Latin titles (Bengali, Japanese, ...)
     * never produce a corrupt filename. */
    private fun truncateUtf8(value: String, maxBytes: Int): String {
        val bytes = value.toByteArray(Charsets.UTF_8)
        if (bytes.size <= maxBytes) return value
        var end = maxBytes
        // Back off until we're not in the middle of a multi-byte sequence
        // (continuation bytes have the top two bits set to 10).
        while (end > 0 && (bytes[end].toInt() and 0xC0) == 0x80) end--
        return String(bytes, 0, end, Charsets.UTF_8)
    }

    /** Finds a filename in [dir] that doesn't collide with an existing file,
     * appending " (1)", " (2)", ... before the extension as needed. */
    fun uniqueNameIn(dir: File, desiredName: String): String {
        if (!File(dir, desiredName).exists()) return desiredName
        val (base, ext) = splitExtension(desiredName)
        var counter = 1
        while (true) {
            val candidate = if (ext.isEmpty()) "$base ($counter)" else "$base ($counter).$ext"
            if (!File(dir, candidate).exists()) return candidate
            counter++
        }
    }

    /** SAF equivalent of [uniqueNameIn] for a user-chosen tree Uri. */
    fun uniqueNameInTree(treeDoc: DocumentFile, desiredName: String): String {
        if (treeDoc.findFile(desiredName) == null) return desiredName
        val (base, ext) = splitExtension(desiredName)
        var counter = 1
        while (true) {
            val candidate = if (ext.isEmpty()) "$base ($counter)" else "$base ($counter).$ext"
            if (treeDoc.findFile(candidate) == null) return candidate
            counter++
        }
    }

    private fun splitExtension(name: String): Pair<String, String> {
        val dot = name.lastIndexOf('.')
        return if (dot <= 0) name to "" else name.substring(0, dot) to name.substring(dot + 1)
    }
}

/** Why a download failed, so the UI can show an honest, specific message and
 * decide whether an automatic retry is worth attempting. Named to mirror the
 * failure taxonomy this app is designed around (extraction vs. network vs.
 * format vs. storage vs. processing), not just a generic try/catch. */
enum class FailureKind {
    NETWORK, TIMEOUT, RATE_LIMITED, PERMANENT_UNAVAILABLE, UNSUPPORTED_SOURCE,
    FORMAT_NOT_AVAILABLE, STORAGE, CONVERSION, CANCELLED, UNKNOWN
}

object ErrorClassifier {

    fun classify(message: String?): FailureKind {
        val text = (message ?: "").lowercase()
        return when {
            "cancel" in text || "interrupted" in text -> FailureKind.CANCELLED
            // Checked before the generic network bucket: a 429/"too many
            // requests" is a distinct condition that deserves a longer
            // backoff and a message that doesn't imply a broken connection.
            "429" in text || "too many requests" in text || "rate limit" in text || "rate-limit" in text ->
                FailureKind.RATE_LIMITED
            "timed out" in text || "timeout" in text -> FailureKind.TIMEOUT
            "unknownhost" in text || "connection reset" in text || "failed to establish" in text ||
                "network is unreachable" in text || "no address associated" in text ||
                "connect error" in text || "econnreset" in text -> FailureKind.NETWORK
            "private" in text || "login required" in text || "sign in" in text ||
                "age-restricted" in text || "age restricted" in text || "no longer available" in text ||
                "has been removed" in text || "does not exist" in text || "unavailable" in text ->
                FailureKind.PERMANENT_UNAVAILABLE
            "unsupported url" in text || "is not a valid url" in text -> FailureKind.UNSUPPORTED_SOURCE
            // The link IS a supported platform, but this specific item has no
            // usable stream at all (distinct from the platform being unsupported).
            "no video formats" in text || "requested format not available" in text ->
                FailureKind.FORMAT_NOT_AVAILABLE
            "enospc" in text || "no space left" in text || "not enough storage" in text -> FailureKind.STORAGE
            "ffmpeg" in text || "postprocess" in text || "conversion" in text -> FailureKind.CONVERSION
            else -> FailureKind.UNKNOWN
        }
    }

    fun isAutoRetryable(kind: FailureKind): Boolean =
        kind == FailureKind.NETWORK || kind == FailureKind.TIMEOUT || kind == FailureKind.RATE_LIMITED

    /** User-facing copy — never the raw exception text (Phase 22/23: no stack
     * traces surfaced to normal users). */
    fun userMessage(kind: FailureKind): String = when (kind) {
        FailureKind.NETWORK -> "Your connection was interrupted. Check your network and try again."
        FailureKind.TIMEOUT -> "The connection timed out. You can retry the download."
        FailureKind.RATE_LIMITED -> "This platform is temporarily limiting requests. Please wait a moment and try again."
        FailureKind.PERMANENT_UNAVAILABLE -> "This content is not accessible through the provided link. It may be private, deleted, or age-restricted."
        FailureKind.UNSUPPORTED_SOURCE -> "This link cannot be downloaded by the app."
        FailureKind.FORMAT_NOT_AVAILABLE -> "We couldn't retrieve the available video formats. Please try again."
        FailureKind.STORAGE -> "Not enough storage space is available."
        FailureKind.CONVERSION -> "The video was downloaded, but conversion to the selected format failed."
        FailureKind.CANCELLED -> "Download cancelled."
        FailureKind.UNKNOWN -> "Unable to access this video right now. Please try again."
    }
}

/** Exponential backoff for transient failures only — permanent/unsupported
 * failures are never retried automatically (Phase 4). */
object RetryPolicy {

    suspend fun <T> withRetry(
        maxAttempts: Int = 3,
        initialDelayMs: Long = 1500,
        factor: Double = 3.0,
        shouldRetry: (FailureKind) -> Boolean,
        classify: (Throwable) -> FailureKind,
        block: suspend (attempt: Int) -> T,
    ): T {
        var attempt = 0
        var delayMs = initialDelayMs
        while (true) {
            attempt++
            try {
                return block(attempt)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Throwable) {
                val kind = classify(e)
                if (attempt >= maxAttempts || !shouldRetry(kind)) throw e
                delay(delayMs)
                delayMs = (delayMs * factor).toLong()
            }
        }
    }
}

/** One selectable download option, built only from qualities the source
 * actually reports — never a fabricated resolution (Phase 7/30). */
data class QualityOption(
    val id: String,
    val label: String,
    val note: String,
    val sizeLabel: String?,
    val kind: String, // "progressive" | "video-only" | "audio"
)

data class MediaInfo(
    val platform: String,
    val title: String,
    val uploader: String,
    val durationSeconds: Long,
    val thumbnailUrl: String?,
    val qualities: List<QualityOption>,
)

object FileSize {
    fun format(numBytes: Long?): String? {
        if (numBytes == null || numBytes <= 0) return null
        var size = numBytes.toDouble()
        for (unit in listOf("B", "KB", "MB", "GB")) {
            if (size < 1024 || unit == "GB") {
                return if (unit == "B") "${size.toInt()} B" else String.format("%.1f %s", size, unit)
            }
            size /= 1024
        }
        return null
    }
}

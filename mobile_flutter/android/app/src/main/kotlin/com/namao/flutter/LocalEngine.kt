package com.namao.flutter

import android.content.Context
import android.util.Log
import com.yausername.ffmpeg.FFmpeg
import com.yausername.youtubedl_android.YoutubeDL
import com.yausername.youtubedl_android.YoutubeDLException
import com.yausername.youtubedl_android.YoutubeDLRequest
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** An engine failure with the tool's own message (never shown to people; Dart classifies it). */
class EngineException(val code: String, message: String) : Exception(message)

/**
 * Runs the bundled yt-dlp + FFmpeg on this phone. Deliberately policy-free: Dart decides every
 * command-line option and interprets progress and errors, so the logic stays testable. This class
 * only starts processes, keeps the raw state of each job for Dart to poll, and remembers a
 * finished file across process restarts.
 */
class LocalEngine private constructor(private val app: Context) {
    private val pool = Executors.newCachedThreadPool()
    private val jobs = ConcurrentHashMap<String, JobState>()
    private val initLock = Any()
    private val prefs = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    @Volatile
    private var initialized = false

    private val jobsRoot: File get() = File(app.noBackupFilesDir, "jobs")

    private class Stream(var downloaded: Long = 0, var total: Long = 0, var done: Boolean = false)

    private class JobState(val id: String, val dir: File) {
        @Volatile var state = "running"
        @Volatile var processing = false
        @Volatile var speed: Double? = null
        @Volatile var eta: Long? = null
        @Volatile var error: String? = null
        @Volatile var title: String? = null
        @Volatile var duration: Double? = null
        @Volatile var file: File? = null
        val streams = LinkedHashMap<String, Stream>()
    }

    // ------------------------------------------------------------------ lifecycle

    /**
     * Unpacks the bundled runtime (first launch only) and makes sure yt-dlp is recent: sites change
     * constantly, so a build that is months old fails. A fresh install updates before returning,
     * with a time limit; later launches refresh in the background once a day.
     */
    fun init(): Map<String, Any?> {
        synchronized(initLock) {
            if (!initialized) {
                try {
                    YoutubeDL.getInstance().init(app)
                    FFmpeg.init(app)
                } catch (e: Exception) {
                    throw EngineException("init_failed", e.message ?: e.javaClass.simpleName)
                }
                initialized = true
                refreshIfStale()
            }
        }
        return mapOf("version" to readVersion())
    }

    /**
     * Updates when the last success is over a day old. A failed attempt is not retried for a few
     * hours, and only the very first attempt on a new install is waited for: on a network where
     * GitHub is blocked or slow, every launch would otherwise stall its first link.
     */
    private fun refreshIfStale() {
        val now = System.currentTimeMillis()
        val last = prefs.getLong(KEY_LAST_UPDATE, 0L)
        val attempted = prefs.getLong(KEY_LAST_ATTEMPT, 0L)
        if (now - last < UPDATE_EVERY_MS) return
        if (attempted != 0L && now - attempted < RETRY_AFTER_FAILURE_MS) return
        prefs.edit().putLong(KEY_LAST_ATTEMPT, now).apply()
        val update = pool.submit { updateNow() }
        if (last == 0L && attempted == 0L) {
            try {
                update.get(FIRST_UPDATE_LIMIT_SECONDS, TimeUnit.SECONDS)
            } catch (e: Exception) {
                Log.w(TAG, "first-run engine update did not finish in time", e)
            }
        }
    }

    /**
     * Fetches yt-dlp's latest release file directly. (The library's own updater goes through the
     * GitHub REST API, which allows only 60 anonymous requests an hour per address: phones behind a
     * shared network address fail it.) The file is checked against the release's published
     * SHA-256 before it replaces the old one, and is swapped in atomically, so a dropped
     * connection can never leave a broken engine behind.
     */
    private fun updateNow() {
        try {
            val target = File(app.noBackupFilesDir, "youtubedl-android/yt-dlp/yt-dlp")
            val partial = File(target.parentFile, "yt-dlp.download")
            val expected = expectedChecksum()
            val digest = MessageDigest.getInstance("SHA-256")
            open(RELEASE_URL + "yt-dlp").use { input ->
                partial.outputStream().use { out ->
                    val buffer = ByteArray(64 * 1024)
                    while (true) {
                        val n = input.read(buffer)
                        if (n < 0) break
                        digest.update(buffer, 0, n)
                        out.write(buffer, 0, n)
                    }
                }
            }
            val actual = digest.digest().joinToString("") { "%02x".format(it) }
            if (partial.length() < MIN_YTDLP_BYTES || actual != expected) {
                partial.delete()
                throw IOException("downloaded yt-dlp failed verification")
            }
            Files.move(partial.toPath(), target.toPath(), StandardCopyOption.REPLACE_EXISTING)
            prefs.edit().putLong(KEY_LAST_UPDATE, System.currentTimeMillis()).apply()
            Log.i(TAG, "engine updated to ${readVersion()}")
        } catch (e: Exception) {
            Log.w(TAG, "engine update failed", e)
        }
    }

    private fun expectedChecksum(): String {
        val sums = open(RELEASE_URL + "SHA2-256SUMS").bufferedReader().use { it.readText() }
        return sums.lineSequence()
            .map { it.trim().split(Regex("\\s+")) }
            .firstOrNull { it.size == 2 && it[1].removePrefix("*") == "yt-dlp" }
            ?.get(0)?.lowercase()
            ?: throw IOException("no checksum published for yt-dlp")
    }

    private fun open(url: String): InputStream {
        val connection = URL(url).openConnection() as HttpURLConnection
        connection.connectTimeout = 15_000
        connection.readTimeout = 30_000
        if (connection.responseCode != 200) throw IOException("HTTP ${connection.responseCode} for $url")
        return connection.inputStream
    }

    /** The version of the yt-dlp that is installed right now (it changes when an update lands). */
    private fun readVersion(): String? = try {
        YoutubeDL.getInstance().execute(YoutubeDLRequest(emptyList<String>()).addCommands(listOf("--version")), null, null)
            .out.trim().ifEmpty { null }
    } catch (e: Exception) {
        Log.w(TAG, "could not read the engine version", e)
        null
    }

    // ------------------------------------------------------------------- metadata

    /** Runs yt-dlp with [args] against [url] and returns its standard output. */
    fun run(url: String, args: List<String>): String {
        requireWebUrl(url)
        ensureReady()
        val request = YoutubeDLRequest(url).addCommands(args)
        try {
            return YoutubeDL.getInstance().execute(request, null, null).out
        } catch (e: YoutubeDLException) {
            throw EngineException("run_failed", e.message ?: "")
        }
    }

    // ------------------------------------------------------------------ downloads

    fun start(jobId: String, url: String, args: List<String>) {
        requireWebUrl(url)
        ensureReady()
        require(jobId.matches(JOB_ID)) { "bad job id" }
        val dir = File(jobsRoot, jobId).apply { mkdirs() }
        val job = JobState(jobId, dir)
        if (jobs.putIfAbsent(jobId, job) != null) return // a repeat of the same start
        try {
            pool.execute { download(job, url, args) }
        } catch (e: RuntimeException) {
            jobs.remove(jobId) // never leave a job "running" that has no thread behind it
            dir.deleteRecursively()
            throw EngineException("engine_error", e.message ?: "could not start")
        }
    }

    /** The URL goes straight onto yt-dlp's command line: it must not be able to look like an option. */
    private fun requireWebUrl(url: String) =
        require(url.startsWith("https://") || url.startsWith("http://")) { "not a web link" }

    private fun download(job: JobState, url: String, args: List<String>) {
        try {
            if (job.state != "running") return // cancelled before the process could start
            // The location and the machine-readable progress/result lines are this class's contract
            // with yt-dlp (parsed in onLine), so they live here rather than in Dart's options.
            // --no-quiet: `--print` implies quiet, which would hide the "[Merger]" lines that tell
            // us the transfer is over and the file is being finished.
            val request = YoutubeDLRequest(url).addCommands(args).addCommands(
                listOf(
                    "--no-quiet", "--newline", "--progress", "--no-colors",
                    "--progress-template", "download:$PROGRESS_PREFIX%(progress)j",
                    "--print", "after_move:$DONE_PREFIX%(.{title,duration,ext})j",
                    "-P", job.dir.absolutePath,
                    "-P", "temp:" + File(job.dir, "tmp").absolutePath,
                    "-o", "$OUTPUT_NAME%(ext)s",
                ),
            )
            YoutubeDL.getInstance().execute(request, job.id) { _, _, line -> onLine(job, line) }
            finish(job)
        } catch (e: YoutubeDL.CanceledException) {
            settle(job, "cancelled", null)
        } catch (e: InterruptedException) {
            settle(job, "cancelled", null)
        } catch (e: Throwable) {
            // Throwable, not Exception: an Error (out of memory, a native library that will not load)
            // must still end the job, or it would stay "running" and be polled forever.
            settle(job, "failed", e.message ?: e.javaClass.simpleName)
        }
        if (job.state != "completed") job.dir.deleteRecursively()
    }

    /** Moves a still-running job to a final state; a job already settled (say, cancelled) is left alone. */
    private fun settle(job: JobState, state: String, error: String?) = synchronized(job) {
        if (job.state == "running") {
            job.error = error
            job.state = state
        }
    }

    private fun onLine(job: JobState, raw: String) {
        val line = raw.trim()
        when {
            line.startsWith(PROGRESS_PREFIX) -> onProgress(job, line.removePrefix(PROGRESS_PREFIX))
            line.startsWith(DONE_PREFIX) -> onDone(job, line.removePrefix(DONE_PREFIX))
            POST_PROCESSING.any { line.startsWith(it) } -> job.processing = true
        }
    }

    private fun onProgress(job: JobState, json: String) {
        val event = try {
            JSONObject(json)
        } catch (e: Exception) {
            return
        }
        val key = event.optString("filename").ifEmpty { "stream" }
        synchronized(job.streams) {
            val stream = job.streams.getOrPut(key) { Stream() }
            stream.downloaded = maxOf(stream.downloaded, event.optLong("downloaded_bytes", 0))
            val total = event.optLong("total_bytes", 0).takeIf { it > 0 }
                ?: event.optLong("total_bytes_estimate", 0)
            if (total > 0) stream.total = maxOf(stream.total, total)
            if (event.optString("status") == "finished") stream.done = true
        }
        job.speed = if (event.isNull("speed")) null else event.optDouble("speed")
        job.eta = if (event.isNull("eta")) null else event.optLong("eta")
    }

    private fun onDone(job: JobState, json: String) {
        try {
            val info = JSONObject(json)
            job.title = info.optString("title").ifEmpty { null }
            job.duration = if (info.isNull("duration")) null else info.optDouble("duration")
        } catch (e: Exception) {
            Log.w(TAG, "unreadable completion line", e)
        }
    }

    private fun finish(job: JobState) {
        val media = job.dir.listFiles { f -> f.isFile && f.name.startsWith(OUTPUT_NAME) && !isPartial(f) }
            ?.maxByOrNull { it.length() }
        if (media == null || media.length() == 0L) {
            settle(job, "failed", "no output file was produced")
            return
        }
        synchronized(job) {
            if (job.state != "running") return // cancelled while the last bytes were landing
            job.file = media
            File(job.dir, RESULT_FILE).writeText(
                JSONObject()
                    .put("name", media.name)
                    .put("title", job.title ?: JSONObject.NULL)
                    .put("duration", job.duration ?: JSONObject.NULL)
                    .toString(),
            )
            job.state = "completed"
        }
    }

    private fun isPartial(file: File) =
        file.name.endsWith(".part") || file.name.endsWith(".ytdl") || file.name.contains(".temp.")

    /** The raw state of a job, or null when this process has never heard of it. */
    fun status(jobId: String): Map<String, Any?>? {
        val job = jobs[jobId] ?: recover(jobId) ?: return null
        val streams = synchronized(job.streams) {
            job.streams.map { (key, s) ->
                mapOf("key" to key, "downloaded" to s.downloaded, "total" to s.total, "done" to s.done)
            }
        }
        val file = job.file
        return mapOf(
            "state" to job.state,
            "processing" to job.processing,
            "streams" to streams,
            "speed" to job.speed,
            "eta" to job.eta,
            "error" to job.error,
            "title" to job.title,
            "duration" to job.duration,
            "path" to file?.absolutePath,
            "size" to file?.length(),
        )
    }

    /** A job that finished in an earlier process: its result marker and file are still on disk. */
    private fun recover(jobId: String): JobState? {
        if (!jobId.matches(JOB_ID)) return null
        val dir = File(jobsRoot, jobId)
        val marker = File(dir, RESULT_FILE)
        if (!marker.isFile) return null
        return try {
            val info = JSONObject(marker.readText())
            val media = File(dir, info.getString("name"))
            if (!media.isFile) return null
            JobState(jobId, dir).also {
                it.state = "completed"
                it.file = media
                it.title = if (info.isNull("title")) null else info.getString("title")
                jobs[jobId] = it
            }
        } catch (e: Exception) {
            null
        }
    }

    fun cancel(jobId: String) {
        val job = jobs[jobId] ?: return
        synchronized(job) {
            if (job.state != "running") return
            job.state = "cancelled"
        }
        YoutubeDL.getInstance().destroyProcessById(jobId)
        job.dir.deleteRecursively()
    }

    /** Removes a job's working files (after the file was saved, or the entry was removed). */
    fun release(jobId: String) {
        if (!jobId.matches(JOB_ID)) return
        val job = jobs[jobId]
        if (job != null && job.state == "running") return
        jobs.remove(jobId)
        File(jobsRoot, jobId).deleteRecursively()
    }

    /** Deletes the working files of every job not in [keep] (leftovers of crashed or removed jobs). */
    fun cleanup(keep: Set<String>) {
        val dirs = jobsRoot.listFiles { f -> f.isDirectory } ?: return
        for (dir in dirs) {
            val job = jobs[dir.name]
            if (dir.name in keep || job?.state == "running") continue
            jobs.remove(dir.name)
            dir.deleteRecursively()
        }
    }

    /** The app is closing: stop every running download so no orphan process keeps using the network. */
    fun cancelAll() {
        for (job in jobs.values) if (job.state == "running") cancel(job.id)
    }

    private fun ensureReady() {
        if (!initialized) init()
    }

    companion object {
        @Volatile
        private var instance: LocalEngine? = null

        /**
         * One engine per process. The Activity (and its Flutter engine) can be destroyed and recreated
         * while the process lives on; a second instance would not know the running downloads and
         * would report them as lost.
         */
        fun get(context: Context): LocalEngine = instance ?: synchronized(this) {
            instance ?: LocalEngine(context.applicationContext).also { instance = it }
        }

        private const val TAG = "NamaoEngine"
        private const val PREFS = "namao_engine"
        private const val KEY_LAST_UPDATE = "last_update_ms"
        private const val KEY_LAST_ATTEMPT = "last_update_attempt_ms"
        private const val RETRY_AFTER_FAILURE_MS = 3L * 60 * 60 * 1000
        private const val UPDATE_EVERY_MS = 24L * 60 * 60 * 1000
        private const val FIRST_UPDATE_LIMIT_SECONDS = 60L
        private const val RELEASE_URL = "https://github.com/yt-dlp/yt-dlp/releases/latest/download/"
        private const val MIN_YTDLP_BYTES = 1_000_000L
        private const val PROGRESS_PREFIX = "NAMAO_P "
        private const val DONE_PREFIX = "NAMAO_DONE "
        private const val OUTPUT_NAME = "media."
        private const val RESULT_FILE = "result.json"
        private val JOB_ID = Regex("[A-Za-z0-9-]{8,64}")
        private val POST_PROCESSING = listOf("[Merger]", "[ExtractAudio]", "[VideoConvertor]", "[VideoRemuxer]", "[Fixup")
    }
}

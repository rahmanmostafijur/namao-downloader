package com.namao.app.service

import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.os.IBinder
import android.util.Log
import android.webkit.MimeTypeMap
import androidx.core.app.ServiceCompat
import com.namao.app.NamaoApplication
import com.namao.app.data.DownloadEntity
import com.namao.app.data.DownloadRepository
import com.namao.app.data.DownloadStatus
import com.namao.app.data.statusEnum
import com.namao.app.engine.CookieStore
import com.namao.app.engine.ErrorClassifier
import com.namao.app.engine.RetryPolicy
import com.namao.app.settings.SettingsRepository
import com.namao.app.storage.FileStore
import com.yausername.youtubedl_android.YoutubeDL
import com.yausername.youtubedl_android.YoutubeDLRequest
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File

/**
 * Owns the actual download queue as a foreground service so jobs keep
 * running when the app is backgrounded, the screen locks, or the Activity is
 * recreated (Phase 2). The Activity/UI only ever reads progress back out of
 * the Room database — it never drives a download directly.
 */
class DownloadService : Service() {

    private val supervisorJob = SupervisorJob()
    private val serviceScope = CoroutineScope(supervisorJob + Dispatchers.Default)
    private lateinit var repository: DownloadRepository
    private lateinit var settingsRepository: SettingsRepository
    private lateinit var fileStore: FileStore
    private lateinit var notifications: DownloadNotifications
    private lateinit var connectivityManager: ConnectivityManager

    private val stateMutex = Mutex()
    private val runningJobs = mutableMapOf<String, Job>()
    private val pausedByUser = mutableSetOf<String>()
    private val cancelledByUser = mutableSetOf<String>()
    private val lastReportedPercent = mutableMapOf<String, Int>()
    private var anchorJobId: String? = null
    private var isForeground = false

    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            serviceScope.launch { checkQueue() }
        }

        override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
            serviceScope.launch { checkQueue() }
        }
    }

    override fun onCreate() {
        super.onCreate()
        val app = application as NamaoApplication
        repository = app.downloadRepository
        settingsRepository = app.settingsRepository
        fileStore = FileStore(this)
        notifications = DownloadNotifications(this)
        notifications.ensureChannel()
        connectivityManager = getSystemService(ConnectivityManager::class.java)
        connectivityManager.registerNetworkCallback(NetworkRequest.Builder().build(), networkCallback)
        // A fresh Service instance means runningJobs starts empty, so any row
        // still marked PREPARING/DOWNLOADING/PROCESSING is orphaned state from
        // a process that died mid-download, not a job actually in progress.
        serviceScope.launch {
            repository.reconcileInterruptedJobs()
            checkQueue()
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_CANCEL_JOB -> intent.getStringExtra(EXTRA_JOB_ID)?.let { cancelJob(it) }
            ACTION_PAUSE_JOB -> intent.getStringExtra(EXTRA_JOB_ID)?.let { pauseJob(it) }
            ACTION_RESUME_JOB -> intent.getStringExtra(EXTRA_JOB_ID)?.let { resumeJob(it) }
            ACTION_RETRY_JOB -> intent.getStringExtra(EXTRA_JOB_ID)?.let { retryJob(it) }
        }
        serviceScope.launch { checkQueue() }
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        super.onDestroy()
        runCatching { connectivityManager.unregisterNetworkCallback(networkCallback) }
        supervisorJob.cancel()
    }

    private fun cancelJob(jobId: String) {
        cancelledByUser += jobId
        val running = runningJobs[jobId]
        if (running != null) {
            YoutubeDL.getInstance().destroyProcessById(jobId)
        } else {
            serviceScope.launch {
                repository.markCancelled(jobId)
                cleanupTempDir(jobId)
                notifications.cancelJobNotification(jobId)
            }
        }
    }

    private fun pauseJob(jobId: String) {
        if (!runningJobs.containsKey(jobId)) return
        pausedByUser += jobId
        YoutubeDL.getInstance().destroyProcessById(jobId)
    }

    private fun resumeJob(jobId: String) {
        serviceScope.launch {
            val entity = repository.getById(jobId) ?: return@launch
            if (entity.statusEnum != DownloadStatus.PAUSED) return@launch
            repository.update(entity.copy(status = DownloadStatus.QUEUED.name))
            checkQueue()
        }
    }

    private fun retryJob(jobId: String) {
        serviceScope.launch {
            repository.requeue(jobId)
            checkQueue()
        }
    }

    /** Pulls as many QUEUED jobs as the concurrency/network settings allow
     * and starts them; stops the foreground service once nothing is left
     * running or queued. */
    private suspend fun checkQueue() {
        val settings = settingsRepository.settings.first()
        var nothingRunning: Boolean
        stateMutex.withLock {
            val canStartMore = runningJobs.size < settings.maxConcurrentDownloads &&
                !(settings.wifiOnly && !isOnWifi())
            if (canStartMore) {
                val queued = repository.getQueuedOnce()
                var slots = settings.maxConcurrentDownloads - runningJobs.size
                for (entity in queued) {
                    if (slots <= 0) break
                    if (runningJobs.containsKey(entity.id)) continue
                    val job = serviceScope.launch { runDownload(entity) }
                    runningJobs[entity.id] = job
                    if (anchorJobId == null) anchorJobId = entity.id
                    slots--
                }
            }
            // Read while still holding the lock — another checkQueue() call
            // could otherwise add a job between releasing the lock and this
            // check, causing a premature stopSelf().
            nothingRunning = runningJobs.isEmpty()
        }
        if (nothingRunning) {
            stopForegroundGracefully()
        }
    }

    private fun isOnWifi(): Boolean {
        val network = connectivityManager.activeNetwork ?: return false
        val caps = connectivityManager.getNetworkCapabilities(network) ?: return false
        return caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)
    }

    private suspend fun runDownload(entity: DownloadEntity) {
        val app = application as NamaoApplication
        val jobId = entity.id
        try {
            repository.updateProgress(jobId, DownloadStatus.PREPARING, 0f)
            promoteForeground(entity, 0)
            app.awaitEngineReady()

            val tempDir = tempDirFor(jobId).apply { mkdirs() }
            repository.updateProgress(jobId, DownloadStatus.DOWNLOADING, 0f)

            RetryPolicy.withRetry(
                shouldRetry = { ErrorClassifier.isAutoRetryable(it) },
                classify = { ErrorClassifier.classify(it.message) },
            ) {
                if (jobId in cancelledByUser || jobId in pausedByUser) {
                    throw IllegalStateException("cancelled")
                }
                val request = buildRequest(entity, tempDir)
                // execute() blocks synchronously for the whole download, so it
                // must run on the IO dispatcher's large thread pool rather than
                // Default's CPU-sized one, or concurrent downloads would starve
                // other coroutines (progress updates, queue checks) on this service.
                withContext(Dispatchers.IO) {
                    YoutubeDL.getInstance().execute(request, jobId) { progress, etaSeconds, _ ->
                        // etaSeconds comes straight from yt-dlp's own progress
                        // line — real, not estimated locally (Phase 20).
                        reportProgress(jobId, progress.toInt().coerceIn(0, 99), etaSeconds.takeIf { it > 0 })
                    }
                }
            }

            repository.updateProgress(jobId, DownloadStatus.PROCESSING, 100f)
            val files = tempDir.listFiles()?.filter { it.isFile && it.length() > 0 }.orEmpty()
            if (files.isEmpty()) {
                throw IllegalStateException("Download produced no file.")
            }
            val resultFile = files.maxBy { it.length() }

            val finalized = withContext(Dispatchers.IO) { fileStore.finalize(resultFile, entity.title) }
            repository.markCompleted(
                id = jobId,
                storageKind = finalized.storageKind,
                filePath = finalized.filePath,
                contentUri = finalized.contentUri,
                fileName = finalized.fileName,
                fileSizeBytes = finalized.sizeBytes,
            )
            cleanupTempDir(jobId)

            val settings = settingsRepository.settings.first()
            if (settings.notifyOnComplete) {
                val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(resultFile.extension)
                val viewUri = repository.getById(jobId)?.let { fileStore.viewUri(it) }
                notifications.notifyCompleted(jobId, entity.title, viewUri, mime)
            }
        } catch (e: Exception) {
            handleFailure(jobId, entity, e)
        } finally {
            stateMutex.withLock {
                runningJobs.remove(jobId)
                lastReportedPercent.remove(jobId)
                if (anchorJobId == jobId) anchorJobId = runningJobs.keys.firstOrNull()
            }
            checkQueue()
        }
    }

    private suspend fun handleFailure(jobId: String, entity: DownloadEntity, e: Exception) {
        when {
            jobId in cancelledByUser -> {
                cancelledByUser.remove(jobId)
                repository.markCancelled(jobId)
                cleanupTempDir(jobId)
            }
            jobId in pausedByUser -> {
                pausedByUser.remove(jobId)
                val current = repository.getById(jobId)
                repository.markPaused(jobId, current?.progressPercent ?: 0f)
                // Temp dir is intentionally kept so Resume can continue via
                // yt-dlp's own byte-range support.
            }
            else -> {
                val kind = ErrorClassifier.classify(e.message)
                val message = ErrorClassifier.userMessage(kind)
                Log.w(TAG, "download failed for $jobId: ${e.message}")
                repository.markFailed(jobId, message, kind.name)
                cleanupTempDir(jobId)
                notifications.notifyFailed(jobId, entity.title, message)
            }
        }
    }

    private fun reportProgress(jobId: String, percent: Int, etaSeconds: Long?) {
        val last = lastReportedPercent[jobId]
        if (last != null && last == percent) return
        lastReportedPercent[jobId] = percent
        serviceScope.launch {
            repository.updateProgress(jobId, DownloadStatus.DOWNLOADING, percent.toFloat(), etaSeconds)
            if (jobId == anchorJobId) {
                promoteForeground(repository.getById(jobId), percent)
            }
        }
    }

    private fun promoteForeground(entity: DownloadEntity?, percent: Int) {
        val title = entity?.title ?: "Download"
        val notification = notifications.buildProgressNotification(
            activeCount = runningJobs.size.coerceAtLeast(1),
            primaryTitle = title,
            progressPercent = percent,
            indeterminate = percent <= 0,
        )
        if (!isForeground) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                ServiceCompat.startForeground(
                    this, DownloadNotifications.FOREGROUND_NOTIFICATION_ID, notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
                )
            } else {
                startForeground(DownloadNotifications.FOREGROUND_NOTIFICATION_ID, notification)
            }
            isForeground = true
        } else {
            startForeground(DownloadNotifications.FOREGROUND_NOTIFICATION_ID, notification)
        }
    }

    private fun stopForegroundGracefully() {
        if (isForeground) {
            stopForeground(STOP_FOREGROUND_REMOVE)
            isForeground = false
        }
        stopSelf()
    }

    private fun buildRequest(entity: DownloadEntity, tempDir: File): YoutubeDLRequest {
        val outTemplate = File(tempDir, "%(title).120B.%(ext)s").absolutePath
        val request = YoutubeDLRequest(entity.sourceUrl)
        CookieStore.applyTo(this, request)
        request.addOption("-o", outTemplate)
        when {
            entity.qualityId == "audio" -> {
                request.addOption("-f", "bestaudio/best")
                request.addOption("-x")
                request.addOption("--audio-format", "mp3")
                request.addOption("--audio-quality", "192K")
            }
            entity.qualityId == "best" -> {
                request.addOption("-f", "bv*+ba/b")
                request.addOption("--merge-output-format", "mp4")
            }
            else -> {
                val height = entity.qualityId.toIntOrNull()
                    ?: throw IllegalArgumentException("Invalid quality value.")
                request.addOption("-f", "bv*[height<=$height]+ba/b[height<=$height]/b")
                request.addOption("--merge-output-format", "mp4")
            }
        }
        return request
    }

    private fun tempDirFor(jobId: String): File = File(cacheDir, "dl_$jobId")

    private fun cleanupTempDir(jobId: String) {
        tempDirFor(jobId).deleteRecursively()
    }

    companion object {
        private const val TAG = "Namao"
        const val ACTION_CANCEL_JOB = "com.namao.app.action.CANCEL_JOB"
        const val ACTION_PAUSE_JOB = "com.namao.app.action.PAUSE_JOB"
        const val ACTION_RESUME_JOB = "com.namao.app.action.RESUME_JOB"
        const val ACTION_RETRY_JOB = "com.namao.app.action.RETRY_JOB"
        const val EXTRA_JOB_ID = "job_id"
    }
}

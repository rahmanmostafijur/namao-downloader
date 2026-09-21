package com.namao.app.data

import kotlinx.coroutines.flow.Flow
import java.util.UUID

/**
 * Thin wrapper around [DownloadDao] — the single place that knows how a job
 * moves between queue and history (they're the same table, split by status).
 */
class DownloadRepository(private val dao: DownloadDao) {

    fun observeActive(): Flow<List<DownloadEntity>> = dao.observeByStatuses(ACTIVE_STATUSES)

    fun observeHistory(): Flow<List<DownloadEntity>> = dao.observeByStatuses(TERMINAL_STATUSES)

    fun observeAll(): Flow<List<DownloadEntity>> = dao.observeAll()

    suspend fun getById(id: String): DownloadEntity? = dao.getById(id)

    suspend fun enqueue(
        sourceUrl: String,
        platform: String,
        title: String,
        uploader: String,
        thumbnailUrl: String?,
        durationSeconds: Long,
        qualityId: String,
        qualityLabel: String,
    ): String {
        val id = UUID.randomUUID().toString()
        val now = System.currentTimeMillis()
        val nextPosition = (dao.maxQueuePosition() ?: 0L) + 1
        dao.insert(
            DownloadEntity(
                id = id,
                sourceUrl = sourceUrl,
                platform = platform,
                title = title,
                uploader = uploader,
                thumbnailUrl = thumbnailUrl,
                durationSeconds = durationSeconds,
                qualityId = qualityId,
                qualityLabel = qualityLabel,
                status = DownloadStatus.QUEUED.name,
                progressPercent = 0f,
                etaSeconds = null,
                storageKind = null,
                filePath = null,
                contentUri = null,
                fileName = null,
                fileSizeBytes = null,
                errorMessage = null,
                failureKind = null,
                queuePosition = nextPosition,
                createdAt = now,
                updatedAt = now,
                completedAt = null,
                retryCount = 0,
                fileMissing = false,
            )
        )
        return id
    }

    suspend fun update(entity: DownloadEntity) = dao.update(entity.copy(updatedAt = System.currentTimeMillis()))

    suspend fun updateProgress(id: String, status: DownloadStatus, progress: Float, etaSeconds: Long? = null) =
        dao.updateProgress(id, status.name, progress, etaSeconds, System.currentTimeMillis())

    suspend fun markCompleted(
        id: String,
        storageKind: String,
        filePath: String?,
        contentUri: String?,
        fileName: String,
        fileSizeBytes: Long,
    ) {
        val now = System.currentTimeMillis()
        dao.markCompleted(
            id = id,
            status = DownloadStatus.COMPLETED.name,
            storageKind = storageKind,
            filePath = filePath,
            contentUri = contentUri,
            fileName = fileName,
            fileSizeBytes = fileSizeBytes,
            completedAt = now,
            updatedAt = now,
        )
    }

    suspend fun markFailed(id: String, userMessage: String, failureKind: String) =
        dao.markFailed(id, DownloadStatus.FAILED.name, userMessage, failureKind, System.currentTimeMillis())

    suspend fun markCancelled(id: String) =
        dao.updateProgress(id, DownloadStatus.CANCELLED.name, 0f, null, System.currentTimeMillis())

    suspend fun markPaused(id: String, progress: Float) =
        dao.updateProgress(id, DownloadStatus.PAUSED.name, progress, null, System.currentTimeMillis())

    /** Resets a finished job back into the queue — used for both "Retry"
     * (failed/cancelled) and "Redownload" (completed) from the history screen. */
    suspend fun requeue(id: String): DownloadEntity? {
        val existing = dao.getById(id) ?: return null
        val nextPosition = (dao.maxQueuePosition() ?: 0L) + 1
        val updated = existing.copy(
            status = DownloadStatus.QUEUED.name,
            progressPercent = 0f,
            errorMessage = null,
            failureKind = null,
            queuePosition = nextPosition,
            updatedAt = System.currentTimeMillis(),
            retryCount = existing.retryCount + 1,
        )
        dao.update(updated)
        return updated
    }

    suspend fun delete(id: String) = dao.deleteById(id)

    suspend fun clearHistory() = dao.clearHistory()

    suspend fun countRunning(): Int = dao.countRunning()

    suspend fun getQueuedOnce(): List<DownloadEntity> = dao.getQueuedOnce()

    /** Resets any row left in PREPARING/DOWNLOADING/PROCESSING back to QUEUED.
     * Only meaningful right after the service (re)starts, when the caller's
     * running-jobs map is guaranteed empty — such a row can only be orphaned
     * leftover state from a process that was killed mid-download, not a job
     * actually in flight (Phase 7/13: no status should be able to get stuck
     * forever). The temp file, if any survived, is left in place so the next
     * attempt can resume via yt-dlp's own byte-range support. */
    suspend fun reconcileInterruptedJobs() {
        val stuck = dao.getByStatusesOnce(
            listOf(DownloadStatus.PREPARING.name, DownloadStatus.DOWNLOADING.name, DownloadStatus.PROCESSING.name)
        )
        val now = System.currentTimeMillis()
        for (entity in stuck) {
            dao.update(entity.copy(status = DownloadStatus.QUEUED.name, updatedAt = now))
        }
    }

    suspend fun markFileMissing(id: String, missing: Boolean) = dao.updateFileMissing(id, missing)

    suspend fun renameFile(id: String, newFileName: String) = dao.updateFileName(id, newFileName)

    /** Moves a queued item up or down relative to its neighbor by swapping
     * their sort positions (Phase 10: "reorder where practical"). */
    suspend fun swapQueuePosition(a: DownloadEntity, b: DownloadEntity) {
        dao.update(a.copy(queuePosition = b.queuePosition, updatedAt = System.currentTimeMillis()))
        dao.update(b.copy(queuePosition = a.queuePosition, updatedAt = System.currentTimeMillis()))
    }
}

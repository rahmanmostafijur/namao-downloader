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
                filePath = null,
                fileTreeUri = null,
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

    suspend fun updateProgress(id: String, status: DownloadStatus, progress: Float) =
        dao.updateProgress(id, status.name, progress, System.currentTimeMillis())

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

    suspend fun markFileMissing(id: String, missing: Boolean) = dao.updateFileMissing(id, missing)

    suspend fun renameFile(id: String, newFileName: String) = dao.updateFileName(id, newFileName)

    /** Moves a queued item up or down relative to its neighbor by swapping
     * their sort positions (Phase 10: "reorder where practical"). */
    suspend fun swapQueuePosition(a: DownloadEntity, b: DownloadEntity) {
        dao.update(a.copy(queuePosition = b.queuePosition, updatedAt = System.currentTimeMillis()))
        dao.update(b.copy(queuePosition = a.queuePosition, updatedAt = System.currentTimeMillis()))
    }
}

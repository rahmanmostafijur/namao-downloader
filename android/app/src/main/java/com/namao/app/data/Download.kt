package com.namao.app.data

import androidx.room.Dao
import androidx.room.Database
import androidx.room.Entity
import androidx.room.Insert
import androidx.room.PrimaryKey
import androidx.room.Query
import androidx.room.RoomDatabase
import androidx.room.Update
import kotlinx.coroutines.flow.Flow

/** Lifecycle states for one download job (Phase 10). PAUSED keeps the partial
 * temp file on disk so a later Resume can continue via yt-dlp's own
 * byte-range `--continue` behavior instead of starting over. */
enum class DownloadStatus {
    QUEUED, PREPARING, DOWNLOADING, PROCESSING, PAUSED, COMPLETED, FAILED, CANCELLED
}

val ACTIVE_STATUSES = listOf(
    DownloadStatus.QUEUED.name,
    DownloadStatus.PREPARING.name,
    DownloadStatus.DOWNLOADING.name,
    DownloadStatus.PROCESSING.name,
    DownloadStatus.PAUSED.name,
)

val TERMINAL_STATUSES = listOf(
    DownloadStatus.COMPLETED.name,
    DownloadStatus.FAILED.name,
    DownloadStatus.CANCELLED.name,
)

/**
 * One row per download job — doubles as both the live queue and the
 * persistent history, distinguished by [status]. Surviving Activity
 * recreation and process death (Phase 2/10/21) is the entire point of this
 * table existing instead of living only in view-model state.
 */
@Entity(tableName = "downloads")
data class DownloadEntity(
    @PrimaryKey val id: String,
    val sourceUrl: String,
    val platform: String,
    val title: String,
    val uploader: String,
    val thumbnailUrl: String?,
    val durationSeconds: Long,
    val qualityId: String,
    val qualityLabel: String,
    val status: String,
    val progressPercent: Float,
    // Real ETA (seconds) as reported by yt-dlp's own progress callback, or
    // null when unknown — never a fabricated/estimated value (Phase 20:
    // "Do not show fake speed or fake ETA").
    val etaSeconds: Long?,
    // How/where the finished file is stored, so it can be opened, shared,
    // renamed, or deleted correctly later:
    //  - "SAF_TREE": contentUri is a tree Uri (user-chosen folder); look the
    //    file up inside it by fileName via DocumentFile.
    //  - "MEDIA_STORE": contentUri is a single MediaStore item Uri, directly
    //    usable for view/share/delete.
    //  - "PLAIN_FILE": filePath is an absolute path (API<=28 public storage,
    //    or an app-specific fallback); needs a FileProvider Uri to share/view.
    val storageKind: String?,
    val filePath: String?,
    val contentUri: String?,
    val fileName: String?,
    val fileSizeBytes: Long?,
    val errorMessage: String?,
    val failureKind: String?,
    val queuePosition: Long,
    val createdAt: Long,
    val updatedAt: Long,
    val completedAt: Long?,
    val retryCount: Int,
    val fileMissing: Boolean,
)

val DownloadEntity.statusEnum: DownloadStatus get() = DownloadStatus.valueOf(status)

@Dao
interface DownloadDao {

    @Insert
    suspend fun insert(entity: DownloadEntity)

    @Update
    suspend fun update(entity: DownloadEntity)

    @Query("SELECT * FROM downloads WHERE id = :id")
    suspend fun getById(id: String): DownloadEntity?

    @Query("SELECT * FROM downloads ORDER BY createdAt DESC")
    fun observeAll(): Flow<List<DownloadEntity>>

    @Query("SELECT * FROM downloads WHERE status IN (:statuses) ORDER BY queuePosition ASC")
    fun observeByStatuses(statuses: List<String>): Flow<List<DownloadEntity>>

    @Query("SELECT * FROM downloads WHERE status = 'QUEUED' ORDER BY queuePosition ASC")
    suspend fun getQueuedOnce(): List<DownloadEntity>

    @Query("SELECT * FROM downloads WHERE status IN (:statuses)")
    suspend fun getByStatusesOnce(statuses: List<String>): List<DownloadEntity>

    @Query("SELECT COUNT(*) FROM downloads WHERE status IN ('PREPARING', 'DOWNLOADING', 'PROCESSING')")
    suspend fun countRunning(): Int

    @Query("DELETE FROM downloads WHERE id = :id")
    suspend fun deleteById(id: String)

    @Query("DELETE FROM downloads WHERE status IN ('COMPLETED', 'FAILED', 'CANCELLED')")
    suspend fun clearHistory()

    @Query(
        "UPDATE downloads SET status = :status, progressPercent = :progress, etaSeconds = :etaSeconds, updatedAt = :updatedAt WHERE id = :id"
    )
    suspend fun updateProgress(id: String, status: String, progress: Float, etaSeconds: Long?, updatedAt: Long)

    @Query("UPDATE downloads SET fileMissing = :missing WHERE id = :id")
    suspend fun updateFileMissing(id: String, missing: Boolean)

    @Query("UPDATE downloads SET fileName = :fileName WHERE id = :id")
    suspend fun updateFileName(id: String, fileName: String)

    @Query(
        """UPDATE downloads SET status = :status, storageKind = :storageKind, filePath = :filePath,
           contentUri = :contentUri, fileName = :fileName, fileSizeBytes = :fileSizeBytes,
           completedAt = :completedAt, updatedAt = :updatedAt, progressPercent = 100
           WHERE id = :id"""
    )
    suspend fun markCompleted(
        id: String,
        status: String,
        storageKind: String,
        filePath: String?,
        contentUri: String?,
        fileName: String,
        fileSizeBytes: Long,
        completedAt: Long,
        updatedAt: Long,
    )

    @Query(
        "UPDATE downloads SET status = :status, errorMessage = :errorMessage, failureKind = :failureKind, updatedAt = :updatedAt WHERE id = :id"
    )
    suspend fun markFailed(id: String, status: String, errorMessage: String, failureKind: String, updatedAt: Long)

    @Query("SELECT MAX(queuePosition) FROM downloads")
    suspend fun maxQueuePosition(): Long?
}

object StorageKind {
    const val SAF_TREE = "SAF_TREE"
    const val MEDIA_STORE = "MEDIA_STORE"
    const val PLAIN_FILE = "PLAIN_FILE"
}

@Database(entities = [DownloadEntity::class], version = 1, exportSchema = false)
abstract class NamaoDatabase : RoomDatabase() {
    abstract fun downloadDao(): DownloadDao
}

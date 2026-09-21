package com.namao.app.storage

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.webkit.MimeTypeMap
import androidx.annotation.RequiresApi
import androidx.core.content.FileProvider
import androidx.documentfile.provider.DocumentFile
import com.namao.app.data.DownloadEntity
import com.namao.app.data.StorageKind
import com.namao.app.engine.FilenameSanitizer
import java.io.File
import java.io.IOException

data class FinalizedFile(
    val storageKind: String,
    val filePath: String?,
    val contentUri: String?,
    val fileName: String,
    val sizeBytes: Long,
)

/**
 * All final-destination file I/O in one place: writes into a user-chosen SAF
 * folder when set, otherwise the public Downloads/Namao folder via MediaStore
 * (API 29+) or a direct File (API<=28) — never depending on the unrestricted
 * external-storage behavior scoped storage removed (Phase 12).
 */
class FileStore(private val context: Context) {

    private val prefs by lazy { context.getSharedPreferences("namao", Context.MODE_PRIVATE) }

    fun savedTreeUri(): Uri? = prefs.getString(DOWNLOAD_FOLDER_KEY, null)?.let { Uri.parse(it) }

    fun saveTreeUri(uri: Uri) {
        context.contentResolver.takePersistableUriPermission(
            uri,
            android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION or android.content.Intent.FLAG_GRANT_WRITE_URI_PERMISSION
        )
        prefs.edit().putString(DOWNLOAD_FOLDER_KEY, uri.toString()).apply()
    }

    fun clearTreeUri() {
        prefs.edit().remove(DOWNLOAD_FOLDER_KEY).apply()
    }

    fun folderDisplayName(): String {
        val uri = savedTreeUri() ?: return "Downloads/Namao (default)"
        val doc = DocumentFile.fromTreeUri(context, uri)
        return doc?.name?.let { "…/$it" } ?: "Downloads/Namao (default)"
    }

    /** Copies [tempFile] into its final home under a name derived from
     * [rawTitle], guaranteed not to collide with (or silently overwrite) an
     * existing file (Phase 12/13). */
    fun finalize(tempFile: File, rawTitle: String): FinalizedFile {
        val ext = tempFile.extension
        val base = FilenameSanitizer.sanitizeBaseName(rawTitle)
        val desiredName = if (ext.isNotEmpty()) "$base.$ext" else base
        val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext) ?: "application/octet-stream"

        val treeUri = savedTreeUri()
        if (treeUri != null) {
            val treeDoc = DocumentFile.fromTreeUri(context, treeUri)
            if (treeDoc != null && treeDoc.canWrite()) {
                val uniqueName = FilenameSanitizer.uniqueNameInTree(treeDoc, desiredName)
                val newFile = treeDoc.createFile(mime, uniqueName)
                    ?: throw IOException("Could not create a file in the chosen folder.")
                val out = context.contentResolver.openOutputStream(newFile.uri)
                    ?: throw IOException("Could not open the chosen folder for writing.")
                out.use { stream -> tempFile.inputStream().use { it.copyTo(stream) } }
                return FinalizedFile(
                    storageKind = StorageKind.SAF_TREE,
                    filePath = null,
                    contentUri = treeUri.toString(),
                    fileName = newFile.name ?: uniqueName,
                    sizeBytes = tempFile.length(),
                )
            }
            // Chosen folder became unwritable (e.g. removed SD card) — fall
            // through to the default location instead of failing the download.
        }

        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            finalizeViaMediaStore(tempFile, desiredName, mime)
        } else {
            finalizeViaPlainFile(tempFile, desiredName)
        }
    }

    @RequiresApi(Build.VERSION_CODES.Q)
    private fun finalizeViaMediaStore(tempFile: File, desiredName: String, mime: String): FinalizedFile {
        val resolver = context.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, desiredName)
            put(MediaStore.Downloads.MIME_TYPE, mime)
            put(MediaStore.Downloads.RELATIVE_PATH, "${Environment.DIRECTORY_DOWNLOADS}/Namao")
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
            ?: throw IOException("Could not create the download in the system Downloads folder.")
        val out = resolver.openOutputStream(uri) ?: throw IOException("Could not write the downloaded file.")
        out.use { stream -> tempFile.inputStream().use { it.copyTo(stream) } }
        resolver.update(uri, ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) }, null, null)
        val finalName = queryDisplayName(uri) ?: desiredName
        return FinalizedFile(StorageKind.MEDIA_STORE, null, uri.toString(), finalName, tempFile.length())
    }

    private fun finalizeViaPlainFile(tempFile: File, desiredName: String): FinalizedFile {
        val downloadsDir = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), "Namao")
        downloadsDir.mkdirs()
        val uniqueName = FilenameSanitizer.uniqueNameIn(downloadsDir, desiredName)
        val destFile = File(downloadsDir, uniqueName)
        tempFile.copyTo(destFile, overwrite = false)
        return FinalizedFile(StorageKind.PLAIN_FILE, destFile.absolutePath, null, uniqueName, destFile.length())
    }

    fun viewUri(entity: DownloadEntity): Uri? = when (entity.storageKind) {
        StorageKind.SAF_TREE -> entity.contentUri?.let { treeUriStr ->
            DocumentFile.fromTreeUri(context, Uri.parse(treeUriStr))
                ?.findFile(entity.fileName ?: return null)?.uri
        }
        StorageKind.MEDIA_STORE -> entity.contentUri?.let { Uri.parse(it) }
        StorageKind.PLAIN_FILE -> entity.filePath?.let { path ->
            val file = File(path)
            if (!file.exists()) null
            else FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
        }
        else -> null
    }

    fun exists(entity: DownloadEntity): Boolean = when (entity.storageKind) {
        StorageKind.SAF_TREE -> entity.contentUri?.let { treeUriStr ->
            DocumentFile.fromTreeUri(context, Uri.parse(treeUriStr))
                ?.findFile(entity.fileName ?: return false)?.exists() == true
        } ?: false
        StorageKind.MEDIA_STORE -> entity.contentUri?.let { uriExists(Uri.parse(it)) } ?: false
        StorageKind.PLAIN_FILE -> entity.filePath?.let { File(it).exists() } ?: false
        else -> false
    }

    fun delete(entity: DownloadEntity): Boolean = when (entity.storageKind) {
        StorageKind.SAF_TREE -> entity.contentUri?.let { treeUriStr ->
            DocumentFile.fromTreeUri(context, Uri.parse(treeUriStr))
                ?.findFile(entity.fileName ?: return false)?.delete() == true
        } ?: false
        StorageKind.MEDIA_STORE -> entity.contentUri?.let {
            context.contentResolver.delete(Uri.parse(it), null, null) > 0
        } ?: false
        StorageKind.PLAIN_FILE -> entity.filePath?.let { File(it).delete() } ?: false
        else -> false
    }

    /** Renames the underlying file and returns the name it actually ended up
     * with (a rename can itself collide, so this re-runs collision avoidance). */
    fun rename(entity: DownloadEntity, desiredBaseName: String): String? {
        val ext = entity.fileName?.substringAfterLast('.', "") ?: ""
        val safeBase = FilenameSanitizer.sanitizeBaseName(desiredBaseName)
        val desiredName = if (ext.isNotEmpty()) "$safeBase.$ext" else safeBase
        return when (entity.storageKind) {
            StorageKind.SAF_TREE -> entity.contentUri?.let { treeUriStr ->
                val treeDoc = DocumentFile.fromTreeUri(context, Uri.parse(treeUriStr)) ?: return null
                val doc = treeDoc.findFile(entity.fileName ?: return null) ?: return null
                val uniqueName = FilenameSanitizer.uniqueNameInTree(treeDoc, desiredName)
                if (doc.renameTo(uniqueName)) uniqueName else null
            }
            StorageKind.MEDIA_STORE -> entity.contentUri?.let {
                val values = ContentValues().apply { put(MediaStore.Downloads.DISPLAY_NAME, desiredName) }
                if (context.contentResolver.update(Uri.parse(it), values, null, null) > 0) {
                    queryDisplayName(Uri.parse(it)) ?: desiredName
                } else null
            }
            StorageKind.PLAIN_FILE -> entity.filePath?.let { path ->
                val file = File(path)
                val uniqueName = FilenameSanitizer.uniqueNameIn(file.parentFile ?: return null, desiredName)
                val target = File(file.parentFile, uniqueName)
                if (file.renameTo(target)) uniqueName else null
            }
            else -> null
        }
    }

    private fun uriExists(uri: Uri): Boolean = try {
        context.contentResolver.query(uri, null, null, null, null)?.use { it.moveToFirst() } ?: false
    } catch (e: SecurityException) {
        false
    }

    private fun queryDisplayName(uri: Uri): String? = try {
        context.contentResolver.query(uri, arrayOf(MediaStore.Downloads.DISPLAY_NAME), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) cursor.getString(0) else null
        }
    } catch (e: SecurityException) {
        null
    }

    companion object {
        private const val DOWNLOAD_FOLDER_KEY = "download_folder_uri"
    }
}

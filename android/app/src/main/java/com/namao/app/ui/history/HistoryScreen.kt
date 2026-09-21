package com.namao.app.ui.history

import android.app.Application
import android.content.Intent
import android.webkit.MimeTypeMap
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.OpenInNew
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Share
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Card
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import coil.compose.AsyncImage
import com.namao.app.NamaoApplication
import com.namao.app.data.DownloadEntity
import com.namao.app.data.DownloadStatus
import com.namao.app.data.statusEnum
import com.namao.app.engine.FileSize
import com.namao.app.service.DownloadService
import com.namao.app.storage.FileStore
import com.namao.app.ui.theme.platformAccent
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter

class HistoryViewModel(application: Application) : AndroidViewModel(application) {

    private val app get() = getApplication<NamaoApplication>()
    private val repository = app.downloadRepository
    private val fileStore = FileStore(app)

    val history: StateFlow<List<DownloadEntity>> = repository.observeHistory()
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    fun refreshMissingFlags(list: List<DownloadEntity>) {
        viewModelScope.launch(Dispatchers.IO) {
            list.filter { it.statusEnum == DownloadStatus.COMPLETED }.forEach { entity ->
                val exists = fileStore.exists(entity)
                if (exists == entity.fileMissing) repository.markFileMissing(entity.id, !exists)
            }
        }
    }

    fun openIntent(entity: DownloadEntity): Intent? {
        val uri = fileStore.viewUri(entity) ?: return null
        val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(entity.fileName?.substringAfterLast('.', ""))
        return Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, mime ?: "video/*")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        }
    }

    fun shareIntent(entity: DownloadEntity): Intent? {
        val uri = fileStore.viewUri(entity) ?: return null
        val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(entity.fileName?.substringAfterLast('.', ""))
        return Intent(Intent.ACTION_SEND).apply {
            type = mime ?: "video/*"
            putExtra(Intent.EXTRA_STREAM, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        }
    }

    fun delete(entity: DownloadEntity) {
        viewModelScope.launch(Dispatchers.IO) {
            fileStore.delete(entity)
            repository.delete(entity.id)
        }
    }

    fun rename(entity: DownloadEntity, newBaseName: String) {
        viewModelScope.launch(Dispatchers.IO) {
            fileStore.rename(entity, newBaseName)?.let { repository.renameFile(entity.id, it) }
        }
    }

    fun retryOrRedownload(entity: DownloadEntity) {
        viewModelScope.launch {
            repository.requeue(entity.id)
            ContextCompat.startForegroundService(app, Intent(app, DownloadService::class.java))
        }
    }

    fun clearHistory() {
        viewModelScope.launch { repository.clearHistory() }
    }
}

@Composable
fun HistoryScreen() {
    val context = LocalContext.current
    val viewModel: HistoryViewModel = viewModel(
        factory = ViewModelProvider.AndroidViewModelFactory.getInstance(context.applicationContext as Application),
    )
    val history by viewModel.history.collectAsState()
    val clipboard = LocalClipboardManager.current
    var renameTarget by remember { mutableStateOf<DownloadEntity?>(null) }
    var deleteTarget by remember { mutableStateOf<DownloadEntity?>(null) }
    var showClearConfirm by remember { mutableStateOf(false) }

    LaunchedEffect(history) { viewModel.refreshMissingFlags(history) }

    Column(Modifier.fillMaxSize()) {
        Row(
            Modifier
                .fillMaxWidth()
                .padding(16.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            Text("History", style = MaterialTheme.typography.titleLarge)
            if (history.isNotEmpty()) {
                TextButton(onClick = { showClearConfirm = true }) { Text("Clear") }
            }
        }

        if (history.isEmpty()) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text("No downloads yet", style = MaterialTheme.typography.bodyMedium)
            }
        } else {
            LazyColumn(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(horizontal = 16.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                items(history, key = { it.id }) { entity ->
                    HistoryItemCard(
                        entity = entity,
                        onOpen = {
                            viewModel.openIntent(entity)?.let { context.startActivity(it) }
                        },
                        onShare = {
                            viewModel.shareIntent(entity)?.let { context.startActivity(Intent.createChooser(it, null)) }
                        },
                        onRename = { renameTarget = entity },
                        onDelete = { deleteTarget = entity },
                        onRetryOrRedownload = { viewModel.retryOrRedownload(entity) },
                        onCopyUrl = { clipboard.setText(AnnotatedString(entity.sourceUrl)) },
                    )
                }
            }
        }
    }

    renameTarget?.let { entity ->
        RenameDialog(
            currentName = entity.fileName ?: entity.title,
            onConfirm = { newName -> viewModel.rename(entity, newName); renameTarget = null },
            onDismiss = { renameTarget = null },
        )
    }

    deleteTarget?.let { entity ->
        AlertDialog(
            onDismissRequest = { deleteTarget = null },
            title = { Text("Delete download?") },
            text = { Text("\"${entity.title}\" and its file will be permanently deleted.") },
            confirmButton = {
                TextButton(onClick = { viewModel.delete(entity); deleteTarget = null }) { Text("Delete") }
            },
            dismissButton = { TextButton(onClick = { deleteTarget = null }) { Text("Cancel") } },
        )
    }

    if (showClearConfirm) {
        AlertDialog(
            onDismissRequest = { showClearConfirm = false },
            title = { Text("Clear history?") },
            text = { Text("This removes history entries but does not delete downloaded files.") },
            confirmButton = {
                TextButton(onClick = { viewModel.clearHistory(); showClearConfirm = false }) { Text("Clear") }
            },
            dismissButton = { TextButton(onClick = { showClearConfirm = false }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun RenameDialog(currentName: String, onConfirm: (String) -> Unit, onDismiss: () -> Unit) {
    var text by remember { mutableStateOf(currentName.substringBeforeLast('.')) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Rename") },
        text = { OutlinedTextField(value = text, onValueChange = { text = it }, singleLine = true) },
        confirmButton = { TextButton(onClick = { onConfirm(text) }) { Text("Rename") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

@Composable
private fun HistoryItemCard(
    entity: DownloadEntity,
    onOpen: () -> Unit,
    onShare: () -> Unit,
    onRename: () -> Unit,
    onDelete: () -> Unit,
    onRetryOrRedownload: () -> Unit,
    onCopyUrl: () -> Unit,
) {
    val isCompleted = entity.statusEnum == DownloadStatus.COMPLETED && !entity.fileMissing
    Card {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                if (entity.thumbnailUrl != null) {
                    AsyncImage(
                        model = entity.thumbnailUrl,
                        contentDescription = null,
                        modifier = Modifier
                            .size(72.dp)
                            .aspectRatio(1f)
                            .clip(RoundedCornerShape(8.dp)),
                    )
                }
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(entity.title, fontWeight = FontWeight.SemiBold, maxLines = 2)
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text(
                            entity.platform.replaceFirstChar { it.uppercase() },
                            color = platformAccent(entity.platform),
                            style = MaterialTheme.typography.bodyMedium,
                        )
                        Text(formatDate(entity.createdAt), style = MaterialTheme.typography.bodyMedium)
                    }
                    Text(detailLine(entity), style = MaterialTheme.typography.bodyMedium)
                    Text(statusText(entity), style = MaterialTheme.typography.bodyMedium)
                }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                if (isCompleted) {
                    IconButton(onClick = onOpen) { Icon(Icons.AutoMirrored.Filled.OpenInNew, "Open") }
                    IconButton(onClick = onShare) { Icon(Icons.Default.Share, "Share") }
                    IconButton(onClick = onRename) { Icon(Icons.Default.Edit, "Rename") }
                } else {
                    IconButton(onClick = onRetryOrRedownload) { Icon(Icons.Default.Refresh, "Retry") }
                }
                IconButton(onClick = onCopyUrl) { Icon(Icons.Default.ContentCopy, "Copy source URL") }
                IconButton(onClick = onDelete) { Icon(Icons.Default.Delete, "Delete") }
            }
        }
    }
}

private fun detailLine(entity: DownloadEntity): String {
    val ext = entity.fileName?.substringAfterLast('.', "")?.uppercase()?.takeIf { it.isNotBlank() }
    val size = FileSize.format(entity.fileSizeBytes)
    return listOfNotNull(entity.qualityLabel, ext, size).joinToString(" · ")
}

private fun statusText(entity: DownloadEntity): String = when {
    entity.statusEnum == DownloadStatus.COMPLETED && entity.fileMissing -> "File missing (deleted outside the app)"
    entity.statusEnum == DownloadStatus.COMPLETED -> "Completed"
    entity.statusEnum == DownloadStatus.FAILED -> entity.errorMessage ?: "Failed"
    entity.statusEnum == DownloadStatus.CANCELLED -> "Cancelled"
    else -> entity.status
}

private fun formatDate(epochMillis: Long): String =
    Instant.ofEpochMilli(epochMillis).atZone(ZoneId.systemDefault())
        .format(DateTimeFormatter.ofPattern("MMM d, yyyy"))

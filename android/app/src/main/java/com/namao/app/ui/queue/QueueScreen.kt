package com.namao.app.ui.queue

import android.app.Application
import android.content.Intent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDownward
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.Card
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import com.namao.app.NamaoApplication
import com.namao.app.data.DownloadEntity
import com.namao.app.data.DownloadStatus
import com.namao.app.data.statusEnum
import com.namao.app.service.DownloadService
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

class QueueViewModel(application: Application) : AndroidViewModel(application) {

    private val app get() = getApplication<NamaoApplication>()
    private val repository = app.downloadRepository

    val activeJobs: StateFlow<List<DownloadEntity>> = repository.observeActive()
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    private fun sendAction(action: String, id: String) {
        app.startService(Intent(app, DownloadService::class.java).setAction(action).putExtra(DownloadService.EXTRA_JOB_ID, id))
    }

    fun cancel(id: String) = sendAction(DownloadService.ACTION_CANCEL_JOB, id)
    fun pause(id: String) = sendAction(DownloadService.ACTION_PAUSE_JOB, id)
    fun resume(id: String) = sendAction(DownloadService.ACTION_RESUME_JOB, id)

    fun moveInQueue(entity: DownloadEntity, direction: Int) {
        val queuedOnly = activeJobs.value.filter { it.statusEnum == DownloadStatus.QUEUED }
        val index = queuedOnly.indexOfFirst { it.id == entity.id }
        val targetIndex = index + direction
        if (index == -1 || targetIndex !in queuedOnly.indices) return
        viewModelScope.launch { repository.swapQueuePosition(queuedOnly[index], queuedOnly[targetIndex]) }
    }
}

@Composable
fun QueueScreen() {
    val context = androidx.compose.ui.platform.LocalContext.current
    val viewModel: QueueViewModel = viewModel(
        factory = ViewModelProvider.AndroidViewModelFactory.getInstance(context.applicationContext as Application),
    )
    val jobs by viewModel.activeJobs.collectAsState()

    if (jobs.isEmpty()) {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Text("No downloads in progress", style = MaterialTheme.typography.bodyMedium)
        }
        return
    }

    LazyColumn(
        modifier = Modifier
            .fillMaxSize()
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        items(jobs, key = { it.id }) { job ->
            QueueItemCard(
                job = job,
                canMoveUp = job.statusEnum == DownloadStatus.QUEUED,
                canMoveDown = job.statusEnum == DownloadStatus.QUEUED,
                onCancel = { viewModel.cancel(job.id) },
                onPause = { viewModel.pause(job.id) },
                onResume = { viewModel.resume(job.id) },
                onMoveUp = { viewModel.moveInQueue(job, -1) },
                onMoveDown = { viewModel.moveInQueue(job, 1) },
            )
        }
    }
}

@Composable
private fun QueueItemCard(
    job: DownloadEntity,
    canMoveUp: Boolean,
    canMoveDown: Boolean,
    onCancel: () -> Unit,
    onPause: () -> Unit,
    onResume: () -> Unit,
    onMoveUp: () -> Unit,
    onMoveDown: () -> Unit,
) {
    Card {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(job.title, fontWeight = FontWeight.SemiBold, maxLines = 2)
            Text(statusLabel(job), style = MaterialTheme.typography.bodyMedium)

            val progressFraction = (job.progressPercent / 100f).coerceIn(0f, 1f)
            if (job.statusEnum == DownloadStatus.PREPARING) {
                LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
            } else if (job.statusEnum == DownloadStatus.DOWNLOADING || job.statusEnum == DownloadStatus.PROCESSING) {
                LinearProgressIndicator(progress = { progressFraction }, modifier = Modifier.fillMaxWidth())
            }

            Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                when (job.statusEnum) {
                    DownloadStatus.QUEUED -> {
                        IconButton(onClick = onMoveUp, enabled = canMoveUp) { Icon(Icons.Default.ArrowUpward, "Move up") }
                        IconButton(onClick = onMoveDown, enabled = canMoveDown) { Icon(Icons.Default.ArrowDownward, "Move down") }
                        IconButton(onClick = onCancel) { Icon(Icons.Default.Close, "Cancel") }
                    }
                    DownloadStatus.DOWNLOADING -> {
                        IconButton(onClick = onPause) { Icon(Icons.Default.Pause, "Pause") }
                        IconButton(onClick = onCancel) { Icon(Icons.Default.Close, "Cancel") }
                    }
                    DownloadStatus.PAUSED -> {
                        IconButton(onClick = onResume) { Icon(Icons.Default.PlayArrow, "Resume") }
                        IconButton(onClick = onCancel) { Icon(Icons.Default.Close, "Cancel") }
                    }
                    else -> {
                        IconButton(onClick = onCancel) { Icon(Icons.Default.Close, "Cancel") }
                    }
                }
            }
        }
    }
}

private fun statusLabel(job: DownloadEntity): String = when (job.statusEnum) {
    DownloadStatus.QUEUED -> "Queued"
    DownloadStatus.PREPARING -> "Preparing…"
    DownloadStatus.DOWNLOADING -> {
        val eta = job.etaSeconds?.takeIf { it > 0 }?.let { " — ${formatEta(it)} left" } ?: ""
        "Downloading — ${job.progressPercent.toInt()}%$eta"
    }
    DownloadStatus.PROCESSING -> "Processing…"
    DownloadStatus.PAUSED -> "Paused at ${job.progressPercent.toInt()}%"
    else -> job.status
}

/** Formats a real ETA (seconds) reported by yt-dlp — never a locally
 * fabricated estimate (Phase 20). */
private fun formatEta(totalSeconds: Long): String {
    val m = totalSeconds / 60
    val s = totalSeconds % 60
    return if (m > 0) "${m}m ${s}s" else "${s}s"
}

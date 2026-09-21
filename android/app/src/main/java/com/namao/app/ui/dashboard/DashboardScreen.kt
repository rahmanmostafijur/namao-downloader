package com.namao.app.ui.dashboard

import android.app.Application
import android.os.Environment
import android.os.StatFs
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
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
import com.namao.app.ui.theme.platformAccent
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import java.io.File

data class DownloadStats(
    val total: Int = 0,
    val completed: Int = 0,
    val failed: Int = 0,
    val active: Int = 0,
    val totalDownloadedBytes: Long = 0L,
    val recent: List<DownloadEntity> = emptyList(),
    val platformCounts: Map<String, Int> = emptyMap(),
)

data class StorageStats(
    val deviceAvailableBytes: Long = 0L,
    val deviceTotalBytes: Long = 0L,
    val appCacheBytes: Long = 0L,
)

/**
 * Every number here is computed from the local downloads table or a real
 * StatFs/cache-directory read — nothing here is a placeholder or invented
 * statistic (this app has no server, so there is no account to attach fake
 * profile data to either).
 */
class DashboardViewModel(application: Application) : AndroidViewModel(application) {

    private val app get() = getApplication<NamaoApplication>()
    private val repository = app.downloadRepository

    val stats: StateFlow<DownloadStats> = repository.observeAll()
        .map { list ->
            DownloadStats(
                total = list.size,
                completed = list.count { it.statusEnum == DownloadStatus.COMPLETED },
                failed = list.count { it.statusEnum == DownloadStatus.FAILED },
                active = list.count { it.status in com.namao.app.data.ACTIVE_STATUSES },
                totalDownloadedBytes = list.filter { it.statusEnum == DownloadStatus.COMPLETED }
                    .sumOf { it.fileSizeBytes ?: 0L },
                recent = list.sortedByDescending { it.createdAt }.take(5),
                platformCounts = list.groupingBy { it.platform }.eachCount(),
            )
        }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), DownloadStats())

    private val _storage = MutableStateFlow(StorageStats())
    val storage: StateFlow<StorageStats> = _storage.asStateFlow()

    fun refreshStorage() {
        viewModelScope.launch(Dispatchers.IO) {
            val statFs = StatFs(Environment.getExternalStorageDirectory().path)
            val available = statFs.availableBytes
            val total = statFs.totalBytes
            val cache = dirSize(app.cacheDir)
            _storage.value = StorageStats(available, total, cache)
        }
    }

    private fun dirSize(file: File): Long =
        if (file.isFile) file.length() else file.listFiles()?.sumOf { dirSize(it) } ?: 0L
}

@Composable
fun DashboardScreen(onNavigateToHistory: () -> Unit, onNavigateToSettings: () -> Unit) {
    val context = LocalContext.current
    val viewModel: DashboardViewModel = viewModel(
        factory = ViewModelProvider.AndroidViewModelFactory.getInstance(context.applicationContext as Application),
    )
    val stats by viewModel.stats.collectAsState()
    val storage by viewModel.storage.collectAsState()

    LaunchedEffect(Unit) { viewModel.refreshStorage() }

    LazyColumn(
        modifier = Modifier
            .fillMaxSize()
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        item { Text("Dashboard", style = MaterialTheme.typography.titleLarge) }

        item { OverviewGrid(stats) }

        item { StorageCard(storage) }

        if (stats.platformCounts.isNotEmpty()) {
            item { PlatformBreakdownCard(stats.platformCounts) }
        }

        item {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(onClick = onNavigateToHistory) { Text("View history") }
                OutlinedButton(onClick = onNavigateToSettings) { Text("Settings") }
            }
        }

        item { Text("Recent downloads", style = MaterialTheme.typography.titleMedium) }

        if (stats.recent.isEmpty()) {
            item { Text("No downloads yet. Paste a video link above to get started.", style = MaterialTheme.typography.bodyMedium) }
        } else {
            stats.recent.forEach { entity ->
                item { RecentDownloadRow(entity) }
            }
        }
    }
}

@Composable
private fun OverviewGrid(stats: DownloadStats) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            StatCard("Total", stats.total.toString(), Modifier.weight(1f))
            StatCard("Completed", stats.completed.toString(), Modifier.weight(1f))
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            StatCard("Active", stats.active.toString(), Modifier.weight(1f))
            StatCard("Failed", stats.failed.toString(), Modifier.weight(1f))
        }
        StatCard("Total downloaded", FileSize.format(stats.totalDownloadedBytes) ?: "0 B", Modifier.fillMaxWidth())
    }
}

@Composable
private fun StatCard(label: String, value: String, modifier: Modifier = Modifier) {
    Card(modifier = modifier) {
        Column(Modifier.padding(16.dp)) {
            Text(value, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
            Text(label, style = MaterialTheme.typography.bodyMedium)
        }
    }
}

@Composable
private fun StorageCard(storage: StorageStats) {
    Card {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("Storage", style = MaterialTheme.typography.titleMedium)
            val used = (storage.deviceTotalBytes - storage.deviceAvailableBytes).coerceAtLeast(0)
            val fraction = if (storage.deviceTotalBytes > 0) (used.toFloat() / storage.deviceTotalBytes).coerceIn(0f, 1f) else 0f
            LinearProgressIndicator(progress = { fraction }, modifier = Modifier.fillMaxWidth())
            Text(
                "${FileSize.format(storage.deviceAvailableBytes) ?: "0 B"} free of ${FileSize.format(storage.deviceTotalBytes) ?: "0 B"}",
                style = MaterialTheme.typography.bodyMedium,
            )
            Text("App cache: ${FileSize.format(storage.appCacheBytes) ?: "0 B"}", style = MaterialTheme.typography.bodyMedium)
        }
    }
}

@Composable
private fun PlatformBreakdownCard(counts: Map<String, Int>) {
    Card {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text("By platform", style = MaterialTheme.typography.titleMedium)
            counts.entries.sortedByDescending { it.value }.forEach { (platform, count) ->
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    Text(platform.replaceFirstChar { it.uppercase() }, color = platformAccent(platform))
                    Text(count.toString())
                }
            }
        }
    }
}

@Composable
private fun RecentDownloadRow(entity: DownloadEntity) {
    Card(colors = CardDefaults.cardColors()) {
        Row(Modifier.padding(12.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            if (entity.thumbnailUrl != null) {
                AsyncImage(
                    model = entity.thumbnailUrl,
                    contentDescription = null,
                    modifier = Modifier
                        .size(56.dp)
                        .aspectRatio(1f)
                        .clip(RoundedCornerShape(6.dp)),
                )
            }
            Column {
                Text(entity.title, maxLines = 1, style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.Medium)
                Text(
                    "${entity.platform.replaceFirstChar { it.uppercase() }} · ${entity.status.lowercase().replaceFirstChar { it.uppercase() }}",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.7f),
                )
            }
        }
    }
}

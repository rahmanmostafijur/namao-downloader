package com.namao.app.ui.settings

import android.app.Application
import android.net.Uri
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Remove
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Card
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import com.namao.app.NamaoApplication
import com.namao.app.engine.CookieStore
import com.namao.app.settings.AppSettings
import com.namao.app.settings.ThemeMode
import com.namao.app.storage.FileStore
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

private val QUALITY_PRESETS = listOf(
    "best" to "Best available",
    "1080" to "1080p",
    "720" to "720p",
    "480" to "480p",
    "360" to "360p",
    "audio" to "Audio only",
)

class SettingsViewModel(application: Application) : AndroidViewModel(application) {

    private val app get() = getApplication<NamaoApplication>()
    private val settingsRepository = app.settingsRepository
    private val fileStore = FileStore(app)

    val settings: StateFlow<AppSettings> = settingsRepository.settings
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), AppSettings())

    fun folderDisplayName(): String = fileStore.folderDisplayName()

    fun onFolderChosen(uri: Uri) {
        fileStore.saveTreeUri(uri)
    }

    fun resetFolder() {
        fileStore.clearTreeUri()
    }

    fun setTheme(mode: ThemeMode) = viewModelScope.launch { settingsRepository.setThemeMode(mode) }
    fun setWifiOnly(enabled: Boolean) = viewModelScope.launch { settingsRepository.setWifiOnly(enabled) }
    fun setMaxConcurrent(value: Int) = viewModelScope.launch { settingsRepository.setMaxConcurrentDownloads(value) }
    fun setDefaultQuality(id: String) = viewModelScope.launch { settingsRepository.setDefaultQualityId(id) }
    fun setNotifyOnComplete(enabled: Boolean) = viewModelScope.launch { settingsRepository.setNotifyOnComplete(enabled) }
    fun setAutoStart(enabled: Boolean) = viewModelScope.launch { settingsRepository.setAutoStartAfterAnalyze(enabled) }

    fun hasCookies(): Boolean = CookieStore.hasCookies(app)
    fun readCookies(): String = CookieStore.read(app)
    fun saveCookies(text: String) = CookieStore.save(app, text)

    fun clearHistory() = viewModelScope.launch { app.downloadRepository.clearHistory() }

    /** Clears generic app cache (e.g. thumbnail cache) but never an active or
     * paused download's temp folder ("dl_*"), so this can't corrupt an
     * in-flight download. */
    fun clearCache() {
        app.cacheDir.listFiles()?.forEach { file ->
            if (!file.name.startsWith("dl_")) file.deleteRecursively()
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(onPickDownloadFolder: ((Uri) -> Unit) -> Unit) {
    val context = LocalContext.current
    val viewModel: SettingsViewModel = viewModel(
        factory = ViewModelProvider.AndroidViewModelFactory.getInstance(context.applicationContext as Application),
    )
    val settings by viewModel.settings.collectAsState()
    var showCookieDialog by remember { mutableStateOf(false) }
    var showClearHistoryConfirm by remember { mutableStateOf(false) }
    var folderName by remember { mutableStateOf(viewModel.folderDisplayName()) }

    LazyColumn(
        modifier = Modifier
            .fillMaxSize()
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(20.dp),
    ) {
        item { Text("Settings", style = MaterialTheme.typography.titleLarge) }

        item {
            SettingsSection(title = "Appearance") {
                SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                    ThemeMode.entries.forEachIndexed { index, mode ->
                        SegmentedButton(
                            selected = settings.themeMode == mode,
                            onClick = { viewModel.setTheme(mode) },
                            shape = SegmentedButtonDefaults.itemShape(index, ThemeMode.entries.size),
                        ) { Text(mode.name.lowercase().replaceFirstChar { it.uppercase() }) }
                    }
                }
            }
        }

        item {
            SettingsSection(title = "Downloads") {
                SettingRow(label = "Wi-Fi only", description = "Pause downloads on mobile data") {
                    Switch(checked = settings.wifiOnly, onCheckedChange = viewModel::setWifiOnly)
                }
                SettingRow(label = "Simultaneous downloads", description = null) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        IconButton(onClick = { viewModel.setMaxConcurrent(settings.maxConcurrentDownloads - 1) }, enabled = settings.maxConcurrentDownloads > 1) {
                            Icon(Icons.Default.Remove, "Decrease")
                        }
                        Text("${settings.maxConcurrentDownloads}")
                        IconButton(onClick = { viewModel.setMaxConcurrent(settings.maxConcurrentDownloads + 1) }, enabled = settings.maxConcurrentDownloads < 3) {
                            Icon(Icons.Default.Add, "Increase")
                        }
                    }
                }
                SettingRow(label = "Auto-download after analyzing", description = "Skip the quality confirmation step") {
                    Switch(checked = settings.autoStartAfterAnalyze, onCheckedChange = viewModel::setAutoStart)
                }
                SettingRow(label = "Notify when complete", description = null) {
                    Switch(checked = settings.notifyOnComplete, onCheckedChange = viewModel::setNotifyOnComplete)
                }
            }
        }

        item {
            SettingsSection(title = "Default quality") {
                QUALITY_PRESETS.forEach { (id, label) ->
                    SettingRow(label = label, description = null, onClick = { viewModel.setDefaultQuality(id) }) {
                        RadioButton(selected = settings.defaultQualityId == id, onClick = { viewModel.setDefaultQuality(id) })
                    }
                }
            }
        }

        item {
            SettingsSection(title = "Storage") {
                SettingRow(
                    label = "Download folder",
                    description = folderName,
                    onClick = {
                        onPickDownloadFolder { uri ->
                            viewModel.onFolderChosen(uri)
                            folderName = viewModel.folderDisplayName()
                        }
                    },
                ) {}
                TextButton(onClick = { viewModel.resetFolder(); folderName = viewModel.folderDisplayName() }) {
                    Text("Use default folder")
                }
                TextButton(onClick = { viewModel.clearCache() }) { Text("Clear cache") }
            }
        }

        item {
            SettingsSection(title = "Account cookies") {
                Text(
                    "Some platforms (Instagram in particular) require a logged-in session even for public-looking posts.",
                    style = MaterialTheme.typography.bodyMedium,
                )
                TextButton(onClick = { showCookieDialog = true }) {
                    Text(if (viewModel.hasCookies()) "Manage cookies" else "Add cookies")
                }
            }
        }

        item {
            SettingsSection(title = "Data") {
                TextButton(onClick = { showClearHistoryConfirm = true }) { Text("Clear download history") }
            }
        }
    }

    if (showCookieDialog) {
        CookieDialog(
            initial = viewModel.readCookies(),
            onSave = { text -> viewModel.saveCookies(text); showCookieDialog = false },
            onDismiss = { showCookieDialog = false },
        )
    }

    if (showClearHistoryConfirm) {
        AlertDialog(
            onDismissRequest = { showClearHistoryConfirm = false },
            title = { Text("Clear download history?") },
            text = { Text("This removes history entries but does not delete downloaded files.") },
            confirmButton = {
                TextButton(onClick = { viewModel.clearHistory(); showClearHistoryConfirm = false }) { Text("Clear") }
            },
            dismissButton = { TextButton(onClick = { showClearHistoryConfirm = false }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun SettingsSection(title: String, content: @Composable () -> Unit) {
    Card {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(title, style = MaterialTheme.typography.titleMedium)
            HorizontalDivider()
            content()
        }
    }
}

@Composable
private fun SettingRow(label: String, description: String?, onClick: (() -> Unit)? = null, trailing: @Composable () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .let { base -> if (onClick != null) base.clickable(onClick = onClick) else base },
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(label, style = MaterialTheme.typography.bodyMedium)
            description?.let {
                Text(it, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.6f))
            }
        }
        trailing()
    }
}

@Composable
private fun CookieDialog(initial: String, onSave: (String) -> Unit, onDismiss: () -> Unit) {
    var text by remember { mutableStateOf(initial) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Cookies") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(
                    "Paste the contents of a Netscape-format cookies.txt export. Stored only on this device.",
                    style = MaterialTheme.typography.bodyMedium,
                )
                OutlinedTextField(
                    value = text,
                    onValueChange = { text = it },
                    modifier = Modifier.fillMaxWidth(),
                    minLines = 4,
                    maxLines = 8,
                )
            }
        },
        confirmButton = { TextButton(onClick = { onSave(text) }) { Text("Save") } },
        dismissButton = {
            Row {
                TextButton(onClick = { onSave("") }) { Text("Clear") }
                TextButton(onClick = onDismiss) { Text("Cancel") }
            }
        },
    )
}

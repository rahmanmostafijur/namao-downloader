package com.namao.app.ui.home

import android.app.Application
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Clear
import androidx.compose.material.icons.filled.ContentPaste
import androidx.compose.material.icons.filled.Dashboard
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import coil.compose.AsyncImage
import com.namao.app.engine.QualityOption
import com.namao.app.ui.theme.platformAccent

@Composable
fun HomeScreen(
    sharedUrl: String?,
    onSharedUrlConsumed: () -> Unit,
    onNavigateToQueue: () -> Unit,
    onNavigateToDashboard: () -> Unit,
) {
    val context = LocalContext.current
    val viewModel: HomeViewModel = viewModel(
        factory = androidx.lifecycle.ViewModelProvider.AndroidViewModelFactory.getInstance(
            context.applicationContext as Application,
        ),
    )
    val state by viewModel.state.collectAsState()
    val clipboard = LocalClipboardManager.current

    LaunchedEffect(sharedUrl) {
        if (!sharedUrl.isNullOrBlank()) {
            viewModel.onUrlChange(sharedUrl)
            viewModel.analyze(sharedUrl)
            onSharedUrlConsumed()
        }
    }
    LaunchedEffect(state.justEnqueued) {
        if (state.justEnqueued) {
            onNavigateToQueue()
            viewModel.consumeEnqueuedFlag()
        }
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column {
                Text("Paste a video link", style = MaterialTheme.typography.titleLarge)
                Text(
                    "YouTube, TikTok, Facebook, X/Twitter, or Instagram",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.7f),
                )
            }
            IconButton(onClick = onNavigateToDashboard) {
                Icon(Icons.Default.Dashboard, contentDescription = "Dashboard")
            }
        }

        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedTextField(
                value = state.url,
                onValueChange = viewModel::onUrlChange,
                modifier = Modifier.weight(1f),
                singleLine = true,
                placeholder = { Text("https://…") },
                trailingIcon = {
                    if (state.url.isNotBlank()) {
                        IconButton(onClick = { viewModel.onUrlChange("") }) {
                            Icon(Icons.Default.Clear, contentDescription = "Clear")
                        }
                    }
                },
            )
            IconButton(onClick = {
                clipboard.getText()?.text?.let { viewModel.onUrlChange(it) }
            }) {
                Icon(Icons.Default.ContentPaste, contentDescription = "Paste")
            }
        }

        Button(
            onClick = { viewModel.analyze() },
            enabled = state.url.isNotBlank() && !state.isAnalyzing,
            modifier = Modifier.fillMaxWidth(),
        ) {
            Text(if (state.isAnalyzing) "Reading video info…" else "Analyze")
        }

        if (state.isAnalyzing) {
            Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator()
            }
        }

        state.errorMessage?.let { message ->
            Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.errorContainer)) {
                Text(message, modifier = Modifier.padding(16.dp), color = MaterialTheme.colorScheme.onErrorContainer)
            }
        }

        state.mediaInfo?.let { info ->
            Card {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        if (info.thumbnailUrl != null) {
                            AsyncImage(
                                model = info.thumbnailUrl,
                                contentDescription = null,
                                modifier = Modifier
                                    .size(96.dp)
                                    .aspectRatio(1f)
                                    .clip(RoundedCornerShape(8.dp)),
                            )
                        }
                        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                            Text(info.title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, maxLines = 2)
                            if (info.uploader.isNotBlank()) {
                                Text(info.uploader, style = MaterialTheme.typography.bodyMedium)
                            }
                            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                PlatformChip(info.platform)
                                if (info.durationSeconds > 0) {
                                    Text(formatDuration(info.durationSeconds), style = MaterialTheme.typography.bodyMedium)
                                }
                            }
                        }
                    }

                    Text("Quality", style = MaterialTheme.typography.labelLarge)
                    LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        items(info.qualities) { quality ->
                            QualityChip(
                                quality = quality,
                                selected = quality.id == state.selectedQualityId,
                                onClick = { viewModel.selectQuality(quality.id) },
                            )
                        }
                    }

                    Button(
                        onClick = { viewModel.enqueue() },
                        enabled = state.selectedQualityId != null,
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Text("Download")
                    }
                }
            }
        }
    }
}

@Composable
private fun PlatformChip(platform: String) {
    Text(
        platform.replaceFirstChar { it.uppercase() },
        style = MaterialTheme.typography.labelLarge,
        color = platformAccent(platform),
    )
}

@Composable
private fun QualityChip(quality: QualityOption, selected: Boolean, onClick: () -> Unit) {
    FilterChip(
        selected = selected,
        onClick = onClick,
        label = {
            Column {
                Text(quality.label)
                val subtitle = listOfNotNull(quality.note.takeIf { it.isNotBlank() }, quality.sizeLabel).joinToString(" · ")
                if (subtitle.isNotBlank()) {
                    Text(subtitle, style = MaterialTheme.typography.bodyMedium)
                }
            }
        },
    )
}

private fun formatDuration(totalSeconds: Long): String {
    val h = totalSeconds / 3600
    val m = (totalSeconds % 3600) / 60
    val s = totalSeconds % 60
    return if (h > 0) String.format("%d:%02d:%02d", h, m, s) else String.format("%d:%02d", m, s)
}

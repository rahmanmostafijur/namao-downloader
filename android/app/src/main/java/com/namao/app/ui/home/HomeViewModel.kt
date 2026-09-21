package com.namao.app.ui.home

import android.app.Application
import android.content.Intent
import androidx.core.content.ContextCompat
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.namao.app.NamaoApplication
import com.namao.app.engine.CookieStore
import com.namao.app.engine.ErrorClassifier
import com.namao.app.engine.MediaInfo
import com.namao.app.engine.PlatformDetector
import com.namao.app.engine.QualityBuilder
import com.namao.app.service.DownloadService
import com.yausername.youtubedl_android.YoutubeDLRequest
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class HomeViewModel(application: Application) : AndroidViewModel(application) {

    private val app get() = getApplication<NamaoApplication>()
    private val repository = app.downloadRepository
    private val settingsRepository = app.settingsRepository

    data class UiState(
        val url: String = "",
        val isAnalyzing: Boolean = false,
        val mediaInfo: MediaInfo? = null,
        val errorMessage: String? = null,
        val selectedQualityId: String? = null,
        val justEnqueued: Boolean = false,
    )

    private val _state = MutableStateFlow(UiState())
    val state: StateFlow<UiState> = _state.asStateFlow()

    fun onUrlChange(newUrl: String) {
        _state.update { it.copy(url = newUrl, errorMessage = null) }
    }

    fun analyze(url: String = _state.value.url) {
        val normalized = PlatformDetector.normalize(url)
        val platform = PlatformDetector.detect(normalized)
        if (platform == null) {
            _state.update { it.copy(errorMessage = "Please enter a valid supported video URL.", mediaInfo = null) }
            return
        }
        _state.update { it.copy(isAnalyzing = true, errorMessage = null, mediaInfo = null, url = normalized) }
        viewModelScope.launch {
            try {
                app.awaitEngineReady()
                val request = YoutubeDLRequest(normalized)
                CookieStore.applyTo(app, request)
                val info = withContext(Dispatchers.IO) {
                    com.yausername.youtubedl_android.YoutubeDL.getInstance().getInfo(request)
                }
                val mediaInfo = QualityBuilder.build(platform, info)
                val settings = settingsRepository.settings.first()
                val defaultQuality = mediaInfo.qualities.firstOrNull { it.id == settings.defaultQualityId }?.id
                    ?: mediaInfo.qualities.firstOrNull()?.id
                _state.update { it.copy(isAnalyzing = false, mediaInfo = mediaInfo, selectedQualityId = defaultQuality) }
                if (settings.autoStartAfterAnalyze && defaultQuality != null) {
                    enqueue(defaultQuality)
                }
            } catch (e: Exception) {
                // yt-dlp's raw exception text is developer-facing only (Phase
                // 22/23); the user always sees one of these two fixed messages.
                val kind = ErrorClassifier.classify(e.message)
                val message = if (kind == com.namao.app.engine.FailureKind.UNKNOWN) {
                    "Couldn't read that video. It may be private, deleted, age-restricted, or blocked in your region."
                } else {
                    ErrorClassifier.userMessage(kind)
                }
                _state.update { it.copy(isAnalyzing = false, errorMessage = message) }
            }
        }
    }

    fun selectQuality(id: String) {
        _state.update { it.copy(selectedQualityId = id) }
    }

    fun enqueue(qualityId: String? = _state.value.selectedQualityId) {
        val id = qualityId ?: return
        val info = _state.value.mediaInfo ?: return
        val quality = info.qualities.firstOrNull { it.id == id } ?: return
        viewModelScope.launch {
            repository.enqueue(
                sourceUrl = _state.value.url,
                platform = info.platform,
                title = info.title,
                uploader = info.uploader,
                thumbnailUrl = info.thumbnailUrl,
                durationSeconds = info.durationSeconds,
                qualityId = quality.id,
                qualityLabel = quality.label,
            )
            ContextCompat.startForegroundService(app, Intent(app, DownloadService::class.java))
            _state.update { UiState(justEnqueued = true) }
        }
    }

    fun consumeEnqueuedFlag() {
        _state.update { it.copy(justEnqueued = false) }
    }
}

package com.namao.app.settings

import android.content.Context
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.intPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map

enum class ThemeMode { SYSTEM, LIGHT, DARK }

data class AppSettings(
    val themeMode: ThemeMode = ThemeMode.SYSTEM,
    val wifiOnly: Boolean = false,
    val maxConcurrentDownloads: Int = 2,
    val defaultQualityId: String = "best",
    val notifyOnComplete: Boolean = true,
    val autoStartAfterAnalyze: Boolean = false,
)

private val Context.dataStore by preferencesDataStore(name = "namao_settings")

/** Only settings the current architecture can actually honor end to end are
 * exposed here (Phase 28: "Only implement settings that are technically
 * supported by the existing architecture."). */
class SettingsRepository(private val context: Context) {

    private object Keys {
        val THEME = stringPreferencesKey("theme_mode")
        val WIFI_ONLY = booleanPreferencesKey("wifi_only")
        val MAX_CONCURRENT = intPreferencesKey("max_concurrent_downloads")
        val DEFAULT_QUALITY = stringPreferencesKey("default_quality_id")
        val NOTIFY_ON_COMPLETE = booleanPreferencesKey("notify_on_complete")
        val AUTO_START = booleanPreferencesKey("auto_start_after_analyze")
    }

    val settings: Flow<AppSettings> = context.dataStore.data.map { prefs ->
        AppSettings(
            themeMode = prefs[Keys.THEME]?.let { runCatching { ThemeMode.valueOf(it) }.getOrNull() }
                ?: ThemeMode.SYSTEM,
            wifiOnly = prefs[Keys.WIFI_ONLY] ?: false,
            maxConcurrentDownloads = (prefs[Keys.MAX_CONCURRENT] ?: 2).coerceIn(1, 3),
            defaultQualityId = prefs[Keys.DEFAULT_QUALITY] ?: "best",
            notifyOnComplete = prefs[Keys.NOTIFY_ON_COMPLETE] ?: true,
            autoStartAfterAnalyze = prefs[Keys.AUTO_START] ?: false,
        )
    }

    suspend fun setThemeMode(mode: ThemeMode) {
        context.dataStore.edit { it[Keys.THEME] = mode.name }
    }

    suspend fun setWifiOnly(enabled: Boolean) {
        context.dataStore.edit { it[Keys.WIFI_ONLY] = enabled }
    }

    suspend fun setMaxConcurrentDownloads(value: Int) {
        context.dataStore.edit { it[Keys.MAX_CONCURRENT] = value.coerceIn(1, 3) }
    }

    suspend fun setDefaultQualityId(id: String) {
        context.dataStore.edit { it[Keys.DEFAULT_QUALITY] = id }
    }

    suspend fun setNotifyOnComplete(enabled: Boolean) {
        context.dataStore.edit { it[Keys.NOTIFY_ON_COMPLETE] = enabled }
    }

    suspend fun setAutoStartAfterAnalyze(enabled: Boolean) {
        context.dataStore.edit { it[Keys.AUTO_START] = enabled }
    }
}

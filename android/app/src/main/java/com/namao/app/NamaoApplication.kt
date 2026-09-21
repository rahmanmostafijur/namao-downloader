package com.namao.app

import android.app.Application
import android.util.Log
import androidx.room.Room
import com.namao.app.data.DownloadRepository
import com.namao.app.data.NamaoDatabase
import com.namao.app.settings.SettingsRepository
import com.yausername.ffmpeg.FFmpeg
import com.yausername.youtubedl_android.YoutubeDL
import com.yausername.youtubedl_android.YoutubeDLException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/**
 * Owns everything that must outlive any single Activity: the database, the
 * yt-dlp/ffmpeg native runtime init (previously done in MainActivity.onCreate,
 * which meant it re-ran on every Activity recreation), and settings.
 */
class NamaoApplication : Application() {

    val applicationScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    val database: NamaoDatabase by lazy {
        Room.databaseBuilder(this, NamaoDatabase::class.java, "namao.db").build()
    }

    val downloadRepository: DownloadRepository by lazy { DownloadRepository(database.downloadDao()) }

    val settingsRepository: SettingsRepository by lazy { SettingsRepository(this) }

    // youtubedl-android bundles a yt-dlp binary frozen at the library's last
    // release, which goes stale fast — YouTube in particular changes often
    // enough that an old yt-dlp regresses to audio-only or nothing at all.
    // Self-update once per process start; every bridge call awaits this so
    // even the very first fetch after install benefits.
    private val engineReady = CompletableDeferred<Unit>()

    override fun onCreate() {
        super.onCreate()
        applicationScope.launch(Dispatchers.IO) {
            try {
                YoutubeDL.getInstance().init(this@NamaoApplication)
                FFmpeg.getInstance().init(this@NamaoApplication)
                try {
                    YoutubeDL.getInstance().updateYoutubeDL(this@NamaoApplication)
                } catch (e: YoutubeDLException) {
                    Log.w(TAG, "yt-dlp self-update failed, continuing with bundled version", e)
                }
            } catch (e: YoutubeDLException) {
                Log.e(TAG, "failed to initialize youtubedl-android", e)
            } finally {
                engineReady.complete(Unit)
            }
        }
    }

    suspend fun awaitEngineReady() = engineReady.await()

    companion object {
        private const val TAG = "Namao"
    }
}

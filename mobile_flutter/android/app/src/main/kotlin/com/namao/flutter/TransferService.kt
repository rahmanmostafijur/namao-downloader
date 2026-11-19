package com.namao.flutter

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.IBinder

/**
 * A foreground service with no logic of its own. While it runs, Android keeps the app process
 * (the downloader and the Dart code tracking it) at foreground priority, so a download survives
 * the user switching apps. It does NOT survive the user swiping the app away from Recents: that
 * destroys the Flutter engine, the running download is stopped, and it shows as interrupted
 * (with Retry) on the next launch.
 */
class TransferService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        ensureChannel(this)
        running = true
        // Promote at the earliest moment: a service started with startForegroundService must call
        // startForeground promptly or Android raises an error.
        startForeground(
            NOTIFICATION_ID,
            build(this, -1, "Preparing your download…"),
            ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
        )
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val text = intent?.getStringExtra(EXTRA_TEXT).orEmpty()
        if (text.isNotEmpty()) update(this, -1, text)
        return START_NOT_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        running = false
        super.onDestroy()
    }

    companion object {
        const val EXTRA_TEXT = "text"

        /** Guards late progress updates from re-posting a notification after the service stopped. */
        @Volatile
        private var running = false
        private const val CHANNEL_ID = "transfers"
        private const val NOTIFICATION_ID = 4712

        private fun ensureChannel(context: Context) {
            val manager = context.getSystemService(NotificationManager::class.java)
            if (manager.getNotificationChannel(CHANNEL_ID) != null) return
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Downloads", NotificationManager.IMPORTANCE_LOW)
                    .apply { description = "Shown while Namao is downloading a video." },
            )
        }

        /** percent < 0 means indeterminate. */
        private fun build(context: Context, percent: Int, text: String): Notification {
            val builder = Notification.Builder(context, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_stat_download)
                .setContentTitle("Namao")
                .setContentText(text)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setCategory(Notification.CATEGORY_PROGRESS)
            builder.setProgress(100, percent.coerceAtLeast(0), percent < 0)
            return builder.build()
        }

        fun update(context: Context, percent: Int, text: String) {
            if (!running) return
            val manager = context.getSystemService(NotificationManager::class.java)
            manager.notify(NOTIFICATION_ID, build(context, percent, text))
        }
    }
}

package com.namao.app.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.core.app.NotificationCompat
import com.namao.app.MainActivity
import com.namao.app.R

/**
 * One place for every notification the app posts (Phase 19). A single
 * ongoing "summary" notification anchors the foreground service; completed
 * and failed jobs each get their own separate, swipeable notification so one
 * doesn't hide another when several downloads finish close together.
 */
class DownloadNotifications(private val context: Context) {

    private val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    fun ensureChannel() {
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Downloads",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Download progress and results"
        }
        manager.createNotificationChannel(channel)
    }

    fun buildProgressNotification(activeCount: Int, primaryTitle: String, progressPercent: Int, indeterminate: Boolean): Notification {
        val contentText = if (activeCount > 1) {
            "$primaryTitle  •  +${activeCount - 1} more"
        } else {
            "Downloading…"
        }
        val openAppIntent = PendingIntent.getActivity(
            context, 0, Intent(context, MainActivity::class.java).setAction(MainActivity.ACTION_OPEN_QUEUE),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(primaryTitle)
            .setContentText(contentText)
            .setProgress(100, progressPercent, indeterminate)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(openAppIntent)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }

    fun notifyCompleted(jobId: String, title: String, viewUri: Uri?, mimeType: String?) {
        val tapIntent = if (viewUri != null) {
            Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(viewUri, mimeType ?: "video/*")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            }
        } else {
            Intent(context, MainActivity::class.java).setAction(MainActivity.ACTION_OPEN_HISTORY)
        }
        val pendingIntent = PendingIntent.getActivity(
            context, jobId.hashCode(), tapIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle("Download complete")
            .setContentText(title)
            .setAutoCancel(true)
            .setContentIntent(pendingIntent)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .build()
        manager.notify(stableId(jobId), notification)
    }

    fun notifyFailed(jobId: String, title: String, message: String) {
        val retryIntent = PendingIntent.getService(
            context, jobId.hashCode(),
            Intent(context, DownloadService::class.java).setAction(DownloadService.ACTION_RETRY_JOB)
                .putExtra(DownloadService.EXTRA_JOB_ID, jobId),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val openIntent = PendingIntent.getActivity(
            context, jobId.hashCode(),
            Intent(context, MainActivity::class.java).setAction(MainActivity.ACTION_OPEN_HISTORY),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle("Download failed")
            .setContentText("$title — $message")
            .setStyle(NotificationCompat.BigTextStyle().bigText("$title — $message"))
            .setAutoCancel(true)
            .setContentIntent(openIntent)
            .addAction(0, "Retry", retryIntent)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .build()
        manager.notify(stableId(jobId), notification)
    }

    fun cancelJobNotification(jobId: String) = manager.cancel(stableId(jobId))

    private fun stableId(jobId: String): Int = (jobId.hashCode() and 0x7fffffff) or 0x10000

    companion object {
        const val CHANNEL_ID = "downloads"
        const val FOREGROUND_NOTIFICATION_ID = 1
    }
}

package com.namao.flutter

import android.app.Activity
import android.app.PendingIntent
import android.content.ActivityNotFoundException
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.content.pm.Signature
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest

/** A downloaded update that must not be installed; [reason] is a code Dart turns into wording. */
class InstallRejected(val reason: String, message: String) : Exception(message)

/**
 * Hands a downloaded Namao APK to Android's Package Installer. Nothing here installs silently or
 * bypasses a check: the system shows its own confirmation screen, and a file that is not our app,
 * not newer, not compatible with this phone or signed by someone else never reaches that screen.
 * (Android would refuse the last case anyway; checking first lets us say so clearly.)
 */
object AppInstaller {
    private const val TAG = "NamaoUpdate"
    const val ACTION_RESULT = "com.namao.flutter.INSTALL_RESULT"

    /** Where Dart saves downloaded updates; emptied on every request so old files never pile up. */
    fun downloadDir(context: Context): File =
        File(context.cacheDir, "updates").apply {
            mkdirs()
            listFiles()?.forEach { it.delete() }
        }

    /** Installed by the channel: tells Dart how the system installer finished. */
    @Volatile
    var onResult: ((status: String, message: String?) -> Unit)? = null

    fun install(activity: Activity, path: String): Map<String, Any?> {
        val file = File(path).canonicalFile
        val allowed = File(activity.cacheDir, "updates").canonicalFile
        if (file.parentFile != allowed || !file.isFile) {
            throw InstallRejected("not_found", "the update file is not where it should be")
        }
        if (!activity.packageManager.canRequestPackageInstalls()) {
            // Android's own switch, per app. Opening it is the supported way to ask.
            val settings = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${activity.packageName}"))
            try {
                activity.startActivity(settings)
            } catch (e: ActivityNotFoundException) {
                Log.w(TAG, "no screen for the install permission", e)
            }
            return mapOf("status" to "needs_permission")
        }
        verify(activity, file)
        commit(activity, file)
        return mapOf("status" to "started")
    }

    private fun verify(context: Context, file: File) {
        val pm = context.packageManager
        val archive = archiveInfo(pm, file.path)
            ?: throw InstallRejected("not_an_apk", "the file could not be read as an app")
        if (archive.packageName != context.packageName) {
            throw InstallRejected("wrong_app", "the file belongs to ${archive.packageName}")
        }
        val installed = pm.getPackageInfo(context.packageName, PackageManager.GET_SIGNING_CERTIFICATES)
        if (archive.longVersionCode <= installed.longVersionCode) {
            throw InstallRejected("not_newer", "version code ${archive.longVersionCode} is not newer than ${installed.longVersionCode}")
        }
        val minSdk = archive.applicationInfo?.minSdkVersion ?: 0
        if (minSdk > Build.VERSION.SDK_INT) {
            throw InstallRejected("incompatible", "needs Android API $minSdk, this phone has ${Build.VERSION.SDK_INT}")
        }
        val installedCerts = digests(installed.signingInfo?.apkContentsSigners)
        val incoming = archive.signingInfo
        if (incoming == null || installedCerts.isEmpty()) {
            // Not readable here; Android compares the certificates itself when installing.
            Log.w(TAG, "could not read the signing certificate before installing")
            return
        }
        val sameSigners = digests(incoming.apkContentsSigners) == installedCerts
        val rotated = digests(incoming.signingCertificateHistory).any { it in installedCerts }
        if (!sameSigners && !rotated) {
            throw InstallRejected("signature_mismatch", "the update is signed with a different key")
        }
    }

    @Suppress("DEPRECATION")
    private fun archiveInfo(pm: PackageManager, path: String): PackageInfo? {
        val flags = PackageManager.GET_SIGNING_CERTIFICATES
        val info = if (Build.VERSION.SDK_INT >= 33) {
            pm.getPackageArchiveInfo(path, PackageManager.PackageInfoFlags.of(flags.toLong()))
        } else {
            pm.getPackageArchiveInfo(path, flags)
        }
        info?.applicationInfo?.let { it.sourceDir = path; it.publicSourceDir = path }
        return info
    }

    private fun digests(signatures: Array<Signature>?): Set<String> =
        signatures.orEmpty().map { sig ->
            MessageDigest.getInstance("SHA-256").digest(sig.toByteArray()).joinToString("") { "%02x".format(it) }
        }.toSet()

    /** Streams the file into an install session and commits it; the system then asks the person to confirm. */
    private fun commit(context: Context, file: File) {
        val installer = context.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
        params.setAppPackageName(context.packageName)
        if (Build.VERSION.SDK_INT >= 31) {
            params.setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_REQUIRED)
        }
        val id = installer.createSession(params)
        val session = installer.openSession(id)
        try {
            session.openWrite("namao-update.apk", 0, file.length()).use { out ->
                file.inputStream().use { it.copyTo(out) }
                session.fsync(out)
            }
            val result = Intent(context, InstallResultReceiver::class.java).setAction(ACTION_RESULT)
            // Mutable: the system adds the status extras to it.
            val pending = PendingIntent.getBroadcast(
                context, id, result, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
            )
            session.commit(pending.intentSender)
        } catch (e: Exception) {
            session.abandon()
            throw e
        } finally {
            session.close()
        }
    }

    /** The release page, for the case where installing from inside the app cannot go ahead. */
    fun openLink(activity: Activity, url: String) {
        require(url.startsWith("https://")) { "only secure links" }
        try {
            activity.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
        } catch (e: ActivityNotFoundException) {
            throw IllegalStateException("no app can open links")
        }
    }
}

/** Receives the Package Installer's progress: shows its confirmation screen, then reports the outcome. */
class InstallResultReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)
        val message = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)
        when (status) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                @Suppress("DEPRECATION")
                val confirm = intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
                if (confirm == null) {
                    AppInstaller.onResult?.invoke("failed", "no confirmation screen")
                } else {
                    try {
                        context.startActivity(confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    } catch (e: Exception) {
                        Log.w("NamaoUpdate", "could not show the install confirmation", e)
                        AppInstaller.onResult?.invoke("failed", e.message)
                    }
                }
            }
            PackageInstaller.STATUS_SUCCESS -> AppInstaller.onResult?.invoke("success", null)
            PackageInstaller.STATUS_FAILURE_ABORTED -> AppInstaller.onResult?.invoke("aborted", message)
            else -> AppInstaller.onResult?.invoke("failed", message)
        }
    }
}

/** The MethodChannel in front of [AppInstaller] (Dart: `data/updates/apk_installer.dart`). */
class AppUpdateChannel(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, CHANNEL)

    private val listener: (String, String?) -> Unit = { status, message ->
        activity.runOnUiThread {
            channel.invokeMethod("installResult", mapOf("status" to status, "message" to message))
        }
    }

    init {
        channel.setMethodCallHandler { call, result -> handle(call, result) }
        AppInstaller.onResult = listener
    }

    fun close() {
        // A newer activity may already have taken over; only remove our own listener.
        if (AppInstaller.onResult === listener) AppInstaller.onResult = null
        channel.setMethodCallHandler(null)
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "downloadDir" -> result.success(AppInstaller.downloadDir(activity).absolutePath)
                "install" -> result.success(AppInstaller.install(activity, call.argument<String>("path")!!))
                "openLink" -> {
                    AppInstaller.openLink(activity, call.argument<String>("url")!!)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        } catch (e: InstallRejected) {
            result.success(mapOf("status" to "rejected", "reason" to e.reason, "message" to e.message))
        } catch (e: Exception) {
            result.error("update_error", e.message ?: e.javaClass.simpleName, null)
        }
    }

    companion object {
        const val CHANNEL = "com.namao.flutter/updates"
    }
}

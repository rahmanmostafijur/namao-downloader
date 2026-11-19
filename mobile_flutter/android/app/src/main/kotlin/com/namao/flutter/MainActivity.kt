package com.namao.flutter

import android.Manifest
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileNotFoundException
import java.io.IOException
import java.util.concurrent.Executors

/** Thrown for failures the Dart side maps to a specific user message. */
class MediaException(val code: String, message: String) : Exception(message)

/**
 * The small Android-only surface of the app: saving into MediaStore.Downloads (Download/Namao),
 * opening / sharing the saved file, and the foreground service that keeps the phone-side
 * transfer alive while the app is in the background. Everything else is Dart.
 */
class MainActivity : FlutterActivity() {
    private val worker = Executors.newSingleThreadExecutor()
    private var pendingNotificationResult: MethodChannel.Result? = null
    private var engineChannel: EngineChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        MethodChannel(messenger, CHANNEL)
            .setMethodCallHandler { call, result -> dispatch(call, result) }
        engineChannel = EngineChannel(this, messenger, LocalEngine.get(applicationContext))
    }

    override fun onDestroy() {
        // Leaving the app destroys the Flutter engine, and with it the progress tracking. The service
        // has no work of its own, so it must not outlive the activity with a stale notification, and
        // a download nobody can see any more is stopped rather than left running unseen.
        if (isFinishing) {
            stopService(Intent(this, TransferService::class.java))
            engineChannel?.close()
        }
        worker.shutdown()
        super.onDestroy()
    }

    private fun dispatch(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "saveToDownloads" -> runOffMainThread(result) { saveToDownloads(call) }
            "exists" -> runOffMainThread(result) { uriExists(Uri.parse(call.argument<String>("uri")!!)) }
            "open" -> guarded(result) { openFile(call) }
            "share" -> guarded(result) { shareFile(call) }
            "startTransfer" -> guarded(result) { startTransfer(call) }
            "updateTransfer" -> guarded(result) { updateTransfer(call) }
            "stopTransfer" -> guarded(result) { stopService(Intent(this, TransferService::class.java)); true }
            "requestNotificationPermission" -> requestNotificationPermission(result)
            "appVersion" -> guarded(result) { appVersion() }
            else -> result.notImplemented()
        }
    }

    private fun guarded(result: MethodChannel.Result, block: () -> Any) {
        try {
            result.success(block())
        } catch (e: MediaException) {
            result.error(e.code, e.message, null)
        } catch (e: Exception) {
            result.error("io", e.message ?: e.javaClass.simpleName, null)
        }
    }

    private fun runOffMainThread(result: MethodChannel.Result, block: () -> Any) {
        worker.execute {
            try {
                val value = block()
                runOnUiThread { result.success(value) }
            } catch (e: MediaException) {
                runOnUiThread { result.error(e.code, e.message, null) }
            } catch (e: Exception) {
                runOnUiThread { result.error("io", e.message ?: e.javaClass.simpleName, null) }
            }
        }
    }

    // --- MediaStore -------------------------------------------------------------------------

    /**
     * Copies the verified temp file into Download/Namao. IS_PENDING hides the row from other apps
     * until every byte is written; on any failure the row is deleted, so no partial file is left.
     * MediaStore renames duplicates ("name (1).mp4"), so the real name is read back.
     */
    private fun saveToDownloads(call: MethodCall): Map<String, Any> {
        val tempPath = call.argument<String>("tempPath")!!
        val displayName = call.argument<String>("displayName")!!
        val mimeType = call.argument<String>("mimeType")!!
        val expectedBytes = (call.argument<Number>("expectedBytes")!!).toLong()

        val resolver = contentResolver
        val collection = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val pending = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, displayName)
            put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
            put(MediaStore.MediaColumns.RELATIVE_PATH, "Download/Namao")
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val uri = resolver.insert(collection, pending)
            ?: throw MediaException("io", "MediaStore refused the new file")
        try {
            val copied = copyInto(uri, File(tempPath))
            if (copied != expectedBytes) {
                throw MediaException("size_mismatch", "Wrote $copied of $expectedBytes bytes")
            }
            val done = ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }
            if (resolver.update(uri, done, null, null) != 1) {
                throw MediaException("io", "Could not publish the saved file")
            }
            return mapOf(
                "uri" to uri.toString(),
                "displayName" to (queryName(uri) ?: displayName),
                "sizeBytes" to copied,
            )
        } catch (e: Throwable) {
            try {
                resolver.delete(uri, null, null)
            } catch (cleanup: Exception) {
                // The original failure is the one worth reporting.
            }
            throw translate(e)
        }
    }

    private fun copyInto(target: Uri, source: File): Long {
        val output = contentResolver.openOutputStream(target, "w")
            ?: throw MediaException("io", "Could not open the destination file")
        output.use { out ->
            source.inputStream().use { input ->
                val written = input.copyTo(out)
                out.flush()
                return written
            }
        }
    }

    private fun translate(error: Throwable): Throwable {
        if (error is MediaException) return error
        val text = (error.message ?: "").lowercase()
        if (error is IOException && (text.contains("enospc") || text.contains("no space left"))) {
            return MediaException("storage_full", "No space left on device")
        }
        return error
    }

    private fun queryName(uri: Uri): String? =
        contentResolver.query(uri, arrayOf(MediaStore.MediaColumns.DISPLAY_NAME), null, null, null)
            ?.use { if (it.moveToFirst()) it.getString(0) else null }

    private fun uriExists(uri: Uri): Boolean = try {
        contentResolver.openFileDescriptor(uri, "r")?.use { true } ?: false
    } catch (e: FileNotFoundException) {
        false
    } catch (e: SecurityException) {
        false
    }

    // --- Open / share -----------------------------------------------------------------------

    private fun openFile(call: MethodCall): Boolean {
        val uri = Uri.parse(call.argument<String>("uri")!!)
        val view = Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, call.argument<String>("mimeType")!!)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        try {
            startActivity(view)
        } catch (e: ActivityNotFoundException) {
            throw MediaException("no_app", "No app can open this file")
        }
        return true
    }

    private fun shareFile(call: MethodCall): Boolean {
        val uri = Uri.parse(call.argument<String>("uri")!!)
        val send = Intent(Intent.ACTION_SEND)
            .setType(call.argument<String>("mimeType")!!)
            .putExtra(Intent.EXTRA_STREAM, uri)
            .putExtra(Intent.EXTRA_TITLE, call.argument<String>("title"))
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        send.clipData = ClipData.newRawUri("", uri)
        val chooser = Intent.createChooser(send, call.argument<String>("title"))
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        try {
            startActivity(chooser)
        } catch (e: ActivityNotFoundException) {
            throw MediaException("no_app", "No app can share this file")
        }
        return true
    }

    // --- Transfer service + notification permission -----------------------------------------

    private fun startTransfer(call: MethodCall): Boolean {
        val intent = Intent(this, TransferService::class.java)
            .putExtra(TransferService.EXTRA_TEXT, call.argument<String>("text") ?: "")
        startForegroundService(intent)
        return true
    }

    private fun updateTransfer(call: MethodCall): Boolean {
        TransferService.update(
            this,
            (call.argument<Number>("percent") ?: 0).toInt(),
            call.argument<String>("text") ?: "",
        )
        return true
    }

    private fun requestNotificationPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        ) {
            result.success(true)
            return
        }
        pendingNotificationResult?.success(false)
        pendingNotificationResult = result
        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQUEST_NOTIFICATIONS)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQUEST_NOTIFICATIONS) {
            pendingNotificationResult?.success(grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED)
            pendingNotificationResult = null
        }
    }

    private fun appVersion(): String {
        val info = packageManager.getPackageInfo(packageName, 0)
        return "${info.versionName} (${info.longVersionCode})"
    }

    companion object {
        const val CHANNEL = "com.namao.flutter/media"
        private const val REQUEST_NOTIFICATIONS = 4711
    }
}

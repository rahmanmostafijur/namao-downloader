package com.namao.flutter

import android.app.Activity
import android.content.Intent
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * The channel for the optional Instagram session: pick a cookies.txt with Android's system file
 * picker (the app needs no storage permission), then store / inspect / remove it in [SessionVault].
 * The file's contents travel only between this process's Dart and Kotlin sides and are never logged.
 */
class SessionChannel(
    private val activity: Activity,
    messenger: BinaryMessenger,
    private val vault: SessionVault,
) {
    private val worker = Executors.newSingleThreadExecutor()
    private var pendingPick: MethodChannel.Result? = null

    init {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result -> dispatch(call, result) }
    }

    fun close() {
        pendingPick?.success(null)
        pendingPick = null
        worker.shutdown()
    }

    private fun dispatch(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pick" -> pick(result)
            "info" -> off(result) { vault.info() }
            "save" -> off(result) {
                vault.save(call.argument<String>("text")!!, call.argument<Number>("expiresAt")?.toLong())
                true
            }
            "remove" -> off(result) {
                vault.remove()
                true
            }
            else -> result.notImplemented()
        }
    }

    private fun off(result: MethodChannel.Result, block: () -> Any?) {
        worker.execute {
            try {
                val value = block()
                activity.runOnUiThread { result.success(value) }
            } catch (e: Exception) {
                // Only the exception type: its message could echo what was being stored.
                activity.runOnUiThread { result.error("session_error", e.javaClass.simpleName, null) }
            }
        }
    }

    private fun pick(result: MethodChannel.Result) {
        pendingPick?.success(null)
        pendingPick = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT)
            .addCategory(Intent.CATEGORY_OPENABLE)
            .setType("*/*")
        try {
            activity.startActivityForResult(intent, REQUEST_PICK)
        } catch (e: Exception) {
            pendingPick = null
            result.error("no_picker", "No file picker is available", null)
        }
    }

    /** True when the result belonged to this channel. */
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_PICK) return false
        val result = pendingPick ?: return true
        pendingPick = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(null) // cancelled
            return true
        }
        worker.execute {
            try {
                val text = readLimited(uri)
                activity.runOnUiThread { result.success(text) }
            } catch (e: TooLarge) {
                activity.runOnUiThread { result.error("too_large", "File is too large", null) }
            } catch (e: Exception) {
                activity.runOnUiThread { result.error("read_failed", e.javaClass.simpleName, null) }
            }
        }
        return true
    }

    private class TooLarge : Exception()

    private fun readLimited(uri: android.net.Uri): String {
        val input = activity.contentResolver.openInputStream(uri) ?: throw java.io.IOException("unreadable")
        input.use { stream ->
            val bytes = stream.readNBytes(MAX_BYTES + 1)
            if (bytes.size > MAX_BYTES) throw TooLarge()
            return String(bytes, Charsets.UTF_8)
        }
    }

    companion object {
        const val CHANNEL = "com.namao.flutter/session"
        private const val REQUEST_PICK = 4712
        private const val MAX_BYTES = 1_000_000 // a cookies.txt is a few KB; a browser export, well under 1 MB
    }
}

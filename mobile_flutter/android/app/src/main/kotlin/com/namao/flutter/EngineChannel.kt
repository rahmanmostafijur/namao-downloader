package com.namao.flutter

import android.app.Activity
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * The MethodChannel in front of [LocalEngine]. Every call is blocking work (starting processes,
 * disk, network), so it runs on a worker thread and answers on the UI thread.
 */
class EngineChannel(
    private val activity: Activity,
    messenger: BinaryMessenger,
    private val engine: LocalEngine,
) {
    private val workers: ExecutorService = Executors.newCachedThreadPool()

    init {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            workers.execute { respond(call, result) }
        }
    }

    fun close() {
        engine.cancelAll()
        workers.shutdown()
    }

    private fun respond(call: MethodCall, result: MethodChannel.Result) {
        try {
            val value = dispatch(call)
            activity.runOnUiThread { result.success(value) }
        } catch (e: EngineException) {
            activity.runOnUiThread { result.error(e.code, e.message, null) }
        } catch (e: IllegalArgumentException) {
            activity.runOnUiThread { result.error("bad_request", e.message, null) }
        } catch (e: Exception) {
            activity.runOnUiThread { result.error("engine_error", e.message ?: e.javaClass.simpleName, null) }
        }
    }

    private fun dispatch(call: MethodCall): Any? = when (call.method) {
        "init" -> engine.init()
        "run" -> engine.run(call.argument<String>("url")!!, call.argument<List<String>>("args")!!)
        "start" -> {
            engine.start(
                call.argument<String>("jobId")!!,
                call.argument<String>("url")!!,
                call.argument<List<String>>("args")!!,
            )
            true
        }
        "status" -> engine.status(call.argument<String>("jobId")!!)
        "cancel" -> {
            engine.cancel(call.argument<String>("jobId")!!)
            true
        }
        "release" -> {
            engine.release(call.argument<String>("jobId")!!)
            true
        }
        "cleanup" -> {
            engine.cleanup(call.argument<List<String>>("keep")!!.toSet())
            true
        }
        else -> throw IllegalArgumentException("unknown method ${call.method}")
    }

    companion object {
        const val CHANNEL = "com.namao.flutter/engine"
    }
}

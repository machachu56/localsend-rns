package org.localsend.localsend_app

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.chaquo.python.PyObject
import com.chaquo.python.Python
import com.chaquo.python.android.AndroidPlatform
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import java.util.function.Consumer

private const val RNS_METHOD_CHANNEL = "org.localsend.localsend_app/rns"
private const val RNS_EVENT_CHANNEL = "org.localsend.localsend_app/rns_events"

/**
 * Runs rns_bridge.py inside the app process (Chaquopy) and exposes it to Dart.
 * Same protocol as the desktop child process: JSON lines in via [MethodChannel] "command",
 * JSON lines out via [EventChannel].
 */
class RnsBridgeHandler(private val context: Context, messenger: BinaryMessenger) {
    private val mainHandler = Handler(Looper.getMainLooper())
    // Single thread: commands (incl. the blocking `init`) stay ordered and never block the UI thread.
    private val executor = Executors.newSingleThreadExecutor()
    private var eventSink: EventChannel.EventSink? = null
    private val pendingEvents = ArrayDeque<String>()
    private var module: PyObject? = null

    init {
        EventChannel(messenger, RNS_EVENT_CHANNEL).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                eventSink = events
                // Flush anything emitted before Dart started listening.
                while (pendingEvents.isNotEmpty()) events?.success(pendingEvents.removeFirst())
            }

            override fun onCancel(arguments: Any?) {
                eventSink = null
            }
        })

        MethodChannel(messenger, RNS_METHOD_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> executor.execute {
                    try {
                        start()
                        mainHandler.post { result.success(null) }
                    } catch (e: Throwable) {
                        mainHandler.post { result.error("RNS_START_FAILED", e.message ?: e.toString(), null) }
                    }
                }

                "command" -> {
                    val line = call.arguments as? String
                    if (line == null) {
                        result.error("BAD_ARGS", "command expects a JSON string", null)
                    } else {
                        executor.execute { runCommand(line) }
                        result.success(null)
                    }
                }

                "stop" -> {
                    executor.execute { module?.callAttr("stop_embedded") }
                    result.success(null)
                }

                else -> result.notImplemented()
            }
        }
    }

    private fun start() {
        if (module != null) return
        if (!Python.isStarted()) Python.start(AndroidPlatform(context))
        val mod = Python.getInstance().getModule("rns_bridge")
        mod.callAttr("start_embedded", Consumer<String> { line -> emit(line) })
        module = mod
    }

    private fun runCommand(line: String) {
        val mod = module
        if (mod == null) {
            emit("""{"event":"bridge_error","message":"RNS bridge not started"}""")
            return
        }
        try {
            mod.callAttr("handle_line", line)
        } catch (e: Throwable) {
            val msg = (e.message ?: e.toString()).replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n")
            emit("""{"event":"error","message":"$msg"}""")
        }
    }

    private fun emit(line: String) {
        mainHandler.post {
            val sink = eventSink
            if (sink != null) sink.success(line) else pendingEvents.addLast(line)
        }
    }
}

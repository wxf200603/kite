package com.psyche.kelivo.quickjs

import java.io.Closeable
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import kotlin.math.max
import org.json.JSONArray

/**
 * Receives console output captured from the QuickJS sandbox.
 *
 * @param level one of `log`, `info`, `warn`, `error`, `debug`.
 * @param message the already-joined stringified arguments.
 */
fun interface QuickJsConsoleListener {
    fun onConsole(level: String, message: String)
}

class QuickJsNativeHostDispatcher(
    private val dispatchTimer: (Int) -> Unit,
    private val forwardCall: (String, String?) -> String?
) : QuickJsNativeRuntime.HostBridge, Closeable {

    @Volatile
    var consoleListener: QuickJsConsoleListener? = null

    private val scheduler = Executors.newSingleThreadScheduledExecutor { runnable ->
        Thread(runnable, "QuickJsNativeTimer").apply { isDaemon = true }
    }
    private val timerTasks = ConcurrentHashMap<Int, ScheduledFuture<*>>()

    override fun onCall(method: String, argsJson: String?): String? {
        return when {
            method.startsWith("console.") -> {
                handleConsole(method, argsJson)
                null
            }
            method == "scheduleTimer" -> {
                schedule(argsJson)
                null
            }
            method == "cancelTimer" -> {
                cancel(argsJson)
                null
            }
            else -> forwardCall(method, argsJson)
        }
    }

    private fun handleConsole(method: String, argsJson: String?) {
        val listener = consoleListener ?: return
        val level = method.removePrefix("console.")
        val args = parseArgs(argsJson)
        val message = args.joinToString(" ")
        runCatching { listener.onConsole(level, message) }
    }

    override fun close() {
        timerTasks.values.forEach { it.cancel(false) }
        timerTasks.clear()
        scheduler.shutdownNow()
    }

    private fun schedule(argsJson: String?) {
        val args = parseArgs(argsJson)
        val timerId = args.getOrNull(0)?.toIntOrNull() ?: return
        val delayMs = max(0L, args.getOrNull(1)?.toLongOrNull() ?: 0L)
        val repeat = args.getOrNull(2)?.let(::parseBoolean) ?: false

        timerTasks.remove(timerId)?.cancel(false)
        val task =
            if (repeat) {
                val safePeriod = max(1L, delayMs)
                scheduler.scheduleAtFixedRate(
                    { dispatchTimer(timerId) },
                    safePeriod,
                    safePeriod,
                    TimeUnit.MILLISECONDS
                )
            } else {
                scheduler.schedule(
                    {
                        timerTasks.remove(timerId)
                        dispatchTimer(timerId)
                    },
                    delayMs,
                    TimeUnit.MILLISECONDS
                )
            }
        timerTasks[timerId] = task
    }

    private fun cancel(argsJson: String?) {
        val timerId = parseArgs(argsJson).firstOrNull()?.toIntOrNull() ?: return
        timerTasks.remove(timerId)?.cancel(false)
    }

    private fun parseArgs(argsJson: String?): List<String> {
        if (argsJson.isNullOrBlank()) {
            return emptyList()
        }
        val array = JSONArray(argsJson)
        return buildList(array.length()) {
            for (index in 0 until array.length()) {
                add(array.optString(index))
            }
        }
    }

    private fun parseBoolean(value: String): Boolean {
        return value.toBooleanStrictOrNull() ?: (value.toIntOrNull() ?: 0) != 0
    }
}

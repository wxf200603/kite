package com.psyche.kelivo.llm

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import com.psyche.kelivo.llm.llama.LlamaSession
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

/**
 * Manages the lifecycle of llama.cpp sessions beyond a single inference call.
 *
 * Responsibilities (all optional, gated by [enabled] which mirrors the Dart
 * `localLlmEnabled` switch):
 *  - Release active sessions when the system is under memory pressure
 *    (`onTrimMemory` / `onLowMemory`).
 *  - Optionally release active sessions when the app is backgrounded
 *    ([bgReleaseModel]).
 *  - Optionally keep the most recently used model mmap-warm while the device
 *    is charging ([warmupOnCharge]).
 *
 * The manager does NOT force preload: when [enabled] is false every method is
 * a no-op and no receiver / component callback is registered.
 */
class LlamaPreWarmManager(private val context: Context) {

    /** Mirrors `localLlmEnabled`. When false the manager is inert. */
    @Volatile
    var enabled: Boolean = false
        set(value) {
            field = value
            if (value) registerCallbacks() else unregisterCallbacks()
        }

    /** Release all sessions when the app goes to the background. */
    @Volatile
    var bgReleaseModel: Boolean = false

    /** mmap-preload the last-used model while the device is charging. */
    @Volatile
    var warmupOnCharge: Boolean = false

    /** Notified when the manager releases a session so the plugin can drop it. */
    fun interface SessionReleaseCallback {
        fun onReleased(sessionId: String)
    }

    private data class TrackedSession(
        val session: LlamaSession,
        val modelPath: String,
        val config: LlamaSession.Config,
    )

    private val sessions = ConcurrentHashMap<String, TrackedSession>()
    private var releaseCallback: SessionReleaseCallback? = null

    @Volatile
    private var lastModelPath: String? = null
    @Volatile
    private var lastConfig: LlamaSession.Config? = null

    /** Session kept alive purely for mmap warm-up while charging. */
    @Volatile
    private var warmupSession: LlamaSession? = null

    private val executor = Executors.newSingleThreadExecutor { r ->
        Thread(r, "kelivo-llm-prewarm").apply { isDaemon = true }
    }

    private val componentCallbacks = object : android.content.ComponentCallbacks2 {
        override fun onTrimMemory(level: Int) {
            if (!enabled) return
            // Release on any non-trivial pressure. We deliberately do not
            // wait for TRIM_MEMORY_COMPLETE because a loaded GGUF model can
            // be hundreds of MB.
            if (level >= android.content.ComponentCallbacks2.TRIM_MEMORY_RUNNING_LOW) {
                releaseAllSessions(reason = "trim_memory_$level")
            }
        }

        override fun onLowMemory() {
            if (!enabled) return
            releaseAllSessions(reason = "low_memory")
        }

        override fun onConfigurationChanged(newConfig: android.content.res.Configuration) = Unit
    }

    private val chargingReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (!enabled || !warmupOnCharge) return
            val status = intent?.getIntExtra(
                BatteryManager.EXTRA_STATUS,
                BatteryManager.BATTERY_STATUS_UNKNOWN
            )
            val isCharging = status == BatteryManager.BATTERY_STATUS_CHARGING ||
                status == BatteryManager.BATTERY_STATUS_FULL
            if (isCharging) {
                scheduleWarmup()
            } else {
                releaseWarmupSession()
            }
        }
    }

    @Volatile
    private var callbacksRegistered = false

    fun setSessionReleaseCallback(callback: SessionReleaseCallback?) {
        releaseCallback = callback
    }

    /** Called by [LocalLlmPlugin] when a session is created. */
    fun trackSession(
        id: String,
        session: LlamaSession,
        modelPath: String,
        config: LlamaSession.Config,
    ) {
        if (!enabled) return
        sessions[id] = TrackedSession(session, modelPath, config)
        lastModelPath = modelPath
        lastConfig = config
    }

    /** Called by [LocalLlmPlugin] when a session is released by Dart. */
    fun untrackSession(id: String) {
        sessions.remove(id)
    }

    /** App moved to the background. */
    fun onAppBackground() {
        if (!enabled || !bgReleaseModel) return
        releaseAllSessions(reason = "background")
    }

    /** App moved to the foreground. */
    fun onAppForeground() {
        if (!enabled) return
        // If charging warm-up is on, make sure the warm-up session is alive.
        if (warmupOnCharge && isCurrentlyCharging()) {
            scheduleWarmup()
        }
    }

    private fun releaseAllSessions(reason: String) {
        val ids = ArrayList(sessions.keys)
        for (id in ids) {
            val tracked = sessions.remove(id) ?: continue
            runCatching { tracked.session.release() }
            releaseCallback?.onReleased(id)
        }
        // Also drop the warm-up session: it is not useful under pressure.
        releaseWarmupSession()
    }

    private fun scheduleWarmup() {
        val path = lastModelPath ?: return
        val baseConfig = lastConfig ?: return
        executor.execute {
            runCatching {
                warmupSession?.release()
                // Force mmap for the warm-up session so the model pages are
                // mapped but not necessarily faulted in. The first real
                // inference will still be fast because the kernel keeps the
                // pages in the page cache.
                warmupSession = LlamaSession.create(
                    pathModel = path,
                    config = baseConfig.copy(useMmap = true),
                )
            }
        }
    }

    private fun releaseWarmupSession() {
        val s = warmupSession
        warmupSession = null
        s?.let { runCatching { it.release() } }
    }

    private fun isCurrentlyCharging(): Boolean {
        val filter = IntentFilter(Intent.ACTION_BATTERY_CHANGED)
        val batteryStatus: Intent? = context.registerReceiver(null, filter)
        val status = batteryStatus?.getIntExtra(
            BatteryManager.EXTRA_STATUS,
            BatteryManager.BATTERY_STATUS_UNKNOWN
        )
        return status == BatteryManager.BATTERY_STATUS_CHARGING ||
            status == BatteryManager.BATTERY_STATUS_FULL
    }

    private fun registerCallbacks() {
        if (callbacksRegistered) return
        runCatching {
            context.registerComponentCallbacks(componentCallbacks)
            context.registerReceiver(
                chargingReceiver,
                IntentFilter(Intent.ACTION_BATTERY_CHANGED)
            )
        }
        callbacksRegistered = true
    }

    private fun unregisterCallbacks() {
        if (!callbacksRegistered) return
        runCatching { context.unregisterComponentCallbacks(componentCallbacks) }
        runCatching { context.unregisterReceiver(chargingReceiver) }
        callbacksRegistered = false
    }

    /** Release everything and tear down. Safe to call multiple times. */
    fun dispose() {
        enabled = false
        releaseAllSessions(reason = "dispose")
        executor.shutdownNow()
    }
}

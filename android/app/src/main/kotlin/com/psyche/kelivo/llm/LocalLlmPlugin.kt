package com.psyche.kelivo.llm

import android.content.Context
import com.psyche.kelivo.llm.llama.LlamaSession
import com.psyche.kelivo.llm.llama.ModelInfoReader
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

/**
 * Bridges Kelivo's Dart layer to the transplanted llama.cpp JNI binding.
 *
 * Only the Android-optimised llama.cpp path is exposed (no MNN). Model
 * download / management UI stays in Kelivo; this plugin just runs inference
 * for a model path the user already selected.
 */
class LocalLlmPlugin(private val context: Context) {
    companion object {
        const val CHANNEL_NAME = "app.llm"
    }

    private val executor = Executors.newSingleThreadExecutor { r ->
        Thread(r, "kelivo-local-llm").apply { isDaemon = true }
    }
    private val sessions = ConcurrentHashMap<String, LlamaSession>()
    private var methodChannel: MethodChannel? = null

    /** Lifecycle / memory / warm-up manager. Inert until [enabled] is set. */
    val prewarmManager = LlamaPreWarmManager(context).also { mgr ->
        mgr.setSessionReleaseCallback { sessionId -> sessions.remove(sessionId) }
    }

    fun configure(messenger: BinaryMessenger) {
        val channel = MethodChannel(messenger, CHANNEL_NAME)
        methodChannel = channel
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "isAvailable" -> result.success(LlamaSession.isAvailable())
                "getUnavailableReason" -> result.success(LlamaSession.getUnavailableReason())
                "createSession" -> {
                    val args = call.arguments as? Map<*, *>
                    val path = args?.get("pathModel")?.toString()
                    if (path.isNullOrBlank()) {
                        result.error("invalid_args", "pathModel is required", null)
                        return@setMethodCallHandler
                    }
                    executor.execute {
                        try {
                            val config = parseConfig(args)
                            val session = LlamaSession.create(path, config)
                            if (session == null) {
                                result.error("load_failed", "Failed to create llama session", null)
                                return@execute
                            }
                            val id = "llm_${System.nanoTime()}"
                            sessions[id] = session
                            prewarmManager.trackSession(id, session, path, config)
                            result.success(mapOf("sessionId" to id))
                        } catch (t: Throwable) {
                            result.error("native_error", t.message, null)
                        }
                    }
                }
                "generate" -> {
                    val args = call.arguments as? Map<*, *>
                    val sessionId = args?.get("sessionId")?.toString()
                    val prompt = args?.get("prompt")?.toString() ?: ""
                    val maxTokens = (args?.get("maxTokens") as? Int) ?: 1024
                    val session = sessions[sessionId]
                    if (session == null) {
                        result.error("no_session", "Session not found", null)
                        return@setMethodCallHandler
                    }
                    executor.execute {
                        try {
                            val sb = StringBuilder()
                            session.generateStream(prompt, maxTokens) { token ->
                                sb.append(token)
                                true
                            }
                            result.success(sb.toString())
                        } catch (t: Throwable) {
                            result.error("generate_error", t.message, null)
                        }
                    }
                }
                "generateStream" -> {
                    val args = call.arguments as? Map<*, *>
                    val sessionId = args?.get("sessionId")?.toString()
                    val prompt = args?.get("prompt")?.toString() ?: ""
                    val maxTokens = (args?.get("maxTokens") as? Int) ?: 1024
                    val session = sessions[sessionId]
                    if (session == null) {
                        result.error("no_session", "Session not found", null)
                        return@setMethodCallHandler
                    }
                    result.success(true)
                    executor.execute {
                        try {
                            session.generateStream(prompt, maxTokens) { token ->
                                runCatching {
                                    methodChannel?.invokeMethod(
                                        "onToken",
                                        mapOf("sessionId" to sessionId, "token" to token),
                                    )
                                }
                                true
                            }
                            runCatching {
                                methodChannel?.invokeMethod(
                                    "onStreamDone",
                                    mapOf("sessionId" to sessionId),
                                )
                            }
                        } catch (t: Throwable) {
                            runCatching {
                                methodChannel?.invokeMethod(
                                    "onStreamError",
                                    mapOf(
                                        "sessionId" to sessionId,
                                        "error" to (t.message ?: "unknown"),
                                    ),
                                )
                            }
                        }
                    }
                }
                "countTokens" -> {
                    val args = call.arguments as? Map<*, *>
                    val session = sessions[args?.get("sessionId")?.toString()]
                    if (session == null) {
                        result.error("no_session", "Session not found", null)
                        return@setMethodCallHandler
                    }
                    val text = args?.get("text")?.toString() ?: ""
                    result.success(session.countTokens(text))
                }
                "applyChatTemplate" -> {
                    val args = call.arguments as? Map<*, *>
                    val session = sessions[args?.get("sessionId")?.toString()]
                    if (session == null) {
                        result.error("no_session", "Session not found", null)
                        return@setMethodCallHandler
                    }
                    val roles = (args?.get("roles") as? List<*>)
                        ?.mapNotNull { it?.toString() } ?: emptyList()
                    val contents = (args?.get("contents") as? List<*>)
                        ?.mapNotNull { it?.toString() } ?: emptyList()
                    val enableThinking = (args?.get("enableThinking") as? Boolean) ?: false
                    val addAssistant = (args?.get("addAssistant") as? Boolean) ?: true
                    val out = session.applyChatTemplate(roles, contents, enableThinking, addAssistant)
                    result.success(out)
                }
                "cancel" -> {
                    val args = call.arguments as? Map<*, *>
                    sessions[args?.get("sessionId")?.toString()]?.cancel()
                    result.success(true)
                }
                "release" -> {
                    val args = call.arguments as? Map<*, *>
                    val id = args?.get("sessionId")?.toString()
                    prewarmManager.untrackSession(id ?: "")
                    sessions.remove(id)?.release()
                    result.success(true)
                }
                "applyPrewarmConfig" -> {
                    val args = call.arguments as? Map<*, *>
                    val enabled = (args?.get("enabled") as? Boolean) ?: false
                    val bgRelease = (args?.get("bgReleaseModel") as? Boolean) ?: false
                    val warmup = (args?.get("warmupOnCharge") as? Boolean) ?: false
                    prewarmManager.bgReleaseModel = bgRelease
                    prewarmManager.warmupOnCharge = warmup
                    // Setting enabled last registers the component callbacks
                    // only when the feature is actually on.
                    prewarmManager.enabled = enabled
                    result.success(true)
                }
                "onAppBackground" -> {
                    prewarmManager.onAppBackground()
                    result.success(true)
                }
                "onAppForeground" -> {
                    prewarmManager.onAppForeground()
                    result.success(true)
                }
                "readGgufMetadata" -> {
                    val args = call.arguments as? Map<*, *>
                    val path = args?.get("path")?.toString()
                    if (path.isNullOrBlank()) {
                        result.error("invalid_args", "path is required", null)
                        return@setMethodCallHandler
                    }
                    executor.execute {
                        try {
                            val info = ModelInfoReader.read(path)
                            result.success(info?.toMap())
                        } catch (t: Throwable) {
                            // Graceful degradation: return null on any error.
                            result.success(null)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun parseConfig(args: Map<*, *>?): LlamaSession.Config {
        if (args == null) return LlamaSession.Config()
        return LlamaSession.Config(
            nThreads = (args["nThreads"] as? Int) ?: 4,
            nCtx = (args["nCtx"] as? Int) ?: 2048,
            nBatch = (args["nBatch"] as? Int) ?: 512,
            nUBatch = (args["nUBatch"] as? Int) ?: 512,
            nGpuLayers = (args["nGpuLayers"] as? Int) ?: 0,
            useMmap = (args["useMmap"] as? Boolean) ?: false,
            flashAttention = (args["flashAttention"] as? Boolean) ?: false,
            kvUnified = (args["kvUnified"] as? Boolean) ?: true,
            offloadKqv = (args["offloadKqv"] as? Boolean) ?: false,
        )
    }
}

package com.psyche.kelivo.toolpkg

import android.content.Context
import com.psyche.kelivo.quickjs.OperitQuickJsEngine
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.net.URI
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.zip.ZipFile

/**
 * Loads and runs ToolPkg JS bundles inside the transplanted QuickJS sandbox.
 *
 * Only the core loader + built-in execution path is implemented. Operit's full
 * hook system (prompt/message/summary hooks) is intentionally not ported.
 *
 * Permission model: each invocation carries `allowFile` / `allowNetwork` flags.
 * When a flag is false, the corresponding host API throws inside the sandbox.
 */
class ToolPkgPlugin(private val context: Context) {
    companion object {
        const val CHANNEL_NAME = "app.toolpkg"
    }

    private val executor = Executors.newSingleThreadExecutor { r ->
        Thread(r, "kelivo-toolpkg").apply { isDaemon = true }
    }

    private data class InstalledPkg(
        val id: String,
        val displayName: String,
        val description: String,
        val version: String,
        val mainFile: File,
        val dir: File,
        val capabilities: List<String>,
    )

    private val packagesDir: File by lazy {
        File(context.filesDir, "toolpkgs").apply { mkdirs() }
    }
    private val installed = ConcurrentHashMap<String, InstalledPkg>()

    /** In-memory ring buffer of console logs captured from QuickJS sandboxes. */
    private val consoleLogs = java.util.concurrent.ConcurrentLinkedQueue<Map<String, Any?>>()
    private val consoleLogLock = Any()
    private var consoleLogChannel: MethodChannel? = null

    /** Maximum number of retained console log entries. */
    private val maxConsoleLogs = 500

    // ---- Host backend for ToolPkg exec/readFile/writeFile ----
    private val nativeLibDir: File by lazy { File(context.applicationInfo.nativeLibraryDir) }
    private val prootTmpDir: File by lazy { File(context.cacheDir, "toolpkg-proot").apply { mkdirs() } }

    @Volatile
    private var hostBackendId: String = "normal"

    @Volatile
    private var rootfsDir: File? = null

    // ---- Controlled network capability ----
    // Global gate for ToolPkg network access. Even when the manifest declares
    // "network" and the user grants it, this master switch must be on.
    @Volatile
    private var networkEnabled: Boolean = false

    // Comma-separated domain patterns. Supports `*` wildcards (e.g.
    // "*.example.com,github.com"). Empty string means no whitelist = allow all.
    @Volatile
    private var networkWhitelist: String = ""

    private fun currentBackend(): HostBackend = when (hostBackendId) {
        "root" -> RootShellBackend()
        "proot" -> ReuseExistingKelivoProotBackend(nativeLibDir, prootTmpDir, rootfsDir)
        else -> NormalShellBackend()
    }

    init {
        scanInstalled()
    }

    fun configure(messenger: BinaryMessenger) {
        val channel = MethodChannel(messenger, CHANNEL_NAME)
        consoleLogChannel = channel
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "install" -> {
                    val args = call.arguments as? Map<*, *>
                    val zipPath = args?.get("zipPath")?.toString()
                    if (zipPath.isNullOrBlank()) {
                        result.error("invalid_args", "zipPath required", null)
                        return@setMethodCallHandler
                    }
                    executor.execute {
                        try {
                            val pkg = installFromZip(File(zipPath))
                            installed[pkg.id] = pkg
                            result.success(pkg.toMap())
                        } catch (t: Throwable) {
                            result.error("install_error", t.message, null)
                        }
                    }
                }
                "list" -> {
                    result.success(JSONArray(installed.values.map { it.toMap() }).toString())
                }
                "invoke" -> {
                    val args = call.arguments as? Map<*, *>
                    val packageId = args?.get("packageId")?.toString()
                    val function = args?.get("function")?.toString() ?: "main"
                    val fnArgs = args?.get("args")?.toString() ?: "{}"
                    val allowFile = (args?.get("allowFile") as? Boolean) ?: false
                    val allowNetwork = (args?.get("allowNetwork") as? Boolean) ?: false
                    val pkg = installed[packageId]
                    if (pkg == null) {
                        result.error("not_found", "Package not installed: $packageId", null)
                        return@setMethodCallHandler
                    }
                    executor.execute {
                        try {
                            val out = runPackage(pkg, function, fnArgs, allowFile, allowNetwork)
                            result.success(out)
                        } catch (t: Throwable) {
                            result.error("invoke_error", t.message, null)
                        }
                    }
                }
                "evalJs" -> {
                    val args = call.arguments as? Map<*, *>
                    val code = args?.get("code")?.toString() ?: ""
                    val fnArgs = args?.get("args")?.toString() ?: "{}"
                    val allowFile = (args?.get("allowFile") as? Boolean) ?: false
                    val allowNetwork = (args?.get("allowNetwork") as? Boolean) ?: false
                    executor.execute {
                        try {
                            val out = evalSandbox(code, fnArgs, allowFile, allowNetwork)
                            result.success(out)
                        } catch (t: Throwable) {
                            result.error("eval_error", t.message, null)
                        }
                    }
                }
                "uninstall" -> {
                    val args = call.arguments as? Map<*, *>
                    val id = args?.get("packageId")?.toString()
                    val pkg = installed.remove(id)
                    if (pkg != null) pkg.dir.deleteRecursively()
                    result.success(pkg != null)
                }
                "getConsoleLogs" -> {
                    result.success(ArrayList(consoleLogs))
                }
                "clearConsoleLogs" -> {
                    consoleLogs.clear()
                    result.success(true)
                }
                "setHostBackend" -> {
                    val args = call.arguments as? Map<*, *>
                    val id = args?.get("backend")?.toString() ?: "normal"
                    hostBackendId = when (id) {
                        "normal", "root", "proot" -> id
                        else -> "normal"
                    }
                    result.success(true)
                }
                "setRootfsDir" -> {
                    val args = call.arguments as? Map<*, *>
                    val path = args?.get("rootfsDir")?.toString()
                    rootfsDir = if (path.isNullOrBlank()) null else File(path)
                    result.success(true)
                }
                "setNetworkConfig" -> {
                    val args = call.arguments as? Map<*, *>
                    networkEnabled = (args?.get("enabled") as? Boolean) ?: false
                    networkWhitelist = args?.get("whitelist")?.toString() ?: ""
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun scanInstalled() {
        if (!packagesDir.isDirectory) return
        packagesDir.listFiles()?.forEach { dir ->
            if (!dir.isDirectory) return@forEach
            val manifest = File(dir, "manifest.json")
            if (!manifest.exists()) return@forEach
            try {
                val json = JSONObject(manifest.readText())
                val id = json.optString("toolpkg_id")
                val main = json.optString("main")
                if (id.isBlank() || main.isBlank()) return@forEach
                installed[id] = InstalledPkg(
                    id = id,
                    displayName = readLocalized(json, "display_name"),
                    description = readLocalized(json, "description"),
                    version = json.optString("version", "0.0.0"),
                    mainFile = File(dir, main),
                    dir = dir,
                    capabilities = parseCapabilities(json),
                )
            } catch (_: Throwable) {
            }
        }
    }

    private fun installFromZip(zip: File): InstalledPkg {
        val tmp = File(packagesDir, "_incoming_${System.nanoTime()}")
        tmp.mkdirs()
        ZipFile(zip).use { zf ->
            zf.entries().asSequence().forEach { entry ->
                val dest = File(tmp, entry.name)
                if (entry.isDirectory) {
                    dest.mkdirs()
                } else {
                    dest.parentFile?.mkdirs()
                    zf.getInputStream(entry).use { input ->
                        dest.outputStream().use { output -> input.copyTo(output) }
                    }
                }
            }
        }
        val manifest = File(tmp, "manifest.json")
        if (!manifest.exists()) {
            tmp.deleteRecursively()
            error("manifest.json not found in package")
        }
        val json = JSONObject(manifest.readText())
        val id = json.optString("toolpkg_id")
        val main = json.optString("main")
        if (id.isBlank() || main.isBlank()) {
            tmp.deleteRecursively()
            error("manifest missing toolpkg_id or main")
        }
        val dest = File(packagesDir, id)
        if (dest.exists()) dest.deleteRecursively()
        tmp.renameTo(dest)
        return InstalledPkg(
            id = id,
            displayName = readLocalized(json, "display_name"),
            description = readLocalized(json, "description"),
            version = json.optString("version", "0.0.0"),
            mainFile = File(dest, main),
            dir = dest,
            capabilities = parseCapabilities(json),
        )
    }

    private fun runPackage(
        pkg: InstalledPkg,
        function: String,
        argsJson: String,
        allowFile: Boolean,
        allowNetwork: Boolean,
    ): String {
        val code = pkg.mainFile.readText()
        val wrapped = """
            $code
            ;(function(){
              var fn = (typeof $function === 'function') ? $function
                : (typeof exports !== 'undefined' && exports && typeof exports.$function === 'function') ? exports.$function
                : (typeof module !== 'undefined' && module.exports && typeof module.exports.$function === 'function') ? module.exports.$function
                : null;
              if (!fn) { throw new Error('function not found: $function'); }
              var __args = $argsJson;
              var __result = fn(__args);
              if (typeof __result === 'object' && __result !== null) {
                return JSON.stringify(__result);
              }
              return String(__result == null ? '' : __result);
            })()
        """.trimIndent()
        return evalSandbox(wrapped, argsJson, allowFile, allowNetwork)
    }

    private fun evalSandbox(
        code: String,
        argsJson: String,
        allowFile: Boolean,
        allowNetwork: Boolean,
    ): String {
        val engine = OperitQuickJsEngine()
        try {
            engine.setConsoleListener { level, message ->
                appendConsoleLog(level, message)
            }
            engine.bindNativeInterface(
                PermissionGate(
                    allowFile = allowFile,
                    allowNetwork = allowNetwork,
                    backend = currentBackend(),
                    channel = consoleLogChannel,
                    networkEnabled = { networkEnabled },
                    whitelist = { networkWhitelist },
                ),
            )
            // Inject permission flags + a minimal require shim.
            val prelude = """
                var __kelivo_perms = { allowFile: $allowFile, allowNetwork: $allowNetwork };
                var module = { exports: {} };
                var exports = module.exports;
                var __args = $argsJson;
            """.trimIndent()
            val result: Any? = engine.evaluate("$prelude\n$code", "<toolpkg>")
            return if (result == null) "" else result.toString()
        } finally {
            engine.close()
        }
    }

    private fun appendConsoleLog(level: String, message: String) {
        val entry = mapOf(
            "ts" to System.currentTimeMillis(),
            "level" to level,
            "message" to message,
        )
        consoleLogs.add(entry)
        synchronized(consoleLogLock) {
            while (consoleLogs.size > maxConsoleLogs) {
                consoleLogs.poll()
            }
        }
        // Push to Dart in real time so the debug dialog can update live.
        runCatching {
            consoleLogChannel?.invokeMethod(
                "onConsoleLog",
                entry,
            )
        }
    }

    /**
     * Host object exposed to JS. File/network access is gated by the per-call
     * permission flags; when disabled the method throws inside the sandbox.
     *
     * `exec` / `readFile` / `writeFile` delegate to the currently selected
     * [HostBackend] (normal shell, root shell, or Kelivo PRoot).
     *
     * `httpGet` does NOT perform HTTP directly. It bridges the request to the
     * Dart side over [MethodChannel] so the real HTTP client lives in Dart.
     * The call blocks the JS runtime thread until Dart replies.
     */
    private class PermissionGate(
        private val allowFile: Boolean,
        private val allowNetwork: Boolean,
        private val backend: HostBackend,
        private val channel: MethodChannel?,
        private val networkEnabled: () -> Boolean,
        private val whitelist: () -> String,
    ) {
        @Suppress("unused")
        fun readFile(path: String): String {
            if (!allowFile) throw SecurityException("file access disabled")
            return backend.readFile(path)
        }

        @Suppress("unused")
        fun writeFile(path: String, content: String): Boolean {
            if (!allowFile) throw SecurityException("file access disabled")
            return backend.writeFile(path, content)
        }

        @Suppress("unused")
        fun httpGet(url: String): String {
            if (!allowNetwork) throw SecurityException("network access disabled")
            // Master switch: the user must have enabled ToolPkg network access
            // in settings, even if the manifest declares the capability.
            if (!networkEnabled()) {
                throw SecurityException("ToolPkg network access is disabled in settings")
            }
            // Domain whitelist (empty = allow all).
            val wl = whitelist().trim()
            if (wl.isNotEmpty() && !isDomainAllowed(url, wl)) {
                throw SecurityException("domain not allowed by ToolPkg network whitelist")
            }
            val ch = channel ?: throw SecurityException("network bridge unavailable")
            // Bridge to Dart. The QuickJS runtime thread blocks here until the
            // Dart HTTP client returns a response (or errors/times out).
            val latch = CountDownLatch(1)
            var response: String? = null
            var failure: Throwable? = null
            ch.invokeMethod(
                "httpGet",
                mapOf("url" to url),
                object : MethodChannel.Result {
                    override fun success(value: Any?) {
                        response = value?.toString()
                        latch.countDown()
                    }
                    override fun error(code: String, msg: String?, details: Any?) {
                        failure = RuntimeException("HTTP error [$code]: ${msg ?: "unknown"}")
                        latch.countDown()
                    }
                    override fun notImplemented() {
                        failure = RuntimeException("network bridge not implemented on Dart side")
                        latch.countDown()
                    }
                },
            )
            if (!latch.await(30, TimeUnit.SECONDS)) {
                throw RuntimeException("ToolPkg httpGet timed out after 30s")
            }
            failure?.let { throw it }
            return response ?: ""
        }

        @Suppress("unused")
        fun exec(command: String): String {
            // exec is gated by allowFile because it can read/write the host.
            if (!allowFile) throw SecurityException("exec requires file access permission")
            val res = backend.exec(command)
            val json = org.json.JSONObject()
                .put("exitCode", res.exitCode)
                .put("stdout", res.stdout)
                .put("stderr", res.stderr)
                .put("timedOut", res.timedOut)
            return json.toString()
        }

        companion object {
            /** Matches [host] against a comma-separated list of glob patterns. */
            internal fun isDomainAllowed(url: String, whitelist: String): Boolean {
                val host = runCatching { URI(url).host }.getOrNull() ?: return false
                val patterns = whitelist.split(',')
                    .map { it.trim() }
                    .filter { it.isNotEmpty() }
                if (patterns.isEmpty()) return true
                return patterns.any { pattern -> matchGlob(pattern, host) }
            }

            private fun matchGlob(pattern: String, host: String): Boolean {
                if (pattern == host) return true
                if (!pattern.contains('*')) return pattern == host
                // Convert a simple glob (*.example.com) into a regex.
                val regex = buildString {
                    append('^')
                    for (ch in pattern) {
                        when (ch) {
                            '*' -> append("[^.]*")
                            '.' -> append("\\.")
                            else -> append(Regex.escape(ch.toString()))
                        }
                    }
                    append('$')
                }
                return Regex(regex, RegexOption.IGNORE_CASE).matches(host)
            }
        }
    }

    private fun parseCapabilities(json: JSONObject): List<String> {
        val arr = json.optJSONArray("capabilities") ?: return emptyList()
        val out = ArrayList<String>(arr.length())
        for (i in 0 until arr.length()) {
            val v = arr.optString(i)
            if (v.isNotBlank()) out.add(v)
        }
        return out
    }

    private fun readLocalized(json: JSONObject, key: String): String {
        val v = json.opt(key)
        return when (v) {
            is JSONObject -> v.optString("default", v.optString("en", ""))
            is String -> v
            else -> ""
        }
    }

    private fun InstalledPkg.toMap(): Map<String, Any> = mapOf(
        "id" to id,
        "displayName" to displayName,
        "description" to description,
        "version" to version,
        "capabilities" to capabilities,
    )
}

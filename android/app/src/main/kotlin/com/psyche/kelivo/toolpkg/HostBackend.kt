package com.psyche.kelivo.toolpkg

import java.io.File

/**
 * Result of a host-side command execution.
 */
data class HostExecResult(
    val exitCode: Int,
    val stdout: String,
    val stderr: String,
    val timedOut: Boolean,
)

/**
 * Unified host backend abstraction for ToolPkg JS host APIs.
 *
 * Three concrete backends are provided:
 *  * [NormalShellBackend] – runs commands through the device's normal `sh`.
 *  * [RootShellBackend] – runs commands through `su` (requires a rooted
 *    device or a root manager).
 *  * [ReuseExistingKelivoProotBackend] – reuses Kelivo's existing PRoot
 *    implementation (`ProotCommand.build` + `stageTalloc`) so a ToolPkg can
 *    execute inside the user's configured rootfs. No Operit Proot code is
 *    copied.
 *
 * The interface is intentionally small: [exec], [readFile], [writeFile].
 * File reads/writes target the same filesystem view the backend's shell
 * would see (host paths for normal/root, guest paths mapped onto the
 * configured rootfs for PRoot).
 */
interface HostBackend {
    /** Stable identifier used by Dart to select the backend. */
    val id: String

    /** Human-readable name for the settings UI. */
    val displayName: String

    /**
     * Executes [command] and returns the captured output.
     *
     * @param command shell command string
     * @param env environment variables to merge into the process environment
     * @param cwd working directory (guest path for PRoot, host path otherwise)
     * @param timeoutMs maximum wall-clock time; 0 means no limit
     */
    fun exec(
        command: String,
        env: Map<String, String> = emptyMap(),
        cwd: String? = null,
        timeoutMs: Long = 60_000L,
    ): HostExecResult

    /** Reads a text file from the backend's filesystem view. */
    fun readFile(path: String): String

    /** Writes [content] to a text file. Returns true on success. */
    fun writeFile(path: String, content: String): Boolean
}

/** Runs commands via the device's normal non-root shell (`/system/bin/sh`). */
class NormalShellBackend : HostBackend {
    override val id: String = "normal"
    override val displayName: String = "普通 Shell"

    override fun exec(
        command: String,
        env: Map<String, String>,
        cwd: String?,
        timeoutMs: Long,
    ): HostExecResult = runProcess(
        argv = listOf("/system/bin/sh", "-c", command),
        env = env,
        cwd = cwd,
        timeoutMs = timeoutMs,
    )

    override fun readFile(path: String): String = File(path).readText()

    override fun writeFile(path: String, content: String): Boolean = runCatching {
        File(path).apply { parentFile?.mkdirs() }.writeText(content)
        true
    }.getOrDefault(false)
}

/** Runs commands via `su -c`. Requires a rooted device. */
class RootShellBackend : HostBackend {
    override val id: String = "root"
    override val displayName: String = "Root Shell (su)"

    override fun exec(
        command: String,
        env: Map<String, String>,
        cwd: String?,
        timeoutMs: Long,
    ): HostExecResult {
        val full = if (cwd != null) "cd ${shellQuote(cwd)} && $command" else command
        return runProcess(
            argv = listOf("su", "-c", full),
            env = env,
            cwd = null,
            timeoutMs = timeoutMs,
        )
    }

    override fun readFile(path: String): String {
        val res = exec("cat ${shellQuote(path)}")
        if (res.exitCode != 0) error("readFile failed: ${res.stderr.ifBlank { "exit ${res.exitCode}" }}")
        return res.stdout
    }

    override fun writeFile(path: String, content: String): Boolean = runCatching {
        val tmp = File.createTempFile("toolpkg_root_", ".tmp")
        tmp.writeText(content)
        val res = exec("cp ${shellQuote(tmp.absolutePath)} ${shellQuote(path)}")
        tmp.delete()
        res.exitCode == 0
    }.getOrDefault(false)
}

/**
 * Reuses Kelivo's existing PRoot implementation to execute commands inside
 * the user's configured rootfs.
 *
 * This backend delegates argv construction entirely to
 * `com.psyche.kelivo.workspace.ProotCommand.build` and
 * `ProotCommand.stageTalloc`. It does not copy any Operit Proot module.
 */
class ReuseExistingKelivoProotBackend(
    private val nativeLibDir: File,
    private val tmpDir: File,
    rootfsDir: File?,
) : HostBackend {
    override val id: String = "proot"
    override val displayName: String = "PRoot (复用 Kelivo rootfs)"

    @Volatile
    var rootfsDir: File? = rootfsDir

    override fun exec(
        command: String,
        env: Map<String, String>,
        cwd: String?,
        timeoutMs: Long,
    ): HostExecResult {
        val rootfs = rootfsDir
            ?: error("PRoot backend requires a configured rootfs directory")
        if (!rootfs.isDirectory) error("rootfs directory does not exist: ${rootfs.absolutePath}")

        tmpDir.mkdirs()
        // Reuse Kelivo's talloc staging (copies libtalloc.so to its SONAME).
        com.psyche.kelivo.workspace.ProotCommand.stageTalloc(nativeLibDir, tmpDir)

        val launch = com.psyche.kelivo.workspace.ProotCommand.build(
            nativeLibDir = nativeLibDir,
            rootfsDir = rootfs,
            tmpDir = tmpDir,
            binds = emptyList(),
            cwd = cwd?.takeIf { it.isNotBlank() } ?: "/",
            command = command,
            env = env,
        )
        return runProcess(
            argv = launch.argv,
            env = launch.processEnv,
            cwd = launch.workingDirectory.absolutePath,
            timeoutMs = timeoutMs,
        )
    }

    override fun readFile(path: String): String {
        val rootfs = rootfsDir ?: error("PRoot backend requires a configured rootfs")
        val guest = com.psyche.kelivo.workspace.ProotCommand.validateGuestCwd(path)
        val host = File(rootfs, guest.removePrefix("/"))
        return host.readText()
    }

    override fun writeFile(path: String, content: String): Boolean = runCatching {
        val rootfs = rootfsDir ?: error("PRoot backend requires a configured rootfs")
        val guest = com.psyche.kelivo.workspace.ProotCommand.validateGuestCwd(path)
        val host = File(rootfs, guest.removePrefix("/"))
        host.parentFile?.mkdirs()
        host.writeText(content)
        true
    }.getOrDefault(false)
}

// ---- shared process runner -------------------------------------------------

internal fun runProcess(
    argv: List<String>,
    env: Map<String, String>,
    cwd: String?,
    timeoutMs: Long,
): HostExecResult {
    val builder = ProcessBuilder(argv).redirectErrorStream(false)
    cwd?.let { builder.directory(File(it)) }
    if (env.isNotEmpty()) builder.environment().putAll(env)
    val process = builder.start()
    val stdoutBuf = StringBuilder()
    val stderrBuf = StringBuilder()
    val outThread = Thread({ process.inputStream.bufferedReader().useLines { lines ->
        lines.forEach { stdoutBuf.append(it).append('\n') }
    } }, "toolpkg-exec-out").apply { isDaemon = true; start() }
    val errThread = Thread({ process.errorStream.bufferedReader().useLines { lines ->
        lines.forEach { stderrBuf.append(it).append('\n') }
    } }, "toolpkg-exec-err").apply { isDaemon = true; start() }

    val finished = try {
        if (timeoutMs <= 0L) {
            process.waitFor()
            true
        } else {
            process.waitFor(timeoutMs, java.util.concurrent.TimeUnit.MILLISECONDS)
        }
    } catch (_: InterruptedException) {
        Thread.currentThread().interrupt()
        false
    }
    val timedOut = !finished
    if (timedOut) {
        runCatching { process.destroyForcibly() }
    }
    outThread.join(1000)
    errThread.join(1000)

    val exitCode = if (timedOut) -1 else runCatching { process.exitValue() }.getOrDefault(-1)
    return HostExecResult(
        exitCode = exitCode,
        stdout = stdoutBuf.toString(),
        stderr = stderrBuf.toString(),
        timedOut = timedOut,
    )
}

internal fun shellQuote(value: String): String {
    if (value.isEmpty()) return "''"
    if (value.none { it == '\'' || it == '\\' || it.isWhitespace() || it == '"' || it == '$' || it == '`' }) {
        return value
    }
    return "'" + value.replace("'", "'\\''") + "'"
}

package com.psyche.kelivo.llm.llama

import java.io.BufferedInputStream
import java.io.File
import java.io.FileInputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.min

/**
 * Lightweight GGUF header parser.
 *
 * Reads only the metadata section (and the first tensor info for the
 * quantization type) — it never loads model weights. Every step is wrapped
 * in [runCatching] so a corrupt or truncated file degrades to a partial
 * result rather than throwing.
 */
object ModelInfoReader {

    private const val MAGIC = "GGUF"

    /** Metadata value types per the GGUF spec. */
    private const val TYPE_UINT8 = 0
    private const val TYPE_INT8 = 1
    private const val TYPE_UINT16 = 2
    private const val TYPE_INT16 = 3
    private const val TYPE_UINT32 = 4
    private const val TYPE_INT32 = 5
    private const val TYPE_FLOAT32 = 6
    private const val TYPE_BOOL = 7
    private const val TYPE_STRING = 8
    private const val TYPE_ARRAY = 9
    private const val TYPE_UINT64 = 10
    private const val TYPE_INT64 = 11
    private const val TYPE_FLOAT64 = 12

    data class GgufInfo(
        val name: String?,
        val architecture: String?,
        val parameterLabel: String?,
        val quantization: String?,
        val contextLength: Long?,
        val fileSizeBytes: Long,
        /** Non-null when the quick integrity check found a potential problem. */
        val integrityWarning: String?,
    ) {
        fun toMap(): Map<String, Any?> = mapOf(
            "name" to name,
            "architecture" to architecture,
            "parameterLabel" to parameterLabel,
            "quantization" to quantization,
            "contextLength" to contextLength,
            "fileSizeBytes" to fileSizeBytes,
            "integrityWarning" to integrityWarning,
        )
    }

    /**
     * Parses the GGUF header at [path] and returns the extracted metadata.
     * Returns null if the file is not a valid GGUF file.
     */
    fun read(path: String): GgufInfo? {
        val file = File(path)
        if (!file.exists() || !file.isFile) return null
        val fileSize = file.length()

        return runCatching {
            BufferedInputStream(FileInputStream(file), 64 * 1024).use { input ->
                val header = ByteArray(24)
                if (input.read(header) != 24) return null
                val buf = ByteBuffer.wrap(header).order(ByteOrder.LITTLE_ENDIAN)

                val magic = String(header, 0, 4, Charsets.US_ASCII)
                if (magic != MAGIC) return null

                @Suppress("UNUSED_VARIABLE")
                val version = buf.int
                val tensorCount = buf.long
                val metadataCount = buf.long
                if (metadataCount < 0 || metadataCount > 1_000_000) return null

                // ---- Quick integrity check (no full sha256) ----
                val warning = quickIntegrityCheck(fileSize, version, tensorCount, metadataCount)

                val metadata = HashMap<String, Any?>(metadataCount.toInt())
                repeat(metadataCount.toInt()) {
                    val key = readString(input) ?: return null
                    val value = readValue(input) ?: return null
                    metadata[key] = value
                }

                val name = metadata["general.name"] as? String
                val arch = metadata["general.architecture"] as? String
                val sizeLabel = metadata["general.size_label"] as? String

                val ctxKey = if (arch != null) "$arch.context_length" else null
                val contextLength = ctxKey?.let { metadata[it] } as? Long
                    ?: (metadata["general.context_length"] as? Long)

                // Read the first tensor info to determine quantization format.
                val quant = readFirstTensorType(input)?.let(::tensorTypeName)

                val paramLabel = sizeLabel ?: estimateParameterLabel(metadata)

                GgufInfo(
                    name = name,
                    architecture = arch,
                    parameterLabel = paramLabel,
                    quantization = quant,
                    contextLength = contextLength,
                    fileSizeBytes = fileSize,
                    integrityWarning = warning,
                )
            }
        }.getOrNull()
    }

    /**
     * Lightweight, fast integrity checks. Returns a human-readable warning
     * string when something looks off, or null when the file appears healthy.
     *
     * Checks performed:
     *  * File is at least large enough to hold the fixed header (24 bytes).
     *  * GGUF version is within the supported range (2..4).
     *  * tensorCount / metadataCount are non-negative and not absurdly large.
     *  * The file is not suspiciously small for the claimed tensor count.
     *
     * This is intentionally NOT a cryptographic check; it catches truncation,
     * wrong magic, and obviously bogus headers.
     */
    private fun quickIntegrityCheck(
        fileSize: Long,
        version: Int,
        tensorCount: Long,
        metadataCount: Long,
    ): String? {
        if (fileSize < 24) return "文件过小，无法容纳 GGUF 头部"
        if (version < 2 || version > 4) {
            return "不支持的 GGUF 版本: $version"
        }
        if (tensorCount < 0) return "tensor 数量为负，文件可能损坏"
        if (tensorCount > 10_000_000) return "tensor 数量异常大 (${tensorCount})，文件可能损坏"
        if (metadataCount < 0) return "metadata 数量为负，文件可能损坏"
        // A real model has tensors; an empty GGUF with many metadata entries
        // but zero tensors is suspicious (though valid for some container files).
        if (tensorCount == 0L && fileSize < 1024) {
            return "未检测到 tensor 数据，文件可能不完整或仅包含元数据"
        }
        // If the file claims many tensors but is tiny, it's almost certainly
        // truncated. Each tensor info entry is at least ~30 bytes.
        val minHeaderForTensors = 24L + tensorCount * 30L
        if (fileSize < minHeaderForTensors) {
            return "文件大小 (${fileSize}B) 小于 tensor 信息区所需最小大小，可能已截断"
        }
        return null
    }

    // ---- low-level readers ------------------------------------------------

    private fun readString(input: BufferedInputStream): String? = runCatching {
        val len = readLong(input) ?: return null
        if (len < 0 || len > 1024 * 1024) return null
        val bytes = ByteArray(len.toInt())
        var read = 0
        while (read < bytes.size) {
            val n = input.read(bytes, read, bytes.size - read)
            if (n <= 0) return null
            read += n
        }
        String(bytes, Charsets.UTF_8)
    }.getOrNull()

    private fun readValue(input: BufferedInputStream): Any? = runCatching {
        val type = readInt(input) ?: return null
        when (type) {
            TYPE_UINT8 -> readBytes(input, 1)?.get(0)?.toInt()?.and(0xFF)?.toLong()
            TYPE_INT8 -> readBytes(input, 1)?.get(0)?.toLong()
            TYPE_UINT16 -> readBytes(input, 2)?.let { bb(it).short.toInt().and(0xFFFF).toLong() }
            TYPE_INT16 -> readBytes(input, 2)?.let { bb(it).short.toLong() }
            TYPE_UINT32 -> readBytes(input, 4)?.let { bb(it).int.toLong().and(0xFFFFFFFFL) }
            TYPE_INT32 -> readBytes(input, 4)?.let { bb(it).int.toLong() }
            TYPE_UINT64 -> readLong(input)
            TYPE_INT64 -> readLong(input)
            TYPE_FLOAT32 -> readBytes(input, 4)?.let { bb(it).float }
            TYPE_FLOAT64 -> readBytes(input, 8)?.let { bb(it).double }
            TYPE_BOOL -> readBytes(input, 1)?.let { it[0].toInt() != 0 }
            TYPE_STRING -> readString(input)
            TYPE_ARRAY -> {
                // Arrays are not needed for the metadata we extract; skip.
                val elemType = readInt(input) ?: return null
                val count = readLong(input) ?: return null
                skipArray(input, elemType, count)
                null
            }
            else -> null
        }
    }.getOrNull()

    private fun skipArray(input: BufferedInputStream, elemType: Int, count: Long) {
        if (count <= 0) return
        val elemSize = fixedSize(elemType)
        if (elemSize > 0) {
            val toSkip = min(count * elemSize, 1024L * 1024 * 1024)
            input.skip(toSkip)
            return
        }
        // Variable-length elements (string / nested array): read and discard.
        repeat(min(count, 100_000L).toInt()) {
            when (elemType) {
                TYPE_STRING -> readString(input)
                TYPE_ARRAY -> {
                    val t = readInt(input) ?: return
                    val c = readLong(input) ?: return
                    skipArray(input, t, c)
                }
                else -> readValue(input)
            }
        }
    }

    private fun fixedSize(type: Int): Int = when (type) {
        TYPE_UINT8, TYPE_INT8, TYPE_BOOL -> 1
        TYPE_UINT16, TYPE_INT16 -> 2
        TYPE_UINT32, TYPE_INT32, TYPE_FLOAT32 -> 4
        TYPE_UINT64, TYPE_INT64, TYPE_FLOAT64 -> 8
        else -> 0
    }

    private fun readFirstTensorType(input: BufferedInputStream): Int? = runCatching {
        // Tensor info: name (string) | n_dims (uint32) | shape (n_dims * uint64) | type (uint32) | offset (uint64)
        readString(input) ?: return null
        val nDims = readInt(input) ?: return null
        if (nDims < 0 || nDims > 16) return null
        repeat(nDims) { readLong(input) ?: return null }
        val type = readInt(input) ?: return null
        // We don't need the offset; return the type.
        type
    }.getOrNull()

    // ---- helpers ----------------------------------------------------------

    private fun bb(bytes: ByteArray): ByteBuffer =
        ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)

    private fun readBytes(input: BufferedInputStream, n: Int): ByteArray? {
        val bytes = ByteArray(n)
        var read = 0
        while (read < n) {
            val r = input.read(bytes, read, n - read)
            if (r <= 0) return null
            read += r
        }
        return bytes
    }

    private fun readInt(input: BufferedInputStream): Int? {
        val bytes = readBytes(input, 4) ?: return null
        return bb(bytes).int
    }

    private fun readLong(input: BufferedInputStream): Long? {
        val bytes = readBytes(input, 8) ?: return null
        return bb(bytes).long
    }

    private fun estimateParameterLabel(metadata: Map<String, Any?>): String? {
        // Most GGUF files expose general.size_label; if absent we fall back to
        // looking for a tensor count hint. Without scanning tensors we cannot
        // compute the exact parameter count, so we simply return null.
        return metadata["general.size_label"] as? String
    }

    private fun tensorTypeName(type: Int): String = when (type) {
        0 -> "F32"
        1 -> "F16"
        2 -> "Q4_0"
        3 -> "Q4_1"
        6 -> "Q5_0"
        7 -> "Q5_1"
        8 -> "Q8_0"
        9 -> "Q8_1"
        10 -> "Q2_K"
        11 -> "Q3_K_S"
        12 -> "Q3_K_M"
        13 -> "Q3_K_L"
        14 -> "Q4_K_S"
        15 -> "Q4_K_M"
        16 -> "Q5_K_S"
        17 -> "Q5_K_M"
        18 -> "Q6_K"
        19 -> "Q8_K"
        20 -> "IQ2_XXS"
        21 -> "IQ2_XS"
        22 -> "IQ3_XXS"
        23 -> "IQ1_S"
        24 -> "IQ4_NL"
        25 -> "IQ3_S"
        26 -> "IQ2_S"
        27 -> "IQ4_XS"
        28 -> "I8"
        29 -> "I16"
        30 -> "I32"
        31 -> "I64"
        32 -> "F64"
        33 -> "IQ1_M"
        34 -> "BF16"
        35 -> "Q4_0_4K"
        36 -> "Q4_0_8K"
        37 -> "Q4_1_4K"
        38 -> "Q4_1_8K"
        39 -> "TQ1_0"
        40 -> "TQ2_0"
        else -> "TYPE_$type"
    }
}

package com.pathors.parley.upload

/**
 * How a recording's audio goes up: one `PUT`, or a multipart upload in parts.
 *
 * Cloudflare's edge answers any request body over 100 MB with its own HTML 413
 * before the Worker runs. Live recordings are Ogg/Opus at ~24 kbps, about
 * 10.8 MB an hour, so a meeting past roughly nine hours could never be uploaded
 * in one piece — and because the audio goes up before the meta, nothing of it
 * reached the cloud at all (#755: a ~14 h meeting, ~150 MB). Files over
 * [thresholdBytes] use the multipart API instead, in parts of [partSizeBytes]
 * (the last one shorter).
 *
 * The defaults are the server's contract (parley-internal
 * `recordingsMultipart.ts`): parts of 32 MiB, at most 64 MiB each, at least
 * 5 MiB for every part but the last. They are parameters only so the tests can
 * plan a 300-byte file the same way the app plans a 150 MB one.
 */
data class AudioUploadPlan(
    /** Above this many bytes the audio goes up in parts. */
    val thresholdBytes: Long = DEFAULT_THRESHOLD_BYTES,
    /** The part size to use when the server does not name a usable one. */
    val partSizeBytes: Long = DEFAULT_PART_SIZE_BYTES,
    /** The smallest non-trailing part the server's storage accepts. */
    val minPartSizeBytes: Long = MIN_PART_SIZE_BYTES,
    /** The largest part the server accepts. */
    val maxPartSizeBytes: Long = MAX_PART_SIZE_BYTES,
) {
    init {
        require(minPartSizeBytes in 1..maxPartSizeBytes) { "bad part size bounds" }
        require(partSizeBytes in minPartSizeBytes..maxPartSizeBytes) { "default part size out of bounds" }
        require(thresholdBytes >= 0) { "threshold must not be negative" }
    }

    /** One part: 1-based [number], and the byte range `[offset, offset + length)` of the file. */
    data class Part(val number: Int, val offset: Long, val length: Long)

    /** Whether a file of [sizeBytes] goes up in parts. Exactly [thresholdBytes] still fits one PUT. */
    fun usesMultipart(sizeBytes: Long): Boolean = sizeBytes > thresholdBytes

    /**
     * The part size to use given what the server answered: its own when it is
     * one the server could accept, ours otherwise — a nonsense value must not
     * turn into ten thousand parts or one oversized one.
     */
    fun partSizeFor(serverPartSize: Long?): Long =
        serverPartSize?.takeIf { it in minPartSizeBytes..maxPartSizeBytes } ?: partSizeBytes

    /**
     * The parts of a file of [sizeBytes]: every one [partSize] long except the
     * last, which holds the remainder. An empty file has no parts.
     */
    fun parts(sizeBytes: Long, partSize: Long = partSizeBytes): List<Part> {
        require(sizeBytes >= 0) { "size must not be negative (got $sizeBytes)" }
        require(partSize > 0) { "part size must be positive (got $partSize)" }
        val count = (sizeBytes + partSize - 1) / partSize
        require(count <= MAX_PARTS) { "$sizeBytes bytes needs $count parts; the server takes $MAX_PARTS" }
        return (0 until count).map { index ->
            val offset = index * partSize
            Part(number = index.toInt() + 1, offset = offset, length = minOf(partSize, sizeBytes - offset))
        }
    }

    companion object {
        private const val MIB = 1024L * 1024L

        /** 64 MiB: comfortably under the edge's 100 MB, and the server's largest part. */
        const val DEFAULT_THRESHOLD_BYTES = 64L * MIB

        /** 32 MiB, what the server's `partSize` says. */
        const val DEFAULT_PART_SIZE_BYTES = 32L * MIB

        /** R2's floor for a non-trailing part. */
        const val MIN_PART_SIZE_BYTES = 5L * MIB

        /** The server's `MAX_PART_BYTES`. */
        const val MAX_PART_SIZE_BYTES = 64L * MIB

        /** R2 / S3 part number ceiling. */
        const val MAX_PARTS = 10_000L
    }
}

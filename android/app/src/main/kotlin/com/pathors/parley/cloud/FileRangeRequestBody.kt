package com.pathors.parley.cloud

import java.io.EOFException
import java.io.File
import java.io.RandomAccessFile
import java.nio.channels.Channels
import okhttp3.MediaType
import okhttp3.RequestBody
import okio.BufferedSink
import okio.source

/**
 * The bytes `[offset, offset + length)` of [file] as a request body, read from
 * disk as they are written to the socket — one multipart part of a recording
 * that may be 150 MB, without ever holding more than OkHttp's own buffer.
 *
 * [contentLength] is exact, so OkHttp sends `Content-Length` (the server
 * refuses a part without one). Not one-shot: every [writeTo] seeks to [offset]
 * again, so OkHttp may replay it on a retried connection. A file that turns
 * out shorter than the range throws [EOFException] rather than sending a short
 * body under a long `Content-Length`.
 */
class FileRangeRequestBody(
    private val file: File,
    private val offset: Long,
    private val length: Long,
    private val contentType: MediaType?,
) : RequestBody() {
    init {
        require(offset >= 0) { "offset must not be negative (got $offset)" }
        require(length >= 0) { "length must not be negative (got $length)" }
    }

    override fun contentType(): MediaType? = contentType

    override fun contentLength(): Long = length

    override fun writeTo(sink: BufferedSink) {
        RandomAccessFile(file, "r").use { raf ->
            val channel = raf.channel
            if (channel.size() < offset + length) {
                throw EOFException("${file.name} is ${channel.size()} bytes; part wants $offset+$length")
            }
            channel.position(offset)
            Channels.newInputStream(channel).source().use { source -> sink.write(source, length) }
        }
    }
}

package com.pathors.parley.upload

import com.pathors.parley.cloud.CloudClient
import com.pathors.parley.cloud.CloudJson
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

private const val REC = "rec-755"

/** The scaled-down plan: over 100 bytes goes up in 40-byte parts. */
private val SMALL_PLAN = AudioUploadPlan(
    thresholdBytes = 100,
    partSizeBytes = 40,
    minPartSizeBytes = 1,
    maxPartSizeBytes = 80,
)

/** 250 bytes → six 40-byte parts and a 10-byte seventh. */
private const val BIG_SIZE = 250
private const val PARTS = 7

/**
 * The upload of a recording too big for one PUT (#755): a ~14 h meeting is
 * ~150 MB, the edge refuses anything over 100 MB, and since the audio goes up
 * before the meta, nothing of the meeting ever reached the cloud. The same flow
 * here at a scale a unit test can carry ([SMALL_PLAN]), against a fake server
 * that speaks the multipart contract.
 */
class MeetingUploaderMultipartTest {

    @get:Rule
    val temporary = TemporaryFolder()

    private val server = MockWebServer()

    /** Every request, in order, with its body bytes. */
    private val requests = CopyOnWriteArrayList<Recorded>()

    private data class Recorded(val method: String, val path: String, val body: ByteArray, val contentLength: String?)

    /** Upload ids the fake has handed out; the last is the live one. */
    private val uploadIds = CopyOnWriteArrayList<String>()

    /**
     * A hook that may answer a request instead of the happy path: return a
     * response to fail it, null to let it through.
     */
    @Volatile
    private var intercept: (RecordedRequest, Int) -> MockResponse? = { _, _ -> null }

    private val calls = AtomicInteger()

    @Before
    fun setUp() {
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val body = request.body.readByteArray()
                val path = request.path.orEmpty()
                requests += Recorded(request.method.orEmpty(), path, body, request.getHeader("Content-Length"))
                intercept(request, calls.incrementAndGet())?.let { return it }
                return happyPath(request.method.orEmpty(), path)
            }
        }
        server.start()
    }

    @After
    fun tearDown() {
        server.shutdown()
    }

    private fun happyPath(method: String, path: String): MockResponse {
        val segments = path.substringBefore('?').trim('/').split('/')
        return when {
            method == "POST" && path.endsWith("/audio/multipart") -> {
                val id = "up-${uploadIds.size + 1}"
                uploadIds += id
                json("""{"uploadId":"$id","partSize":40}""")
            }
            method == "PUT" && segments.size == 6 && segments[3] == "multipart" -> {
                val uploadId = segments[4]
                val number = segments[5].toInt()
                if (uploadId != uploadIds.lastOrNull()) {
                    json("""{"error":"no_such_upload"}""", 404)
                } else {
                    json("""{"partNumber":$number,"etag":"etag-$uploadId-$number"}""")
                }
            }
            method == "POST" && path.endsWith("/complete") -> json("""{"ok":true,"size":$BIG_SIZE}""")
            method == "PUT" && path.endsWith("/audio") -> json("{}")
            method == "POST" && path == "/recordings/$REC" -> json("""{"ok":true,"updatedAt":1}""")
            // A retried push re-reads the meta first; the cloud has none yet.
            method == "GET" && path == "/recordings/$REC/meta" -> json("""{"error":"not_found"}""", 404)
            else -> json("""{"error":"unexpected $method $path"}""", 500)
        }
    }

    private fun json(body: String, status: Int = 200) =
        MockResponse().setResponseCode(status).setBody(body)

    private val audioBytes = ByteArray(BIG_SIZE) { (it % 251).toByte() }

    private fun queue(size: Int = BIG_SIZE): PendingUploadQueue {
        val queue = PendingUploadQueue(temporary.newFolder("PendingUploads"))
        val source = temporary.newFile("$REC.ogg").apply { writeBytes(audioBytes.copyOf(size)) }
        queue.enqueue(PendingUpload(id = REC, title = REC, startedAtMs = 1_700_000_000_000, durationMs = 60_000.0), source)
        return queue
    }

    private fun uploader(queue: PendingUploadQueue) = MeetingUploader(
        cloud = CloudClient(baseUrl = server.url("/").toString(), tokenProvider = { "token" }),
        queue = queue,
        retryDelay = {},
        audioPlan = SMALL_PLAN,
    )

    private fun partRequests() = requests.filter { it.method == "PUT" && "/multipart/" in it.path }

    private fun partNumberOf(r: Recorded) = r.path.substringAfterLast('/').toInt()

    // ── the happy path ───────────────────────────────────────────────────────

    @Test
    fun `a file over the threshold goes up in parts, then complete, then the meta`() = runBlocking {
        val queue = queue()

        val result = uploader(queue).drain()

        assertEquals(setOf(REC), result.uploadedIds)
        assertEquals(0, result.remaining)
        assertFalse("never the single PUT the edge would refuse", requests.any { it.path == "/recordings/$REC/audio" })

        val parts = partRequests()
        assertEquals((1..PARTS).toList(), parts.map(::partNumberOf))
        parts.forEachIndexed { index, part ->
            val offset = index * 40
            val expected = audioBytes.copyOfRange(offset, minOf(offset + 40, BIG_SIZE))
            assertArrayEquals("part ${index + 1} is its slice of the file", expected, part.body)
            assertEquals(expected.size.toString(), part.contentLength)
            assertEquals("/recordings/$REC/audio/multipart/up-1/${index + 1}", part.path)
        }

        val methods = requests.map { "${it.method} ${it.path}" }
        assertEquals("POST /recordings/$REC/audio/multipart", methods.first())
        val completeAt = methods.indexOf("POST /recordings/$REC/audio/multipart/up-1/complete")
        val metaAt = methods.indexOf("POST /recordings/$REC")
        assertTrue("complete after every part", completeAt > methods.indexOfLast { it.startsWith("PUT") })
        assertTrue("the meta only once the audio is whole", metaAt > completeAt)

        val complete = CloudJson.parseToJsonElement(requests[completeAt].body.decodeToString()).jsonObject
        val sent = complete.getValue("parts").jsonArray.map { it.jsonObject }
        assertEquals((1..PARTS).toList(), sent.map { it.getValue("partNumber").jsonPrimitive.int })
        assertEquals(
            (1..PARTS).map { "etag-up-1-$it" },
            sent.map { it.getValue("etag").jsonPrimitive.content },
        )
    }

    @Test
    fun `a file at or under the threshold keeps the single PUT`() = runBlocking {
        val queue = queue(size = 100)

        val result = uploader(queue).drain()

        assertEquals(setOf(REC), result.uploadedIds)
        assertEquals(
            listOf("PUT /recordings/$REC/audio", "POST /recordings/$REC"),
            requests.map { "${it.method} ${it.path}" },
        )
        assertEquals(100, requests.first().body.size)
    }

    // ── failures ─────────────────────────────────────────────────────────────

    @Test
    fun `a part cut short (408) is sent again, and only that part`() = runBlocking {
        val queue = queue()
        var failed = false
        intercept = { request, _ ->
            if (!failed && request.method == "PUT" && request.path!!.endsWith("/up-1/3")) {
                failed = true
                json("""{"error":"incomplete_body"}""", 408)
            } else {
                null
            }
        }

        val result = uploader(queue).drain()

        assertEquals(setOf(REC), result.uploadedIds)
        assertEquals(listOf(1, 2, 3, 3, 4, 5, 6, 7), partRequests().map(::partNumberOf))
        assertEquals("one upload, not a restart", listOf("up-1"), uploadIds)
    }

    @Test
    fun `an upload id the server lost starts a new upload from part one`() = runBlocking {
        val queue = queue()
        var lost = false
        intercept = { request, _ ->
            if (!lost && request.method == "PUT" && request.path!!.endsWith("/up-1/4")) {
                lost = true
                json("""{"error":"no_such_upload"}""", 404)
            } else {
                null
            }
        }

        val result = uploader(queue).drain()

        assertEquals(setOf(REC), result.uploadedIds)
        assertEquals(listOf("up-1", "up-2"), uploadIds)
        val second = partRequests().filter { "/up-2/" in it.path }
        assertEquals((1..PARTS).toList(), second.map(::partNumberOf))
        assertTrue(requests.any { it.path == "/recordings/$REC/audio/multipart/up-2/complete" })
    }

    @Test
    fun `invalid parts at complete aborts and starts over once`() = runBlocking {
        val queue = queue()
        var refused = false
        intercept = { request, _ ->
            if (!refused && request.path!!.endsWith("/up-1/complete")) {
                refused = true
                json("""{"error":"invalid_parts"}""", 400)
            } else if (request.method == "DELETE") {
                json("""{"ok":true}""")
            } else {
                null
            }
        }

        val result = uploader(queue).drain()

        assertEquals(setOf(REC), result.uploadedIds)
        assertTrue(requests.any { it.method == "DELETE" && it.path == "/recordings/$REC/audio/multipart/up-1" })
        assertEquals(listOf("up-1", "up-2"), uploadIds)
    }

    @Test
    fun `a recording deleted elsewhere (410) is parked like the single PUT's 410`() = runBlocking {
        val queue = queue()
        intercept = { request, _ ->
            if (request.method == "PUT" && request.path!!.endsWith("/2")) json("""{"error":"gone"}""", 410) else null
        }

        val result = uploader(queue).drain()

        assertTrue(result.uploadedIds.isEmpty())
        assertEquals(1, result.parked)
        assertEquals(410, queue.list().single().parked?.httpStatus)
        assertEquals(BIG_SIZE.toLong(), queue.audioFile(REC).length())
        assertFalse("no meta for audio that never completed", requests.any { it.path == "/recordings/$REC" })
    }

    @Test
    fun `a pass stopped by a failing part resumes the same upload on the next drain`() = runBlocking {
        val queue = queue()
        val uploader = uploader(queue)
        intercept = { request, _ ->
            if (request.method == "PUT" && request.path!!.endsWith("/up-1/5")) json("{}", 503) else null
        }

        val first = uploader.drain()
        assertTrue(first.uploadedIds.isEmpty())
        assertEquals(1, first.remaining)
        assertEquals("still pending, not parked: the server recovers", 0, first.parked)

        requests.clear()
        intercept = { _, _ -> null }
        val second = uploader.drain()

        assertEquals(setOf(REC), second.uploadedIds)
        assertEquals("no new upload", listOf("up-1"), uploadIds)
        assertEquals("only the parts that never went up", listOf(5, 6, 7), partRequests().map(::partNumberOf))
    }

    @Test
    fun `a meta push that fails after the audio completed does not send the audio again`() = runBlocking {
        val queue = queue()
        var metaFailures = 0
        intercept = { request, _ ->
            if (request.method == "POST" && request.path == "/recordings/$REC" && metaFailures++ == 0) {
                json("{}", 503)
            } else {
                null
            }
        }

        val result = uploader(queue).drain()

        assertEquals(setOf(REC), result.uploadedIds)
        assertEquals("the parts went up once", PARTS, partRequests().size)
        assertEquals(1, requests.count { it.path.endsWith("/complete") })
    }
}

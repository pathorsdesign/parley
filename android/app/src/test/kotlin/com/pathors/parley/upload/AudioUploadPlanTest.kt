package com.pathors.parley.upload

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

private const val MIB = 1024L * 1024L

/**
 * How the audio of a recording is split for the multipart upload (#755). The
 * defaults are the server's contract: over 64 MiB goes up in 32 MiB parts.
 */
class AudioUploadPlanTest {

    private val plan = AudioUploadPlan()

    /** Every byte covered exactly once, in order, with 1-based numbers. */
    private fun assertCovers(size: Long, parts: List<AudioUploadPlan.Part>) {
        var next = 0L
        parts.forEachIndexed { index, part ->
            assertEquals(index + 1, part.number)
            assertEquals(next, part.offset)
            assertTrue(part.length > 0)
            next += part.length
        }
        assertEquals(size, next)
    }

    @Test
    fun `an empty file has no parts`() {
        assertEquals(emptyList<AudioUploadPlan.Part>(), plan.parts(0))
    }

    @Test
    fun `one byte is one part`() {
        assertEquals(listOf(AudioUploadPlan.Part(1, 0, 1)), plan.parts(1))
    }

    @Test
    fun `exactly one part size is one full part, one byte more adds a one-byte part`() {
        assertEquals(listOf(AudioUploadPlan.Part(1, 0, 32 * MIB)), plan.parts(32 * MIB))
        assertEquals(
            listOf(AudioUploadPlan.Part(1, 0, 32 * MIB), AudioUploadPlan.Part(2, 32 * MIB, 1)),
            plan.parts(32 * MIB + 1),
        )
    }

    @Test
    fun `the 14-hour meeting - 150 MB - is four full parts and a short fifth`() {
        val size = 150_000_000L
        val parts = plan.parts(size)

        assertEquals(5, parts.size)
        parts.dropLast(1).forEach { assertEquals(32 * MIB, it.length) }
        assertEquals(size - 4 * 32 * MIB, parts.last().length)
        assertEquals(4 * 32 * MIB, parts.last().offset)
        assertCovers(size, parts)
    }

    @Test
    fun `the threshold - exactly 64 MiB still fits one PUT`() {
        assertFalse(plan.usesMultipart(0))
        assertFalse(plan.usesMultipart(64 * MIB))
        assertTrue(plan.usesMultipart(64 * MIB + 1))
        assertTrue(plan.usesMultipart(150_000_000L))
        // And above the threshold, two parts at the least.
        assertEquals(3, plan.parts(64 * MIB + 1).size)
    }

    @Test
    fun `the server's part size is used only when the server could accept it`() {
        assertEquals(32 * MIB, plan.partSizeFor(32 * MIB))
        assertEquals(16 * MIB, plan.partSizeFor(16 * MIB))
        assertEquals(32 * MIB, plan.partSizeFor(null))
        assertEquals("under R2's 5 MiB floor", 32 * MIB, plan.partSizeFor(MIB))
        assertEquals("over the server's 64 MiB ceiling", 32 * MIB, plan.partSizeFor(65 * MIB))
        assertEquals(32 * MIB, plan.partSizeFor(0))
    }

    @Test
    fun `a size that is not a multiple of the part size is covered exactly`() {
        listOf(7L, 100L, 101L, 999L).forEach { size ->
            assertCovers(size, plan.parts(size, partSize = 10))
        }
    }
}

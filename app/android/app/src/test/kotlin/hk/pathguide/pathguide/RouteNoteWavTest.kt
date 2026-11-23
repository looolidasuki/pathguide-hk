package hk.pathguide.pathguide

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** WAV 須通過 Dart RouteAudioNote.fromBytes 的每一項檢查（此處逐項重寫）。 */
class RouteNoteWavTest {
    private fun dartAccepts(bytes: ByteArray): Boolean {
        if (bytes.size < 46 || bytes.size > 1024 * 1024) return false
        val h = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        val be = ByteBuffer.wrap(bytes).order(ByteOrder.BIG_ENDIAN)
        val rate = h.getInt(24)
        val payload = bytes.size - 44
        return be.getInt(0) == 0x52494646 && be.getInt(8) == 0x57415645 &&
            be.getInt(12) == 0x666d7420 && be.getInt(36) == 0x64617461 &&
            h.getInt(4) == bytes.size - 8 && h.getInt(16) == 16 &&
            h.getShort(20).toInt() == 1 && h.getShort(22).toInt() == 1 &&
            h.getShort(32).toInt() == 2 && h.getShort(34).toInt() == 16 &&
            rate in 8000..96000 && h.getInt(28) == rate * 2 && h.getInt(40) == payload &&
            payload % 2 == 0 && payload >= rate / 2 && payload <= rate * 2 * 10
    }

    @Test
    fun oneSecondAt16kRoundTripsAndPassesTheDartContract() {
        val samples = ShortArray(16000) { ((it % 200) - 100).toShort() }
        val wav = RouteNoteWav.encode(samples, samples.size, 16000)!!
        assertEquals(44 + 32000, wav.size)
        assert(dartAccepts(wav))
        val pcm = RouteNoteWav.decode(wav)!!
        assertEquals(16000, pcm.rate)
        assertArrayEquals(samples, pcm.samples)
        assertEquals(1000L, pcm.durationMs)
    }

    @Test
    fun underAQuarterSecondIsTooShort() {
        assertNull(RouteNoteWav.encode(ShortArray(3999), 3999, 16000))
        assertNotNull(RouteNoteWav.encode(ShortArray(4000), 4000, 16000))
    }

    @Test
    fun recordingIsCappedAtTenSecondsAndOneMebibyte() {
        assertEquals(160000, RouteNoteWav.sampleLimit(16000))
        assertEquals((1024 * 1024 - 44) / 2, RouteNoteWav.sampleLimit(96000))
        val wav = RouteNoteWav.encode(ShortArray(200000), 200000, 16000)!!
        assertEquals(44 + 320000, wav.size)
        assert(dartAccepts(wav))
    }

    @Test
    fun decodeRejectsWrongFormatsAndSizes() {
        val good = RouteNoteWav.encode(ShortArray(8000), 8000, 16000)!!
        val stereo = good.copyOf().also { it[22] = 2 }
        val badRiff = good.copyOf().also { it[0] = 'X'.code.toByte() }
        assertNull(RouteNoteWav.decode(stereo))
        assertNull(RouteNoteWav.decode(badRiff))
        assertNull(RouteNoteWav.decode(good.copyOf(good.size - 2)))
        assertNotNull(RouteNoteWav.decode(good))
    }
}

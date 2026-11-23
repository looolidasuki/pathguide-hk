package hk.pathguide.pathguide

import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * 路標錄音備註的 WAV 編碼／解析（純 Kotlin，可在 JVM 測試）。
 *
 * 格式與 iOS RouteNoteRecording 及 Dart RouteAudioNote.fromBytes 一致：
 * 44 位元組標頭、PCM（format 1）、單聲道、16-bit、8–96 kHz；
 * 至少 0.25 秒（取樣數 ≥ (rate+3)/4），最多 10 秒且整檔 ≤ 1 MiB。
 */
object RouteNoteWav {
    const val MAX_SECONDS = 10
    const val MAX_BYTES = 1024 * 1024
    const val HEADER = 44

    /** 該取樣率下最多可存的取樣數（秒數與位元組上限取較小者）。 */
    fun sampleLimit(rate: Int): Int = minOf(rate * MAX_SECONDS, (MAX_BYTES - HEADER) / 2)

    /** 取樣不足 0.25 秒時回傳 null（對應 iOS 的 too_short）。 */
    fun encode(samples: ShortArray, count: Int, rate: Int): ByteArray? {
        require(rate in 8000..96000)
        val n = minOf(count, sampleLimit(rate))
        if (n < (rate + 3) / 4) return null
        val payload = n * 2
        val buf = ByteBuffer.allocate(HEADER + payload).order(ByteOrder.LITTLE_ENDIAN)
        buf.put("RIFF".toByteArray(Charsets.US_ASCII)).putInt(payload + 36)
        buf.put("WAVE".toByteArray(Charsets.US_ASCII))
        buf.put("fmt ".toByteArray(Charsets.US_ASCII)).putInt(16)
        buf.putShort(1).putShort(1).putInt(rate).putInt(rate * 2).putShort(2).putShort(16)
        buf.put("data".toByteArray(Charsets.US_ASCII)).putInt(payload)
        for (i in 0 until n) buf.putShort(samples[i])
        return buf.array()
    }

    /** 已驗證的 PCM 內容；不合規格回傳 null。 */
    class Pcm(val rate: Int, val samples: ShortArray) {
        val durationMs: Long get() = samples.size * 1000L / rate
    }

    fun decode(bytes: ByteArray): Pcm? {
        if (bytes.size < HEADER + 2 || bytes.size > MAX_BYTES) return null
        val b = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        fun tag(at: Int, s: String) = String(bytes, at, 4, Charsets.US_ASCII) == s
        val rate = b.getInt(24)
        val payload = bytes.size - HEADER
        if (!tag(0, "RIFF") || !tag(8, "WAVE") || !tag(12, "fmt ") || !tag(36, "data") ||
            b.getInt(4) != bytes.size - 8 || b.getInt(16) != 16 ||
            b.getShort(20).toInt() != 1 || b.getShort(22).toInt() != 1 ||
            b.getShort(32).toInt() != 2 || b.getShort(34).toInt() != 16 ||
            rate !in 8000..96000 || b.getInt(28) != rate * 2 || b.getInt(40) != payload ||
            payload % 2 != 0 || payload < rate / 2 || payload > rate * 2 * MAX_SECONDS
        ) return null
        b.position(HEADER)
        val out = ShortArray(payload / 2) { b.short }
        return Pcm(rate, out)
    }
}

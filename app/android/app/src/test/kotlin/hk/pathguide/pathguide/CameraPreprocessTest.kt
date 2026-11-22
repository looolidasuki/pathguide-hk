package hk.pathguide.pathguide

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.abs
import kotlin.math.max

/**
 * Android 檢測前處理與離線評估（OpenCV，a10_evaluate.py 同一邏輯）逐像素對照。
 * 夾具由 scripts/gen_camera_preprocess_fixtures.py 產生。
 */
class CameraPreprocessTest {
    private data class Case(
        val tag: String, val rawW: Int, val rawH: Int, val rotation: Int, val input: Int,
        val sw: Int, val sh: Int, val px: Int, val py: Int,
    )

    private fun cases(): List<Case> =
        resource("cases.txt").toString(Charsets.UTF_8).lines().filter { it.isNotBlank() }.map {
            val p = it.trim().split(" ")
            Case(p[0], p[1].toInt(), p[2].toInt(), p[3].toInt(), p[4].toInt(),
                p[5].toInt(), p[6].toInt(), p[7].toInt(), p[8].toInt())
        }

    private fun resource(name: String): ByteArray =
        javaClass.classLoader!!.getResourceAsStream("camera_preprocess/$name")!!.use { it.readBytes() }

    private fun rawRgb(c: Case): FloatArray =
        resource("${c.tag}.raw_rgb").let { b -> FloatArray(b.size) { (b[it].toInt() and 0xFF).toFloat() } }

    private fun expected(c: Case): FloatArray {
        val buf = ByteBuffer.wrap(resource("${c.tag}.expected_f32le")).order(ByteOrder.LITTLE_ENDIAN)
        return FloatArray(c.input * c.input * 3) { buf.getFloat() }
    }

    /** 2026-11-23 前的 Android 取樣：截斷取整的尺寸、最近一點（整數除法）。只作對照。 */
    private fun legacyNearest(rgb: FloatArray, c: Case): FloatArray {
        val swap = c.rotation == 90 || c.rotation == 270
        val srcW = if (swap) c.rawH else c.rawW
        val srcH = if (swap) c.rawW else c.rawH
        val scale = minOf(c.input.toFloat() / srcW, c.input.toFloat() / srcH)
        val newW = (srcW * scale).toInt().coerceAtLeast(1)
        val newH = (srcH * scale).toInt().coerceAtLeast(1)
        val padX = (c.input - newW) / 2
        val padY = (c.input - newH) / 2
        val out = FloatArray(c.input * c.input * 3) { CameraPreprocess.PAD_VALUE }
        for (dy in 0 until newH) for (dx in 0 until newW) {
            val ux = dx * srcW / newW
            val uy = dy * srcH / newH
            val (sx, sy) = when (c.rotation) {
                90 -> uy to c.rawH - 1 - ux
                180 -> c.rawW - 1 - ux to c.rawH - 1 - uy
                270 -> c.rawW - 1 - uy to ux
                else -> ux to uy
            }
            val s = (sy * c.rawW + sx) * 3
            val o = ((padY + dy) * c.input + padX + dx) * 3
            for (ch in 0 until 3) out[o + ch] = rgb[s + ch] / 255f
        }
        return out
    }

    private fun meanAbs(a: FloatArray, b: FloatArray): Double {
        var sum = 0.0
        for (i in a.indices) sum += abs(a[i] - b[i])
        return sum / a.size
    }

    private fun maxAbs(a: FloatArray, b: FloatArray): Float {
        var m = 0f
        for (i in a.indices) m = max(m, abs(a[i] - b[i]))
        return m
    }

    @Test
    fun letterboxMatchesOfflineOpenCvForEveryRotation() {
        for (c in cases()) {
            val rgb = rawRgb(c)
            val out = FloatArray(c.input * c.input * 3)
            val g = CameraPreprocess.letterbox(rgb, c.rawW, c.rawH, c.rotation, c.input, false, out)
            assertEquals("${c.tag} geometry", listOf(c.sw, c.sh, c.px, c.py),
                listOf(g.scaledWidth, g.scaledHeight, g.padX, g.padY))
            val exp = expected(c)
            val newMean = meanAbs(out, exp)
            val newMax = maxAbs(out, exp)
            val oldMean = meanAbs(legacyNearest(rgb, c), exp)
            println("PARITY ${c.tag}: new mean=%.3e max=%.3e | legacy nearest mean=%.3e"
                .format(newMean, newMax, oldMean))
            assertTrue("${c.tag} max diff $newMax", newMax < 1e-5f)
            assertTrue("${c.tag} legacy should differ", oldMean > newMean * 100)
        }
    }

    @Test
    fun channelsFirstIsATransposeOfHwc() {
        val c = cases().first { it.rotation == 90 }
        val rgb = rawRgb(c)
        val hwc = FloatArray(c.input * c.input * 3)
        val chw = FloatArray(c.input * c.input * 3)
        CameraPreprocess.letterbox(rgb, c.rawW, c.rawH, c.rotation, c.input, false, hwc)
        CameraPreprocess.letterbox(rgb, c.rawW, c.rawH, c.rotation, c.input, true, chw)
        val plane = c.input * c.input
        for (p in 0 until plane) for (ch in 0 until 3) assertEquals(hwc[p * 3 + ch], chw[ch * plane + p], 0f)
    }

    @Test
    fun roundingIsHalfToEvenLikePythonRound() {
        // 直立 5×4 放進 6：scale 1.2 → 6×4.8 → round(4.8)=5；再測 .5 的情況。
        assertEquals(5, CameraPreprocess.geometry(5, 4, 0, 6).scaledHeight)
        // 直立 4×10 放進 5：scale 0.5 → 2.0×5；直立 5×10 放進 5：2.5 → 2（取偶）。
        assertEquals(2, CameraPreprocess.geometry(5, 10, 0, 5).scaledWidth)
        assertEquals(4, CameraPreprocess.geometry(7, 10, 0, 5).scaledWidth) // 3.5 → 4（取偶）
    }

    @Test
    fun yuvFullRangeAndLimitedRangeKeyValues() {
        fun one(yv: Int, uv: Int, vv: Int, full: Boolean): FloatArray {
            val out = FloatArray(3)
            CameraPreprocess.yuvToRgb(byteArrayOf(yv.toByte()), byteArrayOf(uv.toByte()),
                byteArrayOf(vv.toByte()), 1, 1, full, out)
            return out
        }
        // 全範圍：Y 直接是亮度；0 與 255 不被截斷到 16／235。
        assertEquals(0f, one(0, 128, 128, true)[0], 1e-4f)
        assertEquals(255f, one(255, 128, 128, true)[1], 1e-4f)
        assertEquals(128f, one(128, 128, 128, true)[2], 1e-4f)
        // 限幅範圍：16 → 0、235 → 255。
        assertEquals(0f, one(16, 128, 128, false)[0], 1e-3f)
        assertEquals(255f, one(235, 128, 128, false)[0], 1e-3f)
        // 全範圍純紅（JFIF）：Y=76, Cb=85, Cr=255 ≈ (254, 0, 0)。
        val red = one(76, 85, 255, true)
        assertTrue(red[0] > 250f && red[1] < 2f && red[2] < 2f)
    }
}

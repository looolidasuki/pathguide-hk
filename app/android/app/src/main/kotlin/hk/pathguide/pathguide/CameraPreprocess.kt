package hk.pathguide.pathguide

import kotlin.math.max
import kotlin.math.min

/**
 * 檢測模型的相機前處理（純 Kotlin、不依賴 Android，可在 JVM 單元測試）。
 *
 * 必須與離線評估 `dataset_pipeline/a10_evaluate.py` 及 iOS VisionPlugin 完全一致：
 *   - 縮放後尺寸以「四捨五入、.5 取偶」取整（Python round／Swift toNearestOrEven）；
 *   - 雙線性、半像素中心（cv2.INTER_LINEAR）；邊緣夾到最近像素；
 *   - letterbox 置中，四周填 114/255；
 *   - 先把 YUV 轉成 RGB（每通道夾到 0..255），再在 RGB 上插值。
 *
 * 2026-11-23 之前 Android 版用「最近一點」取樣，並以限幅範圍公式（Y−16、×1.164）
 * 轉換相機的 YUV：前者令細節鋸齒化，後者在全範圍相機資料上拉高約 16% 對比、
 * 截斷暗部與亮部。兩者都令輸入偏離訓練分佈（iOS 修正同類問題後誤認下降）。
 */
object CameraPreprocess {
    const val PAD_VALUE = 114f / 255f

    data class Geometry(
        val uprightWidth: Int,
        val uprightHeight: Int,
        val scaledWidth: Int,
        val scaledHeight: Int,
        val padX: Int,
        val padY: Int,
    )

    fun geometry(rawWidth: Int, rawHeight: Int, rotation: Int, inputSize: Int): Geometry {
        require(rawWidth > 0 && rawHeight > 0 && inputSize > 0)
        val rot = normalize(rotation)
        val portrait = rot == 90 || rot == 270
        val uw = if (portrait) rawHeight else rawWidth
        val uh = if (portrait) rawWidth else rawHeight
        val scale = min(inputSize.toDouble() / uw, inputSize.toDouble() / uh)
        // Math.rint 為「.5 取偶」，與 Python round 及 Swift .toNearestOrEven 相同。
        val sw = max(1, Math.rint(uw * scale).toInt())
        val sh = max(1, Math.rint(uh * scale).toInt())
        return Geometry(uw, uh, sw, sh, (inputSize - sw) / 2, (inputSize - sh) / 2)
    }

    fun normalize(rotation: Int): Int {
        val r = ((rotation % 360) + 360) % 360
        require(r == 0 || r == 90 || r == 180 || r == 270) { "rotation $rotation" }
        return r
    }

    /**
     * YUV420（已緊密排列：Y 為 w×h，U／V 為 ((w+1)/2)×((h+1)/2)）→ RGB，值域 0..255。
     *
     * [fullRange]：Android 相機 YUV_420_888 一般為 JFIF 全範圍 BT.601；
     * 限幅範圍只為對照／診斷保留。公式與 iOS CameraImageMath.rgb 相同。
     */
    fun yuvToRgb(
        y: ByteArray,
        u: ByteArray,
        v: ByteArray,
        width: Int,
        height: Int,
        fullRange: Boolean,
        out: FloatArray,
    ) {
        val cw = (width + 1) / 2
        require(out.size >= width * height * 3)
        require(y.size >= width * height && u.size >= cw * ((height + 1) / 2) && v.size >= u.size)
        val lumaScale = if (fullRange) 1f else 255f / 219f
        val lumaOffset = if (fullRange) 0f else 16f
        val chromaScale = if (fullRange) 1f else 255f / 224f
        var o = 0
        for (row in 0 until height) {
            val uvRow = (row / 2) * cw
            for (col in 0 until width) {
                val luma = ((y[row * width + col].toInt() and 0xFF) - lumaOffset) * lumaScale
                val ci = uvRow + col / 2
                val cb = ((u[ci].toInt() and 0xFF) - 128f) * chromaScale
                val cr = ((v[ci].toInt() and 0xFF) - 128f) * chromaScale
                out[o++] = clamp255(luma + 1.402f * cr)
                out[o++] = clamp255(luma - 0.344136f * cb - 0.714136f * cr)
                out[o++] = clamp255(luma + 1.772f * cb)
            }
        }
    }

    private fun clamp255(x: Float): Float = if (x < 0f) 0f else if (x > 255f) 255f else x

    /**
     * 原始方向的 RGB（0..255，w×h×3）→ 直立、letterbox 的模型輸入（0..1）。
     *
     * [out] 長度為 inputSize²×3；[channelsFirst] 時排成 CHW，否則 HWC。
     */
    fun letterbox(
        rgb: FloatArray,
        rawWidth: Int,
        rawHeight: Int,
        rotation: Int,
        inputSize: Int,
        channelsFirst: Boolean,
        out: FloatArray,
    ): Geometry {
        val g = geometry(rawWidth, rawHeight, rotation, inputSize)
        val rot = normalize(rotation)
        val plane = inputSize * inputSize
        require(out.size >= plane * 3 && rgb.size >= rawWidth * rawHeight * 3)
        java.util.Arrays.fill(out, 0, plane * 3, PAD_VALUE)

        val cx0 = IntArray(g.scaledWidth)
        val cx1 = IntArray(g.scaledWidth)
        val ctx = FloatArray(g.scaledWidth)
        for (dx in 0 until g.scaledWidth) {
            val (a, b, t) = position(dx, g.uprightWidth, g.scaledWidth)
            cx0[dx] = a; cx1[dx] = b; ctx[dx] = t
        }
        val inv = 1f / 255f
        for (dy in 0 until g.scaledHeight) {
            val (y0, y1, ty) = position(dy, g.uprightHeight, g.scaledHeight)
            val outRow = (g.padY + dy) * inputSize + g.padX
            for (dx in 0 until g.scaledWidth) {
                val tx = ctx[dx]
                val ia = source(cx0[dx], y0, rot, rawWidth, rawHeight)
                val ib = source(cx1[dx], y0, rot, rawWidth, rawHeight)
                val ic = source(cx0[dx], y1, rot, rawWidth, rawHeight)
                val id = source(cx1[dx], y1, rot, rawWidth, rawHeight)
                val pixel = outRow + dx
                for (ch in 0 until 3) {
                    val top = rgb[ia + ch] + (rgb[ib + ch] - rgb[ia + ch]) * tx
                    val bottom = rgb[ic + ch] + (rgb[id + ch] - rgb[ic + ch]) * tx
                    val value = (top + (bottom - top) * ty) * inv
                    out[if (channelsFirst) ch * plane + pixel else pixel * 3 + ch] = value
                }
            }
        }
        return g
    }

    /** 半像素中心的來源座標，夾在 [0, source-1]（cv2.INTER_LINEAR 的邊界行為）。 */
    private fun position(index: Int, source: Int, destination: Int): Triple<Int, Int, Float> {
        val coordinate = max(0.0, min((source - 1).toDouble(),
            (index + 0.5) * source / destination - 0.5))
        val lower = coordinate.toInt()
        return Triple(lower, min(source - 1, lower + 1), (coordinate - lower).toFloat())
    }

    /** 直立座標 → 原始影格 RGB 起始索引（與 iOS CameraImageMath.rawPoint 同一映射）。 */
    private fun source(ux: Int, uy: Int, rot: Int, rawWidth: Int, rawHeight: Int): Int {
        val sx: Int
        val sy: Int
        when (rot) {
            90 -> { sx = uy; sy = rawHeight - 1 - ux }
            180 -> { sx = rawWidth - 1 - ux; sy = rawHeight - 1 - uy }
            270 -> { sx = rawWidth - 1 - uy; sy = ux }
            else -> { sx = ux; sy = uy }
        }
        return (sy * rawWidth + sx) * 3
    }
}

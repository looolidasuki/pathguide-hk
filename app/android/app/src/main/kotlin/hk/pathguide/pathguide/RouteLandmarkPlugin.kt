package hk.pathguide.pathguide

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Handler
import android.os.Looper
import android.util.Base64
import android.util.Log
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import org.tensorflow.lite.Interpreter
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.math.sqrt

/**
 * Android 路標特徵與文字（`hk.pathguide/route_landmark`），對應 iOS 的
 * RouteLandmarkPlugin／RouteLandmarkAnalyzer。
 *
 * - 特徵：MediaPipe MobileNetV3-small 圖像嵌入（LiteRT），L2 正規化後以
 *   `1 - cos` 作距離（0..2）。與 iOS Apple Vision feature print **不相容**，
 *   以不同的 featureRevision 標示；Dart 端遇到其他版本會報 incompatible。
 * - 文字：ML Kit 中文辨識（亦含拉丁字元），只作樓層提示，樓層仍須人手確認。
 *
 * 只處理呼叫者給的 JPEG：不開相機、不存檔、不連網。
 * 一次只處理一個請求；回覆一律回顯 requestId／inputSha／版本，讓 Dart 拒收過期回覆。
 */
class RouteLandmarkPlugin(private val context: Context) : FlutterPlugin {
    companion object {
        private const val TAG = "PathGuideLandmark"
        private const val CHANNEL = "hk.pathguide/route_landmark"
        const val FEATURE_REVISION = "mediapipe-mobilenet-v3-small-embedder-v1"
        const val PREPROCESS_REVISION = "upright-jpeg-224-rgb-pm1-v1"
        /** Android 版的 OCR 設定序號（與 iOS Vision 的 2/3 分開，見 Dart RouteFeatureProfile）。 */
        const val OCR_REVISION = 1
        private const val MODEL_ASSET = "assets/models/route_landmark_embedder.tflite"
        private const val MODEL_SHA256 =
            "bbbb4c51a55a53905af1daec995ca1aae355046f8839bb8c9f5ce9271394bc40"
        private const val INPUT = 224
        private const val DIM = 1024
        private const val MAX_JPEG = 524288
        private const val MAX_FEATURE = 65536
        private const val MAX_SIDE = 1280
    }

    private var channel: MethodChannel? = null
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()

    // 只在 worker 線程存取。
    private var interpreter: Interpreter? = null
    private val ocr by lazy {
        TextRecognition.getClient(ChineseTextRecognizerOptions.Builder().build())
    }

    @Volatile private var busyId: String? = null
    @Volatile private var cancelledId: String? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also { ch ->
            ch.setMethodCallHandler { call, result -> handle(call, result) }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        worker.execute {
            runCatching { interpreter?.close() }
            interpreter = null
            runCatching { ocr.close() }
        }
        worker.shutdown()
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "cancel" -> {
                val id = call.argument<String>("requestId")
                if (id != null && id == busyId) cancelledId = id
                result.success(null)
            }
            "analyze", "compare" -> {
                val args = (call.arguments as? Map<*, *>) ?: emptyMap<Any, Any>()
                val id = args["requestId"] as? String
                if (id.isNullOrEmpty()) {
                    result.success(mapOf("status" to "invalid"))
                    return
                }
                val echo = mapOf(
                    "requestId" to id,
                    "inputSha" to args["inputSha"],
                    "featureRevision" to FEATURE_REVISION,
                    "preprocessRevision" to PREPROCESS_REVISION,
                )
                if (busyId != null) {
                    result.success(echo + ("status" to "busy"))
                    return
                }
                if (args["featureRevision"] != FEATURE_REVISION ||
                    args["preprocessRevision"] != PREPROCESS_REVISION
                ) {
                    result.success(echo + ("status" to "incompatible"))
                    return
                }
                busyId = id
                cancelledId = null
                worker.execute {
                    val reply: Map<String, Any?> = try {
                        val body = if (call.method == "analyze") analyze(id, args) else compare(id, args)
                        if (cancelledId == id) echo + ("status" to "cancelled") else echo + body
                    } catch (e: LandmarkError) {
                        echo + ("status" to e.code)
                    } catch (e: Throwable) {
                        Log.w(TAG, "${call.method} failed", e)
                        echo + ("status" to "failed")
                    }
                    main.post {
                        // 先清 busy 再回覆：Dart 收到後可能立刻發下一個請求。
                        if (busyId == id) busyId = null
                        if (cancelledId == id) cancelledId = null
                        result.success(reply)
                    }
                }
            }
            else -> result.notImplemented()
        }
    }

    private class LandmarkError(val code: String) : Exception(code)

    private fun checkCancelled(id: String) {
        if (cancelledId == id) throw LandmarkError("cancelled")
    }

    // ------------------------------------------------------------------ analyze

    private fun analyze(id: String, args: Map<*, *>): Map<String, Any?> {
        val jpeg = args["jpeg"] as? ByteArray ?: throw LandmarkError("invalid")
        val width = (args["width"] as? Number)?.toInt() ?: throw LandmarkError("invalid")
        val height = (args["height"] as? Number)?.toInt() ?: throw LandmarkError("invalid")
        if (jpeg.size < 4 || jpeg.size > MAX_JPEG ||
            jpeg[0] != 0xFF.toByte() || jpeg[1] != 0xD8.toByte() ||
            width <= 0 || height <= 0 || maxOf(width, height) > MAX_SIDE
        ) throw LandmarkError("invalid")
        if (sha256(jpeg) != args["inputSha"]) throw LandmarkError("invalid")

        val bitmap = BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size)
            ?: throw LandmarkError("invalid")
        try {
            if (bitmap.width != width || bitmap.height != height) throw LandmarkError("invalid")
            checkCancelled(id)
            val embedding = embed(bitmap)
            checkCancelled(id)
            val feature = envelope(embedding)
            if (feature.size > MAX_FEATURE) throw LandmarkError("invalid")
            // OCR 失敗時仍保留視覺特徵，樓層改由人手確認（與 iOS 相同）。
            val text = runCatching { recognizeText(bitmap) }.getOrElse {
                Log.w(TAG, "OCR failed; keeping visual feature", it)
                emptyList()
            }
            checkCancelled(id)
            return mapOf(
                "status" to "ok",
                "feature" to feature,
                "featureSha" to sha256(feature),
                "text" to text,
                "manualFloorConfirmationRequired" to true,
                "ocrRevision" to OCR_REVISION,
            )
        } finally {
            bitmap.recycle()
        }
    }

    private fun model(): Interpreter {
        interpreter?.let { return it }
        val key = FlutterInjector.instance().flutterLoader().getLookupKeyForAsset(MODEL_ASSET)
        val bytes = context.assets.open(key).use { it.readBytes() }
        if (sha256(bytes) != MODEL_SHA256) {
            Log.e(TAG, "landmark model hash mismatch")
            throw LandmarkError("incompatible")
        }
        val buffer = ByteBuffer.allocateDirect(bytes.size).order(ByteOrder.nativeOrder())
        buffer.put(bytes).rewind()
        return Interpreter(buffer, Interpreter.Options().setNumThreads(2)).also {
            val inShape = it.getInputTensor(0).shape()
            val outShape = it.getOutputTensor(0).shape()
            if (!inShape.contentEquals(intArrayOf(1, INPUT, INPUT, 3)) ||
                !outShape.contentEquals(intArrayOf(1, DIM))
            ) {
                it.close()
                throw LandmarkError("incompatible")
            }
            interpreter = it
        }
    }

    /** RGB、雙線性拉伸到 224×224、x / 127.5 - 1；輸出 L2 正規化。 */
    private fun embed(source: Bitmap): FloatArray {
        val scaled = Bitmap.createScaledBitmap(source, INPUT, INPUT, true)
        val pixels = IntArray(INPUT * INPUT)
        scaled.getPixels(pixels, 0, INPUT, 0, 0, INPUT, INPUT)
        if (scaled !== source) scaled.recycle()
        val input = ByteBuffer.allocateDirect(4 * INPUT * INPUT * 3).order(ByteOrder.nativeOrder())
        for (p in pixels) {
            input.putFloat(((p shr 16) and 0xFF) / 127.5f - 1f)
            input.putFloat(((p shr 8) and 0xFF) / 127.5f - 1f)
            input.putFloat((p and 0xFF) / 127.5f - 1f)
        }
        input.rewind()
        val output = Array(1) { FloatArray(DIM) }
        model().run(input, output)
        return normalize(output[0])
    }

    private fun normalize(v: FloatArray): FloatArray {
        var sum = 0.0
        for (x in v) {
            if (!x.isFinite()) throw LandmarkError("invalid")
            sum += x * x
        }
        val norm = sqrt(sum).toFloat()
        if (norm <= 0f || !norm.isFinite()) throw LandmarkError("invalid")
        return FloatArray(v.size) { v[it] / norm }
    }

    private fun envelope(embedding: FloatArray): ByteArray {
        val raw = ByteBuffer.allocate(4 * embedding.size).order(ByteOrder.LITTLE_ENDIAN)
        for (x in embedding) raw.putFloat(x)
        val json = JSONObject()
            .put("schema", 1)
            .put("featureRevision", FEATURE_REVISION)
            .put("preprocessRevision", PREPROCESS_REVISION)
            .put("modelSha256", MODEL_SHA256)
            .put("dim", embedding.size)
            .put("embedding", Base64.encodeToString(raw.array(), Base64.NO_WRAP))
        return json.toString().toByteArray(Charsets.UTF_8)
    }

    private fun recognizeText(bitmap: Bitmap): List<String> {
        val text = Tasks.await(ocr.process(InputImage.fromBitmap(bitmap, 0)), 6, TimeUnit.SECONDS)
        return text.textBlocks
            .flatMap { it.lines }
            .map { it.text.trim() }
            .filter { it.isNotEmpty() }
            .take(32)
            .map { it.take(120) }
    }

    // ------------------------------------------------------------------ compare

    private fun compare(id: String, args: Map<*, *>): Map<String, Any?> {
        val query = args["query"] as? ByteArray ?: throw LandmarkError("invalid")
        val references = (args["references"] as? List<*>)?.map { it as? ByteArray ?: throw LandmarkError("invalid") }
            ?: throw LandmarkError("invalid")
        if (query.isEmpty() || query.size > MAX_FEATURE ||
            references.isEmpty() || references.size > 64 ||
            references.any { it.isEmpty() || it.size > MAX_FEATURE }
        ) throw LandmarkError("invalid")
        if (sha256(query) != args["inputSha"]) throw LandmarkError("invalid")
        val q = decode(query)
        val distances = references.map { ref ->
            checkCancelled(id)
            val r = decode(ref)
            var dot = 0.0
            for (i in q.indices) dot += q[i] * r[i]
            // 數值誤差可令 cos 略大於 1；距離不能為負。
            maxOf(0.0, 1.0 - dot)
        }
        return mapOf("status" to "ok", "distances" to distances)
    }

    /** 只接受本版本、本模型產生的特徵；iOS 或其他版本一律 incompatible。 */
    private fun decode(bytes: ByteArray): FloatArray {
        val json = runCatching { JSONObject(String(bytes, Charsets.UTF_8)) }
            .getOrElse { throw LandmarkError("incompatible") }
        if (json.optInt("schema") != 1 ||
            json.optString("featureRevision") != FEATURE_REVISION ||
            json.optString("preprocessRevision") != PREPROCESS_REVISION ||
            json.optString("modelSha256") != MODEL_SHA256 ||
            json.optInt("dim") != DIM
        ) throw LandmarkError("incompatible")
        val raw = runCatching { Base64.decode(json.getString("embedding"), Base64.NO_WRAP) }
            .getOrElse { throw LandmarkError("invalid") }
        if (raw.size != 4 * DIM) throw LandmarkError("invalid")
        val buf = ByteBuffer.wrap(raw).order(ByteOrder.LITTLE_ENDIAN)
        return FloatArray(DIM) { buf.getFloat() }.also { v ->
            if (v.any { !it.isFinite() }) throw LandmarkError("invalid")
        }
    }

    private fun sha256(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
}

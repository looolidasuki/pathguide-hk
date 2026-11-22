package hk.pathguide.pathguide

import android.app.Activity
import android.content.Intent
import android.graphics.Bitmap
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import androidx.core.content.FileProvider
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.io.File

/**
 * 菜單 OCR 與菜單語音查詢的 **Android** 實作。
 *
 * ## 契約（與 iOS `MenuPlugin.swift` 完全一致）
 *
 * 通道 `hk.pathguide/menu`：
 * - `readMenu {requestId, source: camera|library|scanner}`
 *   → `{ocrVersion, lines: [{text,page,left,top,width,height,confidence}], pages, truncated, warnings}`
 *   → 使用者取消時回 `null`（Dart 收到 null 即視為取消，不當成錯誤）
 * - `listenMenuQuery {requestId, allowNetwork}` → `{outcome, text}`，outcome ∈
 *   `finalText｜noSpeech｜timeout｜cancelled`
 * - `finishMenuSpeech`、`cancelMenu`
 * - 回呼（native → Dart）：`recognizing`、`speechPhase`、`speechPartial`，
 *   三者都帶 `requestId`；Dart 只認自己那次的 id。
 *
 * ## 為什麼自己寫一個新的語音辨識，而不重用 SpeechInputPlugin
 *
 * `SpeechInputPlugin` 是給「導航語音輸入」用的，它把 `reply` 綁在自己那條通道上。
 * 兩個功能若共用同一個辨識器實例，一邊開始就會把另一邊的 result 吃掉。
 * 這裡寧可多 60 行，也不讓兩個功能互相搶麥克風與回呼。
 *
 * ## 與 iOS 的三個已知差異（都寫在 verification JSON 裡）
 *
 * 1. **單頁**：iOS 可連拍多頁（`pages`、`truncated`），Android 首版只取一張，
 *    固定 `pages=1`、`truncated=false`。
 * 2. **拍攝 UI**：iOS 有自建掃描器；Android 交給系統相機／相簿，
 *    不引入額外相機 UI，也就沒有「連拍」。
 * 3. **置信度**：ML Kit 的文字辨識**不提供逐行 confidence**（Vision 有）。
 *    這裡取該行各 `Text.Element.confidence` 的平均；若引擎全部回 0
 *    （部分機型如此），退回 1.0 而不是 0.0 —— 回 0.0 會讓每一行都被
 *    `menu_document.dart` 標成「文字可能有誤」，把真實的低信心警告淹掉。
 */
class MenuPlugin(private val activity: Activity) :
    FlutterPlugin,
    PluginRegistry.ActivityResultListener {

    companion object {
        private const val CHANNEL = "hk.pathguide/menu"
        private const val REQUEST_READ_MENU = 9401
        private const val SPEECH_TIMEOUT_MS = 15_000L

        /** 給 verification 與畫面顯示用；變更 OCR 引擎時要一起改。 */
        const val OCR_VERSION = "android-mlkit-text-recognition-chinese-16.0.1"
    }

    private var channel: MethodChannel? = null
    private val main = Handler(Looper.getMainLooper())

    // ---- 讀菜單（一次只有一個）----
    private var readReply: MethodChannel.Result? = null
    private var readRequestId: String = ""
    /** 上游 1.12 起的「通用讀字」：Dart 傳 includeGeneral=true 時要另回 readingLines。 */
    private var readIncludeGeneral = false
    private var cameraOutput: File? = null

    // ---- 語音查詢（一次只有一個）----
    private var speechReply: MethodChannel.Result? = null
    private var speechRequestId: String = ""
    private var recognizer: SpeechRecognizer? = null
    private var speechPartial: String = ""
    private var speechLanguage = "zh-HK"

    private val recognizerOptions by lazy {
        TextRecognition.getClient(ChineseTextRecognizerOptions.Builder().build())
    }

    fun attach(messenger: io.flutter.plugin.common.BinaryMessenger) {
        channel = MethodChannel(messenger, CHANNEL).also { ch ->
            ch.setMethodCallHandler { call, result -> handle(call, result) }
        }
    }

    // FlutterPlugin：由 MainActivity 以 plugins.add(MenuPlugin(this)) 註冊。
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        attach(binding.binaryMessenger)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        detach()
    }

    fun detach() {
        channel?.setMethodCallHandler(null)
        channel = null
        stopSpeech(cancelled = true)
        readReply = null
        recognizerOptions.close()
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "readMenu" -> readMenu(call, result)
            "listenMenuQuery" -> listenMenuQuery(call, result)
            "finishMenuSpeech" -> {
                // 只停「聽」，結果照常走 onResults。
                recognizer?.stopListening()
                result.success(null)
            }
            "cancelMenu" -> {
                cancelRead()
                stopSpeech(cancelled = true)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    // ------------------------------------------------------------------ 讀菜單

    private fun readMenu(call: MethodCall, result: MethodChannel.Result) {
        if (readReply != null) {
            result.error("busy", "請先完成或取消目前操作。", null)
            return
        }
        val requestId = call.argument<String>("requestId")
        if (requestId.isNullOrBlank()) {
            result.error("bad_args", "缺少請求識別碼。", null)
            return
        }
        val source = call.argument<String>("source") ?: "camera"
        readReply = result
        readRequestId = requestId
        readIncludeGeneral = call.argument<Boolean>("includeGeneral") == true

        val intent = when (source) {
            "library" -> Intent(Intent.ACTION_GET_CONTENT).apply {
                type = "image/*"
                addCategory(Intent.CATEGORY_OPENABLE)
            }
            // camera 與 scanner 首版同一條路：系統相機。scanner 的「連拍多頁」尚未實作。
            else -> Intent(MediaStore.ACTION_IMAGE_CAPTURE).also { take ->
                val file = File.createTempFile("menu_", ".jpg", activity.cacheDir)
                cameraOutput = file
                val uri: Uri = FileProvider.getUriForFile(
                    activity,
                    "${activity.packageName}.fileprovider",
                    file,
                )
                take.putExtra(MediaStore.EXTRA_OUTPUT, uri)
                take.addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            }
        }
        try {
            activity.startActivityForResult(intent, REQUEST_READ_MENU)
        } catch (e: Exception) {
            readReply = null
            result.error("no_app", "這台裝置沒有可用的相機或相簿應用。", e.message)
        }
    }

    private fun cancelRead() {
        readReply?.success(null)
        readReply = null
        cameraOutput?.delete()
        cameraOutput = null
    }

    /** 由 MainActivity 轉發。 */
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_READ_MENU) return false
        val reply = readReply
        if (reply == null) return true

        val uri: Uri? = when {
            resultCode != Activity.RESULT_OK -> null
            data?.data != null -> data.data
            cameraOutput != null && cameraOutput!!.length() > 0 -> Uri.fromFile(cameraOutput)
            else -> null
        }
        if (uri == null) {
            reply.success(null) // 使用者取消：不是錯誤
            readReply = null
            cameraOutput?.delete()
            cameraOutput = null
            return true
        }

        channel?.invokeMethod("recognizing", mapOf("requestId" to readRequestId))
        recognize(uri, readIncludeGeneral) { payload, failure ->
            // ★ 只回覆「仍是當前請求」的那一次。辨識期間 Dart 可能已 cancelMenu
            //   （cancelRead 先以 null 回覆並清空 readReply），或已開始下一次讀取。
            //   直接用捕獲的 reply 再回覆會丟 IllegalStateException("Reply already submitted")
            //   並令主線程崩潰（2026-11-22 真機：拍照後必崩）。
            if (readReply !== reply) return@recognize
            readReply = null
            cameraOutput?.delete()
            cameraOutput = null
            if (failure != null) {
                reply.error("ocr_failed", "未能讀取這張相片上的文字。", failure)
            } else {
                reply.success(payload)
            }
        }
        return true
    }

    private fun recognize(
        uri: Uri,
        includeGeneral: Boolean,
        done: (Map<String, Any?>?, String?) -> Unit,
    ) {
        val image = try {
            InputImage.fromFilePath(activity, uri)
        } catch (e: Exception) {
            done(null, "無法解碼相片：${e.message}")
            return
        }
        recognizerOptions.process(image)
            .addOnSuccessListener { text ->
                val lines = mutableListOf<Map<String, Any?>>()
                for (block in text.textBlocks) {
                    for (line in block.lines) {
                        val box = line.boundingBox ?: continue
                        val body = line.text.trim()
                        if (body.isEmpty()) continue
                        lines.add(
                            mapOf(
                                "text" to body,
                                "page" to 0,
                                "left" to box.left.toDouble(),
                                "top" to box.top.toDouble(),
                                "width" to box.width().toDouble(),
                                "height" to box.height().toDouble(),
                                "confidence" to lineConfidence(line),
                            )
                        )
                    }
                }
                val warnings = mutableListOf<String>()
                if (image.width < 700 || image.height < 700) {
                    warnings.add("相片較細，價錢可能需要重拍。")
                }
                if (lines.isEmpty()) warnings.add("這張相片沒有辨識到文字。")
                val payload = mutableMapOf<String, Any?>(
                    "ocrVersion" to OCR_VERSION,
                    "lines" to lines,
                    "pages" to 1,
                    "truncated" to false,
                    "warnings" to warnings,
                )
                if (includeGeneral) {
                    // 通用讀字（對齊 iOS MenuPlugin 1.12）：iOS 另跑一次整頁、不做菜單合併的辨識；
                    // ML Kit 本來就是整頁逐行輸出、沒有菜單專用的分區合併，所以同一份行即可。
                    payload["readingLines"] = lines
                    payload["readingLimited"] = false
                    payload["menuUnavailable"] = false
                }
                done(payload, null)
            }
            .addOnFailureListener { e -> done(null, "文字辨識失敗：${e.message}") }
    }

    /**
     * 逐行置信度。ML Kit 沒有 `Text.Line.confidence`，只能由元素平均推定；
     * 全部為 0 時回 1.0（見類別註解的第三點）。
     */
    private fun lineConfidence(line: com.google.mlkit.vision.text.Text.Line): Double {
        val values = line.elements.map { it.confidence.toDouble() }.filter { it > 0.0 }
        if (values.isEmpty()) return 1.0
        return values.average()
    }

    // ------------------------------------------------------------------ 語音查詢

    private fun listenMenuQuery(call: MethodCall, result: MethodChannel.Result) {
        if (speechReply != null) {
            result.error("busy", "請先完成或取消目前操作。", null)
            return
        }
        val requestId = call.argument<String>("requestId")
        if (requestId.isNullOrBlank()) {
            result.error("bad_args", "缺少請求識別碼。", null)
            return
        }
        val allowNetwork = call.argument<Boolean>("allowNetwork") ?: true
        speechReply = result
        speechRequestId = requestId
        speechPartial = ""
        speechLanguage = call.argument<String>("language") ?: "zh-HK"

        if (!SpeechRecognizer.isRecognitionAvailable(activity)) {
            speechReply = null
            result.error("unsupported", "這台裝置沒有語音辨識服務。", null)
            return
        }

        phase("preparing")
        val recognizer = SpeechRecognizer.createSpeechRecognizer(activity).also { this.recognizer = it }
        recognizer.setRecognitionListener(object : RecognitionListener {
            override fun onReadyForSpeech(params: Bundle?) = phase("listening")
            override fun onBeginningOfSpeech() {}
            override fun onRmsChanged(rmsdB: Float) {}
            override fun onBufferReceived(buffer: ByteArray?) {}
            override fun onEndOfSpeech() = phase("finishing")
            override fun onEvent(eventType: Int, params: Bundle?) {}

            override fun onError(error: Int) {
                val reply = speechReply ?: return
                speechReply = null
                phase("finishing")
                when (error) {
                    SpeechRecognizer.ERROR_SPEECH_TIMEOUT,
                    SpeechRecognizer.ERROR_NO_MATCH ->
                        reply.success(mapOf("outcome" to "noSpeech", "text" to speechPartial))
                    SpeechRecognizer.ERROR_RECOGNIZER_BUSY ->
                        reply.error("busy", "語音服務正忙，請再試一次。", null)
                    else ->
                        reply.success(mapOf("outcome" to "cancelled", "text" to speechPartial))
                }
                releaseRecognizer()
            }

            override fun onPartialResults(partialResults: Bundle?) {
                val text = partialResults
                    ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                    ?.firstOrNull()?.trim().orEmpty()
                if (text.isNotEmpty() && text != speechPartial) {
                    speechPartial = text
                    channel?.invokeMethod(
                        "speechPartial",
                        mapOf("requestId" to speechRequestId, "text" to text),
                    )
                }
            }

            override fun onResults(results: Bundle?) {
                val reply = speechReply ?: return
                speechReply = null
                val text = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                    ?.firstOrNull()?.trim().orEmpty().ifEmpty { speechPartial }
                phase("finishing")
                reply.success(
                    mapOf(
                        "outcome" to if (text.isEmpty()) "noSpeech" else "finalText",
                        "text" to text,
                    )
                )
                releaseRecognizer()
            }
        })

        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, speechLanguage)
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
            if (!allowNetwork) putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
        }
        try {
            recognizer.startListening(intent)
        } catch (e: Exception) {
            speechReply = null
            releaseRecognizer()
            result.error("speech_failed", "未能啟動語音辨識。", e.message)
            return
        }
        main.postDelayed({
            val reply = speechReply
            if (reply != null) {
                speechReply = null
                releaseRecognizer()
                reply.success(mapOf("outcome" to "timeout", "text" to speechPartial))
            }
        }, SPEECH_TIMEOUT_MS)
    }

    /** 使用者按「停止」或取消：立刻把目前結果交出去，不讓畫面卡住。 */
    private fun stopSpeech(cancelled: Boolean) {
        val reply = speechReply
        speechReply = null
        releaseRecognizer()
        if (reply != null) {
            if (cancelled) {
                reply.success(mapOf("outcome" to "cancelled", "text" to speechPartial))
            } else {
                reply.success(
                    mapOf(
                        "outcome" to if (speechPartial.isEmpty()) "noSpeech" else "finalText",
                        "text" to speechPartial,
                    )
                )
            }
        }
    }

    private fun releaseRecognizer() {
        recognizer?.destroy()
        recognizer = null
    }

    private fun phase(value: String) {
        channel?.invokeMethod(
            "speechPhase",
            mapOf("requestId" to speechRequestId, "phase" to value),
        )
    }
}

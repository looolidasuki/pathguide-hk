package hk.pathguide.pathguide

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.*
import android.view.HapticFeedbackConstants
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.*

class SpeechInputPlugin : FlutterPlugin, ActivityAware, PluginRegistry.RequestPermissionsResultListener, DefaultLifecycleObserver {
  private lateinit var context: Context
  private lateinit var channel: MethodChannel
  private var activity: Activity? = null
  private var recognizer: SpeechRecognizer? = null
  private var reply: MethodChannel.Result? = null
  private var id: Int = 0
  private var generation: Int = 0
  private var activityBinding: ActivityPluginBinding? = null
  private var allowNetwork = false
  private var partial = ""
  private val handler = Handler(Looper.getMainLooper())
  private val timeout = Runnable { recognizer?.stopListening(); phase("finishing"); handler.postDelayed(finish, 4000) }
  private val finish = Runnable { complete(if (partial.isBlank()) "timeout" else "finalText") }
  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    context = binding.applicationContext
    channel = MethodChannel(binding.binaryMessenger, "hk.pathguide/speech")
    channel.setMethodCallHandler { call, result ->
      when (call.method) {
        "cancel" -> { complete("cancelled"); result.success(null) }
        "listen" -> {
          if (reply != null) { result.error("busy", "請先完成或取消收音。", null); return@setMethodCallHandler }
          id = call.argument<Int>("requestId") ?: 0; allowNetwork = call.argument<Boolean>("allowNetwork") == true
          reply = result; partial = ""; phase("preparing")
          if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) start()
          else activity?.let { ActivityCompat.requestPermissions(it, arrayOf(Manifest.permission.RECORD_AUDIO), 872) } ?: fail("microphone_denied", "請返回 App 後重試。")
        }
        else -> result.notImplemented()
      }
    }
  }
  private fun phase(value: String) { channel.invokeMethod("speechPhase", mapOf("requestId" to id, "phase" to value)) }
  private fun start() {
    if (reply == null) return
    val device = Build.VERSION.SDK_INT >= 31 && SpeechRecognizer.isOnDeviceRecognitionAvailable(context)
    if (!allowNetwork && !device) { fail("offline_speech_unavailable", "此裝置未提供可確認的離線粵語辨識。"); return }
    if (allowNetwork && !SpeechRecognizer.isRecognitionAvailable(context)) { fail("speech_unavailable", "此手機未有語音辨識服務，請用文字搜尋。"); return }
    try {
      val token = generation
      val speech = if (!allowNetwork && Build.VERSION.SDK_INT >= 31) SpeechRecognizer.createOnDeviceSpeechRecognizer(context) else SpeechRecognizer.createSpeechRecognizer(context)
      recognizer = speech
      speech.setRecognitionListener(object : RecognitionListener {
        override fun onReadyForSpeech(params: Bundle?) { if (reply == null || token != generation) return; phase("listening"); activity?.window?.decorView?.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP) }
        override fun onBeginningOfSpeech() {}
        override fun onRmsChanged(rmsdB: Float) {}
        override fun onBufferReceived(buffer: ByteArray?) {}
        override fun onEndOfSpeech() { if (reply != null && token == generation) { phase("finishing"); handler.removeCallbacks(timeout); handler.postDelayed(finish, 4000) } }
        override fun onError(error: Int) {
          if (reply == null || token != generation) return
          if (!allowNetwork && error in listOf(SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED, SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE, SpeechRecognizer.ERROR_SERVER, SpeechRecognizer.ERROR_CLIENT)) fail("offline_speech_unavailable", "此裝置未能以離線粵語收音。")
          else if (partial.isNotBlank()) complete("finalText")
          else if (error == SpeechRecognizer.ERROR_NO_MATCH || error == SpeechRecognizer.ERROR_SPEECH_TIMEOUT) complete("noSpeech")
          else fail("speech_failed", "未能完成收音，請重試或用文字搜尋。")
        }
        private fun best(results: Bundle?) { val text = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()?.trim(); if (!text.isNullOrEmpty()) { partial = text; channel.invokeMethod("speechPartial", mapOf("requestId" to id, "text" to text)) } }
        override fun onResults(results: Bundle?) { if (reply == null || token != generation) return; best(results); complete(if (partial.isBlank()) "noSpeech" else "finalText") }
        override fun onPartialResults(partialResults: Bundle?) { if (reply != null && token == generation) best(partialResults) }
        override fun onEvent(eventType: Int, params: Bundle?) {}
      })
      val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM).putExtra(RecognizerIntent.EXTRA_LANGUAGE, "yue-Hant-HK").putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
      if (!allowNetwork && Build.VERSION.SDK_INT >= 33) {
        val requestId = id
        speech.checkRecognitionSupport(intent, context.mainExecutor, object : RecognitionSupportCallback {
          override fun onSupportResult(support: RecognitionSupport) {
            if (reply == null || id != requestId || token != generation) return
            val language = support.installedOnDeviceLanguages.firstOrNull { it.startsWith("yue", true) || it.equals("zh-HK", true) }
            if (language == null) fail("offline_speech_unavailable", "未安裝可用的離線粵語模型。") else { intent.putExtra(RecognizerIntent.EXTRA_LANGUAGE, language); listen(speech, intent) }
          }
          override fun onError(error: Int) { if (reply != null && id == requestId && token == generation) fail("offline_speech_unavailable", "未能確認離線粵語模型，請用文字或選擇線上語音。") }
        })
      } else listen(speech, intent)
    } catch (_: Exception) { fail(if (allowNetwork) "speech_failed" else "offline_speech_unavailable", "未能啟動語音辨識，請用文字搜尋。") }
  }
  private fun listen(speech: SpeechRecognizer, intent: Intent) { speech.startListening(intent); handler.postDelayed(timeout, 20000) }
  private fun cleanup() { generation++; handler.removeCallbacks(timeout); handler.removeCallbacks(finish); recognizer?.cancel(); recognizer?.destroy(); recognizer = null }
  private fun complete(outcome: String) { val old = reply; reply = null; cleanup(); old?.success(mapOf("outcome" to outcome, "text" to partial)) }
  private fun fail(code: String, message: String) { val old = reply; reply = null; cleanup(); old?.error(code, message, null) }
  override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray): Boolean {
    if (requestCode != 872) return false
    if (reply != null) { if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) start() else fail("microphone_denied", "未獲咪高峰權限，可用文字搜尋。") }; return true
  }
  override fun onStop(owner: LifecycleOwner) { complete("cancelled") }
  override fun onAttachedToActivity(binding: ActivityPluginBinding) { activityBinding = binding; activity = binding.activity; binding.addRequestPermissionsResultListener(this); (activity as? LifecycleOwner)?.lifecycle?.addObserver(this) }
  override fun onDetachedFromActivity() { activityBinding?.removeRequestPermissionsResultListener(this); activityBinding = null; complete("cancelled"); (activity as? LifecycleOwner)?.lifecycle?.removeObserver(this); activity = null }
  override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()
  override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)
  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) { complete("cancelled"); channel.setMethodCallHandler(null) }
}

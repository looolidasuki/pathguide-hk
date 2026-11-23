package hk.pathguide.pathguide

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.content.ContextCompat
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/**
 * 路標錄音備註（Android），對應 iOS RouteNoteAudioPlugin.swift。
 *
 * 通道 hk.pathguide/route_note_audio；每個方法帶 {owner}：
 *   start  → 錄音上限毫秒（≤ 10000）。同一時間只容一個 owner；忙碌或不在前台回 unavailable。
 *   finish → 44 位元組標頭的 PCM WAV；不足 0.25 秒回 too_short。
 *   play   → {owner, bytes}，播完才回覆；不合規格或超過 10 秒回 invalid。
 *   cancel → 停止並清空。
 * 錄音只存在記憶體，不寫檔。進入後台（onStop）或失去音訊焦點時全部重設，
 * 未完成的回覆以 cancelled 失敗。所有狀態只在主線程改動。
 */
class RouteNoteAudioPlugin(private val context: Context) :
    FlutterPlugin,
    ActivityAware,
    PluginRegistry.RequestPermissionsResultListener,
    DefaultLifecycleObserver {

    companion object {
        private const val TAG = "PathGuideNoteAudio"
        private const val CHANNEL = "hk.pathguide/route_note_audio"
        private const val REQ_AUDIO = 7303
        private val RATES = intArrayOf(16000, 44100, 48000, 22050, 8000)
    }

    private class Capture(val record: AudioRecord, val rate: Int, val limit: Int) {
        val samples = ShortArray(limit)
        val count = AtomicInteger(0)
        val running = AtomicBoolean(true)
        var thread: Thread? = null
    }

    private val main = Handler(Looper.getMainLooper())
    private val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private var channel: MethodChannel? = null
    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null

    private var owner: String? = null
    private var pendingStart: MethodChannel.Result? = null
    private var capture: Capture? = null
    private var track: AudioTrack? = null
    private var pendingPlay: MethodChannel.Result? = null
    private var playTimeout: Runnable? = null
    private var focus: Any? = null

    // ------------------------------------------------------------ 註冊

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler { call, result -> handle(call, result) }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        reset()
        channel?.setMethodCallHandler(null)
        channel = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) = attach(binding)
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = attach(binding)
    override fun onDetachedFromActivityForConfigChanges() = detach()
    override fun onDetachedFromActivity() = detach()

    private fun attach(binding: ActivityPluginBinding) {
        activityBinding = binding
        activity = binding.activity
        binding.addRequestPermissionsResultListener(this)
        (binding.activity as? LifecycleOwner)?.lifecycle?.addObserver(this)
    }

    private fun detach() {
        (activity as? LifecycleOwner)?.lifecycle?.removeObserver(this)
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null
        activity = null
        reset()
    }

    /** 進入後台：與 iOS didEnterBackground 相同，全部重設。 */
    override fun onStop(owner: LifecycleOwner) = reset()

    private fun foreground(): Boolean =
        (activity as? LifecycleOwner)?.lifecycle?.currentState?.isAtLeast(Lifecycle.State.STARTED) == true

    // ------------------------------------------------------------ 方法

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        val who = call.argument<String>("owner")
        if (who.isNullOrEmpty()) {
            result.error("invalid", null, null)
            return
        }
        when (call.method) {
            "start" -> start(who, result)
            "finish" -> finish(who, result)
            "play" -> play(who, call.argument<ByteArray>("bytes"), result)
            "cancel" -> {
                if (owner == who) reset()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun start(who: String, result: MethodChannel.Result) {
        if (owner != null || !foreground()) {
            result.error("unavailable", null, null)
            return
        }
        owner = who
        if (hasPermission()) {
            begin(who, result)
            return
        }
        val act = activity
        if (act == null) {
            owner = null
            result.error("unavailable", null, null)
            return
        }
        pendingStart = result
        act.requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), REQ_AUDIO)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != REQ_AUDIO) return false
        val result = pendingStart ?: return true
        pendingStart = null
        val who = owner
        val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
        when {
            who == null -> result.error("cancelled", null, null)
            !granted -> { owner = null; result.error("permission", null, null) }
            !foreground() -> { owner = null; result.error("unavailable", null, null) }
            else -> begin(who, result)
        }
        return true
    }

    private fun begin(who: String, result: MethodChannel.Result) {
        val c = openRecorder()
        if (c == null || !requestFocus()) {
            c?.record?.release()
            owner = null
            result.error("unavailable", null, null)
            return
        }
        try {
            c.record.startRecording()
        } catch (e: Exception) {
            Log.w(TAG, "startRecording 失敗", e)
            c.record.release()
            abandonFocus()
            owner = null
            result.error("unavailable", null, null)
            return
        }
        if (c.record.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
            c.record.release()
            abandonFocus()
            owner = null
            result.error("unavailable", null, null)
            return
        }
        capture = c
        c.thread = Thread({ pump(c) }, "route-note-record").also { it.start() }
        result.success((c.limit * 1000L / c.rate).toInt())
        Log.i(TAG, "錄音開始 owner=$who rate=${c.rate} limit=${c.limit}")
    }

    /** 錄音線程：讀到上限即自動停（保留已錄內容，等 finish 取回）。 */
    private fun pump(c: Capture) {
        val chunk = ShortArray(1024)
        while (c.running.get()) {
            val room = c.limit - c.count.get()
            if (room <= 0) break
            val n = c.record.read(chunk, 0, minOf(chunk.size, room))
            if (n < 0) break
            if (n == 0) continue
            val at = c.count.get()
            System.arraycopy(chunk, 0, c.samples, at, n)
            c.count.set(at + n)
        }
        try { c.record.stop() } catch (_: Exception) {}
    }

    private fun finish(who: String, result: MethodChannel.Result) {
        val c = capture
        if (owner != who || c == null) {
            result.error("invalid", null, null)
            return
        }
        capture = null
        stopCapture(c)
        owner = null
        abandonFocus()
        val wav = RouteNoteWav.encode(c.samples, c.count.get(), c.rate)
        if (wav == null) result.error("too_short", null, null) else result.success(wav)
    }

    private fun play(who: String, bytes: ByteArray?, result: MethodChannel.Result) {
        if (owner != null || !foreground()) {
            result.error("unavailable", null, null)
            return
        }
        val pcm = bytes?.let { RouteNoteWav.decode(it) }
        if (pcm == null || pcm.durationMs > RouteNoteWav.MAX_SECONDS * 1000L) {
            result.error("invalid", null, null)
            return
        }
        if (!requestFocus()) {
            result.error("unavailable", null, null)
            return
        }
        val t = try {
            AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ASSISTANCE_NAVIGATION_GUIDANCE)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build(),
                )
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(pcm.rate)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                        .build(),
                )
                .setTransferMode(AudioTrack.MODE_STATIC)
                .setBufferSizeInBytes(pcm.samples.size * 2)
                .build()
        } catch (e: Exception) {
            Log.w(TAG, "AudioTrack 建立失敗", e)
            abandonFocus()
            result.error("unavailable", null, null)
            return
        }
        if (t.write(pcm.samples, 0, pcm.samples.size) != pcm.samples.size ||
            t.state != AudioTrack.STATE_INITIALIZED
        ) {
            t.release()
            abandonFocus()
            result.error("unavailable", null, null)
            return
        }
        owner = who
        track = t
        pendingPlay = result
        t.setPlaybackPositionUpdateListener(object : AudioTrack.OnPlaybackPositionUpdateListener {
            override fun onMarkerReached(track: AudioTrack?) { if (track === this@RouteNoteAudioPlugin.track) donePlaying() }
            override fun onPeriodicNotification(track: AudioTrack?) {}
        }, main)
        t.notificationMarkerPosition = pcm.samples.size
        // 部分機型不送 marker：以時長加餘量兜底。
        val fallback = Runnable { if (track === t) donePlaying() }
        playTimeout = fallback
        main.postDelayed(fallback, pcm.durationMs + 600)
        t.play()
    }

    private fun donePlaying() {
        val result = pendingPlay
        pendingPlay = null
        releaseTrack()
        owner = null
        abandonFocus()
        result?.success(null)
    }

    // ------------------------------------------------------------ 重設

    /** 停止一切，未完成的回覆以 cancelled 失敗。 */
    private fun reset() {
        pendingStart?.error("cancelled", null, null)
        pendingStart = null
        capture?.let { stopCapture(it) }
        capture = null
        pendingPlay?.error("cancelled", null, null)
        pendingPlay = null
        releaseTrack()
        owner = null
        abandonFocus()
    }

    private fun stopCapture(c: Capture) {
        c.running.set(false)
        c.thread?.join(500)
        try { c.record.stop() } catch (_: Exception) {}
        c.record.release()
    }

    private fun releaseTrack() {
        playTimeout?.let { main.removeCallbacks(it) }
        playTimeout = null
        val t = track ?: return
        track = null
        t.setPlaybackPositionUpdateListener(null)
        try { t.stop() } catch (_: Exception) {}
        t.release()
    }

    // ------------------------------------------------------------ 裝置

    private fun hasPermission(): Boolean =
        ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED

    private fun openRecorder(): Capture? {
        for (rate in RATES) {
            val min = AudioRecord.getMinBufferSize(rate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
            if (min <= 0) continue
            val r = try {
                AudioRecord(
                    MediaRecorder.AudioSource.MIC, rate,
                    AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT,
                    maxOf(min, rate / 5 * 2),
                )
            } catch (e: SecurityException) {
                return null
            } catch (e: Exception) {
                continue
            }
            if (r.state == AudioRecord.STATE_INITIALIZED) return Capture(r, rate, RouteNoteWav.sampleLimit(rate))
            r.release()
        }
        return null
    }

    private val focusListener = AudioManager.OnAudioFocusChangeListener { change ->
        // 閃避音量（CAN_DUCK）不算中斷；真正失去焦點才重設，對應 iOS 的音訊中斷。
        if (change == AudioManager.AUDIOFOCUS_LOSS || change == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT) {
            main.post { if (focus != null) reset() }
        }
    }

    private fun requestFocus(): Boolean {
        if (focus != null) return true
        val granted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val req = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE)
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ASSISTANCE_NAVIGATION_GUIDANCE)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build(),
                )
                .setOnAudioFocusChangeListener(focusListener, main)
                .build()
            (audio.requestAudioFocus(req) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED).also { if (it) focus = req }
        } else {
            @Suppress("DEPRECATION")
            (audio.requestAudioFocus(focusListener, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE) ==
                AudioManager.AUDIOFOCUS_REQUEST_GRANTED).also { if (it) focus = focusListener }
        }
        return granted
    }

    private fun abandonFocus() {
        val f = focus ?: return
        focus = null
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && f is AudioFocusRequest) {
            audio.abandonAudioFocusRequest(f)
        } else {
            @Suppress("DEPRECATION")
            audio.abandonAudioFocus(focusListener)
        }
    }
}

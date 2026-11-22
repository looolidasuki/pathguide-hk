package hk.pathguide.pathguide

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Matrix
import android.hardware.camera2.CameraCharacteristics
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.view.View
import androidx.annotation.OptIn
import androidx.camera.camera2.interop.Camera2CameraInfo
import androidx.camera.camera2.interop.ExperimentalCamera2Interop
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Android 錄路相機（`hk.pathguide/route_camera`），對應 iOS RouteCameraPlugin。
 *
 * 只負責「相機 → 最新一幀 → 依要求編成直立 JPEG 關鍵幀」：不載模型、不存檔、不連網。
 * 契約與 iOS 一致（session／generation／routeId／routeVersion 身分、事件、
 * 1 秒新鮮度、JPEG ≤ 512 KB 且長邊 ≤ 1280），但來源與時鐘誠實標為 CameraX：
 *   source = camerax-back，clockMapping = android-elapsed-realtime，
 *   captureClockId = camerax-session-<epoch>。
 * 感測器時間戳不是 elapsedRealtime 時基時，不估算、不冒充，回 unknown_clock。
 *
 * 所有狀態只在主線程改動；影格在分析線程只寫入加鎖的 [Mailbox]。
 */
class RouteCameraPlugin(private val context: Context) :
    FlutterPlugin,
    ActivityAware,
    EventChannel.StreamHandler,
    PluginRegistry.RequestPermissionsResultListener,
    DefaultLifecycleObserver {

    companion object {
        private const val TAG = "PathGuideRouteCamera"
        private const val METHODS = "hk.pathguide/route_camera"
        private const val EVENTS = "hk.pathguide/route_camera/events"
        private const val PREVIEW = "hk.pathguide/route_camera/preview"
        private const val REQ_CAMERA = 7302
        const val SOURCE = "camerax-back"
        const val PROFILE = "route-camera-engineering-v1"
        const val CLOCK_MAPPING = "android-elapsed-realtime"
        const val MAX_SIDE = 1280
        const val MAX_BYTES = 512 * 1024
        const val MAX_AGE_MS = 1000.0
        /** 分析線程複製影格的最短間隔：關鍵幀只需「1 秒內最新」，不必每幀複製。 */
        private const val COPY_INTERVAL_NS = 120_000_000L
    }

    private data class Ctx(
        val requestId: String,
        val session: String,
        val generation: Int,
        val routeId: String,
        val routeVersion: Int,
        val epoch: String = UUID.randomUUID().toString(),
    )

    /** 一份已複製的 RGBA 影格（不持有 ImageProxy，避免卡住 CameraX）。 */
    private class Frame(
        val ctx: Ctx,
        val sequence: Long,
        val rgba: ByteArray,
        val width: Int,
        val height: Int,
        val rotation: Int,
        val timestampNs: Long,
        val realtimeClock: Boolean,
    )

    /** 分析線程與主線程之間唯一共享的東西。 */
    private class Mailbox {
        private var ctx: Ctx? = null
        private var latest: Frame? = null
        private var sequence = 0L
        private var lastCopyNs = 0L
        @Volatile var realtimeClock = false

        @Synchronized fun activate(c: Ctx) { ctx = c; latest = null; sequence = 0; lastCopyNs = 0 }
        @Synchronized fun invalidate() { ctx = null; latest = null }
        @Synchronized fun snapshot(epoch: String): Frame? = if (ctx?.epoch == epoch) latest else null

        fun put(image: ImageProxy) {
            val c: Ctx
            synchronized(this) {
                c = ctx ?: return
                if (image.imageInfo.timestamp - lastCopyNs < COPY_INTERVAL_NS && latest != null) return
                lastCopyNs = image.imageInfo.timestamp
            }
            val plane = image.planes.firstOrNull() ?: return
            val w = image.width
            val h = image.height
            val rowBytes = w * 4
            val out = ByteArray(rowBytes * h)
            val buf = plane.buffer
            val stride = plane.rowStride
            for (y in 0 until h) {
                buf.position(y * stride)
                buf.get(out, y * rowBytes, rowBytes)
            }
            synchronized(this) {
                if (ctx?.epoch != c.epoch) return
                sequence += 1
                latest = Frame(
                    c, sequence, out, w, h, image.imageInfo.rotationDegrees,
                    image.imageInfo.timestamp, realtimeClock,
                )
            }
        }
    }

    private var methods: MethodChannel? = null
    private var events: EventChannel? = null
    private val main = Handler(Looper.getMainLooper())
    private val mailbox = Mailbox()
    private var analysisExecutor: ExecutorService? = null
    private val imageExecutor = Executors.newSingleThreadExecutor()

    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var ctx: Ctx? = null
    private var state = "stopped"
    private var sink: EventChannel.EventSink? = null
    private var subscriber: String? = null
    private var pending: Pair<String, MethodChannel.Result>? = null
    private var encodingToken: Any? = null
    private var permissionStart: (() -> Unit)? = null
    private var permissionDenied: (() -> Unit)? = null
    private var preview: PreviewView? = null
    private var previewUseCase: Preview? = null
    private var analysisUseCase: ImageAnalysis? = null

    // ------------------------------------------------------------ 註冊

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methods = MethodChannel(binding.binaryMessenger, METHODS).also {
            it.setMethodCallHandler { call, result -> handle(call, result) }
        }
        events = EventChannel(binding.binaryMessenger, EVENTS).also { it.setStreamHandler(this) }
        binding.platformViewRegistry.registerViewFactory(PREVIEW, PreviewFactory())
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        stop("stopped") {}
        methods?.setMethodCallHandler(null)
        events?.setStreamHandler(null)
        methods = null
        events = null
        imageExecutor.shutdown()
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) = attachActivity(binding)
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = attachActivity(binding)
    override fun onDetachedFromActivityForConfigChanges() = detachActivity()
    override fun onDetachedFromActivity() = detachActivity()

    private fun attachActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        activity = binding.activity
        binding.addRequestPermissionsResultListener(this)
        (binding.activity as? LifecycleOwner)?.lifecycle?.addObserver(this)
    }

    private fun detachActivity() {
        (activity as? LifecycleOwner)?.lifecycle?.removeObserver(this)
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null
        stop("paused") {}
        activity = null
    }

    /** 進入後台：與 iOS didEnterBackground 相同，停相機並回報 paused。 */
    override fun onStop(owner: LifecycleOwner) {
        if (state == "running" || state == "starting") stop("paused") {}
    }

    private fun isActive(): Boolean =
        (activity as? LifecycleOwner)?.lifecycle?.currentState?.isAtLeast(Lifecycle.State.STARTED) == true

    // ------------------------------------------------------------ 事件

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        subscriber = (arguments as? Map<*, *>)?.get("subscriber") as? String
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        if ((arguments as? Map<*, *>)?.get("subscriber") as? String != subscriber) return
        sink = null
        subscriber = null
        stop("stopped") {}
    }

    private fun ids(status: String): MutableMap<String, Any?> {
        val m = mutableMapOf<String, Any?>("status" to status)
        ctx?.let {
            m["session"] = it.session
            m["generation"] = it.generation
            m["routeId"] = it.routeId
            m["routeVersion"] = it.routeVersion
        }
        return m
    }

    private fun publish(status: String) {
        state = status
        sink?.success(ids(status))
    }

    // ------------------------------------------------------------ 方法

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "capabilities") {
            result.success(
                mapOf(
                    "camera" to true,
                    "authorization" to if (hasPermission()) "authorized" else "not_determined",
                    "profile" to PROFILE,
                    "maxKeyframeBytes" to MAX_BYTES,
                    "maxKeyframeSide" to MAX_SIDE,
                    "maxFrameAgeMs" to MAX_AGE_MS,
                    "walkingValidated" to false,
                ),
            )
            return
        }
        val args = call.arguments as? Map<*, *> ?: run { result.success(ids("bad_args")); return }
        if (call.method == "start") { start(args, result); return }
        val c = ctx
        if (c == null || args["session"] != c.session || (args["generation"] as? Number)?.toInt() != c.generation) {
            result.success(ids("stale_request"))
            return
        }
        when (call.method) {
            "status" -> result.success(ids(state))
            "stop" -> {
                val reply = ids("stopped")
                stop("stopped") { confirmed ->
                    if (!confirmed) reply["status"] = "stop_unconfirmed"
                    result.success(reply)
                }
            }
            "cancelKeyframe" -> {
                val id = args["requestId"] as? String
                if (id == null || pending?.first != id) {
                    result.success(ids("stale_request"))
                    return
                }
                val reply = ids("cancelled")
                cancelPending()
                result.success(reply)
            }
            "latestObservation", "captureKeyframe" -> {
                val requestId = args["requestId"] as? String
                if (requestId.isNullOrEmpty()) { result.success(ids("bad_args")); return }
                if (state != "running" || !isActive()) { result.success(ids("paused")); return }
                val frame = mailbox.snapshot(c.epoch) ?: run { result.success(ids("no_frame")); return }
                val header = header(frame, requestId)
                val validity = validity(header)
                if (validity != "available") {
                    result.success(mapOf("status" to validity, "header" to header))
                    return
                }
                if (call.method == "latestObservation") {
                    result.success(mapOf("status" to "available", "header" to header))
                    return
                }
                capture(frame, requestId, result)
            }
            else -> result.notImplemented()
        }
    }

    private fun header(frame: Frame, requestId: String): Map<String, Any?> {
        val c = frame.ctx
        val portrait = frame.rotation == 90 || frame.rotation == 270
        val h = mutableMapOf<String, Any?>(
            "requestId" to requestId,
            "startRequestId" to c.requestId,
            "session" to c.session,
            "generation" to c.generation,
            "routeId" to c.routeId,
            "routeVersion" to c.routeVersion,
            "sequence" to frame.sequence,
            "captureClockId" to "camerax-session-${c.epoch}",
            "clockEpoch" to c.epoch,
            "rawTimestampValue" to frame.timestampNs,
            "rawTimestampTimescale" to 1_000_000_000,
            "rawTimestampEpoch" to 0,
            "source" to SOURCE,
            "profile" to PROFILE,
            "rawWidth" to frame.width,
            "rawHeight" to frame.height,
            "uprightWidth" to if (portrait) frame.height else frame.width,
            "uprightHeight" to if (portrait) frame.width else frame.height,
            "rotationDegrees" to frame.rotation,
            "mirrored" to false,
            "clockMapping" to "unknown",
            "walkingValidated" to false,
        )
        if (frame.realtimeClock) {
            // 同一組數字算出 ageMs，Dart 會核對 |age - (now - captured)*1000| ≤ 0.01。
            val captured = frame.timestampNs / 1e9
            val now = SystemClock.elapsedRealtimeNanos() / 1e9
            h["clockMapping"] = CLOCK_MAPPING
            h["capturedHostSeconds"] = captured
            h["nativeNowHostSeconds"] = now
            h["ageMs"] = (now - captured) * 1000
        }
        return h
    }

    private fun validity(header: Map<String, Any?>): String {
        val age = header["ageMs"] as? Double ?: return "unknown_clock"
        if (!age.isFinite()) return "unknown_clock"
        if (age < 0) return "future_frame"
        return if (age <= MAX_AGE_MS) "available" else "stale_frame"
    }

    // ------------------------------------------------------------ start / stop

    private fun start(args: Map<*, *>, result: MethodChannel.Result) {
        val id = args["requestId"] as? String
        val session = args["session"] as? String
        val generation = (args["generation"] as? Number)?.toInt() ?: 0
        val route = args["routeId"] as? String
        val version = (args["routeVersion"] as? Number)?.toInt() ?: 0
        if (id.isNullOrEmpty() || session.isNullOrEmpty() || generation <= 0 || route.isNullOrEmpty() || version <= 0) {
            result.success(ids("bad_args"))
            return
        }
        if (!isActive()) { result.success(mapOf("status" to "paused")); return }
        ctx?.let {
            if (it.session == session && generation <= it.generation) {
                result.success(ids("stale_request"))
                return
            }
        }
        // 先提交新身分，再取消舊的擷取，避免回呼看到舊身分。
        val previousCapture = pending
        pending = null
        unbind()
        mailbox.invalidate()
        val next = Ctx(id, session, generation, route, version)
        ctx = next
        previousCapture?.second?.success(ids("cancelled"))
        publish("starting")

        val begin = begin@{
            if (ctx !== next || !isActive()) {
                result.success(mapOf("status" to "paused"))
                return@begin
            }
            bind(next, result)
        }
        if (hasPermission()) {
            begin()
            return
        }
        val act = activity
        if (act == null || permissionStart != null) {
            publish("permission")
            result.success(ids("permission"))
            return
        }
        permissionStart = begin
        permissionDenied = {
            if (ctx === next) {
                publish("permission")
                result.success(ids("permission"))
            } else {
                result.success(mapOf("status" to "paused"))
            }
        }
        act.requestPermissions(arrayOf(Manifest.permission.CAMERA), REQ_CAMERA)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != REQ_CAMERA) return false
        val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
        val onGranted = permissionStart
        val onDenied = permissionDenied
        permissionStart = null
        permissionDenied = null
        if (granted) onGranted?.invoke() else onDenied?.invoke()
        return true
    }

    private fun hasPermission(): Boolean =
        ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) ==
            PackageManager.PERMISSION_GRANTED

    @OptIn(ExperimentalCamera2Interop::class)
    private fun bind(next: Ctx, result: MethodChannel.Result) {
        val owner = activity as? LifecycleOwner
        if (owner == null) {
            publish("unavailable")
            result.success(ids("unavailable"))
            return
        }
        val future = ProcessCameraProvider.getInstance(context)
        future.addListener({
            if (ctx !== next) {
                result.success(mapOf("status" to "paused"))
                return@addListener
            }
            try {
                val provider = future.get()
                val executor = analysisExecutor ?: Executors.newSingleThreadExecutor().also { analysisExecutor = it }
                val previewUc = Preview.Builder().build()
                val analysis = ImageAnalysis.Builder()
                    .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                    .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_RGBA_8888)
                    .build()
                analysis.setAnalyzer(executor) { image ->
                    try { mailbox.put(image) } catch (e: Throwable) { Log.w(TAG, "frame copy failed", e) } finally { image.close() }
                }
                // 錄路與即時辨識不會同時使用相機；與 VisionPlugin 相同，綁定前清空舊用例。
                provider.unbindAll()
                val camera = provider.bindToLifecycle(owner, CameraSelector.DEFAULT_BACK_CAMERA, previewUc, analysis)
                val source = runCatching {
                    Camera2CameraInfo.from(camera.cameraInfo)
                        .getCameraCharacteristic(CameraCharacteristics.SENSOR_INFO_TIMESTAMP_SOURCE)
                }.getOrNull()
                mailbox.realtimeClock = source == CameraCharacteristics.SENSOR_INFO_TIMESTAMP_SOURCE_REALTIME
                if (!mailbox.realtimeClock) Log.w(TAG, "sensor timestamp source=$source is not realtime; keyframes report unknown_clock")
                previewUseCase = previewUc
                analysisUseCase = analysis
                preview?.let { previewUc.surfaceProvider = it.surfaceProvider }
                mailbox.activate(next)
                TaskWakeLock.set(activity?.window, "route_camera", true)
                publish("running")
                result.success(ids("running"))
            } catch (e: Throwable) {
                Log.e(TAG, "bind failed", e)
                unbind()
                if (ctx === next) publish("unavailable")
                result.success(ids("unavailable"))
            }
        }, ContextCompat.getMainExecutor(context))
    }

    private fun unbind() {
        val p = previewUseCase
        val a = analysisUseCase
        previewUseCase = null
        analysisUseCase = null
        a?.clearAnalyzer()
        if (p != null || a != null) {
            runCatching {
                ProcessCameraProvider.getInstance(context).get().unbind(*listOfNotNull(p, a).toTypedArray())
            }.onFailure { Log.w(TAG, "unbind failed", it) }
        }
        TaskWakeLock.set(activity?.window, "route_camera", false)
    }

    private fun stop(status: String, completion: (Boolean) -> Unit) {
        val stopping = ctx
        val interim = if (status == "stopped") "stopping" else status
        mailbox.invalidate()
        cancelPending()
        if (stopping != null) publish(interim) else state = interim
        unbind()
        permissionStart = null
        permissionDenied = null
        if (ctx === stopping && stopping != null) publish(status) else state = status
        completion(true)
    }

    private fun cancelPending() {
        val old = pending
        pending = null
        old?.second?.success(ids("cancelled"))
    }

    // ------------------------------------------------------------ 關鍵幀

    private fun capture(frame: Frame, requestId: String, result: MethodChannel.Result) {
        if (encodingToken != null) { result.success(ids("busy")); return }
        val token = Any()
        encodingToken = token
        pending = requestId to result
        imageExecutor.execute {
            val encoded = runCatching { encode(frame) }
            main.post {
                if (encodingToken === token) encodingToken = null
                if (pending?.first != requestId || pending?.second !== result) return@post
                pending = null
                if (ctx?.epoch != frame.ctx.epoch || state != "running" || !isActive()) {
                    result.success(ids("paused"))
                    return@post
                }
                val header = header(frame, requestId)
                val validity = validity(header)
                if (validity != "available") {
                    result.success(mapOf("status" to validity, "header" to header))
                    return@post
                }
                val value = encoded.getOrNull()
                if (value == null) {
                    Log.w(TAG, "keyframe encoding failed", encoded.exceptionOrNull())
                    result.success(ids("encoding_failed"))
                    return@post
                }
                result.success(
                    mapOf(
                        "status" to "captured",
                        "header" to header,
                        "jpeg" to value.bytes,
                        "sha256" to sha256(value.bytes),
                        "width" to value.width,
                        "height" to value.height,
                        "orientation" to "up",
                        "byteCount" to value.bytes.size,
                    ),
                )
            }
        }
    }

    private class Encoded(val bytes: ByteArray, val width: Int, val height: Int)

    /** 直立、長邊 ≤ 1280、不寫 EXIF 方向；最多三個品質嘗試，超過上限即失敗。 */
    private fun encode(frame: Frame): Encoded {
        val raw = Bitmap.createBitmap(frame.width, frame.height, Bitmap.Config.ARGB_8888)
        try {
            raw.copyPixelsFromBuffer(ByteBuffer.wrap(frame.rgba))
            val portrait = frame.rotation == 90 || frame.rotation == 270
            val uprightW = if (portrait) frame.height else frame.width
            val uprightH = if (portrait) frame.width else frame.height
            val factor = min(1.0, MAX_SIDE.toDouble() / max(uprightW, uprightH))
            val matrix = Matrix().apply {
                postRotate(frame.rotation.toFloat())
                postScale(factor.toFloat(), factor.toFloat())
            }
            val upright = Bitmap.createBitmap(raw, 0, 0, frame.width, frame.height, matrix, true)
            try {
                val expectedW = (uprightW * factor).roundToInt()
                val expectedH = (uprightH * factor).roundToInt()
                check(upright.width in (expectedW - 1)..(expectedW + 1) && upright.height in (expectedH - 1)..(expectedH + 1))
                check(max(upright.width, upright.height) <= MAX_SIDE)
                for (quality in intArrayOf(80, 60, 40)) {
                    val out = ByteArrayOutputStream()
                    upright.compress(Bitmap.CompressFormat.JPEG, quality, out)
                    val bytes = out.toByteArray()
                    if (bytes.size in 4..MAX_BYTES) return Encoded(bytes, upright.width, upright.height)
                }
                error("keyframe exceeds $MAX_BYTES bytes")
            } finally {
                if (upright !== raw) upright.recycle()
            }
        } finally {
            raw.recycle()
        }
    }

    private fun sha256(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    // ------------------------------------------------------------ 預覽

    private fun attachPreview(view: PreviewView) {
        preview = view
        previewUseCase?.surfaceProvider = view.surfaceProvider
    }

    private fun detachPreview(view: PreviewView) {
        if (preview === view) {
            preview = null
            previewUseCase?.surfaceProvider = null
        }
    }

    private inner class PreviewFactory : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
        @SuppressLint("ClickableViewAccessibility")
        override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
            val view = PreviewView(context).apply {
                implementationMode = PreviewView.ImplementationMode.COMPATIBLE
                scaleType = PreviewView.ScaleType.FIT_CENTER
                setBackgroundColor(android.graphics.Color.BLACK)
                // 預覽只是畫面，讀屏不應聚焦（與 iOS accessibilityElementsHidden 一致）。
                importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
            }
            attachPreview(view)
            return object : PlatformView {
                override fun getView(): View = view
                override fun dispose() = detachPreview(view)
            }
        }
    }
}

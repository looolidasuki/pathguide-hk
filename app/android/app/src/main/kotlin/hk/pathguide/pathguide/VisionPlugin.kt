package hk.pathguide.pathguide

import android.content.Context
import android.util.Log
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import org.tensorflow.lite.Interpreter
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import kotlin.math.max
import kotlin.math.min

/**
 * Android 侧视觉插件：CameraX 取帧 + LiteRT 推理 + 平台通道回传。
 *
 * ## 为什么推理放在原生侧
 *
 * `ImageProxy.planes[0]` 是 Y（亮度）平面的**直接内存映射**，原生侧零拷贝可读。
 * 若把整帧 `w*h*1.5` 字节经平台通道搬到 Dart，每帧要多一次跨语言拷贝，
 * 且 Dart 里没有硬件加速的 YUV→RGB。所以取帧、旋转、letterbox、推理、NMS
 * **全在 Kotlin**，只有归一化后的框过通道。
 *
 * ## 与 Dart 的契约
 *
 * 键名全部来自 `lib/vision/platform_contract.dart`，本文件不得自行发明字符串。
 *
 * - `hk.pathguide/vision`         MethodChannel：loadModel / detect / release / status
 * - `hk.pathguide/vision/frame`   EventChannel：逐帧推检测结果
 * - `hk.pathguide/vision/preview` 平台视图：相机预览
 */
class VisionPlugin(
    private val context: Context,
) : FlutterPlugin, ActivityAware, PluginRegistry.RequestPermissionsResultListener {

    companion object {
        const val TAG = "PathGuideVision"
        const val METHOD_CHANNEL = "hk.pathguide/vision"
        const val FRAME_CHANNEL = "hk.pathguide/vision/frame"
        const val PREVIEW_VIEW = "hk.pathguide/vision/preview"

        /**
         * 历史常量：早期版本从 AssetManager 读模型用的路径。
         *
         * **已不再使用**，保留仅为记录这段经历，避免以后有人再走同一条路：
         * 真机（Redmi / Android 16 / HyperOS）上 `AssetManager.open()` 读
         * `flutter_assets/assets/models/detector.tflite` 必然 FileNotFoundException，
         * 而同一次运行里 `assets.list()` 递归又能列出这个路径——ROM 行为与
         * Android 文档约定不符，改路径试了三轮都无效。
         *
         * 现在模型由 Dart 侧用 rootBundle 读出、写入应用私有目录（见 modelDir /
         * writeFile 两个方法），Kotlin 只读文件，彻底绕开 AssetManager。
         */
        @Suppress("unused")
        const val LEGACY_MODEL_ASSET = "flutter_assets/assets/models/detector.tflite"

        /** 期望输入边长；模型若声明了固定形状则以模型为准。 */
        const val EXPECTED_INPUT_SIZE = 640

        /** 相机权限请求码。 */
        private const val REQ_CAMERA = 7301
    }

    private var methodChannel: MethodChannel? = null
    private var frameChannel: EventChannel? = null

    /** 当前 Activity。权限请求需要它，由 ActivityAware 回调注入。 */
    private var activity: android.app.Activity? = null

    /** 等待权限结果的 startPreview 调用。同一时刻只允许一个。 */
    private var pendingPermissionResult: MethodChannel.Result? = null

    @Volatile private var eventSink: EventChannel.EventSink? = null

    @Volatile var detector: YoloDetector? = null
        private set

    /** 实际加载成功的模型路径。报给 Dart 的是**真实发生过的事**，不是猜的常量。 */
    @Volatile var loadedModelPath: String? = null
        private set

    @Volatile var currentPreview: PreviewView? = null
        private set

    @Volatile var threshold: Float = 0.30f

    // ---- 诊断计数器：全部随每帧结果回传，直接显示在 HUD 上 ----
    // 加的动机：曾出现「预览正常、但推理 0 次」的情况，而当时**拿不到任何计数**，
    // 只能靠反复重新构建来猜。这类问题必须能让用户在屏幕上自己看到。
    @Volatile var analyzedFrames: Long = 0
        private set
    @Volatile var analyzeErrors: Long = 0
        private set

    /** 最近一帧被跳过的原因（空串表示正常处理）。 */
    @Volatile var lastAnalyzeSkip: String = "尚未收到任何帧"
        private set

    @Volatile var lastFrameWidth: Int = 0
        private set
    @Volatile var lastFrameHeight: Int = 0
        private set

    /** 最近一帧的格式描述（平面数、旋转角、UV 步长），用于核对取帧假设。 */
    @Volatile var lastFrameFormat: String = ""
        private set

    /** 最近一帧的最高置信度（**不受阈值影响**），用于判断「模型有没有给出高分」。 */
    @Volatile var lastMaxScore: Float = 0f
        private set

    private var cameraExecutor: ExecutorService? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val messenger: BinaryMessenger = binding.binaryMessenger
        methodChannel = MethodChannel(messenger, METHOD_CHANNEL).apply {
            setMethodCallHandler(::onMethodCall)
        }
        frameChannel = EventChannel(messenger, FRAME_CHANNEL).apply {
            setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            })
        }
        binding.platformViewRegistry.registerViewFactory(
            PREVIEW_VIEW,
            VisionPreviewFactory(context, this),
        )
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel?.setMethodCallHandler(null)
        frameChannel?.setStreamHandler(null)
        methodChannel = null
        frameChannel = null
        eventSink = null
        stopCamera()
        detector?.close()
        detector = null
    }

    // ------------------------------------------------------------------ 方法

    private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "loadModel" -> result.success(loadModel(call))
            "detect" -> result.success(detect(call))
            "setThreshold" -> {
                val v = call.argument<Double>("threshold")
                if (v == null) {
                    result.error("bad_args", "缺少 threshold", null)
                } else {
                    threshold = v.toFloat().coerceIn(0f, 1f)
                    Log.i(TAG, "阈值更新为 ${threshold}")
                    result.success(null)
                }
            }
            // Dart 侧请求启动相机。**这里同时负责申请权限**：
            // 权限是运行时申请的，若只在插件构造时检查一次，用户授权后
            // 原生侧仍停留在「无权限」，相机永不启动，表现为一片黑且无报错。
            //
            // 刻意不用 permission_handler 包：它会传递引入 objective_c，
            // 后者的 build hook 在含空格的路径上会让 `flutter test` 失败。
            // 见 pubspec.yaml 里的说明。
            "startPreview" -> requestPermissionThenStart(result)

            // ---- 模型落盘支持 ----
            // 实测某些 ROM 上 AssetManager 读不到 flutter_assets 下的资源，
            // 因此改为 Dart 用 rootBundle 读出、写到这里、原生再读文件。
            "modelDir" -> result.success(context.filesDir.absolutePath)

            "writeFile" -> {
                val path = call.argument<String>("path")
                val bytes = call.argument<ByteArray>("bytes")
                if (path == null || bytes == null) {
                    result.error("bad_args", "缺少 path 或 bytes", null)
                } else {
                    runCatching {
                        val f = java.io.File(path)
                        f.parentFile?.mkdirs()
                        f.writeBytes(bytes)
                    }.onSuccess {
                        Log.i(TAG, "已写入 ${bytes.size / 1024} KB -> $path")
                        result.success(null)
                    }.onFailure {
                        Log.e(TAG, "写入失败：$path", it)
                        result.error("write_failed", "${it.javaClass.simpleName}: ${it.message}", null)
                    }
                }
            }

            "fileSize" -> {
                val path = call.argument<String>("path")
                val f = if (path == null) null else java.io.File(path)
                result.success(if (f != null && f.exists()) f.length() else -1L)
            }
            "release" -> {
                stopCamera()
                detector?.close()
                detector = null
                result.success(null)
            }
            "status" -> result.success(
                mapOf(
                    "ready" to (detector != null),
                    // 报实际加载成功的那个路径，不是猜的常量。
                    "modelPath" to loadedModelPath,
                    "inputSize" to (detector?.inputSize ?: EXPECTED_INPUT_SIZE),
                    "classes" to (detector?.numClasses ?: 0),
                    // 诊断计数：让 Dart 能在界面上显示「分析了几帧、为什么跳过」。
                    // 这些信息以前只能通过 logcat 看，而用户手上没有 logcat。
                    "analyzedFrames" to analyzedFrames,
                    "analyzeErrors" to analyzeErrors,
                    "skippedReason" to lastAnalyzeSkip,
                    "frameWidth" to lastFrameWidth,
                    "frameHeight" to lastFrameHeight,
                    "frameFormat" to lastFrameFormat,
                    "frameMaxScore" to lastMaxScore.toDouble(),
                    "threshold" to threshold.toDouble(),
                ),
            )
            else -> result.notImplemented()
        }
    }

    /**
     * 加载模型，返回 `{loaded, classes, inputSize}`（失败时附 `error`）。
     *
     * 模型缺失时**不抛异常**：demo 在没有模型时仍要能跑界面（配假数据源），
     * 抛异常会让画面白屏，反而看不出问题出在哪。
     *
     * 入参 `model` 是**绝对文件路径**（由 Dart 侧用 rootBundle 把资源落盘得到）。
     * 不再依赖 AssetManager —— 实测在某些 ROM 上 `AssetManager.open()` 读
     * `flutter_assets/...` 必然 FileNotFoundException，而同一次运行里
     * `assets.list()` 又能列出该路径，即 ROM 行为与文档约定不符。
     */
    private fun loadModel(call: MethodCall): Map<String, Any?> {
        val path = call.argument<String>("model")
        // 单类模型需要把输出 id 0 偏移到项目类别表里的真实 id（垃圾桶 = 7）。
        // 偏移在原生侧完成，Dart 之后的画框/播报/查表无需改动。
        val offset = call.argument<Int>("classOffset") ?: 0
        detector?.close()
        detector = null
        loadedModelPath = null

        if (path.isNullOrBlank()) {
            return mapOf(
                "loaded" to false, "classes" to 0, "inputSize" to EXPECTED_INPUT_SIZE,
                "error" to "Dart 侧没有给出模型文件路径（model 参数为空）",
            )
        }
        val f = java.io.File(path)
        if (!f.exists()) {
            val dir = f.parentFile
            val siblings = dir?.listFiles()?.joinToString(", ") { it.name } ?: "（目录不存在）"
            return mapOf(
                "loaded" to false, "classes" to 0, "inputSize" to EXPECTED_INPUT_SIZE,
                "error" to "文件不存在：$path（同目录下有：$siblings）",
            )
        }

        return try {
            // ★ LiteRT 不接受堆缓冲 `ByteBuffer.wrap(byte[])`，会抛
            //     IllegalArgumentException: Model ByteBuffer should be either a
            //     MappedByteBuffer of the model file, or a direct ByteBuffer using
            //     ByteOrder.nativeOrder()
            // 所以用**文件内存映射**：既满足要求，又省掉一次 10 MB 的内存拷贝。
            // 这也正是当初该直接用文件路径、而不是先在 Dart 侧读成字节的原因之一。
            val det = YoloDetector.fromFile(f, EXPECTED_INPUT_SIZE)
            det.classOffset = offset
            detector = det
            loadedModelPath = path
            startCameraIfPossible()
            Log.i(
                TAG,
                "模型已加载：$path（${f.length() / 1024} KB, ${det.numClasses} 类, " +
                    "类偏移 $offset）",
            )
            mapOf(
                "loaded" to true,
                "classes" to det.numClasses,
                "inputSize" to det.inputSize,
                "modelPath" to path,
                "classOffset" to offset,
            )
        } catch (e: Exception) {
            Log.w(TAG, "模型加载失败：$path", e)
            mapOf(
                "loaded" to false, "classes" to 0, "inputSize" to EXPECTED_INPUT_SIZE,
                "error" to "读文件/建解释器失败 ${e.javaClass.simpleName}: ${e.message}",
            )
        }
    }

    /**
     * 单帧推理（回放 / 调试路径）。实时相机路径不走这里，走 EventChannel，
     * 省掉一次整帧跨通道拷贝。
     *
     * ## 需要完整的 YUV，不能只给 Y
     *
     * 模型要 RGB 输入。只给 Y 平面时这里用 U=V=128（中性灰）补齐，
     * 结果是**灰度**输入——实测置信度会掉到阈值以下，等于检测不到。
     * 所以调用方应当通过 `u` / `v` 传真实色度；只有明确知道不需要颜色时
     * 才省略它们（例如把检测当作纯几何验证）。
     *
     * 这条限制是真机上踩出来的：早期版本只传 Y，24 类模型在真机上一个框都不出，
     * 排查了很久才定位到颜色空间不匹配。
     */
    private fun detect(call: MethodCall): Map<String, Any?> {
        val det = detector
            ?: return mapOf("detections" to emptyList<Any>(), "inferenceMs" to 0.0,
                "error" to "模型未加载")
        val y = call.argument<ByteArray>("bytes")
            ?: return mapOf("detections" to emptyList<Any>(), "inferenceMs" to 0.0,
                "error" to "缺少 bytes（Y 平面）")
        val w = call.argument<Int>("frameWidth")
            ?: return mapOf("detections" to emptyList<Any>(), "inferenceMs" to 0.0,
                "error" to "缺少 frameWidth")
        val h = call.argument<Int>("frameHeight")
            ?: return mapOf("detections" to emptyList<Any>(), "inferenceMs" to 0.0,
                "error" to "缺少 frameHeight")
        val rotation = call.argument<Int>("rotationDegrees") ?: 0
        val thr = (call.argument<Double>("threshold") ?: threshold.toDouble()).toFloat()

        val cw = (w + 1) / 2
        val ch = (h + 1) / 2
        val uBytes = call.argument<ByteArray>("u")
        val vBytes = call.argument<ByteArray>("v")
        val u = if (uBytes != null && uBytes.size >= cw * ch) uBytes
                else ByteArray(cw * ch) { 128.toByte() }
        val v = if (vBytes != null && vBytes.size >= cw * ch) vBytes
                else ByteArray(cw * ch) { 128.toByte() }

        val dets = det.detectYuv(
            y, u, v, w, h,
            uvRowStride = cw, uvPixelStride = 1,
            rotationDegrees = rotation, threshold = thr,
        )
        return mapOf(
            "detections" to dets.map { it.toMap() },
            "inferenceMs" to det.lastInferenceMs,
        )
    }

    // ------------------------------------------------------------------ 相机

    // -------------------------------------------------------------- 权限

    private fun hasCameraPermission(): Boolean =
        ContextCompat.checkSelfPermission(context, android.Manifest.permission.CAMERA) ==
            android.content.pm.PackageManager.PERMISSION_GRANTED

    /**
     * 申请相机权限，拿到结果后启动相机，并把结果回给 Dart。
     *
     * 回包 `{started, granted}`：`granted=false` 表示用户拒绝，
     * Dart 侧要给出可操作的提示，而不是静默黑屏。
     */
    private fun requestPermissionThenStart(result: MethodChannel.Result) {
        if (hasCameraPermission()) {
            startCameraIfPossible()
            result.success(mapOf("started" to true, "granted" to true))
            return
        }
        val act = activity ?: run {
            Log.w(TAG, "没有 Activity，无法申请权限")
            result.success(mapOf("started" to false, "granted" to false))
            return
        }
        if (pendingPermissionResult != null) {
            // 前一次请求还没回来。直接失败而不是覆盖，避免结果丢失。
            result.error("busy", "上一次权限请求尚未返回", null)
            return
        }
        pendingPermissionResult = result
        act.requestPermissions(arrayOf(android.Manifest.permission.CAMERA), REQ_CAMERA)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != REQ_CAMERA) return false
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == android.content.pm.PackageManager.PERMISSION_GRANTED
        val pending = pendingPermissionResult
        pendingPermissionResult = null
        if (granted) {
            startCameraIfPossible()
            pending?.success(mapOf("started" to true, "granted" to true))
        } else {
            Log.w(TAG, "用户拒绝了相机权限")
            pending?.success(mapOf("started" to false, "granted" to false))
        }
        return true
    }

    // ------------------------------------------------- ActivityAware 回调

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        failPendingPermission("Activity 正在重建")
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivity() {
        failPendingPermission("Activity 已分离")
        activity = null
    }

    /** 权限回调永远不会来了（Activity 销毁/重建）时必须给 Dart 一个结果，
     *  否则 startPreview 的 Future 永不完成，界面上表现为卡在「正在初始化」。 */
    private fun failPendingPermission(reason: String) {
        val pending = pendingPermissionResult ?: return
        pendingPermissionResult = null
        pending.success(mapOf("started" to false, "granted" to false, "reason" to reason))
    }

    fun onPreviewCreated(view: PreviewView) {
        currentPreview = view
        startCameraIfPossible()
    }

    fun startCameraIfPossible() {
        val view = currentPreview ?: return
        if (detector == null) return
        // 每次**动态**检查权限。缓存这个结果会导致：用户在 Dart 侧授权之后，
        // 原生侧仍认为无权限，相机永远不启动，屏幕上只有一片黑、也没有异常。
        if (!hasCameraPermission()) {
            Log.w(TAG, "尚未授予相机权限，预览不启动；授权后请调用 startPreview")
            return
        }
        val future = ProcessCameraProvider.getInstance(context)
        future.addListener({
            runCatching { bindCamera(future.get(), view) }
                .onFailure { Log.e(TAG, "绑定相机会话失败", it) }
        }, ContextCompat.getMainExecutor(context))
    }

    private fun bindCamera(provider: ProcessCameraProvider, view: PreviewView) {
        // 必须用 ActivityAware 注入的 activity，**不能用插件构造时的 context**：
        // Flutter 传给插件的 context 是 Activity 的包装上下文，
        // (context as? LifecycleOwner) 永远为 null，相机就永远绑不上——
        // 表现为预览一片黑，日志里只有一行「不是 LifecycleOwner」。
        val owner = activity as? LifecycleOwner
        if (owner == null) {
            Log.e(TAG, "activity 不是 LifecycleOwner，无法绑定相机生命周期")
            return
        }
        val previewUseCase = Preview.Builder().build().also {
            it.surfaceProvider = view.surfaceProvider
        }
        val executor = cameraExecutor
            ?: Executors.newSingleThreadExecutor().also { cameraExecutor = it }
        val analysis = ImageAnalysis.Builder()
            .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
            .build()
            .also { it.setAnalyzer(executor) { proxy -> analyze(proxy) } }

        provider.unbindAll()
        provider.bindToLifecycle(
            owner, CameraSelector.DEFAULT_BACK_CAMERA, previewUseCase, analysis,
        )
        Log.i(TAG, "相机会话已启动（预览 + 分析）")
    }

    fun stopCamera() {
        runCatching {
            ProcessCameraProvider.getInstance(context).get().unbindAll()
        }.onFailure { Log.w(TAG, "解绑相机失败（通常可忽略）", it) }
        cameraExecutor?.shutdown()
        cameraExecutor = null
        currentPreview = null
        // 停止后重置诊断计数，避免「上一轮运行的帧数」被误读成当前状态。
        analyzedFrames = 0
        analyzeErrors = 0
        lastAnalyzeSkip = "相机已停止"
        lastFrameFormat = ""
        lastMaxScore = 0f
    }

    /** 单帧分析：YUV -> 检测 -> EventChannel。
     *
     * 取全部三个平面（Y / U / V），因为模型需要 RGB 输入；
     * 只取 Y 当灰度的做法实测会让置信度掉到阈值以下（详见 detectYuv 的说明）。
     *
     * 每个 return 分支都会累加 [analyzedFrames] 与 [lastAnalyzeSkip]，并把计数
     * 随结果一起回传。**这是刻意的**：曾出现「预览正常但推理 0 次」的情况，
     * 而当时拿不到任何计数信息，只能靠猜。现在 HUD 会直接显示「分析 N 帧」。
     */
    private fun analyze(image: ImageProxy) {
        // 必须无论成败都 close，否则 CameraX 停止投递新帧，表现为画面卡死。
        try {
            analyzedFrames++
            val det = detector
            if (det == null) { lastAnalyzeSkip = "模型未就绪"; return }
            if (currentPreview == null) { lastAnalyzeSkip = "预览未就绪"; return }
            if (det.isBusy) { lastAnalyzeSkip = "上一帧仍在推理"; return }
            lastAnalyzeSkip = ""

            val w = image.width
            val h = image.height
            val rotation = image.imageInfo.rotationDegrees
            if (image.planes.size < 3) {
                lastAnalyzeSkip = "帧平面数 ${image.planes.size} < 3"
                Log.w(TAG, "帧平面数 ${image.planes.size} < 3，无法做 YUV->RGB，丢弃该帧")
                return
            }
            val yPlane = image.planes[0]
            val uPlane = image.planes[1]
            val vPlane = image.planes[2]
            val yBytes = copyPlane(yPlane.buffer, yPlane.rowStride, w, h, yPlane.pixelStride)
            // UV 平面是 2x2 下采样，按半宽半高取
            val cw = (w + 1) / 2
            val ch = (h + 1) / 2
            val uBytes = copyPlane(uPlane.buffer, uPlane.rowStride, cw, ch, uPlane.pixelStride)
            val vBytes = copyPlane(vPlane.buffer, vPlane.rowStride, cw, ch, vPlane.pixelStride)
            if (yBytes == null || uBytes == null || vBytes == null) {
                lastAnalyzeSkip = "取平面失败"
                return
            }

            val t0 = System.nanoTime()
            val detections = det.detectYuv(
                yBytes, uBytes, vBytes,
                w, h,
                uPlane.rowStride, uPlane.pixelStride,
                rotation, threshold,
            )
            // 只统计纯推理耗时，不含取帧与转换——否则看不出瓶颈在哪。
            val ms = (System.nanoTime() - t0) / 1_000_000.0
            lastFrameWidth = w
            lastFrameHeight = h
            lastFrameFormat = "YUV420 planes=${image.planes.size} rot=$rotation " +
                "uvStride=${uPlane.rowStride}/${uPlane.pixelStride}"
            lastMaxScore = detections.maxOfOrNull { it.score } ?: 0f

            val sink = eventSink ?: run { lastAnalyzeSkip = "EventSink 未连接"; return }
            val payload = mapOf(
                "detections" to detections.map { it.toMap() },
                "inferenceMs" to ms,
                "frameWidth" to w,
                "frameHeight" to h,
                "analyzedFrames" to analyzedFrames,
                "skippedReason" to lastAnalyzeSkip,
                "frameMaxScore" to lastMaxScore.toDouble(),
                "frameFormat" to lastFrameFormat,
            )
            ContextCompat.getMainExecutor(context).execute { sink.success(payload) }
        } catch (e: Exception) {
            analyzeErrors++
            lastAnalyzeSkip = "异常 ${e.javaClass.simpleName}: ${e.message}"
            Log.w(TAG, "分析帧失败", e)
        } finally {
            image.close()
        }
    }

    /**
     * 从 `ImageBuffer` 拷出指定尺寸的平面。
     *
     * `rowStride` 可能大于逻辑宽度（硬件按 16/32 字节对齐），也可能带
     * `pixelStride`。按 `rowStride` 逐行定位是**必须**的：直接顺序读会在
     * 非对齐设备上产生斜纹伪影，而且不报错。
     */
    private fun copyPlane(
        buffer: java.nio.ByteBuffer,
        rowStride: Int,
        width: Int,
        height: Int,
        pixelStride: Int,
    ): ByteArray? {
        val out = ByteArray(width * height)
        buffer.rewind()
        val stride0 = pixelStride.coerceAtLeast(1)
        if (rowStride == width * stride0) {
            // 紧凑布局：可直接连续读
            val need = out.size * stride0
            if (stride0 == 1) {
                buffer.get(out, 0, min(out.size, buffer.remaining()))
            } else {
                var o = 0
                var i = 0
                while (o < out.size && i + stride0 <= buffer.remaining()) {
                    out[o++] = buffer.get(i)
                    i += stride0
                }
            }
            if (need <= 0) return null
            return out
        }
        val row = ByteArray(rowStride.coerceAtLeast(width * stride0))
        var o = 0
        for (y in 0 until height) {
            val pos = y * rowStride
            if (pos >= buffer.limit()) break
            buffer.position(pos)
            val n = min(row.size, buffer.remaining())
            buffer.get(row, 0, n)
            var x = 0
            while (x < width) {
                val src = x * stride0
                if (src >= n || o >= out.size) break
                out[o++] = row[src]
                x++
            }
        }
        return out
    }

    // 注：早期这里有一个只取 Y 平面的 readYPlane()。已删除，不再保留死代码。
    // 它对应的灰度输入路径实测会让置信度掉到阈值以下（0.04~0.55 vs RGB 的 0.62~0.82），
    // 表现为「模型明明没问题却检测不到」。现在统一用 copyPlane 取齐 Y/U/V 再做
    // YUV->RGB。要了解详情见 YoloDetector.detectYuv 的注释。
}

/** 预览平台视图。 */
class VisionPreview(private val view: PreviewView) : PlatformView {
    override fun getView(): android.view.View = view
    override fun dispose() {}
}

class VisionPreviewFactory(
    private val context: Context,
    private val plugin: VisionPlugin,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(viewContext: Context?, id: Int, args: Any?): PlatformView {
        val v = PreviewView(context)
        v.implementationMode = PreviewView.ImplementationMode.COMPATIBLE
        v.scaleType = PreviewView.ScaleType.FIT_CENTER
        plugin.onPreviewCreated(v)
        return VisionPreview(v)
    }
}

/** 一个检测框，归一化 YOLO 坐标。键名与 platform_contract.dart 一致。 */
data class Detection(
    val id: Int,
    val score: Float,
    val cx: Float,
    val cy: Float,
    val w: Float,
    val h: Float,
) {
    fun toMap(): Map<String, Any> = mapOf(
        "id" to id,
        "score" to score.toDouble(),
        "cx" to cx.toDouble(),
        "cy" to cy.toDouble(),
        "w" to w.toDouble(),
        "h" to h.toDouble(),
    )
}

/**
 * YOLO 检测器：旋转 + letterbox + LiteRT 推理 + 解码 + NMS。
 *
 * 输出张量按 Ultralytics YOLO11 检测头为 `[1, 4+nc, anchors]`。
 * 类别数**从张量形状反推**，不信任外部类别表——模型与类别表不一致时
 * 靠形状就能发现，比静默错位好。
 */
class YoloDetector private constructor(
    private val interpreter: Interpreter,
    expectedInput: Int,
) {
    companion object {
        /**
         * 从**文件路径**构建，用内存映射。
         *
         * LiteRT 的 `Interpreter` 要求模型缓冲是 `MappedByteBuffer` 或
         * 原生字节序的直接缓冲；传 `ByteBuffer.wrap(byte[])`（堆缓冲）会抛
         * IllegalArgumentException: Model ByteBuffer should be either a
         * MappedByteBuffer of the model file, or a direct ByteBuffer...
         * 内存映射同时省掉一次整模型的内存拷贝。
         */
        fun fromFile(file: java.io.File, expectedInput: Int): YoloDetector {
            val mapped = java.io.RandomAccessFile(file, "r").use { raf ->
                raf.channel.map(
                    java.nio.channels.FileChannel.MapMode.READ_ONLY, 0, raf.length(),
                )
            }
            return YoloDetector(
                Interpreter(mapped, Interpreter.Options().apply { setNumThreads(4) }),
                expectedInput,
            )
        }
    }

    val inputSize: Int
    val numClasses: Int
    private val numAnchors: Int

    /** 输出是否为 `[1, anchors, 4+nc]`。不同导出设置会不同，必须按形状判断。 */
    private val transposed: Boolean

    private val inputBuffer: ByteBuffer
    private val outputBuffer: ByteBuffer

    @Volatile private var busy = false
    val isBusy: Boolean get() = busy

    /**
     * 类别 id 偏移：加到模型输出的每个 id 上再回传。
     *
     * 用处：单类模型（只认垃圾桶）输出 id 0，而项目类别表 `kLabels[0]` 是
     * `footbridge_entrance`。若原样回传，界面会把垃圾桶标成「天橋入口」——
     * **框对、名字错，且不报任何错**。
     * 传 `bin` 的原始 id（7）作偏移后，Dart 侧画框/播报/查表全部无需改动。
     * 多类模型传 0。
     */
    @Volatile var classOffset: Int = 0

    @Volatile var lastInferenceMs: Double = 0.0
        private set

    init {
        val inShape = interpreter.getInputTensor(0).shape()
        require(inShape.size == 4) { "输入张量应为 4 维，实际 ${inShape.toList()}" }
        require(inShape[3] == 3) { "输入通道应为 3，实际 ${inShape[3]}" }
        inputSize = if (inShape[1] > 0) inShape[1] else expectedInput

        val outShape = interpreter.getOutputTensor(0).shape()
        require(outShape.size == 3) { "输出张量应为 3 维，实际 ${outShape.toList()}" }
        val d1 = outShape[1]
        val d2 = outShape[2]
        transposed = d1 < d2
        val channels = min(d1, d2)
        numAnchors = max(d1, d2)
        numClasses = channels - 4
        require(numClasses > 0) { "无法从输出形状 ${outShape.toList()} 推出类别数" }

        inputBuffer = ByteBuffer
            .allocateDirect(inputSize * inputSize * 3)
            .order(ByteOrder.nativeOrder())
        outputBuffer = ByteBuffer
            .allocateDirect(4 * numAnchors * channels)
            .order(ByteOrder.nativeOrder())

        Log.i(
            VisionPlugin.TAG,
            "模型就绪 input=$inputSize classes=$numClasses anchors=$numAnchors " +
                "transposed=$transposed",
        )
    }

    fun close() {
        runCatching { interpreter.close() }
    }

    /**
     * 用 YUV 帧推理（**转成 RGB**）。
     *
     * ## 曾经犯过的错误：为了速度喂灰度
     *
     * 早期版本只读 `planes[0]`（Y 亮度）当灰度输入，理由是省掉每帧 5–15 ms 的
     * YUV→RGB，并判断「垃圾桶靠形状就能认，颜色不是关键特征」。
     *
     * **那个判断是错的。** 实测同一模型、同一批图（模拟完整预处理流程）：
     *
     *     输入 RGB  -> 最高分 0.62 ~ 0.82
     *     输入灰度 -> 最高分 0.04 ~ 0.55
     *
     * 阈值 0.30 下灰度输入**一个框都不出**。模型明显依赖颜色线索。
     * 省下的几毫秒换来的是完全不可用。
     *
     * 结论：**必须传模型训练时使用的颜色空间**。这类错误不崩溃、不报错，
     * 只表现为「模型明明没问题却检测不到」，极难定位。
     */
    fun detectYuv(
        y: ByteArray,
        u: ByteArray,
        v: ByteArray,
        frameWidth: Int,
        frameHeight: Int,
        uvRowStride: Int,
        uvPixelStride: Int,
        rotationDegrees: Int,
        threshold: Float,
    ): List<Detection> {
        if (busy) return emptyList()
        busy = true
        try {
            val rot = ((rotationDegrees % 360) + 360) % 360
            val swap = rot == 90 || rot == 270
            val srcW = if (swap) frameHeight else frameWidth
            val srcH = if (swap) frameWidth else frameHeight

            val scale = min(inputSize.toFloat() / srcW, inputSize.toFloat() / srcH)
            val newW = (srcW * scale).toInt().coerceAtLeast(1)
            val newH = (srcH * scale).toInt().coerceAtLeast(1)
            val padX = (inputSize - newW) / 2
            val padY = (inputSize - newH) / 2

            inputBuffer.rewind()
            for (dy in 0 until newH) {
                for (dx in 0 until newW) {
                    putRgb(
                        y, u, v, frameWidth, frameHeight, uvRowStride, uvPixelStride,
                        rot, dx, dy, newW, newH,
                    )
                }
            }
            inputBuffer.rewind()

            outputBuffer.rewind()
            val t0 = System.nanoTime()
            interpreter.run(inputBuffer, outputBuffer)
            lastInferenceMs = (System.nanoTime() - t0) / 1_000_000.0

            val raw = decode(threshold, scale, srcW, srcH)
            return nms(raw, 0.45f, 100)
        } finally {
            busy = false
        }
    }

    /**
     * 取 (dx, dy) 处的 RGB 写入输入缓冲。
     *
     * 映射链：letterbox 图 -> 正立帧（撤缩放）-> 原始帧（逆旋转）-> YUV 采样 -> RGB。
     *
     * 逆旋转方向必须对：`rotationDegrees` 表示「顺时针转这么多度才正立」。
     * 位图顺时针旋转满足 `destX = SRC_H-1-sy`、`destY = SRC_W-1-sx`；
     * 反解即下面的采样式。**方向搞反的表现是框整体镜像错位，不会报错。**
     */
    private fun putRgb(
        y: ByteArray,
        u: ByteArray,
        v: ByteArray,
        frameWidth: Int,
        frameHeight: Int,
        uvRowStride: Int,
        uvPixelStride: Int,
        rotationDegrees: Int,
        dx: Int,
        dy: Int,
        newW: Int,
        newH: Int,
    ) {
        val outW = frameWidthOrRotated(frameWidth, frameHeight, rotationDegrees)
        val outH = frameHeightOrRotated(frameWidth, frameHeight, rotationDegrees)
        val ux = dx * outW / newW
        val uy = dy * outH / newH

        val (sx, sy) = when (rotationDegrees) {
            90 -> Pair(outH - 1 - uy, frameWidth - 1 - ux)
            180 -> Pair(frameWidth - 1 - ux, frameHeight - 1 - uy)
            270 -> Pair(uy, ux)
            else -> Pair(ux, uy)
        }
        val cx = sx.coerceIn(0, frameWidth - 1)
        val cy = sy.coerceIn(0, frameHeight - 1)

        val yVal = y[cy * frameWidth + cx].toInt() and 0xFF
        // UV 平面按 2x2 下采样：像素 (cx,cy) 对应 UV 的第 (cx/2, cy/2) 个样本
        val uvIndex = (cy / 2) * uvRowStride + (cx / 2) * uvPixelStride
        val uVal = if (uvIndex in u.indices) u[uvIndex].toInt() and 0xFF else 128
        val vVal = if (uvIndex in v.indices) v[uvIndex].toInt() and 0xFF else 128

        // 标准 BT.601 YUV -> RGB
        val yf = yVal - 16
        val uf = uVal - 128
        val vf = vVal - 128
        val r = 1.164f * yf + 1.596f * vf
        val g = 1.164f * yf - 0.392f * uf - 0.813f * vf
        val b = 1.164f * yf + 2.017f * uf
        inputBuffer
            .put(r.toInt().coerceIn(0, 255).toByte())
            .put(g.toInt().coerceIn(0, 255).toByte())
            .put(b.toInt().coerceIn(0, 255).toByte())
    }

    private fun frameWidthOrRotated(w: Int, h: Int, rot: Int): Int =
        if (rot == 90 || rot == 270) h else w

    private fun frameHeightOrRotated(w: Int, h: Int, rot: Int): Int =
        if (rot == 90 || rot == 270) w else h

    /**
     * 输出张量 -> 归一化检测框。
     *
     * 归一化要**两步**，分清楚才能避免取整误差：
     * 1. 模型坐标是相对 `inputSize`（含 letterbox 填充）的像素；
     *    减去填充、除以缩放系数 -> **正立帧**像素。
     * 2. 除以正立帧尺寸 -> 归一化坐标，这正是 Dart 侧期望的坐标系。
     */
    private fun decode(
        threshold: Float,
        scale: Float,
        srcW: Int,
        srcH: Int,
    ): List<Detection> {
        val out = ArrayList<Detection>(64)
        outputBuffer.rewind()
        val fb = outputBuffer.asFloatBuffer()
        val stride = numClasses + 4
        for (a in 0 until numAnchors) {
            var best = -1
            var bestScore = threshold
            for (c in 0 until numClasses) {
                val v = if (transposed) fb.get(a * stride + 4 + c)
                else fb.get((4 + c) * numAnchors + a)
                if (v > bestScore) {
                    bestScore = v
                    best = c
                }
            }
            if (best < 0) continue

            val cx = if (transposed) fb.get(a * stride) else fb.get(a)
            val cy = if (transposed) fb.get(a * stride + 1) else fb.get(numAnchors + a)
            val bw = if (transposed) fb.get(a * stride + 2) else fb.get(2 * numAnchors + a)
            val bh = if (transposed) fb.get(a * stride + 3) else fb.get(3 * numAnchors + a)

            if (scale <= 0f) continue
            // 第 1 步：模型坐标 -> 正立帧像素
            val px1 = (cx - bw / 2) / scale
            val py1 = (cy - bh / 2) / scale
            val px2 = (cx + bw / 2) / scale
            val py2 = (cy + bh / 2) / scale
            // 第 2 步：-> 归一化
            val x1 = (px1 / srcW).coerceIn(0f, 1f)
            val y1 = (py1 / srcH).coerceIn(0f, 1f)
            val x2 = (px2 / srcW).coerceIn(0f, 1f)
            val y2 = (py2 / srcH).coerceIn(0f, 1f)
            if (x2 <= x1 || y2 <= y1) continue

            out.add(
                Detection(
                    // 加上偏移：单类模型输出 0，需要映射回项目类别表里的真实 id。
                    id = best + classOffset,
                    score = bestScore,
                    cx = (x1 + x2) / 2,
                    cy = (y1 + y2) / 2,
                    w = x2 - x1,
                    h = y2 - y1,
                ),
            )
        }
        return out
    }

    private fun nms(input: List<Detection>, iouThreshold: Float, maxDet: Int): List<Detection> {
        if (input.size <= 1) return input
        val sorted = input.sortedByDescending { it.score }
        val keep = ArrayList<Detection>(min(sorted.size, maxDet))
        val suppressed = BooleanArray(sorted.size)
        for (i in sorted.indices) {
            if (suppressed[i]) continue
            keep.add(sorted[i])
            if (keep.size >= maxDet) break
            for (j in i + 1 until sorted.size) {
                if (suppressed[j]) continue
                if (sorted[i].id != sorted[j].id) continue
                if (iou(sorted[i], sorted[j]) > iouThreshold) suppressed[j] = true
            }
        }
        return keep
    }

    private fun iou(a: Detection, b: Detection): Float {
        val ax1 = a.cx - a.w / 2
        val ay1 = a.cy - a.h / 2
        val ax2 = a.cx + a.w / 2
        val ay2 = a.cy + a.h / 2
        val bx1 = b.cx - b.w / 2
        val by1 = b.cy - b.h / 2
        val bx2 = b.cx + b.w / 2
        val by2 = b.cy + b.h / 2
        val iw = min(ax2, bx2) - max(ax1, bx1)
        val ih = min(ay2, by2) - max(ay1, by1)
        if (iw <= 0 || ih <= 0) return 0f
        val inter = iw * ih
        val union = a.w * a.h + b.w * b.h - inter
        return if (union <= 0) 0f else inter / union
    }
}

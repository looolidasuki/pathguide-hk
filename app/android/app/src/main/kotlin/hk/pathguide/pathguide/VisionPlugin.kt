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
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
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
) : FlutterPlugin {

    companion object {
        const val TAG = "PathGuideVision"
        const val METHOD_CHANNEL = "hk.pathguide/vision"
        const val FRAME_CHANNEL = "hk.pathguide/vision/frame"
        const val PREVIEW_VIEW = "hk.pathguide/vision/preview"

        /** 模型在 assets 中的路径。 */
        const val MODEL_ASSET = "assets/models/detector.tflite"

        /** 期望输入边长；模型若声明了固定形状则以模型为准。 */
        const val EXPECTED_INPUT_SIZE = 640
    }

    private var methodChannel: MethodChannel? = null
    private var frameChannel: EventChannel? = null

    @Volatile private var eventSink: EventChannel.EventSink? = null

    @Volatile var detector: YoloDetector? = null
        private set

    @Volatile var currentPreview: PreviewView? = null
        private set

    @Volatile var threshold: Float = 0.30f

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
            // Dart 侧拿到相机权限后调用。**必须在授权之后真的能被调用到**：
            // 权限是运行时申请的，若只在插件构造时检查一次，用户授权后
            // 原生侧仍停留在「无权限」状态，相机永不启动，表现为一片黑且无报错。
            "startPreview" -> {
                val granted = hasCameraPermission()
                if (granted) startCameraIfPossible()
                result.success(mapOf("started" to granted))
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
                    "modelPath" to MODEL_ASSET,
                    "inputSize" to (detector?.inputSize ?: EXPECTED_INPUT_SIZE),
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
     */
    private fun loadModel(call: MethodCall): Map<String, Any?> {
        val path = call.argument<String>("model") ?: MODEL_ASSET
        detector?.close()
        detector = null
        return try {
            val bytes = context.assets.open(path).readBytes()
            val det = YoloDetector(bytes, EXPECTED_INPUT_SIZE)
            detector = det
            startCameraIfPossible()
            mapOf("loaded" to true, "classes" to det.numClasses, "inputSize" to det.inputSize)
        } catch (e: Exception) {
            Log.w(TAG, "加载模型失败：$path", e)
            mapOf(
                "loaded" to false,
                "classes" to 0,
                "inputSize" to EXPECTED_INPUT_SIZE,
                "error" to "${e.javaClass.simpleName}: ${e.message}",
            )
        }
    }

    /**
     * 单帧推理（回放/调试路径）。实时相机路径不走这里，走 EventChannel，
     * 省掉一次整帧跨通道拷贝。
     */
    private fun detect(call: MethodCall): Map<String, Any?> {
        val det = detector
            ?: return mapOf("detections" to emptyList<Any>(), "inferenceMs" to 0.0,
                "error" to "模型未加载")
        val bytes = call.argument<ByteArray>("bytes")
            ?: return mapOf("detections" to emptyList<Any>(), "inferenceMs" to 0.0,
                "error" to "缺少 bytes")
        val w = call.argument<Int>("frameWidth")
            ?: return mapOf("detections" to emptyList<Any>(), "inferenceMs" to 0.0,
                "error" to "缺少 frameWidth")
        val h = call.argument<Int>("frameHeight")
            ?: return mapOf("detections" to emptyList<Any>(), "inferenceMs" to 0.0,
                "error" to "缺少 frameHeight")
        val rotation = call.argument<Int>("rotationDegrees") ?: 0
        val thr = (call.argument<Double>("threshold") ?: threshold.toDouble()).toFloat()

        val dets = det.detectGray(bytes, w, h, rotation, thr)
        return mapOf(
            "detections" to dets.map { it.toMap() },
            "inferenceMs" to det.lastInferenceMs,
        )
    }

    // ------------------------------------------------------------------ 相机

    fun onPreviewCreated(view: PreviewView) {
        currentPreview = view
        startCameraIfPossible()
    }

    private fun hasCameraPermission(): Boolean =
        ContextCompat.checkSelfPermission(context, android.Manifest.permission.CAMERA) ==
            android.content.pm.PackageManager.PERMISSION_GRANTED

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
        val owner = context as? LifecycleOwner
        if (owner == null) {
            Log.e(TAG, "context 不是 LifecycleOwner，无法绑定相机生命周期")
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
    }

    /** 单帧分析：Y 平面 -> 检测 -> EventChannel。 */
    private fun analyze(image: ImageProxy) {
        // 必须无论成败都 close，否则 CameraX 停止投递新帧，表现为画面卡死。
        try {
            val det = detector ?: return
            if (currentPreview == null) return
            if (det.isBusy) return // 上一帧还在推理：丢弃本帧，而不是排队

            val w = image.width
            val h = image.height
            val rotation = image.imageInfo.rotationDegrees
            val y = readYPlane(image, w, h) ?: return

            val t0 = System.nanoTime()
            val detections = det.detectGray(y, w, h, rotation, threshold)
            // 只统计纯推理耗时，不含取帧与转换——否则看不出瓶颈在哪。
            val ms = (System.nanoTime() - t0) / 1_000_000.0

            val sink = eventSink ?: return
            val payload = mapOf(
                "detections" to detections.map { it.toMap() },
                "inferenceMs" to ms,
                "frameWidth" to w,
                "frameHeight" to h,
            )
            ContextCompat.getMainExecutor(context).execute { sink.success(payload) }
        } catch (e: Exception) {
            Log.w(TAG, "分析帧失败", e)
        } finally {
            image.close()
        }
    }

    /**
     * 从 `ImageProxy` 拷出 Y 平面。
     *
     * `rowStride` 可能大于 `width`（硬件按 16/32 字节对齐），Y 平面也可能带
     * `pixelStride`。按 `rowStride` 逐行定位是**必须**的：直接顺序读会在
     * 非对齐设备上产生一条条斜纹伪影，而且不报错。
     */
    private fun readYPlane(image: ImageProxy, w: Int, h: Int): ByteArray? {
        val plane = image.planes.firstOrNull() ?: return null
        val buf = plane.buffer
        val rowStride = plane.rowStride
        val pixelStride = plane.pixelStride
        val out = ByteArray(w * h)
        if (rowStride == w && pixelStride == 1) {
            buf.rewind()
            buf.get(out, 0, min(out.size, buf.remaining()))
            return out
        }
        val row = ByteArray(rowStride)
        var o = 0
        for (y in 0 until h) {
            val pos = y * rowStride
            if (pos >= buf.limit()) break
            buf.position(pos)
            val n = min(rowStride, buf.remaining())
            buf.get(row, 0, n)
            var x = 0
            while (x < w) {
                val src = x * pixelStride
                if (src >= n) break
                out[o++] = row[src]
                x++
            }
        }
        return out
    }
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
class YoloDetector(modelBytes: ByteArray, expectedInput: Int) {

    private val interpreter: Interpreter
    val inputSize: Int
    val numClasses: Int
    private val numAnchors: Int

    /** 输出是否为 `[1, anchors, 4+nc]`。不同导出设置会不同，必须按形状判断。 */
    private val transposed: Boolean

    private val inputBuffer: ByteBuffer
    private val outputBuffer: ByteBuffer

    @Volatile private var busy = false
    val isBusy: Boolean get() = busy

    @Volatile var lastInferenceMs: Double = 0.0
        private set

    init {
        interpreter = Interpreter(
            ByteBuffer.wrap(modelBytes),
            Interpreter.Options().apply { setNumThreads(4) },
        )
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
     * 用 Y 平面（灰度）推理。
     *
     * ## 为什么只传亮度通道
     *
     * 相机输出 YUV_420_888，`planes[0]` 就是亮度。传灰度省掉每帧的
     * YUV→RGB（Android 上约 5–15 ms），代价是丢颜色。
     *
     * 当前唯一有数据的类是 `bin`（垃圾桶），靠形状即可识别，颜色不是关键特征。
     * **若后续加入依赖颜色的类（红色交通锥、黄黑警示牌），必须改回 RGB**，
     * 否则那些会系统性失效，且不报错。
     */
    fun detectGray(
        y: ByteArray,
        frameWidth: Int,
        frameHeight: Int,
        rotationDegrees: Int,
        threshold: Float,
    ): List<Detection> {
        if (busy) return emptyList()
        busy = true
        try {
            val rot = ((rotationDegrees % 360) + 360) % 360
            // 旋转后的有效尺寸：90/270 度时宽高互换
            val swap = rot == 90 || rot == 270
            val srcW = if (swap) frameHeight else frameWidth
            val srcH = if (swap) frameWidth else frameHeight

            val scale = min(inputSize.toFloat() / srcW, inputSize.toFloat() / srcH)
            val newW = (srcW * scale).toInt().coerceAtLeast(1)
            val newH = (srcH * scale).toInt().coerceAtLeast(1)
            val padX = (inputSize - newW) / 2
            val padY = (inputSize - newH) / 2

            // 灰度采样 + 通道复制，不经过 Bitmap（避免每帧分配一张 640x640 位图）
            inputBuffer.rewind()
            for (dy in 0 until newH) {
                for (dx in 0 until newW) {
                    val v = sampleGray(y, frameWidth, frameHeight, rot, dx, dy, newW, newH)
                    inputBuffer.put(v).put(v).put(v)
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
     * 在**正立帧**的 letterbox 图上取 (dx, dy) 处的灰度 [0,1]。
     *
     * 映射链：letterbox 图 -> 正立帧（撤缩放）-> 原始帧（逆旋转）-> 采样。
     *
     * 逆旋转的方向必须对：`rotationDegrees` 表示「顺时针转这么多度才正立」。
     * 位图顺时针旋转满足 `destX = SRC_H-1-sy`、`destY = SRC_W-1-sx`；
     * 反解即下面的采样式。**方向搞反的表现是框整体镜像错位，不会报错。**
     */
    private fun sampleGray(
        y: ByteArray,
        frameWidth: Int,
        frameHeight: Int,
        rotationDegrees: Int,
        dx: Int,
        dy: Int,
        newW: Int,
        newH: Int,
    ): Byte {
        // letterbox 图 -> 正立帧坐标（比例映射，此处不做取整修正）
        val ux = dx * frameWidthOrRotated(frameWidth, frameHeight, rotationDegrees) / newW
        val uy = dy * frameHeightOrRotated(frameWidth, frameHeight, rotationDegrees) / newH
        val outW = frameWidthOrRotated(frameWidth, frameHeight, rotationDegrees)
        val outH = frameHeightOrRotated(frameWidth, frameHeight, rotationDegrees)

        val (sx, sy) = when (rotationDegrees) {
            90 -> Pair(outH - 1 - uy, frameWidth - 1 - ux)
            180 -> Pair(frameWidth - 1 - ux, frameHeight - 1 - uy)
            270 -> Pair(uy, ux)
            else -> Pair(ux, uy)
        }
        val cx = sx.coerceIn(0, frameWidth - 1)
        val cy = sy.coerceIn(0, frameHeight - 1)
        return y[cy * frameWidth + cx]
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
                    id = best,
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

import AVFoundation
import CoreVideo
import CoreImage
import Flutter
import TensorFlowLiteC
import UIKit

/// iOS camera + TensorFlow Lite implementation of lib/vision/platform_contract.dart.
final class VisionPlugin: NSObject, FlutterPlugin, FlutterStreamHandler,
  AVCaptureVideoDataOutputSampleBufferDelegate
{
  static weak var active: VisionPlugin?
  private enum Channel {
    static let method = "hk.pathguide/vision"
    static let frames = "hk.pathguide/vision/frame"
    static let preview = "hk.pathguide/vision/preview"
  }

  private let methodChannel: FlutterMethodChannel
  private let frameChannel: FlutterEventChannel
  private let captureSession = AVCaptureSession()
  private let sessionQueue = DispatchQueue(label: "hk.pathguide.vision.session")
  private let inferenceQueue = DispatchQueue(label: "hk.pathguide.vision.inference")

  private var sessionConfigured = false
  private weak var previewView: VisionPreviewUIView?
  private var eventSink: FlutterEventSink?
  private var interpreter: TFLiteModelRunner?
  private var modelPath: String?
  private var inputSize = 0
  private var modelClassCount = 0
  private var anchorCount = 0
  private var channels = 0
  private var transposed = false
  private var classIds: [Int] = []
  private var threshold: Float = 0.30
  private var busy = false
  private let photoQueue = DispatchQueue(label: "hk.pathguide.vision.photos")
  private let photoContext = CIContext(options: [.cacheIntermediates: false])
  private var pendingPhoto: (id: UUID, result: FlutterResult, trigger: String, deadline: CFAbsoluteTime)?
  private var lowCandidate: IOSDetection?
  private var lowSince: CFAbsoluteTime?


  // Diagnostics mirror Android so the existing Flutter HUD can inspect either platform.
  private var analyzedFrames: Int64 = 0
  private var analyzeErrors: Int64 = 0
  private var skippedReason = "尚未收到任何幀"
  private var analyzeError = ""
  private var frameWidth = 0
  private var frameHeight = 0
  private var frameFormat = ""
  private var frameMaxScore: Float = 0
  private var frameMinScore: Float = 0
  private var detectionCount = 0
  private var invalidDetections: Int64 = 0
  private var invalidSample = ""
  private var invalidByReason: [String: Int64] = [:]
  private var inputStats = ""
  private var outputStats = ""
  private var decodeStats = ""
  private var bufferState = ""

  init(messenger: FlutterBinaryMessenger) {
    methodChannel = FlutterMethodChannel(name: Channel.method, binaryMessenger: messenger)
    frameChannel = FlutterEventChannel(name: Channel.frames, binaryMessenger: messenger)
    super.init()
    Self.active = self
    methodChannel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    frameChannel.setStreamHandler(self)
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let plugin = VisionPlugin(messenger: registrar.messenger())
    registrar.register(
      VisionPreviewFactory(plugin: plugin),
      withId: Channel.preview
    )
  }

  // MARK: Flutter channels

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "captureFrame":
      guard let args = call.arguments as? [String: Any],
        let trigger = args["trigger"] as? String,
        ["manual_report", "low_confidence", "scene_sample"].contains(trigger) else {
        result(FlutterError(code: "bad_args", message: "擷取來源無效", details: nil)); return
      }
      let id = UUID()
      inferenceQueue.async { [weak self] in
        guard let self, self.interpreter != nil, self.captureSession.isRunning else {
          DispatchQueue.main.async { result(FlutterError(code: "not_running", message: "請先開始即時辨識", details: nil)) }; return
        }
        guard self.pendingPhoto == nil else {
          DispatchQueue.main.async { result(FlutterError(code: "busy", message: "正在擷取照片", details: nil)) }; return
        }
        self.lowSince = nil; self.lowCandidate = nil
        self.pendingPhoto = (id, result, trigger, CFAbsoluteTimeGetCurrent() + 4)
        self.inferenceQueue.asyncAfter(deadline: .now() + 4.1) { [weak self] in
          guard let self, let pending = self.pendingPhoto, pending.id == id else { return }
          self.pendingPhoto = nil
          DispatchQueue.main.async { pending.result(nil) }
        }
      }
    case "cancelCapture":
      inferenceQueue.async { [weak self] in
        if let pending = self?.pendingPhoto {
          self?.pendingPhoto = nil
          DispatchQueue.main.async { pending.result(nil) }
        }
        DispatchQueue.main.async { result(nil) }
      }
    case "startPreview":
      requestPermissionAndStart(result)
    case "loadModel":
      loadModel(call.arguments, result: result)
    case "setThreshold":
      guard let args = call.arguments as? [String: Any],
        let value = args["threshold"] as? NSNumber
      else {
        result(FlutterError(code: "bad_args", message: "缺少 threshold", details: nil))
        return
      }
      inferenceQueue.async { [weak self] in
        self?.threshold = min(1, max(0, value.floatValue))
        DispatchQueue.main.async { result(nil) }
      }
    case "modelDir":
      do {
        let url = try modelDirectory()
        result(url.path)
      } catch {
        result(FlutterError(code: "model_dir_failed", message: error.localizedDescription, details: nil))
      }
    case "writeFile":
      writeFile(call.arguments, result: result)
    case "fileSize":
      guard let args = call.arguments as? [String: Any], let path = args["path"] as? String else {
        result(-1)
        return
      }
      let attributes = try? FileManager.default.attributesOfItem(atPath: path)
      result((attributes?[.size] as? NSNumber)?.int64Value ?? -1)
    case "status":
      inferenceQueue.async { [weak self] in
        let snapshot = self?.statusSnapshot() ?? [:]
        DispatchQueue.main.async { result(snapshot) }
      }
    case "release":
      release(result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  func onListen(withArguments _: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    return nil
  }

  func onCancel(withArguments _: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  func attach(preview: VisionPreviewUIView) {
    previewView = preview
    preview.session = captureSession
  }

  // MARK: Camera

  private func requestPermissionAndStart(_ result: @escaping FlutterResult) {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      startSession(result)
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
        guard let self else { return }
        if granted {
          self.startSession(result)
        } else {
          DispatchQueue.main.async {
            result(["started": false, "error": "相機權限已被拒絕；可在設定的私隱與保安中重新允許"])
          }
        }
      }
    case .denied, .restricted:
      result(["started": false, "error": "沒有相機權限；請到設定 → 私隱與保安 → 相機允許領路通"])
    @unknown default:
      result(["started": false, "error": "無法確認相機權限狀態"])
    }
  }

  private func startSession(_ result: @escaping FlutterResult) {
    DispatchQueue.main.async { [weak self] in
      DepthPlugin.active?.stop()
      self?.startCaptureSession(result)
    }
  }

  private func startCaptureSession(_ result: @escaping FlutterResult) {
    sessionQueue.async { [weak self] in
      guard let self else { return }
      do {
        try self.configureSessionIfNeeded()
        if !self.captureSession.isRunning {
          self.captureSession.startRunning()
        }
        let started = self.captureSession.isRunning
        DispatchQueue.main.async { result(["started": started]) }
      } catch {
        DispatchQueue.main.async {
          result(["started": false, "error": error.localizedDescription])
        }
      }
    }
  }

  private func configureSessionIfNeeded() throws {
    if sessionConfigured { return }
    captureSession.beginConfiguration()
    defer { captureSession.commitConfiguration() }
    captureSession.sessionPreset = .hd1280x720

    guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    else { throw VisionError.cameraUnavailable }
    let input = try AVCaptureDeviceInput(device: camera)
    guard captureSession.canAddInput(input) else { throw VisionError.cameraInputRejected }
    captureSession.addInput(input)

    let output = AVCaptureVideoDataOutput()
    output.alwaysDiscardsLateVideoFrames = true
    output.videoSettings = [
      kCVPixelBufferPixelFormatTypeKey as String:
        Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    ]
    output.setSampleBufferDelegate(self, queue: inferenceQueue)
    guard captureSession.canAddOutput(output) else { throw VisionError.cameraOutputRejected }
    captureSession.addOutput(output)

    // Keep analysis buffers in the sensor's landscape coordinate system. The
    // preprocessor rotates them clockwise into portrait; Flutter uses the same 90° contract.
    if let connection = output.connection(with: .video), connection.isVideoOrientationSupported {
      connection.videoOrientation = .landscapeRight
    }
    sessionConfigured = true
  }

  func release(_ result: @escaping FlutterResult) {
    let group = DispatchGroup()
    group.enter()
    sessionQueue.async { [weak self] in
      if self?.captureSession.isRunning == true { self?.captureSession.stopRunning() }
      group.leave()
    }
    group.enter()
    inferenceQueue.async { [weak self] in
      if let pending = self?.pendingPhoto {
        self?.pendingPhoto = nil
        DispatchQueue.main.async { pending.result(nil) }
      }
      self?.interpreter = nil
      self?.modelPath = nil
      self?.busy = false
      self?.analyzedFrames = 0
      self?.analyzeErrors = 0
      self?.skippedReason = "相機已停止"
      group.leave()
    }
    group.notify(queue: .main) { result(nil) }
  }

  // MARK: Model and files

  private func loadModel(_ arguments: Any?, result: @escaping FlutterResult) {
    guard let args = arguments as? [String: Any], let path = args["model"] as? String else {
      result(["loaded": false, "error": "缺少模型路徑"])
      return
    }
    let ids = (args["classIds"] as? [NSNumber])?.map(\.intValue) ?? []
    inferenceQueue.async { [weak self] in
      guard let self else { return }
      do {
        let next = try TFLiteModelRunner(modelPath: path, threadCount: 4)
        let inShape = next.inputShape
        let outShape = next.outputShape
        let inputLayout = try IOSModelInputLayout(shape: inShape)
        guard outShape.count == 3 else {
          throw VisionError.badOutputShape(outShape)
        }
        let inferredInputSize = inputLayout.side
        let isTransposed = outShape[1] > outShape[2]
        let inferredChannels = min(outShape[1], outShape[2])
        let inferredAnchors = max(outShape[1], outShape[2])
        let inferredClasses = inferredChannels - 4
        guard inferredClasses > 0 else { throw VisionError.badOutputShape(outShape) }
        guard ids.isEmpty || ids.count == inferredClasses else {
          throw VisionError.badClassMap(expected: inferredClasses, actual: ids.count)
        }

        self.interpreter = next
        self.modelPath = path
        self.inputSize = inferredInputSize
        self.modelClassCount = inferredClasses
        self.anchorCount = inferredAnchors
        self.channels = inferredChannels
        self.transposed = isTransposed
        self.classIds = ids
        self.skippedReason = "等待相機畫面"
        self.bufferState = "input=\(next.inputByteCount)B output=\(next.outputByteCount)B"
        let reply: [String: Any] = [
          "loaded": true,
          "classes": inferredClasses,
          "inputSize": inferredInputSize,
        ]
        DispatchQueue.main.async { result(reply) }
      } catch {
        self.interpreter = nil
        self.modelPath = nil
        DispatchQueue.main.async {
          result(["loaded": false, "error": error.localizedDescription])
        }
      }
    }
  }

  private func writeFile(_ arguments: Any?, result: @escaping FlutterResult) {
    guard let args = arguments as? [String: Any], let path = args["path"] as? String else {
      result(FlutterError(code: "bad_args", message: "缺少 path", details: nil))
      return
    }
    let data: Data?
    if let typed = args["bytes"] as? FlutterStandardTypedData {
      data = typed.data
    } else {
      data = args["bytes"] as? Data
    }
    guard let data else {
      result(FlutterError(code: "bad_args", message: "缺少 bytes", details: nil))
      return
    }
    do {
      try FileManager.default.createDirectory(
        at: URL(fileURLWithPath: path).deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try data.write(to: URL(fileURLWithPath: path), options: .atomic)
      result(nil)
    } catch {
      result(FlutterError(code: "write_failed", message: error.localizedDescription, details: nil))
    }
  }

  private func modelDirectory() throws -> URL {
    let root = try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    let directory = root.appendingPathComponent("PathGuideModels", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  // MARK: Frame analysis

  func captureOutput(
    _: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from _: AVCaptureConnection
  ) {
    analyzedFrames += 1
    guard !busy else { skippedReason = "上一幀仍在推理"; return }
    guard let interpreter else { skippedReason = "模型未就緒"; return }
    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
      skippedReason = "相機幀沒有 PixelBuffer"
      return
    }
    busy = true
    defer { busy = false }

    do {
      let prepared = try IOSFramePreprocessor.prepare(
        pixelBuffer: pixelBuffer,
        inputSize: inputSize,
        rotationDegrees: 90
      )
      inputStats = prepared.stats
      let start = CFAbsoluteTimeGetCurrent()
      let values = try interpreter.invoke(input: prepared.values)
      let inferenceMs = (CFAbsoluteTimeGetCurrent() - start) * 1_000
      guard values.count == anchorCount * channels else {
        throw VisionError.outputSize(expected: anchorCount * channels, actual: values.count)
      }
      let decoded = IOSYoloDecoder.decode(
        values: values,
        anchors: anchorCount,
        classes: modelClassCount,
        transposed: transposed,
        threshold: pendingPhoto == nil ? threshold : min(threshold, 0.20),
        inputSize: inputSize,
        sourceWidth: prepared.uprightWidth,
        sourceHeight: prepared.uprightHeight,
        scaledWidth: prepared.scaledWidth,
        scaledHeight: prepared.scaledHeight,
        padX: prepared.padX,
        padY: prepared.padY,
        classIds: classIds
      )
      let candidates = IOSYoloDecoder.nonMaximumSuppression(
        decoded.detections,
        iouThreshold: 0.45,
        maximum: 100
      )

      let detections = candidates.filter { $0.score >= threshold }
      if let pending = pendingPhoto {
        let now = CFAbsoluteTimeGetCurrent()
        var ready = pending.trigger != "low_confidence"
        if pending.trigger == "low_confidence" {
          if let low = candidates.first(where: { $0.score >= 0.20 && $0.score <= 0.60 }) {
            if let previous = lowCandidate, previous.id == low.id,
              abs(previous.cx - low.cx) < 0.1, abs(previous.cy - low.cy) < 0.1 {
              if let start = lowSince { ready = now - start >= 1 }
            } else { lowSince = now }
            lowCandidate = low
          } else { lowCandidate = nil; lowSince = nil }
        }
        if now > pending.deadline {
          pendingPhoto = nil
          DispatchQueue.main.async { pending.result(nil) }
        } else if ready {
          pendingPhoto = nil
          // Rotate the full camera frame clockwise exactly as the inference's
          // sourcePoint transform. Re-encode a CGImage; no camera EXIF/GPS is copied.
          let capturedAt = ISO8601DateFormatter().string(from: Date())
          photoQueue.async { [weak self] in
            guard let self else { DispatchQueue.main.async { pending.result(nil) }; return }
            let image = CIImage(cvPixelBuffer: pixelBuffer).oriented(.right)
            if let cg = self.photoContext.createCGImage(image, from: image.extent),
              let data = UIImage(cgImage: cg).jpegData(compressionQuality: 0.85), data.count <= 2 * 1024 * 1024 {
              var gray = [UInt8](repeating: 0, count: 72)
              gray.withUnsafeMutableBytes { buffer in
                if let ctx = CGContext(data: buffer.baseAddress, width: 9, height: 8, bitsPerComponent: 8,
                  bytesPerRow: 9, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) {
                  ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 9, height: 8))
                }
              }
              let mean = gray.reduce(0) { $0 + Int($1) } / 72
              if pending.trigger != "manual_report" && (mean < 8 || mean > 247) {
                DispatchQueue.main.async { pending.result(nil) }; return
              }
              var fingerprint: UInt64 = 0
              for y in 0..<8 { for x in 0..<8 {
                fingerprint = (fingerprint << 1) | (gray[y * 9 + x] > gray[y * 9 + x + 1] ? 1 : 0)
              } }
              let payload: [String: Any] = ["jpeg": FlutterStandardTypedData(bytes: data),
                "width": cg.width, "height": cg.height, "capturedAtClient": capturedAt,
                "perceptualHash": String(format: "%016llx", fingerprint),
                "predictions": candidates.map { d in ["projectClassId": d.id,
                  "score": Double(d.score), "cx": Double(d.cx), "cy": Double(d.cy),
                  "w": Double(d.width), "h": Double(d.height)] as [String: Any] }]
              DispatchQueue.main.async { pending.result(payload) }
            } else {
              DispatchQueue.main.async { pending.result(FlutterError(code: "jpeg_failed", message: "未能編碼照片", details: nil)) }
            }
          }
        }
      }

      frameWidth = prepared.rawWidth
      frameHeight = prepared.rawHeight
      frameFormat = prepared.format
      frameMaxScore = decoded.maximumScore
      frameMinScore = decoded.minimumScore
      detectionCount = detections.count
      invalidDetections += Int64(decoded.invalidCount)
      if let sample = decoded.invalidSample { invalidSample = sample }
      for (reason, count) in decoded.invalidByReason {
        invalidByReason[reason, default: 0] += Int64(count)
      }
      outputStats = IOSYoloDecoder.stats(values)
      decodeStats = decoded.stats
      analyzeError = ""
      skippedReason = ""

      let payload: [String: Any] = [
        "detections": detections.map(\.dictionary),
        "inferenceMs": inferenceMs,
        "frameWidth": prepared.rawWidth,
        "frameHeight": prepared.rawHeight,
        "analyzedFrames": analyzedFrames,
        "analyzeErrors": analyzeErrors,
        "skippedReason": skippedReason,
        "frameMaxScore": Double(frameMaxScore),
        "frameFormat": frameFormat,
      ]
      DispatchQueue.main.async { [weak self] in self?.eventSink?(payload) }
    } catch {
      analyzeErrors += 1
      analyzeError = "\(type(of: error)): \(error.localizedDescription)"
      skippedReason = analyzeError
    }
  }

  private func statusSnapshot() -> [String: Any] {
    [
      "ready": interpreter != nil,
      "modelPath": modelPath ?? NSNull(),
      "inputSize": inputSize,
      "classes": modelClassCount,
      "analyzedFrames": analyzedFrames,
      "analyzeErrors": analyzeErrors,
      "skippedReason": skippedReason,
      "analyzeError": analyzeError,
      "frameWidth": frameWidth,
      "frameHeight": frameHeight,
      "frameFormat": frameFormat,
      "frameMaxScore": Double(frameMaxScore),
      "frameMinScore": Double(frameMinScore),
      "detectionCount": detectionCount,
      "invalidDetections": invalidDetections,
      "invalidSample": invalidSample,
      "invalidByReason": invalidByReason,
      "inputStats": inputStats,
      "outputStats": outputStats,
      "decodeStats": decodeStats,
      "bufferState": bufferState,
      "anchors": anchorCount,
      "channels": channels,
      "transposed": transposed,
    ]
  }
}

// MARK: Native preview

final class VisionPreviewUIView: UIView {
  override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
  private var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

  var session: AVCaptureSession? {
    get { previewLayer.session }
    set {
      previewLayer.session = newValue
      previewLayer.videoGravity = .resizeAspect
      backgroundColor = .black
      if let connection = previewLayer.connection, connection.isVideoOrientationSupported {
        connection.videoOrientation = .portrait
      }
    }
  }
}

private final class VisionPlatformView: NSObject, FlutterPlatformView {
  let nativeView: VisionPreviewUIView

  init(frame: CGRect, plugin: VisionPlugin) {
    nativeView = VisionPreviewUIView(frame: frame)
    super.init()
    plugin.attach(preview: nativeView)
  }

  func view() -> UIView { nativeView }
}

private final class VisionPreviewFactory: NSObject, FlutterPlatformViewFactory {
  private let plugin: VisionPlugin

  init(plugin: VisionPlugin) { self.plugin = plugin }

  func create(
    withFrame frame: CGRect,
    viewIdentifier _: Int64,
    arguments _: Any?
  ) -> FlutterPlatformView {
    VisionPlatformView(frame: frame, plugin: plugin)
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }
}

// MARK: Preprocessing

struct IOSPreparedFrame {
  let values: [Float32]
  let rawWidth: Int
  let rawHeight: Int
  let uprightWidth: Int
  let uprightHeight: Int
  let scaledWidth: Int
  let scaledHeight: Int
  let padX: Int
  let padY: Int
  let format: String
  let stats: String
}

enum IOSFramePreprocessor {
  static func rotatedSize(width: Int, height: Int, degrees: Int) -> (Int, Int) {
    let rotation = ((degrees % 360) + 360) % 360
    return rotation == 90 || rotation == 270 ? (height, width) : (width, height)
  }

  static func sourcePoint(
    uprightX: Int,
    uprightY: Int,
    rawWidth: Int,
    rawHeight: Int,
    degrees: Int
  ) -> (Int, Int) {
    switch ((degrees % 360) + 360) % 360 {
    case 90: return (uprightY, rawHeight - 1 - uprightX)
    case 180: return (rawWidth - 1 - uprightX, rawHeight - 1 - uprightY)
    case 270: return (rawWidth - 1 - uprightY, uprightX)
    default: return (uprightX, uprightY)
    }
  }

  static func prepare(
    pixelBuffer: CVPixelBuffer,
    inputSize: Int,
    rotationDegrees: Int
  ) throws -> IOSPreparedFrame {
    guard inputSize > 0 else { throw VisionError.inputSize }
    guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 2 else { throw VisionError.pixelFormat }
    let formatType = CVPixelBufferGetPixelFormatType(pixelBuffer)
    guard formatType == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
      formatType == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else { throw VisionError.pixelFormat }
    let fullRange = formatType == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    let matrix = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, nil) as? String
    // ARKit normally supplies an explicit matrix; reject unknown matrices
    // rather than silently applying a different colour conversion.
    guard matrix == nil || matrix == kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String ||
      matrix == kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String else { throw VisionError.pixelFormat }
    let bt709 = matrix == kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String
    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    let (uprightWidth, uprightHeight) = rotatedSize(
      width: width,
      height: height,
      degrees: rotationDegrees
    )
    guard width > 0, height > 0, uprightWidth > 0, uprightHeight > 0,
      let yAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
      let uvAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)
    else { throw VisionError.pixelFormat }

    let y = yAddress.assumingMemoryBound(to: UInt8.self)
    let uv = uvAddress.assumingMemoryBound(to: UInt8.self)
    let yStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
    let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
    let scale = min(Float(inputSize) / Float(uprightWidth), Float(inputSize) / Float(uprightHeight))
    let scaledWidth = max(1, Int(Float(uprightWidth) * scale))
    let scaledHeight = max(1, Int(Float(uprightHeight) * scale))
    let padX = (inputSize - scaledWidth) / 2
    let padY = (inputSize - scaledHeight) / 2
    let pad = Float32(114.0 / 255.0)
    var values = [Float32](repeating: pad, count: inputSize * inputSize * 3)

    var minimum = Float32.greatestFiniteMagnitude
    var maximum = -Float32.greatestFiniteMagnitude
    for dy in 0..<scaledHeight {
      let uy = min(uprightHeight - 1, dy * uprightHeight / scaledHeight)
      for dx in 0..<scaledWidth {
        let ux = min(uprightWidth - 1, dx * uprightWidth / scaledWidth)
        var (sx, sy) = sourcePoint(
          uprightX: ux,
          uprightY: uy,
          rawWidth: width,
          rawHeight: height,
          degrees: rotationDegrees
        )
        sx = min(width - 1, max(0, sx))
        sy = min(height - 1, max(0, sy))
        let yy = Float32(y[sy * yStride + sx])
        let chroma = (sy / 2) * uvStride + (sx / 2) * 2
        let rgb = CameraImageMath.rgb(y: Double(yy), cb: Double(uv[chroma]),
          cr: Double(uv[chroma + 1]), fullRange: fullRange, bt709: bt709)
        let (r, g, b) = rgb
        let index = ((padY + dy) * inputSize + padX + dx) * 3
        values[index] = r
        values[index + 1] = g
        values[index + 2] = b
        minimum = min(minimum, min(r, min(g, b)))
        maximum = max(maximum, max(r, max(g, b)))
      }
    }
    if minimum == Float32.greatestFiniteMagnitude { minimum = pad; maximum = pad }
    let format = "NV12 \(width)x\(height) rot=\(rotationDegrees) full=\(fullRange) 709=\(bt709) yStride=\(yStride) uvStride=\(uvStride)"
    let stats = String(format: "count=%d [%.3f,%.3f]", values.count, minimum, maximum)
    return IOSPreparedFrame(
      values: values,
      rawWidth: width,
      rawHeight: height,
      uprightWidth: uprightWidth,
      uprightHeight: uprightHeight,
      scaledWidth: scaledWidth,
      scaledHeight: scaledHeight,
      padX: padX,
      padY: padY,
      format: format,
      stats: stats
    )
  }

  private static func clamp01(_ value: Float32) -> Float32 { min(1, max(0, value)) }
}

// MARK: YOLO decode and NMS

struct IOSDetection {
  let id: Int
  let score: Float32
  let cx: Float32
  let cy: Float32
  let width: Float32
  let height: Float32

  var dictionary: [String: Any] {
    [
      "id": id, "score": Double(score), "cx": Double(cx), "cy": Double(cy),
      "w": Double(width), "h": Double(height),
    ]
  }
}

struct IOSDecodeResult {
  let detections: [IOSDetection]
  let maximumScore: Float32
  let minimumScore: Float32
  let invalidCount: Int
  let invalidSample: String?
  let invalidByReason: [String: Int]
  let stats: String
}

enum IOSYoloDecoder {
  static func decode(
    values: [Float32],
    anchors: Int,
    classes: Int,
    transposed: Bool,
    threshold: Float32,
    inputSize: Int,
    sourceWidth: Int,
    sourceHeight: Int,
    scaledWidth: Int,
    scaledHeight: Int,
    padX: Int,
    padY: Int,
    classIds: [Int]
  ) -> IOSDecodeResult {
    var detections: [IOSDetection] = []
    var topScore: Float32 = 0
    var minimumScore: Float32 = 1
    var invalid = 0
    var invalidSample: String?
    var reasons: [String: Int] = [:]
    let stride = classes + 4

    func value(anchor: Int, channel: Int) -> Float32 {
      transposed ? values[anchor * stride + channel] : values[channel * anchors + anchor]
    }

    for anchor in 0..<anchors {
      var bestClass = -1
      var bestScore = -Float32.greatestFiniteMagnitude
      for classIndex in 0..<classes {
        let score = value(anchor: anchor, channel: 4 + classIndex)
        if score > topScore { topScore = score }
        if score < minimumScore { minimumScore = score }
        if score > bestScore { bestScore = score; bestClass = classIndex }
      }
      if bestScore < threshold { continue }
      let cx = value(anchor: anchor, channel: 0)
      let cy = value(anchor: anchor, channel: 1)
      let width = value(anchor: anchor, channel: 2)
      let height = value(anchor: anchor, channel: 3)
      let reason: String?
      if !bestScore.isFinite || bestScore < 0 || bestScore > 1 {
        reason = "score_out_of_range"
      } else if !cx.isFinite || !cy.isFinite || !width.isFinite || !height.isFinite {
        reason = "non_finite_coord"
      } else if width <= 0 || height <= 0 {
        reason = "non_positive_wh"
      } else {
        reason = nil
      }
      if let reason {
        invalid += 1
        reasons[reason, default: 0] += 1
        if invalidSample == nil {
          invalidSample = "[\(reason)] score=\(bestScore) cx=\(cx) cy=\(cy) w=\(width) h=\(height) anchor=\(anchor)"
        }
        continue
      }

      let side = Float32(inputSize)
      let x1 = min(1, max(0, ((cx - width / 2) * side - Float32(padX)) / Float32(scaledWidth)))
      let y1 = min(1, max(0, ((cy - height / 2) * side - Float32(padY)) / Float32(scaledHeight)))
      let x2 = min(1, max(0, ((cx + width / 2) * side - Float32(padX)) / Float32(scaledWidth)))
      let y2 = min(1, max(0, ((cy + height / 2) * side - Float32(padY)) / Float32(scaledHeight)))
      if x2 <= x1 || y2 <= y1 { continue }
      let appId = classIds.isEmpty ? bestClass : classIds[bestClass]
      detections.append(IOSDetection(
        id: appId,
        score: bestScore,
        cx: (x1 + x2) / 2,
        cy: (y1 + y2) / 2,
        width: x2 - x1,
        height: y2 - y1
      ))
    }

    if minimumScore == 1, topScore == 0 { minimumScore = 0 }
    let details = String(
      format: "topAll=%.3f transposed=%@ stride=%d anchors=%d classes=%d geo=%dx%d->%dx%d pad=%d,%d",
      topScore, transposed.description, stride, anchors, classes,
      sourceWidth, sourceHeight, scaledWidth, scaledHeight, padX, padY
    )
    return IOSDecodeResult(
      detections: detections,
      maximumScore: topScore,
      minimumScore: minimumScore,
      invalidCount: invalid,
      invalidSample: invalidSample,
      invalidByReason: reasons,
      stats: details
    )
  }

  static func nonMaximumSuppression(
    _ input: [IOSDetection],
    iouThreshold: Float32,
    maximum: Int
  ) -> [IOSDetection] {
    let sorted = input.sorted { $0.score > $1.score }
    var kept: [IOSDetection] = []
    for candidate in sorted {
      if kept.count >= maximum { break }
      let overlaps = kept.contains { other in
        other.id == candidate.id && intersectionOverUnion(other, candidate) > iouThreshold
      }
      if !overlaps { kept.append(candidate) }
    }
    return kept
  }

  static func intersectionOverUnion(_ a: IOSDetection, _ b: IOSDetection) -> Float32 {
    let ax1 = a.cx - a.width / 2, ay1 = a.cy - a.height / 2
    let ax2 = a.cx + a.width / 2, ay2 = a.cy + a.height / 2
    let bx1 = b.cx - b.width / 2, by1 = b.cy - b.height / 2
    let bx2 = b.cx + b.width / 2, by2 = b.cy + b.height / 2
    let intersectionWidth = min(ax2, bx2) - max(ax1, bx1)
    let intersectionHeight = min(ay2, by2) - max(ay1, by1)
    if intersectionWidth <= 0 || intersectionHeight <= 0 { return 0 }
    let intersection = intersectionWidth * intersectionHeight
    let union = a.width * a.height + b.width * b.height - intersection
    return union > 0 ? intersection / union : 0
  }

  static func stats(_ values: [Float32]) -> String {
    guard let minimum = values.min(), let maximum = values.max() else { return "empty" }
    let nonFinite = values.reduce(0) { $0 + ($1.isFinite ? 0 : 1) }
    return String(format: "count=%d nonFinite=%d [%.3f,%.3f]", values.count, nonFinite, minimum, maximum)
  }
}

/// Small Swift owner for the official TensorFlow Lite C runtime. Keeping all
/// native pointers in one object makes destruction order explicit: interpreter
/// first, then delegate/options, and model last.
/// Camera preprocessing produces interleaved RGB; newer LiteRT exports use planar RGB.
struct IOSModelInputLayout {
  let side: Int
  let channelsFirst: Bool

  init(shape: [Int]) throws {
    guard shape.count == 4, shape[0] == 1 else { throw VisionError.badInputShape(shape) }
    if shape[3] == 3, shape[1] > 0, shape[1] == shape[2] {
      side = shape[1]
      channelsFirst = false
    } else if shape[1] == 3, shape[2] > 0, shape[2] == shape[3] {
      side = shape[2]
      channelsFirst = true
    } else {
      throw VisionError.badInputShape(shape)
    }
  }

  func packRGB(_ values: [Float32]) throws -> [Float32] {
    let pixels = side * side
    guard values.count == pixels * 3 else {
      throw VisionError.outputSize(expected: pixels * 3, actual: values.count)
    }
    guard channelsFirst else { return values }
    var packed = [Float32](repeating: 0, count: values.count)
    for pixel in 0..<pixels {
      packed[pixel] = values[pixel * 3]
      packed[pixels + pixel] = values[pixel * 3 + 1]
      packed[2 * pixels + pixel] = values[pixel * 3 + 2]
    }
    return packed
  }
}

final class TFLiteModelRunner {
  private let model: OpaquePointer
  private let options: OpaquePointer
  private let interpreter: OpaquePointer
  private let xnnpackDelegate: UnsafeMutablePointer<TfLiteDelegate>?

  let inputShape: [Int]
  let outputShape: [Int]
  let inputByteCount: Int
  let outputByteCount: Int

  init(modelPath: String, threadCount: Int32) throws {
    guard let createdModel = modelPath.withCString({ TfLiteModelCreateFromFile($0) }) else {
      throw VisionError.runtime("無法讀取 TFLite 模型：\(modelPath)")
    }
    model = createdModel

    guard let createdOptions = TfLiteInterpreterOptionsCreate() else {
      TfLiteModelDelete(createdModel)
      throw VisionError.runtime("無法建立 TFLite InterpreterOptions")
    }
    options = createdOptions
    TfLiteInterpreterOptionsSetNumThreads(createdOptions, threadCount)

    var xnnOptions = TfLiteXNNPackDelegateOptionsDefault()
    xnnOptions.num_threads = threadCount
    let delegate = withUnsafePointer(to: &xnnOptions) { pointer in
      TfLiteXNNPackDelegateCreate(pointer)
    }
    xnnpackDelegate = delegate
    if let delegate {
      TfLiteInterpreterOptionsAddDelegate(createdOptions, delegate)
    }

    guard let createdInterpreter = TfLiteInterpreterCreate(createdModel, createdOptions) else {
      if let delegate { TfLiteXNNPackDelegateDelete(delegate) }
      TfLiteInterpreterOptionsDelete(createdOptions)
      TfLiteModelDelete(createdModel)
      throw VisionError.runtime("無法建立 TFLite Interpreter")
    }
    interpreter = createdInterpreter
    guard TfLiteInterpreterAllocateTensors(createdInterpreter) == kTfLiteOk else {
      TfLiteInterpreterDelete(createdInterpreter)
      if let delegate { TfLiteXNNPackDelegateDelete(delegate) }
      TfLiteInterpreterOptionsDelete(createdOptions)
      TfLiteModelDelete(createdModel)
      throw VisionError.runtime("TFLite 無法配置張量")
    }
    guard let input = TfLiteInterpreterGetInputTensor(createdInterpreter, 0),
      let output = TfLiteInterpreterGetOutputTensor(createdInterpreter, 0)
    else {
      TfLiteInterpreterDelete(createdInterpreter)
      if let delegate { TfLiteXNNPackDelegateDelete(delegate) }
      TfLiteInterpreterOptionsDelete(createdOptions)
      TfLiteModelDelete(createdModel)
      throw VisionError.runtime("TFLite 模型缺少輸入或輸出張量")
    }
    guard TfLiteTensorType(input) == kTfLiteFloat32,
      TfLiteTensorType(output) == kTfLiteFloat32
    else {
      TfLiteInterpreterDelete(createdInterpreter)
      if let delegate { TfLiteXNNPackDelegateDelete(delegate) }
      TfLiteInterpreterOptionsDelete(createdOptions)
      TfLiteModelDelete(createdModel)
      throw VisionError.runtime("目前只支援 Float32 輸入與輸出張量")
    }
    inputShape = Self.shape(of: UnsafePointer(input))
    outputShape = Self.shape(of: output)
    inputByteCount = TfLiteTensorByteSize(input)
    outputByteCount = TfLiteTensorByteSize(output)
  }

  deinit {
    TfLiteInterpreterDelete(interpreter)
    if let xnnpackDelegate { TfLiteXNNPackDelegateDelete(xnnpackDelegate) }
    TfLiteInterpreterOptionsDelete(options)
    TfLiteModelDelete(model)
  }

  func invoke(input values: [Float32]) throws -> [Float32] {
    guard values.count * MemoryLayout<Float32>.size == inputByteCount,
      let inputTensor = TfLiteInterpreterGetInputTensor(interpreter, 0)
    else {
      throw VisionError.outputSize(
        expected: inputByteCount / MemoryLayout<Float32>.size,
        actual: values.count
      )
    }
    let inputValues = try IOSModelInputLayout(shape: inputShape).packRGB(values)
    let copied = inputValues.withUnsafeBytes { bytes in
      TfLiteTensorCopyFromBuffer(inputTensor, bytes.baseAddress, bytes.count)
    }
    guard copied == kTfLiteOk else { throw VisionError.runtime("複製模型輸入失敗") }
    guard TfLiteInterpreterInvoke(interpreter) == kTfLiteOk else {
      throw VisionError.runtime("TFLite 推理失敗")
    }
    guard let outputTensor = TfLiteInterpreterGetOutputTensor(interpreter, 0) else {
      throw VisionError.runtime("推理後找不到輸出張量")
    }
    var output = [Float32](
      repeating: 0,
      count: outputByteCount / MemoryLayout<Float32>.size
    )
    let outputStatus = output.withUnsafeMutableBytes { bytes in
      TfLiteTensorCopyToBuffer(outputTensor, bytes.baseAddress, bytes.count)
    }
    guard outputStatus == kTfLiteOk else { throw VisionError.runtime("複製模型輸出失敗") }
    return output
  }

  private static func shape(of tensor: UnsafePointer<TfLiteTensor>) -> [Int] {
    let dimensions = Int(TfLiteTensorNumDims(tensor))
    guard dimensions > 0 else { return [] }
    return (0..<dimensions).map { Int(TfLiteTensorDim(tensor, Int32($0))) }
  }
}

private enum VisionError: LocalizedError {
  case cameraUnavailable
  case cameraInputRejected
  case cameraOutputRejected
  case badInputShape([Int])
  case badOutputShape([Int])
  case badClassMap(expected: Int, actual: Int)
  case outputSize(expected: Int, actual: Int)
  case pixelFormat
  case inputSize
  case runtime(String)

  var errorDescription: String? {
    switch self {
    case .cameraUnavailable: return "找不到後置廣角相機"
    case .cameraInputRejected: return "無法把後置相機加入擷取工作階段"
    case .cameraOutputRejected: return "無法取得相機分析畫面"
    case let .badInputShape(shape): return "模型輸入形狀不支援：\(shape)；預期 [1,N,N,3] 或 [1,3,N,N] Float32"
    case let .badOutputShape(shape): return "模型輸出形狀不支援：\(shape)；預期三維 Float32"
    case let .badClassMap(expected, actual): return "類別映射長度錯誤：模型有 \(expected) 類，映射有 \(actual) 項"
    case let .outputSize(expected, actual): return "模型輸出大小錯誤：預期 \(expected)，實際 \(actual)"
    case .pixelFormat: return "相機沒有提供可用的 NV12 雙平面畫面"
    case .inputSize: return "模型輸入尺寸尚未初始化"
    case let .runtime(message): return message
    }
  }
}

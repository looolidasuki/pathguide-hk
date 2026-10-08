import AVFoundation
import CoreVideo
import Flutter
import TensorFlowLite
import UIKit

private enum VisionContract {
  static let methodChannel = "hk.pathguide/vision"
  static let frameChannel = "hk.pathguide/vision/frame"
  static let previewView = "hk.pathguide/vision/preview"
}

private struct VisionDetection {
  let id: Int
  let score: Float
  let cx: Float
  let cy: Float
  let width: Float
  let height: Float

  var map: [String: Any] {
    ["id": id, "score": Double(score), "cx": Double(cx), "cy": Double(cy),
     "w": Double(width), "h": Double(height)]
  }
}

private final class YoloDetector {
  private let interpreter: Interpreter
  private var input: [Float]
  let inputSize: Int
  let numClasses: Int
  let numAnchors: Int
  let transposed: Bool
  var classIds: [Int] = []
  private(set) var lastInferenceMs: Double = 0

  init(path: String) throws {
    var options = Interpreter.Options()
    options.threadCount = 4
    interpreter = try Interpreter(modelPath: path, options: options)
    try interpreter.allocateTensors()

    let inputTensor = try interpreter.input(at: 0)
    let inputShape = inputTensor.shape.dimensions
    guard inputShape.count == 4, inputShape[3] == 3, inputTensor.dataType == .float32 else {
      throw NSError(domain: "PathGuideVision", code: 1, userInfo: [
        NSLocalizedDescriptionKey: "Expected a float32 NHWC RGB model input; got \(inputShape), \(inputTensor.dataType).",
      ])
    }
    inputSize = inputShape[1]

    let outputTensor = try interpreter.output(at: 0)
    let outputShape = outputTensor.shape.dimensions
    guard outputShape.count == 3, outputTensor.dataType == .float32 else {
      throw NSError(domain: "PathGuideVision", code: 2, userInfo: [
        NSLocalizedDescriptionKey: "Expected a float32 rank-3 YOLO output; got \(outputShape), \(outputTensor.dataType).",
      ])
    }
    transposed = outputShape[1] > outputShape[2]
    let channels = min(outputShape[1], outputShape[2])
    numAnchors = max(outputShape[1], outputShape[2])
    numClasses = channels - 4
    guard inputSize > 0, numClasses > 0 else {
      throw NSError(domain: "PathGuideVision", code: 3, userInfo: [
        NSLocalizedDescriptionKey: "Invalid model tensor dimensions: input=\(inputShape), output=\(outputShape).",
      ])
    }
    input = [Float](repeating: 0, count: inputSize * inputSize * 3)
  }

  func detect(_ pixelBuffer: CVPixelBuffer, threshold: Float) throws -> [VisionDetection] {
    guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else {
      throw NSError(domain: "PathGuideVision", code: 4, userInfo: [
        NSLocalizedDescriptionKey: "Camera frame is not bi-planar video-range YUV.",
      ])
    }
    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

    guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 2,
          let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
          let uvBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else {
      throw NSError(domain: "PathGuideVision", code: 5, userInfo: [
        NSLocalizedDescriptionKey: "Camera frame has no accessible YUV planes.",
      ])
    }

    let sourceWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
    let sourceHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
    let yStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
    let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
    let yBytes = yBase.assumingMemoryBound(to: UInt8.self)
    let uvBytes = uvBase.assumingMemoryBound(to: UInt8.self)

    let scale = min(Float(inputSize) / Float(sourceWidth), Float(inputSize) / Float(sourceHeight))
    let resizedWidth = max(1, Int(Float(sourceWidth) * scale))
    let resizedHeight = max(1, Int(Float(sourceHeight) * scale))
    let padX = (inputSize - resizedWidth) / 2
    let padY = (inputSize - resizedHeight) / 2
    let padding = Float(114) / 255
    for index in stride(from: 0, to: input.count, by: 3) {
      input[index] = padding
      input[index + 1] = padding
      input[index + 2] = padding
    }

    for dy in 0..<resizedHeight {
      let sourceY = min(sourceHeight - 1, dy * sourceHeight / resizedHeight)
      for dx in 0..<resizedWidth {
        let sourceX = min(sourceWidth - 1, dx * sourceWidth / resizedWidth)
        let yValue = Float(yBytes[sourceY * yStride + sourceX])
        let chromaIndex = (sourceY / 2) * uvStride + (sourceX / 2) * 2
        let uValue = Float(uvBytes[chromaIndex]) - 128
        let vValue = Float(uvBytes[chromaIndex + 1]) - 128
        let luma = yValue - 16
        let rgbIndex = ((dy + padY) * inputSize + dx + padX) * 3
        input[rgbIndex] = min(255, max(0, 1.164 * luma + 1.596 * vValue)) / 255
        input[rgbIndex + 1] = min(255, max(0, 1.164 * luma - 0.392 * uValue - 0.813 * vValue)) / 255
        input[rgbIndex + 2] = min(255, max(0, 1.164 * luma + 2.017 * uValue)) / 255
      }
    }

    let inputData = input.withUnsafeBufferPointer { buffer in
      Data(bytes: buffer.baseAddress!, count: buffer.count * MemoryLayout<Float>.stride)
    }
    let start = CFAbsoluteTimeGetCurrent()
    try interpreter.copy(inputData, toInputAt: 0)
    try interpreter.invoke()
    let outputData = try interpreter.output(at: 0).data
    lastInferenceMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
    let output = outputData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    return suppressOverlaps(
      decode(output, threshold: threshold, resizedWidth: resizedWidth,
             resizedHeight: resizedHeight, padX: padX, padY: padY),
      threshold: 0.45,
      limit: 100
    )
  }

  private func decode(
    _ output: [Float], threshold: Float, resizedWidth: Int, resizedHeight: Int, padX: Int, padY: Int
  ) -> [VisionDetection] {
    let channels = numClasses + 4
    guard output.count >= channels * numAnchors else { return [] }
    var detections: [VisionDetection] = []
    detections.reserveCapacity(64)

    func value(anchor: Int, channel: Int) -> Float {
      transposed ? output[anchor * channels + channel] : output[channel * numAnchors + anchor]
    }

    for anchor in 0..<numAnchors {
      var bestClass = -1
      var bestScore = threshold
      for classIndex in 0..<numClasses {
        let score = value(anchor: anchor, channel: classIndex + 4)
        if score > bestScore {
          bestClass = classIndex
          bestScore = score
        }
      }
      guard bestClass >= 0, bestScore.isFinite, bestScore <= 1 else { continue }
      let cx = value(anchor: anchor, channel: 0)
      let cy = value(anchor: anchor, channel: 1)
      let width = value(anchor: anchor, channel: 2)
      let height = value(anchor: anchor, channel: 3)
      guard cx.isFinite, cy.isFinite, width.isFinite, height.isFinite, width > 0, height > 0 else { continue }

      let side = Float(inputSize)
      let x1 = min(1, max(0, ((cx - width / 2) * side - Float(padX)) / Float(resizedWidth)))
      let y1 = min(1, max(0, ((cy - height / 2) * side - Float(padY)) / Float(resizedHeight)))
      let x2 = min(1, max(0, ((cx + width / 2) * side - Float(padX)) / Float(resizedWidth)))
      let y2 = min(1, max(0, ((cy + height / 2) * side - Float(padY)) / Float(resizedHeight)))
      guard x2 > x1, y2 > y1 else { continue }
      let classId = classIds.isEmpty ? bestClass : classIds[bestClass]
      detections.append(VisionDetection(
        id: classId, score: bestScore,
        cx: (x1 + x2) / 2, cy: (y1 + y2) / 2,
        width: x2 - x1, height: y2 - y1
      ))
    }
    return detections
  }

  private func suppressOverlaps(
    _ input: [VisionDetection], threshold: Float, limit: Int
  ) -> [VisionDetection] {
    let sorted = input.sorted { $0.score > $1.score }
    var kept: [VisionDetection] = []
    for candidate in sorted {
      let overlaps = kept.contains { existing in
        guard existing.id == candidate.id else { return false }
        let left = max(existing.cx - existing.width / 2, candidate.cx - candidate.width / 2)
        let top = max(existing.cy - existing.height / 2, candidate.cy - candidate.height / 2)
        let right = min(existing.cx + existing.width / 2, candidate.cx + candidate.width / 2)
        let bottom = min(existing.cy + existing.height / 2, candidate.cy + candidate.height / 2)
        let intersection = max(0, right - left) * max(0, bottom - top)
        let union = existing.width * existing.height + candidate.width * candidate.height - intersection
        return union > 0 && intersection / union > threshold
      }
      if !overlaps { kept.append(candidate) }
      if kept.count == limit { break }
    }
    return kept
  }
}

private final class VisionPreviewView: UIView {
  override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
  var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

  override init(frame: CGRect) {
    super.init(frame: frame)
    previewLayer.videoGravity = .resizeAspect
    backgroundColor = .black
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class VisionPreview: NSObject, FlutterPlatformView {
  private let preview: VisionPreviewView

  init(frame: CGRect, plugin: VisionPlugin) {
    preview = VisionPreviewView(frame: frame)
    super.init()
    plugin.attach(preview)
  }

  func view() -> UIView { preview }
}

private final class VisionPreviewFactory: NSObject, FlutterPlatformViewFactory {
  private let plugin: VisionPlugin

  init(plugin: VisionPlugin) { self.plugin = plugin }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }

  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
    VisionPreview(frame: frame, plugin: plugin)
  }
}

final class VisionPlugin: NSObject, FlutterPlugin, FlutterStreamHandler, AVCaptureVideoDataOutputSampleBufferDelegate {
  private let session = AVCaptureSession()
  private let sessionQueue = DispatchQueue(label: "hk.pathguide.vision.session")
  private let captureQueue = DispatchQueue(label: "hk.pathguide.vision.capture")
  private let sinkLock = NSLock()
  private let thresholdLock = NSLock()
  private weak var previewView: VisionPreviewView?
  private var eventSink: FlutterEventSink?
  private var detector: YoloDetector?
  private var threshold: Float = 0.30
  private var configured = false
  private var analyzedFrames = 0
  private var analyzeErrors = 0
  private var lastError = ""
  private var lastSkip = "尚未收到任何幀"
  private var lastWidth = 0
  private var lastHeight = 0
  private var lastMaxScore: Float = 0
  private var lastMinScore: Float = 0
  private var lastDetectionCount = 0
  private var lastInferenceMs: Double = 0
  private var lastFrameFormat = ""
  private var lastInvalidCount = 0
  private var loadedModelPath: String?

  static func register(with registrar: FlutterPluginRegistrar) {
    let plugin = VisionPlugin()
    let methods = FlutterMethodChannel(name: VisionContract.methodChannel, binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(plugin, channel: methods)
    let events = FlutterEventChannel(name: VisionContract.frameChannel, binaryMessenger: registrar.messenger())
    events.setStreamHandler(plugin)
    registrar.register(VisionPreviewFactory(plugin: plugin), withId: VisionContract.previewView)
  }

  func attach(_ view: VisionPreviewView) {
    previewView = view
    DispatchQueue.main.async { view.previewLayer.session = self.session }
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sinkLock.lock()
    eventSink = events
    sinkLock.unlock()
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sinkLock.lock()
    eventSink = nil
    sinkLock.unlock()
    return nil
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "startPreview": startPreview(result)
    case "loadModel": loadModel(call, result: result)
    case "setThreshold":
      guard let args = call.arguments as? [String: Any], let value = args["threshold"] as? NSNumber else {
        result(FlutterError(code: "bad_args", message: "Missing threshold", details: nil))
        return
      }
      thresholdLock.lock()
      threshold = min(1, max(0, value.floatValue))
      thresholdLock.unlock()
      result(nil)
    case "modelDir":
      result(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path)
    case "writeFile": writeFile(call, result: result)
    case "fileSize":
      let args = call.arguments as? [String: Any]
      let path = args?["path"] as? String ?? ""
      let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? -1
      result(size)
    case "status":
      captureQueue.async {
        let status = self.status()
        DispatchQueue.main.async { result(status) }
      }
    case "release":
      captureQueue.async {
        self.detector = nil
        self.loadedModelPath = nil
        self.resetDiagnostics(reason: "相機已停止")
        self.sessionQueue.async {
          if self.session.isRunning { self.session.stopRunning() }
        }
        DispatchQueue.main.async { result(nil) }
      }
    case "detect":
      result(["detections": [], "inferenceMs": 0.0, "error": "iOS uses the live frame stream."])
    default: result(FlutterMethodNotImplemented)
    }
  }

  private func startPreview(_ result: @escaping FlutterResult) {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized: startSession(result)
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .video) { granted in
        if granted { self.startSession(result) }
        else { DispatchQueue.main.async { result(["started": false, "granted": false]) } }
      }
    default: result(["started": false, "granted": false])
    }
  }

  private func startSession(_ result: @escaping FlutterResult) {
    sessionQueue.async {
      do {
        if !self.configured { try self.configureSession() }
        if !self.session.isRunning { self.session.startRunning() }
        DispatchQueue.main.async { result(["started": self.session.isRunning, "granted": true]) }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "camera_start_failed", message: error.localizedDescription, details: nil))
        }
      }
    }
  }

  private func configureSession() throws {
    guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
      throw NSError(domain: "PathGuideVision", code: 10, userInfo: [NSLocalizedDescriptionKey: "No rear camera is available."])
    }
    let input = try AVCaptureDeviceInput(device: camera)
    session.beginConfiguration()
    session.sessionPreset = .hd1280x720
    guard session.canAddInput(input) else {
      session.commitConfiguration()
      throw NSError(domain: "PathGuideVision", code: 11, userInfo: [NSLocalizedDescriptionKey: "Cannot add camera input."])
    }
    session.addInput(input)

    let output = AVCaptureVideoDataOutput()
    output.alwaysDiscardsLateVideoFrames = true
    output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
    output.setSampleBufferDelegate(self, queue: captureQueue)
    guard session.canAddOutput(output) else {
      session.commitConfiguration()
      throw NSError(domain: "PathGuideVision", code: 12, userInfo: [NSLocalizedDescriptionKey: "Cannot add camera frame output."])
    }
    session.addOutput(output)
    if let connection = output.connection(with: .video), connection.isVideoOrientationSupported {
      connection.videoOrientation = .portrait
    }
    if let layer = previewView?.previewLayer, let connection = layer.connection,
       connection.isVideoOrientationSupported {
      connection.videoOrientation = .portrait
    }
    session.commitConfiguration()
    configured = true
    DispatchQueue.main.async { self.previewView?.previewLayer.session = self.session }
  }

  private func loadModel(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any]
    guard let path = args?["model"] as? String, !path.isEmpty else {
      result(["loaded": false, "classes": 0, "inputSize": 640, "error": "Missing model path."])
      return
    }
    let classIds = args?["classIds"] as? [Int] ?? []
    captureQueue.async {
      do {
        let model = try YoloDetector(path: path)
        guard classIds.isEmpty || classIds.count == model.numClasses else {
          throw NSError(domain: "PathGuideVision", code: 13, userInfo: [
            NSLocalizedDescriptionKey: "Class mapping has \(classIds.count) entries; model has \(model.numClasses) classes.",
          ])
        }
        model.classIds = classIds
        self.detector = model
        self.loadedModelPath = path
        self.resetDiagnostics(reason: "")
        DispatchQueue.main.async {
          result(["loaded": true, "classes": model.numClasses, "inputSize": model.inputSize,
                  "modelPath": path, "classIds": classIds])
        }
      } catch {
        DispatchQueue.main.async {
          result(["loaded": false, "classes": 0, "inputSize": 640, "error": error.localizedDescription])
        }
      }
    }
  }

  private func writeFile(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let path = args["path"] as? String,
          let typedData = args["bytes"] as? FlutterStandardTypedData else {
      result(FlutterError(code: "bad_args", message: "Missing path or bytes", details: nil))
      return
    }
    let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].standardizedFileURL
    let target = URL(fileURLWithPath: path).standardizedFileURL
    guard target.path.hasPrefix(root.path + "/") else {
      result(FlutterError(code: "bad_path", message: "Model files must stay inside the app documents directory.", details: nil))
      return
    }
    do {
      try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
      try typedData.data.write(to: target, options: .atomic)
      result(nil)
    } catch {
      result(FlutterError(code: "write_failed", message: error.localizedDescription, details: nil))
    }
  }

  private func status() -> [String: Any] {
    ["ready": detector != nil, "modelPath": loadedModelPath as Any? ?? NSNull(),
     "inputSize": detector?.inputSize ?? 640, "classes": detector?.numClasses ?? 0,
     "analyzedFrames": analyzedFrames, "analyzeErrors": analyzeErrors,
     "skippedReason": lastSkip, "analyzeError": lastError,
     "frameWidth": lastWidth, "frameHeight": lastHeight, "frameFormat": lastFrameFormat,
     "frameMaxScore": Double(lastMaxScore), "frameMinScore": Double(lastMinScore),
     "detectionCount": lastDetectionCount, "invalidDetections": lastInvalidCount,
     "invalidSample": "", "invalidByReason": [String: Int](),
     "inputStats": "", "outputStats": "", "decodeStats": "",
     "bufferState": "", "threshold": Double(currentThreshold),
     "anchors": detector?.numAnchors ?? 0, "channels": (detector?.numClasses ?? 0) + 4,
     "transposed": detector?.transposed ?? false]
  }

  private var currentThreshold: Float {
    thresholdLock.lock()
    defer { thresholdLock.unlock() }
    return threshold
  }

  private func resetDiagnostics(reason: String) {
    analyzedFrames = 0
    analyzeErrors = 0
    lastError = ""
    lastSkip = reason
    lastWidth = 0
    lastHeight = 0
    lastMaxScore = 0
    lastMinScore = 0
    lastDetectionCount = 0
    lastInferenceMs = 0
    lastFrameFormat = ""
    lastInvalidCount = 0
  }

  func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
    analyzedFrames += 1
    guard let detector, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
      lastSkip = "模型未就緒或相機幀為空"
      return
    }
    do {
      let detections = try detector.detect(pixelBuffer, threshold: currentThreshold)
      lastWidth = CVPixelBufferGetWidth(pixelBuffer)
      lastHeight = CVPixelBufferGetHeight(pixelBuffer)
      lastInferenceMs = detector.lastInferenceMs
      lastMaxScore = detections.map(\.score).max() ?? 0
      lastMinScore = detections.map(\.score).min() ?? 0
      lastDetectionCount = detections.count
      lastFrameFormat = "420v portrait \(lastWidth)x\(lastHeight)"
      lastSkip = ""
      lastError = ""
      sinkLock.lock()
      let sink = eventSink
      sinkLock.unlock()
      guard let sink else { lastSkip = "EventSink 未連接"; return }
      let payload: [String: Any] = [
        "detections": detections.map(\.map), "inferenceMs": lastInferenceMs,
        "frameWidth": lastWidth, "frameHeight": lastHeight,
        "analyzedFrames": analyzedFrames, "analyzeErrors": analyzeErrors,
        "skippedReason": lastSkip, "frameMaxScore": Double(lastMaxScore),
        "frameFormat": lastFrameFormat,
      ]
      DispatchQueue.main.async { sink(payload) }
    } catch {
      analyzeErrors += 1
      lastError = "\(type(of: error)): \(error.localizedDescription)"
      lastSkip = lastError
    }
  }
}
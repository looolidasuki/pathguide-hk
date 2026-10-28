import ARKit
import AVFoundation
import CryptoKit
import Flutter
import SceneKit
import UIKit

/// One explicit, local-only measurement session. No image/depth/pose is saved.
final class DepthPlugin: NSObject, FlutterPlugin, FlutterStreamHandler, ARSessionDelegate {
  static weak var active: DepthPlugin?
  private let methods: FlutterMethodChannel
  private let events: FlutterEventChannel
  private let session = ARSession()
  private weak var preview: ARSCNView?
  private var sink: FlutterEventSink?
  private var running = false
  private var generation = 0
  private var lastSent = -Double.infinity
  private var previousPose: simd_float4x4?
  private var token = ""
  private var startedAt = Double.infinity
  private let work = DispatchQueue(label: "hk.pathguide.depth.inference", qos: .userInitiated)
  // detector is owned exclusively by work; busy/epoch by the main queue.
  private var detector: DepthDetector?
  private var objectsEnabled = false
  private var busy = false
  private var epoch = 0

  init(messenger: FlutterBinaryMessenger) {
    methods = FlutterMethodChannel(name: "hk.pathguide/depth", binaryMessenger: messenger)
    events = FlutterEventChannel(name: "hk.pathguide/depth/frames", binaryMessenger: messenger)
    super.init()
    Self.active = self
    session.delegate = self
    // All state, view geometry and delegate calls belong to the main queue.
    session.delegateQueue = .main
    methods.setMethodCallHandler { [weak self] call, result in self?.handle(call, result) }
    events.setStreamHandler(self)
    NotificationCenter.default.addObserver(self, selector: #selector(background),
      name: UIApplication.willResignActiveNotification, object: nil)
  }

  deinit { NotificationCenter.default.removeObserver(self) }

  static func register(with registrar: FlutterPluginRegistrar) {
    let plugin = DepthPlugin(messenger: registrar.messenger())
    registrar.register(DepthPreviewFactory(plugin: plugin), withId: "hk.pathguide/depth/preview")
  }

  func attach(_ view: ARSCNView) {
    preview = view
    view.session = session
    view.scene = SCNScene()
    view.automaticallyUpdatesLighting = false
    view.isAccessibilityElement = false
    view.accessibilityElementsHidden = true
  }

  func onListen(withArguments _: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    return nil
  }
  func onCancel(withArguments _: Any?) -> FlutterError? {
    stop()
    sink = nil
    return nil
  }

  @objc private func background() {
    emit("paused")
    stop()
  }

  /// Also called before the other native camera stacks start.
  func stop() {
    if running { emit("paused") }
    generation += 1
    running = false
    previousPose = nil
    epoch += 1
    work.async { [weak self] in self?.detector = nil }
    session.pause()
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    switch call.method {
    case "stop":
      stop()
      result(nil)
    case "start":
      guard let args = call.arguments as? [String: Any], let id = args["session"] as? String,
        !id.isEmpty else {
        result(FlutterError(code: "bad_session", message: "Missing session", details: nil)); return
      }
      stop()
      token = id
      objectsEnabled = args["objects"] as? Bool == true
      guard ARWorldTrackingConfiguration.isSupported,
        ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) else {
        result(["status": "unsupported"]); return
      }
      let expected = generation
      func begin(_ granted: Bool) {
        guard expected == self.generation,
          UIApplication.shared.applicationState == .active else {
          result(["status": "paused"]); return
        }
        guard granted else { result(["status": "permission"]); return }
        func run() {
          guard expected == self.generation,
            UIApplication.shared.applicationState == .active else {
            result(["status": "paused"]); return
          }
          let config = ARWorldTrackingConfiguration()
          config.frameSemantics = .sceneDepth
          config.worldAlignment = .gravity
          self.running = true
          self.lastSent = -Double.infinity
          self.startedAt = ProcessInfo.processInfo.systemUptime
          self.session.run(config, options: [.resetTracking, .removeExistingAnchors])
          result(["status": "running"])
        }
        // Await AVCapture shutdown before ARKit takes the rear camera.
        if let vision = VisionPlugin.active { vision.release { _ in run() } }
        else { run() }
      }
      func authorize() {
        guard expected == self.generation else { result(["status": "paused"]); return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: begin(true)
        case .notDetermined:
          AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async { begin(granted) }
          }
        default: begin(false)
        }
      }
      if objectsEnabled {
        work.async { [weak self] in
          guard let self else { return }
          do {
            self.detector = try DepthDetector(arguments: args)
            DispatchQueue.main.async { authorize() }
          } catch {
            self.detector = nil
            DispatchQueue.main.async {
              result(["status": expected == self.generation ? "model" : "paused"])
            }
          }
        }
      } else { authorize() }
    default: result(FlutterMethodNotImplemented)
    }
  }

  private func emit(_ status: String, frame: ARFrame? = nil, patch: DepthPatch? = nil,
    details: [String: Any] = [:]) {
    var value: [String: Any] = ["session": token, "status": status]
    if let frame {
      value["timestamp"] = frame.timestamp
      value["ageMs"] = max(0, (ProcessInfo.processInfo.systemUptime - frame.timestamp) * 1000)
    }
    if let patch {
      value["rangeM"] = patch.range
      value["planeZM"] = patch.z
      value["accepted"] = patch.accepted
      value["total"] = patch.total
      value["spreadM"] = patch.spread
    }
    value.merge(details) { _, new in new }
    sink?(value)
  }

  func session(_ session: ARSession, didUpdate frame: ARFrame) {
    guard running, frame.timestamp >= startedAt, frame.timestamp - lastSent >= 0.12 else { return }
    lastSent = frame.timestamp
    guard ProcessInfo.processInfo.systemUptime - frame.timestamp <= 0.35 else {
      epoch += 1
      previousPose = nil
      emit("stale", frame: frame); return
    }
    guard case .normal = frame.camera.trackingState else {
      epoch += 1
      previousPose = nil
      emit("tracking", frame: frame); return
    }
    let pose = frame.camera.transform
    let old = previousPose
    previousPose = pose
    guard let old else { emit("moving", frame: frame); return }
    let moved = simd_distance(SIMD3(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z),
      SIMD3(old.columns.3.x, old.columns.3.y, old.columns.3.z))
    let rotation = simd_mul(simd_transpose(simd_float3x3(old)), simd_float3x3(pose))
    let cosine = max(-1, min(1, (rotation.columns.0.x + rotation.columns.1.y + rotation.columns.2.z - 1) / 2))
    guard moved <= 0.025, acos(cosine) <= 0.04 else {
      epoch += 1
      emit("moving", frame: frame); return
    }
    if objectsEnabled {
      analyzeObjects(frame)
      return
    }
    guard let view = preview, view.bounds.width > 0, view.bounds.height > 0,
      let orientation = view.window?.windowScene?.interfaceOrientation,
      let depth = frame.sceneDepth, let confidence = depth.confidenceMap else {
      emit("unavailable", frame: frame); return
    }
    // The same ARFrame supplies view mapping, RGB, intrinsics, depth and pose.
    let inverse = frame.displayTransform(for: orientation, viewportSize: view.bounds.size).inverted()
    let point = CGPoint(x: 0.5, y: 0.5).applying(inverse)
    let buffer = depth.depthMap
    guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_DepthFloat32,
      CVPixelBufferGetPixelFormatType(confidence) == kCVPixelFormatType_OneComponent8 else {
      emit("unavailable", frame: frame); return
    }
    let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
    guard CVPixelBufferGetWidth(confidence) == w, CVPixelBufferGetHeight(confidence) == h,
      point.x.isFinite, point.y.isFinite, point.x >= 0, point.x <= 1,
      point.y >= 0, point.y <= 1 else { emit("unavailable", frame: frame); return }
    let x = Int(point.x * CGFloat(w)), y = Int(point.y * CGFloat(h))
    guard x >= 2, y >= 2, x + 2 < w, y + 2 < h else { emit("unavailable", frame: frame); return }
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    CVPixelBufferLockBaseAddress(confidence, .readOnly)
    defer {
      CVPixelBufferUnlockBaseAddress(confidence, .readOnly)
      CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
    }
    guard let raw = CVPixelBufferGetBaseAddress(buffer),
      let conf = CVPixelBufferGetBaseAddress(confidence) else { emit("unavailable", frame: frame); return }
    let k = frame.camera.intrinsics
    let sx = Double(w) / Double(frame.camera.imageResolution.width)
    let sy = Double(h) / Double(frame.camera.imageResolution.height)
    let fx = Double(k.columns.0.x) * sx, fy = Double(k.columns.1.y) * sy
    let cx = Double(k.columns.2.x) * sx, cy = Double(k.columns.2.y) * sy
    guard fx > 0, fy > 0 else { emit("unavailable", frame: frame); return }
    var pixels: [DepthPixel] = []
    for row in (y - 2)...(y + 2) {
      let depths = raw.advanced(by: row * CVPixelBufferGetBytesPerRow(buffer)).assumingMemoryBound(to: Float32.self)
      let confidences = conf.advanced(by: row * CVPixelBufferGetBytesPerRow(confidence)).assumingMemoryBound(to: UInt8.self)
      for col in (x - 2)...(x + 2) {
        pixels.append(DepthPixel(z: Double(depths[col]), confidence: confidences[col],
          rayX: (Double(col) - cx) / fx, rayY: (Double(row) - cy) / fy))
      }
    }
    guard let patch = DepthSampling.evaluate(pixels) else { emit("unreliable", frame: frame); return }
    emit("sample", frame: frame, patch: patch)
  }

  private func analyzeObjects(_ frame: ARFrame) {
    guard !busy else { return } // Drop frames, never queue camera inference.
    guard let view = preview, view.bounds.width > 0, view.bounds.height > 0,
      let orientation = view.window?.windowScene?.interfaceOrientation else {
      epoch += 1
      emit("unavailable", frame: frame); return
    }
    let rotation: Int
    switch orientation {
    case .portrait: rotation = 90
    case .portraitUpsideDown: rotation = 270
    case .landscapeLeft: rotation = 180
    case .landscapeRight: rotation = 0
    default: emit("unavailable", frame: frame); return
    }
    let size = view.bounds.size
    let transform = frame.displayTransform(for: orientation, viewportSize: size)
    let expectedGeneration = generation, expectedEpoch = epoch
    busy = true
    work.async { [weak self] in
      guard let self else { return }
      let result: Result<[[String: Any]], Error>
      let start = ProcessInfo.processInfo.systemUptime
      do {
        guard let detector = self.detector else { throw DepthDetector.Failure.invalid }
        result = .success(try detector.analyze(frame, rotation: rotation, displayTransform: transform))
      } catch { result = .failure(error) }
      let inferenceMs = (ProcessInfo.processInfo.systemUptime - start) * 1000
      DispatchQueue.main.async {
        self.busy = false
        guard self.running, expectedGeneration == self.generation, expectedEpoch == self.epoch else { return }
        guard self.preview?.bounds.size == size,
          self.preview?.window?.windowScene?.interfaceOrientation == orientation else {
          self.epoch += 1
          self.emit("moving", frame: frame); return
        }
        guard ProcessInfo.processInfo.systemUptime - frame.timestamp <= 0.35 else {
          self.emit("stale", frame: frame); return
        }
        guard case .success(let objects) = result else {
          self.emit("failed", frame: frame)
          self.stop(); return
        }
        self.emit("objects", frame: frame, details: ["objects": objects,
          "viewWidth": size.width, "viewHeight": size.height, "rotation": rotation,
          "inferenceMs": inferenceMs])
      }
    }
  }

  func sessionWasInterrupted(_ session: ARSession) {
    emit("interrupted")
    stop()
  }
  func session(_ session: ARSession, didFailWithError error: Error) {
    emit("failed")
    stop()
  }
}

private final class DepthDetector {
  enum Failure: Error { case invalid }
  let runner: TFLiteModelRunner
  let ids: [Int]
  let side: Int
  let anchors: Int
  let transposed: Bool
  let threshold: Float32

  init(arguments args: [String: Any]) throws {
    guard let path = args["model"] as? String, let sha = args["sha256"] as? String,
      let bytes = args["bytes"] as? Int, let classes = args["classes"] as? Int,
      let size = args["inputSize"] as? Int,
      let values = args["classIds"] as? [NSNumber],
      let cutoff = args["threshold"] as? Double, cutoff.isFinite, cutoff >= 0.05, cutoff <= 0.95 else {
      throw Failure.invalid
    }
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    guard data.count == bytes,
      SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == sha else { throw Failure.invalid }
    runner = try TFLiteModelRunner(modelPath: path, threadCount: 4)
    side = try IOSModelInputLayout(shape: runner.inputShape).side
    ids = values.map(\.intValue)
    let out = runner.outputShape
    guard side == size, out.count == 3, out[0] == 1,
      min(out[1], out[2]) == classes + 4, max(out[1], out[2]) > classes + 4,
      ids.count == classes, Set(ids).count == classes, ids.allSatisfy({ $0 >= 0 }) else { throw Failure.invalid }
    anchors = max(out[1], out[2])
    transposed = out[1] > out[2]
    threshold = Float32(cutoff)
  }

  func analyze(_ frame: ARFrame, rotation: Int, displayTransform: CGAffineTransform) throws -> [[String: Any]] {
    let prepared = try IOSFramePreprocessor.prepare(pixelBuffer: frame.capturedImage,
      inputSize: side, rotationDegrees: rotation)
    let output = try runner.invoke(input: prepared.values)
    guard output.count == anchors * (ids.count + 4) else { throw Failure.invalid }
    let decoded = IOSYoloDecoder.decode(values: output, anchors: anchors, classes: ids.count,
      transposed: transposed, threshold: threshold, inputSize: side,
      sourceWidth: prepared.uprightWidth, sourceHeight: prepared.uprightHeight,
      scaledWidth: prepared.scaledWidth, scaledHeight: prepared.scaledHeight,
      padX: prepared.padX, padY: prepared.padY, classIds: ids)
    let detections = IOSYoloDecoder.nonMaximumSuppression(decoded.detections, iouThreshold: 0.45, maximum: 20)
    let rawBoxes = detections.map { detection -> CGRect in
      let corners = [(-1.0, -1.0), (1.0, -1.0), (-1.0, 1.0), (1.0, 1.0)].map { dx, dy in
        CameraImageMath.rawPoint(x: Double(detection.cx) + dx * Double(detection.width) / 2,
          y: Double(detection.cy) + dy * Double(detection.height) / 2, rotation: rotation)
      }
      let xs = corners.map { $0.0 }, ys = corners.map { $0.1 }
      return CGRect(x: max(0, xs.min()!), y: max(0, ys.min()!),
        width: min(1, xs.max()!) - max(0, xs.min()!), height: min(1, ys.max()!) - max(0, ys.min()!))
    }
    var results: [[String: Any]] = []
    for (index, detection) in detections.enumerated() {
      let raw = rawBoxes[index]
      let displayed = raw.applying(displayTransform).standardized
      let visible = displayed.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
      guard !visible.isNull, displayed.width > 0, displayed.height > 0,
        displayed.midX >= 0, displayed.midX <= 1, displayed.midY >= 0, displayed.midY <= 1,
        visible.width * visible.height / (displayed.width * displayed.height) >= 0.6 else { continue }
      var value: [String: Any] = ["id": detection.id, "score": Double(detection.score),
        "box": [visible.minX, visible.minY, visible.width, visible.height], "reason": "unreliable"]
      let occluders = rawBoxes.enumerated().filter { $0.offset != index }.map { $0.element }
      value.merge(sample(frame, box: raw, occluders: occluders, transform: displayTransform)) { _, next in next }
      results.append(value)
      if results.count == 5 { break }
    }
    return results
  }

  private func sample(_ frame: ARFrame, box: CGRect, occluders: [CGRect], transform: CGAffineTransform) -> [String: Any] {
    guard let depth = frame.sceneDepth, let confidence = depth.confidenceMap else { return ["reason": "depth_missing"] }
    let buffer = depth.depthMap
    let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
    guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_DepthFloat32,
      CVPixelBufferGetPixelFormatType(confidence) == kCVPixelFormatType_OneComponent8,
      CVPixelBufferGetWidth(confidence) == w, CVPixelBufferGetHeight(confidence) == h else { return ["reason": "depth_format"] }
    let unmasked = CameraImageMath.localPatches(box: box, occluders: [], width: w, height: h)
    guard !unmasked.isEmpty else { return ["reason": "small"] }
    let patches = CameraImageMath.localPatches(box: box, occluders: occluders, width: w, height: h)
    guard !patches.isEmpty else { return ["reason": "overlap"] }
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    CVPixelBufferLockBaseAddress(confidence, .readOnly)
    defer {
      CVPixelBufferUnlockBaseAddress(confidence, .readOnly)
      CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
    }
    guard let raw = CVPixelBufferGetBaseAddress(buffer),
      let conf = CVPixelBufferGetBaseAddress(confidence) else { return ["reason": "depth_missing"] }
    let k = frame.camera.intrinsics
    let sx = Double(w) / Double(frame.camera.imageResolution.width)
    let sy = Double(h) / Double(frame.camera.imageResolution.height)
    let fx = Double(k.columns.0.x) * sx, fy = Double(k.columns.1.y) * sy
    let cx = Double(k.columns.2.x) * sx, cy = Double(k.columns.2.y) * sy
    guard fx > 0, fy > 0 else { return ["reason": "depth_format"] }
    var best: [String: Any] = ["reason": "low_depth"]
    var bestValid = -1
    for grid in patches {
    let pixels = grid.map { col, row -> DepthPixel in
      let values = raw.advanced(by: row * CVPixelBufferGetBytesPerRow(buffer)).assumingMemoryBound(to: Float32.self)
      let confidenceRow = conf.advanced(by: row * CVPixelBufferGetBytesPerRow(confidence)).assumingMemoryBound(to: UInt8.self)
      return DepthPixel(z: Double(values[col]), confidence: confidenceRow[col],
        rayX: (Double(col) - cx) / fx, rayY: (Double(row) - cy) / fy)
    }
    let assessment = DepthSampling.inspect(pixels)
    let center = grid[12]
    let point = CGPoint(x: Double(center.0) / Double(w), y: Double(center.1) / Double(h)).applying(transform)
    guard point.x >= 0, point.x <= 1, point.y >= 0, point.y <= 1 else { continue }
    var result: [String: Any] = ["reason": assessment.reason, "validDepth": assessment.valid,
      "depthTotal": assessment.total, "samplePoint": [point.x, point.y]]
    if let patch = assessment.patch {
      result["rangeM"] = patch.range; result["planeZM"] = patch.z
      result["accepted"] = patch.accepted; result["total"] = patch.total; result["spreadM"] = patch.spread
      return result
    }
    if assessment.valid > bestValid { best = result; bestValid = assessment.valid }
    }
    return best
  }
}

private final class DepthPreviewFactory: NSObject, FlutterPlatformViewFactory {
  private let plugin: DepthPlugin
  init(plugin: DepthPlugin) { self.plugin = plugin }
  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
    DepthPreview(frame: frame, plugin: plugin)
  }
}

private final class DepthPreview: NSObject, FlutterPlatformView {
  private let content: ARSCNView
  init(frame: CGRect, plugin: DepthPlugin) {
    content = ARSCNView(frame: frame)
    super.init()
    plugin.attach(content)
  }
  func view() -> UIView { content }
}

private extension simd_float3x3 {
  init(_ m: simd_float4x4) {
    self.init(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
      SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
      SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z))
  }
}

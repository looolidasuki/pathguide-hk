import ARKit
import AVFoundation
import CoreImage
import CryptoKit
import Flutter
import ImageIO
import UIKit

/// Camera-only source. Driver start/stop run on the plugin's serial session
/// queue; frames never queue work on main or initialize a model/AR session.
protocol RouteCaptureDriving: AnyObject {
  var previewSession: AVCaptureSession? { get }
  func start(frame: @escaping (CVPixelBuffer, CMTime, CMTime?) -> Void) throws -> Bool
  func stop()
}

private final class RouteFrameReceiver: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
  let deliver: (CVPixelBuffer, CMTime, CMTime?) -> Void
  let clock: () -> CMClock?
  init(clock: @escaping () -> CMClock?, deliver: @escaping (CVPixelBuffer, CMTime, CMTime?) -> Void) {
    self.clock = clock
    self.deliver = deliver
  }
  func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer,
                     from connection: AVCaptureConnection) {
    guard CMSampleBufferDataIsReady(sample), let pixels = CMSampleBufferGetImageBuffer(sample) else { return }
    let pts = CMSampleBufferGetPresentationTimeStamp(sample)
    let mapped = clock().map { CMSyncConvertTime(pts, from: $0, to: CMClockGetHostTimeClock()) }
    deliver(pixels, pts, mapped)
  }
}

final class AVRouteCaptureDriver: RouteCaptureDriving {
  let captureSession = AVCaptureSession()
  var previewSession: AVCaptureSession? { captureSession }
  private let frames = DispatchQueue(label: "hk.pathguide.route-camera.frames")
  private var receiver: RouteFrameReceiver?

  func start(frame: @escaping (CVPixelBuffer, CMTime, CMTime?) -> Void) throws -> Bool {
    try configure(frame: frame)
    captureSession.startRunning()
    return captureSession.isRunning
  }

  private func configure(frame: @escaping (CVPixelBuffer, CMTime, CMTime?) -> Void) throws {
    captureSession.beginConfiguration()
    defer { captureSession.commitConfiguration() }
    for output in captureSession.outputs { captureSession.removeOutput(output) }
    for input in captureSession.inputs { captureSession.removeInput(input) }
    captureSession.sessionPreset = .hd1280x720
    guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
      throw RouteCameraError.unavailable
    }
    let input = try AVCaptureDeviceInput(device: camera)
    guard captureSession.canAddInput(input) else { throw RouteCameraError.unavailable }
    captureSession.addInput(input)
    let output = AVCaptureVideoDataOutput()
    output.alwaysDiscardsLateVideoFrames = true
    output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String:
      Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)]
    let receiver = RouteFrameReceiver(clock: { [weak self] in
      guard let self else { return nil }
      if #available(iOS 15.4, *) { return self.captureSession.synchronizationClock }
      return self.captureSession.masterClock
    }, deliver: frame)
    self.receiver = receiver
    output.setSampleBufferDelegate(receiver, queue: frames)
    guard captureSession.canAddOutput(output) else { throw RouteCameraError.unavailable }
    captureSession.addOutput(output)
    if let connection = output.connection(with: .video), connection.isVideoOrientationSupported {
      connection.videoOrientation = .landscapeRight
      if connection.isVideoMirroringSupported { connection.isVideoMirrored = false }
    }
  }

  func stop() {
    if captureSession.isRunning { captureSession.stopRunning() }
    for output in captureSession.outputs {
      (output as? AVCaptureVideoDataOutput)?.setSampleBufferDelegate(nil, queue: nil)
    }
    frames.sync {} // No old delegate callback survives the stop acknowledgment.
    captureSession.beginConfiguration()
    for output in captureSession.outputs { captureSession.removeOutput(output) }
    for input in captureSession.inputs { captureSession.removeInput(input) }
    captureSession.commitConfiguration()
    receiver = nil
  }
}

enum RouteCameraError: Error { case unavailable, encoding }

struct RouteCaptureContext {
  let requestID: String
  let session: String
  let generation: Int
  let routeID: String
  let routeVersion: Int
  let epoch = UUID()
}

struct RouteCameraFrame {
  let pixels: CVPixelBuffer
  let context: RouteCaptureContext
  let sequence: Int64
  let pts: CMTime
  let hostTime: CMTime?
  let rotation: Int

  func header(requestID: String, now: CMTime) -> [String: Any] {
    let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
    let portrait = rotation == 90 || rotation == 270
    var result: [String: Any] = [
      "requestId": requestID, "startRequestId": context.requestID,
      "session": context.session, "generation": context.generation,
      "routeId": context.routeID, "routeVersion": context.routeVersion,
      "sequence": sequence, "captureClockId": "avcapture-session-\(context.epoch.uuidString)",
      "clockEpoch": context.epoch.uuidString, "rawTimestampValue": pts.value,
      "rawTimestampTimescale": pts.timescale, "rawTimestampEpoch": pts.epoch,
      "source": "avfoundation-back-wide", "profile": "route-camera-engineering-v1",
      "rawWidth": width, "rawHeight": height, "uprightWidth": portrait ? height : width,
      "uprightHeight": portrait ? width : height, "rotationDegrees": rotation,
      "mirrored": false, "clockMapping": "unknown", "walkingValidated": false,
    ]
    if pts.isNumeric, let hostTime, hostTime.isNumeric, now.isNumeric,
       hostTime.epoch == now.epoch {
      let captured = CMTimeGetSeconds(hostTime), current = CMTimeGetSeconds(now)
      if captured.isFinite, current.isFinite {
        result["clockMapping"] = "coremedia-host"
        result["capturedHostSeconds"] = captured
        result["nativeNowHostSeconds"] = current
        result["ageMs"] = (current - captured) * 1000
      }
    }
    return result
  }
}

/// One latest buffer, protected without dispatching a main-queue task per frame.
final class RouteFrameMailbox {
  private let lock = NSLock()
  private var context: RouteCaptureContext?
  private var latest: RouteCameraFrame?
  private var sequence: Int64 = 0
  private var rotation = 90

  func activate(_ context: RouteCaptureContext) {
    lock.lock(); defer { lock.unlock() }
    self.context = context; latest = nil; sequence = 0
  }
  func invalidate() {
    lock.lock(); defer { lock.unlock() }
    context = nil; latest = nil
  }
  func orient(_ rotation: Int) {
    lock.lock(); defer { lock.unlock() }
    if self.rotation != rotation { self.rotation = rotation; latest = nil }
  }
  func put(_ pixels: CVPixelBuffer, pts: CMTime, hostTime: CMTime?, epoch: UUID) {
    lock.lock(); defer { lock.unlock() }
    guard let context, context.epoch == epoch else { return }
    sequence += 1
    latest = RouteCameraFrame(pixels: pixels, context: context, sequence: sequence,
      pts: pts, hostTime: hostTime, rotation: rotation)
  }
  func snapshot(epoch: UUID) -> RouteCameraFrame? {
    lock.lock(); defer { lock.unlock() }
    guard context?.epoch == epoch else { return nil }
    return latest
  }
  var currentEpoch: UUID? {
    lock.lock(); defer { lock.unlock() }
    return context?.epoch
  }
}

struct RouteEncodedKeyframe {
  let data: Data
  let width: Int
  let height: Int
}

enum RouteKeyframeEncoder {
  static let maxSide = 1280
  static let maxBytes = 512 * 1024
  static func encode(_ frame: RouteCameraFrame) throws -> RouteEncodedKeyframe {
    let orientation: CGImagePropertyOrientation
    switch frame.rotation {
    case 0: orientation = .up
    case 90: orientation = .right
    case 180: orientation = .down
    case 270: orientation = .left
    default: throw RouteCameraError.encoding
    }
    let image = CIImage(cvPixelBuffer: frame.pixels).oriented(orientation)
    let factor = min(1, Double(maxSide) / max(image.extent.width, image.extent.height))
    let resized = image.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
    let context = CIContext(options: [.cacheIntermediates: false])
    guard let cg = context.createCGImage(resized, from: resized.extent),
      cg.width > 0, cg.height > 0, max(cg.width, cg.height) <= maxSide else {
      throw RouteCameraError.encoding
    }
    // At most three bounded attempts; never save a temporary file or video.
    for quality in [0.8, 0.6, 0.4] {
      if let bytes = UIImage(cgImage: cg).jpegData(compressionQuality: quality), bytes.count <= maxBytes {
        return RouteEncodedKeyframe(data: bytes, width: cg.width, height: cg.height)
      }
    }
    throw RouteCameraError.encoding
  }
}

final class RouteCameraPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private let methods: FlutterMethodChannel
  private let events: FlutterEventChannel
  private let coordinator: CameraCoordinator
  private let driver: RouteCaptureDriving
  private let authorization: () -> AVAuthorizationStatus
  private let requestPermission: (@escaping (Bool) -> Void) -> Void
  private let capabilities: () -> [String: Any]
  private let now: () -> CMTime
  private let encoder: (RouteCameraFrame) throws -> RouteEncodedKeyframe
  private let isActive: () -> Bool
  private let sessionQueue = DispatchQueue(label: "hk.pathguide.route-camera.session")
  private let imageQueue = DispatchQueue(label: "hk.pathguide.route-camera.jpeg", qos: .userInitiated)
  private let mailbox = RouteFrameMailbox()
  private var access: CameraLeaseClient?
  private var context: RouteCaptureContext?
  private var state = "stopped"
  private var sink: FlutterEventSink?
  private var subscriber: String?
  private var pending: (id: String, token: UUID, reply: CameraOnceReply<Any?>)?
  // Remains busy through cancellation until the old encoder actually drains.
  private var encodingToken: UUID?
  private weak var preview: RouteCameraPreviewView?
  static let maxAgeMs = 1000.0 // Capture-only engineering profile, not a walking threshold.

  init(messenger: FlutterBinaryMessenger, coordinator: CameraCoordinator = .shared,
       driver: RouteCaptureDriving = AVRouteCaptureDriver(),
       authorization: @escaping () -> AVAuthorizationStatus = { AVCaptureDevice.authorizationStatus(for: .video) },
       requestPermission: @escaping (@escaping (Bool) -> Void) -> Void = {
         AVCaptureDevice.requestAccess(for: .video, completionHandler: $0)
       }, capabilities: @escaping () -> [String: Any] = {
         ["camera": AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil,
          "arTracking": ARWorldTrackingConfiguration.isSupported,
          "sceneDepth": ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)]
       }, now: @escaping () -> CMTime = { CMClockGetTime(CMClockGetHostTimeClock()) },
       encoder: @escaping (RouteCameraFrame) throws -> RouteEncodedKeyframe = RouteKeyframeEncoder.encode,
       isActive: @escaping () -> Bool = { UIApplication.shared.applicationState == .active }) {
    self.coordinator = coordinator; self.driver = driver; self.authorization = authorization
    self.requestPermission = requestPermission; self.capabilities = capabilities
    self.now = now; self.encoder = encoder; self.isActive = isActive
    methods = FlutterMethodChannel(name: "hk.pathguide/route_camera", binaryMessenger: messenger)
    events = FlutterEventChannel(name: "hk.pathguide/route_camera/events", binaryMessenger: messenger)
    super.init()
    methods.setMethodCallHandler { [weak self] call, result in self?.handle(call, result: result) }
    events.setStreamHandler(self)
    NotificationCenter.default.addObserver(self, selector: #selector(background),
      name: UIApplication.didEnterBackgroundNotification, object: nil)
    if let session = driver.previewSession {
      NotificationCenter.default.addObserver(self, selector: #selector(interrupted),
        name: .AVCaptureSessionWasInterrupted, object: session)
      NotificationCenter.default.addObserver(self, selector: #selector(interrupted),
        name: .AVCaptureSessionRuntimeError, object: session)
    }
  }
  deinit { NotificationCenter.default.removeObserver(self) }

  static func register(with registrar: FlutterPluginRegistrar) {
    let plugin = RouteCameraPlugin(messenger: registrar.messenger())
    registrar.register(RouteCameraPreviewFactory(plugin), withId: "hk.pathguide/route_camera/preview")
  }
  func onListen(withArguments args: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    subscriber = (args as? [String: Any])?["subscriber"] as? String
    sink = events; return nil
  }
  func onCancel(withArguments args: Any?) -> FlutterError? {
    guard (args as? [String: Any])?["subscriber"] as? String == subscriber else { return nil }
    sink = nil; subscriber = nil; stop(status: "stopped") { _ in }; return nil
  }
  @objc private func background() { stop(status: "paused") { _ in } }
  @objc private func interrupted() {
    // Capture notifications may arrive on an AVFoundation queue.
    guard let epoch = mailbox.currentEpoch else { return }
    DispatchQueue.main.async { [weak self] in
      guard let self, self.context?.epoch == epoch else { return }
      self.stop(status: "interrupted") { _ in }
    }
  }
  func attach(_ view: RouteCameraPreviewView) {
    preview = view
    // A retained view may be created before start finishes. Bind only after
    // configuration/start has drained, and detach on main before physical stop.
    view.captureLayer.session = state == "running" ? driver.previewSession : nil
    view.orientationChanged = { [weak self] rotation in self?.mailbox.orient(rotation) }
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    precondition(Thread.isMainThread)
    if call.method == "capabilities" {
      var value = capabilities()
      switch authorization() {
      case .authorized: value["authorization"] = "authorized"
      case .notDetermined: value["authorization"] = "not_determined"
      case .restricted: value["authorization"] = "restricted"
      default: value["authorization"] = "denied"
      }
      value["profile"] = "route-camera-engineering-v1"
      value["maxKeyframeBytes"] = RouteKeyframeEncoder.maxBytes
      value["maxKeyframeSide"] = RouteKeyframeEncoder.maxSide
      value["maxFrameAgeMs"] = Self.maxAgeMs
      value["walkingValidated"] = false
      result(value); return
    }
    guard let args = call.arguments as? [String: Any] else { result(failure("bad_args")); return }
    if call.method == "start" { start(args, result: result); return }
    guard let context, args["session"] as? String == context.session,
      args["generation"] as? Int == context.generation else { result(failure("stale_request")); return }
    switch call.method {
    case "status": result(failure(state))
    case "stop":
      let response = failure("stopped")
      stop(status: "stopped") { confirmed in
        var value = response
        if !confirmed { value["status"] = "stop_unconfirmed" }
        result(value)
      }
    case "cancelKeyframe":
      guard let id = args["requestId"] as? String, pending?.id == id else {
        result(failure("stale_request")); return
      }
      let response = failure("cancelled")
      cancelPending(); result(response)
    case "latestObservation", "captureKeyframe":
      guard let requestID = args["requestId"] as? String, !requestID.isEmpty else { result(failure("bad_args")); return }
      guard access?.isCurrent == true, state == "running", isActive() else { result(failure("paused")); return }
      guard let frame = mailbox.snapshot(epoch: context.epoch) else { result(failure("no_frame")); return }
      let header = frame.header(requestID: requestID, now: now())
      guard valid(header) else { result(["status": validity(header), "header": header]); return }
      if call.method == "latestObservation" { result(["status": "available", "header": header]); return }
      capture(frame, requestID: requestID, result: result)
    default: result(FlutterMethodNotImplemented)
    }
  }

  private func failure(_ status: String) -> [String: Any] {
    var value: [String: Any] = ["status": status]
    if let context {
      value["session"] = context.session; value["generation"] = context.generation
      value["routeId"] = context.routeID; value["routeVersion"] = context.routeVersion
    }
    return value
  }
  private func publish(_ state: String) { self.state = state; sink?(failure(state)) }
  private func validity(_ header: [String: Any]) -> String {
    guard let age = header["ageMs"] as? Double, age.isFinite else { return "unknown_clock" }
    if age < 0 { return "future_frame" }
    return age <= Self.maxAgeMs ? "available" : "stale_frame"
  }
  private func valid(_ header: [String: Any]) -> Bool { validity(header) == "available" }

  private func start(_ args: [String: Any], result: @escaping FlutterResult) {
    guard let id = args["requestId"] as? String, !id.isEmpty,
      let session = args["session"] as? String, !session.isEmpty,
      let generation = args["generation"] as? Int, generation > 0,
      let route = args["routeId"] as? String, !route.isEmpty,
      let version = args["routeVersion"] as? Int, version > 0 else { result(failure("bad_args")); return }
    guard isActive() else { result(failure("paused")); return }
    if let context, session == context.session, generation <= context.generation {
      result(failure("stale_request")); return
    }
    let previous = access
    let previousCapture = pending, cancelledCapture = failure("cancelled")
    pending = nil
    let next = RouteCaptureContext(requestID: id, session: session, generation: generation,
      routeID: route, routeVersion: version)
    let reply = CameraOnceReply<Any?>(result)
    let client = CameraLeaseClient(owner: .route, coordinator: coordinator) { [weak self] in
      reply.finish(["status": "paused", "session": next.session, "generation": next.generation])
      guard let self, self.context?.epoch == next.epoch else { return }
      self.mailbox.invalidate()
      if ["running", "starting"].contains(self.state) { self.publish("paused") }
      if self.context?.epoch == next.epoch { self.cancelPending() }
    }
    // Commit the new identity before exposing cancellation/event callbacks.
    // Either callback may synchronously start a newer generation.
    context = next; access = client; mailbox.invalidate(); state = "starting"
    previous?.cancel()
    previousCapture?.reply.finish(cancelledCapture)
    guard context?.epoch == next.epoch else { client.cancel(); return }
    publish("starting")
    guard context?.epoch == next.epoch else { client.cancel(); return }
    client.acquire(stop: { [weak self] acknowledge in
      guard let self else { acknowledge(true); return }
      self.preview?.captureLayer.session = nil
      self.sessionQueue.async {
        self.driver.stop()
        self.imageQueue.async { DispatchQueue.main.async { acknowledge(true) } }
      }
    }) { [weak self] granted in
      guard let self, granted, client.isCurrent else { return }
      func begin(_ allowed: Bool) {
        guard client.isCurrent, self.context?.epoch == next.epoch, self.isActive() else {
          reply.finish(["status": "paused"]); client.cancel(); return
        }
        guard allowed else {
          self.publish("permission"); reply.finish(self.failure("permission")); client.cancel(); return
        }
        self.mailbox.activate(next)
        self.sessionQueue.async {
          guard DispatchQueue.main.sync(execute: { client.isCurrent && self.isActive() }) else {
            DispatchQueue.main.async { reply.finish(["status": "paused"]); client.cancel() }
            return
          }
          do {
            let running = try self.driver.start { [weak self] pixels, pts, hostTime in
              self?.mailbox.put(pixels, pts: pts, hostTime: hostTime, epoch: next.epoch)
            }
            DispatchQueue.main.async {
              guard client.isCurrent, self.context?.epoch == next.epoch else { return }
              self.preview?.captureLayer.session = running ? self.driver.previewSession : nil
              self.preview?.setNeedsLayout()
              self.preview?.layoutIfNeeded()
              self.publish(running ? "running" : "unavailable")
              reply.finish(self.failure(running ? "running" : "unavailable"))
              if !running { client.cancel() }
            }
          } catch {
            DispatchQueue.main.async {
              guard client.isCurrent, self.context?.epoch == next.epoch else { return }
              self.publish("unavailable"); reply.finish(self.failure("unavailable")); client.cancel()
            }
          }
        }
      }
      switch self.authorization() {
      case .authorized: begin(true)
      case .notDetermined:
        self.requestPermission { allowed in DispatchQueue.main.async { begin(allowed) } }
      default: begin(false)
      }
    }
  }

  private func stop(status: String, completion: @escaping (Bool) -> Void) {
    let stopping = access, epoch = context?.epoch
    let interim = status == "stopped" ? "stopping" : status
    mailbox.invalidate(); state = interim; cancelPending()
    if context?.epoch == epoch { publish(interim) }
    let finished: (Bool) -> Void = { confirmed in
      if self.context?.epoch == epoch { self.publish(confirmed ? status : "stop_unconfirmed") }
      completion(confirmed)
    }
    if let stopping { stopping.cancel(completion: finished) } else { finished(true) }
  }
  private func cancelPending() {
    let old = pending; pending = nil
    old?.reply.finish(failure("cancelled"))
  }
  private func capture(_ frame: RouteCameraFrame, requestID: String, result: @escaping FlutterResult) {
    guard encodingToken == nil else { result(failure("busy")); return }
    let token = UUID(), reply = CameraOnceReply<Any?>(result)
    pending = (requestID, token, reply); encodingToken = token
    imageQueue.async {
      let encoded = Result { try self.encoder(frame) }
      DispatchQueue.main.async {
        if self.encodingToken == token { self.encodingToken = nil }
        guard self.pending?.token == token else { return }
        self.pending = nil
        guard self.access?.isCurrent == true, self.context?.epoch == frame.context.epoch,
          self.isActive() else { reply.finish(self.failure("paused")); return }
        let header = frame.header(requestID: requestID, now: self.now())
        guard self.valid(header) else { reply.finish(["status": self.validity(header), "header": header]); return }
        guard case .success(let value) = encoded, !value.data.isEmpty,
          value.data.count <= RouteKeyframeEncoder.maxBytes, value.width > 0, value.height > 0,
          max(value.width, value.height) <= RouteKeyframeEncoder.maxSide else {
          reply.finish(self.failure("encoding_failed")); return
        }
        reply.finish(["status": "captured", "header": header, "jpeg": FlutterStandardTypedData(bytes: value.data),
          "sha256": SHA256.hash(data: value.data).map { String(format: "%02x", $0) }.joined(),
          "width": value.width, "height": value.height, "orientation": "up", "byteCount": value.data.count])
      }
    }
  }
}

final class RouteCameraPreviewView: UIView {
  override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
  var captureLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
  var orientationChanged: ((Int) -> Void)?
  override func layoutSubviews() {
    super.layoutSubviews()
    guard let orientation = window?.windowScene?.interfaceOrientation else { return }
    let video: AVCaptureVideoOrientation, rotation: Int
    switch orientation {
    case .portrait: video = .portrait; rotation = 90
    case .portraitUpsideDown: video = .portraitUpsideDown; rotation = 270
    case .landscapeLeft: video = .landscapeLeft; rotation = 180
    case .landscapeRight: video = .landscapeRight; rotation = 0
    default: return
    }
    if let connection = captureLayer.connection, connection.isVideoOrientationSupported {
      connection.videoOrientation = video
    }
    orientationChanged?(rotation)
  }
}

private final class RouteCameraPlatformView: NSObject, FlutterPlatformView {
  let nativeView: RouteCameraPreviewView
  init(frame: CGRect, plugin: RouteCameraPlugin) {
    nativeView = RouteCameraPreviewView(frame: frame)
    super.init()
    nativeView.backgroundColor = .black
    nativeView.captureLayer.videoGravity = .resizeAspect
    nativeView.isAccessibilityElement = false; nativeView.accessibilityElementsHidden = true
    plugin.attach(nativeView)
  }
  func view() -> UIView { nativeView }
}

private final class RouteCameraPreviewFactory: NSObject, FlutterPlatformViewFactory {
  let plugin: RouteCameraPlugin
  init(_ plugin: RouteCameraPlugin) { self.plugin = plugin }
  func create(withFrame frame: CGRect, viewIdentifier _: Int64, arguments _: Any?) -> FlutterPlatformView {
    RouteCameraPlatformView(frame: frame, plugin: plugin)
  }
  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol { FlutterStandardMessageCodec.sharedInstance() }
}

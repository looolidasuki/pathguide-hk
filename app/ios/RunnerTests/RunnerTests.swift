import Flutter
import AVFoundation
import CoreVideo
import CryptoKit
import CoreLocation
import MapKit
import ImageIO
@testable import Runner
import UIKit
import XCTest

class RunnerTests: XCTestCase {
  func testRoutePreviewBindsOnlyRunningSessionAndDetachesBeforeStop() {
    let driver = RouteTestDriver()
    driver.previewSession = AVCaptureSession()
    let plugin = RouteCameraPlugin(messenger: NavigationTestMessenger(), coordinator: CameraCoordinator(), driver: driver,
      authorization: { .authorized }, isActive: { true })
    let preview = RouteCameraPreviewView(frame: .zero)
    plugin.attach(preview)
    XCTAssertNil(preview.captureLayer.session)
    let started = expectation(description: "start binds preview")
    plugin.handle(FlutterMethodCall(methodName: "start", arguments: routeArgs())) { _ in started.fulfill() }
    wait(for: [started], timeout: 5)
    XCTAssertTrue(preview.captureLayer.session === driver.previewSession)
    let stopped = expectation(description: "stop detaches preview")
    plugin.handle(FlutterMethodCall(methodName: "stop", arguments: routeArgs())) { _ in stopped.fulfill() }
    XCTAssertNil(preview.captureLayer.session)
    wait(for: [stopped], timeout: 5)
  }
  func testLandmarkRejectsInvalidFeatureRevisionAndCancelledImage() throws {
    XCTAssertThrowsError(try RouteLandmarkAnalyzer.distance(Data([1]), Data([1]), feature: "other"))
    XCTAssertThrowsError(try RouteLandmarkAnalyzer.distance(Data([1]), Data([1])))
    XCTAssertThrowsError(try RouteLandmarkAnalyzer.analyze(jpeg: Data([1]), width: 1, height: 1, cancelled: { true }))
  }
  func testLandmarkFeatureArchiveSelfDistanceAndRuntimeOCRProfile() throws {
    let jpeg = RouteLandmarkProbe.fixtureJPEG()
    let analysis = try RouteLandmarkAnalyzer.analyze(jpeg: jpeg, width: 320, height: 240)
    XCTAssertFalse(analysis.feature.isEmpty)
    XCTAssertLessThanOrEqual(analysis.feature.count, 65536)
    XCTAssertEqual(try RouteLandmarkAnalyzer.distance(analysis.feature, analysis.feature), 0, accuracy: 0.001)
    var incompatible = try XCTUnwrap(JSONSerialization.jsonObject(with:analysis.feature) as? [String:Any])
    incompatible["preprocessRevision"] = "different-crop"
    XCTAssertThrowsError(try RouteLandmarkAnalyzer.distance(analysis.feature, JSONSerialization.data(withJSONObject:incompatible)))
    XCTAssertTrue(analysis.ocr.manualFloorConfirmationRequired)
    XCTAssertTrue([2, 3].contains(analysis.ocr.revision))
  }


  func testRouteStorageAppliesPolicyWithoutChangingExistingV1Bytes() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let original = Data([7, 8, 9])
    try original.write(to: base.appendingPathComponent("catalog.enc"))
    let storage = RouteProtectedFiles(root: base); try storage.prepare()
    XCTAssertEqual(try Data(contentsOf: base.appendingPathComponent("catalog.enc")), original)
    XCTAssertEqual(try storage.inspect()["allExcludedFromBackup"] as? Bool, true)
  }

  func testRouteStorageRejectsTraversalAndImmutableOverwrite() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let files = RouteProtectedFiles(root: base); try files.prepare()
    for path in ["../outside", "/tmp/outside", "catalog.enc", "a/../../outside", String(repeating: "a", count: 64) + "/../x.tmp"] {
      XCTAssertThrowsError(try files.write(path: path, data: Data([1])))
    }
    let temp = String(repeating: "b", count: 32) + ".tmp"
    try files.write(path: temp, data: Data([1]))
    XCTAssertThrowsError(try files.write(path: temp, data: Data([2])))
    try files.move(from: temp, to: "catalog.enc")
    XCTAssertEqual(try Data(contentsOf: base.appendingPathComponent("catalog.enc")), Data([1]))
  }

  func testRouteStorageRejectsSymlinkDirectoriesAndOversizedWrites() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base); try? FileManager.default.removeItem(at: outside) }
    let files = RouteProtectedFiles(root: base); try files.prepare()
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let folder = String(repeating: "c", count: 64)
    try FileManager.default.createSymbolicLink(at: base.appendingPathComponent(folder), withDestinationURL: outside)
    XCTAssertThrowsError(try files.write(path: folder + "/" + String(repeating: "d", count: 32) + ".enc.tmp", data: Data([1])))
    XCTAssertThrowsError(try files.prepare())
    XCTAssertThrowsError(try files.write(path: String(repeating: "d", count: 32) + ".tmp", data: Data(count: 2 * 1024 * 1024 + 1)))
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
  }

  func testRouteStorageProtectsTemporaryAndRenamedEncryptedFiles() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let storage = RouteProtectedFiles(root: base)
    try storage.prepare()
    try storage.write(path: String(repeating: "a", count: 32) + ".tmp", data: Data([1, 2, 3]))
    try storage.move(from: String(repeating: "a", count: 32) + ".tmp", to: "catalog.enc")
    let audit = try storage.inspect()
    #if targetEnvironment(simulator)
    // Simulator has no Data Protection class metadata. Do not report a real
    // protection pass; the device probe must verify the hardware separately.
    XCTAssertEqual(audit["protectionClasses"] as? [String], ["unavailable"])
    XCTAssertEqual(audit["allProtected"] as? Bool, false)
    #else
    XCTAssertEqual(audit["allProtected"] as? Bool, true, "\(audit)")
    #endif
    XCTAssertEqual(audit["allExcludedFromBackup"] as? Bool, true)
    XCTAssertEqual(audit["files"] as? Int, 2) // lock and catalog
  }



  func testRouteOldEventSubscriberCannotStopNewCameraSession() {
    let driver = RouteTestDriver(), plugin = routePlugin(driver)
    _ = plugin.onListen(withArguments: ["subscriber": "old"], eventSink: { _ in })
    startRoute(plugin); stopRoute(plugin)
    _ = plugin.onListen(withArguments: ["subscriber": "new"], eventSink: { _ in })
    startRoute(plugin, generation: 2)
    _ = plugin.onCancel(withArguments: ["subscriber": "old"])
    XCTAssertEqual(routeQuery(plugin, method: "status", generation: 2)["status"] as? String, "running")
    stopRoute(plugin, generation: 2)
  }

  func testCameraApplicationLifecycleBlocksLateStartsAndDoesNotAutoResume() {
    let coordinator = CameraCoordinator(), center = NotificationCenter()
    let lifecycle = CameraApplicationLifecycle(coordinator: coordinator, center: center, initiallyActive: true)
    var permissions = 0, starts = 0
    let plugin = VisionPlugin(messenger: NavigationTestMessenger(),
      cameraAuthorizationStatus: { .notDetermined },
      requestCameraAccess: { _ in permissions += 1 }, cameraCoordinator: coordinator,
      captureStart: { starts += 1; return true }, captureStop: {})
    center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
    var replies = 0
    plugin.handle(FlutterMethodCall(methodName: "startPreview", arguments: nil)) {
      replies += 1
      XCTAssertEqual(($0 as? [String: Any])?["started"] as? Bool, false)
    }
    XCTAssertTrue(coordinator.isBackgrounded)
    XCTAssertEqual(replies, 1)
    XCTAssertEqual(permissions, 0)
    center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
    XCTAssertFalse(coordinator.isBackgrounded)
    XCTAssertEqual(starts, 0)
    XCTAssertEqual(permissions, 0)
    withExtendedLifetime(lifecycle) {}
  }

  private func routeArgs(generation: Int = 1, request: String = "request") -> [String: Any] {
    ["requestId": request, "session": "route-session", "generation": generation,
      "routeId": "local-route", "routeVersion": 3]
  }

  func testRouteStartingEventReentryPreservesNewerGeneration() {
    let driver = RouteTestDriver(), plugin = routePlugin(driver)
    let newest = expectation(description: "newer start survives synchronous event reentry")
    var reentered = false
    _ = plugin.onListen(withArguments: nil) { value in
      guard let event = value as? [String: Any], event["status"] as? String == "starting",
        event["generation"] as? Int == 1, !reentered else { return }
      reentered = true
      plugin.handle(FlutterMethodCall(methodName: "start", arguments: self.routeArgs(generation: 2))) {
        XCTAssertEqual(($0 as? [String: Any])?["status"] as? String, "running")
        newest.fulfill()
      }
    }
    plugin.handle(FlutterMethodCall(methodName: "start", arguments: routeArgs())) {
      XCTAssertEqual(($0 as? [String: Any])?["status"] as? String, "paused")
    }
    wait(for: [newest], timeout: 5)
    XCTAssertEqual(routeQuery(plugin, method: "status", generation: 2)["status"] as? String, "running")
    stopRoute(plugin, generation: 2)
    _ = plugin.onListen(withArguments: nil, eventSink: { _ in })
  }

  func testRouteStopCaptureReplyReentryCannotCancelNewStart() throws {
    let driver = RouteTestDriver()
    let entered = expectation(description: "encoder entered"), unblock = DispatchSemaphore(value: 0)
    let plugin = routePlugin(driver, encoder: { _ in
      entered.fulfill(); _ = unblock.wait(timeout: .now() + 5)
      return RouteEncodedKeyframe(data: Data([1]), width: 4, height: 8)
    })
    startRoute(plugin)
    let time = CMTime(seconds: 99.9, preferredTimescale: 1000)
    driver.frames[0](try routePixels(), time, time)
    let newest = expectation(description: "capture cancellation callback restarts next generation")
    plugin.handle(FlutterMethodCall(methodName: "captureKeyframe", arguments: routeArgs())) { value in
      XCTAssertEqual((value as? [String: Any])?["status"] as? String, "cancelled")
      plugin.handle(FlutterMethodCall(methodName: "start", arguments: self.routeArgs(generation: 2))) {
        XCTAssertEqual(($0 as? [String: Any])?["status"] as? String, "running")
        newest.fulfill()
      }
    }
    wait(for: [entered], timeout: 5)
    let stopped = expectation(description: "old stop reply retains old generation")
    plugin.handle(FlutterMethodCall(methodName: "stop", arguments: routeArgs())) {
      XCTAssertEqual(($0 as? [String: Any])?["generation"] as? Int, 1)
      stopped.fulfill()
    }
    unblock.signal()
    wait(for: [newest, stopped], timeout: 5)
    XCTAssertEqual(routeQuery(plugin, method: "status", generation: 2)["status"] as? String, "running")
    stopRoute(plugin, generation: 2)
  }
  private func routePlugin(_ driver: RouteTestDriver, coordinator: CameraCoordinator = CameraCoordinator(),
    now: @escaping () -> CMTime = { CMTime(seconds: 100, preferredTimescale: 1000) },
    encoder: @escaping (RouteCameraFrame) throws -> RouteEncodedKeyframe = RouteKeyframeEncoder.encode
  ) -> RouteCameraPlugin {
    RouteCameraPlugin(messenger: NavigationTestMessenger(), coordinator: coordinator, driver: driver,
      authorization: { .authorized }, capabilities: { ["camera": true, "arTracking": false, "sceneDepth": false] },
      now: now, encoder: encoder, isActive: { true })
  }
  private func startRoute(_ plugin: RouteCameraPlugin, generation: Int = 1) {
    let running = expectation(description: "route camera started without interpreter or AR")
    plugin.handle(FlutterMethodCall(methodName: "start", arguments: routeArgs(generation: generation))) {
      XCTAssertEqual(($0 as? [String: Any])?["status"] as? String, "running")
      running.fulfill()
    }
    wait(for: [running], timeout: 5)
  }
  private func stopRoute(_ plugin: RouteCameraPlugin, generation: Int = 1) {
    let stopped = expectation(description: "route driver and image queue drained")
    plugin.handle(FlutterMethodCall(methodName: "stop", arguments: routeArgs(generation: generation))) {
      XCTAssertEqual(($0 as? [String: Any])?["status"] as? String, "stopped")
      stopped.fulfill()
    }
    wait(for: [stopped], timeout: 5)
  }
  private func routeQuery(_ plugin: RouteCameraPlugin, method: String = "latestObservation",
    generation: Int = 1, request: String = "query") -> [String: Any] {
    var value: [String: Any] = [:]
    plugin.handle(FlutterMethodCall(methodName: method,
      arguments: routeArgs(generation: generation, request: request))) { value = $0 as? [String: Any] ?? [:] }
    return value
  }
  private func routePixels(width: Int = 8, height: Int = 4) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
    let pixels = try XCTUnwrap(buffer)
    CVPixelBufferLockBaseAddress(pixels, [])
    if let bytes = CVPixelBufferGetBaseAddress(pixels) {
      memset(bytes, 120, CVPixelBufferGetBytesPerRow(pixels) * height)
    }
    CVPixelBufferUnlockBaseAddress(pixels, [])
    return pixels
  }

  func testRouteCameraStartsWithoutAROrModelAndCapabilitiesStaySeparate() {
    let driver = RouteTestDriver(), coordinator = CameraCoordinator()
    let plugin = routePlugin(driver, coordinator: coordinator)
    let caps = routeQuery(plugin, method: "capabilities")
    XCTAssertEqual(caps["camera"] as? Bool, true)
    XCTAssertEqual(caps["arTracking"] as? Bool, false)
    XCTAssertEqual(caps["sceneDepth"] as? Bool, false)
    XCTAssertEqual(caps["walkingValidated"] as? Bool, false)
    startRoute(plugin)
    XCTAssertEqual(driver.starts, 1)
    XCTAssertEqual(routeQuery(plugin)["status"] as? String, "no_frame")
    stopRoute(plugin)
    XCTAssertEqual(driver.stops, 1)
    XCTAssertEqual(coordinator.currentStatus, .idle)
  }

  func testRouteQueuedCancellationNeverRequestsPermissionOrStartsDriver() {
    let coordinator = CameraCoordinator(), driver = RouteTestDriver()
    var acknowledge: ((Bool) -> Void)?
    coordinator.request(owner: .vision, stop: { acknowledge = $0 }) { _ in }
    var permissions = 0, replies = 0
    let plugin = RouteCameraPlugin(messenger: NavigationTestMessenger(), coordinator: coordinator, driver: driver,
      authorization: { .notDetermined }, requestPermission: { _ in permissions += 1 }, isActive: { true })
    plugin.handle(FlutterMethodCall(methodName: "start", arguments: routeArgs())) {
      replies += 1; XCTAssertEqual(($0 as? [String: Any])?["status"] as? String, "paused")
    }
    stopRoute(plugin)
    acknowledge?(true)
    XCTAssertEqual(permissions, 0)
    XCTAssertEqual(driver.starts, 0)
    XCTAssertEqual(driver.stops, 0)
    XCTAssertEqual(replies, 1)
    XCTAssertEqual(coordinator.currentStatus, .idle)
  }

  func testRouteLatePermissionCannotStartAfterStop() {
    let driver = RouteTestDriver()
    var permission: ((Bool) -> Void)?, replies = 0
    let plugin = RouteCameraPlugin(messenger: NavigationTestMessenger(), coordinator: CameraCoordinator(), driver: driver,
      authorization: { .notDetermined }, requestPermission: { permission = $0 }, isActive: { true })
    plugin.handle(FlutterMethodCall(methodName: "start", arguments: routeArgs())) {
      replies += 1; XCTAssertEqual(($0 as? [String: Any])?["status"] as? String, "paused")
    }
    XCTAssertNotNil(permission)
    stopRoute(plugin)
    permission?(true)
    let drained = expectation(description: "late route permission callback")
    DispatchQueue.main.async { drained.fulfill() }
    wait(for: [drained], timeout: 5)
    XCTAssertEqual(driver.starts, 0)
    XCTAssertEqual(replies, 1)
  }

  func testRouteDeniedPermissionRepliesOnceAndReleasesLease() {
    let driver = RouteTestDriver(), coordinator = CameraCoordinator()
    let plugin = RouteCameraPlugin(messenger: NavigationTestMessenger(), coordinator: coordinator, driver: driver,
      authorization: { .denied }, isActive: { true })
    var replies = 0
    plugin.handle(FlutterMethodCall(methodName: "start", arguments: routeArgs())) {
      replies += 1; XCTAssertEqual(($0 as? [String: Any])?["status"] as? String, "permission")
    }
    stopRoute(plugin)
    XCTAssertEqual(replies, 1)
    XCTAssertEqual(driver.starts, 0)
    XCTAssertEqual(coordinator.currentStatus, .idle)
  }

  func testRouteLatestMailboxBindsMetadataAndNeverEncodesUnrequestedFrames() throws {
    let driver = RouteTestDriver()
    var encodes = 0
    let plugin = routePlugin(driver, encoder: { _ in encodes += 1; throw RouteCameraError.encoding })
    startRoute(plugin)
    let pixels = try routePixels()
    for _ in 0..<50 {
      driver.frames[0](pixels, CMTime(seconds: 500, preferredTimescale: 1000),
        CMTime(seconds: 99.8, preferredTimescale: 1000))
    }
    let value = routeQuery(plugin), header = try XCTUnwrap(value["header"] as? [String: Any])
    XCTAssertEqual(value["status"] as? String, "available")
    XCTAssertNil(value["jpeg"])
    XCTAssertEqual(encodes, 0)
    XCTAssertEqual(header["session"] as? String, "route-session")
    XCTAssertEqual(header["generation"] as? Int, 1)
    XCTAssertEqual(header["routeVersion"] as? Int, 3)
    XCTAssertEqual(header["routeId"] as? String, "local-route")
    XCTAssertEqual(header["sequence"] as? Int64, 50)
    XCTAssertEqual(header["rawTimestampValue"] as? Int64, 500000)
    XCTAssertEqual(header["clockMapping"] as? String, "coremedia-host")
    XCTAssertEqual(try XCTUnwrap(header["ageMs"] as? Double), 200, accuracy: 0.001)
    XCTAssertEqual(header["uprightWidth"] as? Int, 4)
    XCTAssertEqual(header["uprightHeight"] as? Int, 8)
    XCTAssertNotNil(FlutterStandardMethodCodec.sharedInstance().encodeSuccessEnvelope(value))
    stopRoute(plugin)
  }

  func testRouteUnknownFutureAndStaleClocksNeverEncode() throws {
    let driver = RouteTestDriver()
    var encodes = 0
    let plugin = routePlugin(driver, encoder: { _ in encodes += 1; throw RouteCameraError.encoding })
    startRoute(plugin)
    let pixels = try routePixels(), pts = CMTime(seconds: 500, preferredTimescale: 1000)
    let cases: [(CMTime?, String)] = [(nil, "unknown_clock"), (.invalid, "unknown_clock"),
      (CMTime(seconds: 101, preferredTimescale: 1000), "future_frame"),
      (CMTime(seconds: 98, preferredTimescale: 1000), "stale_frame")]
    for (host, status) in cases {
      driver.frames[0](pixels, pts, host)
      XCTAssertEqual(routeQuery(plugin, method: "captureKeyframe")["status"] as? String, status)
    }
    XCTAssertEqual(encodes, 0)
    stopRoute(plugin)
  }

  func testRouteKeyframeJPEGIsUprightBoundedAndHashBindsActualBytes() throws {
    let driver = RouteTestDriver(), plugin = routePlugin(driver)
    startRoute(plugin)
    driver.frames[0](try routePixels(width: 1600, height: 800),
      CMTime(seconds: 500, preferredTimescale: 1000), CMTime(seconds: 99.9, preferredTimescale: 1000))
    let captured = expectation(description: "explicit bounded JPEG")
    plugin.handle(FlutterMethodCall(methodName: "captureKeyframe", arguments: routeArgs(request: "jpeg"))) { value in
      guard let value = value as? [String: Any], let data = (value["jpeg"] as? FlutterStandardTypedData)?.data else {
        XCTFail("missing JPEG: \(String(describing: value))"); captured.fulfill(); return
      }
      XCTAssertEqual(value["status"] as? String, "captured")
      XCTAssertEqual(value["orientation"] as? String, "up")
      XCTAssertEqual(value["width"] as? Int, 640)
      XCTAssertEqual(value["height"] as? Int, 1280)
      XCTAssertLessThanOrEqual(data.count, RouteKeyframeEncoder.maxBytes)
      XCTAssertEqual(value["sha256"] as? String, SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
      let source = CGImageSourceCreateWithData(data as CFData, nil)
      XCTAssertNotNil(source)
      if let source, let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
        XCTAssertEqual(image.width, 640); XCTAssertEqual(image.height, 1280)
      } else { XCTFail("invalid JPEG") }
      captured.fulfill()
    }
    wait(for: [captured], timeout: 5)
    stopRoute(plugin)
  }

  func testRouteCancelledEncoderStaysBoundedAndHandoffWaitsForDrain() throws {
    let coordinator = CameraCoordinator(), driver = RouteTestDriver()
    let entered = expectation(description: "JPEG worker entered"), unblock = DispatchSemaphore(value: 0)
    let plugin = routePlugin(driver, coordinator: coordinator, encoder: { _ in
      entered.fulfill(); _ = unblock.wait(timeout: .now() + 5)
      return RouteEncodedKeyframe(data: Data([1,2,3]), width: 4, height: 8)
    })
    startRoute(plugin)
    driver.frames[0](try routePixels(), CMTime(value: 1, timescale: 1), CMTime(seconds: 99.9, preferredTimescale: 1000))
    var replies = 0
    plugin.handle(FlutterMethodCall(methodName: "captureKeyframe", arguments: routeArgs(request: "pending"))) {
      replies += 1; XCTAssertEqual(($0 as? [String: Any])?["status"] as? String, "cancelled")
    }
    wait(for: [entered], timeout: 5)
    XCTAssertEqual(routeQuery(plugin, method: "captureKeyframe")["status"] as? String, "busy")
    _ = routeQuery(plugin, method: "cancelKeyframe", request: "other")
    XCTAssertEqual(replies, 0)
    _ = routeQuery(plugin, method: "cancelKeyframe", request: "pending")
    XCTAssertEqual(replies, 1)
    XCTAssertEqual(routeQuery(plugin, method: "captureKeyframe")["status"] as? String, "busy")
    let granted = expectation(description: "next camera after JPEG drain")
    var grants = 0
    coordinator.request(owner: .vision, stop: { $0(true) }) { outcome in
      guard case .granted(let lease) = outcome else { return XCTFail("handoff failed") }
      grants += 1; coordinator.release(lease); granted.fulfill()
    }
    XCTAssertEqual(grants, 0)
    unblock.signal()
    wait(for: [granted], timeout: 5)
    XCTAssertEqual(replies, 1)
    XCTAssertEqual(driver.stops, 1)
    XCTAssertEqual(coordinator.currentStatus, .idle)
  }

  func testRouteExpiredDuringJPEGDoesNotDeliverImage() throws {
    let driver = RouteTestDriver()
    var clock = CMTime(seconds: 100, preferredTimescale: 1000)
    let entered = expectation(description: "slow JPEG"), unblock = DispatchSemaphore(value: 0)
    let plugin = routePlugin(driver, now: { clock }, encoder: { _ in
      entered.fulfill(); _ = unblock.wait(timeout: .now() + 5)
      return RouteEncodedKeyframe(data: Data([1]), width: 4, height: 8)
    })
    startRoute(plugin)
    driver.frames[0](try routePixels(), CMTime(value: 1, timescale: 1), CMTime(seconds: 99.9, preferredTimescale: 1000))
    let expired = expectation(description: "expired payload rejected after encoding")
    plugin.handle(FlutterMethodCall(methodName: "captureKeyframe", arguments: routeArgs())) { value in
      XCTAssertEqual((value as? [String: Any])?["status"] as? String, "stale_frame")
      XCTAssertNil((value as? [String: Any])?["jpeg"]); expired.fulfill()
    }
    wait(for: [entered], timeout: 5)
    clock = CMTime(seconds: 102, preferredTimescale: 1000)
    unblock.signal()
    wait(for: [expired], timeout: 5)
    stopRoute(plugin)
  }

  func testRouteOldCallbacksAndStaleStopCannotAffectNewGeneration() throws {
    let driver = RouteTestDriver(), plugin = routePlugin(driver)
    startRoute(plugin); stopRoute(plugin)
    startRoute(plugin, generation: 2)
    let pixels = try routePixels(), time = CMTime(seconds: 99.9, preferredTimescale: 1000)
    driver.frames[0](pixels, time, time)
    XCTAssertEqual(routeQuery(plugin, generation: 2)["status"] as? String, "no_frame")
    XCTAssertEqual(routeQuery(plugin, method: "stop")["status"] as? String, "stale_request")
    driver.frames[1](pixels, time, time)
    let header = routeQuery(plugin, generation: 2)["header"] as? [String: Any]
    XCTAssertEqual(header?["generation"] as? Int, 2)
    XCTAssertEqual(header?["sequence"] as? Int64, 1)
    stopRoute(plugin, generation: 2)
  }

  func testRouteBackgroundInvalidatesFramesWithoutForegroundResume() throws {
    let driver = RouteTestDriver(), plugin = routePlugin(driver)
    startRoute(plugin)
    NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
    stopRoute(plugin)
    let time = CMTime(seconds: 99.9, preferredTimescale: 1000)
    driver.frames[0](try routePixels(), time, time)
    NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
    XCTAssertEqual(routeQuery(plugin)["status"] as? String, "paused")
    XCTAssertEqual(driver.starts, 1)
  }

  func testRouteInvalidContextDoesNotTouchCamera() {
    let driver = RouteTestDriver(), plugin = routePlugin(driver)
    var args = routeArgs(); args["routeVersion"] = 0
    plugin.handle(FlutterMethodCall(methodName: "start", arguments: args)) {
      XCTAssertEqual(($0 as? [String: Any])?["status"] as? String, "bad_args")
    }
    XCTAssertEqual(driver.starts, 0)
    XCTAssertEqual(driver.stops, 0)
  }

  func testRouteJPEGEncoderNormalizesFourRotationsAndCornerPositions() throws {
    let pixels = try routePixels(width: 80, height: 40)
    CVPixelBufferLockBaseAddress(pixels, [])
    let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(pixels)
    let colors: [[UInt8]] = [[255,0,0], [0,255,0], [0,0,255], [255,255,0]]
    for y in 0..<40 {
      for x in 0..<80 {
        let rgb = colors[(y < 20 ? 0 : 2) + (x < 40 ? 0 : 1)]
        let p = y * stride + x * 4
        base[p] = rgb[2]; base[p+1] = rgb[1]; base[p+2] = rgb[0]; base[p+3] = 255
      }
    }
    CVPixelBufferUnlockBaseAddress(pixels, [])
    let context = RouteCaptureContext(requestID: "r", session: "s", generation: 1, routeID: "route", routeVersion: 1)
    for (rotation, corner) in [(0, 0), (90, 2), (180, 3), (270, 1)] {
      let frame = RouteCameraFrame(pixels: pixels, context: context, sequence: 1,
        pts: .zero, hostTime: .zero, rotation: rotation)
      let encoded = try RouteKeyframeEncoder.encode(frame)
      let image = try XCTUnwrap(CIImage(data: encoded.data))
      var rgba = [UInt8](repeating: 0, count: 4)
      let sample = CGRect(x: 4, y: encoded.height - 5, width: 1, height: 1)
      rgba.withUnsafeMutableBytes { bytes in
        CIContext().render(image, toBitmap: bytes.baseAddress!, rowBytes: 4, bounds: sample,
          format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
      }
      for channel in 0..<3 {
        XCTAssertEqual(Int(rgba[channel]), Int(colors[corner][channel]), accuracy: 35, "rotation \(rotation)")
      }
      XCTAssertEqual(UIImage(data: encoded.data)?.imageOrientation, .up)
    }
  }

  func testRouteRejectsEncodedPayloadAboveHardByteLimit() throws {
    let driver = RouteTestDriver()
    let plugin = routePlugin(driver, encoder: { _ in
      RouteEncodedKeyframe(data: Data(repeating: 1, count: RouteKeyframeEncoder.maxBytes + 1), width: 4, height: 8)
    })
    startRoute(plugin)
    let time = CMTime(seconds: 99.9, preferredTimescale: 1000)
    driver.frames[0](try routePixels(), time, time)
    let rejected = expectation(description: "oversized bytes never cross Flutter channel")
    plugin.handle(FlutterMethodCall(methodName: "captureKeyframe", arguments: routeArgs())) {
      XCTAssertEqual(($0 as? [String: Any])?["status"] as? String, "encoding_failed")
      XCTAssertNil(($0 as? [String: Any])?["jpeg"]); rejected.fulfill()
    }
    wait(for: [rejected], timeout: 5)
    stopRoute(plugin)
  }

  func testRouteStopTimeoutReportsUnconfirmedAndKeepsHardwareGateClosed() {
    let driver = RouteTestDriver(), scheduler = RouteTestScheduler()
    let coordinator = CameraCoordinator(scheduler: scheduler)
    let entered = expectation(description: "physical stop is blocked"), unblock = DispatchSemaphore(value: 0)
    driver.onStop = { entered.fulfill(); _ = unblock.wait(timeout: .now() + 5) }
    let plugin = routePlugin(driver, coordinator: coordinator)
    startRoute(plugin)
    var replies = 0
    plugin.handle(FlutterMethodCall(methodName: "stop", arguments: routeArgs())) {
      replies += 1
      XCTAssertEqual(($0 as? [String: Any])?["status"] as? String, "stop_unconfirmed")
    }
    XCTAssertEqual(routeQuery(plugin, method: "status")["status"] as? String, "stopping")
    wait(for: [entered], timeout: 5)
    XCTAssertEqual(replies, 0)
    scheduler.fire()
    XCTAssertEqual(replies, 1)
    XCTAssertEqual(routeQuery(plugin, method: "status")["status"] as? String, "stop_unconfirmed")
    coordinator.request(owner: .vision, stop: { $0(true) }) { outcome in
      XCTAssertEqual(outcome, .failed(.physicalStopFailed))
    }
    unblock.signal()
  }

  func testMenuCaptureFailureRepliesOnlyAfterDismissal() {
    let coordinator = CameraCoordinator()
    let controller = UIImagePickerController()
    var dismissed: (() -> Void)?
    var replies = 0
    let plugin = MenuPlugin(messenger: NavigationTestMessenger(), cameraCoordinator: coordinator,
      cameraAuthorizationStatus: { .authorized }, cameraPresenter: { _ in controller },
      pickerDismisser: { _, completion in dismissed = completion })
    plugin.handle(FlutterMethodCall(methodName: "readMenu", arguments: ["requestId": "capture"])) { value in
      replies += 1
      XCTAssertEqual((value as? FlutterError)?.code, "capture_failed")
    }
    plugin.imagePickerController(controller, didFinishPickingMediaWithInfo: [:])
    XCTAssertEqual(replies, 0)
    XCTAssertNotNil(dismissed)
    dismissed?()
    XCTAssertEqual(replies, 1)
    XCTAssertEqual(coordinator.currentStatus, .idle)
  }

  func testMenuDeniedPermissionReleasesItsLease() {
    let coordinator = CameraCoordinator()
    var presentations = 0, replies = 0
    let plugin = MenuPlugin(messenger: NavigationTestMessenger(), cameraCoordinator: coordinator,
      cameraAuthorizationStatus: { .denied },
      cameraPresenter: { _ in presentations += 1; return UIViewController() })
    plugin.handle(FlutterMethodCall(methodName: "readMenu", arguments: ["requestId": "denied"])) { value in
      replies += 1
      XCTAssertEqual((value as? FlutterError)?.code, "camera_denied")
    }
    XCTAssertEqual(presentations, 0)
    XCTAssertEqual(replies, 1)
    XCTAssertEqual(coordinator.currentStatus, .idle)
  }

  func testDepthBackgroundDoesNotResumeAfterForeground() {
    let coordinator = CameraCoordinator()
    var starts = 0, pauses = 0
    let plugin = DepthPlugin(messenger: NavigationTestMessenger(), cameraCoordinator: coordinator,
      isApplicationActive: { true },
      supportsDepth: { true }, cameraAuthorizationStatus: { .authorized },
      runSession: { _ in starts += 1 }, pauseSession: { pauses += 1 })
    plugin.handle(FlutterMethodCall(methodName: "start", arguments: ["session": "background"])) { value in
      XCTAssertEqual((value as? [String: Any])?["status"] as? String, "running")
    }
    NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
    let stopped = expectation(description: "background depth stop completed")
    plugin.stop { confirmed in XCTAssertTrue(confirmed); stopped.fulfill() }
    wait(for: [stopped], timeout: 5)
    NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
    XCTAssertEqual(starts, 1)
    XCTAssertEqual(pauses, 1)
    XCTAssertEqual(coordinator.currentStatus, .idle)
  }

  func testVisionQueuedStartDrainsBeforeHandoffAcknowledgment() {
    let coordinator = CameraCoordinator()
    let startEntered = expectation(description: "start running on session queue")
    let unblockStart = DispatchSemaphore(value: 0)
    var operations: [String] = []
    let plugin = VisionPlugin(messenger: NavigationTestMessenger(),
      cameraAuthorizationStatus: { .authorized }, cameraCoordinator: coordinator,
      captureStart: {
        operations.append("start")
        startEntered.fulfill()
        _ = unblockStart.wait(timeout: .now() + 5)
        return true
      }, captureStop: { operations.append("stop") })
    var replies = 0
    plugin.handle(FlutterMethodCall(methodName: "startPreview", arguments: nil)) { value in
      replies += 1
      XCTAssertEqual((value as? [String: Any])?["started"] as? Bool, false)
    }
    wait(for: [startEntered], timeout: 5)
    let handedOff = expectation(description: "grant after actual stop queue drained")
    var grants = 0
    coordinator.request(owner: .route, stop: { $0(true) }) { outcome in
      guard case .granted(let lease) = outcome else { return XCTFail("handoff failed") }
      XCTAssertEqual(operations, ["start", "stop"])
      grants += 1
      coordinator.release(lease)
      handedOff.fulfill()
    }
    XCTAssertEqual(grants, 0)
    unblockStart.signal()
    wait(for: [handedOff], timeout: 5)
    XCTAssertEqual(replies, 1)
    XCTAssertEqual(coordinator.currentStatus, .idle)
  }

  func testMenuBackgroundDismissalRejectsNewWorkUntilStopped() {
    let coordinator = CameraCoordinator()
    let controller = UIViewController()
    var dismissed: (() -> Void)?
    var replies = 0, presentations = 0
    let plugin = MenuPlugin(messenger: NavigationTestMessenger(), cameraCoordinator: coordinator,
      cameraAuthorizationStatus: { .authorized },
      cameraPresenter: { _ in presentations += 1; return controller },
      pickerDismisser: { _, completion in dismissed = completion })
    plugin.handle(FlutterMethodCall(methodName: "readMenu", arguments: ["requestId": "background"])) { value in
      replies += 1; XCTAssertNil(value)
    }
    NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
    var error: FlutterError?
    plugin.handle(FlutterMethodCall(methodName: "readMenu", arguments: ["requestId": "retry"])) {
      error = $0 as? FlutterError
    }
    XCTAssertEqual(error?.code, "busy")
    XCTAssertEqual(presentations, 1)
    XCTAssertEqual(replies, 1)
    dismissed?()
    XCTAssertEqual(coordinator.currentStatus, .idle)
  }

  func testDepthQueuedCancellationDoesNotRequestPermissionOrPauseHardware() {
    let coordinator = CameraCoordinator()
    var acknowledge: ((Bool) -> Void)?
    coordinator.request(owner: .route, stop: { acknowledge = $0 }) { _ in }
    var permissions = 0, pauses = 0, starts = 0, replies = 0
    let plugin = DepthPlugin(messenger: NavigationTestMessenger(), cameraCoordinator: coordinator,
      isApplicationActive: { true },
      supportsDepth: { true }, cameraAuthorizationStatus: { .notDetermined },
      requestCameraAccess: { _ in permissions += 1 },
      runSession: { _ in starts += 1 }, pauseSession: { pauses += 1 })
    plugin.handle(FlutterMethodCall(methodName: "start", arguments: ["session": "queued"])) { value in
      replies += 1
      XCTAssertEqual((value as? [String: Any])?["status"] as? String, "paused")
    }
    plugin.stop()
    acknowledge?(true)
    XCTAssertEqual(permissions, 0)
    XCTAssertEqual(pauses, 0)
    XCTAssertEqual(starts, 0)
    XCTAssertEqual(replies, 1)
    XCTAssertEqual(coordinator.currentStatus, .idle)
  }

  func testDepthLatePermissionCannotRestartAfterStop() {
    let coordinator = CameraCoordinator()
    var permission: ((Bool) -> Void)?
    var starts = 0, pauses = 0, replies = 0
    let plugin = DepthPlugin(messenger: NavigationTestMessenger(), cameraCoordinator: coordinator,
      isApplicationActive: { true },
      supportsDepth: { true }, cameraAuthorizationStatus: { .notDetermined },
      requestCameraAccess: { permission = $0 },
      runSession: { _ in starts += 1 }, pauseSession: { pauses += 1 })
    plugin.handle(FlutterMethodCall(methodName: "start", arguments: ["session": "late"])) { value in
      replies += 1
      XCTAssertEqual((value as? [String: Any])?["status"] as? String, "paused")
    }
    XCTAssertNotNil(permission)
    let stopped = expectation(description: "depth work drained")
    plugin.stop { confirmed in XCTAssertTrue(confirmed); stopped.fulfill() }
    wait(for: [stopped], timeout: 5)
    permission?(true)
    let drained = expectation(description: "late authorization consumed")
    DispatchQueue.main.async { drained.fulfill() }
    wait(for: [drained], timeout: 5)
    XCTAssertEqual(starts, 0)
    XCTAssertEqual(pauses, 1)
    XCTAssertEqual(replies, 1)
    XCTAssertEqual(coordinator.currentStatus, .idle)
  }

  func testDepthHandoffPausesAndDrainsBeforeNextOwner() {
    let coordinator = CameraCoordinator()
    var starts = 0, pauses = 0
    let plugin = DepthPlugin(messenger: NavigationTestMessenger(), cameraCoordinator: coordinator,
      isApplicationActive: { true },
      supportsDepth: { true }, cameraAuthorizationStatus: { .authorized },
      runSession: { _ in starts += 1 }, pauseSession: { pauses += 1 })
    plugin.handle(FlutterMethodCall(methodName: "start", arguments: ["session": "running"])) { value in
      XCTAssertEqual((value as? [String: Any])?["status"] as? String, "running")
    }
    XCTAssertEqual(starts, 1)
    let handedOff = expectation(description: "next owner waits for work barrier")
    var granted = false
    coordinator.request(owner: .route, stop: { $0(true) }) { outcome in
      guard case .granted(let lease) = outcome else { return XCTFail("handoff failed") }
      XCTAssertEqual(pauses, 1)
      granted = true
      coordinator.release(lease)
      handedOff.fulfill()
    }
    XCTAssertFalse(granted)
    wait(for: [handedOff], timeout: 5)
    XCTAssertEqual(coordinator.currentStatus, .idle)
  }

  func testMenuQueuedCancellationDoesNotRequestPermission() {
    let coordinator = CameraCoordinator()
    var acknowledge: ((Bool) -> Void)?
    coordinator.request(owner: .route, stop: { acknowledge = $0 }) { _ in }
    var permissions = 0, presentations = 0, replies = 0
    let plugin = MenuPlugin(messenger: NavigationTestMessenger(), cameraCoordinator: coordinator,
      cameraAuthorizationStatus: { .notDetermined },
      requestCameraAccess: { _ in permissions += 1 },
      cameraPresenter: { _ in presentations += 1; return UIViewController() })
    plugin.handle(FlutterMethodCall(methodName: "readMenu", arguments: ["requestId": "queued"])) { value in
      replies += 1; XCTAssertNil(value)
    }
    plugin.releaseCamera {}
    acknowledge?(true)
    XCTAssertEqual(permissions, 0)
    XCTAssertEqual(presentations, 0)
    XCTAssertEqual(replies, 1)
    XCTAssertEqual(coordinator.currentStatus, .idle)
  }

  func testMenuLatePermissionCannotPresentAfterCancellation() {
    let coordinator = CameraCoordinator()
    var permission: ((Bool) -> Void)?
    var presentations = 0, replies = 0
    let plugin = MenuPlugin(messenger: NavigationTestMessenger(), cameraCoordinator: coordinator,
      cameraAuthorizationStatus: { .notDetermined },
      requestCameraAccess: { permission = $0 },
      cameraPresenter: { _ in presentations += 1; return UIViewController() })
    plugin.handle(FlutterMethodCall(methodName: "readMenu", arguments: ["requestId": "late"])) { value in
      replies += 1; XCTAssertNil(value)
    }
    XCTAssertNotNil(permission)
    plugin.releaseCamera {}
    permission?(true)
    let drained = expectation(description: "late menu permission consumed")
    DispatchQueue.main.async { drained.fulfill() }
    wait(for: [drained], timeout: 5)
    XCTAssertEqual(presentations, 0)
    XCTAssertEqual(replies, 1)
    XCTAssertEqual(coordinator.currentStatus, .idle)
  }

  func testMenuHandoffWaitsForPickerDismissalAndCoalescesRelease() {
    let coordinator = CameraCoordinator()
    let controller = UIViewController()
    var dismissed: (() -> Void)?
    var dismissals = 0, replies = 0, grants = 0, releases = 0
    let plugin = MenuPlugin(messenger: NavigationTestMessenger(), cameraCoordinator: coordinator,
      cameraAuthorizationStatus: { .authorized },
      cameraPresenter: { _ in controller },
      pickerDismisser: { _, completion in dismissals += 1; dismissed = completion })
    plugin.handle(FlutterMethodCall(methodName: "readMenu", arguments: ["requestId": "picker"])) { value in
      replies += 1; XCTAssertNil(value)
    }
    coordinator.request(owner: .route, stop: { $0(true) }) { outcome in
      guard case .granted(let lease) = outcome else { return XCTFail("handoff failed") }
      grants += 1
      coordinator.release(lease)
    }
    plugin.releaseCamera { releases += 1 }
    XCTAssertEqual(dismissals, 1)
    XCTAssertEqual(grants, 0)
    XCTAssertEqual(releases, 0)
    XCTAssertEqual(replies, 1)
    dismissed?()
    XCTAssertEqual(grants, 1)
    XCTAssertEqual(releases, 1)
    XCTAssertEqual(coordinator.currentStatus, .idle)
  }

  func testVisionQueuedAcquisitionCancelsBeforeRequestingPermission() {
    let coordinator = CameraCoordinator()
    var acknowledge: ((Bool) -> Void)?
    coordinator.request(owner: .route, stop: { acknowledge = $0 }) { _ in }
    var permissionRequests = 0
    let plugin = VisionPlugin(messenger: NavigationTestMessenger(),
      cameraAuthorizationStatus: { .notDetermined },
      requestCameraAccess: { _ in permissionRequests += 1 },
      cameraCoordinator: coordinator)
    var replies = 0
    plugin.handle(FlutterMethodCall(methodName: "startPreview", arguments: nil)) { value in
      replies += 1
      XCTAssertEqual((value as? [String: Any])?["started"] as? Bool, false)
    }
    XCTAssertEqual(permissionRequests, 0)
    plugin.release { _ in }
    acknowledge?(true)
    XCTAssertEqual(permissionRequests, 0)
    XCTAssertEqual(replies, 1)
    XCTAssertEqual(coordinator.currentStatus, .idle)
  }

  func testVisionReleaseInvalidatesLateCameraPermission() {
    var permission: ((Bool) -> Void)?
    let plugin = VisionPlugin(messenger: NavigationTestMessenger(),
      cameraAuthorizationStatus: { .notDetermined },
      requestCameraAccess: { permission = $0 })
    let response = expectation(description: "cancelled start replies")
    plugin.handle(FlutterMethodCall(methodName: "startPreview", arguments: nil)) { value in
      XCTAssertEqual((value as? [String: Any])?["started"] as? Bool, false)
      response.fulfill()
    }
    XCTAssertNotNil(permission)
    let released = expectation(description: "camera release completes before permission")
    plugin.release { _ in released.fulfill() }
    wait(for: [released], timeout: 5)
    permission?(true)
    wait(for: [response], timeout: 5)
  }

  func testNavigationPluginAcceptsFlutterDelegateCalls() {
    let plugin: FlutterPlugin = NavigationPlugin(messenger: NavigationTestMessenger())
    // Flutter's registrar dispatches this Objective-C selector, rather than a
    // Swift-only helper. A missing implementation aborts the app on first use.
    guard plugin.responds(to: NSSelectorFromString("handleMethodCall:result:")) else {
      XCTFail("NavigationPlugin must implement FlutterPlugin's method-call selector")
      return
    }
    for method in ["cancelRoute", "cancelSearch"] {
      var replied = false
      plugin.handle?(FlutterMethodCall(methodName: method, arguments: nil), result: { value in
        replied = true
        XCTAssertNil(value)
      })
      XCTAssertTrue(replied, "\(method) must reply through FlutterPlugin dispatch")
    }
    var failure: FlutterError?
    plugin.handle?(FlutterMethodCall(methodName: "searchPlaces", arguments: ["query": ""]), result: { value in
      failure = value as? FlutterError
    })
    XCTAssertEqual(failure?.code, "invalid_argument")
  }

  func testNavigationCurrentLocationRejectsStaleFixAndEncodesFreshFix() throws {
    let manager = NavigationTestLocationManager()
    let plugin = NavigationPlugin(messenger: NavigationTestMessenger(), locationManager: manager,
                                  locationServicesEnabled: { true })
    var reply: Any?
    plugin.handle(FlutterMethodCall(methodName: "currentLocation", arguments: nil), result: { reply = $0 })
    XCTAssertEqual(manager.starts, 1)
    let stale = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 22.3, longitude: 114.2),
                          altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5,
                          timestamp: Date(timeIntervalSinceNow: -20))
    plugin.locationManager(manager, didUpdateLocations: [stale])
    XCTAssertNil(reply)
    let fresh = CLLocation(coordinate: stale.coordinate, altitude: 0,
                          horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: Date())
    plugin.locationManager(manager, didUpdateLocations: [fresh])
    let value = try XCTUnwrap(reply as? [String: Any])
    XCTAssertEqual(value["accuracy"] as? Double, 5)
    XCTAssertNotNil(FlutterStandardMethodCodec.sharedInstance().encodeSuccessEnvelope(value))
    XCTAssertGreaterThan(manager.stops, 0)
  }

  func testNavigationPermissionsRejectDeniedAndApproximateLocation() {
    let manager = NavigationTestLocationManager()
    let plugin = NavigationPlugin(messenger: NavigationTestMessenger(), locationManager: manager,
                                  locationServicesEnabled: { true })
    manager.status = .denied
    var failure: FlutterError?
    plugin.handle(FlutterMethodCall(methodName: "currentLocation", arguments: nil), result: { failure = $0 as? FlutterError })
    XCTAssertEqual(failure?.code, "location_denied")
    manager.status = .authorizedWhenInUse
    manager.accuracy = .reducedAccuracy
    plugin.handle(FlutterMethodCall(methodName: "startLocation", arguments: nil), result: { failure = $0 as? FlutterError })
    XCTAssertEqual(failure?.code, "location_denied")
    XCTAssertEqual(manager.starts, 0)
  }

  func testNavigationAccuracyDowngradeStopsTrackingAndRestoresWakeState() {
    let manager = NavigationTestLocationManager()
    let plugin = NavigationPlugin(messenger: NavigationTestMessenger(), locationManager: manager)
    let idleBefore = UIApplication.shared.isIdleTimerDisabled
    var events: [Any] = []
    _ = plugin.onListen(withArguments: nil, eventSink: { if let event = $0 { events.append(event) } })
    plugin.handle(FlutterMethodCall(methodName: "startLocation", arguments: nil), result: { XCTAssertNil($0) })
    plugin.handle(FlutterMethodCall(methodName: "keepAwake", arguments: ["enabled": true]), result: { _ in })
    manager.accuracy = .reducedAccuracy
    plugin.locationManagerDidChangeAuthorization(manager)
    XCTAssertEqual((events.last as? FlutterError)?.code, "location_poor")
    XCTAssertGreaterThan(manager.stops, 0)
    XCTAssertEqual(UIApplication.shared.isIdleTimerDisabled, idleBefore)
    _ = plugin.onCancel(withArguments: nil)
  }

  func testNavigationBackgroundCancelsPendingLocation() {
    let manager = NavigationTestLocationManager()
    let plugin = NavigationPlugin(messenger: NavigationTestMessenger(), locationManager: manager,
                                  locationServicesEnabled: { true })
    var failure: FlutterError?
    plugin.handle(FlutterMethodCall(methodName: "currentLocation", arguments: nil), result: { failure = $0 as? FlutterError })
    NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
    XCTAssertEqual(failure?.code, "cancelled")
    XCTAssertGreaterThan(manager.stops, 0)
  }

  func testNavigationEmptySearchAndThrottlingAreDistinct() {
    let empty = NSError(domain: MKErrorDomain, code: Int(MKError.Code.placemarkNotFound.rawValue))
    let result = NavigationPlugin.placesResult(nil, failure: empty)
    XCTAssertEqual((result as? [[String: Any]])?.count, 0)
    XCTAssertNotNil(FlutterStandardMethodCodec.sharedInstance().encodeSuccessEnvelope(result))
    let throttled = NSError(domain: MKErrorDomain, code: Int(MKError.Code.loadingThrottled.rawValue))
    XCTAssertEqual((NavigationPlugin.placesResult(nil, failure: throttled) as? FlutterError)?.code, "quota")
    let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
    XCTAssertEqual((NavigationPlugin.placesResult(nil, failure: offline) as? FlutterError)?.code, "unavailable")
  }

  func testPlanarModelReceivesSeparateRGBChannels() throws {
    let layout = try IOSModelInputLayout(shape: [1, 3, 2, 2])
    XCTAssertEqual(layout.side, 2)
    XCTAssertEqual(try layout.packRGB([1,2,3,4,5,6,7,8,9,10,11,12]),
                   [1,4,7,10,2,5,8,11,3,6,9,12])
    let legacy = try IOSModelInputLayout(shape: [1, 2, 2, 3])
    XCTAssertEqual(try legacy.packRGB([1,2,3,4,5,6,7,8,9,10,11,12]),
                   [1,2,3,4,5,6,7,8,9,10,11,12])
    XCTAssertThrowsError(try IOSModelInputLayout(shape: [1, 3, 640, 320]))
    XCTAssertThrowsError(try layout.packRGB([1,2,3]))
  }

  func testPortraitRotationMapping() {
    let size = IOSFramePreprocessor.rotatedSize(width: 1280, height: 720, degrees: 90)
    XCTAssertEqual(size.0, 720)
    XCTAssertEqual(size.1, 1280)
    let topLeft = IOSFramePreprocessor.sourcePoint(
      uprightX: 0, uprightY: 0, rawWidth: 1280, rawHeight: 720, degrees: 90)
    XCTAssertEqual(topLeft.0, 0)
    XCTAssertEqual(topLeft.1, 719)
  }

  func testDecoderMapsClassAndSuppressesOverlap() {
    // channels-first [cx, cy, width, height, score], one anchor and one class.
    let values: [Float32] = [0.5, 0.5, 0.2, 0.4, 0.9]
    let decoded = IOSYoloDecoder.decode(
      values: values,
      anchors: 1,
      classes: 1,
      transposed: false,
      threshold: 0.3,
      inputSize: 416,
      sourceWidth: 416,
      sourceHeight: 416,
      scaledWidth: 416,
      scaledHeight: 416,
      padX: 0,
      padY: 0,
      classIds: [7]
    )
    XCTAssertEqual(decoded.detections.count, 1)
    XCTAssertEqual(decoded.detections.first?.id, 7)
    XCTAssertEqual(decoded.detections.first?.score ?? 0, 0.9, accuracy: 0.0001)
    let doubled = decoded.detections + decoded.detections
    XCTAssertEqual(
      IOSYoloDecoder.nonMaximumSuppression(doubled, iouThreshold: 0.45, maximum: 100).count,
      1
    )
  }

  func testBundledModelShape() throws {
    let modelURL = Bundle.main.bundleURL
      .appendingPathComponent("Frameworks/App.framework/flutter_assets/assets/models/detector.tflite")
    XCTAssertTrue(FileManager.default.fileExists(atPath: modelURL.path), "Flutter model asset missing")
    let interpreter = try TFLiteModelRunner(modelPath: modelURL.path, threadCount: 4)
    let manifestURL = modelURL.deletingLastPathComponent().appendingPathComponent("detector.json")
    let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
    let classes = try XCTUnwrap(manifest["modelClassCount"] as? Int)
    let bytes = try Data(contentsOf: modelURL)
    XCTAssertEqual(bytes.count, manifest["bytes"] as? Int)
    XCTAssertEqual(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), manifest["sha256"] as? String)
    XCTAssertEqual(interpreter.inputShape, [1, 3, 640, 640])
    XCTAssertEqual(interpreter.outputShape, [1, classes + 4, 8400])
    let output = try interpreter.invoke(input: [Float32](repeating: 114.0 / 255.0, count: 640 * 640 * 3))
    XCTAssertEqual(output.count, (classes + 4) * 8400)
    XCTAssertTrue(output.allSatisfy { $0.isFinite })
    XCTAssertTrue(output.dropFirst(4 * 8400).allSatisfy { $0 >= 0 && $0 <= 1 })
  }

  func testCameraPreprocessingSeparatesFullAndVideoRange() throws {
    func make(_ format: OSType) throws -> CVPixelBuffer {
      var value: CVPixelBuffer?
      XCTAssertEqual(CVPixelBufferCreate(nil, 4, 4, format, nil, &value), kCVReturnSuccess)
      let buffer = try XCTUnwrap(value)
      CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
        kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
      CVPixelBufferLockBaseAddress(buffer, [])
      for plane in 0..<2 {
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, plane))
        memset(base, plane == 0 ? 16 : 128,
          CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane))
      }
      CVPixelBufferUnlockBaseAddress(buffer, [])
      return buffer
    }
    let full = try IOSFramePreprocessor.prepare(pixelBuffer: make(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange), inputSize: 4, rotationDegrees: 90)
    let video = try IOSFramePreprocessor.prepare(pixelBuffer: make(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange), inputSize: 4, rotationDegrees: 90)
    XCTAssertTrue(full.values.allSatisfy { abs($0 - 16 / 255) < 0.00001 })
    XCTAssertTrue(video.values.allSatisfy { $0 == 0 })
  }

  private func gradientBuffer(width: Int, height: Int, fullRange: Bool) throws -> CVPixelBuffer {
    var value: CVPixelBuffer?
    let format = fullRange ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
      : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    XCTAssertEqual(CVPixelBufferCreate(nil, width, height, format, nil, &value), kCVReturnSuccess)
    let buffer = try XCTUnwrap(value)
    CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
      kCVImageBufferYCbCrMatrix_ITU_R_601_4, .shouldPropagate)
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let y = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 0)).assumingMemoryBound(to: UInt8.self)
    for row in 0..<height {
      for col in 0..<width {
        y[row * CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) + col] =
          UInt8((fullRange ? 0 : 16) + row * 20 + col * 10)
      }
    }
    let uv = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 1))
    memset(uv, 128, CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) * CVPixelBufferGetHeightOfPlane(buffer, 1))
    return buffer
  }

  func testCameraResizeUsesBilinearPixelCentresBeforeModelPacking() throws {
    for fullRange in [true, false] {
      // Half-pixel resize samples x/y=.5,2.5,...; the old nearest path
      // incorrectly selected x/y=0,2,... and returned zero for this pixel.
      let expectedByRotation: [Int: [Float32]] = [
        0: [15,35,55,75,55,75,95,115,95,115,135,155],
        90: [95,55,15,115,75,35,135,95,55,155,115,75],
        180: [155,135,115,95,115,95,75,55,75,55,35,15],
        270: [75,115,155,55,95,135,35,75,115,15,55,95],
      ]
      for rotation in [0, 90, 180, 270] {
        let prepared = try IOSFramePreprocessor.prepare(
          pixelBuffer: gradientBuffer(width: 8, height: 6, fullRange: fullRange),
          inputSize: 4, rotationDegrees: rotation)
        let portrait = rotation == 90 || rotation == 270
        XCTAssertEqual(prepared.scaledWidth, portrait ? 3 : 4)
        XCTAssertEqual(prepared.scaledHeight, portrait ? 4 : 3)
        let divisor: Float32 = fullRange ? 255 : 219
        let expected = try XCTUnwrap(expectedByRotation[rotation])
        for row in 0..<4 {
          for col in 0..<4 {
            let padding = row >= prepared.scaledHeight || col >= prepared.scaledWidth
            let value = padding ? Float32(114.0 / 255.0) : expected[row * prepared.scaledWidth + col] / divisor
            for channel in 0..<3 {
              XCTAssertEqual(prepared.values[(row * 4 + col) * 3 + channel], value, accuracy: 0.00001)
            }
          }
        }
      }
    }
  }

  func testLetterboxRoundsDimensionsAndRejectsUnsupportedRotation() throws {
    let buffer = try gradientBuffer(width: 10, height: 8, fullRange: true)
    let prepared = try IOSFramePreprocessor.prepare(pixelBuffer: buffer, inputSize: 6, rotationDegrees: 0)
    XCTAssertEqual(prepared.scaledWidth, 6)
    XCTAssertEqual(prepared.scaledHeight, 5) // 8 * .6 = 4.8, not four rows.
    XCTAssertEqual(prepared.padY, 0)
    XCTAssertTrue(prepared.values.suffix(18).allSatisfy { abs($0 - 114 / 255) < 0.00001 })
    XCTAssertThrowsError(try IOSFramePreprocessor.prepare(pixelBuffer: buffer, inputSize: 6, rotationDegrees: 45))
  }

}

private final class RouteTestDriver: RouteCaptureDriving {
  var previewSession: AVCaptureSession?
  var starts = 0
  var stops = 0
  var frames: [(CVPixelBuffer, CMTime, CMTime?) -> Void] = []
  var onStop: (() -> Void)?
  func start(frame: @escaping (CVPixelBuffer, CMTime, CMTime?) -> Void) throws -> Bool {
    starts += 1; frames.append(frame); return true
  }
  func stop() { stops += 1; onStop?() }
}

private final class RouteTestScheduler: CameraTimeoutScheduler {
  private final class Token: CameraTimerToken {
    var cancelled = false
    let callback: () -> Void
    init(_ callback: @escaping () -> Void) { self.callback = callback }
    func cancel() { cancelled = true }
  }
  private var token: Token?
  func schedule(after seconds: TimeInterval, _ callback: @escaping () -> Void) -> CameraTimerToken {
    let next = Token(callback); token = next; return next
  }
  func fire() { if let token, !token.cancelled { token.callback() } }
}

private final class NavigationTestMessenger: NSObject, FlutterBinaryMessenger {
  func send(onChannel channel: String, message: Data?) {}
  func send(onChannel channel: String, message: Data?, binaryReply callback: FlutterBinaryReply?) {}
  func setMessageHandlerOnChannel(
    _ channel: String, binaryMessageHandler handler: FlutterBinaryMessageHandler?
  ) -> FlutterBinaryMessengerConnection { 1 }
  func cleanUpConnection(_ connection: FlutterBinaryMessengerConnection) {}
}

private final class NavigationTestLocationManager: CLLocationManager {
  var status: CLAuthorizationStatus = .authorizedWhenInUse
  var accuracy: CLAccuracyAuthorization = .fullAccuracy
  var starts = 0, stops = 0
  override var authorizationStatus: CLAuthorizationStatus { status }
  override var accuracyAuthorization: CLAccuracyAuthorization { accuracy }
  override func startUpdatingLocation() { starts += 1 }
  override func stopUpdatingLocation() { stops += 1 }
}


extension RunnerTests {
  func testLandmarkChannelBindsIdentityAndRejectsInvalidHash() {
    let plugin = RouteLandmarkPlugin()
    let done = expectation(description: "invalid image hash replied")
    plugin.handle(FlutterMethodCall(methodName: "analyze", arguments: [
      "requestId": "hash-check", "inputSha": "wrong", "jpeg": FlutterStandardTypedData(bytes: Data([1])),
      "width": 1, "height": 1,
      "featureRevision": RouteLandmarkAnalyzer.featureRevision,
      "preprocessRevision": RouteLandmarkAnalyzer.preprocessRevision])) { value in
      let reply = value as? [String: Any]
      XCTAssertEqual(reply?["requestId"] as? String, "hash-check")
      XCTAssertEqual(reply?["status"] as? String, "invalid")
      done.fulfill()
    }
    wait(for: [done], timeout: 5)
  }
  func testLandmarkChannelSingleFlightAndExactCancellation() {
    let plugin = RouteLandmarkPlugin()
    let jpeg = RouteLandmarkProbe.fixtureJPEG()
    let args: [String: Any] = ["requestId": "first", "inputSha": SHA256.hash(data: jpeg).map { String(format: "%02x", $0) }.joined(),
      "jpeg": FlutterStandardTypedData(bytes: jpeg), "width": 320, "height": 240,
      "featureRevision": RouteLandmarkAnalyzer.featureRevision, "preprocessRevision": RouteLandmarkAnalyzer.preprocessRevision]
    let done = expectation(description: "cancelled analysis drained")
    plugin.handle(FlutterMethodCall(methodName: "analyze", arguments: args)) { value in
      XCTAssertEqual((value as? [String: Any])?["status"] as? String, "cancelled")
      done.fulfill()
    }
    plugin.handle(FlutterMethodCall(methodName: "cancel", arguments: ["requestId": "other"])) { _ in }
    plugin.handle(FlutterMethodCall(methodName: "analyze", arguments: args)) { value in
      XCTAssertEqual((value as? [String: Any])?["status"] as? String, "busy")
    }
    plugin.handle(FlutterMethodCall(methodName: "cancel", arguments: ["requestId": "first"])) { _ in }
    plugin.handle(FlutterMethodCall(methodName: "analyze", arguments: args)) { value in
      XCTAssertEqual((value as? [String: Any])?["status"] as? String, "busy")
    }
    wait(for: [done], timeout: 10)
  }
}

import Flutter
import CoreVideo
import CryptoKit
import CoreLocation
import MapKit
@testable import Runner
import UIKit
import XCTest

class RunnerTests: XCTestCase {

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

import CryptoKit
import Flutter
import Foundation
import Vision

private final class LandmarkJob {
  let id: String
  private let lock = NSLock()
  private var cancelled = false
  private var requests: [VNRequest] = []
  init(_ id: String) { self.id = id }
  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }
  func publish(_ request: VNRequest) {
    lock.lock()
    requests.append(request)
    let stop = cancelled
    lock.unlock()
    if stop { request.cancel() }
  }
  func cancel() {
    lock.lock()
    cancelled = true
    let values = requests
    lock.unlock()
    values.forEach { $0.cancel() }
  }
}
final class RouteLandmarkPlugin: NSObject, FlutterPlugin {
  private let queue = DispatchQueue(label: "hk.pathguide.route-landmark")
  private var active: LandmarkJob?
  static func register(with registrar: FlutterPluginRegistrar) {
    let p = RouteLandmarkPlugin()
    registrar.addMethodCallDelegate(
      p,
      channel: FlutterMethodChannel(
        name: "hk.pathguide/route_landmark", binaryMessenger: registrar.messenger()))
  }
  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    guard let id = args["requestId"] as? String, !id.isEmpty, id.count <= 100 else {
      result(FlutterError(code: "invalid", message: nil, details: nil))
      return
    }
    if call.method == "cancel" {
      if active?.id == id { active?.cancel() }
      result(nil)
      return
    }
    guard ["analyze", "compare"].contains(call.method) else {
      result(FlutterMethodNotImplemented)
      return
    }
    let base: [String: Any] = [
      "requestId": id, "inputSha": args["inputSha"] as? String ?? "",
      "featureRevision": RouteLandmarkAnalyzer.featureRevision,
      "preprocessRevision": RouteLandmarkAnalyzer.preprocessRevision,
    ]
    guard active == nil else {
      result(base.merging(["status": "busy"]) { _, b in b })
      return
    }
    guard args["featureRevision"] as? String == RouteLandmarkAnalyzer.featureRevision,
      args["preprocessRevision"] as? String == RouteLandmarkAnalyzer.preprocessRevision
    else {
      result(base.merging(["status": "incompatible"]) { _, b in b })
      return
    }
    let job = LandmarkJob(id)
    active = job
    queue.async {
      var response = base
      do {
        if call.method == "analyze" {
          guard let jpeg = args["jpeg"] as? FlutterStandardTypedData,
            let w = args["width"] as? Int, let h = args["height"] as? Int,
            SHA256.hash(data: jpeg.data).map({ String(format: "%02x", $0) }).joined() == base[
              "inputSha"] as? String
          else { throw RouteLandmarkError.invalid }
          let a = try RouteLandmarkAnalyzer.analyze(
            jpeg: jpeg.data, width: w, height: h, cancelled: { job.isCancelled },
            publish: job.publish)
          response["feature"] = FlutterStandardTypedData(bytes: a.feature)
          response["featureSha"] = SHA256.hash(data: a.feature).map { String(format: "%02x", $0) }
            .joined()
          response["text"] = a.text
          response["ocrRevision"] = a.ocr.revision
          response["languages"] = a.ocr.languages
          response["manualFloorConfirmationRequired"] = true
        } else {
          guard let query = args["query"] as? FlutterStandardTypedData,
            let references = args["references"] as? [FlutterStandardTypedData], !references.isEmpty,
            references.count <= 64,
            query.data.count <= 65536,
            references.allSatisfy({ !$0.data.isEmpty && $0.data.count <= 65536 }),
            SHA256.hash(data: query.data).map({ String(format: "%02x", $0) }).joined() == base[
              "inputSha"] as? String
          else { throw RouteLandmarkError.invalid }
          var distances: [Double] = []
          for reference in references {
            if job.isCancelled { throw RouteLandmarkError.cancelled }
            distances.append(Double(try RouteLandmarkAnalyzer.distance(query.data, reference.data)))
          }
          response["distances"] = distances
        }
        response["status"] = job.isCancelled ? "cancelled" : "ok"
      } catch { response["status"] = job.isCancelled ? "cancelled" : "invalid" }
      let output = response
      DispatchQueue.main.async {
        if self.active === job { self.active = nil }
        result(output)
      }
    }
  }
}

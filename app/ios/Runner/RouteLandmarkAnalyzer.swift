import Foundation
import Vision
import ImageIO

struct RouteOCRProfile {
  let revision: Int
  let languages: [String]
  let manualFloorConfirmationRequired = true
  static func current() throws -> RouteOCRProfile {
    let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
    if #available(iOS 16.0, *) { request.revision = VNRecognizeTextRequestRevision3 }
    else { request.revision = VNRecognizeTextRequestRevision2 }
    let supported = try request.supportedRecognitionLanguages()
    return RouteOCRProfile(revision: request.revision, languages: ["zh-Hant", "en-US"].filter { supported.contains($0) })
  }
}
struct RouteLandmarkAnalysis {
  let feature: Data
  let text: [String]
  let ocr: RouteOCRProfile
}
enum RouteLandmarkError: Error { case invalid, incompatible, cancelled }
/// No camera, file persistence, network, AR or automatic floor assignment.
struct RouteLandmarkAnalyzer {
  static let featureRevision = "vision-featureprint-v1"
  static let preprocessRevision = "upright-jpeg-v1"
  static func analyze(jpeg: Data, width: Int, height: Int,
    cancelled: () -> Bool = { false }, publish: (VNRequest) -> Void = { _ in }) throws -> RouteLandmarkAnalysis {
    guard !cancelled() else { throw RouteLandmarkError.cancelled }
    guard jpeg.count <= 524288, jpeg.count >= 4, jpeg.prefix(2) == Data([255,216]),
      width > 0, height > 0, max(width,height) <= 1280,
      let source = CGImageSourceCreateWithData(jpeg as CFData,nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
      (properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1,
      properties[kCGImagePropertyPixelWidth] as? Int == width,
      properties[kCGImagePropertyPixelHeight] as? Int == height,
      let image = CGImageSourceCreateImageAtIndex(source,0,nil), image.width == width, image.height == height else { throw RouteLandmarkError.invalid }
    let request = VNGenerateImageFeaturePrintRequest()
    guard VNGenerateImageFeaturePrintRequest.supportedRevisions.contains(VNGenerateImageFeaturePrintRequestRevision1) else { throw RouteLandmarkError.incompatible }
    request.revision = VNGenerateImageFeaturePrintRequestRevision1
    request.imageCropAndScaleOption = .scaleFit
    #if targetEnvironment(simulator)
    request.usesCPUOnly = true
    #endif
    publish(request)
    guard !cancelled() else { request.cancel(); throw RouteLandmarkError.cancelled }
    try VNImageRequestHandler(cgImage:image,orientation:.up,options:[:]).perform([request])
    guard let print = request.results?.first else { throw RouteLandmarkError.invalid }
    let archive = try NSKeyedArchiver.archivedData(withRootObject:print,requiringSecureCoding:true)
    let bytes = try JSONSerialization.data(withJSONObject: ["schema":1,
      "featureRevision":featureRevision,"preprocessRevision":preprocessRevision,
      "visionRevision":VNGenerateImageFeaturePrintRequestRevision1,"archive":archive.base64EncodedString()], options:[.sortedKeys])
    guard bytes.count <= 65536 else { throw RouteLandmarkError.invalid }
    guard !cancelled() else { throw RouteLandmarkError.cancelled }
    let profile = (try? RouteOCRProfile.current()) ?? RouteOCRProfile(revision: 2, languages: [])
    var text: [String] = []
    if !profile.languages.isEmpty {
      let ocr = VNRecognizeTextRequest(); ocr.revision = profile.revision
      ocr.recognitionLevel = .accurate; ocr.recognitionLanguages = profile.languages
      ocr.usesLanguageCorrection = false
      #if targetEnvironment(simulator)
      ocr.usesCPUOnly = true
      #endif
      publish(ocr)
      guard !cancelled() else { ocr.cancel(); throw RouteLandmarkError.cancelled }
      // OCR failure retains the visual feature and explicit manual fallback.
      if (try? VNImageRequestHandler(cgImage:image,orientation:.up,options:[:]).perform([ocr])) != nil {
        text = (ocr.results ?? []).prefix(32).compactMap { $0.topCandidates(1).first }.map { String($0.string.prefix(120)) }
      }
    }
    guard !cancelled() else { throw RouteLandmarkError.cancelled }
    return RouteLandmarkAnalysis(feature:bytes,text:text,ocr:profile)
  }
  static func distance(_ first: Data,_ second: Data,
    feature: String = featureRevision, preprocess: String = preprocessRevision) throws -> Float {
    guard feature == featureRevision, preprocess == preprocessRevision else { throw RouteLandmarkError.incompatible }
    func decode(_ bytes: Data) throws -> VNFeaturePrintObservation {
      guard !bytes.isEmpty, bytes.count <= 65536,
        let envelope = try JSONSerialization.jsonObject(with:bytes) as? [String:Any],
        envelope["schema"] as? Int == 1,
        envelope["featureRevision"] as? String == featureRevision,
        envelope["preprocessRevision"] as? String == preprocessRevision,
        envelope["visionRevision"] as? Int == VNGenerateImageFeaturePrintRequestRevision1,
        let encoded = envelope["archive"] as? String, let archive = Data(base64Encoded:encoded),
        let value = try NSKeyedUnarchiver.unarchivedObject(ofClass:VNFeaturePrintObservation.self,from:archive),
        value.requestRevision == VNGenerateImageFeaturePrintRequestRevision1 else { throw RouteLandmarkError.incompatible }
      return value
    }
    let a = try decode(first), b = try decode(second)
    var distance: Float = 0; try a.computeDistance(&distance,to:b)
    guard distance.isFinite, distance >= 0 else { throw RouteLandmarkError.invalid }
    return distance
  }
}

import CoreGraphics
import Foundation
import Vision

/// Shared by iOS and the macOS regression probe. No images or audio are persisted.
struct MenuOCRLine {
  let text: String
  let box: CGRect // normalised, top-left origin
  let confidence: Float
  var map: [String: Any] {
    ["text": text, "left": box.minX, "top": box.minY,
     "width": box.width, "height": box.height, "confidence": Double(confidence)]
  }
}

struct MenuOCR {
  static let version = "2026-10-23.price-crops.1"
  static func recognize(_ image: CGImage, cancelled: () -> Bool,
                        publish: (VNRecognizeTextRequest) -> Void) throws -> [MenuOCRLine] {
    // Horizontal overlapping regions retain full dish-to-price rows. Splitting
    // vertically at assumed column boundaries can cut dishes in half.
    let regions = [CGRect(x: 0, y: 0, width: 1, height: 1),
                   CGRect(x: 0, y: 0, width: 1, height: 0.55),
                   CGRect(x: 0, y: 0.45, width: 1, height: 0.55)]
    var lines: [MenuOCRLine] = []
    for region in regions {
      if cancelled() { throw CancellationError() }
      let pixels = CGRect(x: region.minX * CGFloat(image.width), y: region.minY * CGFloat(image.height),
                          width: region.width * CGFloat(image.width), height: region.height * CGFloat(image.height)).integral
      guard let crop = image.cropping(to: pixels) else { continue }
      // Upscaling helps text detection; it cannot restore missing source detail.
      let scale = min(2, 2400 / CGFloat(max(crop.width, crop.height)))
      let width = max(1, Int(CGFloat(crop.width) * scale))
      let height = max(1, Int(CGFloat(crop.height) * scale))
      guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
          bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
      context.interpolationQuality = .high
      context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
      guard let prepared = context.makeImage() else { continue }
      let request = VNRecognizeTextRequest()
      request.recognitionLevel = .accurate
      if #available(iOS 16.0, macOS 13.0, *) {
        request.revision = VNRecognizeTextRequestRevision3
      } else { throw NSError(domain: "MenuOCRVersion", code: 1) }
      let supported = try request.supportedRecognitionLanguages()
      guard supported.contains("zh-Hant") else { throw NSError(domain: "MenuOCRLanguage", code: 1) }
      request.recognitionLanguages = ["zh-Hant", "en-US"].filter { supported.contains($0) }
      request.usesLanguageCorrection = true
      request.minimumTextHeight = 0.006
      publish(request)
      if cancelled() { request.cancel(); throw CancellationError() }
      try VNImageRequestHandler(cgImage: prepared, options: [:]).perform([request])
      for observation in request.results ?? [] {
        guard let candidate = observation.topCandidates(1).first else { continue }
        let b = observation.boundingBox
        // Map actual integral crop bounds back to page coordinates.
        let box = CGRect(x: (pixels.minX + b.minX * pixels.width) / CGFloat(image.width),
          y: (pixels.minY + (1 - b.maxY) * pixels.height) / CGFloat(image.height),
          width: b.width * pixels.width / CGFloat(image.width), height: b.height * pixels.height / CGFloat(image.height))
        // Do not use cut-off lines touching an internal crop edge.
        if (region.minY > 0 && 1 - b.maxY < 0.015) || (region.maxY < 1 && 1 - b.minY > 0.985) { continue }
        let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { continue }
        let next = MenuOCRLine(text: String(text.prefix(1000)), box: box, confidence: candidate.confidence)
        if let index = lines.firstIndex(where: { overlaps($0.box, box) }) {
          let old = lines[index]
          if old.text == "價錢辨識有分歧，請重拍" { continue }
          if compact(old.text) == compact(text) {
            if next.confidence > old.confidence { lines[index] = next }
          } else {
            // Disagreement is visible and is never offered as a confirmed price.
            // Keep a visible conflict marker at low confidence.
            let oldMoney = explicitMoney(old.text), newMoney = explicitMoney(text)
            if oldMoney != nil && newMoney != nil && oldMoney != newMoney {
              lines[index] = MenuOCRLine(text: "價錢辨識有分歧，請重拍", box: old.box, confidence: 0)
            } else if oldMoney == nil && newMoney != nil {
              lines[index] = next
            } else if oldMoney == nil && newMoney == nil && next.confidence > old.confidence {
              lines[index] = next
            }
          }
        } else { lines.append(next) }
      }
    }
    // Price circles and small coloured numerals need a separate contextual pass.
    // Keep their label and add a white border; isolated numerals can be rotated
    // or misread by OCR. Never manufacture a currency symbol from a bare number.
    var regionsToRead: [CGRect] = []
    let anchors = lines.sorted { priority($0.text) > priority($1.text) }
    for line in anchors {
      let option = priority(line.text) == 2
      let numeric = line.text.range(of: #"^(?:HK\s*)?[$＄﹩]?[0-9０-９]+(?:[.,．][0-9０-９]+)?$"#, options: .regularExpression) != nil
      let dish = line.text.count < 32 && line.text.range(of: "飯|麵|米線|三文治|多士|脆豬|扒") != nil
      guard option || numeric || dish else { continue }
      if !option && lines.contains(where: { explicitMoney($0.text) != nil &&
        abs($0.box.midY - line.box.midY) < max($0.box.height, line.box.height) * 0.65 &&
        $0.box.minX >= line.box.maxX - 0.02 }) { continue }
      let left = option ? max(0, line.box.minX - 0.08) : max(0, min(0.68, line.box.maxX - 0.10))
      let height = max(0.065, line.box.height * 2.4)
      let region = CGRect(x: left, y: max(0, line.box.midY - height / 2),
        width: 1 - left, height: min(height, 1 - max(0, line.box.midY - height / 2)))
      if regionsToRead.contains(where: { abs($0.midY - region.midY) < 0.018 && abs($0.minX - region.minX) < 0.12 }) { continue }
      regionsToRead.append(region)
      if regionsToRead.count >= 18 { break }
    }
    for region in regionsToRead {
      if cancelled() { throw CancellationError() }
      let pixels = CGRect(x: region.minX * CGFloat(image.width), y: region.minY * CGFloat(image.height),
        width: region.width * CGFloat(image.width), height: region.height * CGFloat(image.height)).integral
        .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
      guard let crop = image.cropping(to: pixels) else { continue }
      let scale = min(4, 1600 / CGFloat(max(crop.width, crop.height)))
      let w = max(1, Int(CGFloat(crop.width) * scale)), h = max(1, Int(CGFloat(crop.height) * scale))
      let padding = 20
      guard let context = CGContext(data: nil, width: w + padding * 2, height: h + padding * 2,
        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { continue }
      context.setFillColor(gray: 1, alpha: 1)
      context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
      context.interpolationQuality = .high
      context.draw(crop, in: CGRect(x: padding, y: padding, width: w, height: h))
      guard let prepared = context.makeImage() else { continue }
      let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
      if #available(iOS 16.0, macOS 13.0, *) { request.revision = VNRecognizeTextRequestRevision3 }
      request.recognitionLanguages = ["zh-Hant", "en-US"]
      request.usesLanguageCorrection = false; request.minimumTextHeight = 0.01
      publish(request)
      if cancelled() { request.cancel(); throw CancellationError() }
      try VNImageRequestHandler(cgImage: prepared, options: [:]).perform([request])
      for observation in request.results ?? [] {
        guard let candidate = observation.topCandidates(1).first else { continue }
        let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only accept explicit prices or fragments which can later join an
        // actually detected currency symbol. Ignore spurious crop dish text.
        guard explicitMoney(text) != nil || text.range(of: #"^(?:[$＄﹩]|[0-9０-９]{1,4}(?:[.,．][0-9０-９]{1,2})?)$"#, options: .regularExpression) != nil else { continue }
        let b = observation.boundingBox
        let x = (b.minX * CGFloat(context.width) - CGFloat(padding)) / CGFloat(w)
        let y = ((1 - b.maxY) * CGFloat(context.height) - CGFloat(padding)) / CGFloat(h)
        guard x >= 0, y >= 0 else { continue }
        let box = CGRect(x: (pixels.minX + x * pixels.width) / CGFloat(image.width),
          y: (pixels.minY + y * pixels.height) / CGFloat(image.height),
          width: b.width * CGFloat(context.width) / CGFloat(w) * pixels.width / CGFloat(image.width),
          height: b.height * CGFloat(context.height) / CGFloat(h) * pixels.height / CGFloat(image.height))
        let next = MenuOCRLine(text: text, box: box, confidence: candidate.confidence)
        if let index = lines.firstIndex(where: { overlaps($0.box, box) }) {
          let old = lines[index]
          if old.text == "價錢辨識有分歧，請重拍" { continue }
          if let price = explicitMoney(text) {
            if let oldPrice = explicitMoney(old.text), oldPrice != price {
              lines[index] = MenuOCRLine(text: "價錢辨識有分歧，請重拍", box: box, confidence: 0)
            } else { lines[index] = next }
          }
        } else { lines.append(next) }
      }
    }
    return lines
  }
  private static func priority(_ text: String) -> Int {
    compact(text).range(of: "^(單拼|雙拼|三拼)", options: .regularExpression) != nil ? 2 : 1
  }
  private static func compact(_ text: String) -> String {
    text.replacingOccurrences(of: "＄", with: "$").filter { !$0.isWhitespace }
  }
  private static func explicitMoney(_ text: String) -> String? {
    let value = compact(text)
    return value.range(of: #"^(?:HK\$|\$)\d+(?:\.\d{1,2})?$"#, options: .regularExpression) != nil ? value : nil
  }
  private static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
    let intersection = a.intersection(b)
    guard !intersection.isNull else { return false }
    let union = a.width * a.height + b.width * b.height - intersection.width * intersection.height
    return intersection.width * intersection.height / max(union, 0.000001) > 0.55
  }
}

// macOS-only probe using the same OCR implementation as the iOS app.
// swiftc ios/Runner/MenuOCR.swift tool/menu_ocr_probe.swift -o /tmp/menu-ocr-probe
// /tmp/menu-ocr-probe output-directory menu-image [...]
import Foundation
import ImageIO

@main
struct MenuOCRProbe {
  static func main() throws {
    let args = Array(CommandLine.arguments.dropFirst())
    guard args.count >= 2 else { print("Expected output directory and images"); return }
    let output = URL(fileURLWithPath: args[0])
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    for (index, path) in args.dropFirst().enumerated() {
      guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
      let started = Date()
      let lines = try MenuOCR.recognize(image, cancelled: { false }, publish: { _ in })
      let maps = lines.map { line -> [String: Any] in var m = line.map; m["page"] = 1; return m }
      let result: [String: Any] = ["ocrVersion": MenuOCR.version, "lines": maps, "pages": 1, "truncated": false,
        "sourceWidth": image.width, "sourceHeight": image.height,
        "host": "macOS Vision; not iPhone acceptance", "seconds": Date().timeIntervalSince(started)]
      try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        .write(to: output.appendingPathComponent("menu-\(index + 1).json"))
      print("Image \(index+1): \(lines.count) observations")
    }
  }
}

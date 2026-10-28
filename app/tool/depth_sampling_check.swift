import Foundation

@main struct CheckDepthSampling {
  static func main() {
    var checks = 0
    func check(_ ok: Bool, _ name: String) {
      precondition(ok, name)
      checks += 1
    }
    func pixel(_ z: Double, _ c: UInt8 = 2, _ x: Double = 0) -> DepthPixel {
      DepthPixel(z: z, confidence: c, rayX: x, rayY: 0)
    }
    let wall = Array(repeating: pixel(2), count: 25)
    let result = DepthSampling.evaluate(wall)!
    check(result.z == 2 && result.range == 2 && result.accepted == 25, "uniform central wall")
    let oblique = DepthSampling.evaluate(Array(repeating: pixel(2, 2, 0.75), count: 25))!
    check(abs(oblique.range - 2.5) < 1e-9 && oblique.z == 2, "unprojection separates radial range and Z")
    check(DepthSampling.evaluate(Array(repeating: pixel(2, 1), count: 25)) == nil, "low confidence rejected")
    check(DepthSampling.evaluate(Array(wall.prefix(17)) + Array(repeating: pixel(.nan), count: 8)) == nil, "coverage below70%")
    check(DepthSampling.evaluate(Array(wall.prefix(18)) + Array(repeating: pixel(.nan), count: 7)) != nil, "coverage above70%")
    check(DepthSampling.evaluate(Array(wall.prefix(20)) + Array(repeating: pixel(3), count: 5))?.range == 2, "minority background rejected")
    check(DepthSampling.evaluate(Array(wall.prefix(19)) + Array(repeating: pixel(3), count: 6)) == nil, "mixed surface rejected")
    check(DepthSampling.evaluate(Array(repeating: pixel(0.1), count: 25)) == nil, "near range gate")
    check(DepthSampling.evaluate(Array(repeating: pixel(4.1), count: 25)) == nil, "far range gate")
    check(DepthSampling.evaluate(Array(repeating: pixel(4, 2, 0.5), count: 25)) == nil, "radial exceeds supported range")
    check(DepthSampling.evaluate(Array(wall.prefix(24))) == nil, "patch too small")
    check(DepthSampling.evaluate(Array(repeating: pixel(.infinity), count: 25)) == nil, "infinite depth rejected")
    let p90 = CameraImageMath.rawPoint(x: 0.2, y: 0.7, rotation: 90)
    check(abs(p90.0 - 0.7) < 1e-9 && abs(p90.1 - 0.8) < 1e-9, "portrait box maps back to raw depth")
    let p270 = CameraImageMath.rawPoint(x: 0.2, y: 0.7, rotation: 270)
    check(abs(p270.0 - 0.3) < 1e-9 && abs(p270.1 - 0.2) < 1e-9, "upside-down portrait raw mapping")
    let p180 = CameraImageMath.rawPoint(x: 0.2, y: 0.7, rotation: 180)
    check(abs(p180.0 - 0.8) < 1e-9 && abs(p180.1 - 0.3) < 1e-9, "landscape rotation mapping")
    let p0 = CameraImageMath.rawPoint(x: 0.2, y: 0.7, rotation: 0)
    check(p0.0 == 0.2 && p0.1 == 0.7, "native landscape raw mapping")
    let grid = CameraImageMath.grid(box: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.5), width: 256, height: 192)!
    check(grid.count == 25 && Set(grid.map { "\($0.0),\($0.1)" }).count == 25, "twenty-five distinct depth pixels")
    check(grid.allSatisfy { $0.0 >= 44 && $0.0 <= 84 && $0.1 >= 62 && $0.1 <= 110 }, "samples inside central half of box")
    check(CameraImageMath.grid(box: CGRect(x: 0.1, y: 0.2, width: 0.01, height: 0.5), width: 256, height: 192) == nil, "thin box cannot inflate sample count")
    check(CameraImageMath.grid(box: CGRect(x: -0.1, y: 0.2, width: 0.3, height: 0.5), width: 256, height: 192) == nil, "out-of-frame box rejected")
    let fullBlack = CameraImageMath.rgb(y: 0, cb: 128, cr: 128, fullRange: true, bt709: true)
    let fullWhite = CameraImageMath.rgb(y: 255, cb: 128, cr: 128, fullRange: true, bt709: true)
    check(fullBlack.0 == 0 && fullWhite.0 == 1, "ARKit full-range black and white")
    let videoBlack = CameraImageMath.rgb(y: 16, cb: 128, cr: 128, fullRange: false, bt709: false)
    let videoWhite = CameraImageMath.rgb(y: 235, cb: 128, cr: 128, fullRange: false, bt709: false)
    check(videoBlack.0 == 0 && videoWhite.0 == 1, "AVCapture video-range black and white")
    let grey = CameraImageMath.rgb(y: 128, cb: 128, cr: 128, fullRange: true, bt709: true)
    check(abs(Double(grey.0) - 128.0 / 255) < 1e-6 && grey.0 == grey.1 && grey.1 == grey.2, "neutral full-range grey")
    let red601 = CameraImageMath.rgb(y: 76.245, cb: 84.972, cr: 255.5, fullRange: true, bt709: false)
    check(red601.0 > 0.99 && red601.1 < 0.01 && red601.2 < 0.01, "BT601 red conversion")
    let red709 = CameraImageMath.rgb(y: 54.213, cb: 98.784, cr: 255.5, fullRange: true, bt709: true)
    check(red709.0 > 0.99 && red709.1 < 0.01 && red709.2 < 0.01, "BT709 red conversion")
    let bodyBox = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
    let local = CameraImageMath.localPatches(box: bodyBox, occluders: [], width: 200, height: 200)
    check(local.count == 9 && local[0].count == 25, "centre-first bounded local candidates")
    check(local[0].map { $0.0 }.max()! - local[0].map { $0.0 }.min()! == 4 &&
      Set(local[0].map { "\($0.0),\($0.1)" }).count == 25, "adjacent distinct pixels, not broad sparse grid")
    func curved(_ grid: [(Int, Int)]) -> [DepthPixel] { grid.map { _, row in pixel(1.2 + Double(row) / 200) } }
    let broad = CameraImageMath.grid(box: bodyBox, width: 200, height: 200)!
    check(DepthSampling.evaluate(curved(broad)) == nil && DepthSampling.evaluate(curved(local[0])) != nil,
      "curved person surface uses unchanged confidence gates on local patch")
    let masked = CameraImageMath.localPatches(box: bodyBox,
      occluders: [CGRect(x: 0.48,y:0.48,width:0.05,height:0.05)], width: 200, height: 200)
    check(!masked.isEmpty && masked[0][12].1 < 90, "central occlusion uses unoccluded nearby patch")
    check(CameraImageMath.localPatches(box: bodyBox, occluders: [bodyBox], width: 200, height: 200).isEmpty,
      "fully occluded object never borrows another object depth")
    check(CameraImageMath.localPatches(box: CGRect(x:0.1,y:0.1,width:0.01,height:0.5),
      occluders: [], width:200,height:200).isEmpty, "small object cannot fit full local patch")
    let low = DepthSampling.inspect(Array(repeating: pixel(2,1),count:25))
    check(low.reason == "low_depth" && low.valid == 0 && low.patch == nil, "low confidence diagnosis")
    let mixed = DepthSampling.inspect(Array(wall.prefix(19)) + Array(repeating:pixel(3),count:6))
    check(mixed.reason == "mixed_depth" && mixed.valid == 25 && mixed.patch == nil, "mixed surface diagnosis")
    print("DepthSampling: \(checks) deterministic checks passed; no device accuracy claim")
  }
}

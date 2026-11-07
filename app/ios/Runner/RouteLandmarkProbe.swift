import Foundation

import UIKit
import CryptoKit

/// Explicit engineering launch flag; generated fixture only, never user media.
enum RouteLandmarkProbe {
  static func fixtureJPEG() -> Data {
    let format = UIGraphicsImageRendererFormat(); format.scale = 1
    return UIGraphicsImageRenderer(size: CGSize(width:320,height:240),format:format).jpegData(withCompressionQuality:0.9) { context in
      UIColor.white.setFill(); context.fill(CGRect(x:0,y:0,width:320,height:240))
      UIColor.blue.setFill(); context.fill(CGRect(x:0,y:130,width:140,height:110))
      ("3F ROOM 301" as NSString).draw(at:CGPoint(x:12,y:40),withAttributes:[.font:UIFont.systemFont(ofSize:36),.foregroundColor:UIColor.black])
    }
  }
  static func runIfRequested() {
    guard ProcessInfo.processInfo.arguments.contains("--route-landmark-probe") else { return }
    let jpeg=fixtureJPEG()
    DispatchQueue.global(qos:.userInitiated).async {
      var report:[String:Any] = ["fixtureOnly":true,"passed":false]
      do {
        let value=try RouteLandmarkAnalyzer.analyze(jpeg:jpeg,width:320,height:240)
        let distance=try RouteLandmarkAnalyzer.distance(value.feature,value.feature)
        report["featureBytes"]=value.feature.count
        report["featureSha256"]=SHA256.hash(data:value.feature).map { String(format:"%02x",$0) }.joined()
        report["selfDistance"]=Double(distance); report["ocrRevision"]=value.ocr.revision
        report["ocrLanguages"]=value.ocr.languages
        report["manualFloorConfirmationRequired"]=value.ocr.manualFloorConfirmationRequired
        report["passed"]=distance.isFinite && distance < 0.001 && !value.feature.isEmpty
      } catch { report["problem"]="native_analysis_failed"; report["errorDomain"]=(error as NSError).domain; report["errorCode"]=(error as NSError).code }
      do {
        let base=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
        try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true)
        var url=base.appendingPathComponent("route-landmark-probe-result.json")
        try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]).write(to:url,options:[.atomic,.completeFileProtection])
        var flags=URLResourceValues(); flags.isExcludedFromBackup=true; try url.setResourceValues(flags)
      } catch { /* No private payload or error is logged. Device harness requires the report. */ }
    }
  }
}

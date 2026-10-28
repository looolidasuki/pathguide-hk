import AVFoundation
import Flutter
import PhotosUI
import Speech
import UIKit
import Vision
import VisionKit

/// Menu photos and OCR results stay in memory and never enter the training queue.
final class MenuPlugin: NSObject, FlutterPlugin, VNDocumentCameraViewControllerDelegate, PHPickerViewControllerDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
  private let channel: FlutterMethodChannel
  private var pending: FlutterResult?
  private var requestId = ""
  private weak var picker: UIViewController?
  private let work = DispatchQueue(label: "hk.pathguide.menu.ocr", qos: .userInitiated)
  private var textRequest: VNRecognizeTextRequest?
  private var recognizer: SFSpeechRecognizer?
  private var speechTask: SFSpeechRecognitionTask?
  private var speechRequest: SFSpeechAudioBufferRecognitionRequest?
  private let engine = AVAudioEngine()
  private var tapped = false
  private var recording = false
  private var partial = ""
  private var isSpeechRequest = false
  private var finishing = false
  private var startedAt = 0.0
  private var lastVoiceAt = 0.0
  private var voicedDuration = 0.0
  private var heardVoice = false
  private var timedOut = false
  private var speechTimer: Timer?


  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "hk.pathguide/menu", binaryMessenger: messenger)
    super.init()
    NotificationCenter.default.addObserver(self, selector: #selector(enteredBackground),
      name: UIApplication.didEnterBackgroundNotification, object: nil)
    channel.setMethodCallHandler { [weak self] call, result in self?.handle(call, result: result) }
  }
  deinit { NotificationCenter.default.removeObserver(self) }
  @objc private func enteredBackground() {
    if pending != nil { cancel() }
  }
  static func register(with registrar: FlutterPluginRegistrar) {
    let plugin = MenuPlugin(messenger: registrar.messenger())
    registrar.addMethodCallDelegate(plugin, channel: plugin.channel)
  }
  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "cancelMenu" { cancel(); result(nil); return }
    if call.method == "finishMenuSpeech" { finishSpeech(); result(nil); return }
    guard ["readMenu", "listenMenuQuery"].contains(call.method) else { result(FlutterMethodNotImplemented); return }
    guard pending == nil else { result(FlutterError(code: "busy", message: "請先完成或取消目前操作。", details: nil)); return }
    guard let args = call.arguments as? [String: Any], let id = args["requestId"] as? String else {
      result(FlutterError(code: "bad_args", message: "缺少請求識別碼。", details: nil)); return
    }
    pending = result; requestId = id
    isSpeechRequest = call.method == "listenMenuQuery"
    if isSpeechRequest { authorizeSpeech(id: id, allowNetwork: args["allowNetwork"] as? Bool == true); return }
    guard #available(iOS 16.0, *) else { fail("unsupported", "繁體中文菜單辨識需要 iOS 16 或以上。"); return }
    if args["source"] as? String == "library" { openLibrary() }
    else { openCamera(id: id, scanner: args["source"] as? String == "scanner") }
  }
  private func presenter() -> UIViewController? {
    guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }),
      var root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else { return nil }
    while let presented = root.presentedViewController { root = presented }
    return root
  }
  private func complete(_ value: Any?) {
    let callback = pending; pending = nil; requestId = ""; textRequest = nil
    cleanupSpeech(); isSpeechRequest = false; callback?(value)
  }
  private func fail(_ code: String, _ message: String) { complete(FlutterError(code: code, message: message, details: nil)) }
  private func cancel() {
    textRequest?.cancel()
    picker?.dismiss(animated: true); picker = nil
    complete(isSpeechRequest ? ["outcome": "cancelled", "text": ""] : nil)
  }
  private func openCamera(id: String, scanner: Bool = false) {
    func permitted() {
      // The permission sheet may be dismissing when its completion runs.
      presentCamera(id: id, scanner: scanner, attempt: 0)
    }
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized: permitted()
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
        DispatchQueue.main.async {
          guard let self, self.requestId == id, self.pending != nil else { return }
          if granted { self.presentCamera(id: id, scanner: scanner, attempt: 0) }
          else { self.fail("camera_denied", "未獲相機權限。請到 iPhone 設定的領路通開啟相機，或選取照片。") }
        }
      }
    case .restricted: fail("camera_restricted", "相機受系統限制，可檢查螢幕使用時間或改為選取照片。")
    default: fail("camera_denied", "未獲相機權限。請到 iPhone 設定的領路通開啟相機，或選取照片。")
    }
  }
  private func presentCamera(id: String, scanner: Bool, attempt: Int) {
    DepthPlugin.active?.stop()
    guard requestId == id, pending != nil else { return }
    guard let host = presenter(), host.viewIfLoaded?.window != nil,
          !host.isBeingDismissed, !host.isBeingPresented else {
      if attempt < 10 {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
          self?.presentCamera(id: id, scanner: scanner, attempt: attempt + 1)
        }
      } else { fail("no_presenter", "相機未能開啟，請再試或選取菜單照片。") }
      return
    }
    if scanner && VNDocumentCameraViewController.isSupported {
      let vc = VNDocumentCameraViewController(); vc.delegate = self
      vc.modalPresentationStyle = .fullScreen; picker = vc
      host.present(vc, animated: true)
    } else {
      guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
        fail("camera_unavailable", "此裝置無可用相機，可選取菜單照片。"); return
      }
      let vc = UIImagePickerController()
      vc.sourceType = .camera; vc.cameraDevice = .rear
      vc.cameraCaptureMode = .photo; vc.allowsEditing = false
      vc.delegate = self; vc.modalPresentationStyle = .fullScreen; picker = vc
      host.present(vc, animated: true)
    }
  }
  func imagePickerControllerDidCancel(_ controller: UIImagePickerController) {
    controller.dismiss(animated: true); picker = nil; complete(nil)
  }
  func imagePickerController(_ controller: UIImagePickerController,
      didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
    let id = requestId
    guard let image = info[.originalImage] as? UIImage else {
      controller.dismiss(animated: true); picker = nil
      fail("capture_failed", "未能取得照片，請重拍或選取照片。"); return
    }
    controller.dismiss(animated: true) { [weak self] in
      guard let self, self.requestId == id, self.pending != nil else { return }
      self.picker = nil; self.recognize([image], truncated: false)
    }
  }
  private func openLibrary() {
    guard let host = presenter() else { fail("no_presenter", "未能開啟照片選取，請重試。"); return }
    var config = PHPickerConfiguration(); config.filter = .images; config.selectionLimit = 1
    let vc = PHPickerViewController(configuration: config); vc.delegate = self; picker = vc
    host.present(vc, animated: true)
  }
  func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
    controller.dismiss(animated: true); picker = nil; complete(nil)
  }
  func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError _: Error) {
    let id = requestId
    controller.dismiss(animated: true) { [weak self] in
      guard let self, self.requestId == id, self.pending != nil else { return }
      self.picker = nil; self.presentCamera(id: id, scanner: false, attempt: 0)
    }
  }
  func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
    let images = (0..<min(scan.pageCount, 3)).map { scan.imageOfPage(at: $0) }
    controller.dismiss(animated: true); picker = nil
    recognize(images, truncated: scan.pageCount > 3)
  }
  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true); self.picker = nil
    guard let item = results.first else { complete(nil); return }
    let id = requestId
    guard item.itemProvider.canLoadObject(ofClass: UIImage.self) else { fail("image_failed", "未能讀取這張照片，請選另一張。"); return }
    item.itemProvider.loadObject(ofClass: UIImage.self) { [weak self] value, _ in
      DispatchQueue.main.async {
        guard let self, self.requestId == id, self.pending != nil else { return }
        guard let image = value as? UIImage else { self.fail("image_failed", "照片未能載入，若在 iCloud 可先下載再試。"); return }
        self.recognize([image], truncated: false)
      }
    }
  }
  private func recognize(_ images: [UIImage], truncated: Bool) {
    let id = requestId
    channel.invokeMethod("recognizing", arguments: ["requestId": id])
    work.async { [weak self] in
      guard let self else { return }
      do {
        var all: [[String: Any]] = []; var limited = truncated
        for (index, image) in images.enumerated() {
          // Draw UIImage to honour EXIF orientation without saving any temporary file.
          let pixelWidth = image.size.width * image.scale
          let pixelHeight = image.size.height * image.scale
          let factor = min(1, 2400 / max(pixelWidth, pixelHeight))
          let size = CGSize(width: max(1, pixelWidth * factor), height: max(1, pixelHeight * factor))
          let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
          let upright = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
          guard let cg = upright.cgImage else { throw NSError(domain: "MenuOCR", code: 1) }
          let results = try MenuOCR.recognize(cg, cancelled: {
            var stale = false
            DispatchQueue.main.sync { stale = self.requestId != id || self.pending == nil }
            return stale
          }, publish: { request in
            DispatchQueue.main.sync {
              if self.requestId == id && self.pending != nil { self.textRequest = request }
              else { request.cancel() }
            }
          })
          if results.count > 300 { limited = true }
          for line in results.prefix(300) {
            var value = line.map; value["page"] = index + 1; all.append(value)
          }
        }
        let output: [String: Any] = ["ocrVersion": MenuOCR.version, "lines": all, "pages": images.count, "truncated": limited,
          "warnings": images.contains(where: { min($0.size.width * $0.scale, $0.size.height * $0.scale) < 700 })
            ? ["圖片解像度偏低，密集細字及價錢可能讀錯；建議近距離分區重拍。"] : []]
        DispatchQueue.main.async { if self.requestId == id { self.complete(output) } }
      } catch {
        DispatchQueue.main.async { if self.requestId == id { self.fail("ocr_failed", "未能辨識照片，請保持文字清晰、減少反光後重拍。") } }
      }
    }
  }

  private func authorizeSpeech(id: String, allowNetwork: Bool) {
    guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-HK")), recognizer.isAvailable else {
      fail("speech_unavailable", "粵語語音辨識暫時不可用，可用文字搜尋。"); return
    }
    if !allowNetwork && !recognizer.supportsOnDeviceRecognition {
      fail("offline_speech_unavailable", "此裝置未提供離線粵語辨識。可選 Apple 線上語音服務，或用文字搜尋。"); return
    }
    SFSpeechRecognizer.requestAuthorization { [weak self] status in
      DispatchQueue.main.async {
        guard let self, self.requestId == id else { return }
        guard status == .authorized else { self.fail("speech_denied", "未獲語音辨識權限，可在設定開啟或改用文字搜尋。"); return }
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
          DispatchQueue.main.async {
            guard self.requestId == id else { return }
            guard granted else { self.fail("microphone_denied", "未獲咪高峰權限，可在設定開啟或改用文字搜尋。"); return }
            self.startSpeech(recognizer, id: id, allowNetwork: allowNetwork)
          }
        }
      }
    }
  }
  private func speechPhase(_ phase: String) {
    channel.invokeMethod("speechPhase", arguments: ["requestId": requestId, "phase": phase])
  }
  private func speechComplete() {
    let outcome = partial.isEmpty ? (timedOut ? "timeout" : "noSpeech") : "finalText"
    complete(["outcome": outcome, "text": partial])
  }
  private func startSpeech(_ recognizer: SFSpeechRecognizer, id: String, allowNetwork: Bool) {
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker])
      try session.setActive(true)
      self.recognizer = recognizer
      let request = SFSpeechAudioBufferRecognitionRequest()
      request.shouldReportPartialResults = true
      request.requiresOnDeviceRecognition = !allowNetwork
      request.taskHint = .search
      request.contextualStrings = ["我想食", "我想飲", "我想去", "帶我去"]
      speechRequest = request; partial = ""; recording = true; finishing = false
      heardVoice = false; voicedDuration = 0; timedOut = false
      let node = engine.inputNode; let format = node.outputFormat(forBus: 0)
      guard format.channelCount > 0, format.sampleRate > 0 else { throw NSError(domain: "MenuMic", code: 1) }
      speechTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
        DispatchQueue.main.async {
          guard let self, self.requestId == id else { return }
          if let result {
            let next = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
            // Empty final updates must never discard a usable partial transcript.
            if !next.isEmpty {
              self.partial = next
              self.channel.invokeMethod("speechPartial", arguments: ["requestId": id, "text": next])
            }
            if result.isFinal { self.speechComplete(); return }
          }
          if error != nil {
            if !self.partial.isEmpty || self.finishing { self.speechComplete() }
            else { self.fail("speech_failed", "未聽清楚，請重試或輸入搜尋文字。") }
          }
        }
      }
      node.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
        request.append(buffer)
        // Measure actual audio rather than gaps between transcription callbacks.
        // A short run above -42 dBFS filters single clicks; device/noise calibration
        // remains part of phone acceptance. No audio is saved.
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        var energy: Float = 0
        for index in 0..<Int(buffer.frameLength) { energy += samples[index] * samples[index] }
        let level = 10 * log10(max(energy / Float(buffer.frameLength), 1e-12))
        let duration = Double(buffer.frameLength) / buffer.format.sampleRate
        let timestamp = ProcessInfo.processInfo.systemUptime
        DispatchQueue.main.async {
          guard let self, self.requestId == id, !self.finishing else { return }
          if level > -42 {
            self.voicedDuration += duration
            self.lastVoiceAt = timestamp
            if self.voicedDuration >= 0.18 { self.heardVoice = true }
          } else if !self.heardVoice { self.voicedDuration = 0 }
        }
      }
      tapped = true; engine.prepare(); try engine.start()
      startedAt = ProcessInfo.processInfo.systemUptime; lastVoiceAt = startedAt
      speechPhase("listening")
      UIImpactFeedbackGenerator(style: .light).impactOccurred()
      speechTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
        guard let self, self.requestId == id, !self.finishing else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now - self.startedAt >= 20 {
          self.timedOut = true; self.finishSpeech()
        } else if self.heardVoice && now - self.lastVoiceAt >= 2.2 {
          self.finishSpeech()
        } else if !self.heardVoice && now - self.startedAt >= 8 {
          self.finishSpeech()
        }
      }
    } catch { fail("recording_failed", "未能開始錄音，請檢查咪高峰或重試。") }
  }
  private func finishSpeech() {
    guard recording, !finishing else { return }
    finishing = true; speechTimer?.invalidate(); speechTimer = nil
    speechPhase("finishing")
    engine.stop(); if tapped { engine.inputNode.removeTap(onBus: 0); tapped = false }
    speechRequest?.endAudio()
    let id = requestId
    // Keep the recognition task alive for delayed final words after endAudio.
    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
      guard let self, self.requestId == id, self.pending != nil else { return }
      self.timedOut = true
      self.speechComplete()
    }
  }
  private func cleanupSpeech() {
    speechTimer?.invalidate(); speechTimer = nil
    if recording {
      engine.stop(); if tapped { engine.inputNode.removeTap(onBus: 0); tapped = false }
      if !finishing { speechRequest?.endAudio() }
      speechTask?.cancel(); speechTask = nil; speechRequest = nil
      let session = AVAudioSession.sharedInstance()
      try? session.setActive(false, options: .notifyOthersOnDeactivation)
      // Restore before returning the Flutter result, for both TTS and VoiceOver.
      try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
    }
    recording = false; finishing = false; recognizer = nil
  }
}

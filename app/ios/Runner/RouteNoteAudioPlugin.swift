import AVFoundation
import Flutter
import UIKit

private final class RouteNoteRecording {
  static let maxBytes = 1024 * 1024
  static let maxSeconds = 10
  let rate: Int
  private let limit: Int
  private let lock = NSLock()
  private var samples: [Int16] = []

  init(rate: Int) {
    self.rate = rate
    limit = min(rate * Self.maxSeconds, (Self.maxBytes - 44) / 2)
    samples.reserveCapacity(limit)
  }

  var limitMilliseconds: Int { limit * 1000 / rate }

  func append(_ buffer: AVAudioPCMBuffer) {
    guard let channel = buffer.floatChannelData?[0] else { return }
    lock.lock()
    defer { lock.unlock() }
    for i in 0..<min(Int(buffer.frameLength), limit - samples.count) {
      let sample = channel[i]
      let clipped = sample.isFinite ? max(-1, min(1, sample)) : 0
      samples.append(Int16(clipped * Float(Int16.max)).littleEndian)
    }
  }

  func wav() -> Data? {
    lock.lock()
    defer { lock.unlock() }
    guard samples.count >= (rate + 3) / 4 else { return nil }
    let payload = samples.count * 2
    var data = Data(capacity: payload + 44)
    func tag(_ value: String) { data.append(contentsOf: value.utf8) }
    func put<T: FixedWidthInteger>(_ value: T) {
      var littleEndian = value.littleEndian
      withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
    tag("RIFF"); put(UInt32(payload + 36)); tag("WAVE")
    tag("fmt "); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
    put(UInt32(rate)); put(UInt32(rate * 2)); put(UInt16(2)); put(UInt16(16))
    tag("data"); put(UInt32(payload))
    samples.withUnsafeBytes { data.append(contentsOf: $0) }
    return data
  }
}

/// Recording and playback use memory buffers and never allocate a media file.
/// All session changes and method replies are owned by the main thread.
final class RouteNoteAudioPlugin: NSObject, FlutterPlugin, AVAudioPlayerDelegate {
  private var owner: String?
  private var startRequest: UUID?
  private var startReply: FlutterResult?
  private var recording: RouteNoteRecording?
  private var engine: AVAudioEngine?
  private var recordLimit: DispatchWorkItem?
  private var player: AVAudioPlayer?
  private var playReply: FlutterResult?
  private var previousSession: (AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions)?
  private var observers: [NSObjectProtocol] = []

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "hk.pathguide/route_note_audio", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(RouteNoteAudioPlugin(), channel: channel)
  }

  override init() {
    super.init()
    let center = NotificationCenter.default
    observers = [
      center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
        self?.reset()
      },
      center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] change in
        if change.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt == AVAudioSession.InterruptionType.began.rawValue {
          self?.reset()
        }
      },
      center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] change in
        if let engine = self?.engine, (change.object as? AVAudioEngine) === engine {
          self?.reset()
        }
      },
    ]
  }

  deinit { observers.forEach(NotificationCenter.default.removeObserver) }

  func detachFromEngine(for registrar: FlutterPluginRegistrar) { reset() }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let id = args["owner"] as? String, !id.isEmpty else {
      result(error("invalid")); return
    }
    switch call.method {
    case "start": start(owner: id, result: result)
    case "finish": finish(owner: id, result: result)
    case "play":
      guard let bytes = args["bytes"] as? FlutterStandardTypedData else {
        result(error("invalid")); return
      }
      play(owner: id, data: bytes.data, result: result)
    case "cancel":
      if owner == id { reset() }
      result(nil)
    default: result(FlutterMethodNotImplemented)
    }
  }

  private func error(_ code: String) -> FlutterError {
    FlutterError(code: code, message: nil, details: nil)
  }

  private func activate(_ category: AVAudioSession.Category, options: AVAudioSession.CategoryOptions) throws {
    let session = AVAudioSession.sharedInstance()
    previousSession = (session.category, session.mode, session.categoryOptions)
    try session.setCategory(category, mode: .default, options: options)
    try session.setActive(true)
  }

  private func deactivate() {
    guard let previous = previousSession else { return }
    previousSession = nil
    let session = AVAudioSession.sharedInstance()
    try? session.setActive(false, options: .notifyOthersOnDeactivation)
    try? session.setCategory(previous.0, mode: previous.1, options: previous.2)
  }

  private func start(owner id: String, result: @escaping FlutterResult) {
    guard owner == nil, UIApplication.shared.applicationState != .background else {
      result(error("unavailable")); return
    }
    let request = UUID()
    owner = id
    startRequest = request
    startReply = result
    let authorize: (Bool) -> Void = { [weak self] granted in
      DispatchQueue.main.async {
        guard let self, self.startRequest == request, let reply = self.startReply else { return }
        self.startReply = nil
        self.startRequest = nil
        guard granted, UIApplication.shared.applicationState != .background else {
          self.reset()
          reply(self.error(granted ? "cancelled" : "permission")); return
        }
        do {
          try self.activate(.playAndRecord, options: [.defaultToSpeaker, .mixWithOthers])
          let engine = AVAudioEngine()
          let node = engine.inputNode
          let format = node.outputFormat(forBus: 0)
          guard format.sampleRate >= 8000, format.sampleRate <= 96000,
                format.commonFormat == .pcmFormatFloat32, !format.isInterleaved,
                format.channelCount > 0 else {
            self.reset(); reply(self.error("unavailable")); return
          }
          let buffer = RouteNoteRecording(rate: Int(format.sampleRate.rounded()))
          node.installTap(onBus: 0, bufferSize: 1024, format: format) { pcm, _ in buffer.append(pcm) }
          self.engine = engine
          self.recording = buffer
          engine.prepare()
          try engine.start()
          let limit = DispatchWorkItem { [weak self, weak buffer] in
            if let self, let buffer, self.recording === buffer { self.endMicrophone() }
          }
          self.recordLimit = limit
          DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(buffer.limitMilliseconds), execute: limit)
          reply(buffer.limitMilliseconds)
        } catch {
          self.reset()
          reply(self.error("unavailable"))
        }
      }
    }
    if #available(iOS 17.0, *) {
      AVAudioApplication.requestRecordPermission(completionHandler: authorize)
    } else {
      AVAudioSession.sharedInstance().requestRecordPermission(authorize)
    }
  }

  private func endMicrophone() {
    recordLimit?.cancel()
    recordLimit = nil
    if let engine {
      self.engine = nil
      engine.stop()
      engine.inputNode.removeTap(onBus: 0)
      deactivate()
    }
  }

  private func finish(owner id: String, result: FlutterResult) {
    guard owner == id, let recording else { result(error("cancelled")); return }
    endMicrophone()
    let data = recording.wav()
    reset()
    if let data { result(FlutterStandardTypedData(bytes: data)) }
    else { result(error("too_short")) }
  }

  private func play(owner id: String, data: Data, result: @escaping FlutterResult) {
    guard owner == nil, UIApplication.shared.applicationState != .background,
          data.count <= RouteNoteRecording.maxBytes else {
      result(error("unavailable")); return
    }
    owner = id
    do {
      let player = try AVAudioPlayer(data: data, fileTypeHint: AVFileType.wav.rawValue)
      guard player.duration > 0, player.duration <= Double(RouteNoteRecording.maxSeconds) else {
        reset(); result(error("invalid")); return
      }
      try activate(.playback, options: [.mixWithOthers])
      player.delegate = self
      self.player = player
      guard player.play() else { reset(); result(error("unavailable")); return }
      playReply = result
    } catch {
      reset()
      result(self.error("unavailable"))
    }
  }

  func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    finishPlayer(player, success: flag)
  }

  func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
    finishPlayer(player, success: false)
  }

  private func finishPlayer(_ player: AVAudioPlayer, success: Bool) {
    DispatchQueue.main.async { [weak self, weak player] in
      guard let self, let player, self.player === player, let reply = self.playReply else { return }
      self.playReply = nil
      self.reset()
      reply(success ? nil : self.error("unavailable"))
    }
  }

  private func reset() {
    let started = startReply, played = playReply
    startReply = nil
    startRequest = nil
    playReply = nil
    owner = nil
    endMicrophone()
    recording = nil
    player?.stop()
    player = nil
    deactivate()
    started?(error("cancelled"))
    played?(error("cancelled"))
  }
}

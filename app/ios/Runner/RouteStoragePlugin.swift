import Darwin
import Flutter
import Foundation
import Security

/// App-local encrypted route files. No user-supplied absolute path is accepted
/// by the channel. Temporary files receive protection before bytes are written.
final class RouteProtectedFiles {
  let root: URL
  private let fm = FileManager.default
  init(root: URL) { self.root = root.standardizedFileURL }

  private func protect(_ url: URL) throws {
    let attrs = try fm.attributesOfItem(atPath: url.path)
    guard attrs[.type] as? FileAttributeType != .typeSymbolicLink else { throw CocoaError(.fileWriteInvalidFileName) }
    try fm.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
    var value = URLResourceValues(); value.isExcludedFromBackup = true
    var target = url; try target.setResourceValues(value)
  }
  func prepare() throws {
    if !fm.fileExists(atPath: root.path) {
      try fm.createDirectory(at: root, withIntermediateDirectories: true,
        attributes: [.protectionKey: FileProtectionType.complete, .posixPermissions: 0o700])
    }
    guard try fm.attributesOfItem(atPath: root.path)[.type] as? FileAttributeType == .typeDirectory else {
      throw CocoaError(.fileWriteInvalidFileName)
    }
    try protect(root)
    if let entries = fm.enumerator(at: root, includingPropertiesForKeys: nil) {
      for case let url as URL in entries { try protect(url) }
    }
    let lock = root.appendingPathComponent(".lock")
    if !fm.fileExists(atPath: lock.path) { try Data().write(to: lock, options: [.withoutOverwriting, .completeFileProtection]) }
    try protect(lock)
  }
  private func target(_ path: String, directory: Bool = false) throws -> URL {
    let pattern = directory ? "^[a-f0-9]{64}$" : "^(catalog\\.enc|[a-f0-9]{32}\\.tmp|[a-f0-9]{64}/[a-f0-9]{32}\\.enc(?:\\.tmp)?)$"
    guard path.range(of: pattern, options: .regularExpression) != nil else { throw CocoaError(.fileWriteInvalidFileName) }
    var cursor = root
    guard try fm.attributesOfItem(atPath: root.path)[.type] as? FileAttributeType == .typeDirectory else {
      throw CocoaError(.fileWriteInvalidFileName)
    }
    for component in path.split(separator: "/") {
      cursor.appendPathComponent(String(component))
      if let attributes = try? fm.attributesOfItem(atPath: cursor.path) {
        guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else {
          throw CocoaError(.fileWriteInvalidFileName)
        }
      }
    }
    guard cursor.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else {
      throw CocoaError(.fileWriteInvalidFileName)
    }
    return cursor
  }
  func mkdir(_ path: String) throws {
    let url = try target(path, directory: true)
    try fm.createDirectory(at: url, withIntermediateDirectories: false,
      attributes: [.protectionKey: FileProtectionType.complete, .posixPermissions: 0o700])
    try protect(url)
  }
  func write(path: String, data: Data) throws {
    guard data.count <= 2 * 1024 * 1024 else { throw CocoaError(.fileWriteOutOfSpace) }
    let url = try target(path)
    // Only unique temporary names may be written. A stable file is immutable.
    guard path.hasSuffix(".tmp") else { throw CocoaError(.fileWriteInvalidFileName) }
    try data.write(to: url, options: [.withoutOverwriting, .completeFileProtection])
    try protect(url)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.synchronize()
  }
  func move(from: String, to: String) throws {
    let source = try target(from), destination = try target(to)
    let catalog = from.range(of: "^[a-f0-9]{32}\\.tmp$", options: .regularExpression) != nil && to == "catalog.enc"
    guard catalog || (from == to + ".tmp" && to.hasSuffix(".enc") && !fm.fileExists(atPath: destination.path)) else {
      throw CocoaError(.fileWriteInvalidFileName)
    }
    guard Darwin.rename(source.path, destination.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    try protect(destination)
  }
  func inspect() throws -> [String: Any] {
    var protected = true, excluded = true, files = 0, bytes = 0
    var protectionClasses = Set<String>()
    var urls = [root]
    if let entries = fm.enumerator(at: root, includingPropertiesForKeys: nil) {
      for case let url as URL in entries { urls.append(url) }
    }
    for url in urls {
      let attrs = try fm.attributesOfItem(atPath: url.path)
      guard attrs[.type] as? FileAttributeType != .typeSymbolicLink else { throw CocoaError(.fileReadInvalidFileName) }
      let protection = (attrs[.protectionKey] as? FileProtectionType)?.rawValue ?? (attrs[.protectionKey] as? String) ?? "unavailable"
      protectionClasses.insert(protection)
      protected = protected && (protection == FileProtectionType.complete.rawValue)
      let backupExcluded = try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
      excluded = excluded && (backupExcluded == true)
      if attrs[.type] as? FileAttributeType == .typeRegular {
        files += 1; bytes += (attrs[.size] as? NSNumber)?.intValue ?? 0
      }
    }
    return ["allProtected": protected, "allExcludedFromBackup": excluded, "files": files, "bytes": bytes, "protectionClasses": protectionClasses.sorted()]
  }
}

final class RouteStoragePlugin: NSObject, FlutterPlugin {
  private let support: URL
  private let queue = DispatchQueue(label: "hk.pathguide.route-storage")
  init(support: URL) { self.support = support }
  static func register(with registrar: FlutterPluginRegistrar) {
    guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
    let plugin = RouteStoragePlugin(support: support)
    let channel = FlutterMethodChannel(name: "hk.pathguide/route_storage", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(plugin, channel: channel)
  }
  private func files(_ scope: String) throws -> RouteProtectedFiles {
    guard ["library", "probe"].contains(scope) else { throw CocoaError(.fileWriteInvalidFileName) }
    return RouteProtectedFiles(root: support.appendingPathComponent(scope == "library" ? "route_memory_v1" : "route_memory_probe_v1"))
  }
  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "probePhase" {
      result(ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--route-storage-probe=") })?.components(separatedBy: "=").last)
      return
    }
    queue.async {
      do {
        let args = call.arguments as? [String: Any] ?? [:]
        var response: Any?
        switch call.method {
        case "prepare":
          let files = try self.files(args["scope"] as? String ?? "")
          try files.prepare(); response = files.root.path
        case "mkdir":
          try self.files(args["scope"] as? String ?? "").mkdir(args["path"] as? String ?? "")
        case "write":
          guard let bytes = args["bytes"] as? FlutterStandardTypedData else { throw CocoaError(.fileWriteUnknown) }
          try self.files(args["scope"] as? String ?? "").write(path: args["path"] as? String ?? "", data: bytes.data)
        case "move":
          try self.files(args["scope"] as? String ?? "").move(from: args["from"] as? String ?? "", to: args["to"] as? String ?? "")
        case "inspect": response = try self.files(args["scope"] as? String ?? "").inspect()
        case "removeProbe":
          let root = try self.files("probe").root
          if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
        case "probeKeyAttributes":
          var item: CFTypeRef?
          let status = SecItemCopyMatching([kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: "pathguide.route_memory.probe.aes.v1", kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitOne] as CFDictionary, &item)
          let attributes = item as? [String: Any]
          response = ["found": status == errSecSuccess,
            "thisDeviceOnlyWhenUnlocked": attributes?[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String,
            "synchronizable": attributes?[kSecAttrSynchronizable as String] as? Bool ?? false]
        case "probeReport":
          let data = try JSONSerialization.data(withJSONObject: args, options: [.sortedKeys])
          let url = self.support.appendingPathComponent("route-storage-probe-result.json")
          try data.write(to: url, options: [.atomic, .completeFileProtection])
          var values = URLResourceValues(); values.isExcludedFromBackup = true
          var target = url; try target.setResourceValues(values)
          print("PATHGUIDE_ROUTE_STORAGE_PROBE " + (String(data: data, encoding: .utf8) ?? "{}")); fflush(stdout)
        default: DispatchQueue.main.async { result(FlutterMethodNotImplemented) }; return
        }
        DispatchQueue.main.async { result(response) }
      } catch {
        DispatchQueue.main.async { result(FlutterError(code: "route_storage_io", message: "Protected route storage operation failed", details: nil)) }
      }
    }
  }
}

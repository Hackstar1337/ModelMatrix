import Foundation
import Darwin

public struct ClientConfigError: Error, CustomStringConvertible, Sendable {
  public let status: Int
  public let code: String
  public let message: String
  public init(status: Int, code: String, message: String) {
    self.status = status; self.code = code; self.message = message
  }
  public var description: String { "\(code): \(message)" }
}

public struct ClientConfigPreview: Codable, Sendable {
  public let configPath: String
  public let targetVersion: String
  public let changes: [String]
  public let notes: [String]

  // Safe metadata for the core's durable approval comparison. Internal, not a public
  // API or Codable field; contains neither raw settings nor credential references.
  internal var approvalFingerprint: String {
    let metadata = [configPath, targetVersion, sourceHash ?? "missing",
                    sourceIdentity.map { "\($0.device):\($0.inode)" } ?? "missing"]
    return configHash(try! JSONEncoder().encode(metadata))
  }
  fileprivate let target: String
  fileprivate let providerID: String
  fileprivate let modelKey: String
  fileprivate let modelID: String
  fileprivate let baseURL: String
  fileprivate let keyFile: String
  fileprivate let context: Int?
  fileprivate let makeDefault: Bool
  fileprivate let sourceHash: String?
  fileprivate let sourceIdentity: ConfigFileIdentity?
  fileprivate let sourceMode: UInt16?
  fileprivate let ownedEnabledProviderMembership: Bool?

  fileprivate init(configPath: String, targetVersion: String, changes: [String], notes: [String],
                   target: String, providerID: String, modelKey: String, modelID: String,
                   baseURL: String, keyFile: String, context: Int?, makeDefault: Bool,
                   source: ConfigFileSnapshot?, ownedEnabledProviderMembership: Bool?) {
    self.configPath = configPath; self.targetVersion = targetVersion
    self.changes = changes; self.notes = notes; self.target = target
    self.providerID = providerID; self.modelKey = modelKey; self.modelID = modelID
    self.baseURL = baseURL; self.keyFile = keyFile; self.context = context
    self.makeDefault = makeDefault; self.sourceHash = source.map { configHash($0.bytes) }
    self.sourceIdentity = source?.identity; self.sourceMode = source?.mode
    self.ownedEnabledProviderMembership = ownedEnabledProviderMembership
  }
  private enum CodingKeys: String, CodingKey { case configPath, targetVersion, changes, notes }
  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(configPath, forKey: .configPath); try c.encode(targetVersion, forKey: .targetVersion)
    try c.encode(changes, forKey: .changes); try c.encode(notes, forKey: .notes)
  }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    configPath = try c.decode(String.self, forKey: .configPath)
    targetVersion = try c.decode(String.self, forKey: .targetVersion)
    changes = try c.decode([String].self, forKey: .changes); notes = try c.decode([String].self, forKey: .notes)
    target = ""; providerID = ""; modelKey = ""; modelID = ""; baseURL = ""; keyFile = ""
    context = nil; makeDefault = false; sourceHash = nil; sourceIdentity = nil; sourceMode = nil; ownedEnabledProviderMembership = nil
    // Decoded public previews are display data, never write capabilities.
  }
}

public struct ClientConfigReceipt: Codable, Sendable {
  public let configPath: String
  public let target: String
  public let providerID: String
  public let modelKey: String
  public let operationID: String
  public let backupPath: String
  public let makeDefault: Bool
  public let expectedOwnedHash: String
  public let priorDefault: String?
  public let ownedEnabledProviderMembership: Bool?
  public init(configPath: String, target: String, providerID: String, modelKey: String,
              operationID: String, backupPath: String, makeDefault: Bool,
              expectedOwnedHash: String, priorDefault: String?, ownedEnabledProviderMembership: Bool? = nil) {
    self.configPath = configPath; self.target = target; self.providerID = providerID
    self.modelKey = modelKey; self.operationID = operationID; self.backupPath = backupPath
    self.makeDefault = makeDefault; self.expectedOwnedHash = expectedOwnedHash; self.priorDefault = priorDefault
    self.ownedEnabledProviderMembership = ownedEnabledProviderMembership
  }
}

public final class ClientConfigManager: @unchecked Sendable {
  private let home: URL
  private let qualifiedOverrides: [String: URL]
  private let versionOverrides: [String: String]
  private let backupDirectory: URL?
  private let lock = NSLock()
  // A manager instance is the lifetime of a configure/reconfigure flow. This
  // distinguishes a membership ModelMatrix added from one that predated setup.
  private var ownedEnabledMembership: [String: Bool] = [:]
  public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
              qualifiedOverrides: [String: URL] = [:], versionOverrides: [String: String] = [:]) {
    self.home = canonicalURL(home); self.qualifiedOverrides = qualifiedOverrides
    self.versionOverrides = versionOverrides; backupDirectory = nil
  }
  /// Constructor-only injection; never accepts arbitrary API-supplied file paths.
  public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
              qualifiedOverrides: [String: URL] = [:], versionOverrides: [String: String] = [:], backupDirectory: URL?) {
    self.home = canonicalURL(home); self.qualifiedOverrides = qualifiedOverrides
    self.versionOverrides = versionOverrides; self.backupDirectory = backupDirectory.map(canonicalURL)
  }

  public func targets() -> [[String: Any]] {
    lock.lock(); defer { lock.unlock() }
    return [targetInfo(.kilo), targetInfo(.opencode)]
  }

  public func prepare(target: String, providerID: String, modelKey: String, modelID: String,
                      baseURL: String, keyFile: String, context: Int?, makeDefault: Bool,
                      previousReceipt: ClientConfigReceipt? = nil) throws -> ClientConfigPreview {
    lock.lock(); defer { lock.unlock() }
    let kind = try validateTarget(target)
    try validateOwnedIdentifiers(providerID: providerID, modelKey: modelKey)
    guard !modelID.isEmpty, modelID.utf8.count <= 1000, !modelID.unicodeScalars.contains(where: { $0.value < 32 }),
          !modelID.contains("{file:"), !modelID.contains("{env:") else {
      throw configError("invalid_input", "invalid model id", status: 400)
    }
    try validateBaseURL(baseURL); try validateKeyFile(keyFile)
    if let context, !(1...10_000_000).contains(context) { throw configError("invalid_input", "context must be a positive bounded integer", status: 400) }
    let selected = try selectedTarget(kind)
    guard selected.version == kind.requiredVersion else { throw configError("unsupported_version", "only the exact qualified installed client version is supported") }
    if let previousReceipt {
      guard previousReceipt.target == target, previousReceipt.providerID == providerID,
            previousReceipt.modelKey == modelKey,
            canonicalURL(URL(fileURLWithPath: previousReceipt.configPath)).path == selected.path.path else {
        throw configError("ownership_conflict", "prior receipt does not match this approved provider/config scope")
      }
    }
    if let warning = overrideWarning(kind) { throw configError("override_detected", warning) }
    let source = try ConfigFileIO.read(selected.path)
    let document = try source.map { try ConfigJSONDocument(data: $0.bytes) }
    var changes: [String] = []
    var ownedEnabledProviderMembership: Bool?
    if let document {
      let filters = try document.providerFilterMembership(providerID: providerID)
      if let enabled = filters.enabled {
        let key = membershipKey(path: selected.path, target: kind, providerID: providerID, modelKey: modelKey)
        ownedEnabledProviderMembership = enabled ? (previousReceipt?.ownedEnabledProviderMembership ?? ownedEnabledMembership[key] ?? false) : true
      }
      let container = try document.providerContainer()
      if container?.member(providerID) != nil {
        guard try document.matchesOwned(providerID: providerID, modelKey: modelKey, modelID: modelID, baseURL: baseURL, keyFile: keyFile, context: context) else {
          throw configError("ownership_conflict", "requested provider namespace already exists and differs from the approved single-model block")
        }
        changes.append("Retain the exact existing owned provider/model block")
      } else { changes += ["Add provider.\(providerID)", "Add models.\(modelKey) with the exact wire id"] }
      if filters.enabled == false { changes.append("Add \(providerID) to enabled_providers allow-list") }
      if makeDefault, document.rootDefault != "\(providerID)/\(modelKey)" {
        if document.root.member("model") != nil, document.rootDefault == nil {
          throw configError("ownership_conflict", "existing root default is not a string and cannot be safely restored")
        }
        let old = document.rootDefault ?? "(not set in this file)"
        changes.append("Make default: \(old) → \(providerID)/\(modelKey) (explicit approval; restored on disconnect/undo if still owned)")
      }
    } else {
      changes += ["Create the approved global configuration", "Add provider.\(providerID)", "Add models.\(modelKey) with the exact wire id"]
      if makeDefault { changes.append("Make default: (not set) → \(providerID)/\(modelKey)") }
    }
    var notes = ["Only the dedicated provider/model subtree is changed; unrelated JSONC bytes and comments are preserved.",
                 "Approval is bound to path, exact target version, source hash and inode; all are checked again before writing.",
                 "Read-back verifies the actual controlled file on disk, not effective merged client configuration.",
                 "Project/legacy layers can override this global file. Reload in a fresh client process and verify effective scope separately; no client is restarted."]
    if !makeDefault { notes.append("The existing root default is preserved (Make default is off).") }
    if let context {
      notes.append("Native limit.context is the known runtime context (\(context)); limit.output is an explicit ModelMatrix application POLICY generation budget of \(ConfigFormat.outputBudget(context: context)) tokens (min(8192, runtime context)), NOT a verified model maximum.")
    } else { notes.append("Runtime context is unknown; native limit is omitted rather than inventing model maxima.") }
    if kind == .opencode { notes.append("OpenCode 1.16.2 CLI/TUI v1 syntax is used; desktop/v2 and live client use are not qualified.") }
    else { notes.append("Kilo 7.8.12 qualifies local model-key → models.<key>.id wire mapping; live editor use remains a separate gate.") }
    return ClientConfigPreview(configPath: selected.path.path, targetVersion: selected.version ?? "unknown",
      changes: changes, notes: notes, target: target, providerID: providerID, modelKey: modelKey, modelID: modelID,
      baseURL: baseURL, keyFile: keyFile, context: context, makeDefault: makeDefault, source: source,
      ownedEnabledProviderMembership: ownedEnabledProviderMembership)
  }

  public func apply(_ preview: ClientConfigPreview, operationID: String) throws -> ClientConfigReceipt {
    lock.lock(); defer { lock.unlock() }
    try validateOperationID(operationID)
    let kind = try validateTarget(preview.target)
    let selected = try selectedTarget(kind)
    guard selected.path.path == preview.configPath, selected.version == preview.targetVersion,
          selected.version == kind.requiredVersion else {
      throw configError("stale_approval", "target path or installed version changed after approval; create a new plan")
    }
    if let warning = overrideWarning(kind) { throw configError("override_detected", warning) }
    let path = selected.path
    return try ConfigFileIO.withLock(path) { parentFD in
      let current = try ConfigFileIO.read(path.lastPathComponent, parentFD: parentFD)
      guard current.map({ configHash($0.bytes) }) == preview.sourceHash,
            current?.identity == preview.sourceIdentity, current?.mode == preview.sourceMode else {
        throw configError("stale_approval", "configuration changed after approval; create a new plan")
      }
      let document = try ConfigJSONDocument(data: current?.bytes ?? Data("{}".utf8))
      let patch = try document.additionPatch(providerID: preview.providerID, modelKey: preview.modelKey,
        modelID: preview.modelID, baseURL: preview.baseURL, keyFile: preview.keyFile, context: preview.context, makeDefault: preview.makeDefault)
      let output = try patch.apply(to: document.data)
      let candidate = try ConfigJSONDocument(data: output) // Validate BEFORE any replacement.
      let candidateEnabled = try candidate.providerFilterMembership(providerID: preview.providerID).enabled
      guard try candidate.matchesOwned(providerID: preview.providerID, modelKey: preview.modelKey, modelID: preview.modelID,
          baseURL: preview.baseURL, keyFile: preview.keyFile, context: preview.context),
          preview.ownedEnabledProviderMembership == nil || candidateEnabled == true,
          !preview.makeDefault || candidate.rootDefault == "\(preview.providerID)/\(preview.modelKey)" else {
        throw configError("read_back_failed", "generated configuration does not match approved native fields", status: 500)
      }
      let backup = try ConfigFileIO.backup(current?.bytes, path: path, directory: backupDirectory, operationID: operationID)
      try ConfigFileIO.replace(output, path: path, parentFD: parentFD, expected: current)
      guard let disk = try ConfigFileIO.read(path.lastPathComponent, parentFD: parentFD), disk.bytes == output else {
        throw configError("read_back_failed", "actual on-disk output differs from the approved configuration", status: 500)
      }
      let readBack = try ConfigJSONDocument(data: disk.bytes)
      let readBackEnabled = try readBack.providerFilterMembership(providerID: preview.providerID).enabled
      guard try readBack.matchesOwned(providerID: preview.providerID, modelKey: preview.modelKey, modelID: preview.modelID,
          baseURL: preview.baseURL, keyFile: preview.keyFile, context: preview.context),
          preview.ownedEnabledProviderMembership == nil || readBackEnabled == true,
          !preview.makeDefault || readBack.rootDefault == "\(preview.providerID)/\(preview.modelKey)" else {
        throw configError("read_back_failed", "actual on-disk native fields did not match", status: 500)
      }
      if let owned = preview.ownedEnabledProviderMembership {
        ownedEnabledMembership[membershipKey(path: path, target: kind, providerID: preview.providerID, modelKey: preview.modelKey)] = owned
      }
      return ClientConfigReceipt(configPath: path.path, target: kind.rawValue, providerID: preview.providerID,
        modelKey: preview.modelKey, operationID: operationID, backupPath: backup?.path ?? "", makeDefault: preview.makeDefault,
        expectedOwnedHash: try readBack.ownedHash(providerID: preview.providerID, modelKey: preview.modelKey), priorDefault: document.rootDefault,
        ownedEnabledProviderMembership: preview.ownedEnabledProviderMembership)
    }
  }

  public func readBack(_ receipt: ClientConfigReceipt) throws -> Bool {
    lock.lock(); defer { lock.unlock() }
    let path = try receiptPath(receipt)
    guard let source = try ConfigFileIO.read(path), let document = try? ConfigJSONDocument(data: source.bytes),
          let ownedHash = try? document.ownedHash(providerID: receipt.providerID, modelKey: receipt.modelKey),
          ownedHash == receipt.expectedOwnedHash else { return false }
    if receipt.ownedEnabledProviderMembership != nil {
      guard let filters = try? document.providerFilterMembership(providerID: receipt.providerID), filters.enabled == true else { return false }
    }
    return !receipt.makeDefault || document.rootDefault == "\(receipt.providerID)/\(receipt.modelKey)"
  }
  public func remove(_ receipt: ClientConfigReceipt) throws { try mutateOwnership(receipt) }
  public func undo(_ receipt: ClientConfigReceipt) throws { try mutateOwnership(receipt) }

  private func mutateOwnership(_ receipt: ClientConfigReceipt) throws {
    lock.lock(); defer { lock.unlock() }
    let path = try receiptPath(receipt)
    try ConfigFileIO.withLock(path) { parentFD in
      guard let source = try ConfigFileIO.read(path.lastPathComponent, parentFD: parentFD) else { throw configError("not_found", "owned configuration is missing", status: 404) }
      let document = try ConfigJSONDocument(data: source.bytes)
      guard try document.ownedHash(providerID: receipt.providerID, modelKey: receipt.modelKey) == receipt.expectedOwnedHash else {
        throw configError("ownership_conflict", "owned settings changed; refusing to remove another writer's configuration")
      }
      let patch = try document.removalPatch(providerID: receipt.providerID, modelKey: receipt.modelKey,
        restoreDefault: receipt.priorDefault, ownsDefault: receipt.makeDefault,
        ownsEnabledProviderMembership: receipt.ownedEnabledProviderMembership)
      let output = try patch.apply(to: source.bytes)
      let check = try ConfigJSONDocument(data: output)
      guard try check.providerContainer()?.member(receipt.providerID) == nil else {
        throw configError("read_back_failed", "generated removal did not remove the owned provider", status: 500)
      }
      _ = try ConfigFileIO.backup(source.bytes, path: path, directory: backupDirectory, operationID: receipt.operationID + "-recovery")
      try ConfigFileIO.replace(output, path: path, parentFD: parentFD, expected: source)
      guard let disk = try ConfigFileIO.read(path.lastPathComponent, parentFD: parentFD), disk.bytes == output else {
        throw configError("read_back_failed", "actual disk removal did not match", status: 500)
      }
      _ = try ConfigJSONDocument(data: disk.bytes)
    }
  }

  // MARK: Qualified target discovery
  private struct Selection { let path: URL; let version: String? }
  private func configDirectory(_ kind: ConfigTarget) -> URL { home.appendingPathComponent(".config/\(kind.rawValue)", isDirectory: true) }
  private func selectedTarget(_ kind: ConfigTarget) throws -> Selection {
    Selection(path: try selectedConfigPath(kind), version: detectedVersion(kind))
  }
  private func selectedConfigPath(_ kind: ConfigTarget) throws -> URL {
    if let injected = qualifiedOverrides[kind.rawValue] {
      guard ["json", "jsonc"].contains(injected.pathExtension.lowercased()) else { throw configError("unsafe_path", "injected configuration must be JSON or JSONC") }
      let path = canonicalURL(injected)
      if let source = try ConfigFileIO.read(path) { _ = try ConfigJSONDocument(data: source.bytes) }
      return path
    }
    var selected = configDirectory(kind).appendingPathComponent(kind.defaultFile)
    // Inspect EVERY existing global layer, including dangling symlinks. Never create
    // a competing sibling merely because a later layer is unsafe or invalid.
    for name in kind.candidates {
      let path = configDirectory(kind).appendingPathComponent(name)
      if let source = try ConfigFileIO.read(path) {
        _ = try ConfigJSONDocument(data: source.bytes); selected = path
      }
    }
    return selected
  }

  private func kiloInstallations() -> [URL] {
    let root = home.appendingPathComponent(".vscode/extensions", isDirectory: true)
    guard let fd = try? ConfigFileIO.parent(root.appendingPathComponent("sentinel"), create: false) else { return [] }
    defer { close(fd) }
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
    return names.filter { $0.hasPrefix("kilocode.kilo-code-") }.map { root.appendingPathComponent($0, isDirectory: true) }
  }
  private func installation(_ kind: ConfigTarget) -> URL? {
    if qualifiedOverrides[kind.rawValue] != nil, versionOverrides[kind.rawValue] != nil { return nil }
    switch kind {
    case .kilo:
      // Conservative: VS Code activation identity is ambiguous if multiple copies are
      // installed; do not guess lexicographically or use a directory-name version.
      let matches = kiloInstallations()
      guard matches.count == 1 else { return nil }
      return matches[0]
    case .opencode:
      let binary = home.appendingPathComponent(".opencode/bin/opencode")
      return (try? ConfigFileIO.validateExecutable(binary)) == true ? binary : nil
    }
  }
  private func cliPath(_ kind: ConfigTarget, installed: URL?) -> URL? {
    guard let installed else { return nil }
    let cli = kind == .kilo ? installed.appendingPathComponent("bin/kilo") : installed
    return (try? ConfigFileIO.validateExecutable(cli)) == true ? cli : nil
  }
  private func detectedVersion(_ kind: ConfigTarget) -> String? {
    if let version = versionOverrides[kind.rawValue] { return version }
    guard let installed = installation(kind), let cli = cliPath(kind, installed: installed) else { return nil }
    if kind == .kilo {
      guard let data = try? ConfigFileIO.installationMetadata(installed.appendingPathComponent("package.json")),
            let json = (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? [String: Any],
            let version = json["version"] as? String, version.range(of: "^[0-9]+\\.[0-9]+\\.[0-9]+$", options: .regularExpression) != nil else { return nil }
      return version
    }
    return shortVersionProbe(cli)
  }

  private func shortVersionProbe(_ binary: URL) -> String? {
    // Execute ONLY this known native binary with --version, never a shell, installer,
    // inferred directory/package entry, or client config command. Isolate HOME/XDG/CWD.
    let isolated = canonicalURL(FileManager.default.temporaryDirectory).appendingPathComponent("modelmatrix-version-\(UUID().uuidString)", isDirectory: true)
    do { try FileManager.default.createDirectory(at: isolated, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
    catch { return nil }
    defer { try? FileManager.default.removeItem(at: isolated) }
    let process = Process(), pipe = Pipe()
    process.executableURL = binary; process.arguments = ["--version"]
    process.currentDirectoryURL = isolated
    process.environment = ["HOME": isolated.path, "XDG_CONFIG_HOME": isolated.appendingPathComponent("config").path,
      "XDG_DATA_HOME": isolated.appendingPathComponent("data").path, "XDG_CACHE_HOME": isolated.appendingPathComponent("cache").path,
      "XDG_STATE_HOME": isolated.appendingPathComponent("state").path, "TMPDIR": isolated.path,
      "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "OPENCODE_DISABLE_PROJECT_CONFIG": "true", "OPENCODE_DISABLE_MODELS_FETCH": "true"]
    process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
    let fd = pipe.fileHandleForReading.fileDescriptor
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    do { try process.run() } catch { return nil }
    defer { try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close() }
    var output = Data(), buffer = [UInt8](repeating: 0, count: 512)
    let deadline = ProcessInfo.processInfo.systemUptime + 4.0
    while true {
      let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
      if count > 0 { output.append(contentsOf: buffer.prefix(count)) }
      if output.count > 4096 || ProcessInfo.processInfo.systemUptime >= deadline {
        if process.isRunning { process.terminate(); usleep(20_000); if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) } }
        return nil
      }
      if !process.isRunning, count <= 0 { break }
      usleep(5_000)
    }
    guard process.terminationStatus == 0, let text = String(data: output, encoding: .utf8) else { return nil }
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return value.range(of: "^[0-9]+\\.[0-9]+\\.[0-9]+$", options: .regularExpression) != nil ? value : nil
  }

  private func targetInfo(_ kind: ConfigTarget) -> [String: Any] {
    let installed = installation(kind), version = detectedVersion(kind)
    var result: [String: Any] = ["id": kind.rawValue, "name": kind.displayName,
      "installed": installed != nil || versionOverrides[kind.rawValue] != nil || (kind == .kilo && !kiloInstallations().isEmpty),
      "qualified": version == kind.requiredVersion,
      "reload_note": "Configured file read-back is not live client verification. Reload in a fresh client process; project/legacy overrides may win."]
    if let version { result["version"] = version }
    if let installed { result["path"] = installed.path }
    if let cli = cliPath(kind, installed: installed) { result["cli_path"] = cli.path }
    do { result["config_path"] = try selectedConfigPath(kind).path }
    catch { result["qualified"] = false; result["reason"] = "global configuration is unsafe, invalid or inaccessible" }
    if version != kind.requiredVersion { result["reason"] = "only exact \(kind.requiredVersion) is qualified; installed version is unknown, ambiguous or unsupported" }
    if let warning = overrideWarning(kind) { result["qualified"] = false; result["reason"] = warning }
    return result
  }
  private func overrideWarning(_ kind: ConfigTarget) -> String? {
    let env = ProcessInfo.processInfo.environment
    if let xdg = env["XDG_CONFIG_HOME"], !xdg.isEmpty, canonicalURL(URL(fileURLWithPath: xdg)).path != home.appendingPathComponent(".config").path {
      return "XDG_CONFIG_HOME changes the approved global scope; automatic configuration is declined"
    }
    let names = kind == .opencode ? ["OPENCODE_CONFIG", "OPENCODE_CONFIG_CONTENT", "OPENCODE_CONFIG_DIR"] : ["KILO_CONFIG", "KILO_CONFIG_CONTENT", "KILO_CONFIG_DIR", "OPENCODE_CONFIG", "OPENCODE_CONFIG_CONTENT", "OPENCODE_CONFIG_DIR"]
    if let name = names.first(where: { env[$0] != nil }) { return "\(name) overrides the approved global scope; automatic configuration is declined" }
    return nil
  }

  // MARK: Input and receipt boundary validation
  private func validateTarget(_ raw: String) throws -> ConfigTarget {
    guard let kind = ConfigTarget(rawValue: raw) else { throw configError("invalid_input", "unsupported automatic target", status: 400) }
    return kind
  }
  private func membershipKey(path: URL, target: ConfigTarget, providerID: String, modelKey: String) -> String {
    "\(path.path)|\(target.rawValue)|\(providerID)|\(modelKey)"
  }
  private func validateOwnedIdentifiers(providerID: String, modelKey: String) throws {
    for value in [providerID, modelKey] {
      guard (1...100).contains(value.utf8.count), value.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 95, 46].contains($0) }) else {
        throw configError("invalid_input", "invalid owned provider/model identifier", status: 400)
      }
    }
    guard providerID.hasPrefix("mmx-") else { throw configError("ownership_conflict", "provider id is not a ModelMatrix-owned namespace") }
  }
  private func validateOperationID(_ value: String) throws {
    guard (1...200).contains(value.utf8.count), value.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 95, 46].contains($0) }) else {
      throw configError("invalid_input", "invalid operation id", status: 400)
    }
  }
  private func validateBaseURL(_ value: String) throws {
    guard value.utf8.count <= 2000, let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
          url.host != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
          !value.unicodeScalars.contains(where: { $0.value < 32 }), !value.contains("{file:"), !value.contains("{env:") else {
      throw configError("invalid_input", "invalid relay base URL", status: 400)
    }
  }
  private func validateKeyFile(_ value: String) throws {
    // This is only a reference. Never read an existing credential during prepare.
    guard value.hasPrefix("/"), value.utf8.count <= 4096,
          !value.unicodeScalars.contains(where: { $0.value < 32 }), !value.contains("{"), !value.contains("}"),
          !value.contains("\\"), !value.contains("\""),
          !value.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
      throw configError("invalid_input", "invalid protected key-file reference", status: 400)
    }
  }
  private func receiptPath(_ receipt: ClientConfigReceipt) throws -> URL {
    let kind = try validateTarget(receipt.target)
    try validateOwnedIdentifiers(providerID: receipt.providerID, modelKey: receipt.modelKey)
    try validateOperationID(receipt.operationID)
    let path = canonicalURL(URL(fileURLWithPath: receipt.configPath))
    _ = try ConfigFileIO.components(path)
    let allowed: [URL]
    if let injected = qualifiedOverrides[kind.rawValue] { allowed = [canonicalURL(injected)] }
    else { allowed = kind.candidates.map { configDirectory(kind).appendingPathComponent($0) } }
    guard allowed.contains(where: { $0.path == path.path }) else { throw configError("unsafe_path", "receipt path is outside the approved client configuration scope") }
    return path
  }
}

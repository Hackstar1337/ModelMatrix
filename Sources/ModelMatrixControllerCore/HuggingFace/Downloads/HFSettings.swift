import Foundation
import ModelMatrixCore

/// Settings for Hugging Face checks, downloads and engines. Stored as
/// `<controller root>/huggingface/settings.json`.
public struct HFSettings: Codable, Sendable, Equatable {
  public static let defaultModelsFolder = "~/ModelMatrix/Models"

  /// Where models are saved; `~` is the user's home folder.
  public var modelsFolder = HFSettings.defaultModelsFolder
  /// A Hugging Face mirror (for example https://hf-mirror.com); nil uses huggingface.co.
  public var endpoint: String?
  /// Start the model and send it a test message once its download is verified.
  public var startAfterDownload = true
  /// Keep the Mac from idle-sleeping while downloads run.
  public var keepAwake = true
  /// Parallel connections for each large file (1-8).
  public var connectionsPerFile = 4
  /// Total download speed limit in MB/s; 0 means no limit.
  public var speedLimitMBps: Double = 0
  /// Whether a token is saved in the Keychain. The token itself is never stored here.
  public var tokenSaved = false
  /// Engine locations set by the user, e.g. {"llama.cpp": "/opt/tools/llama-server"}.
  public var enginePaths: [String: String] = [:]

  public init() {}

  enum CodingKeys: String, CodingKey {
    case modelsFolder, endpoint, startAfterDownload, keepAwake, connectionsPerFile, speedLimitMBps
    case tokenSaved, enginePaths
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let defaults = HFSettings()
    modelsFolder = (try? values.decodeIfPresent(String.self, forKey: .modelsFolder)) ?? defaults.modelsFolder
    endpoint = (try? values.decodeIfPresent(String.self, forKey: .endpoint)) ?? nil
    startAfterDownload = (try? values.decodeIfPresent(Bool.self, forKey: .startAfterDownload)) ?? true
    keepAwake = (try? values.decodeIfPresent(Bool.self, forKey: .keepAwake)) ?? true
    connectionsPerFile = (try? values.decodeIfPresent(Int.self, forKey: .connectionsPerFile)) ?? 4
    speedLimitMBps = (try? values.decodeIfPresent(Double.self, forKey: .speedLimitMBps)) ?? 0
    tokenSaved = (try? values.decodeIfPresent(Bool.self, forKey: .tokenSaved)) ?? false
    enginePaths = (try? values.decodeIfPresent([String: String].self, forKey: .enginePaths)) ?? [:]
    connectionsPerFile = min(max(connectionsPerFile, 1), 8)
    speedLimitMBps = min(max(speedLimitMBps, 0), 10_000)
  }

  /// The models folder as an absolute URL.
  public var modelsFolderURL: URL {
    URL(fileURLWithPath: HFSettings.expand(modelsFolder), isDirectory: true).standardizedFileURL
  }

  public var endpointURL: URL? {
    guard let endpoint, !endpoint.isEmpty else { return nil }
    return URL(string: endpoint)
  }

  static func expand(_ path: String) -> String {
    if path == "~" { return NSHomeDirectory() }
    if path.hasPrefix("~/") { return NSHomeDirectory() + String(path.dropFirst(1)) }
    return path
  }

  /// Applies the fields present in `patch` (JSON from the dashboard or CLI).
  /// Throws a user-facing message for invalid values; nothing is saved then.
  public func applying(_ patch: [String: Any]) throws -> HFSettings {
    var next = self
    for (key, value) in patch {
      switch key {
      case "models_folder":
        guard let text = (value as? String)?.trimmed, !text.isEmpty else {
          throw HFError.invalidSetting("The models folder can't be empty.")
        }
        let expanded = HFSettings.expand(text)
        guard expanded.hasPrefix("/"), !expanded.split(separator: "/").contains("..") else {
          throw HFError.invalidSetting("The models folder must be a full path, such as ~/ModelMatrix/Models.")
        }
        next.modelsFolder = text
      case "endpoint":
        if value is NSNull || (value as? String)?.trimmed.isEmpty == true {
          next.endpoint = nil
          continue
        }
        guard var text = (value as? String)?.trimmed, let url = URL(string: text),
          let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", url.host != nil,
          url.query == nil, url.user == nil
        else {
          throw HFError.invalidSetting("The Hugging Face address must look like https://hf-mirror.com.")
        }
        while text.hasSuffix("/") { text.removeLast() }
        next.endpoint = text == "https://huggingface.co" ? nil : text
      case "start_after_download":
        guard let flag = value as? Bool else { throw HFError.invalidSetting("start_after_download must be true or false.") }
        next.startAfterDownload = flag
      case "keep_awake":
        guard let flag = value as? Bool else { throw HFError.invalidSetting("keep_awake must be true or false.") }
        next.keepAwake = flag
      case "connections_per_file":
        guard let number = (value as? NSNumber)?.intValue, (1...8).contains(number) else {
          throw HFError.invalidSetting("Connections per file must be between 1 and 8.")
        }
        next.connectionsPerFile = number
      case "speed_limit_mbps":
        guard let number = (value as? NSNumber)?.doubleValue, number >= 0, number <= 10_000 else {
          throw HFError.invalidSetting("The speed limit must be 0 (no limit) or a number of MB/s.")
        }
        next.speedLimitMBps = number
      case "engine_paths":
        guard let paths = value as? [String: Any] else {
          throw HFError.invalidSetting("engine_paths must map an engine to the path of its server program.")
        }
        // Per engine: a path sets it, null or "" clears it, others stay.
        var cleaned = next.enginePaths
        for (engine, raw) in paths {
          guard HFEngineID(rawValue: engine) != nil else {
            throw HFError.invalidSetting("Unknown engine \(engine). Use llama.cpp, mlx-lm or ollama.")
          }
          if raw is NSNull || (raw as? String)?.trimmed.isEmpty == true {
            cleaned[engine] = nil
            continue
          }
          guard let text = (raw as? String)?.trimmed else { continue }
          let path = HFSettings.expand(text)
          guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else {
            throw HFError.invalidSetting("\(text) is not a program on this machine.")
          }
          cleaned[engine] = path
        }
        next.enginePaths = cleaned
      default:
        throw HFError.invalidSetting("Unknown setting \(key).")
      }
    }
    return next
  }
}

/// Loads and saves `HFSettings`, thread-safe.
public final class HFSettingsStore: @unchecked Sendable {
  public let file: URL
  private let lock = NSLock()
  private var cached: HFSettings?

  public init(file: URL) {
    self.file = file
  }

  public var current: HFSettings {
    lock.lock()
    defer { lock.unlock() }
    if let cached { return cached }
    let loaded = (try? Data(contentsOf: file)).flatMap { try? HFFiles.decoder.decode(HFSettings.self, from: $0) }
    let value = loaded ?? HFSettings()
    cached = value
    return value
  }

  @discardableResult
  public func save(_ settings: HFSettings) throws -> HFSettings {
    lock.lock()
    defer { lock.unlock() }
    try HFFiles.writeAtomically(try HFFiles.encoder.encode(settings), to: file)
    cached = settings
    return settings
  }

  public func update(_ change: (inout HFSettings) -> Void) throws -> HFSettings {
    var value = current
    change(&value)
    return try save(value)
  }
}

/// Where the Hugging Face token is kept. The Keychain on Macs; tests use memory.
public protocol HFTokenStoring: Sendable {
  func load() -> String?
  func save(_ token: String)
  func delete()
}

public struct HFKeychainTokenStore: HFTokenStoring {
  let storage = KeychainTokenStorage(
    service: "io.github.hackstar1337.modelmatrix.huggingface-token", accessGroup: nil, account: "huggingface")

  public init() {}
  public func load() -> String? { storage.load() }
  public func save(_ token: String) { storage.save(token) }
  public func delete() { storage.delete() }
}

public final class HFMemoryTokenStore: HFTokenStoring, @unchecked Sendable {
  private let lock = NSLock()
  private var value: String?

  public init(_ value: String? = nil) {
    self.value = value
  }

  public func load() -> String? {
    lock.lock()
    defer { lock.unlock() }
    return value
  }

  public func save(_ token: String) {
    lock.lock()
    value = token
    lock.unlock()
  }

  public func delete() {
    lock.lock()
    value = nil
    lock.unlock()
  }
}

/// JSON files written by the Hugging Face features.
enum HFFiles {
  static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return encoder
  }()

  static let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return decoder
  }()

  /// Writes via a temporary file and rename, so a crash never leaves half a file.
  static func writeAtomically(_ data: Data, to file: URL) throws {
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let temporary = file.deletingLastPathComponent()
      .appendingPathComponent(".\(file.lastPathComponent).\(UUID().uuidString).tmp")
    try data.write(to: temporary, options: [.atomic])
    if FileManager.default.fileExists(atPath: file.path) {
      _ = try FileManager.default.replaceItemAt(file, withItemAt: temporary)
    } else {
      try FileManager.default.moveItem(at: temporary, to: file)
    }
  }

  static func timestamp(_ date: Date = Date()) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
  }
}

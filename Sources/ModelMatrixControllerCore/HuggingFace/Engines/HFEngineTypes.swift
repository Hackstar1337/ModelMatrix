import Foundation

/// What an engine plan does.
public enum HFEngineAction: String, Sendable, Codable, CaseIterable {
  case install, update, uninstall
}

/// How the engine is (or was) installed.
public enum HFEngineMethod: String, Sendable, Codable {
  /// `brew install …` with the Mac's own Homebrew.
  case homebrew
  /// The project's official build, checked against its SHA-256, into the
  /// ModelMatrix engines folder (or ~/Applications for the Ollama app).
  case official
}

/// A file the plan downloads, with the checksum it must match.
public struct HFEngineDownload: Sendable, Codable, Equatable {
  public var name: String
  public var url: String
  public var size: Int64
  public var sha256: String
}

/// One step of a plan, run in order.
public enum HFEngineStep: Sendable, Codable, Equatable {
  /// Run this exact program with these arguments.
  case run(program: String, arguments: [String], environment: [String: String])
  /// Download and verify an official archive, unpack it, and move its
  /// top folder `keep` to `into/name`. With `linkBin`, `into/bin` then
  /// points at it (so updates switch over in one step).
  case unpack(download: HFEngineDownload, into: String, keep: String, name: String, linkBin: Bool)
  /// Move an unpacked app bundle into place.
  case placeApp(download: HFEngineDownload, app: String, destination: String)
  /// Delete a folder ModelMatrix created (or move an app it installed to the Trash).
  case remove(path: String, toTrash: Bool)
}

/// Everything the user sees before approving, plus the steps that will run.
/// A plan runs at most once, and only within `expiresAt`.
public struct HFEnginePlan: Sendable, Encodable {
  public var id: String
  public var engine: HFEngineID
  public var engineName: String
  public var action: HFEngineAction
  public var method: HFEngineMethod
  /// Version that will be installed (nil: whatever Homebrew has).
  public var version: String?
  public var installedVersion: String?
  /// Plain-English summary, e.g. "Install llama.cpp with Homebrew".
  public var title: String
  /// The exact commands that will run, as typed in Terminal.
  public var commands: [String]
  /// Official files that will be downloaded and checked.
  public var downloads: [HFEngineDownload]
  public var downloadSize: String
  public var location: String
  public var needsAdmin: Bool
  public var removal: String?
  public var notes: [String]
  public var createdAt: String
  public var expiresAt: String
  var steps: [HFEngineStep]
  var expires: Date
  /// Where the engine's server program ends up (for the registry).
  var programPath: String

  enum CodingKeys: String, CodingKey {
    case id, engine, engineName, action, method, version, installedVersion, title, commands, downloads
    case downloadSize, location, needsAdmin, removal, notes, createdAt, expiresAt
  }
}

public enum HFEngineJobState: String, Sendable, Codable {
  case running, succeeded, failed, cancelled
}

/// A running or finished install, update or uninstall, with its live log.
public struct HFEngineJob: Sendable, Encodable {
  public var id: String
  public var planID: String
  public var engine: HFEngineID
  public var action: HFEngineAction
  public var method: HFEngineMethod
  public var title: String
  public var state: HFEngineJobState = .running
  /// Number of log lines so far; `log` holds the most recent ones.
  public var logCount = 0
  public var log: [String] = []
  public var error: String?
  /// Found after the install: where the engine is and its version.
  public var path: String?
  public var version: String?
  public var startedAt: String
  public var finishedAt: String?
  /// What to do if it failed: the command to run yourself.
  public var manualCommand: String?

  static let logLimit = 400

  mutating func append(_ line: String) {
    logCount += 1
    log.append(line)
    if log.count > Self.logLimit { log.removeFirst(log.count - Self.logLimit) }
  }

  /// The log from line number `since` (0-based) on, for live views.
  func log(since: Int) -> (lines: [String], first: Int) {
    let first = logCount - log.count
    let start = max(since, first)
    guard start < logCount else { return ([], logCount) }
    return (Array(log[(start - first)...]), start)
  }
}

/// An engine ModelMatrix installed, so it may later update or remove it.
/// Engines you installed yourself never appear here and are never touched.
public struct HFEngineRecord: Sendable, Codable, Equatable {
  public var engine: String
  public var method: HFEngineMethod
  public var version: String?
  /// The engine's server program.
  public var path: String
  /// What uninstall removes (official installs).
  public var location: String
  public var installedAt: String
}

/// Saved list of engines ModelMatrix installed.
final class HFEngineRegistry: @unchecked Sendable {
  private let file: URL
  private let lock = NSLock()
  private var records: [HFEngineRecord]

  init(file: URL) {
    self.file = file
    records = (try? Data(contentsOf: file)).flatMap { try? HFFiles.decoder.decode([HFEngineRecord].self, from: $0) } ?? []
  }

  func all() -> [HFEngineRecord] {
    lock.lock()
    defer { lock.unlock() }
    return records
  }

  func record(_ engine: HFEngineID) -> HFEngineRecord? {
    all().first { $0.engine == engine.rawValue }
  }

  func set(_ record: HFEngineRecord?, for engine: HFEngineID) {
    lock.lock()
    records.removeAll { $0.engine == engine.rawValue }
    if let record { records.append(record) }
    let snapshot = records
    lock.unlock()
    if let data = try? HFFiles.encoder.encode(snapshot) { try? HFFiles.writeAtomically(data, to: file) }
  }
}

/// Where ModelMatrix keeps the engines it installs.
public enum HFEngineFolders {
  /// `~/ModelMatrix/Engines`, or `MODELMATRIX_ENGINES_DIR` (used by tests).
  public static func root(home: String = NSHomeDirectory()) -> String {
    if let custom = ProcessInfo.processInfo.environment["MODELMATRIX_ENGINES_DIR"], custom.hasPrefix("/") {
      return custom
    }
    return "\(home)/ModelMatrix/Engines"
  }

  /// `MODELMATRIX_IGNORE_HOMEBREW=1` makes ModelMatrix act as if Homebrew
  /// weren't installed (to test the official-build route).
  public static var ignoreHomebrew: Bool {
    ProcessInfo.processInfo.environment["MODELMATRIX_IGNORE_HOMEBREW"] == "1"
  }

  static func llamaBin(_ root: String) -> String { "\(root)/llama.cpp/bin" }
  static func mlxBin(_ root: String) -> String { "\(root)/mlx-lm/venv/bin" }
}

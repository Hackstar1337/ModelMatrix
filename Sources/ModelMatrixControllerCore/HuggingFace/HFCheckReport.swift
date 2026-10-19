import Foundation

/// The answer to "can I run this Hugging Face model here, and which
/// version should I download?". Produced without downloading anything.
public struct HFCheckReport: Sendable, Encodable {
  public var schemaVersion = 1
  public var input: String
  /// "model" (one repository was checked) or "search" (a list to choose from).
  public var kind: String
  public var repo: HFRepoSummary?
  public var format: HFFormatSummary?
  public var task: HFTask?
  public var verdict: HFVerdict
  public var machine: HFMachine
  public var engine: HFEngineSummary?
  public var model: HFModelSummary?
  public var variants: [HFVariantReport] = []
  /// Image adapter that vision GGUF models need next to the main file.
  public var projector: HFFile?
  public var recommendation: HFRecommendation?
  /// Ready-to-run versions of the same model in other repositories.
  public var alternatives: [HFAlternative] = []
  public var searchResults: [HFAlternative] = []
  public var notes: [String] = []
  /// Downloading is a separate, later step; the check never downloads.
  public var downloadAvailable = false
  /// Where this repository's files will be saved once downloading arrives:
  /// ~/ModelMatrix/Models/<owner>/<name>.
  public var downloadFolder: String?
  public var checkedAt: String
}

public struct HFRepoSummary: Sendable, Encodable {
  public var id: String
  public var url: String
  public var revision: String
  public var sha: String?
  public var license: String?
  public var gated: Bool
  public var loginRequired: Bool
  public var downloads: Int?
  public var likes: Int?
  public var library: String?
  public var pipelineTag: String?
  public var baseModel: String?
  public var baseRelation: String?
  public var lastModified: String?
}

public struct HFFormatSummary: Sendable, Encodable {
  public var id: HFFormat
  public var name: String
  public var summary: String
}

/// Overall result. Codes: `ready`, `needs_engine`, `too_big`,
/// `use_alternative`, `not_supported`, `login_required`, `choose_model`,
/// `not_found`.
public struct HFVerdict: Sendable, Encodable, Equatable {
  public var code: String
  public var title: String
  public var detail: String
  /// Whether this repository has a version that can run on this machine.
  public var runnable: Bool
}

public struct HFEngineSummary: Sendable, Encodable {
  public var needed: HFEngineID?
  public var neededName: String?
  public var ready: Bool
  /// Ollama can also run GGUF files, as a backup engine.
  public var backup: HFEngineID?
  public var engines: [HFEngineStatus]
  /// ModelMatrix will offer to install a missing engine after the user
  /// approves; not available in this version, so only advice is shown.
  public var installerAvailable = false
}

public struct HFModelSummary: Sendable, Encodable {
  public var name: String?
  public var architecture: String?
  public var parameters: Int64?
  public var maxContext: Int?
  public var defaultContext: Int
  /// Context length used for the fit numbers below.
  public var context: Int
  /// "gguf_header", "config_json" or "rough".
  public var layoutSource: String
  public var cacheBytesAtContext: Int64
}

public struct HFVariantReport: Sendable, Encodable {
  public var label: String
  public var files: [HFFile]
  public var totalBytes: Int64
  /// Download size including the image adapter, when one is needed.
  public var downloadBytes: Int64
  public var bitsPerWeight: Double?
  public var quality: String
  public var fullPrecision: Bool
  public var supported: Bool
  public var unsupportedReason: String?
  public var fit: HFFit?
  public var longestGoodContext: Int?
  public var fitsOnDisk: Bool?
  public var recommended = false
}

public struct HFRecommendation: Sendable, Encodable {
  public var label: String
  public var context: Int
  public var needBytes: Int64
  public var downloadBytes: Int64
  public var level: String
  public var reason: String
}

public struct HFAlternative: Sendable, Encodable, Equatable {
  public var repo: String
  public var format: String
  public var downloads: Int?
  public var likes: Int?
  public var gated: Bool
  /// The same model converted (true), or a modified version of it, such as
  /// a fine-tune (false). Nil for search results.
  public var sameModel: Bool?
}

enum HFJSON {
  static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return encoder
  }()

  static func data<T: Encodable>(_ value: T) throws -> Data { try encoder.encode(value) }
}

/// A remote host to check for: its measured machine and its engines.
public struct HFCheckTarget: Sendable {
  public var machine: HFMachine
  public var engines: [HFEngineStatus]

  public init(machine: HFMachine, engines: [HFEngineStatus]) {
    self.machine = machine
    self.engines = engines
  }
}

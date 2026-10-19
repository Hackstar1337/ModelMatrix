import Foundation

/// One file of a download.
public struct HFDownloadFile: Codable, Sendable, Equatable {
  /// Path inside the repository, e.g. "Qwen2.5-7B-Instruct-Q8_0.gguf".
  public var path: String
  public var size: Int64
  /// SHA-256 published by Hugging Face (large files). Small files are checked by size.
  public var sha256: String?
  public var bytesDone: Int64 = 0
  public var done = false
  /// "existing" (already on disk and verified) or "copy" (cloned from another download).
  public var reused: String?

  public init(path: String, size: Int64, sha256: String?) {
    self.path = path
    self.size = size
    self.sha256 = sha256
  }
}

/// States: queued, downloading, waiting (network, disk space, rate limit or
/// a retry pause), verifying, paused, completed, failed, cancelled.
public enum HFDownloadState: String, Codable, Sendable {
  case queued, downloading, waiting, verifying, paused, completed, failed, cancelled

  public var isActive: Bool { [.queued, .downloading, .waiting, .verifying].contains(self) }
  public var isFinished: Bool { [.completed, .failed, .cancelled].contains(self) }
}

/// What happens with the model after its files are verified.
public enum HFProfileState: String, Codable, Sendable {
  /// Creating the profile.
  case creating
  /// The profile exists but its engine isn't installed yet.
  case needsEngine = "needs_engine"
  /// The profile exists and was not started (start after download is off).
  case created
  /// Not started: the Mac doesn't have enough free memory right now.
  case needsMemory = "needs_memory"
  case starting
  /// Started and answered the test message.
  case ready
  case startFailed = "start_failed"
}

/// A download, saved in `downloads.json` so it continues after a restart.
public struct HFDownloadJob: Codable, Sendable {
  public var id: String
  /// "files" (ModelMatrix downloads the files) or "ollama" (Ollama pulls the model).
  public var kind: String
  public var repo: String
  /// The exact repository version (commit), so files from two versions can't mix.
  public var revision: String
  /// Version label: "Q4_K_M", "4-bit", ...
  public var label: String
  /// "gguf" or "mlx".
  public var format: String
  /// Engine that will run it: "llama.cpp", "mlx" or "ollama".
  public var engine: String
  public var displayName: String
  /// Absolute folder the files are saved in.
  public var folder: String
  public var files: [HFDownloadFile]
  /// GGUF: the file llama.cpp is pointed at (first part of a split set).
  public var mainFile: String?
  /// Vision GGUF: the image adapter file.
  public var projectorFile: String?
  /// Ollama: the model name Ollama pulls, e.g. "hf.co/owner/name:Q4_K_M".
  public var ollamaModel: String?
  /// Ollama: whether Ollama already had the model before this download.
  /// Such a model is never deleted from Ollama by ModelMatrix.
  public var ollamaHadModel: Bool?
  public var context: Int
  public var parameters: Int64?
  public var vision = false
  /// Start and test the model after the download.
  public var startAfter: Bool
  /// Machine that downloads it: nil for this Mac, otherwise a remote host id.
  public var host: String?
  /// Remote host's name (filled in when listed; not saved on this Mac).
  public var hostName: String?
  /// Login-only model: a resumed download needs the saved token again.
  public var gated: Bool?

  public var state: HFDownloadState = .queued
  /// For `waiting`: "network", "disk", "rate_limit" or "retry".
  public var waitingFor: String?
  public var bytesDone: Int64 = 0
  public var bytesTotal: Int64
  public var speedBytesPerSecond: Int64 = 0
  public var etaSeconds: Int?
  /// A short status line ("Downloading 2 of 3 files", "Waiting for the network").
  public var message: String?
  public var error: String?
  public var attempts = 0
  public var warnings: [String] = []
  /// Set by Cancel with "delete files" while the job is downloading; the
  /// download thread removes finished files too once it stops.
  public var removeFilesOnCancel = false
  public var createdAt: String
  public var updatedAt: String
  public var completedAt: String?

  public var profile: String?
  public var profileState: HFProfileState?
  public var profileMessage: String?
  /// Address apps use once the model is ready (the relay).
  public var readyUrl: String?
  /// Model name apps send once it is ready.
  public var readyModel: String?
  /// Estimated memory the model needs at its context (from the check).
  public var memoryNeedBytes: Int64?
  /// The end of the server log when the model failed to start.
  public var profileLog: [String]?

  public init(
    id: String, kind: String, repo: String, revision: String, label: String, format: String, engine: String,
    displayName: String, folder: String, files: [HFDownloadFile], context: Int, startAfter: Bool
  ) {
    self.id = id
    self.kind = kind
    self.repo = repo
    self.revision = revision
    self.label = label
    self.format = format
    self.engine = engine
    self.displayName = displayName
    self.folder = folder
    self.files = files
    self.context = context
    self.startAfter = startAfter
    self.bytesTotal = files.reduce(0) { $0 + $1.size }
    let now = HFFiles.timestamp()
    self.createdAt = now
    self.updatedAt = now
  }

  public var folderURL: URL { URL(fileURLWithPath: folder, isDirectory: true) }

  public func fileURL(_ file: HFDownloadFile) -> URL {
    folderURL.appendingPathComponent(file.path)
  }

  /// Bytes already on disk, including partial files.
  mutating func recount() {
    bytesDone = files.reduce(0) { $0 + ($1.done ? $1.size : min($1.bytesDone, $1.size)) }
  }

  static func newID() -> String {
    "dl-" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(12)
  }
}

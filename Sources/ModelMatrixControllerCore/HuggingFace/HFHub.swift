import Foundation

/// Everything Hugging Face: check, settings, token, downloads, engine
/// installs and automatic profiles. Data lives in `<controller root>/huggingface/`.
public final class HFHub: @unchecked Sendable {
  public let directory: URL
  public let settings: HFSettingsStore
  public let tokenStore: HFTokenStoring
  public let check: HFCheckService
  public let downloads: HFDownloadManager
  /// Installs engines, only through plans the user approved.
  public let engines: HFEngineInstaller
  /// Creates, starts and tests a profile for each verified download.
  public let profiles: HFProfileManager
  /// Called when an engine was installed, updated or removed.
  public var onEngineChange: (@Sendable (HFEngineJob) -> Void)?
  /// Remote hosts, as the menu bar app reports them (nil: this Mac only).
  public var hostDirectory: HFHostDirectory?
  /// Talks to the ModelMatrix agent on remote hosts.
  public var agent = HFAgentClient()
  let remoteLock = NSLock()
  /// Approve-first engine plans for remote hosts, by plan id.
  var remotePlans: [String: HFRemoteEnginePlan] = [:]
  /// Which host has which download and engine job (by id).
  var downloadHosts: [String: String] = [:]
  var engineJobHosts: [String: String] = [:]

  public init(
    directory: URL, check: HFCheckService, tokenStore: HFTokenStoring = HFKeychainTokenStore(),
    streamer: HFByteStreamer = URLSessionByteStreamer(), network: HFNetworkStatus = HFPathMonitor.shared,
    freeSpace: @escaping @Sendable (URL) -> Int64? = { HFDisk.freeBytes($0) },
    pause: @escaping @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
    ollama: HFOllamaPulling = HFOllamaClient(),
    engineTransport: HFTransport = URLSessionHFTransport(), engineRunner: HFCommandRunning = HFProcessRunner(),
    now: @escaping @Sendable () -> Date = { Date() },
    chat: HFChatTesting = HFChatTester(),
    portFree: @escaping @Sendable (Int) -> Bool = { HFLocalPorts.isFree($0) },
    availableMemory: @escaping @Sendable () -> Int64? = { HFLocalMemory.available() }
  ) {
    self.directory = directory
    let settings = HFSettingsStore(file: directory.appendingPathComponent("settings.json"))
    self.settings = settings
    self.tokenStore = tokenStore
    self.check = check
    let downloads = HFDownloadManager(
      file: directory.appendingPathComponent("downloads.json"), settings: settings, client: check.client,
      streamer: streamer, network: network, freeSpace: freeSpace, pause: pause, ollama: ollama)
    self.downloads = downloads
    self.engines = HFEngineInstaller(
      probe: check.engines, machine: check.machineProbe, registryFile: directory.appendingPathComponent("engines.json"),
      transport: engineTransport, streamer: streamer, runner: engineRunner, now: now)
    let profiles = HFProfileManager(
      downloads: downloads, settings: settings, engines: check.engines, machine: check.machineProbe, chat: chat,
      portFree: portFree, availableMemory: availableMemory, pause: pause, ollamaRemove: { [ollama] model in
        if let client = ollama as? HFOllamaClient { try client.remove(model: model) }
      })
    self.profiles = profiles
    downloads.onCompleted = { [weak profiles] job in profiles?.handle(job) }
    check.modelsFolder = { settings.current.modelsFolderURL }
    check.freeSpace = freeSpace
    check.downloadsEnabled = true
    check.installerEnabled = true
    applySettings(settings.current)
    engines.onFinished = { [weak self] job in
      self?.onEngineChange?(job)
      // A profile waiting for this engine can start now.
      self?.profiles.recheckWaiting()
    }
  }

  /// Starts the download queue (and continues interrupted downloads).
  public func start() {
    downloads.start()
    profiles.resumeAfterRestart()
  }

  // MARK: Settings and token

  func applySettings(_ value: HFSettings) {
    check.client.configure(endpoint: value.endpointURL)
    check.engines.setConfiguredPaths(value.enginePaths)
    let store = tokenStore
    // The Keychain is only touched when a token was saved.
    if value.tokenSaved {
      check.client.setTokenProvider { store.load() }
    } else {
      check.client.setTokenProvider(nil)
    }
  }

  public func updateSettings(_ patch: [String: Any]) throws -> HFSettings {
    let next = try settings.current.applying(patch)
    let saved = try settings.save(next)
    applySettings(saved)
    return saved
  }

  /// Checks the token with Hugging Face, then saves it in the Keychain.
  /// Returns the account name.
  public func saveToken(_ raw: String) throws -> String {
    let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard token.count >= 8, token.count <= 512, token.allSatisfy({ $0.isASCII && !$0.isWhitespace }) else {
      throw HFError.invalidSetting("That doesn't look like a Hugging Face token (they start with hf_).")
    }
    guard let user = try check.client.whoami(token: token) else {
      throw HFError.invalidSetting("Hugging Face didn't accept this token. Create a read token at huggingface.co/settings/tokens.")
    }
    tokenStore.save(token)
    let saved = try settings.update { $0.tokenSaved = true }
    applySettings(saved)
    return user
  }

  public func deleteToken() throws {
    tokenStore.delete()
    let saved = try settings.update { $0.tokenSaved = false }
    applySettings(saved)
  }

  public var settingsPayload: [String: Any] {
    let value = settings.current
    var payload: [String: Any] = [
      "models_folder": value.modelsFolder,
      "models_folder_path": value.modelsFolderURL.path,
      "endpoint": value.endpoint ?? NSNull(),
      "endpoint_in_use": check.client.endpoint.absoluteString,
      "start_after_download": value.startAfterDownload,
      "keep_awake": value.keepAwake,
      "connections_per_file": value.connectionsPerFile,
      "speed_limit_mbps": value.speedLimitMBps,
      "token_saved": value.tokenSaved,
      "engine_paths": value.enginePaths,
    ]
    if let free = HFDisk.freeBytes(value.modelsFolderURL) { payload["free_disk_bytes"] = free }
    return payload
  }

  // MARK: Downloads

  /// What the user asked to download.
  public struct DownloadRequest: Sendable {
    public var name: String
    public var version: String?
    /// "auto", "llama.cpp", "mlx-lm" or "ollama".
    public var engine: String?
    public var context: Int?
    public var startAfter: Bool?
    /// A remote host's id or name; nil for this Mac.
    public var host: String?

    public init(
      name: String, version: String? = nil, engine: String? = nil, context: Int? = nil, startAfter: Bool? = nil,
      host: String? = nil
    ) {
      self.name = name
      self.version = version
      self.engine = engine
      self.context = context
      self.startAfter = startAfter
      self.host = host
    }

    public init(json: [String: Any]) throws {
      guard let name = (json["name"] as? String)?.trimmed, !name.isEmpty else {
        throw HFError.invalidName("Give the model's name, for example bartowski/Qwen2.5-7B-Instruct-GGUF.")
      }
      self.name = name
      version = (json["version"] as? String)?.trimmed.nilIfEmpty
      engine = (json["engine"] as? String)?.trimmed.nilIfEmpty
      host = (json["host"] as? String)?.trimmed.nilIfEmpty
      if let raw = json["context"], !(raw is NSNull) {
        guard let number = (raw as? NSNumber)?.intValue, HFCheckService.contextRange.contains(number) else {
          throw HFError.invalidName("Context must be between 512 and 1048576 tokens.")
        }
        context = number
      }
      if let raw = json["start_after"], !(raw is NSNull) {
        guard let flag = raw as? Bool else { throw HFError.invalidName("start_after must be true or false.") }
        startAfter = flag
      }
    }
  }

  /// Checks the model again, picks the version, and queues the download.
  /// Returns the job and whether it was already in the list.
  public func startDownload(_ request: DownloadRequest) throws -> (job: HFDownloadJob, existing: Bool) {
    var request = request
    // "owner/name:Q4_K_M" names a version just like --version does.
    if request.version == nil, case .repo(let reference)? = try? HFQuery.parse(request.name, extraHost: check.client.mirrorHost) {
      request.version = reference.variant
    }
    if let host = try remoteHost(request.host) { return try startRemoteDownload(request, host: host) }
    let report = try check.check(request.name, context: request.context, version: request.version)
    let job = try plan(report, request: request)
    if let existing = downloads.existing(repo: job.repo, label: job.label, host: job.host, kind: job.kind) {
      return (existing, true)
    }
    return (try downloads.add(job), false)
  }

  /// Turns a check into a download job, refusing anything that can't run here.
  public func plan(_ report: HFCheckReport, request: DownloadRequest) throws -> HFDownloadJob {
    guard report.kind == "model", let repo = report.repo, let format = report.format else {
      if report.verdict.code == "not_found" { throw HFError.notFound(request.name) }
      throw HFError.refused("Pick one model first: \(report.verdict.detail)")
    }
    if report.verdict.code == "login_required" { throw HFError.loginRequired(repo.id) }
    guard format.id == .gguf || format.id == .mlx else {
      if !report.alternatives.isEmpty {
        let names = report.alternatives.prefix(3).map(\.repo).joined(separator: ", ")
        let why = report.verdict.detail.components(separatedBy: " Check one of").first ?? report.verdict.detail
        throw HFError.refused("\(why) Ready-to-run versions: \(names). Check one with: modelmatrixctl check <owner/name>")
      }
      throw HFError.refused("\(report.verdict.title). \(report.verdict.detail)")
    }
    if format.id == .mlx, !report.machine.appleSilicon {
      throw HFError.refused("MLX models run only on Apple Silicon Macs. Choose a GGUF version instead.")
    }
    let wanted = request.version ?? report.recommendation?.label
    guard let label = wanted else {
      throw HFError.refused("\(report.verdict.title). \(report.verdict.detail)")
    }
    guard
      let variant = report.variants.first(where: { $0.label.caseInsensitiveCompare(label) == .orderedSame })
        ?? report.variants.first(where: {
          $0.label.uppercased().replacingOccurrences(of: "UD-", with: "") == label.uppercased()
        })
    else {
      let names = report.variants.filter(\.supported).map(\.label).joined(separator: ", ")
      throw HFError.refused("\(repo.id) has no version named \(label). Versions: \(names).")
    }
    guard variant.supported else {
      throw HFError.refused("\(variant.label) can't be used: \(variant.unsupportedReason ?? "not supported").")
    }
    let recommended = report.recommendation?.label == variant.label ? report.recommendation : nil
    let fitLevel = recommended?.level ?? variant.fit?.level
    if fitLevel == "too_big" {
      throw HFError.refused(
        "\(variant.label) is too big for the \(HFCheckService.gb(report.machine.budgetBytes)) this machine can give a model. Choose a smaller version.")
    }

    // Engine.
    let engines = report.engine?.engines ?? []
    let choice = (request.engine ?? "auto").lowercased()
    let engine: HFEngineID
    switch (format.id, choice) {
    case (.gguf, "auto"), (.gguf, "llama.cpp"), (.gguf, "llamacpp"): engine = .llamaCpp
    case (.gguf, "ollama"): engine = .ollama
    case (.mlx, "auto"), (.mlx, "mlx"), (.mlx, "mlx-lm"): engine = .mlxLM
    default:
      throw HFError.refused("\(format.name) models can't run with \(choice). Use auto, llama.cpp, mlx-lm or ollama.")
    }
    let isSplit = variant.files.count > 1
    if engine == .ollama {
      guard engines.first(where: { $0.id == .ollama })?.installed == true else {
        throw HFError.refused("Ollama isn't installed. Install it, or download with llama.cpp instead.")
      }
      if isSplit { throw HFError.refused("Ollama can't download GGUF versions split into several files. Use llama.cpp.") }
    }

    // Files and folder.
    let current = settings.current
    let remote = report.machine.isRemote
    let base = remote ? URL(fileURLWithPath: report.machine.modelsFolder, isDirectory: true) : current.modelsFolderURL
    let folder = base.appendingPathComponent(repo.id, isDirectory: true)
    var files = variant.files.map { HFDownloadFile(path: $0.path, size: $0.size, sha256: $0.sha256) }
    if engine != .ollama, format.id == .gguf, let projector = report.projector {
      files.append(HFDownloadFile(path: projector.path, size: projector.size, sha256: projector.sha256))
    }
    for file in files {
      let parts = file.path.split(separator: "/")
      guard !file.path.hasPrefix("/"), !parts.contains(where: { $0 == ".." || $0 == "." }) else {
        throw HFError.badResponse("unsafe file name \(file.path)")
      }
    }
    let total = files.reduce(Int64(0)) { $0 + $1.size }
    if engine != .ollama {
      if !remote, HFDisk.fileSystem(folder) == "msdos", files.contains(where: { $0.size >= 4 * 1024 * 1024 * 1024 }) {
        throw HFError.refused(
          "The drive for \(folder.path) uses FAT32, which can't hold files over 4 GB. Choose a models folder on another drive in Settings.")
      }
      let free = (remote ? report.machine.freeDiskBytes : downloads.freeSpace(folder)) ?? Int64.max
      let needed = total + HFDownloadManager.minimumFreeBytes
      if free < needed {
        throw HFError.insufficientDisk(
          "Not enough disk space: \(variant.label) needs \(HFCheckService.gb(needed)) free (download plus 2 GB to spare), and \(HFCheckService.gb(free)) is available.")
      }
    }

    let context = recommended?.context ?? variant.fit?.context ?? report.model?.context ?? 8192
    let name = repo.id.split(separator: "/").last.map(String.init) ?? repo.id
    var job = HFDownloadJob(
      id: HFDownloadJob.newID(), kind: engine == .ollama ? "ollama" : "files", repo: repo.id,
      revision: repo.sha ?? repo.revision, label: variant.label, format: format.id.rawValue, engine: engine.rawValue,
      displayName: "\(name) \(variant.label)", folder: folder.path, files: engine == .ollama ? [] : files,
      context: context, startAfter: request.startAfter ?? current.startAfterDownload)
    if engine == .ollama {
      job.ollamaModel = "hf.co/\(repo.id):\(variant.label)"
      job.bytesTotal = variant.downloadBytes
      job.folder = ""
    }
    job.host = report.machine.host
    job.gated = repo.gated
    job.parameters = report.model?.parameters
    job.memoryNeedBytes = recommended?.needBytes ?? variant.fit?.needBytes
    job.vision = report.projector != nil
    if format.id == .gguf {
      job.mainFile = variant.files.map(\.path).sorted().first
      job.projectorFile = engine == .ollama ? nil : report.projector?.path
    }
    if fitLevel == "tight" {
      job.warnings.append("\(variant.label) fits this machine's memory only tightly; close other apps if it runs slowly.")
    }
    if report.engine?.engines.first(where: { $0.id == engine })?.installed != true {
      job.warnings.append(HFProfileMaker.engineMissingWarning(engine.displayName))
    }
    return job
  }
}

extension String {
  var nilIfEmpty: String? { isEmpty ? nil : self }
}

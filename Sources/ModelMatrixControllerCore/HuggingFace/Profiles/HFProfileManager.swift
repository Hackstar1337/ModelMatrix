import Foundation

/// A model on disk that ModelMatrix downloaded.
public struct HFDownloadedModel: Sendable, Encodable {
  public var id: String
  public var repo: String
  public var label: String
  public var format: String
  public var engine: String
  public var kind: String
  public var displayName: String
  public var folder: String
  public var files: [String]
  /// Bytes the files use on disk now.
  public var bytesOnDisk: Int64
  public var missingFiles: Int
  public var profile: String?
  public var profileState: String?
  public var profileMessage: String?
  public var readyModel: String?
  public var readyUrl: String?
  public var completedAt: String?
  /// Remote host id and name (nil for this Mac).
  public var host: String?
  public var hostName: String?
}

/// Folders in the models folder that no download in the list owns.
public struct HFUntrackedFolder: Sendable, Encodable {
  public var folder: String
  public var bytesOnDisk: Int64
}

/// Turns verified downloads into working profiles: creates the profile,
/// waits for a missing engine, starts the model and sends it a test message.
public final class HFProfileManager: @unchecked Sendable {
  let downloads: HFDownloadManager
  let settings: HFSettingsStore
  let engines: HFEngineProbe
  let machine: @Sendable () -> HFMachine
  let chat: HFChatTesting
  let portFree: @Sendable (Int) -> Bool
  let availableMemory: @Sendable () -> Int64?
  let physicalCores: Int
  let pause: @Sendable (TimeInterval) -> Void
  let ollamaRemove: @Sendable (String) throws -> Void
  /// Profile steps run one at a time, in order.
  let queue = DispatchQueue(label: "ModelMatrix profiles")

  private let lock = NSLock()
  private var hostStorage: HFProfileHosting?
  private var relayStorage: @Sendable () -> URL? = { nil }

  /// The controller's profiles. Nil (tests, one-shot commands) turns the step off.
  public var host: HFProfileHosting? {
    get { lock.withLock { hostStorage } }
    set { lock.withLock { hostStorage = newValue } }
  }

  /// The relay address apps use (nil when the relay is off).
  public var relayURL: @Sendable () -> URL? {
    get { lock.withLock { relayStorage } }
    set { lock.withLock { relayStorage = newValue } }
  }

  /// How long the test message may take (the first answer loads the model).
  var chatTimeout: TimeInterval = 120
  /// Attempts while the relay picks up the new server.
  var chatAttempts = 8

  public init(
    downloads: HFDownloadManager, settings: HFSettingsStore, engines: HFEngineProbe,
    machine: @escaping @Sendable () -> HFMachine,
    chat: HFChatTesting = HFChatTester(),
    portFree: @escaping @Sendable (Int) -> Bool = { HFLocalPorts.isFree($0) },
    availableMemory: @escaping @Sendable () -> Int64? = { HFLocalMemory.available() },
    physicalCores: Int = HFLocalMemory.physicalCores(),
    pause: @escaping @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
    ollamaRemove: @escaping @Sendable (String) throws -> Void = { try HFOllamaClient().remove(model: $0) }
  ) {
    self.downloads = downloads
    self.settings = settings
    self.engines = engines
    self.machine = machine
    self.chat = chat
    self.portFree = portFree
    self.availableMemory = availableMemory
    self.physicalCores = physicalCores
    self.pause = pause
    self.ollamaRemove = ollamaRemove
  }

  // MARK: Entry points

  /// Called when a download has been verified.
  public func handle(_ job: HFDownloadJob) {
    guard host != nil else { return }
    let id = job.id
    queue.async { [weak self] in self?.process(id, start: nil) }
  }

  /// Runs the profile step again: creates the profile if needed and starts
  /// and tests the model (the Start / Try again button).
  public func start(_ id: String) throws -> HFDownloadJob {
    guard let job = downloads.job(id) else { throw HFError.unknownItem("No download with id \(id).") }
    guard job.state == .completed else {
      throw HFError.conflict("The download hasn't finished yet (\(job.state.rawValue)).")
    }
    guard host != nil else { throw HFError.unavailable("Profiles can only be created by the running controller.") }
    if [.creating, .starting].contains(job.profileState) {
      throw HFError.conflict("This model is already being set up.")
    }
    let updated =
      downloads.update(id) {
        $0.profileState = .starting
        $0.profileMessage = "Starting"
        $0.profileLog = nil
      } ?? job
    queue.async { [weak self] in self?.process(id, start: true) }
    return updated
  }

  /// An engine was installed or removed, or the user pressed Check again:
  /// waiting profiles get the engine and start.
  public func recheckWaiting() {
    guard host != nil else { return }
    queue.async { [weak self] in
      guard let self else { return }
      self.engines.refresh()
      for job in self.downloads.list() where job.state == .completed && job.profileState == .needsEngine {
        self.process(job.id, start: nil)
      }
    }
  }

  /// After a controller restart: a model that was starting is shown as
  /// created (the user starts it again); waiting ones are checked again.
  public func resumeAfterRestart() {
    for job in downloads.list() where job.state == .completed && job.profile != nil && job.profileState == nil {
      downloads.update(job.id) {
        $0.profileState = .created
        $0.profileMessage = "Profile \(job.profile ?? "") is ready to start."
      }
    }
    recheckWaiting()
  }

  // MARK: The profile step

  func process(_ id: String, start explicit: Bool?) {
    guard let host, let job = downloads.job(id), job.state == .completed else { return }
    if job.kind == "ollama" {
      testOllama(job)
      return
    }
    let engineID = HFEngineID(rawValue: job.engine) ?? (job.format == "mlx" ? .mlxLM : .llamaCpp)
    let machine = machine()
    let engine = engines.detect(machine: machine).first { $0.id == engineID }
    let enginePath = engine?.installed == true ? engine?.path : nil

    var profiles = host.allProfiles()
    var name = job.profile.flatMap { profiles[$0] != nil ? $0 : nil }
    if name == nil {
      downloads.update(id) {
        $0.profileState = .creating
        $0.profileMessage = "Creating the profile"
      }
      do {
        name = try create(job, host: host, profiles: profiles, enginePath: enginePath, machine: machine)
        profiles = host.allProfiles()
      } catch {
        fail(id, message: "Couldn't create the profile: \(Self.describe(error))", log: [])
        return
      }
    }
    guard let name, var values = profiles[name] else { return }

    // Give the profile the engine (it may have been installed since).
    if let enginePath, values["SERVER_BIN"] != enginePath {
      values["SERVER_BIN"] = enginePath
      try? host.updateProfile(name: name, values: values)
    }
    guard enginePath != nil else {
      downloads.update(id) {
        $0.profileState = .needsEngine
        $0.profileMessage =
          "Needs \(engineID.displayName). Install it in Settings → Engines or with: modelmatrixctl engine install \(engineID.rawValue)"
      }
      return
    }
    // The engine is here now, so the "not installed yet" warning no longer applies.
    let staleWarning = HFProfileMaker.engineMissingWarning(engineID.displayName)
    if job.warnings.contains(staleWarning) {
      downloads.update(id) { $0.warnings.removeAll { $0 == staleWarning } }
    }
    let shouldStart = explicit ?? job.startAfter
    guard shouldStart else {
      downloads.update(id) {
        $0.profileState = .created
        $0.profileMessage = "Profile \(name) created. Start it from Models & Servers."
      }
      return
    }
    // Starting a model that doesn't fit in free memory makes the Mac swap.
    if machine.kind == "mac", let need = job.memoryNeedBytes, let free = availableMemory(), need > free,
      explicit != true
    {
      downloads.update(id) {
        $0.profileState = .needsMemory
        $0.profileMessage =
          "Needs about \(HFCheckService.gb(need)) of free memory and \(HFCheckService.gb(free)) is free now. Use Optimize, then start it."
      }
      return
    }
    startAndTest(id, name: name, values: values, engine: engineID, host: host)
  }

  /// Writes the new profile and records it on the job. Returns its name.
  func create(
    _ job: HFDownloadJob, host: HFProfileHosting, profiles: [String: [String: String]], enginePath: String?,
    machine: HFMachine
  ) throws -> String {
    let modelName = HFProfileMaker.modelName(
      repo: job.repo, label: job.label, taken: HFProfileMaker.modelNames(in: profiles))
    let name = HFProfileMaker.profileName(repo: job.repo, label: job.label, existing: Set(profiles.keys))
    guard let port = HFProfileMaker.pickPort(profiles: profiles, isFree: portFree) else {
      throw HFError.unavailable("No free port between 8081 and 8999.")
    }
    let inputs = HFProfileMaker.Inputs(
      job: job, profileName: name, modelName: modelName, port: port, enginePath: enginePath,
      accelerator: machine.accelerator, physicalCores: physicalCores,
      resolvedFolder: HFLocalMemory.realPath(job.folder))
    try host.createProfile(name: name, values: HFProfileMaker.values(inputs))
    downloads.update(id: job.id, profile: name, model: modelName)
    return name
  }

  func startAndTest(_ id: String, name: String, values: [String: String], engine: HFEngineID, host: HFProfileHosting) {
    let model = values["REQUEST_MODEL"] ?? name
    downloads.update(id) {
      $0.profileState = .starting
      $0.profileMessage = "Starting \(model)"
      $0.profileLog = nil
    }
    do {
      try host.startProfile(name)
    } catch {
      let tail = host.logTail(name, lines: 15)
      // When the server never wrote a log, show why the start itself failed.
      let log = tail.isEmpty ? [Self.describe(error)] : tail
      let hint = HFProfileMaker.suggestion(log: tail + [Self.describe(error)], engine: engine.rawValue, port: values["PORT"])
      fail(id, message: "\(model) didn't start. \(hint)", log: log)
      return
    }
    downloads.update(id) { $0.profileMessage = "Sending a test message to \(model)" }
    let relay = relayURL()
    let direct = values["BASE_URL"].flatMap { URL(string: $0) }
    guard let base = relay ?? direct else {
      fail(id, message: "\(model) started, but the profile has no address to test.", log: [])
      return
    }
    // Without the relay, MLX must get the name it reserves for its model.
    let sentName = relay == nil ? (values["UPSTREAM_MODEL"] ?? model) : model
    switch sendTest(base: base, model: sentName) {
    case .success:
      downloads.update(id) {
        $0.profileState = .ready
        $0.readyUrl = base.absoluteString
        $0.readyModel = model
        $0.profileMessage = "Ready: use model \(model) at \(base.absoluteString)"
        $0.profileLog = nil
      }
    case .failure(let message):
      let log = host.logTail(name, lines: 15)
      fail(id, message: "\(model) started, but the test message failed: \(message)", log: log)
    }
  }

  enum TestResult {
    case success
    case failure(String)
  }

  func sendTest(base: URL, model: String) -> TestResult {
    var last = "no answer"
    for attempt in 1...max(1, chatAttempts) {
      do {
        _ = try chat.send(baseURL: base, model: model, timeout: chatTimeout)
        return .success
      } catch let error as HFChatTestError {
        last = error.message
        guard error.retryable, attempt < chatAttempts else { break }
      } catch {
        last = Self.describe(error)
        break
      }
      pause(2)
    }
    return .failure(last)
  }

  func testOllama(_ job: HFDownloadJob) {
    guard let model = job.ollamaModel else { return }
    downloads.update(job.id) {
      $0.profileState = .starting
      $0.profileMessage = "Sending a test message to \(model)"
    }
    let base = relayURL() ?? HFOllamaClient.environmentURL().appendingPathComponent("v1")
    switch sendTest(base: base, model: model) {
    case .success:
      downloads.update(job.id) {
        $0.profileState = .ready
        $0.readyUrl = base.absoluteString
        $0.readyModel = model
        $0.profileMessage = "Ready in Ollama: use model \(model) at \(base.absoluteString)"
      }
    case .failure(let message):
      fail(job.id, message: "Ollama has the model, but the test message failed: \(message)", log: [])
    }
  }

  func fail(_ id: String, message: String, log: [String]) {
    downloads.update(id) {
      $0.profileState = .startFailed
      $0.profileMessage = message
      $0.profileLog = log.isEmpty ? nil : log
    }
  }

  static func describe(_ error: Error) -> String {
    if let error = error as? HFError { return error.description }
    if let error = error as? ControllerError { return error.description }
    return error.localizedDescription
  }

  // MARK: Downloaded models

  public func downloadedModels() -> (models: [HFDownloadedModel], untracked: [HFUntrackedFolder]) {
    let profiles = host?.allProfiles() ?? [:]
    var models: [HFDownloadedModel] = []
    var owned = Set<String>()
    for job in downloads.list() where job.state == .completed {
      var bytes: Int64 = 0
      var missing = 0
      for file in job.files {
        let url = job.fileURL(file)
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber {
          bytes += size.int64Value
        } else {
          missing += 1
        }
      }
      if !job.folder.isEmpty { owned.insert(URL(fileURLWithPath: job.folder).standardizedFileURL.path) }
      let profile = job.profile.flatMap { profiles[$0] != nil ? $0 : nil }
      models.append(
        HFDownloadedModel(
          id: job.id, repo: job.repo, label: job.label, format: job.format, engine: job.engine, kind: job.kind,
          displayName: job.displayName, folder: job.folder, files: job.files.map(\.path),
          bytesOnDisk: job.kind == "ollama" ? job.bytesTotal : bytes, missingFiles: missing, profile: profile,
          profileState: job.profileState?.rawValue, profileMessage: job.profileMessage, readyModel: job.readyModel,
          readyUrl: job.readyUrl, completedAt: job.completedAt))
    }
    // owner/name folders in the models folder that no download owns.
    var untracked: [HFUntrackedFolder] = []
    let root = settings.current.modelsFolderURL
    let manager = FileManager.default
    for owner in (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? [] {
      guard (try? owner.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
        !owner.lastPathComponent.hasPrefix(".")
      else { continue }
      for repo in (try? manager.contentsOfDirectory(at: owner, includingPropertiesForKeys: [.isDirectoryKey])) ?? [] {
        guard (try? repo.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
        let path = repo.standardizedFileURL.path
        if owned.contains(path) { continue }
        untracked.append(HFUntrackedFolder(folder: path, bytesOnDisk: HFDisk.usage(repo)))
      }
    }
    return (models, untracked)
  }

  // MARK: Deleting

  /// Deletes a downloaded model's profile and, if asked, its files. Files
  /// another download still uses (a shared image adapter) are kept, and so
  /// is an Ollama model that Ollama already had before this download.
  @discardableResult
  public func delete(_ id: String, deleteFiles: Bool) throws -> (
    profile: String?, freedBytes: Int64, keptInOllama: Bool
  ) {
    guard let job = downloads.job(id) else { throw HFError.unknownItem("No download with id \(id).") }
    guard !job.state.isActive, job.state != .paused else {
      throw HFError.conflict("Cancel the download first.")
    }
    if [.creating, .starting].contains(job.profileState) {
      throw HFError.conflict("Wait until the model has finished starting.")
    }
    var removedProfile: String?
    if let name = job.profile, let host, host.allProfiles()[name] != nil {
      try host.deleteProfile(name)
      removedProfile = name
    }
    var freed: Int64 = 0
    var kept = false
    if deleteFiles {
      if job.kind == "ollama", let model = job.ollamaModel {
        if job.ollamaHadModel == true {
          kept = true
        } else {
          try ollamaRemove(model)
          freed = job.bytesTotal
        }
      } else {
        freed = removeFiles(of: job)
      }
    }
    try downloads.remove(id)
    return (removedProfile, freed, kept)
  }

  /// Removes the job's files (and its leftover part files) unless another
  /// download in the list uses the same file. Returns the bytes freed.
  func removeFiles(of job: HFDownloadJob) -> Int64 {
    guard !job.folder.isEmpty else { return 0 }
    let manager = FileManager.default
    let others = downloads.list().filter { $0.id != job.id && ![.cancelled, .failed].contains($0.state) }
    var freed: Int64 = 0
    for file in job.files {
      let url = job.fileURL(file).standardizedFileURL
      let shared = others.contains { other in
        other.files.contains { other.fileURL($0).standardizedFileURL.path == url.path }
      }
      if shared { continue }
      if let size = (try? manager.attributesOfItem(atPath: url.path))?[.size] as? NSNumber {
        freed += size.int64Value
      }
      try? manager.removeItem(at: url)
      HFFileTransfer.removePartial(for: url)
    }
    // Remove folders left empty (split sets live in subfolders), up to the models folder.
    let stop = settings.current.modelsFolderURL
    let folders = Set(job.files.map { job.fileURL($0).deletingLastPathComponent().standardizedFileURL.path })
    for folder in folders.sorted(by: { $0.count > $1.count }) {
      HFDownloadManager.removeEmptyFolders(from: URL(fileURLWithPath: folder, isDirectory: true), stopAt: stop)
    }
    HFDownloadManager.removeEmptyFolders(from: job.folderURL, stopAt: stop)
    return freed
  }
}

extension HFDownloadManager {
  /// Records the profile and the model name on a job.
  @discardableResult
  func update(id: String, profile: String, model: String) -> HFDownloadJob? {
    update(id) {
      $0.profile = profile
      $0.readyModel = model
    }
  }
}

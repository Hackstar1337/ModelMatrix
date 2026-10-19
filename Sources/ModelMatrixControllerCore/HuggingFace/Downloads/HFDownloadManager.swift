import Foundation

/// The download queue. Jobs are saved in `downloads.json` and continue after
/// a restart. One job downloads at a time; large files use several
/// connections. Every file is checked against its SHA-256 before use.
public final class HFDownloadManager: @unchecked Sendable {
  public static let minimumFreeBytes: Int64 = 2 * 1024 * 1024 * 1024
  static let maxAttempts = 10

  public let file: URL
  let settings: HFSettingsStore
  let client: HFClient
  let streamer: HFByteStreamer
  let network: HFNetworkStatus
  let freeSpace: @Sendable (URL) -> Int64?
  let pause: @Sendable (TimeInterval) -> Void
  let ollama: HFOllamaPulling
  let limiter = HFRateLimiter(bytesPerSecond: 0)
  /// Files from this size on download in several pieces (smaller in tests).
  var pieceThreshold = HFFileTransfer.defaultPieceThreshold
  var minimumPiece = HFFileTransfer.defaultMinimumPiece
  let sleepGuard = HFSleepGuard()

  let lock = NSLock()
  private let wake = DispatchSemaphore(value: 0)
  var jobs: [String: HFDownloadJob] = [:]
  var order: [String] = []
  var stopFlags: [String: HFFlag] = [:]
  var running: String?
  /// Cancelled while running: the files to tidy once the thread lets go.
  /// Kept apart from the list so removing the entry can't skip the cleanup.
  var pendingCleanup: [String: (job: HFDownloadJob, deleteFinished: Bool)] = [:]
  private var started = false
  private var lastSave = Date.distantPast
  /// Called on the download thread once a job's files are verified (Stage 4:
  /// profile creation). It may call `update(_:)`.
  public var onCompleted: (@Sendable (HFDownloadJob) -> Void)?
  /// Called whenever a job changes (for status revision bumps).
  public var onChange: (@Sendable () -> Void)?

  public init(
    file: URL, settings: HFSettingsStore, client: HFClient, streamer: HFByteStreamer = URLSessionByteStreamer(),
    network: HFNetworkStatus = HFPathMonitor.shared,
    freeSpace: @escaping @Sendable (URL) -> Int64? = { HFDisk.freeBytes($0) },
    pause: @escaping @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
    ollama: HFOllamaPulling = HFOllamaClient()
  ) {
    self.file = file
    self.settings = settings
    self.client = client
    self.streamer = streamer
    self.network = network
    self.freeSpace = freeSpace
    self.pause = pause
    self.ollama = ollama
  }

  // MARK: Lifecycle

  /// Loads saved jobs and starts the download thread. Jobs that were running
  /// when the controller stopped continue where they left off.
  public func start() {
    lock.lock()
    guard !started else {
      lock.unlock()
      return
    }
    started = true
    if let data = try? Data(contentsOf: file),
      let saved = try? HFFiles.decoder.decode([HFDownloadJob].self, from: data)
    {
      for var job in saved {
        if [.downloading, .verifying, .waiting].contains(job.state) {
          job.state = .queued
          job.waitingFor = nil
          job.message = "Continuing after a restart"
        }
        if job.profileState == .starting || job.profileState == .creating {
          job.profileState = nil
        }
        jobs[job.id] = job
        order.append(job.id)
      }
    }
    lock.unlock()
    // A cancel that the controller couldn't finish tidying before it stopped.
    for job in list() where job.state == .cancelled && job.removeFilesOnCancel {
      removeFiles(of: job, finishedToo: true)
      update(job.id) { $0.removeFilesOnCancel = false }
    }
    let thread = Thread { [weak self] in self?.workLoop() }
    thread.name = "ModelMatrix downloads"
    thread.qualityOfService = .utility
    thread.start()
    // Finished downloads whose profile step didn't complete (controller
    // stopped in between) pick it up again.
    for job in list() where job.state == .completed && job.profileState == nil && job.profile == nil {
      DispatchQueue.global(qos: .utility).async { [weak self] in self?.onCompleted?(job) }
    }
  }

  // MARK: Queries

  public func list() -> [HFDownloadJob] {
    lock.lock()
    defer { lock.unlock() }
    return order.compactMap { jobs[$0] }
  }

  public func job(_ id: String) -> HFDownloadJob? {
    lock.lock()
    defer { lock.unlock() }
    return jobs[id]
  }

  public var hasActiveDownloads: Bool {
    list().contains { $0.state.isActive }
  }

  /// A matching job that hasn't failed or been cancelled (to avoid duplicates).
  public func existing(repo: String, label: String, host: String?, kind: String) -> HFDownloadJob? {
    list().last {
      $0.repo.lowercased() == repo.lowercased() && $0.label == label && $0.host == host && $0.kind == kind
        && ![.failed, .cancelled].contains($0.state)
    }
  }

  // MARK: Changes

  /// Adds a job to the queue.
  @discardableResult
  public func add(_ job: HFDownloadJob) throws -> HFDownloadJob {
    lock.lock()
    jobs[job.id] = job
    order.append(job.id)
    lock.unlock()
    persist(force: true)
    wake.signal()
    return job
  }

  /// Changes a job and saves it.
  @discardableResult
  public func update(_ id: String, force: Bool = true, _ change: (inout HFDownloadJob) -> Void) -> HFDownloadJob? {
    lock.lock()
    guard var job = jobs[id] else {
      lock.unlock()
      return nil
    }
    change(&job)
    job.updatedAt = HFFiles.timestamp()
    jobs[id] = job
    lock.unlock()
    persist(force: force)
    return job
  }

  public func pause(_ id: String) throws -> HFDownloadJob {
    guard let job = job(id) else { throw HFError.unknownItem("No download with id \(id).") }
    guard job.state.isActive else {
      throw HFError.conflict("This download is \(job.state.rawValue) and can't be paused.")
    }
    stopFlag(id).set()
    return update(id) {
      $0.state = .paused
      $0.waitingFor = nil
      $0.speedBytesPerSecond = 0
      $0.etaSeconds = nil
      $0.message = "Paused"
    } ?? job
  }

  public func resume(_ id: String) throws -> HFDownloadJob {
    guard let job = job(id) else { throw HFError.unknownItem("No download with id \(id).") }
    guard [.paused, .failed].contains(job.state) else {
      throw HFError.conflict("This download is \(job.state.rawValue); only paused or failed downloads can be resumed.")
    }
    let updated =
      update(id) {
        $0.state = .queued
        $0.error = nil
        $0.attempts = 0
        $0.message = "Waiting to continue"
      } ?? job
    wake.signal()
    return updated
  }

  /// Stops a download and removes its unfinished files. With `deleteFiles`,
  /// files it already finished are removed too.
  public func cancel(_ id: String, deleteFiles: Bool) throws -> HFDownloadJob {
    guard let job = job(id) else { throw HFError.unknownItem("No download with id \(id).") }
    if job.state == .completed && !deleteFiles {
      throw HFError.conflict("This download already finished. Delete the model instead.")
    }
    stopFlag(id).set()
    let updated =
      update(id) {
        $0.state = .cancelled
        $0.speedBytesPerSecond = 0
        $0.etaSeconds = nil
        $0.waitingFor = nil
        $0.message = deleteFiles ? "Cancelled; files deleted" : "Cancelled"
      } ?? job
    // A running job is tidied by the download thread once it has stopped
    // writing; any other job right now.
    lock.lock()
    let busy = running == id
    if busy { pendingCleanup[id] = (updated, deleteFiles) }
    lock.unlock()
    if busy {
      if deleteFiles { update(id) { $0.removeFilesOnCancel = true } }
    } else {
      removeFiles(of: updated, finishedToo: deleteFiles)
    }
    return updated
  }

  /// Removes a finished, failed or cancelled job from the list (files stay).
  public func remove(_ id: String) throws {
    guard let job = job(id) else { throw HFError.unknownItem("No download with id \(id).") }
    guard !job.state.isActive, job.state != .paused else {
      throw HFError.conflict("Pause or cancel the download before removing it from the list.")
    }
    lock.lock()
    jobs[id] = nil
    order.removeAll { $0 == id }
    lock.unlock()
    persist(force: true)
  }

  func isRunning(_ id: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return running == id
  }

  func stopFlag(_ id: String) -> HFFlag {
    lock.lock()
    defer { lock.unlock() }
    if let flag = stopFlags[id] { return flag }
    let flag = HFFlag()
    stopFlags[id] = flag
    return flag
  }

  func clearStopFlag(_ id: String) {
    lock.lock()
    stopFlags[id] = nil
    lock.unlock()
  }

  func removeFiles(of job: HFDownloadJob, finishedToo: Bool) {
    guard !job.folder.isEmpty else { return }
    for file in job.files {
      let destination = job.fileURL(file)
      HFFileTransfer.removePartial(for: destination)
      if finishedToo, file.done || file.reused != nil { try? FileManager.default.removeItem(at: destination) }
    }
    if finishedToo { HFDownloadManager.removeEmptyFolders(from: job.folderURL, stopAt: settings.current.modelsFolderURL) }
  }

  /// Removes `folder` and its empty parents up to (not including) `stopAt`.
  static func removeEmptyFolders(from folder: URL, stopAt: URL) {
    var current = folder.standardizedFileURL
    let limit = stopAt.standardizedFileURL.path
    while current.path.hasPrefix(limit + "/") {
      let contents = (try? FileManager.default.contentsOfDirectory(atPath: current.path)) ?? ["?"]
      guard contents.allSatisfy({ $0 == ".DS_Store" }) else { return }
      try? FileManager.default.removeItem(at: current)
      current = current.deletingLastPathComponent()
    }
  }

  func persist(force: Bool) {
    lock.lock()
    if !force, Date().timeIntervalSince(lastSave) < 2 {
      lock.unlock()
      return
    }
    lastSave = Date()
    let snapshot = order.compactMap { jobs[$0] }
    lock.unlock()
    if let data = try? HFFiles.encoder.encode(snapshot) { try? HFFiles.writeAtomically(data, to: file) }
    // Progress ticks don't notify; state changes do.
    if force { onChange?() }
  }

  // MARK: Download thread

  private func workLoop() {
    while true {
      guard let id = nextQueued() else {
        sleepGuard.hold(false)
        _ = wake.wait(timeout: .now() + 30)
        continue
      }
      sleepGuard.hold(settings.current.keepAwake)
      lock.lock()
      running = id
      lock.unlock()
      clearStopFlag(id)
      process(id)
      lock.lock()
      running = nil
      lock.unlock()
      finishStopped(id)
    }
  }

  func nextQueued() -> String? {
    lock.lock()
    defer { lock.unlock() }
    return order.first { jobs[$0]?.state == .queued }
  }

  /// After the thread lets go of a job: tidy up a cancel (even when the
  /// entry was removed from the list meanwhile).
  func finishStopped(_ id: String) {
    lock.lock()
    let pending = pendingCleanup.removeValue(forKey: id)
    lock.unlock()
    guard let pending else { return }
    removeFiles(of: pending.job, finishedToo: pending.deleteFinished)
    update(id) { $0.removeFilesOnCancel = false }
  }

  /// Runs the queue until it is empty (tests).
  func runQueueForTesting() {
    while let id = nextQueued() {
      lock.lock()
      running = id
      lock.unlock()
      clearStopFlag(id)
      process(id)
      lock.lock()
      running = nil
      lock.unlock()
      finishStopped(id)
    }
  }
}

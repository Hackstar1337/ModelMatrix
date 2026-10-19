import Foundation

extension HFDownloadManager {
  /// Downloads every file of a job, or hands it to Ollama.
  func process(_ id: String) {
    guard let job = job(id), job.state == .queued else { return }
    let stop = stopFlag(id)
    update(id) {
      $0.state = .downloading
      $0.error = nil
      $0.message = "Starting"
    }
    if job.kind == "ollama" {
      runOllama(id, stop: stop)
      return
    }
    do {
      try FileManager.default.createDirectory(at: job.folderURL, withIntermediateDirectories: true)
    } catch {
      fail(id, "Can't create the folder \(job.folder): \(error.localizedDescription)")
      return
    }
    let total = job.files.count
    for (index, file) in job.files.enumerated() where !file.done {
      guard stillRunning(id, stop) else { return }
      update(id) { $0.message = total > 1 ? "File \(index + 1) of \(total): \(file.path)" : "Downloading \(file.path)" }
      guard downloadFile(id, index: index, stop: stop) else { return }
    }
    guard stillRunning(id, stop) else { return }
    let finished = update(id) {
      $0.state = .completed
      $0.completedAt = HFFiles.timestamp()
      $0.speedBytesPerSecond = 0
      $0.etaSeconds = 0
      $0.waitingFor = nil
      $0.recount()
      $0.message = "Downloaded and verified"
    }
    if let finished { onCompleted?(finished) }
  }

  func stillRunning(_ id: String, _ stop: HFFlag) -> Bool {
    !stop.isSet && job(id)?.state.isActive == true
  }

  func fail(_ id: String, _ message: String) {
    update(id) {
      $0.state = .failed
      $0.error = message
      $0.message = "Failed"
      $0.speedBytesPerSecond = 0
      $0.etaSeconds = nil
      $0.waitingFor = nil
    }
  }

  /// Waits `seconds`, in short steps so pause and cancel stay responsive.
  /// Returns false when the job was stopped meanwhile.
  func wait(_ seconds: TimeInterval, _ id: String, _ stop: HFFlag) -> Bool {
    var left = seconds
    while left > 0 {
      guard stillRunning(id, stop) else { return false }
      let step = min(left, 1)
      pause(step)
      left -= step
    }
    return stillRunning(id, stop)
  }

  func waiting(_ id: String, _ reason: String, _ message: String) {
    update(id) {
      $0.state = .waiting
      $0.waitingFor = reason
      $0.message = message
      $0.speedBytesPerSecond = 0
      $0.etaSeconds = nil
    }
  }

  func resumeDownloading(_ id: String) {
    update(id) {
      if $0.state == .waiting {
        $0.state = .downloading
        $0.waitingFor = nil
      }
    }
  }

  // MARK: One file

  /// Returns true when the file is in place and verified.
  private func downloadFile(_ id: String, index: Int, stop: HFFlag) -> Bool {
    guard let job = job(id) else { return false }
    let file = job.files[index]
    let destination = job.fileURL(file)
    if let reuse = reuse(file, at: destination, job: job, stop: stop) {
      markDone(id, index: index, reused: reuse)
      return true
    }
    guard stillRunning(id, stop) else { return false }
    var damaged = 0
    let meter = HFSpeedMeter()
    while true {
      guard waitForDisk(id, stop: stop), waitForNetwork(id, stop: stop) else { return false }
      guard let job = self.job(id) else { return false }
      let before = job.files[index].bytesDone
      let transfer = makeTransfer(job: job, file: file, destination: destination, stop: stop) { [weak self] done in
        self?.progress(id, index: index, done: done, meter: meter)
      }
      do {
        try transfer.run()
      } catch let failure as HFTransferError {
        if transfer.bytesDone > before { update(id) { $0.attempts = 0 } }
        guard handle(failure, id: id, destination: destination, stop: stop) else { return false }
        continue
      } catch {
        fail(id, error.localizedDescription)
        return false
      }
      guard stillRunning(id, stop) else { return false }
      switch verify(id, file: file, part: HFFileTransfer.partURL(for: destination), stop: stop) {
      case .stopped:
        return false
      case .damaged:
        damaged += 1
        HFFileTransfer.removePartial(for: destination)
        update(id) { $0.files[index].bytesDone = 0; $0.recount() }
        if damaged >= 2 {
          fail(id, "\(file.path) arrived damaged twice (its checksum didn't match). Try again later.")
          return false
        }
        update(id) { $0.message = "\(file.path) arrived damaged; downloading it again" }
        continue
      case .good:
        do {
          try place(HFFileTransfer.partURL(for: destination), at: destination)
        } catch {
          fail(id, "Can't save \(file.path): \(error.localizedDescription)")
          return false
        }
        markDone(id, index: index, reused: nil)
        return true
      }
    }
  }

  private func makeTransfer(
    job: HFDownloadJob, file: HFDownloadFile, destination: URL, stop: HFFlag,
    progress: @escaping @Sendable (Int64) -> Void
  ) -> HFFileTransfer {
    let resolve = client.url(path: client.resolvePath(
      HFRepoReference(owner: job.ownerName.owner, name: job.ownerName.name, revision: nil),
      revision: job.revision, file: file.path), query: [])!
    var headers = ["User-Agent": "ModelMatrix/\(ControllerVersion.current)", "Accept-Encoding": "identity"]
    if let auth = client.authorization(for: resolve) { headers["Authorization"] = auth }
    let current = settings.current
    limiter.setLimit(bytesPerSecond: current.speedLimitMBps * 1_000_000)
    return HFFileTransfer(
      url: resolve, headers: headers, file: file, revision: job.revision,
      partURL: HFFileTransfer.partURL(for: destination), connections: current.connectionsPerFile,
      streamer: streamer, limiter: limiter, apiHost: client.endpoint.host ?? "huggingface.co",
      pieceThreshold: pieceThreshold, minimumPiece: minimumPiece,
      shouldStop: { [weak self] in stop.isSet || self?.job(job.id)?.state.isActive != true },
      onProgress: progress)
  }

  private func progress(_ id: String, index: Int, done: Int64, meter: HFSpeedMeter) {
    var total: Int64 = 0
    var size: Int64 = 0
    lock.lock()
    if var job = jobs[id] {
      job.files[index].bytesDone = done
      job.recount()
      total = job.bytesDone
      size = job.bytesTotal
      jobs[id] = job
    }
    lock.unlock()
    let speed = meter.add(total)
    update(id, force: false) {
      if $0.state == .waiting {
        $0.state = .downloading
        $0.waitingFor = nil
      }
      $0.speedBytesPerSecond = speed
      $0.etaSeconds = speed > 0 ? Int((size - total) / speed) : nil
    }
  }

  /// Decides what a failed transfer means. Returns true to try again.
  private func handle(_ failure: HFTransferError, id: String, destination: URL, stop: HFFlag) -> Bool {
    switch failure {
    case .stopped:
      return false
    case .loginRequired:
      fail(id, "This model needs a Hugging Face login. Add a token in Settings, accept the model's license on huggingface.co, then resume.")
      return false
    case .notFound:
      fail(id, "A file is no longer on Hugging Face. Check the model again and download the current version.")
      return false
    case .disk(let detail):
      if let free = freeSpace(job(id)?.folderURL ?? destination), free < Self.minimumFreeBytes {
        return waitForDisk(id, stop: stop)
      }
      fail(id, "Can't write to the disk: \(detail)")
      return false
    case .restart(let reason):
      HFFileTransfer.removePartial(for: destination)
      return retry(id, stop: stop, reason: "Starting the file again (\(reason))")
    case .rateLimited(let seconds):
      let delay = TimeInterval(min(max(seconds ?? 60, 5), 900))
      waiting(id, "rate_limit", "Hugging Face asked to slow down; continuing in \(Int(delay)) seconds")
      guard wait(delay, id, stop) else { return false }
      resumeDownloading(id)
      return true
    case .expired:
      // Every attempt asks Hugging Face for a fresh link.
      return retry(id, stop: stop, reason: "The download link expired; getting a new one", quick: true)
    case .network(let detail):
      if !network.isAvailable { return waitForNetwork(id, stop: stop) }
      return retry(id, stop: stop, reason: "Connection problem (\(detail)); trying again")
    case .http(let status):
      return retry(id, stop: stop, reason: "Hugging Face answered with HTTP \(status); trying again")
    }
  }

  /// Retries with growing pauses (1, 2, 4 ... up to 60 seconds); gives up
  /// after `maxAttempts` attempts in a row without progress.
  private func retry(_ id: String, stop: HFFlag, reason: String, quick: Bool = false) -> Bool {
    guard let job = update(id, { $0.attempts += 1 }) else { return false }
    if job.attempts > Self.maxAttempts {
      fail(id, "Gave up after \(Self.maxAttempts) attempts. Last problem: \(reason). Press Resume to try again.")
      return false
    }
    let delay = quick ? 0 : min(60, pow(2, Double(job.attempts - 1)))
    waiting(id, "retry", delay > 0 ? "\(reason) in \(Int(delay)) seconds" : reason)
    guard wait(delay, id, stop) else { return false }
    resumeDownloading(id)
    return true
  }

  /// Waits while there is no network connection.
  func waitForNetwork(_ id: String, stop: HFFlag) -> Bool {
    guard !network.isAvailable else { return true }
    waiting(id, "network", "Waiting for the network to come back")
    while !network.isAvailable {
      guard wait(2, id, stop) else { return false }
    }
    resumeDownloading(id)
    return true
  }

  /// Waits while the disk is too full: the rest of the download plus 2 GB
  /// must fit.
  func waitForDisk(_ id: String, stop: HFFlag) -> Bool {
    var announced = false
    while true {
      guard let job = job(id) else { return false }
      let needed = max(0, job.bytesTotal - job.bytesDone) + Self.minimumFreeBytes
      guard let free = freeSpace(job.folderURL), free < needed else {
        if announced { resumeDownloading(id) }
        return true
      }
      if !announced {
        waiting(
          id, "disk",
          "Waiting for disk space: needs \(HFCheckService.gb(needed)) free, \(HFCheckService.gb(free)) available")
        announced = true
      }
      guard wait(10, id, stop) else { return false }
    }
  }

  // MARK: Checks and reuse

  enum Verification { case good, damaged, stopped }

  private func verify(_ id: String, file: HFDownloadFile, part: URL, stop: HFFlag) -> Verification {
    let size = (try? FileManager.default.attributesOfItem(atPath: part.path)[.size] as? NSNumber)?.int64Value ?? -1
    guard size == file.size else { return .damaged }
    guard let expected = file.sha256?.lowercased() else { return .good }
    update(id) {
      $0.state = .verifying
      $0.message = "Checking \(file.path)"
    }
    defer { update(id) { if $0.state == .verifying { $0.state = .downloading } } }
    do {
      guard let actual = try HFHash.sha256(part, shouldStop: { stop.isSet }) else { return .stopped }
      return actual == expected ? .good : .damaged
    } catch {
      return .damaged
    }
  }

  /// A verified copy already at `destination`, or the same file (by SHA-256)
  /// from another download, which is cloned instantly instead of downloaded.
  private func reuse(_ file: HFDownloadFile, at destination: URL, job: HFDownloadJob, stop: HFFlag) -> String? {
    let manager = FileManager.default
    if manager.fileExists(atPath: destination.path), Self.size(of: destination) == file.size {
      if let expected = file.sha256 {
        update(job.id) { $0.message = "Checking the copy of \(file.path) already on disk" }
        if (try? HFHash.sha256(destination, shouldStop: { stop.isSet })) == expected.lowercased() {
          return "existing"
        }
      } else {
        return "existing"
      }
    }
    guard let expected = file.sha256?.lowercased() else { return nil }
    for other in list() where other.id != job.id && other.state == .completed {
      for candidate in other.files where candidate.sha256?.lowercased() == expected {
        let source = other.fileURL(candidate)
        guard Self.size(of: source) == file.size else { continue }
        if (try? HFDisk.cloneOrCopy(source, to: destination)) != nil { return "copy" }
      }
    }
    return nil
  }

  private func markDone(_ id: String, index: Int, reused: String?) {
    let destination = job(id).map { $0.fileURL($0.files[index]) }
    if let destination { HFFileTransfer.removePartial(for: destination) }
    update(id) {
      $0.files[index].done = true
      $0.files[index].bytesDone = $0.files[index].size
      $0.files[index].reused = reused
      $0.attempts = 0
      if $0.state == .verifying { $0.state = .downloading }
      $0.recount()
    }
  }

  private func place(_ part: URL, at destination: URL) throws {
    let manager = FileManager.default
    try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
    try manager.moveItem(at: part, to: destination)
  }

  static func size(of url: URL) -> Int64 {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? -1
  }

  // MARK: Ollama

  private func runOllama(_ id: String, stop: HFFlag) {
    guard let job = job(id), let model = job.ollamaModel else {
      fail(id, "No Ollama model name.")
      return
    }
    if job.ollamaHadModel == nil, let had = ollama.hasModel(model) {
      update(id) { $0.ollamaHadModel = had }
    }
    let meter = HFSpeedMeter()
    while true {
      do {
        update(id) { $0.message = "Ollama is downloading \(model)" }
        try ollama.pull(
          model: model,
          progress: { [weak self] status, completed, total in
            guard let self else { return }
            let speed = meter.add(completed)
            self.update(id, force: false) {
              if total > 0 {
                $0.bytesTotal = max($0.bytesTotal, total)
                $0.bytesDone = completed
              }
              $0.speedBytesPerSecond = speed
              $0.etaSeconds = speed > 0 && total > completed ? Int((total - completed) / speed) : nil
              if !status.isEmpty { $0.message = "Ollama: \(status)" }
            }
          }, shouldStop: { [weak self] in stop.isSet || self?.job(id)?.state.isActive != true })
        break
      } catch HFOllamaError.stopped {
        return
      } catch HFOllamaError.notRunning {
        fail(id, "Ollama isn't running. Open Ollama, then press Resume.")
        return
      } catch HFOllamaError.failed(let message) {
        if !network.isAvailable {
          guard waitForNetwork(id, stop: stop) else { return }
          continue
        }
        guard retry(id, stop: stop, reason: "Ollama: \(message)") else { return }
      } catch {
        fail(id, error.localizedDescription)
        return
      }
    }
    guard stillRunning(id, stop) else { return }
    let finished = update(id) {
      $0.state = .completed
      $0.completedAt = HFFiles.timestamp()
      $0.bytesDone = $0.bytesTotal
      $0.speedBytesPerSecond = 0
      $0.etaSeconds = 0
      $0.message = "Downloaded by Ollama"
    }
    if let finished { onCompleted?(finished) }
  }
}

extension HFDownloadJob {
  var ownerName: (owner: String, name: String) {
    let parts = repo.split(separator: "/", maxSplits: 1).map(String.init)
    return (parts.first ?? repo, parts.count > 1 ? parts[1] : repo)
  }
}

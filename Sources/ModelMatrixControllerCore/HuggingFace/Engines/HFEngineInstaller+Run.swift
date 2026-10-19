import Foundation

extension HFEngineInstaller {
  /// Carries out an approved plan once. Refused for unknown, used or
  /// expired plan IDs, and while another engine job is running.
  public func run(planID: String) throws -> HFEngineJob {
    lock.lock()
    guard let plan = plans.removeValue(forKey: planID) else {
      lock.unlock()
      throw HFError.unknownItem("This install plan isn't valid any more (it was used, or it never existed). Create a new plan.")
    }
    guard plan.expires > now() else {
      lock.unlock()
      throw HFError.conflict("This install plan expired (plans are valid for 10 minutes). Create a new plan.")
    }
    if let busy = jobOrder.compactMap({ jobs[$0] }).first(where: { $0.state == .running }) {
      plans[planID] = plan
      lock.unlock()
      throw HFError.conflict("\(busy.title) is still running. Wait for it to finish.")
    }
    let job = HFEngineJob(
      id: "eng-" + Self.randomHex(6), planID: plan.id, engine: plan.engine, action: plan.action, method: plan.method,
      title: plan.title, startedAt: HFFiles.timestamp(now()))
    jobs[job.id] = job
    jobOrder.insert(job.id, at: 0)
    if jobOrder.count > 30, let last = jobOrder.popLast() { jobs[last] = nil }
    let flag = HFFlag()
    stopFlags[job.id] = flag
    lock.unlock()
    let thread = Thread { [self] in execute(plan, jobID: job.id, stop: flag) }
    thread.name = "ModelMatrix engine install"
    thread.start()
    return job
  }

  public func job(_ id: String) -> HFEngineJob? {
    lock.lock()
    defer { lock.unlock() }
    return jobs[id]
  }

  public func jobList() -> [HFEngineJob] {
    lock.lock()
    defer { lock.unlock() }
    return jobOrder.compactMap { jobs[$0] }
  }

  public func cancel(_ id: String) throws -> HFEngineJob {
    lock.lock()
    guard let job = jobs[id] else {
      lock.unlock()
      throw HFError.unknownItem("No engine job with id \(id).")
    }
    let flag = stopFlags[id]
    lock.unlock()
    guard job.state == .running else { throw HFError.conflict("This engine job already finished.") }
    flag?.set()
    return job
  }

  /// Waits until the job finishes (tests and the CLI's --wait).
  public func wait(_ id: String, timeout: TimeInterval) -> HFEngineJob? {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if let job = job(id), job.state != .running { return job }
      Thread.sleep(forTimeInterval: 0.05)
    }
    return job(id)
  }

  func log(_ id: String, _ line: String) {
    let clean = String(line.unicodeScalars.filter { $0 == "\t" || $0.value >= 32 }.prefix(2000))
    lock.lock()
    jobs[id]?.append(clean)
    lock.unlock()
  }

  func updateJob(_ id: String, _ change: (inout HFEngineJob) -> Void) {
    lock.lock()
    if var job = jobs[id] {
      change(&job)
      jobs[id] = job
    }
    lock.unlock()
  }

  // MARK: Running the steps

  func execute(_ plan: HFEnginePlan, jobID: String, stop: HFFlag) {
    log(jobID, "\(plan.title)")
    do {
      for step in plan.steps {
        if stop.isSet { throw HFTransferError.stopped }
        try perform(step, jobID: jobID, stop: stop)
      }
      if stop.isSet { throw HFTransferError.stopped }
      try finish(plan, jobID: jobID)
    } catch HFTransferError.stopped {
      log(jobID, "Stopped. Nothing more was changed.")
      updateJob(jobID) {
        $0.state = .cancelled
        $0.finishedAt = HFFiles.timestamp(now())
      }
    } catch {
      let message = (error as? HFError)?.description ?? "\(error)"
      log(jobID, "Failed: \(message)")
      updateJob(jobID) {
        $0.state = .failed
        $0.error = message
        $0.finishedAt = HFFiles.timestamp(now())
        $0.manualCommand = plan.commands.first.map { _ in plan.commands.joined(separator: " && ") } ?? plan.downloads.first?.url
      }
    }
    lock.lock()
    stopFlags[jobID] = nil
    let finished = jobs[jobID]
    lock.unlock()
    probe.refresh()
    if let finished { onFinished?(finished) }
  }

  func perform(_ step: HFEngineStep, jobID: String, stop: HFFlag) throws {
    switch step {
    case .run(let program, let arguments, let environment):
      log(jobID, "$ \(Self.shown(program)) \(arguments.joined(separator: " "))")
      let status = try runner.run(
        program, arguments, environment: environment, output: { [self] in log(jobID, $0) }, shouldStop: { stop.isSet })
      if stop.isSet { throw HFTransferError.stopped }
      guard status == 0 else {
        throw HFError.unavailable("\((program as NSString).lastPathComponent) \(arguments.first ?? "") stopped with exit status \(status).")
      }
    case .unpack(let download, let folder, let keep, let name, let linkBin):
      try requireInsideRoot(folder)
      let incoming = URL(fileURLWithPath: folder).appendingPathComponent(".incoming-\(jobID)")
      defer { try? FileManager.default.removeItem(at: incoming) }
      try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
      let archive = incoming.appendingPathComponent(download.name)
      log(jobID, "Downloading \(download.name) (\(Self.size(download.size))) from \(URL(string: download.url)?.host ?? "GitHub")")
      try fetcher.fetch(download, to: archive, log: { [self] in log(jobID, $0) }, shouldStop: { stop.isSet })
      let unpacked = incoming.appendingPathComponent("files")
      try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
      log(jobID, "Unpacking")
      let status = try runner.run(
        "/usr/bin/tar", ["-xzf", archive.path, "-C", unpacked.path], environment: ["PATH": "/usr/bin:/bin"],
        output: { [self] in log(jobID, $0) }, shouldStop: { stop.isSet })
      guard status == 0 else { throw HFError.unavailable("Unpacking \(download.name) failed (tar exit status \(status)).") }
      let top = unpacked.appendingPathComponent(keep)
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: top.path, isDirectory: &isDirectory), isDirectory.boolValue else {
        throw HFError.unavailable("\(download.name) didn't contain the expected folder \(keep).")
      }
      let target = URL(fileURLWithPath: folder).appendingPathComponent(name)
      try? FileManager.default.removeItem(at: target)
      try FileManager.default.moveItem(at: top, to: target)
      if linkBin {
        let link = URL(fileURLWithPath: folder).appendingPathComponent("bin")
        let staged = URL(fileURLWithPath: folder).appendingPathComponent(".bin-\(jobID)")
        try? FileManager.default.removeItem(at: staged)
        try FileManager.default.createSymbolicLink(atPath: staged.path, withDestinationPath: name)
        // rename() replaces the old link in one step.
        guard rename(staged.path, link.path) == 0 else {
          throw HFError.unavailable("Couldn't switch \(link.path) to the new build.")
        }
      }
      log(jobID, "Installed into \(target.path)")
    case .placeApp(let download, let app, let destination):
      let parent = (destination as NSString).deletingLastPathComponent
      guard destination.hasPrefix(home + "/Applications/"), !FileManager.default.fileExists(atPath: destination) else {
        throw HFError.refused("\(destination) already exists or isn't in your Applications folder.")
      }
      try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
      let incoming = URL(fileURLWithPath: root).appendingPathComponent("ollama/.incoming-\(jobID)")
      defer { try? FileManager.default.removeItem(at: incoming) }
      try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
      let archive = incoming.appendingPathComponent(download.name)
      log(jobID, "Downloading \(download.name) (\(Self.size(download.size))) from \(URL(string: download.url)?.host ?? "GitHub")")
      try fetcher.fetch(download, to: archive, log: { [self] in log(jobID, $0) }, shouldStop: { stop.isSet })
      log(jobID, "Unpacking")
      let unpacked = incoming.appendingPathComponent("files")
      let status = try runner.run(
        "/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path], environment: ["PATH": "/usr/bin:/bin"],
        output: { [self] in log(jobID, $0) }, shouldStop: { stop.isSet })
      guard status == 0 else { throw HFError.unavailable("Unpacking \(download.name) failed (ditto exit status \(status)).") }
      let bundle = unpacked.appendingPathComponent(app)
      guard FileManager.default.fileExists(atPath: bundle.appendingPathComponent("Contents/Info.plist").path) else {
        throw HFError.unavailable("\(download.name) didn't contain \(app).")
      }
      try FileManager.default.moveItem(at: bundle, to: URL(fileURLWithPath: destination))
      log(jobID, "Installed \(destination)")
    case .remove(let path, let toTrash):
      try requireRemovable(path)
      guard FileManager.default.fileExists(atPath: path) else { return }
      if toTrash {
        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
        log(jobID, "Moved \(path) to the Trash")
      } else {
        try FileManager.default.removeItem(atPath: path)
        log(jobID, "Deleted \(path)")
      }
    }
  }

  /// Installs and deletions stay inside the engines folder.
  func requireInsideRoot(_ path: String) throws {
    let clean = URL(fileURLWithPath: path).standardizedFileURL.path
    guard clean.hasPrefix(URL(fileURLWithPath: root).standardizedFileURL.path + "/") else {
      throw HFError.refused("ModelMatrix only changes files inside \(root).")
    }
  }

  /// Deletion is allowed inside the engines folder, or for an app bundle
  /// ModelMatrix itself placed in ~/Applications.
  func requireRemovable(_ path: String) throws {
    if let record = registry.all().first(where: { $0.location == path }), record.method == .official,
      path.hasPrefix(home + "/Applications/"), path.hasSuffix(".app")
    {
      return
    }
    try requireInsideRoot(path)
  }

  func finish(_ plan: HFEnginePlan, jobID: String) throws {
    probe.refresh()
    let status = probe.detect(machine: machine()).first { $0.id == plan.engine }
    switch plan.action {
    case .install, .update:
      guard let status, status.installed, let path = status.path else {
        throw HFError.unavailable("The install finished, but \(plan.engine.executable) wasn't found afterwards.")
      }
      let version = plan.method == .official && plan.engine == .llamaCpp ? (plan.version ?? status.version) : status.version
      registry.set(
        HFEngineRecord(
          engine: plan.engine.rawValue, method: plan.method, version: version, path: path,
          location: plan.method == .homebrew ? path : plan.location, installedAt: HFFiles.timestamp(now())),
        for: plan.engine)
      let versionText = version.map { " \($0)" } ?? ""
      log(jobID, "Done: \(plan.engine.displayName)\(versionText) at \(path)")
      updateJob(jobID) {
        $0.state = .succeeded
        $0.path = path
        $0.version = version
        $0.finishedAt = HFFiles.timestamp(now())
      }
    case .uninstall:
      registry.set(nil, for: plan.engine)
      log(jobID, "Done: \(plan.engine.displayName) was removed")
      updateJob(jobID) {
        $0.state = .succeeded
        $0.finishedAt = HFFiles.timestamp(now())
      }
    }
  }

  static func shown(_ program: String) -> String {
    let name = (program as NSString).lastPathComponent
    return ["brew", "uv"].contains(name) ? name : program
  }
}

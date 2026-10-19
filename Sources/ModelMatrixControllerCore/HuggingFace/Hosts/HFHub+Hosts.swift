import Foundation

/// Remote hosts: the same check, download, engine install and automatic
/// profile steps, carried out by the ModelMatrix agent on the host. The
/// host downloads straight from Hugging Face (or the mirror in Settings)
/// and from GitHub; nothing passes through this Mac.
extension HFHub {
  /// The host named `query`, or nil for this Mac.
  public func remoteHost(_ query: String?) throws -> HFRemoteHost? {
    let text = (query ?? "").trimmingCharacters(in: .whitespaces)
    guard let directory = hostDirectory else {
      if HFBridgeHostDirectory.localNames.contains(text.lowercased()) { return nil }
      throw HFError.unavailable("Remote hosts aren't available in this controller.")
    }
    return try directory.resolve(text)
  }

  /// The host's machine and engines, as its agent measures them now.
  public func hostTarget(_ host: HFRemoteHost) throws -> HFCheckTarget {
    let answer = try agent.get(host, "/api/hf/host")
    guard let facts = answer["machine"] as? [String: Any] else {
      throw HFError.badResponse("\(host.name) sent no machine details.")
    }
    let machine = try HFMachine.remote(facts, host: host)
    return HFCheckTarget(
      machine: machine, engines: HFRemoteEngines.statuses(answer["engines"] as? [[String: Any]] ?? [], machine: machine))
  }

  /// Checks a model for this Mac (`host` nil) or for a remote host.
  public func check(_ input: String, context: Int? = nil, version: String? = nil, host: String?) throws -> HFCheckReport {
    guard let remote = try remoteHost(host) else { return try check.check(input, context: context, version: version) }
    return try check.check(input, context: context, version: version, target: try hostTarget(remote))
  }

  // MARK: Downloads on a host

  func startRemoteDownload(_ request: DownloadRequest, host: HFRemoteHost) throws -> (job: HFDownloadJob, existing: Bool) {
    let report = try check.check(
      request.name, context: request.context, version: request.version, target: try hostTarget(host))
    let job = try plan(report, request: request)
    if let existing = try remoteDownloads(host).last(where: {
      $0.repo.lowercased() == job.repo.lowercased() && $0.label == job.label && $0.kind == job.kind
        && ![.failed, .cancelled].contains($0.state)
    }) {
      return (existing, true)
    }
    let encoded = try JSONSerialization.jsonObject(with: try HFJSON.data(job))
    var body: [String: Any] = [
      "job": encoded, "folder_name": job.repo, "endpoint": check.client.endpoint.absoluteString,
      // Same names a download on this Mac would get; the host keeps them unique.
      "profile_name": HFProfileMaker.slug(
        "\(HFProfileMaker.baseModelName(repo: job.repo))-\(job.label)", fallback: "hf-model", limit: 60),
      "model_name": HFProfileMaker.baseModelName(repo: job.repo),
    ]
    // The token goes to the host only for login-only models, and the host
    // keeps it in memory only for that download.
    if job.gated == true, let token = check.client.token() { body["token"] = token }
    let answer = try agent.post(host, "/api/hf/downloads", body)
    return (try Self.remoteJob(answer["download"], host: host), false)
  }

  /// Downloads on one host.
  public func remoteDownloads(_ host: HFRemoteHost, timeout: TimeInterval = 20) throws -> [HFDownloadJob] {
    let answer = try agent.get(host, "/api/hf/downloads", timeout: timeout)
    let jobs = try (answer["downloads"] as? [Any] ?? []).map { try Self.remoteJob($0, host: host) }
    rememberDownloads(jobs.map(\.id), host: host)
    return jobs
  }

  /// Downloads on this Mac and every reachable host. Hosts that can't be
  /// reached are listed by name in `unreachable`.
  public func allDownloads() -> (downloads: [HFDownloadJob], unreachable: [String]) {
    var list = downloads.list()
    var unreachable: [String] = []
    for host in (hostDirectory?.hosts() ?? []) where host.enabled {
      do {
        list += try remoteDownloads(host, timeout: 6)
      } catch {
        unreachable.append(host.name)
      }
    }
    return (list, unreachable)
  }

  /// Which host has the download `id`: nil when it is on this Mac.
  public func downloadHost(_ id: String, hint: String?) throws -> HFRemoteHost? {
    if let host = try remoteHost(hint) { return host }
    if downloads.job(id) != nil { return nil }
    let hosts = (hostDirectory?.hosts() ?? []).filter(\.enabled)
    if let known = knownDownloadHost(id), let host = hosts.first(where: { $0.id == known }) { return host }
    for host in hosts where (try? remoteDownloads(host, timeout: 6))?.contains(where: { $0.id == id }) == true {
      return host
    }
    throw HFError.unknownItem("No download with id \(id).")
  }

  /// pause, resume, cancel or start on a host.
  public func remoteDownloadAction(_ id: String, action: String, deleteFiles: Bool = false, host: HFRemoteHost) throws
    -> HFDownloadJob
  {
    var body: [String: Any] = ["id": id, "action": action, "delete_files": deleteFiles]
    if action == "resume", let token = check.client.token(),
      (try? remoteDownloads(host))?.first(where: { $0.id == id })?.gated == true
    {
      body["token"] = token
    }
    let answer = try agent.post(host, "/api/hf/downloads/action", body)
    return try Self.remoteJob(answer["download"], host: host)
  }

  /// Deletes a finished download on a host: its profile, and its files too
  /// with `deleteFiles`. Returns whether Ollama kept the model.
  public func remoteDelete(_ id: String, deleteFiles: Bool, host: HFRemoteHost) throws -> (job: HFDownloadJob?, keptInOllama: Bool) {
    let job = try remoteDownloads(host).first { $0.id == id }
    let answer = try agent.post(host, "/api/hf/downloads/action", ["id": id, "action": "delete", "delete_files": deleteFiles])
    forgetDownload(id)
    return (job, answer["kept_in_ollama"] as? Bool ?? false)
  }

  /// A finished download on a host, in the Downloaded models list's shape.
  static func remoteModel(_ job: HFDownloadJob) -> HFDownloadedModel {
    let done = job.files.filter(\.done)
    var model = HFDownloadedModel(
      id: job.id, repo: job.repo, label: job.label, format: job.format, engine: job.engine, kind: job.kind,
      displayName: job.displayName, folder: job.folder, files: job.files.map(\.path),
      bytesOnDisk: job.kind == "ollama" ? job.bytesTotal : done.reduce(0) { $0 + $1.size },
      missingFiles: job.files.count - done.count, profile: job.profile, profileState: job.profileState?.rawValue,
      profileMessage: job.profileMessage, readyModel: job.readyModel, readyUrl: job.readyUrl, completedAt: job.completedAt)
    model.host = job.host
    model.hostName = job.hostName
    return model
  }

  static func remoteJob(_ object: Any?, host: HFRemoteHost) throws -> HFDownloadJob {
    guard let object, JSONSerialization.isValidJSONObject(object) else {
      throw HFError.badResponse("\(host.name) sent no download details.")
    }
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    do {
      var job = try decoder.decode(HFDownloadJob.self, from: try JSONSerialization.data(withJSONObject: object))
      job.host = host.id
      job.hostName = host.name
      job.readyUrl = reachableURL(job.readyUrl, host: host)
      return job
    } catch {
      throw HFError.badResponse("\(host.name) sent download details ModelMatrix can't read (\(error)).")
    }
  }

  /// The host reports addresses as it sees them ("http://127.0.0.1:8766/v1").
  /// Swap a loopback or any-address host for the one this Mac uses to reach
  /// it, keeping the port and path. Tunnelled hosts (loopback base) stay as is.
  static func reachableURL(_ raw: String?, host: HFRemoteHost) -> String? {
    guard let raw, var parts = URLComponents(string: raw), let reported = parts.host?.lowercased(),
      let base = URLComponents(string: host.baseURL), let reach = base.host, !reach.isEmpty
    else { return raw }
    let local = ["127.0.0.1", "localhost", "::1", "[::1]", "0.0.0.0", "::", "[::]"]
    guard local.contains(reported), !local.contains(reach.lowercased()) else { return raw }
    parts.host = reach
    return parts.string ?? raw
  }

  // MARK: Engines on a host

  /// Engines on the host, with what ModelMatrix can do, and recent jobs.
  public func remoteEngines(_ host: HFRemoteHost) throws -> (target: HFCheckTarget, jobs: [HFEngineJob]) {
    let target = try hostTarget(host)
    let answer = try agent.get(host, "/api/hf/engines")
    let jobs = (answer["jobs"] as? [[String: Any]] ?? []).map { Self.remoteEngineJob($0) }
    rememberEngineJobs(jobs.map(\.id), host: host)
    return (target, jobs)
  }

  /// Describes installing, updating or removing llama.cpp on a host and
  /// returns the plan with a one-time ID. Nothing changes on the host.
  public func remoteEnginePlan(_ engine: HFEngineID, action: HFEngineAction, host: HFRemoteHost) throws -> HFEnginePlan {
    switch engine {
    case .mlxLM: throw HFError.refused("MLX runs only on Apple Silicon Macs, so it can't be installed on \(host.name).")
    case .ollama:
      throw HFError.refused(
        "ModelMatrix doesn't install Ollama on Linux hosts: its installer sets up a system service and needs an administrator password. To install it, run this on \(host.name): curl -fsSL https://ollama.com/install.sh | sh")
    case .llamaCpp: break
    }
    let target = try hostTarget(host)
    let machine = target.machine
    guard let status = target.engines.first(where: { $0.id == .llamaCpp }) else {
      throw HFError.badResponse("\(host.name) didn't report its engines.")
    }
    let folder = "\(machine.enginesFolder ?? "~/ModelMatrix/Engines")/llama.cpp"
    var plan = engines.newPlan(
      .llamaCpp, action: action, method: .official, title: "", programPath: "\(folder)/bin/llama-server",
      location: "\(folder) on \(host.name)", steps: [])
    plan.installedVersion = status.version
    var payload: [String: Any] = ["engine": "llama.cpp", "job_id": "eng-" + HFEngineInstaller.randomHex(8)]
    switch action {
    case .install, .update:
      if action == .install, status.installed {
        let place = status.path.map { " at \($0)" } ?? ""
        throw HFError.conflict("llama.cpp is already installed on \(host.name)\(place)\(status.version.map { " (version \($0))" } ?? "").")
      }
      if action == .update, status.managed != true {
        throw HFError.refused(
          status.installed
            ? "llama.cpp on \(host.name) was installed by you, not by ModelMatrix, so ModelMatrix leaves it alone. Update it the way it was installed."
            : "llama.cpp isn't installed on \(host.name).")
      }
      guard let build = HFLinuxBuild.choose(machine) else {
        throw HFError.refused("There is no official llama.cpp build for \(machine.architecture) Linux.")
      }
      let assets = try engines.releases.llamaCpp(platform: build.platform, runtime: build.runtime)
      if action == .update, let installed = status.version, installed.contains(assets.main.tag.dropFirst()) {
        throw HFError.conflict("llama.cpp on \(host.name) is already the newest official build (\(assets.main.tag)).")
      }
      let downloads = [assets.main.download] + (assets.runtime.map { [$0.download] } ?? [])
      plan.title = "\(action == .install ? "Install" : "Update") the official llama.cpp build \(assets.main.tag) on \(host.name) (\(build.label))"
      plan.version = assets.main.tag
      plan.downloads = downloads
      plan.downloadSize = HFEngineInstaller.size(downloads.reduce(0) { $0 + $1.size })
      plan.removal = "modelmatrixctl engine uninstall llama.cpp --host \(host.name) (deletes \(folder))"
      plan.notes = [
        "\(host.name) downloads the files itself from the llama.cpp project's GitHub releases and checks each one against its published SHA-256.",
        "No administrator password is needed; nothing outside \(folder) changes.",
        "Before switching over, the host checks that the new llama-server runs. If it doesn't, the install stops and nothing changes.",
      ]
      if build.runtime {
        plan.notes.append("The NVIDIA build comes with its CUDA runtime (the second, larger file), so nothing else needs installing.")
      }
      plan.notes += build.notes
      payload["archives"] = downloads.map { ["url": $0.url, "sha256": $0.sha256, "size": $0.size] }
      payload["build"] = build.label
      payload["tag"] = assets.main.tag
    case .uninstall:
      guard status.installed, status.managed == true else {
        throw HFError.refused(
          status.installed
            ? "llama.cpp on \(host.name) was installed by you, not by ModelMatrix, so ModelMatrix leaves it alone."
            : "llama.cpp isn't installed on \(host.name).")
      }
      plan.title = "Uninstall llama.cpp from \(host.name)"
      plan.downloadSize = "Nothing is downloaded."
      plan.notes = ["Deletes \(folder) on \(host.name). Models you downloaded stay where they are."]
    }
    remoteLock.lock()
    let cutoff = engines.now()
    remotePlans = remotePlans.filter { $0.value.plan.expires > cutoff }
    remotePlans[plan.id] = HFRemoteEnginePlan(plan: plan, host: host.id, payload: payload)
    remoteLock.unlock()
    return plan
  }

  /// Whether `planID` is a plan for a remote host.
  public func isRemotePlan(_ planID: String) -> Bool {
    remoteLock.lock()
    defer { remoteLock.unlock() }
    return remotePlans[planID] != nil
  }

  /// Carries out an approved host plan, once.
  public func runRemotePlan(_ planID: String) throws -> HFEngineJob {
    remoteLock.lock()
    let entry = remotePlans.removeValue(forKey: planID)
    remoteLock.unlock()
    guard let entry else { throw HFError.unknownItem("No plan with id \(planID). Make a new plan.") }
    guard entry.plan.expires > engines.now() else {
      throw HFError.refused("This plan has expired (plans last 10 minutes). Make a new plan and approve it again.")
    }
    guard let host = try remoteHost(entry.host) else { throw HFError.unknownItem("The host for this plan is gone.") }
    let path = entry.plan.action == .uninstall ? "/api/hf/engines/uninstall" : "/api/hf/engines/install"
    let answer = try agent.post(host, path, entry.payload)
    guard let object = answer["job"] as? [String: Any] else { throw HFError.badResponse("\(host.name) sent no job details.") }
    var job = Self.remoteEngineJob(object)
    job.planID = planID
    rememberEngineJobs([job.id], host: host)
    return job
  }

  /// Which host runs the engine job `id`: nil when it runs on this Mac.
  public func engineJobHost(_ id: String, hint: String?) throws -> HFRemoteHost? {
    if let host = try remoteHost(hint) { return host }
    if engines.job(id) != nil { return nil }
    let hosts = (hostDirectory?.hosts() ?? []).filter(\.enabled)
    if let known = knownEngineJobHost(id), let host = hosts.first(where: { $0.id == known }) { return host }
    for host in hosts where (try? remoteEngines(host))?.jobs.contains(where: { $0.id == id }) == true {
      return host
    }
    throw HFError.unknownItem("No engine job with id \(id).")
  }

  public func remoteEngineJob(_ id: String, host: HFRemoteHost) throws -> HFEngineJob {
    let answer = try agent.get(host, "/api/hf/engines/job", query: ["id": id])
    guard let object = answer["job"] as? [String: Any] else { throw HFError.badResponse("\(host.name) sent no job details.") }
    return Self.remoteEngineJob(object)
  }

  public func cancelRemoteEngineJob(_ id: String, host: HFRemoteHost) throws -> HFEngineJob {
    let answer = try agent.post(host, "/api/hf/engines/cancel", ["id": id])
    guard let object = answer["job"] as? [String: Any] else { throw HFError.badResponse("\(host.name) sent no job details.") }
    return Self.remoteEngineJob(object)
  }

  static func remoteEngineJob(_ object: [String: Any]) -> HFEngineJob {
    func text(_ key: String) -> String? { (object[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
    let log = (object["log"] as? [String] ?? []).map { String($0.prefix(2000)) }
    var job = HFEngineJob(
      id: text("id") ?? "", planID: "", engine: HFEngineID(rawValue: text("engine") ?? "") ?? .llamaCpp,
      action: HFEngineAction(rawValue: text("action") ?? "") ?? .install,
      method: HFEngineMethod(rawValue: text("method") ?? "") ?? .official, title: text("title") ?? "llama.cpp",
      error: text("error"), path: text("path"), version: text("version") ?? text("tag"),
      startedAt: text("created_at") ?? text("started_at") ?? HFFiles.timestamp(), finishedAt: text("finished_at"))
    job.state = HFEngineJobState(rawValue: text("state") ?? "") ?? .running
    job.log = Array(log.suffix(HFEngineJob.logLimit))
    job.logCount = max((object["log_count"] as? NSNumber)?.intValue ?? log.count, job.log.count)
    return job
  }

  // MARK: Which host has which id (so ids work without naming the host)

  func rememberDownloads(_ ids: [String], host: HFRemoteHost) {
    remoteLock.lock()
    for id in ids { downloadHosts[id] = host.id }
    remoteLock.unlock()
  }

  func forgetDownload(_ id: String) {
    remoteLock.lock()
    downloadHosts[id] = nil
    remoteLock.unlock()
  }

  func knownDownloadHost(_ id: String) -> String? {
    remoteLock.lock()
    defer { remoteLock.unlock() }
    return downloadHosts[id]
  }

  func rememberEngineJobs(_ ids: [String], host: HFRemoteHost) {
    remoteLock.lock()
    for id in ids { engineJobHosts[id] = host.id }
    remoteLock.unlock()
  }

  func knownEngineJobHost(_ id: String) -> String? {
    remoteLock.lock()
    defer { remoteLock.unlock() }
    return engineJobHosts[id]
  }
}

/// An approved-once plan for a host, with what will be sent to its agent.
struct HFRemoteEnginePlan: @unchecked Sendable {
  var plan: HFEnginePlan
  var host: String
  var payload: [String: Any]
}

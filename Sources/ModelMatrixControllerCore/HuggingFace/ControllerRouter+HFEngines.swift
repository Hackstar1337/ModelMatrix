import Foundation

/// Engine installs (always two steps: plan, then run that plan):
///
///     GET  /api/hf/engines                     engines here, with what can be done (?refresh=1 checks again)
///     POST /api/hf/engines/plan                {"engine", "action"?: install|update|uninstall, "method"?: homebrew|official}
///     POST /api/hf/engines/run                 {"plan_id"}  carries out that plan once
///     GET  /api/hf/engines/jobs                recent install jobs
///     GET  /api/hf/engines/jobs/<id>           one job; ?since=N returns log lines from N on
///     POST /api/hf/engines/jobs/<id>/cancel
///
/// Each route takes `host` (query, or body for POST) to act on a remote
/// host; there only llama.cpp's official build can be installed. Job ids
/// from a host also work without naming the host.
///
/// With ?format=text a job answer is just its new log lines, and the
/// headers X-ModelMatrix-Job-State and X-ModelMatrix-Log-Next tell the
/// state and where the next read starts.
extension ControllerRouter {
  var huggingFaceEngineRoutes: [RouteKey: Route] {
    [
      RouteKey(method: "GET", path: "/api/hf/engines"): { [self] request in
        try hfAction {
          let query = Self.formQuery(request.target)
          if let host = try hub.remoteHost(query["host"]) {
            let found = try hub.remoteEngines(host)
            return try engineListAnswer(
              request, list: found.target.engines, machine: found.target.machine, jobs: found.jobs,
              folder: found.target.machine.enginesFolder ?? "", homebrew: nil)
          }
          let refresh = ["1", "true", "yes"].contains(query["refresh"] ?? "")
          let list = hub.engines.engines(refresh: refresh)
          // "Check again" also lets models waiting for an engine continue.
          if refresh { hub.profiles.recheckWaiting() }
          return try engineListAnswer(
            request, list: list, machine: hub.check.machineProbe(), jobs: hub.engines.jobList(),
            folder: hub.engines.root, homebrew: hub.engines.homebrew)
        }
      },
      RouteKey(method: "POST", path: "/api/hf/engines/plan"): { [self] request in
        try hfAction {
          let body = try requestObject(request)
          guard let engine = HFEngineID.parse(body["engine"] as? String) else {
            throw HFError.invalidSetting("Name the engine: llama.cpp, mlx-lm or ollama.")
          }
          let actionName = (body["action"] as? String)?.lowercased() ?? "install"
          guard let action = HFEngineAction(rawValue: actionName) else {
            throw HFError.invalidSetting("action must be install, update or uninstall.")
          }
          var method: HFEngineMethod?
          if let raw = body["method"] as? String, !raw.isEmpty, raw != "auto" {
            guard let parsed = HFEngineMethod(rawValue: raw.lowercased()) else {
              throw HFError.invalidSetting("method must be homebrew or official.")
            }
            method = parsed
          }
          let plan: HFEnginePlan
          if let host = try hub.remoteHost(body["host"] as? String) {
            if method == .homebrew {
              throw HFError.refused("Homebrew isn't used on Linux hosts; ModelMatrix installs llama.cpp's official build there.")
            }
            plan = try hub.remoteEnginePlan(engine, action: action, host: host)
          } else {
            plan = try hub.engines.plan(engine, action: action, method: method)
          }
          if wantsText(request) { return hfText(HFEngineText.render(plan)) }
          return try hfJSON(HFEnginePlanEnvelope(plan: plan))
        }
      },
      RouteKey(method: "POST", path: "/api/hf/engines/run"): { [self] request in
        try hfAction {
          guard let planID = try requestObject(request)["plan_id"] as? String, Self.validEngineID(planID, prefix: "plan-") else {
            throw HFError.invalidSetting("Send the plan's id as {\"plan_id\": \"plan-…\"}.")
          }
          let job = hub.isRemotePlan(planID) ? try hub.runRemotePlan(planID) : try hub.engines.run(planID: planID)
          return try hfJSON(HFEngineJobEnvelope(job: job, lines: nil, next: nil), status: 202)
        }
      },
      RouteKey(method: "GET", path: "/api/hf/engines/jobs"): { [self] request in
        try hfAction {
          if let host = try hub.remoteHost(Self.formQuery(request.target)["host"]) {
            return try hfJSON(HFEngineJobList(jobs: try hub.remoteEngines(host).jobs.map(HFEngineJobSummary.init)))
          }
          return try hfJSON(HFEngineJobList(jobs: hub.engines.jobList().map(HFEngineJobSummary.init)))
        }
      },
    ]
  }

  /// `/api/hf/engines/jobs/<id>[/cancel]`.
  func huggingFaceEnginePrefixRoute(_ request: ControllerHTTPRequest) throws -> ControllerHTTPResponse? {
    let prefix = "/api/hf/engines/jobs/"
    guard request.path.hasPrefix(prefix) else { return nil }
    let parts = request.path.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard (1...2).contains(parts.count), Self.validEngineID(parts[0], prefix: "eng-") else {
      return try error(status: 404, code: "not_found", message: "not found")
    }
    let id = parts[0]
    return try hfAction {
      switch (request.method, parts.count == 2 ? parts[1] : nil) {
      case ("GET", nil):
        let query = Self.formQuery(request.target)
        let remote = try hub.engineJobHost(id, hint: query["host"])
        guard let job = try remote.map({ try hub.remoteEngineJob(id, host: $0) }) ?? hub.engines.job(id) else {
          throw HFError.unknownItem("No engine job with id \(id).")
        }
        let since = query["since"].flatMap(Int.init).map { max(0, $0) }
        let headers = [
          "X-ModelMatrix-Job-State": job.state.rawValue, "X-ModelMatrix-Log-Next": String(job.logCount),
        ]
        if wantsText(request) {
          let lines = since.map { job.log(since: $0).lines } ?? []
          let text = since == nil ? HFEngineText.render(job) : lines.map { $0 + "\n" }.joined()
          return ControllerHTTPResponse(
            status: 200, headers: headers.merging(["Content-Type": "text/plain; charset=utf-8"]) { $1 }, body: Data(text.utf8))
        }
        let lines = since.map { job.log(since: $0).lines }
        let body = try HFJSON.data(HFEngineJobEnvelope(job: job, lines: lines, next: since == nil ? nil : job.logCount))
        return ControllerHTTPResponse(
          status: 200, headers: headers.merging(["Content-Type": "application/json"]) { $1 }, body: body)
      case ("POST", "cancel"):
        let remote = try hub.engineJobHost(id, hint: Self.formQuery(request.target)["host"])
        let job = try remote.map { try hub.cancelRemoteEngineJob(id, host: $0) } ?? hub.engines.cancel(id)
        return try hfJSON(HFEngineJobEnvelope(job: job, lines: nil, next: nil))
      default:
        return try error(status: 404, code: "not_found", message: "not found")
      }
    }
  }

  /// The engines answer (one engine with ?engine=, text, or JSON).
  func engineListAnswer(
    _ request: ControllerHTTPRequest, list: [HFEngineStatus], machine: HFMachine, jobs: [HFEngineJob], folder: String,
    homebrew: String?
  ) throws -> ControllerHTTPResponse {
    if let name = Self.formQuery(request.target)["engine"] {
      guard let id = HFEngineID.parse(name), let engine = list.first(where: { $0.id == id }) else {
        throw HFError.invalidSetting("Name the engine: llama.cpp, mlx-lm or ollama.")
      }
      return try hfJSON(HFEngineOne(engine: engine))
    }
    if wantsText(request) { return hfText(HFEngineText.render(list, machine: machine, jobs: jobs)) }
    return try hfJSON(
      HFEngineList(
        engines: list, enginesFolder: folder, homebrew: homebrew, jobs: jobs.map(HFEngineJobSummary.init),
        host: machine.hostName))
  }

  static func validEngineID(_ id: String, prefix: String) -> Bool {
    id.hasPrefix(prefix) && (prefix.count + 4...prefix.count + 40).contains(id.count)
      && id.dropFirst(prefix.count).allSatisfy { $0.isASCII && $0.isHexDigit }
  }
}

extension HFEngineID {
  /// Accepts the usual spellings: llama.cpp, llamacpp, llama-server, mlx, mlx-lm, ollama.
  static func parse(_ raw: String?) -> HFEngineID? {
    switch raw?.lowercased().trimmingCharacters(in: .whitespaces) {
    case "llama.cpp", "llamacpp", "llama-cpp", "llama", "llama-server": return .llamaCpp
    case "mlx-lm", "mlx", "mlx_lm", "mlxlm": return .mlxLM
    case "ollama": return .ollama
    default: return nil
    }
  }
}

struct HFEngineList: Encodable {
  let engines: [HFEngineStatus]
  let enginesFolder: String
  let homebrew: String?
  let jobs: [HFEngineJobSummary]
  /// Remote host's name (nil for this Mac).
  var host: String?
}

struct HFEngineOne: Encodable {
  let engine: HFEngineStatus
}

struct HFEnginePlanEnvelope: Encodable {
  let plan: HFEnginePlan
}

struct HFEngineJobEnvelope: Encodable {
  let job: HFEngineJob
  /// Log lines from `since` on (when asked for).
  let lines: [String]?
  let next: Int?
}

struct HFEngineJobList: Encodable {
  let jobs: [HFEngineJobSummary]
}

/// A job without its log (for lists).
struct HFEngineJobSummary: Encodable {
  let id: String
  let engine: HFEngineID
  let action: HFEngineAction
  let method: HFEngineMethod
  let title: String
  let state: HFEngineJobState
  let error: String?
  let version: String?
  let startedAt: String
  let finishedAt: String?

  init(_ job: HFEngineJob) {
    id = job.id
    engine = job.engine
    action = job.action
    method = job.method
    title = job.title
    state = job.state
    error = job.error
    version = job.version
    startedAt = job.startedAt
    finishedAt = job.finishedAt
  }
}

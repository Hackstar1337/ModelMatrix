import Foundation
import Testing
@testable import ModelMatrixControllerCore

// MARK: Test doubles

/// The menu bar app's host list.
final class FakeHosts: HFHostDirectory, @unchecked Sendable {
  var list: [HFRemoteHost]?

  init(_ list: [HFRemoteHost]?) { self.list = list }

  func hosts() -> [HFRemoteHost]? { list }

  static let gpuBox = HFRemoteHost(
    id: "host-1", name: "gpu-box", baseURL: "http://10.0.0.5:8765", enabled: true, token: "agent-key")
}

/// Answers like the ModelMatrix agent's /api/hf/* routes (same JSON shapes).
final class FakeAgent: HFAgentTransport, @unchecked Sendable {
  struct Call {
    let method: String
    let path: String
    let query: [String: String]
    let token: String?
    let body: [String: Any]
  }

  private let lock = NSLock()
  private var log: [Call] = []
  var facts: [String: Any] = FakeAgent.linux()
  var engines: [[String: Any]] = [["id": "llama.cpp", "installed": false, "managed": false], ["id": "ollama", "installed": false]]
  var jobs: [[String: Any]] = []
  var engineJobs: [[String: Any]] = []
  var offline = false
  var tooOld = false

  var calls: [Call] {
    lock.lock()
    defer { lock.unlock() }
    return log
  }

  func calls(_ method: String, _ path: String) -> [Call] { calls.filter { $0.method == method && $0.path == path } }

  static func linux(
    memoryGiB: Int64 = 32, budgetGiB: Int64 = 24, accelerator: String = "cpu", cuda: String? = nil,
    architecture: String = "x86_64", freeDisk: Int64 = 1 << 40, glibc: String? = "2.39", vulkan: Bool = false
  ) -> [String: Any] {
    var facts: [String: Any] = [
      "kind": "linux", "os": "Ubuntu 24.04", "architecture": architecture, "chip": "AMD EPYC",
      "memory_bytes": memoryGiB << 30, "budget_bytes": budgetGiB << 30, "budget_source": accelerator,
      "accelerator": accelerator, "models_folder": "/home/ai/ModelMatrix/Models", "free_disk_bytes": freeDisk,
      "engines_folder": "/home/ai/ModelMatrix/Engines", "vulkan": vulkan, "rocm": false,
    ]
    if let cuda { facts["cuda_version"] = cuda }
    if let glibc { facts["glibc"] = glibc }
    return facts
  }

  func send(method: String, url: URL, token: String?, body: Data?, timeout: TimeInterval) throws -> (
    status: Int, body: Data
  ) {
    if offline { throw HFError.unavailable("connection refused") }
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    let query = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    let object = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    lock.lock()
    defer { lock.unlock() }
    log.append(Call(method: method, path: url.path, query: query, token: token, body: object))
    guard token == "agent-key" else { return reply(401, ["error": "unauthorized", "message": "missing or invalid token"]) }
    if tooOld { return reply(404, ["error": "not_found", "message": "not found"]) }
    switch (method, url.path) {
    case ("GET", "/api/hf/host"):
      return reply(200, ["machine": facts, "engines": engines, "hf_api": 1])
    case ("GET", "/api/hf/downloads"):
      return reply(200, ["downloads": jobs, "models_folder": facts["models_folder"] ?? ""])
    case ("POST", "/api/hf/downloads"):
      guard var job = object["job"] as? [String: Any] else { return reply(400, ["error": "invalid", "message": "Missing download details."]) }
      job["state"] = "queued"
      job["folder"] = "\(facts["models_folder"] ?? "")/\(object["folder_name"] ?? "")"
      jobs.append(job)
      return reply(200, ["download": job])
    case ("POST", "/api/hf/downloads/action"):
      guard let index = jobs.firstIndex(where: { $0["id"] as? String == object["id"] as? String }) else {
        return reply(404, ["error": "unknown_item", "message": "No download with id \(object["id"] ?? "")."])
      }
      switch object["action"] as? String {
      case "pause": jobs[index]["state"] = "paused"
      case "resume": jobs[index]["state"] = "queued"
      case "cancel": jobs[index]["state"] = "cancelled"
      case "start": jobs[index]["profile_state"] = "starting"
      case "delete":
        let id = jobs[index]["id"] ?? ""
        jobs.remove(at: index)
        return reply(200, ["deleted": true, "id": id, "kept_in_ollama": false])
      default: return reply(400, ["error": "invalid", "message": "Unknown action."])
      }
      return reply(200, ["download": jobs[index]])
    case ("GET", "/api/hf/engines"):
      return reply(200, ["engines": engines, "jobs": engineJobs])
    case ("POST", "/api/hf/engines/install"), ("POST", "/api/hf/engines/uninstall"):
      let job: [String: Any] = [
        "id": object["job_id"] ?? "", "engine": "llama.cpp", "action": url.path.hasSuffix("install") && !url.path.hasSuffix("uninstall") ? "install" : "uninstall",
        "method": "official", "title": "llama.cpp on the host", "state": "running", "log": ["Downloading 1 of 2"],
        "log_count": 1, "started_at": "2026-10-20T00:00:00Z",
      ]
      engineJobs.append(job)
      return reply(200, ["job": job])
    case ("GET", "/api/hf/engines/job"):
      guard let job = engineJobs.first(where: { $0["id"] as? String == query["id"] }) else {
        return reply(404, ["error": "unknown_item", "message": "No engine job with id \(query["id"] ?? "")."])
      }
      return reply(200, ["job": job])
    case ("POST", "/api/hf/engines/cancel"):
      guard let index = engineJobs.firstIndex(where: { $0["id"] as? String == object["id"] as? String }) else {
        return reply(404, ["error": "unknown_item", "message": "No engine job."])
      }
      engineJobs[index]["state"] = "cancelled"
      return reply(200, ["job": engineJobs[index]])
    default:
      return reply(404, ["error": "not_found", "message": "not found"])
    }
  }

  private func reply(_ status: Int, _ object: [String: Any]) -> (status: Int, body: Data) {
    (status, (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
  }
}

struct HostSandbox {
  let directory: URL
  let hub: HFHub
  let agent = FakeAgent()
  let hosts = FakeHosts([FakeHosts.gpuBox])
  let github = FakeGitHub()
  let transport: FakeHFTransport
  let clock = DateBox()

  init(transport: FakeHFTransport = FakeHFTransport()) {
    self.transport = transport
    directory = FileManager.default.temporaryDirectory.appendingPathComponent("mm-hosts-\(UUID().uuidString)")
    let clock = clock
    hub = HFHub(
      directory: directory, check: makeCheckService(transport: transport, machine: .sample(memoryGiB: 48)),
      tokenStore: HFMemoryTokenStore(), streamer: FakeByteStreamer(), network: FakeNetwork(),
      freeSpace: { _ in 1 << 42 }, pause: { _ in }, engineTransport: github, now: { clock.value })
    hub.hostDirectory = hosts
    hub.agent = HFAgentClient(transport: agent)
  }

  func cleanUp() { try? FileManager.default.removeItem(at: directory) }

  /// Publishes Linux llama.cpp builds; `cudart` lists the tags that also
  /// have the CUDA runtime.
  func publishLinux(_ tags: [String], platform: String, cudart: Set<String> = []) {
    github.answers["/repos/ggml-org/llama.cpp/releases"] = tags.map { tag -> [String: Any] in
      var assets = [FakeGitHub.asset("ggml-org/llama.cpp", tag: tag, name: "llama-\(tag)-bin-\(platform).tar.gz", data: Data(tag.utf8))]
      if cudart.contains(tag) {
        assets.append(
          FakeGitHub.asset("ggml-org/llama.cpp", tag: tag, name: "cudart-llama-\(tag)-bin-\(platform).tar.gz", data: Data("rt\(tag)".utf8)))
      }
      return ["tag_name": tag, "draft": false, "prerelease": true, "assets": assets]
    }
  }
}

// MARK: Check and download on a host

@Test func hfHostCheckUsesTheHostsOwnMemoryAndEngines() throws {
  let box = HostSandbox()
  defer { box.cleanUp() }
  let report = try box.hub.check("bartowski/Qwen2.5-7B-Instruct-GGUF", host: "GPU-BOX")  // names match in any case
  #expect(report.machine.isRemote && report.machine.hostName == "gpu-box" && !report.machine.appleSilicon)
  #expect(report.machine.memoryBytes == 32 << 30 && report.machine.modelsFolder == "/home/ai/ModelMatrix/Models")
  #expect(report.recommendation?.label == "Q8_0")
  let llama = try #require(report.engine?.engines.first { $0.id == .llamaCpp })
  #expect(!llama.installed && llama.install?.method == "official")
  #expect(report.engine?.engines.first { $0.id == .mlxLM }?.applicable == false)
  #expect(HFCheckText.render(report).contains("gpu-box"))
  #expect(report.verdict.title == "Runs on gpu-box once llama.cpp is installed")
  // Ollama on Linux needs sudo, so it is shown as a command to run yourself.
  let ollama = try #require(report.engine?.engines.first { $0.id == .ollama })
  #expect(ollama.install?.method == "manual")
  let checkText = HFCheckText.render(report)
  #expect(checkText.contains("run this yourself: curl -fsSL https://ollama.com/install.sh | sh"))
  #expect(!checkText.contains("engine install ollama"))
  let enginesText = HFEngineText.render(report.engine?.engines ?? [], machine: report.machine, jobs: [])
  #expect(enginesText.contains("Install it yourself: curl -fsSL https://ollama.com/install.sh | sh"))
  #expect(!enginesText.contains("engine install ollama") && enginesText.contains("engine install llama.cpp --host gpu-box"))
  // A small host gets a smaller version than the big one.
  box.agent.facts = FakeAgent.linux(memoryGiB: 8, budgetGiB: 5)
  let small = try box.hub.check("bartowski/Qwen2.5-7B-Instruct-GGUF", host: "gpu-box")
  #expect(small.recommendation?.label != "Q8_0")
  // "local" and no host mean this Mac.
  #expect(try box.hub.check("bartowski/Qwen2.5-7B-Instruct-GGUF", host: "local").machine.isRemote == false)
  #expect(box.agent.calls.allSatisfy { $0.token == "agent-key" })
}

@Test func hfHostDownloadIsQueuedOnTheHostNotThisMac() throws {
  let box = HostSandbox()
  defer { box.cleanUp() }
  let started = try box.hub.startDownload(.init(name: "bartowski/Qwen2.5-7B-Instruct-GGUF", host: "gpu-box"))
  #expect(!started.existing && started.job.host == "host-1" && started.job.hostName == "gpu-box")
  #expect(started.job.folder == "/home/ai/ModelMatrix/Models/bartowski/Qwen2.5-7B-Instruct-GGUF")
  #expect(box.hub.downloads.list().isEmpty)  // nothing downloads on the Mac
  let sent = try #require(box.agent.calls("POST", "/api/hf/downloads").first)
  let job = try #require(sent.body["job"] as? [String: Any])
  #expect(job["label"] as? String == "Q8_0" && (job["files"] as? [[String: Any]])?.count == 1)
  #expect(sent.body["folder_name"] as? String == "bartowski/Qwen2.5-7B-Instruct-GGUF")
  #expect(sent.body["endpoint"] as? String == "https://huggingface.co")
  #expect(sent.body["token"] == nil)
  // Asking again returns the same download.
  let again = try box.hub.startDownload(.init(name: "bartowski/Qwen2.5-7B-Instruct-GGUF", host: "gpu-box"))
  #expect(again.existing && again.job.id == started.job.id)
  #expect(box.agent.calls("POST", "/api/hf/downloads").count == 1)
  // Lists show the host.
  let all = box.hub.allDownloads()
  #expect(all.downloads.map(\.id) == [started.job.id] && all.unreachable.isEmpty)
  #expect(HFDownloadText.render(all.downloads).contains("on gpu-box"))
}

@Test func hfHostDownloadRefusesMLXAndChecksTheHostsDisk() throws {
  let box = HostSandbox()
  defer { box.cleanUp() }
  expectHFError("refused", "Apple Silicon") {
    _ = try box.hub.startDownload(.init(name: "mlx-community/Qwen2.5-7B-Instruct-4bit", host: "gpu-box"))
  }
  box.agent.facts = FakeAgent.linux(freeDisk: 3 << 30)
  expectHFError("insufficient_disk", "Not enough disk space") {
    _ = try box.hub.startDownload(.init(name: "bartowski/Qwen2.5-7B-Instruct-GGUF", host: "gpu-box"))
  }
  #expect(box.agent.calls("POST", "/api/hf/downloads").isEmpty)
}

@Test func hfHostGetsTheTokenOnlyForLoginOnlyModels() throws {
  let transport = FakeHFTransport()
  transport.markedGated = ["bartowski/Qwen2.5-7B-Instruct-GGUF"]
  let box = HostSandbox(transport: transport)
  defer { box.cleanUp() }
  // Without a saved token a login-only model can't be downloaded anywhere.
  expectHFError("login_required") {
    _ = try box.hub.startDownload(.init(name: "bartowski/Qwen2.5-7B-Instruct-GGUF", host: "gpu-box"))
  }
  box.hub.check.client.setTokenProvider { "hf_secret_token" }
  let started = try box.hub.startDownload(.init(name: "bartowski/Qwen2.5-7B-Instruct-GGUF", host: "gpu-box"))
  #expect(started.job.gated == true)
  #expect(box.agent.calls("POST", "/api/hf/downloads").first?.body["token"] as? String == "hf_secret_token")
  // A resume carries it again (the host keeps it in memory only).
  _ = try box.hub.remoteDownloadAction(started.job.id, action: "pause", host: FakeHosts.gpuBox)
  _ = try box.hub.remoteDownloadAction(started.job.id, action: "resume", host: FakeHosts.gpuBox)
  let actions = box.agent.calls("POST", "/api/hf/downloads/action")
  #expect(actions.first?.body["token"] == nil && actions.last?.body["token"] as? String == "hf_secret_token")
  // A public model never sends it.
  _ = try box.hub.startDownload(.init(name: "ggml-org/gemma-3-4b-it-GGUF", host: "gpu-box"))
  #expect(box.agent.calls("POST", "/api/hf/downloads").last?.body["token"] == nil)
}

// MARK: Engines on a host

@Test func hfHostEnginePlanPicksTheMatchingCUDABuildAndRunsOnce() throws {
  let box = HostSandbox()
  defer { box.cleanUp() }
  box.agent.facts = FakeAgent.linux(accelerator: "cuda", cuda: "12.9")
  // The newest build has no CUDA runtime yet, so the one before it is used.
  box.publishLinux(["b301", "b300"], platform: "ubuntu-cuda-12.8-x64", cudart: ["b300"])
  let plan = try box.hub.remoteEnginePlan(.llamaCpp, action: .install, host: FakeHosts.gpuBox)
  #expect(plan.version == "b300" && plan.downloads.count == 2)
  #expect(plan.downloads.last?.url.contains("cudart-llama-b300-bin-ubuntu-cuda-12.8-x64") == true)
  #expect(plan.title.contains("NVIDIA CUDA 12.8") && plan.title.contains("gpu-box"))
  #expect(plan.location == "/home/ai/ModelMatrix/Engines/llama.cpp on gpu-box")
  #expect(box.agent.calls("POST", "/api/hf/engines/install").isEmpty)  // a plan changes nothing
  let job = try box.hub.runRemotePlan(plan.id)
  let sent = try #require(box.agent.calls("POST", "/api/hf/engines/install").first)
  let archives = try #require(sent.body["archives"] as? [[String: Any]])
  #expect(archives.count == 2 && archives.allSatisfy { ($0["sha256"] as? String)?.count == 64 })
  #expect(sent.body["job_id"] as? String == job.id && job.planID == plan.id)
  expectHFError("unknown_item") { _ = try box.hub.runRemotePlan(plan.id) }  // once only
  #expect(try box.hub.engineJobHost(job.id, hint: nil)?.id == "host-1")
  // Plans last 10 minutes.
  let later = try box.hub.remoteEnginePlan(.llamaCpp, action: .install, host: FakeHosts.gpuBox)
  box.clock.value = box.clock.value.addingTimeInterval(11 * 60)
  expectHFError("refused", "expired") { _ = try box.hub.runRemotePlan(later.id) }
  #expect(box.agent.calls("POST", "/api/hf/engines/install").count == 1)
}

@Test func hfHostEnginePlansLeaveOtherEnginesAndUserInstallsAlone() throws {
  let box = HostSandbox()
  defer { box.cleanUp() }
  expectHFError("refused", "Apple Silicon") { _ = try box.hub.remoteEnginePlan(.mlxLM, action: .install, host: FakeHosts.gpuBox) }
  expectHFError("refused", "install.sh") { _ = try box.hub.remoteEnginePlan(.ollama, action: .install, host: FakeHosts.gpuBox) }
  box.agent.engines = [["id": "llama.cpp", "installed": true, "managed": false, "path": "/usr/local/bin/llama-server", "version": "b5000"]]
  expectHFError("conflict", "already installed") { _ = try box.hub.remoteEnginePlan(.llamaCpp, action: .install, host: FakeHosts.gpuBox) }
  expectHFError("refused", "installed by you") { _ = try box.hub.remoteEnginePlan(.llamaCpp, action: .update, host: FakeHosts.gpuBox) }
  expectHFError("refused", "installed by you") { _ = try box.hub.remoteEnginePlan(.llamaCpp, action: .uninstall, host: FakeHosts.gpuBox) }
  // One ModelMatrix installed can be removed (nothing is downloaded).
  box.agent.engines = [["id": "llama.cpp", "installed": true, "managed": true, "path": "/home/ai/ModelMatrix/Engines/llama.cpp/bin/llama-server"]]
  let removal = try box.hub.remoteEnginePlan(.llamaCpp, action: .uninstall, host: FakeHosts.gpuBox)
  #expect(removal.downloads.isEmpty && removal.downloadSize == "Nothing is downloaded.")
  _ = try box.hub.runRemotePlan(removal.id)
  #expect(box.agent.calls("POST", "/api/hf/engines/uninstall").count == 1)
  #expect(box.agent.calls("POST", "/api/hf/engines/install").isEmpty)
}

// MARK: Routes

@Test func hfHostRoutesFindTheRightHost() throws {
  let box = HostSandbox()
  defer { box.cleanUp() }
  try withFixtureRoot { fixture in
    let router = ControllerRouter(service: fixture.service, authToken: nil, hub: box.hub)
    func call(_ method: String, _ target: String, _ body: [String: Any]? = nil) -> ControllerHTTPResponse {
      let data = body.map { try! JSONSerialization.data(withJSONObject: $0) } ?? Data()
      return router.handle(.init(method: method, target: target, headers: ["Content-Type": "application/json"], body: data))
    }
    func object(_ response: ControllerHTTPResponse) -> [String: Any] {
      (try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]) ?? [:]
    }
    let check = object(call("GET", "/api/hf/check?name=bartowski/Qwen2.5-7B-Instruct-GGUF&host=gpu-box"))
    #expect((check["machine"] as? [String: Any])?["host_name"] as? String == "gpu-box")
    let started = call("POST", "/api/hf/downloads", ["name": "bartowski/Qwen2.5-7B-Instruct-GGUF", "host": "gpu-box"])
    #expect(started.status == 202)
    let id = try #require((object(started)["download"] as? [String: Any])?["id"] as? String)
    // The id alone is enough: the controller finds the host that has it.
    #expect(call("POST", "/api/hf/downloads/\(id)/pause").status == 200)
    #expect(box.agent.calls("POST", "/api/hf/downloads/action").last?.body["action"] as? String == "pause")
    let one = object(call("GET", "/api/hf/downloads/\(id)"))
    #expect((one["download"] as? [String: Any])?["state"] as? String == "paused")
    #expect((object(call("GET", "/api/hf/downloads?host=gpu-box"))["downloads"] as? [Any])?.count == 1)
    #expect((object(call("GET", "/api/hf/downloads"))["downloads"] as? [Any])?.isEmpty == true)  // this Mac only
    let text = String(decoding: call("GET", "/api/hf/downloads?host=all&format=text").body, as: UTF8.self)
    #expect(text.contains("on gpu-box"))
    // Engines on the host.
    let engines = object(call("GET", "/api/hf/engines?host=gpu-box"))
    #expect(engines["host"] as? String == "gpu-box" && engines["engines_folder"] as? String == "/home/ai/ModelMatrix/Engines")
    #expect(call("POST", "/api/hf/engines/plan", ["engine": "llama.cpp", "host": "gpu-box", "method": "homebrew"]).status == 422)
    // Problems are explained.
    let unknown = object(call("GET", "/api/hf/check?name=bartowski/Qwen2.5-7B-Instruct-GGUF&host=nas"))
    #expect((unknown["message"] as? String)?.contains("Hosts: gpu-box") == true)
    box.hosts.list = [HFRemoteHost(id: "host-1", name: "gpu-box", baseURL: "http://10.0.0.5:8765", enabled: false, token: "agent-key")]
    #expect((object(call("GET", "/api/hf/engines?host=gpu-box"))["message"] as? String)?.contains("paused") == true)
    box.hosts.list = [FakeHosts.gpuBox]
    box.agent.offline = true
    let offline = object(call("GET", "/api/hf/downloads?host=all"))
    #expect(offline["unreachable"] as? [String] == ["gpu-box"])
    #expect((object(call("GET", "/api/hf/engines?host=gpu-box"))["message"] as? String)?.contains("Couldn't reach gpu-box") == true)
    box.agent.offline = false
    box.agent.tooOld = true
    #expect((object(call("GET", "/api/hf/engines?host=gpu-box"))["message"] as? String)?.contains("too old") == true)
    box.agent.tooOld = false
    box.hosts.list = [HFRemoteHost(id: "host-1", name: "gpu-box", baseURL: "http://10.0.0.5:8765", token: "wrong")]
    #expect((object(call("GET", "/api/hf/engines?host=gpu-box"))["message"] as? String)?.contains("access key") == true)
    box.hosts.list = nil  // menu bar app not running
    #expect((object(call("GET", "/api/hf/engines?host=gpu-box"))["message"] as? String)?.contains("menu bar app") == true)
  }
}

@Test func hfHostListedModelsAndDeletes() throws {
  let box = HostSandbox()
  defer { box.cleanUp() }
  let started = try box.hub.startDownload(.init(name: "bartowski/Qwen2.5-7B-Instruct-GGUF", host: "gpu-box"))
  // Finish it on the "host".
  box.agent.jobs[0]["state"] = "completed"
  box.agent.jobs[0]["profile"] = "qwen2.5-7b-instruct-q8-0"
  var files = box.agent.jobs[0]["files"] as? [[String: Any]] ?? []
  for index in files.indices { files[index]["done"] = true }
  box.agent.jobs[0]["files"] = files
  let jobs = try box.hub.remoteDownloads(FakeHosts.gpuBox)
  let model = HFHub.remoteModel(try #require(jobs.first))
  #expect(model.hostName == "gpu-box" && model.missingFiles == 0 && model.bytesOnDisk > 7_000_000_000)
  #expect(HFProfileText.render([model], untracked: []).contains("on gpu-box"))
  let deleted = try box.hub.remoteDelete(started.job.id, deleteFiles: true, host: FakeHosts.gpuBox)
  #expect(deleted.job?.profile == "qwen2.5-7b-instruct-q8-0" && !deleted.keptInOllama)
  #expect(box.agent.calls("POST", "/api/hf/downloads/action").last?.body["delete_files"] as? Bool == true)
  #expect(try box.hub.remoteDownloads(FakeHosts.gpuBox).isEmpty)
}

// MARK: Which llama.cpp build suits a Linux host

@Test func hfLinuxBuildMatchesTheHostsHardware() throws {
  func build(_ facts: [String: Any]) throws -> HFLinuxBuild? {
    HFLinuxBuild.choose(try HFMachine.remote(facts, host: FakeHosts.gpuBox))
  }
  #expect(try build(FakeAgent.linux())?.platform == "ubuntu-x64")
  #expect(try build(FakeAgent.linux(architecture: "aarch64"))?.platform == "ubuntu-arm64")
  let cuda128 = try #require(try build(FakeAgent.linux(accelerator: "cuda", cuda: "12.8")))
  #expect(cuda128.platform == "ubuntu-cuda-12.8-x64" && cuda128.runtime && cuda128.notes.isEmpty)
  #expect(try build(FakeAgent.linux(accelerator: "cuda", cuda: "13.1"))?.platform == "ubuntu-cuda-13.4-x64")
  #expect(try build(FakeAgent.linux(accelerator: "cuda", cuda: "13.0", architecture: "arm64"))?.platform == "ubuntu-cuda-13.4-arm64")
  let oldDriver = try #require(try build(FakeAgent.linux(accelerator: "cuda", cuda: "12.4")))
  #expect(oldDriver.platform == "ubuntu-x64" && !oldDriver.runtime)
  #expect(oldDriver.notes.contains { $0.contains("driver is too old") && $0.contains("12.4") })
  #expect(try build(FakeAgent.linux(accelerator: "cuda", cuda: "12.4", vulkan: true))?.platform == "ubuntu-vulkan-x64")
  #expect(try build(FakeAgent.linux(accelerator: "amd", vulkan: true))?.platform == "ubuntu-vulkan-x64")
  let amd = try #require(try build(FakeAgent.linux(accelerator: "amd")))
  #expect(amd.platform == "ubuntu-x64" && amd.notes.contains { $0.contains("mesa-vulkan-drivers") })
  #expect(try build(FakeAgent.linux(glibc: "2.31"))?.notes.contains { $0.contains("glibc 2.31") } == true)
  #expect(try build(FakeAgent.linux(glibc: nil))?.notes.contains { $0.contains("Alpine") } == true)
  #expect(try build(FakeAgent.linux(architecture: "riscv64")) == nil)
  // Facts without memory are refused rather than guessed.
  var broken = FakeAgent.linux()
  broken["memory_bytes"] = nil
  expectHFError("hf_bad_response", "memory") { _ = try HFMachine.remote(broken, host: FakeHosts.gpuBox) }
}

@Test func hfHostReadyAddressUsesTheAddressThisMacReaches() {
  let lan = HFRemoteHost(id: "gw", name: "gpu-box", baseURL: "http://192.168.1.40:8765")
  #expect(HFHub.reachableURL("http://127.0.0.1:8766/v1", host: lan) == "http://192.168.1.40:8766/v1")
  #expect(HFHub.reachableURL("http://0.0.0.0:8766/v1", host: lan) == "http://192.168.1.40:8766/v1")
  // A real address the host reported is kept, and so is a tunnelled host's.
  #expect(HFHub.reachableURL("http://100.64.0.7:8766/v1", host: lan) == "http://100.64.0.7:8766/v1")
  let tunnel = HFRemoteHost(id: "gw2", name: "ssh-box", baseURL: "http://127.0.0.1:18765")
  #expect(HFHub.reachableURL("http://127.0.0.1:8766/v1", host: tunnel) == "http://127.0.0.1:8766/v1")
  #expect(HFHub.reachableURL(nil, host: lan) == nil)
}

@Test func hfResultTitleKeepsTheHostSpelling() {
  #expect(HFCheckText.shout("Ready to run on linux-box", keeping: "linux-box") == "READY TO RUN ON linux-box")
  #expect(HFCheckText.shout("Ready to run on this machine", keeping: nil) == "READY TO RUN ON THIS MACHINE")
}

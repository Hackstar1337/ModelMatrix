import Foundation
import Testing

@testable import ModelMatrixControllerCore

// MARK: Fakes

final class FakeProfileHost: HFProfileHosting, @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [String: [String: String]] = [:]
  private var startedNames: [String] = []
  private var deletedNames: [String] = []
  var startError: Error?
  var log: [String] = []

  init(profiles: [String: [String: String]] = [:]) {
    stored = profiles
  }

  var profiles: [String: [String: String]] { lock.withLock { stored } }
  var started: [String] { lock.withLock { startedNames } }
  var deleted: [String] { lock.withLock { deletedNames } }

  func allProfiles() -> [String: [String: String]] { profiles }

  func createProfile(name: String, values: [String: String]) throws {
    _ = try ControllerProfile(name: name, values: values)
    try lock.withLock {
      guard stored[name] == nil else { throw ControllerError.profileConflict("\(name) exists") }
      stored[name] = values
    }
  }

  func updateProfile(name: String, values: [String: String]) throws {
    lock.withLock { stored[name] = values }
  }

  func startProfile(_ name: String) throws {
    lock.withLock { startedNames.append(name) }
    if let startError { throw startError }
  }

  func deleteProfile(_ name: String) throws {
    lock.withLock {
      stored[name] = nil
      deletedNames.append(name)
    }
  }

  func isRunning(_ name: String) -> Bool { started.contains(name) }

  func logTail(_ name: String, lines: Int) -> [String] { Array(log.suffix(lines)) }
}

final class FakeChat: HFChatTesting, @unchecked Sendable {
  private let lock = NSLock()
  private var answers: [Result<String, HFChatTestError>]
  private var calls: [(URL, String)] = []

  init(_ answers: [Result<String, HFChatTestError>] = [.success("ready")]) {
    self.answers = answers
  }

  var sent: [(url: URL, model: String)] { lock.withLock { calls.map { (url: $0.0, model: $0.1) } } }

  func send(baseURL: URL, model: String, timeout: TimeInterval) throws -> String {
    let answer: Result<String, HFChatTestError> = lock.withLock {
      calls.append((baseURL, model))
      return answers.count > 1 ? answers.removeFirst() : answers[0]
    }
    return try answer.get()
  }
}

/// Engines that can be "installed" part-way through a test.
final class SwitchableEngines: @unchecked Sendable {
  private let lock = NSLock()
  private var on: Bool

  init(installed: Bool) {
    on = installed
  }

  var installed: Bool {
    get { lock.withLock { on } }
    set { lock.withLock { on = newValue } }
  }

  var environment: HFEngineEnvironment {
    let all = FakeEngineEnvironment.allInstalled
    return HFEngineEnvironment(
      home: "/Users/test",
      searchDirectories: { ["/opt/homebrew/bin"] },
      isExecutable: { [self] path in path == "/opt/homebrew/bin/brew" || (installed && all.executables.contains(path)) },
      resolve: { all.links[$0] ?? $0 },
      run: { path, _ in all.outputs[path] },
      ollamaServerVersion: { nil })
  }
}

final class RemovedOllamaModels: @unchecked Sendable {
  private let lock = NSLock()
  private var names: [String] = []
  var all: [String] { lock.withLock { names } }
  func add(_ name: String) { lock.withLock { names.append(name) } }
}

struct ProfileFixture {
  let downloads: DownloadFixture
  let host: FakeProfileHost
  let chat: FakeChat
  let engines: SwitchableEngines
  let profiles: HFProfileManager
  let removed: RemovedOllamaModels

  /// Waits until queued profile steps have run.
  func settle() { profiles.queue.sync {} }

  /// A finished download with its files on disk.
  @discardableResult
  func completed(
    repo: String = "bartowski/Qwen2.5-7B-Instruct-GGUF", label: String = "Q4_K_M", format: String = "gguf",
    files: [(String, Int)] = [("Qwen2.5-7B-Instruct-Q4_K_M.gguf", 4_000)], projector: String? = nil,
    startAfter: Bool = true, need: Int64? = 6 << 30
  ) throws -> HFDownloadJob {
    let folder = downloads.models.appendingPathComponent(repo, isDirectory: true)
    var job = HFDownloadJob(
      id: HFDownloadJob.newID(), kind: "files", repo: repo, revision: "abc123", label: label, format: format,
      engine: format == "mlx" ? "mlx-lm" : "llama.cpp", displayName: "\(repo) \(label)", folder: folder.path,
      files: files.map { HFDownloadFile(path: $0.0, size: Int64($0.1), sha256: nil) }, context: 16_384,
      startAfter: startAfter)
    job.state = .completed
    job.mainFile = format == "mlx" ? nil : files.first?.0
    job.projectorFile = projector
    job.memoryNeedBytes = need
    for index in job.files.indices {
      job.files[index].done = true
      let url = job.fileURL(job.files[index])
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try testBytes(Int(job.files[index].size)).write(to: url)
    }
    try downloads.manager.add(job)
    return job
  }
}

func withProfiles(
  installed: Bool = true, machine: HFMachine = .sample(memoryGiB: 48), chat: FakeChat = FakeChat(),
  free: Int64? = 1 << 40, relay: URL? = URL(string: "http://127.0.0.1:7701/v1"), busyPorts: Set<Int> = [],
  host: FakeProfileHost = FakeProfileHost(), _ body: (ProfileFixture) throws -> Void
) throws {
  try withDownloads { downloads in
    let engines = SwitchableEngines(installed: installed)
    let removed = RemovedOllamaModels()
    let manager = HFProfileManager(
      downloads: downloads.manager, settings: downloads.settings,
      engines: HFEngineProbe(environment: engines.environment), machine: { machine }, chat: chat,
      portFree: { !busyPorts.contains($0) }, availableMemory: { free }, physicalCores: 8, pause: { _ in },
      ollamaRemove: { removed.add($0) })
    manager.host = host
    manager.relayURL = { relay }
    try body(
      ProfileFixture(downloads: downloads, host: host, chat: chat, engines: engines, profiles: manager, removed: removed))
  }
}

// MARK: Names, ports and settings

@Test func hfProfileNamesAreReadableAndUnique() {
  #expect(HFProfileMaker.baseModelName(repo: "bartowski/Qwen2.5-7B-Instruct-GGUF") == "qwen2.5-7b-instruct")
  #expect(HFProfileMaker.baseModelName(repo: "mlx-community/Qwen2.5-7B-Instruct-4bit") == "qwen2.5-7b-instruct")
  #expect(HFProfileMaker.baseModelName(repo: "mlx-community/Llama-3.2-3B-Instruct-mlx-8bit") == "llama-3.2-3b-instruct")
  #expect(HFProfileMaker.baseModelName(repo: "ggml-org/gemma-3-4b-it-GGUF") == "gemma-3-4b-it")
  #expect(HFProfileMaker.baseModelName(repo: "someone/Ünïcode Model!") == "n-code-model")
  #expect(HFProfileMaker.displayName(repo: "bartowski/Qwen2.5-7B-Instruct-GGUF", label: "Q8_0") == "Qwen2.5 7B Instruct · Q8_0")
  let repo = "bartowski/Qwen2.5-7B-Instruct-GGUF"
  #expect(HFProfileMaker.modelName(repo: repo, label: "Q4_K_M", taken: []) == "qwen2.5-7b-instruct")
  #expect(HFProfileMaker.modelName(repo: repo, label: "Q4_K_M", taken: ["Qwen2.5-7B-Instruct"]) == "qwen2.5-7b-instruct-q4_k_m")
  #expect(
    HFProfileMaker.modelName(repo: repo, label: "Q4_K_M", taken: ["qwen2.5-7b-instruct", "qwen2.5-7b-instruct-q4_k_m"])
      == "qwen2.5-7b-instruct-q4_k_m-2")
  #expect(HFProfileMaker.profileName(repo: repo, label: "Q8_0", existing: []) == "qwen2.5-7b-instruct-q8_0")
  #expect(HFProfileMaker.profileName(repo: repo, label: "Q8_0", existing: ["qwen2.5-7b-instruct-q8_0"]) == "qwen2.5-7b-instruct-q8_0-2")
  // Every generated name is a valid profile name.
  let long = HFProfileMaker.profileName(repo: "o/" + String(repeating: "very-long-name-", count: 10), label: "UD-Q4_K_XL", existing: [])
  #expect(ControllerService.isValidProfileName(long))
}

@Test func hfProfilePortsSkipUsedAndBusyPorts() {
  let profiles = ["a": ["PORT": "8081"], "b": ["BASE_URL": "http://127.0.0.1:8082/v1"]]
  #expect(HFProfileMaker.pickPort(profiles: profiles, isFree: { $0 != 8083 }) == 8084)
  #expect(HFProfileMaker.pickPort(profiles: [:], isFree: { _ in true }) == 8081)
  #expect(HFProfileMaker.pickPort(profiles: [:], isFree: { _ in false }) == nil)
}

func ggufInputs(accelerator: String, projector: String? = "mmproj-model-f16.gguf") -> HFProfileMaker.Inputs {
  var job = HFDownloadJob(
    id: "dl-1234abcd", kind: "files", repo: "ggml-org/gemma-3-4b-it-GGUF", revision: "abc123", label: "Q4_K_M",
    format: "gguf", engine: "llama.cpp", displayName: "gemma", folder: "/Users/test/My Models/ggml-org/gemma-3-4b-it-GGUF",
    files: [HFDownloadFile(path: "gemma-3-4b-it-Q4_K_M.gguf", size: 1, sha256: nil)], context: 32_768, startAfter: true)
  job.mainFile = "gemma-3-4b-it-Q4_K_M.gguf"
  job.projectorFile = projector
  return HFProfileMaker.Inputs(
    job: job, profileName: "gemma-3-4b-it-q4_k_m", modelName: "gemma-3-4b-it", port: 8085,
    enginePath: "/opt/homebrew/bin/llama-server", accelerator: accelerator, physicalCores: 6,
    resolvedFolder: job.folder)
}

@Test func hfProfileSettingsForGGUFOnAppleSiliconAndIntel() throws {
  let metal = HFProfileMaker.values(ggufInputs(accelerator: "metal"))
  #expect(metal["RUNTIME"] == "llama.cpp" && metal["GPU_LAYERS"] == "999" && metal["THREADS"] == nil)
  #expect(metal["MODEL_PATH"] == "/Users/test/My Models/ggml-org/gemma-3-4b-it-GGUF/gemma-3-4b-it-Q4_K_M.gguf")
  #expect(metal["MODEL_ALIAS"] == "gemma-3-4b-it" && metal["REQUEST_MODEL"] == "gemma-3-4b-it")
  #expect(metal["SERVER_MODEL_ID"] == "gemma-3-4b-it" && metal["CONTEXT_SIZE"] == "32768")
  #expect(metal["PORT"] == "8085" && metal["BASE_URL"] == "http://127.0.0.1:8085/v1" && metal["HOST"] == "127.0.0.1")
  #expect(metal["SERVER_BIN"] == "/opt/homebrew/bin/llama-server" && metal["LOG_ALIAS"] == "gemma-3-4b-it-q4_k_m")
  #expect(metal["HF_REPO"] == "ggml-org/gemma-3-4b-it-GGUF" && metal["HF_DOWNLOAD_ID"] == "dl-1234abcd")
  #expect(metal["UPSTREAM_MODEL"] == nil)
  // The image adapter is passed to llama-server.
  let args = try #require(metal["SERVER_ARGS_JSON"])
  let decoded = try JSONSerialization.jsonObject(with: Data(args.utf8)) as? [String]
  #expect(decoded == ["--mmproj", "/Users/test/My Models/ggml-org/gemma-3-4b-it-GGUF/mmproj-model-f16.gguf"])
  // Intel Macs and processor-only hosts.
  let intel = HFProfileMaker.values(ggufInputs(accelerator: "cpu", projector: nil))
  #expect(intel["GPU_LAYERS"] == "0" && intel["THREADS"] == "6" && intel["SERVER_ARGS_JSON"] == nil)
}

@Test func hfProfileSettingsSurviveSavingAndReloading() throws {
  try withFixtureRoot { fixture in
    let values = HFProfileMaker.values(ggufInputs(accelerator: "metal"))
    try fixture.service.saveProfile(name: "gemma-3-4b-it-q4_k_m", values: values, createOnly: true)
    let profile = try fixture.service.profiles.profile(named: "gemma-3-4b-it-q4_k_m")
    for (key, value) in values { #expect(profile[key] == value, "\(key)") }
    #expect(profile.runtime == "llama.cpp" && profile.requestModel == "gemma-3-4b-it")
    #expect(profile.endpointIdentity == "localhost:8085")
    // Controller and launcher agree on the log file.
    #expect(profile.logPath == "/tmp/gemma-3-4b-it-q4_k_m.log")
  }
}

@Test func hfProfileSettingsForMLX() {
  var inputs = ggufInputs(accelerator: "metal", projector: nil)
  inputs.job.format = "mlx"
  inputs.job.engine = "mlx-lm"
  inputs.job.mainFile = nil
  inputs.resolvedFolder = "/private/tmp/mlx-model"
  inputs.enginePath = "/opt/homebrew/bin/mlx_lm.server"
  let values = HFProfileMaker.values(inputs)
  #expect(values["RUNTIME"] == "mlx" && values["MODEL_DIR"] == inputs.job.folder)
  #expect(values["SERVER_MODEL_ID"] == "/private/tmp/mlx-model" && values["UPSTREAM_MODEL"] == "default_model")
  #expect(values["REQUEST_MODEL"] == "gemma-3-4b-it" && values["MODEL_ALIAS"] == nil && values["MODEL_PATH"] == nil)
  #expect(values["SERVER_BIN"] == "/opt/homebrew/bin/mlx_lm.server" && values["GPU_LAYERS"] == nil)
  // Resolved like Python's Path.resolve(), keeping /private.
  #expect(HFLocalMemory.realPath("/tmp") == "/private/tmp")
}

@Test func hfStartFailureSuggestions() {
  #expect(HFProfileMaker.suggestion(log: ["error: couldn't bind HTTP server socket, address already in use"], engine: "llama.cpp", port: "8081").contains("Port 8081"))
  #expect(HFProfileMaker.suggestion(log: ["error: invalid argument: --flash-attn"], engine: "llama.cpp", port: nil).contains("engine update llama.cpp"))
  #expect(HFProfileMaker.suggestion(log: ["unknown model architecture: 'qwen3next'"], engine: "llama.cpp", port: nil).contains("can't run this model yet"))
  let refused = HFProfileMaker.suggestion(
    log: ["error while handling argument \"--reasoning\": error: unknown value for --reasoning: 'none'"], engine: "llama.cpp", port: nil)
  #expect(refused.contains("Change that setting in the profile") && refused.contains("engine update llama.cpp"))
  #expect(HFProfileMaker.suggestion(log: ["ggml_metal: failed to allocate buffer"], engine: "llama.cpp", port: nil).contains("Optimize"))
  #expect(HFProfileMaker.suggestion(log: ["all good?"], engine: "mlx-lm", port: nil) == "See the server log for details.")
  // "No such file" only means a missing model when the message is about a model file.
  #expect(
    HFProfileMaker.suggestion(log: ["/x/start-model-mac.sh: No such file or directory"], engine: "llama.cpp", port: nil)
      .contains("start script is missing"))
  #expect(
    HFProfileMaker.suggestion(log: ["failed to open /m/Model-Q4_K_M.gguf: No such file or directory"], engine: "llama.cpp", port: nil)
      .contains("A model file is missing"))
  #expect(
    HFProfileMaker.suggestion(log: ["libfoo.dylib: No such file or directory"], engine: "llama.cpp", port: nil)
      == "A file the server needs is missing (see the log).")
}

// MARK: The profile step

@Test func hfDownloadedModelGetsAProfileStartsAndAnswers() throws {
  try withProfiles { fixture in
    let job = try fixture.completed()
    fixture.profiles.handle(job)
    fixture.settle()
    let done = try #require(fixture.downloads.manager.job(job.id))
    #expect(done.profileState == .ready)
    #expect(done.profile == "qwen2.5-7b-instruct-q4_k_m" && done.readyModel == "qwen2.5-7b-instruct")
    #expect(done.readyUrl == "http://127.0.0.1:7701/v1")
    #expect(done.profileMessage?.contains("Ready") == true)
    let values = try #require(fixture.host.profiles["qwen2.5-7b-instruct-q4_k_m"])
    #expect(values["SERVER_BIN"] == "/opt/homebrew/bin/llama-server" && values["PORT"] == "8081")
    #expect(fixture.host.started == ["qwen2.5-7b-instruct-q4_k_m"])
    #expect(fixture.chat.sent.map(\.model) == ["qwen2.5-7b-instruct"])
    #expect(fixture.chat.sent.first?.url.absoluteString == "http://127.0.0.1:7701/v1")
  }
}

@Test func hfProfileWaitsForAMissingEngineThenStarts() throws {
  try withProfiles(installed: false) { fixture in
    var job = try fixture.completed()
    let stale = HFProfileMaker.engineMissingWarning("llama.cpp")
    job = try #require(fixture.downloads.manager.update(job.id) { $0.warnings = [stale, "Other note"] })
    fixture.profiles.handle(job)
    fixture.settle()
    var current = try #require(fixture.downloads.manager.job(job.id))
    #expect(current.profileState == .needsEngine)
    #expect(current.profileMessage?.contains("modelmatrixctl engine install llama.cpp") == true)
    let name = try #require(current.profile)
    #expect(fixture.host.profiles[name]?["SERVER_BIN"] == nil)
    #expect(fixture.host.started.isEmpty)
    // The engine gets installed (by ModelMatrix after approval, or by hand).
    fixture.engines.installed = true
    fixture.profiles.recheckWaiting()
    fixture.settle()
    current = try #require(fixture.downloads.manager.job(job.id))
    #expect(current.profileState == .ready)
    // The "isn't installed yet" warning goes once the engine is found; others stay.
    #expect(current.warnings == ["Other note"])
    #expect(fixture.host.profiles[name]?["SERVER_BIN"] == "/opt/homebrew/bin/llama-server")
    #expect(fixture.host.started == [name])
  }
}

@Test func hfProfileWithoutStartIsOnlyCreatedUntilStarted() throws {
  try withProfiles { fixture in
    let job = try fixture.completed(startAfter: false)
    fixture.profiles.handle(job)
    fixture.settle()
    #expect(fixture.downloads.manager.job(job.id)?.profileState == .created)
    #expect(fixture.host.started.isEmpty)
    let starting = try fixture.profiles.start(job.id)
    #expect(starting.profileState == .starting)
    fixture.settle()
    #expect(fixture.downloads.manager.job(job.id)?.profileState == .ready)
    #expect(fixture.host.started.count == 1)
  }
}

@Test func hfProfileChecksFreeMemoryBeforeStarting() throws {
  try withProfiles(free: 2 << 30) { fixture in
    let job = try fixture.completed(need: 6 << 30)
    fixture.profiles.handle(job)
    fixture.settle()
    let waiting = try #require(fixture.downloads.manager.job(job.id))
    #expect(waiting.profileState == .needsMemory)
    #expect(waiting.profileMessage?.contains("Optimize") == true)
    #expect(fixture.host.started.isEmpty)
    // Starting by hand (after Optimize, or anyway) is the user's choice.
    _ = try fixture.profiles.start(job.id)
    fixture.settle()
    #expect(fixture.downloads.manager.job(job.id)?.profileState == .ready)
  }
}

@Test func hfProfileStartFailureShowsTheLogAndAFix() throws {
  let host = FakeProfileHost()
  host.startError = HFError.unavailable("Model server failed to become ready")
  host.log = ["llama_model_load: error loading model architecture", "unknown model architecture: 'qwen3next'"]
  try withProfiles(host: host) { fixture in
    let job = try fixture.completed()
    fixture.profiles.handle(job)
    fixture.settle()
    let failed = try #require(fixture.downloads.manager.job(job.id))
    #expect(failed.profileState == .startFailed)
    #expect(failed.profileMessage?.contains("didn't start") == true)
    #expect(failed.profileMessage?.contains("engine update llama.cpp") == true)
    #expect(failed.profileLog == host.log)
    #expect(fixture.chat.sent.isEmpty)
    #expect(HFDownloadText.render(failed).contains("Last lines of the server log:"))
  }
}

@Test func hfProfileTestRetriesWhileTheRelayCatchesUp() throws {
  let busy = HFChatTestError(message: "HTTP 503 no running model server", retryable: true)
  try withProfiles(chat: FakeChat([.failure(busy), .failure(busy), .success("ready")])) { fixture in
    let job = try fixture.completed()
    fixture.profiles.handle(job)
    fixture.settle()
    #expect(fixture.downloads.manager.job(job.id)?.profileState == .ready)
    #expect(fixture.chat.sent.count == 3)
  }
  let broken = HFChatTestError(message: "HTTP 500 model crashed", retryable: false)
  try withProfiles(chat: FakeChat([.failure(broken)])) { fixture in
    let job = try fixture.completed()
    fixture.profiles.handle(job)
    fixture.settle()
    let failed = try #require(fixture.downloads.manager.job(job.id))
    #expect(failed.profileState == .startFailed)
    #expect(failed.profileMessage?.contains("test message failed: HTTP 500 model crashed") == true)
    #expect(fixture.chat.sent.count == 1)
  }
}

@Test func hfProfileTestWithoutTheRelayUsesTheServerDirectly() throws {
  try withProfiles(relay: nil) { fixture in
    let mlx = try fixture.completed(
      repo: "mlx-community/Qwen2.5-7B-Instruct-4bit", label: "4bit", format: "mlx",
      files: [("config.json", 10), ("model.safetensors", 3_000)])
    fixture.profiles.handle(mlx)
    fixture.settle()
    let done = try #require(fixture.downloads.manager.job(mlx.id))
    #expect(done.profileState == .ready && done.readyUrl == "http://127.0.0.1:8081/v1")
    // mlx-lm only accepts its reserved name for the model it was started with.
    #expect(fixture.chat.sent.last?.model == "default_model")
    let values = try #require(done.profile.flatMap { fixture.host.profiles[$0] })
    #expect(values["SERVER_BIN"] == "/opt/homebrew/bin/mlx_lm.server" && values["RUNTIME"] == "mlx")
    #expect(values["SERVER_MODEL_ID"] == HFLocalMemory.realPath(mlx.folder))
  }
}

@Test func hfSeveralVersionsGetDistinctNamesAndPorts() throws {
  try withProfiles(busyPorts: [8082]) { fixture in
    let first = try fixture.completed(label: "Q4_K_M")
    let second = try fixture.completed(label: "Q8_0", files: [("Qwen2.5-7B-Instruct-Q8_0.gguf", 5_000)])
    fixture.profiles.handle(first)
    fixture.profiles.handle(second)
    fixture.settle()
    let a = try #require(fixture.downloads.manager.job(first.id))
    let b = try #require(fixture.downloads.manager.job(second.id))
    #expect(a.readyModel == "qwen2.5-7b-instruct" && b.readyModel == "qwen2.5-7b-instruct-q8_0")
    #expect(fixture.host.profiles[a.profile ?? ""]?["PORT"] == "8081")
    #expect(fixture.host.profiles[b.profile ?? ""]?["PORT"] == "8083")  // 8082 is busy
  }
}

@Test func hfOllamaDownloadIsTestedWithoutAProfile() throws {
  try withProfiles { fixture in
    var job = HFDownloadJob(
      id: HFDownloadJob.newID(), kind: "ollama", repo: "bartowski/Qwen2.5-7B-Instruct-GGUF", revision: "abc123",
      label: "Q4_K_M", format: "gguf", engine: "ollama", displayName: "Qwen", folder: "", files: [], context: 8192,
      startAfter: true)
    job.state = .completed
    job.ollamaModel = "hf.co/bartowski/Qwen2.5-7B-Instruct-GGUF:Q4_K_M"
    try fixture.downloads.manager.add(job)
    fixture.profiles.handle(job)
    fixture.settle()
    let done = try #require(fixture.downloads.manager.job(job.id))
    #expect(done.profileState == .ready && done.profile == nil)
    #expect(done.readyModel == "hf.co/bartowski/Qwen2.5-7B-Instruct-GGUF:Q4_K_M")
    #expect(fixture.host.profiles.isEmpty)
    // Deleting its files asks Ollama to delete the model.
    let result = try fixture.profiles.delete(job.id, deleteFiles: true)
    #expect(fixture.removed.all == ["hf.co/bartowski/Qwen2.5-7B-Instruct-GGUF:Q4_K_M"] && !result.keptInOllama)
  }
}

@Test func hfOllamaModelTheUserAlreadyHadIsNeverDeleted() throws {
  try withProfiles { fixture in
    var job = HFDownloadJob(
      id: HFDownloadJob.newID(), kind: "ollama", repo: "bartowski/Qwen2.5-7B-Instruct-GGUF", revision: "abc123",
      label: "Q4_K_M", format: "gguf", engine: "ollama", displayName: "Qwen", folder: "", files: [], context: 8192,
      startAfter: false)
    job.state = .completed
    job.ollamaModel = "hf.co/bartowski/Qwen2.5-7B-Instruct-GGUF:Q4_K_M"
    job.ollamaHadModel = true
    try fixture.downloads.manager.add(job)
    let result = try fixture.profiles.delete(job.id, deleteFiles: true)
    #expect(result.keptInOllama && result.freedBytes == 0)
    #expect(fixture.removed.all.isEmpty)
    #expect(fixture.downloads.manager.job(job.id) == nil)
  }
}

@Test func hfOllamaPullRecordsWhetherTheModelWasAlreadyThere() {
  #expect(HFOllamaClient.normalized("HF.co/Owner/Name:Q4_K_M") == "hf.co/owner/name:q4_k_m")
  #expect(HFOllamaClient.normalized("llama3:latest") == "llama3")
}

@Test func hfRestartTurnsAnInterruptedStartIntoCreated() throws {
  try withProfiles { fixture in
    var job = try fixture.completed()
    job.profile = "qwen2.5-7b-instruct-q4_k_m"
    fixture.downloads.manager.update(job.id) {
      $0.profile = job.profile
      $0.profileState = nil
    }
    fixture.profiles.resumeAfterRestart()
    fixture.settle()
    #expect(fixture.downloads.manager.job(job.id)?.profileState == .created)
    #expect(fixture.host.started.isEmpty)
  }
}

// MARK: Downloaded models and deleting

@Test func hfDeletingAModelKeepsFilesAnotherVersionUses() throws {
  try withProfiles { fixture in
    let repo = "ggml-org/gemma-3-4b-it-GGUF"
    let a = try fixture.completed(
      repo: repo, label: "Q4_K_M", files: [("gemma-Q4_K_M.gguf", 4_000), ("mmproj-model-f16.gguf", 900)],
      projector: "mmproj-model-f16.gguf")
    let b = try fixture.completed(
      repo: repo, label: "Q8_0", files: [("gemma-Q8_0.gguf", 7_000), ("mmproj-model-f16.gguf", 900)],
      projector: "mmproj-model-f16.gguf")
    fixture.profiles.handle(a)
    fixture.profiles.handle(b)
    fixture.settle()
    let folder = URL(fileURLWithPath: a.folder)
    let profileA = try #require(fixture.downloads.manager.job(a.id)?.profile)
    // A: its own file goes, the shared image adapter stays for B.
    let first = try fixture.profiles.delete(a.id, deleteFiles: true)
    #expect(first.profile == profileA && first.freedBytes == 4_000)
    #expect(fixture.host.profiles[profileA] == nil && fixture.downloads.manager.job(a.id) == nil)
    #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("gemma-Q4_K_M.gguf").path))
    #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("mmproj-model-f16.gguf").path))
    // B without files: profile goes, files stay.
    let kept = try fixture.profiles.delete(b.id, deleteFiles: false)
    #expect(kept.freedBytes == 0)
    #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("gemma-Q8_0.gguf").path))
  }
  try withProfiles { fixture in
    let job = try fixture.completed(files: [("sub/model-00001-of-00002.gguf", 100), ("sub/model-00002-of-00002.gguf", 100)])
    let freed = try fixture.profiles.delete(job.id, deleteFiles: true).freedBytes
    #expect(freed == 200)
    // The empty repo and owner folders are removed; the models folder stays.
    #expect(!FileManager.default.fileExists(atPath: job.folder))
    #expect(FileManager.default.fileExists(atPath: fixture.downloads.models.path))
  }
}

@Test func hfDeletingRefusesWhileDownloadingOrStarting() throws {
  try withProfiles { fixture in
    let job = try fixture.completed()
    fixture.downloads.manager.update(job.id) { $0.state = .downloading }
    #expect(throws: HFError.self) { try fixture.profiles.delete(job.id, deleteFiles: true) }
    fixture.downloads.manager.update(job.id) {
      $0.state = .completed
      $0.profileState = .starting
    }
    #expect(throws: HFError.self) { try fixture.profiles.delete(job.id, deleteFiles: true) }
    #expect(throws: HFError.self) { try fixture.profiles.delete("dl-missing", deleteFiles: false) }
  }
}

@Test func hfDownloadedModelsShowDiskUsageAndOtherFolders() throws {
  try withProfiles { fixture in
    let job = try fixture.completed(files: [("a.gguf", 1_500), ("b.gguf", 500)])
    let other = fixture.downloads.models.appendingPathComponent("someone/hand-copied", isDirectory: true)
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    try testBytes(700).write(to: other.appendingPathComponent("x.gguf"))
    try FileManager.default.removeItem(at: job.fileURL(job.files[1]))
    let found = fixture.profiles.downloadedModels()
    #expect(found.models.count == 1)
    #expect(found.models[0].bytesOnDisk == 1_500 && found.models[0].missingFiles == 1)
    #expect(found.models[0].profile == nil)
    #expect(found.untracked.count == 1 && found.untracked[0].folder.hasSuffix("someone/hand-copied"))
    let text = HFProfileText.render(found.models, untracked: found.untracked)
    #expect(text.contains("Downloaded models (1,") && text.contains("1 file(s) are missing"))
    #expect(text.contains("not downloaded by ModelMatrix, left untouched"))
  }
}

// MARK: Relay and routes

@Test func hfRelaySendsTheServersOwnModelName() throws {
  let body = Data(#"{"model":"qwen2.5-7b-instruct","messages":[{"role":"user","content":"hi"}],"stream":true}"#.utf8)
  let rewritten = try #require(RelayConnection.replacingModel(in: body, with: "default_model"))
  let object = try #require(try JSONSerialization.jsonObject(with: rewritten) as? [String: Any])
  #expect(object["model"] as? String == "default_model" && object["stream"] as? Bool == true)
  #expect((object["messages"] as? [[String: String]])?.first?["content"] == "hi")
  #expect(RelayConnection.replacingModel(in: Data(#"{"prompt":"x"}"#.utf8), with: "y") == nil)
  #expect(RelayConnection.replacingModel(in: Data("not json".utf8), with: "y") == nil)
  let profile = "RUNTIME=mlx\nPORT=18090\nBASE_URL=http://127.0.0.1:18090/v1\nREQUEST_MODEL=qwen\nUPSTREAM_MODEL=default_model\nMODEL_DIR=/tmp/x\n"
  try withFixtureRoot(profileBodies: ["mlx-test": profile]) { fixture in
    let status = try #require(try fixture.service.statusPayload(selected: ["mlx-test"]).statuses.first)
    let loaded = try fixture.service.profiles.profile(named: "mlx-test")
    let target = try #require(RelayTarget.from(status: status, profile: loaded, activeProfile: nil))
    #expect(target.upstreamModel == "default_model" && target.models.contains("qwen"))
  }
}

@Test func hfModelRoutes() throws {
  try withFixtureRoot { fixture in
    let (hub, directory) = makeHub()
    defer { try? FileManager.default.removeItem(at: directory) }
    let models = directory.appendingPathComponent("Models", isDirectory: true)
    try hub.settings.update { $0.modelsFolder = models.path }
    let host = FakeProfileHost()
    hub.profiles.host = host
    let router = ControllerRouter(service: fixture.service, authToken: nil, hub: hub)
    func call(_ method: String, _ target: String, _ body: [String: Any]? = nil) -> (Int, [String: Any], String) {
      let data = body.map { try! JSONSerialization.data(withJSONObject: $0) } ?? Data()
      let response = router.handle(.init(method: method, target: target, headers: ["Content-Type": "application/json"], body: data))
      let text = String(decoding: response.body, as: UTF8.self)
      return (response.status, (try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]) ?? [:], text)
    }
    #expect((call("GET", "/api/hf/models").1["models"] as? [Any])?.isEmpty == true)
    #expect(call("GET", "/api/hf/models?format=text").2.contains("No downloaded models yet"))
    // A finished download.
    let folder = models.appendingPathComponent("test/model", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try testBytes(1_000).write(to: folder.appendingPathComponent("m.gguf"))
    var job = HFDownloadJob(
      id: HFDownloadJob.newID(), kind: "files", repo: "test/model", revision: "abc", label: "Q4_K_M", format: "gguf",
      engine: "llama.cpp", displayName: "model", folder: folder.path,
      files: [HFDownloadFile(path: "m.gguf", size: 1_000, sha256: nil)], context: 4096, startAfter: false)
    job.state = .completed
    job.files[0].done = true
    job.mainFile = "m.gguf"
    try hub.downloads.add(job)
    let listed = try #require((call("GET", "/api/hf/models").1["models"] as? [[String: Any]])?.first)
    #expect(listed["id"] as? String == job.id && listed["bytes_on_disk"] as? Int == 1_000)
    // Start: answers at once; the profile step runs in the background.
    let (started, body, _) = call("POST", "/api/hf/downloads/\(job.id)/start")
    #expect(started == 202 && (body["download"] as? [String: Any])?["profile_state"] as? String == "starting")
    hub.profiles.queue.sync {}
    // This fake Mac has no llama.cpp, so the new profile waits for it.
    #expect(hub.downloads.job(job.id)?.profileState == .needsEngine && host.profiles.count == 1)
    #expect(call("GET", "/api/hf/downloads/\(job.id)?format=text").2.contains("waiting for the engine"))
    // Delete with files.
    #expect(call("POST", "/api/hf/models/delete", [:]).0 == 400)
    let (deleted, answer, _) = call("POST", "/api/hf/models/delete", ["id": job.id, "delete_files": true])
    #expect(deleted == 200 && answer["freed_bytes"] as? Int == 1_000 && answer["files_deleted"] as? Bool == true)
    #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("m.gguf").path))
    #expect(call("POST", "/api/hf/models/delete", ["id": job.id]).0 == 404)
    #expect(call("POST", "/api/hf/downloads/dl-missing/start").0 == 404)
  }
}

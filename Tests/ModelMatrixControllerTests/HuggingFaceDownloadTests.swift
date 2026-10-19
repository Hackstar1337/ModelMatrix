import Foundation
import Testing
@testable import ModelMatrixControllerCore

// MARK: Pieces and saved progress

@Test func hfPiecesCoverTheFileExactly() {
  let small = HFFileTransfer.pieces(size: 1000, connections: 4, threshold: 4096, minimum: 1024)
  #expect(small == [.init(start: 0, end: 999, next: 0)])
  let large = HFFileTransfer.pieces(size: 10_000_001, connections: 4, threshold: 4096, minimum: 1024)
  #expect(large.count == 4)
  #expect(HFFileTransfer.valid(large, size: 10_000_001))
  #expect(large.last?.end == 10_000_000)
  // Never more pieces than the minimum piece size allows.
  #expect(HFFileTransfer.pieces(size: 5000, connections: 8, threshold: 4096, minimum: 2048).count == 2)
  #expect(!HFFileTransfer.valid([.init(start: 0, end: 10, next: 0), .init(start: 12, end: 20, next: 12)], size: 21))
  #expect(HFFileTransfer.contentRangeStart("bytes 100-199/1000") == 100)
}

@Test func hfDownloadsAndVerifiesFilesInPieces() throws {
  let big = testBytes(1_200_000)
  let small = Data("{\"a\":1}".utf8)
  try withDownloads(files: ["model.gguf": big, "sub/config.json": small]) { env in
    var job = env.job([("model.gguf", big), ("sub/config.json", small)])
    job.files[1].sha256 = nil  // small files are checked by size
    try env.manager.add(job)
    env.manager.runQueueForTesting()
    let done = try #require(env.manager.job(job.id))
    #expect(done.state == .completed)
    #expect(done.bytesDone == done.bytesTotal)
    #expect(try Data(contentsOf: done.fileURL(done.files[0])) == big)
    #expect(try Data(contentsOf: done.fileURL(done.files[1])) == small)
    #expect(partFiles(in: env.models).isEmpty)
    // The big file used 4 parallel pieces; every request asked for a range.
    let ranges = env.streamer.requests.filter { $0.url.path.hasSuffix("model.gguf") }.map(\.range)
    #expect(ranges.count == 4)
    #expect(env.streamer.requests.allSatisfy { $0.headers["Range"]?.hasPrefix("bytes=") == true })
    #expect(env.streamer.requests[0].url.absoluteString.contains("/test/model/resolve/abc123/"))
    // Saved to disk for restarts.
    let saved = try Data(contentsOf: env.root.appendingPathComponent("downloads.json"))
    #expect(String(decoding: saved, as: UTF8.self).contains("\"state\" : \"completed\""))
  }
}

@Test func hfResumesFromWhereAConnectionDropped() throws {
  let bytes = testBytes(200_000)
  try withDownloads(files: ["m.gguf": bytes], faults: [.drop(after: 90_000)], connections: 1) { env in
    let job = env.job([("m.gguf", bytes)])
    try env.manager.add(job)
    env.manager.runQueueForTesting()
    #expect(env.manager.job(job.id)?.state == .completed)
    let requests = env.streamer.requests
    #expect(requests.count == 2)
    #expect(requests[1].range.lowerBound == 90_000)  // continued, not restarted
    #expect(try Data(contentsOf: job.fileURL(job.files[0])) == bytes)
    #expect(env.clock.total >= 1)  // waited before retrying
  }
}

@Test func hfContinuesAfterAControllerRestart() throws {
  let bytes = testBytes(300_000)
  try withDownloads(files: ["m.gguf": bytes], connections: 1) { env in
    let job = env.job([("m.gguf", bytes)])
    let manager = env.manager
    env.streamer.add([.hook(after: 128 * 1024) { _ = try? manager.pause(job.id) }])
    try manager.add(job)
    manager.runQueueForTesting()
    #expect(manager.job(job.id)?.state == .paused)
    #expect(partFiles(in: env.models).count == 2)  // .part and its progress file

    // A new controller process reads the saved queue and continues.
    let reopened = env.reopen()
    reopened.start()
    #expect(reopened.job(job.id)?.state == .paused)
    _ = try reopened.resume(job.id)
    let deadline = Date().addingTimeInterval(20)
    while reopened.job(job.id)?.state != .completed, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
    #expect(reopened.job(job.id)?.state == .completed)
    #expect(env.streamer.requests.last!.range.lowerBound >= 128 * 1024)
    #expect(try Data(contentsOf: job.fileURL(job.files[0])) == bytes)
  }
}

@Test func hfDamagedFilesAreDownloadedAgainThenFail() throws {
  let bytes = testBytes(100_000)
  try withDownloads(files: ["m.gguf": bytes], faults: [.corrupt], connections: 1) { env in
    let job = env.job([("m.gguf", bytes)])
    try env.manager.add(job)
    env.manager.runQueueForTesting()
    #expect(env.manager.job(job.id)?.state == .completed)
    #expect(env.streamer.requests.count == 2)
    #expect(env.streamer.requests[1].range.lowerBound == 0)
  }
  try withDownloads(files: ["m.gguf": bytes], faults: [.corrupt, .corrupt], connections: 1) { env in
    let job = env.job([("m.gguf", bytes)])
    try env.manager.add(job)
    env.manager.runQueueForTesting()
    let failed = try #require(env.manager.job(job.id))
    #expect(failed.state == .failed)
    #expect(failed.error?.contains("damaged twice") == true)
    #expect(!FileManager.default.fileExists(atPath: job.fileURL(job.files[0]).path))
    #expect(partFiles(in: env.models).isEmpty)
  }
}

@Test func hfHandlesExpiredLinksRateLimitsAndIgnoredRanges() throws {
  let bytes = testBytes(150_000)
  let faults: [FakeByteStreamer.Fault] = [
    .status(403, headers: [:], host: "cas-bridge.example"),  // signed link expired
    .status(429, headers: ["Retry-After": "7"], host: "huggingface.co"),
    .status(503, headers: [:], host: "huggingface.co"),
  ]
  try withDownloads(files: ["m.gguf": bytes], faults: faults, connections: 1) { env in
    let job = env.job([("m.gguf", bytes)])
    try env.manager.add(job)
    env.manager.runQueueForTesting()
    #expect(env.manager.job(job.id)?.state == .completed)
    #expect(env.streamer.requests.count == 4)
    #expect(env.clock.total >= 7)  // honoured Retry-After
  }
  // A server that ignores ranges is fine for a fresh single-piece file...
  try withDownloads(files: ["m.gguf": bytes], faults: [.ignoreRange], connections: 1) { env in
    let job = env.job([("m.gguf", bytes)])
    try env.manager.add(job)
    env.manager.runQueueForTesting()
    #expect(env.manager.job(job.id)?.state == .completed)
    #expect(try Data(contentsOf: job.fileURL(job.files[0])) == bytes)
  }
  // ...but resuming from it restarts the file instead of mixing bytes.
  try withDownloads(files: ["m.gguf": bytes], faults: [.drop(after: 50_000), .ignoreRange], connections: 1) { env in
    let job = env.job([("m.gguf", bytes)])
    try env.manager.add(job)
    env.manager.runQueueForTesting()
    #expect(env.manager.job(job.id)?.state == .completed)
    #expect(env.streamer.requests.map(\.range.lowerBound) == [0, 50_000, 0])
    #expect(try Data(contentsOf: job.fileURL(job.files[0])) == bytes)
  }
}

@Test func hfGivesUpWithClearMessages() throws {
  let bytes = testBytes(10_000)
  let gated: [FakeByteStreamer.Fault] = [.status(401, headers: ["X-Error-Code": "GatedRepo"], host: "huggingface.co")]
  try withDownloads(files: ["m.gguf": bytes], faults: gated, connections: 1) { env in
    let job = env.job([("m.gguf", bytes)])
    try env.manager.add(job)
    env.manager.runQueueForTesting()
    let failed = try #require(env.manager.job(job.id))
    #expect(failed.state == .failed)
    #expect(failed.error?.contains("Hugging Face login") == true)
    #expect(env.streamer.requests.count == 1)  // no pointless retries
  }
  let errors = Array(repeating: FakeByteStreamer.Fault.status(500, headers: [:], host: "huggingface.co"), count: 20)
  try withDownloads(files: ["m.gguf": bytes], faults: errors, connections: 1) { env in
    let job = env.job([("m.gguf", bytes)])
    try env.manager.add(job)
    env.manager.runQueueForTesting()
    let failed = try #require(env.manager.job(job.id))
    #expect(failed.state == .failed)
    #expect(failed.error?.contains("Gave up after 10 attempts") == true)
    #expect(env.clock.total <= 10 * 60)  // pauses grow but never above a minute
    // Resume starts over with fresh attempts.
    env.streamer.add([])
    _ = try env.manager.resume(job.id)
    #expect(env.manager.job(job.id)?.state == .queued)
  }
}

@Test func hfWaitsForTheNetworkAndForDiskSpace() throws {
  let bytes = testBytes(120_000)
  try withDownloads(files: ["m.gguf": bytes], faults: [.drop(after: 40_000)], connections: 1) { env in
    let job = env.job([("m.gguf", bytes)])
    env.network.set(false)
    let network = env.network
    let manager = env.manager
    env.clock.onWait = { count in
      if count == 1 { #expect(manager.job(job.id)?.waitingFor == "network") }
      if count == 3 { network.set(true) }
    }
    try manager.add(job)
    manager.runQueueForTesting()
    #expect(manager.job(job.id)?.state == .completed)
    #expect(env.clock.count >= 3)
  }
  try withDownloads(files: ["m.gguf": bytes], connections: 1, freeSpace: FreeSpace([1 << 30, 1 << 30])) { env in
    let job = env.job([("m.gguf", bytes)])
    let manager = env.manager
    env.clock.onWait = { count in
      if count == 1 {
        let waiting = manager.job(job.id)
        #expect(waiting?.state == .waiting && waiting?.waitingFor == "disk")
        #expect(waiting?.message?.contains("Waiting for disk space") == true)
      }
    }
    try manager.add(job)
    manager.runQueueForTesting()
    #expect(manager.job(job.id)?.state == .completed)
  }
}

@Test func hfReusesVerifiedFilesInsteadOfDownloading() throws {
  let bytes = testBytes(80_000)
  try withDownloads(files: ["m.gguf": bytes], connections: 1) { env in
    let first = env.job([("m.gguf", bytes)])
    try env.manager.add(first)
    env.manager.runQueueForTesting()
    #expect(env.streamer.requests.count == 1)
    // Same file in another repository: cloned from the first, not downloaded.
    let second = env.job([("m.gguf", bytes)], repo: "other/copy")
    try env.manager.add(second)
    env.manager.runQueueForTesting()
    let copied = try #require(env.manager.job(second.id))
    #expect(copied.state == .completed && copied.files[0].reused == "copy")
    #expect(env.streamer.requests.count == 1)
    #expect(try Data(contentsOf: copied.fileURL(copied.files[0])) == bytes)
    // Already in place (e.g. downloaded again after removing the entry).
    try env.manager.remove(first.id)
    let again = env.job([("m.gguf", bytes)])
    try env.manager.add(again)
    env.manager.runQueueForTesting()
    #expect(env.manager.job(again.id)?.files[0].reused == "existing")
    #expect(env.streamer.requests.count == 1)
    // A different file with the same name is not mistaken for it.
    let changed = testBytes(80_000, seed: 9)
    env.streamer.files["m.gguf"] = changed
    let newer = env.job([("m.gguf", changed)])
    try env.manager.add(newer)
    env.manager.runQueueForTesting()
    #expect(env.manager.job(newer.id)?.files[0].reused == nil)
    #expect(try Data(contentsOf: newer.fileURL(newer.files[0])) == changed)
  }
}

@Test func hfPauseResumeAndCancel() throws {
  let bytes = testBytes(400_000)
  try withDownloads(files: ["m.gguf": bytes], connections: 1) { env in
    let manager = env.manager
    let job = env.job([("m.gguf", bytes)])
    env.streamer.add([.hook(after: 100_000) { _ = try? manager.cancel(job.id, deleteFiles: true) }])
    try manager.add(job)
    #expect(throws: HFError.self) { try manager.remove(job.id) }  // active: cancel first
    manager.runQueueForTesting()
    let cancelled = try #require(manager.job(job.id))
    #expect(cancelled.state == .cancelled)
    #expect(partFiles(in: env.models).isEmpty)
    #expect(!FileManager.default.fileExists(atPath: job.folderURL.path))
    #expect(throws: HFError.self) { try manager.pause(job.id) }
    try manager.remove(job.id)
    #expect(manager.job(job.id) == nil)
    #expect(throws: HFError.self) { try manager.pause("dl-missing") }
  }
}

@Test func hfSpeedLimitAndTokenScope() throws {
  let limiter = HFRateLimiter(bytesPerSecond: 1_000_000)
  let start = Date()
  for _ in 0..<5 { limiter.consume(500_000) }
  #expect(Date().timeIntervalSince(start) >= 1.4)  // 2.5 MB at 1 MB/s, after the first second's allowance

  // The token goes to Hugging Face only, never to a download server.
  let bytes = testBytes(1000)
  try withDownloads(files: ["m.gguf": bytes], connections: 1, token: "hf_secret_token") { env in
    let job = env.job([("m.gguf", bytes)])
    try env.manager.add(job)
    env.manager.runQueueForTesting()
    #expect(env.streamer.requests[0].headers["Authorization"] == "Bearer hf_secret_token")
    #expect(!String(decoding: try Data(contentsOf: env.root.appendingPathComponent("downloads.json")), as: UTF8.self).contains("hf_secret"))
  }
  var request = URLRequest(url: URL(string: "https://cas-bridge.example/file")!)
  request.setValue("Bearer x", forHTTPHeaderField: "Authorization")
  #expect(HFRedirect.stripCredentials(request, originalHost: "huggingface.co").value(forHTTPHeaderField: "Authorization") == nil)
  #expect(HFRedirect.stripCredentials(request, originalHost: "cas-bridge.example").value(forHTTPHeaderField: "Authorization") == "Bearer x")
}

// MARK: Settings

@Test func hfSettingsValidateAndPersist() throws {
  let file = FileManager.default.temporaryDirectory.appendingPathComponent("mm-settings-\(UUID().uuidString).json")
  defer { try? FileManager.default.removeItem(at: file) }
  let store = HFSettingsStore(file: file)
  #expect(store.current.modelsFolder == "~/ModelMatrix/Models")
  let next = try store.current.applying([
    "endpoint": "https://hf-mirror.com/", "connections_per_file": 6, "speed_limit_mbps": 12.5, "keep_awake": false,
  ])
  #expect(next.endpoint == "https://hf-mirror.com" && next.connectionsPerFile == 6 && next.speedLimitMBps == 12.5)
  try store.save(next)
  #expect(HFSettingsStore(file: file).current == next)
  for bad: [String: Any] in [
    ["connections_per_file": 0], ["connections_per_file": 9], ["speed_limit_mbps": -1], ["endpoint": "ftp://x"],
    ["models_folder": "relative/path"], ["models_folder": "/a/../b"], ["engine_paths": ["llama.cpp": "/nope"]],
    ["engine_paths": ["vllm": "/bin/sh"]], ["unknown": 1],
  ] {
    #expect(throws: HFError.self) { try next.applying(bad) }
  }
  #expect(try next.applying(["endpoint": NSNull()]).endpoint == nil)
  #expect(try next.applying(["engine_paths": ["llama.cpp": "/bin/sh"]]).enginePaths == ["llama.cpp": "/bin/sh"])
}

// MARK: Planning a download from a check

func makeHub(
  machine: HFMachine = .sample(memoryGiB: 48), engines: FakeEngineEnvironment = .homebrewOnly,
  free: Int64 = 1 << 42, transport: FakeHFTransport = FakeHFTransport()
) -> (HFHub, URL) {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mm-hub-\(UUID().uuidString)")
  let hub = HFHub(
    directory: directory, check: makeCheckService(transport: transport, engines: engines, machine: machine),
    tokenStore: HFMemoryTokenStore(), streamer: FakeByteStreamer(), network: FakeNetwork(),
    freeSpace: { _ in free }, pause: { _ in })
  return (hub, directory)
}

@Test func hfPlansTheRecommendedVersionWithItsFiles() throws {
  let (hub, directory) = makeHub()
  defer { try? FileManager.default.removeItem(at: directory) }
  let started = try hub.startDownload(.init(name: "bartowski/Qwen2.5-7B-Instruct-GGUF"))
  let job = started.job
  #expect(!started.existing && job.state == .queued)
  #expect(job.label == "Q8_0" && job.engine == "llama.cpp" && job.kind == "files")
  #expect(job.files.count == 1 && job.files[0].sha256?.count == 64)
  #expect(job.folder.hasSuffix("/ModelMatrix/Models/bartowski/Qwen2.5-7B-Instruct-GGUF"))
  #expect(job.revision.count == 40)  // pinned to the exact commit
  #expect(job.warnings.contains { $0.contains("llama.cpp isn't installed yet") })
  // Asking again returns the same download instead of a second copy.
  let again = try hub.startDownload(.init(name: "bartowski/Qwen2.5-7B-Instruct-GGUF"))
  #expect(again.existing && again.job.id == job.id)
  // A chosen version and the vision adapter.
  let small = try hub.startDownload(.init(name: "bartowski/Qwen2.5-7B-Instruct-GGUF", version: "q4_k_m")).job
  #expect(small.label == "Q4_K_M")
  let vision = try hub.startDownload(.init(name: "ggml-org/gemma-3-4b-it-GGUF")).job
  #expect(vision.vision && vision.projectorFile?.hasPrefix("mmproj") == true)
  #expect(vision.files.contains { $0.path == vision.projectorFile })
  // Split GGUF: every part, the first one is what llama.cpp opens.
  let (bigHub, bigDirectory) = makeHub(machine: .sample(memoryGiB: 192))
  defer { try? FileManager.default.removeItem(at: bigDirectory) }
  let split = try bigHub.startDownload(.init(name: "bartowski/Qwen2.5-72B-Instruct-GGUF", version: "Q8_0")).job
  #expect(split.files.count > 1 && split.mainFile?.contains("00001-of-") == true)
  #expect(throws: HFError.self) {
    try bigHub.startDownload(.init(name: "bartowski/Qwen2.5-72B-Instruct-GGUF", version: "Q8_0", engine: "ollama"))
  }
}

@Test func hfRefusesDownloadsThatCannotWorkHere() throws {
  let (hub, directory) = makeHub(machine: .sample(memoryGiB: 16))
  defer { try? FileManager.default.removeItem(at: directory) }
  func refusal(_ request: HFHub.DownloadRequest, _ hub: HFHub = hub) -> HFError? {
    do {
      _ = try hub.startDownload(request)
      return nil
    } catch let error as HFError {
      return error
    } catch {
      return nil
    }
  }
  #expect(refusal(.init(name: "bartowski/Qwen2.5-7B-Instruct-GGUF", version: "Q9_X"))?.description.contains("Versions:") == true)
  #expect(refusal(.init(name: "Qwen/Qwen2.5-7B-Instruct"))?.code == "refused")  // original weights
  #expect(refusal(.init(name: "openai/whisper-large-v3"))?.code == "refused")  // not a chat model
  #expect(refusal(.init(name: "qwen2.5 coder 7b"))?.code == "refused")  // a search, not one model
  #expect(refusal(.init(name: "meta-llama/Llama-3.1-8B-Instruct"))?.code != nil)
  #expect(refusal(.init(name: "bartowski/Qwen2.5-7B-Instruct-GGUF", engine: "mlx-lm"))?.code == "refused")
  #expect(refusal(.init(name: "bartowski/Qwen2.5-7B-Instruct-GGUF", engine: "ollama"))?.description.contains("Ollama isn't installed") == true)
  let (intel, intelDirectory) = makeHub(machine: .sample(memoryGiB: 32, appleSilicon: false))
  defer { try? FileManager.default.removeItem(at: intelDirectory) }
  #expect(refusal(.init(name: "mlx-community/Qwen2.5-7B-Instruct-4bit"), intel)?.code == "refused")
  let (full, fullDirectory) = makeHub(free: 3 << 30)
  defer { try? FileManager.default.removeItem(at: fullDirectory) }
  let disk = refusal(.init(name: "bartowski/Qwen2.5-7B-Instruct-GGUF"), full)
  #expect(disk?.code == "insufficient_disk" && disk?.httpStatus == 507)
  #expect(hub.downloads.list().isEmpty && full.downloads.list().isEmpty)
}

@Test func hfPlansMLXAndOllamaDownloads() throws {
  let (hub, directory) = makeHub(engines: .allInstalled)
  defer { try? FileManager.default.removeItem(at: directory) }
  let mlx = try hub.startDownload(.init(name: "mlx-community/Qwen2.5-7B-Instruct-4bit")).job
  #expect(mlx.engine == "mlx-lm" && mlx.format == "mlx")
  #expect(mlx.files.contains { $0.path == "config.json" } && mlx.files.contains { $0.path.hasSuffix(".safetensors") })
  #expect(!mlx.files.contains { $0.path.hasSuffix(".md") })
  #expect(mlx.warnings.isEmpty)
  let ollama = try hub.startDownload(.init(name: "bartowski/Qwen2.5-7B-Instruct-GGUF", version: "Q4_K_M", engine: "ollama")).job
  #expect(ollama.kind == "ollama" && ollama.ollamaModel == "hf.co/bartowski/Qwen2.5-7B-Instruct-GGUF:Q4_K_M")
  #expect(ollama.files.isEmpty && ollama.bytesTotal > 4_000_000_000)
}

final class FakeOllama: HFOllamaPulling, @unchecked Sendable {
  var pulled: [String] = []
  var failure: HFOllamaError?
  var existing: Set<String>?
  func hasModel(_ model: String) -> Bool? { existing.map { $0.contains(model) } }

  func pull(model: String, progress: @escaping (String, Int64, Int64) -> Void, shouldStop: @escaping () -> Bool) throws {
    pulled.append(model)
    if let failure { throw failure }
    progress("pulling manifest", 0, 0)
    progress("pulling 6a0746a1ec1a", 2_000, 4_000)
    progress("success", 4_000, 4_000)
  }
}

@Test func hfOllamaPullsReportProgress() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("mm-ollama-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: root) }
  let fake = FakeOllama()
  let manager = HFDownloadManager(
    file: root.appendingPathComponent("downloads.json"),
    settings: HFSettingsStore(file: root.appendingPathComponent("settings.json")),
    client: HFClient(endpoint: HFClient.defaultEndpoint, transport: FakeHFTransport()), streamer: FakeByteStreamer(),
    network: FakeNetwork(), freeSpace: { _ in 1 << 42 }, pause: { _ in }, ollama: fake)
  var job = HFDownloadJob(
    id: HFDownloadJob.newID(), kind: "ollama", repo: "a/b-GGUF", revision: "r", label: "Q4_K_M", format: "gguf",
    engine: "ollama", displayName: "b Q4_K_M", folder: "", files: [], context: 8192, startAfter: false)
  job.ollamaModel = "hf.co/a/b-GGUF:Q4_K_M"
  try manager.add(job)
  fake.existing = ["hf.co/a/b-GGUF:Q4_K_M"]
  manager.runQueueForTesting()
  #expect(fake.pulled == ["hf.co/a/b-GGUF:Q4_K_M"])
  #expect(manager.job(job.id)?.state == .completed && manager.job(job.id)?.bytesDone == 4_000)
  #expect(manager.job(job.id)?.ollamaHadModel == true)
  fake.failure = .notRunning
  fake.existing = nil
  var second = job
  second.id = HFDownloadJob.newID()
  second.ollamaHadModel = nil
  try manager.add(second)
  manager.runQueueForTesting()
  #expect(manager.job(second.id)?.state == .failed)
  #expect(manager.job(second.id)?.error?.contains("Ollama isn't running") == true)
  #expect(manager.job(second.id)?.ollamaHadModel == nil)
}

// MARK: Routes

@Test func hfDownloadRoutes() throws {
  try withFixtureRoot { fixture in
    let (hub, directory) = makeHub()
    defer { try? FileManager.default.removeItem(at: directory) }
    let router = ControllerRouter(service: fixture.service, authToken: nil, hub: hub)
    func call(_ method: String, _ target: String, _ body: [String: Any]? = nil) -> (Int, [String: Any]) {
      let data = body.map { try! JSONSerialization.data(withJSONObject: $0) } ?? Data()
      let response = router.handle(.init(method: method, target: target, headers: ["Content-Type": "application/json"], body: data))
      return (response.status, (try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]) ?? [:])
    }
    let (created, body) = call("POST", "/api/hf/downloads", ["name": "bartowski/Qwen2.5-7B-Instruct-GGUF", "version": "Q4_K_M"])
    #expect(created == 202)
    let download = try #require(body["download"] as? [String: Any])
    let id = try #require(download["id"] as? String)
    #expect(download["state"] as? String == "queued" && download["label"] as? String == "Q4_K_M")
    #expect(call("POST", "/api/hf/downloads", ["name": "bartowski/Qwen2.5-7B-Instruct-GGUF", "version": "Q4_K_M"]).0 == 200)
    #expect((call("GET", "/api/hf/downloads").1["downloads"] as? [[String: Any]])?.count == 1)
    #expect((call("GET", "/api/hf/downloads/\(id)").1["download"] as? [String: Any])?["id"] as? String == id)
    #expect((call("POST", "/api/hf/downloads/\(id)/pause").1["download"] as? [String: Any])?["state"] as? String == "paused")
    #expect((call("POST", "/api/hf/downloads/\(id)/resume").1["download"] as? [String: Any])?["state"] as? String == "queued")
    #expect(call("DELETE", "/api/hf/downloads/\(id)").0 == 409)
    #expect((call("POST", "/api/hf/downloads/\(id)/cancel", ["delete_files": true]).1["download"] as? [String: Any])?["state"] as? String == "cancelled")
    #expect(call("DELETE", "/api/hf/downloads/\(id)").0 == 200)
    #expect(call("GET", "/api/hf/downloads/\(id)").0 == 404)
    #expect(call("GET", "/api/hf/downloads/..%2F..%2Fetc").0 == 404)
    #expect(call("POST", "/api/hf/downloads/\(id)/explode").0 == 404)
    #expect(call("POST", "/api/hf/downloads", ["name": "bartowski/Qwen2.5-72B-Instruct-GGUF", "version": "F16"]).0 == 422)
    #expect(call("POST", "/api/hf/downloads", [:]).0 == 400)
    #expect(call("POST", "/api/hf/downloads", ["name": "a/b", "context": 10]).0 == 400)
    // Settings.
    #expect((call("GET", "/api/hf/settings").1["settings"] as? [String: Any])?["connections_per_file"] as? Int == 4)
    let (saved, settings) = call("PUT", "/api/hf/settings", ["speed_limit_mbps": 5])
    #expect(saved == 200 && (settings["settings"] as? [String: Any])?["speed_limit_mbps"] as? Double == 5)
    #expect(call("PUT", "/api/hf/settings", ["connections_per_file": 99]).0 == 400)
    #expect(call("POST", "/api/hf/token", ["token": "short"]).0 == 400)
    #expect(call("DELETE", "/api/hf/token").1["saved"] as? Bool == false)
  }
}

@Test func hfDownloadRoutesNeedTheControllerToken() throws {
  try withFixtureRoot { fixture in
    let (hub, directory) = makeHub()
    defer { try? FileManager.default.removeItem(at: directory) }
    let router = ControllerRouter(service: fixture.service, authToken: "secret", hub: hub)
    let body = try JSONSerialization.data(withJSONObject: ["name": "bartowski/Qwen2.5-7B-Instruct-GGUF"])
    #expect(router.handle(.init(method: "POST", target: "/api/hf/downloads", body: body)).status == 401)
    let crossSite = router.handle(.init(
      method: "POST", target: "/api/hf/downloads",
      headers: ["Origin": "https://evil.example.com", "Sec-Fetch-Site": "cross-site", "Authorization": "Bearer secret"],
      body: body))
    #expect(crossSite.status == 403)
    #expect(hub.downloads.list().isEmpty)
  }
}

// MARK: Regressions found in live testing

@Test func hfCancelThenRemoveStillDeletesPartialFiles() throws {
  let bytes = testBytes(400_000)
  try withDownloads(files: ["m.gguf": bytes], connections: 1) { env in
    let manager = env.manager
    let job = env.job([("m.gguf", bytes)])
    // Cancel, then remove the entry at once, while the transfer is still stopping.
    env.streamer.add([.hook(after: 100_000) {
      _ = try? manager.cancel(job.id, deleteFiles: true)
      try? manager.remove(job.id)
    }])
    try manager.add(job)
    manager.runQueueForTesting()
    #expect(manager.job(job.id) == nil)
    #expect(partFiles(in: env.models).isEmpty)
  }
  // A cancel the controller couldn't tidy before it stopped is finished at the next start.
  try withDownloads(files: ["m.gguf": bytes], connections: 1) { env in
    var job = env.job([("m.gguf", bytes)])
    job.state = .cancelled
    job.removeFilesOnCancel = true
    try FileManager.default.createDirectory(at: job.folderURL, withIntermediateDirectories: true)
    let part = HFFileTransfer.partURL(for: job.fileURL(job.files[0]))
    try Data(count: 10).write(to: part)
    try HFFiles.writeAtomically(try HFFiles.encoder.encode([job]), to: env.root.appendingPathComponent("downloads.json"))
    let reopened = env.reopen()
    reopened.start()
    #expect(!FileManager.default.fileExists(atPath: part.path))
    #expect(reopened.job(job.id)?.removeFilesOnCancel == false)
  }
}

@Test func hfTypedVersionLabelIsAnExplicitChoice() throws {
  let (hub, directory) = makeHub()
  defer { try? FileManager.default.removeItem(at: directory) }
  #expect(throws: HFError.self) { try hub.startDownload(.init(name: "bartowski/Qwen2.5-7B-Instruct-GGUF:Q9_X")) }
  #expect(hub.downloads.list().isEmpty)
  let typed = try hub.startDownload(.init(name: "bartowski/Qwen2.5-7B-Instruct-GGUF:Q4_K_M")).job
  #expect(typed.label == "Q4_K_M")
  do {
    _ = try hub.startDownload(.init(name: "Qwen/Qwen2.5-7B-Instruct"))
    Issue.record("original weights must be refused")
  } catch let error as HFError {
    #expect(error.description.contains("Ready-to-run versions: "))
    #expect(!error.description.contains("listed below"))
  }
}

@Test func hfSavedJobsKeepEveryFieldAfterAReload() throws {
  var job = HFDownloadJob(
    id: "dl-1", kind: "files", repo: "a/b-GGUF", revision: "r", label: "Q4_K_M", format: "gguf", engine: "llama.cpp",
    displayName: "b", folder: "/tmp/b", files: [HFDownloadFile(path: "b.gguf", size: 10, sha256: nil)], context: 8192,
    startAfter: true)
  job.readyUrl = "http://127.0.0.1:7701/v1"
  job.readyModel = "b"
  job.ollamaHadModel = false
  job.host = "gpu-box"
  job.memoryNeedBytes = 123
  let data = try HFFiles.encoder.encode([job])
  #expect(String(decoding: data, as: UTF8.self).contains("\"ready_url\""))
  let back = try #require(try HFFiles.decoder.decode([HFDownloadJob].self, from: data).first)
  #expect(back.readyUrl == "http://127.0.0.1:7701/v1" && back.readyModel == "b")
  #expect(back.ollamaHadModel == false && back.host == "gpu-box" && back.memoryNeedBytes == 123)
}

/// Found with a real full disk: one piece failed to write, the others were
/// told to stop, and their `.stopped` hid the disk error, so the job looked
/// like it was still downloading.
@Test func hfTransferReportsTheRealFailureNotTheOtherPiecesStopping() {
  let full = HFTransferError.disk("No space left on device")
  #expect(HFFileTransfer.decidingFailure([.stopped, full, .stopped], userStopped: false) == full)
  #expect(HFFileTransfer.decidingFailure([.stopped, .loginRequired, .network("x")], userStopped: false) == .loginRequired)
  #expect(HFFileTransfer.decidingFailure([.stopped, full], userStopped: true) == .stopped)
  #expect(HFFileTransfer.decidingFailure([.stopped], userStopped: false) == .network("a connection stopped early"))
  #expect(HFFileTransfer.decidingFailure([], userStopped: false) == nil)
}

import Foundation
import Testing
@testable import ModelMatrixControllerCore

@Test func hfSingleLowQualityVersionIsAdvisoryAndDownloadable() throws {
  let repo = "bartowski/Qwen2.5-7B-Instruct-GGUF"
  let transport = FakeHFTransport()
  let files: [[String: Any]] = [[
    "type": "file", "path": "model-IQ2_XXS.gguf", "size": 2_000_000_000,
    "lfs": ["oid": String(repeating: "a", count: 64), "size": 2_000_000_000],
  ]]
  transport.overrides["/api/models/\(repo)/tree/"] = HFHTTPResponse(
    status: 200, body: try JSONSerialization.data(withJSONObject: files))
  let (hub, directory) = makeHub(transport: transport)
  defer { try? FileManager.default.removeItem(at: directory) }
  let report = try hub.check.check(repo)
  #expect(report.variants.count == 1 && report.variants[0].label == "IQ2_XXS")
  #expect(report.verdict.code == "low_quality" && report.verdict.runnable)
  #expect(report.verdict.title.hasPrefix("Suggestion:"))
  #expect(report.downloadAvailable && report.downloadFolder != nil)
  #expect(report.recommendation == nil && !report.variants[0].recommended)
  #expect(report.variants[0].fit?.level == "good")
  let text = HFCheckText.render(report)
  #expect(text.contains("SUGGESTION:") && text.contains("\(repo):LABEL"))
  let job = try hub.startDownload(.init(name: repo, version: "IQ2_XXS", startAfter: false)).job
  #expect(job.state == .queued && job.label == "IQ2_XXS")
  #expect(job.warnings.contains { $0.contains("answer quality") })
  #expect(!job.warnings.contains { $0.contains("exceeds the estimated") })
}

@Test func hfOversizedExplicitVersionCanDownloadWithMemoryWarning() throws {
  let (hub, directory) = makeHub(machine: .sample(memoryGiB: 8))
  defer { try? FileManager.default.removeItem(at: directory) }
  let repo = "bartowski/Qwen2.5-72B-Instruct-GGUF"
  let report = try hub.check.check(repo, version: "Q8_0")
  #expect(report.verdict.code == "too_big" && !report.verdict.runnable)
  #expect(report.verdict.title.hasPrefix("Suggestion:") && report.downloadAvailable)
  #expect(report.recommendation?.label == "Q8_0")
  #expect(!report.variants.contains { $0.recommended })
  let text = HFCheckText.render(report)
  #expect(text.contains("Selected:") && text.contains("may not fit in memory"))
  let job = try hub.startDownload(.init(name: repo, version: "Q8_0", startAfter: false)).job
  #expect(job.state == .queued && job.files.count > 1)
  #expect(job.warnings.contains { $0.contains("may fail to start") })
  #expect((job.memoryNeedBytes ?? 0) > report.machine.budgetBytes)
}

@Test func hfNoRecommendationStillRequiresAnExplicitDownloadChoice() throws {
  let (hub, directory) = makeHub(machine: .sample(memoryGiB: 8))
  defer { try? FileManager.default.removeItem(at: directory) }
  expectHFError("refused", "Choose a supported version explicitly") {
    _ = try hub.startDownload(.init(name: "bartowski/Qwen2.5-72B-Instruct-GGUF"))
  }
  #expect(hub.downloads.list().isEmpty)
}

@Test func hfGatedOversizedOrLowQualityChoicesStillRequireLogin() throws {
  for (repo, label) in [
    ("bartowski/Qwen2.5-72B-Instruct-GGUF", "Q8_0"),
    ("unsloth/Qwen3-30B-A3B-GGUF", "UD-IQ1_M"),
  ] {
    let transport = FakeHFTransport()
    transport.markedGated = [repo]
    let (hub, directory) = makeHub(machine: .sample(memoryGiB: 16), transport: transport)
    defer { try? FileManager.default.removeItem(at: directory) }
    let report = try hub.check.check(repo, version: label)
    #expect(report.verdict.code == "login_required" && report.repo?.loginRequired == true)
    expectHFError("login_required") {
      _ = try hub.startDownload(.init(name: repo, version: label))
    }
    #expect(hub.downloads.list().isEmpty)
  }
}

@Test func hfAdvisoryDownloadsStillRequireEnoughDiskSpace() throws {
  let (hub, directory) = makeHub(machine: .sample(memoryGiB: 8), free: 3 << 30)
  defer { try? FileManager.default.removeItem(at: directory) }
  expectHFError("insufficient_disk") {
    _ = try hub.startDownload(.init(name: "bartowski/Qwen2.5-72B-Instruct-GGUF", version: "Q8_0"))
  }
  #expect(hub.downloads.list().isEmpty)
}

@Test func hfRemoteAdvisoryDownloadsKeepWarningsAndStayOnTheHost() throws {
  let box = HostSandbox()
  defer { box.cleanUp() }
  box.agent.facts = FakeAgent.linux(memoryGiB: 8, budgetGiB: 5)
  let repo = "bartowski/Qwen2.5-72B-Instruct-GGUF"
  let report = try box.hub.check(repo, version: "Q8_0", host: "gpu-box")
  #expect(report.verdict.code == "too_big" && report.downloadAvailable)
  let started = try box.hub.startDownload(.init(name: repo, version: "Q8_0", startAfter: false, host: "gpu-box"))
  #expect(started.job.hostName == "gpu-box" && box.hub.downloads.list().isEmpty)
  #expect(started.job.warnings.contains { $0.contains("may fail to start") })
  let sent = try #require(box.agent.calls("POST", "/api/hf/downloads").first)
  let payload = try #require(sent.body["job"] as? [String: Any])
  #expect((payload["warnings"] as? [String])?.contains { $0.contains("may fail to start") } == true)
}

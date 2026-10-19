import Foundation
import Testing
@testable import ModelMatrixControllerCore

// MARK: Formats and verdicts

@Test func hfCheckRecommendsAGGUFVersionThatFits() throws {
  let transport = FakeHFTransport()
  let report = try makeCheckService(transport: transport).check("bartowski/Qwen2.5-7B-Instruct-GGUF")
  #expect(report.kind == "model" && report.schemaVersion == 1)
  #expect(report.format?.id == .gguf && report.task?.chat == true)
  #expect(report.verdict.code == "needs_engine" && report.verdict.runnable)
  #expect(report.model?.layoutSource == "gguf_header")
  #expect(report.model?.context == 32768 && report.model?.maxContext == 32768)
  let pick = try #require(report.recommendation)
  #expect(pick.label == "Q8_0" && pick.level == "good" && pick.context == 32768)
  #expect(report.variants.filter(\.recommended).map(\.label) == ["Q8_0"])
  #expect(report.repo?.license == "apache-2.0" && report.repo?.loginRequired == false)
  #expect(report.repo?.sha?.count == 40)
  #expect(report.engine?.needed == .llamaCpp && report.engine?.backup == .ollama)
  #expect(report.engine?.engines.first { $0.id == .llamaCpp }?.install?.command == "brew install llama.cpp")
  #expect(report.downloadAvailable == false)
  #expect(report.downloadFolder?.hasSuffix("/ModelMatrix/Models/bartowski/Qwen2.5-7B-Instruct-GGUF") == true)
  // The check only names the folder; it never creates it.
  #expect(try makeCheckService().check("Qwen/Qwen2.5-7B-Instruct").downloadFolder == nil)
}

@Test func hfCheckNeverDownloadsModelFiles() throws {
  let transport = FakeHFTransport()
  let service = makeCheckService(transport: transport)
  for name in [
    "bartowski/Qwen2.5-7B-Instruct-GGUF", "bartowski/Qwen2.5-72B-Instruct-GGUF", "ggml-org/gemma-3-4b-it-GGUF",
    "unsloth/Qwen3-30B-A3B-GGUF", "mlx-community/Qwen2.5-7B-Instruct-4bit", "Qwen/Qwen2.5-7B-Instruct",
  ] {
    _ = try service.check(name)
  }
  #expect(!transport.calls.isEmpty)
  for call in transport.calls {
    #expect(call.url.scheme == "https" && call.url.host == "huggingface.co")
    #expect(call.maxBytes <= 8 * 1024 * 1024)
    if call.url.path.contains("/resolve/"), call.url.path.hasSuffix(".gguf") {
      // Model files are only ever read through a small byte range.
      let range = try #require(call.headers["Range"])
      #expect(range.hasPrefix("bytes=0-"))
      #expect(call.maxBytes <= 4 * 1024 * 1024)
    }
    if call.url.path.contains("/resolve/"), !call.url.path.hasSuffix(".gguf") {
      #expect(call.url.path.hasSuffix("/config.json"))
    }
  }
}

@Test func hfCheckReadsMoreOfALongHeaderButStaysBounded() throws {
  let transport = FakeHFTransport()
  transport.ggufHeaders = [
    "*": GGUFBuilder.model(arch: "qwen2", layers: 28, heads: 28, kvHeads: 4, embedding: 3584, context: 32768, padding: 900_000)
  ]
  let report = try makeCheckService(transport: transport).check("bartowski/Qwen2.5-7B-Instruct-GGUF")
  #expect(report.model?.layoutSource == "gguf_header")
  let ranged = transport.calls.filter { $0.headers["Range"] != nil }
  #expect(ranged.map(\.maxBytes) == [512 * 1024, 4 * 1024 * 1024])
}

@Test func hfCheckFallsBackWhenTheHeaderIsDamaged() throws {
  let transport = FakeHFTransport()
  transport.ggufHeaders = ["*": Data("not a gguf file at all".utf8)]
  let report = try makeCheckService(transport: transport).check("bartowski/Qwen2.5-7B-Instruct-GGUF")
  #expect(report.model?.layoutSource == "rough")
  #expect(report.recommendation != nil)
  #expect(report.notes.contains { $0.contains("rough") })
}

@Test func hfCheckHandlesVisionAndMixtureModels() throws {
  let service = makeCheckService()
  let vision = try service.check("ggml-org/gemma-3-4b-it-GGUF")
  #expect(vision.task?.kind == "vision_chat")
  let projector = try #require(vision.projector)
  #expect(vision.variants.allSatisfy { $0.downloadBytes == $0.totalBytes + projector.size })
  #expect(vision.recommendation.map { $0.downloadBytes > projector.size } == true)
  // 131,072 tokens possible; the default stays at 32K.
  #expect(vision.model?.maxContext == 131072 && vision.model?.context == 32768)

  let moe = try service.check("unsloth/Qwen3-30B-A3B-GGUF")
  #expect(moe.verdict.runnable)
  #expect(moe.recommendation?.level == "good")
}

@Test func hfCheckHandlesMLXOnAppleSiliconAndIntel() throws {
  let apple = try makeCheckService().check("mlx-community/Qwen2.5-7B-Instruct-4bit")
  #expect(apple.format?.id == .mlx && apple.verdict.code == "needs_engine")
  #expect(apple.model?.layoutSource == "config_json")
  #expect(apple.variants.count == 1 && apple.variants[0].recommended)
  #expect(apple.engine?.engines.first { $0.id == .mlxLM }?.install?.command == "brew install mlx-lm")
  #expect(apple.alternatives.allSatisfy { $0.repo.hasPrefix("mlx-community/Qwen2.5-7B-Instruct-") })
  #expect(!apple.alternatives.contains { $0.repo.localizedCaseInsensitiveContains("uncensored") || $0.repo.contains("1M") })

  let intel = try makeCheckService(machine: .sample(memoryGiB: 16, appleSilicon: false)).check("mlx-community/Qwen2.5-7B-Instruct-4bit")
  #expect(intel.verdict.code == "use_alternative" && !intel.verdict.runnable)
  #expect(intel.alternatives.allSatisfy { $0.format == "gguf" })
  #expect(intel.engine?.engines.first { $0.id == .mlxLM }?.applicable == false)
}

@Test func hfCheckPointsOriginalAndServerFormatsAtReadyVersions() throws {
  let service = makeCheckService()
  for name in ["Qwen/Qwen2.5-7B-Instruct", "Qwen/Qwen2.5-7B-Instruct-AWQ", "mlc-ai/Llama-3-8B-Instruct-q4f16_1-MLC"] {
    let report = try service.check(name)
    #expect(report.verdict.code == "use_alternative", "\(name)")
    #expect(!report.alternatives.isEmpty, "\(name)")
    #expect(report.variants.isEmpty && report.recommendation == nil)
    // Plain conversions are listed before modified versions.
    let flags = report.alternatives.filter { $0.format == "gguf" }.map { $0.sameModel == true }
    #expect(flags == flags.sorted { $0 && !$1 }, "\(name)")
  }
  #expect(try service.check("Qwen/Qwen2.5-7B-Instruct-AWQ").format?.id == .awq)
  #expect(try service.check("mlc-ai/Llama-3-8B-Instruct-q4f16_1-MLC").format?.id == .mlc)
}

@Test func hfCheckRejectsNonChatModels() throws {
  let service = makeCheckService()
  let speech = try service.check("openai/whisper-large-v3")
  #expect(speech.verdict.code == "not_supported" && speech.verdict.title == "Not a chat model")
  #expect(speech.task?.chat == false)
  let image = try service.check("stabilityai/stable-diffusion-xl-base-1.0")
  #expect(image.verdict.code == "not_supported")
}

@Test func hfCheckFlagsGatedModels() throws {
  let service = makeCheckService()
  let original = try service.check("meta-llama/Llama-3.1-8B-Instruct")
  #expect(original.repo?.loginRequired == true)
  #expect(original.verdict.code == "use_alternative")
  #expect(original.alternatives.contains { $0.repo == "bartowski/Meta-Llama-3.1-8B-Instruct-GGUF" && $0.sameModel == true })
}

@Test func hfCheckUsesTheVersionAndContextAskedFor() throws {
  let service = makeCheckService()
  let chosen = try service.check("hf.co/bartowski/Qwen2.5-7B-Instruct-GGUF:Q4_K_M")
  #expect(chosen.recommendation?.label == "Q4_K_M")
  #expect(chosen.recommendation?.reason == "The version you asked for.")
  let short = try service.check("bartowski/Qwen2.5-7B-Instruct-GGUF", context: 8192)
  #expect(short.model?.context == 8192 && short.recommendation?.context == 8192)
  let clamped = try service.check("bartowski/Qwen2.5-7B-Instruct-GGUF", context: 131072)
  #expect(clamped.model?.context == 32768 && clamped.recommendation?.context == 32768)
  #expect(clamped.notes.contains { $0.contains("at most 32768") })
  let missing = try service.check("bartowski/Qwen2.5-7B-Instruct-GGUF:Q9_Z")
  #expect(missing.recommendation?.label == "Q8_0")
  #expect(missing.notes.contains { $0.contains("no usable version named Q9_Z") })
  let file = try service.check("https://huggingface.co/ggml-org/gemma-3-4b-it-GGUF/blob/main/gemma-3-4b-it-Q4_K_M.gguf")
  #expect(file.variants.map(\.label) == ["Q4_K_M"])
  #expect(throws: HFError.self) { try service.check("bartowski/Qwen2.5-7B-Instruct-GGUF", context: 100) }
}

// MARK: Machines

@Test func hfCheckScalesTheRecommendationWithMemory() throws {
  var picks: [Int: String] = [:]
  for memory in [8, 16, 24, 32, 48, 64, 96, 128, 192, 256, 512] {
    let machine = HFMachine.sample(memoryGiB: memory)
    let report = try makeCheckService(machine: machine).check("bartowski/Qwen2.5-7B-Instruct-GGUF")
    let pick = try #require(report.recommendation, "\(memory) GB")
    #expect(pick.needBytes <= machine.budgetBytes, "\(memory) GB")
    #expect(report.variants.first { $0.recommended }?.supported == true)
    picks[memory] = pick.label
  }
  // Small Macs get a smaller version; big Macs never get F16 by default.
  #expect(picks[8] != "Q8_0")
  #expect(picks[16] == "Q5_K_M")
  #expect(picks[48] == "Q8_0" && picks[512] == "Q8_0")
  let sixteen = try makeCheckService(machine: .sample(memoryGiB: 16)).check("bartowski/Qwen2.5-7B-Instruct-GGUF")
  #expect(sixteen.recommendation?.context == 16384)
  let roomy = try makeCheckService(machine: .sample(memoryGiB: 96)).check("bartowski/Qwen2.5-72B-Instruct-GGUF")
  #expect(roomy.recommendation.map { !["Q4_0", "Q4_1", "Q5_0", "Q5_1"].contains($0.label) } == true)
  let large = try makeCheckService(machine: .sample(memoryGiB: 8)).check("bartowski/Qwen2.5-72B-Instruct-GGUF")
  #expect(large.verdict.code == "too_big" && !large.verdict.runnable && large.recommendation == nil)
  let big = try makeCheckService(machine: .sample(memoryGiB: 192)).check("bartowski/Qwen2.5-72B-Instruct-GGUF")
  #expect(big.recommendation?.level == "good")
}

@Test func hfNeverRecommendsVeryLowQualityVersionsByItself() throws {
  for memory in [8, 16, 24, 32, 48, 64, 96] {
    let service = makeCheckService(machine: .sample(memoryGiB: memory))
    for repo in ["bartowski/Qwen2.5-72B-Instruct-GGUF", "unsloth/Qwen3-30B-A3B-GGUF", "bartowski/Qwen2.5-7B-Instruct-GGUF"] {
      let report = try service.check(repo)
      if let chosen = report.variants.first(where: \.recommended) {
        #expect((chosen.bitsPerWeight ?? 8) >= HFMemoryPlanner.minimumRecommendedBits, "\(memory) GB \(repo) \(chosen.label)")
      }
    }
  }
  let small = try makeCheckService(machine: .sample(memoryGiB: 16)).check("unsloth/Qwen3-30B-A3B-GGUF")
  #expect(small.verdict.code == "low_quality" && small.verdict.detail.contains("under 3.5 bits"))
  #expect(small.verdict.runnable && small.verdict.title.hasPrefix("Suggestion:"))
  // Still possible on purpose.
  let chosen = try makeCheckService(machine: .sample(memoryGiB: 16)).check("unsloth/Qwen3-30B-A3B-GGUF:UD-IQ1_M")
  #expect(chosen.recommendation?.label == "UD-IQ1_M" && chosen.verdict.runnable)
}

@Test func hfCheckDescribesIntelMacs() throws {
  let report = try makeCheckService(machine: .sample(memoryGiB: 32, appleSilicon: false)).check("bartowski/Qwen2.5-7B-Instruct-GGUF")
  #expect(report.machine.accelerator == "cpu" && report.machine.budgetSource == "cpu")
  #expect(report.notes.contains { $0.contains("Intel Macs run models on the processor") })
  #expect(report.verdict.runnable)
  let option = report.engine?.engines.first { $0.id == .llamaCpp }?.install
  #expect(option?.command == "brew install llama.cpp")
}

// MARK: Engines

@Test func hfEnginesReportInstalledVersionsWithoutRunningModels() throws {
  let environment = FakeEngineEnvironment.allInstalled
  let report = try makeCheckService(engines: environment).check("bartowski/Qwen2.5-7B-Instruct-GGUF")
  #expect(report.verdict.code == "ready")
  let llama = try #require(report.engine?.engines.first { $0.id == .llamaCpp })
  #expect(llama.installed && llama.version == "b7034 (a1b2c3d)" && llama.installedBy == "Homebrew" && llama.install == nil)
  let mlx = try #require(report.engine?.engines.first { $0.id == .mlxLM })
  #expect(mlx.version == "0.32.2")
  let ollama = try #require(report.engine?.engines.first { $0.id == .ollama })
  #expect(ollama.running == true && ollama.version == "0.40.6")
  // Only version questions were asked; nothing was started or installed.
  for (_, arguments) in environment.commands {
    #expect(arguments == ["--version"] || arguments.first == "-c")
  }
}

@Test func hfEnginesIgnoreOllamasPrivateCopyAndOfferOfficialBuilds() throws {
  let bundled = FakeEngineEnvironment(executables: [
    "/Applications/Ollama.app/Contents/Resources/llama-server", "/Applications/Ollama.app/Contents/Resources/ollama",
  ])
  let machine = HFMachine.sample(memoryGiB: 16)
  let statuses = HFEngineProbe(environment: bundled.environment).detect(machine: machine)
  let llama = try #require(statuses.first { $0.id == .llamaCpp })
  #expect(!llama.installed)
  #expect(llama.install?.method == "official")
  #expect(llama.install?.source == "https://github.com/ggml-org/llama.cpp/releases")
  #expect(llama.install?.summary.contains("macos-arm64") == true)
  #expect(llama.install?.location == "/Users/test/ModelMatrix/Engines/llama.cpp")
  #expect(statuses.first { $0.id == .ollama }?.installedBy == "Ollama app")
  let intel = HFEngineProbe(environment: FakeEngineEnvironment.nothing.environment)
    .detect(machine: .sample(memoryGiB: 16, appleSilicon: false))
  #expect(intel.first { $0.id == .llamaCpp }?.install?.summary.contains("macos-x64") == true)
}

@Test func hfEngineVersionsAreParsedFromTheirOutput() {
  #expect(HFEngineProbe.cellarVersion("/opt/homebrew/Cellar/mlx-lm/0.32.2/bin/mlx_lm.server") == "0.32.2")
  #expect(HFEngineProbe.cellarVersion("/usr/local/bin/ollama") == nil)
  #expect(HFEngineProbe.firstVersion("ollama version is 0.40.6") == "0.40.6")
  #expect(HFEngineProbe.installedBy(path: "/Users/x/.local/bin/mlx_lm.server", resolved: "", home: "/Users/x") == "pipx or uv")
  #expect(HFEngineProbe.installedBy(path: "/Users/x/miniforge3/bin/mlx_lm.server", resolved: "", home: "/Users/x") == "conda")
}

// MARK: Errors and search

@Test func hfCheckTurnsHuggingFaceProblemsIntoClearErrors() throws {
  let limited = FakeHFTransport()
  limited.overrides = ["/api/models/": HFHTTPResponse(status: 429, headers: ["retry-after": "42"])]
  #expect(throws: HFError.rateLimited(retryAfterSeconds: 42)) { try makeCheckService(transport: limited).check("a/b") }

  let broken = FakeHFTransport()
  broken.overrides = ["/api/models/": HFHTTPResponse(status: 503)]
  #expect(throws: HFError.upstream(status: 503)) { try makeCheckService(transport: broken).check("a/b") }

  let garbage = FakeHFTransport()
  garbage.overrides = ["/api/models/": HFHTTPResponse(status: 200, body: Data("<html>".utf8))]
  #expect(throws: HFError.self) { try makeCheckService(transport: garbage).check("a/b") }

  let missing = try makeCheckService().check("nobody-xyz/does-not-exist-123")
  #expect(missing.verdict.code == "not_found" && missing.kind == "search")
  #expect(HFError.rateLimited(retryAfterSeconds: 42).httpStatus == 429)
  #expect(HFError.notFound("a/b").httpStatus == 404)
  #expect(HFError.unreachable("x").httpStatus == 502)
}

@Test func hfSearchListsReadyToRunModels() throws {
  let report = try makeCheckService().check("qwen2.5 coder 7b")
  #expect(report.kind == "search" && report.verdict.code == "choose_model")
  #expect(!report.searchResults.isEmpty)
  #expect(Set(report.searchResults.map(\.format)).isSubset(of: ["gguf", "mlx"]))
  let downloads = report.searchResults.map { $0.downloads ?? 0 }
  #expect(downloads == downloads.sorted(by: >))
  let intel = try makeCheckService(machine: .sample(memoryGiB: 16, appleSilicon: false)).check("qwen2.5 coder 7b")
  #expect(intel.searchResults.allSatisfy { $0.format == "gguf" })
}

// MARK: Routes and text

@Test func hfRoutesAreReadOnlyAndValidated() throws {
  try withFixtureRoot { fixture in
    let router = ControllerRouter(service: fixture.service, authToken: nil, huggingFace: makeCheckService())
    let ok = router.handle(.init(method: "GET", target: "/api/hf/check?name=bartowski%2FQwen2.5-7B-Instruct-GGUF"))
    #expect(ok.status == 200)
    let json = try JSONSerialization.jsonObject(with: ok.body) as? [String: Any]
    #expect((json?["verdict"] as? [String: Any])?["code"] as? String == "needs_engine")
    #expect((json?["recommendation"] as? [String: Any])?["label"] as? String == "Q8_0")
    #expect(json?["schema_version"] as? Int == 1)

    let text = router.handle(.init(method: "GET", target: "/api/hf/check?name=bartowski/Qwen2.5-7B-Instruct-GGUF&context=8k&format=text"))
    #expect(text.headers["Content-Type"]?.hasPrefix("text/plain") == true)
    let body = String(decoding: text.body, as: UTF8.self)
    #expect(body.contains("Recommended: Q8_0") && body.contains("at 8K context"))
    #expect(body.contains("To install: modelmatrixctl engine install llama.cpp"))
    #expect(body.contains("Method: brew install llama.cpp"))
    #expect(body.contains("Saves to:    ~/ModelMatrix/Models/bartowski/Qwen2.5-7B-Instruct-GGUF"))
    #expect(body.hasSuffix("Nothing was downloaded or installed.\n"))

    #expect(router.handle(.init(method: "GET", target: "/api/hf/check")).status == 400)
    #expect(router.handle(.init(method: "GET", target: "/api/hf/check?name=a/b&context=huge")).status == 400)
    #expect(router.handle(.init(method: "GET", target: "/api/hf/check?name=..%2F..%2Fetc")).status == 400)
    #expect(router.handle(.init(method: "POST", target: "/api/hf/check?name=a/b")).status == 404)
    #expect(router.handle(.init(method: "GET", target: "/api/hf/search?q=")).status == 400)
    #expect(router.handle(.init(method: "GET", target: "/api/hf/search?q=qwen2.5+coder+7b")).status == 200)
    #expect(router.runsConcurrently(.init(method: "GET", target: "/api/hf/check?name=a/b")))
    // Nothing was written into the controller's folders.
    let profiles = try FileManager.default.contentsOfDirectory(atPath: fixture.configuration.profilesDirectory.path)
    #expect(profiles.allSatisfy { !$0.lowercased().contains("qwen") })
  }
}

@Test func hfRoutesKeepTheControllerProtections() throws {
  try withFixtureRoot { fixture in
    let router = ControllerRouter(service: fixture.service, authToken: "secret", huggingFace: makeCheckService())
    #expect(router.handle(.init(method: "GET", target: "/api/hf/check?name=a/b")).status == 401)
    let authorized = router.handle(.init(
      method: "GET", target: "/api/hf/check?name=bartowski/Qwen2.5-7B-Instruct-GGUF",
      headers: ["Authorization": "Bearer secret"]))
    #expect(authorized.status == 200)
    let crossSite = router.handle(.init(
      method: "GET", target: "/api/hf/check?name=a/b",
      headers: ["Origin": "https://evil.example.com", "Sec-Fetch-Site": "cross-site", "Authorization": "Bearer secret"]))
    #expect(crossSite.status == 403)
  }
}

@Test func hfTextExplainsAlternativesAndSearches() throws {
  let service = makeCheckService()
  let original = HFCheckText.render(try service.check("Qwen/Qwen2.5-7B-Instruct"))
  #expect(original.contains("USE A READY-TO-RUN VERSION INSTEAD"))
  #expect(original.contains("bartowski/Qwen2.5-7B-Instruct-GGUF"))
  #expect(original.contains("Check one with: modelmatrixctl check <owner/name>"))
  let search = HFCheckText.render(try service.check("qwen2.5 coder 7b"))
  #expect(search.contains("These ready-to-run models match"))
  let mem = HFCheckText.render(try makeCheckService(machine: .sample(memoryGiB: 48)).check("bartowski/Qwen2.5-7B-Instruct-GGUF"))
  #expect(mem.contains("Apple Silicon, 48 GB memory"))
}

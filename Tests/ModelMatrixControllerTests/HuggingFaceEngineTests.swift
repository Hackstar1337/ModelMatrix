import CryptoKit
import Foundation
import Testing
@testable import ModelMatrixControllerCore

// MARK: Test doubles

/// Answers GitHub release and PyPI questions from memory.
final class FakeGitHub: HFTransport, @unchecked Sendable {
  private let lock = NSLock()
  var answers: [String: Any] = [:]
  var limited = false
  private(set) var paths: [String] = []

  func get(_ url: URL, headers: [String: String], maxBytes: Int, timeout: TimeInterval) throws -> HFHTTPResponse {
    lock.lock()
    paths.append(url.path)
    let answer = answers[url.path]
    lock.unlock()
    if limited { return HFHTTPResponse(status: 403) }
    guard let answer else { return HFHTTPResponse(status: 404) }
    return HFHTTPResponse(status: 200, body: try JSONSerialization.data(withJSONObject: answer))
  }

  static func asset(_ repository: String, tag: String, name: String, data: Data) -> [String: Any] {
    [
      "name": name, "size": data.count, "digest": "sha256:" + sha256Hex(data),
      "browser_download_url": "https://github.com/\(repository)/releases/download/\(tag)/\(name)",
    ]
  }
}

/// Stands in for Homebrew and uv; really runs tar and ditto.
final class FakeRunner: HFCommandRunning, @unchecked Sendable {
  struct Call {
    let program: String
    let arguments: [String]
    let environment: [String: String]
  }

  private let lock = NSLock()
  private var log: [Call] = []
  let brewPrefix: URL
  let root: URL
  var brewExit: Int32 = 0
  var slow = false

  init(brewPrefix: URL, root: URL) {
    self.brewPrefix = brewPrefix
    self.root = root
  }

  var calls: [Call] {
    lock.lock()
    defer { lock.unlock() }
    return log
  }

  func run(
    _ program: String, _ arguments: [String], environment: [String: String], output: @escaping (String) -> Void,
    shouldStop: @escaping () -> Bool
  ) throws -> Int32 {
    lock.lock()
    log.append(Call(program: program, arguments: arguments, environment: environment))
    lock.unlock()
    if program == "/usr/bin/tar" || program == "/usr/bin/ditto" {
      return try HFProcessRunner().run(program, arguments, environment: environment, output: output, shouldStop: shouldStop)
    }
    switch ((program as NSString).lastPathComponent, arguments.first ?? "") {
    case ("brew", "info"):
      output(#"{"formulae":[{"versions":{"stable":"7100"}}],"casks":[{"version":"0.40.6"}]}"#)
      return 0
    case ("brew", "install"), ("brew", "upgrade"):
      output("==> Downloading https://ghcr.io/v2/homebrew/core/\(arguments.last ?? "")/blobs/sha256:abc")
      if slow {
        while !shouldStop() { usleep(10_000) }
        return 15
      }
      if brewExit != 0 {
        output("Error: something went wrong")
        return brewExit
      }
      let program = arguments.last == "mlx-lm" ? "mlx_lm.server" : "llama-server"
      try writeScript(brewPrefix.appendingPathComponent("bin/\(program)"), "version: 7100 (abc1234)")
      output("==> Pouring \(arguments.last ?? "")--7100.arm64_sequoia.bottle.tar.gz")
      return 0
    case ("brew", "uninstall"):
      let program = arguments.last == "mlx-lm" ? "mlx_lm.server" : "llama-server"
      try? FileManager.default.removeItem(at: brewPrefix.appendingPathComponent("bin/\(program)"))
      return 0
    case ("uv", "pip"):
      let venv = root.appendingPathComponent("mlx-lm/venv/bin")
      try writeScript(venv.appendingPathComponent("mlx_lm.server"), "", shebang: "#!\(venv.path)/python")
      try FileManager.default.createDirectory(at: root.appendingPathComponent("mlx-lm/cache/wheels"), withIntermediateDirectories: true)
      output("Installed 23 packages in 1.2s")
      return 0
    case ("uv", _):
      return 0
    default:
      return 127
    }
  }
}

func writeScript(_ file: URL, _ body: String, shebang: String = "#!/bin/sh") throws {
  try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
  try Data("\(shebang)\necho '\(body)'\n".utf8).write(to: file)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
}

final class DateBox: @unchecked Sendable {
  var value = Date(timeIntervalSince1970: 1_800_000_000)
}

/// A private folder standing in for the home folder, engines folder and Homebrew.
struct EngineSandbox {
  let base: URL
  let home: URL
  let root: URL
  let brew: URL
  let runner: FakeRunner
  let github = FakeGitHub()
  let streamer = FakeByteStreamer()
  let clock = DateBox()
  let probe: HFEngineProbe
  let installer: HFEngineInstaller
  let machine: HFMachine

  init(homebrew: Bool = true, machine: HFMachine = .sample(memoryGiB: 48)) throws {
    base = FileManager.default.temporaryDirectory.appendingPathComponent("mm-engines-\(UUID().uuidString)")
    home = base.appendingPathComponent("home")
    root = base.appendingPathComponent("Engines")
    brew = base.appendingPathComponent("brew")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    if homebrew { try writeScript(brew.appendingPathComponent("bin/brew"), "brew") }
    runner = FakeRunner(brewPrefix: brew, root: root)
    self.machine = machine
    let (base, home, root, brew) = (base, home, root, brew)
    let environment = HFEngineEnvironment(
      home: home.path,
      searchDirectories: {
        [
          "\(root.path)/llama.cpp/bin", "\(root.path)/mlx-lm/venv/bin", "\(brew.path)/bin",
          "\(home.path)/Applications/Ollama.app/Contents/Resources",
        ]
      },
      isExecutable: { $0.hasPrefix(base.path) && FileManager.default.isExecutableFile(atPath: $0) },
      resolve: { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
      run: { path, _ in
        if path.hasSuffix("/python") { return "0.40.0" }
        if path.hasSuffix("/ollama") { return "ollama version is 0.40.6" }
        return try? String(contentsOfFile: path, encoding: .utf8)
      },
      ollamaServerVersion: { nil }, enginesRoot: root.path)
    probe = HFEngineProbe(environment: environment)
    let clock = clock
    installer = HFEngineInstaller(
      probe: probe, machine: { machine }, registryFile: base.appendingPathComponent("engines.json"), transport: github,
      streamer: streamer, runner: runner, now: { clock.value })
  }

  func cleanUp() { try? FileManager.default.removeItem(at: base) }

  /// Publishes an official llama.cpp build (a real .tar.gz) on the fake GitHub.
  @discardableResult
  func publishLlama(_ tags: [String], macAssets: Bool = true) throws -> [String: Data] {
    var releases: [[String: Any]] = []
    var archives: [String: Data] = [:]
    for tag in tags {
      let archive = try tarball(top: "llama-\(tag)", files: ["llama-server": "version: 0.7.0-dev (build \(tag.dropFirst()), commit f174553e1)", "libllama.dylib": "lib"])
      let name = "llama-\(tag)-bin-macos-arm64.tar.gz"
      var assets: [[String: Any]] = [FakeGitHub.asset("ggml-org/llama.cpp", tag: tag, name: "llama-\(tag)-bin-ubuntu-x64.tar.gz", data: archive)]
      if macAssets {
        assets.append(FakeGitHub.asset("ggml-org/llama.cpp", tag: tag, name: name, data: archive))
        streamer.files["\(tag)/\(name)"] = archive
        archives[tag] = archive
      }
      releases.append(["tag_name": tag, "draft": false, "prerelease": true, "assets": assets])
    }
    let existing = github.answers["/repos/ggml-org/llama.cpp/releases"] as? [[String: Any]] ?? []
    github.answers["/repos/ggml-org/llama.cpp/releases"] = releases + existing
    return archives
  }

  func tarball(top: String, files: [String: String]) throws -> Data {
    let work = base.appendingPathComponent("pack-\(UUID().uuidString)")
    for (name, body) in files { try writeScript(work.appendingPathComponent("\(top)/\(name)"), body) }
    let out = work.appendingPathComponent("out.tar.gz")
    #expect(try HFProcessRunner().run("/usr/bin/tar", ["-czf", out.path, "-C", work.path, top], environment: [:], output: { _ in }, shouldStop: { false }) == 0)
    defer { try? FileManager.default.removeItem(at: work) }
    return try Data(contentsOf: out)
  }

  func status(_ engine: HFEngineID) -> HFEngineStatus? {
    installer.engines(refresh: true).first { $0.id == engine }
  }

  func run(_ plan: HFEnginePlan) throws -> HFEngineJob {
    let job = try installer.run(planID: plan.id)
    return try #require(installer.wait(job.id, timeout: 20))
  }

  func files(_ relative: String) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(relative).path)) ?? []).sorted()
  }
}

func expectHFError(_ code: String, _ message: String? = nil, _ body: () throws -> Void) {
  do {
    try body()
    Issue.record("expected \(code)")
  } catch let error as HFError {
    #expect(error.code == code)
    if let message { #expect(error.description.contains(message), "\(error.description)") }
  } catch {
    Issue.record("unexpected \(error)")
  }
}

// MARK: Plans and approval

@Test func hfEnginePlanDescribesHomebrewInstallAndChangesNothing() throws {
  let box = try EngineSandbox()
  defer { box.cleanUp() }
  let plan = try box.installer.plan(.llamaCpp, action: .install)
  #expect(plan.method == .homebrew && plan.commands == ["brew install llama.cpp"])
  #expect(plan.version == "7100" && plan.location.hasPrefix(box.brew.path))
  #expect(plan.removal == "brew uninstall llama.cpp" && !plan.needsAdmin)
  #expect(plan.id.hasPrefix("plan-") && plan.id.count == 37)
  #expect(plan.downloadSize.contains("Decided by Homebrew"))
  // Planning only asked Homebrew for the version.
  #expect(box.runner.calls.map(\.arguments) == [["info", "--json=v2", "llama.cpp"]])
  #expect(!FileManager.default.fileExists(atPath: box.brew.appendingPathComponent("bin/llama-server").path))
  let text = HFEngineText.render(plan)
  #expect(text.contains("Runs:           brew install llama.cpp") && text.contains("Admin password: not needed"))
  #expect(text.contains("Plan ID: \(plan.id)") && text.contains("usable once"))
  #expect(text.contains("Method:         Homebrew"))
}

@Test func hfEngineHomebrewInstallRunsTheApprovedPlanOnce() throws {
  let box = try EngineSandbox()
  defer { box.cleanUp() }
  let plan = try box.installer.plan(.llamaCpp, action: .install)
  let job = try box.run(plan)
  #expect(job.state == .succeeded, "\(job.log)")
  #expect(job.version?.hasPrefix("b7100") == true)
  let install = try #require(box.runner.calls.first { $0.arguments.first == "install" })
  #expect(install.arguments == ["install", "llama.cpp"])
  #expect(install.environment["NONINTERACTIVE"] == "1" && install.environment["PATH"]?.hasPrefix(box.brew.path) == true)
  #expect(job.log.contains { $0.contains("$ brew install llama.cpp") } && job.log.contains { $0.contains("Pouring") })
  // Single use.
  expectHFError("unknown_item") { _ = try box.installer.run(planID: plan.id) }
  let status = try #require(box.status(.llamaCpp))
  #expect(status.installed && status.managed == true && status.actions == ["update", "uninstall"])
  // Installing again is refused; uninstall goes back through Homebrew.
  expectHFError("conflict", "already installed") { _ = try box.installer.plan(.llamaCpp, action: .install) }
  let removal = try box.installer.plan(.llamaCpp, action: .uninstall)
  #expect(removal.commands == ["brew uninstall llama.cpp"])
  #expect(try box.run(removal).state == .succeeded)
  #expect(box.status(.llamaCpp)?.installed == false && box.status(.llamaCpp)?.actions == ["install"])
}

@Test func hfEnginePlansExpireAndUnknownPlansAreRefused() throws {
  let box = try EngineSandbox()
  defer { box.cleanUp() }
  let plan = try box.installer.plan(.mlxLM, action: .install)
  box.clock.value += 601
  expectHFError("conflict", "expired") { _ = try box.installer.run(planID: plan.id) }
  expectHFError("unknown_item") { _ = try box.installer.run(planID: plan.id) }
  expectHFError("unknown_item") { _ = try box.installer.run(planID: "plan-" + String(repeating: "0", count: 32)) }
  #expect(!box.runner.calls.contains { $0.arguments.first == "install" })
}

@Test func hfEngineLeavesUserInstalledEnginesAlone() throws {
  let box = try EngineSandbox()
  defer { box.cleanUp() }
  try writeScript(box.brew.appendingPathComponent("bin/llama-server"), "version: 7034 (a1b2c3d)")
  let status = try #require(box.status(.llamaCpp))
  #expect(status.installed && status.managed == false && status.actions == [])
  expectHFError("refused", "leaves it alone") { _ = try box.installer.plan(.llamaCpp, action: .update) }
  expectHFError("refused", "leaves it alone") { _ = try box.installer.plan(.llamaCpp, action: .uninstall) }
  expectHFError("conflict", "already installed") { _ = try box.installer.plan(.llamaCpp, action: .install) }
  expectHFError("conflict", "isn't installed") { _ = try box.installer.plan(.mlxLM, action: .uninstall) }
}

@Test func hfEngineRefusesMLXOnIntelAndHomebrewWhenMissing() throws {
  let intel = try EngineSandbox(machine: .sample(memoryGiB: 32, appleSilicon: false))
  defer { intel.cleanUp() }
  expectHFError("refused", "Apple Silicon") { _ = try intel.installer.plan(.mlxLM, action: .install) }
  let bare = try EngineSandbox(homebrew: false)
  defer { bare.cleanUp() }
  expectHFError("refused", "Homebrew isn't installed") { _ = try bare.installer.plan(.llamaCpp, action: .install, method: .homebrew) }
}

@Test func hfEngineFailedAndCancelledInstallsAreReported() throws {
  let box = try EngineSandbox()
  defer { box.cleanUp() }
  box.runner.brewExit = 1
  let failed = try box.run(try box.installer.plan(.llamaCpp, action: .install))
  #expect(failed.state == .failed && failed.error?.contains("exit status 1") == true)
  #expect(failed.manualCommand == "brew install llama.cpp")
  #expect(failed.log.contains("Error: something went wrong"))
  #expect(box.status(.llamaCpp)?.installed == false)
  // Cancel, and one job at a time.
  box.runner.brewExit = 0
  box.runner.slow = true
  let job = try box.installer.run(planID: try box.installer.plan(.llamaCpp, action: .install).id)
  let second = try box.installer.plan(.mlxLM, action: .install)
  expectHFError("conflict", "still running") { _ = try box.installer.run(planID: second.id) }
  _ = try box.installer.cancel(job.id)
  #expect(box.installer.wait(job.id, timeout: 10)?.state == .cancelled)
  expectHFError("conflict") { _ = try box.installer.cancel(job.id) }
  // The refused plan stays usable once the first job finished.
  box.runner.slow = false
  #expect(try box.run(second).state == .succeeded)
}

// MARK: Official builds

@Test func hfEngineOfficialLlamaBuildInstallsUpdatesAndUninstalls() throws {
  let box = try EngineSandbox(homebrew: false)
  defer { box.cleanUp() }
  try box.publishLlama(["b199"])
  try box.publishLlama(["b200"], macAssets: false)  // newest build lacks a Mac file
  let plan = try box.installer.plan(.llamaCpp, action: .install)
  #expect(plan.method == .official && plan.version == "b199" && plan.commands.isEmpty)
  #expect(plan.downloads.first?.url == "https://github.com/ggml-org/llama.cpp/releases/download/b199/llama-b199-bin-macos-arm64.tar.gz")
  #expect(plan.downloads.first?.sha256.count == 64 && plan.location == box.root.path + "/llama.cpp")
  #expect(box.streamer.requests.isEmpty)  // planning downloads nothing
  let job = try box.run(plan)
  #expect(job.state == .succeeded, "\(job.log)")
  #expect(job.log.contains { $0.hasPrefix("Checksum OK") })
  #expect(job.log.contains { $0.hasPrefix("Done: llama.cpp b199 at ") }, "\(job.log)")
  #expect(box.files("llama.cpp") == ["b199", "bin"])
  #expect(try FileManager.default.destinationOfSymbolicLink(atPath: box.root.path + "/llama.cpp/bin") == "b199")
  let status = try #require(box.status(.llamaCpp))
  #expect(status.installed && status.installedBy == "ModelMatrix" && status.version == "b199" && status.managed == true)
  // Update to a newer build: switch over, delete the old one.
  try box.publishLlama(["b201"])
  let update = try box.installer.plan(.llamaCpp, action: .update)
  #expect(update.version == "b201" && update.installedVersion == "b199")
  #expect(HFEngineText.methodLabel(update) == "official build")
  #expect(try box.run(update).state == .succeeded)
  #expect(box.files("llama.cpp") == ["b201", "bin"] && box.status(.llamaCpp)?.version == "b201")
  expectHFError("conflict", "newest") { _ = try box.installer.plan(.llamaCpp, action: .update) }
  // Uninstall removes only the engines folder entry.
  let removal = try box.installer.plan(.llamaCpp, action: .uninstall)
  #expect(HFEngineText.methodLabel(removal) == "remove the copy ModelMatrix installed")
  #expect(try box.run(removal).state == .succeeded)
  #expect(!FileManager.default.fileExists(atPath: box.root.path + "/llama.cpp"))
  #expect(box.status(.llamaCpp)?.installed == false)
}

@Test func hfEngineRejectsADamagedOfficialBuild() throws {
  let box = try EngineSandbox(homebrew: false)
  defer { box.cleanUp() }
  try box.publishLlama(["b199"])
  box.streamer.add([.corrupt])
  let job = try box.run(try box.installer.plan(.llamaCpp, action: .install))
  #expect(job.state == .failed && job.error?.contains("doesn't match its published SHA-256") == true)
  #expect(box.files("llama.cpp").isEmpty)  // nothing kept, no half install
  #expect(box.status(.llamaCpp)?.installed == false)
  // A build without a published checksum is never offered.
  let fresh = try EngineSandbox(homebrew: false)
  defer { fresh.cleanUp() }
  fresh.github.answers["/repos/ggml-org/llama.cpp/releases"] = [
    ["tag_name": "b5", "assets": [["name": "llama-b5-bin-macos-arm64.tar.gz", "size": 10, "browser_download_url": "https://github.com/x/y/releases/download/b5/llama-b5-bin-macos-arm64.tar.gz"]]]
  ]
  expectHFError("unavailable", "No official llama.cpp build") { _ = try fresh.installer.plan(.llamaCpp, action: .install) }
  fresh.github.limited = true
  expectHFError("unavailable", "limiting requests") { _ = try fresh.installer.plan(.llamaCpp, action: .install) }
}

@Test func hfEngineOfficialMLXUsesAPrivatePython() throws {
  let box = try EngineSandbox(homebrew: false)
  defer { box.cleanUp() }
  let uv = try box.tarball(top: "uv-aarch64-apple-darwin", files: ["uv": "uv 0.13.1", "uvx": "uvx"])
  box.github.answers["/repos/astral-sh/uv/releases/latest"] = [
    "tag_name": "0.13.1", "assets": [FakeGitHub.asset("astral-sh/uv", tag: "0.13.1", name: "uv-aarch64-apple-darwin.tar.gz", data: uv)],
  ]
  box.github.answers["/pypi/mlx-lm/json"] = ["info": ["version": "0.40.0"]]
  box.streamer.files["0.13.1/uv-aarch64-apple-darwin.tar.gz"] = uv
  let plan = try box.installer.plan(.mlxLM, action: .install)
  let base = box.root.path + "/mlx-lm"
  #expect(plan.method == .official && plan.version == "0.40.0")
  #expect(HFEngineText.methodLabel(plan) == "private Python made by uv")
  #expect(plan.commands == ["uv python install --no-bin 3.12", "uv venv --python 3.12 \(base)/venv", "uv pip install --python \(base)/venv/bin/python mlx-lm"])
  let job = try box.run(plan)
  #expect(job.state == .succeeded, "\(job.log)")
  let uvCalls = box.runner.calls.filter { $0.program == base + "/uv/uv" }
  #expect(uvCalls.map { $0.arguments.first ?? "" } == ["python", "venv", "pip"])
  #expect(uvCalls.first?.arguments == ["python", "install", "--no-bin", "3.12"])
  for call in uvCalls {
    #expect(call.environment["UV_PYTHON_INSTALL_DIR"] == base + "/python")
    #expect(call.environment["UV_PYTHON_BIN_DIR"] == base + "/python/bin" && call.environment["UV_PYTHON_INSTALL_BIN"] == "0")
    #expect(call.environment["UV_PYTHON_PREFERENCE"] == "only-managed" && call.environment["UV_CACHE_DIR"] == base + "/cache")
  }
  #expect(!FileManager.default.fileExists(atPath: base + "/cache"))  // cache removed afterwards
  let status = try #require(box.status(.mlxLM))
  #expect(status.installed && status.version == "0.40.0" && status.installedBy == "ModelMatrix")
  let update = try box.installer.plan(.mlxLM, action: .update)
  #expect(update.commands == ["uv pip install --upgrade --python \(base)/venv/bin/python mlx-lm"])
}

@Test func hfEngineOfficialOllamaGoesToTheUsersApplications() throws {
  let box = try EngineSandbox(homebrew: false)
  defer { box.cleanUp() }
  let app = box.base.appendingPathComponent("pack/Ollama.app")
  try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
  try Data("<plist/>".utf8).write(to: app.appendingPathComponent("Contents/Info.plist"))
  try writeScript(app.appendingPathComponent("Contents/Resources/ollama"), "ollama version is 0.40.6")
  let zip = box.base.appendingPathComponent("pack/Ollama-darwin.zip")
  #expect(try HFProcessRunner().run("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, zip.path], environment: [:], output: { _ in }, shouldStop: { false }) == 0)
  let data = try Data(contentsOf: zip)
  box.github.answers["/repos/ollama/ollama/releases/latest"] = [
    "tag_name": "v0.40.6", "assets": [FakeGitHub.asset("ollama/ollama", tag: "v0.40.6", name: "Ollama-darwin.zip", data: data)],
  ]
  box.streamer.files["v0.40.6/Ollama-darwin.zip"] = data
  let plan = try box.installer.plan(.ollama, action: .install)
  #expect(plan.location == box.home.path + "/Applications/Ollama.app" && !plan.needsAdmin)
  #expect(try box.run(plan).state == .succeeded)
  let status = try #require(box.status(.ollama))
  #expect(status.installed && status.version == "0.40.6" && status.managed == true && status.actions == ["uninstall"])
  expectHFError("refused", "updates itself") { _ = try box.installer.plan(.ollama, action: .update) }
}

@Test func hfEngineRemovalStaysInsideItsOwnFolders() throws {
  let box = try EngineSandbox()
  defer { box.cleanUp() }
  expectHFError("refused") { try box.installer.requireRemovable("/Applications/Safari.app") }
  expectHFError("refused") { try box.installer.requireRemovable(box.root.path + "/../home") }
  expectHFError("refused") { try box.installer.requireRemovable(box.root.path) }
  try box.installer.requireRemovable(box.root.path + "/llama.cpp")
}

// MARK: Finding engines

@Test func hfEngineFinderReadsNewVersionsAndSettingsPaths() throws {
  let box = try EngineSandbox()
  defer { box.cleanUp() }
  let custom = box.base.appendingPathComponent("custom/llama-server")
  try writeScript(custom, "version: 0.7.0-dev (build 11738, commit f174553e1)")
  box.probe.setConfiguredPaths(["llama.cpp": custom.path])
  let status = try #require(box.status(.llamaCpp))
  #expect(status.path == custom.path && status.version == "b11738" && status.installedBy == "you (set in Settings)")
  #expect(status.actions == [] && status.managed == false)
  // A missing configured file falls back to the normal search.
  box.probe.setConfiguredPaths(["llama.cpp": box.base.path + "/gone/llama-server"])
  #expect(box.status(.llamaCpp)?.installed == false)
}

@Test func hfCheckOffersTheApproveFirstInstall() throws {
  let (hub, directory) = makeHub(engines: .homebrewOnly)
  defer { try? FileManager.default.removeItem(at: directory) }
  let report = try hub.check.check("bartowski/Qwen2.5-7B-Instruct-GGUF")
  let text = HFCheckText.render(report)
  #expect(text.contains("To install: modelmatrixctl engine install llama.cpp"))
  #expect(text.contains("installs only after you confirm") && text.contains("Method: brew install llama.cpp"))
}

// MARK: Routes

@Test func hfEngineRoutes() throws {
  let box = try EngineSandbox()
  defer { box.cleanUp() }
  try withFixtureRoot { fixture in
    let directory = box.base.appendingPathComponent("hub")
    let check = HFCheckService(
      client: HFClient(endpoint: HFClient.defaultEndpoint, transport: FakeHFTransport()), engines: box.probe,
      machine: { box.machine })
    let hub = HFHub(
      directory: directory, check: check, tokenStore: HFMemoryTokenStore(), streamer: box.streamer, network: FakeNetwork(),
      freeSpace: { _ in 1 << 42 }, pause: { _ in }, engineTransport: box.github, engineRunner: box.runner)
    let router = ControllerRouter(service: fixture.service, authToken: nil, hub: hub)
    func call(_ method: String, _ target: String, _ body: [String: Any]? = nil) -> ControllerHTTPResponse {
      let data = body.map { try! JSONSerialization.data(withJSONObject: $0) } ?? Data()
      return router.handle(.init(method: method, target: target, headers: ["Content-Type": "application/json"], body: data))
    }
    func object(_ response: ControllerHTTPResponse) -> [String: Any] {
      (try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]) ?? [:]
    }
    let list = object(call("GET", "/api/hf/engines?refresh=1"))
    let engines = try #require(list["engines"] as? [[String: Any]])
    #expect(engines.count == 3 && (engines.first?["actions"] as? [String]) == ["install"])
    #expect(list["engines_folder"] as? String == box.root.path)
    #expect(call("POST", "/api/hf/engines/plan", ["engine": "nope"]).status == 400)
    #expect(call("POST", "/api/hf/engines/plan", ["engine": "llama.cpp", "action": "explode"]).status == 400)
    #expect(call("POST", "/api/hf/engines/plan", ["engine": "llama.cpp", "method": "curl"]).status == 400)
    let text = call("POST", "/api/hf/engines/plan?format=text", ["engine": "llama"])
    #expect(String(decoding: text.body, as: UTF8.self).contains("brew install llama.cpp"))
    let planned = object(call("POST", "/api/hf/engines/plan", ["engine": "llama.cpp"]))
    let plan = try #require(planned["plan"] as? [String: Any])
    let planID = try #require(plan["id"] as? String)
    #expect(plan["steps"] == nil)  // internal steps are never sent out
    #expect(call("POST", "/api/hf/engines/run", ["plan_id": "../etc"]).status == 400)
    let started = call("POST", "/api/hf/engines/run", ["plan_id": planID])
    #expect(started.status == 202)
    let jobID = try #require((object(started)["job"] as? [String: Any])?["id"] as? String)
    _ = hub.engines.wait(jobID, timeout: 10)
    let log = call("GET", "/api/hf/engines/jobs/\(jobID)?since=0&format=text")
    #expect(log.headers["X-ModelMatrix-Job-State"] == "succeeded")
    #expect(Int(log.headers["X-ModelMatrix-Log-Next"] ?? "") ?? 0 > 2)
    #expect(String(decoding: log.body, as: UTF8.self).contains("$ brew install llama.cpp"))
    let later = call("GET", "/api/hf/engines/jobs/\(jobID)?since=999&format=text")
    #expect(later.body.isEmpty)
    #expect(call("POST", "/api/hf/engines/run", ["plan_id": planID]).status == 404)  // used
    #expect(call("GET", "/api/hf/engines/jobs/eng-zzzz").status == 404)
    #expect((object(call("GET", "/api/hf/engines/jobs"))["jobs"] as? [[String: Any]])?.count == 1)
  }
}

@Test func hfEngineRoutesRefuseOtherWebsites() throws {
  let box = try EngineSandbox()
  defer { box.cleanUp() }
  try withFixtureRoot { fixture in
    let check = HFCheckService(
      client: HFClient(endpoint: HFClient.defaultEndpoint, transport: FakeHFTransport()), engines: box.probe,
      machine: { box.machine })
    let hub = HFHub(
      directory: box.base.appendingPathComponent("hub"), check: check, tokenStore: HFMemoryTokenStore(),
      streamer: box.streamer, network: FakeNetwork(), freeSpace: { _ in 1 << 42 }, pause: { _ in },
      engineTransport: box.github, engineRunner: box.runner)
    let router = ControllerRouter(service: fixture.service, authToken: "secret", hub: hub)
    let plan = try hub.engines.plan(.llamaCpp, action: .install)
    let body = try JSONSerialization.data(withJSONObject: ["plan_id": plan.id])
    #expect(router.handle(.init(method: "POST", target: "/api/hf/engines/run", body: body)).status == 401)
    let crossSite = router.handle(.init(
      method: "POST", target: "/api/hf/engines/run",
      headers: ["Origin": "https://evil.example.com", "Sec-Fetch-Site": "cross-site", "Authorization": "Bearer secret"],
      body: body))
    #expect(crossSite.status == 403)
    #expect(hub.engines.jobList().isEmpty && !box.runner.calls.contains { $0.arguments.first == "install" })
  }
}

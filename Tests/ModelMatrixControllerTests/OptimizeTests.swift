import Foundation
import Testing
@testable import ModelMatrixControllerCore

private let now: Double = 1_800_000_000

private func inputs(
  models: [(String, UInt64)] = [], servers: [OptimizeInputs.Server] = [], cached: UInt64 = 0
) -> OptimizeInputs {
  var value = OptimizeInputs()
  value.now = now
  value.cachedBytes = cached
  value.ollamaModels = models.map { OptimizeInputs.OllamaModel(name: $0.0, bytes: $0.1) }
  value.servers = servers
  return value
}

private func server(_ profile: String, bytes: UInt64 = 1 << 30, startedAgo: Double) -> OptimizeInputs.Server {
  OptimizeInputs.Server(
    profile: profile, displayName: profile.capitalized, runtimeLabel: "llama.cpp", pid: 4242,
    bytes: bytes, startedAt: now - startedAgo)
}

@Test func optimizePlannerOffersIdleOllamaModelsInBothPresets() {
  let items = OptimizePlanner.items(inputs(models: [("small", 1 << 28), ("big:7b", 1 << 32)]))
  // Largest first, file cache last.
  #expect(items.map(\.id) == ["ollama:big:7b", "ollama:small", OptimizePlanner.fileCacheID])
  #expect(OptimizePlanner.preset("recommended", items) == ["ollama:big:7b", "ollama:small"])
  #expect(OptimizePlanner.preset("maximum", items) == ["ollama:big:7b", "ollama:small", "system:file-cache"])
}

@Test func optimizePlannerNeverPresetsModelsThatAreAnsweringRequests() {
  var value = inputs(models: [("llama3", 1 << 30), ("qwen", 1 << 30)])
  value.inflightModels = ["llama3:latest"]  // `name` and `name:latest` are the same model
  value.lastUsed = ["model:qwen": now - 20]  // used 20 s ago
  let items = OptimizePlanner.items(value)
  #expect(items.filter(\.inUse).map(\.id) == ["ollama:llama3", "ollama:qwen"])
  #expect(OptimizePlanner.preset("recommended", items).isEmpty)
  #expect(OptimizePlanner.preset("maximum", items) == [OptimizePlanner.fileCacheID])
  #expect(items.first { $0.id == "ollama:qwen" }?.lastUsedAt == now - 20)
}

@Test func optimizePlannerRecommendsOnlyServersIdleForFifteenMinutes() {
  var value = inputs(servers: [
    server("fresh", startedAgo: 120),  // started 2 min ago, never used
    server("stale", startedAgo: 3600),  // started an hour ago, last request 20 min ago
    server("busy", startedAgo: 3600),  // request 30 s ago
  ])
  value.lastUsed = ["profile:stale": now - 1200, "profile:busy": now - 30]
  let items = OptimizePlanner.items(value)
  #expect(OptimizePlanner.preset("recommended", items) == ["profile:stale"])
  #expect(Set(OptimizePlanner.preset("maximum", items)) == ["profile:fresh", "profile:stale", OptimizePlanner.fileCacheID])
  #expect(items.first { $0.id == "profile:busy" }?.inUse == true)

  value.inflightProfiles = ["stale"]
  #expect(OptimizePlanner.preset("recommended", OptimizePlanner.items(value)).isEmpty)
}

@Test func optimizeFileCacheNeedsPasswordAndIsMaximumOnly() {
  let items = OptimizePlanner.items(inputs(cached: 5 << 30))
  let cache = items.last
  #expect(cache?.kind == .fileCache)
  #expect(cache?.needsPassword == true)
  #expect(cache?.bytes == 5 << 30)
  #expect(cache?.recommended == false)
  #expect(cache?.maximum == true)
  #expect(OptimizePlanner.estimate(OptimizePlanner.preset("maximum", items), items) == 5 << 30)
  #expect(OptimizePlanner.estimate(["missing"], items) == 0)
}

@Test func optimizeFreedBytesUsesTheLargerOfUsedDropAndFreeGain() {
  let before = MemorySnapshot(
    totalBytes: 48 << 30, appBytes: 20 << 30, wiredBytes: 4 << 30, compressedBytes: 2 << 30,
    cachedBytes: 16 << 30, freeBytes: 6 << 30)
  var stopped = before
  stopped.appBytes = 16 << 30
  stopped.freeBytes = 7 << 30  // freed pages go partly to the file cache
  #expect(OptimizePlanner.freedBytes(before: before, after: stopped) == 4 << 30)
  var purged = before
  purged.cachedBytes = 2 << 30
  purged.freeBytes = 20 << 30  // Memory Used is unchanged by a purge
  #expect(OptimizePlanner.freedBytes(before: before, after: purged) == 14 << 30)
  #expect(OptimizePlanner.freedBytes(before: purged, after: before) == 0)
  #expect(before.usedBytes == 26 << 30)
}

@Test func optimizeMatchesOllamaModelNames() {
  #expect(OptimizePlanner.sameModel("Llama3", "llama3:latest"))
  #expect(OptimizePlanner.sameModel("gemma3:270m", "gemma3:270m"))
  #expect(!OptimizePlanner.sameModel("gemma3:270m", "gemma3:1b"))
}

@Test func processTableGroupsAppsAndProtectsSystemBundles() {
  let mb: UInt64 = 1 << 20
  let table = ProcessTable(rows: [
    ProcessMemoryRow(pid: 10, parent: 1, startedAt: 100, path: "/Applications/Browser.app/Contents/MacOS/Browser", name: "Browser", footprintBytes: 300 * mb),
    ProcessMemoryRow(pid: 11, parent: 10, startedAt: 101, path: "/Applications/Browser.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper", name: "Helper", footprintBytes: 200 * mb),
    ProcessMemoryRow(pid: 12, parent: 11, startedAt: 102, path: "/Applications/Browser.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper", name: "Helper", footprintBytes: 100 * mb),
    ProcessMemoryRow(pid: 20, parent: 1, startedAt: 50, path: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder", name: "Finder", footprintBytes: 400 * mb),
    ProcessMemoryRow(pid: 30, parent: 1, startedAt: 60, path: "/opt/homebrew/bin/node", name: "node", footprintBytes: 700 * mb),
    ProcessMemoryRow(pid: 40, parent: 1, startedAt: 70, path: "/Applications/Tiny.app/Contents/MacOS/Tiny", name: "Tiny", footprintBytes: 10 * mb),
    ProcessMemoryRow(pid: 50, parent: 1, startedAt: 80, path: "/Applications/Model.app/Contents/MacOS/Model", name: "Model", footprintBytes: 900 * mb),
  ])
  #expect(Set(table.tree(10)) == [10, 11, 12])
  #expect(table.footprint(ofTree: 11) == 300 * mb)
  #expect(ProcessTable.bundlePath(for: "/Applications/Browser.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper") == "/Applications/Browser.app")
  #expect(ProcessTable.bundlePath(for: "/opt/homebrew/bin/node") == nil)
  // Command-line Python runs from an app stub inside its framework: a tool, not an app.
  #expect(ProcessTable.bundlePath(for: "/opt/homebrew/Cellar/python@3.14/3.14.5/Frameworks/Python.framework/Versions/3.14/Resources/Python.app/Contents/MacOS/Python") == nil)
  // Helpers nested in a framework inside an app still belong to that app.
  #expect(ProcessTable.bundlePath(for: "/Applications/Browser.app/Contents/Frameworks/Browser Framework.framework/Helpers/Browser Helper.app/Contents/MacOS/Browser Helper") == "/Applications/Browser.app")

  let groups = table.appGroups(excluding: [50])
  #expect(groups.map(\.name) == ["node", "Browser", "Finder"])  // Model excluded, Tiny below 50 MB
  let browser = groups.first { $0.name == "Browser" }
  #expect(browser?.bytes == 600 * mb)
  #expect(browser?.processCount == 3)
  #expect(browser?.mainPID == 10)
  #expect(browser?.quittable == true)
  #expect(groups.first { $0.name == "Finder" }?.quittable == false)
  #expect(groups.first { $0.name == "node" }?.quittable == false)
}

@Test func purgeFileCacheReportsSuccessAndCancel() {
  let ok = OptimizeActions.purgeFileCache(timeout: 20, script: "return 1")
  #expect(ok.ok)
  let canceled = OptimizeActions.purgeFileCache(timeout: 20, script: "error number -128")
  #expect(!canceled.ok)
  #expect(canceled.canceled)
  let failed = OptimizeActions.purgeFileCache(timeout: 20, script: "error \"disk busy\" number 5")
  #expect(!failed.ok)
  #expect(!failed.canceled)
  #expect(failed.message.contains("disk busy"))
}

@Test func optimizeRoutesValidateRunPayloads() throws {
  try withFixtureRoot { fixture in
    let router = ControllerRouter(service: fixture.service, authToken: nil)
    func post(_ object: [String: Any]) -> ControllerHTTPResponse {
      router.handle(
        ControllerHTTPRequest(
          method: "POST", target: "/api/optimize/run", headers: ["Content-Type": "application/json"],
          body: try! JSONSerialization.data(withJSONObject: object)))
    }
    #expect(post([:]).status == 400)
    #expect(post(["preset": "everything"]).status == 400)
    let empty = post(["items": [String]()])
    #expect(empty.status == 200)
    let payload = try JSONSerialization.jsonObject(with: empty.body) as? [String: Any]
    #expect((payload?["results"] as? [Any])?.isEmpty == true)

    let plan = router.handle(.init(method: "GET", target: "/api/optimize/plan"))
    #expect(plan.status == 200)
    let body = try JSONSerialization.jsonObject(with: plan.body) as? [String: Any]
    let items = body?["items"] as? [[String: Any]]
    #expect(items?.last?["id"] as? String == OptimizePlanner.fileCacheID)
    #expect((body?["presets"] as? [String: Any])?["maximum"] is [String])
    #expect(body?["memory"] is [String: Any])
  }
}

/// Apple's own apps are ordinary apps; the rest of /System is macOS itself.
@Test func optimizeAppRulesExplainWhatCannotQuit() {
  #expect(ProcessTable.isQuittable(bundle: "/System/Applications/Mail.app"))
  #expect(ProcessTable.isQuittable(bundle: "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app"))
  #expect(!ProcessTable.isQuittable(bundle: "/System/Library/CoreServices/Finder.app"))
  #expect(!ProcessTable.isQuittable(bundle: nil))
  let mb: UInt64 = 1 << 20
  let table = ProcessTable(rows: [
    ProcessMemoryRow(pid: 1, parent: 0, startedAt: 1, path: "/opt/homebrew/bin/node", name: "node", footprintBytes: 900 * mb),
    ProcessMemoryRow(pid: 2, parent: 0, startedAt: 1, path: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder", name: "Finder", footprintBytes: 300 * mb),
    ProcessMemoryRow(pid: 3, parent: 0, startedAt: 1, path: "/Applications/Editor.app/Contents/MacOS/Editor", name: "Editor", footprintBytes: 800 * mb),
    ProcessMemoryRow(pid: 4, parent: 0, startedAt: 1, path: "/Applications/Clip.app/Contents/MacOS/Clip", name: "Clip", footprintBytes: 200 * mb),
    ProcessMemoryRow(pid: 5, parent: 0, startedAt: 1, path: "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app/Contents/MacOS/Safari", name: "Safari", footprintBytes: 400 * mb),
  ])
  let groups = table.appGroups(excluding: [])
  #expect(groups.first { $0.name == "node" }?.reason == "command-line tool")
  #expect(groups.first { $0.name == "Finder" }?.reason == "part of macOS")
  #expect(groups.first { $0.name == "Editor" }?.reason == nil)
  #expect(groups.first { $0.name == "Editor" }?.json.keys.contains("reason") == false)
  // Without the menu bar app the rules above stand.
  #expect(ProcessTable.refine(groups, allowedApps: nil) == groups)
  // With it, only apps it sees as regular stay quittable; Safari matches by file name.
  let refined = ProcessTable.refine(groups, allowedApps: ["/Applications/Editor.app", "/Applications/Safari.app"])
  #expect(refined.first { $0.name == "Editor" }?.quittable == true)
  #expect(refined.first { $0.name == "Safari" }?.quittable == true)
  let clip = refined.first { $0.name == "Clip" }
  #expect(clip?.quittable == false)
  #expect(clip?.reason == "background app")
  #expect(clip?.json["reason"] as? String == "background app")
  #expect(refined.first { $0.name == "node" }?.reason == "command-line tool")
  // System services without an app bundle are part of macOS, not tools.
  #expect(ProcessTable.lockedReason(bundle: nil, path: "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent") == "part of macOS")
  #expect(ProcessTable.lockedReason(bundle: nil, path: "/usr/libexec/trustd") == "part of macOS")
  #expect(ProcessTable.lockedReason(bundle: nil, path: "/usr/bin/python3") == "command-line tool")
  #expect(ProcessTable.lockedReason(bundle: nil, path: "") == "command-line tool")
}

@Test func bridgeReportsRegularAppsFromHeartbeat() {
  let bridge = BridgeState()
  #expect(bridge.quittableAppPaths == nil)
  #expect(BridgeState.commandTypes.contains("app.quit_apps"))
  _ = bridge.heartbeat(["app": ["version": "1.0.0", "quittable_apps": ["/Applications/Editor.app"]], "gateways": []])
  #expect(bridge.quittableAppPaths == ["/Applications/Editor.app"])
  _ = bridge.heartbeat(["app": ["version": "1.0.0"], "gateways": []])
  #expect(bridge.quittableAppPaths == nil)
}

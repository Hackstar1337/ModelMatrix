import AppKit
import Testing
@testable import ModelMatrixApp

/// Quit from the Optimize panel (or the web dashboard) is limited to regular
/// apps: never ModelMatrix itself, core macOS components, or background agents.
@MainActor
@Test func appQuitterRefusesItselfSystemAndBackgroundApps() {
  let other: pid_t = 999_999
  #expect(AppQuitter.refusal(bundleID: "com.example.editor", pid: other, policy: .regular) == nil)
  #expect(AppQuitter.refusal(bundleID: nil, pid: ProcessInfo.processInfo.processIdentifier, policy: .regular) != nil)
  #expect(AppQuitter.refusal(bundleID: "com.apple.finder", pid: other, policy: .regular) != nil)
  #expect(AppQuitter.refusal(bundleID: "com.apple.dock", pid: other, policy: .regular) != nil)
  #expect(AppQuitter.refusal(bundleID: "com.example.agent", pid: other, policy: .prohibited) != nil)
  // Menu bar utilities can be quit like any other app.
  #expect(AppQuitter.refusal(bundleID: "com.example.menubar", pid: other, policy: .accessory) == nil)
  #expect(AppQuitter.refusal(bundleID: "com.example.daemon", pid: other, policy: .prohibited) != nil)
}

@MainActor
@Test func appQuitterOnlyAcceptsAppBundles() {
  #expect(throws: AppQuitter.Failure.self) { try AppQuitter.quit(path: "/opt/homebrew/bin/node", name: "node") }
  #expect(throws: AppQuitter.Failure.self) { try AppQuitter.quit(path: nil, name: nil) }
  #expect(throws: AppQuitter.Failure.self) {
    try AppQuitter.quit(path: "/Applications/Definitely Not Running \(UUID().uuidString).app", name: "Nothing")
  }
}

@MainActor
@Test func optimizeMonitorFreedMatchesController() {
  let gb = 1_073_741_824.0
  let before = JSONRow(["used_bytes": 26 * gb, "free_bytes": 6 * gb])
  let stopped = JSONRow(["used_bytes": 22 * gb, "free_bytes": 7 * gb])
  let purged = JSONRow(["used_bytes": 26 * gb, "free_bytes": 20 * gb])
  #expect(OptimizeMonitor.freed(before, stopped) == 4 * gb)
  #expect(OptimizeMonitor.freed(before, purged) == 14 * gb)
  #expect(OptimizeMonitor.freed(purged, before) == 0)
  #expect(OptimizeMonitor.freed(nil, stopped) == 0)
}

@MainActor
@Test func optimizeMonitorSelectsPresetsAndTotalsEstimate() {
  let monitor = OptimizeMonitor()
  monitor.plan = JSONRow([
    "items": [
      ["id": "ollama:a", "kind": "ollama_model", "bytes": 100.0],
      ["id": "profile:b", "kind": "model_server", "bytes": 200.0],
      ["id": "system:file-cache", "kind": "file_cache", "bytes": 400.0],
    ],
    "presets": ["maximum": ["ollama:a", "profile:b", "system:file-cache"], "recommended": ["ollama:a"]],
    "estimates": ["maximum": 700.0, "recommended": 100.0],
  ])
  monitor.applyPreset()
  #expect(monitor.selected == ["ollama:a", "profile:b", "system:file-cache"])
  #expect(monitor.estimate == 700)
  #expect(monitor.wantsPurge)
  monitor.preset = "recommended"
  #expect(monitor.selected == ["ollama:a"])
  #expect(!monitor.wantsPurge)
  #expect(monitor.estimate(for: "maximum") == 700)
  monitor.toggle("profile:b")
  #expect(monitor.estimate == 300)
  monitor.toggle("ollama:a")
  #expect(monitor.chosen.map(\.id) == ["profile:b"])
}

/// Other apps are picked on their own (presets never pick them), count toward
/// the estimate, and "Select all" only takes apps that can quit.
@MainActor
@Test func optimizeMonitorSelectsAppsSeparatelyFromPresets() {
  let monitor = OptimizeMonitor()
  monitor.plan = JSONRow([
    "items": [["id": "ollama:a", "kind": "ollama_model", "bytes": 100.0]],
    "apps": [
      ["name": "Editor", "path": "/Applications/Editor.app", "bytes": 1_000.0, "quittable": true],
      ["name": "Browser", "path": "/Applications/Browser.app", "bytes": 2_000.0, "quittable": true],
      ["name": "node", "bytes": 5_000.0, "quittable": false, "reason": "command-line tool"],
    ],
    "presets": ["maximum": ["ollama:a"], "recommended": []],
    "estimates": ["maximum": 100.0, "recommended": 0.0],
  ])
  monitor.selected = []
  #expect(!monitor.hasWork)
  monitor.toggleApp("/Applications/Editor.app")
  #expect(monitor.hasWork)
  #expect(monitor.estimate == 1_000)
  #expect(!monitor.allAppsSelected)
  monitor.toggleAllApps()
  #expect(monitor.selectedApps == ["/Applications/Editor.app", "/Applications/Browser.app"])
  #expect(monitor.allAppsSelected)
  monitor.applyPreset()
  #expect(monitor.selected == ["ollama:a"])
  #expect(monitor.selectedApps.count == 2)  // presets leave apps alone
  #expect(monitor.estimate == 3_100)
  monitor.toggleAllApps()
  #expect(monitor.selectedApps.isEmpty)
  #expect(monitor.chosenApps.isEmpty)
}

/// Batch quit reports every app: gone apps count as closed, tools are refused.
@MainActor
@Test func appQuitterQuitAllReportsEachApp() async {
  let results = await AppQuitter.quitAll(
    [
      (path: "/Applications/Definitely Not Running \(UUID().uuidString).app", name: "Ghost"),
      (path: "/opt/homebrew/bin/node", name: "node"),
    ], wait: .milliseconds(100))
  #expect(results.count == 2)
  #expect(results[0].status == .quit)
  #expect(results[0].message == "Already closed.")
  #expect(results[0].json["ok"] as? Bool == true)
  #expect(results[1].status == .refused)
  #expect(results[1].json["status"] as? String == "refused")
  #expect(!AppQuitter.quittableAppPaths().contains { $0.hasSuffix("/ModelMatrix.app") && $0 == Bundle.main.bundlePath })
}

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
  #expect(AppQuitter.refusal(bundleID: "com.example.agent", pid: other, policy: .accessory) != nil)
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

import AppKit
import Foundation
import Observation

/// Menu bar twin of the web dashboard's Optimize window: measures memory, lists
/// what can be freed (idle Ollama models, model servers, the file cache) and
/// frees the selected items through the local controller.
@MainActor
@Observable
final class OptimizeMonitor {
    enum Phase: Equatable { case idle, running, purging, done }

    struct Step: Identifiable {
        let id: String
        let title: String
        let ok: Bool
        let skipped: Bool
        let message: String
        let bytes: Double?
    }

    struct Outcome {
        var before: JSONRow?
        var after: JSONRow?
        var freed: Double
        var steps: [Step]
    }

    static let presets = ["maximum", "recommended"]
    static let fileCacheID = "system:file-cache"

    var plan: JSONRow?
    var preset = "maximum" { didSet { if oldValue != preset { applyPreset() } } }
    var selected: Set<String> = []
    var phase: Phase = .idle
    var outcome: Outcome?
    var errorMessage: String?
    var noticeMessage: String?
    @ObservationIgnored private var client: (() -> WebDashboardClient)?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var hasSelection = false

    var items: [JSONRow] { plan?.rows("items") ?? [] }
    var apps: [JSONRow] { plan?.rows("apps") ?? [] }
    var memory: JSONRow? { outcome?.after ?? plan?.row("memory") }
    var isBusy: Bool { phase == .running || phase == .purging }
    var chosen: [JSONRow] { items.filter { selected.contains($0.string("id") ?? "") } }
    var estimate: Double { chosen.reduce(0) { $0 + ($1.double("bytes") ?? 0) } }
    var wantsPurge: Bool { chosen.contains { $0.string("kind") == "file_cache" } }

    func estimate(for preset: String) -> Double { plan?.row("estimates")?.double(preset) ?? 0 }

    func start(client: @escaping () -> WebDashboardClient) {
        self.client = client
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.phase == .idle { await self.refresh() }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh() async {
        guard let client else { return }
        do {
            let next = try await client().object("/api/optimize/plan", timeout: 20)
            plan = next
            errorMessage = nil
            if hasSelection {
                // Keep the user's ticks, minus items that are gone.
                let ids = Set(next.rows("items").compactMap { $0.string("id") })
                selected = selected.intersection(ids)
            } else {
                applyPreset()
                hasSelection = true
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func applyPreset() {
        selected = Set(plan?.row("presets")?.strings(preset) ?? [])
    }

    func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    func reset() {
        outcome = nil
        phase = .idle
        Task { await refresh() }
    }

    func run() async {
        guard let client, !chosen.isEmpty, !isBusy else { return }
        let api = client()
        let chosenNow = chosen
        let purge = wantsPurge
        let titles = Dictionary(
            items.compactMap { row in row.string("id").map { ($0, row.string("title") ?? $0) } },
            uniquingKeysWith: { first, _ in first })
        var steps: [Step] = []
        var before: JSONRow?
        var after: JSONRow?
        noticeMessage = nil
        errorMessage = nil
        do {
            let ids = chosenNow.filter { $0.string("kind") != "file_cache" }.compactMap { $0.string("id") }
            if !ids.isEmpty {
                phase = .running
                let result = try await api.post("/api/optimize/run", ["items": ids], timeout: 300)
                before = result.row("before")
                after = result.row("after")
                for row in result.rows("results") where !row.bool("skipped") {
                    let id = row.string("id") ?? ""
                    steps.append(Step(
                        id: id, title: titles[id] ?? id, ok: row.bool("ok"), skipped: false,
                        message: row.string("message") ?? "", bytes: row.double("bytes")))
                }
            }
            if purge {
                phase = .purging
                let result = try await api.post("/api/optimize/purge", [:], timeout: 240)
                before = before ?? result.row("before")
                after = result.row("after") ?? after
                steps.append(Step(
                    id: Self.fileCacheID, title: titles[Self.fileCacheID] ?? "Clear file cache",
                    ok: result.bool("ok"), skipped: result.bool("canceled"),
                    message: result.string("message") ?? "", bytes: nil))
            }
            outcome = Outcome(before: before, after: after, freed: Self.freed(before, after), steps: steps)
            phase = .done
        } catch {
            phase = .idle
            errorMessage = "Optimize failed: \(error.localizedDescription)"
        }
        await refresh()
    }

    /// Memory handed back, by whichever of used or free moved more.
    static func freed(_ before: JSONRow?, _ after: JSONRow?) -> Double {
        guard let before, let after else { return 0 }
        let used = (before.double("used_bytes") ?? 0) - (after.double("used_bytes") ?? 0)
        let free = (after.double("free_bytes") ?? 0) - (before.double("free_bytes") ?? 0)
        return max(0, used, free)
    }

    func quit(app row: JSONRow) {
        do {
            let name = try AppQuitter.quit(path: row.string("path"), name: row.string("name"))
            noticeMessage = "Asked \(name) to quit."
            Task {
                try? await Task.sleep(for: .seconds(2.5))
                await refresh()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Quits a running app the way ⌘Q does, so it can still ask to save work.
/// Shared by the Optimize panel and the web dashboard (through the bridge).
@MainActor
enum AppQuitter {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Parts of macOS that must never be quit from here.
    static let protectedBundleIDs: Set<String> = [
        "com.apple.finder", "com.apple.dock", "com.apple.loginwindow", "com.apple.systemuiserver",
        "com.apple.controlcenter", "com.apple.WindowManager", "com.apple.notificationcenterui",
    ]

    @discardableResult
    static func quit(path: String?, name: String?) throws -> String {
        guard let path, path.hasSuffix(".app") else {
            throw Failure(message: "Only regular apps can be quit from ModelMatrix.")
        }
        let target = URL(fileURLWithPath: path).standardizedFileURL.path
        let matches = NSWorkspace.shared.runningApplications.filter {
            $0.bundleURL?.standardizedFileURL.path == target
        }
        guard let app = matches.first else { throw Failure(message: "\(name ?? "That app") is not running.") }
        let display = app.localizedName ?? name ?? "The app"
        if let reason = refusal(
            bundleID: app.bundleIdentifier, pid: app.processIdentifier, policy: app.activationPolicy)
        {
            throw Failure(message: "\(display) \(reason)")
        }
        matches.forEach { $0.terminate() }
        return display
    }

    /// Why an app may not be quit, or nil when it may.
    static func refusal(bundleID: String?, pid: pid_t, policy: NSApplication.ActivationPolicy) -> String? {
        if pid == ProcessInfo.processInfo.processIdentifier
            || (bundleID != nil && bundleID == Bundle.main.bundleIdentifier)
        {
            return "is ModelMatrix itself; use Quit in the menu bar instead."
        }
        if let bundleID, protectedBundleIDs.contains(bundleID) { return "is part of macOS and was left running." }
        if policy != .regular { return "runs in the background and was left running." }
        return nil
    }
}

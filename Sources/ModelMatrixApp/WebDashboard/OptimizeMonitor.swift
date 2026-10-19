import AppKit
import Foundation
import Observation

/// Menu bar twin of the web dashboard's Optimize window: measures memory, lists
/// what can be freed (idle Ollama models, model servers, the file cache, other
/// apps) and frees the selected items through the local controller.
@MainActor
@Observable
final class OptimizeMonitor {
    enum Phase: Equatable { case idle, running, quitting, purging, done }

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
    /// Bundle paths of the other apps picked to quit. Presets never pick apps.
    var selectedApps: Set<String> = []
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
    var isBusy: Bool { phase == .running || phase == .quitting || phase == .purging }
    var chosen: [JSONRow] { items.filter { selected.contains($0.string("id") ?? "") } }
    var quittableApps: [JSONRow] { apps.filter { $0.bool("quittable") && $0.string("path") != nil } }
    var chosenApps: [JSONRow] { quittableApps.filter { selectedApps.contains($0.string("path") ?? "") } }
    var allAppsSelected: Bool { !quittableApps.isEmpty && chosenApps.count == quittableApps.count }
    /// Models and caches plus the selected apps.
    var estimate: Double {
        (chosen + chosenApps).reduce(0) { $0 + ($1.double("bytes") ?? 0) }
    }
    var hasWork: Bool { !chosen.isEmpty || !chosenApps.isEmpty }
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
                selectedApps = selectedApps.intersection(quittableApps.compactMap { $0.string("path") })
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

    func toggleApp(_ path: String) {
        if selectedApps.contains(path) { selectedApps.remove(path) } else { selectedApps.insert(path) }
    }

    /// Selects every app that can be quit, or clears them when all are selected.
    func toggleAllApps() {
        selectedApps = allAppsSelected ? [] : Set(quittableApps.compactMap { $0.string("path") })
    }

    func reset() {
        outcome = nil
        phase = .idle
        Task { await refresh() }
    }

    func run() async {
        guard let client, hasWork, !isBusy else { return }
        let api = client()
        let chosenNow = chosen
        let appsNow = chosenApps
        let purge = wantsPurge
        let titles = Dictionary(
            items.compactMap { row in row.string("id").map { ($0, row.string("title") ?? $0) } },
            uniquingKeysWith: { first, _ in first })
        var steps: [Step] = []
        var before: JSONRow? = plan?.row("memory")
        var after: JSONRow?
        noticeMessage = nil
        errorMessage = nil
        do {
            let ids = chosenNow.filter { $0.string("kind") != "file_cache" }.compactMap { $0.string("id") }
            if !ids.isEmpty {
                phase = .running
                let result = try await api.post("/api/optimize/run", ["items": ids], timeout: 300)
                before = result.row("before") ?? before
                after = result.row("after")
                for row in result.rows("results") where !row.bool("skipped") {
                    let id = row.string("id") ?? ""
                    steps.append(Step(
                        id: id, title: titles[id] ?? id, ok: row.bool("ok"), skipped: false,
                        message: row.string("message") ?? "", bytes: row.double("bytes")))
                }
            }
            if !appsNow.isEmpty {
                phase = .quitting
                steps += await quitApps(appsNow)
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
            if !appsNow.isEmpty {
                // Closed apps hand memory back over a second or two.
                try? await Task.sleep(for: .seconds(1.5))
                after = (try? await api.object("/api/optimize/plan", timeout: 20))?.row("memory") ?? after
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

    /// Quits the picked apps together and turns each outcome into a result step.
    func quitApps(_ rows: [JSONRow]) async -> [Step] {
        let sizes = Dictionary(
            rows.compactMap { row in row.string("path").map { ($0, row.double("bytes") ?? 0) } },
            uniquingKeysWith: { first, _ in first })
        let results = await AppQuitter.quitAll(rows.map { (path: $0.string("path"), name: $0.string("name")) })
        selectedApps.subtract(results.filter { $0.status == .quit }.map(\.path))
        return results.map { result in
            Step(
                id: "app:\(result.path)", title: "Quit \(result.name)", ok: result.status == .quit,
                skipped: result.status == .stillOpen, message: result.message,
                bytes: result.status == .quit ? sizes[result.path] : nil)
        }
    }
}


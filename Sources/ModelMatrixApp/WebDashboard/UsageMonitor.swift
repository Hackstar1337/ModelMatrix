import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

/// Usage statistics for the menu bar's Usage panel: the same numbers the web
/// dashboard shows (KPIs, live feed, model split, clients, relay, capture mode,
/// Ollama), polled from the local controller only while the panel is open.
@MainActor
@Observable
final class UsageMonitor {
    static let ranges = ["1h", "24h", "7d", "30d"]
    static let tiers = ["all", "local", "cloud"]

    var range = "24h" { didSet { if oldValue != range { refreshSoon() } } }
    var tier = "all" { didSet { if oldValue != tier { refreshSoon() } } }

    var summary: JSONRow?
    var totals: JSONRow?
    var recent: [JSONRow] = []
    var inFlight: [JSONRow] = []
    var models: [JSONRow] = []
    var clients: [JSONRow] = []
    var relay: JSONRow?
    var capture: [JSONRow] = []
    var ollama: JSONRow?
    var errorMessage: String?
    var noticeMessage: String?
    var lastUpdated: Date?
    var isWorking = false

    @ObservationIgnored var client: () -> WebDashboardClient = {
        WebDashboardClient(baseURL: "http://127.0.0.1:7700", token: "")
    }
    @ObservationIgnored var pollTask: Task<Void, Never>?
    @ObservationIgnored var tick = 0

    func start(client: @escaping () -> WebDashboardClient) {
        self.client = client
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh(includeSlow: self.tick % 4 == 0)
                self.tick += 1
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        tick = 0
    }

    func refreshSoon() {
        Task { await refresh(includeSlow: false) }
    }

    func refresh(includeSlow: Bool) async {
        let api = client()
        let params = WebDashboardClient.query(["range": range, "tier": tier])
        do {
            let overview = try await api.object("/api/usage/overview" + params)
            summary = overview.row("summary")
            totals = overview.row("totals")
            recent = overview.rows("recent")
            inFlight = overview.rows("in_flight")
            models = overview.rows("models")
            clients = overview.rows("clients")
            relay = overview.row("relay") ?? relay
            errorMessage = nil
            lastUpdated = Date()
        } catch {
            errorMessage = error.localizedDescription
        }
        guard includeSlow else { return }
        if let settings = try? await api.object("/api/usage/settings") {
            relay = settings
            capture = settings.rows("capture")
        }
        ollama = try? await api.object("/api/ollama/status")
    }

    // MARK: Actions (same endpoints the web dashboard uses)

    func perform(_ success: String, _ work: @escaping (WebDashboardClient) async throws -> Void) {
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await work(client())
                noticeMessage = success
                errorMessage = nil
                await refresh(includeSlow: true)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func renameClient(_ id: String, to name: String) {
        perform(name.isEmpty ? "Client name reset" : "Renamed to \(name)") { api in
            try await api.post("/api/usage/clients/rename", ["client_id": id, "name": name])
        }
    }

    func setRetention(days: Int) {
        perform("Keeping \(days) days of history") { api in
            try await api.post("/api/usage/settings", ["retention_days": days])
        }
    }

    func resetHistory() {
        perform("Usage history cleared") { api in
            try await api.post("/api/usage/reset", ["confirm": true])
        }
    }

    func setCapture(profile: String, enabled: Bool) {
        perform(enabled ? "Capture on for \(profile) - restart it to apply" : "Capture off for \(profile)") { api in
            try await api.post("/api/profiles/capture", ["profile": profile, "enabled": enabled])
        }
    }

    /// Downloads the CSV export for the current filter and asks where to save it.
    func exportCSV() {
        let api = client()
        let params = WebDashboardClient.query(["range": range, "tier": tier])
        let stamp = ISO8601DateFormatter().string(from: Date()).prefix(10)
        Task {
            do {
                let data = try await api.data("/api/usage/export.csv" + params, timeout: 60)
                let panel = NSSavePanel()
                panel.nameFieldStringValue = "modelmatrix-usage-\(range)-\(stamp).csv"
                panel.allowedContentTypes = [.commaSeparatedText]
                NSApp.activate(ignoringOtherApps: true)
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try data.write(to: url, options: .atomic)
                noticeMessage = "Saved \(url.lastPathComponent)"
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

enum UsageFormat {
    static func compact(_ value: Double?) -> String {
        guard let value else { return "-" }
        let magnitude = abs(value)
        if magnitude >= 1_000_000_000 { return String(format: "%.1fB", value / 1_000_000_000) }
        if magnitude >= 1_000_000 { return String(format: "%.1fM", value / 1_000_000) }
        if magnitude >= 1_000 { return String(format: "%.1fk", value / 1_000) }
        if value == value.rounded() { return String(Int(value)) }
        return String(format: "%.1f", value)
    }

    static func number(_ value: Double?, digits: Int = 1) -> String {
        guard let value, value.isFinite else { return "-" }
        return String(format: "%.\(digits)f", value)
    }

    static func seconds(_ milliseconds: Double?) -> String {
        guard let milliseconds, milliseconds.isFinite, milliseconds > 0 else { return "-" }
        if milliseconds < 1_000 { return String(format: "%.2fs", milliseconds / 1_000) }
        if milliseconds < 60_000 { return String(format: "%.1fs", milliseconds / 1_000) }
        return duration(milliseconds)
    }

    static func duration(_ milliseconds: Double?) -> String {
        guard let milliseconds, milliseconds > 0 else { return "-" }
        let seconds = milliseconds / 1_000
        if seconds < 60 { return String(format: "%.0fs", seconds) }
        if seconds < 3_600 { return String(format: "%.0fm", seconds / 60) }
        if seconds < 86_400 { return String(format: "%.1fh", seconds / 3_600) }
        return String(format: "%.1fd", seconds / 86_400)
    }

    static func clock(_ epoch: Double?) -> String {
        guard let epoch else { return "-" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date(timeIntervalSince1970: epoch))
    }

    static func ago(_ epoch: Double?) -> String {
        guard let epoch else { return "-" }
        let delta = max(0, Date().timeIntervalSince1970 - epoch)
        if delta < 60 { return "\(Int(delta))s ago" }
        if delta < 3_600 { return "\(Int(delta / 60))m ago" }
        if delta < 86_400 { return "\(Int(delta / 3_600))h ago" }
        return "\(Int(delta / 86_400))d ago"
    }

    static func bytes(_ value: Double?) -> String {
        guard let value, value > 0 else { return "-" }
        let gb = value / 1_073_741_824
        return gb >= 1 ? String(format: "%.1f GB", gb) : String(format: "%.0f MB", value / 1_048_576)
    }
}

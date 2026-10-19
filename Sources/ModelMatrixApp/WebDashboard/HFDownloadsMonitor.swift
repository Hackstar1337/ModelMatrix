import Foundation
import Observation

/// One notification: a download is ready to use, needs an engine or memory,
/// didn't start, finished without starting, or failed.
struct HFDownloadEvent: Equatable {
    let id: String
    let title: String
    let body: String
}

/// Decides which download changes deserve a notification. Pure, so it is tested
/// without a controller.
enum HFDownloadEvents {
    /// The stage worth telling the user about, or nil while the job is still working.
    /// After a download completes, ModelMatrix creates the profile ("creating") and
    /// usually starts it ("starting"); only the state it settles in is reported, so a
    /// finished download gives one notification, not three.
    static func milestone(_ job: JSONRow, now: Date = Date()) -> String? {
        switch job.string("state") {
        case "failed":
            return "failed"
        case "completed":
            switch job.string("profile_state") {
            case "ready", "needs_engine", "needs_memory", "start_failed":
                return job.string("profile_state")
            case "created":
                return "completed"
            case "creating", "starting":
                return nil
            default:
                // No profile step (for example a model ModelMatrix can't run by itself):
                // report the finished download once it has settled for a minute.
                guard let done = date(job.string("completed_at")) else { return nil }
                return now.timeIntervalSince(done) > 60 ? "completed" : nil
            }
        default:
            return nil
        }
    }

    /// Notifications for jobs whose milestone changed since the previous poll. Jobs
    /// not seen before only count when they were created after `since` (so opening
    /// the app doesn't replay old downloads).
    static func events(
        previous: [String: String?], jobs: [JSONRow], since: Date, now: Date = Date()
    ) -> (events: [HFDownloadEvent], seen: [String: String?]) {
        var seen: [String: String?] = [:]
        var events: [HFDownloadEvent] = []
        for job in jobs {
            guard let id = job.string("id") else { continue }
            let stage = milestone(job, now: now)
            seen[id] = stage
            guard let stage else { continue }
            if let before = previous[id] {
                if before == stage { continue }
            } else if (date(job.string("created_at")) ?? .distantPast) < since {
                continue
            }
            events.append(event(job, stage: stage))
        }
        return (events, seen)
    }

    static func event(_ job: JSONRow, stage: String) -> HFDownloadEvent {
        let name = job.string("display_name") ?? job.string("repo") ?? "The model"
        let place = job.string("host_name").map { " on \($0)" } ?? ""
        let message = job.string("profile_message")
        let identifier = "hf-\(job.string("id") ?? name)"
        switch stage {
        case "ready":
            var body = "Downloaded, started and answered a test message\(place)."
            if let model = job.string("ready_model") { body += " Use the model name \(model)" }
            if let url = job.string("ready_url") { body += " at \(url)" }
            return HFDownloadEvent(id: identifier, title: "\(name) is ready", body: body + (body.hasSuffix(".") ? "" : "."))
        case "needs_engine":
            let engine = engineName(job.string("engine"))
            return HFDownloadEvent(
                id: identifier, title: "\(name) needs \(engine)",
                body: "Downloaded\(place). Open Downloads in ModelMatrix to install \(engine); nothing is installed until you approve it.")
        case "needs_memory":
            return HFDownloadEvent(
                id: identifier, title: "\(name) is waiting for memory",
                body: message ?? "Downloaded\(place), but there isn't enough free memory to start it. Use Optimize, then start it.")
        case "start_failed":
            return HFDownloadEvent(
                id: identifier, title: "\(name) didn't start",
                body: message ?? "Downloaded\(place), but the model server didn't start. Open Downloads for details.")
        case "failed":
            return HFDownloadEvent(
                id: identifier, title: "Download failed: \(name)",
                body: job.string("error") ?? job.string("message") ?? "Open Downloads in ModelMatrix to retry.")
        default:
            return HFDownloadEvent(
                id: identifier, title: "\(name) downloaded",
                body: message ?? "Saved\(place) to \(job.string("folder") ?? "the models folder") and checked.")
        }
    }

    static func engineName(_ id: String?) -> String {
        switch id {
        case "mlx-lm": "MLX"
        case "ollama": "Ollama"
        default: "llama.cpp"
        }
    }

    static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let value = formatter.date(from: text) { return value }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    static func isActive(_ job: JSONRow) -> Bool {
        ["queued", "downloading", "waiting", "verifying"].contains(job.string("state") ?? "")
    }

    static func isStarting(_ job: JSONRow) -> Bool {
        ["creating", "starting"].contains(job.string("profile_state") ?? "")
    }
}

/// Menu bar side of Hugging Face downloads (this Mac and remote hosts): keeps the
/// Downloads panel current, runs its buttons through the controller, and posts a
/// notification when a download settles. Runs from app launch, so notifications
/// arrive even when the panel is closed. Polls quickly only while something is
/// downloading or starting.
@MainActor
@Observable
final class HFDownloadsMonitor {
    static let shared = HFDownloadsMonitor()

    var downloads: [JSONRow] = []
    var models: [JSONRow] = []
    var untracked: [JSONRow] = []
    var unreachable: [String] = []
    var loaded = false
    var modelsLoaded = false
    var errorMessage: String?
    var noticeMessage: String?
    var busy: Set<String> = []
    var panelOpen = false {
        didSet { if panelOpen, !oldValue { wake() } }
    }

    @ObservationIgnored private var client: (() -> WebDashboardClient)?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var lastPoll = Date.distantPast
    @ObservationIgnored private var nudged = false
    @ObservationIgnored private var seen: [String: String?] = [:]
    @ObservationIgnored private var primed = false
    @ObservationIgnored private let startedAt = Date()

    var activeCount: Int { downloads.filter(HFDownloadEvents.isActive).count }

    var interval: TimeInterval {
        let working = downloads.contains { HFDownloadEvents.isActive($0) || HFDownloadEvents.isStarting($0) }
        if working { return panelOpen ? 1.5 : 3 }
        return panelOpen ? 4 : 15
    }

    func start(client: @escaping () -> WebDashboardClient) {
        self.client = client
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.nudged || Date().timeIntervalSince(self.lastPoll) >= self.interval {
                    self.nudged = false
                    await self.refresh()
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    /// Poll on the next tick (after an action, or when the panel opens).
    func wake() { nudged = true }

    func refresh() async {
        guard let client else { return }
        lastPoll = Date()
        let api = client()
        do {
            let list = try await api.object("/api/hf/downloads?host=all", timeout: 15)
            downloads = list.rows("downloads")
            unreachable = list.strings("unreachable")
            errorMessage = nil
            loaded = true
            announce()
        } catch {
            errorMessage = "Couldn't read downloads from the ModelMatrix controller: \(error.localizedDescription)"
        }
        guard panelOpen else { return }
        if let list = try? await api.object("/api/hf/models?host=all", timeout: 15) {
            models = list.rows("models")
            untracked = list.rows("untracked")
            modelsLoaded = true
        }
    }

    private func announce() {
        let result = HFDownloadEvents.events(previous: seen, jobs: downloads, since: startedAt)
        seen = result.seen
        // The first answer only records where things stand.
        guard primed else {
            primed = true
            return
        }
        for event in result.events {
            HFNotifier.shared.post(id: event.id, title: event.title, body: event.body)
        }
    }

    // MARK: Actions (same controller calls as the web dashboard)

    /// pause, resume, cancel or start ("Start and test").
    func act(_ job: JSONRow, _ action: String, deleteFiles: Bool? = nil) async {
        guard let client, let id = job.string("id") else { return }
        var body: [String: Any] = [:]
        if let host = job.string("host_name") { body["host"] = host }
        if let deleteFiles { body["delete_files"] = deleteFiles }
        await perform(id) {
            _ = try await client().post("/api/hf/downloads/\(Self.escape(id))/\(action)", body, timeout: 60)
        }
    }

    func removeFromList(_ job: JSONRow) async {
        guard let client, let id = job.string("id") else { return }
        var query: [String: String] = [:]
        if let host = job.string("host_name") { query["host"] = host }
        await perform(id) {
            _ = try await client().data(
                "/api/hf/downloads/\(Self.escape(id))" + WebDashboardClient.query(query), method: "DELETE", timeout: 30)
        }
    }

    func deleteModel(_ model: JSONRow, deleteFiles: Bool) async {
        guard let client, let id = model.string("id") else { return }
        var body: [String: Any] = ["id": id, "delete_files": deleteFiles]
        if let host = model.string("host_name") { body["host"] = host }
        let name = model.string("display_name") ?? id
        await perform(id) {
            let result = try await client().post("/api/hf/models/delete", body, timeout: 120)
            var text = "Removed \(name)"
            if result.bool("files_deleted"), let freed = result.double("freed_bytes"), freed > 0 {
                text += " and freed \(UsageFormat.bytes(freed))"
            }
            if result.bool("kept_in_ollama") { text += ". It stays in Ollama because it was there before ModelMatrix" }
            self.noticeMessage = text + "."
        }
    }

    private func perform(_ id: String, _ work: () async throws -> Void) async {
        busy.insert(id)
        defer { busy.remove(id) }
        do {
            try await work()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        await refresh()
    }

    static func escape(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

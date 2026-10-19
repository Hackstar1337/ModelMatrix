import AppKit
import Foundation
import Observation

/// Menu bar twin of the web dashboard's "Add a model from Hugging Face" dialog.
/// Checking only reads the file list and model settings; nothing downloads until
/// Download is pressed, and an engine is only installed after its plan is shown
/// and approved (the plan id is single-use and expires after 10 minutes).
@MainActor
@Observable
final class HFCheckModel {
    enum Phase: Equatable { case idle, checking, downloading }

    var input = ""
    /// A remote host's name, or "" for this Mac.
    var host = ""
    var report: JSONRow?
    var selected: String?
    /// nil = the recommended engine; otherwise the backup engine's id (Ollama).
    var engineChoice: String?
    /// nil = the recommended context; otherwise the chat memory (tokens) to plan for.
    var context: Int?
    var phase: Phase = .idle
    var errorMessage: String?
    var noticeMessage: String?
    /// Kept for API compatibility with the dashboard-era property name; this
    /// now covers both memory-fit and quantization-quality confirmations.
    var confirmingTooBig = false

    // Engine install, update or removal: plan first, then the approved job.
    var planEngine: (id: String, name: String, action: String, host: String)?
    var plan: JSONRow?
    var planError: String?
    var job: JSONRow?
    var jobLines: [String] = []

    @ObservationIgnored private var checkTask: Task<Void, Never>?
    @ObservationIgnored private var jobTask: Task<Void, Never>?

    var place: String { host.isEmpty ? "this Mac" : host }
    var variants: [JSONRow] { report?.rows("variants") ?? [] }
    var variant: JSONRow? { variants.first { $0.string("label") == selected } }
    var isModel: Bool { report?.string("kind") == "model" }
    var loginNeeded: Bool { report?.row("repo")?.bool("login_required") ?? false }
    var canDownload: Bool {
        guard let report, isModel, report.bool("download_available"), let variant, variant.bool("supported") else { return false }
        return !loginNeeded && phase == .idle
    }
    var jobRunning: Bool { job?.string("state") == "running" }

    enum DownloadConfirmationReason: Equatable {
        case memory
        case quality
    }

    var confirmationReasons: [DownloadConfirmationReason] {
        guard let variant else { return [] }
        return Self.confirmationReasons(for: variant)
    }

    /// Recommendation is preferred even when it is an advisory-only fit. If
    /// it is absent or cannot be selected, choose a supported fitting version,
    /// then fall back to any supported version so a large download is never
    /// blocked merely because no version fits the memory estimate.
    static func preferredVariantLabel(rows: [JSONRow], recommendation: String?) -> String? {
        if let recommendation,
           let row = rows.first(where: { $0.string("label") == recommendation && $0.bool("supported") })
        {
            return row.string("label")
        }
        return rows.first { $0.bool("supported") && $0.row("fit")?.string("level") != "too_big" }?.string("label")
            ?? rows.first { $0.bool("supported") }?.string("label")
    }

    /// A download remains possible for these warnings, but asks the user to
    /// acknowledge the separate memory and quality trade-offs first.
    static func confirmationReasons(for variant: JSONRow) -> [DownloadConfirmationReason] {
        var reasons: [DownloadConfirmationReason] = []
        if variant.row("fit")?.string("level") == "too_big" { reasons.append(.memory) }
        if let bits = variant.double("bits_per_weight"), bits < 3.5 { reasons.append(.quality) }
        return reasons
    }

    /// The engine the model needs, from the report's engine list.
    var neededEngine: JSONRow? {
        guard let summary = report?.row("engine"), let needed = summary.string("needed") else { return nil }
        return summary.rows("engines").first { $0.string("id") == needed }
    }

    /// The backup engine (Ollama for GGUF) when it is installed and can be chosen instead.
    var backupEngine: JSONRow? {
        guard let summary = report?.row("engine"), let backup = summary.string("backup"), !variants.isEmpty else { return nil }
        return summary.rows("engines").first { $0.string("id") == backup && $0.bool("installed") }
    }

    /// Context lengths offered, up to the model's own maximum.
    var contextChoices: [Int] {
        let all = [4096, 8192, 16384, 32768, 65536, 131072]
        guard let maximum = report?.row("model")?.int("max_context") else { return all }
        return all.filter { $0 <= maximum }
    }

    func check(_ client: WebDashboardClient, name: String? = nil) {
        if let name { input = name }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        checkTask?.cancel()
        phase = .checking
        errorMessage = nil
        noticeMessage = nil
        let target = host
        checkTask = Task {
            var items = ["name": text]
            if !target.isEmpty { items["host"] = target }
            if let context { items["context"] = "\(context)" }
            do {
                let next = try await client.object("/api/hf/check" + WebDashboardClient.query(items), timeout: 120)
                guard !Task.isCancelled else { return }
                report = next
                engineChoice = nil
                confirmingTooBig = false
                let rows = next.rows("variants")
                selected = Self.preferredVariantLabel(
                    rows: rows, recommendation: next.row("recommendation")?.string("label"))
            } catch {
                guard !Task.isCancelled else { return }
                report = nil
                errorMessage = error.localizedDescription
            }
            phase = .idle
        }
    }

    /// Checks the same model again (after a host change or an engine install).
    func recheck(_ client: WebDashboardClient) {
        if isModel, let repo = report?.row("repo")?.string("id") { input = repo }
        check(client)
    }

    func select(_ row: JSONRow) {
        guard row.bool("supported"), let label = row.string("label") else { return }
        selected = label
        confirmingTooBig = false
    }

    /// Download pressed. A version that won't fit asks first, like the dashboard.
    func requestDownload(_ client: WebDashboardClient) {
        guard canDownload else { return }
        if !confirmationReasons.isEmpty {
            confirmingTooBig = true
        } else {
            Task { await download(client) }
        }
    }

    func download(_ client: WebDashboardClient) async {
        guard let repo = report?.row("repo")?.string("id"), let label = variant?.string("label") else { return }
        phase = .downloading
        errorMessage = nil
        var body: [String: Any] = ["name": repo, "version": label]
        if !host.isEmpty { body["host"] = host }
        if let engineChoice { body["engine"] = engineChoice }
        if let context { body["context"] = context }
        do {
            let result = try await client.post("/api/hf/downloads", body, timeout: 120)
            let name = result.row("download")?.string("display_name") ?? "\(repo) \(label)"
            noticeMessage = result.bool("existing")
                ? "\(name) is already in Downloads below."
                : "Downloading \(name) to \(place). It keeps going if you close this panel, and you'll get a notification when it's ready."
            HFDownloadsMonitor.shared.wake()
        } catch {
            errorMessage = "Download didn't start: \(error.localizedDescription)"
        }
        phase = .idle
    }

    // MARK: Engine install (approve first)

    /// Asks the controller what installing (or updating/removing) would do. Nothing changes yet.
    func preparePlan(
        _ client: WebDashboardClient, engine: String, name: String, action: String = "install", host target: String? = nil
    ) {
        jobTask?.cancel()
        let planHost = target ?? host
        planEngine = (engine, name, action, planHost)
        plan = nil
        planError = nil
        job = nil
        jobLines = []
        var body: [String: Any] = ["engine": engine, "action": action]
        if !planHost.isEmpty { body["host"] = planHost }
        Task {
            do {
                plan = try await client.post("/api/hf/engines/plan", body, timeout: 90).row("plan")
            } catch {
                planError = error.localizedDescription
            }
        }
    }

    func dismissPlan() {
        guard !jobRunning else { return }
        jobTask?.cancel()
        planEngine = nil
        plan = nil
        planError = nil
        job = nil
        jobLines = []
    }

    /// The user pressed Install/Update/Remove on the shown plan.
    func approvePlan(_ client: WebDashboardClient) {
        guard let id = plan?.string("id") else { return }
        planError = nil
        Task {
            do {
                job = try await client.post("/api/hf/engines/run", ["plan_id": id], timeout: 30).row("job")
                jobLines = []
                follow(client)
            } catch {
                planError = error.localizedDescription
            }
        }
    }

    func stopJob(_ client: WebDashboardClient) {
        guard let id = job?.string("id") else { return }
        Task {
            if let next = try? await client.post("/api/hf/engines/jobs/\(HFDownloadsMonitor.escape(id))/cancel", [:], timeout: 30).row("job") {
                job = next
            }
        }
    }

    private func follow(_ client: WebDashboardClient) {
        jobTask?.cancel()
        jobTask = Task {
            var next = 0
            while !Task.isCancelled, let id = job?.string("id") {
                if let answer = try? await client.object(
                    "/api/hf/engines/jobs/\(HFDownloadsMonitor.escape(id))" + WebDashboardClient.query(["since": "\(next)"]),
                    timeout: 20)
                {
                    jobLines = Array((jobLines + answer.strings("lines")).suffix(200))
                    next = answer.int("next") ?? next
                    if let latest = answer.row("job") { job = latest }
                    if job?.string("state") != "running" { break }
                }
                try? await Task.sleep(for: .milliseconds(900))
            }
            guard !Task.isCancelled else { return }
            if job?.string("state") == "succeeded" {
                // The engine is here now: refresh the check, and let waiting downloads start.
                if report != nil { recheck(client) }
                HFDownloadsMonitor.shared.wake()
            }
        }
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Small text helpers shared by the Downloads panel.
enum HFWords {
    static func size(_ value: Double?) -> String {
        guard let value, value > 0 else { return "0 MB" }
        let gb = value / 1_073_741_824
        if gb >= 1 { return String(format: gb >= 100 ? "%.0f GB" : "%.1f GB", gb) }
        return "\(max(1, Int((value / 1_048_576).rounded()))) MB"
    }

    static func context(_ tokens: Int?) -> String {
        guard let tokens, tokens > 0 else { return "-" }
        return tokens >= 1024 && tokens % 1024 == 0 ? "\(tokens / 1024)K" : "\(tokens)"
    }

    static func kindDescription(_ description: String, vision: Bool) -> String {
        guard vision, !description.localizedCaseInsensitiveContains("image") else { return description }
        return description + " that can also read images"
    }

    static func fit(_ level: String?) -> String {
        switch level {
        case "good": "FITS WELL"
        case "tight": "TIGHT FIT"
        case "too_big": "TOO BIG"
        default: "UNKNOWN"
        }
    }

    static func eta(_ seconds: Int?) -> String? {
        guard let seconds, seconds >= 0 else { return nil }
        if seconds < 60 { return "\(seconds)s left" }
        let minutes = Int((Double(seconds) / 60).rounded())
        if minutes < 60 { return "\(minutes) min left" }
        return "\(minutes / 60) h \(minutes % 60) min left"
    }

    /// Badge text for a download, matching the web dashboard.
    static func state(_ job: JSONRow) -> String {
        let state = job.string("state") ?? ""
        if state == "completed" {
            switch job.string("profile_state") {
            case "ready": return "READY"
            case "starting", "creating": return "STARTING"
            case "needs_engine": return "NEEDS ENGINE"
            case "needs_memory": return "NEEDS MEMORY"
            case "start_failed": return "START FAILED"
            default: return "DOWNLOADED"
            }
        }
        return state.uppercased()
    }

    /// Badge colour group: good, busy, warn, bad, or plain.
    static func tone(_ job: JSONRow) -> String {
        switch state(job) {
        case "READY", "DOWNLOADED": "good"
        case "DOWNLOADING", "VERIFYING", "STARTING": "busy"
        case "WAITING", "NEEDS ENGINE", "NEEDS MEMORY": "warn"
        case "FAILED", "START FAILED": "bad"
        default: "plain"
        }
    }

    static func verdictTone(_ code: String?) -> String {
        switch code {
        case "ready": "good"
        case "too_big", "low_quality": "warn"
        case "not_supported", "not_found", "login_required", "unsafe_files", "disk_full", "wrong_architecture": "bad"
        default: "warn"
        }
    }

    static func verdictTitle(_ code: String?, _ title: String) -> String {
        guard code == "too_big" || code == "low_quality",
              !title.lowercased().hasPrefix("suggestion")
        else { return title }
        return "Suggestion: " + title
    }
}

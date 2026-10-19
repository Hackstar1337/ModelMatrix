import Foundation
import Testing
@testable import ModelMatrixApp

/// The menu bar posts one notification when a download settles. These rules are
/// pure, so they are tested here without a controller or the notification centre.
struct HFDownloadEventsTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    func job(
        _ id: String = "d1", state: String, profile: String? = nil, created: Date? = nil, extra: [String: Any] = [:]
    ) -> JSONRow {
        var raw: [String: Any] = [
            "id": id, "state": state, "display_name": "SmolLM2 Q4_K_M", "repo": "bartowski/SmolLM2-135M-Instruct-GGUF",
            "engine": "llama.cpp", "created_at": iso(created ?? start.addingTimeInterval(5)),
        ]
        if let profile { raw["profile_state"] = profile }
        raw.merge(extra) { _, new in new }
        return JSONRow(raw)
    }

    @Test func hfMenuBarWorkingStatesGiveNoMilestone() {
        for state in ["queued", "downloading", "waiting", "verifying", "paused", "cancelled"] {
            #expect(HFDownloadEvents.milestone(job(state: state)) == nil, "\(state)")
        }
        // Profile still being made or started: wait for where it settles.
        #expect(HFDownloadEvents.milestone(job(state: "completed", profile: "creating")) == nil)
        #expect(HFDownloadEvents.milestone(job(state: "completed", profile: "starting")) == nil)
    }

    @Test func hfMenuBarSettledStatesAreMilestones() {
        #expect(HFDownloadEvents.milestone(job(state: "failed")) == "failed")
        for profile in ["ready", "needs_engine", "needs_memory", "start_failed"] {
            #expect(HFDownloadEvents.milestone(job(state: "completed", profile: profile)) == profile)
        }
        #expect(HFDownloadEvents.milestone(job(state: "completed", profile: "created")) == "completed")
    }

    @Test func hfMenuBarDownloadWithoutProfileIsReportedAfterAMinute() {
        let done = start.addingTimeInterval(100)
        let finished = job(state: "completed", extra: ["completed_at": iso(done)])
        #expect(HFDownloadEvents.milestone(finished, now: done.addingTimeInterval(30)) == nil)
        #expect(HFDownloadEvents.milestone(finished, now: done.addingTimeInterval(61)) == "completed")
    }

    @Test func hfMenuBarOneNotificationPerFinishedDownload() {
        var seen: [String: String?] = [:]
        var posted: [HFDownloadEvent] = []
        // downloading -> verifying -> completed/creating -> completed/starting -> completed/ready
        let steps: [JSONRow] = [
            job(state: "downloading"), job(state: "verifying"), job(state: "completed", profile: "creating"),
            job(state: "completed", profile: "starting"),
            job(
                state: "completed", profile: "ready",
                extra: ["ready_model": "smollm2-135m-instruct-q4_k_m", "ready_url": "http://127.0.0.1:7701/v1"]),
            job(state: "completed", profile: "ready"),
        ]
        for step in steps {
            let result = HFDownloadEvents.events(previous: seen, jobs: [step], since: start)
            seen = result.seen
            posted += result.events
        }
        #expect(posted.count == 1)
        #expect(posted.first?.title == "SmolLM2 Q4_K_M is ready")
        #expect(posted.first?.body.contains("smollm2-135m-instruct-q4_k_m") == true)
        #expect(posted.first?.body.contains("http://127.0.0.1:7701/v1") == true)
        #expect(posted.first?.id == "hf-d1")
    }

    @Test func hfMenuBarOldDownloadsAreNotReplayedAtLaunch() {
        let old = job("old", state: "completed", profile: "ready", created: start.addingTimeInterval(-3600))
        let fresh = job("new", state: "failed", extra: ["error": "Disk full"])
        let result = HFDownloadEvents.events(previous: [:], jobs: [old, fresh], since: start)
        #expect(result.events.map(\.id) == ["hf-new"])
        #expect(result.events.first?.title == "Download failed: SmolLM2 Q4_K_M")
        #expect(result.events.first?.body == "Disk full")
        // Both are remembered, so neither repeats on the next poll.
        let again = HFDownloadEvents.events(previous: result.seen, jobs: [old, fresh], since: start)
        #expect(again.events.isEmpty)
    }

    @Test func hfMenuBarRetryAfterFailureNotifiesAgainWhenReady() {
        let failed = HFDownloadEvents.events(previous: [:], jobs: [job(state: "failed")], since: start)
        let retrying = HFDownloadEvents.events(previous: failed.seen, jobs: [job(state: "downloading")], since: start)
        #expect(retrying.events.isEmpty)
        let ready = HFDownloadEvents.events(
            previous: retrying.seen, jobs: [job(state: "completed", profile: "ready")], since: start)
        #expect(ready.events.map(\.title) == ["SmolLM2 Q4_K_M is ready"])
    }

    @Test func hfMenuBarNeedsEngineSaysNothingInstallsWithoutApproval() {
        let mlx = job(state: "completed", profile: "needs_engine", extra: ["engine": "mlx-lm", "host_name": "gpu-box"])
        let event = HFDownloadEvents.event(mlx, stage: "needs_engine")
        #expect(event.title == "SmolLM2 Q4_K_M needs MLX")
        #expect(event.body.contains("on gpu-box"))
        #expect(event.body.contains("nothing is installed until you approve it"))
        #expect(HFDownloadEvents.engineName("llama.cpp") == "llama.cpp")
        #expect(HFDownloadEvents.engineName("ollama") == "Ollama")
    }

    @Test func hfMenuBarActiveAndStartingStates() {
        #expect(HFDownloadEvents.isActive(job(state: "downloading")))
        #expect(HFDownloadEvents.isActive(job(state: "waiting")))
        #expect(!HFDownloadEvents.isActive(job(state: "paused")))
        #expect(!HFDownloadEvents.isActive(job(state: "completed", profile: "starting")))
        #expect(HFDownloadEvents.isStarting(job(state: "completed", profile: "starting")))
    }

    @Test func hfMenuBarBadgeWordsMatchTheWebDashboard() {
        #expect(HFWords.state(job(state: "completed", profile: "ready")) == "READY")
        #expect(HFWords.state(job(state: "completed", profile: "needs_engine")) == "NEEDS ENGINE")
        #expect(HFWords.state(job(state: "completed")) == "DOWNLOADED")
        #expect(HFWords.state(job(state: "downloading")) == "DOWNLOADING")
        #expect(HFWords.tone(job(state: "completed", profile: "start_failed")) == "bad")
        #expect(HFWords.tone(job(state: "waiting")) == "warn")
        #expect(HFWords.verdictTone("ready") == "good")
        #expect(HFWords.verdictTone("too_big") == "bad")
        #expect(HFWords.verdictTone("needs_engine") == "warn")
    }

    @Test func hfMenuBarSizesContextsAndTimes() {
        #expect(HFWords.size(105_000_000) == "100 MB")
        #expect(HFWords.size(4_683_073_536) == "4.4 GB")
        #expect(HFWords.size(150 * 1_073_741_824) == "150 GB")
        #expect(HFWords.size(nil) == "0 MB")
        #expect(HFWords.context(32768) == "32K")
        #expect(HFWords.context(5000) == "5000")
        #expect(HFWords.eta(42) == "42s left")
        #expect(HFWords.eta(600) == "10 min left")
        #expect(HFWords.eta(3900) == "1 h 5 min left")
        #expect(HFWords.fit("tight") == "TIGHT FIT")
    }
}

/// The check model's choices, without a controller.
@MainActor
struct HFCheckModelTests {
    func report(_ variants: [[String: Any]], maxContext: Int = 32768, engine: [String: Any]? = nil) -> JSONRow {
        var raw: [String: Any] = [
            "kind": "model", "download_available": true,
            "repo": ["id": "bartowski/SmolLM2-135M-Instruct-GGUF", "login_required": false],
            "model": ["max_context": maxContext], "variants": variants,
        ]
        if let engine { raw["engine"] = engine }
        return JSONRow(raw)
    }

    @Test func hfMenuBarDownloadNeedsASupportedChosenVersion() {
        let model = HFCheckModel()
        model.report = report([
            ["label": "Q4_K_M", "supported": true, "fit": ["level": "good"]],
            ["label": "Q4_0_4_4", "supported": false, "unsupported_reason": "Old ARM-only layout"],
        ])
        #expect(!model.canDownload)
        model.select(JSONRow(["label": "Q4_0_4_4", "supported": false]))
        #expect(model.selected == nil)
        model.select(JSONRow(["label": "Q4_K_M", "supported": true]))
        #expect(model.selected == "Q4_K_M")
        #expect(model.canDownload)
    }

    @Test func hfMenuBarLoginRequiredBlocksDownload() {
        let model = HFCheckModel()
        var raw = report([["label": "Q4_K_M", "supported": true]]).raw
        raw["repo"] = ["id": "meta-llama/Llama-3.2-1B", "login_required": true]
        model.report = JSONRow(raw)
        model.selected = "Q4_K_M"
        #expect(model.loginNeeded)
        #expect(!model.canDownload)
    }

    @Test func hfMenuBarContextChoicesStopAtTheModelMaximum() {
        let model = HFCheckModel()
        model.report = report([], maxContext: 16384)
        #expect(model.contextChoices == [4096, 8192, 16384])
        model.report = nil
        #expect(model.contextChoices.last == 131072)
    }

    @Test func hfMenuBarBackupEngineOnlyWhenInstalled() {
        let model = HFCheckModel()
        let engines: [[String: Any]] = [
            ["id": "llama.cpp", "name": "llama.cpp", "installed": false],
            ["id": "ollama", "name": "Ollama", "installed": true],
        ]
        model.report = report(
            [["label": "Q4_K_M", "supported": true]], engine: ["needed": "llama.cpp", "backup": "ollama", "engines": engines])
        #expect(model.neededEngine?.string("name") == "llama.cpp")
        #expect(model.backupEngine?.string("id") == "ollama")
        var notInstalled = engines
        notInstalled[1]["installed"] = false
        model.report = report(
            [["label": "Q4_K_M", "supported": true]], engine: ["needed": "llama.cpp", "backup": "ollama", "engines": notInstalled])
        #expect(model.backupEngine == nil)
    }

    @Test func hfMenuBarPlaceNamesTheHost() {
        let model = HFCheckModel()
        #expect(model.place == "this Mac")
        model.host = "gpu-box"
        #expect(model.place == "gpu-box")
    }
}

@Test func compactNumbersSwitchUnitBeforeRoundingUp() {
  #expect(UsageFormat.compact(999_960_000) == "1.0B")
  #expect(UsageFormat.compact(999_960) == "1.0M")
  #expect(UsageFormat.compact(1_500) == "1.5k")
  #expect(UsageFormat.compact(42) == "42")
}

@Test func enginePlanMethodWordingMatchesEngineAndAction() {
  #expect(DownloadsPanelView.planMethodText(method: "homebrew", engine: "mlx-lm", action: "install") == "With Homebrew")
  #expect(DownloadsPanelView.planMethodText(method: "official", engine: "mlx-lm", action: "install").hasPrefix("A private Python made by uv"))
  #expect(DownloadsPanelView.planMethodText(method: "official", engine: "llama.cpp", action: "update").hasPrefix("Official release"))
  #expect(DownloadsPanelView.planMethodText(method: "official", engine: "llama.cpp", action: "uninstall") == "Deletes the copy ModelMatrix installed")
}

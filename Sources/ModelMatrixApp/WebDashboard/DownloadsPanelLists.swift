import AppKit
import SwiftUI

extension DownloadsPanelView {
    var downloadsCard: some View {
        let jobs = monitor.downloads
        let meta = monitor.activeCount > 0 ? "\(monitor.activeCount) active" : "\(jobs.count)"
        return VStack(alignment: .leading, spacing: 6) {
            if let message = monitor.errorMessage {
                UsageNotice(text: message, color: .red, theme: theme)
            } else if let notice = monitor.noticeMessage {
                UsageNotice(text: notice, color: accent, theme: theme)
            }
            if !monitor.unreachable.isEmpty {
                UsageNotice(
                    text: "Couldn't reach \(monitor.unreachable.joined(separator: ", ")). Its downloads aren't shown right now.",
                    color: .orange, theme: theme)
            }
            UsageCard(title: "DOWNLOADS", meta: meta, theme: theme) {
                if !monitor.loaded {
                    loadingRow("Reading downloads…")
                } else if jobs.isEmpty {
                    emptyRow("Nothing downloaded yet. Check a model above to start.")
                }
                ForEach(Array(jobs.enumerated()), id: \.offset) { index, job in
                    if index > 0 { HFDivider(theme: theme) }
                    downloadRow(job)
                }
            }
        }
    }

    func downloadRow(_ job: JSONRow) -> some View {
        let id = job.string("id") ?? ""
        let state = job.string("state") ?? ""
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(job.string("display_name") ?? job.string("repo") ?? "Download")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let host = job.string("host_name") { HFBadge(text: "ON \(host)", tone: "plain", theme: theme, accent: accent) }
                Spacer(minLength: 4)
                if monitor.busy.contains(id) { ProgressView().controlSize(.mini) }
                HFBadge(text: HFWords.state(job), tone: HFWords.tone(job), theme: theme, accent: accent)
            }
            Text(([job.string("repo"), job.string("engine"), job.string("profile").map { "profile \($0)" }].compactMap { $0 })
                .joined(separator: " · "))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(theme.faint)
                .lineLimit(1)
                .truncationMode(.middle)
            if state != "completed", state != "cancelled" {
                UsageBar(fraction: fraction(job), color: state == "paused" ? theme.faint : accent, theme: theme)
            }
            smallText(progressText(job), color: theme.sub)
            if state == "completed", let message = job.string("profile_message") { smallText(message, color: theme.label) }
            if state == "completed", job.string("profile_state") == "ready", let url = job.string("ready_url") {
                readyBox(url: url, model: job.string("ready_model"))
            }
            if let error = job.string("error") { smallText(error, color: .red) }
            ForEach(job.strings("warnings"), id: \.self) { smallText($0, color: .orange) }
            if job.string("profile_state") == "start_failed", !job.strings("profile_log").isEmpty {
                Text(job.strings("profile_log").suffix(6).joined(separator: "\n"))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(theme.sub)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(theme.fieldBg))
            }
            if cancelling == id { cancelBox(job) } else { downloadButtons(job) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    func downloadButtons(_ job: JSONRow) -> some View {
        let id = job.string("id") ?? ""
        let state = job.string("state") ?? ""
        let profile = job.string("profile_state") ?? ""
        let canStart = state == "completed" && ["needs_engine", "created", "needs_memory", "start_failed"].contains(profile)
        let engine = job.string("engine")
        return HStack(spacing: 12) {
            Spacer(minLength: 0)
            if ["downloading", "waiting", "queued"].contains(state) {
                linkButton("Pause") { await monitor.act(job, "pause") }
            }
            if state == "paused" || state == "failed" {
                linkButton(state == "failed" ? "Retry" : "Resume", emphasized: true) { await monitor.act(job, "resume") }
            }
            if state == "completed", profile == "needs_engine", let engine, engine != "ollama" {
                let name = HFDownloadEvents.engineName(engine)
                SettingsLinkButton(title: "Install \(name)…", theme: theme, accent: accent) {
                    check.preparePlan(client, engine: engine, name: name, host: job.string("host_name") ?? "")
                }
                .disabled(check.planEngine != nil)
            }
            if canStart { linkButton("Start and test", emphasized: true) { await monitor.act(job, "start") } }
            if HFDownloadEvents.isActive(job) || state == "paused" {
                SettingsLinkButton(title: "Cancel…", theme: theme, accent: accent) { cancelling = id }
            }
            if state == "failed" || state == "cancelled" {
                linkButton("Remove from list") { await monitor.removeFromList(job) }
            }
        }
        .disabled(monitor.busy.contains(id))
    }

    func cancelBox(_ job: JSONRow) -> some View {
        let place = job.string("host_name").map { " on \($0)" } ?? ""
        let done = "\(HFWords.size(job.double("bytes_done"))) of \(HFWords.size(job.double("bytes_total")))"
        return VStack(alignment: .leading, spacing: 6) {
            Text("Cancel \(job.string("display_name") ?? "this download")?")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(theme.label)
            Text("\(done) is downloaded\(place).")
                .font(.system(size: 9.5))
                .foregroundStyle(theme.sub)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                SettingsLinkButton(title: "Keep downloading", theme: theme, accent: accent) { cancelling = nil }
                if job.string("kind") != "ollama" {
                    SettingsLinkButton(title: "Cancel, keep part", theme: theme, accent: accent) {
                        cancelling = nil
                        Task { await monitor.act(job, "cancel", deleteFiles: false) }
                    }
                }
                SettingsLinkButton(
                    title: job.string("kind") == "ollama" ? "Cancel download" : "Cancel and delete part",
                    emphasized: true, theme: theme, accent: .red
                ) {
                    cancelling = nil
                    Task { await monitor.act(job, "cancel", deleteFiles: true) }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.07)))
    }

    // MARK: Downloaded models

    var modelsCard: some View {
        let models = monitor.models
        let total = models.reduce(0.0) { $0 + ($1.double("bytes_on_disk") ?? 0) }
        return VStack(alignment: .leading, spacing: 6) {
            UsageCard(title: "DOWNLOADED MODELS", meta: models.isEmpty ? nil : "\(models.count) · \(HFWords.size(total))", theme: theme) {
                if !monitor.modelsLoaded {
                    loadingRow("Reading downloaded models…")
                } else if models.isEmpty {
                    emptyRow("No models downloaded with ModelMatrix yet.")
                }
                ForEach(Array(models.enumerated()), id: \.offset) { index, model in
                    if index > 0 { HFDivider(theme: theme) }
                    modelRow(model)
                }
            }
            if !monitor.untracked.isEmpty {
                Text(
                    "Folders in the models folder that no download owns (left alone): "
                        + monitor.untracked.map { "\($0.string("folder") ?? "?") (\(HFWords.size($0.double("bytes_on_disk"))))" }
                        .joined(separator: ", ")
                )
                .font(.system(size: 9.5))
                .foregroundStyle(theme.faint)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    func modelRow(_ model: JSONRow) -> some View {
        let key = (model.string("host_name") ?? "") + ":" + (model.string("id") ?? "")
        let profile = model.string("profile_state") ?? ""
        let ollama = model.string("kind") == "ollama"
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(model.string("display_name") ?? model.string("repo") ?? "Model")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HFBadge(text: (model.string("host_name") ?? "This Mac").uppercased(), tone: "plain", theme: theme, accent: accent)
                Spacer(minLength: 4)
                if monitor.busy.contains(model.string("id") ?? "") { ProgressView().controlSize(.mini) }
                if !profile.isEmpty {
                    HFBadge(
                        text: HFWords.state(JSONRow(["state": "completed", "profile_state": profile])),
                        tone: HFWords.tone(JSONRow(["state": "completed", "profile_state": profile])),
                        theme: theme, accent: accent)
                }
            }
            Text(
                [
                    model.string("engine"), ollama ? "in Ollama" : HFWords.size(model.double("bytes_on_disk")),
                    model.string("profile").map { "profile \($0)" },
                ].compactMap { $0 }.joined(separator: " · ")
            )
            .font(.system(size: 9.5, design: .monospaced))
            .foregroundStyle(theme.sub)
            .lineLimit(1)
            .truncationMode(.middle)
            if let missing = model.int("missing_files"), missing > 0 {
                smallText("\(missing) file(s) missing from the folder", color: .red)
            }
            if profile == "ready", let url = model.string("ready_url") { readyBox(url: url, model: model.string("ready_model")) }
            if deleting == key {
                deleteBox(model, ollama: ollama)
            } else {
                HStack(spacing: 12) {
                    Spacer(minLength: 0)
                    if profile != "ready", profile != "starting" {
                        linkButton("Start and test", emphasized: true) { await monitor.act(model, "start") }
                    }
                    SettingsLinkButton(title: "Delete…", theme: theme, accent: accent) { deleting = key }
                        .accessibilityLabel("Delete \(model.string("display_name") ?? "model") on \(model.string("host_name") ?? "this Mac")")
                }
                .disabled(monitor.busy.contains(model.string("id") ?? ""))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    func deleteBox(_ model: JSONRow, ollama: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Delete \(model.string("display_name") ?? "this model")?")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(theme.label)
            Text(
                (model.string("profile").map { "The profile \($0) is stopped and removed." } ?? "It is removed from the list.")
                    + (ollama ? " A model Ollama already had before ModelMatrix downloaded it is never removed from Ollama." : "")
            )
            .font(.system(size: 9.5))
            .foregroundStyle(theme.sub)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                SettingsLinkButton(title: "Cancel", theme: theme, accent: accent) { deleting = nil }
                SettingsLinkButton(title: ollama ? "Keep in Ollama" : "Keep files", theme: theme, accent: accent) {
                    deleting = nil
                    Task { await monitor.deleteModel(model, deleteFiles: false) }
                }
                SettingsLinkButton(
                    title: ollama ? "Delete and remove from Ollama" : "Delete with files (\(HFWords.size(model.double("bytes_on_disk"))))",
                    emphasized: true, theme: theme, accent: .red
                ) {
                    deleting = nil
                    Task { await monitor.deleteModel(model, deleteFiles: true) }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.07)))
    }

    // MARK: Helpers

    func fraction(_ job: JSONRow) -> Double {
        guard let total = job.double("bytes_total"), total > 0 else { return 0 }
        return (job.double("bytes_done") ?? 0) / total
    }

    func progressText(_ job: JSONRow) -> String {
        let done = HFWords.size(job.double("bytes_done"))
        let total = job.double("bytes_total") ?? 0
        let of = total > 0 ? "\(done) of \(HFWords.size(total))" : done
        switch job.string("state") {
        case "downloading":
            let speed = (job.double("speed_bytes_per_second") ?? 0) > 0 ? "\(HFWords.size(job.double("speed_bytes_per_second")))/s" : nil
            return [of, speed, HFWords.eta(job.int("eta_seconds"))].compactMap { $0 }.joined(separator: " · ")
        case "waiting": return job.string("message") ?? "Waiting for \(job.string("waiting_for") ?? "a moment")"
        case "queued": return job.string("message") ?? "Waiting for the download before it to finish"
        case "verifying": return job.string("message") ?? "Checking every file against its published SHA-256"
        case "paused": return "\(of) · paused, resumes where it stopped"
        case "completed": return "\(HFWords.size(total)) · \(job.string("message") ?? "Downloaded and verified")"
        default: return job.string("message") ?? ""
        }
    }

    func readyBox(url: String, model: String?) -> some View {
        HStack(spacing: 8) {
            Text(url + (model.map { "  ·  model \"\($0)\"" } ?? ""))
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(theme.label)
                .textSelection(.enabled)
                .lineLimit(2)
            Spacer(minLength: 0)
            SettingsLinkButton(title: "Copy address", theme: theme, accent: accent) { HFCheckModel.copy(url) }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(theme.fieldBg))
    }

    func linkButton(_ title: String, emphasized: Bool = false, _ work: @escaping @MainActor () async -> Void) -> some View {
        SettingsLinkButton(title: title, emphasized: emphasized, theme: theme, accent: accent) { Task { await work() } }
    }

    func smallText(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9.5))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    func loadingRow(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(.system(size: 11)).foregroundStyle(theme.sub)
        }
        .padding(10)
    }

    func emptyRow(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(theme.sub).padding(10)
    }
}

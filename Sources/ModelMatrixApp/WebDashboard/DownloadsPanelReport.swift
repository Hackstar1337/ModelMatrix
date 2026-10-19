import AppKit
import SwiftUI

extension DownloadsPanelView {
    @ViewBuilder
    func reportSection(_ report: JSONRow) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            verdictBox(report)
            if report.string("kind") == "search" {
                alternativesCard("MATCHING MODELS", report.rows("search_results"))
            } else {
                factsCard(report)
                if check.loginNeeded {
                    UsageNotice(
                        text: "This model needs a Hugging Face login. Accept its terms on its Hugging Face page, "
                            + "save a token in the web dashboard (Settings → Hugging Face), then check again.",
                        color: .orange, theme: theme)
                }
                engineBlock(report)
                if let backup = check.backupEngine { engineChoice(report, backup: backup) }
                if !check.variants.isEmpty {
                    versionsCard(report)
                    downloadBar(report)
                }
                if !report.rows("alternatives").isEmpty {
                    alternativesCard("READY-TO-RUN VERSIONS OF THIS MODEL", report.rows("alternatives"))
                }
                ForEach(report.strings("notes"), id: \.self) { note in
                    Text("• " + note)
                        .font(.system(size: 9.5))
                        .foregroundStyle(theme.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .opacity(check.phase == .checking ? 0.55 : 1)
    }

    func verdictBox(_ report: JSONRow) -> some View {
        let verdict = report.row("verdict")
        let tone = HFWords.verdictTone(verdict?.string("code"))
        let color = HFBadge.color(tone, theme: theme, accent: accent)
        let icon =
            tone == "good" ? "checkmark.circle.fill" : tone == "bad" ? "xmark.octagon.fill" : "exclamationmark.triangle.fill"
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).font(.system(size: 15)).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 3) {
                Text(verdict?.string("title") ?? "Checked")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.label)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = verdict?.string("detail") {
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(theme.sub)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9).fill(color.opacity(0.09)))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(color.opacity(0.35), lineWidth: 0.5))
    }

    func factsCard(_ report: JSONRow) -> some View {
        let repo = report.row("repo")
        let model = report.row("model")
        return UsageCard(title: "WHAT IT IS", theme: theme) {
            VStack(alignment: .leading, spacing: 5) {
                if let repo {
                    HFFactRow(label: "Model", value: modelLine(repo), mono: true, theme: theme)
                }
                if let format = report.row("format") {
                    let summary = format.string("summary").map { " — \($0)" } ?? ""
                    HFFactRow(label: "Format", value: (format.string("name") ?? "Unknown") + summary, theme: theme)
                }
                if let task = report.row("task"), let text = task.string("description") {
                    HFFactRow(label: "Kind", value: text + (task.bool("vision") ? " that can also read images" : ""), theme: theme)
                }
                if let model, model.double("parameters") != nil || model.int("max_context") != nil {
                    let params = model.double("parameters").map { "\(UsageFormat.compact($0)) parameters" } ?? "Parameters unknown"
                    let context = model.int("max_context").map { " · up to \(HFWords.context($0)) context" } ?? ""
                    HFFactRow(label: "Size", value: params + context, theme: theme)
                }
                if repo != nil {
                    HFFactRow(label: "License", value: repo?.string("license") ?? "Not stated", theme: theme)
                }
                if let machine = report.row("machine") {
                    HFFactRow(label: machine.string("host_name") == nil ? "This Mac" : "Host", value: machineLine(machine), theme: theme)
                }
                if let folder = report.string("download_folder") {
                    HFFactRow(label: "Downloads to", value: folder, mono: true, theme: theme)
                }
                if let link = repo?.string("url"), let url = URL(string: link) {
                    SettingsLinkButton(title: "Open on Hugging Face", theme: theme, accent: accent) {
                        NSWorkspace.shared.open(url)
                    }
                    .padding(.top, 2)
                }
            }
            .padding(10)
        }
    }

    func modelLine(_ repo: JSONRow) -> String {
        var line = repo.string("id") ?? ""
        if let sha = repo.string("sha") { line += " · " + String(sha.prefix(7)) }
        if repo.bool("gated") { line += " · needs login" }
        return line
    }

    func machineLine(_ machine: JSONRow) -> String {
        var text = machine.string("host_name").map { "\($0): " } ?? ""
        text += machine.string("chip") ?? machine.string("architecture") ?? "Unknown processor"
        text += ", \(HFWords.size(machine.double("memory_bytes"))) memory, about "
        text += "\(HFWords.size(machine.double("budget_bytes"))) usable for models"
        if machine.string("accelerator") == "cpu" { text += " (processor only)" }
        if let free = machine.double("free_disk_bytes") { text += " · \(HFWords.size(free)) free disk" }
        return text
    }

    @ViewBuilder
    func engineBlock(_ report: JSONRow) -> some View {
        if let needed = check.neededEngine {
            let name = needed.string("name") ?? "The engine"
            if needed.bool("installed") {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "checkmark.shield.fill").foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        let by = needed.string("installed_by").map { " (\($0))" } ?? ""
                        Text("\(name) \(needed.string("version") ?? "") is installed on \(check.place)\(by).")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.label)
                            .fixedSize(horizontal: false, vertical: true)
                        if let path = needed.string("path") {
                            Text(path).font(.system(size: 9.5, design: .monospaced)).foregroundStyle(theme.faint).lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.green.opacity(0.08)))
            } else {
                missingEngine(report, needed: needed, name: name)
            }
        }
    }

    func missingEngine(_ report: JSONRow, needed: JSONRow, name: String) -> some View {
        let install = needed.row("install")
        let manual =
            install == nil || install?.string("method") == "manual"
            || !(report.row("engine")?.bool("installer_available") ?? false)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "wrench.and.screwdriver.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(name) is needed to run this model and isn't installed on \(check.place) yet.")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.label)
                        .fixedSize(horizontal: false, vertical: true)
                    if let summary = install?.string("summary") {
                        Text(summary).font(.system(size: 10)).foregroundStyle(theme.sub).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if manual, let command = install?.string("command") {
                HStack(spacing: 8) {
                    Text(command)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(theme.label)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    SettingsLinkButton(title: "Copy", theme: theme, accent: accent) { HFCheckModel.copy(command) }
                }
                .padding(7)
                .background(RoundedRectangle(cornerRadius: 6).fill(theme.fieldBg))
            }
            HStack(spacing: 12) {
                if !manual, let id = needed.string("id") {
                    SettingsLinkButton(title: "Install \(name)…", emphasized: true, theme: theme, accent: accent) {
                        check.preparePlan(client, engine: id, name: name)
                    }
                    .disabled(check.planEngine != nil)
                }
                SettingsLinkButton(title: "Check again", theme: theme, accent: accent) { check.recheck(client) }
                Spacer(minLength: 0)
            }
            Text("You can download now; the model starts once \(name) is installed.")
                .font(.system(size: 9.5))
                .foregroundStyle(theme.faint)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.orange.opacity(0.08)))
    }

    func engineChoice(_ report: JSONRow, backup: JSONRow) -> some View {
        let summary = report.row("engine")
        let recommended = summary?.string("needed_name") ?? summary?.string("needed") ?? "Recommended"
        return HStack(spacing: 8) {
            Text("Run it with").font(.system(size: 10)).foregroundStyle(theme.sub)
            Picker("Run it with", selection: $check.engineChoice) {
                Text("\(recommended) (recommended)").tag(String?.none)
                Text(backup.string("name") ?? "Ollama").tag(backup.string("id"))
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)
            .fixedSize()
            Spacer(minLength: 0)
        }
    }

    func alternativesCard(_ title: String, _ items: [JSONRow]) -> some View {
        UsageCard(title: title, meta: "\(items.count)", theme: theme) {
            if items.isEmpty {
                Text("No matching models found on Hugging Face.")
                    .font(.system(size: 11)).foregroundStyle(theme.sub).padding(10)
            }
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if index > 0 { HFDivider(theme: theme) }
                HStack(spacing: 6) {
                    Text(item.string("repo") ?? "?")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(theme.label)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let format = item.string("format") {
                        HFBadge(text: format.uppercased(), tone: "busy", theme: theme, accent: accent)
                    }
                    if item.bool("gated") { HFBadge(text: "LOGIN", tone: "warn", theme: theme, accent: accent) }
                    if item.raw["same_model"] as? Bool == false {
                        HFBadge(text: "MODIFIED", tone: "plain", theme: theme, accent: accent)
                    }
                    Spacer(minLength: 4)
                    if let downloads = item.double("downloads") {
                        Text(UsageFormat.compact(downloads)).font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(theme.faint)
                    }
                    SettingsLinkButton(title: "Check", theme: theme, accent: accent) {
                        check.context = nil
                        check.check(client, name: item.string("repo"))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
        }
    }
}

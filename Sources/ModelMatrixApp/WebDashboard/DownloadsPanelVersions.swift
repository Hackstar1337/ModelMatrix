import SwiftUI

extension DownloadsPanelView {
    func versionsCard(_ report: JSONRow) -> some View {
        let rows = check.variants
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Plan for")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.sub)
                Picker(
                    "Context",
                    selection: Binding(
                        get: { check.context },
                        set: { value in
                            check.context = value
                            check.recheck(client)
                        })
                ) {
                    Text("Recommended context").tag(Int?.none)
                    ForEach(check.contextChoices, id: \.self) { tokens in
                        Text("\(HFWords.context(tokens)) context").tag(Int?.some(tokens))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .fixedSize()
                .disabled(check.phase != .idle)
                Spacer(minLength: 0)
            }
            UsageCard(title: "VERSIONS", meta: "\(rows.count)", theme: theme) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    if index > 0 { HFDivider(theme: theme) }
                    versionRow(row)
                }
            }
            if let recommendation = report.row("recommendation"), let label = recommendation.string("label") {
                Text("Recommended: \(label). \(recommendation.string("reason") ?? "") Memory figures are estimates.")
                    .font(.system(size: 9.5))
                    .foregroundStyle(theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    func versionRow(_ row: JSONRow) -> some View {
        let label = row.string("label") ?? "?"
        let supported = row.bool("supported")
        let checked = label == check.selected
        let fit = row.row("fit")
        let level = fit?.string("level")
        return Button {
            check.select(row)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: checked ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 11))
                    .foregroundStyle(checked ? accent : theme.faint)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(label)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(theme.label)
                        if row.bool("recommended") { HFBadge(text: "RECOMMENDED", tone: "good", theme: theme, accent: accent) }
                        if row.bool("full_precision") { HFBadge(text: "FULL SIZE", tone: "plain", theme: theme, accent: accent) }
                    }
                    Text(versionDetail(row))
                        .font(.system(size: 9.5))
                        .foregroundStyle(supported ? theme.sub : theme.faint)
                        .fixedSize(horizontal: false, vertical: true)
                    if row.raw["fits_on_disk"] as? Bool == false {
                        Text("Not enough free disk space for this version.")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.red)
                    }
                }
                Spacer(minLength: 4)
                if supported, fit != nil {
                    HFBadge(
                        text: HFWords.fit(level),
                        tone: level == "good" ? "good" : level == "tight" || level == "too_big" ? "warn" : "plain",
                        theme: theme, accent: accent)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .background(checked ? accent.opacity(0.08) : Color.clear)
        }
        .buttonStyle(.plain)
        .disabled(!supported || check.phase != .idle)
        .opacity(supported ? 1 : 0.55)
        .accessibilityLabel("Version \(label)")
        .accessibilityAddTraits(checked ? .isSelected : [])
    }

    func versionDetail(_ row: JSONRow) -> String {
        if !row.bool("supported") {
            return row.string("unsupported_reason") ?? "Not supported on \(check.place)."
        }
        var parts: [String] = []
        if let quality = row.string("quality") { parts.append(quality) }
        if let bits = row.double("bits_per_weight") { parts.append(String(format: "%.1f bits", bits)) }
        parts.append("\(HFWords.size(row.double("download_bytes"))) download")
        if let fit = row.row("fit"), let need = fit.double("need_bytes") {
            let context = HFWords.context(fit.int("context"))
            parts.append("needs about \(HFWords.size(need)) at \(context) context")
        }
        let files = row.rows("files").count
        if files > 1 { parts.append("\(files) files") }
        return parts.joined(separator: " · ")
    }

    func downloadBar(_ report: JSONRow) -> some View {
        let variant = check.variant
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(
                        variant.map { "Download \($0.string("label") ?? "") · \(HFWords.size($0.double("download_bytes")))" }
                            ?? "Choose a version"
                    )
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.label)
                    Text(downloadHint(report))
                        .font(.system(size: 9.5))
                        .foregroundStyle(theme.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if check.phase == .downloading { ProgressView().controlSize(.small) }
                SettingsLinkButton(title: "Download", emphasized: true, theme: theme, accent: accent) {
                    check.requestDownload(client)
                }
                .disabled(!check.canDownload || check.confirmingTooBig)
            }
            if check.confirmingTooBig, let variant { confirmationBox(variant) }
        }
    }

    func downloadHint(_ report: JSONRow) -> String {
        if check.loginNeeded { return "Needs a Hugging Face login first (see above)." }
        if !report.bool("download_available") { return "This model can't be downloaded from here." }
        let folder = report.string("download_folder").map { " to \($0)" } ?? ""
        let start = "Resumable. When it finishes, ModelMatrix makes a profile, starts it and sends a test message."
        return "Saves\(folder) on \(check.place). \(start)"
    }

    func confirmationBox(_ variant: JSONRow) -> some View {
        let fit = variant.row("fit")
        let reasons = HFCheckModel.confirmationReasons(for: variant)
        let memoryWarning = reasons.contains(.memory)
        let qualityWarning = reasons.contains(.quality)
        let need = HFWords.size(fit?.double("need_bytes"))
        let budget = HFWords.size(check.report?.row("machine")?.double("budget_bytes"))
        return VStack(alignment: .leading, spacing: 6) {
            Text("Suggestion before downloading")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(theme.label)
            if memoryWarning {
                Text(
                    "Memory shortfall: \(variant.string("label") ?? "This version") needs about \(need) at "
                        + "\(HFWords.context(fit?.int("context"))) context, but \(check.place) can give a model about \(budget). "
                        + "It may fail to start or run very slowly."
                )
                .font(.system(size: 9.5))
                .foregroundStyle(theme.sub)
                .fixedSize(horizontal: false, vertical: true)
            }
            if qualityWarning, let bits = variant.double("bits_per_weight") {
                Text(
                    String(format: "Quality trade-off: %.1f bits per weight is below 3.5, so this smaller quantization may lose answer quality.", bits)
                )
                .font(.system(size: 9.5))
                .foregroundStyle(theme.sub)
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                SettingsLinkButton(title: "Cancel", theme: theme, accent: accent) { check.confirmingTooBig = false }
                SettingsLinkButton(title: "Download anyway", emphasized: true, theme: theme, accent: accent) {
                    check.confirmingTooBig = false
                    Task { await check.download(client) }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.09)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.3), lineWidth: 0.5))
    }

    // MARK: Engine plan (nothing changes until Install is pressed)

    var enginePlanBox: some View {
        let engine = check.planEngine
        let place = engine.map { $0.host.isEmpty ? "this Mac" : $0.host } ?? "this Mac"
        let verb = engine?.action == "uninstall" ? "Remove" : engine?.action == "update" ? "Update" : "Install"
        return UsageCard(title: "\(verb.uppercased()) \(engine?.name.uppercased() ?? "ENGINE")", meta: place, theme: theme) {
            VStack(alignment: .leading, spacing: 8) {
                if let error = check.planError {
                    UsageNotice(text: error, color: .red, theme: theme)
                }
                if let job = check.job {
                    engineJob(job)
                } else if let plan = check.plan {
                    planDetails(plan, verb: verb)
                } else if check.planError == nil {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Preparing the plan. Nothing is installed yet.")
                            .font(.system(size: 10.5)).foregroundStyle(theme.sub)
                    }
                }
                if check.job == nil, check.plan == nil, check.planError != nil {
                    HStack {
                        Spacer(minLength: 0)
                        SettingsLinkButton(title: "Close", theme: theme, accent: accent) { check.dismissPlan() }
                    }
                }
            }
            .padding(10)
        }
    }

    /// Plain words for how a plan installs or removes an engine.
    static func planMethodText(method: String, engine: String?, action: String?) -> String {
        if method == "homebrew" { return "With Homebrew" }
        if action == "uninstall" { return "Deletes the copy ModelMatrix installed" }
        switch engine {
        case "mlx-lm": return "A private Python made by uv, checked against its published checksum. Your own Python is not changed"
        case "ollama": return "The official Ollama app download"
        default: return "Official release, checked against its published checksum"
        }
    }
    func planDetails(_ plan: JSONRow, verb: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title = plan.string("title") {
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(theme.label)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let method = plan.string("method") {
                HFFactRow(label: "How", value: Self.planMethodText(method: method, engine: plan.string("engine"), action: plan.string("action")), theme: theme)
            }
            let downloads = plan.rows("downloads")
            if !downloads.isEmpty {
                HFFactRow(
                    label: "Downloads",
                    value: downloads.map { "\($0.string("name") ?? "file") (\(HFWords.size($0.double("size"))))" }
                        .joined(separator: ", "),
                    mono: true, theme: theme)
            }
            if let size = plan.string("download_size") { HFFactRow(label: "Size", value: size, theme: theme) }
            if !plan.strings("commands").isEmpty {
                HFFactRow(label: "Runs", value: plan.strings("commands").joined(separator: "\n"), mono: true, theme: theme)
            }
            if let location = plan.string("location") { HFFactRow(label: "Installs to", value: location, mono: true, theme: theme) }
            if let removal = plan.string("removal") { HFFactRow(label: "To remove", value: removal, theme: theme) }
            HFFactRow(label: "Password", value: plan.bool("needs_admin") ? "Needed" : "Not needed", theme: theme)
            ForEach(plan.strings("notes"), id: \.self) { note in
                Text("• " + note)
                    .font(.system(size: 9.5))
                    .foregroundStyle(theme.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Nothing changes until you press \(verb). This plan expires in 10 minutes.")
                .font(.system(size: 9.5))
                .foregroundStyle(theme.faint)
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                SettingsLinkButton(title: "Don't \(verb.lowercased())", theme: theme, accent: accent) { check.dismissPlan() }
                SettingsLinkButton(title: verb, emphasized: true, theme: theme, accent: verb == "Remove" ? .red : accent) {
                    check.approvePlan(client)
                }
            }
        }
    }

    func engineJob(_ job: JSONRow) -> some View {
        let state = job.string("state") ?? "running"
        let tone = state == "succeeded" ? "good" : state == "running" ? "busy" : "bad"
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if state == "running" { ProgressView().controlSize(.small) }
                HFBadge(text: state.uppercased(), tone: tone, theme: theme, accent: accent)
                Text(job.string("title") ?? "")
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.label)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            if let error = job.string("error") {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if state == "succeeded", job.string("action") != "uninstall", let version = job.string("version") {
                Text("Version \(version)" + (job.string("path").map { " at \($0)" } ?? ""))
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(theme.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !check.jobLines.isEmpty {
                Text(check.jobLines.suffix(10).joined(separator: "\n"))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(theme.sub)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(7)
                    .background(RoundedRectangle(cornerRadius: 6).fill(theme.fieldBg))
            }
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                if state == "running" {
                    SettingsLinkButton(title: "Stop", theme: theme, accent: .red) { check.stopJob(client) }
                } else {
                    SettingsLinkButton(title: "Done", emphasized: true, theme: theme, accent: accent) { check.dismissPlan() }
                }
            }
        }
    }
}

import SwiftUI

/// Menu bar twin of the web dashboard's Optimize window: memory breakdown,
/// Maximum / Recommended presets, a checklist of what to free, other apps with
/// a polite Quit, and a before/after result.
struct OptimizePanelView: View {
    @Bindable var monitor: OptimizeMonitor
    let store: MatrixStore
    let theme: DashboardTheme
    let accent: Color
    @State private var pendingQuit: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let message = monitor.errorMessage {
                UsageNotice(text: message, color: .red, theme: theme)
            } else if let notice = monitor.noticeMessage {
                UsageNotice(text: notice, color: accent, theme: theme)
            }
            if let memory = monitor.memory {
                OptimizeMemoryCard(memory: memory, theme: theme, accent: accent)
            } else if monitor.plan == nil, monitor.errorMessage == nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Measuring memory…").font(.system(size: 11)).foregroundStyle(theme.sub)
                }
            }
            if monitor.phase == .purging {
                UsageNotice(
                    text: "macOS is asking for your password to clear the file cache. Cancel the dialog to skip this step.",
                    color: accent, theme: theme)
            }
            if let outcome = monitor.outcome {
                OptimizeOutcomeCard(outcome: outcome, theme: theme, accent: accent)
                HStack(spacing: 8) {
                    SettingsLinkButton(title: "Optimize Again", emphasized: true, theme: theme, accent: accent) {
                        monitor.reset()
                    }
                    SettingsLinkButton(title: "Open Web Dashboard", theme: theme, accent: accent) {
                        WebDashboard.open(store)
                    }
                }
            } else if monitor.plan != nil {
                presets
                itemsCard
                runBar
                appsCard
            }
        }
        .padding(EdgeInsets(top: 10, leading: 14, bottom: 14, trailing: 14))
        .onAppear { monitor.start { WebDashboardClient.local(store) } }
        .onDisappear { monitor.stop() }
    }

    var presets: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsSegmentedControl(
                options: OptimizeMonitor.presets,
                label: { name in
                    let size = UsageFormat.bytes(monitor.estimate(for: name))
                    return "\(name == "maximum" ? "Maximum" : "Recommended") · \(size == "-" ? "0 MB" : size)"
                },
                selection: $monitor.preset,
                theme: theme)
            .disabled(monitor.isBusy)
            Text(
                monitor.preset == "maximum"
                    ? "Everything not answering a request right now, plus the file cache."
                    : "Unused Ollama models and model servers idle for 15+ minutes. No password needed."
            )
            .font(.system(size: 10))
            .foregroundStyle(theme.sub)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    var itemsCard: some View {
        UsageCard(title: "WHAT TO FREE", meta: "\(monitor.selected.count) selected", theme: theme) {
            ForEach(Array(monitor.items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { Rectangle().fill(theme.line).frame(height: 0.5) }
                OptimizeItemRow(
                    item: item, checked: monitor.selected.contains(item.string("id") ?? ""),
                    theme: theme, accent: accent
                ) {
                    monitor.toggle(item.string("id") ?? "")
                }
                .disabled(monitor.isBusy)
            }
            if monitor.items.count <= 1 {
                Text("No models are loaded right now. Clearing the file cache is the only thing left to free.")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.sub)
                    .padding(10)
            }
        }
    }

    var runBar: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(monitor.chosen.isEmpty ? "Nothing selected" : "Up to \(UsageFormat.bytes(monitor.estimate))")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.label)
                if monitor.wantsPurge {
                    Text("asks for your password").font(.system(size: 9.5)).foregroundStyle(theme.faint)
                }
            }
            Spacer(minLength: 0)
            if monitor.isBusy { ProgressView().controlSize(.small) }
            SettingsLinkButton(
                title: monitor.phase == .running
                    ? "Freeing…" : monitor.phase == .purging ? "Waiting for password…" : "Optimize Now",
                emphasized: true, theme: theme, accent: accent
            ) {
                Task { await monitor.run() }
            }
            .disabled(monitor.isBusy || monitor.chosen.isEmpty)
        }
    }

    @ViewBuilder var appsCard: some View {
        if !monitor.apps.isEmpty {
            UsageCard(title: "OTHER APPS USING MEMORY", theme: theme) {
                ForEach(Array(monitor.apps.prefix(8).enumerated()), id: \.offset) { index, app in
                    if index > 0 { Rectangle().fill(theme.line).frame(height: 0.5) }
                    appRow(app)
                }
            }
            Text("Optimize never quits apps on its own. Quit closes an app like ⌘Q, so it can still ask to save your work.")
                .font(.system(size: 9.5))
                .foregroundStyle(theme.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    func appRow(_ app: JSONRow) -> some View {
        let key = app.string("path") ?? app.string("name") ?? ""
        let processes = app.int("processes") ?? 1
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(app.string("name") ?? "App")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(theme.label)
                    .lineLimit(1)
                Text("\(processes) process\(processes == 1 ? "" : "es")\(app.bool("quittable") ? "" : " · system or command-line")")
                    .font(.system(size: 9.5))
                    .foregroundStyle(theme.sub)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(UsageFormat.bytes(app.double("bytes")))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(theme.sub)
            if app.bool("quittable") {
                if pendingQuit == key {
                    SettingsLinkButton(title: "Cancel", theme: theme, accent: accent) { pendingQuit = nil }
                    SettingsLinkButton(title: "Quit", emphasized: true, theme: theme, accent: .red) {
                        pendingQuit = nil
                        monitor.quit(app: app)
                    }
                } else {
                    SettingsLinkButton(title: "Quit", theme: theme, accent: accent) { pendingQuit = key }
                        .disabled(monitor.isBusy)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

struct OptimizeItemRow: View {
    let item: JSONRow
    let checked: Bool
    let theme: DashboardTheme
    let accent: Color
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13))
                    .foregroundStyle(checked ? accent : theme.faint)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(item.string("title") ?? "")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(theme.label)
                            .lineLimit(1)
                        OptimizeBadge(text: kindLabel, color: theme.sub, theme: theme)
                        if item.bool("in_use") { OptimizeBadge(text: "IN USE", color: .orange, theme: theme) }
                        if item.bool("needs_password") { OptimizeBadge(text: "PASSWORD", color: theme.sub, theme: theme) }
                    }
                    Text(detail)
                        .font(.system(size: 9.5))
                        .foregroundStyle(theme.sub)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 4)
                Text(sizeLabel)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(theme.label)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(checked ? accent.opacity(0.08) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    var kindLabel: String {
        switch item.string("kind") {
        case "ollama_model": "OLLAMA"
        case "model_server": "SERVER"
        default: "MACOS"
        }
    }

    var detail: String {
        let base = item.string("detail") ?? ""
        guard let last = item.double("last_used_at") else { return base }
        return "\(base) Last request \(UsageFormat.ago(last))."
    }

    var sizeLabel: String {
        let size = UsageFormat.bytes(item.double("bytes"))
        return item.string("kind") == "file_cache" ? "≤ \(size)" : size
    }
}

struct OptimizeBadge: View {
    let text: String
    let color: Color
    let theme: DashboardTheme

    var body: some View {
        Text(text)
            .font(.system(size: 8, weight: .semibold, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(color.opacity(0.5), lineWidth: 0.5))
    }
}

import AppKit
import SwiftUI

struct UsageModelSplit: View {
    let monitor: UsageMonitor
    let theme: DashboardTheme
    let accent: Color

    var body: some View {
        let requests = monitor.summary?.double("requests") ?? 0
        let local = monitor.summary?.double("local_requests") ?? 0
        UsageCard(title: "MODEL SPLIT", meta: monitor.range, theme: theme) {
            if monitor.models.isEmpty {
                Text("No model usage in this range.").font(.system(size: 11)).foregroundStyle(theme.sub).padding(12)
            }
            ForEach(Array(monitor.models.prefix(8))) { model in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(model.string("model") ?? "-")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(theme.label)
                            .lineLimit(1)
                        Spacer()
                        Text("\(UsageFormat.compact(model.double("requests"))) req · \(UsageFormat.number(model.double("avg_tps"))) t/s")
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(theme.sub)
                    }
                    UsageBar(fraction: model.double("share") ?? 0, color: model.string("tier") == "cloud" ? accent : accent.opacity(0.75), theme: theme)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            if requests > 0 {
                HStack(spacing: 6) {
                    Text("LOCAL VS CLOUD").font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(theme.faint)
                    UsageBar(fraction: local / requests, color: theme.sub, theme: theme, trailing: accent)
                    Text(String(format: "%.0f%% local", local / requests * 100))
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(theme.sub)
                }
                .padding(10)
            }
        }
    }
}

struct UsageBar: View {
    let fraction: Double
    let color: Color
    let theme: DashboardTheme
    var trailing: Color?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(trailing ?? theme.line)
                Capsule().fill(color).frame(width: max(2, proxy.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 5)
    }
}

struct UsageClientsSection: View {
    let monitor: UsageMonitor
    let theme: DashboardTheme
    let accent: Color
    @State var renaming: JSONRow?
    @State var newName = ""

    var body: some View {
        UsageCard(title: "CLIENTS", meta: "\(monitor.clients.count)", theme: theme) {
            if monitor.clients.isEmpty {
                Text("Apps that call your models through the relay show up here.")
                    .font(.system(size: 11)).foregroundStyle(theme.sub).padding(12)
            }
            ForEach(monitor.clients) { client in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(client.string("name") ?? client.string("client_id") ?? "-")
                            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(accent)
                            .lineLimit(1)
                        Text("\(UsageFormat.compact(client.double("requests"))) req · \(UsageFormat.compact(client.double("tokens"))) tok · \(UsageFormat.ago(client.double("last_seen")))")
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(theme.sub)
                    }
                    Spacer()
                    Button("Rename") {
                        newName = client.string("custom_name") ?? client.string("name") ?? ""
                        renaming = client
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.btnFg)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
        }
        .alert("Rename client", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Save") {
                if let id = renaming?.string("client_id") { monitor.renameClient(id, to: newName.trimmingCharacters(in: .whitespaces)) }
                renaming = nil
            }
            Button("Use detected name") {
                if let id = renaming?.string("client_id") { monitor.renameClient(id, to: "") }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("Give \(renaming?.string("detected") ?? "this client") a friendly label. It is used in the menu bar and the web dashboard.")
        }
    }
}

struct UsageRelaySection: View {
    let monitor: UsageMonitor
    let theme: DashboardTheme
    let accent: Color
    @State var retention = 30
    @State var confirmReset = false

    var body: some View {
        let relay = monitor.relay
        UsageCard(title: "USAGE & RELAY", meta: relay?.bool("listening") == true ? "recording" : "offline", theme: theme) {
            VStack(alignment: .leading, spacing: 8) {
                copyRow("OpenAI URL", relay?.string("url"))
                copyRow("Ollama URL", relay?.string("ollama_url"))
                Text("\(UsageFormat.compact(relay?.double("requests_recorded"))) requests recorded. Only metadata is stored, never prompts or responses.")
                    .font(.system(size: 10)).foregroundStyle(theme.sub)
                    .fixedSize(horizontal: false, vertical: true)
                if let error = relay?.string("error") {
                    Text(error).font(.system(size: 10)).foregroundStyle(.red)
                }
                HStack(spacing: 8) {
                    SettingsNumberField(label: "Keep days", value: $retention, theme: theme)
                    SettingsLinkButton(title: "Save", theme: theme, accent: accent) {
                        monitor.setRetention(days: min(3650, max(1, retention)))
                    }
                    Spacer()
                    SettingsLinkButton(title: "Clear history", theme: theme, accent: .red) { confirmReset = true }
                }
            }
            .padding(10)
        }
        .onChange(of: monitor.relay?.int("retention_days")) { _, days in
            if let days { retention = days }
        }
        .onAppear { if let days = monitor.relay?.int("retention_days") { retention = days } }
        .confirmationDialog("Clear all usage history?", isPresented: $confirmReset) {
            Button("Delete history", role: .destructive) { monitor.resetHistory() }
        } message: {
            Text("Every recorded request, client name and statistic is deleted.")
        }
    }

    func copyRow(_ label: String, _ value: String?) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(theme.sub).frame(width: 74, alignment: .leading)
            Text(value ?? "-")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(theme.label)
                .lineLimit(1)
                .textSelection(.enabled)
            Spacer(minLength: 4)
            if let value {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc").font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(theme.faint)
                .help("Copy")
            }
        }
    }
}

struct UsageCaptureSection: View {
    let monitor: UsageMonitor
    let theme: DashboardTheme
    let accent: Color

    var body: some View {
        UsageCard(title: "CAPTURE MODE", meta: "\(monitor.capture.filter { $0.bool("enabled") }.count) on", theme: theme) {
            Text("Records every app that calls a model's own port, without changing app settings. Restart the model after switching.")
                .font(.system(size: 10)).foregroundStyle(theme.sub)
                .fixedSize(horizontal: false, vertical: true)
                .padding(EdgeInsets(top: 10, leading: 10, bottom: 2, trailing: 10))
            ForEach(monitor.capture) { item in
                let profile = item.string("profile") ?? ""
                SettingsToggleRow(
                    label: item.string("display_name") ?? profile,
                    subtitle: item.bool("supported")
                        ? "Port \(item.string("port") ?? "?")"
                        : (item.string("reason") ?? "Not available for this runtime"),
                    isOn: Binding(
                        get: { item.bool("enabled") },
                        set: { monitor.setCapture(profile: profile, enabled: $0) }),
                    disabled: !item.bool("supported"),
                    theme: theme,
                    accent: accent
                )
                .padding(SettingsChrome.rowInsets)
            }
        }
    }
}

struct UsageOllamaSection: View {
    let monitor: UsageMonitor
    let theme: DashboardTheme
    let accent: Color

    var body: some View {
        let ollama = monitor.ollama
        let reachable = ollama?.bool("reachable") == true
        UsageCard(title: "OLLAMA", meta: reachable ? "v\(ollama?.string("version") ?? "?")" : "not running", theme: theme) {
            VStack(alignment: .leading, spacing: 6) {
                if !reachable {
                    Text("Start Ollama to see installed and loaded models.").font(.system(size: 11)).foregroundStyle(theme.sub)
                }
                ForEach(ollama?.rows("loaded") ?? []) { model in
                    HStack {
                        Circle().fill(accent).frame(width: 6, height: 6)
                        Text(model.string("name") ?? "-").font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.label)
                        Spacer()
                        Text(UsageFormat.bytes(model.double("size_vram") ?? model.double("size")))
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(theme.sub)
                    }
                }
                if reachable {
                    let installed = ollama?.rows("installed") ?? []
                    Text("\(installed.count) installed: \(installed.prefix(6).compactMap { $0.string("name") }.joined(separator: ", "))\(installed.count > 6 ? "…" : "")")
                        .font(.system(size: 10)).foregroundStyle(theme.sub)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
        }
    }
}

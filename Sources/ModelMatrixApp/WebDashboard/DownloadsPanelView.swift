import AppKit
import SwiftUI

/// Menu bar twin of the web dashboard's Hugging Face features: check a model
/// before downloading, choose a version, install a missing engine only after
/// approving its plan, and manage downloads and downloaded models on this Mac
/// and remote hosts.
struct DownloadsPanelView: View {
    @Bindable var monitor: HFDownloadsMonitor
    @Bindable var check: HFCheckModel
    let store: MatrixStore
    /// Remote host names, as listed in Remote Hosts.
    let hostNames: [String]
    let theme: DashboardTheme
    let accent: Color
    @State var cancelling: String?
    @State var deleting: String?

    var client: WebDashboardClient { WebDashboardClient.local(store) }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 14) {
                if let message = check.errorMessage {
                    UsageNotice(text: message, color: .red, theme: theme)
                } else if let notice = check.noticeMessage {
                    UsageNotice(text: notice, color: accent, theme: theme)
                }
                checkCard
                if check.planEngine != nil { enginePlanBox }
                if let report = check.report { reportSection(report) }
                downloadsCard
                modelsCard
                HFSettingsCard(client: client, theme: theme, accent: accent)
                HStack(spacing: 8) {
                    SettingsLinkButton(title: "Open Web Dashboard", theme: theme, accent: accent) {
                        WebDashboard.open(store)
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(EdgeInsets(top: 10, leading: 14, bottom: 14, trailing: 14))
        }
        .onAppear { monitor.panelOpen = true }
        .onDisappear { monitor.panelOpen = false }
    }

    var checkCard: some View {
        UsageCard(title: "ADD A MODEL FROM HUGGING FACE", theme: theme) {
            VStack(alignment: .leading, spacing: 8) {
                if !hostNames.isEmpty { hostPicker }
                HStack(spacing: 8) {
                    TextField("owner/model, a link, or words to search", text: $check.input)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(theme.fieldFg)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6).fill(theme.fieldBg))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.line, lineWidth: 0.5))
                        .onSubmit { freshCheck() }
                        .accessibilityLabel("Hugging Face model")
                    if check.phase == .checking { ProgressView().controlSize(.small) }
                    SettingsLinkButton(title: "Check", emphasized: true, theme: theme, accent: accent) { freshCheck() }
                        .disabled(check.phase != .idle || check.input.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text(
                    check.phase == .checking
                        ? "Checking on Hugging Face. Only the file list and model settings are read."
                        : "Checking only reads the file list and model settings. Nothing downloads or installs until you choose."
                )
                .font(.system(size: 9.5))
                .foregroundStyle(theme.faint)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
        }
    }

    var hostPicker: some View {
        HStack(spacing: 6) {
            Text("Run it on")
                .font(.system(size: 10))
                .foregroundStyle(theme.sub)
            Picker(
                "Run it on",
                selection: Binding(
                    get: { check.host },
                    set: { value in
                        check.host = value
                        if check.report != nil { check.recheck(client) }
                    })
            ) {
                Text("This Mac").tag("")
                ForEach(hostNames, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .fixedSize()
            Spacer(minLength: 0)
        }
    }

    func freshCheck() {
        check.context = nil
        check.check(client)
    }
}

/// Small capsule label (state, fit, host).
struct HFBadge: View {
    let text: String
    let tone: String
    let theme: DashboardTheme
    let accent: Color

    var body: some View {
        let color = HFBadge.color(tone, theme: theme, accent: accent)
        Text(text)
            .font(.system(size: 8.5, weight: .bold, design: .monospaced))
            .tracking(0.4)
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.13)))
    }

    static func color(_ tone: String, theme: DashboardTheme, accent: Color) -> Color {
        switch tone {
        case "good": .green
        case "busy": accent
        case "warn": .orange
        case "bad": .red
        default: theme.sub
        }
    }
}

/// "Label   value" line used in the facts and plan boxes.
struct HFFactRow: View {
    let label: String
    let value: String
    var mono = false
    let theme: DashboardTheme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(theme.faint)
                .frame(width: 82, alignment: .leading)
            Text(value)
                .font(.system(size: 10.5, design: mono ? .monospaced : .default))
                .foregroundStyle(theme.label)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

/// Thin divider between card rows.
struct HFDivider: View {
    let theme: DashboardTheme
    var body: some View { Rectangle().fill(theme.line).frame(height: 0.5) }
}

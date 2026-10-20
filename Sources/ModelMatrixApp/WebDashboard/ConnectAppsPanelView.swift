import AppKit
import SwiftUI

/// Native menu-bar parity for dashboard Connect to an app actions. The panel is
/// intentionally inline so it works in the compact inspector without changing
/// the inspector enum or opening a separate window.
struct ConnectAppsPanelView: View {
    let store: MatrixStore
    let theme: DashboardTheme
    let accent: Color
    let initialTarget: ConnectAppsTarget?

    @State private var profiles: [JSONRow] = []
    @State private var targets: [JSONRow] = []
    @State private var connections: [JSONRow] = []
    @State private var selectedProfileKey = ""
    @State private var selectedTarget = "kilo"
    @State private var selectedConnection: String?
    @State private var selectedDetails: JSONRow?
    @State private var detailsGeneration = 0
    @State private var plan: JSONRow?
    @State private var makeDefault = false
    @State private var manualAppName = ""
    @State private var message: String?
    @State private var failure: String?
    @State private var busy = false
    @State private var loaded = false
    @State private var approval = false
    @State private var revealedKey: String?
    @State private var keyWarning: String?
    @State private var showKeyWarning = false
    @State private var pendingAction: ConnectAppsPendingAction?

    private var client: WebDashboardClient { WebDashboardClient.local(store) }
    private var selectedProfile: JSONRow? { profiles.first { $0.string("key") == selectedProfileKey || $0.string("profile") == selectedProfileKey } }
    private var automaticTarget: JSONRow? { targets.first { $0.string("id") == selectedTarget } }
    private var selectedConnectionRow: JSONRow? {
        guard let selectedConnection else { return nil }
        return connections.first { $0.string("id") == selectedConnection && $0.string("profile_key") == selectedProfileKey }
    }

    var body: some View {
        UsageCard(title: "CONNECT TO AN APP", meta: connections.isEmpty ? nil : "\(connections.count) connection\(connections.count == 1 ? "" : "s")", theme: theme) {
            VStack(alignment: .leading, spacing: 9) {
                if let failure { UsageNotice(text: failure, color: .red, theme: theme) }
                if let message, failure == nil { UsageNotice(text: message, color: accent, theme: theme) }
                if !loaded {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Reading profiles and qualified app targets…")
                            .font(.system(size: 10.5)).foregroundStyle(theme.sub)
                    }
                } else if profiles.isEmpty {
                    Text("No runnable profiles are available yet. Start or create a profile, then return here. Read-only opening never starts a model or changes a client config.")
                        .font(.system(size: 10.5)).foregroundStyle(theme.sub)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    profilePicker
                    targetPicker
                    if selectedTarget == "manual" { manualDetails }
                    if let selectedDetails { detailCard(selectedDetails) }
                    if let plan { planCard(plan) }
                    if let selectedConnectionRow { connectionActionCard(selectedConnectionRow) }
                }
                connectionList
            }
            .padding(10)
        }
        .task { await load() }
        .confirmationDialog(
            "Disconnect this ModelMatrix connection?",
            isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } })
        ) {
            if case .some(.disconnect(let id)) = pendingAction {
                Button("Disconnect and revoke", role: .destructive) { disconnect(id) }
            }
            if case .some(.undo(let id)) = pendingAction {
                Button("Undo connection change", role: .destructive) { undo(id) }
            }
            Button("Cancel", role: .cancel) { pendingAction = nil }
        } message: {
            Text("This only changes the owned ModelMatrix connection block. It does not delete the app, model weights, or unrelated settings. Reload the client only when its own instructions require it.")
        }
        .alert("Reveal private key?", isPresented: $showKeyWarning) {
            Button("Reveal key", role: .destructive) { revealKey() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The key is shown once for deliberate clipboard use. It is not included in normal connection details, summaries, URLs, or logs. Treat it like a password.")
        }
    }

    private var profilePicker: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("PROFILE")
                .font(.system(size: 9, weight: .bold)).tracking(0.5).foregroundStyle(theme.faint)
            Picker("Profile", selection: $selectedProfileKey) {
                if selectedProfileKey.isEmpty { Text("Choose a profile").tag("") }
                ForEach(profiles) { profile in
                    Text(profileTitle(profile)).tag(profile.string("key") ?? profile.string("profile") ?? profile.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .onChange(of: selectedProfileKey) { _, _ in
                selectedDetails = nil
                plan = nil
                Task { await loadDetails() }
            }
            if let selectedProfile {
                HStack(spacing: 6) {
                    HFBadge(text: ConnectAppsFormatter.readiness(selectedProfile).uppercased(), tone: readinessTone(selectedProfile), theme: theme, accent: accent)
                    Text([selectedProfile.string("runtime"), selectedProfile.string("host")].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 9.5, design: .monospaced)).foregroundStyle(theme.sub).lineLimit(1)
                }
            }
        }
    }

    private var targetPicker: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("APP")
                    .font(.system(size: 9, weight: .bold)).tracking(0.5).foregroundStyle(theme.faint)
                Spacer(minLength: 0)
                if busy { ProgressView().controlSize(.small) }
            }
            Picker("App", selection: $selectedTarget) {
                ForEach(targets) { target in
                    let id = target.string("id") ?? target.id
                    Text(ConnectAppsFormatter.targetLabel(target)).tag(id)
                        .disabled(id != "manual" && (!target.bool("installed") || !target.bool("qualified")))
                }
                Text("Other app · manual details").tag("manual")
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .onChange(of: selectedTarget) { _, _ in
                selectedDetails = nil
                plan = nil
                Task { await loadDetails() }
            }
            if let automaticTarget, selectedTarget != "manual" {
                Text(automaticTarget.string("reason") ?? automaticTarget.string("reload_note") ?? "Qualified target status comes from the controller.")
                    .font(.system(size: 9.5)).foregroundStyle(targetTone(automaticTarget))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var manualDetails: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("OTHER APP")
                .font(.system(size: 9, weight: .bold)).tracking(0.5).foregroundStyle(theme.faint)
            TextField("App name (for your notes)", text: $manualAppName)
                .textFieldStyle(.plain)
                .font(.system(size: 10.5))
                .foregroundStyle(theme.fieldFg)
                .padding(.horizontal, 6).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 5).fill(theme.fieldBg))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(theme.line, lineWidth: 0.5))
            Text("Manual mode prepares the protected connection plan for the selected profile. Use the copied non-secret fields in the other app; ModelMatrix never edits arbitrary app files.")
                .font(.system(size: 9.5)).foregroundStyle(theme.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func detailCard(_ details: JSONRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("CONNECTION DETAILS")
                    .font(.system(size: 9, weight: .bold)).tracking(0.5).foregroundStyle(theme.faint)
                Spacer(minLength: 0)
                SettingsLinkButton(title: "Copy fields", theme: theme, accent: accent) { copy(ConnectAppsFormatter.copyableDetails(details)) }
            }
            ForEach([
                ("Provider", details.string("provider") ?? "OpenAI-compatible"),
                ("Base URL", details.string("base_url") ?? "—"),
                ("Server root", details.string("server_root") ?? "—"),
                ("Model", details.string("model_id") ?? selectedProfile?.string("model_id") ?? "—"),
                ("Key", details.string("api_key_requirement") ?? "unknown"),
            ], id: \.0) { label, value in
                HFFactRow(label: label, value: value, mono: label != "Provider" && label != "Key", theme: theme)
            }
            if let request = details.string("request_example"), !request.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Text(request)
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(theme.label)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    SettingsLinkButton(title: "Copy example", theme: theme, accent: accent) { copy(request) }
                }
                .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 5).fill(theme.fieldBg))
            }
            ForEach(details.strings("notes"), id: \.self) { note in
                Text(note).font(.system(size: 9.5)).foregroundStyle(theme.faint).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                SettingsLinkButton(title: "Preview plan", emphasized: true, theme: theme, accent: accent) { makePlan() }
                    .disabled(busy || (selectedTarget != "manual" && !(automaticTarget?.bool("installed") == true && automaticTarget?.bool("qualified") == true)))
                Toggle("Make default", isOn: $makeDefault)
                    .toggleStyle(.checkbox).font(.system(size: 9.5)).foregroundStyle(theme.sub)
                Spacer(minLength: 0)
            }
        }
        .padding(7)
        .background(RoundedRectangle(cornerRadius: 7).fill(theme.cellBg))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.line, lineWidth: 0.5))
    }

    private func planCard(_ plan: JSONRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(plan.string("title") ?? "Connection plan")
                    .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(theme.label)
                Spacer(minLength: 0)
                HFBadge(text: "APPROVAL REQUIRED", tone: "warn", theme: theme, accent: accent)
            }
            ForEach(plan.strings("changes"), id: \.self) { change in
                Text("• \(change)").font(.system(size: 9.5)).foregroundStyle(theme.sub).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(plan.strings("notes"), id: \.self) { note in
                Text(note).font(.system(size: 9.5)).foregroundStyle(theme.faint).fixedSize(horizontal: false, vertical: true)
            }
            Text(plan.string("recovery") ?? "If the file changes before approval, the plan is rejected and no settings are written.")
                .font(.system(size: 9.5)).foregroundStyle(theme.faint).fixedSize(horizontal: false, vertical: true)
            Toggle("I approve this exact plan and its protected config change", isOn: $approval)
                .toggleStyle(.checkbox).font(.system(size: 9.5)).foregroundStyle(theme.sub)
            HStack(spacing: 8) {
                SettingsLinkButton(title: "Apply approved plan", emphasized: true, theme: theme, accent: accent) { applyPlan() }
                    .disabled(!approval || busy)
                SettingsLinkButton(title: "Cancel", theme: theme, accent: accent) { self.plan = nil; approval = false }
                Spacer(minLength: 0)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 7).fill(accent.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(accent.opacity(0.35), lineWidth: 0.5))
    }

    private var connectionList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("CONNECTIONS")
                    .font(.system(size: 9, weight: .bold)).tracking(0.5).foregroundStyle(theme.faint)
                Spacer(minLength: 0)
                SettingsLinkButton(title: "Refresh", theme: theme, accent: accent) { Task { await refreshConnections() } }
            }
            if connections.isEmpty {
                Text("No configured connections. Opening this panel is read-only; a connection appears only after an approved plan is applied.")
                    .font(.system(size: 9.5)).foregroundStyle(theme.faint).fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(connections) { connection in connectionRow(connection) }
            }
        }
        .padding(.top, 2)
    }

    private func connectionRow(_ row: JSONRow) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(row.string("display_name") ?? row.string("profile") ?? row.id)
                    .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(theme.label).lineLimit(1)
                Spacer(minLength: 0)
                HFBadge(text: ConnectAppsFormatter.connectionState(row).uppercased(), tone: connectionTone(row), theme: theme, accent: accent)
            }
            Text([row.string("target"), row.string("model_key"), row.string("base_url")].compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 9, design: .monospaced)).foregroundStyle(theme.faint).lineLimit(2).truncationMode(.middle)
            HStack(spacing: 8) {
                SettingsLinkButton(title: "Verify API", theme: theme, accent: accent) { verify(row) }
                SettingsLinkButton(title: "Reveal key…", theme: theme, accent: accent) {
                    selectedConnection = row.string("id")
                    showKeyWarning = true
                }
                SettingsLinkButton(title: "Disconnect…", theme: theme, accent: .red) { pendingAction = .disconnect(row.string("id") ?? row.id) }
                if row.string("operation_id") != nil { SettingsLinkButton(title: "Undo…", theme: theme, accent: accent) { pendingAction = .undo(row.string("id") ?? row.id) } }
                Spacer(minLength: 0)
            }
            if selectedConnection == row.string("id"), let revealedKey {
                Text(keyWarning ?? "Private key revealed for deliberate use")
                    .font(.system(size: 9.5)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text(revealedKey).font(.system(size: 9, design: .monospaced)).foregroundStyle(theme.label).textSelection(.enabled).lineLimit(2)
                    SettingsLinkButton(title: "Copy key", emphasized: true, theme: theme, accent: .orange) { copy(revealedKey); message = "Private key copied. It is not stored in the panel after this view closes." }
                }
            }
        }
        .padding(7)
        .background(RoundedRectangle(cornerRadius: 7).fill(theme.cellBg))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.line, lineWidth: 0.5))
    }

    private func connectionActionCard(_ row: JSONRow) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("SELECTED CONNECTION")
                    .font(.system(size: 9, weight: .bold)).tracking(0.5).foregroundStyle(theme.faint)
                Spacer(minLength: 0)
                HFBadge(text: ConnectAppsFormatter.connectionState(row).uppercased(), tone: connectionTone(row), theme: theme, accent: accent)
            }
            Text("Configured, API-tested, client-verified, reload-required and model readiness are tracked separately.")
                .font(.system(size: 9.5)).foregroundStyle(theme.sub).fixedSize(horizontal: false, vertical: true)
        }
        .padding(7)
        .background(RoundedRectangle(cornerRadius: 7).fill(theme.cellBg))
    }

    private func load() async {
        do {
            let profilePayload = try await client.object("/api/connect/profiles")
            profiles = profilePayload.rows("profiles")
            let targetPayload = try await client.object("/api/connect/targets")
            targets = targetPayload.rows("targets").filter { target in
                let id = target.string("id") ?? ""
                return id == "kilo" || id == "opencode"
            }
            if !targets.contains(where: { $0.string("id") == "manual" }) {
                targets.append(JSONRow(["id": "manual", "name": "Other app", "installed": true, "qualified": true]))
            }
            if let initial = initialTarget, let key = initial.profileKey {
                let match = profiles.first { row in
                    row.string("key") == key || (row.string("profile") == key && row.string("host") == initial.host)
                }
                selectedProfileKey = match?.string("key") ?? ""
            } else {
                selectedProfileKey = profiles.first?.string("key") ?? profiles.first?.string("profile") ?? ""
            }
            if let initial = initialTarget {
                selectedTarget = initial.profileKey == nil ? "manual" : selectedTarget
            }
            if selectedTarget != "manual", !targets.contains(where: { $0.string("id") == selectedTarget }) {
                selectedTarget = targets.first(where: { ($0.string("id") == "kilo" || $0.string("id") == "opencode") && $0.bool("installed") && $0.bool("qualified") })?.string("id") ?? "manual"
            }
            if targets.contains(where: { $0.string("id") == selectedTarget && !$0.bool("installed") && selectedTarget != "manual" }) {
                selectedTarget = "manual"
            }
            loaded = true
            await refreshConnections()
            await loadDetails()
        } catch {
            failure = error.localizedDescription
            loaded = true
        }
    }

    private func loadDetails() async {
        guard !selectedProfileKey.isEmpty else {
            selectedDetails = nil
            return
        }
        let key = selectedProfileKey
        let query = ConnectAppsFormatter.detailQuery(profileKey: key, connection: selectedConnectionRow)
        detailsGeneration += 1
        let generation = detailsGeneration
        selectedDetails = nil
        do {
            let details = try await client.object("/api/connect/details" + WebDashboardClient.query(query))
            guard generation == detailsGeneration, key == selectedProfileKey else { return }
            selectedDetails = details
            failure = nil
        } catch {
            if generation == detailsGeneration { failure = error.localizedDescription }
        }
    }

    private func refreshConnections() async {
        do {
            connections = try await client.object("/api/connect/list").rows("connections")
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }

    private func makePlan() {
        guard !selectedProfileKey.isEmpty else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let answer = try await client.post("/api/connect/plan", [
                    "profile": selectedProfileKey,
                    "target": selectedTarget,
                    "make_default": makeDefault,
                ])
                plan = answer.row("plan")
                approval = false
                message = answer.bool("existing") ? "An owned connection already exists; review the reconfiguration plan." : "Read-only preview ready. Nothing changed."
                failure = nil
            } catch { failure = error.localizedDescription }
        }
    }

    private func applyPlan() {
        guard approval, let plan, let id = plan.string("id") else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let answer = try await client.post("/api/connect/apply", ["plan_id": id, "approved": true])
                self.plan = nil
                approval = false
                if let connection = answer.row("connection"), let connectionID = connection.string("id") {
                    selectedConnection = connectionID
                }
                revealedKey = nil
                message = "Connection configured. Read-back and reload-required state remain separate; restart the client only when instructed."
                failure = nil
                await refreshConnections()
                await loadDetails()
            } catch { failure = error.localizedDescription }
        }
    }

    private func verify(_ row: JSONRow) {
        guard let id = row.string("id") else { return }
        runAction {
            let answer = try await client.post("/api/connect/verify", ["id": id])
            message = answer.string("message") ?? "Scoped API verification completed."
        }
    }

    private func disconnect(_ id: String) {
        pendingAction = nil
        revealedKey = nil
        runAction {
            let answer = try await client.post("/api/connect/disconnect", ["id": id, "remove_config": true, "approved": true])
            message = answer.string("message") ?? "Connection disconnected and route revoked."
        }
    }

    private func undo(_ id: String) {
        pendingAction = nil
        revealedKey = nil
        runAction {
            let answer = try await client.post("/api/connect/undo", ["id": id, "approved": true])
            message = answer.string("message") ?? "Connection change undone."
        }
    }

    private func revealKey() {
        guard let id = selectedConnection else { return }
        runAction {
            let answer = try await client.post("/api/connect/key", ["id": id, "approved": true])
            revealedKey = answer.string("key")
            keyWarning = ConnectAppsFormatter.secretWarning(answer)
            message = nil
        }
    }

    private func runAction(_ work: @escaping () async throws -> Void) {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await work()
                failure = nil
                await refreshConnections()
                await loadDetails()
            } catch { failure = error.localizedDescription }
        }
    }

    private func profileTitle(_ row: JSONRow) -> String {
        let name = row.string("display_name") ?? row.string("profile") ?? row.id
        let model = row.string("model_id").map { " · \($0)" } ?? ""
        let host = row.string("host").map { " on \($0)" } ?? ""
        return name + model + host
    }

    private func readinessTone(_ row: JSONRow) -> String {
        switch row.string("readiness") {
        case "ready": "good"
        case "starting", "loading": "busy"
        case "stopped", "offline": "warn"
        default: "bad"
        }
    }

    private func targetTone(_ row: JSONRow) -> Color {
        if row.bool("qualified") && row.bool("installed") { return .green }
        if row.bool("installed") { return .orange }
        return theme.faint
    }

    private func connectionTone(_ row: JSONRow) -> String {
        if row.bool("client_verified") { return "good" }
        if row.bool("api_tested") { return "busy" }
        if row.bool("configured") { return "warn" }
        return "bad"
    }

    private func copy(_ value: String) {
        guard !value.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        message = "Copied non-secret connection fields."
    }
}

import SwiftUI
import ModelMatrixCore

/// Menu bar twin of the web dashboard's profile manager: create a profile from
/// a template, edit any key (form or raw file), duplicate and delete.
struct ProfilesPanelView: View {
    let store: MatrixStore
    let theme: DashboardTheme
    let accent: Color

    @State var editor: ProfileDraft?
    @State var templates: [JSONRow] = []
    @State var runtimes: [JSONRow] = []
    @State var message: String?
    @State var failure: String?
    @State var deleting: String?
    @State var duplicating: String?
    @State var duplicateName = ""

    var client: WebDashboardClient { WebDashboardClient.local(store) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let failure { UsageNotice(text: failure, color: .red, theme: theme) }
            if let message, failure == nil { UsageNotice(text: message, color: accent, theme: theme) }
            if let editor {
                ProfileEditorForm(
                    draft: Binding(get: { editor }, set: { self.editor = $0 }),
                    templates: templates,
                    runtimes: runtimes,
                    theme: theme,
                    accent: accent,
                    save: save,
                    cancel: { self.editor = nil }
                )
            } else {
                list
            }
        }
        .padding(EdgeInsets(top: 10, leading: 14, bottom: 14, trailing: 14))
        .task { await loadCatalog() }
        .confirmationDialog(
            "Delete \(deleting ?? "")?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
        ) {
            Button("Delete profile", role: .destructive) {
                if let name = deleting { run("Deleted \(name)") { try await $0.post("/api/profiles/delete", ["profile": name]) } }
                deleting = nil
            }
        } message: {
            Text("The profile file is removed. Model weights are not touched.")
        }
        .alert("Duplicate \(duplicating ?? "")", isPresented: Binding(get: { duplicating != nil }, set: { if !$0 { duplicating = nil } })) {
            TextField("New profile ID", text: $duplicateName)
            Button("Duplicate") {
                if let name = duplicating {
                    let target = duplicateName.trimmingCharacters(in: .whitespaces)
                    run("Created \(target)") { try await $0.post("/api/profiles/duplicate", ["profile": name, "new_profile": target]) }
                }
                duplicating = nil
            }
            Button("Cancel", role: .cancel) { duplicating = nil }
        }
    }

    var list: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SettingsLinkButton(title: "New Profile", emphasized: true, theme: theme, accent: accent) {
                    editor = ProfileDraft.new(template: templates.first)
                }
                SettingsLinkButton(title: "Open Folder", theme: theme, accent: accent) { store.openProfilesDirectory() }
                Spacer()
            }
            UsageCard(title: "PROFILES", meta: "\(store.statuses.count)", theme: theme) {
                if store.statuses.isEmpty {
                    Text("No profiles yet. Create one for Ollama, llama.cpp, MLX, vLLM, LM Studio or any OpenAI-compatible server.")
                        .font(.system(size: 11)).foregroundStyle(theme.sub).padding(12)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(store.statuses) { status in
                    row(status)
                }
            }
        }
    }

    func row(_ status: ModelProfileStatus) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(status.ready ? Color.green : (status.running ? accent : theme.dotOff))
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(status.displayName.isEmpty ? status.profile : status.displayName)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(theme.label)
                    .lineLimit(1)
                Text("\(status.profile) · \(status.runtimeLabel ?? status.runtime) · \(status.requestModel)")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(theme.sub)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            iconButton("pencil", "Edit") { Task { await edit(status.profile) } }
            iconButton("plus.square.on.square", "Duplicate") {
                duplicateName = "\(status.profile)-copy"
                duplicating = status.profile
            }
            iconButton("trash", "Delete") { deleting = status.profile }
                .disabled(status.running)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    func iconButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11))
        }
        .buttonStyle(.borderless)
        .foregroundStyle(theme.faint)
        .help(label)
        .accessibilityLabel(label)
    }

    func loadCatalog() async {
        guard let catalog = try? await client.object("/api/profiles/runtimes") else { return }
        templates = catalog.rows("templates")
        runtimes = catalog.rows("runtimes")
    }

    func edit(_ name: String) async {
        do {
            let document = try await client.object("/api/profiles/document" + WebDashboardClient.query(["profile": name]))
            editor = ProfileDraft.existing(document)
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }

    func save(_ draft: ProfileDraft) {
        run(draft.isNew ? "Created \(draft.profileID)" : "Saved \(draft.profileID)") { api in
            try await api.post("/api/profiles/save", draft.requestBody)
        } onSuccess: {
            editor = nil
        }
    }

    func run(
        _ success: String,
        _ work: @escaping (WebDashboardClient) async throws -> Void,
        onSuccess: @escaping () -> Void = {}
    ) {
        let api = client
        Task {
            do {
                try await work(api)
                message = success
                failure = nil
                onSuccess()
                await store.refresh(includeDoctor: false)
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

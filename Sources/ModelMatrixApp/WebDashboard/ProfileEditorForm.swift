import SwiftUI

/// Editable copy of a profile: the common keys as fields, every other key as
/// `KEY=value` lines, or the whole file as raw text.
struct ProfileDraft: Equatable {
    static let formKeys = ["DISPLAY_NAME", "RUNTIME", "REQUEST_MODEL", "PORT", "BASE_URL", "MODEL_PATH"]

    var isNew: Bool
    var originalID: String?
    var profileID: String
    var values: [String: String]
    var extraText: String
    var rawMode = false
    var rawText = ""
    var format = "env"

    static func new(template: JSONRow?) -> ProfileDraft {
        var draft = ProfileDraft(isNew: true, originalID: nil, profileID: "", values: [:], extraText: "")
        if let template { draft.apply(template: template) }
        return draft
    }

    static func existing(_ document: JSONRow) -> ProfileDraft {
        let raw = document.raw["values"] as? [String: Any] ?? [:]
        var values: [String: String] = [:]
        for (key, value) in raw where key != "PROFILE_NAME" { values[key] = "\(value)" }
        let name = document.string("profile") ?? ""
        var draft = ProfileDraft(isNew: false, originalID: name, profileID: name, values: [:], extraText: "")
        draft.format = document.string("format") ?? "env"
        draft.rawText = document.string("text") ?? ""
        draft.load(values)
        return draft
    }

    mutating func apply(template: JSONRow) {
        let raw = template.raw["values"] as? [String: Any] ?? [:]
        var values: [String: String] = [:]
        for (key, value) in raw { values[key] = "\(value)" }
        load(values)
        if profileID.isEmpty, let id = template.string("id") { profileID = id == "blank" ? "" : id }
    }

    mutating func load(_ all: [String: String]) {
        values = all.filter { Self.formKeys.contains($0.key) }
        extraText = all.filter { !Self.formKeys.contains($0.key) }
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "\n")
    }

    var mergedValues: [String: String] {
        var merged = values.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
        for line in extraText.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, !text.hasPrefix("#"), let equals = text.firstIndex(of: "=") else { continue }
            let key = text[..<equals].trimmingCharacters(in: .whitespaces)
            let value = text[text.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { merged[key] = value }
        }
        return merged
    }

    var requestBody: [String: Any] {
        var body: [String: Any] = ["profile": profileID.trimmingCharacters(in: .whitespaces)]
        if let originalID { body["original_profile"] = originalID }
        if isNew { body["create"] = true }
        if rawMode { body["text"] = rawText } else { body["values"] = mergedValues }
        return body
    }

    func binding(_ key: String, in draft: Binding<ProfileDraft>) -> Binding<String> {
        Binding(get: { draft.wrappedValue.values[key] ?? "" }, set: { draft.wrappedValue.values[key] = $0 })
    }
}

struct ProfileEditorForm: View {
    @Binding var draft: ProfileDraft
    let templates: [JSONRow]
    let runtimes: [JSONRow]
    let theme: DashboardTheme
    let accent: Color
    let save: (ProfileDraft) -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(draft.isNew ? "New profile" : "Edit \(draft.originalID ?? "")")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.label)
                Spacer()
                if !draft.isNew {
                    Toggle("Raw file", isOn: $draft.rawMode)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .font(.system(size: 10.5))
                        .foregroundStyle(theme.sub)
                }
            }
            if draft.isNew && !templates.isEmpty {
                Picker("Template", selection: Binding(
                    get: { "" },
                    set: { id in if let template = templates.first(where: { $0.string("id") == id }) { draft.apply(template: template) } }
                )) {
                    Text("Start from template…").tag("")
                    ForEach(templates) { template in
                        Text(template.string("label") ?? template.string("id") ?? "-").tag(template.string("id") ?? "")
                    }
                }
                .font(.system(size: 11))
            }
            if draft.rawMode {
                TextEditor(text: $draft.rawText)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(minHeight: 260)
                    .scrollContentBackground(.hidden)
                    .background(RoundedRectangle(cornerRadius: 8).fill(theme.fieldBg))
                Text("Saved exactly as typed (\(draft.format) format).").font(.system(size: 10)).foregroundStyle(theme.sub)
            } else {
                fields
            }
            HStack(spacing: 8) {
                Spacer()
                SettingsLinkButton(title: "Cancel", theme: theme, accent: accent, action: cancel)
                SettingsLinkButton(title: draft.isNew ? "Create" : "Save", emphasized: true, theme: theme, accent: accent) {
                    save(draft)
                }
                .disabled(draft.profileID.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(theme.cellBg))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.line, lineWidth: 0.5))
    }

    @ViewBuilder
    var fields: some View {
        field("Profile ID", text: $draft.profileID, prompt: "qwen3-8b", hint: "File name in the profiles folder. Letters, numbers, - and _.")
        field("Display name", text: draft.binding("DISPLAY_NAME", in: $draft), prompt: "Qwen3 8B")
        VStack(alignment: .leading, spacing: 3) {
            label("Runtime")
            Picker("", selection: draft.binding("RUNTIME", in: $draft)) {
                Text("Choose…").tag("")
                ForEach(runtimes) { runtime in
                    Text(runtime.string("label") ?? runtime.string("id") ?? "-").tag(runtime.string("id") ?? "")
                }
                if let current = draft.values["RUNTIME"], !current.isEmpty,
                    !runtimes.contains(where: { $0.string("id") == current }) {
                    Text(current).tag(current)
                }
            }
            .labelsHidden()
            .font(.system(size: 11))
        }
        field("Request model", text: draft.binding("REQUEST_MODEL", in: $draft), prompt: "qwen3:8b", hint: "Model name clients send in requests.")
        HStack(spacing: 8) {
            field("Port", text: draft.binding("PORT", in: $draft), prompt: "8080")
            field("Base URL", text: draft.binding("BASE_URL", in: $draft), prompt: "http://127.0.0.1:8080/v1")
        }
        field("Model path", text: draft.binding("MODEL_PATH", in: $draft), prompt: "~/models/qwen3-8b.gguf")
        VStack(alignment: .leading, spacing: 3) {
            label("Other settings (KEY=value per line)")
            TextEditor(text: $draft.extraText)
                .font(.system(size: 10.5, design: .monospaced))
                .frame(minHeight: 110)
                .scrollContentBackground(.hidden)
                .background(RoundedRectangle(cornerRadius: 8).fill(theme.fieldBg))
        }
    }

    func label(_ text: String) -> some View {
        Text(text).font(.system(size: 10, weight: .medium)).foregroundStyle(theme.sub)
    }

    func field(_ title: String, text: Binding<String>, prompt: String, hint: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            label(title)
            TextField("", text: text, prompt: Text(prompt))
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7).fill(theme.fieldBg))
                .foregroundStyle(theme.fieldFg)
            if let hint {
                Text(hint).font(.system(size: 9.5)).foregroundStyle(theme.faint)
            }
        }
    }
}

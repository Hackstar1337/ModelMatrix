import SwiftUI

/// Menu bar twin of the dashboard's Settings > Hugging Face and the engine
/// locations under Settings > Engines. Settings belong to this Mac's
/// controller; remote hosts keep their own.
struct HFSettingsCard: View {
    let client: WebDashboardClient
    let theme: DashboardTheme
    let accent: Color

    @State private var expanded = false
    @State private var settings: JSONRow?
    @State private var folder = ""
    @State private var mirror = ""
    @State private var speed = ""
    @State private var token = ""
    @State private var paths: [String: String] = [:]
    @State private var message: String?
    @State private var failed = false
    @State private var busy = false

    static let engines: [(id: String, name: String)] = [
        ("llama.cpp", "llama.cpp"), ("mlx-lm", "MLX (mlx-lm)"), ("ollama", "Ollama"),
    ]

    var body: some View {
        UsageCard(title: "DOWNLOAD SETTINGS", meta: settings.map { $0.bool("token_saved") ? "token saved" : "no token" }, theme: theme) {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    expanded.toggle()
                    if expanded { load() }
                } label: {
                    HStack(spacing: 6) {
                        Text(expanded ? "Hide settings" : "Models folder, mirror, speed, token and engine locations")
                            .font(.system(size: 10.5))
                            .foregroundStyle(theme.sub)
                        Spacer(minLength: 0)
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(theme.faint)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expanded ? "Hide download settings" : "Show download settings")
                if let message {
                    UsageNotice(text: message, color: failed ? .red : accent, theme: theme)
                }
                if expanded, let settings { content(settings) }
                if expanded, settings == nil, !failed { ProgressView().controlSize(.small) }
            }
            .padding(10)
        }
    }

    @ViewBuilder
    func content(_ settings: JSONRow) -> some View {
        field("Models folder", text: $folder, placeholder: "~/ModelMatrix/Models", saved: settings.string("models_folder") ?? "") {
            put(["models_folder": folder.trimmingCharacters(in: .whitespaces)], done: "Models folder saved")
        }
        if let free = settings.double("free_disk_bytes") {
            Text("\(UsageFormat.bytes(free)) free there. Remote hosts use their own folder.")
                .font(.system(size: 9.5))
                .foregroundStyle(theme.faint)
        }
        field("Mirror", text: $mirror, placeholder: "https://huggingface.co", saved: settings.string("endpoint") ?? "") {
            let value = mirror.trimmingCharacters(in: .whitespaces)
            put(["endpoint": value.isEmpty ? NSNull() : value], done: value.isEmpty ? "Using huggingface.co" : "Mirror saved")
        }
        field("Speed limit", text: $speed, placeholder: "0 = no limit", saved: Self.speedText(settings), unit: "MB/s") {
            let value = Double(speed.trimmingCharacters(in: .whitespaces)) ?? 0
            put(["speed_limit_mbps": value], done: value > 0 ? "Limited to \(speed) MB/s" : "No speed limit")
        }
        HStack(spacing: 8) {
            label("Connections")
            Stepper(
                "\(settings.int("connections_per_file") ?? 4) per file",
                value: Binding(
                    get: { settings.int("connections_per_file") ?? 4 },
                    set: { put(["connections_per_file": $0], done: "\($0) connection\($0 == 1 ? "" : "s") per file") }),
                in: 1...8
            )
            .font(.system(size: 10.5))
            .controlSize(.small)
            .disabled(busy)
            Spacer(minLength: 0)
        }
        toggle("Start after download", key: "start_after_download", settings: settings,
               on: "New models start after download", off: "New models are only set up")
        toggle("Keep the Mac awake", key: "keep_awake", settings: settings,
               on: "Keeps the Mac awake while downloading", off: "The Mac may sleep during downloads")
        HFDivider(theme: theme)
        tokenRow(settings)
        HFDivider(theme: theme)
        Text("ENGINE LOCATIONS")
            .font(.system(size: 9, weight: .bold))
            .tracking(0.5)
            .foregroundStyle(theme.faint)
        Text("Only for engines installed where ModelMatrix doesn't look. Enter the full path of the server program, or leave it empty to find it automatically.")
            .font(.system(size: 9.5))
            .foregroundStyle(theme.faint)
            .fixedSize(horizontal: false, vertical: true)
        ForEach(Self.engines, id: \.id) { engine in
            field(
                engine.name,
                text: Binding(get: { paths[engine.id] ?? "" }, set: { paths[engine.id] = $0 }),
                placeholder: "automatic",
                saved: Self.enginePaths(settings)[engine.id] ?? ""
            ) {
                let value = (paths[engine.id] ?? "").trimmingCharacters(in: .whitespaces)
                put(["engine_paths": [engine.id: value]],
                    done: value.isEmpty ? "\(engine.name) is found automatically again" : "\(engine.name) location saved")
            }
        }
    }

    func tokenRow(_ settings: JSONRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                label("Token")
                Text(settings.bool("token_saved") ? "Saved in the Keychain" : "Not saved (needed only for gated models)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(settings.bool("token_saved") ? .green : theme.sub)
                Spacer(minLength: 0)
                if settings.bool("token_saved") {
                    SettingsLinkButton(title: "Remove", theme: theme, accent: accent) { removeToken() }
                        .disabled(busy)
                }
            }
            HStack(spacing: 8) {
                label("")
                SecureField("hf_…", text: $token)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.fieldFg)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 5).fill(theme.fieldBg))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(theme.line, lineWidth: 0.5))
                    .onSubmit { saveToken() }
                    .accessibilityLabel("Hugging Face token")
                SettingsLinkButton(title: "Save", emphasized: true, theme: theme, accent: accent) { saveToken() }
                    .disabled(busy || token.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("Create a read token at huggingface.co/settings/tokens. It is checked with Hugging Face, kept in the Keychain and sent only to Hugging Face.")
                .font(.system(size: 9.5))
                .foregroundStyle(theme.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(theme.faint)
            .frame(width: 82, alignment: .leading)
    }

    func field(
        _ title: String,
        text: Binding<String>,
        placeholder: String,
        saved: String,
        unit: String? = nil,
        save: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            label(title)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(theme.fieldFg)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 5).fill(theme.fieldBg))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(theme.line, lineWidth: 0.5))
                .onSubmit(save)
                .accessibilityLabel(title)
            if let unit {
                Text(unit).font(.system(size: 10)).foregroundStyle(theme.faint)
            }
            SettingsLinkButton(title: "Save", theme: theme, accent: accent, action: save)
                .disabled(busy || text.wrappedValue.trimmingCharacters(in: .whitespaces) == saved)
        }
    }

    func toggle(_ title: String, key: String, settings: JSONRow, on: String, off: String) -> some View {
        HStack(spacing: 8) {
            label(title)
            Spacer(minLength: 0)
            Toggle(
                title,
                isOn: Binding(get: { settings.bool(key) }, set: { put([key: $0], done: $0 ? on : off) })
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(busy)
        }
    }

    static func speedText(_ settings: JSONRow) -> String {
        let value = settings.double("speed_limit_mbps") ?? 0
        return value == value.rounded() ? String(Int(value)) : String(value)
    }

    static func enginePaths(_ settings: JSONRow) -> [String: String] {
        settings.raw["engine_paths"] as? [String: String] ?? [:]
    }

    func apply(_ row: JSONRow?) {
        guard let row else { return }
        settings = row
        folder = row.string("models_folder") ?? ""
        mirror = row.string("endpoint") ?? ""
        speed = Self.speedText(row)
        paths = Self.enginePaths(row)
    }

    func load() {
        Task {
            do {
                apply(try await client.object("/api/hf/settings").row("settings"))
                failed = false
            } catch {
                failed = true
                message = error.localizedDescription
            }
        }
    }

    func put(_ patch: [String: Any], done: String) {
        busy = true
        Task {
            defer { busy = false }
            do {
                apply(try await client.object("/api/hf/settings", method: "PUT", body: patch).row("settings"))
                failed = false
                message = done
            } catch {
                failed = true
                message = error.localizedDescription
            }
        }
    }

    func saveToken() {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let answer = try await client.post("/api/hf/token", ["token": value], timeout: 30)
                token = ""
                failed = false
                message = answer.string("user").map { "Token saved for \($0)" } ?? "Token saved"
                load()
            } catch {
                failed = true
                message = error.localizedDescription
            }
        }
    }

    func removeToken() {
        busy = true
        Task {
            defer { busy = false }
            do {
                _ = try await client.object("/api/hf/token", method: "DELETE")
                failed = false
                message = "Token removed"
                load()
            } catch {
                failed = true
                message = error.localizedDescription
            }
        }
    }
}

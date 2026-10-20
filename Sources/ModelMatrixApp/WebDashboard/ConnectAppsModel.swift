import Foundation

/// A model/profile entrypoint selected from the native profile or downloads panels.
struct ConnectAppsTarget: Equatable, Sendable {
    let profileKey: String?
    let host: String?
    let modelID: String?
    let label: String
}

/// Deliberate confirmations for destructive or secret-bearing Connect actions.
enum ConnectAppsPendingAction: Identifiable, Equatable {
    case disconnect(String)
    case undo(String)

    var id: String {
        switch self {
        case .disconnect(let id): "disconnect-\(id)"
        case .undo(let id): "undo-\(id)"
        }
    }
}

/// Formatting is kept free of views and networking so menu-bar parity can be
/// tested without touching a controller, client config, or a real credential.
enum ConnectAppsFormatter {
    static func readiness(_ row: JSONRow) -> String {
        let readiness = row.string("readiness") ?? "unknown"
        switch readiness {
        case "ready": return "Ready"
        case "starting", "loading": return "Starting"
        case "stopped", "offline": return "Stopped"
        case "needs_attention", "needs_review": return "Needs attention"
        default: return readiness.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    static func targetLabel(_ row: JSONRow) -> String {
        let name = row.string("name") ?? row.string("id") ?? "App"
        if row.bool("installed") == false { return "\(name) · not installed" }
        if row.bool("qualified") == false { return "\(name) · not qualified" }
        return "\(name) · ready"
    }

    static func connectionState(_ row: JSONRow) -> String {
        var states: [String] = []
        if row.bool("configured") { states.append("Configured") }
        if row.bool("api_tested") { states.append("API tested") }
        if row.bool("client_verified") { states.append("Client verified") }
        if row.bool("reload_required") { states.append("Reload required") }
        if let readiness = row.string("readiness"), !readiness.isEmpty {
            states.append(readiness.replacingOccurrences(of: "_", with: " ").capitalized)
        }
        return states.isEmpty ? "Not configured" : states.joined(separator: " · ")
    }

    static func detailQuery(profileKey: String, connection: JSONRow?) -> [String: String] {
        var query = ["profile": profileKey]
        if let connection, connection.bool("configured"),
           connection.string("profile_key") == profileKey,
           let id = connection.string("id") {
            query["connection"] = id
        }
        return query
    }

    /// Fields intentionally exclude `key`, credential references and any secret.
    static func copyableDetails(_ row: JSONRow) -> String {
        let pairs: [(String, String?)] = [
            ("Provider", row.string("provider") ?? row.string("provider_id")),
            ("Base URL", row.string("base_url")),
            ("Server root", row.string("server_root")),
            ("Model list", row.string("model_list_url")),
            ("Chat", row.string("chat_url")),
            ("Model ID", row.string("model_id")),
            ("API key", row.string("api_key_requirement")),
        ]
        return pairs.compactMap { label, value in
            guard let value, !value.isEmpty else { return nil }
            return "\(label): \(value)"
        }.joined(separator: "\n")
    }

    static func secretWarning(_ row: JSONRow) -> String {
        row.string("warning") ?? "This is the private connection key. Copy it only into the selected app or an approved private key file; never paste it into a shared document or chat."
    }
}

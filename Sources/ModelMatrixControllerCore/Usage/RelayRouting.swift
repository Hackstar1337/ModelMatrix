import Foundation
import ModelMatrixCore

/// A model server the relay can forward to.
public struct RelayTarget: Sendable, Equatable {
    public var profile: String?
    public var displayName: String
    public var runtime: String
    public var host: String
    public var port: UInt16
    /// Path prefix of the OpenAI-compatible API on the server (usually `/v1`).
    public var basePath: String
    /// Model ids this server answers to (lowercased).
    public var models: [String]
    /// Profile and display names that also select this server (lowercased).
    public var aliases: [String] = []
    public var ready: Bool
    public var running: Bool
    public var active: Bool

    public init(
        profile: String?, displayName: String, runtime: String, host: String, port: UInt16,
        basePath: String = "/v1", models: [String] = [], ready: Bool = true, running: Bool = true,
        active: Bool = false
    ) {
        self.profile = profile
        self.displayName = displayName
        self.runtime = runtime
        self.host = host
        self.port = port
        self.basePath = basePath
        self.models = models.map { $0.lowercased() }
        self.ready = ready
        self.running = running
        self.active = active
    }

    public var isOllama: Bool { runtime == "ollama" }

    /// Internal port used by a captured profile's runtime.
    public static func capturePort(for port: UInt16) -> UInt16 {
        port <= 55_535 ? port + 10_000 : port - 10_000
    }

    /// Builds a target from a controller status row.
    public static func from(
        status: ModelProfileStatus, profile: ControllerProfile?, activeProfile: String?
    ) -> RelayTarget? {
        guard let url = URL(string: status.baseURL), let host = url.host else { return nil }
        let rawPort = url.port.map(UInt16.init) ?? UInt16(status.port) ?? (url.scheme == "https" ? 443 : 80)
        var port = rawPort
        if let profile, UsageService.captureEnabled(profile) {
            port = capturePort(for: rawPort)
        }
        var models = Set([status.requestModel, status.serverModelID])
        for id in status.serverIDs { models.insert(id) }
        var basePath = url.path
        if basePath.hasSuffix("/") { basePath.removeLast() }
        var target = RelayTarget(
            profile: status.profile,
            displayName: status.displayName,
            runtime: status.runtime,
            host: ControllerConfiguration.isLoopback(host) ? "127.0.0.1" : host,
            port: port,
            basePath: basePath,
            models: Array(models).filter { !$0.isEmpty },
            ready: status.ready,
            running: status.running,
            active: status.profile == activeProfile
        )
        target.aliases = [status.profile.lowercased(), status.displayName.lowercased()]
        return target
    }
}

public enum RelayRouting {
    /// Native Ollama API paths (forwarded to an Ollama server as-is).
    public static func isOllamaNative(_ path: String) -> Bool {
        path.hasPrefix("/api/")
    }

    /// Endpoints whose requests are recorded as usage.
    public static func isMetered(method: String, path: String) -> Bool {
        guard method == "POST" else { return false }
        let metered = [
            "/v1/chat/completions", "/v1/completions", "/v1/embeddings", "/v1/responses", "/v1/messages",
            "/api/chat", "/api/generate", "/api/embed", "/api/embeddings",
            "/chat/completions", "/completions", "/embeddings",
        ]
        return metered.contains(path)
    }

    public static func isCloudModel(_ model: String?) -> Bool {
        guard let model = model?.lowercased(), !model.isEmpty else { return false }
        return model.range(of: "(^|[:\\-_])cloud($|[:\\-_])", options: .regularExpression) != nil
    }

    /// Picks the server for a request.
    public static func resolve(model: String?, path: String, targets: [RelayTarget]) -> RelayTarget? {
        let wanted = model?.lowercased()
        let ollama = targets.filter(\.isOllama).sorted { score($0) > score($1) }
        if isOllamaNative(path) { return ollama.first }
        if let wanted, !wanted.isEmpty {
            let matches = targets.filter { $0.models.contains(wanted) || $0.aliases.contains(wanted) }.sorted { score($0) > score($1) }
            if let best = matches.first { return best }
            // Ollama answers for any tag it has pulled ("name:tag").
            let base = wanted.split(separator: ":").first.map(String.init) ?? wanted
            let prefix = targets.filter { target in
                target.models.contains { $0.split(separator: ":").first.map(String.init) == base }
            }.sorted { score($0) > score($1) }
            if let best = prefix.first, wanted.contains(":") || best.isOllama { return best }
            if wanted.contains(":"), let first = ollama.first { return first }
        }
        let ready = targets.filter(\.ready).sorted { score($0) > score($1) }
        return ready.first
    }

    /// Ready > running > configured; the active profile wins ties; profiles beat the bare Ollama daemon.
    static func score(_ target: RelayTarget) -> Int {
        (target.ready ? 100 : 0) + (target.running ? 10 : 0) + (target.active ? 5 : 0)
            + (target.profile == nil ? 0 : 1)
    }

    /// Maps the client's path onto the server's API prefix.
    public static func upstreamPath(for target: String, server: RelayTarget) -> String {
        let pathEnd = target.firstIndex(of: "?") ?? target.endIndex
        let path = String(target[..<pathEnd])
        let query = String(target[pathEnd...])
        if isOllamaNative(path) { return path + query }
        var suffix = path
        if suffix.hasPrefix("/v1/") || suffix == "/v1" { suffix = String(suffix.dropFirst(3)) }
        let base = server.isOllama && server.basePath.isEmpty ? "/v1" : server.basePath
        return base + (suffix.hasPrefix("/") ? suffix : "/" + suffix) + query
    }
}

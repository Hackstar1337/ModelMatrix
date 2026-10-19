import AppKit
import Foundation
import Observation
import OSLog
import ModelMatrixCore

/// Keeps the web dashboard in step with the menu bar app.
///
/// Every few seconds the app reports its remote hosts (with their tunnel URL
/// and Keychain token, which stay inside the local controller process) and
/// picks up commands queued by the dashboard: pairing, agent installs, host
/// edits, opening Finder or the settings panel. Everything the app can do for
/// remote hosts is therefore also available from `http://localhost:7700`.
@MainActor
@Observable
final class DashboardBridge {
    static let shared = DashboardBridge()
    static let logger = Logger(subsystem: "io.github.hackstar1337.modelmatrix.app", category: "dashboard-bridge")
    static let interval: Duration = .seconds(3)

    /// Inspector the dashboard asked the menu bar to show ("settings", "usage", ...).
    var requestedInspector: String?
    /// Bumped whenever the dashboard asks the app to show its menu.
    var presentRequest = 0
    var isConnected = false

    @ObservationIgnored weak var store: MatrixStore?
    @ObservationIgnored weak var hub: GatewayHub?
    @ObservationIgnored var loop: Task<Void, Never>?
    @ObservationIgnored var running: Set<String> = []
    /// Last controller status revision seen; nil until the first heartbeat.
    @ObservationIgnored var lastStatusRevision: Int?

    func start(store: MatrixStore, hub: GatewayHub) {
        self.store = store
        self.hub = hub
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.beat()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    var client: WebDashboardClient? {
        store.map { WebDashboardClient.local($0) }
    }

    func beat() async {
        guard let client, let payload = heartbeatPayload() else { return }
        do {
            let response = try await client.post("/api/bridge/heartbeat", payload, timeout: 8)
            isConnected = true
            syncStatusRevision(response.int("status_revision"))
            for command in response.rows("commands") {
                guard let id = command.string("id"), !running.contains(id) else { continue }
                running.insert(id)
                Task { await self.run(command, id: id, client: client) }
            }
        } catch {
            // Older controllers have no bridge; the menu bar works without it.
            isConnected = false
        }
    }

    func heartbeatPayload() -> [String: Any]? {
        guard let store, let hub else { return nil }
        var gateways: [[String: Any]] = hub.remoteRuntimes.map { runtime in
            var item: [String: Any] = [
                "id": runtime.id,
                "name": runtime.name,
                "kind": runtime.config.kind.rawValue,
                "enabled": runtime.config.enabled,
                "base_url": runtime.store.controllerBaseURL,
                "token": runtime.store.controllerAuthToken,
                "connection": Self.connectionLabel(runtime),
                "profiles": runtime.store.statuses.count,
                "running": runtime.store.statuses.filter(\.running).count,
            ]
            if let ssh = runtime.config.ssh {
                item["ssh_target"] = ssh.sshPort == 22 ? ssh.destination : "\(ssh.destination):\(ssh.sshPort)"
            }
            if let direct = runtime.config.direct { item["base_url_configured"] = direct.baseURL }
            if let updated = runtime.store.lastUpdated { item["last_updated"] = updated.timeIntervalSince1970 }
            return item
        }
        // Paused hosts have no runtime but must stay visible so they can be resumed.
        let active = Set(hub.remoteRuntimes.map(\.id))
        for config in GatewayConfigStore.load(from: hub.defaults) where !active.contains(config.id) {
            var item: [String: Any] = [
                "id": config.id,
                "name": config.name,
                "kind": config.kind.rawValue,
                "enabled": config.enabled,
                "base_url": config.direct?.baseURL ?? "",
                "connection": config.enabled ? "starting" : "paused",
                "profiles": 0,
                "running": 0,
            ]
            if let ssh = config.ssh {
                item["ssh_target"] = ssh.sshPort == 22 ? ssh.destination : "\(ssh.destination):\(ssh.sshPort)"
            }
            if let direct = config.direct { item["base_url_configured"] = direct.baseURL }
            gateways.append(item)
        }
        var app: [String: Any] = [
            "version": MenuBarContentView.appVersion,
            "pid": ProcessInfo.processInfo.processIdentifier,
        ]
        app["last_active_profile"] = store.lastActiveProfiles.first
        app["quittable_apps"] = AppQuitter.quittableAppPaths()
        return ["app": app, "gateways": gateways]
    }

    static func connectionLabel(_ runtime: GatewayRuntime) -> String {
        guard runtime.config.kind == .ssh else { return "direct" }
        switch runtime.tunnelState {
        case .idle: return "tunnel off"
        case .connecting: return "tunnel connecting"
        case .established: return "tunnel up"
        case .failed(let message): return "tunnel failed: \(message)"
        }
    }

    func run(_ command: JSONRow, id: String, client: WebDashboardClient) async {
        defer { running.remove(id) }
        let type = command.string("type") ?? ""
        let payload = command.row("payload") ?? JSONRow([:])
        var body: [String: Any] = ["id": id]
        do {
            let reply = try await executeWithResult(type: type, payload: payload)
            body["ok"] = true
            body["message"] = reply.message
            if let result = reply.result { body["result"] = result }
        } catch {
            body["ok"] = false
            body["message"] = error.localizedDescription
            Self.logger.error("dashboard command \(type, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
        _ = try? await client.post("/api/bridge/commands/result", body, timeout: 8)
    }
}

struct BridgeCommandError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

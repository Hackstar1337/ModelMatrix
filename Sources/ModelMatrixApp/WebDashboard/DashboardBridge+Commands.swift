import AppKit
import Foundation
import ModelMatrixCore

extension DashboardBridge {
    func execute(type: String, payload: JSONRow) async throws -> String {
        guard let store, let hub else { throw BridgeCommandError("The menu bar app is starting up.") }
        switch type {
        case "gateway.pair":
            let link = payload.string("link") ?? ""
            guard let config = GatewayLinkCode.parse(link) else {
                throw BridgeCommandError("That is not a valid ModelMatrix pairing link.")
            }
            hub.upsertGateway(config, token: payload.string("token") ?? "")
            return "Paired \(config.name)"
        case "gateway.add":
            let config = try Self.makeConfig(payload, existing: nil)
            hub.upsertGateway(config, token: payload.string("token") ?? "")
            return "Added \(config.name)"
        case "gateway.update":
            let existing = try gatewayConfig(payload.string("id"), hub: hub)
            let config = try Self.makeConfig(payload, existing: existing)
            hub.upsertGateway(config, token: payload.string("token") ?? "")
            return "Saved \(config.name)"
        case "gateway.remove":
            let config = try gatewayConfig(payload.string("id"), hub: hub)
            hub.removeGateway(id: config.id)
            return "Removed \(config.name)"
        case "gateway.toggle":
            var config = try gatewayConfig(payload.string("id"), hub: hub)
            config.enabled.toggle()
            hub.upsertGateway(config, token: "")
            return config.enabled ? "Resumed \(config.name)" : "Paused \(config.name)"
        case "gateway.refresh":
            let config = try gatewayConfig(payload.string("id"), hub: hub)
            guard let runtime = hub.runtime(id: config.id) else { throw BridgeCommandError("\(config.name) is paused.") }
            await runtime.store.refresh()
            return "Refreshed \(config.name)"
        case "gateway.install_agent":
            return try await installAgent(payload.string("id"), hub: hub)
        case "gateway.update_agent":
            let config = try gatewayConfig(payload.string("id"), hub: hub)
            await hub.forceUpdateGateway(id: config.id)
            if let runtime = hub.runtime(id: config.id), case .failed(let message) = runtime.forceUpdatePhase {
                throw BridgeCommandError(message)
            }
            return "Updated the agent on \(config.name)"
        case "app.refresh":
            await store.refresh(includeDoctor: false)
            hub.refreshAll()
            return "Refreshed"
        case "app.open_settings", "app.open_usage", "app.open_profiles", "app.open_optimize", "app.open_downloads":
            requestedInspector = String(type.dropFirst("app.open_".count))
            presentRequest += 1
            NSApp.activate(ignoringOtherApps: true)
            return "Opened"
        case "app.quit_app":
            let name = try AppQuitter.quit(path: payload.string("path"), name: payload.string("name"))
            return "Asked \(name) to quit"
        case "app.open_profiles_folder":
            store.openProfilesDirectory()
            return "Opened the profiles folder"
        case "app.open_logs":
            guard let root = store.controllerRoot else { throw BridgeCommandError("The controller folder is not known yet.") }
            let logs = URL(fileURLWithPath: root).appendingPathComponent("run/logs", isDirectory: true)
            let target = FileManager.default.fileExists(atPath: logs.path) ? logs : URL(fileURLWithPath: root)
            NSWorkspace.shared.open(target)
            return "Opened the logs folder"
        default:
            throw BridgeCommandError("Unknown action: \(type)")
        }
    }

    func gatewayConfig(_ id: String?, hub: GatewayHub) throws -> GatewayConfig {
        guard let id, let config = GatewayConfigStore.load(from: hub.defaults).first(where: { $0.id == id }) else {
            throw BridgeCommandError("That remote host no longer exists.")
        }
        return config
    }

    func installAgent(_ id: String?, hub: GatewayHub) async throws -> String {
        let config = try gatewayConfig(id, hub: hub)
        guard let ssh = config.ssh else {
            throw BridgeCommandError("Agent install needs an SSH host. Use Update agent for direct hosts.")
        }
        do {
            let result = try await RemoteAgentDeployer().deploy(to: ssh, useTailscale: false)
            if let token = result.authToken, !token.isEmpty {
                hub.upsertGateway(config, token: token)
            } else {
                hub.refreshAll()
            }
            return "Agent installed on \(ssh.sshHost)"
        } catch let error as RemoteAgentDeployer.DeployError {
            switch error {
            case .missingResources:
                throw BridgeCommandError("This build is missing the bundled agent. Reinstall ModelMatrix.")
            case .sshFailed:
                throw BridgeCommandError(error.userFacingMessage(verb: "Install"))
            }
        }
    }

    /// Builds a gateway from the dashboard form, keeping fields the form does not
    /// show (SSH identity file/agent, deploy host) when editing.
    static func makeConfig(_ payload: JSONRow, existing: GatewayConfig?) throws -> GatewayConfig {
        let kind = payload.string("kind") ?? existing?.kind.rawValue ?? "direct"
        let id = existing?.id ?? UUID().uuidString
        let enabled = existing?.enabled ?? true
        if kind == "ssh" {
            let target = (payload.string("ssh_target") ?? existing?.ssh.map(\.destination) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let parsed = parseSSHTarget(target) else {
                throw BridgeCommandError("Enter the SSH target as user@host or user@host:port.")
            }
            let name = payload.string("name")?.trimmingCharacters(in: .whitespaces) ?? existing?.name ?? parsed.host
            return .ssh(
                id: id,
                name: name.isEmpty ? parsed.host : name,
                sshUser: parsed.user,
                sshHost: parsed.host,
                sshPort: parsed.port ?? existing?.ssh?.sshPort ?? 22,
                remotePort: existing?.remotePort ?? 7700,
                identityFile: existing?.ssh?.identityFile,
                identityAgent: existing?.ssh?.identityAgent,
                enabled: enabled
            )
        }
        let baseURL = (payload.string("base_url") ?? existing?.direct?.baseURL ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: baseURL), let scheme = url.scheme, ["http", "https"].contains(scheme), let host = url.host
        else {
            throw BridgeCommandError("Enter the agent URL, for example http://192.168.1.20:7700.")
        }
        let name = payload.string("name")?.trimmingCharacters(in: .whitespaces) ?? existing?.name ?? host
        return .direct(
            id: id,
            name: name.isEmpty ? host : name,
            baseURL: baseURL,
            remotePort: url.port ?? existing?.remotePort ?? 7700,
            deployHost: existing?.direct?.deployHost,
            enabled: enabled
        )
    }

    static func parseSSHTarget(_ raw: String) -> (user: String, host: String, port: Int?)? {
        var text = raw
        if text.hasPrefix("ssh://") { text.removeFirst("ssh://".count) }
        guard !text.isEmpty, !text.hasPrefix("-"), !text.contains(" ") else { return nil }
        var user = ""
        if let at = text.lastIndex(of: "@") {
            user = String(text[..<at])
            text = String(text[text.index(after: at)...])
        }
        var port: Int?
        if let colon = text.lastIndex(of: ":"), !text.hasPrefix("[") {
            port = Int(text[text.index(after: colon)...])
            if port == nil { return nil }
            text = String(text[..<colon])
        }
        guard !text.isEmpty, !GatewayConfig.looksLikeSSHOption(text), !GatewayConfig.looksLikeSSHOption(user) else {
            return nil
        }
        return (user, text, port)
    }
}

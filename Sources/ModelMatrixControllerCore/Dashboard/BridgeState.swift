import Foundation

/// A command the dashboard asks the menu bar app to run (pairing, agent
/// installs, remote host edits - things only the app can do because they need
/// SSH, the Keychain or a tunnel).
public struct BridgeCommand: Sendable {
    public let id: String
    public let type: String
    public let payloadJSON: Data
    public var status: String = "queued"
    public var message: String?
    public var resultJSON: Data?
    public let createdAt: Date
    public var updatedAt: Date

    public var publicObject: [String: Any] {
        var object: [String: Any] = [
            "id": id, "type": type, "status": status,
            "created_at": createdAt.timeIntervalSince1970, "updated_at": updatedAt.timeIntervalSince1970,
        ]
        object["message"] = message
        if let resultJSON, let result = try? JSONSerialization.jsonObject(with: resultJSON) {
            object["result"] = result
        }
        if let payload = try? JSONSerialization.jsonObject(with: payloadJSON) { object["payload"] = payload }
        return object
    }
}

/// Remote host as reported by the app. The token never leaves the controller process.
public struct BridgeGateway: Sendable {
    public let id: String
    public let name: String
    public let kind: String
    public let enabled: Bool
    public let baseURL: String
    let token: String?
    public let infoJSON: Data
}

public final class BridgeState: @unchecked Sendable {
    let lock = NSLock()
    var gateways: [String: BridgeGateway] = [:]
    var gatewayOrder: [String] = []
    var lastHeartbeat: Date?
    var appInfo: [String: Any] = [:]
    var commands: [String: BridgeCommand] = [:]
    var commandOrder: [String] = []
    var revision = 0
    public static let commandTypes: Set<String> = [
        "gateway.add", "gateway.update", "gateway.remove", "gateway.pair", "gateway.install_agent",
        "gateway.update_agent", "gateway.refresh", "gateway.toggle", "app.open_settings", "app.refresh",
        "app.open_profiles_folder", "app.open_logs", "app.open_usage", "app.open_profiles",
    ]

    public init() {}

    /// Changes whenever a request may have changed profile or host state
    /// (start, stop, edits, remote actions...). The app reads it from every
    /// heartbeat and refreshes at once when it moves, so actions taken from
    /// the web dashboard, the CLI or other clients show up in the menu bar
    /// within one heartbeat instead of waiting for the idle refresh cadence.
    public var statusRevision: Int {
        lock.lock()
        defer { lock.unlock() }
        return revision
    }

    public func bumpStatusRevision() {
        lock.lock()
        defer { lock.unlock() }
        revision &+= 1
    }

    /// POST routes that cannot change what the menu bar shows: the bridge's
    /// own traffic, dashboard sign-in, and usage statistics settings.
    public static func changesStatus(method: String, path: String) -> Bool {
        guard method == "POST", path.hasPrefix("/api/") else { return false }
        let quiet = ["/api/bridge/", "/api/usage/", "/api/dashboard/"]
        return !quiet.contains { path.hasPrefix($0) }
    }

    public var appConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let lastHeartbeat else { return false }
        return Date().timeIntervalSince(lastHeartbeat) < 15
    }

    /// Records the app's heartbeat and hands back commands waiting for it.
    public func heartbeat(_ payload: [String: Any]) -> [[String: Any]] {
        var list: [BridgeGateway] = []
        for item in payload["gateways"] as? [[String: Any]] ?? [] {
            guard let id = item["id"] as? String, !id.isEmpty, let baseURL = item["base_url"] as? String else {
                continue
            }
            var info = item
            info["token"] = nil
            let infoData = (try? JSONSerialization.data(withJSONObject: info)) ?? Data("{}".utf8)
            let token = (item["token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            list.append(
                BridgeGateway(
                    id: id, name: item["name"] as? String ?? id, kind: item["kind"] as? String ?? "direct",
                    enabled: JSONSupport.boolValue(item["enabled"]) ?? true, baseURL: baseURL, token: token,
                    infoJSON: infoData))
        }
        lock.lock()
        defer { lock.unlock() }
        lastHeartbeat = Date()
        appInfo = (payload["app"] as? [String: Any]) ?? [:]
        gateways = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
        gatewayOrder = list.map(\.id)
        var pending: [[String: Any]] = []
        for id in commandOrder {
            guard var command = commands[id], command.status == "queued" else { continue }
            command.status = "dispatched"
            command.updatedAt = Date()
            commands[id] = command
            var object: [String: Any] = ["id": command.id, "type": command.type]
            object["payload"] = (try? JSONSerialization.jsonObject(with: command.payloadJSON)) ?? [:]
            pending.append(object)
        }
        // Commands nobody picked up in two minutes fail instead of lingering.
        for id in commandOrder {
            guard var command = commands[id], command.status == "dispatched",
                Date().timeIntervalSince(command.updatedAt) > 120
            else { continue }
            command.status = "failed"
            command.message = "the app did not report a result"
            commands[id] = command
        }
        return pending
    }

    public func enqueue(type: String, payload: [String: Any]) throws -> BridgeCommand {
        guard Self.commandTypes.contains(type) else {
            throw ControllerError.usage("unknown command type: \(type)")
        }
        let data = try JSONSerialization.data(withJSONObject: payload)
        let command = BridgeCommand(
            id: UUID().uuidString, type: type, payloadJSON: data, createdAt: Date(), updatedAt: Date())
        lock.lock()
        defer { lock.unlock() }
        commands[command.id] = command
        commandOrder.append(command.id)
        if commandOrder.count > 200 {
            let dropped = commandOrder.removeFirst()
            commands[dropped] = nil
        }
        return command
    }

    public func complete(id: String, ok: Bool, message: String?, result: Any?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard var command = commands[id] else { return false }
        command.status = ok ? "done" : "failed"
        command.message = message
        if let result, JSONSerialization.isValidJSONObject(result) {
            command.resultJSON = try? JSONSerialization.data(withJSONObject: result)
        }
        command.updatedAt = Date()
        commands[id] = command
        return true
    }

    public func command(id: String) -> BridgeCommand? {
        lock.lock()
        defer { lock.unlock() }
        return commands[id]
    }

    public func gateway(id: String) -> BridgeGateway? {
        lock.lock()
        defer { lock.unlock() }
        return gateways[id]
    }

    /// Bridge state for the dashboard (no tokens).
    public func publicState() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        let connected = lastHeartbeat.map { Date().timeIntervalSince($0) < 15 } ?? false
        let list: [[String: Any]] = gatewayOrder.compactMap { id in
            guard let gateway = gateways[id] else { return nil }
            var info = (try? JSONSerialization.jsonObject(with: gateway.infoJSON) as? [String: Any]) ?? [:]
            info["id"] = gateway.id
            info["name"] = gateway.name
            info["kind"] = gateway.kind
            info["enabled"] = gateway.enabled
            info["has_token"] = gateway.token != nil
            return info
        }
        var state: [String: Any] = [
            "app_connected": connected,
            "gateways": connected ? list : [],
            "app": appInfo,
        ]
        if let lastHeartbeat { state["last_heartbeat"] = lastHeartbeat.timeIntervalSince1970 }
        return state
    }
}

extension ControllerRouter {
    /// Allowed remote-agent paths for the dashboard proxy.
    static let remoteProxyAllowed: [(String, String)] = [
        ("GET", "/api/status"), ("GET", "/api/host/metrics"), ("GET", "/api/doctor"),
        ("GET", "/api/benchmark/status"), ("GET", "/api/integrations"), ("GET", "/api/usage/overview"),
        ("GET", "/api/usage/summary"), ("GET", "/api/usage/timeseries"), ("GET", "/api/usage/models"),
        ("GET", "/api/usage/clients"), ("GET", "/api/usage/requests"), ("GET", "/api/usage/live"),
        ("GET", "/api/usage/settings"), ("GET", "/api/version"), ("GET", "/api/ollama/status"),
        ("POST", "/api/start"), ("POST", "/api/stop"), ("POST", "/api/restart"), ("POST", "/api/switch"),
        ("POST", "/api/stop-all"), ("POST", "/api/benchmark/start"), ("POST", "/api/usage/clients/rename"),
        ("GET", "/api/usage/export.csv"),
    ]

    /// `/api/remote/<gateway>/<agent path>` -> the remote agent, with the app-supplied token.
    func remoteProxy(_ request: ControllerHTTPRequest) throws -> ControllerHTTPResponse {
        let rest = request.path.dropFirst("/api/remote/".count)
        guard let slash = rest.firstIndex(of: "/") else {
            return try error(status: 404, code: "not_found", message: "not found")
        }
        let gatewayID = String(rest[..<slash])
        let agentPath = String(rest[slash...])
        guard Self.remoteProxyAllowed.contains(where: { $0.0 == request.method && $0.1 == agentPath }) else {
            return try error(status: 404, code: "not_found", message: "remote route not available")
        }
        guard bridge.appConnected, let gateway = bridge.gateway(id: gatewayID) else {
            return try error(
                status: 503, code: "app_not_connected",
                message: "open the ModelMatrix menu bar app to reach remote hosts")
        }
        let query = URLComponents(string: request.target)?.percentEncodedQuery.map { "?" + $0 } ?? ""
        var base = gateway.baseURL
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + agentPath + query) else {
            return try error(status: 400, code: "invalid_gateway", message: "invalid remote address")
        }
        let isAction = request.method == "POST"
        var outgoing = URLRequest(url: url, timeoutInterval: isAction ? 120 : 20)
        outgoing.httpMethod = request.method
        outgoing.setValue("application/json", forHTTPHeaderField: "Content-Type")
        outgoing.setValue("ModelMatrix-Controller", forHTTPHeaderField: "User-Agent")
        if let token = gateway.token { outgoing.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if isAction { outgoing.httpBody = request.body.isEmpty ? Data("{}".utf8) : request.body }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: (Data?, HTTPURLResponse?, Error?) = (nil, nil, nil)
        session.dataTask(with: outgoing) { data, response, failure in
            result = (data, response as? HTTPURLResponse, failure)
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + (isAction ? 125 : 25))
        guard let response = result.1 else {
            return try error(
                status: 502, code: "remote_unreachable",
                message: "could not reach \(gateway.name): \(result.2?.localizedDescription ?? "timed out")")
        }
        let type = response.value(forHTTPHeaderField: "Content-Type") ?? "application/json"
        return ControllerHTTPResponse(status: response.statusCode, headers: ["Content-Type": type], body: result.0 ?? Data())
    }
}

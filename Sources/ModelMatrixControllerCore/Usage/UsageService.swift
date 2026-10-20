import Foundation
import ModelMatrixCore

/// Owns the metering relay, the usage database and the live request list.
public final class UsageService: @unchecked Sendable {
    public static let defaultRelayPort: UInt16 = 7701
    public let store: UsageStore
    public let relayPort: UInt16
    public private(set) var relay: MeteringRelay?
    weak var service: ControllerService?
    /// New authenticated routes are opt-in; legacy /v1 routing is unchanged.
    weak var clientConnections: ClientConnectionService?
    weak var connectionBridge: BridgeState?

    let lock = NSLock()
    var inflight: [String: [String: Any]] = [:]
    var targetsCache: [RelayTarget] = []
    var targetsUpdatedAt = Date.distantPast
    var refreshingTargets = false
    var lastTrafficAt = Date.distantPast
    var ollamaModels: [String] = []
    var ollamaTags: [[String: Any]] = []
    var ollamaReachable = false
    var ollamaCheckedAt = Date.distantPast
    var captureRelays: [String: MeteringRelay] = [:]
    var maintenanceTimer: DispatchSourceTimer?
    let maintenanceQueue = DispatchQueue(label: "io.github.hackstar1337.modelmatrix.usage.maintenance")
    public var ollamaBaseURL = URL(string: "http://127.0.0.1:11434")!

    public init(store: UsageStore, relayPort: UInt16 = UsageService.defaultRelayPort, service: ControllerService?) {
        self.store = store
        self.relayPort = relayPort
        self.service = service
    }

    public static func open(configuration: ControllerConfiguration, service: ControllerService) throws
        -> UsageService
    {
        let url = configuration.root.appendingPathComponent("usage", isDirectory: true)
            .appendingPathComponent("usage.sqlite3")
        let store = try UsageStore(url: url)
        let environment = ProcessInfo.processInfo.environment
        let port = environment["MODELMATRIX_RELAY_PORT"].flatMap(UInt16.init) ?? defaultRelayPort
        return UsageService(store: store, relayPort: port, service: service)
    }

    public static func captureEnabled(_ profile: ControllerProfile) -> Bool {
        EnvFlag.isEnabled(profile["CAPTURE_MODE"]) && captureSupported(profile)
    }

    /// Capture needs a runtime that ModelMatrix launches on `PORT`.
    public static func captureSupported(_ profile: ControllerProfile) -> Bool {
        guard let port = profile["PORT"], UInt16(port) != nil else { return false }
        let mode = profile.runtimeSpec.launchMode
        return mode != "external" && profile.runtime != "ollama"
    }

    public var relayURL: String { "http://127.0.0.1:\(relayPort)/v1" }

    // MARK: - Lifecycle

    public func start() {
        if EnvFlag.isEnabled(ProcessInfo.processInfo.environment["MODELMATRIX_RELAY_DISABLED"]) { return }
        let relay = MeteringRelay(port: relayPort, usage: self)
        do {
            try relay.start()
            self.relay = relay
        } catch {
            FileHandle.standardError.write(Data("relay start failed: \(error)\n".utf8))
        }
        let timer = DispatchSource.makeTimerSource(queue: maintenanceQueue)
        timer.schedule(deadline: .now() + 2, repeating: 5)
        timer.setEventHandler { [weak self] in self?.maintenanceTick() }
        timer.resume()
        maintenanceTimer = timer
    }

    public func stop() {
        relay?.stop()
        relay = nil
        maintenanceTimer?.cancel()
        lock.lock()
        let captured = captureRelays
        captureRelays = [:]
        lock.unlock()
        captured.values.forEach { $0.stop() }
    }

    var tickCount = 0

    func maintenanceTick() {
        tickCount += 1
        syncCaptureListeners()
        if Date().timeIntervalSince(lastTrafficAt) < 120 { refreshTargets() }
        if tickCount % 720 == 1 {  // about hourly
            store.prune(olderThanDays: retentionDays)
        }
    }

    public var retentionDays: Int {
        Int(store.setting("retention_days") ?? "") ?? 30
    }

    // MARK: - Routing table

    /// Current model servers. Refreshed in the background so requests never wait on health probes.
    public func relayTargets() -> [RelayTarget] {
        lock.lock()
        lastTrafficAt = Date()
        let cached = targetsCache
        let age = Date().timeIntervalSince(targetsUpdatedAt)
        lock.unlock()
        if cached.isEmpty || age > 30 {
            refreshTargets()
            lock.lock()
            defer { lock.unlock() }
            return targetsCache
        }
        if age > 4 {
            maintenanceQueue.async { [weak self] in self?.refreshTargets() }
        }
        return cached
    }

    func refreshTargets() {
        lock.lock()
        if refreshingTargets {
            lock.unlock()
            return
        }
        refreshingTargets = true
        lock.unlock()
        defer {
            lock.lock()
            refreshingTargets = false
            lock.unlock()
        }
        var targets: [RelayTarget] = []
        if let service, let payload = try? service.statusPayload() {
            let loaded = (try? service.profiles.load()) ?? [:]
            let active = (try? String(contentsOf: service.configuration.activeProfileFile, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            for status in payload.statuses {
                if let target = RelayTarget.from(status: status, profile: loaded[status.profile], activeProfile: active) {
                    targets.append(target)
                }
            }
        }
        refreshOllama()
        lock.lock()
        let ollamaUp = ollamaReachable
        let ollamaTags = ollamaModels
        lock.unlock()
        if ollamaUp {
            let port = UInt16(ollamaBaseURL.port ?? 11434)
            let covered = targets.contains { $0.isOllama && $0.port == port }
            if covered {
                for index in targets.indices where targets[index].isOllama && targets[index].port == port {
                    targets[index].models = Array(Set(targets[index].models + ollamaTags.map { $0.lowercased() }))
                }
            } else {
                targets.append(
                    RelayTarget(
                        profile: nil, displayName: "Ollama", runtime: "ollama", host: "127.0.0.1", port: port,
                        basePath: "/v1", models: ollamaTags, ready: true, running: true))
            }
        }
        lock.lock()
        targetsCache = targets
        targetsUpdatedAt = Date()
        lock.unlock()
    }

    // MARK: - Ollama

    func refreshOllama(force: Bool = false) {
        lock.lock()
        let fresh = Date().timeIntervalSince(ollamaCheckedAt) < 15
        lock.unlock()
        if fresh && !force { return }
        let tags = Self.fetchJSON(ollamaBaseURL.appendingPathComponent("api/tags"), timeout: 1.5)
        let entries = (tags?["models"] as? [[String: Any]]) ?? []
        let names = entries.compactMap { $0["name"] as? String ?? $0["model"] as? String }
        lock.lock()
        ollamaReachable = tags != nil
        ollamaModels = names
        ollamaTags = entries
        ollamaCheckedAt = Date()
        lock.unlock()
    }

    /// Ollama's loaded models (`/api/ps`) plus installed tags, for the dashboard.
    public func ollamaStatus() -> [String: Any] {
        let ps = Self.fetchJSON(ollamaBaseURL.appendingPathComponent("api/ps"), timeout: 1.5)
        let version = Self.fetchJSON(ollamaBaseURL.appendingPathComponent("api/version"), timeout: 1.5)
        refreshOllama(force: true)
        lock.lock()
        let reachable = ollamaReachable
        let installed = ollamaTags.map { entry -> [String: Any] in
            var item: [String: Any] = ["name": entry["name"] as? String ?? entry["model"] as? String ?? ""]
            if let size = entry["size"] { item["size"] = size }
            if let details = entry["details"] as? [String: Any] { item["details"] = details }
            if let modified = entry["modified_at"] { item["modified_at"] = modified }
            return item
        }
        lock.unlock()
        var result: [String: Any] = [
            "reachable": reachable || ps != nil,
            "base_url": ollamaBaseURL.absoluteString,
            "installed": installed,
            "loaded": (ps?["models"] as? [[String: Any]]) ?? [],
        ]
        if let value = version?["version"] as? String { result["version"] = value }
        return result
    }

    static func fetchJSON(_ url: URL, timeout: TimeInterval) -> [String: Any]? {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("ModelMatrix", forHTTPHeaderField: "User-Agent")
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var output: [String: Any]?
        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            if let data, (response as? HTTPURLResponse)?.statusCode == 200 {
                output = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
            semaphore.signal()
        }
        task.resume()
        if semaphore.wait(timeout: .now() + timeout + 0.5) == .timedOut {
            task.cancel()
            return nil
        }
        return output
    }

    /// `/v1/models` answered by the relay itself: every model a running server offers.
    func relayModelList() -> [String: Any] {
        var seen = Set<String>()
        var data: [[String: Any]] = []
        for target in relayTargets() where target.ready {
            for model in target.models.sorted() where !seen.contains(model) {
                seen.insert(model)
                data.append(["id": model, "object": "model", "owned_by": target.profile ?? target.displayName])
            }
        }
        return ["object": "list", "data": data]
    }

    // MARK: - Capture listeners

    func syncCaptureListeners() {
        guard let service, let loaded = try? service.profiles.load() else { return }
        let wanted = loaded.values.filter { Self.captureEnabled($0) }
        var wantedPorts: [String: (UInt16, ControllerProfile)] = [:]
        for profile in wanted {
            if let port = UInt16(profile["PORT"] ?? ""), port != relayPort {
                wantedPorts[profile.name] = (port, profile)
            }
        }
        lock.lock()
        var current = captureRelays
        lock.unlock()
        for (name, relay) in current where wantedPorts[name]?.0 != relay.port || !relay.isListening && relay.lastError != nil {
            relay.stop()
            current[name] = nil
        }
        for (name, entry) in wantedPorts where current[name] == nil {
            let profileName = name
            let relay = MeteringRelay(port: entry.0, usage: self) { [weak self] in
                self?.relayTargets().first { $0.profile == profileName }
            }
            do {
                try relay.start()
                current[name] = relay
            } catch {
                FileHandle.standardError.write(Data("capture relay for \(name) failed: \(error)\n".utf8))
            }
        }
        lock.lock()
        captureRelays = current
        lock.unlock()
    }

    public func captureState() -> [[String: Any]] {
        guard let service, let loaded = try? service.profiles.load() else { return [] }
        lock.lock()
        let current = captureRelays
        lock.unlock()
        return loaded.values.sorted { $0.name < $1.name }.map { profile in
            let enabled = Self.captureEnabled(profile)
            var item: [String: Any] = [
                "profile": profile.name,
                "display_name": profile.displayName,
                "supported": Self.captureSupported(profile),
                "enabled": enabled,
            ]
            if let port = UInt16(profile["PORT"] ?? "") {
                item["port"] = Int(port)
                if enabled { item["internal_port"] = Int(RelayTarget.capturePort(for: port)) }
            }
            if enabled {
                let relay = current[profile.name]
                item["listening"] = relay?.isListening ?? false
                if let error = relay?.lastError { item["error"] = error }
            }
            return item
        }
    }

    // MARK: - In-flight requests

    func beginInflight(_ record: UsageRecord) -> String {
        let id = UUID().uuidString
        var item: [String: Any] = [
            "id": id, "started_at": record.startedAt, "endpoint": record.endpoint,
            "client_label": record.clientLabel, "client_id": record.clientID, "stream": record.stream,
            "host": record.host, "chunks": 0,
        ]
        item["model"] = record.modelRequested
        item["profile"] = record.profile
        item["runtime"] = record.runtime
        item["tier"] = record.tier
        item["client_process"] = record.clientProcess
        lock.lock()
        inflight[id] = item
        lock.unlock()
        return id
    }

    func updateInflight(_ id: String, chunks: Int, firstTokenAt: Double?) {
        lock.lock()
        inflight[id]?["chunks"] = chunks
        if let firstTokenAt { inflight[id]?["first_token_at"] = firstTokenAt }
        lock.unlock()
    }

    func endInflight(_ id: String?) {
        guard let id else { return }
        lock.lock()
        inflight[id] = nil
        lock.unlock()
    }

    public func inflightSnapshot() -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return inflight.values.sorted {
            ($0["started_at"] as? Double ?? 0) > ($1["started_at"] as? Double ?? 0)
        }
    }

    func record(_ record: UsageRecord) {
        store.insert(record)
    }

    // MARK: - Status

    public func relayStatus() -> [String: Any] {
        var status: [String: Any] = [
            "enabled": relay != nil,
            "listening": relay?.isListening ?? false,
            "port": Int(relayPort),
            "url": relayURL,
            "ollama_url": "http://127.0.0.1:\(relayPort)",
            "retention_days": retentionDays,
            "requests_recorded": store.count(),
            "database": store.url.path,
        ]
        if let error = relay?.lastError { status["error"] = error }
        return status
    }
}

import Foundation

/// Something Optimize can free.
public struct OptimizeItem: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case ollamaModel = "ollama_model"
        case modelServer = "model_server"
        case fileCache = "file_cache"
    }

    public var id: String
    public var kind: Kind
    public var title: String
    public var detail: String
    public var bytes: UInt64
    /// Serving a request now, or answered one in the last minute.
    public var inUse: Bool
    public var lastUsedAt: Double?
    public var recommended: Bool
    public var maximum: Bool
    public var needsPassword: Bool { kind == .fileCache }

    public var json: [String: Any] {
        var value: [String: Any] = [
            "id": id, "kind": kind.rawValue, "title": title, "detail": detail, "bytes": bytes,
            "in_use": inUse, "needs_password": needsPassword,
            "presets": [recommended ? "recommended" : nil, maximum ? "maximum" : nil].compactMap { $0 },
        ]
        if let lastUsedAt { value["last_used_at"] = lastUsedAt }
        return value
    }
}

/// What is in memory right now, gathered by the controller.
public struct OptimizeInputs: Sendable {
    public struct OllamaModel: Sendable {
        public var name: String
        public var bytes: UInt64
        public init(name: String, bytes: UInt64) {
            self.name = name
            self.bytes = bytes
        }
    }

    public struct Server: Sendable {
        public var profile: String
        public var displayName: String
        public var runtimeLabel: String
        public var pid: Int32
        public var bytes: UInt64
        public var startedAt: Double?
        public init(
            profile: String, displayName: String, runtimeLabel: String, pid: Int32, bytes: UInt64,
            startedAt: Double?
        ) {
            self.profile = profile
            self.displayName = displayName
            self.runtimeLabel = runtimeLabel
            self.pid = pid
            self.bytes = bytes
            self.startedAt = startedAt
        }
    }

    public var ollamaModels: [OllamaModel] = []
    public var servers: [Server] = []
    public var cachedBytes: UInt64 = 0
    /// Last request seen by the relay, keyed `profile:<name>` and `model:<name>`.
    public var lastUsed: [String: Double] = [:]
    public var inflightProfiles: Set<String> = []
    public var inflightModels: Set<String> = []
    public var now: Double = Date().timeIntervalSince1970

    public init() {}
}

public enum OptimizePlanner {
    /// A request this recent counts as "in use".
    public static let inUseSeconds: Double = 60
    /// Recommended stops model servers idle at least this long.
    public static let idleSeconds: Double = 15 * 60
    public static let fileCacheID = "system:file-cache"

    public static func items(_ inputs: OptimizeInputs) -> [OptimizeItem] {
        var items: [OptimizeItem] = []
        for model in inputs.ollamaModels.sorted(by: { $0.bytes > $1.bytes }) {
            let last = lastUsed(model: model.name, in: inputs.lastUsed)
            let inUse = inputs.inflightModels.contains { sameModel($0, model.name) }
                || recent(last, inputs.now)
            items.append(
                OptimizeItem(
                    id: "ollama:\(model.name)", kind: .ollamaModel, title: model.name,
                    detail: "Ollama model. Unloads now; Ollama loads it again on the next request.",
                    bytes: model.bytes, inUse: inUse, lastUsedAt: last,
                    recommended: !inUse, maximum: !inUse))
        }
        for server in inputs.servers.sorted(by: { $0.bytes > $1.bytes }) {
            let last = inputs.lastUsed["profile:\(server.profile)"]
            let inUse = inputs.inflightProfiles.contains(server.profile) || recent(last, inputs.now)
            let idleSince = max(last ?? 0, server.startedAt ?? 0)
            let idle = !inUse && inputs.now - idleSince >= idleSeconds
            items.append(
                OptimizeItem(
                    id: "profile:\(server.profile)", kind: .modelServer, title: server.displayName,
                    detail: "\(server.runtimeLabel) model server (pid \(server.pid)). Stops it; start it again any time.",
                    bytes: server.bytes, inUse: inUse, lastUsedAt: last,
                    recommended: idle, maximum: !inUse))
        }
        items.append(
            OptimizeItem(
                id: fileCacheID, kind: .fileCache, title: "Clear file cache",
                detail: "Drops files macOS keeps cached in memory, including model files from stopped servers. macOS asks for your password.",
                bytes: inputs.cachedBytes, inUse: false, lastUsedAt: nil,
                recommended: false, maximum: true))
        return items
    }

    public static func preset(_ name: String, _ items: [OptimizeItem]) -> [String] {
        items.filter { name == "recommended" ? $0.recommended : $0.maximum }.map(\.id)
    }

    public static func estimate(_ ids: [String], _ items: [OptimizeItem]) -> UInt64 {
        let selected = Set(ids)
        return items.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.bytes }
    }

    /// Memory given back: the larger of the drop in Memory Used and the rise
    /// in free memory (clearing the file cache raises free memory without
    /// changing Memory Used).
    public static func freedBytes(before: MemorySnapshot, after: MemorySnapshot) -> UInt64 {
        let usedDrop = before.usedBytes > after.usedBytes ? before.usedBytes - after.usedBytes : 0
        let freeGain = after.freeBytes > before.freeBytes ? after.freeBytes - before.freeBytes : 0
        return max(usedDrop, freeGain)
    }

    static func recent(_ last: Double?, _ now: Double) -> Bool {
        guard let last else { return false }
        return now - last < inUseSeconds
    }

    /// Ollama treats `name` and `name:latest` as the same model.
    public static func sameModel(_ lhs: String, _ rhs: String) -> Bool {
        func normalized(_ value: String) -> String {
            let lower = value.lowercased()
            return lower.hasSuffix(":latest") ? String(lower.dropLast(7)) : lower
        }
        return normalized(lhs) == normalized(rhs)
    }

    static func lastUsed(model: String, in table: [String: Double]) -> Double? {
        table.compactMap { key, value -> Double? in
            guard key.hasPrefix("model:"), sameModel(String(key.dropFirst(6)), model) else { return nil }
            return value
        }.max()
    }
}

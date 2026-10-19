import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// One metered request, as recorded by the relay.
public struct UsageRecord: Sendable, Equatable {
    public var id: Int64 = 0
    public var startedAt: Double
    public var durationMS: Double?
    public var ttftMS: Double?
    public var host: String = "local"
    public var profile: String?
    public var runtime: String?
    public var endpoint: String
    public var method: String = "POST"
    public var modelRequested: String?
    public var modelServed: String?
    public var clientID: String = "unknown"
    public var clientLabel: String = "Unknown client"
    public var clientProcess: String?
    public var status: Int = 0
    public var stream: Bool = false
    public var promptTokens: Int?
    public var completionTokens: Int?
    public var tokensEstimated: Bool = false
    public var tokensPerSecond: Double?
    public var error: String?
    public var tier: String = "local"

    public init(startedAt: Double, endpoint: String) {
        self.startedAt = startedAt
        self.endpoint = endpoint
    }

    public var object: [String: Any] {
        var value: [String: Any] = [
            "id": id, "started_at": startedAt, "host": host, "endpoint": endpoint,
            "method": method, "client_id": clientID, "client_label": clientLabel,
            "status": status, "stream": stream, "tokens_estimated": tokensEstimated, "tier": tier,
        ]
        value["duration_ms"] = durationMS
        value["ttft_ms"] = ttftMS
        value["profile"] = profile
        value["runtime"] = runtime
        value["model_requested"] = modelRequested
        value["model_served"] = modelServed
        value["model"] = modelServed ?? modelRequested
        value["client_process"] = clientProcess
        value["prompt_tokens"] = promptTokens
        value["completion_tokens"] = completionTokens
        value["tokens_per_second"] = tokensPerSecond
        value["error"] = error
        return value
    }
}

/// SQLite storage for metered requests. All access is serialized by `lock`.
public final class UsageStore: @unchecked Sendable {
    public let url: URL
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()

    public init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            throw ControllerError.operationFailed("usage database: \(message)")
        }
        db = handle
        sqlite3_busy_timeout(handle, 3000)
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=NORMAL")
        try execute(
            """
            CREATE TABLE IF NOT EXISTS requests (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              started_at REAL NOT NULL,
              duration_ms REAL, ttft_ms REAL,
              host TEXT NOT NULL DEFAULT 'local',
              profile TEXT, runtime TEXT, endpoint TEXT, method TEXT,
              model_requested TEXT, model_served TEXT,
              client_id TEXT, client_label TEXT, client_process TEXT,
              status INTEGER, stream INTEGER,
              prompt_tokens INTEGER, completion_tokens INTEGER,
              tokens_estimated INTEGER DEFAULT 0,
              tokens_per_second REAL, error TEXT,
              tier TEXT DEFAULT 'local'
            )
            """)
        try execute("CREATE INDEX IF NOT EXISTS idx_requests_started ON requests(started_at)")
        try execute("CREATE INDEX IF NOT EXISTS idx_requests_client ON requests(client_id)")
        try execute(
            "CREATE TABLE IF NOT EXISTS client_names (client_id TEXT PRIMARY KEY, name TEXT NOT NULL)")
        try execute("CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT)")
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Low level

    func execute(_ sql: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &message) == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? "sqlite error"
            sqlite3_free(message)
            throw ControllerError.operationFailed("usage database: \(text)")
        }
    }

    enum Value {
        case text(String?)
        case double(Double?)
        case int(Int64?)
    }

    func bind(_ statement: OpaquePointer?, _ values: [Value]) {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .text(let text):
                if let text { sqlite3_bind_text(statement, index, text, -1, sqliteTransient) } else {
                    sqlite3_bind_null(statement, index)
                }
            case .double(let double):
                if let double, double.isFinite { sqlite3_bind_double(statement, index, double) } else {
                    sqlite3_bind_null(statement, index)
                }
            case .int(let int):
                if let int { sqlite3_bind_int64(statement, index, int) } else {
                    sqlite3_bind_null(statement, index)
                }
            }
        }
    }

    /// Runs a query and returns rows as dictionaries keyed by column name.
    func query(_ sql: String, _ values: [Value] = []) -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            fputs("[usage] prepare failed: \(String(cString: sqlite3_errmsg(db))) for \(sql)\n", stderr)
            return []
        }
        defer { sqlite3_finalize(statement) }
        bind(statement, values)
        var rows: [[String: Any]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var row: [String: Any] = [:]
            for column in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, column))
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: row[name] = sqlite3_column_int64(statement, column)
                case SQLITE_FLOAT: row[name] = sqlite3_column_double(statement, column)
                case SQLITE_TEXT: row[name] = String(cString: sqlite3_column_text(statement, column))
                default: row[name] = NSNull()
                }
            }
            rows.append(row)
        }
        return rows
    }

    @discardableResult
    func run(_ sql: String, _ values: [Value] = []) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            fputs("[usage] prepare failed: \(String(cString: sqlite3_errmsg(db)))\n", stderr)
            return false
        }
        defer { sqlite3_finalize(statement) }
        bind(statement, values)
        return sqlite3_step(statement) == SQLITE_DONE
    }

    // MARK: - Writes

    @discardableResult
    public func insert(_ record: UsageRecord) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        let ok = run(
            """
            INSERT INTO requests (started_at, duration_ms, ttft_ms, host, profile, runtime, endpoint,
              method, model_requested, model_served, client_id, client_label, client_process, status,
              stream, prompt_tokens, completion_tokens, tokens_estimated, tokens_per_second, error, tier)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """,
            [
                .double(record.startedAt), .double(record.durationMS), .double(record.ttftMS),
                .text(record.host), .text(record.profile), .text(record.runtime),
                .text(record.endpoint), .text(record.method), .text(record.modelRequested),
                .text(record.modelServed), .text(record.clientID), .text(record.clientLabel),
                .text(record.clientProcess), .int(Int64(record.status)), .int(record.stream ? 1 : 0),
                .int(record.promptTokens.map(Int64.init)), .int(record.completionTokens.map(Int64.init)),
                .int(record.tokensEstimated ? 1 : 0), .double(record.tokensPerSecond),
                .text(record.error), .text(record.tier),
            ])
        return ok ? sqlite3_last_insert_rowid(db) : 0
    }

    public func setting(_ key: String) -> String? {
        query("SELECT value FROM settings WHERE key = ?", [.text(key)]).first?["value"] as? String
    }

    public func setSetting(_ key: String, _ value: String) {
        run(
            "INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            [.text(key), .text(value)])
    }

    public func renameClient(_ clientID: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            run("DELETE FROM client_names WHERE client_id = ?", [.text(clientID)])
        } else {
            run(
                "INSERT INTO client_names (client_id, name) VALUES (?, ?) ON CONFLICT(client_id) DO UPDATE SET name = excluded.name",
                [.text(clientID), .text(String(trimmed.prefix(80)))])
        }
    }

    public func prune(olderThanDays days: Int) {
        guard days > 0 else { return }
        let cutoff = Date().timeIntervalSince1970 - Double(days) * 86_400
        run("DELETE FROM requests WHERE started_at < ?", [.double(cutoff)])
    }

    public func reset() {
        run("DELETE FROM requests")
    }

    public func count() -> Int {
        (query("SELECT COUNT(*) AS n FROM requests").first?["n"] as? Int64).map(Int.init) ?? 0
    }
}

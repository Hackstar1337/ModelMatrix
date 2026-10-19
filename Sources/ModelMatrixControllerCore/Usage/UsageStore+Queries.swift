import Foundation

/// Time range and filters shared by every usage query.
public struct UsageFilter: Sendable, Equatable {
    public var range: String = "24h"
    public var host: String = "all"
    public var tier: String = "all"
    public var now: Double = Date().timeIntervalSince1970

    public init(range: String = "24h", host: String = "all", tier: String = "all", now: Double? = nil) {
        self.range = UsageFilter.ranges.keys.contains(range) ? range : "24h"
        self.host = host.isEmpty ? "all" : host
        self.tier = ["local", "cloud"].contains(tier) ? tier : "all"
        if let now { self.now = now }
    }

    /// range -> (seconds, bucket seconds)
    static let ranges: [String: (Double, Double)] = [
        "1h": (3_600, 120),
        "24h": (86_400, 3_600),
        "7d": (604_800, 21_600),
        "30d": (2_592_000, 86_400),
        "all": (315_360_000, 2_592_000),
    ]

    public var seconds: Double { Self.ranges[range]?.0 ?? 86_400 }
    public var bucketSeconds: Double { Self.ranges[range]?.1 ?? 3_600 }
    public var since: Double { now - seconds }

    /// SQL WHERE clause (without the keyword) plus bound values.
    func clause(prefix: String = "") -> (String, [UsageStore.Value]) {
        var parts = ["\(prefix)started_at >= ?"]
        var values: [UsageStore.Value] = [.double(since)]
        if host != "all" {
            parts.append("\(prefix)host = ?")
            values.append(.text(host))
        }
        if tier != "all" {
            parts.append("\(prefix)tier = ?")
            values.append(.text(tier))
        }
        return (parts.joined(separator: " AND "), values)
    }
}

extension UsageStore {
    static func double(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int64 { return Double(value) }
        return nil
    }

    static func int(_ value: Any?) -> Int {
        if let value = value as? Int64 { return Int(value) }
        if let value = value as? Double { return Int(value) }
        return 0
    }

    public func summary(_ filter: UsageFilter) -> [String: Any] {
        let (whereSQL, values) = filter.clause()
        let row =
            query(
                """
                SELECT COUNT(*) AS requests,
                  COALESCE(SUM(prompt_tokens),0) AS prompt_tokens,
                  COALESCE(SUM(completion_tokens),0) AS completion_tokens,
                  AVG(tokens_per_second) AS avg_tps,
                  AVG(ttft_ms) AS avg_ttft_ms,
                  AVG(duration_ms) AS avg_duration_ms,
                  SUM(CASE WHEN status >= 400 OR status = 0 THEN 1 ELSE 0 END) AS errors,
                  SUM(CASE WHEN tier = 'cloud' THEN 1 ELSE 0 END) AS cloud_requests,
                  SUM(CASE WHEN tier != 'cloud' THEN 1 ELSE 0 END) AS local_requests,
                  COALESCE(SUM(CASE WHEN tier = 'cloud' THEN completion_tokens END),0) AS cloud_completion_tokens,
                  COALESCE(SUM(CASE WHEN tier != 'cloud' THEN completion_tokens END),0) AS local_completion_tokens,
                  COALESCE(SUM(duration_ms),0) AS inference_ms,
                  SUM(tokens_estimated) AS estimated_rows,
                  COUNT(DISTINCT client_id) AS clients,
                  COUNT(DISTINCT COALESCE(model_served, model_requested)) AS models
                FROM requests WHERE \(whereSQL)
                """, values
            ).first ?? [:]
        let requests = Self.int(row["requests"])
        let ttfts = query(
            "SELECT ttft_ms FROM requests WHERE \(whereSQL) AND ttft_ms IS NOT NULL ORDER BY ttft_ms",
            values
        ).compactMap { Self.double($0["ttft_ms"]) }
        let tpsValues = query(
            "SELECT tokens_per_second FROM requests WHERE \(whereSQL) AND tokens_per_second IS NOT NULL ORDER BY tokens_per_second",
            values
        ).compactMap { Self.double($0["tokens_per_second"]) }
        // Previous period of equal length, for the trend arrows.
        var previous = filter
        previous.now = filter.since
        let (previousSQL, previousValues) = previous.clause()
        let previousRow =
            query(
                """
                SELECT COUNT(*) AS requests,
                  COALESCE(SUM(prompt_tokens),0) + COALESCE(SUM(completion_tokens),0) AS tokens,
                  AVG(tokens_per_second) AS avg_tps, AVG(ttft_ms) AS avg_ttft_ms
                FROM requests WHERE \(previousSQL) AND started_at < ?
                """, previousValues + [.double(filter.since)]
            ).first ?? [:]
        var result: [String: Any] = [
            "range": filter.range,
            "requests": requests,
            "prompt_tokens": Self.int(row["prompt_tokens"]),
            "completion_tokens": Self.int(row["completion_tokens"]),
            "total_tokens": Self.int(row["prompt_tokens"]) + Self.int(row["completion_tokens"]),
            "errors": Self.int(row["errors"]),
            "local_requests": Self.int(row["local_requests"]),
            "cloud_requests": Self.int(row["cloud_requests"]),
            "local_completion_tokens": Self.int(row["local_completion_tokens"]),
            "cloud_completion_tokens": Self.int(row["cloud_completion_tokens"]),
            "inference_ms": Self.double(row["inference_ms"]) ?? 0,
            "estimated_rows": Self.int(row["estimated_rows"]),
            "clients": Self.int(row["clients"]),
            "models": Self.int(row["models"]),
            "previous": [
                "requests": Self.int(previousRow["requests"]),
                "tokens": Self.int(previousRow["tokens"]),
                "avg_tps": Self.double(previousRow["avg_tps"]).map { $0 as Any } ?? NSNull(),
                "avg_ttft_ms": Self.double(previousRow["avg_ttft_ms"]).map { $0 as Any } ?? NSNull(),
            ],
        ]
        result["avg_tps"] = Self.double(row["avg_tps"])
        result["avg_ttft_ms"] = Self.double(row["avg_ttft_ms"])
        result["avg_duration_ms"] = Self.double(row["avg_duration_ms"])
        result["p50_ttft_ms"] = Self.percentile(ttfts, 0.5)
        result["p95_ttft_ms"] = Self.percentile(ttfts, 0.95)
        result["p50_tps"] = Self.percentile(tpsValues, 0.5)
        result["peak_tps"] = tpsValues.last
        result["avg_prompt_tokens"] = requests > 0 ? Double(Self.int(row["prompt_tokens"])) / Double(requests) : 0
        return result
    }

    /// All-time totals and 24h/10m rates for the dashboard's top strip.
    public func totals(host: String = "all", tier: String = "all", now: Double = Date().timeIntervalSince1970)
        -> [String: Any]
    {
        var parts: [String] = []
        var values: [Value] = []
        if host != "all" {
            parts.append("host = ?")
            values.append(.text(host))
        }
        if ["local", "cloud"].contains(tier) {
            parts.append("tier = ?")
            values.append(.text(tier))
        }
        let whereSQL = parts.isEmpty ? "1=1" : parts.joined(separator: " AND ")
        let day = now - 86_400
        let tenMinutes = now - 600
        let row =
            query(
                """
                SELECT COUNT(*) AS requests,
                  COALESCE(SUM(prompt_tokens),0) + COALESCE(SUM(completion_tokens),0) AS tokens,
                  AVG(tokens_per_second) AS avg_tps,
                  COALESCE(SUM(duration_ms),0) AS inference_ms,
                  COUNT(DISTINCT client_id) AS clients,
                  SUM(CASE WHEN tier = 'cloud' THEN 1 ELSE 0 END) AS cloud_requests,
                  SUM(CASE WHEN tier != 'cloud' THEN 1 ELSE 0 END) AS local_requests,
                  SUM(CASE WHEN started_at >= ? THEN 1 ELSE 0 END) AS requests_24h,
                  COALESCE(SUM(CASE WHEN started_at >= ? THEN COALESCE(prompt_tokens,0) + COALESCE(completion_tokens,0) END),0) AS tokens_24h,
                  COUNT(DISTINCT CASE WHEN started_at >= ? THEN client_id END) AS active_clients,
                  SUM(CASE WHEN started_at >= ? THEN 1 ELSE 0 END) AS requests_10m,
                  MIN(started_at) AS first_request
                FROM requests WHERE \(whereSQL)
                """, [.double(day), .double(day), .double(day), .double(tenMinutes)] + values
            ).first ?? [:]
        var result: [String: Any] = [
            "requests": Self.int(row["requests"]),
            "tokens": Self.int(row["tokens"]),
            "inference_ms": Self.double(row["inference_ms"]) ?? 0,
            "clients": Self.int(row["clients"]),
            "local_requests": Self.int(row["local_requests"]),
            "cloud_requests": Self.int(row["cloud_requests"]),
            "requests_24h": Self.int(row["requests_24h"]),
            "tokens_24h": Self.int(row["tokens_24h"]),
            "active_clients": Self.int(row["active_clients"]),
            "requests_per_minute": Double(Self.int(row["requests_10m"])) / 10,
        ]
        result["avg_tps"] = Self.double(row["avg_tps"])
        result["first_request"] = Self.double(row["first_request"])
        return result
    }

    /// Last-hour stats per host and per profile (Fleet card footers).
    public func hostStats(now: Double = Date().timeIntervalSince1970) -> [[String: Any]] {
        query(
            """
            SELECT host, COUNT(*) AS requests, AVG(tokens_per_second) AS avg_tps, AVG(ttft_ms) AS avg_ttft_ms,
              MAX(started_at) AS last_request
            FROM requests WHERE started_at >= ? GROUP BY host
            """, [.double(now - 3_600)]
        ).map { row in row.filter { !($0.value is NSNull) } }
    }

    static func percentile(_ sorted: [Double], _ fraction: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * fraction).rounded())))
        return sorted[index]
    }

    /// Fixed-size buckets covering the whole range (empty buckets included).
    public func timeseries(_ filter: UsageFilter) -> [[String: Any]] {
        let (whereSQL, values) = filter.clause()
        let bucket = filter.bucketSeconds
        let start = (filter.since / bucket).rounded(.down) * bucket
        let rows = query(
            """
            SELECT CAST((started_at - ?) / ? AS INTEGER) AS slot,
              COUNT(*) AS requests,
              SUM(CASE WHEN tier = 'cloud' THEN 1 ELSE 0 END) AS cloud,
              SUM(CASE WHEN tier != 'cloud' THEN 1 ELSE 0 END) AS local,
              COALESCE(SUM(prompt_tokens),0) AS prompt_tokens,
              COALESCE(SUM(completion_tokens),0) AS completion_tokens,
              AVG(tokens_per_second) AS avg_tps, AVG(ttft_ms) AS avg_ttft_ms,
              SUM(CASE WHEN status >= 400 OR status = 0 THEN 1 ELSE 0 END) AS errors
            FROM requests WHERE \(whereSQL) GROUP BY slot ORDER BY slot
            """, [.double(start), .double(bucket)] + values)
        var bySlot: [Int: [String: Any]] = [:]
        for row in rows { bySlot[Self.int(row["slot"])] = row }
        let count = Int(((filter.now - start) / bucket).rounded(.up))
        return (0..<max(1, count)).map { slot in
            let row = bySlot[slot] ?? [:]
            var item: [String: Any] = [
                "t": start + Double(slot) * bucket,
                "requests": Self.int(row["requests"]),
                "local": Self.int(row["local"]),
                "cloud": Self.int(row["cloud"]),
                "prompt_tokens": Self.int(row["prompt_tokens"]),
                "completion_tokens": Self.int(row["completion_tokens"]),
                "errors": Self.int(row["errors"]),
            ]
            item["avg_tps"] = Self.double(row["avg_tps"])
            item["avg_ttft_ms"] = Self.double(row["avg_ttft_ms"])
            return item
        }
    }

    public func models(_ filter: UsageFilter) -> [[String: Any]] {
        let (whereSQL, values) = filter.clause()
        let rows = query(
            """
            SELECT COALESCE(model_served, model_requested, 'unknown') AS model,
              MAX(model_requested) AS alias, MAX(profile) AS profile, MAX(runtime) AS runtime,
              MAX(tier) AS tier, MAX(host) AS host,
              COUNT(*) AS requests,
              COALESCE(SUM(prompt_tokens),0) AS prompt_tokens,
              COALESCE(SUM(completion_tokens),0) AS completion_tokens,
              AVG(tokens_per_second) AS avg_tps, AVG(ttft_ms) AS avg_ttft_ms,
              MAX(started_at) AS last_used
            FROM requests WHERE \(whereSQL)
            GROUP BY COALESCE(model_served, model_requested, 'unknown')
            ORDER BY requests DESC LIMIT 50
            """, values)
        let total = max(1, rows.reduce(0) { $0 + Self.int($1["requests"]) })
        return rows.map { row in
            var item = row.filter { !($0.value is NSNull) }
            item["share"] = Double(Self.int(row["requests"])) / Double(total)
            return item
        }
    }

    public func clients(_ filter: UsageFilter) -> [[String: Any]] {
        let (whereSQL, values) = filter.clause(prefix: "r.")
        let rows = query(
            """
            SELECT r.client_id AS client_id,
              COALESCE(MAX(n.name), MAX(r.client_label)) AS name,
              MAX(r.client_label) AS detected, MAX(r.client_process) AS process,
              MAX(n.name) AS custom_name,
              COUNT(*) AS requests,
              COALESCE(SUM(r.prompt_tokens),0) + COALESCE(SUM(r.completion_tokens),0) AS tokens,
              AVG(r.tokens_per_second) AS avg_tps,
              MAX(r.started_at) AS last_seen, MIN(r.started_at) AS first_seen
            FROM requests r LEFT JOIN client_names n ON n.client_id = r.client_id
            WHERE \(whereSQL)
            GROUP BY r.client_id ORDER BY requests DESC LIMIT 100
            """, values)
        return rows.map { row in
            var item = row.filter { !($0.value is NSNull) }
            let id = row["client_id"] as? String ?? ""
            let top = query(
                """
                SELECT COALESCE(model_served, model_requested) AS model, COUNT(*) AS n FROM requests
                WHERE client_id = ? AND started_at >= ? GROUP BY model ORDER BY n DESC LIMIT 1
                """, [.text(id), .double(filter.since)]
            ).first?["model"]
            if let top = top as? String { item["top_model"] = top }
            return item
        }
    }

    public func recent(_ filter: UsageFilter, limit: Int = 50, offset: Int = 0, search: String? = nil,
                       sinceID: Int64? = nil) -> [[String: Any]] {
        var (whereSQL, values) = filter.clause(prefix: "r.")
        if let search, !search.isEmpty {
            whereSQL += " AND (r.model_served LIKE ? OR r.model_requested LIKE ? OR r.client_label LIKE ? OR n.name LIKE ? OR r.profile LIKE ?)"
            let pattern = "%\(search)%"
            values += Array(repeating: .text(pattern), count: 5)
        }
        if let sinceID {
            whereSQL += " AND r.id > ?"
            values.append(.int(sinceID))
        }
        let rows = query(
            """
            SELECT r.*, COALESCE(n.name, r.client_label) AS client_name
            FROM requests r LEFT JOIN client_names n ON n.client_id = r.client_id
            WHERE \(whereSQL) ORDER BY r.id DESC LIMIT ? OFFSET ?
            """, values + [.int(Int64(max(1, min(limit, 500)))), .int(Int64(max(0, offset)))])
        return rows.map { row in
            var item = row.filter { !($0.value is NSNull) }
            item["stream"] = Self.int(row["stream"]) == 1
            item["tokens_estimated"] = Self.int(row["tokens_estimated"]) == 1
            item["model"] = (row["model_served"] as? String) ?? (row["model_requested"] as? String)
            return item
        }
    }

    public func lastID() -> Int64 {
        (query("SELECT MAX(id) AS id FROM requests").first?["id"] as? Int64) ?? 0
    }

    public func hosts() -> [String] {
        query("SELECT DISTINCT host FROM requests ORDER BY host").compactMap { $0["host"] as? String }
    }

    /// CSV export of every request in the filter's range.
    public func csv(_ filter: UsageFilter) -> String {
        let columns = [
            "id", "started_at", "host", "profile", "runtime", "endpoint", "model_requested", "model_served",
            "client_name", "client_process", "status", "stream", "prompt_tokens", "completion_tokens",
            "tokens_estimated", "tokens_per_second", "ttft_ms", "duration_ms", "tier", "error",
        ]
        var lines = [columns.joined(separator: ",")]
        let rows = recent(filter, limit: 500, offset: 0)
        var offset = 0
        var batch = rows
        let formatter = ISO8601DateFormatter()
        while !batch.isEmpty {
            for row in batch {
                lines.append(
                    columns.map { column -> String in
                        var value: String
                        if column == "started_at", let time = Self.double(row[column]) {
                            value = formatter.string(from: Date(timeIntervalSince1970: time))
                        } else if let raw = row[column] {
                            value = "\(raw)"
                        } else {
                            value = ""
                        }
                        if value.contains(",") || value.contains("\"") || value.contains("\n") {
                            value = "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                        }
                        return value
                    }.joined(separator: ","))
            }
            offset += batch.count
            if batch.count < 500 || offset >= 100_000 { break }
            batch = recent(filter, limit: 500, offset: offset)
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

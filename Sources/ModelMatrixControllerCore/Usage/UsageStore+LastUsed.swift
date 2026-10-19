import Foundation

extension UsageStore {
    /// The most recent request per profile and per model on this Mac in the
    /// last day, keyed `profile:<name>` and `model:<name>`. Optimize uses it to
    /// leave models that are answering requests alone.
    public func lastUsed(now: Double = Date().timeIntervalSince1970) -> [String: Double] {
        var result: [String: Double] = [:]
        let since = now - 86_400
        let columns = [("profile", "profile"), ("model", "model_served"), ("model", "model_requested")]
        for (prefix, column) in columns {
            let rows = query(
                """
                SELECT \(column) AS name, MAX(started_at) AS at FROM requests
                WHERE host = 'local' AND started_at >= ? AND \(column) IS NOT NULL AND \(column) != ''
                GROUP BY \(column)
                """, [.double(since)])
            for row in rows {
                guard let name = row["name"] as? String, let at = Self.double(row["at"]) else { continue }
                let key = "\(prefix):\(name)"
                result[key] = max(result[key] ?? 0, at)
            }
        }
        return result
    }
}

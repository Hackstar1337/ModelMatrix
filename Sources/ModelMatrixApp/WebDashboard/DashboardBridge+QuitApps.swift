import Foundation

extension DashboardBridge {
    /// Runs a dashboard command, including ones that hand structured data back.
    func executeWithResult(type: String, payload: JSONRow) async throws -> (message: String, result: Any?) {
        if type == "app.quit_apps" { return try await quitApps(payload) }
        return (try await execute(type: type, payload: payload), nil)
    }

    /// Quits the apps picked in the dashboard's Optimize window, waits for
    /// them to close, and reports each one.
    func quitApps(_ payload: JSONRow) async throws -> (message: String, result: Any?) {
        let targets = payload.rows("apps").map { (path: $0.string("path"), name: $0.string("name")) }
        guard !targets.isEmpty else { throw BridgeCommandError("No apps were selected.") }
        guard targets.count <= 40 else { throw BridgeCommandError("Too many apps in one request.") }
        let results = await AppQuitter.quitAll(targets)
        let closed = results.filter { $0.status == .quit }.count
        return ("Closed \(closed) of \(results.count) app\(results.count == 1 ? "" : "s")", results.map(\.json))
    }
}

import Darwin
import Foundation

/// `GET /api/optimize/plan`, `POST /api/optimize/run`, `POST /api/optimize/purge`.
///
/// Plan lists what can be freed (loaded Ollama models, running model servers,
/// the file cache) with sizes and the Recommended / Maximum presets. Run
/// unloads and stops the chosen items and reports memory before and after.
/// Purge clears the file cache behind the macOS password dialog; it runs on
/// the concurrent queue so a slow answer never holds up other actions.
extension ControllerRouter {
    var optimizeRoutes: [RouteKey: Route] {
        [
            RouteKey(method: "GET", path: "/api/optimize/plan"): { [self] _ in
                try json(optimizePlan())
            },
            RouteKey(method: "POST", path: "/api/optimize/run"): { [self] request in
                let object = try requestObject(request)
                if let ids = object["items"] as? [String] { return try json(optimizeRun(ids)) }
                // {"preset": "maximum"|"recommended"} resolves the preset against a
                // fresh scan (the file cache is left to /api/optimize/purge).
                guard let preset = object["preset"] as? String, ["maximum", "recommended"].contains(preset) else {
                    throw ControllerError.usage("send items (ids from the plan) or preset: maximum or recommended")
                }
                let ids = OptimizePlanner.preset(preset, OptimizePlanner.items(optimizeScan().inputs))
                return try json(optimizeRun(ids.filter { $0 != "system:file-cache" }))
            },
            RouteKey(method: "POST", path: "/api/optimize/purge"): { [self] _ in
                try json(optimizePurge())
            },
        ]
    }

    var optimizeOllamaURL: URL { usage?.ollamaBaseURL ?? URL(string: "http://127.0.0.1:11434")! }

    struct OptimizeScan {
        var inputs = OptimizeInputs()
        var memory: MemorySnapshot?
        var table: ProcessTable
        var excluded: Set<Int32> = []
    }

    func optimizeScan() -> OptimizeScan {
        var scan = OptimizeScan(memory: MemorySnapshot.current(), table: ProcessTable.current())
        scan.inputs.cachedBytes = scan.memory?.cachedBytes ?? 0
        scan.inputs.ollamaModels = OptimizeActions.loadedOllamaModels(optimizeOllamaURL)
        scan.excluded.insert(getpid())
        for (profile, pid) in service.runningModelServers() {
            let root = Int32(pid)
            scan.excluded.formUnion(scan.table.tree(root))
            scan.inputs.servers.append(
                OptimizeInputs.Server(
                    profile: profile.name, displayName: profile.displayName,
                    runtimeLabel: profile.runtimeSpec.label, pid: root,
                    bytes: scan.table.footprint(ofTree: root),
                    startedAt: scan.table.rows[root]?.startedAt))
        }
        // Ollama's memory is listed per model; ModelMatrix itself is not a target.
        for row in scan.table.rows.values
        where row.name.lowercased().hasPrefix("ollama") || row.path.contains("/Ollama.app/")
            || row.path.contains("/ModelMatrix.app/")
        {
            scan.excluded.insert(row.pid)
        }
        if let usage {
            scan.inputs.lastUsed = usage.store.lastUsed()
            for entry in usage.inflightSnapshot() {
                if let profile = entry["profile"] as? String { scan.inputs.inflightProfiles.insert(profile) }
                if let model = entry["model"] as? String { scan.inputs.inflightModels.insert(model) }
            }
        }
        return scan
    }

    func optimizePlan() -> [String: Any] {
        let scan = optimizeScan()
        let items = OptimizePlanner.items(scan.inputs)
        let recommended = OptimizePlanner.preset("recommended", items)
        let maximum = OptimizePlanner.preset("maximum", items)
        var plan: [String: Any] = [
            "items": items.map(\.json),
            "apps": ProcessTable.refine(
                scan.table.appGroups(excluding: scan.excluded), allowedApps: bridge.quittableAppPaths
            ).map(\.json),
            "presets": ["recommended": recommended, "maximum": maximum],
            "estimates": [
                "recommended": OptimizePlanner.estimate(recommended, items),
                "maximum": OptimizePlanner.estimate(maximum, items),
            ],
            "thresholds": [
                "in_use_seconds": OptimizePlanner.inUseSeconds,
                "idle_seconds": OptimizePlanner.idleSeconds,
            ],
            "generated_at": Date().timeIntervalSince1970,
        ]
        if let memory = scan.memory { plan["memory"] = memory.json }
        return plan
    }

    func optimizeRun(_ ids: [String]) -> [String: Any] {
        let before = MemorySnapshot.current()
        let scan = optimizeScan()
        let items = OptimizePlanner.items(scan.inputs)
        let serverPIDs = Dictionary(
            scan.inputs.servers.map { ($0.profile, $0.pid) }, uniquingKeysWith: { first, _ in first })
        var results: [[String: Any]] = []
        for id in ids {
            guard let item = items.first(where: { $0.id == id }) else {
                results.append(["id": id, "ok": true, "skipped": true, "message": "Already freed"])
                continue
            }
            if item.kind == .fileCache {
                results.append([
                    "id": id, "ok": false, "skipped": true,
                    "message": "Clearing the file cache needs your password: POST /api/optimize/purge",
                ])
            }
        }
        let chosen = items.filter { ids.contains($0.id) && $0.kind != .fileCache }
        for item in chosen where item.kind == .ollamaModel {
            let model = String(item.id.dropFirst("ollama:".count))
            let outcome = OptimizeActions.unloadOllama(model, baseURL: optimizeOllamaURL)
            results.append(["id": item.id, "ok": outcome.ok, "message": outcome.message, "bytes": item.bytes])
        }
        for item in chosen where item.kind == .modelServer {
            let profile = String(item.id.dropFirst("profile:".count))
            do {
                try service.stop(profile)
                if let pid = serverPIDs[profile], !Self.waitForExit(pid) {
                    results.append([
                        "id": item.id, "ok": false,
                        "message": "Still running (pid \(pid)): ModelMatrix could not confirm this process is the model server, so it left it alone",
                    ])
                } else {
                    results.append(["id": item.id, "ok": true, "message": "Stopped", "bytes": item.bytes])
                }
            } catch let error as ControllerError {
                results.append(["id": item.id, "ok": false, "message": httpSpec(for: error).message])
            } catch {
                results.append(["id": item.id, "ok": false, "message": error.localizedDescription])
            }
        }
        // Freed pages reach the free list a moment after a process exits.
        if !chosen.isEmpty { Thread.sleep(forTimeInterval: 1.0) }
        return withMemory(["results": results], before: before, after: MemorySnapshot.current())
    }

    static func waitForExit(_ pid: Int32, timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while ProcessRunner.processIsAlive(Int(pid)) {
            if Date() >= deadline { return false }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return true
    }

    func optimizePurge() -> [String: Any] {
        let before = MemorySnapshot.current()
        let outcome = OptimizeActions.purgeFileCache()
        if outcome.ok { Thread.sleep(forTimeInterval: 0.5) }
        let result: [String: Any] = [
            "ok": outcome.ok, "canceled": outcome.canceled, "message": outcome.message,
        ]
        return withMemory(result, before: before, after: MemorySnapshot.current())
    }

    func withMemory(_ payload: [String: Any], before: MemorySnapshot?, after: MemorySnapshot?) -> [String: Any] {
        var payload = payload
        if let before { payload["before"] = before.json }
        if let after { payload["after"] = after.json }
        if let before, let after {
            payload["freed_bytes"] = OptimizePlanner.freedBytes(before: before, after: after)
        }
        return payload
    }
}

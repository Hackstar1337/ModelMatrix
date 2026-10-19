import Foundation

/// Side effects used by Optimize. Model servers are stopped through
/// `ControllerService.stop`, like any other stop.
public enum OptimizeActions {
    public struct Outcome: Sendable {
        public var ok: Bool
        public var message: String
        public var canceled = false
    }

    /// Asks Ollama to unload `model` now (`keep_alive: 0`) and waits until
    /// `/api/ps` no longer lists it.
    public static func unloadOllama(_ model: String, baseURL: URL, timeout: TimeInterval = 8) -> Outcome {
        let body: [String: Any] = ["model": model, "keep_alive": 0, "stream": false]
        guard postJSON(baseURL.appendingPathComponent("api/generate"), body, timeout: timeout) else {
            return Outcome(ok: false, message: "Ollama did not accept the unload request")
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !loadedOllamaModels(baseURL).contains(where: { OptimizePlanner.sameModel($0.name, model) }) {
                return Outcome(ok: true, message: "Unloaded")
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return Outcome(ok: false, message: "Ollama still lists the model as loaded")
    }

    public static func loadedOllamaModels(_ baseURL: URL) -> [OptimizeInputs.OllamaModel] {
        let payload = UsageService.fetchJSON(baseURL.appendingPathComponent("api/ps"), timeout: 1.5)
        return ((payload?["models"] as? [[String: Any]]) ?? []).compactMap { entry in
            guard let name = (entry["name"] as? String) ?? (entry["model"] as? String) else { return nil }
            let size = (entry["size"] as? NSNumber)?.uint64Value ?? 0
            return OptimizeInputs.OllamaModel(name: name, bytes: size)
        }
    }

    static func postJSON(_ url: URL, _ body: [String: Any], timeout: TimeInterval) -> Bool {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("ModelMatrix", forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var accepted = false
        let task = URLSession.shared.dataTask(with: request) { _, response, _ in
            accepted = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
            semaphore.signal()
        }
        task.resume()
        if semaphore.wait(timeout: .now() + timeout + 0.5) == .timedOut {
            task.cancel()
            return false
        }
        return accepted
    }

    public static let purgePrompt =
        "ModelMatrix wants to clear the macOS file cache to free memory."

    /// Runs `/usr/sbin/purge`, which needs administrator rights, through the
    /// standard macOS password dialog. Gives up (and closes the dialog) after
    /// `timeout` seconds.
    public static let purgeScript =
        "do shell script \"/usr/sbin/purge\" with prompt \"\(purgePrompt)\" with administrator privileges"

    public static func purgeFileCache(timeout: TimeInterval = 180, script: String = purgeScript) -> Outcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return Outcome(ok: false, message: "Could not ask for permission: \(error.localizedDescription)")
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return Outcome(ok: false, message: "No answer to the password prompt", canceled: true)
        }
        let stderr = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if process.terminationStatus == 0 {
            return Outcome(ok: true, message: "File cache cleared")
        }
        if stderr.contains("-128") || stderr.localizedCaseInsensitiveContains("cancel") {
            return Outcome(ok: false, message: "Canceled", canceled: true)
        }
        let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return Outcome(ok: false, message: detail.isEmpty ? "purge failed" : detail)
    }
}

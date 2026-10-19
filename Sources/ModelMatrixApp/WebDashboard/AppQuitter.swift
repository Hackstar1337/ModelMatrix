import AppKit
import Foundation

/// Quits running apps the way ⌘Q does, so they can still ask to save work.
/// Shared by the Optimize panel and the web dashboard (through the bridge).
@MainActor
enum AppQuitter {
    struct Failure: LocalizedError {
        let message: String
        /// The app was not running, so there was nothing left to quit.
        var alreadyClosed = false
        var errorDescription: String? { message }
    }

    /// What happened to one app after it was asked to quit.
    struct Result: Equatable {
        enum Status: String {
            /// Closed (or had already closed).
            case quit
            /// Still running when the wait ended, usually because it is asking to save.
            case stillOpen = "still_open"
            /// Not allowed: part of macOS, a background app, ModelMatrix itself...
            case refused
        }

        let path: String
        let name: String
        let status: Status
        let message: String

        var json: [String: Any] {
            ["path": path, "name": name, "status": status.rawValue, "ok": status == .quit, "message": message]
        }
    }

    /// Parts of macOS that must never be quit from here.
    static let protectedBundleIDs: Set<String> = [
        "com.apple.finder", "com.apple.dock", "com.apple.loginwindow", "com.apple.systemuiserver",
        "com.apple.controlcenter", "com.apple.WindowManager", "com.apple.notificationcenterui",
    ]

    /// Asks one app to quit and returns its display name without waiting.
    @discardableResult
    static func quit(path: String?, name: String?) throws -> String {
        let (display, apps) = try prepare(path: path, name: name)
        apps.forEach { $0.terminate() }
        return display
    }

    /// Asks every app to quit at once, then waits up to `wait` for them to
    /// close and reports each one.
    static func quitAll(_ targets: [(path: String?, name: String?)], wait: Duration = .seconds(10)) async -> [Result] {
        var results: [Result?] = Array(repeating: nil, count: targets.count)
        var asked: [(index: Int, path: String, name: String, apps: [NSRunningApplication])] = []
        for (index, target) in targets.enumerated() {
            let path = target.path ?? ""
            do {
                let (display, apps) = try prepare(path: target.path, name: target.name)
                apps.forEach { $0.terminate() }
                asked.append((index, path, display, apps))
            } catch let failure as Failure where failure.alreadyClosed {
                results[index] = Result(
                    path: path, name: target.name ?? "The app", status: .quit, message: "Already closed.")
            } catch {
                results[index] = Result(
                    path: path, name: target.name ?? "The app", status: .refused,
                    message: error.localizedDescription)
            }
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: wait)
        while clock.now < deadline, asked.contains(where: { !$0.apps.allSatisfy(\.isTerminated) }) {
            try? await Task.sleep(for: .milliseconds(250))
        }
        for entry in asked {
            let closed = entry.apps.allSatisfy(\.isTerminated)
            results[entry.index] = Result(
                path: entry.path, name: entry.name, status: closed ? .quit : .stillOpen,
                message: closed ? "Quit." : "Still open. It may be asking you to save your work.")
        }
        return results.compactMap { $0 }
    }

    /// Bundle paths of the apps (Dock apps and menu bar utilities) that may be quit right now. Sent with
    /// every heartbeat so the controller only offers apps that will really quit.
    static func quittableAppPaths() -> [String] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard refusal(bundleID: app.bundleIdentifier, pid: app.processIdentifier, policy: app.activationPolicy) == nil
            else { return nil }
            return app.bundleURL?.standardizedFileURL.path
        }
    }

    /// Why an app may not be quit, or nil when it may.
    static func refusal(bundleID: String?, pid: pid_t, policy: NSApplication.ActivationPolicy) -> String? {
        if pid == ProcessInfo.processInfo.processIdentifier
            || (bundleID != nil && bundleID == Bundle.main.bundleIdentifier)
        {
            return "is ModelMatrix itself; use Quit in the menu bar instead."
        }
        if let bundleID, protectedBundleIDs.contains(bundleID) { return "is part of macOS and was left running." }
        // Menu bar utilities (.accessory) quit from their menu like any app;
        // background-only agents (.prohibited) have no way to ask the user.
        if policy == .prohibited { return "runs in the background and was left running." }
        return nil
    }

    /// Finds the running copies of an app and checks it may be quit.
    private static func prepare(path: String?, name: String?) throws -> (String, [NSRunningApplication]) {
        guard let path, path.hasSuffix(".app") else {
            throw Failure(message: "Only regular apps can be quit from ModelMatrix.")
        }
        let matches = running(path: path)
        guard let app = matches.first else {
            throw Failure(message: "\(name ?? "That app") is not running.", alreadyClosed: true)
        }
        let display = app.localizedName ?? name ?? "The app"
        if let reason = refusal(
            bundleID: app.bundleIdentifier, pid: app.processIdentifier, policy: app.activationPolicy)
        {
            throw Failure(message: "\(display) \(reason)")
        }
        return (display, matches)
    }

    /// Running apps at `path`. Falls back to the bundle's file name, because
    /// some Apple apps (Safari) run from a different on-disk location than
    /// the one their processes report.
    private static func running(path: String) -> [NSRunningApplication] {
        let target = URL(fileURLWithPath: path).standardizedFileURL.path
        let all = NSWorkspace.shared.runningApplications
        let exact = all.filter { $0.bundleURL?.standardizedFileURL.path == target }
        if !exact.isEmpty { return exact }
        let file = (target as NSString).lastPathComponent
        return all.filter { $0.activationPolicy != .prohibited && $0.bundleURL?.lastPathComponent == file }
    }
}

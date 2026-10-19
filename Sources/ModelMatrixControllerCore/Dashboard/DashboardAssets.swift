import Foundation

/// Serves the built web dashboard (`index.html` + hashed assets).
///
/// Lookup order for the dashboard folder:
/// 1. `MODELMATRIX_DASHBOARD_DIR`
/// 2. `<controller executable dir>/Dashboard` (inside `ModelMatrix.app/Contents/Resources`)
/// 3. `<controller root>/Dashboard`
/// 4. `Dashboard/dist` in the current directory (development checkout)
public struct DashboardAssets: Sendable {
    public let directory: URL?

    public init(directory: URL?) {
        self.directory = directory?.standardizedFileURL
    }

    public static func locate(
        configuration: ControllerConfiguration,
        // launchd passes the bare name as argv[0] (BundleProgram), so ask the
        // loader for the real path rather than trusting CommandLine.arguments.
        executableURL: URL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> DashboardAssets {
        var candidates: [URL] = []
        if let override = environment["MODELMATRIX_DASHBOARD_DIR"], !override.isEmpty {
            candidates.append(URL(fileURLWithPath: NSString(string: override).expandingTildeInPath))
        }
        let executableDirectory = executableURL.resolvingSymlinksInPath().deletingLastPathComponent()
        candidates.append(executableDirectory.appendingPathComponent("Dashboard", isDirectory: true))
        candidates.append(configuration.root.appendingPathComponent("Dashboard", isDirectory: true))
        candidates.append(
            URL(fileURLWithPath: fileManager.currentDirectoryPath)
                .appendingPathComponent("Dashboard/dist", isDirectory: true))
        for candidate in candidates
        where fileManager.fileExists(atPath: candidate.appendingPathComponent("index.html").path) {
            return DashboardAssets(directory: candidate)
        }
        return DashboardAssets(directory: nil)
    }

    static let mimeTypes: [String: String] = [
        "html": "text/html; charset=utf-8",
        "js": "text/javascript; charset=utf-8",
        "mjs": "text/javascript; charset=utf-8",
        "css": "text/css; charset=utf-8",
        "json": "application/json",
        "svg": "image/svg+xml",
        "png": "image/png",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "webp": "image/webp",
        "ico": "image/x-icon",
        "woff": "font/woff",
        "woff2": "font/woff2",
        "ttf": "font/ttf",
        "txt": "text/plain; charset=utf-8",
        "map": "application/json",
        "webmanifest": "application/manifest+json",
    ]

    static func mimeType(for url: URL) -> String {
        mimeTypes[url.pathExtension.lowercased()] ?? "application/octet-stream"
    }

    /// Resolves a URL path to a file inside the dashboard directory, refusing
    /// anything that would escape it. Paths without an extension fall back to
    /// `index.html` so client-side routes (`/fleet`, `/models`) work on reload.
    public func file(forPath rawPath: String) -> URL? {
        guard let directory else { return nil }
        let decoded = rawPath.removingPercentEncoding ?? rawPath
        if decoded.contains("\0") { return nil }
        let components = decoded.split(separator: "/").map(String.init)
        if components.contains(where: { $0 == ".." || $0.hasPrefix(".") }) { return nil }
        let index = directory.appendingPathComponent("index.html")
        if components.isEmpty { return index }
        var candidate = directory
        for component in components { candidate.appendPathComponent(component) }
        candidate = candidate.standardizedFileURL
        guard candidate.path.hasPrefix(directory.path + "/") else { return nil }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
            !isDirectory.boolValue
        {
            return candidate
        }
        if candidate.pathExtension.isEmpty { return index }
        return nil
    }

    static let placeholderHTML = """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8"><title>ModelMatrix</title>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        body{margin:0;min-height:100vh;display:grid;place-items:center;background:#0b0b0c;color:#e8e8ea;
        font:15px -apple-system,BlinkMacSystemFont,"SF Pro Text",Inter,sans-serif}
        main{max-width:520px;padding:32px;border:1px solid #2a2a2e;border-radius:14px;background:#121214}
        h1{margin:0 0 8px;color:#ff6b1a;letter-spacing:.06em;font-size:22px}
        code{font-family:"SF Mono",Menlo,monospace;color:#ffb27a}
        p{line-height:1.55;color:#a1a1a8}
        </style></head>
        <body><main><h1>MODELMATRIX</h1>
        <p>The controller is running, but the dashboard files were not found.</p>
        <p>Reinstall ModelMatrix, or set <code>MODELMATRIX_DASHBOARD_DIR</code> to a built
        dashboard folder and restart the controller.</p>
        <p>API status: <a style="color:#ff6b1a" href="/api/status">/api/status</a></p>
        </main></body></html>
        """
}

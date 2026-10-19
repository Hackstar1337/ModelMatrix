import Foundation
import Security

/// Browser-facing protection for the controller API.
///
/// The controller has always trusted any local process (the menu bar app,
/// the CLI, Raycast, SwiftBar). Serving a web dashboard from the same port
/// adds a new kind of caller - a web browser - which can be tricked by other
/// websites into sending requests to `localhost`. These checks close that gap
/// without changing anything for non-browser clients:
///
/// 1. DNS-rebinding guard: when no bearer token is configured, the `Host`
///    header must name a loopback address.
/// 2. Requests that carry browser fetch metadata (`Origin`, `Sec-Fetch-Site`)
///    must be same-origin.
/// 3. Browser requests to `/api/` must present the dashboard session cookie,
///    which is only handed out by the dashboard page itself
///    (`HttpOnly; SameSite=Strict`, so other sites can neither read nor send it).
public final class DashboardSession: @unchecked Sendable {
    public static let cookieName = "mmx_session"

    private let lock = NSLock()
    private var tokens: [String: Date] = [:]
    private let lifetime: TimeInterval

    public init(lifetime: TimeInterval = 60 * 60 * 24 * 30) {
        self.lifetime = lifetime
    }

    /// Issues a new random session token.
    public func issue() -> String {
        let token = Self.randomToken()
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        tokens = tokens.filter { $0.value > now }
        tokens[token] = now.addingTimeInterval(lifetime)
        return token
    }

    public func isValid(_ token: String?) -> Bool {
        guard let token, !token.isEmpty else { return false }
        lock.lock()
        defer { lock.unlock() }
        guard let expiry = tokens[token] else { return false }
        return expiry > Date()
    }

    public func revoke(_ token: String?) {
        guard let token else { return }
        lock.lock()
        tokens[token] = nil
        lock.unlock()
    }

    public func cookieHeader(for token: String) -> String {
        "\(Self.cookieName)=\(token); Path=/; HttpOnly; SameSite=Strict; Max-Age=\(Int(lifetime))"
    }

    static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

enum DashboardRequestGuard {
    /// Value of a cookie from the request's `Cookie` header.
    static func cookie(_ name: String, in request: ControllerHTTPRequest) -> String? {
        guard let header = request.headers["cookie"] else { return nil }
        for part in header.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            if pair.count == 2, pair[0] == name { return pair[1] }
        }
        return nil
    }

    /// True when the request carries browser fetch metadata. Native clients
    /// (URLSession in the app, curl, Raycast, SwiftBar) never send these.
    static func isBrowserRequest(_ request: ControllerHTTPRequest) -> Bool {
        request.headers["origin"] != nil || request.headers["sec-fetch-site"] != nil
            || request.headers["sec-fetch-mode"] != nil
    }

    /// Hostname portion of a `Host` header (`127.0.0.1:7700`, `[::1]:7700`, `localhost`).
    static func hostName(fromHostHeader raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if value.hasPrefix("[") {
            if let close = value.firstIndex(of: "]") {
                return String(value[value.index(after: value.startIndex)..<close])
            }
            return value
        }
        if let colon = value.lastIndex(of: ":"), value.filter({ $0 == ":" }).count == 1 {
            return String(value[..<colon])
        }
        return value
    }

    static func isLoopbackName(_ host: String) -> Bool {
        let name = host.lowercased()
        if name == "localhost" || name.hasSuffix(".localhost") { return true }
        return ControllerConfiguration.isLoopback(name)
    }

    /// DNS-rebinding guard: without a bearer token the controller only
    /// answers requests addressed to a loopback name.
    static func hostAllowed(_ request: ControllerHTTPRequest, configuration: ControllerConfiguration)
        -> Bool
    {
        guard let raw = request.headers["host"], !raw.isEmpty else { return true }
        let name = hostName(fromHostHeader: raw)
        if isLoopbackName(name) { return true }
        if configuration.authToken != nil {
            // Remote access is token-protected, so any Host is acceptable.
            return true
        }
        return name == configuration.host.lowercased()
    }

    /// Same-origin check for browser requests.
    static func sameOrigin(_ request: ControllerHTTPRequest) -> Bool {
        if let site = request.headers["sec-fetch-site"]?.lowercased(),
            site != "same-origin", site != "none"
        {
            return false
        }
        guard let origin = request.headers["origin"] else { return true }
        if origin == "null" { return false }
        guard let originURL = URL(string: origin), let originHost = originURL.host else {
            return false
        }
        guard let hostHeader = request.headers["host"] else { return false }
        let expectedHost = hostName(fromHostHeader: hostHeader)
        let expectedPort = hostHeader.split(separator: ":").last.flatMap { Int($0) }
        let originPort = originURL.port ?? (originURL.scheme == "https" ? 443 : 80)
        let hostsMatch =
            originHost.lowercased() == expectedHost
            || (isLoopbackName(originHost) && isLoopbackName(expectedHost))
        return hostsMatch && (expectedPort == nil || expectedPort == originPort)
    }
}

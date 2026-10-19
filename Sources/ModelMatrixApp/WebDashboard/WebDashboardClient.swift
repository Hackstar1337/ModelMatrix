import AppKit
import Foundation

enum WebDashboardError: LocalizedError {
    case invalidURL
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: "The controller URL is not valid."
        case .http(_, let message): message
        }
    }
}

/// A loosely typed JSON object from the controller. The usage and profile APIs
/// return rows whose numeric fields may be integers or doubles depending on the
/// SQLite aggregate, so the panels read them through these accessors instead of
/// strict `Decodable` models.
struct JSONRow: Identifiable {
    let raw: [String: Any]

    init(_ raw: [String: Any]) { self.raw = raw }

    var id: String {
        if let value = raw["id"] { return "\(value)" }
        if let value = raw["client_id"] as? String { return value }
        if let value = raw["profile"] as? String { return value }
        if let value = raw["model"] as? String { return value + "|" + (raw["host"] as? String ?? "") }
        if let value = raw["name"] as? String { return value }
        return UUID().uuidString
    }

    func string(_ key: String) -> String? {
        switch raw[key] {
        case let value as String: value.isEmpty ? nil : value
        case let value as NSNumber: value.stringValue
        default: nil
        }
    }

    func double(_ key: String) -> Double? {
        switch raw[key] {
        case let value as NSNumber: value.doubleValue
        case let value as String: Double(value)
        default: nil
        }
    }

    func int(_ key: String) -> Int? { double(key).map { Int($0.rounded()) } }

    func bool(_ key: String) -> Bool {
        switch raw[key] {
        case let value as Bool: value
        case let value as NSNumber: value.boolValue
        case let value as String: ["1", "true", "yes"].contains(value.lowercased())
        default: false
        }
    }

    func row(_ key: String) -> JSONRow? { (raw[key] as? [String: Any]).map(JSONRow.init) }

    func rows(_ key: String) -> [JSONRow] { (raw[key] as? [[String: Any]] ?? []).map(JSONRow.init) }

    func strings(_ key: String) -> [String] { raw[key] as? [String] ?? [] }
}

/// Talks to the local controller's dashboard API (usage, profiles, bridge) with
/// the same base URL and token the menu bar already uses.
@MainActor
struct WebDashboardClient {
    let baseURL: String
    let token: String

    static func local(_ store: MatrixStore) -> WebDashboardClient {
        WebDashboardClient(baseURL: store.controllerBaseURL, token: store.controllerAuthToken)
    }

    nonisolated static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 20
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    var normalizedBase: String {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        return base.isEmpty ? "http://127.0.0.1:7700" : base
    }

    func url(_ path: String) throws -> URL {
        guard let url = URL(string: normalizedBase + path) else { throw WebDashboardError.invalidURL }
        return url
    }

    /// Browser address for the web dashboard (`localhost` reads better than the loopback IP).
    var dashboardURL: URL? {
        guard var components = URLComponents(string: normalizedBase) else { return nil }
        if components.host == "127.0.0.1" || components.host == "::1" { components.host = "localhost" }
        components.path = "/"
        components.query = nil
        return components.url
    }

    func data(
        _ path: String,
        method: String = "GET",
        body: [String: Any]? = nil,
        timeout: TimeInterval = 20
    ) async throws -> Data {
        var request = URLRequest(url: try url(path), timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ModelMatrix-App", forHTTPHeaderField: "User-Agent")
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await Self.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw WebDashboardError.http(status, Self.errorMessage(data) ?? "The controller answered HTTP \(status).")
        }
        return data
    }

    func object(
        _ path: String,
        method: String = "GET",
        body: [String: Any]? = nil,
        timeout: TimeInterval = 20
    ) async throws -> JSONRow {
        let data = try await data(path, method: method, body: body, timeout: timeout)
        return JSONRow((try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:])
    }

    @discardableResult
    func post(_ path: String, _ body: [String: Any] = [:], timeout: TimeInterval = 30) async throws -> JSONRow {
        try await object(path, method: "POST", body: body, timeout: timeout)
    }

    static func errorMessage(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let text = String(decoding: data.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        if let message = object["message"] as? String, !message.isEmpty { return message }
        if let nested = object["error"] as? [String: Any], let message = nested["message"] as? String { return message }
        return object["error"] as? String
    }

    static func query(_ items: [String: String]) -> String {
        var components = URLComponents()
        components.queryItems = items.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.percentEncodedQuery.map { "?" + $0 } ?? ""
    }
}

@MainActor
enum WebDashboard {
    /// Opens the web dashboard served by the local controller in the default browser.
    static func open(_ store: MatrixStore) {
        guard let url = WebDashboardClient.local(store).dashboardURL else { return }
        NSWorkspace.shared.open(url)
    }
}

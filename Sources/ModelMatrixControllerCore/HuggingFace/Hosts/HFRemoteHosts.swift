import Foundation

/// A remote host: a Linux machine running the ModelMatrix agent, set up in
/// the menu bar's Remote Hosts. The controller learns about hosts (and
/// their access keys) only from the menu bar app.
public struct HFRemoteHost: Sendable, Equatable {
  public var id: String
  public var name: String
  /// The agent's address (for SSH hosts, the local tunnel).
  public var baseURL: String
  public var enabled: Bool
  var token: String?

  public init(id: String, name: String, baseURL: String, enabled: Bool = true, token: String? = nil) {
    self.id = id
    self.name = name
    self.baseURL = baseURL
    self.enabled = enabled
    self.token = token
  }
}

/// Lists remote hosts. `nil` means the menu bar app isn't connected, so
/// hosts can't be reached right now.
public protocol HFHostDirectory: Sendable {
  func hosts() -> [HFRemoteHost]?
}

/// Hosts as reported by the menu bar app's heartbeat.
struct HFBridgeHostDirectory: HFHostDirectory {
  let bridge: BridgeState

  func hosts() -> [HFRemoteHost]? {
    guard bridge.appConnected else { return nil }
    return bridge.gatewayList().map {
      HFRemoteHost(
        id: $0.id, name: $0.name, baseURL: $0.baseURL, enabled: $0.enabled && !$0.baseURL.isEmpty, token: $0.token)
    }
  }
}

extension HFHostDirectory {
  /// Words that mean "this Mac" rather than a remote host.
  static var localNames: Set<String> { ["", "local", "mac", "this-mac", "this mac", "localhost"] }

  /// The host named `query` (its id, or its name in any letter case), or
  /// nil for this Mac.
  func resolve(_ query: String?) throws -> HFRemoteHost? {
    let text = (query ?? "").trimmingCharacters(in: .whitespaces)
    if Self.localNames.contains(text.lowercased()) { return nil }
    guard text.count <= 100, text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
      throw HFError.invalidSetting("That isn't a valid host name.")
    }
    guard let list = hosts() else {
      throw HFError.unavailable(
        "Remote hosts are reached through the ModelMatrix menu bar app. Open it, then try again.")
    }
    let found = list.first { $0.id == text } ?? list.first { $0.name.caseInsensitiveCompare(text) == .orderedSame }
    guard let host = found else {
      if list.isEmpty {
        throw HFError.unknownItem("No remote hosts are set up. Add one in the menu bar under Remote Hosts.")
      }
      throw HFError.unknownItem(
        "No remote host named \"\(text)\". Hosts: \(list.map(\.name).joined(separator: ", ")).")
    }
    guard host.enabled else {
      throw HFError.refused("\(host.name) is paused in ModelMatrix. Resume it in the menu bar first.")
    }
    return host
  }
}

/// Sends one request to an agent; replaceable in tests.
public protocol HFAgentTransport: Sendable {
  /// Throws `HFError.unavailable` when the host can't be reached.
  func send(method: String, url: URL, token: String?, body: Data?, timeout: TimeInterval) throws -> (
    status: Int, body: Data
  )
}

/// Talks to agents directly (no system proxy: hosts are on the user's own
/// network or behind an SSH tunnel), like the dashboard's remote proxy.
public struct URLSessionAgentTransport: HFAgentTransport {
  public init() {}

  public func send(method: String, url: URL, token: String?, body: Data?, timeout: TimeInterval) throws -> (
    status: Int, body: Data
  ) {
    var request = URLRequest(url: url, timeoutInterval: timeout)
    request.httpMethod = method
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("ModelMatrix-Controller", forHTTPHeaderField: "User-Agent")
    if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    request.httpBody = body
    let configuration = URLSessionConfiguration.ephemeral
    configuration.connectionProxyDictionary = [:]
    configuration.waitsForConnectivity = false
    let session = URLSession(configuration: configuration)
    defer { session.finishTasksAndInvalidate() }
    let semaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: (Data?, HTTPURLResponse?, Error?) = (nil, nil, nil)
    session.dataTask(with: request) { data, response, failure in
      result = (data, response as? HTTPURLResponse, failure)
      semaphore.signal()
    }.resume()
    _ = semaphore.wait(timeout: .now() + timeout + 5)
    guard let response = result.1 else {
      throw HFError.unavailable(result.2?.localizedDescription ?? "no answer within \(Int(timeout)) seconds")
    }
    return (response.statusCode, result.0 ?? Data())
  }
}

/// JSON calls to the Hugging Face part of an agent (`/api/hf/...`).
public struct HFAgentClient: Sendable {
  let transport: HFAgentTransport

  public init(transport: HFAgentTransport = URLSessionAgentTransport()) {
    self.transport = transport
  }

  func get(_ host: HFRemoteHost, _ path: String, query: [String: String] = [:], timeout: TimeInterval = 20) throws
    -> [String: Any]
  {
    try call(host, "GET", path, query: query, body: nil, timeout: timeout)
  }

  func post(_ host: HFRemoteHost, _ path: String, _ body: [String: Any], timeout: TimeInterval = 60) throws
    -> [String: Any]
  {
    guard JSONSerialization.isValidJSONObject(body) else { throw HFError.badResponse("request body is not JSON") }
    return try call(host, "POST", path, query: [:], body: try JSONSerialization.data(withJSONObject: body), timeout: timeout)
  }

  private func call(
    _ host: HFRemoteHost, _ method: String, _ path: String, query: [String: String], body: Data?, timeout: TimeInterval
  ) throws -> [String: Any] {
    var base = host.baseURL
    while base.hasSuffix("/") { base.removeLast() }
    guard var components = URLComponents(string: base + path), components.scheme == "http" || components.scheme == "https"
    else {
      throw HFError.invalidSetting("\(host.name) has an invalid address in ModelMatrix.")
    }
    if !query.isEmpty {
      components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
    }
    guard let url = components.url else { throw HFError.invalidSetting("\(host.name) has an invalid address in ModelMatrix.") }
    let response: (status: Int, body: Data)
    do {
      response = try transport.send(method: method, url: url, token: host.token, body: body, timeout: timeout)
    } catch HFError.unavailable(let why) {
      throw HFError.unavailable("Couldn't reach \(host.name): \(why). Check that the host is online in the menu bar.")
    }
    let object = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any]
    if (200..<300).contains(response.status) {
      guard let object else { throw HFError.badResponse("\(host.name) sent an unreadable answer.") }
      return object
    }
    throw Self.error(status: response.status, object: object, host: host)
  }

  /// Turns an agent's error answer (`{"error": code, "message": text}`)
  /// into the matching error here.
  static func error(status: Int, object: [String: Any]?, host: HFRemoteHost) -> HFError {
    let code = object?["error"] as? String ?? ""
    let message = (object?["message"] as? String).map { String($0.prefix(600)) } ?? "HTTP \(status)"
    switch (status, code) {
    case (404, "not_found"), (404, ""), (405, _):
      return .unavailable(
        "The ModelMatrix agent on \(host.name) is too old for Hugging Face downloads. Update it in the menu bar (Remote Hosts > Update agent).")
    case (401, _):
      return .refused("\(host.name) didn't accept ModelMatrix's access key. Reconnect the host in the menu bar.")
    case (403, _) where code != "login_required":
      return .refused("\(host.name) didn't accept ModelMatrix's access key. Reconnect the host in the menu bar.")
    case (_, "unknown_item"): return .unknownItem(message)
    case (_, "conflict"): return .conflict(message)
    case (_, "insufficient_disk"): return .insufficientDisk(message)
    case (_, "login_required"): return .refused(message)
    case (_, "invalid_setting"): return .invalidSetting(message)
    case (429, _): return .unavailable("\(host.name): \(message)")
    case (500..., _): return .unavailable("\(host.name): \(message)")
    default: return .refused(message)
    }
  }
}

import Foundation
import ModelMatrixCore

/// Read-only Hugging Face API client used by the check. Never writes to disk.
public final class HFClient: @unchecked Sendable {
  public static let defaultEndpoint = URL(string: "https://huggingface.co")!
  static let jsonLimit = 8 * 1024 * 1024
  static let maxTreePages = 50
  static let cacheSeconds: TimeInterval = 600

  public let endpoint: URL
  let transport: HFTransport
  let timeout: TimeInterval
  private let lock = NSLock()
  private var cache: [String: (Date, HFHTTPResponse)] = [:]

  /// `endpoint` defaults to `HF_ENDPOINT` from the environment (a mirror),
  /// otherwise huggingface.co.
  public init(
    endpoint: URL? = nil, transport: HFTransport = URLSessionHFTransport(), timeout: TimeInterval = 20
  ) {
    self.endpoint = endpoint ?? HFClient.environmentEndpoint() ?? HFClient.defaultEndpoint
    self.transport = transport
    self.timeout = timeout
  }

  static func environmentEndpoint() -> URL? {
    guard let raw = ProcessInfo.processInfo.environment["HF_ENDPOINT"]?.trimmed, !raw.isEmpty,
      let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
      scheme == "https" || scheme == "http", url.host != nil
    else { return nil }
    return url
  }

  /// Mirror host accepted in pasted links, when one is configured.
  var mirrorHost: String? {
    let host = endpoint.host?.lowercased()
    return host == "huggingface.co" ? nil : host
  }

  static let infoFields = [
    "gguf", "library_name", "tags", "pipeline_tag", "gated", "private", "sha", "cardData",
    "downloads", "likes", "safetensors", "config", "baseModels", "lastModified",
  ]

  // MARK: API calls

  public func modelInfo(_ repo: HFRepoReference) throws -> [String: Any] {
    var path = "/api/models/\(repo.owner)/\(repo.name)"
    if let revision = repo.revision { path += "/revision/\(Self.encodeSegment(revision))" }
    let query = Self.infoFields.map { ("expand[]", $0) }
    let response = try get(path: path, query: query, limit: Self.jsonLimit)
    try check(response, repo: repo.id)
    return try Self.object(response.body)
  }

  /// Every file in the repository at `revision`, following pagination.
  public func tree(_ repo: HFRepoReference, revision: String) throws -> [[String: Any]] {
    var entries: [[String: Any]] = []
    var next: URL? = url(
      path: "/api/models/\(repo.owner)/\(repo.name)/tree/\(Self.encodeSegment(revision))",
      query: [("recursive", "true")])
    var pages = 0
    while let current = next, pages < Self.maxTreePages {
      let response = try get(current, limit: Self.jsonLimit)
      try check(response, repo: repo.id)
      guard let page = try JSONSerialization.jsonObject(with: response.body) as? [[String: Any]] else {
        throw HFError.badResponse("file list is not a list")
      }
      entries += page
      next = Self.nextLink(response.headers["link"], sameHostAs: endpoint)
      pages += 1
    }
    return entries
  }

  /// Model search, sorted by downloads.
  public func models(
    search: String? = nil, filters: [String] = [], author: String? = nil, limit: Int = 10
  ) throws -> [[String: Any]] {
    var query: [(String, String)] = []
    if let search { query.append(("search", search)) }
    if let author { query.append(("author", author)) }
    query += filters.map { ("filter", $0) }
    query += [("sort", "downloads"), ("direction", "-1"), ("limit", String(max(1, min(limit, 50))))]
    query += ["downloads", "likes", "tags", "library_name", "pipeline_tag", "gated"].map {
      ("expand[]", $0)
    }
    let response = try get(path: "/api/models", query: query, limit: Self.jsonLimit)
    try check(response, repo: search ?? "search")
    guard let list = try JSONSerialization.jsonObject(with: response.body) as? [[String: Any]] else {
      throw HFError.badResponse("search answer is not a list")
    }
    return list
  }

  /// The first `length` bytes of a file (a header read, never a download).
  public func fileHead(_ repo: HFRepoReference, revision: String, path: String, length: Int)
    throws -> Data
  {
    let response = try get(
      path: resolvePath(repo, revision: revision, file: path), query: [],
      headers: ["Range": "bytes=0-\(length - 1)"], limit: length, cacheable: true)
    try check(response, repo: repo.id, file: true)
    guard response.status == 206 || response.status == 200 else {
      throw HFError.upstream(status: response.status)
    }
    return response.body.prefix(length)
  }

  /// A small JSON file from the repository, such as config.json.
  public func fileJSON(_ repo: HFRepoReference, revision: String, path: String) throws -> [String: Any] {
    let response = try get(path: resolvePath(repo, revision: revision, file: path), query: [], limit: 2 * 1024 * 1024)
    try check(response, repo: repo.id, file: true)
    return try Self.object(response.body)
  }

  func resolvePath(_ repo: HFRepoReference, revision: String, file: String) -> String {
    let encodedFile = file.split(separator: "/").map { Self.encodeSegment(String($0)) }.joined(separator: "/")
    return "/\(repo.owner)/\(repo.name)/resolve/\(Self.encodeSegment(revision))/\(encodedFile)"
  }

  // MARK: Plumbing

  func url(path: String, query: [(String, String)]) -> URL? {
    var base = endpoint.absoluteString
    while base.hasSuffix("/") { base.removeLast() }
    var text = base + path
    if !query.isEmpty {
      text += "?" + query.map { "\(Self.encodeQuery($0.0))=\(Self.encodeQuery($0.1))" }.joined(separator: "&")
    }
    return URL(string: text)
  }

  func get(
    path: String, query: [(String, String)], headers: [String: String] = [:], limit: Int,
    cacheable: Bool = true
  ) throws -> HFHTTPResponse {
    guard let url = url(path: path, query: query) else { throw HFError.invalidName("bad address") }
    return try get(url, headers: headers, limit: limit, cacheable: cacheable)
  }

  func get(_ url: URL, headers: [String: String] = [:], limit: Int, cacheable: Bool = true) throws
    -> HFHTTPResponse
  {
    let key = url.absoluteString + "|" + headers.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
    if cacheable, let hit = cached(key) { return hit }
    var allHeaders = headers
    allHeaders["User-Agent"] = "ModelMatrix/\(ControllerVersion.current)"
    allHeaders["Accept"] = allHeaders["Range"] == nil ? "application/json" : "*/*"
    let response = try transport.get(url, headers: allHeaders, maxBytes: limit, timeout: timeout)
    if cacheable, response.status == 200 || response.status == 206 { store(key, response) }
    return response
  }

  private func cached(_ key: String) -> HFHTTPResponse? {
    lock.lock()
    defer { lock.unlock() }
    guard let (date, response) = cache[key], Date().timeIntervalSince(date) < Self.cacheSeconds else {
      cache[key] = nil
      return nil
    }
    return response
  }

  private func store(_ key: String, _ response: HFHTTPResponse) {
    lock.lock()
    defer { lock.unlock() }
    if cache.count >= 128 {
      let cutoff = Date().addingTimeInterval(-Self.cacheSeconds)
      cache = cache.filter { $0.value.0 > cutoff }
      if cache.count >= 128 { cache.removeAll() }
    }
    cache[key] = (Date(), response)
  }

  /// Maps Hugging Face statuses to actionable errors. Unknown and private
  /// repositories both answer 401 without an error code, so they are
  /// reported as "not found"; gated files carry `X-Error-Code: GatedRepo`.
  func check(_ response: HFHTTPResponse, repo: String, file: Bool = false) throws {
    switch response.status {
    case 200, 206: return
    case 401, 403:
      let code = response.headers["x-error-code"] ?? ""
      if code == "GatedRepo" || (file && response.status == 403) { throw HFError.loginRequired(repo) }
      throw HFError.notFound(repo)
    case 404:
      if response.headers["x-error-code"] == "EntryNotFound" || file {
        throw HFError.badResponse("a file listed by Hugging Face could not be read")
      }
      throw HFError.notFound(repo)
    case 429:
      throw HFError.rateLimited(retryAfterSeconds: Self.retryAfter(response.headers))
    default:
      throw HFError.upstream(status: response.status)
    }
  }

  static func retryAfter(_ headers: [String: String]) -> Int? {
    if let value = headers["retry-after"], let seconds = Int(value.trimmed) { return seconds }
    // RateLimit: "api";r=0;t=55
    if let value = headers["ratelimit"],
      let match = value.range(of: #"t=(\d+)"#, options: .regularExpression)
    {
      return Int(value[match].dropFirst(2))
    }
    return nil
  }

  static func nextLink(_ header: String?, sameHostAs endpoint: URL) -> URL? {
    guard let header else { return nil }
    for part in header.split(separator: ",") where part.contains("rel=\"next\"") {
      guard let start = part.firstIndex(of: "<"), let end = part.firstIndex(of: ">"), start < end,
        let url = URL(string: String(part[part.index(after: start)..<end])),
        url.host?.lowercased() == endpoint.host?.lowercased(), url.scheme == endpoint.scheme
      else { return nil }
      return url
    }
    return nil
  }

  static func object(_ data: Data) throws -> [String: Any] {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw HFError.badResponse("not a JSON object")
    }
    return object
  }

  static let unreserved = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

  static func encodeSegment(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
  }

  static func encodeQuery(_ value: String) -> String {
    var allowed = unreserved
    allowed.insert(charactersIn: ":")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
  }
}

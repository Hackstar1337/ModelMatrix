import Foundation

/// `GET /api/hf/check?name=<owner/name>[&context=N][&format=text]` and
/// `GET /api/hf/search?q=<text>`. Both are read-only: they look things up
/// on Hugging Face and on this machine, and never download or install.
extension ControllerRouter {
  var huggingFaceRoutes: [RouteKey: Route] {
    [
      RouteKey(method: "GET", path: "/api/hf/check"): { [self] request in
        try huggingFaceCheck(request)
      },
      RouteKey(method: "GET", path: "/api/hf/search"): { [self] request in
        try huggingFaceSearch(request)
      },
    ]
  }

  func huggingFaceCheck(_ request: ControllerHTTPRequest) throws -> ControllerHTTPResponse {
    let query = Self.formQuery(request.target)
    guard let name = query["name"], !name.isEmpty else {
      return try error(status: 400, code: "invalid_name", message: "missing query parameter: name")
    }
    var context: Int?
    if let raw = query["context"], !raw.isEmpty {
      guard let value = Self.contextValue(raw), HFCheckService.contextRange.contains(value) else {
        return try error(
          status: 400, code: "invalid_context",
          message: "context must be a number of tokens between 512 and 1048576 (16K and 32k are accepted)")
      }
      context = value
    }
    if query["refresh"] == "1" { huggingFace.engines.refresh() }
    do {
      let report = try huggingFace.check(name, context: context)
      if query["format"] == "text" {
        return ControllerHTTPResponse(
          status: 200, headers: ["Content-Type": "text/plain; charset=utf-8"],
          body: Data(HFCheckText.render(report).utf8))
      }
      return ControllerHTTPResponse(status: 200, body: try HFJSON.data(report))
    } catch let failure as HFError {
      return try huggingFaceError(failure, text: query["format"] == "text")
    }
  }

  func huggingFaceSearch(_ request: ControllerHTTPRequest) throws -> ControllerHTTPResponse {
    let query = Self.formQuery(request.target)
    let text = (query["q"] ?? "").trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty, text.count <= 100,
      text.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || " ._-+/".unicodeScalars.contains($0) })
    else {
      return try error(status: 400, code: "invalid_query", message: "q must be 1-100 letters, digits, spaces or . _ - + /")
    }
    do {
      let results = try huggingFace.search(text, machine: HFMachine.current(), limit: 10)
      return ControllerHTTPResponse(status: 200, body: try HFJSON.data(["results": results]))
    } catch let failure as HFError {
      return try huggingFaceError(failure, text: false)
    }
  }

  func huggingFaceError(_ failure: HFError, text: Bool) throws -> ControllerHTTPResponse {
    if text {
      return ControllerHTTPResponse(
        status: failure.httpStatus, headers: ["Content-Type": "text/plain; charset=utf-8"],
        body: Data("error: \(failure.description)\n".utf8))
    }
    return try error(status: failure.httpStatus, code: failure.code, message: failure.description)
  }

  /// Query parameters with form encoding: `+` is a space (curl
  /// `--data-urlencode` and browser forms send spaces that way).
  static func formQuery(_ target: String) -> [String: String] {
    guard let mark = target.firstIndex(of: "?") else { return [:] }
    var items: [String: String] = [:]
    for pair in target[target.index(after: mark)...].split(separator: "&") {
      let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      let decode = { (text: Substring) in
        String(text).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? ""
      }
      guard let key = parts.first.map(decode), !key.isEmpty, items[key] == nil else { continue }
      items[key] = parts.count > 1 ? decode(parts[1]) : ""
    }
    return items
  }

  /// "32768", "32k" or "32K" -> 32768.
  static func contextValue(_ raw: String) -> Int? {
    let text = raw.trimmingCharacters(in: .whitespaces).lowercased()
    if text.hasSuffix("k"), let value = Int(text.dropLast()), value > 0, value <= 1024 { return value * 1024 }
    return Int(text)
  }
}

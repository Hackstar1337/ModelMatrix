import Foundation

extension ControllerRouter {
  static let securityHeaders: [String: String] = [
    "X-Content-Type-Options": "nosniff",
    "X-Frame-Options": "DENY",
    "Referrer-Policy": "no-referrer",
    "Cross-Origin-Opener-Policy": "same-origin",
    "Cross-Origin-Resource-Policy": "same-origin",
  ]

  static let contentSecurityPolicy =
    "default-src 'self'; img-src 'self' data: blob:; style-src 'self' 'unsafe-inline'; "
    + "script-src 'self'; connect-src 'self'; font-src 'self' data:; worker-src 'self' blob:; "
    + "frame-ancestors 'none'; base-uri 'none'; form-action 'self'; object-src 'none'"

  /// Static dashboard files. The HTML document hands out the session cookie
  /// when the controller runs without a bearer token (loopback default).
  func dashboardResponse(_ request: ControllerHTTPRequest) throws -> ControllerHTTPResponse {
    guard request.method == "GET" else {
      return try error(status: 405, code: "method_not_allowed", message: "method not allowed")
    }
    var headers = Self.securityHeaders
    guard let file = dashboard.file(forPath: request.path) else {
      if dashboard.directory == nil {
        headers["Content-Type"] = "text/html; charset=utf-8"
        headers["Cache-Control"] = "no-store"
        return ControllerHTTPResponse(
          status: 200, headers: headers, body: Data(DashboardAssets.placeholderHTML.utf8))
      }
      return try error(status: 404, code: "not_found", message: "not found")
    }
    let body: Data
    do {
      body = try Data(contentsOf: file)
    } catch {
      return try self.error(status: 404, code: "not_found", message: "not found")
    }
    let isDocument = file.pathExtension.lowercased() == "html"
    headers["Content-Type"] = DashboardAssets.mimeType(for: file)
    if isDocument {
      headers["Cache-Control"] = "no-store"
      headers["Content-Security-Policy"] = Self.contentSecurityPolicy
      let existing = DashboardRequestGuard.cookie(DashboardSession.cookieName, in: request)
      if authToken == nil, !session.isValid(existing) {
        headers["Set-Cookie"] = session.cookieHeader(for: session.issue())
      }
    } else if request.path.hasPrefix("/assets/") {
      headers["Cache-Control"] = "public, max-age=31536000, immutable"
    } else {
      headers["Cache-Control"] = "no-cache"
    }
    return ControllerHTTPResponse(status: 200, headers: headers, body: body)
  }

  /// `GET` reports session state; `POST {token}` logs in (or, without a
  /// configured token, simply issues a session); `DELETE` logs out.
  func sessionRoute(_ request: ControllerHTTPRequest) throws -> ControllerHTTPResponse {
    let current = DashboardRequestGuard.cookie(DashboardSession.cookieName, in: request)
    switch request.method {
    case "GET":
      return try json([
        "authenticated": session.isValid(current),
        "token_required": authToken != nil,
      ])
    case "POST":
      let payload = try requestObject(request)
      if let authToken {
        let supplied = (payload["token"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        guard constantTimeEqual(supplied, authToken) else {
          return try error(status: 401, code: "invalid_token", message: "invalid token")
        }
      }
      let token = session.issue()
      var response = try json(["authenticated": true, "token_required": authToken != nil])
      var headers = response.headers
      headers["Set-Cookie"] = session.cookieHeader(for: token)
      response = ControllerHTTPResponse(status: 200, headers: headers, body: response.body)
      return response
    case "DELETE":
      session.revoke(current)
      let body = try JSONSupport.data(["authenticated": false])
      return ControllerHTTPResponse(
        status: 200,
        headers: [
          "Content-Type": "application/json",
          "Set-Cookie": "\(DashboardSession.cookieName)=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0",
        ],
        body: body)
    default:
      return try error(status: 405, code: "method_not_allowed", message: "method not allowed")
    }
  }

  /// Routes matched by prefix rather than exact path.
  func prefixRoute(_ request: ControllerHTTPRequest) throws -> ControllerHTTPResponse? {
    if request.path.hasPrefix("/api/remote/") {
      return try remoteProxy(request)
    }
    if let download = try huggingFaceDownloadPrefixRoute(request) {
      return download
    }
    if let engineJob = try huggingFaceEnginePrefixRoute(request) {
      return engineJob
    }
    if request.method == "GET", request.path.hasPrefix("/api/bridge/commands/") {
      let id = String(request.path.dropFirst("/api/bridge/commands/".count))
      guard let command = bridge.command(id: id) else {
        return try error(status: 404, code: "not_found", message: "command not found")
      }
      return try json(command.publicObject)
    }
    return nil
  }
}

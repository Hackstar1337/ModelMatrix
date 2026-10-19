import Foundation

public final class ControllerRouter: @unchecked Sendable {
  struct RouteKey: Hashable {
    let method: String
    let path: String
  }

  typealias Route = (ControllerHTTPRequest) throws -> ControllerHTTPResponse

  let service: ControllerService
  let authToken: String?
  /// Web dashboard files served at `/`.
  public var dashboard: DashboardAssets
  /// Browser session cookies for the dashboard.
  public let session: DashboardSession
  /// Mac host metrics sampler for `GET /api/host/metrics`.
  public let hostMetrics: MacHostMetricsSampler
  /// Usage statistics (metering relay database). Nil when metering is disabled.
  public var usage: UsageService?
  /// App <-> controller bridge (remote hosts and app-side actions).
  public let bridge: BridgeState
  /// Read-only Hugging Face model check for `GET /api/hf/*`.
  public let huggingFace: HFCheckService

  public init(
    service: ControllerService,
    authToken: String?,
    dashboard: DashboardAssets? = nil,
    usage: UsageService? = nil,
    bridge: BridgeState = BridgeState(),
    huggingFace: HFCheckService? = nil
  ) {
    self.service = service
    self.authToken = authToken
    self.dashboard = dashboard ?? DashboardAssets(directory: nil)
    self.session = DashboardSession()
    self.hostMetrics = MacHostMetricsSampler()
    self.usage = usage
    self.bridge = bridge
    self.huggingFace = huggingFace ?? HFCheckService()
  }

  public func handle(_ request: ControllerHTTPRequest) -> ControllerHTTPResponse {
    if let rejection = preflight(request) {
      return rejection
    }
    // Bumped on arrival (so the menu bar can show "starting" while a long
    // action runs) and again once it finishes (ready, stopped or failed).
    let changesStatus = BridgeState.changesStatus(method: request.method, path: request.path)
    if changesStatus { bridge.bumpStatusRevision() }
    defer { if changesStatus { bridge.bumpStatusRevision() } }
    return route(request)
  }

  private func route(_ request: ControllerHTTPRequest) -> ControllerHTTPResponse {
    do {
      guard request.path.hasPrefix("/api/") else {
        return try dashboardResponse(request)
      }
      if request.path == "/api/dashboard/session" {
        return try sessionRoute(request)
      }
      if let route = routes[RouteKey(method: request.method, path: request.path)] {
        return try route(request)
      }
      if let prefixed = try prefixRoute(request) {
        return prefixed
      }
      return try error(status: 404, code: "not_found", message: "not found")
    } catch RouterError.invalidJSON {
      return (try? error(status: 400, code: "invalid_json", message: "invalid JSON")) ?? fallback()
    } catch let controllerError as ControllerError {
      return mapped(controllerError)
    } catch {
      return
        (try? self.error(status: 500, code: "internal_error", message: "internal server error"))
        ?? fallback()
    }
  }

  /// Host, origin, session and token checks. Cheap and side-effect free, so
  /// the server runs it before queueing: a rejected request is answered at
  /// once even while a long action (such as a model start) holds the queue.
  public func preflight(_ request: ControllerHTTPRequest) -> ControllerHTTPResponse? {
    do {
      guard DashboardRequestGuard.hostAllowed(request, configuration: service.configuration) else {
        return try error(
          status: 403, code: "forbidden_host",
          message: "requests must be addressed to localhost")
      }
      guard request.path.hasPrefix("/api/") else { return nil }
      let browser = DashboardRequestGuard.isBrowserRequest(request)
      if browser, !DashboardRequestGuard.sameOrigin(request) {
        return try error(
          status: 403, code: "cross_origin", message: "cross-origin requests are not allowed")
      }
      if request.path == "/api/dashboard/session" { return nil }
      let sessionValid = session.isValid(
        DashboardRequestGuard.cookie(DashboardSession.cookieName, in: request))
      if browser {
        guard sessionValid else {
          return try error(
            status: 401, code: "dashboard_session_required",
            message: "open the dashboard page to start a session")
        }
      } else if !sessionValid, !authorized(request) {
        return try error(status: 401, code: "unauthorized", message: "unauthorized")
      }
      return nil
    } catch {
      return fallback()
    }
  }

  /// Routes that never touch the profile service's mutable state and may run
  /// on the server's concurrent queue (static files, usage stats, host
  /// metrics, bridge, remote proxy, read-only Hugging Face checks).
  public func runsConcurrently(_ request: ControllerHTTPRequest) -> Bool {
    let path = request.path
    if !path.hasPrefix("/api/") { return true }
    for prefix in [
      "/api/usage/", "/api/host/", "/api/bridge/", "/api/remote/", "/api/ollama/",
      "/api/dashboard/", "/api/optimize/purge", "/api/hf/",
    ] where path.hasPrefix(prefix) {
      return true
    }
    return false
  }
}

enum RouterError: Error { case invalidJSON }

import Foundation
import Network

extension ControllerHTTPServer {
  func applyParse(
    _ result: HTTPParseResult,
    connection: NWConnection,
    buffer: Data,
    complete: Bool,
    error: Error?
  ) {
    switch result {
    case .request(let request):
      // Profile actions stay strictly serialized (as before); reads, usage
      // stats, host metrics and dashboard files run concurrently so a slow
      // model start never freezes the dashboard. Security checks run first,
      // so a rejected request is never queued behind a long action.
      let serialized = !(request.method == "GET" || router.runsConcurrently(request))
      concurrentQueue.async { [self] in
        if let rejection = router.preflight(request) {
          send(rejection, connection: connection)
        } else if serialized {
          actionQueue.async { [self] in send(router.handle(request), connection: connection) }
        } else {
          send(router.handle(request), connection: connection)
        }
      }
    case .needMore where !complete && error == nil:
      receive(connection, buffer: buffer)
    case .error(let status, let code, let message):
      let body =
        (try? JSONSupport.data(["error": code, "message": message])) ?? Data()
      send(ControllerHTTPResponse(status: status, body: body), connection: connection)
    default:
      connection.cancel()
    }
  }

  func send(_ response: ControllerHTTPResponse, connection: NWConnection) {
    let reason =
      [
        200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
        404: "Not Found", 405: "Method Not Allowed", 409: "Conflict", 413: "Payload Too Large",
        431: "Request Header Fields Too Large", 500: "Internal Server Error", 502: "Bad Gateway",
        503: "Service Unavailable", 504: "Gateway Timeout",
      ][response.status] ?? "OK"
    var headers = response.headers
    headers["Content-Length"] = String(response.body.count)
    headers["Connection"] = "close"
    var message = Data("HTTP/1.1 \(response.status) \(reason)\r\n".utf8)
    for key in headers.keys.sorted() { message.append(Data("\(key): \(headers[key]!)\r\n".utf8)) }
    message.append(Data("\r\n".utf8))
    message.append(response.body)
    connection.send(content: message, completion: .contentProcessed { _ in connection.cancel() })
  }
}

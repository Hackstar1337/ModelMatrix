import Foundation

/// One HTTP answer, with lower-cased header names.
public struct HFHTTPResponse: Sendable {
  public let status: Int
  public let headers: [String: String]
  public let body: Data

  public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
    self.status = status
    self.headers = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
    self.body = body
  }
}

/// Network access for the check, replaceable in tests.
public protocol HFTransport: Sendable {
  /// GET `url`. Must give up after `timeout` seconds and must never hold more
  /// than `maxBytes` of body in memory (answers that are larger fail).
  func get(_ url: URL, headers: [String: String], maxBytes: Int, timeout: TimeInterval) throws
    -> HFHTTPResponse
}

/// URLSession transport: ephemeral (no cookies or disk cache), system proxy
/// settings, HTTPS-only redirects, streaming size cap.
public struct URLSessionHFTransport: HFTransport {
  public init() {}

  public func get(_ url: URL, headers: [String: String], maxBytes: Int, timeout: TimeInterval)
    throws -> HFHTTPResponse
  {
    let collector = HFResponseCollector(
      maxBytes: maxBytes, allowedScheme: url.scheme ?? "https", originalHost: url.host?.lowercased() ?? "")
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = timeout
    configuration.timeoutIntervalForResource = timeout
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.httpCookieAcceptPolicy = .never
    let session = URLSession(configuration: configuration, delegate: collector, delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(url: url, timeoutInterval: timeout)
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    let task = session.dataTask(with: request)
    task.resume()
    if collector.wait(seconds: timeout + 1) == false {
      task.cancel()
      throw HFError.unreachable("timed out after \(Int(timeout)) seconds")
    }
    return try collector.result()
  }
}

/// Collects one response body, cancelling once it grows past the cap.
final class HFResponseCollector: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private let lock = NSLock()
  private let done = DispatchSemaphore(value: 0)
  private let maxBytes: Int
  private let allowedScheme: String
  private let originalHost: String
  private var response: HTTPURLResponse?
  private var data = Data()
  private var failure: HFError?

  init(maxBytes: Int, allowedScheme: String, originalHost: String) {
    self.maxBytes = maxBytes
    self.allowedScheme = allowedScheme.lowercased()
    self.originalHost = originalHost
  }

  func wait(seconds: TimeInterval) -> Bool {
    done.wait(timeout: .now() + seconds) == .success
  }

  func result() throws -> HFHTTPResponse {
    lock.lock()
    defer { lock.unlock() }
    if let failure { throw failure }
    guard let response else { throw HFError.badResponse("no HTTP response") }
    var headers: [String: String] = [:]
    for (key, value) in response.allHeaderFields {
      if let key = key as? String { headers[key.lowercased()] = "\(value)" }
    }
    return HFHTTPResponse(status: response.statusCode, headers: headers, body: data)
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
  ) {
    // File reads redirect to a signed CDN address. Follow only secure
    // redirects (or same-scheme ones for a plain-HTTP mirror).
    let scheme = request.url?.scheme?.lowercased() ?? ""
    guard scheme == "https" || scheme == allowedScheme else { return completionHandler(nil) }
    completionHandler(HFRedirect.stripCredentials(request, originalHost: originalHost))
  }

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    lock.lock()
    self.response = response as? HTTPURLResponse
    lock.unlock()
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
    lock.lock()
    if data.count + chunk.count > maxBytes {
      failure = HFError.badResponse("answer larger than \(maxBytes / 1024) KB")
      lock.unlock()
      dataTask.cancel()
      return
    }
    data.append(chunk)
    lock.unlock()
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    lock.lock()
    if let error, failure == nil {
      failure = HFError.unreachable((error as NSError).localizedDescription)
    }
    lock.unlock()
    done.signal()
  }
}

enum HFRedirect {
  /// The Hugging Face token must never reach a download server: drop it
  /// whenever a redirect leaves the host it was meant for.
  static func stripCredentials(_ request: URLRequest, originalHost: String) -> URLRequest {
    guard request.url?.host?.lowercased() != originalHost else { return request }
    var copy = request
    copy.setValue(nil, forHTTPHeaderField: "Authorization")
    return copy
  }
}

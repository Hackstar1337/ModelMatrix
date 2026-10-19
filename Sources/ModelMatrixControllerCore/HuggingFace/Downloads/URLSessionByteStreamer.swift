import Foundation

/// Streams byte ranges with URLSession: system proxy settings, no caching,
/// HTTPS-only redirects (or the mirror's own scheme), and the Hugging Face
/// token dropped as soon as a redirect leaves the Hugging Face host.
public struct URLSessionByteStreamer: HFByteStreamer {
  /// Seconds without any data before a connection counts as lost.
  public var idleTimeout: TimeInterval = 60

  public init() {}

  public func stream(
    _ url: URL, headers: [String: String], range: ClosedRange<Int64>,
    head: @escaping (HFStreamHead) throws -> Void, data: @escaping (Data) throws -> Bool,
    shouldStop: @escaping () -> Bool
  ) throws {
    let delegate = HFStreamDelegate(
      head: head, data: data, allowedScheme: url.scheme?.lowercased() ?? "https",
      originalHost: url.host?.lowercased() ?? "")
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = idleTimeout
    configuration.timeoutIntervalForResource = 7 * 24 * 3600
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.urlCache = nil
    configuration.httpCookieAcceptPolicy = .never
    configuration.httpMaximumConnectionsPerHost = 8
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(url: url, timeoutInterval: idleTimeout)
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    let task = session.dataTask(with: request)
    task.resume()
    while !delegate.wait(seconds: 0.25) {
      if shouldStop() {
        task.cancel()
        _ = delegate.wait(seconds: 5)
        throw HFTransferError.stopped
      }
    }
    if let failure = delegate.failure { throw failure }
  }
}

final class HFStreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private let head: (HFStreamHead) throws -> Void
  private let data: (Data) throws -> Bool
  private let allowedScheme: String
  private let originalHost: String
  private let done = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var storedFailure: HFTransferError?
  private var finishedEarly = false

  init(
    head: @escaping (HFStreamHead) throws -> Void, data: @escaping (Data) throws -> Bool, allowedScheme: String,
    originalHost: String
  ) {
    self.head = head
    self.data = data
    self.allowedScheme = allowedScheme
    self.originalHost = originalHost
  }

  var failure: HFTransferError? {
    lock.lock()
    defer { lock.unlock() }
    return storedFailure
  }

  func wait(seconds: TimeInterval) -> Bool {
    done.wait(timeout: .now() + seconds) == .success
  }

  private func fail(_ failure: HFTransferError) {
    lock.lock()
    if storedFailure == nil { storedFailure = failure }
    lock.unlock()
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
  ) {
    let scheme = request.url?.scheme?.lowercased() ?? ""
    guard scheme == "https" || scheme == allowedScheme else {
      fail(.network("refused an insecure redirect"))
      return completionHandler(nil)
    }
    var next = HFRedirect.stripCredentials(request, originalHost: originalHost)
    // Keep the byte range on the redirected request.
    if next.value(forHTTPHeaderField: "Range") == nil,
      let range = task.originalRequest?.value(forHTTPHeaderField: "Range")
    {
      next.setValue(range, forHTTPHeaderField: "Range")
    }
    completionHandler(next)
  }

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    guard let http = response as? HTTPURLResponse else {
      fail(.network("no HTTP response"))
      return completionHandler(.cancel)
    }
    var headers: [String: String] = [:]
    for (key, value) in http.allHeaderFields {
      if let key = key as? String { headers[key] = "\(value)" }
    }
    do {
      try head(HFStreamHead(status: http.statusCode, headers: headers, host: http.url?.host ?? ""))
      completionHandler(.allow)
    } catch let failure as HFTransferError {
      fail(failure)
      completionHandler(.cancel)
    } catch {
      fail(.network(error.localizedDescription))
      completionHandler(.cancel)
    }
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
    do {
      if try data(chunk) == false {
        lock.lock()
        finishedEarly = true
        lock.unlock()
        dataTask.cancel()
      }
    } catch let failure as HFTransferError {
      fail(failure)
      dataTask.cancel()
    } catch {
      fail(.disk(error.localizedDescription))
      dataTask.cancel()
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    lock.lock()
    let early = finishedEarly
    lock.unlock()
    if let error = error as NSError?, !early {
      if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled {
        // Cancelled by us; a failure (if any) is already recorded.
      } else {
        fail(.network(error.localizedDescription))
      }
    }
    done.signal()
  }
}

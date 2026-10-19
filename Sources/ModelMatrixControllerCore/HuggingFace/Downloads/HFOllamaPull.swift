import Foundation

/// Asks Ollama to download a model (`hf.co/owner/name:VERSION`). Ollama
/// resumes its own downloads. Replaceable in tests.
public protocol HFOllamaPulling: Sendable {
  /// Blocks until the pull finishes. `progress` gets Ollama's status line and
  /// the bytes done and total across all layers.
  func pull(
    model: String, progress: @escaping (_ status: String, _ completed: Int64, _ total: Int64) -> Void,
    shouldStop: @escaping () -> Bool
  ) throws

  /// Whether Ollama already has the model; nil when Ollama can't be asked.
  func hasModel(_ model: String) -> Bool?
}

extension HFOllamaPulling {
  public func hasModel(_ model: String) -> Bool? { nil }
}

public enum HFOllamaError: Error, Equatable {
  case notRunning
  case failed(String)
  case stopped
}

public struct HFOllamaClient: HFOllamaPulling {
  public let baseURL: URL

  public init(baseURL: URL? = nil) {
    self.baseURL = baseURL ?? HFOllamaClient.environmentURL()
  }

  /// `OLLAMA_HOST` (e.g. "127.0.0.1:11434" or "http://host:port"), otherwise the default.
  static func environmentURL() -> URL {
    if let raw = ProcessInfo.processInfo.environment["OLLAMA_HOST"]?.trimmingCharacters(in: .whitespaces),
      !raw.isEmpty
    {
      let text = raw.contains("://") ? raw : "http://\(raw)"
      if let url = URL(string: text), let host = url.host, ["127.0.0.1", "localhost", "::1"].contains(host) {
        return url
      }
    }
    return URL(string: "http://127.0.0.1:11434")!
  }

  public func hasModel(_ model: String) -> Bool? {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.connectionProxyDictionary = [:]
    let session = URLSession(configuration: configuration)
    defer { session.finishTasksAndInvalidate() }
    let done = DispatchSemaphore(value: 0)
    let box = HFChatBox()
    session.dataTask(with: URLRequest(url: baseURL.appendingPathComponent("api/tags"), timeoutInterval: 5)) {
      data, response, error in
      box.set(data: data, status: (response as? HTTPURLResponse)?.statusCode, error: error)
      done.signal()
    }.resume()
    guard done.wait(timeout: .now() + 6) == .success else { return nil }
    let (data, status, error) = box.get()
    guard error == nil, status == 200, let data,
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let models = object["models"] as? [[String: Any]]
    else { return nil }
    let wanted = HFOllamaClient.normalized(model)
    return models.contains { entry in
      [entry["name"], entry["model"]].compactMap { $0 as? String }.contains { HFOllamaClient.normalized($0) == wanted }
    }
  }

  /// Ollama names compare without case and without a ":latest" tag.
  static func normalized(_ name: String) -> String {
    let lower = name.lowercased()
    return lower.hasSuffix(":latest") ? String(lower.dropLast(7)) : lower
  }

  /// Deletes a model from Ollama (`DELETE /api/delete`). A model Ollama
  /// doesn't have counts as deleted.
  public func remove(model: String) throws {
    var request = URLRequest(url: baseURL.appendingPathComponent("api/delete"), timeoutInterval: 30)
    request.httpMethod = "DELETE"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model])
    let configuration = URLSessionConfiguration.ephemeral
    configuration.connectionProxyDictionary = [:]
    let session = URLSession(configuration: configuration)
    defer { session.finishTasksAndInvalidate() }
    let done = DispatchSemaphore(value: 0)
    let box = HFChatBox()
    session.dataTask(with: request) { data, response, error in
      box.set(data: data, status: (response as? HTTPURLResponse)?.statusCode, error: error)
      done.signal()
    }.resume()
    guard done.wait(timeout: .now() + 35) == .success else { throw HFError.unreachable("Ollama didn't answer.") }
    let (_, status, error) = box.get()
    if error != nil { throw HFError.unreachable("Ollama isn't running, so the model couldn't be deleted from it.") }
    guard status == 200 || status == 404 else { throw HFError.upstream(status: status ?? 0) }
  }

  public func pull(
    model: String, progress: @escaping (String, Int64, Int64) -> Void, shouldStop: @escaping () -> Bool
  ) throws {
    let collector = HFOllamaStream(progress: progress)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 300
    configuration.timeoutIntervalForResource = 7 * 24 * 3600
    configuration.connectionProxyDictionary = [:]
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    let session = URLSession(configuration: configuration, delegate: collector, delegateQueue: queue)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(url: baseURL.appendingPathComponent("api/pull"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "stream": true])
    let task = session.dataTask(with: request)
    task.resume()
    while !collector.wait(seconds: 0.25) {
      if shouldStop() {
        task.cancel()
        _ = collector.wait(seconds: 5)
        throw HFOllamaError.stopped
      }
    }
    if let failure = collector.failure { throw failure }
    guard collector.succeeded else { throw HFOllamaError.failed("Ollama stopped before the download finished") }
  }
}

final class HFOllamaStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private let progress: (String, Int64, Int64) -> Void
  private let done = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var buffer = Data()
  private var layers: [String: (Int64, Int64)] = [:]
  private(set) var failure: HFOllamaError?
  private(set) var succeeded = false
  private var status = 200

  init(progress: @escaping (String, Int64, Int64) -> Void) {
    self.progress = progress
  }

  func wait(seconds: TimeInterval) -> Bool {
    done.wait(timeout: .now() + seconds) == .success
  }

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    status = (response as? HTTPURLResponse)?.statusCode ?? 0
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    buffer.append(data)
    while let newline = buffer.firstIndex(of: 0x0A) {
      let line = buffer[buffer.startIndex..<newline]
      buffer.removeSubrange(buffer.startIndex...newline)
      handle(Data(line))
    }
  }

  func handle(_ line: Data) {
    guard !line.isEmpty, let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
      return
    }
    if let error = object["error"] as? String {
      failure = .failed(error)
      return
    }
    let text = object["status"] as? String ?? ""
    if let digest = object["digest"] as? String {
      let total = (object["total"] as? NSNumber)?.int64Value ?? layers[digest]?.1 ?? 0
      let completed = (object["completed"] as? NSNumber)?.int64Value ?? layers[digest]?.0 ?? 0
      layers[digest] = (completed, total)
    }
    if text == "success" { succeeded = true }
    let completed = layers.values.reduce(0) { $0 + $1.0 }
    let total = layers.values.reduce(0) { $0 + $1.1 }
    progress(text, completed, total)
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    if !buffer.isEmpty { handle(buffer) }
    if let error = error as NSError?, failure == nil {
      if error.domain == NSURLErrorDomain,
        [NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost, NSURLErrorNetworkConnectionLost].contains(error.code)
      {
        failure = .notRunning
      } else if error.code != NSURLErrorCancelled {
        failure = .failed(error.localizedDescription)
      }
    } else if status >= 400, failure == nil {
      failure = .failed("Ollama answered with HTTP \(status)")
    }
    done.signal()
  }
}

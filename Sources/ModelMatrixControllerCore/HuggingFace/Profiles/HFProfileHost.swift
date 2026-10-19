import Darwin
import Foundation
import ModelMatrixCore

/// What the automatic profile step needs from the controller. The real one
/// is `ControllerProfileHost`; tests use a fake.
public protocol HFProfileHosting: AnyObject, Sendable {
  /// Every profile's settings, by profile name.
  func allProfiles() -> [String: [String: String]]
  /// Writes a new profile (fails if the name is taken).
  func createProfile(name: String, values: [String: String]) throws
  /// Replaces an existing profile's settings.
  func updateProfile(name: String, values: [String: String]) throws
  /// Starts the profile and waits until its server answers (throws if it doesn't).
  func startProfile(_ name: String) throws
  /// Stops (if running) and deletes the profile.
  func deleteProfile(_ name: String) throws
  func isRunning(_ name: String) -> Bool
  /// The last lines of the profile's server log.
  func logTail(_ name: String, lines: Int) -> [String]
}

/// Connects the profile step to the controller's normal profile handling,
/// so automatic profiles behave exactly like hand-made ones.
public final class ControllerProfileHost: HFProfileHosting, @unchecked Sendable {
  let service: ControllerService

  public init(service: ControllerService) {
    self.service = service
  }

  public func allProfiles() -> [String: [String: String]] {
    ((try? service.profiles.load()) ?? [:]).mapValues(\.values)
  }

  public func createProfile(name: String, values: [String: String]) throws {
    try service.saveProfile(name: name, values: values, createOnly: true)
  }

  public func updateProfile(name: String, values: [String: String]) throws {
    try service.saveProfile(name: name, values: values, originalName: name)
  }

  public func startProfile(_ name: String) throws {
    try service.start(name)
  }

  public func deleteProfile(_ name: String) throws {
    try service.deleteProfile(name)
  }

  public func isRunning(_ name: String) -> Bool {
    (try? service.statusPayload(selected: [name]).statuses.first?.running) == true
  }

  public func logTail(_ name: String, lines: Int) -> [String] {
    guard let profile = try? service.profiles.profile(named: name) else { return [] }
    return HFLogTail.read(profile.logPath, lines: lines)
  }
}

enum HFLogTail {
  /// The last `lines` non-empty lines of a log file (reads at most 256 KB).
  static func read(_ path: String, lines: Int) -> [String] {
    guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
    defer { try? handle.close() }
    let size = (try? handle.seekToEnd()) ?? 0
    let window: UInt64 = 256 * 1024
    try? handle.seek(toOffset: size > window ? size - window : 0)
    let data = (try? handle.readToEnd()) ?? Data()
    let text = String(decoding: data, as: UTF8.self)
    let all = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    return all.suffix(lines).map { $0.count > 300 ? String($0.prefix(300)) + "…" : $0 }
  }
}

/// Sends the one-word test message after a model starts.
public protocol HFChatTesting: Sendable {
  /// Returns the model's reply (possibly empty). Throws when the server
  /// doesn't answer with HTTP 200. `retryable` errors mean "try again shortly".
  func send(baseURL: URL, model: String, timeout: TimeInterval) throws -> String
}

public struct HFChatTestError: Error, Sendable {
  public var message: String
  /// The relay didn't know the model yet, or the server was still loading.
  public var retryable: Bool
}

public struct HFChatTester: HFChatTesting {
  public init() {}

  public func send(baseURL: URL, model: String, timeout: TimeInterval) throws -> String {
    var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"), timeoutInterval: timeout)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("ModelMatrix setup test", forHTTPHeaderField: "X-Client-Name")
    let body: [String: Any] = [
      "model": model,
      "messages": [["role": "user", "content": "Reply with one word: ready"]],
      "max_tokens": 8,
      "temperature": 0,
      "stream": false,
    ]
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.connectionProxyDictionary = [:]
    configuration.timeoutIntervalForRequest = timeout
    configuration.timeoutIntervalForResource = timeout
    let session = URLSession(configuration: configuration)
    defer { session.finishTasksAndInvalidate() }
    let done = DispatchSemaphore(value: 0)
    let box = HFChatBox()
    session.dataTask(with: request) { data, response, error in
      box.set(data: data, status: (response as? HTTPURLResponse)?.statusCode, error: error)
      done.signal()
    }.resume()
    if done.wait(timeout: .now() + timeout + 5) == .timedOut {
      throw HFChatTestError(message: "the model didn't answer within \(Int(timeout)) seconds", retryable: false)
    }
    let (data, status, error) = box.get()
    if let error {
      throw HFChatTestError(message: error.localizedDescription, retryable: true)
    }
    let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    guard status == 200 else {
      let detail =
        ((object?["error"] as? [String: Any])?["message"] as? String)
        ?? (object?["error"] as? String)
        ?? data.map { String(decoding: $0.prefix(200), as: UTF8.self) } ?? ""
      // 503: the relay hasn't seen the new server yet, or the server is loading.
      throw HFChatTestError(message: "HTTP \(status ?? 0) \(detail)".trimmingCharacters(in: .whitespaces), retryable: status == 503)
    }
    let message = ((object?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])
    let reply = (message?["content"] as? String) ?? (message?["reasoning_content"] as? String) ?? ""
    return reply.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

final class HFChatBox: @unchecked Sendable {
  private let lock = NSLock()
  private var data: Data?
  private var status: Int?
  private var error: Error?

  func set(data: Data?, status: Int?, error: Error?) {
    lock.lock()
    self.data = data
    self.status = status
    self.error = error
    lock.unlock()
  }

  func get() -> (Data?, Int?, Error?) {
    lock.lock()
    defer { lock.unlock() }
    return (data, status, error)
  }
}

public enum HFLocalPorts {
  /// True when nothing on this Mac is listening on the port.
  public static func isFree(_ port: Int) -> Bool {
    guard (1...65_535).contains(port) else { return false }
    let socketFD = socket(AF_INET, SOCK_STREAM, 0)
    guard socketFD >= 0 else { return false }
    defer { close(socketFD) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(UInt16(port).bigEndian)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    return result == 0
  }
}

public enum HFLocalMemory {
  /// Memory that can be given to a new model now: free plus cached (which
  /// macOS hands back on demand). Nil when it can't be read.
  public static func available() -> Int64? {
    guard let snapshot = MemorySnapshot.current() else { return nil }
    let used = snapshot.usedBytes
    return snapshot.totalBytes > used ? Int64(snapshot.totalBytes - used) : 0
  }

  /// Physical processor cores (for processor-only machines).
  public static func physicalCores() -> Int {
    var cores: Int32 = 0
    var size = MemoryLayout<Int32>.size
    if sysctlbyname("hw.physicalcpu", &cores, &size, nil, 0) == 0, cores > 0 { return Int(cores) }
    return max(1, ProcessInfo.processInfo.activeProcessorCount / 2)
  }

  /// The real path with symlinks resolved the way Python's Path.resolve()
  /// does it (keeps /private on macOS), which is how mlx-lm names the model.
  public static func realPath(_ path: String) -> String {
    guard let resolved = Darwin.realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
  }
}

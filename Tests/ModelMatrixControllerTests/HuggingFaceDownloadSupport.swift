import CryptoKit
import Foundation
@testable import ModelMatrixControllerCore

/// Serves file bytes for `/owner/name/resolve/<revision>/<file>` with byte
/// ranges, and injects one fault per request in order: dropped connections,
/// damaged data, expired links, rate limits, login errors, ignored ranges.
final class FakeByteStreamer: HFByteStreamer, @unchecked Sendable {
  enum Fault {
    /// The connection drops after this many bytes of the answer.
    case drop(after: Int64)
    /// One byte of the answer is changed.
    case corrupt
    /// Answer with this status instead (host: who answered).
    case status(Int, headers: [String: String], host: String)
    /// Send the whole file with 200, ignoring the range.
    case ignoreRange
    /// Call `action` after this many bytes, then keep sending.
    case hook(after: Int64, action: @Sendable () -> Void)
  }

  struct Request {
    let url: URL
    let headers: [String: String]
    let range: ClosedRange<Int64>
  }

  private let lock = NSLock()
  private var queue: [Fault] = []
  private var log: [Request] = []
  var files: [String: Data] = [:]
  var chunkSize = 64 * 1024

  init(files: [String: Data] = [:], faults: [Fault] = []) {
    self.files = files
    self.queue = faults
  }

  var requests: [Request] {
    lock.lock()
    defer { lock.unlock() }
    return log
  }

  func add(_ faults: [Fault]) {
    lock.lock()
    queue += faults
    lock.unlock()
  }

  func stream(
    _ url: URL, headers: [String: String], range: ClosedRange<Int64>, head: @escaping (HFStreamHead) throws -> Void,
    data: @escaping (Data) throws -> Bool, shouldStop: @escaping () -> Bool
  ) throws {
    lock.lock()
    log.append(Request(url: url, headers: headers, range: range))
    let fault = queue.isEmpty ? nil : queue.removeFirst()
    lock.unlock()
    let parts = url.path.split(separator: "/").map(String.init)
    let path = parts.count > 4 ? parts[4...].joined(separator: "/") : ""
    guard let content = files[path] else {
      try head(HFStreamHead(status: 404, headers: ["x-error-code": "EntryNotFound"], host: url.host ?? ""))
      return
    }
    if case .status(let code, let extra, let host) = fault {
      try head(HFStreamHead(status: code, headers: extra, host: host))
      return
    }
    var start = Int(range.lowerBound)
    var body: Data
    if case .ignoreRange = fault {
      start = 0
      body = content
      try head(HFStreamHead(status: 200, headers: [:], host: "cdn.example"))
    } else {
      let end = min(Int(range.upperBound), content.count - 1)
      body = content.subdata(in: start..<(end + 1))
      try head(HFStreamHead(
        status: 206, headers: ["Content-Range": "bytes \(start)-\(end)/\(content.count)"], host: "cdn.example"))
    }
    if case .corrupt = fault, !body.isEmpty {
      body[body.startIndex + body.count / 2] ^= 0xFF
    }
    var sent: Int64 = 0
    var hooked = false
    var offset = 0
    while offset < body.count {
      if shouldStop() { throw HFTransferError.stopped }
      if case .drop(let after) = fault, sent >= after { throw HFTransferError.network("connection dropped") }
      if case .hook(let after, let action) = fault, !hooked, sent >= after {
        hooked = true
        action()
      }
      var length = min(chunkSize, body.count - offset)
      if case .drop(let after) = fault { length = min(length, Int(after - sent)) }
      let chunk = body.subdata(in: offset..<(offset + length))
      offset += length
      sent += Int64(length)
      if try data(chunk) == false { return }
    }
    if shouldStop() { throw HFTransferError.stopped }
  }
}

final class FakeNetwork: HFNetworkStatus, @unchecked Sendable {
  private let lock = NSLock()
  private var online: Bool

  init(online: Bool = true) {
    self.online = online
  }

  var isAvailable: Bool {
    lock.lock()
    defer { lock.unlock() }
    return online
  }

  func set(_ value: Bool) {
    lock.lock()
    online = value
    lock.unlock()
  }
}

/// Records waits instead of sleeping; `onWait` can change the world meanwhile.
final class FakeClock: @unchecked Sendable {
  private let lock = NSLock()
  private var waits: [TimeInterval] = []
  var onWait: (@Sendable (Int) -> Void)?

  var total: TimeInterval {
    lock.lock()
    defer { lock.unlock() }
    return waits.reduce(0, +)
  }

  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return waits.count
  }

  var pause: @Sendable (TimeInterval) -> Void {
    { [self] seconds in
      lock.lock()
      waits.append(seconds)
      let number = waits.count
      lock.unlock()
      onWait?(number)
    }
  }
}

final class FreeSpace: @unchecked Sendable {
  private let lock = NSLock()
  private var answers: [Int64]
  private let last: Int64

  init(_ answers: [Int64], then last: Int64 = 1 << 42) {
    self.answers = answers
    self.last = last
  }

  func next(_ url: URL) -> Int64? {
    lock.lock()
    defer { lock.unlock() }
    return answers.isEmpty ? last : answers.removeFirst()
  }
}

func sha256Hex(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// Deterministic bytes that differ along the file (so misplaced pieces show).
func testBytes(_ count: Int, seed: UInt8 = 7) -> Data {
  var data = Data(count: count)
  data.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
    var value = UInt32(seed) &* 2_654_435_761
    for index in 0..<count {
      value = value &* 1_664_525 &+ 1_013_904_223
      buffer[index] = UInt8(truncatingIfNeeded: value >> 24)
    }
  }
  return data
}

struct DownloadFixture {
  let root: URL
  let models: URL
  let settings: HFSettingsStore
  let streamer: FakeByteStreamer
  let network: FakeNetwork
  let clock: FakeClock
  let manager: HFDownloadManager

  /// A job for `files` (path -> bytes) of repo "test/model".
  func job(_ files: [(String, Data)], sha: Bool = true, repo: String = "test/model") -> HFDownloadJob {
    let folder = models.appendingPathComponent(repo, isDirectory: true)
    return HFDownloadJob(
      id: HFDownloadJob.newID(), kind: "files", repo: repo, revision: "abc123", label: "Q4_K_M", format: "gguf",
      engine: "llama.cpp", displayName: "model Q4_K_M", folder: folder.path,
      files: files.map { HFDownloadFile(path: $0.0, size: Int64($0.1.count), sha256: sha ? sha256Hex($0.1) : nil) },
      context: 8192, startAfter: false)
  }

  func reopen() -> HFDownloadManager {
    let manager = HFDownloadManager(
      file: root.appendingPathComponent("downloads.json"), settings: settings,
      client: HFClient(endpoint: HFClient.defaultEndpoint, transport: FakeHFTransport()), streamer: streamer,
      network: network, freeSpace: { _ in 1 << 42 }, pause: clock.pause)
    manager.pieceThreshold = 256 * 1024
    manager.minimumPiece = 64 * 1024
    return manager
  }
}

func withDownloads(
  files: [String: Data] = [:], faults: [FakeByteStreamer.Fault] = [], connections: Int = 4,
  freeSpace: FreeSpace = FreeSpace([]), token: String? = nil, _ body: (DownloadFixture) throws -> Void
) throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("modelmatrix-dl-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: root) }
  let models = root.appendingPathComponent("Models", isDirectory: true)
  let settings = HFSettingsStore(file: root.appendingPathComponent("settings.json"))
  try settings.update {
    $0.modelsFolder = models.path
    $0.connectionsPerFile = connections
  }
  let streamer = FakeByteStreamer(files: files, faults: faults)
  let network = FakeNetwork()
  let clock = FakeClock()
  let client = HFClient(endpoint: HFClient.defaultEndpoint, transport: FakeHFTransport())
  if let token { client.setTokenProvider { token } }
  let manager = HFDownloadManager(
    file: root.appendingPathComponent("downloads.json"), settings: settings, client: client, streamer: streamer,
    network: network, freeSpace: { freeSpace.next($0) }, pause: clock.pause)
  manager.pieceThreshold = 256 * 1024
  manager.minimumPiece = 64 * 1024
  try body(
    DownloadFixture(
      root: root, models: models, settings: settings, streamer: streamer, network: network, clock: clock,
      manager: manager))
}

func partFiles(in folder: URL) -> [String] {
  let walker = FileManager.default.enumerator(atPath: folder.path)
  return (walker?.allObjects as? [String] ?? []).filter { $0.hasSuffix(".part") || $0.hasSuffix(".part.json") }
}

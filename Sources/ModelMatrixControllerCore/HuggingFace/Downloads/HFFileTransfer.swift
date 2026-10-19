import Foundation

/// Why a transfer stopped. The download manager decides whether to retry.
public enum HFTransferError: Error, Equatable, Sendable {
  /// Connection lost, timed out or the host could not be reached.
  case network(String)
  /// HTTP 429. Wait this many seconds (nil: unknown).
  case rateLimited(Int?)
  /// The signed download link expired (403 from the download server); ask again.
  case expired
  /// The files need a Hugging Face login.
  case loginRequired
  /// The file is gone from the repository.
  case notFound
  /// Other HTTP error.
  case http(Int)
  /// Writing to disk failed (for example the disk is full).
  case disk(String)
  /// The server sent a different range than asked for, or the saved progress
  /// doesn't match the file; the file starts again from the beginning.
  case restart(String)
  /// Stopped on request (pause, cancel or shutdown).
  case stopped
}

/// HTTP response head passed to `HFByteStreamer` callbacks.
public struct HFStreamHead: Sendable {
  public let status: Int
  /// Lower-cased header names.
  public let headers: [String: String]
  /// Host that answered (after redirects).
  public let host: String

  public init(status: Int, headers: [String: String], host: String) {
    self.status = status
    self.headers = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
    self.host = host.lowercased()
  }
}

/// Streams part of a file over HTTP. Replaceable in tests.
public protocol HFByteStreamer: Sendable {
  /// GET `url` with `Range: bytes=<range>`. Calls `head` once, then `data` with
  /// the body in order. Either callback may throw to stop. Must return
  /// promptly once `shouldStop` returns true.
  func stream(
    _ url: URL, headers: [String: String], range: ClosedRange<Int64>,
    head: @escaping (HFStreamHead) throws -> Void, data: @escaping (Data) throws -> Bool,
    shouldStop: @escaping () -> Bool
  ) throws
}

/// Shared download speed limit (token bucket across every connection).
public final class HFRateLimiter: @unchecked Sendable {
  private let lock = NSLock()
  private var bytesPerSecond: Double
  private var allowance: Double = 0
  private var last = Date()

  public init(bytesPerSecond: Double) {
    self.bytesPerSecond = bytesPerSecond
  }

  public func setLimit(bytesPerSecond: Double) {
    lock.lock()
    self.bytesPerSecond = bytesPerSecond
    lock.unlock()
  }

  /// Blocks just long enough to keep the total rate under the limit.
  public func consume(_ count: Int) {
    lock.lock()
    let limit = bytesPerSecond
    guard limit > 0 else {
      lock.unlock()
      return
    }
    let now = Date()
    allowance = min(limit, allowance + now.timeIntervalSince(last) * limit)
    last = now
    allowance -= Double(count)
    let wait = allowance < 0 ? -allowance / limit : 0
    lock.unlock()
    if wait > 0 { Thread.sleep(forTimeInterval: min(wait, 5)) }
  }
}

/// Downloads one file into `<folder>/.<name>.part`, in up to `connections`
/// pieces at once. Progress of every piece is saved next to it in
/// `.<name>.part.json` every couple of seconds, so after any interruption
/// each piece continues from its last saved byte.
final class HFFileTransfer: @unchecked Sendable {
  struct Piece: Codable, Equatable {
    var start: Int64
    /// Inclusive.
    var end: Int64
    var next: Int64
    var done: Bool { next > end }
  }

  struct Progress: Codable {
    var size: Int64
    var sha256: String?
    var revision: String
    var pieces: [Piece]
  }

  /// Files from this size on are split into pieces.
  static let defaultPieceThreshold: Int64 = 64 * 1024 * 1024
  static let defaultMinimumPiece: Int64 = 32 * 1024 * 1024
  static let saveInterval: TimeInterval = 2

  let url: URL
  let headers: [String: String]
  let file: HFDownloadFile
  let revision: String
  let partURL: URL
  let progressURL: URL
  let connections: Int
  let streamer: HFByteStreamer
  let limiter: HFRateLimiter
  let shouldStop: @Sendable () -> Bool
  let onProgress: @Sendable (Int64) -> Void
  /// Host of the Hugging Face address; a 403 from any other host means the
  /// signed download link expired.
  let apiHost: String
  let pieceThreshold: Int64
  let minimumPiece: Int64

  private let lock = NSLock()
  private var progress: Progress
  private var lastSave = Date.distantPast

  init(
    url: URL, headers: [String: String], file: HFDownloadFile, revision: String, partURL: URL,
    connections: Int, streamer: HFByteStreamer, limiter: HFRateLimiter, apiHost: String,
    pieceThreshold: Int64 = HFFileTransfer.defaultPieceThreshold,
    minimumPiece: Int64 = HFFileTransfer.defaultMinimumPiece,
    shouldStop: @escaping @Sendable () -> Bool, onProgress: @escaping @Sendable (Int64) -> Void
  ) {
    self.pieceThreshold = pieceThreshold
    self.minimumPiece = minimumPiece
    self.url = url
    self.headers = headers
    self.file = file
    self.revision = revision
    self.partURL = partURL
    self.progressURL = partURL.appendingPathExtension("json")
    self.connections = max(1, min(connections, 8))
    self.streamer = streamer
    self.limiter = limiter
    self.apiHost = apiHost.lowercased()
    self.shouldStop = shouldStop
    self.onProgress = onProgress
    self.progress = Progress(size: file.size, sha256: file.sha256, revision: revision, pieces: [])
  }

  static func partURL(for destination: URL) -> URL {
    destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).part")
  }

  /// Bytes already saved for `destination` from an earlier attempt.
  static func savedBytes(for destination: URL, file: HFDownloadFile, revision: String) -> Int64 {
    let progressURL = partURL(for: destination).appendingPathExtension("json")
    guard let data = try? Data(contentsOf: progressURL),
      let saved = try? JSONDecoder().decode(Progress.self, from: data),
      saved.size == file.size, saved.sha256 == file.sha256, saved.revision == revision
    else { return 0 }
    return saved.pieces.reduce(0) { $0 + ($1.next - $1.start) }
  }

  static func removePartial(for destination: URL) {
    let part = partURL(for: destination)
    try? FileManager.default.removeItem(at: part)
    try? FileManager.default.removeItem(at: part.appendingPathExtension("json"))
  }

  /// Plans the pieces of a fresh download.
  static func pieces(
    size: Int64, connections: Int, threshold: Int64 = defaultPieceThreshold, minimum: Int64 = defaultMinimumPiece
  ) -> [Piece] {
    guard size > 0 else { return [] }
    guard size >= threshold, connections > 1 else { return [Piece(start: 0, end: size - 1, next: 0)] }
    let count = Int(min(Int64(connections), max(1, size / max(minimum, 1))))
    let step = size / Int64(count)
    return (0..<count).map { index in
      let start = Int64(index) * step
      let end = index == count - 1 ? size - 1 : start + step - 1
      return Piece(start: start, end: end, next: start)
    }
  }

  var bytesDone: Int64 {
    lock.lock()
    defer { lock.unlock() }
    return progress.pieces.reduce(0) { $0 + ($1.next - $1.start) }
  }

  /// Downloads the remaining bytes. Returns when the `.part` file is complete.
  func run() throws {
    let manager = FileManager.default
    try? manager.createDirectory(at: partURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    loadProgress()
    let descriptor = open(partURL.path, O_RDWR | O_CREAT, 0o644)
    guard descriptor >= 0 else { throw HFTransferError.disk(String(cString: strerror(errno))) }
    defer { close(descriptor) }
    if file.size == 0 {
      saveProgress(force: true)
      return
    }
    var info = stat()
    if fstat(descriptor, &info) == 0, info.st_size < file.size, ftruncate(descriptor, off_t(file.size)) != 0 {
      throw HFTransferError.disk(String(cString: strerror(errno)))
    }
    onProgress(bytesDone)
    let pending = progress.pieces.indices.filter { !progress.pieces[$0].done }
    let failures = HFFailureList()
    let stopAll = HFFlag()
    let group = DispatchGroup()
    for index in pending {
      group.enter()
      Thread.detachNewThread { [self] in
        defer { group.leave() }
        do {
          try runPiece(index, descriptor: descriptor, stop: stopAll)
        } catch let failure as HFTransferError {
          failures.add(failure)
          // A fatal answer stops the other pieces; a dropped connection
          // in one piece lets the others finish what they can.
          if failure != .stopped, Self.stopsOthers(failure) { stopAll.set() }
        } catch {
          failures.add(.network(error.localizedDescription))
        }
      }
    }
    group.wait()
    saveProgress(force: true)
    if let failure = Self.decidingFailure(failures.all, userStopped: shouldStop()) { throw failure }
    guard progress.pieces.allSatisfy(\.done) else { throw HFTransferError.network("connection closed early") }
    if fsync(descriptor) != 0 { throw HFTransferError.disk(String(cString: strerror(errno))) }
  }

  /// When one piece fails for real (disk full, login, ...), the others are
  /// told to stop and report `.stopped`. That must not hide the real cause:
  /// `.stopped` only wins when the user paused or cancelled.
  static func decidingFailure(_ failures: [HFTransferError], userStopped: Bool) -> HFTransferError? {
    if userStopped, failures.contains(.stopped) { return .stopped }
    if let real = mostImportant(failures.filter { $0 != .stopped }) { return real }
    // Stopped without a reason or a user action: try again rather than hang.
    return failures.isEmpty ? nil : .network("a connection stopped early")
  }

  static func stopsOthers(_ failure: HFTransferError) -> Bool {
    switch failure {
    case .network, .expired: return false
    default: return true
    }
  }

  /// The error that decides what happens next.
  static func mostImportant(_ failures: [HFTransferError]) -> HFTransferError? {
    func rank(_ failure: HFTransferError) -> Int {
      switch failure {
      case .stopped: return 9
      case .loginRequired: return 8
      case .notFound: return 7
      case .disk: return 6
      case .restart: return 5
      case .rateLimited: return 4
      case .http: return 3
      case .expired: return 2
      case .network: return 1
      }
    }
    return failures.max { rank($0) < rank($1) }
  }

  private func runPiece(_ index: Int, descriptor: Int32, stop: HFFlag) throws {
    lock.lock()
    let piece = progress.pieces[index]
    lock.unlock()
    guard !piece.done else { return }
    var requestHeaders = headers
    requestHeaders["Range"] = "bytes=\(piece.next)-\(piece.end)"
    let expectedStart = piece.next
    try streamer.stream(
      url, headers: requestHeaders, range: piece.next...piece.end,
      head: { [self] head in
        try validate(head, expectedStart: expectedStart, piece: piece)
      },
      data: { [self] chunk in
        try write(chunk, piece: index, descriptor: descriptor)
      },
      shouldStop: { [self] in shouldStop() || stop.isSet })
    if shouldStop() || stop.isSet {
      lock.lock()
      let finished = progress.pieces[index].done
      lock.unlock()
      if !finished { throw HFTransferError.stopped }
    }
  }

  private func validate(_ head: HFStreamHead, expectedStart: Int64, piece: Piece) throws {
    switch head.status {
    case 206:
      // "bytes 100-199/1000": the server must start where we asked.
      if let range = head.headers["content-range"], let start = Self.contentRangeStart(range), start != expectedStart {
        throw HFTransferError.restart("the server sent a different part of the file")
      }
    case 200:
      // Range ignored: only usable when we asked for the whole file.
      if expectedStart != 0 { throw HFTransferError.restart("the server doesn't support resuming") }
    case 401, 403:
      if head.headers["x-error-code"] == "GatedRepo" { throw HFTransferError.loginRequired }
      if head.host != apiHost { throw HFTransferError.expired }
      throw HFTransferError.loginRequired
    case 404: throw HFTransferError.notFound
    case 416: throw HFTransferError.restart("saved progress doesn't match the file")
    case 429: throw HFTransferError.rateLimited(HFClient.retryAfter(head.headers))
    default: throw HFTransferError.http(head.status)
    }
  }

  static func contentRangeStart(_ value: String) -> Int64? {
    let text = value.lowercased().replacingOccurrences(of: "bytes", with: "").trimmingCharacters(in: .whitespaces)
    guard let dash = text.firstIndex(of: "-") else { return nil }
    return Int64(text[..<dash])
  }

  /// Writes a chunk at its place in the file. Returns false once the piece is
  /// complete (the streamer then stops reading).
  private func write(_ chunk: Data, piece index: Int, descriptor: Int32) throws -> Bool {
    lock.lock()
    let piece = progress.pieces[index]
    lock.unlock()
    let remaining = piece.end - piece.next + 1
    guard remaining > 0 else { return false }
    let usable = chunk.count > remaining ? chunk.prefix(Int(remaining)) : chunk
    var offset = piece.next
    try usable.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
      var written = 0
      while written < buffer.count {
        let result = pwrite(
          descriptor, buffer.baseAddress!.advanced(by: written), buffer.count - written, off_t(offset))
        if result < 0 {
          if errno == EINTR { continue }
          throw HFTransferError.disk(String(cString: strerror(errno)))
        }
        written += result
        offset += Int64(result)
      }
    }
    lock.lock()
    progress.pieces[index].next += Int64(usable.count)
    let finished = progress.pieces[index].done
    lock.unlock()
    limiter.consume(usable.count)
    onProgress(bytesDone)
    saveProgress(force: false)
    return !finished
  }

  private func loadProgress() {
    let fresh = Progress(
      size: file.size, sha256: file.sha256, revision: revision,
      pieces: Self.pieces(size: file.size, connections: connections, threshold: pieceThreshold, minimum: minimumPiece))
    guard FileManager.default.fileExists(atPath: partURL.path),
      let data = try? Data(contentsOf: progressURL),
      let saved = try? JSONDecoder().decode(Progress.self, from: data),
      saved.size == file.size, saved.sha256 == file.sha256, saved.revision == revision,
      Self.valid(saved.pieces, size: file.size)
    else {
      // Unknown or mismatched partial file: start over.
      try? FileManager.default.removeItem(at: partURL)
      lock.lock()
      progress = fresh
      lock.unlock()
      return
    }
    lock.lock()
    progress = saved
    lock.unlock()
  }

  /// Pieces must cover 0..<size exactly, in order.
  static func valid(_ pieces: [Piece], size: Int64) -> Bool {
    guard size > 0 else { return pieces.isEmpty }
    var expected: Int64 = 0
    for piece in pieces {
      guard piece.start == expected, piece.end >= piece.start, piece.next >= piece.start,
        piece.next <= piece.end + 1
      else { return false }
      expected = piece.end + 1
    }
    return expected == size
  }

  private func saveProgress(force: Bool) {
    lock.lock()
    guard force || Date().timeIntervalSince(lastSave) >= Self.saveInterval else {
      lock.unlock()
      return
    }
    lastSave = Date()
    let snapshot = progress
    lock.unlock()
    if let data = try? JSONEncoder().encode(snapshot) {
      try? data.write(to: progressURL, options: [.atomic])
    }
  }
}

/// Failures collected from several threads.
final class HFFailureList: @unchecked Sendable {
  private let lock = NSLock()
  private var items: [HFTransferError] = []

  func add(_ failure: HFTransferError) {
    lock.lock()
    items.append(failure)
    lock.unlock()
  }

  var all: [HFTransferError] {
    lock.lock()
    defer { lock.unlock() }
    return items
  }
}

/// A thread-safe one-way flag.
final class HFFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false

  var isSet: Bool {
    lock.lock()
    defer { lock.unlock() }
    return value
  }

  func set() {
    lock.lock()
    value = true
    lock.unlock()
  }
}

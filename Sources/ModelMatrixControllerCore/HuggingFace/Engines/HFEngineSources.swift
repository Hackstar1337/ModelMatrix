import CryptoKit
import Foundation

/// Finds official engine builds and their published SHA-256 checksums on
/// GitHub release pages.
struct HFReleaseLookup: Sendable {
  let transport: HFTransport

  struct Asset: Sendable {
    var tag: String
    var download: HFEngineDownload
  }

  /// Newest llama.cpp build that has `llama-<tag>-bin-<platform>.tar.gz`.
  /// (Builds are published as pre-releases, so "latest" isn't used.)
  func llamaCpp(platform: String) throws -> Asset {
    try llamaCpp(platform: platform, runtime: false).main
  }

  /// Like `llamaCpp(platform:)`; with `runtime`, the same release must also
  /// have the matching CUDA runtime, `cudart-llama-<tag>-bin-<platform>.tar.gz`.
  func llamaCpp(platform: String, runtime: Bool) throws -> (main: Asset, runtime: Asset?) {
    let releases = try json("https://api.github.com/repos/ggml-org/llama.cpp/releases?per_page=12") as? [[String: Any]] ?? []
    for release in releases where (release["draft"] as? Bool) != true {
      guard let tag = release["tag_name"] as? String,
        let main = Self.asset(in: release, named: "llama-\(tag)-bin-\(platform).tar.gz", tag: tag)
      else { continue }
      guard runtime else { return (main, nil) }
      if let cudart = Self.asset(in: release, named: "cudart-llama-\(tag)-bin-\(platform).tar.gz", tag: tag) {
        return (main, cudart)
      }
    }
    throw HFError.unavailable("No official llama.cpp build for \(platform) was found on GitHub right now.")
  }

  /// The latest release asset with exactly this name.
  func latest(_ repository: String, asset name: String) throws -> Asset {
    guard let release = try json("https://api.github.com/repos/\(repository)/releases/latest") as? [String: Any],
      let tag = release["tag_name"] as? String
    else { throw HFError.unavailable("GitHub didn't list a release for \(repository).") }
    guard let asset = Self.asset(in: release, named: name, tag: tag) else {
      throw HFError.unavailable("The latest \(repository) release (\(tag)) has no \(name) with a checksum.")
    }
    return asset
  }

  /// Latest mlx-lm version on PyPI (shown in the plan; nil if unknown).
  func pypiVersion(_ package: String) -> String? {
    guard let object = try? json("https://pypi.org/pypi/\(package)/json", maxBytes: 16 << 20) as? [String: Any] else { return nil }
    return (object["info"] as? [String: Any])?["version"] as? String
  }

  static func asset(in release: [String: Any], named name: String, tag: String) -> Asset? {
    for asset in release["assets"] as? [[String: Any]] ?? [] where asset["name"] as? String == name {
      guard let url = asset["browser_download_url"] as? String, url.hasPrefix("https://github.com/"),
        let size = (asset["size"] as? NSNumber)?.int64Value, size > 0,
        let digest = asset["digest"] as? String, digest.hasPrefix("sha256:")
      else { return nil }
      let sha = String(digest.dropFirst(7)).lowercased()
      guard sha.count == 64, sha.allSatisfy(\.isHexDigit) else { return nil }
      return Asset(tag: tag, download: HFEngineDownload(name: name, url: url, size: size, sha256: sha))
    }
    return nil
  }

  private func json(_ address: String, maxBytes: Int = 8 << 20) throws -> Any {
    guard let url = URL(string: address) else { throw HFError.unavailable("bad address \(address)") }
    let response = try transport.get(
      url, headers: ["Accept": "application/vnd.github+json", "User-Agent": "ModelMatrix"], maxBytes: maxBytes, timeout: 30)
    switch response.status {
    case 200: break
    case 403, 429:
      throw HFError.unavailable("\(url.host ?? "GitHub") is limiting requests right now. Try again in a few minutes.")
    default:
      throw HFError.unavailable("\(url.host ?? address) answered HTTP \(response.status).")
    }
    do {
      return try JSONSerialization.jsonObject(with: response.body)
    } catch {
      throw HFError.unavailable("\(url.host ?? address) sent an unreadable answer.")
    }
  }
}

/// Downloads one official file and checks its size and SHA-256.
struct HFEngineFetcher: Sendable {
  let streamer: HFByteStreamer

  func fetch(
    _ download: HFEngineDownload, to destination: URL, log: @escaping (String) -> Void, shouldStop: @escaping () -> Bool
  ) throws {
    guard let url = URL(string: download.url), url.scheme == "https" else {
      throw HFError.refused("Only https downloads are allowed.")
    }
    var lastError: Error = HFError.unavailable("download failed")
    for attempt in 1...3 {
      if shouldStop() { throw HFTransferError.stopped }
      do {
        try fetchOnce(download, url: url, to: destination, log: log, shouldStop: shouldStop)
        return
      } catch HFTransferError.stopped {
        throw HFTransferError.stopped
      } catch let error as HFError {
        throw error
      } catch {
        lastError = error
        log("Download attempt \(attempt) failed (\(error)); trying again.")
        Thread.sleep(forTimeInterval: Double(attempt * 2))
      }
    }
    throw HFError.unavailable("Couldn't download \(download.name): \(lastError)")
  }

  private func fetchOnce(
    _ download: HFEngineDownload, url: URL, to destination: URL, log: @escaping (String) -> Void,
    shouldStop: @escaping () -> Bool
  ) throws {
    try? FileManager.default.removeItem(at: destination)
    guard FileManager.default.createFile(atPath: destination.path, contents: nil),
      let handle = FileHandle(forWritingAtPath: destination.path)
    else { throw HFError.unavailable("Can't write \(destination.path).") }
    defer { try? handle.close() }
    let total = download.size
    let state = FetchState()
    try streamer.stream(
      url, headers: ["User-Agent": "ModelMatrix"], range: 0...(total - 1),
      head: { head in
        guard head.status == 200 || head.status == 206 else { throw HFTransferError.http(head.status) }
      },
      data: { chunk in
        try handle.write(contentsOf: chunk)
        let done = state.add(chunk)
        guard done <= total else { throw HFTransferError.restart("more data than expected") }
        let step = Int(done * 10 / total)
        if state.report(step) { log("Downloaded \(step * 10)% of \(HFEngineInstaller.size(total))") }
        return true
      },
      shouldStop: shouldStop)
    if shouldStop() { throw HFTransferError.stopped }
    guard state.bytes == total else {
      throw HFTransferError.network("got \(state.bytes) of \(total) bytes")
    }
    let digest = state.digest()
    guard digest == download.sha256 else {
      try? FileManager.default.removeItem(at: destination)
      throw HFError.refused(
        "\(download.name) doesn't match its published SHA-256 checksum, so it wasn't used. Nothing was installed.")
    }
    log("Checksum OK (SHA-256 \(digest.prefix(16))…)")
  }

  private final class FetchState: @unchecked Sendable {
    private let lock = NSLock()
    private var hasher = SHA256()
    private(set) var bytes: Int64 = 0
    private var reported = 0

    func add(_ chunk: Data) -> Int64 {
      lock.lock()
      defer { lock.unlock() }
      hasher.update(data: chunk)
      bytes += Int64(chunk.count)
      return bytes
    }

    func report(_ step: Int) -> Bool {
      lock.lock()
      defer { lock.unlock() }
      guard step > reported else { return false }
      reported = step
      return true
    }

    func digest() -> String {
      lock.lock()
      defer { lock.unlock() }
      return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
  }
}

/// Runs an install command and streams its output line by line.
public protocol HFCommandRunning: Sendable {
  /// Returns the exit status. Must stop the program soon after `shouldStop`
  /// turns true.
  func run(
    _ program: String, _ arguments: [String], environment: [String: String], output: @escaping (String) -> Void,
    shouldStop: @escaping () -> Bool
  ) throws -> Int32
}

public struct HFProcessRunner: HFCommandRunning {
  public init() {}

  public func run(
    _ program: String, _ arguments: [String], environment: [String: String], output: @escaping (String) -> Void,
    shouldStop: @escaping () -> Bool
  ) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: program)
    process.arguments = arguments
    process.environment = environment
    process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
    process.standardInput = FileHandle.nullDevice
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    let splitter = LineSplitter(output)
    pipe.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      if data.isEmpty {
        handle.readabilityHandler = nil
      } else {
        splitter.feed(data)
      }
    }
    try process.run()
    while process.isRunning {
      if shouldStop() {
        process.terminate()
        Thread.sleep(forTimeInterval: 3)
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        break
      }
      Thread.sleep(forTimeInterval: 0.2)
    }
    process.waitUntilExit()
    // Let the last output arrive.
    Thread.sleep(forTimeInterval: 0.2)
    pipe.fileHandleForReading.readabilityHandler = nil
    splitter.flush()
    return process.terminationStatus
  }

  final class LineSplitter: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let output: (String) -> Void

    init(_ output: @escaping (String) -> Void) { self.output = output }

    func feed(_ data: Data) {
      lock.lock()
      buffer.append(data)
      var lines: [String] = []
      while let index = buffer.firstIndex(where: { $0 == 10 || $0 == 13 }) {
        let line = String(decoding: buffer[buffer.startIndex..<index], as: UTF8.self)
        buffer.removeSubrange(buffer.startIndex...index)
        if !line.trimmingCharacters(in: .whitespaces).isEmpty { lines.append(line) }
      }
      if buffer.count > 64 << 10 {
        lines.append(String(decoding: buffer, as: UTF8.self))
        buffer.removeAll()
      }
      lock.unlock()
      lines.forEach(output)
    }

    func flush() {
      lock.lock()
      let rest = String(decoding: buffer, as: UTF8.self)
      buffer.removeAll()
      lock.unlock()
      if !rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { output(rest) }
    }
  }
}

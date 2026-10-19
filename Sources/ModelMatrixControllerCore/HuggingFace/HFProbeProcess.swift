import Darwin
import Foundation

/// Runs a short read-only command (such as `llama-server --version`) with a
/// time limit and an output cap. Returns nil on failure or timeout.
enum HFProbeProcess {
  static let outputLimit = 64 * 1024

  static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 5) -> String? {
    guard FileManager.default.isExecutableFile(atPath: executable) else { return nil }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    var environment = ProcessInfo.processInfo.environment
    environment["NO_COLOR"] = "1"
    environment["OLLAMA_NOHISTORY"] = "1"
    process.environment = environment
    process.standardInput = FileHandle.nullDevice
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    let buffer = HFOutputBuffer(limit: outputLimit)
    let endOfOutput = DispatchSemaphore(value: 0)
    pipe.fileHandleForReading.readabilityHandler = { handle in
      let chunk = handle.availableData
      if chunk.isEmpty {
        handle.readabilityHandler = nil
        endOfOutput.signal()
      } else {
        buffer.append(chunk)
      }
    }
    let finished = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in finished.signal() }
    do { try process.run() } catch {
      pipe.fileHandleForReading.readabilityHandler = nil
      return nil
    }
    if finished.wait(timeout: .now() + timeout) == .timedOut {
      process.terminate()
      if finished.wait(timeout: .now() + 1) == .timedOut { kill(process.processIdentifier, SIGKILL) }
      pipe.fileHandleForReading.readabilityHandler = nil
      return nil
    }
    // Output still in the pipe arrives shortly after exit; never block on a
    // pipe that a leftover child process might keep open.
    _ = endOfOutput.wait(timeout: .now() + 0.5)
    pipe.fileHandleForReading.readabilityHandler = nil
    return buffer.text
  }
}

final class HFOutputBuffer: @unchecked Sendable {
  private let lock = NSLock()
  private var data = Data()
  private let limit: Int

  init(limit: Int) { self.limit = limit }

  func append(_ chunk: Data) {
    lock.lock()
    defer { lock.unlock() }
    guard data.count < limit else { return }
    data.append(chunk.prefix(limit - data.count))
  }

  var text: String {
    lock.lock()
    defer { lock.unlock() }
    return String(decoding: data, as: UTF8.self)
  }
}

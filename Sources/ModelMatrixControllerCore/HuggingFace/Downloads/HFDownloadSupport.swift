import CryptoKit
import Foundation
import IOKit.pwr_mgt
import Network

/// Whether the machine has a network connection. Replaceable in tests.
public protocol HFNetworkStatus: Sendable {
  var isAvailable: Bool { get }
}

/// Network status from the system (NWPathMonitor).
public final class HFPathMonitor: HFNetworkStatus, @unchecked Sendable {
  public static let shared = HFPathMonitor()

  private let monitor = NWPathMonitor()
  private let lock = NSLock()
  private var available = true

  private init() {
    monitor.pathUpdateHandler = { [weak self] path in
      guard let self else { return }
      self.lock.lock()
      self.available = path.status == .satisfied
      self.lock.unlock()
    }
    monitor.start(queue: DispatchQueue(label: "modelmatrix.hf.network"))
  }

  public var isAvailable: Bool {
    lock.lock()
    defer { lock.unlock() }
    return available
  }
}

public struct HFAlwaysOnline: HFNetworkStatus {
  public init() {}
  public var isAvailable: Bool { true }
}

public enum HFDisk {
  /// Free bytes on the volume holding `url` (or its nearest existing parent).
  public static func freeBytes(_ url: URL) -> Int64? {
    let existing = nearestExisting(url)
    if let values = try? existing.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
      let capacity = values.volumeAvailableCapacityForImportantUsage, capacity > 0
    {
      return capacity
    }
    var info = statfs()
    guard statfs(existing.path, &info) == 0 else { return nil }
    return Int64(info.f_bavail) * Int64(info.f_bsize)
  }

  /// File system type ("apfs", "msdos" for FAT32, "exfat", ...).
  static func fileSystem(_ url: URL) -> String? {
    var info = statfs()
    guard statfs(nearestExisting(url).path, &info) == 0 else { return nil }
    return withUnsafePointer(to: &info.f_fstypename) {
      $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
    }
  }

  static func nearestExisting(_ url: URL) -> URL {
    var current = url.standardizedFileURL
    while !FileManager.default.fileExists(atPath: current.path), current.path != "/" {
      current = current.deletingLastPathComponent()
    }
    return current
  }

  /// Copies `source` to `destination` instantly on APFS (a clone shares the
  /// data until either copy changes). Falls back to a normal copy.
  static func cloneOrCopy(_ source: URL, to destination: URL) throws -> String {
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? FileManager.default.removeItem(at: destination)
    if clonefile(source.path, destination.path, 0) == 0 { return "clone" }
    try FileManager.default.copyItem(at: source, to: destination)
    return "copy"
  }

  /// Bytes used by the files under `folder`.
  static func usage(_ folder: URL) -> Int64 {
    guard
      let walker = FileManager.default.enumerator(
        at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
    else { return 0 }
    var total: Int64 = 0
    for case let file as URL in walker {
      let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
      if values?.isRegularFile == true { total += Int64(values?.totalFileAllocatedSize ?? 0) }
    }
    return total
  }
}

enum HFHash {
  /// SHA-256 of a file, read in 16 MB chunks. Returns nil when stopped.
  static func sha256(_ url: URL, shouldStop: () -> Bool = { false }, progress: (Int64) -> Void = { _ in })
    throws -> String?
  {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    var done: Int64 = 0
    while true {
      if shouldStop() { return nil }
      let chunk = try autoreleasepool { try handle.read(upToCount: 16 * 1024 * 1024) ?? Data() }
      if chunk.isEmpty { break }
      hasher.update(data: chunk)
      done += Int64(chunk.count)
      progress(done)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
}

/// Keeps the Mac from idle-sleeping while downloads run.
final class HFSleepGuard: @unchecked Sendable {
  private let lock = NSLock()
  private var assertion: IOPMAssertionID = 0
  private var held = false

  func hold(_ wanted: Bool) {
    lock.lock()
    defer { lock.unlock() }
    if wanted, !held {
      let reason = "ModelMatrix is downloading a model" as CFString
      held =
        IOPMAssertionCreateWithName(
          kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
          reason, &assertion) == kIOReturnSuccess
    } else if !wanted, held {
      IOPMAssertionRelease(assertion)
      held = false
    }
  }

  var isHeld: Bool {
    lock.lock()
    defer { lock.unlock() }
    return held
  }
}

/// Download speed over the last few seconds. Thread-safe.
final class HFSpeedMeter: @unchecked Sendable {
  private let lock = NSLock()
  private var samples: [(Date, Int64)] = []

  func add(_ bytes: Int64, at time: Date = Date()) -> Int64 {
    lock.lock()
    defer { lock.unlock() }
    samples.append((time, bytes))
    samples.removeAll { time.timeIntervalSince($0.0) > 6 }
    guard let first = samples.first, let last = samples.last, last.0.timeIntervalSince(first.0) > 0.5 else {
      return 0
    }
    return max(0, Int64(Double(last.1 - first.1) / last.0.timeIntervalSince(first.0)))
  }
}

import Darwin
import Foundation
import Metal

/// The machine a model would run on, measured when the check runs.
public struct HFMachine: Sendable, Encodable, Equatable {
  /// "mac" (Linux hosts are added with remote downloads).
  public var kind: String
  public var os: String
  /// "arm64" or "x86_64": decides which engine builds apply.
  public var architecture: String
  public var appleSilicon: Bool
  /// An Intel build running through Rosetta on an Apple Silicon Mac.
  public var rosetta: Bool
  public var chip: String
  public var memoryBytes: Int64
  /// Memory a model may use: the GPU working-set limit on Apple Silicon,
  /// 60% of memory on Intel (processor only).
  public var budgetBytes: Int64
  /// "metal" (measured), "estimate" (from memory size) or "cpu".
  public var budgetSource: String
  /// "metal" or "cpu".
  public var accelerator: String
  public var modelsFolder: String
  public var freeDiskBytes: Int64?

  public init(
    kind: String = "mac", os: String = "", architecture: String, appleSilicon: Bool, rosetta: Bool = false,
    chip: String = "", memoryBytes: Int64, budgetBytes: Int64, budgetSource: String, accelerator: String,
    modelsFolder: String = "~/ModelMatrix/Models", freeDiskBytes: Int64? = nil
  ) {
    self.kind = kind
    self.os = os
    self.architecture = architecture
    self.appleSilicon = appleSilicon
    self.rosetta = rosetta
    self.chip = chip
    self.memoryBytes = memoryBytes
    self.budgetBytes = budgetBytes
    self.budgetSource = budgetSource
    self.accelerator = accelerator
    self.modelsFolder = modelsFolder
    self.freeDiskBytes = freeDiskBytes
  }

  /// The share of memory a model may use when it can't be measured.
  public static func estimatedBudget(memoryBytes: Int64, appleSilicon: Bool) -> Int64 {
    if !appleSilicon { return memoryBytes * 3 / 5 }
    return memoryBytes < 36 * (1 << 30) ? memoryBytes * 2 / 3 : memoryBytes * 3 / 4
  }

  /// A typical Mac of the given memory size, for planning and tests.
  public static func sample(memoryGiB: Int, appleSilicon: Bool = true) -> HFMachine {
    let memory = Int64(memoryGiB) << 30
    return HFMachine(
      architecture: appleSilicon ? "arm64" : "x86_64", appleSilicon: appleSilicon,
      chip: appleSilicon ? "Apple Silicon" : "Intel", memoryBytes: memory,
      budgetBytes: estimatedBudget(memoryBytes: memory, appleSilicon: appleSilicon),
      budgetSource: appleSilicon ? "estimate" : "cpu", accelerator: appleSilicon ? "metal" : "cpu",
      freeDiskBytes: 500 << 30)
  }

  /// Whether this copy of ModelMatrix is the Apple Silicon build.
  static var isArm64Build: Bool {
    #if arch(arm64)
      return true
    #else
      return false
    #endif
  }

  public static let defaultModelsFolder = "~/ModelMatrix/Models"

  /// Measures this Mac.
  public static func current(modelsFolder: String = defaultModelsFolder) -> HFMachine {
    let nativeArm = isArm64Build
    let memory = Int64(clamping: sysctlUInt64("hw.memsize") ?? 0)
    let rosetta = sysctlInt32("sysctl.proc_translated") == 1
    var budget = estimatedBudget(memoryBytes: memory, appleSilicon: nativeArm)
    var source = nativeArm ? "estimate" : "cpu"
    if nativeArm, let device = MTLCreateSystemDefaultDevice() {
      let measured = Int64(clamping: device.recommendedMaxWorkingSetSize)
      if measured > 0, measured <= memory { budget = measured; source = "metal" }
    }
    let version = ProcessInfo.processInfo.operatingSystemVersion
    return HFMachine(
      os: "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
      architecture: nativeArm ? "arm64" : "x86_64", appleSilicon: nativeArm, rosetta: rosetta,
      chip: sysctlString("machdep.cpu.brand_string") ?? (nativeArm ? "Apple Silicon" : "Intel"),
      memoryBytes: memory, budgetBytes: budget, budgetSource: source, accelerator: nativeArm ? "metal" : "cpu",
      modelsFolder: modelsFolder, freeDiskBytes: freeSpace(near: expandTilde(modelsFolder)))
  }

  static func expandTilde(_ path: String) -> String {
    path.hasPrefix("~/") ? NSHomeDirectory() + String(path.dropFirst(1)) : path
  }

  /// Free space on the disk that holds `path` (or its nearest existing
  /// parent folder).
  static func freeSpace(near path: String) -> Int64? {
    var url = URL(fileURLWithPath: path)
    while !FileManager.default.fileExists(atPath: url.path), url.path != "/" {
      url.deleteLastPathComponent()
    }
    let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
    if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
    return values?.volumeAvailableCapacity.map(Int64.init)
  }

  static func sysctlUInt64(_ name: String) -> UInt64? {
    var value: UInt64 = 0
    var size = MemoryLayout<UInt64>.size
    return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : nil
  }

  static func sysctlInt32(_ name: String) -> Int32? {
    var value: Int32 = 0
    var size = MemoryLayout<Int32>.size
    return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : nil
  }

  static func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
    return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
      .trimmingCharacters(in: .whitespaces)
  }
}

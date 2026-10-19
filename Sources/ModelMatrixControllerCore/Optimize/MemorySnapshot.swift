import Darwin
import Foundation

/// A point-in-time reading of this Mac's memory, in Activity Monitor's terms:
/// Memory Used = App Memory + Wired + Compressed. Cached Files are file-backed
/// pages macOS keeps around and can drop when something needs the space.
public struct MemorySnapshot: Sendable, Equatable {
    public var totalBytes: UInt64
    public var appBytes: UInt64
    public var wiredBytes: UInt64
    public var compressedBytes: UInt64
    public var cachedBytes: UInt64
    public var freeBytes: UInt64
    public var swapUsedBytes: UInt64
    public var swapTotalBytes: UInt64
    /// `normal`, `warning` or `critical` (the kernel's memory pressure level).
    public var pressure: String

    public var usedBytes: UInt64 { appBytes + wiredBytes + compressedBytes }

    public init(
        totalBytes: UInt64, appBytes: UInt64, wiredBytes: UInt64, compressedBytes: UInt64,
        cachedBytes: UInt64, freeBytes: UInt64, swapUsedBytes: UInt64 = 0,
        swapTotalBytes: UInt64 = 0, pressure: String = "normal"
    ) {
        self.totalBytes = totalBytes
        self.appBytes = appBytes
        self.wiredBytes = wiredBytes
        self.compressedBytes = compressedBytes
        self.cachedBytes = cachedBytes
        self.freeBytes = freeBytes
        self.swapUsedBytes = swapUsedBytes
        self.swapTotalBytes = swapTotalBytes
        self.pressure = pressure
    }

    public var json: [String: Any] {
        [
            "total_bytes": totalBytes, "used_bytes": usedBytes, "app_bytes": appBytes,
            "wired_bytes": wiredBytes, "compressed_bytes": compressedBytes,
            "cached_bytes": cachedBytes, "free_bytes": freeBytes,
            "swap_used_bytes": swapUsedBytes, "swap_total_bytes": swapTotalBytes,
            "pressure": pressure,
        ]
    }

    public static func current() -> MemorySnapshot? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS, pageSize > 0 else {
            return nil
        }
        let page = UInt64(pageSize)
        let anonymous = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        let swap = swapUsage()
        return MemorySnapshot(
            totalBytes: sysctlUInt64("hw.memsize") ?? 0,
            appBytes: (anonymous > purgeable ? anonymous - purgeable : 0) * page,
            wiredBytes: UInt64(stats.wire_count) * page,
            compressedBytes: UInt64(stats.compressor_page_count) * page,
            cachedBytes: (UInt64(stats.external_page_count) + purgeable) * page,
            // free_count already includes speculative pages (see vm_stat).
            freeBytes: UInt64(stats.free_count) * page,
            swapUsedBytes: swap.used, swapTotalBytes: swap.total,
            pressure: pressureLevel())
    }

    static func sysctlUInt64(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    static func swapUsage() -> (used: UInt64, total: UInt64) {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return (0, 0) }
        return (usage.xsu_used, usage.xsu_total)
    }

    static func pressureLevel() -> String {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0
        else { return "normal" }
        switch level {
        case 4: return "critical"
        case 2: return "warning"
        default: return "normal"
        }
    }
}

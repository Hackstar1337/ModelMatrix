import Darwin
import Foundation
import IOKit

/// Samples this Mac's CPU, unified memory, GPU and storage for
/// `GET /api/host/metrics`. The JSON keys match the remote agent's payload
/// (`cpu_percent`, `memory.used_mb`, `gpus[].util_percent`, ...) so the
/// dashboard renders local and remote hosts with the same code.
public final class MacHostMetricsSampler: @unchecked Sendable {
    struct CPUTicks {
        let total: UInt64
        let idle: UInt64
    }

    private let lock = NSLock()
    private var previousTicks: CPUTicks?
    private var lastPayload: [String: Any]?
    private var lastSampleAt = Date.distantPast

    public init() {}

    /// Returns a fresh sample, reusing the previous one if it is under a second old.
    public func payload() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        if let lastPayload, Date().timeIntervalSince(lastSampleAt) < 1 { return lastPayload }
        if previousTicks == nil {
            previousTicks = Self.cpuTicks()
            usleep(150_000)
        }
        let ticks = Self.cpuTicks()
        var cpuPercent: Double?
        if let previous = previousTicks, let ticks, ticks.total > previous.total {
            let total = Double(ticks.total &- previous.total)
            let idle = Double(ticks.idle &- previous.idle)
            cpuPercent = max(0, min(100, (1 - idle / total) * 100))
        }
        previousTicks = ticks ?? previousTicks
        let totalMB = Double(ProcessInfo.processInfo.physicalMemory) / 1_048_576
        let usedMB = Self.usedMemoryMB()
        var memory: [String: Any] = ["total_mb": Self.round1(totalMB), "source": "vm_statistics64"]
        if let usedMB {
            memory["used_mb"] = Self.round1(usedMB)
            memory["percent"] = Self.round1(usedMB / totalMB * 100)
        }
        let gpu = Self.gpuSample()
        var gpuEntry: [String: Any] = [
            "index": 0,
            "name": Self.chipName().map { "\($0) GPU" } ?? "Apple GPU",
            "vram_total_mb": Self.round1(totalMB),
            "unified_memory": true,
        ]
        if let util = gpu.util { gpuEntry["util_percent"] = Self.round1(util) }
        if let inUse = gpu.inUseMB { gpuEntry["vram_used_mb"] = Self.round1(inUse) }
        var payload: [String: Any] = [
            "host": ProcessInfo.processInfo.hostName,
            "platform": "macos",
            "collected_at": ISO8601DateFormatter().string(from: Date()),
            "memory": memory,
            "gpus": [gpuEntry],
            "gpu_source": "iokit",
            "processes": [],
            "unified_memory": true,
            "thermal_state": Self.thermalState(),
            "os_version": ProcessInfo.processInfo.operatingSystemVersionString,
            "cpu_cores": ProcessInfo.processInfo.activeProcessorCount,
        ]
        if let cpuPercent { payload["cpu_percent"] = Self.round1(cpuPercent) }
        if let chip = Self.chipName() { payload["chip"] = chip }
        if let uptime = Self.uptimeSeconds() { payload["uptime_seconds"] = uptime.rounded() }
        if let storage = Self.storage() { payload["storage"] = storage }
        if let load = Self.loadAverage() { payload["load_average"] = load }
        lastPayload = payload
        lastSampleAt = Date()
        return payload
    }

    static func round1(_ value: Double) -> Double { (value * 10).rounded() / 10 }

    static func cpuTicks() -> CPUTicks? {
        var load = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &load) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let user = UInt64(load.cpu_ticks.0)
        let system = UInt64(load.cpu_ticks.1)
        let idle = UInt64(load.cpu_ticks.2)
        let nice = UInt64(load.cpu_ticks.3)
        return CPUTicks(total: user + system + idle + nice, idle: idle)
    }

    /// Activity Monitor's "Memory Used": App Memory + Wired + Compressed
    /// (the same figure Optimize reports).
    static func usedMemoryMB() -> Double? {
        MemorySnapshot.current().map { Double($0.usedBytes) / 1_048_576 }
    }
    static func gpuSample() -> (util: Double?, inUseMB: Double?) {
        for className in ["AGXAccelerator", "IOAccelerator", "IOGPU"] {
            guard let matching = IOServiceMatching(className) else { continue }
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS
            else { continue }
            defer { IOObjectRelease(iterator) }
            var service = IOIteratorNext(iterator)
            while service != 0 {
                defer {
                    IOObjectRelease(service)
                    service = IOIteratorNext(iterator)
                }
                var raw: Unmanaged<CFMutableDictionary>?
                guard IORegistryEntryCreateCFProperties(service, &raw, kCFAllocatorDefault, 0)
                    == KERN_SUCCESS,
                    let properties = raw?.takeRetainedValue() as? [String: Any],
                    let stats = properties["PerformanceStatistics"] as? [String: Any]
                else { continue }
                let util = number(stats["Device Utilization %"] ?? stats["GPU Core Utilization"])
                let inUse = number(stats["In use system memory"]).map { $0 / 1_048_576 }
                if util != nil || inUse != nil {
                    return (util.map { min(100, max(0, $0)) }, inUse)
                }
            }
        }
        return (nil, nil)
    }

    static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        return nil
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let value = String(cString: buffer).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    static func chipName() -> String? {
        sysctlString("machdep.cpu.brand_string")
    }

    static func uptimeSeconds() -> Double? {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 else { return nil }
        let booted = Double(boot.tv_sec) + Double(boot.tv_usec) / 1_000_000
        return Date().timeIntervalSince1970 - booted
    }

    static func loadAverage() -> [Double]? {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) == 3 else { return nil }
        return loads.map { (($0 * 100).rounded()) / 100 }
    }

    static func storage() -> [String: Any]? {
        guard
            let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [
                .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
            ]),
            let total = values.volumeTotalCapacity
        else { return nil }
        let available = Double(values.volumeAvailableCapacityForImportantUsage ?? 0)
        let totalMB = Double(total) / 1_048_576
        let usedMB = max(0, totalMB - available / 1_048_576)
        return [
            "path": "/",
            "total_mb": round1(totalMB),
            "used_mb": round1(usedMB),
            "percent": round1(totalMB > 0 ? usedMB / totalMB * 100 : 0),
        ]
    }

    static func thermalState() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}

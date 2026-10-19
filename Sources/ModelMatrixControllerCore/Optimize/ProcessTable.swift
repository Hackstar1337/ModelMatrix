import Darwin
import Foundation

/// One process owned by this user.
public struct ProcessMemoryRow: Sendable, Equatable {
    public let pid: Int32
    public let parent: Int32
    public let startedAt: Double
    public let path: String
    public let name: String
    /// Physical footprint, the figure Activity Monitor shows as "Memory".
    /// On Apple silicon it includes GPU (Metal) allocations.
    public let footprintBytes: UInt64
}

/// Memory used by one app (all processes inside its bundle) or one tool.
public struct AppMemoryGroup: Sendable, Equatable {
    public let name: String
    public let bundlePath: String?
    public let bytes: UInt64
    public let processCount: Int
    public let mainPID: Int32
    /// Regular apps outside /System can be asked to quit.
    public let quittable: Bool

    public var json: [String: Any] {
        var value: [String: Any] = [
            "name": name, "bytes": bytes, "processes": processCount, "pid": mainPID,
            "quittable": quittable,
        ]
        if let bundlePath { value["path"] = bundlePath }
        return value
    }
}

/// A single pass over this user's processes (other users' processes cannot
/// be measured without root and are skipped).
public struct ProcessTable: Sendable {
    public let rows: [Int32: ProcessMemoryRow]

    public init(rows: [ProcessMemoryRow]) {
        self.rows = Dictionary(rows.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public static func current() -> ProcessTable {
        let uid = getuid()
        let estimate = max(Int(proc_listallpids(nil, 0)), 0) + 64
        var pids = [pid_t](repeating: 0, count: estimate)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        var rows: [ProcessMemoryRow] = []
        for pid in pids.prefix(max(count, 0)) where pid > 0 {
            guard let row = Self.row(pid, uid: uid) else { continue }
            rows.append(row)
        }
        return ProcessTable(rows: rows)
    }

    static func row(_ pid: pid_t, uid: uid_t) -> ProcessMemoryRow? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_uid == uid
        else { return nil }
        var usage = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard status == 0 else { return nil }
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        let path = pathLength > 0 ? String(cString: pathBuffer) : ""
        var name = (path as NSString).lastPathComponent
        if name.isEmpty {
            name = withUnsafeBytes(of: info.pbi_name) { raw in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
        }
        return ProcessMemoryRow(
            pid: pid, parent: Int32(info.pbi_ppid),
            startedAt: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000,
            path: path, name: name, footprintBytes: usage.ri_phys_footprint)
    }

    /// The process and everything it started.
    public func tree(_ pid: Int32) -> [Int32] {
        var children: [Int32: [Int32]] = [:]
        for row in rows.values { children[row.parent, default: []].append(row.pid) }
        var result: [Int32] = []
        var queue = [pid]
        var seen: Set<Int32> = []
        while let next = queue.popLast() {
            guard seen.insert(next).inserted else { continue }
            if rows[next] != nil { result.append(next) }
            queue.append(contentsOf: children[next] ?? [])
        }
        return result
    }

    public func footprint(ofTree pid: Int32) -> UInt64 {
        tree(pid).reduce(0) { $0 + (rows[$1]?.footprintBytes ?? 0) }
    }

    /// The outermost `.app` bundle containing `path`, if any. An `.app` stub
    /// inside a framework (Homebrew or python.org Python runs from
    /// `Python.framework/.../Python.app`) is a command-line tool, not an app.
    public static func bundlePath(for path: String) -> String? {
        guard let range = path.range(of: ".app/") ?? (path.hasSuffix(".app") ? path.range(of: ".app") : nil)
        else { return nil }
        let prefix = path[..<range.lowerBound]
        if prefix.contains(".framework/") { return nil }
        return String(prefix) + ".app"
    }

    /// Biggest memory users, grouped by app bundle (or executable name for
    /// tools), largest first.
    public func appGroups(excluding excluded: Set<Int32>, limit: Int = 8, minimumBytes: UInt64 = 50 << 20)
        -> [AppMemoryGroup]
    {
        struct Accumulator { var name: String; var bundle: String?; var bytes: UInt64 = 0; var count = 0; var main: Int32; var mainStart: Double }
        var groups: [String: Accumulator] = [:]
        for row in rows.values where !excluded.contains(row.pid) && row.footprintBytes > 0 {
            let bundle = Self.bundlePath(for: row.path)
            let key = bundle ?? "tool:\(row.name)"
            let name = bundle.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension } ?? row.name
            var group = groups[key] ?? Accumulator(name: name, bundle: bundle, main: row.pid, mainStart: row.startedAt)
            group.bytes += row.footprintBytes
            group.count += 1
            if row.startedAt < group.mainStart { group.main = row.pid; group.mainStart = row.startedAt }
            groups[key] = group
        }
        return groups.values
            .filter { $0.bytes >= minimumBytes }
            .sorted { $0.bytes > $1.bytes }
            .prefix(limit)
            .map {
                AppMemoryGroup(
                    name: $0.name, bundlePath: $0.bundle, bytes: $0.bytes, processCount: $0.count,
                    mainPID: $0.main, quittable: Self.isQuittable(bundle: $0.bundle))
            }
    }

    static func isQuittable(bundle: String?) -> Bool {
        guard let bundle else { return false }
        return !bundle.hasPrefix("/System/") && !bundle.hasPrefix("/usr/")
            && !bundle.hasPrefix("/Library/Apple/")
    }
}

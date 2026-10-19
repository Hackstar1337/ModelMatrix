import Darwin
import Foundation

/// Works out a friendly name for the app that sent a request.
///
/// Order: explicit `X-Client-Name` / `X-Title` headers, a known User-Agent
/// family, then the name of the local process that owns the TCP connection.
public enum ClientIdentity {
    static let userAgentFamilies: [(String, String)] = [
        ("open-webui", "Open WebUI"),
        ("openwebui", "Open WebUI"),
        ("continue", "Continue"),
        ("cursor", "Cursor"),
        ("zed", "Zed"),
        ("aider", "aider"),
        ("cline", "Cline"),
        ("roo", "Roo Code"),
        ("kilo", "Kilo Code"),
        ("jetbrains", "JetBrains AI"),
        ("raycast", "Raycast"),
        ("msty", "Msty"),
        ("enchanted", "Enchanted"),
        ("anythingllm", "AnythingLLM"),
        ("librechat", "LibreChat"),
        ("lobechat", "LobeChat"),
        ("chatbox", "Chatbox"),
        ("factory", "Factory Droid"),
        ("droid", "Factory Droid"),
        ("opencode", "opencode"),
        ("claude", "Claude Code"),
        ("codex", "Codex CLI"),
        ("langchain", "LangChain"),
        ("llamaindex", "LlamaIndex"),
        ("litellm", "LiteLLM"),
        ("ollama-python", "Ollama Python"),
        ("ollama-js", "Ollama JS"),
        ("ollama/", "Ollama CLI"),
        ("openai/python", "OpenAI Python SDK"),
        ("asyncopenai/python", "OpenAI Python SDK"),
        ("openai/js", "OpenAI JS SDK"),
        ("openai-node", "OpenAI JS SDK"),
        ("modelmatrix", "ModelMatrix"),
        ("python-httpx", "Python (httpx)"),
        ("python-requests", "Python (requests)"),
        ("aiohttp", "Python (aiohttp)"),
        ("node-fetch", "Node.js"),
        ("undici", "Node.js"),
        ("axios", "Node.js (axios)"),
        ("bun/", "Bun"),
        ("deno/", "Deno"),
        ("go-http-client", "Go client"),
        ("reqwest", "Rust client"),
        ("curl/", "curl"),
        ("wget/", "wget"),
        ("httpie", "HTTPie"),
        ("postman", "Postman"),
        ("insomnia", "Insomnia"),
        ("mozilla/", "Web browser"),
    ]

    public static func label(headers: [String: String]) -> (label: String, explicit: Bool) {
        for key in ["x-client-name", "x-title", "x-modelmatrix-client"] {
            if let value = headers[key]?.trimmingCharacters(in: .whitespaces), !value.isEmpty {
                return (String(value.prefix(60)), true)
            }
        }
        let agent = (headers["user-agent"] ?? "").lowercased()
        if agent.isEmpty { return ("Unknown client", false) }
        for (needle, name) in userAgentFamilies where agent.contains(needle) {
            return (name, false)
        }
        let first = agent.split(separator: " ").first.map(String.init) ?? agent
        let product = first.split(separator: "/").first.map(String.init) ?? first
        return (String(product.prefix(40)), false)
    }

    /// Stable identifier for grouping requests from the same client.
    public static func identifier(label: String, process: String?) -> String {
        let basis = "\(label.lowercased())|\((process ?? "").lowercased())"
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in basis.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return String(format: "c%016llx", hash)
    }

    // MARK: - Owning process of a loopback TCP connection

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: (String?, Date)] = [:]

    /// Name of the local process whose socket has local port `port`
    /// (the client side of a loopback connection to the relay).
    public static func processName(forLocalPort port: UInt16, cacheKey: String) -> String? {
        cacheLock.lock()
        if let cached = cache[cacheKey], Date().timeIntervalSince(cached.1) < 60 {
            cacheLock.unlock()
            return cached.0
        }
        cacheLock.unlock()
        let name = lookupProcess(localPort: port)
        cacheLock.lock()
        cache[cacheKey] = (name, Date())
        if cache.count > 500 { cache.removeAll() }
        cacheLock.unlock()
        return name
    }

    static func lookupProcess(localPort: UInt16) -> String? {
        let ownPID = getpid()
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return nil }
        for pid in pids.prefix(Int(filled)) where pid > 0 && pid != ownPID {
            let bufferSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard bufferSize > 0 else { continue }
            let fdCount = Int(bufferSize) / MemoryLayout<proc_fdinfo>.size
            var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: fdCount)
            let used = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, bufferSize)
            guard used > 0 else { continue }
            for fd in fds.prefix(Int(used) / MemoryLayout<proc_fdinfo>.size)
            where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
                var info = socket_fdinfo()
                let size = proc_pidfdinfo(
                    pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, Int32(MemoryLayout<socket_fdinfo>.size))
                guard size == Int32(MemoryLayout<socket_fdinfo>.size),
                    info.psi.soi_kind == Int32(SOCKINFO_TCP)
                else { continue }
                let local = UInt16(bigEndian: UInt16(truncatingIfNeeded: info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport))
                if local == localPort {
                    var nameBuffer = [CChar](repeating: 0, count: 256)
                    proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
                    let name = String(cString: nameBuffer)
                    return name.isEmpty ? nil : prettyProcessName(name)
                }
            }
        }
        return nil
    }

    static func prettyProcessName(_ raw: String) -> String {
        let lowered = raw.lowercased()
        let known: [String: String] = [
            "python3": "Python", "python": "Python", "node": "Node.js", "bun": "Bun", "deno": "Deno",
            "curl": "curl", "ruby": "Ruby", "java": "Java", "cursor helper": "Cursor",
            "code helper": "VS Code", "code helper (plugin)": "VS Code", "electron": "Electron app",
        ]
        if let mapped = known[lowered] { return mapped }
        if lowered.hasPrefix("python") { return "Python" }
        return raw
    }
}

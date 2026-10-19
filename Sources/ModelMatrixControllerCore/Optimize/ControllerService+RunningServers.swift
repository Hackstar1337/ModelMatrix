import Foundation

extension ControllerService {
    /// Profiles whose model server is running now, one entry per process.
    /// Ollama profiles are left out: Optimize unloads Ollama models through
    /// Ollama itself instead of stopping the shared Ollama server.
    func runningModelServers() -> [(profile: ControllerProfile, pid: Int)] {
        guard let loaded = try? profiles.load() else { return [] }
        let own = Int(ProcessInfo.processInfo.processIdentifier)
        var seen: Set<Int> = []
        return loaded.values.sorted { $0.name < $1.name }.compactMap { profile in
            guard profile.runtime != "ollama",
                let pid = resolvedPID(for: profile, allowPortFallback: true), pid != own,
                ProcessRunner.processIsAlive(pid), seen.insert(pid).inserted
            else { return nil }
            return (profile, pid)
        }
    }
}

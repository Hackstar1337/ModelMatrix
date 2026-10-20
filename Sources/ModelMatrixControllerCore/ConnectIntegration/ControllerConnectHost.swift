import Darwin
import Foundation
import ModelMatrixCore

/// Read-only bridge between profile/host state and the client connection registry.
/// A short cache keeps agent health probes out of every streamed request.
final class ControllerConnectHost: @unchecked Sendable {
    weak var service: ControllerService?
    weak var usage: UsageService?
    let hub: HFHub
    let bridge: BridgeState
    private let lock = NSLock()
    private var cached: [ClientConnectionProfile] = []
    private var refreshed = Date.distantPast

    init(service: ControllerService, hub: HFHub, bridge: BridgeState, usage: UsageService?) {
        self.service = service
        self.hub = hub
        self.bridge = bridge
        self.usage = usage
    }

    func invalidate() {
        lock.lock(); refreshed = .distantPast; lock.unlock()
        usage?.invalidateConnectionTargets()
    }

    func relayState() -> ClientRelayState {
        guard let usage else {
            return ClientRelayState(baseURL: "", listening: false, error: "The model API relay is disabled.")
        }
        return ClientRelayState(baseURL: usage.relayURL, listening: usage.relay?.isListening == true,
                                error: usage.relay?.lastError)
    }

    func profiles() -> [ClientConnectionProfile] {
        lock.lock()
        if Date().timeIntervalSince(refreshed) < 3 {
            let answer = cached
            lock.unlock()
            return answer
        }
        let previous = cached
        lock.unlock()
        var answer = localProfiles()
        let hosts = hub.hostDirectory?.hosts() ?? []
        for host in hosts where host.enabled {
            do {
                let payload = try hub.agent.get(host, "/api/connect/profiles", timeout: 3)
                for row in payload["profiles"] as? [[String: Any]] ?? [] {
                    guard let name = row["profile"] as? String, ControllerService.isValidProfileName(name),
                          let model = row["model_id"] as? String, !model.isEmpty,
                          let identity = row["identity_token"] as? String, !identity.isEmpty else { continue }
                    answer.append(ClientConnectionProfile(
                        key: "remote:\(host.id):\(name)", profile: name,
                        displayName: row["display_name"] as? String ?? name, modelID: model,
                        runtime: row["runtime"] as? String ?? "external", host: host.name,
                        readiness: row["readiness"] as? String ?? "host_unavailable",
                        context: row["context"] as? Int, identityToken: identity))
                }
            } catch {
                // Keep known models visible, but never route to their old address.
                answer += previous.filter { $0.key.hasPrefix("remote:\(host.id):") }.map {
                    ClientConnectionProfile(key: $0.key, profile: $0.profile, displayName: $0.displayName,
                        modelID: $0.modelID, runtime: $0.runtime, host: $0.host,
                        readiness: "host_unavailable", context: $0.context, identityToken: $0.identityToken)
                }
            }
        }
        // App disconnected/host disabled: preserve the model identity with unavailable readiness.
        let present = Set(answer.map(\.key))
        answer += previous.filter { $0.key.hasPrefix("remote:") && !present.contains($0.key) }.map {
            ClientConnectionProfile(key: $0.key, profile: $0.profile, displayName: $0.displayName,
                modelID: $0.modelID, runtime: $0.runtime, host: $0.host,
                readiness: "host_unavailable", context: $0.context, identityToken: $0.identityToken)
        }
        lock.lock(); cached = answer; refreshed = Date(); lock.unlock()
        return answer
    }

    private func localProfiles() -> [ClientConnectionProfile] {
        guard let service else { return [] }
        return service.withMutationLock {
            guard let profiles = try? service.profiles.load() else { return [] }
            let statuses = (try? service.statusPayload().statuses) ?? []
            let byName = Dictionary(statuses.map { ($0.profile, $0) }, uniquingKeysWith: { first, _ in first })
            return profiles.values.sorted { $0.name < $1.name }.compactMap { profile in
                guard let file = service.profileFile(named: profile.name) else { return nil }
                var info = stat()
                guard lstat(file.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
                let status = byName[profile.name]
                let state = status?.ready == true ? "running" : status?.running == true ? "starting" : "stopped"
                // Only llama.cpp's configured CONTEXT_SIZE is currently enforced by the launcher.
                let context = profile.runtime.lowercased().contains("llama") ? profile["CONTEXT_SIZE"].flatMap(Int.init) : nil
                return ClientConnectionProfile(key: "local:\(profile.name)", profile: profile.name,
                    displayName: profile.displayName, modelID: profile.requestModel, runtime: profile.runtime,
                    host: nil, readiness: state, context: context,
                    identityToken: "\(info.st_dev):\(info.st_ino):\(info.st_birthtimespec.tv_sec):\(info.st_birthtimespec.tv_nsec)")
            }
        }
    }
}

extension UsageService {
    func invalidateConnectionTargets() {
        lock.lock(); targetsUpdatedAt = .distantPast; lock.unlock()
    }
}

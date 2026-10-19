import Foundation
import ModelMatrixCore

extension ControllerService {
    public func start(_ name: String) throws {
        try withMutationLock {
            let loaded = try requireExistingProfile(name, action: "start")
            var environment = ProcessInfo.processInfo.environment
            environment["MODEL_PROFILE"] = name
            environment.merge(loaded[name]?.values ?? [:]) { _, new in new }
            environment["MODELMATRIX_PROFILE_LOADED"] = "1"
            environment["MODELMATRIX_CONTROLLER_BIN"] = controllerExecutableURL.path
            if let profile = loaded[name] {
                Self.applyCapturePort(profile, to: &environment)
            }
            _ = try ProcessRunner.run(
                "/bin/bash",
                [configuration.startScript.path],
                environment: environment,
                currentDirectory: configuration.root
            )
        }
    }

    /// Capture mode: the runtime listens on an internal port and the
    /// controller's relay owns the profile's public port, so every request
    /// (from any app) is metered.
    static func applyCapturePort(_ profile: ControllerProfile, to environment: inout [String: String]) {
        guard UsageService.captureEnabled(profile), let rawPort = profile["PORT"],
            let port = UInt16(rawPort)
        else { return }
        let internalPort = String(RelayTarget.capturePort(for: port))
        environment["PORT"] = internalPort
        environment["MODELMATRIX_PUBLIC_PORT"] = rawPort
        for key in ["BASE_URL", "HEALTHCHECK_URL"] {
            if let value = environment[key] {
                environment[key] = value.replacingOccurrences(of: ":\(rawPort)", with: ":\(internalPort)")
            }
        }
    }

    public func restart(_ name: String) throws {
        try withMutationLock {
            _ = try requireExistingProfile(name, action: "restart")
            try stop(name)
            try start(name)
        }
    }
}

import Foundation
import ModelMatrixCore
import OSLog

/// Deploys the bundled remote agent to an SSH gateway host, so the remote
/// machine never downloads anything: the app pushes the agent modules and
/// runs the bundled installer over the user's own SSH connection.
actor RemoteAgentDeployer {
    static let logger = Logger(subsystem: "io.github.hackstar1337.modelmatrix.app", category: "agent-deployer")
    static let remoteRoot = ".local/share/modelmatrix-agent"

    let executableURL: URL
    let agentSourceURL: URL
    let coreSourceURL: URL
    let discoverySourceURL: URL
    let huggingFaceSourceURL: URL
    let connectionSourceURL: URL
    let installerURL: URL
    /// Hard cap per ssh invocation. ssh prompts that BatchMode cannot answer
    /// (Tailscale SSH re-auth, host-key confirm, password) otherwise hang the
    /// push forever and the UI sticks on "Pushing agent…".
    nonisolated let sshDeadline: TimeInterval

    init(
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/ssh"),
        agentSourceURL: URL? = nil,
        coreSourceURL: URL? = nil,
        discoverySourceURL: URL? = nil,
        huggingFaceSourceURL: URL? = nil,
        connectionSourceURL: URL? = nil,
        installerURL: URL? = nil,
        sshDeadline: TimeInterval = 120
    ) {
        self.executableURL = executableURL
        self.agentSourceURL = agentSourceURL ?? Self.bundledResource("modelmatrix_agent.py")
        self.coreSourceURL = coreSourceURL ?? Self.bundledResource("agent_core.py")
        self.discoverySourceURL = discoverySourceURL ?? Self.bundledResource("discovery.py")
        self.huggingFaceSourceURL = huggingFaceSourceURL ?? Self.bundledResource("hf_agent.py")
        self.connectionSourceURL = connectionSourceURL ?? Self.bundledResource("client_connections.py")
        self.installerURL = installerURL ?? Self.bundledResource("install-remote-agent.sh")
        self.sshDeadline = sshDeadline
    }
}

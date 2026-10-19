import AppKit
import SwiftUI
import ModelMatrixCore

extension GatewaySettingsSection {
    func isSSHDeployReady(_ config: GatewayConfig) -> Bool {
        guard case .ssh(let ssh) = config.connection else { return false }
        return ssh.sshHost.nonEmptyWhitespaceTrimmed != nil && !ssh.hasUnsafeDestination
    }
}

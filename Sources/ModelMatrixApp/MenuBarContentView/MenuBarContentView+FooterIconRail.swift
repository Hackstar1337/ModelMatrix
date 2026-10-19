import AppKit
import SwiftUI
import ModelMatrixCore

extension MenuBarContentView {
    var footerIconRail: some View {
        HStack(spacing: 2) {
            footerIconButton("chart.bar.xaxis", label: "Usage") {
                let nextPanel = inspectorCoordinator.toggle(.usage)
                synchronizeInspectorWindow(panel: nextPanel)
            }
            footerIconButton("square.stack.3d.up", label: "Profiles") {
                let nextPanel = inspectorCoordinator.toggle(.profiles)
                synchronizeInspectorWindow(panel: nextPanel)
            }
            footerIconButton("questionmark.circle", label: "Help") {
                let nextPanel = inspectorCoordinator.toggle(.help)
                synchronizeInspectorWindow(panel: nextPanel)
            }
            if hub.hasRemoteGateways {
                footerIconButton("server.rack", label: "Remote Hosts") {
                    let nextPanel = inspectorCoordinator.toggle(.remoteHosts)
                    synchronizeInspectorWindow(panel: nextPanel)
                }
            }
            footerIconButton("gearshape", label: "Settings") {
                let nextPanel = inspectorCoordinator.toggle(.settings)
                synchronizeInspectorWindow(panel: nextPanel)
            }
            footerIconButton("power", label: "Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .layoutPriority(1)
    }
}

import SwiftUI
import ModelMatrixCore

extension MenuBarContentView {
    func startAttachedMonitors() {
        systemMetrics.start()
        syncHostMetricsMonitor(hasRemotes: hub.hasRemoteGateways)
    }

    func syncHostMetricsMonitor(hasRemotes: Bool) {
        hostMetricsMonitor.attach(hub: hub)
        if hasRemotes {
            hostMetricsMonitor.start()
        } else {
            hostMetricsMonitor.stop()
        }
    }
}

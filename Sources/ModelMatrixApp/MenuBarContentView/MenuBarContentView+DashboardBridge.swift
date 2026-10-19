import SwiftUI
import ModelMatrixCore

extension MenuBarContentView {
    /// Opens the web dashboard (`http://localhost:7700`) in the default browser.
    var headerDashboardControl: some View {
        Button {
            WebDashboard.open(store)
        } label: {
            Image(systemName: "safari")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(theme.faint)
                .frame(width: DashboardChromeMetrics.footerIconHitSize, height: DashboardChromeMetrics.footerIconHitSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(TactilePressStyle())
        .accessibilityLabel("Open Web Dashboard")
        .help("Open the web dashboard in your browser")
    }

    /// Shows the panel the web dashboard asked for (Settings, Usage, Profiles).
    func applyDashboardRequests<Content: View>(_ content: Content) -> some View {
        content
            .onChange(of: dashboardBridge.presentRequest) { _, _ in
                showRequestedInspector()
            }
            .onAppear { showRequestedInspector() }
    }

    func showRequestedInspector() {
        guard let requested = dashboardBridge.requestedInspector else { return }
        dashboardBridge.requestedInspector = nil
        let panel: InspectorPanel? =
            switch requested {
            case "settings": .settings
            case "usage": .usage
            case "profiles": .profiles
            default: nil
            }
        if let panel { setInspectorPanel(panel) }
    }
}

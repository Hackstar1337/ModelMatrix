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

    /// Opens the Optimize panel: frees memory held by idle models and caches.
    var headerOptimizeControl: some View {
        Button {
            let nextPanel = inspectorCoordinator.toggle(.optimize)
            synchronizeInspectorWindow(panel: nextPanel)
        } label: {
            Image(systemName: "sparkles")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(inspectorCoordinator.openPanel == .optimize ? accent : theme.faint)
                .frame(width: DashboardChromeMetrics.footerIconHitSize, height: DashboardChromeMetrics.footerIconHitSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(TactilePressStyle())
        .accessibilityLabel("Optimize Memory")
        .help("Free memory held by idle models and caches")
    }

    /// Shows the panel the web dashboard asked for (Settings, Usage, Profiles, Optimize).
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
            case "optimize": .optimize
            default: nil
            }
        if let panel { setInspectorPanel(panel) }
    }
}

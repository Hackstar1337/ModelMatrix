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

    /// Opens the Hugging Face Downloads panel; shows how many downloads are running.
    var headerDownloadsControl: some View {
        let active = hfDownloads.activeCount
        return Button {
            let nextPanel = inspectorCoordinator.toggle(.downloads)
            synchronizeInspectorWindow(panel: nextPanel)
        } label: {
            HStack(spacing: 2) {
                Image(systemName: active > 0 ? "arrow.down.circle.fill" : "arrow.down.circle")
                    .font(.system(size: 10.5, weight: .semibold))
                if active > 0 {
                    Text("\(active)")
                        .font(.system(size: 9, weight: .bold).monospacedDigit())
                }
            }
            .foregroundStyle(inspectorCoordinator.openPanel == .downloads || active > 0 ? accent : theme.faint)
            .frame(minWidth: DashboardChromeMetrics.footerIconHitSize, minHeight: DashboardChromeMetrics.footerIconHitSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(TactilePressStyle())
        .accessibilityLabel(active > 0 ? "Hugging Face Downloads, \(active) running" : "Hugging Face Downloads")
        .help("Check, download and manage models from Hugging Face")
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

    /// Shows the panel the web dashboard asked for (Settings, Usage, Profiles, Optimize, Downloads).
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
            case "downloads": .downloads
            default: nil
            }
        if let panel { setInspectorPanel(panel) }
    }
}

import Foundation

/// Keeps the menu bar in step with changes made outside it.
///
/// The menu bar store polls the controller slowly while nothing runs (see
/// `AutoRefreshPolicy.idleInterval`). The controller bumps a status revision
/// whenever a request may change profile or host state, and returns it with
/// every heartbeat; when it moves, the app refreshes right away. A model
/// started from the web dashboard or the CLI therefore shows in the menu bar
/// within one heartbeat.
extension DashboardBridge {
    func syncStatusRevision(_ revision: Int?) {
        guard let revision else { return }  // controller without revisions
        if Self.shouldRefresh(previous: lastStatusRevision, current: revision) {
            refreshAfterExternalChange()
        }
        lastStatusRevision = revision
    }

    /// True when the controller reports a change since the last heartbeat.
    /// The first heartbeat only records the revision: the store already
    /// loads its status on launch.
    nonisolated static func shouldRefresh(previous: Int?, current: Int) -> Bool {
        guard let previous else { return false }
        return previous != current
    }

    /// Restarting the local refresh loop refreshes now and re-picks the
    /// cadence, so a model started elsewhere gets active-runtime polling
    /// instead of the long idle interval. Remote stores refresh once.
    func refreshAfterExternalChange() {
        store?.startAutoRefresh()
        for runtime in hub?.remoteRuntimes ?? [] {
            Task { await runtime.store.refresh() }
        }
    }
}

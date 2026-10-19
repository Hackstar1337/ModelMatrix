import Foundation
import ModelMatrixCore

extension MenuBarContentView {
    static func isDisplayedRunning(
        _ status: ModelProfileStatus,
        in store: MatrixStore,
        relativeTo now: Date = .now
    ) -> Bool {
        guard status.isBoardVisible else { return false }
        return store.profileBadgeState(for: status, relativeTo: now) == .running
    }

    /// Legacy mlx / llama.cpp classification for tests and older call sites.
    static func runtimeKind(_ status: ModelProfileStatus) -> String? {
        DashboardFilterPreferences.legacyRuntimeKind(status)
    }
}

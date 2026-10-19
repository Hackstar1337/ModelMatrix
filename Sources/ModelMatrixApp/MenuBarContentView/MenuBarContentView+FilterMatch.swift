import SwiftUI
import ModelMatrixCore

extension MenuBarContentView {
    func matchesFilter(_ status: ModelProfileStatus) -> Bool {
        matchesFilter(status, in: store)
    }

    func isLocalHero(_ status: ModelProfileStatus) -> Bool {
        matchesFilter(status) && (isDisplayedRunning(status) || store.isBusy(profile: status.profile))
    }

    func isDisplayedRunning(_ status: ModelProfileStatus, relativeTo now: Date = .now) -> Bool {
        Self.isDisplayedRunning(status, in: store, relativeTo: now)
    }

    func matchesFilter(_ status: ModelProfileStatus, in store: MatrixStore) -> Bool {
        DashboardFilterPreferences.matches(
            status,
            filterID: profileFilter,
            isDisplayedRunning: MenuBarContentView.isDisplayedRunning(status, in: store),
            isBusy: store.isBusy(profile: status.profile)
        )
    }
}

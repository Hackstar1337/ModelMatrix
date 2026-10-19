import Testing
@testable import ModelMatrixApp

/// The bridge refreshes the menu bar when the controller's status revision
/// moves, so changes made from the web dashboard or CLI show up at once.
@Test func dashboardBridgeRefreshesOnlyWhenRevisionMoves() {
    // First heartbeat: just record the revision (the store loads on launch).
    #expect(!DashboardBridge.shouldRefresh(previous: nil, current: 0))
    #expect(!DashboardBridge.shouldRefresh(previous: nil, current: 7))
    #expect(!DashboardBridge.shouldRefresh(previous: 7, current: 7))
    #expect(DashboardBridge.shouldRefresh(previous: 7, current: 9))
    // A restarted controller starts counting again from zero.
    #expect(DashboardBridge.shouldRefresh(previous: 42, current: 0))
}

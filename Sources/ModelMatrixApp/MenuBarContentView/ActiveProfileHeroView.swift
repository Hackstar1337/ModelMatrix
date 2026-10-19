import SwiftUI
import ModelMatrixCore

/// Shared hero card for the active local or remote profile.
struct ActiveProfileHeroView: View {
    enum Context: Equatable {
        case local
        case remote(gatewayName: String)
    }

    let profile: ModelProfileStatus
    let store: MatrixStore
    var context: Context = .local
    var hostMetrics: HostMetricsPayload? = nil
    var decodeTokensPerSecond: Double? = nil
    var ttftMilliseconds: Double? = nil
    /// Mac-reachable URL for remote heroes (forwarded / rewritten).
    var reachableEndpointURL: String? = nil
    var onOpenBenchmarks: (() -> Void)? = nil
    let theme: DashboardTheme
    let accent: Color
    @AppStorage(DisplayPrivacy.defaultsKey) var hideHostInfo = false
}

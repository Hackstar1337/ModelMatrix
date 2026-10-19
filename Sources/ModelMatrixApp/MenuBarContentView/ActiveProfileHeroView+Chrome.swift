import SwiftUI
import ModelMatrixCore

extension ActiveProfileHeroView {
    @ViewBuilder
    var trailingMetric: some View {
        VStack(alignment: .trailing, spacing: 2) {
            switch context {
            case .local:
                localTrailingMetrics
            case .remote:
                remoteTrailingMetrics
            }
        }
        .accessibilityElement(children: .combine)
    }
}

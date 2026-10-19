import Foundation
import ModelMatrixCore

extension RemoteHostMetricsMonitor {
    func clientPollTarget(
        id: String,
        previous: Entry,
        store: MatrixStore
    ) -> RemoteHostMetricsPollTarget {
        do {
            return RemoteHostMetricsPollTarget(
                id: id,
                previous: previous,
                client: try store.client,
                immediateError: nil,
                preserveUpdatedAt: false
            )
        } catch {
            return RemoteHostMetricsPollTarget(
                id: id,
                previous: previous,
                client: nil,
                immediateError: MatrixStore.userFacingErrorDescription(for: error),
                preserveUpdatedAt: false
            )
        }
    }
}

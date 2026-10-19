import Foundation
import ModelMatrixCore

extension MatrixStore {
    func runIntegration(_ integration: ControllerIntegration, action: String = "sync") async {
        guard pendingIntegrationActions.insert(integration.id).inserted else { return }
        defer { pendingIntegrationActions.remove(integration.id) }
        await run { try await $0.runIntegration(id: integration.id, action: action) }
    }
}

import Foundation
import ModelMatrixCore

extension MatrixStore {
    func syncAuxiliaryStateAfterMutation() async {
        await probeLoopbackEndpointsIfNeeded()
        if let report = try? await client.fetchDoctorReport() {
            apply(doctorReport: report)
        }
    }
}

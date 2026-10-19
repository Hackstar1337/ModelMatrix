import SwiftUI
import ModelMatrixCore

extension RemoteGatewaySectionView {
    var emptyProfilesMessage: String {
        if let profilesDirectory = store.profilesDirectory, !profilesDirectory.isEmpty {
            return "No model profiles in \(profilesDirectory). Drop .env/.json launch files there, or re-run `modelmatrix-agent link` on the host to pick another folder."
        }
        return "No model profiles reported yet. On the host, run `modelmatrix-agent link` to choose a profiles folder."
    }
}

import Foundation
import ModelMatrixCore

extension MatrixStore {
    func markProfilesStarting(_ profiles: [String]) {
        for profile in profiles {
            pendingProfileActions[profile] = .starting
            markProfile(profile, running: true, ready: false)
        }
    }

    func clearPendingProfileActions(_ profiles: [String]) {
        for profile in profiles {
            pendingProfileActions.removeValue(forKey: profile)
        }
    }
}

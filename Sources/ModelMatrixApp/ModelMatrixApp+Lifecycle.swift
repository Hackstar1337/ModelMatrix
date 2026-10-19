import SwiftUI
import AppKit
import ModelMatrixCore

extension ModelMatrixApp {
    static func loadAuthToken() -> String {
        KeychainTokenStorage.shared.load() ?? ""
    }

    func applyControllerBindings() {
        if store.controllerBaseURL != controllerBaseURL {
            store.controllerBaseURL = controllerBaseURL
        }
        if store.controllerAuthToken != controllerAuthToken {
            store.controllerAuthToken = controllerAuthToken
        }
    }
}

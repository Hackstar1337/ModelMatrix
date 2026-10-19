import SwiftUI
import AppKit
import ModelMatrixCore
import MenuBarExtraAccess

extension ModelMatrixApp {
    func applyMenuBarContentLifecycle<Content: View>(_ content: Content) -> some View {
        content
            .onAppear {
                applyControllerBindings()
            }
            .onChange(of: controllerBaseURL) { _, newValue in
                store.controllerBaseURL = newValue
                Task { await store.refresh(includeDoctor: true) }
            }
            .onChange(of: controllerAuthToken) { _, newValue in
                handleTokenChange(newValue)
            }
    }
}

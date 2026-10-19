import SwiftUI
import AppKit
import ModelMatrixCore
import MenuBarExtraAccess

@main
struct ModelMatrixApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage(ControllerEndpointDefaults.baseURLUserDefaultsKey)
    var controllerBaseURL = ControllerEndpointDefaults.baseURLString
    @State var controllerAuthToken: String = ""
    @AppStorage(DashboardAppearanceKeys.menuBarShowsReadyCount) var menuBarShowsReadyCount = true
    @State var store: MatrixStore
    @State var hub: GatewayHub
    @State var tokenSaveTask: Task<Void, Never>?
    @StateObject var launchAtLoginManager = LaunchAtLoginManager.shared
    @State var isMenuPresented = false
    @State var statusItem: NSStatusItem?
    @State var statusItemClickGate = StatusItemClickGate()

    init() {
        let token = Self.loadAuthToken()
        let baseURL =
            UserDefaults.standard.string(forKey: ControllerEndpointDefaults.baseURLUserDefaultsKey)
            ?? ControllerEndpointDefaults.baseURLString
        _controllerAuthToken = State(initialValue: token)
        let store = MatrixStore(
            controllerBaseURL: baseURL,
            controllerAuthToken: token
        )
        _store = State(initialValue: store)
        _hub = State(initialValue: GatewayHub(localStore: store))
    }

    var body: some Scene {
        menuBarScene
    }
}

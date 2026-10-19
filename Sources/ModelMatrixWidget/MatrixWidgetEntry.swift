import AppIntents
import WidgetKit
import ModelMatrixCore

enum WidgetControllerConfig {
    static let defaultBaseURL = ControllerEndpointDefaults.baseURLString
    static let reloadInterval: TimeInterval = 60

    static var authToken: String? {
        KeychainTokenStorage.shared.load()?.nonEmptyTrimmed
    }
}

struct MatrixWidgetEntry: TimelineEntry {
    let date: Date
    let configuration: MatrixWidgetConfigurationIntent
    let payload: ControllerStatusPayload?
    let errorDescription: String?
}

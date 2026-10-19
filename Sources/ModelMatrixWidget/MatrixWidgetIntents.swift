import AppIntents
import WidgetKit
import ModelMatrixCore

enum MatrixWidgetDisplayMode: String, AppEnum {
    case summary
    case readyFirst

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Display Mode")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .summary: .init(title: "Summary"),
        .readyFirst: .init(title: "Ready Models")
    ]
}

struct MatrixWidgetConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Matrix Widget"
    static let description = IntentDescription("Choose what the widget emphasizes.")

    @Parameter(title: "Display Mode")
    var displayMode: MatrixWidgetDisplayMode?

    init() {
        displayMode = .summary
    }
}

struct RefreshMatrixWidgetIntent: AppIntent {
    static let title: LocalizedStringResource = "Refresh Widget"
    static let description = IntentDescription("Reload the ModelMatrix widget timeline.")
    static let isDiscoverable = false
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

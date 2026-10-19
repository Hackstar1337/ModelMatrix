import AppIntents
import OSLog
import WidgetKit
import ModelMatrixCore

struct MatrixTimelineProvider: AppIntentTimelineProvider {
    static let logger = Logger(subsystem: "io.github.hackstar1337.modelmatrix.widget", category: "timeline")

    func placeholder(in context: Context) -> MatrixWidgetEntry {
        MatrixWidgetEntry(
            date: .now,
            configuration: MatrixWidgetConfigurationIntent(),
            payload: ControllerStatusPayload(statuses: sampleStatuses, benchmark: nil, integrations: []),
            errorDescription: nil
        )
    }

    func snapshot(for configuration: MatrixWidgetConfigurationIntent, in context: Context) async -> MatrixWidgetEntry {
        await makeEntry(for: configuration)
    }

    func timeline(for configuration: MatrixWidgetConfigurationIntent, in context: Context) async -> Timeline<MatrixWidgetEntry> {
        let entry = await makeEntry(for: configuration)
        return Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(WidgetControllerConfig.reloadInterval)))
    }

    func makeEntry(for configuration: MatrixWidgetConfigurationIntent) async -> MatrixWidgetEntry {
        do {
            return try await liveEntry(for: configuration)
        } catch {
            return cachedOrFailedEntry(for: configuration, error: error)
        }
    }
}

import AppIntents
import OSLog
import WidgetKit
import ModelMatrixCore

extension MatrixTimelineProvider {
    func liveEntry(for configuration: MatrixWidgetConfigurationIntent) async throws -> MatrixWidgetEntry {
        let client = try ControllerClient(
            baseURLString: WidgetControllerConfig.defaultBaseURL,
            authToken: WidgetControllerConfig.authToken
        )
        let payload = try await client.fetchStatus()
        do {
            try ControllerStatusCache.write(payload)
        } catch {
            Self.logger.error("Cache write failed: \(String(describing: error), privacy: .public)")
        }
        return MatrixWidgetEntry(date: .now, configuration: configuration, payload: payload, errorDescription: nil)
    }

    func cachedOrFailedEntry(
        for configuration: MatrixWidgetConfigurationIntent,
        error: Error
    ) -> MatrixWidgetEntry {
        if let cached = ControllerStatusCache.load() {
            return MatrixWidgetEntry(
                date: cached.cachedAt,
                configuration: configuration,
                payload: cached.payload,
                errorDescription: "Controller unavailable. Showing cached state."
            )
        }
        return MatrixWidgetEntry(
            date: .now,
            configuration: configuration,
            payload: nil,
            errorDescription: UserFacingControllerError.description(for: error, isLocal: true)
                ?? "Controller unavailable."
        )
    }
}

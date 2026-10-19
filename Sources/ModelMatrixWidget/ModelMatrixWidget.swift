import SwiftUI
import WidgetKit
import ModelMatrixCore

struct ModelMatrixStatusWidget: Widget {
    var kind: String {
        "ModelMatrixStatusWidget"
    }

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: MatrixWidgetConfigurationIntent.self, provider: MatrixTimelineProvider()) { entry in
            MatrixWidgetView(entry: entry)
        }
        .configurationDisplayName("ModelMatrix")
        .description("Shows local model readiness and quick runtime context.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct ModelMatrixWidgetBundle: WidgetBundle {
    var body: some Widget {
        ModelMatrixStatusWidget()
    }
}

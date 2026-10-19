import SwiftUI
import ModelMatrixCore

extension SettingsControllerSection {
    @ViewBuilder
    var doctorBlock: some View {
        if let doctorReport {
            doctorSummary(doctorReport)
        }

        SettingsLinkButton(
            title: isRunningControllerDoctor ? "Running Controller Doctor\u{2026}" : "Run Controller Doctor",
            emphasized: true,
            theme: theme,
            accent: accent,
            action: runControllerDoctor
        )
        .disabled(isRunningControllerDoctor)

        doctorDiagnostics
    }
}

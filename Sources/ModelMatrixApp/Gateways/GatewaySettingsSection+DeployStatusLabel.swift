import SwiftUI
import ModelMatrixCore

extension GatewaySettingsSection {
    func deployStatusLabel(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(color)
    }
}

import SwiftUI
import ModelMatrixCore

extension GatewaySettingsSection {
    func deployButton(
        _ title: String,
        prominent: Bool,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: prominent ? .semibold : .regular))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    prominent ? accent.opacity(0.18) : theme.btnBg,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .foregroundStyle(prominent ? accent : theme.btnFg)
                .contentShape(Rectangle())
        }
        .buttonStyle(TactilePressStyle())
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
    }
}

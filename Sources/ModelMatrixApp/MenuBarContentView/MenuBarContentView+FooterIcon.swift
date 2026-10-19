import SwiftUI
import ModelMatrixCore

extension MenuBarContentView {
    func footerIconButton(_ systemName: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.faint)
                // Square hit target keeps the glyph centered away from the
                // continuous corner clip at the panel's bottom-right.
                .frame(
                    width: DashboardChromeMetrics.footerIconHitSize,
                    height: DashboardChromeMetrics.footerIconHitSize,
                    alignment: .center
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(TactilePressStyle())
        .accessibilityLabel(label)
        .help(label)
    }
}

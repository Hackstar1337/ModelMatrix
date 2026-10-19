import AppKit
import SwiftUI
import ModelMatrixCore

extension RemoteGatewayCardView {
    var renameEditor: some View {
        HStack(spacing: 6) {
            TextField("Display name", text: $renameDraft)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, weight: .semibold))
                .onSubmit { commitRename() }
            Button("Save") { commitRename() }
                .buttonStyle(TactilePressStyle())
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(accent)
            Button("Cancel") {
                renamingGatewayID = nil
                renameDraft = ""
                renameError = nil
            }
            .buttonStyle(TactilePressStyle())
            .font(.system(size: 11.5))
            .foregroundStyle(theme.sub)
        }
    }

    func commitRename() {
        guard let trimmed = renameDraft.nonEmptyTrimmed else {
            renameError = "Give this gateway a name."
            return
        }
        _ = hub.renameGateway(id: runtime.id, to: trimmed)
        renamingGatewayID = nil
        renameDraft = ""
        renameError = nil
    }
}

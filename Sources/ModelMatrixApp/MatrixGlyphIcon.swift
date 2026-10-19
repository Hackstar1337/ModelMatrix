import AppKit
import SwiftUI

/// Menu bar glyph: the ModelMatrix dot-matrix "M" (the same 5x5 mark as the
/// app icon), drawn as a template image so macOS tints it for light and dark
/// menu bars. Template images keep their alpha channel, so unlit cells are
/// drawn faintly to show the grid. MenuBarExtra labels only render `Image`
/// and `Text`, so the grid is rasterized into an `NSImage` rather than drawn
/// with SwiftUI shapes.
///
/// - ready models: the whole M lit
/// - running but not yet ready: the two outer columns lit, the middle dim
/// - idle: the M dim
struct MatrixGlyphIcon: View {
    let hasReadyModels: Bool
    let hasRunningModels: Bool
    var size: CGFloat = 18

    enum State: Equatable {
        case ready
        case running
        case idle
    }

    var state: State {
        if hasReadyModels { return .ready }
        if hasRunningModels { return .running }
        return .idle
    }

    var body: some View {
        Image(nsImage: Self.image(for: state, size: size))
            .renderingMode(.template)
            .frame(width: size, height: size)
            .contentShape(Rectangle())
            .accessibilityLabel(Self.accessibilityLabel(for: state))
    }

    static func accessibilityLabel(for state: State) -> String {
        switch state {
        case .ready: "ModelMatrix: model ready"
        case .running: "ModelMatrix: model starting"
        case .idle: "ModelMatrix: idle"
        }
    }

    /// The 5x5 "M", row-major from the top-left. `X` cells form the letter.
    static let pattern = ["X...X", "XX.XX", "X.X.X", "X...X", "X...X"]
    static let gridSize = 5

    static func isLetterCell(row: Int, column: Int) -> Bool {
        guard pattern.indices.contains(row) else { return false }
        let line = Array(pattern[row])
        guard line.indices.contains(column) else { return false }
        return line[column] == "X"
    }

    /// Opacity of one cell for a state. Letter cells carry the status; the
    /// rest stay faint so the matrix shows without crowding the M.
    static func cellAlpha(for state: State, row: Int, column: Int) -> CGFloat {
        let letter = isLetterCell(row: row, column: column)
        switch state {
        case .ready:
            return letter ? 1 : 0.13
        case .running:
            guard letter else { return 0.1 }
            return column == 0 || column == gridSize - 1 ? 1 : 0.3
        case .idle:
            return letter ? 0.42 : 0.08
        }
    }

    @MainActor private static var cache: [String: NSImage] = [:]

    @MainActor
    static func image(for state: State, size: CGFloat) -> NSImage {
        let key = "\(state)-\(size)"
        if let cached = cache[key] { return cached }
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            let unit = rect.width / 18
            let inset = 1.0 * unit
            let gap = 0.72 * unit
            let count = CGFloat(gridSize)
            let cell = (rect.width - inset * 2 - gap * (count - 1)) / count
            let radius = cell * 0.24
            for row in 0..<gridSize {
                for column in 0..<gridSize {
                    let cellRect = NSRect(
                        x: inset + CGFloat(column) * (cell + gap),
                        y: inset + CGFloat(row) * (cell + gap),
                        width: cell,
                        height: cell
                    )
                    let alpha = cellAlpha(for: state, row: row, column: column)
                    NSColor.black.withAlphaComponent(alpha).setFill()
                    NSBezierPath(roundedRect: cellRect, xRadius: radius, yRadius: radius).fill()
                }
            }
            return true
        }
        image.isTemplate = true
        cache[key] = image
        return image
    }
}

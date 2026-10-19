import AppKit
import SwiftUI

/// Menu bar glyph: a 3x3 matrix drawn as a template image so macOS tints it
/// for light / dark menu bars. MenuBarExtra labels only render `Image` and
/// `Text`, so the grid is rasterized into an `NSImage` rather than drawn with
/// SwiftUI shapes.
///
/// - ready models: every cell filled
/// - running but not yet ready: checkerboard (5 cells) filled
/// - idle: outlined cells only
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

    /// Cells lit for each state, row-major over the 3x3 grid.
    static func litCells(for state: State) -> Set<Int> {
        switch state {
        case .ready: Set(0..<9)
        case .running: [0, 2, 4, 6, 8]
        case .idle: []
        }
    }

    @MainActor private static var cache: [String: NSImage] = [:]

    @MainActor
    static func image(for state: State, size: CGFloat) -> NSImage {
        let key = "\(state)-\(size)"
        if let cached = cache[key] { return cached }
        let lit = litCells(for: state)
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            let inset = rect.width * 0.08
            let gap = rect.width * 0.09
            let cell = (rect.width - inset * 2 - gap * 2) / 3
            let radius = cell * 0.28
            let lineWidth = max(1.0, rect.width * 0.065)
            NSColor.black.setFill()
            NSColor.black.setStroke()
            for index in 0..<9 {
                let row = CGFloat(index / 3)
                let column = CGFloat(index % 3)
                let cellRect = NSRect(
                    x: inset + column * (cell + gap),
                    y: inset + row * (cell + gap),
                    width: cell,
                    height: cell
                )
                if lit.contains(index) {
                    NSBezierPath(roundedRect: cellRect, xRadius: radius, yRadius: radius).fill()
                } else {
                    let stroked = cellRect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
                    let path = NSBezierPath(roundedRect: stroked, xRadius: radius, yRadius: radius)
                    path.lineWidth = lineWidth
                    path.stroke()
                }
            }
            return true
        }
        image.isTemplate = true
        cache[key] = image
        return image
    }
}

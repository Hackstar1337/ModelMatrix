import AppKit
import Testing
@testable import ModelMatrixApp

/// The menu bar glyph is the 5x5 dot-matrix "M" from the app icon; its cell
/// opacities carry the ready / starting / idle status.

private func cells() -> [(row: Int, column: Int)] {
    (0..<MatrixGlyphIcon.gridSize).flatMap { row in
        (0..<MatrixGlyphIcon.gridSize).map { (row: row, column: $0) }
    }
}

@Test func matrixGlyphPatternSpellsM() {
    #expect(MatrixGlyphIcon.pattern.count == 5)
    #expect(MatrixGlyphIcon.pattern.allSatisfy { $0.count == 5 })
    let letter = cells().filter { MatrixGlyphIcon.isLetterCell(row: $0.row, column: $0.column) }
    #expect(letter.count == 13)
    // Both legs run the full height; the middle peak sits in the centre.
    #expect((0..<5).allSatisfy { MatrixGlyphIcon.isLetterCell(row: $0, column: 0) })
    #expect((0..<5).allSatisfy { MatrixGlyphIcon.isLetterCell(row: $0, column: 4) })
    #expect(MatrixGlyphIcon.isLetterCell(row: 2, column: 2))
    #expect(!MatrixGlyphIcon.isLetterCell(row: 4, column: 2))
    #expect(!MatrixGlyphIcon.isLetterCell(row: 9, column: 0))
}

@Test func matrixGlyphReadyLightsTheWholeLetter() {
    for cell in cells() {
        let alpha = MatrixGlyphIcon.cellAlpha(for: .ready, row: cell.row, column: cell.column)
        if MatrixGlyphIcon.isLetterCell(row: cell.row, column: cell.column) {
            #expect(alpha == 1)
        } else {
            #expect(alpha > 0 && alpha < 0.2)
        }
    }
}

@Test func matrixGlyphStartingLightsOnlyTheLegs() {
    for cell in cells() where MatrixGlyphIcon.isLetterCell(row: cell.row, column: cell.column) {
        let alpha = MatrixGlyphIcon.cellAlpha(for: .running, row: cell.row, column: cell.column)
        let isLeg = cell.column == 0 || cell.column == 4
        #expect(isLeg ? alpha == 1 : alpha < 0.5)
    }
}

@Test func matrixGlyphIdleHasNoFullyLitCell() {
    let alphas = cells().map { MatrixGlyphIcon.cellAlpha(for: .idle, row: $0.row, column: $0.column) }
    #expect(alphas.allSatisfy { $0 < 0.5 })
    // The letter still reads: it stays brighter than the background.
    #expect(MatrixGlyphIcon.cellAlpha(for: .idle, row: 0, column: 0) > MatrixGlyphIcon.cellAlpha(for: .idle, row: 0, column: 1))
}

@Test func matrixGlyphStateFollowsProfileCounts() {
    #expect(MatrixGlyphIcon(hasReadyModels: true, hasRunningModels: true).state == .ready)
    #expect(MatrixGlyphIcon(hasReadyModels: false, hasRunningModels: true).state == .running)
    #expect(MatrixGlyphIcon(hasReadyModels: false, hasRunningModels: false).state == .idle)
}

@Test @MainActor func matrixGlyphImageIsTemplateAtRequestedSize() {
    let image = MatrixGlyphIcon.image(for: .ready, size: 18)
    #expect(image.isTemplate)
    #expect(image.size == NSSize(width: 18, height: 18))
    #expect(MatrixGlyphIcon.image(for: .ready, size: 18) === image)
}

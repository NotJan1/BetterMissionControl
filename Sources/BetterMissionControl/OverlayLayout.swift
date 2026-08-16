import CoreGraphics
import Foundation

/// Geometry for the overview.
///
/// Tiles are placed freely (R4), but they still need a sensible *starting*
/// arrangement and a consistent size, both of which come from a notional grid.
enum OverlayLayout {
    static let spacing: CGFloat = 26
    static let outerPadding: CGFloat = 72
    static let labelHeight: CGFloat = 24
    static let cornerRadius: CGFloat = 10

    /// Aims for a block of tiles roughly as wide-to-tall as the screen, which
    /// is what keeps the automatic arrangement feeling like Mission Control.
    static func columnCount(for count: Int, in size: CGSize) -> Int {
        guard count > 1 else { return max(count, 1) }
        let aspect = max(size.width / max(size.height, 1), 0.5)
        let ideal = Int(ceil((Double(count) * Double(aspect)).squareRoot()))
        return max(1, min(count, ideal))
    }

    static func rowCount(for count: Int, columns: Int) -> Int {
        guard columns > 0 else { return 1 }
        return max(1, Int(ceil(Double(count) / Double(columns))))
    }

    /// The box a tile is fitted into. Uniform across tiles so a freely
    /// arranged layout still reads as one set rather than a jumble of sizes.
    static func cellSize(count: Int, in size: CGSize) -> CGSize {
        let columns = columnCount(for: count, in: size)
        let rows = rowCount(for: count, columns: columns)
        let availableWidth = size.width - outerPadding * 2 - spacing * CGFloat(columns - 1)
        let availableHeight = size.height - outerPadding * 2 - spacing * CGFloat(rows - 1)
        return CGSize(
            width: max(140, availableWidth / CGFloat(columns)),
            height: max(110, availableHeight / CGFloat(rows))
        )
    }

    /// Starting centres, normalised to 0...1, for windows with no saved
    /// position — the automatic app-grouped arrangement of R3.
    static func automaticCenters(count: Int, in size: CGSize) -> [CGPoint] {
        guard count > 0, size.width > 0, size.height > 0 else { return [] }
        let columns = columnCount(for: count, in: size)
        let rows = rowCount(for: count, columns: columns)
        let cell = cellSize(count: count, in: size)

        // Centre the whole block in the overlay.
        let blockWidth = CGFloat(columns) * cell.width + CGFloat(columns - 1) * spacing
        let blockHeight = CGFloat(rows) * cell.height + CGFloat(rows - 1) * spacing
        let originX = (size.width - blockWidth) / 2
        let originY = (size.height - blockHeight) / 2

        return (0 ..< count).map { index in
            let column = index % columns
            let row = index / columns
            let x = originX + CGFloat(column) * (cell.width + spacing) + cell.width / 2
            let y = originY + CGFloat(row) * (cell.height + spacing) + cell.height / 2
            return CGPoint(x: x / size.width, y: y / size.height)
        }
    }

    /// Keeps a tile fully inside the overlay, so a tile can't be stranded
    /// half off-screen where its close button is unreachable.
    static func clampCenter(_ center: CGPoint, tile: CGSize, in size: CGSize) -> CGPoint {
        guard size.width > 0, size.height > 0 else { return center }
        let halfWidth = tile.width / 2
        let halfHeight = tile.height / 2
        let minX = halfWidth / size.width
        let maxX = 1 - halfWidth / size.width
        let minY = halfHeight / size.height
        let maxY = 1 - halfHeight / size.height
        return CGPoint(
            x: min(max(center.x, min(minX, 0.5)), max(maxX, 0.5)),
            y: min(max(center.y, min(minY, 0.5)), max(maxY, 0.5))
        )
    }
}

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
    /// Gap between a tile's thumbnail and its label.
    static let labelSpacing: CGFloat = 6
    static let cornerRadius: CGFloat = 10

    /// The part of a cell available to the thumbnail, before its own aspect
    /// ratio is taken into account.
    static func imageArea(of cell: CGSize) -> CGSize {
        CGSize(width: cell.width, height: max(40, cell.height - labelHeight - labelSpacing))
    }

    /// The exact size a window's thumbnail is drawn at.
    ///
    /// Computed rather than left to SwiftUI's `.aspectRatio` + `.frame(max:)`:
    /// a flexible frame is *greedy*, so it expands to whatever the cell offers
    /// instead of capping, which stretched tiles to the full height of the
    /// screen whenever few windows made cells tall.
    static func thumbnailSize(aspect: CGFloat, native: CGSize, in cell: CGSize) -> CGSize {
        let area = imageArea(of: cell)
        let safeAspect = max(aspect, 0.01)

        var size = CGSize(width: area.width, height: area.width / safeAspect)
        if size.height > area.height {
            size = CGSize(width: area.height * safeAspect, height: area.height)
        }
        // Never larger than the window itself — there'd be no extra detail to
        // show, so scaling it up would only look soft.
        if native.width > 0, size.width > native.width {
            size = native
        }
        return size
    }

    /// Thumbnail plus its label: the tile's real bounds.
    ///
    /// Tiles are framed to this rather than to the whole cell, so a tile's
    /// clickable and draggable area matches what's actually drawn instead of
    /// spilling over its neighbours.
    static func tileSize(aspect: CGFloat, native: CGSize, in cell: CGSize) -> CGSize {
        let thumbnail = thumbnailSize(aspect: aspect, native: native, in: cell)
        return CGSize(
            width: thumbnail.width,
            height: thumbnail.height + labelSpacing + labelHeight
        )
    }

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

        let blockHeight = CGFloat(rows) * cell.height + CGFloat(rows - 1) * spacing
        let originY = (size.height - blockHeight) / 2

        return (0 ..< count).map { index in
            let column = index % columns
            let row = index / columns
            // Each row is centred on its own contents, so a part-filled last
            // row sits under the middle of the block rather than hugging the
            // left edge and leaving a void beside it.
            let itemsInRow = min(columns, count - row * columns)
            let rowWidth = CGFloat(itemsInRow) * cell.width + CGFloat(itemsInRow - 1) * spacing
            let originX = (size.width - rowWidth) / 2

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

import CoreGraphics
import Foundation

/// Grid geometry for the overview.
///
/// The column count is computed rather than left to an adaptive `LazyVGrid`
/// because keyboard navigation needs to know exactly how many columns there
/// are for up/down to land where the eye expects (R5).
enum OverlayLayout {
    static let spacing: CGFloat = 26
    static let outerPadding: CGFloat = 72
    static let labelHeight: CGFloat = 24
    static let cornerRadius: CGFloat = 10

    /// Aims for a block of tiles roughly as wide-to-tall as the screen itself,
    /// which is what keeps the result feeling like Mission Control.
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

    static func cellSize(count: Int, columns: Int, in size: CGSize) -> CGSize {
        let rows = rowCount(for: count, columns: columns)
        let availableWidth = size.width - outerPadding * 2 - spacing * CGFloat(columns - 1)
        let availableHeight = size.height - outerPadding * 2 - spacing * CGFloat(rows - 1)
        return CGSize(
            width: max(140, availableWidth / CGFloat(columns)),
            height: max(110, availableHeight / CGFloat(rows))
        )
    }
}

extension Array {
    /// Splits a flat window list into grid rows.
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}

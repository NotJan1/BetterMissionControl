import AppKit
import CoreGraphics

/// Identity used to remember a tile's position across launches.
///
/// Accessibility/ScreenCaptureKit window references aren't stable across app
/// relaunches, so the layout is keyed by bundle identifier + window title
/// instead. Two windows of one app sharing a title are treated as
/// interchangeable for ordering purposes.
struct LayoutKey: Codable, Hashable {
    let appID: String
    let title: String
}

/// One on-screen window, as shown by a tile in the overview.
struct ManagedWindow: Identifiable {
    let id: CGWindowID
    let pid: pid_t
    let appName: String
    let bundleID: String?
    let title: String
    /// Global screen coordinates, top-left origin — the same space the
    /// Accessibility API reports, which is what makes window matching work.
    let frame: CGRect
    /// The frame the tile is *drawn* from, frozen when the window first
    /// appears in the overview.
    ///
    /// `frame` has to stay live because Accessibility matching compares
    /// against the window's real position. But laying tiles out from a live
    /// frame made the whole overview twitch: revealing the Dock reflows every
    /// full-height window (1205 -> 1113pt here), so a second after opening,
    /// every tile changed aspect ratio and resized at once. The overview holds
    /// still instead.
    var layoutFrame: CGRect
    var thumbnail: CGImage?
    /// Tile centre as a fraction of the overlay's size (0...1), once resolved
    /// from either the saved layout or the automatic arrangement.
    var normalizedCenter: CGPoint?

    var layoutKey: LayoutKey {
        LayoutKey(appID: bundleID ?? appName, title: title)
    }

    var displayTitle: String {
        title.trimmingCharacters(in: .whitespaces).isEmpty ? appName : title
    }

    /// Clamped so a pathologically shaped window can't blow up the grid.
    var aspectRatio: CGFloat {
        guard layoutFrame.width > 0, layoutFrame.height > 0 else { return 16.0 / 9.0 }
        return min(max(layoutFrame.width / layoutFrame.height, 0.3), 4.0)
    }

    var appIcon: NSImage? {
        NSRunningApplication(processIdentifier: pid)?.icon
    }

    /// Size a tile's thumbnail is drawn at inside the given cell.
    func thumbnailSize(in cell: CGSize) -> CGSize {
        OverlayLayout.thumbnailSize(aspect: aspectRatio, native: layoutFrame.size, in: cell)
    }

    /// App icon size for this tile.
    func iconSize(in cell: CGSize) -> CGFloat {
        OverlayLayout.iconSize(in: cell)
    }

    /// Thumbnail plus label — the tile's actual bounds.
    func tileSize(in cell: CGSize) -> CGSize {
        OverlayLayout.tileSize(aspect: aspectRatio, native: layoutFrame.size, in: cell)
    }
}

extension ManagedWindow: Equatable {
    static func == (lhs: ManagedWindow, rhs: ManagedWindow) -> Bool {
        lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.layoutFrame == rhs.layoutFrame
            && lhs.normalizedCenter == rhs.normalizedCenter
            && lhs.thumbnail.map(ObjectIdentifier.init) == rhs.thumbnail.map(ObjectIdentifier.init)
    }
}

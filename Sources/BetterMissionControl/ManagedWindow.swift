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
        guard frame.width > 0, frame.height > 0 else { return 16.0 / 9.0 }
        return min(max(frame.width / frame.height, 0.3), 4.0)
    }

    var appIcon: NSImage? {
        NSRunningApplication(processIdentifier: pid)?.icon
    }
}

extension ManagedWindow: Equatable {
    static func == (lhs: ManagedWindow, rhs: ManagedWindow) -> Bool {
        lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.frame == rhs.frame
            && lhs.normalizedCenter == rhs.normalizedCenter
            && lhs.thumbnail.map(ObjectIdentifier.init) == rhs.thumbnail.map(ObjectIdentifier.init)
    }
}

import CoreGraphics
import Foundation

/// One remembered tile placement.
struct LayoutEntry: Codable {
    let key: LayoutKey
    /// Tile centre as a fraction of the overlay's size (0...1).
    ///
    /// Normalised rather than absolute so a layout saved on one display still
    /// makes sense on another, and survives a resolution change.
    let center: CGPoint
}

/// Remembers where the user put each tile (R4).
///
/// Stored as JSON in Application Support — small, inspectable, and easy to
/// delete if it ever gets into a bad state.
@MainActor
final class LayoutStore {
    private let fileURL: URL
    private var entries: [LayoutEntry]

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BetterMissionControl", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("layout.json")

        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([LayoutEntry].self, from: data) {
            entries = decoded
        } else {
            entries = []
        }
    }

    var isEmpty: Bool { entries.isEmpty }

    /// Saved centre for a window, if one was stored.
    ///
    /// `consumed` lets the caller resolve several windows that share a layout
    /// key — two untitled windows of one app, say — by handing each a
    /// different saved slot instead of stacking them all in one place.
    func center(for key: LayoutKey, consumed: inout Set<Int>) -> CGPoint? {
        for (index, entry) in entries.enumerated()
        where entry.key == key && !consumed.contains(index) {
            consumed.insert(index)
            return entry.center
        }
        return nil
    }

    func save(_ windows: [ManagedWindow]) {
        entries = windows.compactMap { window in
            window.normalizedCenter.map { LayoutEntry(key: window.layoutKey, center: $0) }
        }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func reset() {
        entries = []
        try? FileManager.default.removeItem(at: fileURL)
    }
}

import Foundation

/// Remembers the user's custom tile order between launches (R4).
///
/// Stored as a plain JSON list of `LayoutKey`s in Application Support — small,
/// inspectable, and trivially deletable if it ever gets into a bad state.
@MainActor
final class LayoutStore {
    private let fileURL: URL
    private var order: [LayoutKey]

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BetterMissionControl", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("layout.json")

        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([LayoutKey].self, from: data) {
            order = decoded
        } else {
            order = []
        }
    }

    var hasSavedOrder: Bool { !order.isEmpty }

    /// Reorders `windows` to match the saved layout.
    ///
    /// Saved entries whose window is no longer open are simply skipped, and
    /// windows we've never seen keep their automatic-arrangement position at
    /// the end — so the layout degrades gracefully instead of needing a reset.
    func applyOrder(to windows: [ManagedWindow]) -> [ManagedWindow] {
        guard !order.isEmpty else { return windows }

        var remaining = windows
        var arranged: [ManagedWindow] = []
        for key in order {
            guard let index = remaining.firstIndex(where: { $0.layoutKey == key }) else { continue }
            arranged.append(remaining.remove(at: index))
        }
        arranged.append(contentsOf: remaining)
        return arranged
    }

    func save(_ windows: [ManagedWindow]) {
        order = windows.map(\.layoutKey)
        guard let data = try? JSONEncoder().encode(order) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func reset() {
        order = []
        try? FileManager.default.removeItem(at: fileURL)
    }
}

import AppKit
import Observation
import ScreenCaptureKit

/// The single source of truth behind the overlay's SwiftUI view.
@MainActor
@Observable
final class OverviewModel {
    enum State: Equatable {
        case loading
        case ready
        case empty
        case missingPermissions([Permission])
    }

    private(set) var state: State = .loading
    private(set) var windows: [ManagedWindow] = []
    private(set) var desktopPicture: CGImage?
    var selectedID: CGWindowID?
    /// Which tile the pointer is over. Lives here rather than in the tile view
    /// because SwiftUI's `@State` is a macro whose compiler plugin ships only
    /// with full Xcode, and only one tile can be hovered at a time anyway.
    var hoveredID: CGWindowID?

    /// How often the overlay re-reads the window list and re-captures
    /// thumbnails while open. Fast enough to feel live (R10), slow enough not
    /// to hammer ScreenCaptureKit.
    private let refreshInterval = Duration.milliseconds(1000)

    private var sourceWindows: [CGWindowID: SCWindow] = [:]
    private var refreshTask: Task<Void, Never>?
    private var terminationObserver: NSObjectProtocol?
    private let layoutStore = LayoutStore()
    private var hasLoadedOnce = false

    // MARK: - Lifecycle

    func start() {
        state = .loading
        hasLoadedOnce = false
        windows = []
        desktopPicture = nil

        let missing = PermissionsManager.missing
        if missing.contains(.screenRecording) {
            // Without Screen Recording there is nothing to enumerate, so stop
            // here and explain rather than showing an empty grid.
            state = .missingPermissions(missing)
            return
        }

        observeAppTermination()
        refreshTask = Task { [weak self] in
            await self?.runRefreshLoop()
        }
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
        if let terminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(terminationObserver)
            self.terminationObserver = nil
        }
    }

    /// R10: an app quitting elsewhere should update the overlay immediately,
    /// not on the next poll tick.
    private func observeAppTermination() {
        guard terminationObserver == nil else { return }
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication else { return }
            MainActor.assumeIsolated {
                self?.removeWindows(ofPID: app.processIdentifier)
            }
        }
    }

    private func runRefreshLoop() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: refreshInterval)
        }
    }

    // MARK: - Refresh

    private func refresh() async {
        guard let snapshot = try? await WindowEnumerator.snapshot() else {
            if !hasLoadedOnce { state = .missingPermissions(PermissionsManager.missing) }
            return
        }
        guard !Task.isCancelled else { return }

        sourceWindows = snapshot.sourceWindows
        reconcile(with: snapshot.windows)

        if !hasLoadedOnce {
            hasLoadedOnce = true
            await captureDesktopPicture(from: snapshot)
        }

        await captureThumbnails()
        state = windows.isEmpty ? .empty : .ready
        ensureValidSelection()
    }

    /// Merges a fresh snapshot into the current list *without* disturbing the
    /// user's ordering: known windows keep their slot, vanished ones drop out,
    /// and genuinely new ones are appended.
    private func reconcile(with fresh: [ManagedWindow]) {
        let freshByID = Dictionary(uniqueKeysWithValues: fresh.map { ($0.id, $0) })

        if !hasLoadedOnce {
            windows = layoutStore.applyOrder(to: fresh)
            return
        }

        var updated: [ManagedWindow] = []
        updated.reserveCapacity(fresh.count)

        for existing in windows {
            guard var refreshed = freshByID[existing.id] else { continue }
            // Keep the thumbnail we already have so the tile doesn't blink
            // between captures.
            refreshed.thumbnail = existing.thumbnail
            updated.append(refreshed)
        }

        let knownIDs = Set(updated.map(\.id))
        updated.append(contentsOf: fresh.filter { !knownIDs.contains($0.id) })
        windows = updated
    }

    private func captureThumbnails() async {
        let targets = windows.compactMap { window in
            sourceWindows[window.id].map { (id: window.id, source: $0) }
        }
        guard !targets.isEmpty else { return }

        let images = await withTaskGroup(
            of: (CGWindowID, CGImage?).self,
            returning: [CGWindowID: CGImage].self
        ) { group in
            for target in targets {
                group.addTask {
                    (target.id, await ThumbnailCapturer.capture(target.source))
                }
            }
            var collected: [CGWindowID: CGImage] = [:]
            for await (id, image) in group {
                if let image { collected[id] = image }
            }
            return collected
        }

        guard !Task.isCancelled else { return }
        for index in windows.indices {
            if let image = images[windows[index].id] {
                windows[index].thumbnail = image
            }
        }
    }

    private func captureDesktopPicture(from snapshot: WindowSnapshot) async {
        guard let display = snapshot.display else { return }
        desktopPicture = await ThumbnailCapturer.captureDesktop(
            display: display,
            excluding: snapshot.foregroundWindows
        )
    }

    // MARK: - Selection

    private func ensureValidSelection() {
        guard !windows.isEmpty else {
            selectedID = nil
            return
        }
        if let selectedID, windows.contains(where: { $0.id == selectedID }) { return }
        // Edge case: the selected window went away. Land on a real tile rather
        // than pointing at nothing.
        selectedID = windows.first?.id
    }

    var selectedIndex: Int? {
        guard let selectedID else { return nil }
        return windows.firstIndex { $0.id == selectedID }
    }

    var selectedWindow: ManagedWindow? {
        selectedIndex.map { windows[$0] }
    }

    func select(index: Int) {
        guard windows.indices.contains(index) else { return }
        selectedID = windows[index].id
    }

    /// R5: arrow keys move by grid geometry, Tab moves linearly.
    func moveSelection(_ direction: SelectionDirection, columns: Int) {
        guard !windows.isEmpty else { return }
        guard let current = selectedIndex else {
            selectedID = windows.first?.id
            return
        }

        let count = windows.count
        let target: Int
        switch direction {
        case .left: target = current - 1
        case .right: target = current + 1
        case .up: target = current - columns
        case .down: target = current + columns
        case .next: target = (current + 1) % count
        case .previous: target = (current - 1 + count) % count
        }

        // Arrow keys clamp at the edges; Tab already wrapped above.
        guard windows.indices.contains(target) else { return }
        selectedID = windows[target].id
    }

    enum SelectionDirection {
        case left, right, up, down, next, previous
    }

    // MARK: - Window actions

    func activate(_ window: ManagedWindow) {
        WindowActions.activate(window)
    }

    func close(_ window: ManagedWindow) {
        WindowActions.close(window)
        remove(id: window.id)
    }

    func minimize(_ window: ManagedWindow) {
        WindowActions.minimize(window)
        remove(id: window.id)
    }

    func quitApp(of window: ManagedWindow) {
        WindowActions.quitApp(window)
        removeWindows(ofPID: window.pid)
    }

    /// Optimistic removal — the poll would catch up within a second anyway,
    /// but waiting that long feels broken.
    private func remove(id: CGWindowID) {
        let index = windows.firstIndex { $0.id == id }
        windows.removeAll { $0.id == id }
        advanceSelection(after: index)
    }

    private func removeWindows(ofPID pid: pid_t) {
        let index = windows.firstIndex { $0.pid == pid }
        windows.removeAll { $0.pid == pid }
        advanceSelection(after: index)
    }

    private func advanceSelection(after removedIndex: Int?) {
        if windows.isEmpty {
            selectedID = nil
            state = .empty
            return
        }
        if let selectedID, windows.contains(where: { $0.id == selectedID }) { return }
        // Keep the cursor where the removed tile was, so repeated ⌘W walks
        // forward through the grid instead of jumping to the start.
        let fallback = min(removedIndex ?? 0, windows.count - 1)
        selectedID = windows[max(0, fallback)].id
    }

    // MARK: - Reordering

    /// R4: moving a tile takes effect now and is remembered for next time.
    func move(id: CGWindowID, toIndexOf targetID: CGWindowID) {
        guard id != targetID,
              let from = windows.firstIndex(where: { $0.id == id }),
              let to = windows.firstIndex(where: { $0.id == targetID })
        else { return }

        let window = windows.remove(at: from)
        windows.insert(window, at: to)
        selectedID = id
        layoutStore.save(windows)
    }

    func resetLayout() {
        layoutStore.reset()
        windows = WindowEnumerator.autoArranged(windows)
    }
}

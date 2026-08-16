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
    private(set) var draggingID: CGWindowID?
    /// Transient banner shown when an action couldn't be carried out, so a
    /// failure says so instead of looking like the overlay ignored the key.
    private(set) var actionMessage: String?
    private var messageTask: Task<Void, Never>?

    /// Set by the controller when the overlay opens. Positions are stored
    /// normalised, so nearly everything here needs the pixel size to resolve.
    var overlaySize: CGSize = .zero

    /// How often the overlay re-reads the window list and re-captures
    /// thumbnails while open. Fast enough to feel live (R10), slow enough not
    /// to hammer ScreenCaptureKit.
    private let refreshInterval = Duration.milliseconds(1000)

    private var sourceWindows: [CGWindowID: SCWindow] = [:]
    private var refreshTask: Task<Void, Never>?
    private var terminationObserver: NSObjectProtocol?
    private let layoutStore = LayoutStore()
    private var hasLoadedOnce = false
    private var dragStart: (id: CGWindowID, center: CGPoint)?

    // MARK: - Lifecycle

    func start() {
        state = .loading
        hasLoadedOnce = false
        windows = []
        desktopPicture = nil
        actionMessage = nil

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
        messageTask?.cancel()
        messageTask = nil
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
        resolvePositions()

        if !hasLoadedOnce {
            hasLoadedOnce = true
            await captureDesktopPicture(from: snapshot)
        }

        await captureThumbnails()
        state = windows.isEmpty ? .empty : .ready
        ensureValidSelection()
    }

    /// Merges a fresh snapshot into the current list, keeping each tile's
    /// placement: known windows hold their position, vanished ones drop out,
    /// and genuinely new ones arrive without a position for `resolvePositions`
    /// to fill in.
    private func reconcile(with fresh: [ManagedWindow]) {
        let freshByID = Dictionary(uniqueKeysWithValues: fresh.map { ($0.id, $0) })

        if !hasLoadedOnce {
            windows = fresh
            return
        }

        var updated: [ManagedWindow] = []
        updated.reserveCapacity(fresh.count)

        for existing in windows {
            guard var refreshed = freshByID[existing.id] else { continue }
            // Keep the thumbnail so the tile doesn't blink between captures,
            // and the position so a refresh never moves a tile the user placed.
            refreshed.thumbnail = existing.thumbnail
            refreshed.normalizedCenter = existing.normalizedCenter
            updated.append(refreshed)
        }

        let knownIDs = Set(updated.map(\.id))
        updated.append(contentsOf: fresh.filter { !knownIDs.contains($0.id) })
        windows = updated
    }

    /// Gives every tile a centre: the one the user saved if there is one (R4),
    /// otherwise a slot in the automatic app-grouped arrangement (R3).
    private func resolvePositions() {
        guard overlaySize.width > 0, overlaySize.height > 0 else { return }
        let automatic = OverlayLayout.automaticCenters(count: windows.count, in: overlaySize)
        var consumed: Set<Int> = []

        for index in windows.indices where windows[index].normalizedCenter == nil {
            if let saved = layoutStore.center(for: windows[index].layoutKey, consumed: &consumed) {
                windows[index].normalizedCenter = saved
            } else if automatic.indices.contains(index) {
                windows[index].normalizedCenter = automatic[index]
            }
        }
    }

    private func captureThumbnails() async {
        let targets = windows.compactMap { window in
            sourceWindows[window.id].map { (id: window.id, source: $0) }
        }
        guard !targets.isEmpty else { return }

        let scale = tileScale
        // Capture for the size tiles are actually drawn at, so thumbnails stay
        // sharp when few windows make tiles large, and cost less when many
        // windows make them small.
        let imageArea = OverlayLayout.imageArea(of: tileSize(in: overlaySize))
        let images = await withTaskGroup(
            of: (CGWindowID, CGImage?).self,
            returning: [CGWindowID: CGImage].self
        ) { group in
            for target in targets {
                group.addTask {
                    (target.id, await ThumbnailCapturer.capture(
                        target.source,
                        targetSize: imageArea,
                        backingScale: scale
                    ))
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

    /// Backing scale of the display the overlay is on, so captures match the
    /// pixel density they'll be drawn at rather than being upscaled.
    private var tileScale: CGFloat {
        WindowEnumerator.screenUnderCursor().backingScaleFactor
    }

    private func captureDesktopPicture(from snapshot: WindowSnapshot) async {
        guard let display = snapshot.display else { return }
        desktopPicture = await ThumbnailCapturer.captureDesktop(
            display: display,
            excluding: snapshot.foregroundWindows
        )
    }

    // MARK: - Geometry

    func tileSize(in size: CGSize) -> CGSize {
        OverlayLayout.cellSize(count: max(windows.count, 1), in: size)
    }

    func center(for window: ManagedWindow, in size: CGSize) -> CGPoint {
        let normalized = window.normalizedCenter ?? CGPoint(x: 0.5, y: 0.5)
        return CGPoint(x: normalized.x * size.width, y: normalized.y * size.height)
    }

    // MARK: - Dragging (R4)

    func beginDrag(_ window: ManagedWindow) {
        guard dragStart?.id != window.id else { return }
        dragStart = (window.id, window.normalizedCenter ?? CGPoint(x: 0.5, y: 0.5))
        draggingID = window.id
        selectedID = window.id
    }

    func updateDrag(_ window: ManagedWindow, translation: CGSize, in size: CGSize) {
        guard let dragStart, dragStart.id == window.id,
              size.width > 0, size.height > 0,
              let index = windows.firstIndex(where: { $0.id == window.id }) else { return }

        let proposed = CGPoint(
            x: dragStart.center.x + translation.width / size.width,
            y: dragStart.center.y + translation.height / size.height
        )
        windows[index].normalizedCenter = OverlayLayout.clampCenter(
            proposed,
            tile: tileSize(in: size),
            in: size
        )
    }

    func endDrag() {
        guard dragStart != nil else { return }
        dragStart = nil
        draggingID = nil
        layoutStore.save(windows)
    }

    func resetLayout() {
        layoutStore.reset()
        for index in windows.indices {
            windows[index].normalizedCenter = nil
        }
        resolvePositions()
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
        selectedID = readingOrder().first?.id
    }

    var selectedWindow: ManagedWindow? {
        guard let selectedID else { return nil }
        return windows.first { $0.id == selectedID }
    }

    enum SelectionDirection {
        case left, right, up, down, next, previous
    }

    /// R5. Arrow keys can't use column arithmetic any more — once tiles are
    /// placed freely there are no columns — so they pick the nearest tile in
    /// the direction of travel instead.
    func moveSelection(_ direction: SelectionDirection) {
        guard !windows.isEmpty else { return }
        guard let current = selectedWindow, let from = current.normalizedCenter else {
            selectedID = readingOrder().first?.id
            return
        }

        switch direction {
        case .next, .previous:
            let ordered = readingOrder()
            guard let index = ordered.firstIndex(where: { $0.id == current.id }) else { return }
            let step = direction == .next ? 1 : -1
            selectedID = ordered[(index + step + ordered.count) % ordered.count].id
        default:
            if let target = nearest(to: from, going: direction) {
                selectedID = target.id
            }
        }
    }

    /// Top-to-bottom, left-to-right. Rows are banded so tiles that are only
    /// slightly offset still read as being on the same row.
    private func readingOrder() -> [ManagedWindow] {
        windows.sorted { lhs, rhs in
            let a = lhs.normalizedCenter ?? .zero
            let b = rhs.normalizedCenter ?? .zero
            let bandA = (a.y * 8).rounded(.down)
            let bandB = (b.y * 8).rounded(.down)
            if bandA != bandB { return bandA < bandB }
            if a.x != b.x { return a.x < b.x }
            return lhs.id < rhs.id
        }
    }

    private func nearest(to origin: CGPoint, going direction: SelectionDirection) -> ManagedWindow? {
        var best: (window: ManagedWindow, cost: CGFloat)?

        for window in windows where window.id != selectedID {
            guard let center = window.normalizedCenter else { continue }
            let dx = center.x - origin.x
            let dy = center.y - origin.y

            let along: CGFloat
            let across: CGFloat
            switch direction {
            case .left: (along, across) = (-dx, abs(dy))
            case .right: (along, across) = (dx, abs(dy))
            case .up: (along, across) = (-dy, abs(dx))
            case .down: (along, across) = (dy, abs(dx))
            case .next, .previous: continue
            }

            // Must actually lie in the requested direction.
            guard along > 0.005 else { continue }
            // Weight sideways drift heavily so the selection prefers the tile
            // in line with the current one over one that's merely nearer.
            let cost = along + across * 2.5
            if cost < (best?.cost ?? .greatestFiniteMagnitude) {
                best = (window, cost)
            }
        }
        return best?.window
    }

    // MARK: - Window actions

    func activate(_ window: ManagedWindow) {
        WindowActions.activate(window)
    }

    /// Tiles are only dropped when the action actually succeeded.
    ///
    /// Removing optimistically looked fine while everything worked, but on
    /// failure the window was still open, so the next poll re-added it — and
    /// since unknown windows are appended, the tile appeared to jump to the
    /// end of the grid instead of reporting that nothing had happened.
    func close(_ window: ManagedWindow) {
        guard WindowActions.close(window) else {
            reportFailure(action: "close", window: window)
            return
        }
        remove(id: window.id)
    }

    func minimize(_ window: ManagedWindow) {
        guard WindowActions.minimize(window) else {
            reportFailure(action: "minimize", window: window)
            return
        }
        remove(id: window.id)
    }

    func quitApp(of window: ManagedWindow) {
        guard WindowActions.quitApp(window) else {
            reportFailure(action: "quit", window: window)
            return
        }
        removeWindows(ofPID: window.pid)
    }

    private func reportFailure(action: String, window: ManagedWindow) {
        if !PermissionsManager.isGranted(.accessibility) {
            flash("Can't \(action) — Accessibility permission not granted")
        } else {
            flash("\(window.appName) wouldn't let that window be \(action)d")
        }
    }

    private func flash(_ message: String) {
        actionMessage = message
        messageTask?.cancel()
        messageTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.actionMessage = nil
        }
    }

    private func remove(id: CGWindowID) {
        windows.removeAll { $0.id == id }
        advanceSelection()
    }

    private func removeWindows(ofPID pid: pid_t) {
        windows.removeAll { $0.pid == pid }
        advanceSelection()
    }

    private func advanceSelection() {
        if windows.isEmpty {
            selectedID = nil
            state = .empty
            return
        }
        if let selectedID, windows.contains(where: { $0.id == selectedID }) { return }
        selectedID = readingOrder().first?.id
    }
}

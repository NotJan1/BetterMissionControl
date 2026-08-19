import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Owns the overlay panel and translates key presses into model actions.
@MainActor
final class OverlayController {
    private let model = OverviewModel()
    private var panel: OverlayPanel?
    private var keyMonitor: Any?
    private var hotKeyDisplay: String = ""
    /// Set by the app delegate so ⌘, works from inside the overlay too.
    var onOpenSettings: (() -> Void)?

    var isVisible: Bool { panel?.isVisible ?? false }

    func updateHotKeyDisplay(_ value: String) {
        hotKeyDisplay = value
    }

    // MARK: - Show / hide

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        guard !isVisible else { return }

        // R1: on the display containing the cursor.
        let screen = WindowEnumerator.screenUnderCursor()
        let panel = OverlayPanel(frame: screen.frame)
        let root = OverlayView(
            model: model,
            hotKeyDisplay: hotKeyDisplay,
            onDismiss: { [weak self] in self?.hide() },
            onActivate: { [weak self] window in
                self?.activateAndDismiss(window)
            },
            onOpenAppleMissionControl: { [weak self] in
                // Dismiss without quitting: the app stays running and the next
                // summon behaves normally.
                self?.hide()
                AppleMissionControl.open()
            }
        )
        panel.contentView = NSHostingView(rootView: root)
        panel.setFrame(screen.frame, display: true)
        self.panel = panel

        // Positions are stored normalised, so the model needs the pixel size
        // before it can resolve any of them.
        model.overlaySize = screen.frame.size
        // Window frames arrive in a global, y-down space whose origin is the
        // top-left of the *main* display. Converting the panel's own origin
        // into that space is what lets the open animation start each tile
        // exactly where its window really is.
        let mainHeight = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
        model.overlayOrigin = CGPoint(
            x: screen.frame.minX,
            y: mainHeight - screen.frame.maxY
        )
        model.start()
        installKeyMonitor()

        // Deliberately last in the sequence, and only once the tiles have
        // finished flying into place.
        //
        // Revealing the Dock makes macOS reflow windows that were sized around
        // its absence. Doing it up front meant that reflow happened in plain
        // sight — Dock slides in, windows jump, *then* the overview appears —
        // and it also moved the very windows the open animation flies the
        // tiles out of, so they started from stale positions. Held until the
        // reveal is done, the reflow happens behind an overlay that's already
        // drawn.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(620))
            // Dismissed in the meantime — leave the Dock alone.
            guard let self, self.isVisible else { return }
            DockVisibility.show()
        }

        // `NSApp.activate()` alone is a *cooperative* request, and macOS is
        // free to ignore it for a background/accessory app — which it does
        // here, leaving the panel visible but never key. A panel that isn't
        // key gets no keystrokes, so the local monitor never fires and every
        // shortcut silently goes to whatever app was in front. The deprecated
        // `ignoringOtherApps:` form is the only one that reliably takes focus
        // for a hotkey-summoned overlay.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(panel.contentView)
    }

    /// - Parameter returningFocus: pass `false` when a window has just been
    ///   activated. Hiding the app in that case would hand focus back to
    ///   whatever was frontmost *before* the overlay opened, undoing the
    ///   activation the user just asked for.
    func hide(returningFocus: Bool = true) {
        guard let panel else { return }
        DockVisibility.restore()
        removeKeyMonitor()
        model.stop()
        panel.orderOut(nil)
        panel.contentView = nil
        self.panel = nil
        if returningFocus {
            NSApp.hide(nil)
        }
    }

    /// Dismisses and brings the chosen window forward, in that order.
    ///
    /// The order is the point. macOS lays a window out for the screen space
    /// available at the moment it is raised, and while the overview is open
    /// the Dock is being held visible — so raising a full-screen or zoomed
    /// window first left it short by the Dock's height once the Dock hid
    /// itself again, cutting off the bottom.
    private func activateAndDismiss(_ window: ManagedWindow) {
        // Putting the Dock back is synchronous, and the screen's usable area
        // recovers with it — measured with the `dockframe` self-test, the Dock
        // costs 92pt of height and `visibleFrame` is back to full the instant
        // this returns. So no waiting is needed, only the right order.
        DockVisibility.restore()
        hide(returningFocus: false)
        model.activate(window)
    }

    // MARK: - Keyboard

    /// A local event monitor is used rather than SwiftUI key handling or a
    /// menu, because it gets first refusal on ⌘W/⌘M/⌘Q — otherwise ⌘Q would
    /// quit *this* app instead of the app under the selected tile.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            if event.type == .otherMouseDown {
                return self.handleMiddleClick(event) ? nil : event
            }
            return self.handle(event) ? nil : event
        }
    }

    /// Middle-click a tile to close that window, the way AltTab does.
    ///
    /// Handled here rather than in SwiftUI, which has no middle-click gesture.
    /// A three-finger click becomes a real middle click if something like
    /// MiddleClick is running, so that works too without any special casing.
    private func handleMiddleClick(_ event: NSEvent) -> Bool {
        // Button 2 is the middle button; other extra buttons are left alone.
        guard event.buttonNumber == 2, let panel, panel.isVisible else { return false }

        // AppKit window coordinates run bottom-up; SwiftUI's layout is
        // top-down, so the y axis has to be flipped to match tile positions.
        let size = panel.frame.size
        let location = event.locationInWindow
        let point = CGPoint(x: location.x, y: size.height - location.y)

        guard let window = model.window(at: point, in: size) else { return false }
        model.close(window)
        return true
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    /// Returns true when the event was consumed.
    private func handle(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if modifiers.contains(.command) {
            // R12: ⌘, opens Settings. Handled before the tile shortcuts since
            // it doesn't need a selection.
            if event.charactersIgnoringModifiers == "," {
                hide()
                onOpenSettings?()
                return true
            }
            guard let window = model.selectedWindow else { return false }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "w": model.close(window); return true       // R6
            case "m": model.minimize(window); return true    // R6
            case "q": model.quitApp(of: window); return true // R6
            default: return false
            }
        }

        switch Int(event.keyCode) {
        case kVK_Escape:                                     // R9
            hide()
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter:               // R6
            guard let window = model.selectedWindow else { return true }
            activateAndDismiss(window)
            return true
        case kVK_LeftArrow:
            model.moveSelection(.left)
            return true
        case kVK_RightArrow:
            model.moveSelection(.right)
            return true
        case kVK_UpArrow:
            model.moveSelection(.up)
            return true
        case kVK_DownArrow:
            model.moveSelection(.down)
            return true
        case kVK_Tab:                                        // R5
            model.moveSelection(modifiers.contains(.shift) ? .previous : .next)
            return true
        default:
            return false
        }
    }

    func resetLayout() {
        model.resetLayout()
    }

    // MARK: - Test seams

    /// Dispatches a key event through exactly the path the local monitor uses.
    func debugHandleKey(_ event: NSEvent) -> Bool { handle(event) }
    var debugModel: OverviewModel { model }
}

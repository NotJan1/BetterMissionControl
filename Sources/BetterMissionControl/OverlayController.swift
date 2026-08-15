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
            onDismiss: { [weak self] in self?.hide() }
        )
        panel.contentView = NSHostingView(rootView: root)
        panel.setFrame(screen.frame, display: true)
        self.panel = panel

        model.start()
        installKeyMonitor()

        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        guard let panel else { return }
        removeKeyMonitor()
        model.stop()
        panel.orderOut(nil)
        panel.contentView = nil
        self.panel = nil
        // Hand focus back to whatever the user was in before.
        NSApp.hide(nil)
    }

    // MARK: - Keyboard

    /// A local event monitor is used rather than SwiftUI key handling or a
    /// menu, because it gets first refusal on ⌘W/⌘M/⌘Q — otherwise ⌘Q would
    /// quit *this* app instead of the app under the selected tile.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    private var currentColumns: Int {
        guard let size = panel?.frame.size else { return 1 }
        return OverlayLayout.columnCount(for: model.windows.count, in: size)
    }

    /// Returns true when the event was consumed.
    private func handle(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let columns = currentColumns

        if modifiers.contains(.command) {
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
            model.activate(window)
            hide()
            return true
        case kVK_LeftArrow:
            model.moveSelection(.left, columns: columns)
            return true
        case kVK_RightArrow:
            model.moveSelection(.right, columns: columns)
            return true
        case kVK_UpArrow:
            model.moveSelection(.up, columns: columns)
            return true
        case kVK_DownArrow:
            model.moveSelection(.down, columns: columns)
            return true
        case kVK_Tab:                                        // R5
            model.moveSelection(modifiers.contains(.shift) ? .previous : .next, columns: columns)
            return true
        default:
            return false
        }
    }

    func resetLayout() {
        model.resetLayout()
    }
}

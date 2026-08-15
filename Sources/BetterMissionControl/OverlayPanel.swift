import AppKit

/// The borderless, full-screen panel the overview is drawn into.
///
/// A borderless `NSPanel` refuses key status by default, which would break all
/// keyboard navigation — hence the overrides.
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    init(frame: NSRect) {
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        // Above the menu bar, so nothing shows through the overlay.
        level = NSWindow.Level(Int(CGWindowLevelForKey(.mainMenuWindow)) + 1)
        collectionBehavior = [
            .canJoinAllSpaces,      // present regardless of the active Space
            .fullScreenAuxiliary,   // and over full-screen apps
            .stationary,
            .ignoresCycle
        ]

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        // Keep the overlay out of screen recordings and screenshots of itself.
        sharingType = .none
    }
}

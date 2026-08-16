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
        // Deliberately left as the default (`.readWrite`): `.none` would keep
        // the overlay out of *all* screen capture, which silently makes it
        // impossible to screenshot or screen-record the overview. Excluding the
        // overlay from its own thumbnails is already handled elsewhere — window
        // enumeration skips our own process, and the desktop backdrop capture
        // filters out everything at or above the normal window layer.
    }
}

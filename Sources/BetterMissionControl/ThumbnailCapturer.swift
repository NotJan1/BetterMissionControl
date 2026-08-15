import CoreGraphics
import ScreenCaptureKit

enum ThumbnailCapturer {
    /// Tiles are never shown larger than roughly a third of the screen, so
    /// capturing beyond this just burns time.
    private static let maxDimension: CGFloat = 640
    /// Captured at 2x so thumbnails stay crisp on Retina displays.
    private static let scaleFactor: CGFloat = 2

    /// One-shot capture of a single window's contents.
    static func capture(_ window: SCWindow) async -> CGImage? {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()

        let longestSide = max(window.frame.width, window.frame.height)
        let fit = longestSide > 0 ? min(1.0, maxDimension / longestSide) : 1.0
        configuration.width = max(1, Int(window.frame.width * fit * scaleFactor))
        configuration.height = max(1, Int(window.frame.height * fit * scaleFactor))
        configuration.showsCursor = false
        configuration.scalesToFit = true
        configuration.ignoreShadowsSingleWindow = true

        return try? await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
    }

    /// Captures the desktop picture alone, by filtering out every window at or
    /// above the normal layer.
    ///
    /// This is what lets the overlay show a dimmed *desktop* the way native
    /// Mission Control does, rather than a blurred smear of the windows that
    /// happen to be underneath it.
    static func captureDesktop(display: SCDisplay, excluding windows: [SCWindow]) async -> CGImage? {
        let filter = SCContentFilter(display: display, excludingWindows: windows)
        let configuration = SCStreamConfiguration()
        configuration.width = display.width
        configuration.height = display.height
        configuration.showsCursor = false

        return try? await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
    }
}

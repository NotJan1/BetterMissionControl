import CoreGraphics
import ScreenCaptureKit

enum ThumbnailCapturer {
    /// Tiles are never shown larger than roughly a third of the screen, so
    /// capturing beyond this just burns time.
    private static let maxDimension: CGFloat = 640

    /// One-shot capture of a single window's contents.
    ///
    /// - Parameter backingScale: the display's backing scale factor. Capturing
    ///   at the display's own pixel density is what keeps thumbnails sharp;
    ///   capturing in points and letting the view upscale is what makes them
    ///   look soft on Retina.
    static func capture(_ window: SCWindow, backingScale: CGFloat = 2) async -> CGImage? {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()

        let longestSide = max(window.frame.width, window.frame.height)
        let fit = longestSide > 0 ? min(1.0, maxDimension / longestSide) : 1.0
        let scale = max(1, backingScale)
        configuration.width = max(1, Int(window.frame.width * fit * scale))
        configuration.height = max(1, Int(window.frame.height * fit * scale))
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

import CoreGraphics
import ScreenCaptureKit

enum ThumbnailCapturer {
    /// Absolute ceiling on a capture's longest side, in pixels, so a very
    /// large tile can't turn a once-a-second refresh into a memory problem.
    /// Well above what any realistic tile needs.
    private static let pixelCeiling: CGFloat = 2048

    /// One-shot capture of a single window's contents, sized for the tile it
    /// will be drawn into.
    ///
    /// - Parameters:
    ///   - targetSize: the size in points the thumbnail will be rendered at.
    ///   - backingScale: the display's backing scale factor.
    ///
    /// Capturing to a fixed cap regardless of tile size was what made
    /// thumbnails soft: with only a few windows open, tiles are drawn large
    /// enough that a capped capture had to be upscaled. Sizing from the
    /// rendered size × backing scale keeps a tile sharp at any tile size,
    /// and *reduces* work when tiles are small.
    static func capture(
        _ window: SCWindow,
        targetSize: CGSize,
        backingScale: CGFloat
    ) async -> CGImage? {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let size = pixelSize(for: window.frame.size, targetSize: targetSize, backingScale: backingScale)
        configuration.width = size.width
        configuration.height = size.height
        configuration.showsCursor = false
        configuration.scalesToFit = true
        configuration.ignoreShadowsSingleWindow = true

        return try? await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
    }

    /// Pixel dimensions to capture a window at so it is pixel-for-pixel sharp
    /// when drawn at `targetSize`, never exceeding the window's own resolution
    /// (capturing past native detail buys nothing).
    static func pixelSize(
        for windowSize: CGSize,
        targetSize: CGSize,
        backingScale: CGFloat
    ) -> (width: Int, height: Int) {
        guard windowSize.width > 0, windowSize.height > 0 else { return (1, 1) }

        // How much the window is scaled down to fit the tile.
        let fit = min(
            targetSize.width / windowSize.width,
            targetSize.height / windowSize.height
        )
        let scale = max(1, backingScale)
        // Capping at 1 keeps us from capturing above the window's own size.
        var pixels = CGSize(
            width: windowSize.width * min(fit, 1) * scale,
            height: windowSize.height * min(fit, 1) * scale
        )

        let longest = max(pixels.width, pixels.height)
        if longest > pixelCeiling {
            let shrink = pixelCeiling / longest
            pixels = CGSize(width: pixels.width * shrink, height: pixels.height * shrink)
        }
        return (max(1, Int(pixels.width.rounded())), max(1, Int(pixels.height.rounded())))
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

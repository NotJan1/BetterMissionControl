import AppKit
import ScreenCaptureKit

/// One snapshot of what's on screen, plus the ScreenCaptureKit handles needed
/// to turn it into thumbnails.
struct WindowSnapshot {
    var windows: [ManagedWindow] = []
    var sourceWindows: [CGWindowID: SCWindow] = [:]
    var display: SCDisplay?
    /// Everything at or above the normal window layer — excluded when
    /// capturing the desktop picture for the overlay background.
    var foregroundWindows: [SCWindow] = []
}

enum WindowEnumerator {
    /// Anything smaller than this is a palette, tooltip or shim rather than a
    /// window worth showing.
    private static let minimumSize = CGSize(width: 96, height: 72)

    /// System UI that reports itself as a normal window but isn't one the user
    /// thinks of as a window.
    private static let excludedBundleIDs: Set<String> = [
        "com.apple.dock",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.systemuiserver",
        "com.apple.WindowManager",
        "com.apple.wallpaper.agent",
        "com.apple.Spotlight",
        "com.apple.screencaptureui"
    ]

    static func snapshot() async throws -> WindowSnapshot {
        // `onScreenWindowsOnly: true` is what excludes minimized windows, which
        // is exactly the behaviour R2 asks for.
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )

        let ownPID = ProcessInfo.processInfo.processIdentifier
        var result = WindowSnapshot()
        result.display = displayUnderCursor(from: content.displays)
        result.foregroundWindows = content.windows.filter { $0.windowLayer >= 0 }

        var windows: [ManagedWindow] = []
        for scWindow in content.windows {
            guard scWindow.isOnScreen,
                  scWindow.windowLayer == 0,
                  scWindow.frame.width >= minimumSize.width,
                  scWindow.frame.height >= minimumSize.height,
                  let owner = scWindow.owningApplication,
                  owner.processID != ownPID,
                  !excludedBundleIDs.contains(owner.bundleIdentifier)
            else { continue }

            // Only apps with a Dock presence own windows a user would expect to
            // see here; this filters out background agents cleanly.
            let runningApp = NSRunningApplication(processIdentifier: owner.processID)
            guard runningApp?.activationPolicy == .regular else { continue }

            windows.append(
                ManagedWindow(
                    id: scWindow.windowID,
                    pid: owner.processID,
                    appName: owner.applicationName,
                    bundleID: owner.bundleIdentifier,
                    title: scWindow.title ?? "",
                    frame: scWindow.frame,
                    thumbnail: nil
                )
            )
            result.sourceWindows[scWindow.windowID] = scWindow
        }

        result.windows = autoArranged(windows)
        return result
    }

    /// R3's automatic layout: windows clustered by owning app, with app groups
    /// ordered roughly top-to-bottom, left-to-right by where they sit on
    /// screen — the shape native Mission Control tends to settle into.
    static func autoArranged(_ windows: [ManagedWindow]) -> [ManagedWindow] {
        // A coarse vertical band keeps windows that are only slightly offset
        // from reading as different rows.
        func anchor(_ window: ManagedWindow) -> (CGFloat, CGFloat) {
            ((window.frame.minY / 200).rounded(.down), window.frame.minX)
        }

        func precedes(_ a: (CGFloat, CGFloat), _ b: (CGFloat, CGFloat)) -> Bool {
            a.0 != b.0 ? a.0 < b.0 : a.1 < b.1
        }

        let groups = Dictionary(grouping: windows) { $0.bundleID ?? $0.appName }

        return groups.values
            .map { group -> [ManagedWindow] in
                group.sorted { lhs, rhs in
                    let (a, b) = (anchor(lhs), anchor(rhs))
                    if a != b { return precedes(a, b) }
                    return lhs.id < rhs.id
                }
            }
            .sorted { lhs, rhs in
                let (a, b) = (anchor(lhs[0]), anchor(rhs[0]))
                if a != b { return precedes(a, b) }
                return lhs[0].appName.localizedCaseInsensitiveCompare(rhs[0].appName) == .orderedAscending
            }
            .flatMap { $0 }
    }

    /// R1: the overlay belongs on whichever display the pointer is on.
    static func screenUnderCursor() -> NSScreen {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    private static func displayUnderCursor(from displays: [SCDisplay]) -> SCDisplay? {
        let screen = screenUnderCursor()
        guard let number = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber else { return displays.first }
        let displayID = CGDirectDisplayID(number.uint32Value)
        return displays.first { $0.displayID == displayID } ?? displays.first
    }
}

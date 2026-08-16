import AppKit
import ApplicationServices

/// Acts on other apps' windows through the Accessibility API.
///
/// ScreenCaptureKit gives us a `CGWindowID`; the Accessibility API speaks in
/// `AXUIElement`s, and there is no *public* call that bridges the two.
/// (`_AXUIElementGetWindow` does exactly this but is private SPI — the kind of
/// dependency that got HyperDock broken, so it's avoided here.) Instead we
/// match on the attributes both sides expose: owning process, frame, and title.
/// Both report frames in the same top-left-origin global space, so an exact
/// frame match is a strong signal and near-impossible for two windows of one
/// app to share.
@MainActor
enum WindowActions {
    /// How close two frames must be, in points, to count as the same window.
    private static let frameTolerance: CGFloat = 2.0
    /// Minimum confidence before we'll act on a match. A frame origin hit
    /// alone (4) isn't enough; origin+size, or title plus either, is.
    private static let minimumScore = 5

    // MARK: - Actions

    /// R8/R6: bring the window forward and give its app focus.
    static func activate(_ window: ManagedWindow) {
        let app = NSRunningApplication(processIdentifier: window.pid)
        if let element = axWindow(for: window) {
            AXUIElementPerformAction(element, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
        // Activating the app is what actually moves keyboard focus, and works
        // even when Accessibility hasn't been granted yet.
        app?.activate()
    }

    /// R6/R7: close a single window, leaving the app running.
    @discardableResult
    static func close(_ window: ManagedWindow) -> Bool {
        guard let element = axWindow(for: window) else { return false }
        var button: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXCloseButtonAttribute as CFString,
            &button
        ) == .success, let button else { return false }

        // CFTypeRef -> AXUIElement without a force cast.
        let closeButton = button as! AXUIElement
        return AXUIElementPerformAction(closeButton, kAXPressAction as CFString) == .success
    }

    /// R6: minimize. The tile disappears because minimized windows are
    /// excluded from enumeration entirely.
    @discardableResult
    static func minimize(_ window: ManagedWindow) -> Bool {
        guard let element = axWindow(for: window) else { return false }
        return AXUIElementSetAttributeValue(
            element,
            kAXMinimizedAttribute as CFString,
            kCFBooleanTrue
        ) == .success
    }

    /// R6: quit the owning app outright, taking all its tiles with it.
    @discardableResult
    static func quitApp(_ window: ManagedWindow) -> Bool {
        NSRunningApplication(processIdentifier: window.pid)?.terminate() ?? false
    }

    // MARK: - CGWindowID -> AXUIElement matching

    private static func axWindow(for window: ManagedWindow) -> AXUIElement? {
        guard AXIsProcessTrusted() else { return nil }

        let appElement = AXUIElementCreateApplication(window.pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXWindowsAttribute as CFString,
            &value
        ) == .success, let candidates = value as? [AXUIElement], !candidates.isEmpty
        else { return nil }

        var best: (element: AXUIElement, score: Int)?
        for candidate in candidates {
            let candidateScore = score(candidate, against: window)
            if candidateScore > (best?.score ?? 0) {
                best = (candidate, candidateScore)
            }
        }

        guard let best, best.score >= minimumScore else { return nil }
        return best.element
    }

    /// Confidence that `candidate` is the same window as `window`.
    ///
    /// Every candidate is scored, including when the app owns only one AX
    /// window — returning that one unchecked would happily close an unrelated
    /// window whenever the lists disagree (Finder's desktop window, for
    /// instance, is an AX window that no tile corresponds to).
    private static func score(_ candidate: AXUIElement, against window: ManagedWindow) -> Int {
        var score = 0
        if let frame = frame(of: candidate) {
            if abs(frame.origin.x - window.frame.origin.x) <= frameTolerance,
               abs(frame.origin.y - window.frame.origin.y) <= frameTolerance {
                score += 4
            }
            if abs(frame.width - window.frame.width) <= frameTolerance,
               abs(frame.height - window.frame.height) <= frameTolerance {
                score += 3
            }
        }
        if !window.title.isEmpty, title(of: candidate) == window.title {
            score += 3
        }
        return score
    }

    /// Explains what `axWindow(for:)` decided, for the self-test harness.
    static func debugMatchDescription(for window: ManagedWindow) -> String {
        guard AXIsProcessTrusted() else { return "accessibility not trusted" }
        let appElement = AXUIElementCreateApplication(window.pid)
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value)
        guard status == .success, let candidates = value as? [AXUIElement] else {
            return "kAXWindows failed (status \(status.rawValue))"
        }
        let scored = candidates.map { candidate -> String in
            let title = title(of: candidate) ?? ""
            let frame = frame(of: candidate).map { "(\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height)))" } ?? "no-frame"
            var hasCloseButton = false
            var button: CFTypeRef?
            if AXUIElementCopyAttributeValue(candidate, kAXCloseButtonAttribute as CFString, &button) == .success {
                hasCloseButton = button != nil
            }
            return "[score=\(score(candidate, against: window)) '\(title)' \(frame) closeButton=\(hasCloseButton)]"
        }
        return "\(candidates.count) candidate(s): \(scored.joined(separator: " "))"
    }

    // MARK: - Attribute readers

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let position: CGPoint = axValue(element, kAXPositionAttribute, .cgPoint),
              let size: CGSize = axValue(element, kAXSizeAttribute, .cgSize)
        else { return nil }
        return CGRect(origin: position, size: size)
    }

    private static func title(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXTitleAttribute as CFString,
            &value
        ) == .success else { return nil }
        return value as? String
    }

    /// Reads an `AXValue`-wrapped struct (points and sizes arrive boxed).
    private static func axValue<T>(
        _ element: AXUIElement,
        _ attribute: String,
        _ type: AXValueType
    ) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success, let value else { return nil }

        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == type else { return nil }

        let result = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { result.deallocate() }
        guard AXValueGetValue(axValue, type, result) else { return nil }
        return result.pointee
    }
}

import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// Takes the F3 / Mission Control key for this app.
///
/// The route was found by measurement, not assumption. Unticking "Mission
/// Control" in Keyboard Shortcuts does nothing to F3 — that setting governs the
/// key *combination* (⌘↑ or ⌃↑), while the function-row key is wired to Mission
/// Control further down the stack. The `keys` probe showed what actually
/// happens: pressing F3 emits a plain key event with virtual code 160, and it
/// is visible at a HID tap — which sits *before* the WindowServer.
///
/// That last part is what makes this work. A tap placed before the WindowServer
/// can swallow the event, so macOS never gets to act on it: Mission Control
/// doesn't open, and nothing in System Settings has to change. The media keys
/// keep working exactly as they did.
///
/// It needs Accessibility (already required) and no other permission.
@MainActor
final class MissionControlKeyTap {
    static let shared = MissionControlKeyTap()
    private init() {}

    private(set) var isRunning = false
    private(set) var lastError: String?

    @discardableResult
    func start(onPress: @escaping () -> Void) -> Bool {
        guard !isRunning else { return true }
        lastError = nil

        guard AXIsProcessTrusted() else {
            lastError = "Accessibility permission is needed to take over the F3 key"
            return false
        }

        keyHandler = { onPress() }

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)

        // `.cghidEventTap` is the whole point: a session tap sits after the
        // WindowServer, where consuming the event would be too late to stop
        // Mission Control. `.defaultTap` (not `.listenOnly`) is what allows
        // the event to be swallowed at all.
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: missionControlKeyCallback,
            userInfo: nil
        ) else {
            lastError = "Couldn't place a keyboard tap — check Accessibility permission"
            keyHandler = nil
            return false
        }

        tapPort = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isRunning = true
        return true
    }

    func stop() {
        guard isRunning else { return }
        if let tapPort {
            CGEvent.tapEnable(tap: tapPort, enable: false)
            CFMachPortInvalidate(tapPort)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        tapPort = nil
        runLoopSource = nil
        keyHandler = nil
        isRunning = false
    }
}

// MARK: - Tap plumbing
//
// At file scope because the tap callback is a C function pointer and can't
// capture context.

/// Virtual key codes the F3 key produces.
///
/// 160 is what it emits in its normal media-key role, measured with the `keys`
/// probe. 99 (`kVK_F3`) is what the same key sends when "use F1, F2, etc. as
/// standard function keys" is switched on, so accepting both means the feature
/// works whichever way that setting is left.
private let missionControlKeyCodes: Set<Int64> = [160, Int64(kVK_F3)]

private nonisolated(unsafe) var tapPort: CFMachPort?
private nonisolated(unsafe) var runLoopSource: CFRunLoopSource?
private nonisolated(unsafe) var keyHandler: (() -> Void)?

private func missionControlKeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    // macOS switches a tap off if it ever blocks for too long. Turning it back
    // on keeps the key working rather than silently dying after a hiccup.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tapPort { CGEvent.tapEnable(tap: tapPort, enable: true) }
        return Unmanaged.passUnretained(event)
    }

    let code = event.getIntegerValueField(.keyboardEventKeycode)
    guard missionControlKeyCodes.contains(code) else {
        return Unmanaged.passUnretained(event)
    }

    // Only act on the press; the release is swallowed too so nothing
    // downstream sees a stray half of a keystroke.
    if type == .keyDown, let keyHandler {
        DispatchQueue.main.async(execute: keyHandler)
    }
    return nil
}

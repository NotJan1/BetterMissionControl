import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// Finds out what macOS actually delivers to a background app for the two
/// inputs Mission Control owns: the F3 key and the four-finger swipe.
///
/// Runs as a guided sequence with one instruction at a time, because a free-
/// for-all can't tell an F3 press from a stray brightness key, or a swipe up
/// from the fingers coming back down afterwards. Each phase reports only what
/// it measured — no phase draws a conclusion the data doesn't support.
///
///     BMC_SELFTEST=input dist/BetterMissionControl.app/Contents/MacOS/BetterMissionControl
@MainActor
enum InputProbe {
    private static var monitors: [Any] = []

    static func run(seconds _: Int) async {
        note("Accessibility granted: \(AXIsProcessTrusted())")
        startEventTap()
        startGestureMonitors()
        startMultitouch()
        note("")

        await phase(
            "STEP 1 of 3 — press F3 (and nothing else) a few times",
            seconds: 12
        )
        reportKeys()

        await phase(
            "STEP 2 of 3 — four-finger swipe UP, several times",
            seconds: 12
        )
        let up = reportSwipe(named: "UP")

        await phase(
            "STEP 3 of 3 — four-finger swipe DOWN, several times",
            seconds: 12
        )
        let down = reportSwipe(named: "DOWN")

        note("")
        note(verdict(up: up, down: down))
        MultitouchBridge.stop()
    }

    // MARK: - Phases

    private static func phase(_ instruction: String, seconds: Int) async {
        Bucket.reset()
        note("")
        note(">>> \(instruction) — \(seconds)s")
        for remaining in stride(from: seconds, to: 0, by: -4) {
            try? await Task.sleep(for: .seconds(4))
            note("    \(remaining - 4)s")
        }
    }

    private static func reportKeys() {
        if Bucket.plainKeys.contains(kVK_F3) {
            note("    RESULT: F3 arrived as a plain key — RegisterEventHotKey can bind it directly")
        }
        if Bucket.systemKeys.isEmpty && !Bucket.plainKeys.contains(kVK_F3) {
            note("    RESULT: nothing reached the tap — the WindowServer consumes F3 upstream")
        }
        for code in Bucket.systemKeys.sorted() {
            note("    RESULT: system-defined key code=\(code) (\(nxKeyName(code)))")
        }
        if !Bucket.plainKeys.isEmpty {
            let names = Bucket.plainKeys.sorted().map { "\($0)" }.joined(separator: ", ")
            note("    (plain key codes also seen: \(names))")
        }
    }

    /// Returns the mean vertical velocity for this phase, or nil if no
    /// four-finger movement was seen.
    private static func reportSwipe(named name: String) -> Float? {
        guard !Bucket.velocities.isEmpty else {
            note("    RESULT: no four-finger movement detected")
            return nil
        }
        let mean = Bucket.velocities.reduce(0, +) / Float(Bucket.velocities.count)
        let positive = Bucket.velocities.filter { $0 > 0 }.count
        note(String(
            format: "    RESULT: %@ — %d samples, mean vY=%+.3f (%d positive, %d negative), max fingers=%d",
            name, Bucket.velocities.count, mean, positive,
            Bucket.velocities.count - positive, Bucket.maxTouches
        ))
        return mean
    }

    /// Only states a direction when the two phases actually disagree in sign.
    private static func verdict(up: Float?, down: Float?) -> String {
        var lines = ["VERDICT:"]
        lines.append("  four-finger contacts visible: \(Bucket.everSawFour ? "YES (private framework)" : "no")")
        lines.append("  public route to the gesture: \(Bucket.sawPublicMultiFinger ? "YES" : "no — nothing public delivers it")")

        switch (up, down) {
        case let (up?, down?) where up > 0 && down < 0:
            lines.append("  swipe up is POSITIVE vY (confirmed: up \(fmt(up)) vs down \(fmt(down)))")
        case let (up?, down?) where up < 0 && down > 0:
            lines.append("  swipe up is NEGATIVE vY (confirmed: up \(fmt(up)) vs down \(fmt(down)))")
        case let (up?, down?):
            lines.append("  INCONCLUSIVE — both phases had the same sign (up \(fmt(up)), down \(fmt(down)))")
        default:
            lines.append("  INCONCLUSIVE — one or both swipe phases saw nothing")
        }
        return lines.joined(separator: "\n")
    }

    private static func fmt(_ value: Float) -> String { String(format: "%+.3f", value) }

    // MARK: - Routes

    private static func startEventTap() {
        // Type 14 is NX_SYSDEFINED, where the F-key row's special-key
        // behaviour arrives when it isn't acting as a plain function key.
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << 14)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, _ in
                probeCallback(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: nil
        ) else {
            note("CGEventTap: FAILED — Input Monitoring probably not granted")
            return
        }
        note("CGEventTap: created")
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private static func startGestureMonitors() {
        let masks: [NSEvent.EventTypeMask] = [
            .gesture, .beginGesture, .endGesture, .swipe, .magnify, .scrollWheel
        ]
        for mask in masks {
            let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { event in
                let active = event.allTouches().filter {
                    $0.phase == .began || $0.phase == .moved || $0.phase == .stationary
                }
                if active.count >= 4 { Bucket.sawPublicMultiFinger = true }
            }
            if let monitor { monitors.append(monitor) }
        }
        note("global monitors: \(monitors.count)/\(masks.count) installed")
    }

    private static func startMultitouch() {
        let started = MultitouchBridge.start { _, raw, count, _, _ in
            let contacts = MultitouchBridge.touches(from: raw, count: count)
            guard !contacts.isEmpty else { return 0 }
            Bucket.maxTouches = max(Bucket.maxTouches, contacts.count)
            guard contacts.count >= 4 else { return 0 }
            Bucket.everSawFour = true
            let meanVelocityY = contacts.reduce(Float(0)) { $0 + $1.normalized.velocity.y }
                / Float(contacts.count)
            // Ignore fingers merely resting; only real movement carries a sign.
            if abs(meanVelocityY) > 0.25 {
                Bucket.velocities.append(meanVelocityY)
            }
            return 0
        }
        note(started
             ? "MultitouchSupport: started, \(MultitouchBridge.deviceCount) device(s)"
             : "MultitouchSupport: unavailable — \(MultitouchBridge.lastError ?? "unknown")")
    }

    // MARK: - Collection

    enum Bucket {
        nonisolated(unsafe) static var plainKeys: Set<Int> = []
        nonisolated(unsafe) static var systemKeys: Set<Int> = []
        nonisolated(unsafe) static var velocities: [Float] = []
        nonisolated(unsafe) static var maxTouches = 0
        nonisolated(unsafe) static var everSawFour = false
        nonisolated(unsafe) static var sawPublicMultiFinger = false

        /// Cleared between phases so each instruction is measured on its own.
        static func reset() {
            plainKeys.removeAll()
            systemKeys.removeAll()
            velocities.removeAll()
            maxTouches = 0
        }
    }

    /// Documented NX special-key codes, so a brightness key can't be mistaken
    /// for the one we're after.
    private static func nxKeyName(_ code: Int) -> String {
        let names: [Int: String] = [
            0: "Volume Up", 1: "Volume Down", 2: "Brightness Up", 3: "Brightness Down",
            4: "Num Lock", 6: "Help", 7: "Mute",
            8: "Keyboard Illumination Up", 9: "Keyboard Illumination Down",
            10: "Keyboard Illumination Toggle", 16: "Play/Pause", 17: "Next",
            18: "Previous", 19: "Fast Forward", 20: "Rewind"
        ]
        return names[code] ?? "unknown — possibly Mission Control"
    }

    nonisolated fileprivate static func note(_ message: String) {
        FileHandle.standardError.write(Data("PROBE: \(message)\n".utf8))
    }
}

/// Top-level so it can be used as a C function pointer.
private func probeCallback(type: CGEventType, event: CGEvent) {
    if type == .keyDown {
        InputProbe.Bucket.plainKeys.insert(Int(event.getIntegerValueField(.keyboardEventKeycode)))
        return
    }
    guard type.rawValue == 14,
          let nsEvent = NSEvent(cgEvent: event),
          nsEvent.subtype.rawValue == 8 else { return }
    let keyCode = Int((nsEvent.data1 & 0xFFFF_0000) >> 16)
    let isDown = ((nsEvent.data1 & 0x0000_FF00) >> 8) == 0x0A
    guard isDown else { return }
    InputProbe.Bucket.systemKeys.insert(keyCode)
}

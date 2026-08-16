import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// Finds out what macOS actually delivers to a background app for the two
/// inputs Mission Control owns: the F3 key and the four-finger swipe.
///
/// Both are claimed by the WindowServer by default, and the interesting
/// question is what — if anything — reaches us once the user has turned the
/// system's own use of them off. That's an empirical question about this
/// machine and this OS version, not something to guess at, so this listens on
/// every public route at once and reports which ones see the input:
///
///   * a `CGEventTap` on key events and on NX system-defined events, which is
///     where the F-key row's media-key behaviour shows up
///   * global `NSEvent` monitors for gesture, swipe and scroll events, with
///     the touch count that comes attached
///
///     BMC_SELFTEST=input dist/BetterMissionControl.app/Contents/MacOS/BetterMissionControl
@MainActor
enum InputProbe {
    private static var monitors: [Any] = []
    private static var tap: CFMachPort?

    static func run(seconds: Int) async {
        note("Accessibility granted: \(AXIsProcessTrusted())")
        note("Press F3, then do a four-finger swipe up. Listening for \(seconds)s…")
        note("--- events below ---")

        startEventTap()
        startGestureMonitors()
        startMultitouch()

        for remaining in stride(from: seconds, to: 0, by: -5) {
            try? await Task.sleep(for: .seconds(5))
            note("… \(remaining - 5)s left")
        }

        note("--- done ---")
        note(Summary.report())
    }

    // MARK: - CGEventTap (keyboard + media keys)

    private static func startEventTap() {
        // Type 14 is NX_SYSDEFINED, where the F-key row's special-key
        // behaviour arrives when it isn't acting as a plain function key.
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) | (1 << 14)

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
            note("CGEventTap: FAILED to create — Input Monitoring is probably not granted")
            Summary.tapCreated = false
            return
        }

        self.tap = tap
        Summary.tapCreated = true
        note("CGEventTap: created")
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    // MARK: - Gesture monitors

    private static func startGestureMonitors() {
        let masks: [(String, NSEvent.EventTypeMask)] = [
            ("gesture", .gesture),
            ("beginGesture", .beginGesture),
            ("endGesture", .endGesture),
            ("swipe", .swipe),
            ("magnify", .magnify),
            ("scrollWheel", .scrollWheel)
        ]

        for (name, mask) in masks {
            let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { event in
                let touches = event.allTouches()
                let active = touches.filter {
                    $0.phase == .began || $0.phase == .moved || $0.phase == .stationary
                }
                // Only a multi-finger event is interesting here; ordinary
                // two-finger scrolling would drown everything else out.
                guard !active.isEmpty || name != "scrollWheel" else { return }
                if active.count >= 3 {
                    Summary.sawMultiFinger = true
                    Summary.maxTouches = max(Summary.maxTouches, active.count)
                }
                if !active.isEmpty {
                    note("\(name): touches=\(active.count) (total \(touches.count)) deltaY=\(String(format: "%.1f", event.scrollingDeltaY))")
                }
            }
            if let monitor { monitors.append(monitor) }
        }
        note("global monitors: \(monitors.count)/\(masks.count) installed")
    }

    // MARK: - Private framework route

    /// Confirms the private binding works *and* which way "up" runs in
    /// normalised trackpad coordinates, rather than assuming it.
    private static func startMultitouch() {
        let started = MultitouchBridge.start { _, raw, count, _, _ in
            let contacts = MultitouchBridge.touches(from: raw, count: count)
            guard !contacts.isEmpty else { return 0 }
            Summary.maxRawTouches = max(Summary.maxRawTouches, Int(count))
            if count >= 4 {
                let meanVelocityY = contacts.reduce(Float(0)) { $0 + $1.normalized.velocity.y } / Float(count)
                if abs(meanVelocityY) > 0.2 {
                    Summary.sawRawFourFinger = true
                    Summary.rawVelocitySamples.append(meanVelocityY)
                    InputProbe.note("multitouch: \(count) fingers, mean vY=\(String(format: "%+.2f", meanVelocityY))")
                }
            }
            return 0
        }
        if started {
            note("MultitouchSupport: started, \(MultitouchBridge.deviceCount) device(s)")
        } else {
            note("MultitouchSupport: unavailable — \(MultitouchBridge.lastError ?? "unknown") (devices reported: \(MultitouchBridge.deviceCount))")
        }
        Summary.multitouchStarted = started
    }

    // MARK: - Reporting

    enum Summary {
        nonisolated(unsafe) static var tapCreated = false
        nonisolated(unsafe) static var sawPlainF3 = false
        nonisolated(unsafe) static var sawSystemDefined = false
        nonisolated(unsafe) static var systemDefinedKeys: Set<Int> = []
        nonisolated(unsafe) static var sawMultiFinger = false
        nonisolated(unsafe) static var maxTouches = 0
        nonisolated(unsafe) static var multitouchStarted = false
        nonisolated(unsafe) static var sawRawFourFinger = false
        nonisolated(unsafe) static var maxRawTouches = 0
        nonisolated(unsafe) static var rawVelocitySamples: [Float] = []

        static func report() -> String {
            var lines = ["SUMMARY:"]
            lines.append("  event tap created: \(tapCreated)")
            lines.append("  F3 as a plain key (kVK_F3): \(sawPlainF3 ? "YES — RegisterEventHotKey can bind it" : "no")")
            lines.append("  F3 as a system-defined media key: \(sawSystemDefined ? "YES — a CGEventTap can catch and consume it" : "no")")
            if !systemDefinedKeys.isEmpty {
                lines.append("  system-defined key codes seen: \(systemDefinedKeys.sorted())")
            }
            lines.append("  PUBLIC route to four-finger swipe: \(sawMultiFinger ? "YES (max \(maxTouches) touches)" : "no — macOS delivers nothing public")")
            lines.append("  PRIVATE route (MultitouchSupport) started: \(multitouchStarted)")
            lines.append("  PRIVATE route saw four fingers: \(sawRawFourFinger ? "YES (max \(maxRawTouches) contacts)" : "no (max \(maxRawTouches) contacts)")")
            if !rawVelocitySamples.isEmpty {
                let up = rawVelocitySamples.filter { $0 > 0 }.count
                let down = rawVelocitySamples.filter { $0 < 0 }.count
                lines.append("  swipe direction samples: \(up) positive, \(down) negative — positive vY means 'up'")
            }
            return lines.joined(separator: "\n")
        }
    }

    /// Nonisolated so the event-tap callback, which runs outside the main
    /// actor, can report what it sees.
    nonisolated fileprivate static func note(_ message: String) {
        FileHandle.standardError.write(Data("PROBE: \(message)\n".utf8))
    }
}

/// Top-level so it can be used as a C function pointer.
private func probeCallback(type: CGEventType, event: CGEvent) {
    if type == .keyDown {
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        if keyCode == kVK_F3 {
            InputProbe.Summary.sawPlainF3 = true
            InputProbe.note("tap: plain key F3 (keyCode \(keyCode)) — bindable directly")
        } else {
            InputProbe.note("tap: key keyCode=\(keyCode)")
        }
        return
    }

    // NX_SYSDEFINED, subtype 8 is where special keys arrive.
    guard type.rawValue == 14, let nsEvent = NSEvent(cgEvent: event), nsEvent.subtype.rawValue == 8 else { return }
    let keyCode = Int((nsEvent.data1 & 0xFFFF_0000) >> 16)
    let isDown = ((nsEvent.data1 & 0x0000_FF00) >> 8) == 0x0A
    guard isDown else { return }
    InputProbe.Summary.sawSystemDefined = true
    InputProbe.Summary.systemDefinedKeys.insert(keyCode)
    InputProbe.note("tap: system-defined special key code=\(keyCode)")
}

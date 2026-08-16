import AppKit
import ApplicationServices
import CoreGraphics

/// Headless exercise of the real enumeration and action code paths.
///
/// There's no Xcode on this machine and therefore no test target, so this runs
/// the actual `WindowEnumerator` and `WindowActions` in-process and reports
/// what happened:
///
///     BMC_SELFTEST=close BMC_SELFTEST_APP=TextEdit \
///       dist/BetterMissionControl.app/Contents/MacOS/BetterMissionControl
@MainActor
enum SelfTest {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["BMC_SELFTEST"] != nil
    }

    static func run() async -> Never {
        let env = ProcessInfo.processInfo.environment
        let mode = env["BMC_SELFTEST"] ?? "list"
        let targetApp = env["BMC_SELFTEST_APP"]

        log("accessibility=\(AXIsProcessTrusted()) screenRecording=\(CGPreflightScreenCaptureAccess())")

        guard let snapshot = try? await WindowEnumerator.snapshot() else {
            log("FAIL: WindowEnumerator.snapshot() threw")
            exit(1)
        }
        log("enumerated \(snapshot.windows.count) window(s)")
        for window in snapshot.windows {
            log("  id=\(window.id) app='\(window.appName)' title='\(window.title)' frame=\(shortFrame(window.frame))")
        }

        // Non-destructive: report what matching would decide for every window.
        if mode == "match" {
            for window in snapshot.windows {
                log("\(window.appName) '\(window.title)' -> \(WindowActions.debugMatchDescription(for: window))")
            }
            exit(0)
        }

        // Drives the real overlay and pushes a synthetic Cmd-W through the
        // real key handler, which is the part a headless action test misses.
        if mode == "key" {
            guard let targetApp else { log("FAIL: set BMC_SELFTEST_APP"); exit(1) }
            let controller = OverlayController()
            controller.show()
            try? await Task.sleep(for: .seconds(2))
            let model = controller.debugModel
            log("overlay windows=\(model.windows.count)")
            guard let target = model.windows.first(where: { $0.appName == targetApp }) else {
                log("FAIL: no window for '\(targetApp)' in overlay"); exit(1)
            }
            model.selectedID = target.id
            log("selected id=\(target.id) '\(target.title)'")

            guard let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                context: nil, characters: "w", charactersIgnoringModifiers: "w",
                isARepeat: false, keyCode: 13
            ) else { log("FAIL: could not build event"); exit(1) }

            log("event: mods=\(event.modifierFlags.rawValue) chars='\(event.charactersIgnoringModifiers ?? "")' keyCode=\(event.keyCode)")
            let handled = controller.debugHandleKey(event)
            log("handler returned handled=\(handled)")

            try? await Task.sleep(for: .milliseconds(1200))
            log("overlay now has \(model.windows.count) window(s)")
            if let after = try? await WindowEnumerator.snapshot() {
                let stillOpen = after.windows.contains { $0.id == target.id }
                log(stillOpen ? "RESULT: window STILL OPEN" : "RESULT: window closed")
                if let idx = model.windows.firstIndex(where: { $0.id == target.id }) {
                    log("RESULT: tile still present at index \(idx) of \(model.windows.count)")
                }
            }
            exit(0)
        }

        // Does the overlay actually take keyboard focus? If the panel never
        // becomes key, the local monitor never sees a keystroke.
        if mode == "focus" {
            let controller = OverlayController()
            controller.show()
            try? await Task.sleep(for: .seconds(2))
            log("NSApp.isActive=\(NSApp.isActive)")
            for window in NSApp.windows where window is OverlayPanel {
                log("panel visible=\(window.isVisible) key=\(window.isKeyWindow) main=\(window.isMainWindow) level=\(window.level.rawValue)")
                log("panel canBecomeKey=\(window.canBecomeKey) acceptsFirstResponder=\(window.contentView?.acceptsFirstResponder ?? false)")
            }
            log("NSApp.keyWindow=\(NSApp.keyWindow.map { String(describing: type(of: $0)) } ?? "nil")")
            exit(0)
        }

        // Free-form positioning: drag a tile, then confirm the exact position
        // was kept and written to disk.
        if mode == "drag" {
            guard let targetApp else { log("FAIL: set BMC_SELFTEST_APP"); exit(1) }
            let controller = OverlayController()
            controller.show()
            try? await Task.sleep(for: .seconds(2))
            let model = controller.debugModel
            let size = model.overlaySize
            log("overlay size=\(Int(size.width))x\(Int(size.height)) windows=\(model.windows.count)")
            for window in model.windows {
                log("  '\(window.appName)' center=\(describe(window.normalizedCenter))")
            }
            guard let target = model.windows.first(where: { $0.appName == targetApp }) else {
                log("FAIL: no window for '\(targetApp)'"); exit(1)
            }
            let before = target.normalizedCenter
            log("dragging '\(target.appName)' from \(describe(before))")

            model.beginDrag(target)
            model.updateDrag(target, translation: CGSize(width: -260, height: 180), in: size)
            model.endDrag()

            let after = model.windows.first { $0.id == target.id }?.normalizedCenter
            log("after drag center=\(describe(after))")
            log(before == after ? "RESULT: position UNCHANGED (drag failed)" : "RESULT: position moved")

            // A grid would have snapped to a column; a free canvas should not.
            if let after {
                let automatic = OverlayLayout.automaticCenters(count: model.windows.count, in: size)
                let snapped = automatic.contains { abs($0.x - after.x) < 0.001 && abs($0.y - after.y) < 0.001 }
                log(snapped ? "RESULT: SNAPPED to a grid slot" : "RESULT: free position (no grid snap)")
            }

            let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("BetterMissionControl/layout.json")
            if let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) {
                log("layout.json: \(text.prefix(400))")
            } else {
                log("RESULT: layout.json NOT written")
            }
            exit(0)
        }

        // Reopens the overlay and reports where tiles landed — run after
        // "drag" to confirm a custom layout survives between sessions.
        if mode == "persist" {
            let controller = OverlayController()
            controller.show()
            try? await Task.sleep(for: .seconds(2))
            for window in controller.debugModel.windows {
                log("restored '\(window.appName)' '\(window.title)' center=\(describe(window.normalizedCenter))")
            }
            exit(0)
        }

        guard mode != "list" else { exit(0) }

        guard let targetApp else {
            log("FAIL: set BMC_SELFTEST_APP to choose a target")
            exit(1)
        }
        guard let target = snapshot.windows.first(where: { $0.appName == targetApp }) else {
            log("FAIL: no window owned by '\(targetApp)'")
            exit(1)
        }
        log("target: id=\(target.id) '\(target.title)' frame=\(shortFrame(target.frame))")

        switch mode {
        case "close":
            let matched = WindowActions.debugMatchDescription(for: target)
            log("match: \(matched)")
            let ok = WindowActions.close(target)
            log("WindowActions.close returned \(ok)")
            // Give the app a moment, then confirm the window really went away.
            try? await Task.sleep(for: .milliseconds(700))
            if let after = try? await WindowEnumerator.snapshot() {
                let stillThere = after.windows.contains { $0.id == target.id }
                log(stillThere ? "RESULT: window STILL OPEN" : "RESULT: window closed")
            }
        case "minimize":
            let ok = WindowActions.minimize(target)
            log("WindowActions.minimize returned \(ok)")
        default:
            log("FAIL: unknown mode '\(mode)'")
            exit(1)
        }
        exit(0)
    }

    private static func describe(_ point: CGPoint?) -> String {
        guard let point else { return "nil" }
        return String(format: "(%.3f, %.3f)", point.x, point.y)
    }

    private static func shortFrame(_ r: CGRect) -> String {
        "(\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height)))"
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("SELFTEST: \(message)\n".utf8))
    }
}
